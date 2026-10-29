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

    BeforeEach {
        # Default: an empty, unmanaged store so no test touches the real registry or local GPO.
        Mock Get-OpenPathManagedPolicyValue {
            [PSCustomObject]@{ Type = $null; Value = $null; Source = 'None' }
        } -ModuleName Browser.FirefoxPolicy
        Mock Set-OpenPathManagedPolicyValue {
            [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = $null }
        } -ModuleName Browser.FirefoxPolicy
        Mock Remove-OpenPathManagedPolicyValue {
            [PSCustomObject]@{ Removed = $true; FailureCode = $null }
        } -ModuleName Browser.FirefoxPolicy
        Mock Get-OpenPathPolicyValueOwner {
            [PSCustomObject]@{ Owner = 'None'; GpoName = $null; Evidence = @() }
        } -ModuleName Browser.FirefoxPolicy
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
                Mock Get-OpenPathFirefoxReleaseInstallationChannel { 'release' } -ModuleName Browser.FirefoxPolicy

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
                        ReleaseIdentity = $true
                    },
                    [PSCustomObject]@{
                        Path = $registry32Path
                        Source = 'Registry32 Uninstall/InstallLocation'
                        ReleaseIdentity = $true
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
                        ReleaseIdentity = $true
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

        It "Allows a registered Firefox Release below an unrelated Developer directory" {
            $customPath = 'D:\Developer\Applications\Firefox\firefox.exe'

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @([PSCustomObject]@{
                        Path = $customPath
                        Source = 'Registry64 Uninstall/InstallLocation'
                        ReleaseIdentity = $true
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
            @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $unverifiedPath }).Reason | Should -Be 'Firefox installation channel could not be verified as Release'
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
                URLUpdateInfo = 'https://www.firefox.com/firefox/1/releasenotes'
            }
            $beta64 = & $newFakeRegistryKey -Values @{
                DisplayName = 'Mozilla Firefox (x64 en-US)'
                InstallLocation = 'D:\Firefox Beta'
                DisplayIcon = 'D:\Firefox Beta\firefox.exe,0'
            }
            $esr64 = & $newFakeRegistryKey -Values @{
                DisplayName = 'Mozilla Firefox ESR (x64 en-US)'
                InstallLocation = 'D:\Firefox ESR'
                DisplayIcon = 'D:\Firefox ESR\firefox.exe,0'
            }
            $uninstall64 = & $newFakeRegistryKey -SubKeys @{
                'Mozilla Firefox' = $release64
                'Mozilla Firefox Beta' = $beta64
                'Mozilla Firefox ESR' = $esr64
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
                URLUpdateInfo = 'https://www.firefox.com/firefox/1/releasenotes'
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
            @($candidates | Where-Object { $_.Path -eq 'D:\Firefox Beta\firefox.exe' }).Count | Should -Be 2
            @($candidates | Where-Object { $_.Path -eq 'D:\Firefox Beta\firefox.exe' -and $_.ReleaseIdentity }).Count | Should -Be 0
            @($candidates | Where-Object { $_.Path -eq 'D:\Firefox ESR\firefox.exe' }).Count | Should -Be 0
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
                Mock Get-OpenPathFirefoxReleaseInstallationChannel { 'release' } -ModuleName Browser.FirefoxPolicy
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

        It "Rejects a Beta installation with Release-shaped branding and path" {
            $betaPath = 'C:\Program Files\Mozilla Firefox\firefox.exe'
            $channelPrefsPath = 'C:\Program Files\Mozilla Firefox\defaults\pref\channel-prefs.js'

            Mock Get-OpenPathFirefoxReleaseRegistryCandidates {
                @([PSCustomObject]@{
                        Path = $betaPath
                        Source = 'Registry64 Uninstall/InstallLocation'
                        DisplayName = 'Mozilla Firefox (x64 en-US)'
                        InstallLocation = 'C:\Program Files\Mozilla Firefox'
                        ReleaseIdentity = $false
                    })
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-Path {
                param(
                    [string]$Path,
                    [string]$LiteralPath,
                    [string]$PathType
                )

                $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                return $candidate -in @($betaPath, $channelPrefsPath)
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-Content {
                param(
                    [string]$LiteralPath,
                    [switch]$Raw
                )

                if ($LiteralPath -eq $channelPrefsPath) {
                    return 'pref("app.update.channel", "beta");'
                }

                throw "Unexpected path: $LiteralPath"
            } -ModuleName Browser.FirefoxPolicy

            $discovery = InModuleScope Browser.FirefoxPolicy {
                Get-OpenPathFirefoxReleaseDiscovery
            }

            $discovery.Path | Should -BeNullOrEmpty
            @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $betaPath }).Reason | Should -Be 'Firefox installation channel beta is not Firefox Release'
        }

        It "Rejects ESR at the canonical Mozilla Firefox path even when the executable exists" {
            $esrPath = 'C:\Program Files\Mozilla Firefox\firefox.exe'
            $channelPrefsPath = 'C:\Program Files\Mozilla Firefox\defaults\pref\channel-prefs.js'
            $environmentNames = @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')
            $previousEnvironment = @{}

            foreach ($name in $environmentNames) {
                $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }

            try {
                [Environment]::SetEnvironmentVariable('ProgramFiles', 'C:\Program Files', 'Process')
                [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Missing Program Files (x86)', 'Process')
                [Environment]::SetEnvironmentVariable('ProgramW6432', $null, 'Process')

                Mock Get-OpenPathFirefoxReleaseRegistryCandidates { @() } -ModuleName Browser.FirefoxPolicy
                Mock Test-Path {
                    param(
                        [string]$Path,
                        [string]$LiteralPath,
                        [string]$PathType
                    )

                    $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
                    return $candidate -in @($esrPath, $channelPrefsPath)
                } -ModuleName Browser.FirefoxPolicy
                Mock Get-Content {
                    param(
                        [string]$LiteralPath,
                        [switch]$Raw
                    )

                    if ($LiteralPath -eq $channelPrefsPath) {
                        return 'pref("app.update.channel", "esr");'
                    }

                    throw "Unexpected path: $LiteralPath"
                } -ModuleName Browser.FirefoxPolicy

                $discovery = InModuleScope Browser.FirefoxPolicy {
                    Get-OpenPathFirefoxReleaseDiscovery
                }

                $discovery.Path | Should -BeNullOrEmpty
                @($discovery.RejectedCandidates | Where-Object { $_.Path -eq $esrPath }).Reason | Should -Be 'Firefox installation channel esr is not Firefox Release'
            }
            finally {
                foreach ($name in $environmentNames) {
                    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
                }
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
            Mock Set-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName, [string]$Type, [object]$Value)
                if ($ValueName -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyPath = $Key
                    $script:capturedMachinePolicyType = $Type
                    $script:capturedMachinePolicyValue = @($Value)
                }
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = $null }
            } -ModuleName Browser.FirefoxPolicy
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy

            $result = Sync-OpenPathFirefoxManagedExtensionPolicy
            $result | Should -BeTrue

            $policy = $script:capturedFirefoxPolicyJson | ConvertFrom-Json
            $policy.policies.PSObject.Properties.Name | Should -Be @('ExtensionSettings')
            $policy.policies.ExtensionSettings.($contract.extensionId).installation_mode | Should -Be 'force_installed'
            $policy.policies.ExtensionSettings.($contract.extensionId).install_url | Should -Be $contract.configuredInstallUrl
            $policy.policies.ExtensionSettings.($contract.extensionId).private_browsing | Should -BeTrue

            $script:capturedMachinePolicyPath | Should -Be 'Software\Policies\Mozilla\Firefox'
            $script:capturedMachinePolicyType | Should -Be 'MultiString'
            $script:capturedMachinePolicyValue.Count | Should -Be 1
            $machinePolicy = $script:capturedMachinePolicyValue[0] | ConvertFrom-Json
            $machinePolicy.($contract.extensionId).installation_mode | Should -Be 'force_installed'
            $machinePolicy.($contract.extensionId).install_url | Should -Be $contract.configuredInstallUrl
            $machinePolicy.($contract.extensionId).private_browsing | Should -BeTrue
        }

        It "Treats a machine policy entry without private browsing access as not applied" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'
            $managedPolicy = [PSCustomObject]@{
                ExtensionId = $contract.extensionId
                InstallUrl = $contract.configuredInstallUrl
            }
            $script:machineEntryJson = $null
            Mock Get-ItemProperty {
                [PSCustomObject]@{ ExtensionSettings = @($script:machineEntryJson) }
            } -ModuleName Browser.FirefoxPolicy

            $script:machineEntryJson = (@{ $contract.extensionId = @{ installation_mode = 'force_installed'; install_url = $contract.configuredInstallUrl } } | ConvertTo-Json -Compress)
            Test-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $managedPolicy | Should -BeFalse

            $script:machineEntryJson = (@{ $contract.extensionId = @{ installation_mode = 'force_installed'; install_url = $contract.configuredInstallUrl; private_browsing = $true } } | ConvertTo-Json -Compress)
            Test-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $managedPolicy | Should -BeTrue
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
            Mock Set-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName, [string]$Type, [object]$Value)
                if ($ValueName -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyValue = @($Value)
                }
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = $null }
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
            Mock Set-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName, [string]$Type, [object]$Value)
                if ($ValueName -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyValue = @($Value)
                }
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = $null }
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
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{
                    Type = 'MultiString'
                    Value = [string[]]@('{"other@example.com":{"installation_mode":"allowed"}}')
                    Source = 'LocalGpo'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    firefoxExtensionId = $contract.extensionId
                    firefoxExtensionInstallUrl = $contract.configuredInstallUrl
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Set-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName, [string]$Type, [object]$Value)
                if ($ValueName -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyValue = @($Value)
                }
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = $null }
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
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{
                    Type = 'MultiString'
                    Value = [string[]]@("{`"$($contract.extensionId)`":{`"installation_mode`":`"force_installed`"},`"other@example.com`":{`"installation_mode`":`"allowed`"}}")
                    Source = 'LocalGpo'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Set-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName, [string]$Type, [object]$Value)
                if ($ValueName -eq 'ExtensionSettings') {
                    $script:capturedMachinePolicyValue = @($Value)
                }
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = $null }
            } -ModuleName Browser.FirefoxPolicy
            Mock Remove-OpenPathManagedPolicyValue { throw 'Should not remove non-empty ExtensionSettings' } -ModuleName Browser.FirefoxPolicy
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
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{
                    Type = 'MultiString'
                    Value = [string[]]@("{`"$($contract.extensionId)`":{`"installation_mode`":`"force_installed`"}}")
                    Source = 'LocalGpo'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Remove-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName)
                if ($ValueName -eq 'ExtensionSettings') {
                    $script:removedMachinePolicyValue = $true
                }
                [PSCustomObject]@{ Removed = $true; FailureCode = $null }
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

    Context "Firefox ExtensionSettings through the policy store" {
        BeforeEach {
            $script:storeContract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'
            $script:storePolicy = [PSCustomObject]@{
                ExtensionId = $script:storeContract.extensionId
                InstallUrl = 'https://openpath.example.invalid/firefox/openpath.xpi'
                Source = 'configured-install-url'
            }
            $script:storeSetCalls = @()
            $script:storeRemoveCalls = @()
            $script:storeOriginal = $null
            $script:registryOnlyWrites = @()
            Mock Write-OpenPathLog { } -ModuleName Browser.FirefoxPolicy
            Mock Set-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName, [string]$Type, [object]$Value, [switch]$ReleaseOriginal)
                $script:storeSetCalls += [PSCustomObject]@{ Key = $Key; ValueName = $ValueName; Type = $Type; Value = $Value; ReleaseOriginal = [bool]$ReleaseOriginal }
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = $null }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeSequence = New-Object System.Collections.Generic.List[string]
            $script:refreshExitCode = 0
            $script:refreshCalls = @()
            Mock Remove-OpenPathManagedPolicyValue {
                param([string]$Key, [string]$ValueName, [switch]$DiscardOriginal, [switch]$KeepRegistryValue)
                $script:storeSequence.Add('remove')
                $script:storeRemoveCalls += [PSCustomObject]@{ Key = $Key; ValueName = $ValueName; DiscardOriginal = [bool]$DiscardOriginal; KeepRegistryValue = [bool]$KeepRegistryValue }
                [PSCustomObject]@{ Removed = $true; Restored = $false; FailureCode = $null }
            } -ModuleName Browser.FirefoxPolicy
            Mock Invoke-OpenPathPolicyRefresh {
                param([switch]$Force, [int]$TimeoutSeconds)
                $script:storeSequence.Add('refresh')
                $script:refreshCalls += [PSCustomObject]@{ Force = [bool]$Force; TimeoutSeconds = $TimeoutSeconds }
                [PSCustomObject]@{ ExitCode = $script:refreshExitCode; DurationMs = 1 }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathPolicyStoreOriginal { $script:storeOriginal } -ModuleName Browser.FirefoxPolicy
            Mock New-ItemProperty {
                param([string]$Path, [string]$Name, [object]$Value, [string]$PropertyType)
                $script:storeSequence.Add('registry-write')
                $script:registryOnlyWrites += [PSCustomObject]@{ Path = $Path; Name = $Name; Value = $Value; PropertyType = $PropertyType }
            } -ModuleName Browser.FirefoxPolicy
            $script:firefoxKeyExists = $true
            Mock Test-Path { $script:firefoxKeyExists } -ModuleName Browser.FirefoxPolicy -ParameterFilter { "$Path$LiteralPath" -eq 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' }
            Mock New-Item {
                $script:storeSequence.Add('create-key')
                $script:firefoxKeyExists = $true
            } -ModuleName Browser.FirefoxPolicy -ParameterFilter { "$Path" -eq 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' }
        }

        It "Merges into HP REG_SZ GPO value keeping vendor entries and type" {
            $hpValue = '{"https://a.bromium.com/*":{"installation_mode":"blocked"},"https://b.bromium.com/*":{"installation_mode":"blocked"}}'
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $hpValue; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeSetCalls.Count | Should -Be 1
            $call = $script:storeSetCalls[0]
            $call.Key | Should -Be 'Software\Policies\Mozilla\Firefox'
            $call.ValueName | Should -Be 'ExtensionSettings'
            $call.Type | Should -Be 'String'
            $call.Value | Should -BeOfType [string]
            $merged = $call.Value | ConvertFrom-Json
            @($merged.PSObject.Properties.Name).Count | Should -Be 3
            $merged.'https://a.bromium.com/*'.installation_mode | Should -Be 'blocked'
            $merged.'https://b.bromium.com/*'.installation_mode | Should -Be 'blocked'
            $ours = $merged.($script:storeContract.extensionId)
            $ours.installation_mode | Should -Be 'force_installed'
            $ours.install_url | Should -Be 'https://openpath.example.invalid/firefox/openpath.xpi'
            $ours.private_browsing | Should -BeTrue
        }

        It "Uses MultiString when no value exists" {
            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeSetCalls.Count | Should -Be 1
            $script:storeSetCalls[0].Type | Should -Be 'MultiString'
            @($script:storeSetCalls[0].Value).Count | Should -Be 1
            $merged = @($script:storeSetCalls[0].Value)[0] | ConvertFrom-Json
            $merged.($script:storeContract.extensionId).private_browsing | Should -BeTrue
        }

        It "Parses MULTI_SZ JSON split across lines as one object" {
            $settings = InModuleScope Browser.FirefoxPolicy {
                ConvertFrom-OpenPathFirefoxMachineExtensionSettings -Value @(
                    '{"a@x":{"installation_mode":"blocked"},',
                    '"b@x":{"installation_mode":"blocked"}}'
                )
            }

            @($settings.Keys).Count | Should -Be 2
            $settings['a@x'].installation_mode | Should -Be 'blocked'
            $settings['b@x'].installation_mode | Should -Be 'blocked'
        }

        It "Still parses legacy one-object-per-line MULTI_SZ values" {
            $settings = InModuleScope Browser.FirefoxPolicy {
                ConvertFrom-OpenPathFirefoxMachineExtensionSettings -Value @(
                    '{"a@x":{"installation_mode":"blocked"}}',
                    '{"b@x":{"installation_mode":"allowed"}}'
                )
            }

            @($settings.Keys).Count | Should -Be 2
            $settings['b@x'].installation_mode | Should -Be 'allowed'
        }

        It "Preserves vendor entries when the multi-line GPO value is merged" {
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{
                    Type = 'MultiString'
                    Value = [string[]]@('{"a@x":{"installation_mode":"blocked"},', '"b@x":{"installation_mode":"blocked"}}')
                    Source = 'LocalGpo'
                }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeSetCalls[0].Type | Should -Be 'MultiString'
            $merged = @($script:storeSetCalls[0].Value)[0] | ConvertFrom-Json
            @($merged.PSObject.Properties.Name).Count | Should -Be 3
            $merged.'a@x'.installation_mode | Should -Be 'blocked'
            $merged.'b@x'.installation_mode | Should -Be 'blocked'
        }

        It "Returns false and names the owner when a domain GPO owns the value" {
            Mock Set-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Applied = $false; Changed = $false; Owner = 'DomainGpo'; GpoName = 'Default Domain Policy'; FailureCode = 'policy-externally-managed' }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse

            Should -Invoke Write-OpenPathLog -ModuleName Browser.FirefoxPolicy -Times 1 -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'DomainGpo' -and $Message -match 'Default Domain Policy'
            }
        }

        It "Returns false when the GPO version bump fails" {
            Mock Set-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = 'gpt-ini-bump-failed' }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse
        }

        It "Returns false when the store cannot apply the value" {
            Mock Set-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Applied = $false; Changed = $false; Owner = 'LocalGpo'; GpoName = $null; FailureCode = 'local-gpo-unreadable' }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse
        }

        It "Leaves a partially unparseable REG_SZ value untouched" {
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = '{"a":1,'; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse

            $script:storeSetCalls.Count | Should -Be 0
            Should -Invoke Write-OpenPathLog -ModuleName Browser.FirefoxPolicy -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'left untouched' -and $Message -match 'LocalGpo'
            }
        }

        It "Leaves a MultiString value with an unparseable line untouched" {
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{
                    Type = 'MultiString'
                    Value = [string[]]@('{"a@x":{"installation_mode":"blocked"}}', 'not json')
                    Source = 'LocalGpo'
                }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse

            $script:storeSetCalls.Count | Should -Be 0
        }

        It "Leaves a fully unparseable MultiString value untouched" {
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'MultiString'; Value = [string[]]@('{"a":1,', '"b":'); Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse

            $script:storeSetCalls.Count | Should -Be 0
        }

        It "Does not write when the store read throws" {
            Mock Get-OpenPathManagedPolicyValue { throw 'local-gpo-unreadable' } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse

            $script:storeSetCalls.Count | Should -Be 0
            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse
            $script:storeSetCalls.Count | Should -Be 0
            $script:storeRemoveCalls.Count | Should -Be 0
        }

        It "Remove leaves an unparseable value untouched" {
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = '{"a":1,'; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse

            $script:storeSetCalls.Count | Should -Be 0
            $script:storeRemoveCalls.Count | Should -Be 0
        }

        It "Remove returns false when the GPO version bump fails" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"a@x`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $stored; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            Mock Set-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'LocalGpo'; GpoName = $null; FailureCode = 'gpt-ini-bump-failed' }
            } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse
        }

        It "Checks the effective HKLM value, not the local GPO value" {
            $id = $script:storeContract.extensionId
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{
                    Type = 'String'
                    Value = "{`"$id`":{`"installation_mode`":`"force_installed`",`"install_url`":`"https://openpath.example.invalid/firefox/openpath.xpi`",`"private_browsing`":true}}"
                    Source = 'LocalGpo'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-ItemProperty {
                [PSCustomObject]@{ ExtensionSettings = '{"https://a.bromium.com/*":{"installation_mode":"blocked"}}' }
            } -ModuleName Browser.FirefoxPolicy

            Test-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse
        }

        It "Readiness goes to the owner branch when HKLM lacks our entry although the local GPO has it" {
            $id = $script:storeContract.extensionId
            $url = $script:storePolicy.InstallUrl
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{
                    Type = 'String'
                    Value = "{`"$id`":{`"installation_mode`":`"force_installed`",`"install_url`":`"$url`",`"private_browsing`":true}}"
                    Source = 'LocalGpo'
                }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-ItemProperty {
                [PSCustomObject]@{ ExtensionSettings = '{"https://a.bromium.com/*":{"installation_mode":"blocked"}}' }
            } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy { $script:storePolicy } -ModuleName Browser.FirefoxPolicy
            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathPolicyValueOwner {
                [PSCustomObject]@{ Owner = 'DomainGpo'; GpoName = 'Default Domain Policy'; Evidence = @() }
            } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady -Config ([PSCustomObject]@{})

            $result.Ready | Should -BeFalse
            $result.FailureCode | Should -Be 'firefox-machine-policy-externally-managed'
        }

        It "Builds valid JSON for the required entry when the install URL needs escaping" {
            $id = $script:storeContract.extensionId
            $script:storePolicy.InstallUrl = 'https://openpath.example.invalid/x?a="b"&c=\d'
            Mock Get-OpenPathFirefoxManagedExtensionPolicy { $script:storePolicy } -ModuleName Browser.FirefoxPolicy
            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $false } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathPolicyValueOwner {
                [PSCustomObject]@{ Owner = 'Mdm'; GpoName = $null; Evidence = @() }
            } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady -Config ([PSCustomObject]@{})

            $json = '{' + $result.Message.Substring($result.Message.IndexOf('"' + $id + '":')) + '}'
            ($json | ConvertFrom-Json).$id.install_url | Should -Be $script:storePolicy.InstallUrl
        }

        It "Remove keeps vendor entries" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"https://a.bromium.com/*`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $stored; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeRemoveCalls.Count | Should -Be 0
            $script:storeSetCalls.Count | Should -Be 1
            $script:storeSetCalls[0].Type | Should -Be 'String'
            $remaining = $script:storeSetCalls[0].Value | ConvertFrom-Json
            $remaining.PSObject.Properties.Name | Should -Be @('https://a.bromium.com/*')
        }

        It "Remove hands the vendor entries back to the registry only when the value was not in the local GPO before OpenPath" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"third@party`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'MultiString'; Value = [string[]]@($stored); Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeOriginal = [PSCustomObject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeSetCalls.Count | Should -Be 0
            $script:storeRemoveCalls.Count | Should -Be 1
            $script:storeRemoveCalls[0].DiscardOriginal | Should -BeTrue
            # Only the Registry.pol entry goes; the registry value is later overwritten in place, never deleted by OpenPath.
            $script:storeRemoveCalls[0].KeepRegistryValue | Should -BeTrue
            # The Registry CSE deletes a value it applied from Registry.pol once the pol entry is gone,
            # so the remainder is written only after a policy refresh has run that deletion.
            @($script:storeSequence) | Should -Be @('remove', 'refresh', 'registry-write')
            $script:refreshCalls[0].Force | Should -BeFalse
            $script:refreshCalls[0].TimeoutSeconds | Should -BeGreaterThan 0
            $script:registryOnlyWrites.Count | Should -Be 1
            $script:registryOnlyWrites[0].Path | Should -Be 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
            $script:registryOnlyWrites[0].Name | Should -Be 'ExtensionSettings'
            $script:registryOnlyWrites[0].PropertyType | Should -Be 'MultiString'
            $remaining = @($script:registryOnlyWrites[0].Value)[0] | ConvertFrom-Json
            @($remaining.PSObject.Properties.Name) | Should -Be @('third@party')
        }

        It "Recreates the Firefox policy key the refresh deleted before handing the remainder back" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"third@party`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'MultiString'; Value = [string[]]@($stored); Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeOriginal = [PSCustomObject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }
            Mock Invoke-OpenPathPolicyRefresh {
                $script:storeSequence.Add('refresh')
                # The CSE deleted the whole key because nothing else was left in it.
                $script:firefoxKeyExists = $false
                [PSCustomObject]@{ ExitCode = 0; DurationMs = 1234 }
            } -ModuleName Browser.FirefoxPolicy
            $script:ffLogs = New-Object System.Collections.Generic.List[string]
            Mock Write-OpenPathLog { param($Message, $Level) $script:ffLogs.Add("$Level|$Message") } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            @($script:storeSequence) | Should -Be @('remove', 'refresh', 'create-key', 'registry-write')
            $script:storeSetCalls.Count | Should -Be 0
            (@($script:registryOnlyWrites[0].Value)[0] | ConvertFrom-Json).PSObject.Properties.Name | Should -Be @('third@party')
            @($script:ffLogs | Where-Object { $_ -like 'INFO|*ExitCode=0*DurationMs=1234*' }).Count | Should -Be 1
        }

        It "Keeps the remainder in the local GPO when the registry hand-back write fails" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"third@party`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $stored; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeOriginal = [PSCustomObject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }
            Mock New-ItemProperty { throw "Cannot find path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' because it does not exist." } -ModuleName Browser.FirefoxPolicy
            $script:ffLogs = New-Object System.Collections.Generic.List[string]
            Mock Write-OpenPathLog { param($Message, $Level) $script:ffLogs.Add("$Level|$Message") } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeSetCalls.Count | Should -Be 1
            $script:storeSetCalls[0].ReleaseOriginal | Should -BeTrue
            $script:storeSetCalls[0].Type | Should -Be 'String'
            ($script:storeSetCalls[0].Value | ConvertFrom-Json).PSObject.Properties.Name | Should -Be @('third@party')
            @($script:ffLogs | Where-Object { $_ -like 'WARN|*keeping the remaining entries in the local GPO*' }).Count | Should -Be 1
        }

        It "Remove keeps the remainder in the local GPO and warns when the policy refresh before the hand-back fails" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"third@party`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'MultiString'; Value = [string[]]@($stored); Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeOriginal = [PSCustomObject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }
            $script:refreshExitCode = 1
            $script:ffLogs = New-Object System.Collections.Generic.List[string]
            Mock Write-OpenPathLog { param($Message, $Level) $script:ffLogs.Add("$Level|$Message") } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:registryOnlyWrites.Count | Should -Be 0
            $script:storeSetCalls.Count | Should -Be 1
            $script:storeSetCalls[0].ReleaseOriginal | Should -BeTrue
            $script:storeSetCalls[0].Type | Should -Be 'MultiString'
            (@($script:storeSetCalls[0].Value)[0] | ConvertFrom-Json).PSObject.Properties.Name | Should -Be @('third@party')
            @($script:ffLogs | Where-Object { $_ -like 'WARN|*refresh*' }).Count | Should -Be 1
        }

        It "Remove keeps the remainder in the local GPO when the policy refresh command is unavailable" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"third@party`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $stored; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeOriginal = [PSCustomObject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }
            Mock Get-Command { $null } -ModuleName Browser.FirefoxPolicy -ParameterFilter { $Name -eq 'Invoke-OpenPathPolicyRefresh' }

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:registryOnlyWrites.Count | Should -Be 0
            $script:storeSetCalls.Count | Should -Be 1
            $script:storeSetCalls[0].Type | Should -Be 'String'
            Should -Invoke Invoke-OpenPathPolicyRefresh -ModuleName Browser.FirefoxPolicy -Times 0 -Exactly
        }

        It "Remove keeps the remaining entries in the local GPO and releases the original when the vendor value was there first" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"https://a.bromium.com/*`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $stored; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeOriginal = [PSCustomObject]@{ InPol = $true; Type = [uint32]1; Data = [byte[]](1, 0) }

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeRemoveCalls.Count | Should -Be 0
            $script:registryOnlyWrites.Count | Should -Be 0
            $script:storeSetCalls.Count | Should -Be 1
            $script:storeSetCalls[0].ReleaseOriginal | Should -BeTrue
            $script:storeSetCalls[0].Type | Should -Be 'String'
            ($script:storeSetCalls[0].Value | ConvertFrom-Json).PSObject.Properties.Name | Should -Be @('https://a.bromium.com/*')
        }

        It "Remove without a recorded original keeps the remaining entries in the local GPO" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"a@x`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'MultiString'; Value = [string[]]@($stored); Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeRemoveCalls.Count | Should -Be 0
            $script:registryOnlyWrites.Count | Should -Be 0
            $script:storeSetCalls.Count | Should -Be 1
            $script:storeSetCalls[0].Type | Should -Be 'MultiString'
        }

        It "Remove returns false when the store cannot drop the value before the registry-only hand-back" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"third@party`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'MultiString'; Value = [string[]]@($stored); Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy
            $script:storeOriginal = [PSCustomObject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }
            Mock Remove-OpenPathManagedPolicyValue { [PSCustomObject]@{ Removed = $false; Restored = $false; FailureCode = 'local-gpo-busy' } } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse
            $script:registryOnlyWrites.Count | Should -Be 0
            Should -Invoke Invoke-OpenPathPolicyRefresh -ModuleName Browser.FirefoxPolicy -Times 0 -Exactly
        }

        It "Serializing, reading back and re-merging vendor entries is a fixed point" {
            $vendor = '{"https://a.bromium.com/*":{"installation_mode":"blocked","extra":{"nested":[1,"two",{"three":null}],"flag":false,"single":["only"],"empty":[]}},' +
                '"quote\"and\\backslash@vendor":{"installation_mode":"allowed","note":"<tag> & ''apos'' \u00e9\u4e2d \t tab"},' +
                '"unknown@vendor":{"future_property":{"deep":{"deeper":{"deepest":"x"}}},"number":1.5,"big":12345678901}}'
            $script:fixedPointValue = $vendor
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $script:fixedPointValue; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue
            $first = [string]$script:storeSetCalls[0].Value
            $script:fixedPointValue = $first
            Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue
            $second = [string]$script:storeSetCalls[1].Value

            $second | Should -BeExactly $first
            $parsed = $first | ConvertFrom-Json
            $parsed.'quote"and\backslash@vendor'.note | Should -Be "<tag> & 'apos' $([char]0x00e9)$([char]0x4e2d) `t tab"
            @($parsed.'https://a.bromium.com/*'.extra.single).Count | Should -Be 1
            $parsed.'unknown@vendor'.future_property.deep.deeper.deepest | Should -Be 'x'
        }

        It "Remove deletes value when only ours remained" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'MultiString'; Value = [string[]]@($stored); Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeTrue

            $script:storeSetCalls.Count | Should -Be 0
            $script:storeRemoveCalls.Count | Should -Be 1
            $script:storeRemoveCalls[0].Key | Should -Be 'Software\Policies\Mozilla\Firefox'
            $script:storeRemoveCalls[0].ValueName | Should -Be 'ExtensionSettings'
            $script:storeRemoveCalls[0].DiscardOriginal | Should -BeTrue
        }

        It "Remove does nothing when our entry is absent" {
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = '{"a@x":{"installation_mode":"blocked"}}'; Source = 'LocalGpo' }
            } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse

            $script:storeSetCalls.Count | Should -Be 0
            $script:storeRemoveCalls.Count | Should -Be 0
        }

        It "Remove returns false when a domain GPO owns the value" {
            $id = $script:storeContract.extensionId
            $stored = "{`"$id`":{`"installation_mode`":`"force_installed`"},`"a@x`":{`"installation_mode`":`"blocked`"}}"
            Mock Get-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Type = 'String'; Value = $stored; Source = 'Registry' }
            } -ModuleName Browser.FirefoxPolicy
            Mock Set-OpenPathManagedPolicyValue {
                [PSCustomObject]@{ Applied = $false; Changed = $false; Owner = 'DomainGpo'; GpoName = 'Default Domain Policy'; FailureCode = 'policy-externally-managed' }
            } -ModuleName Browser.FirefoxPolicy

            Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $script:storePolicy | Should -BeFalse
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

        It "Reports externally-managed for a domain GPO that owns ExtensionSettings" {
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
            Mock Get-OpenPathPolicyValueOwner {
                [PSCustomObject]@{ Owner = 'DomainGpo'; GpoName = 'Default Domain Policy'; Evidence = @('rsop') }
            } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady `
                -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' }) `
                -RequireRuntimeRegistration

            $result.Ready | Should -BeFalse
            $result.FailureCode | Should -Be 'firefox-machine-policy-externally-managed'
            $result.Message | Should -Match 'DomainGpo'
            $result.Message | Should -Match 'Default Domain Policy'
            $result.Message | Should -Match ([regex]::Escape($contract.extensionId))
            $result.Message | Should -Match ([regex]::Escape($contract.managedApiInstallUrl))
            $entryText = $result.Message.Substring($result.Message.IndexOf('"' + $contract.extensionId + '":'))
            $entryText = $entryText.Substring($contract.extensionId.Length + 4)
            ($entryText | ConvertFrom-Json).install_url | Should -Be $contract.managedApiInstallUrl
            $result.Message | Should -Match '"installation_mode":"force_installed"'
            $result.Message | Should -Match '"private_browsing":true'
            $result.ExtensionId | Should -Be $contract.extensionId
            $result.InstallUrl | Should -Be $contract.managedApiInstallUrl
        }

        It "Reports externally-managed for an MDM owner" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{ ExtensionId = $contract.extensionId; InstallUrl = $contract.managedApiInstallUrl; Source = 'managed-api' }
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $false } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathPolicyValueOwner {
                [PSCustomObject]@{ Owner = 'Mdm'; GpoName = $null; Evidence = @() }
            } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' })

            $result.FailureCode | Should -Be 'firefox-machine-policy-externally-managed'
            $result.Message | Should -Match 'Mdm'
        }

        It "Keeps machine-policy-missing with owner evidence for LocalGpo" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{ ExtensionId = $contract.extensionId; InstallUrl = $contract.managedApiInstallUrl; Source = 'managed-api' }
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $false } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathPolicyValueOwner {
                [PSCustomObject]@{ Owner = 'LocalGpo'; GpoName = $null; Evidence = @() }
            } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' })

            $result.Ready | Should -BeFalse
            $result.FailureCode | Should -Be 'firefox-machine-policy-missing'
            $result.Message | Should -Match 'owner=LocalGpo'
            $result.Message | Should -Match 'force_installed'
        }

        It "Keeps machine-policy-missing when the owner lookup fails" {
            $contract = Get-ContractFixtureJson -FileName 'browser-firefox-managed-extension.json'

            Mock Resolve-OpenPathFirefoxReleaseExecutable { 'C:\Program Files\Mozilla Firefox\firefox.exe' } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{ ExtensionId = $contract.extensionId; InstallUrl = $contract.managedApiInstallUrl; Source = 'managed-api' }
            } -ModuleName Browser.FirefoxPolicy
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $false } -ModuleName Browser.FirefoxPolicy
            Mock Get-OpenPathPolicyValueOwner { throw 'rsop unavailable' } -ModuleName Browser.FirefoxPolicy

            $result = Test-OpenPathFirefoxManagedExtensionReady -Config ([PSCustomObject]@{ apiUrl = 'https://school.example' })

            $result.FailureCode | Should -Be 'firefox-machine-policy-missing'
            $result.Message | Should -Match 'owner=Unknown'
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
