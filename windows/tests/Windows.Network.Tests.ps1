Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Network bridge-filter neutralization" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\Network.psm1" -Force -Global -ErrorAction SilentlyContinue

        # The NetAdapter cmdlets only exist on Windows; stub them so the module's
        # Get-Command guards pass and Pester can intercept them with mocks.
        $script:createdCmdStubs = @()
        foreach ($cmd in @('Get-NetAdapter', 'Get-NetAdapterBinding', 'Disable-NetAdapterBinding', 'Enable-NetAdapterBinding')) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Function:\global:$cmd" -Value { } | Out-Null
                $script:createdCmdStubs += $cmd
            }
        }
    }

    AfterAll {
        foreach ($cmd in @($script:createdCmdStubs)) {
            Remove-Item -Path "Function:\global:$cmd" -ErrorAction SilentlyContinue
        }
    }

    Context "Get-OpenPathBridgeFilterCatalog" {
        It "Includes the known VirtualBox and VMware bridge component ids" {
            $catalog = @(Get-OpenPathBridgeFilterCatalog)
            $catalog | Should -Contain 'VBoxNetLwf'
            $catalog | Should -Contain 'VMnetBridge'
        }
    }

    Context "Get-OpenPathAdaptersWithBridgeFilters" {
        BeforeEach {
            Mock Write-OpenPathLog { } -ModuleName Network
            Mock Get-NetAdapter {
                @([PSCustomObject]@{ Name = 'Ethernet'; Status = 'Up' })
            } -ModuleName Network
        }

        It "Detects an enabled bridge filter on a physical adapter and ignores ordinary bindings" {
            Mock Get-NetAdapterBinding {
                @(
                    [PSCustomObject]@{ ComponentID = 'VBoxNetLwf'; Enabled = $true },
                    [PSCustomObject]@{ ComponentID = 'ms_tcpip'; Enabled = $true }
                )
            } -ModuleName Network

            $result = @(Get-OpenPathAdaptersWithBridgeFilters)
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'Ethernet'
            $result[0].ComponentIds | Should -Contain 'VBoxNetLwf'
            $result[0].ComponentIds | Should -Not -Contain 'ms_tcpip'
        }

        It "Ignores a bridge filter that is already disabled" {
            Mock Get-NetAdapterBinding {
                @([PSCustomObject]@{ ComponentID = 'VBoxNetLwf'; Enabled = $false })
            } -ModuleName Network

            @(Get-OpenPathAdaptersWithBridgeFilters).Count | Should -Be 0
        }

        It "Respects the adapter-name allowlist" {
            Mock Get-NetAdapterBinding {
                @([PSCustomObject]@{ ComponentID = 'VBoxNetLwf'; Enabled = $true })
            } -ModuleName Network

            @(Get-OpenPathAdaptersWithBridgeFilters -Allowlist @('Ethernet')).Count | Should -Be 0
        }

        It "Respects the component-id allowlist" {
            Mock Get-NetAdapterBinding {
                @([PSCustomObject]@{ ComponentID = 'VBoxNetLwf'; Enabled = $true })
            } -ModuleName Network

            @(Get-OpenPathAdaptersWithBridgeFilters -Allowlist @('VBoxNetLwf')).Count | Should -Be 0
        }

        It "Detects extra component ids supplied via configuration" {
            Mock Get-NetAdapterBinding {
                @([PSCustomObject]@{ ComponentID = 'custom_bridge'; Enabled = $true })
            } -ModuleName Network

            $result = @(Get-OpenPathAdaptersWithBridgeFilters -ExtraComponentIds @('custom_bridge'))
            $result.Count | Should -Be 1
            $result[0].ComponentIds | Should -Contain 'custom_bridge'
        }
    }

    Context "Disable-OpenPathBridgeFilters" {
        BeforeEach {
            Mock Write-OpenPathLog { } -ModuleName Network
            Mock Save-OpenPathOriginalBridgeFilterSnapshot { $true } -ModuleName Network
            Mock Get-NetAdapter { @([PSCustomObject]@{ Name = 'Ethernet'; Status = 'Up' }) } -ModuleName Network
            Mock Get-NetAdapterBinding { @([PSCustomObject]@{ ComponentID = 'VBoxNetLwf'; Enabled = $true }) } -ModuleName Network
            Mock Disable-NetAdapterBinding { } -ModuleName Network
        }

        It "Saves a snapshot and unbinds the detected bridge filter" {
            Disable-OpenPathBridgeFilters -Confirm:$false

            Should -Invoke -CommandName Save-OpenPathOriginalBridgeFilterSnapshot -ModuleName Network -Times 1
            Should -Invoke -CommandName Disable-NetAdapterBinding -ModuleName Network -Times 1 -Exactly
        }

        It "Does not unbind an allowlisted adapter" {
            Disable-OpenPathBridgeFilters -Allowlist @('Ethernet') -Confirm:$false

            Should -Invoke -CommandName Disable-NetAdapterBinding -ModuleName Network -Times 0 -Exactly
        }
    }

    Context "Snapshot save and restore round-trip" {
        It "Persists the original enabled state and restores only the filters that were enabled" {
            $snapshotPath = Join-Path $TestDrive 'original-bridge-filters.json'
            Mock Write-OpenPathLog { } -ModuleName Network
            Mock Get-NetAdapter { @([PSCustomObject]@{ Name = 'Ethernet' }) } -ModuleName Network
            Mock Get-NetAdapterBinding {
                @(
                    [PSCustomObject]@{ ComponentID = 'VBoxNetLwf'; Enabled = $true },
                    [PSCustomObject]@{ ComponentID = 'VMnetBridge'; Enabled = $false }
                )
            } -ModuleName Network

            Save-OpenPathOriginalBridgeFilterSnapshot -Path $snapshotPath | Should -BeTrue
            Test-Path $snapshotPath | Should -BeTrue
            @((Get-Content $snapshotPath -Raw | ConvertFrom-Json).bindings).Count | Should -Be 2

            Mock Enable-NetAdapterBinding { } -ModuleName Network
            Restore-OpenPathOriginalBridgeFilters -Path $snapshotPath -Confirm:$false

            # Only the one filter that was enabled before OpenPath touched it is re-enabled.
            Should -Invoke -CommandName Enable-NetAdapterBinding -ModuleName Network -Times 1 -Exactly
        }
    }
}
