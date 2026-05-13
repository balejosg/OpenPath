# OpenPath Windows browser Chromium policy tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.psm1" -Force -Global -ErrorAction Stop

Describe "Browser Module - Chromium Policy" {
    BeforeAll {
        $browserModulePath = Join-Path (Join-Path $PSScriptRoot ".." "lib") "Browser.psm1"
        Import-Module $browserModulePath -Force -Global -ErrorAction Stop
    }

    Context "Set-ChromePolicy" {
        It "Does not throw with empty blocked paths" -Skip:((-not $IsWindows) -or -not (Test-IsAdmin)) {
            { Set-ChromePolicy -BlockedPaths @() } | Should -Not -Throw
        }

        It "Reads Chromium defaults from the shared contract fixture" {
            $contract = Get-ContractFixtureJson -FileName 'browser-chromium-policy.json'
            $contract.defaultSearchProviderName | Should -Be 'DuckDuckGo'
            $contract.defaultSearchProviderSearchURL | Should -Be 'https://duckduckgo.com/?q={searchTerms}'
            $contract.dnsOverHttpsMode | Should -Be 'off'
        }

        It "Sets DnsOverHttpsMode to off for managed browsers" -Skip:(-not $IsWindows) {
            $script:capturedRegistryWrites = @()

            Mock Test-Path { $false } -ModuleName Browser
            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-reg-path' } } -ModuleName Browser
            Mock Remove-Item { } -ModuleName Browser
            Mock Set-ItemProperty {
                param([string]$Path, [object]$Name, [object]$Value, [string]$Type)
                $script:capturedRegistryWrites += [PSCustomObject]@{
                    Path = $Path
                    Name = [string]$Name
                    Value = [string]$Value
                    Type = $Type
                }
            } -ModuleName Browser
            Mock Write-OpenPathLog { } -ModuleName Browser

            $result = Set-ChromePolicy -BlockedPaths @()
            $result | Should -BeTrue

            $dohModeWrites = @($script:capturedRegistryWrites | Where-Object {
                    $_.Name -eq 'DnsOverHttpsMode' -and $_.Value -eq 'off'
                })
            $dohModeWrites.Count | Should -BeGreaterThan 0
        }

        It "Writes ExtensionInstallForcelist when managed metadata is available" -Skip:(-not $IsWindows) {
            $script:capturedRegistryWrites = @()

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*chromium-managed\metadata.json') { return $true }
                return $false
            } -ModuleName Browser
            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-reg-path' } } -ModuleName Browser
            Mock Remove-Item { } -ModuleName Browser
            Mock Get-Content {
                param([string]$Path, [switch]$Raw)
                if ($Path -like '*chromium-managed\metadata.json') {
                    return '{"extensionId":"abcdefghijklmnopabcdefghijklmnop","version":"2.0.0"}'
                }

                throw "Unexpected path: $Path"
            } -ModuleName Browser
            Mock Get-OpenPathConfig { [PSCustomObject]@{ apiUrl = 'https://school.example' } } -ModuleName Browser
            Mock Set-ItemProperty {
                param([string]$Path, [object]$Name, [object]$Value, [string]$Type)
                $script:capturedRegistryWrites += [PSCustomObject]@{
                    Path = $Path
                    Name = [string]$Name
                    Value = [string]$Value
                    Type = $Type
                }
            } -ModuleName Browser
            Mock Write-OpenPathLog { } -ModuleName Browser

            $result = Set-ChromePolicy -BlockedPaths @()
            $result | Should -BeTrue

            $forceInstallWrites = @($script:capturedRegistryWrites | Where-Object {
                    $_.Path -like '*ExtensionInstallForcelist' -and
                    $_.Name -eq '1' -and
                    $_.Value -eq 'abcdefghijklmnopabcdefghijklmnop;https://school.example/api/extensions/chromium/updates.xml'
                })
            $forceInstallWrites.Count | Should -BeGreaterThan 0
        }

        It "Writes the Google search URL blocklist entry for managed browsers" {
            $script:capturedRegistryWrites = @()

            Mock Test-Path { $false } -ModuleName Browser
            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-reg-path' } } -ModuleName Browser
            Mock Remove-Item { } -ModuleName Browser
            Mock Set-ItemProperty {
                param([string]$Path, [object]$Name, [object]$Value, [string]$Type)
                $script:capturedRegistryWrites += [PSCustomObject]@{
                    Path = $Path
                    Name = [string]$Name
                    Value = [string]$Value
                    Type = $Type
                }
            } -ModuleName Browser
            Mock Write-OpenPathLog { } -ModuleName Browser

            $result = Set-ChromePolicy -BlockedPaths @()
            $result | Should -BeTrue

            $googleBlockWrites = @($script:capturedRegistryWrites | Where-Object {
                    $_.Path -like '*URLBlocklist' -and
                    $_.Value -eq '*://www.google.*/search*'
                })
            $googleBlockWrites.Count | Should -Be 2
        }
    }

    Context "Remove-BrowserPolicy" {
        It "Can remove enforcement policies while preserving the Firefox managed extension policy" {
            $script:removedBrowserPolicyPaths = @()
            Mock Test-Path {
                param([string]$Path)
                return ($Path -like '*Mozilla Firefox*distribution*policies.json')
            } -ModuleName Browser
            Mock Remove-Item {
                param([string]$Path)
                $script:removedBrowserPolicyPaths += $Path
            } -ModuleName Browser
            Mock Write-OpenPathLog { } -ModuleName Browser
            Mock Sync-OpenPathFirefoxManagedExtensionPolicy { return $true } -ModuleName Browser
            Mock Remove-OpenPathFirefoxMachineExtensionPolicy { throw 'Firefox managed extension policy should be preserved' } -ModuleName Browser.FirefoxPolicy
            Mock Remove-OpenPathFirefoxNetworkAutoconfig { } -ModuleName Browser.FirefoxConfig

            { Remove-BrowserPolicy -PreserveFirefoxManagedExtension } | Should -Not -Throw

            Should -Invoke Remove-OpenPathFirefoxMachineExtensionPolicy -ModuleName Browser.FirefoxPolicy -Times 0 -Exactly
            Should -Invoke Sync-OpenPathFirefoxManagedExtensionPolicy -ModuleName Browser -Times 1 -Exactly
            @($script:removedBrowserPolicyPaths | Where-Object { $_ -like '*Mozilla Firefox*distribution*policies.json' }).Count | Should -Be 0
        }
    }
}
