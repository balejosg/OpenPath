# OpenPath Windows browser Firefox policy tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.Common.psm1" -Force -Global -ErrorAction Stop
Import-Module "$modulePath\Browser.FirefoxPolicy.psm1" -Force -Global -ErrorAction Stop

Describe "Browser Module - Firefox Policy" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module (Join-Path $modulePath "Browser.Common.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Browser.FirefoxPolicy.psm1") -Force -Global -ErrorAction Stop
    }

    Context "Sync-OpenPathFirefoxManagedExtensionPolicy" {
        It "Returns a boolean value" {
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy
            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeOfType [bool]
        }

        It "Skips Firefox extension force-install when only the unsigned staged bundle is available" {
            $script:capturedFirefoxPolicyJson = $null

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*firefox.exe') { return $true }
                if ($Path -like '*browser-extension\firefox\manifest.json') { return $true }
                return $false
            } -ModuleName Browser.FirefoxPolicy

            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig { [PSCustomObject]@{} } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeFalse
            $script:capturedFirefoxPolicyJson | Should -BeNullOrEmpty
        }

        It "Uses explicit signed Firefox extension config when available" {
            $script:capturedFirefoxPolicyJson = $null
            $script:capturedMachinePolicyPath = $null
            $script:capturedMachinePolicyValue = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*firefox.exe') { return $true }
                return $false
            } -ModuleName Browser.FirefoxPolicy

            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    firefoxExtensionId = $contract.extensionId
                    firefoxExtensionInstallUrl = $contract.configuredInstallUrl
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock New-ItemProperty {
                param([string]$Path, [string]$Name, [object]$Value, [object]$PropertyType)
                if ($Name -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyPath = $Path
                    $script:capturedMachinePolicyValue = @($Value)
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.PSObject.Properties.Name | Should -Be @('ExtensionSettings')
            $policy.policies.ExtensionSettings.($contract.extensionId).installation_mode | Should -Be 'force_installed'
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.configuredInstallUrl

            $script:capturedMachinePolicyPath | Should -Be 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
            $script:capturedMachinePolicyValue.Count | Should -Be 1
            $machinePolicy = $script:capturedMachinePolicyValue[0] | ConvertFrom-Json
            $machinePolicy.($contract.extensionId).installation_mode | Should -Be 'force_installed'
            $machinePolicy.($contract.extensionId).install_url | Should -Be $contract.configuredInstallUrl
        }

        It "Uses caller-provided config without re-reading config.json" {
            $script:capturedFirefoxPolicyJson = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'
            $config = [PSCustomObject]@{
                firefoxExtensionId = $contract.extensionId
                firefoxExtensionInstallUrl = $contract.configuredInstallUrl
            }

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*firefox.exe') { return $true }
                return $false
            } -ModuleName Browser.FirefoxPolicy
            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                throw 'config.json should not be read when Config is supplied'
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock New-ItemProperty { } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy -Config $config
            $result | Should -BeTrue

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.configuredInstallUrl
        }

        It "Writes machine Firefox policy even when firefox.exe is not installed" {
            $script:capturedFirefoxPolicyJson = $null
            $script:capturedMachinePolicyValue = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path { return $false } -ModuleName Browser.FirefoxPolicy
            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    firefoxExtensionId = $contract.extensionId
                    firefoxExtensionInstallUrl = $contract.configuredInstallUrl
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock New-ItemProperty {
                param([string]$Path, [string]$Name, [object]$Value, [object]$PropertyType)
                if ($Name -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyValue = @($Value)
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue
            $script:capturedFirefoxPolicyJson | Should -BeNullOrEmpty

            $machinePolicy = $script:capturedMachinePolicyValue[0] | ConvertFrom-Json
            $machinePolicy.($contract.extensionId).installation_mode | Should -Be 'force_installed'
            $machinePolicy.($contract.extensionId).install_url | Should -Be $contract.configuredInstallUrl
        }

        It "Preserves existing machine Firefox ExtensionSettings entries" {
            $script:capturedMachinePolicyValue = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path { return $false } -ModuleName Browser.FirefoxPolicy
            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-ItemProperty {
                [PSCustomObject]@{
                    ExtensionSettings = @(
                        '{"other@example.com":{"installation_mode":"allowed"}}'
                    )
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    firefoxExtensionId = $contract.extensionId
                    firefoxExtensionInstallUrl = $contract.configuredInstallUrl
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock New-ItemProperty {
                param([string]$Path, [string]$Name, [object]$Value, [object]$PropertyType)
                if ($Name -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyValue = @($Value)
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue

            $machinePolicy = $script:capturedMachinePolicyValue[0] | ConvertFrom-Json
            $machinePolicy.'other@example.com'.installation_mode | Should -Be 'allowed'
            $machinePolicy.($contract.extensionId).installation_mode | Should -Be 'force_installed'
        }

        It "Removes only OpenPath entry from machine Firefox ExtensionSettings cleanup" {
            $script:capturedMachinePolicyValue = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path { return $true } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    firefoxExtensionId = $contract.extensionId
                    firefoxExtensionInstallUrl = $contract.configuredInstallUrl
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-ItemProperty {
                [PSCustomObject]@{
                    ExtensionSettings = @(
                        "{`"$($contract.extensionId)`":{`"installation_mode`":`"force_installed`"},`"other@example.com`":{`"installation_mode`":`"allowed`"}}"
                    )
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock New-ItemProperty {
                param([string]$Path, [string]$Name, [object]$Value, [object]$PropertyType)
                if ($Name -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyValue = @($Value)
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Remove-ItemProperty { throw 'Should not remove non-empty ExtensionSettings' } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy

            $machinePolicy = $script:capturedMachinePolicyValue[0] | ConvertFrom-Json
            $machinePolicy.PSObject.Properties.Name | Should -Contain 'other@example.com'
            $machinePolicy.PSObject.Properties.Name | Should -Not -Contain $contract.extensionId
        }

        It "Removes OpenPath machine policy entry even when signed config is unavailable" {
            $script:removedMachinePolicyValue = $false
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Get-OpenPathConfig { [PSCustomObject]@{} } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path { return $false } -ModuleName Browser.FirefoxPolicy
            Mock Get-ItemProperty {
                [PSCustomObject]@{
                    ExtensionSettings = @(
                        "{`"$($contract.extensionId)`":{`"installation_mode`":`"force_installed`"}}"
                    )
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Remove-ItemProperty {
                param([string]$Path, [string]$Name)
                if ($Name -eq 'ExtensionSettings') {
                    $script:removedMachinePolicyValue = $true
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy | Should -BeTrue
            $script:removedMachinePolicyValue | Should -BeTrue
        }

        It "Uses the managed OpenPath API for Firefox release updates when apiUrl is configured" {
            $script:capturedFirefoxPolicyJson = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*firefox.exe') { return $true }
                if ($Path -like '*metadata.json') { return $true }
                if ($Path -like '*openpath-firefox-extension.xpi') { return $true }
                return $false
            } -ModuleName Browser.FirefoxPolicy

            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig { [PSCustomObject]@{ apiUrl = 'https://school.example/' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = $contract.extensionId
                    InstallUrl = $contract.managedApiInstallUrl
                    Source = 'managed-api'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-Content {
                param([string]$Path, [switch]$Raw)
                if ($Path -like '*metadata.json') {
                    return '{"extensionId":"openpath-block-monitor@openpath","version":"2.0.0"}'
                }

                throw "Unexpected path: $Path"
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.managedApiInstallUrl
        }

        It "Prefers the staged signed Firefox XPI over metadata installUrl when both exist" {
            $script:capturedFirefoxPolicyJson = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*firefox.exe') { return $true }
                if ($Path -like '*metadata.json') { return $true }
                if ($Path -like '*openpath-firefox-extension.xpi') { return $true }
                return $false
            } -ModuleName Browser.FirefoxPolicy

            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig { [PSCustomObject]@{} } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = $contract.extensionId
                    InstallUrl = $contract.stagedReleaseInstallUrl
                    Source = 'staged-release'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Resolve-Path { $null } -ModuleName Browser.FirefoxPolicy
            Mock ConvertTo-OpenPathFileUrl { $contract.stagedReleaseInstallUrl } -ModuleName Browser.FirefoxPolicy
            Mock Get-Content {
                param([string]$Path, [switch]$Raw)
                if ($Path -like '*metadata.json') {
                    return "{`"extensionId`":`"$($contract.extensionId)`",`"version`":`"2.0.0`",`"installUrl`":`"$($contract.metadataInstallUrl)`"}"
                }

                throw "Unexpected path: $Path"
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.stagedReleaseInstallUrl
        }

        It "Resolves staged Firefox release artifacts from the default OpenPath root" {
            $script:capturedFirefoxPolicyJson = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path {
                param([string]$Path)
                switch ($Path) {
                    { $_ -like '*firefox.exe' } { return $true }
                    { $_ -like '*metadata.json' } { return $true }
                    { $_ -like '*openpath-firefox-extension.xpi' } { return $true }
                    default { return $false }
                }
            } -ModuleName Browser.FirefoxPolicy

            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig { [PSCustomObject]@{} } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = $contract.extensionId
                    InstallUrl = $contract.stagedReleaseInstallUrl
                    Source = 'staged-release'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Resolve-Path { $null } -ModuleName Browser.FirefoxPolicy
            Mock ConvertTo-OpenPathFileUrl { $contract.stagedReleaseInstallUrl } -ModuleName Browser.FirefoxPolicy
            Mock Get-Content {
                param([string]$Path, [switch]$Raw)
                if ($Path -like '*metadata.json') {
                    return "{`"extensionId`":`"$($contract.extensionId)`",`"version`":`"2.0.0`"}"
                }

                throw "Unexpected path: $Path"
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.stagedReleaseInstallUrl
        }

        It "Converts unresolved staged Windows XPI paths into file URLs" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-Path { $null } -ModuleName Browser.Common

            $result = InModuleScope Browser.Common {
                ConvertTo-OpenPathFileUrl -Path 'C:\OpenPath\browser-extension\firefox-release\openpath-firefox-extension.xpi'
            }
            $result | Should -Be $contract.stagedReleaseInstallUrl
        }

        It "Writes UTF-8 text files without a BOM" {
            $tempFile = Join-Path $TestDrive 'policies.json'
            $json = '{"policies":{"DisableTelemetry":true}}'

            InModuleScope Browser.Common -Parameters @{
                TempFile = $tempFile
                Json = $json
            } {
                Write-OpenPathUtf8NoBomFile -Path $TempFile -Value $Json
            }

            $bytes = [System.IO.File]::ReadAllBytes($tempFile)
            $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191

            $hasUtf8Bom | Should -BeFalse
            [System.IO.File]::ReadAllText($tempFile, [System.Text.UTF8Encoding]::new($false)) | Should -Be $json
        }

        It "Guards Firefox policy output against Set-Content -Encoding UTF8 regressions" {
            $browserPolicyModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxPolicy.psm1"
            $content = Get-Content $browserPolicyModulePath -Raw

            $content | Should -Not -Match 'Set-Content\s+[^\r\n]*-Encoding\s+UTF8'
            $content | Should -Match 'Write-OpenPathUtf8NoBomFile -Path \$policiesPath -Value \$policiesJson'
        }

        It "Does not write Firefox enforcement policy keys" {
            $script:capturedFirefoxPolicyJson = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*firefox.exe') { return $true }
                return $false
            } -ModuleName Browser.FirefoxPolicy

            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    firefoxExtensionId = $contract.extensionId
                    firefoxExtensionInstallUrl = $contract.configuredInstallUrl
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathUtf8NoBomFile {
                param([string]$Path, [string]$Value)
                if ($Path -like '*policies.json') {
                    $script:capturedFirefoxPolicyJson = $Value
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.PSObject.Properties.Name | Should -Not -Contain 'WebsiteFilter'
            $policy.policies.PSObject.Properties.Name | Should -Not -Contain 'SearchEngines'
            $policy.policies.PSObject.Properties.Name | Should -Not -Contain 'DNSOverHTTPS'
            $policy.policies.PSObject.Properties.Name | Should -Not -Contain 'DisableTelemetry'
            $policy.policies.PSObject.Properties.Name | Should -Not -Contain 'OverrideFirstRunPage'
        }
    }

    Context "Test-OpenPathFirefoxManagedExtensionReady" {
        It "Fails when Firefox Release is missing" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-OpenPathFirefoxReleaseExecutable { '' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = $contract.extensionId
                    InstallUrl = $contract.managedApiInstallUrl
                    Source = 'managed-api'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $true } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady `
                -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' }) `
                -RequireRuntimeRegistration

            $result.Ready | Should -BeFalse
            $result.FailureCode | Should -Be 'firefox-release-missing'
            $result.ExtensionInstalled | Should -BeFalse
            $result.ExtensionActive | Should -BeFalse
            $result.InstallUrl | Should -Be $contract.managedApiInstallUrl
            $result.PolicyPath | Should -Be 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
        }

        It "Fails when the force-installed machine policy is missing" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = $contract.extensionId
                    InstallUrl = $contract.managedApiInstallUrl
                    Source = 'managed-api'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $false } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady `
                -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' }) `
                -RequireRuntimeRegistration

            $result.Ready | Should -BeFalse
            $result.FailureCode | Should -Be 'firefox-machine-policy-missing'
            $result.Message | Should -Match 'force_installed'
            $result.ExtensionInstalled | Should -BeFalse
            $result.ExtensionActive | Should -BeFalse
        }

        It "Fails when Firefox starts but does not register the managed extension" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = $contract.extensionId
                    InstallUrl = $contract.managedApiInstallUrl
                    Source = 'managed-api'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $true } -ModuleName Browser.FirefoxPolicy
            Mock Invoke-OpenPathFirefoxManagedExtensionRuntimeProbe {
                [PSCustomObject]@{
                    ExtensionInstalled = $false
                    ExtensionActive = $false
                    Message = 'extensions.json did not contain openpath-block-monitor@openpath'
                    ProfilePath = 'C:\Temp\openpath-firefox-profile'
                }
            } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady `
                -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' }) `
                -RequireRuntimeRegistration

            $result.Ready | Should -BeFalse
            $result.FailureCode | Should -Be 'firefox-extension-runtime-missing'
            $result.ExtensionInstalled | Should -BeFalse
            $result.ExtensionActive | Should -BeFalse
            $result.Message | Should -Match 'extensions.json'
        }

        It "Passes when policy and active runtime registration exist" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = $contract.extensionId
                    InstallUrl = $contract.managedApiInstallUrl
                    Source = 'managed-api'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $true } -ModuleName Browser.FirefoxPolicy
            Mock Invoke-OpenPathFirefoxManagedExtensionRuntimeProbe {
                [PSCustomObject]@{
                    ExtensionInstalled = $true
                    ExtensionActive = $true
                    Message = 'Firefox registered active managed extension.'
                    ProfilePath = 'C:\Temp\openpath-firefox-profile'
                }
            } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady `
                -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' }) `
                -RequireRuntimeRegistration

            $result.Ready | Should -BeTrue
            $result.FailureCode | Should -Be ''
            $result.ExtensionInstalled | Should -BeTrue
            $result.ExtensionActive | Should -BeTrue
            $result.InstallUrl | Should -Be $contract.managedApiInstallUrl
        }
    }
}
