Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Firewall teardown leaf" {
    BeforeAll {
        $script:LeafPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Teardown.ps1"

        $script:CreatedStubs = @()
        $stubs = @{
            'Get-NetFirewallProfile' = { param($Profile) }
            'Set-NetFirewallProfile' = { param($Profile, $DefaultOutboundAction) }
            'Get-NetFirewallRule'    = { param($DisplayName, $Group) }
            'Remove-NetFirewallRule' = { param([string[]]$DisplayName, [string]$Group, [Parameter(ValueFromPipeline = $true)]$InputObject) process { } }
        }
        foreach ($commandName in @($stubs.Keys)) {
            if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                New-Item -Path "Function:\global:$commandName" -Value $stubs[$commandName] -Force | Out-Null
                $script:CreatedStubs += @($commandName)
            }
        }

        . $script:LeafPath

        function New-ActionMap {
            param([string]$Domain, [string]$Private, [string]$Public)
            $map = @{}
            if ($Domain) { $map['Domain'] = $Domain }
            if ($Private) { $map['Private'] = $Private }
            if ($Public) { $map['Public'] = $Public }
            return $map
        }

        function Format-Plan {
            param([object[]]$Plan)
            return (@($Plan | ForEach-Object { "$($_.Profile)=$($_.Action)" } | Sort-Object) -join ',')
        }

        function Resolve-MockFirewallProfileName {
            # The real NetSecurity cmdlets expose the profile as -Name with the -Profile alias;
            # Pester injects the real parameter name on Windows, while the local stubs use
            # -Profile. Accept either so the mocks capture the profile on both platforms.
            param($Name, $Profile)
            if (-not [string]::IsNullOrWhiteSpace([string]$Name)) { return [string]$Name }
            return [string]$Profile
        }
    }

    AfterAll {
        foreach ($commandName in @($script:CreatedStubs)) {
            if ($commandName) { Remove-Item -Path "Function:\$commandName" -ErrorAction SilentlyContinue }
        }
    }

    Context "Structure" {
        It "Defines every OpenPath command it calls" {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:LeafPath, [ref]$null, [ref]$null)
            $defined = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                    ForEach-Object { $_.Name })
            $called = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                    ForEach-Object { $_.GetCommandName() } |
                    Where-Object { $_ -and $_ -match '-OpenPath' } |
                    Sort-Object -Unique)

            $called.Count | Should -BeGreaterThan 0
            foreach ($name in $called) {
                $defined | Should -Contain $name
            }
        }

        It "Does not log" {
            (Get-Content -LiteralPath $script:LeafPath -Raw) | Should -Not -Match 'Write-OpenPathLog'
        }
    }

    Context "Outbound restore plan" {
        It "<Name>" -ForEach @(
            @{ Name = 'No state, all Block, OnlyBlocked: all three to Allow'; Recorded = @{}; HasState = $false; Current = 'Block,Block,Block'; Modes = @('OnlyBlocked'); Expected = 'Domain=Allow,Private=Allow,Public=Allow' }
            @{ Name = 'No state, all Allow, OnlyBlocked: empty'; Recorded = @{}; HasState = $false; Current = 'Allow,Allow,Allow'; Modes = @('OnlyBlocked'); Expected = '' }
            @{ Name = 'No state, only Public Block, OnlyBlocked: Public to Allow'; Recorded = @{}; HasState = $false; Current = 'Allow,Allow,Block'; Modes = @('OnlyBlocked'); Expected = 'Public=Allow' }
            @{ Name = 'No state, all Allow, AllProfiles: all three to Allow'; Recorded = @{}; HasState = $false; Current = 'Allow,Allow,Allow'; Modes = @('AllProfiles'); Expected = 'Domain=Allow,Private=Allow,Public=Allow' }
            @{ Name = 'All NotConfigured recorded: all three to NotConfigured'; Recorded = @{ Domain = 'NotConfigured'; Private = 'NotConfigured'; Public = 'NotConfigured' }; HasState = $true; Current = 'Block,Block,Block'; Modes = @('OnlyBlocked', 'AllProfiles'); Expected = 'Domain=NotConfigured,Private=NotConfigured,Public=NotConfigured' }
            @{ Name = 'All Block recorded: all three to Allow'; Recorded = @{ Domain = 'Block'; Private = 'Block'; Public = 'Block' }; HasState = $true; Current = 'Block,Block,Block'; Modes = @('OnlyBlocked', 'AllProfiles'); Expected = 'Domain=Allow,Private=Allow,Public=Allow' }
            @{ Name = 'Only Domain Allow recorded: all three to Allow'; Recorded = @{ Domain = 'Allow' }; HasState = $true; Current = 'Block,Block,Block'; Modes = @('OnlyBlocked', 'AllProfiles'); Expected = 'Domain=Allow,Private=Allow,Public=Allow' }
            @{ Name = 'Garbage recorded: all three to Allow'; Recorded = @{ Domain = 'Garbage'; Private = 'Garbage'; Public = 'Garbage' }; HasState = $true; Current = 'Block,Block,Block'; Modes = @('OnlyBlocked', 'AllProfiles'); Expected = 'Domain=Allow,Private=Allow,Public=Allow' }
        ) {
            $currentValues = $Current -split ','
            $currentMap = New-ActionMap -Domain $currentValues[0] -Private $currentValues[1] -Public $currentValues[2]
            foreach ($mode in $Modes) {
                $plan = @(Get-OpenPathFirewallOutboundRestorePlan -RecordedActions $Recorded -CurrentActions $currentMap -HasState $HasState -WhenNoState $mode)
                Format-Plan -Plan $plan | Should -Be $Expected -Because "mode $mode"
                @($plan | Where-Object { $_.Action -eq 'Block' }).Count | Should -Be 0
            }
        }
    }

    Context "Outbound restore executor" {
        BeforeEach {
            $script:statePath = Join-Path $TestDrive "egress-floor-prev-outbound-$([guid]::NewGuid().ToString('N')).json"
            $global:openPathProfileCalls = [System.Collections.Generic.List[string]]::new()
            $global:openPathFailingProfile = ''
            Mock Get-NetFirewallProfile {
                param($Name, $Profile)
                [PSCustomObject]@{ Name = (Resolve-MockFirewallProfileName -Name $Name -Profile $Profile); DefaultOutboundAction = 'Block' }
            }
            Mock Set-NetFirewallProfile {
                param($Name, $Profile, $DefaultOutboundAction)
                $profileName = Resolve-MockFirewallProfileName -Name $Name -Profile $Profile
                $global:openPathProfileCalls.Add("${profileName}:$DefaultOutboundAction")
                if ($profileName -eq $global:openPathFailingProfile) { throw "profile $profileName refused" }
            }
        }

        AfterEach {
            Remove-Variable -Name openPathProfileCalls, openPathFailingProfile -Scope Global -ErrorAction SilentlyContinue
        }

        It "Treats a <Kind> state file as no usable state" -ForEach @(
            @{ Kind = 'empty'; Bytes = [byte[]]@() }
            @{ Kind = 'cut'; Bytes = [System.Text.Encoding]::ASCII.GetBytes('{ "Domain": "NotConf') }
            @{ Kind = 'zero-filled'; Bytes = [byte[]](@(0) * 64) }
        ) {
            [System.IO.File]::WriteAllBytes($script:statePath, $Bytes)

            $result = Invoke-OpenPathFirewallOutboundRestore -StatePath $script:statePath -WhenNoState OnlyBlocked

            $result.StateUnreadable | Should -BeTrue
            @($global:openPathProfileCalls | Sort-Object) | Should -Be @('Domain:Allow', 'Private:Allow', 'Public:Allow')
            @($result.Applied).Count | Should -Be 3
        }

        It "Applies a recorded state and deletes it with -RemoveState" {
            Set-Content -LiteralPath $script:statePath -Value '{ "Domain": "NotConfigured", "Private": "Allow", "Public": "Block" }' -Encoding ASCII

            $result = Invoke-OpenPathFirewallOutboundRestore -StatePath $script:statePath -WhenNoState OnlyBlocked -RemoveState

            $result.StateUnreadable | Should -BeFalse
            @($global:openPathProfileCalls | Sort-Object) | Should -Be @('Domain:NotConfigured', 'Private:Allow', 'Public:Allow')
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
        }

        It "Keeps the state file without -RemoveState" {
            Set-Content -LiteralPath $script:statePath -Value '{ "Domain": "Allow", "Private": "Allow", "Public": "Allow" }' -Encoding ASCII

            Invoke-OpenPathFirewallOutboundRestore -StatePath $script:statePath -WhenNoState OnlyBlocked | Out-Null

            Test-Path -LiteralPath $script:statePath | Should -BeTrue
        }

        It "Reports a failing profile and still applies the others" {
            $global:openPathFailingProfile = 'Private'

            $result = Invoke-OpenPathFirewallOutboundRestore -StatePath $script:statePath -WhenNoState AllProfiles

            @($result.Errors).Count | Should -Be 1
            @($result.Errors)[0] | Should -Match 'Private'
            @($global:openPathProfileCalls | Sort-Object) | Should -Be @('Domain:Allow', 'Private:Allow', 'Public:Allow')
            @($result.Applied | ForEach-Object { $_.Profile } | Sort-Object) | Should -Be @('Domain', 'Public')
        }

        It "Returns without calls when Set-NetFirewallProfile is missing" {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Set-NetFirewallProfile' }

            $result = Invoke-OpenPathFirewallOutboundRestore -StatePath $script:statePath -WhenNoState AllProfiles

            @($result.Applied).Count | Should -Be 0
            Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly
            Should -Invoke Get-NetFirewallProfile -Times 0 -Exactly
        }
    }

    Context "Audit restore" {
        BeforeEach {
            $script:auditStatePath = Join-Path $TestDrive "egress-floor-audit-prev-$([guid]::NewGuid().ToString('N')).json"
            $global:openPathAuditCalls = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-OpenPathAuditPol {
                param([string[]]$Arguments)
                $global:openPathAuditCalls.Add(($Arguments -join ' '))
            }
        }

        AfterEach {
            Remove-Variable -Name openPathAuditCalls -Scope Global -ErrorAction SilentlyContinue
        }

        It "Is a no-op when the state file is missing" {
            $result = Invoke-OpenPathFirewallAuditRestore -StatePath $script:auditStatePath

            $result.Restored | Should -BeFalse
            $result.Error | Should -BeNullOrEmpty
            $global:openPathAuditCalls.Count | Should -Be 0
        }

        It "Restores setting value <Value> as success:<Success> failure:<Failure>" -ForEach @(
            @{ Value = 3; Success = 'enable'; Failure = 'enable' }
            @{ Value = 2; Success = 'disable'; Failure = 'enable' }
        ) {
            Set-Content -LiteralPath $script:auditStatePath -Value "{ ""settingValue"": $Value }" -Encoding ASCII

            $result = Invoke-OpenPathFirewallAuditRestore -StatePath $script:auditStatePath

            $result.Restored | Should -BeTrue
            @($global:openPathAuditCalls) | Should -Be @("/set /subcategory:{0CCE9226-69AE-11D9-BED3-505054503030} /success:$Success /failure:$Failure")
            Test-Path -LiteralPath $script:auditStatePath | Should -BeFalse
        }

        It "Returns an error for an unreadable file and still removes it" {
            Set-Content -LiteralPath $script:auditStatePath -Value '{ "settingVal' -Encoding ASCII

            $result = Invoke-OpenPathFirewallAuditRestore -StatePath $script:auditStatePath

            $result.Restored | Should -BeFalse
            $result.Error | Should -Not -BeNullOrEmpty
            $global:openPathAuditCalls.Count | Should -Be 0
            Test-Path -LiteralPath $script:auditStatePath | Should -BeFalse
        }
    }

    Context "Rule removal" {
        BeforeEach {
            $script:manifestPath = Join-Path $TestDrive "firewall-rules-$([guid]::NewGuid().ToString('N')).json"
            $global:openPathRuleEvents = [System.Collections.Generic.List[string]]::new()
            $global:openPathRemainingRules = [System.Collections.Generic.List[object]]::new()
            Mock Get-NetFirewallRule {
                param($DisplayName, $Group)
                $names = @($DisplayName | ForEach-Object { [string]$_ })
                $global:openPathRuleEvents.Add("get:name:$($names -join ',')")
                return @($global:openPathRemainingRules)
            }
            Mock Remove-NetFirewallRule {
                param($DisplayName, $Group)
                $names = @($DisplayName | ForEach-Object { [string]$_ })
                $global:openPathRuleEvents.Add("remove:names:$($names -join ',')")
            }
        }

        AfterEach {
            Remove-Variable -Name openPathRuleEvents, openPathRemainingRules -Scope Global -ErrorAction SilentlyContinue
        }

        It "Uses a constant number of bulk calls for <Count> manifest rules" -ForEach @(
            @{ Count = 2 }
            @{ Count = 87 }
        ) {
            $names = @(1..$Count | ForEach-Object { "OpenPath-DNS-Rule-$_" })
            Set-Content -LiteralPath $script:manifestPath -Value (ConvertTo-Json -InputObject $names) -Encoding ASCII

            $result = Remove-OpenPathFirewallOwnedRules -ManifestPath $script:manifestPath -RulePrefix 'OpenPath-DNS' -RemoveManifest

            $result.ManifestError | Should -BeNullOrEmpty
            @($result.Errors).Count | Should -Be 0
            $events = @($global:openPathRuleEvents)
            # No Get probes: the manifest and prefix deletes are one bulk call each.
            @($events | Where-Object { $_ -like 'get:name:*' }).Count | Should -Be 0
            @($events | Where-Object { $_ -like 'remove:names:*' }).Count | Should -Be 2
            # The manifest names were removed together, never one Remove per rule.
            $manifestRemoves = @($events | Where-Object { $_ -like 'remove:names:*' -and $_ -ne 'remove:names:OpenPath-DNS-*' })
            $manifestRemoves.Count | Should -Be 1
            ($manifestRemoves[0] -split ',').Count | Should -Be $Count
            Test-Path -LiteralPath $script:manifestPath | Should -BeFalse
        }

        It "Removes leftover manifest names, then leftover prefix rules, and deletes the manifest last" {
            Set-Content -LiteralPath $script:manifestPath -Value '["OpenPath-DNS-B", "OpenPath-DNS-A"]' -Encoding ASCII
            $global:openPathRemainingRules.Add([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-A' })
            $global:openPathRemainingRules.Add([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-B' })

            Remove-OpenPathFirewallOwnedRules -ManifestPath $script:manifestPath -RulePrefix 'OpenPath-DNS' -RemoveManifest | Out-Null

            $events = @($global:openPathRuleEvents)
            $events[0] | Should -Be 'remove:names:OpenPath-DNS-A,OpenPath-DNS-B'
            $events[1] | Should -Be 'remove:names:OpenPath-DNS-*'
            Test-Path -LiteralPath $script:manifestPath | Should -BeFalse
        }

        It "Keeps the manifest without -RemoveManifest" {
            Set-Content -LiteralPath $script:manifestPath -Value '["OpenPath-DNS-A"]' -Encoding ASCII

            Remove-OpenPathFirewallOwnedRules -ManifestPath $script:manifestPath | Out-Null

            Test-Path -LiteralPath $script:manifestPath | Should -BeTrue
        }

        It "Sets ManifestError for an unreadable manifest and still removes the prefix" {
            Set-Content -LiteralPath $script:manifestPath -Value '[ "OpenPath-DNS-A", ' -Encoding ASCII
            $global:openPathRemainingRules.Add([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-legacy-rule' })

            $result = Remove-OpenPathFirewallOwnedRules -ManifestPath $script:manifestPath -RulePrefix 'OpenPath-DNS' -RemoveManifest

            $result.ManifestError | Should -Not -BeNullOrEmpty
            @($global:openPathRuleEvents) | Should -Contain 'remove:names:OpenPath-DNS-*'
        }

        It "Removes leftover ungrouped prefix rules with one wildcard call" {
            $global:openPathRemainingRules.Add([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-legacy-1' })
            $global:openPathRemainingRules.Add([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-legacy-2' })

            $result = Remove-OpenPathFirewallOwnedRules -ManifestPath $script:manifestPath -RulePrefix 'OpenPath-DNS'

            @($result.Errors).Count | Should -Be 0
            @($global:openPathRuleEvents | Where-Object { $_ -eq 'get:name:OpenPath-DNS-*' }).Count | Should -Be 0
            @($global:openPathRuleEvents | Where-Object { $_ -eq 'remove:names:OpenPath-DNS-*' }).Count | Should -Be 1
            @($global:openPathRuleEvents | Where-Object { $_ -like 'remove:names:OpenPath-DNS-legacy-*' }).Count | Should -Be 0
        }

        It "Collects removal failures instead of throwing" {
            $global:openPathRemainingRules.Add([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-legacy-rule' })
            Mock Remove-NetFirewallRule {
                param($DisplayName, $Group)
                throw 'firewall refused'
            }

            $result = Remove-OpenPathFirewallOwnedRules -ManifestPath $script:manifestPath -RulePrefix 'OpenPath-DNS'

            @($result.Errors).Count | Should -Be 1
            @($result.PrefixErrors).Count | Should -Be 1
        }
    }

    Context "Through the standalone uninstaller wrapper" {
        BeforeEach {
            $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($uninstallPath, [ref]$null, [ref]$null)
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-OpenPathFirewallRules' }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))

            $OpenPathRoot = Join-Path $TestDrive "op-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path (Join-Path $OpenPathRoot 'data') -Force | Out-Null
            $global:openPathWrapperEvents = [System.Collections.Generic.List[string]]::new()
            Mock Get-NetFirewallProfile {
                param($Name, $Profile)
                [PSCustomObject]@{ Name = (Resolve-MockFirewallProfileName -Name $Name -Profile $Profile); DefaultOutboundAction = 'Block' }
            }
            Mock Set-NetFirewallProfile {
                param($Name, $Profile, $DefaultOutboundAction)
                $global:openPathWrapperEvents.Add("set:$(Resolve-MockFirewallProfileName -Name $Name -Profile $Profile):$DefaultOutboundAction")
            }
            Mock Get-NetFirewallRule { param($DisplayName, $Group) [PSCustomObject]@{ DisplayName = 'rule' } }
            Mock Remove-NetFirewallRule {
                param([string[]]$DisplayName, [string]$Group, [Parameter(ValueFromPipeline = $true)]$InputObject)
                process { $global:openPathWrapperEvents.Add('remove') }
            }
            Mock Write-Warning { }
        }

        AfterEach {
            Remove-Variable -Name openPathWrapperEvents -Scope Global -ErrorAction SilentlyContinue
        }

        It "Ends a Block default with no state file at Allow and never writes Block" {
            Remove-OpenPathFirewallRules

            $sets = @($global:openPathWrapperEvents | Where-Object { $_ -like 'set:*' })
            @($sets | Sort-Object) | Should -Be @('set:Domain:Allow', 'set:Private:Allow', 'set:Public:Allow')
            @($sets | Where-Object { $_ -like '*:Block' }).Count | Should -Be 0
        }

        It "Keeps the rules and warns when a profile cannot leave Block" {
            Mock Set-NetFirewallProfile {
                param($Name, $Profile, $DefaultOutboundAction)
                throw "profile $(Resolve-MockFirewallProfileName -Name $Name -Profile $Profile) refused"
            }

            { Remove-OpenPathFirewallRules } | Should -Not -Throw

            @($global:openPathWrapperEvents | Where-Object { $_ -eq 'remove' }).Count | Should -Be 0
            Should -Invoke Write-Warning -ParameterFilter { $Message -like '*OpenPath firewall rules were kept*' } -Times 1 -Exactly
        }

        It "Treats a <Kind> state file as no usable state and still removes the rules" -ForEach @(
            @{ Kind = 'empty'; Bytes = [byte[]]@() }
            @{ Kind = 'cut'; Bytes = [System.Text.Encoding]::ASCII.GetBytes('{ "Domain": "Blo') }
            @{ Kind = 'zero-filled'; Bytes = [byte[]](@(0) * 64) }
        ) {
            [System.IO.File]::WriteAllBytes((Join-Path $OpenPathRoot 'data\egress-floor-prev-outbound.json'), $Bytes)

            { Remove-OpenPathFirewallRules } | Should -Not -Throw

            @($global:openPathWrapperEvents | Where-Object { $_ -like 'set:*' } | Sort-Object) |
                Should -Be @('set:Domain:Allow', 'set:Private:Allow', 'set:Public:Allow')
            @($global:openPathWrapperEvents | Where-Object { $_ -eq 'remove' }).Count | Should -BeGreaterThan 0
            Should -Invoke Write-Warning -ParameterFilter { $Message -like 'Ignoring unreadable egress-floor state*' } -Times 1 -Exactly
        }
    }

    Context "Keeping the rules when the outbound restore fails" {
        BeforeEach {
            $global:openPathKeepEvents = [System.Collections.Generic.List[string]]::new()
            Mock Get-NetFirewallProfile {
                param($Name, $Profile)
                [PSCustomObject]@{ Name = (Resolve-MockFirewallProfileName -Name $Name -Profile $Profile); DefaultOutboundAction = 'Block' }
            }
            Mock Set-NetFirewallProfile {
                param($Name, $Profile, $DefaultOutboundAction)
                $profileName = Resolve-MockFirewallProfileName -Name $Name -Profile $Profile
                if ($profileName -eq 'Public') { throw 'profile Public refused' }
                $global:openPathKeepEvents.Add("set:$profileName")
            }
            Mock Get-NetFirewallRule { param($DisplayName, $Group) [PSCustomObject]@{ DisplayName = 'rule' } }
            Mock Remove-NetFirewallRule {
                param([string[]]$DisplayName, [string]$Group, [Parameter(ValueFromPipeline = $true)]$InputObject)
                process { $global:openPathKeepEvents.Add('remove') }
            }
            $script:teardownArgs = @{
                OutboundStatePath = (Join-Path $TestDrive 'missing-outbound.json')
                AuditStatePath    = (Join-Path $TestDrive 'missing-audit.json')
                ManifestPath      = (Join-Path $TestDrive 'missing-manifest.json')
                WhenNoState       = 'OnlyBlocked'
            }
        }

        AfterEach {
            Remove-Variable -Name openPathKeepEvents -Scope Global -ErrorAction SilentlyContinue
        }

        It "Skips rule removal with -KeepRulesWhenOutboundFails when a profile could not be restored" {
            $result = Invoke-OpenPathFirewallTeardown @script:teardownArgs -KeepRulesWhenOutboundFails

            $result.RulesKept | Should -BeTrue
            @($global:openPathKeepEvents | Where-Object { $_ -eq 'remove' }).Count | Should -Be 0
            @($result.Outbound.Errors).Count | Should -Be 1
        }

        It "Still removes the rules without the switch" {
            $result = Invoke-OpenPathFirewallTeardown @script:teardownArgs

            $result.RulesKept | Should -BeFalse
            @($global:openPathKeepEvents | Where-Object { $_ -eq 'remove' }).Count | Should -BeGreaterThan 0
        }
    }

    Context "Teardown order" {
        It "Restores every profile before removing the first rule" {
            $global:openPathTeardownEvents = [System.Collections.Generic.List[string]]::new()
            Mock Get-NetFirewallProfile {
                param($Name, $Profile)
                [PSCustomObject]@{ Name = (Resolve-MockFirewallProfileName -Name $Name -Profile $Profile); DefaultOutboundAction = 'Block' }
            }
            Mock Set-NetFirewallProfile {
                param($Name, $Profile, $DefaultOutboundAction)
                $global:openPathTeardownEvents.Add("set:$(Resolve-MockFirewallProfileName -Name $Name -Profile $Profile)")
            }
            Mock Get-NetFirewallRule { param($DisplayName, $Group) [PSCustomObject]@{ DisplayName = 'rule' } }
            Mock Remove-NetFirewallRule {
                param([string[]]$DisplayName, [string]$Group, [Parameter(ValueFromPipeline = $true)]$InputObject)
                process { $global:openPathTeardownEvents.Add('remove') }
            }

            try {
                $result = Invoke-OpenPathFirewallTeardown `
                    -OutboundStatePath (Join-Path $TestDrive 'missing-outbound.json') `
                    -AuditStatePath (Join-Path $TestDrive 'missing-audit.json') `
                    -ManifestPath (Join-Path $TestDrive 'missing-manifest.json') `
                    -WhenNoState OnlyBlocked

                $events = @($global:openPathTeardownEvents)
                @($events | Where-Object { $_ -like 'set:*' }).Count | Should -Be 3
                $firstRemove = [array]::IndexOf([string[]]$events, 'remove')
                $firstRemove | Should -BeGreaterThan 2
                $result.Outbound | Should -Not -BeNullOrEmpty
                $result.Audit | Should -Not -BeNullOrEmpty
                $result.Rules | Should -Not -BeNullOrEmpty
            }
            finally {
                Remove-Variable -Name openPathTeardownEvents -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }
}
