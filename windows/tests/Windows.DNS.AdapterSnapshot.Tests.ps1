Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "DNS adapter snapshot leaf" {
    BeforeAll {
        $script:LeafPath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.AdapterSnapshot.ps1"

        $script:CreatedStubs = @()
        $stubs = @{
            'Get-NetAdapter'             = { param() }
            'Get-DnsClientServerAddress' = { param($InterfaceIndex, $AddressFamily) }
            'Set-DnsClientServerAddress' = { param($InterfaceIndex, $ServerAddresses, [switch]$ResetServerAddresses) }
            'Clear-DnsClientCache'       = { param() }
            'Get-NetRoute'               = { param($DestinationPrefix, $InterfaceIndex) }
        }
        foreach ($commandName in @($stubs.Keys)) {
            if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                New-Item -Path "Function:\global:$commandName" -Value $stubs[$commandName] -Force | Out-Null
                $script:CreatedStubs += @($commandName)
            }
        }

        . $script:LeafPath

        function New-TestAdapter {
            param([string]$Guid, [string]$Name, [int]$Index, [string]$Status = 'Up')
            [PSCustomObject]@{ InterfaceGuid = $Guid; Name = $Name; ifIndex = $Index; Status = $Status }
        }

        function Get-MockDnsInterfaceIndex {
            # Set-DnsClientServerAddress/Get-NetRoute take UInt32[] on Windows; Pester injects
            # the real parameter type, so the mock sees a one-element array, not an int.
            param($InterfaceIndex)
            $values = @($InterfaceIndex | Where-Object { $null -ne $_ })
            if ($values.Count -eq 0) { return 0 }
            return [int]$values[0]
        }

        function Write-TestSnapshot {
            param([string]$Path, [object[]]$Entries)
            [PSCustomObject]@{ version = 3; adapters = @($Entries) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
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

    Context "Restore plan" {
        BeforeEach {
            $global:openPathRegistryState = $null
            Mock Get-ItemProperty {
                if ($null -eq $global:openPathRegistryState) { throw 'registry key unavailable' }
                return $global:openPathRegistryState
            }
        }

        AfterEach {
            Remove-Variable -Name openPathRegistryState -Scope Global -ErrorAction SilentlyContinue
        }

        It "<Name>" -ForEach @(
            @{
                Name = 'Sets a static entry by GUID'
                Entry = @{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
                Registry = $null
                Action = 'set'; Servers = '192.0.2.53'; Reason = 'static'
            }
            @{
                Name = 'Resets a static entry that only holds loopback'
                Entry = @{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; Origin = 'static'; ServerAddresses = @('127.0.0.1') }
                Registry = $null
                Action = 'reset'; Servers = ''; Reason = 'no-servers'
            }
            @{
                Name = 'Resets a DHCP-origin entry'
                Entry = @{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; Origin = 'dhcp'; ServerAddresses = @('198.51.100.1') }
                Registry = $null
                Action = 'reset'; Servers = ''; Reason = 'dhcp-origin'
            }
            @{
                Name = 'Resets a legacy entry on a DHCP-backed adapter'
                Entry = @{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; ServerAddresses = @('192.0.2.53') }
                Registry = @{ NameServer = ''; DhcpNameServer = '198.51.100.1'; EnableDHCP = 1 }
                Action = 'reset'; Servers = ''; Reason = 'legacy-dhcp'
            }
            @{
                Name = 'Sets a legacy entry on an adapter without DHCP'
                Entry = @{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; ServerAddresses = @('192.0.2.53') }
                Registry = @{ NameServer = '192.0.2.53'; DhcpNameServer = ''; EnableDHCP = 0 }
                Action = 'set'; Servers = '192.0.2.53'; Reason = 'static'
            }
            @{
                Name = 'Resets a legacy entry without servers'
                Entry = @{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; ServerAddresses = @() }
                Registry = $null
                Action = 'reset'; Servers = ''; Reason = 'no-servers'
            }
        ) {
            if ($Registry) { $global:openPathRegistryState = [PSCustomObject]$Registry }
            $adapters = @(New-TestAdapter -Guid 'g1' -Name 'Ethernet' -Index 7)

            $plan = @(Get-OpenPathOriginalDnsRestorePlan -SnapshotEntries @([PSCustomObject]$Entry) -Adapters $adapters)

            $plan.Count | Should -Be 1
            $plan[0].InterfaceIndex | Should -Be 7
            $plan[0].AdapterName | Should -Be 'Ethernet'
            $plan[0].Action | Should -Be $Action
            (@($plan[0].ServerAddresses) -join ',') | Should -Be $Servers
            $plan[0].Reason | Should -Be $Reason
        }

        It "Matches by index when the GUID is unknown and the index is wrapped in an array" {
            $entry = [PSCustomObject]@{ InterfaceGuid = 'gone'; InterfaceAlias = 'Old'; InterfaceIndex = @(7); Origin = 'static'; ServerAddresses = @('192.0.2.53') }
            $adapters = @(
                New-TestAdapter -Guid 'other' -Name 'Wi-Fi' -Index 3
                New-TestAdapter -Guid 'g7' -Name 'Ethernet 2' -Index 7
            )

            $plan = @(Get-OpenPathOriginalDnsRestorePlan -SnapshotEntries @($entry) -Adapters $adapters)

            $plan.Count | Should -Be 1
            $plan[0].InterfaceIndex | Should -Be 7
            $plan[0].AdapterName | Should -Be 'Ethernet 2'
        }

        It "Matches by alias when the GUID and the index are unknown" {
            $entry = [PSCustomObject]@{ InterfaceGuid = 'gone'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 99; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
            $adapters = @(New-TestAdapter -Guid 'g4' -Name 'Ethernet' -Index 4)

            $plan = @(Get-OpenPathOriginalDnsRestorePlan -SnapshotEntries @($entry) -Adapters $adapters)

            $plan.Count | Should -Be 1
            $plan[0].InterfaceIndex | Should -Be 4
        }

        It "Plans nothing when no adapter matches" {
            $entry = [PSCustomObject]@{ InterfaceGuid = 'gone'; InterfaceAlias = 'Old'; InterfaceIndex = 99; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
            $adapters = @(New-TestAdapter -Guid 'g4' -Name 'Ethernet' -Index 4)

            @(Get-OpenPathOriginalDnsRestorePlan -SnapshotEntries @($entry) -Adapters $adapters).Count | Should -Be 0
        }
    }

    Context "Restore executor" {
        BeforeEach {
            $script:snapshotPath = Join-Path $TestDrive "original-dns-$([guid]::NewGuid().ToString('N')).json"
            $global:openPathDnsCalls = [System.Collections.Generic.List[object]]::new()
            $global:openPathFailingIndexes = @()
            $global:openPathLoopbackEntries = @()

            Mock Get-NetAdapter {
                @(
                    [PSCustomObject]@{ InterfaceGuid = 'g1'; Name = 'Ethernet'; ifIndex = 1; Status = 'Up' }
                    [PSCustomObject]@{ InterfaceGuid = 'g2'; Name = 'Wi-Fi'; ifIndex = 2; Status = 'Up' }
                    [PSCustomObject]@{ InterfaceGuid = 'g3'; Name = 'Spare'; ifIndex = 3; Status = 'Disconnected' }
                )
            }
            Mock Set-DnsClientServerAddress {
                param($InterfaceIndex, $ServerAddresses, [switch]$ResetServerAddresses)
                $adapterIndex = Get-MockDnsInterfaceIndex -InterfaceIndex $InterfaceIndex
                $global:openPathDnsCalls.Add([PSCustomObject]@{
                        InterfaceIndex = $adapterIndex
                        ServerAddresses = @($ServerAddresses)
                        Reset = [bool]$ResetServerAddresses
                    })
                if ($adapterIndex -in $global:openPathFailingIndexes) {
                    throw "adapter $adapterIndex refused"
                }
            }
            Mock Get-DnsClientServerAddress { @($global:openPathLoopbackEntries) }
            Mock Clear-DnsClientCache { }
            Mock Get-ItemProperty { throw 'registry key unavailable' }
        }

        AfterEach {
            Remove-Variable -Name openPathDnsCalls, openPathFailingIndexes, openPathLoopbackEntries -Scope Global -ErrorAction SilentlyContinue
        }

        It "Resets every Up adapter when there is no snapshot" {
            $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Stop

            $result.UsedSnapshot | Should -BeFalse
            @($global:openPathDnsCalls | ForEach-Object { $_.InterfaceIndex }) | Should -Be @(1, 2)
            @($global:openPathDnsCalls | Where-Object { -not $_.Reset }).Count | Should -Be 0
            Should -Invoke Clear-DnsClientCache -Times 1 -Exactly
        }

        It "Stops at the first failing adapter with one error" {
            Write-TestSnapshot -Path $script:snapshotPath -Entries @(
                [PSCustomObject]@{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 1; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
                [PSCustomObject]@{ InterfaceGuid = 'g2'; InterfaceAlias = 'Wi-Fi'; InterfaceIndex = 2; Origin = 'static'; ServerAddresses = @('192.0.2.54') }
            )
            $global:openPathFailingIndexes = @(1)

            $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Stop

            $result.UsedSnapshot | Should -BeTrue
            @($result.Errors).Count | Should -Be 1
            @($result.Errors)[0] | Should -Match 'adapter 1 refused'
            @($result.Applied).Count | Should -Be 0
            @($global:openPathDnsCalls | ForEach-Object { $_.InterfaceIndex }) | Should -Be @(1)
            $result.FallbackUsed | Should -BeFalse
        }

        It "Continues past failing adapters and reports every error" {
            Write-TestSnapshot -Path $script:snapshotPath -Entries @(
                [PSCustomObject]@{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 1; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
                [PSCustomObject]@{ InterfaceGuid = 'g2'; InterfaceAlias = 'Wi-Fi'; InterfaceIndex = 2; Origin = 'dhcp'; ServerAddresses = @() }
                [PSCustomObject]@{ InterfaceGuid = 'g3'; InterfaceAlias = 'Spare'; InterfaceIndex = 3; Origin = 'static'; ServerAddresses = @('192.0.2.55') }
            )
            $global:openPathFailingIndexes = @(1, 3)

            $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Continue

            @($result.Errors).Count | Should -Be 2
            @($result.Applied).Count | Should -Be 1
            @($result.Applied)[0].InterfaceIndex | Should -Be 2
            @($global:openPathDnsCalls | ForEach-Object { $_.InterfaceIndex }) | Should -Be @(1, 2, 3)
        }

        It "Resets every Up adapter after a failure when the fallback is requested" {
            Write-TestSnapshot -Path $script:snapshotPath -Entries @(
                [PSCustomObject]@{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 1; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
            )
            $global:openPathFailingIndexes = @(1)

            $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Stop -FallbackResetAllOnFailure

            $result.FallbackUsed | Should -BeTrue
            @($result.Errors).Count | Should -Be 1
            $fallbackCalls = @($global:openPathDnsCalls | Select-Object -Skip 1)
            @($fallbackCalls | ForEach-Object { $_.InterfaceIndex }) | Should -Be @(1, 2)
            @($fallbackCalls | Where-Object { -not $_.Reset }).Count | Should -Be 0
        }

        It "Treats an unreadable snapshot as a failed snapshot phase" {
            Set-Content -LiteralPath $script:snapshotPath -Value '{ "adapters": [' -Encoding ASCII

            $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Stop -FallbackResetAllOnFailure

            $result.UsedSnapshot | Should -BeTrue
            @($result.Errors).Count | Should -Be 1
            $result.FallbackUsed | Should -BeTrue
            @($global:openPathDnsCalls | ForEach-Object { $_.InterfaceIndex }) | Should -Be @(1, 2)
        }

        It "Restores a legacy bare-array snapshot" {
            Set-Content -LiteralPath $script:snapshotPath -Encoding UTF8 -Value @'
[
  { "InterfaceGuid": "g1", "InterfaceAlias": "Ethernet", "InterfaceIndex": [1], "ServerAddresses": ["192.0.2.53"] }
]
'@

            $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Stop

            @($result.Errors).Count | Should -Be 0
            @($result.Applied).Count | Should -Be 1
            $global:openPathDnsCalls[0].InterfaceIndex | Should -Be 1
            (@($global:openPathDnsCalls[0].ServerAddresses) -join ',') | Should -Be '192.0.2.53'
        }

        It "Runs the loopback sweep last in every case and returns its indexes" -ForEach @(
            @{ Case = 'no snapshot'; WriteSnapshot = $false; Failing = @() }
            @{ Case = 'snapshot applied'; WriteSnapshot = $true; Failing = @() }
            @{ Case = 'snapshot failed'; WriteSnapshot = $true; Failing = @(1) }
        ) {
            if ($WriteSnapshot) {
                Write-TestSnapshot -Path $script:snapshotPath -Entries @(
                    [PSCustomObject]@{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 1; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
                )
            }
            $global:openPathFailingIndexes = @($Failing)
            $global:openPathLoopbackEntries = @(
                [PSCustomObject]@{ InterfaceIndex = 9; ServerAddresses = @('127.0.0.1') }
                [PSCustomObject]@{ InterfaceIndex = 2; ServerAddresses = @('192.0.2.1') }
            )

            $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Continue

            @($result.LoopbackResets) | Should -Be @(9)
            $last = $global:openPathDnsCalls[$global:openPathDnsCalls.Count - 1]
            $last.InterfaceIndex | Should -Be 9
            $last.Reset | Should -BeTrue
        }

        It "Returns an empty result and calls nothing when a required cmdlet is missing" -ForEach @(
            @{ Missing = 'Get-NetAdapter' }
            @{ Missing = 'Set-DnsClientServerAddress' }
        ) {
            $global:openPathMissingCommand = $Missing
            Mock Get-Command { $null } -ParameterFilter { $Name -eq $global:openPathMissingCommand }
            Write-TestSnapshot -Path $script:snapshotPath -Entries @(
                [PSCustomObject]@{ InterfaceGuid = 'g1'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 1; Origin = 'static'; ServerAddresses = @('192.0.2.53') }
            )

            try {
                $result = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $script:snapshotPath -OnAdapterError Stop -FallbackResetAllOnFailure

                $result.UsedSnapshot | Should -BeFalse
                @($result.Applied).Count | Should -Be 0
                @($result.LoopbackResets).Count | Should -Be 0
                @($result.Errors).Count | Should -Be 0
                Should -Invoke Set-DnsClientServerAddress -Times 0 -Exactly
                Should -Invoke Get-NetAdapter -Times 0 -Exactly
                Should -Invoke Clear-DnsClientCache -Times 0 -Exactly
            }
            finally {
                Remove-Variable -Name openPathMissingCommand -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Snapshot payload" {
        It "Writes version 3 with a fingerprint of its adapters and a Gateway per entry" {
            Mock Get-NetAdapter {
                @(
                    [PSCustomObject]@{ InterfaceGuid = 'g1'; Name = 'Ethernet'; ifIndex = 1; Status = 'Up' }
                    [PSCustomObject]@{ InterfaceGuid = 'g2'; Name = 'Wi-Fi'; ifIndex = 2; Status = 'Up' }
                )
            }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @('192.0.2.53') } }
            Mock Get-NetRoute {
                if ((Get-MockDnsInterfaceIndex -InterfaceIndex $InterfaceIndex) -eq 1) {
                    [PSCustomObject]@{ NextHop = '192.0.2.1' }
                }
            }
            Mock Get-ItemProperty { [PSCustomObject]@{ NameServer = ''; DhcpNameServer = '192.0.2.53'; EnableDHCP = 1 } }

            $payload = New-OpenPathOriginalDnsSnapshot

            $payload.version | Should -Be 3
            @($payload.adapters).Count | Should -Be 2
            foreach ($entry in @($payload.adapters)) {
                $entry.PSObject.Properties['Gateway'] | Should -Not -BeNullOrEmpty
            }
            (@($payload.adapters) | Where-Object { $_.InterfaceIndex -eq 1 }).Gateway | Should -Be '192.0.2.1'
            $payload.networkFingerprint | Should -Be (Get-OpenPathDnsNetworkFingerprint -Entries @($payload.adapters))
            $payload.networkFingerprint | Should -Match '192\.0\.2\.1'
        }

        It "Returns null when the adapter cmdlets are unavailable" {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-DnsClientServerAddress' }

            New-OpenPathOriginalDnsSnapshot | Should -BeNullOrEmpty
        }
    }
}
