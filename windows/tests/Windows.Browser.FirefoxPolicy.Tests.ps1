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

    Context "Firefox Release executable discovery" {
        It "Resolves 64-bit Firefox Release from ProgramW6432 under a 32-bit PowerShell process" {
            $environmentNames = @(
                'ProgramFiles',
                'ProgramFiles(x86)',
                'ProgramW6432',
                'PROCESSOR_ARCHITECTURE',
                'PROCESSOR_ARCHITEW6432'
            )
            $previousEnvironment = @{}

            foreach ($name in $environmentNames) {
                $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }

            try {
                [Environment]::SetEnvironmentVariable('ProgramFiles', 'C:\Program Files (x86)', 'Process')
                [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)', 'Process')
                [Environment]::SetEnvironmentVariable('ProgramW6432', 'C:\Program Files', 'Process')
                [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'x86', 'Process')
                [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITEW6432', 'AMD64', 'Process')

                Mock Test-Path {
                    param(
                        [string]$Path,
                        [string]$LiteralPath
                    )

                    $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                    return $candidate -eq 'C:\Program Files\Mozilla Firefox\firefox.exe'
                } -ModuleName Browser.FirefoxPolicy
                Mock Get-OpenPathFirefoxReleaseRegistryCandidates { @() } -ModuleName Browser.FirefoxPolicy

                $resolved = InModuleScope Browser.FirefoxPolicy {
                    Resolve-OpenPathFirefoxReleaseExecutable
                }

                $resolved | Should -Be 'C:\Program Files\Mozilla Firefox\firefox.exe'
            }
            finally {
                foreach ($name in $environmentNames) {
                    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
                }
            }
        }

        It "Prefers a Registry64 Firefox Release candidate before Registry32 and filesystem candidates" {
            $registry64Path = 'D:\School Firefox 64\firefox.exe'
            $registry32Path = 'D:\School Firefox 32\firefox.exe'

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @(
                    [PSCustomObject]@{
                        Path = $registry64Path
                        Source = 'Registry64 Uninstall/InstallLocation'
                    },
                    [PSCustomObject]@{
                        Path = $registry32Path
                        Source = 'Registry32 Uninstall/InstallLocation'
                    }
                )
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path {
                param(
                    [string]$Path,
                    [string]$LiteralPath
                )

                $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                return $candidate -in @($registry64Path, $registry32Path)
            } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            $discovery.Path | Should -Be $registry64Path
            $discovery.Source | Should -Be 'Registry64 Uninstall/InstallLocation'
            @($discovery.CheckedCandidates).Count | Should -Be 1
        }

        It "Resolves a custom Firefox Release location from registered installation data" {
            $customPath = 'D:\Applications\Firefox\firefox.exe'

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @([PSCustomObject]@{
                        Path = $customPath
                        Source = 'Registry64 Uninstall/InstallLocation'
                    })
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path {
                param(
                    [string]$Path,
                    [string]$LiteralPath
                )

                $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                return $candidate -eq $customPath
            } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            $discovery.Path | Should -Be $customPath
            $discovery.Source | Should -Be 'Registry64 Uninstall/InstallLocation'
        }

        It "Does not trust an uncorroborated App Paths entry as Firefox Release" {
            $unverifiedPath = 'D:\Applications\Unverified Firefox\firefox.exe'

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @([PSCustomObject]@{
                        Path = $unverifiedPath
                        Source = 'Registry64 App Paths'
                        ReleaseIdentity = $false
                    })
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path {
                param(
                    [string]$Path,
                    [string]$LiteralPath
                )

                $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                return $candidate -eq $unverifiedPath
            } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            $discovery.Path | Should -BeNullOrEmpty
            @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $unverifiedPath }).Reason | Should -Be 'registered App Paths entry lacks Firefox Release identity'
        }

        It "Reads the explicit Registry64 and Registry32 views in order" {
            $newFakeRegistryKey = {
                param(
                    [hashtable]$Values = @{},
                    [hashtable]$SubKeys = @{}
                )

                $fakeKey = [PSCustomObject]@{
                    Values = $Values
                    SubKeys = $SubKeys
                }
                Add-Member -InputObject $fakeKey -MemberType ScriptMethod -Name GetValue -Value {
                    param([string]$Name)
                    if ($this.Values.ContainsKey($Name)) {
                        return $this.Values[$Name]
                    }

                    return $null
                }
                Add-Member -InputObject $fakeKey -MemberType ScriptMethod -Name GetSubKeyNames -Value {
                    return @($this.SubKeys.Keys)
                }
                Add-Member -InputObject $fakeKey -MemberType ScriptMethod -Name OpenSubKey -Value {
                    param([string]$Name)
                    if ($this.SubKeys.ContainsKey($Name)) {
                        return $this.SubKeys[$Name]
                    }

                    return $null
                }
                Add-Member -InputObject $fakeKey -MemberType ScriptMethod -Name Close -Value {}
                return $fakeKey
            }

            $appPaths64 = & $newFakeRegistryKey -Values @{
                '' = 'D:\Firefox 64\firefox.exe'
            }
            $release64 = & $newFakeRegistryKey -Values @{
                DisplayName = 'Mozilla Firefox'
                InstallLocation = 'D:\Firefox 64'
                DisplayIcon = 'D:\Firefox 64\firefox.exe,0'
            }
            $uninstall64 = & $newFakeRegistryKey -SubKeys @{
                'Mozilla Firefox' = $release64
            }
            $base64 = & $newFakeRegistryKey -SubKeys @{
                'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe' = $appPaths64
                'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = $uninstall64
            }

            $appPaths32 = & $newFakeRegistryKey -Values @{
                '' = 'D:\Firefox 32\firefox.exe'
            }
            $release32 = & $newFakeRegistryKey -Values @{
                DisplayName = 'Mozilla Firefox'
                InstallLocation = 'D:\Firefox 32'
                DisplayIcon = 'D:\Firefox 32\firefox.exe,0'
            }
            $uninstall32 = & $newFakeRegistryKey -SubKeys @{
                'Mozilla Firefox' = $release32
            }
            $base32 = & $newFakeRegistryKey -SubKeys @{
                'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe' = $appPaths32
                'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = $uninstall32
            }

            $fakeBases = @{
                Registry64 = $base64
                Registry32 = $base32
            }
            $script:seenFirefoxRegistryViews = @()

            Mock Open-OpenPathFirefoxReleaseRegistryBaseKey {
                param([Microsoft.Win32.RegistryView]$RegistryView)
                $script:seenFirefoxRegistryViews += [string]$RegistryView
                return $fakeBases[[string]$RegistryView]
            } -ModuleName Browser.FirefoxPolicy

            $candidates = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseRegistryCandidates
            }

            ($script:seenFirefoxRegistryViews -join ',') | Should -Be 'Registry64,Registry32'
            $candidates[0].Source | Should -Be 'Registry64 App Paths'
            @($candidates | Where-Object { $_.Source -like 'Registry32*' }).Count | Should -BeGreaterThan 0
            @($candidates | Where-Object { $_.ReleaseIdentity }).Count | Should -Be 4
        }

        It "Converts a registered Firefox DisplayIcon value into an executable path" {
            $resolved = InModuleScope Browser.FirefoxPolicy {
                ConvertTo-OpenPathFirefoxReleaseExecutablePath -Value '"D:\Applications\Firefox\firefox.exe",0'
            }

            $resolved | Should -Be 'D:\Applications\Firefox\firefox.exe'
        }

        It "Requires a Firefox Release uninstall identity" {
            $releaseNames = @(
                'Mozilla Firefox',
                'Mozilla Firefox (x64 en-US)'
            )
            $nonReleaseNames = @(
                'Mozilla Firefox ESR',
                'Mozilla Firefox (ESR)',
                'Mozilla Firefox (Developer Edition)',
                'Firefox Nightly'
            )

            foreach ($displayName in $releaseNames) {
                $isRelease = InModuleScope Browser.FirefoxPolicy -Parameters @{ Name = $displayName } {
                    Test-OpenPathFirefoxReleaseDisplayName -DisplayName $Name
                }

                $isRelease | Should -BeTrue
            }

            foreach ($displayName in $nonReleaseNames) {
                $isRelease = InModuleScope Browser.FirefoxPolicy -Parameters @{ Name = $displayName } {
                    Test-OpenPathFirefoxReleaseDisplayName -DisplayName $Name
                }

                $isRelease | Should -BeFalse
            }
        }

        It "Resolves Firefox x86 from ProgramFiles(x86) when wider paths are unavailable" {
            $environmentNames = @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')
            $previousEnvironment = @{}

            foreach ($name in $environmentNames) {
                $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }

            try {
                [Environment]::SetEnvironmentVariable('ProgramFiles', 'C:\Missing Program Files', 'Process')
                [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)', 'Process')
                [Environment]::SetEnvironmentVariable('ProgramW6432', $null, 'Process')

                Mock Get-OpenPathFirefoxReleaseRegistryCandidates { @() } -ModuleName Browser.FirefoxPolicy
                Mock Test-Path {
                    param(
                        [string]$Path,
                        [string]$LiteralPath
                    )

                    $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                    return $candidate -eq 'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
                } -ModuleName Browser.FirefoxPolicy

                $resolved = InModuleScope Browser.FirefoxPolicy {
                    Resolve-OpenPathFirefoxReleaseExecutable
                }

                $resolved | Should -Be 'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
            }
            finally {
                foreach ($name in $environmentNames) {
                    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
                }
            }
        }

        It "Rejects Tor Browser and Firefox Portable even when their executables exist" {
            $torPaths = @(
                'C:\Program Files\Tor Browser\Browser\firefox.exe',
                'C:\Program Files\TorBrowser\Browser\firefox.exe'
            )
            $portablePaths = @(
                'C:\Users\student\Downloads\FirefoxPortable\App\Firefox64\firefox.exe',
                'C:\Users\student\Downloads\Firefox Portable\firefox.exe',
                'C:\Users\student\Downloads\Portable\Firefox\firefox.exe'
            )
            $excludedPaths = @($torPaths + $portablePaths)

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @($excludedPaths | ForEach-Object {
                        [PSCustomObject]@{
                            Path = $_
                            Source = 'Registry64 App Paths'
                        }
                    })
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path {
                param(
                    [string]$Path,
                    [string]$LiteralPath
                )

                $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                return $candidate -in $excludedPaths
            } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            $discovery.Path | Should -BeNullOrEmpty
            foreach ($torPath in $torPaths) {
                @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $torPath }).Reason | Should -Be 'Tor Browser is not Firefox Release'
            }
            foreach ($portablePath in $portablePaths) {
                @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $portablePath }).Reason | Should -Be 'portable Firefox is not Firefox Release'
            }
        }

        It "Rejects registered Firefox non-Release channels" {
            $nonReleasePaths = @(
                'C:\Program Files\Firefox Developer Edition\firefox.exe',
                'C:\Program Files\Mozilla Firefox Developer Edition\firefox.exe',
                'C:\Program Files\Mozilla Firefox (ESR)\firefox.exe'
            )

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @($nonReleasePaths | ForEach-Object {
                        [PSCustomObject]@{
                            Path = $_
                            Source = 'Registry64 App Paths'
                        }
                    })
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path {
                param(
                    [string]$Path,
                    [string]$LiteralPath
                )

                $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                return $candidate -in $nonReleasePaths
            } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            $discovery.Path | Should -BeNullOrEmpty
            foreach ($nonReleasePath in $nonReleasePaths) {
                @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $nonReleasePath }).Reason | Should -Be 'non-Release Firefox channel is not Firefox Release'
            }
        }

        It "Rejects a firefox.exe directory instead of treating it as an executable" {
            $directoryPath = 'C:\Program Files\Mozilla Firefox\firefox.exe'

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @([PSCustomObject]@{
                        Path = $directoryPath
                        Source = 'Registry64 Uninstall/InstallLocation'
                    })
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path {
                param(
                    [string]$Path,
                    [string]$LiteralPath,
                    [string]$PathType
                )

                if (-not $PathType) {
                    return $true
                }

                return $false
            } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            $discovery.Path | Should -BeNullOrEmpty
            @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $directoryPath }).Reason | Should -Be 'executable path is missing or not a file'
        }

        It "Deduplicates registered Firefox candidates before validation" {
            $duplicatePath = 'D:\Applications\Firefox\firefox.exe'

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @(
                    [PSCustomObject]@{ Path = $duplicatePath; Source = 'Registry64 App Paths' },
                    [PSCustomObject]@{ Path = $duplicatePath; Source = 'Registry32 Uninstall/InstallLocation' }
                )
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path { $false } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            @($discovery.CheckedCandidates | Where-Object { $_.Path -eq $duplicatePath }).Count | Should -Be 1
        }
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

        It "Version-keys configured managed API Firefox install URLs from release metadata" {
            $script:capturedFirefoxPolicyJson = $null
            $script:capturedMachinePolicyValue = $null
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Test-Path {
                param([string]$Path)
                if ($Path -like '*firefox.exe') { return $true }
                if ($Path -like '*metadata.json') { return $true }
                return $false
            } -ModuleName Browser.FirefoxPolicy

            Mock New-Item { [PSCustomObject]@{ FullName = 'mock-path' } } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    firefoxExtensionId = $contract.extensionId
                    firefoxExtensionInstallUrl = $contract.managedApiInstallUrl
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxReleaseMetadata {
                [PSCustomObject]@{
                    extensionId = $contract.extensionId
                    version = '2.0.0.779021904'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-Content {
                param([string]$Path, [switch]$Raw)
                if ($Path -like '*metadata.json') {
                    return "{`"extensionId`":`"$($contract.extensionId)`",`"version`":`"2.0.0.779021904`"}"
                }

                throw "Unexpected path: $Path"
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

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.managedApiVersionedInstallUrl

            $machinePolicy = $script:capturedMachinePolicyValue[0] | ConvertFrom-Json
            $machinePolicy.($contract.extensionId).install_url | Should -Be $contract.managedApiVersionedInstallUrl
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
            Mock Get-OpenPathFirefoxReleaseMetadata {
                [PSCustomObject]@{
                    extensionId = $contract.extensionId
                    version = '2.0.0.779021904'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-Content {
                param([string]$Path, [switch]$Raw)
                if ($Path -like '*metadata.json') {
                    return "{`"extensionId`":`"$($contract.extensionId)`",`"version`":`"2.0.0.779021904`"}"
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
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.managedApiVersionedInstallUrl
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

            Mock Resolve-OpenPathFirefoxReleaseExecutable {
                param([ref]$Diagnostics)
                $Diagnostics.Value = [PSCustomObject]@{
                    CheckedCandidates = @([PSCustomObject]@{
                            Path = 'D:\Firefox Release\firefox.exe'
                            Source = 'Registry64 Uninstall/InstallLocation'
                            Valid = $false
                            Reason = 'executable path does not exist'
                        })
                    RejectedCandidates = @()
                }
                return ''
            } -ModuleName Browser.FirefoxPolicy
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
            $result.Message | Should -Match 'Firefox Release executable could not be discovered'
            $result.Message | Should -Match 'Registry64 Uninstall/InstallLocation'
            $result.Message | Should -Match 'D:\\Firefox Release\\firefox.exe'
            $result.Message | Should -Not -Match '(?i)managed extension policy|runtime registration'
            $result.FirefoxDiscovery.CheckedCandidates[0].Source | Should -Be 'Registry64 Uninstall/InstallLocation'
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
