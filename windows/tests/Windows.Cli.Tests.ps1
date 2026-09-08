Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Operational Command Script" {
    Context "Script existence" {
        It "OpenPath.ps1 exists" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            Test-Path $scriptPath | Should -BeTrue
        }
    }

    Context "Command routing" {
        It "Routes key commands through a unified dispatcher" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.Contains('switch ($commandName)') | Should -BeTrue
            $content.Contains("'status'") | Should -BeTrue
            $content.Contains("'update'") | Should -BeTrue
            $content.Contains("'health'") | Should -BeTrue
            $content.Contains("'self-update'") | Should -BeTrue
            $content.Contains("'enroll'") | Should -BeTrue
            $content.Contains("'rotate-token'") | Should -BeTrue
            $content.Contains("'restart'") | Should -BeTrue
            $content.Contains('Show-OpenPathStatus') | Should -BeTrue
            $content.Contains('Invoke-OpenPathAgentSelfUpdate') | Should -BeTrue
            $content.Contains('Enroll-Machine.ps1') | Should -BeTrue
        }
    }

    Context "Argument forwarding" {
        It "Normalizes named arguments before invoking child scripts" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function ConvertTo-OpenPathInvocationSplat',
                '$namedArguments = @{}',
                '& $ScriptPath @namedArguments @positionalArguments'
            )
            $content.Contains('& $ScriptPath @ScriptArguments') | Should -BeFalse
        }
    }

    Context "DNS probe selection" {
        It "Uses the shared probe selection instead of hard-coding google.com" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.Contains("Test-DNSResolution -Domain 'google.com'") | Should -BeFalse
            $content.Contains('Test-DNSResolution)') | Should -BeTrue
        }
    }

    Context "Status redaction" {
        It "Redacts tokenized whitelist URLs in status output" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Common.Redaction.ps1',
                'ConvertTo-OpenPathRedactedValue -Value $config.whitelistUrl'
            )
            $content | Should -Not -Match 'Write-Host "Whitelist URL: \$\(\$config\.whitelistUrl\)"'
        }
    }

    Context "Required boundary health" {
        It "does not allow HEALTHY status when AppControl or watchdog readiness is unhealthy" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathWatchdogTaskHealth',
                'Get-OpenPathNonAdminAppControlHealth',
                'requiredBoundaryHealthy',
                '-not $requiredBoundaryHealthy'
            )
        }

        It "observes required boundary health without mutating scheduled tasks" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
            $functionAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-OpenPathStatus'
                }, $true)
            $functionAst | Should -Not -BeNullOrEmpty
            $functionAst.Body.GetType().Name | Should -Be 'ScriptBlockAst'
            . ([scriptblock]::Create($functionAst.Extent.Text))

            $testRoot = Join-Path $TestDrive 'cli-health'
            New-Item -ItemType Directory -Path (Join-Path $testRoot 'data') -Force | Out-Null
            '{}' | Set-Content -LiteralPath (Join-Path $testRoot 'data\config.json')
            function global:Get-OpenPathConfig { [pscustomobject]@{ enableNonAdminAppControl = $true } }
            function global:Get-Service { param($DisplayName) [pscustomobject]@{ Status = 'Running' } }
            function global:Test-DNSResolution { return $true }
            function global:Test-DNSSinkhole { param($Domain) return $true }
            function global:Test-FirewallActive { return $true }
            function global:Get-OpenPathTaskStatus { return @() }
            function global:Get-OpenPathWatchdogTaskHealth {
                param([string]$OpenPathRoot)
                [pscustomobject]@{ Healthy = $false; ReasonCodes = @('watchdog_task_missing') }
            }
            function global:Get-OpenPathNonAdminAppControlHealth {
                param($Mode, $ApprovedBrowsers)
                [pscustomobject]@{ Healthy = $false; ReasonCodes = @('appcontrol_effective_policy_absent') }
            }
            function global:ConvertTo-OpenPathRedactedValue { param([string]$Value) return '<redacted>' }
            function global:Write-OpenPathLog {}
            function global:Register-ScheduledTask { throw 'status must not register tasks' }
            function global:Start-ScheduledTask { throw 'status must not start tasks' }
            function global:Enable-ScheduledTask { throw 'status must not enable tasks' }
            function global:Disable-ScheduledTask { throw 'status must not disable tasks' }
            function global:Unregister-ScheduledTask { throw 'status must not unregister tasks' }

            try {
                $output = (& { Show-OpenPathStatus -OpenPathRoot $testRoot } 6>&1 | Out-String)
                $output | Should -Match 'Overall: DEGRADED'
            }
            finally {
                Remove-Item Function:\Get-OpenPathConfig, Function:\Get-Service, Function:\Test-DNSResolution, Function:\Test-DNSSinkhole, Function:\Test-FirewallActive -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-OpenPathTaskStatus, Function:\Get-OpenPathWatchdogTaskHealth, Function:\Get-OpenPathNonAdminAppControlHealth -ErrorAction SilentlyContinue
                Remove-Item Function:\ConvertTo-OpenPathRedactedValue, Function:\Write-OpenPathLog -ErrorAction SilentlyContinue
                Remove-Item Function:\Register-ScheduledTask, Function:\Start-ScheduledTask, Function:\Enable-ScheduledTask, Function:\Disable-ScheduledTask, Function:\Unregister-ScheduledTask -ErrorAction SilentlyContinue
            }
        }

        It "requires durable configuration as well as healthy runtime observations" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
            $functionAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-OpenPathStatus'
                }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))

            $testRoot = Join-Path $TestDrive 'cli-health-healthy'
            New-Item -ItemType Directory -Path (Join-Path $testRoot 'data') -Force | Out-Null
            '{}' | Set-Content -LiteralPath (Join-Path $testRoot 'data\config.json')
            $global:opCliHealthConfig = [pscustomobject]@{ enableNonAdminAppControl = $true; appControlCommitState = 'committed'; installState = 'complete' }
            function global:Get-OpenPathConfig { $global:opCliHealthConfig }
            function global:Get-Service { param($DisplayName) [pscustomobject]@{ Status = 'Running' } }
            function global:Test-DNSResolution { return $true }
            function global:Test-DNSSinkhole { param($Domain) return $true }
            function global:Test-FirewallActive { return $true }
            function global:Get-OpenPathTaskStatus { return @() }
            function global:Get-OpenPathWatchdogTaskHealth { [pscustomobject]@{ Healthy = $true; ReasonCodes = @() } }
            function global:Get-OpenPathNonAdminAppControlHealth { [pscustomobject]@{ Healthy = $true; ReasonCodes = @() } }
            function global:ConvertTo-OpenPathRedactedValue { param([string]$Value) return '<redacted>' }
            function global:Write-OpenPathLog {}

            try {
                $output = (& { Show-OpenPathStatus -OpenPathRoot $testRoot } 6>&1 | Out-String)
                $output | Should -Match 'Overall: HEALTHY'
                foreach ($state in @($null, '', 'pending', 'failed')) {
                    $global:opCliHealthConfig.appControlCommitState = $state
                    $output = (& { Show-OpenPathStatus -OpenPathRoot $testRoot } 6>&1 | Out-String)
                    $output | Should -Match 'Overall: DEGRADED'
                    $output | Should -Match 'appcontrol_uncommitted'
                }
                $global:opCliHealthConfig = [pscustomobject]@{ enableNonAdminAppControl = $true }
                $output = (& { Show-OpenPathStatus -OpenPathRoot $testRoot } 6>&1 | Out-String)
                $output | Should -Match 'Overall: DEGRADED'
                foreach ($state in @('installing', 'failed')) {
                    $global:opCliHealthConfig = [pscustomobject]@{ enableNonAdminAppControl = $true; appControlCommitState = 'committed'; installState = $state }
                    $output = (& { Show-OpenPathStatus -OpenPathRoot $testRoot } 6>&1 | Out-String)
                    $output | Should -Match 'Overall: DEGRADED'
                }
                $global:opCliHealthConfig = $null
                $output = (& { Show-OpenPathStatus -OpenPathRoot $testRoot } 6>&1 | Out-String)
                $output | Should -Match 'Overall: DEGRADED'
                $output | Should -Match 'configuration_unavailable'
                $global:opCliHealthConfig = [pscustomobject]@{ enableNonAdminAppControl = $false }
                $output = (& { Show-OpenPathStatus -OpenPathRoot $testRoot } 6>&1 | Out-String)
                $output | Should -Match 'Overall: HEALTHY'
            }
            finally {
                Remove-Item Function:\Get-OpenPathConfig, Function:\Get-Service, Function:\Test-DNSResolution, Function:\Test-DNSSinkhole, Function:\Test-FirewallActive -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-OpenPathTaskStatus, Function:\Get-OpenPathWatchdogTaskHealth, Function:\Get-OpenPathNonAdminAppControlHealth -ErrorAction SilentlyContinue
                Remove-Item Function:\ConvertTo-OpenPathRedactedValue, Function:\Write-OpenPathLog -ErrorAction SilentlyContinue
                Remove-Variable -Name opCliHealthConfig -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Rotate token sync" {
        It "Syncs the Firefox native host state after saving a rotated whitelist URL" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Rotate-Token.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$BrowserModulePath = "$OpenPathRoot\lib\Browser.psm1"',
                'Import-Module $BrowserModulePath -Force',
                'Sync-OpenPathFirefoxNativeHostState -Config $config -ClearWhitelist | Out-Null',
                'Failed to sync Firefox native host state after token rotation'
            )
        }
    }

    Context "New verb: domains" {
        It "OpenPath.ps1 handles the 'domains' command using Get-OpenPathWhitelistSectionsFromFile" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                "'domains'",
                'Get-OpenPathWhitelistSectionsFromFile',
                'whitelist.txt'
            )
        }
    }

    Context "New verb: check" {
        It "OpenPath.ps1 handles the 'check' command using Test-DNSSinkhole and Test-DNSResolution" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                "'check'",
                'Test-DNSSinkhole',
                'Test-DNSResolution'
            )
        }
    }

    Context "New verb: enable" {
        It "OpenPath.ps1 handles 'enable' by re-enabling the firewall and Acrylic service" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                "'enable'",
                'Enable-OpenPathFirewall',
                'Start-AcrylicService'
            )
        }
    }

    Context "New verb: disable" {
        It "OpenPath.ps1 handles 'disable' by suspending the firewall and stopping Acrylic" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                "'disable'",
                'Disable-OpenPathFirewall',
                'Stop-AcrylicService',
                'Restore-OriginalDNS'
            )
        }
    }

    Context "Help text completeness" {
        It "Show-OpenPathHelp documents all canonical verbs including the new parity additions" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            foreach ($verb in @('domains', 'check', 'enable', 'disable')) {
                $content.Contains("'  $verb") | Should -BeTrue -Because "Show-OpenPathHelp must document '$verb'"
            }
        }
    }
}
