Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Installer" {
    Context "Phase pipeline" {
        BeforeAll {
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Plan.ps1")
        }

        It "Builds the installer plan in execution order while preserving public parameter inputs" {
            $inputParameters = @{
                WhitelistUrl = 'https://allow.example.test'
                SkipAcrylic = $true
                SkipPreflight = $true
                Classroom = 'math'
                ApiUrl = 'https://api.example.test'
                RegistrationToken = 'reg-secret'
                EnrollmentToken = ''
                ClassroomId = ''
                MachineName = 'student-01'
                FirefoxExtensionId = 'openpath@example'
                FirefoxExtensionInstallUrl = 'https://addons.example/openpath.xpi'
                ChromeExtensionStoreUrl = 'https://chrome.example/openpath'
                EdgeExtensionStoreUrl = 'https://edge.example/openpath'
                Unattended = $true
                HealthApiSecret = 'health-secret'
                EnforceManagedBrowserBoundary = $true
                ApprovedStudentBrowsers = @('Firefox')
                BrowserCleanupMode = 'ReportOnly'
                TimingOutputPath = 'C:\OpenPath\timing.json'
            }

            $plan = New-OpenPathInstallPlan -Parameters $inputParameters -OpenPathRoot 'C:\OpenPath' -ScriptDir 'C:\pkg\windows'

            $plan.Type | Should -Be 'OpenPathInstallPlan'
            @($plan.Phases.Name) | Should -Be @(
                'existing-install-cleanup',
                'preflight',
                'directories',
                'runtime',
                'configuration',
                'acrylic',
                'acrylic-configuration',
                'local-dns',
                'scheduled-tasks',
                'enrollment',
                'native-host',
                'first-update',
                'firefox-managed-extension-ready',
                'realtime-updates',
                'app-control',
                'browser-inventory',
                'integrity',
                'timing',
                'summary'
            )
            $plan.Context.OpenPathRoot | Should -Be 'C:\OpenPath'
            $plan.Context.ScriptDir | Should -Be 'C:\pkg\windows'
            $plan.Parameters.WhitelistUrl | Should -Be 'https://allow.example.test'
            $plan.Parameters.BrowserCleanupMode | Should -Be 'ReportOnly'
        }

        It "Returns structured success and failure results for installer phases" {
            $success = Invoke-OpenPathInstallPhase -Phase ([pscustomobject]@{
                    Name = 'configuration'
                    Step = 3
                    TotalSteps = 7
                    Status = 'Creando configuracion'
                    Inputs = @{ WhitelistUrl = 'https://allow.example.test'; RegistrationToken = 'secret-token' }
                    RecoveryHint = 'Check installer configuration inputs.'
                    Action = { param($Context) $Context.Value = 42 }
                }) -Context ([pscustomobject]@{ Value = 0 })

            $success.Type | Should -Be 'OpenPathInstallResult'
            $success.Name | Should -Be 'configuration'
            $success.Success | Should -BeTrue
            $success.Status | Should -Be 'success'
            $success.DurationMs | Should -BeGreaterOrEqual 0
            $success.Inputs.WhitelistUrl | Should -Be 'https://allow.example.test'
            $success.Inputs.RegistrationToken | Should -Be '<redacted>'
            $success.Error | Should -BeNullOrEmpty

            $failure = Invoke-OpenPathInstallPhase -Phase ([pscustomobject]@{
                    Name = 'enrollment'
                    Step = 9
                    TotalSteps = 7
                    Status = 'Registrando equipo'
                    Inputs = @{ EnrollmentToken = 'enroll-secret'; MachineName = 'student-01' }
                    RecoveryHint = 'Re-run enrollment after checking API URL and token.'
                    Action = { throw 'registration failed' }
                }) -Context ([pscustomobject]@{})

            $failure.Type | Should -Be 'OpenPathInstallResult'
            $failure.Name | Should -Be 'enrollment'
            $failure.Success | Should -BeFalse
            $failure.Status | Should -Be 'failed'
            $failure.Inputs.EnrollmentToken | Should -Be '<redacted>'
            $failure.Inputs.MachineName | Should -Be 'student-01'
            $failure.Error.Message | Should -BeLike '*registration failed*'
            $failure.Error.Category | Should -Not -BeNullOrEmpty
            $failure.RecoveryHint | Should -Be 'Re-run enrollment after checking API URL and token.'
        }

        It "Keeps Install-OpenPath public parameters compatible while using the phase pipeline helper" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[string]$WhitelistUrl = ""',
                '[switch]$SkipAcrylic',
                '[switch]$SkipPreflight',
                '[string]$Classroom = ""',
                '[string]$ApiUrl = ""',
                '[string]$RegistrationToken = ""',
                '[string]$EnrollmentToken = ""',
                '[string]$ClassroomId = ""',
                '[string]$MachineName = ""',
                '[string]$FirefoxExtensionId = ""',
                '[string]$FirefoxExtensionInstallUrl = ""',
                '[string]$ChromeExtensionStoreUrl = ""',
                '[string]$EdgeExtensionStoreUrl = ""',
                '[switch]$Unattended',
                '[string]$HealthApiSecret = ""',
                '[switch]$EnforceManagedBrowserBoundary',
                '[string[]]$ApprovedStudentBrowsers = @(''Firefox'')',
                '[string]$BrowserCleanupMode = ''ReportOnly''',
                '[string]$TimingOutputPath = ""',
                'Installer.Plan.ps1',
                'New-OpenPathInstallPlan',
                'Invoke-OpenPathInstallPhase'
            )
        }

        It "Executes representative installer phases through structured phase results" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $phaseNames = @(
                'configuration',
                'acrylic',
                'scheduled-tasks',
                'enrollment',
                'native-host',
                'first-update',
                'app-control',
                'browser-inventory',
                'integrity',
                'timing',
                'summary'
            )

            foreach ($phaseName in $phaseNames) {
                $content | Should -Match "Invoke-OpenPathPlanned(?:Warning)?Phase -Name '$phaseName'"
            }
        }
    }

    Context "ACL lockdown" {
        It "Sets restrictive file permissions during installation" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Set-OpenPathCapabilityStorageAcl -Path $OpenPathRoot -Profile RestrictedRoot',
                'CapabilityStorage.ps1'
            )
        }

        It "Grants local users read access to staged browser extension artifacts" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$browserExtensionAclPath = "$OpenPathRoot\browser-extension"',
                'Set-OpenPathCapabilityStorageAcl -Path $browserExtensionAclPath -Profile BrowserExtensionRead',
                'Read access granted for browser extension artifacts'
            )
        }

        It "Stages Firefox release assets beneath the user-readable browser-extension ACL root" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$browserExtensionAclPath = "$OpenPathRoot\browser-extension"',
                '$firefoxReleaseTarget = "$OpenPathRoot\browser-extension\firefox-release"',
                'Signed Firefox Release artifacts staged in $OpenPathRoot\browser-extension\firefox-release'
            )
        }

        It "Stages Chromium managed rollout metadata beneath the user-readable browser-extension ACL root" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$browserExtensionAclPath = "$OpenPathRoot\browser-extension"',
                '$chromiumManagedCandidates = @(',
                "firefox-extension\build\chromium-managed",
                '$chromiumManagedTarget = "$OpenPathRoot\browser-extension\chromium-managed"',
                'Chromium managed rollout metadata staged in $OpenPathRoot\browser-extension\chromium-managed'
            )
        }

        It "Stages Windows native host assets beneath the user-readable Firefox native directory" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.ArtifactCatalog.ps1"
            $content = Get-Content $scriptPath -Raw

            . $catalogPath
            $artifactNames = @(Get-OpenPathNativeHostArtifactNames)
            $artifactNames | Should -Contain 'OpenPath-NativeHost.ps1'
            $artifactNames | Should -Contain 'OpenPath-NativeHost.cmd'
            $artifactNames | Should -Contain 'NativeHost.Actions.ps1'

            $scriptRoot = Join-Path $TestDrive 'package\scripts'
            $libRoot = Join-Path $TestDrive 'package\lib'
            $internalRoot = Join-Path $libRoot 'internal'
            New-Item -ItemType Directory -Path $scriptRoot, $libRoot, $internalRoot -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $scriptRoot 'OpenPath-NativeHost.ps1') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $internalRoot 'NativeHost.Actions.ps1') -Force | Out-Null

            $candidateRoots = @(Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $scriptRoot)
            $resolution = Resolve-OpenPathNativeHostArtifactSources `
                -ArtifactNames @('OpenPath-NativeHost.ps1', 'NativeHost.Actions.ps1', 'missing.ps1') `
                -CandidateRoots $candidateRoots
            $resolution.Sources['OpenPath-NativeHost.ps1'] | Should -Be $scriptRoot
            $resolution.Sources['NativeHost.Actions.ps1'] | Should -Be $internalRoot
            @($resolution.Missing) | Should -Contain 'missing.ps1'

            Assert-ContentContainsAll -Content $content -Needles @(
                '$firefoxNativeHostTarget = "$OpenPathRoot\browser-extension\firefox\native"',
                'NativeHost.ArtifactCatalog.ps1',
                'Get-OpenPathNativeHostArtifactNames',
                'Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $nativeHostSourceRoot',
                'Resolve-OpenPathNativeHostArtifactSources -ArtifactNames $nativeHostArtifacts -CandidateRoots $nativeHostSourceRoots',
                'Firefox native host assets staged in $OpenPathRoot\browser-extension\firefox\native'
            )
        }

        It "Copies command wrappers into the installed scripts directory for later re-registration" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$requiredScriptFiles = @(',
                'Enroll-Machine.ps1',
                'Required installer script missing from bootstrap package',
                'Required installer script was not staged into OpenPath runtime',
                'Get-ChildItem "$ScriptDir\scripts\*.cmd" -ErrorAction SilentlyContinue',
                'Copy-Item -Destination "$OpenPathRoot\scripts\" -Force'
            )
        }

        It "Stages installer helpers so installed reinstall entrypoints remain runnable" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'New-Item -ItemType Directory -Path "$OpenPathRoot\lib\install" -Force',
                'Get-ChildItem "$ScriptDir\lib\install\*.ps1" -ErrorAction Stop',
                'Copy-Item -Destination "$OpenPathRoot\lib\install\" -Force',
                'Installer.Cleanup.ps1'
            )
        }

        It "Registers Firefox native messaging host in both 64-bit and WOW6432Node registry views" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $content = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Mozilla\NativeMessagingHosts\whitelist_native_host',
                'WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host',
                "allowed_extensions = @('openpath-block-monitor@openpath')",
                'name = Get-OpenPathFirefoxNativeHostName'
            )
        }

        It "Uses braced interpolation for SourceRoot error messages before a colon" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $content = Get-Content $nativeHostModulePath -Raw

            $content.Contains('Firefox native host artifacts not found in ${SourceRoot}:') | Should -BeTrue
            $content.Contains('Firefox native host artifacts not found in $SourceRoot:') | Should -BeFalse
        }

        It "Skips registry deletion when Firefox native host keys are already absent in the shared browser helpers" {
            $browserCommonModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.Common.psm1"
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $browserCommonContent = Get-Content $browserCommonModulePath -Raw
            $nativeHostContent = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $browserCommonContent -Needles @(
                'function ConvertTo-OpenPathRegistryProviderPath',
                'return "Registry::HKEY_LOCAL_MACHINE\\$($RegistryPath.Substring(5))"',
                'if ($RegistryPath -match ''^HKLM\\'')',
                'if (Test-Path $providerPath)'
            )
            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                'Remove-OpenPathRegistryKeyIfPresent -RegistryPath $registryPath'
            )
            $browserCommonContent.Contains('& reg.exe DELETE $registryPath /f 2>$null | Out-Null') | Should -BeFalse
        }

        It "Falls back to the staged native host directory during re-registration after self-update" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $content = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $SourceRoot -NativeRoot $nativeRoot',
                'Resolve-OpenPathNativeHostArtifactSources -ArtifactNames $artifactNames -CandidateRoots $candidateRoots',
                '[string]::Equals($sourcePath, $destinationPath, [System.StringComparison]::OrdinalIgnoreCase)'
            )
        }
    }

    Context "Source path validation" {
        It "Validates modules exist before copying" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Modules not found',
                'Test-Path "$scriptDir\lib\*.psm1"'
            )
        }
    }

    Context "Checkpoint defaults" {
        It "Configures checkpoint rollback defaults during install" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            $content = Get-Content $scriptPath -Raw
            $configHelper = Get-Content $configHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'New-OpenPathInstallerConfig',
                'Installer.Config.ps1'
            )
            Assert-ContentContainsAll -Content $configHelper -Needles @(
                'enableCheckpointRollback',
                'maxCheckpoints',
                'enableDohIpBlocking',
                'dohResolverIps',
                'vpnBlockRules',
                'torBlockPorts',
                'Get-DefaultDohResolverIps',
                'Get-DefaultVpnBlockRules',
                'Get-DefaultTorBlockPorts'
            )
        }
    }

    Context "Enrollment extraction" {
        It "Uses Enroll-Machine script for classroom registration" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"
            $enrollScriptPath = Join-Path $PSScriptRoot ".." "scripts" "Enroll-Machine.ps1"
            $content = Get-Content $scriptPath -Raw

            Test-Path $enrollScriptPath | Should -BeTrue
            Assert-ContentContainsAll -Content $content -Needles @(
                'Enroll-Machine.ps1',
                'SkipTokenValidation',
                'Machine registration completed'
            )
        }
    }

    Context "Enrollment argument forwarding" {
        It "Uses named parameter splatting for classroom registration" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$enrollParams = @{',
                '& $enrollScript @enrollParams'
            )
            $content.Contains('$enrollArgs = @(') | Should -BeFalse
            $content.Contains('& $enrollScript @enrollArgs') | Should -BeFalse
        }
    }

    Context "Unattended enrollment support" {
        It "Supports enrollment-token unattended parameters in installer" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[string]$EnrollmentToken = ""',
                '[string]$ClassroomId = ""',
                '[switch]$Unattended',
                '-EnrollmentToken',
                '-ClassroomId',
                '-Unattended'
            )
        }

        It "Supports optional Chromium store URLs for unmanaged browser installs" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            $content = Get-Content $scriptPath -Raw
            $configHelper = Get-Content $configHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[string]$ChromeExtensionStoreUrl = ""',
                '[string]$EdgeExtensionStoreUrl = ""',
                '-ChromeExtensionStoreUrl $ChromeExtensionStoreUrl',
                '-EdgeExtensionStoreUrl $EdgeExtensionStoreUrl'
            )

            Assert-ContentContainsAll -Content $configHelper -Needles @(
                '$config.chromeExtensionStoreUrl = $ChromeExtensionStoreUrl',
                '$config.edgeExtensionStoreUrl = $EdgeExtensionStoreUrl'
            )
        }

        It "Supports managed browser boundary and cleanup installer options" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            $content = Get-Content $scriptPath -Raw
            $configHelper = Get-Content $configHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[switch]$EnforceManagedBrowserBoundary',
                '[string[]]$ApprovedStudentBrowsers = @(''Firefox'')',
                "[ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]",
                '[string]$BrowserCleanupMode = ''ReportOnly''',
                '-EnforceManagedBrowserBoundary:$enforceManagedBrowserBoundary',
                '-ApprovedStudentBrowsers $ApprovedStudentBrowsers',
                '-BrowserCleanupMode $BrowserCleanupMode'
            )

            Assert-ContentContainsAll -Content $configHelper -Needles @(
                '[bool]$EnforceManagedBrowserBoundary = $false',
                '[string[]]$ApprovedStudentBrowsers = @(''Firefox'')',
                "[ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]",
                '[string]$BrowserCleanupMode = ''ReportOnly''',
                'enforceManagedBrowserBoundary = $EnforceManagedBrowserBoundary',
                'approvedStudentBrowsers = @($ApprovedStudentBrowsers)',
                'browserCleanupMode = $BrowserCleanupMode'
            )
        }

        It "Persists managed browser boundary and cleanup mode in installer config" {
            $firewallCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Catalog.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            . $firewallCatalogPath
            . $configHelperPath

            $config = New-OpenPathInstallerConfig `
                -WhitelistUrl '' `
                -AgentVersion 'test-version' `
                -PrimaryDNS '8.8.8.8' `
                -EnforceManagedBrowserBoundary:$true `
                -BrowserCleanupMode RemoveKnownInstallers

            $config.enforceManagedBrowserBoundary | Should -BeTrue
            @($config.approvedStudentBrowsers) | Should -Be @('Firefox')
            $config.browserCleanupMode | Should -Be 'RemoveKnownInstallers'
        }

        It "Defaults browser cleanup to report-only in installer config" {
            $firewallCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Catalog.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            . $firewallCatalogPath
            . $configHelperPath

            $config = New-OpenPathInstallerConfig `
                -WhitelistUrl '' `
                -AgentVersion 'test-version' `
                -PrimaryDNS '8.8.8.8'

            $config.browserCleanupMode | Should -Be 'ReportOnly'
            $config.enforceManagedBrowserBoundary | Should -BeFalse
        }

        It "Defaults classroom unattended installs to managed browser boundary enforcement" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$enforceManagedBrowserBoundary = [bool]$EnforceManagedBrowserBoundary',
                'if ($classroomModeRequested -and $Unattended -and -not $PSBoundParameters.ContainsKey(''EnforceManagedBrowserBoundary''))',
                '$enforceManagedBrowserBoundary = $true'
            )
        }
    }

    Context "Enrollment before first update" {
        It "Allows enrollment-mode config to start without a whitelist URL" {
            $firewallCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Catalog.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            . $firewallCatalogPath
            . $configHelperPath

            $config = New-OpenPathInstallerConfig `
                -WhitelistUrl '' `
                -AgentVersion 'test-version' `
                -PrimaryDNS '8.8.8.8' `
                -ApiBaseUrl 'https://api.example.test' `
                -ClassroomId 'cls_test'

            $config.whitelistUrl | Should -Be ''
            $config.apiUrl | Should -Be 'https://api.example.test'
            $config.classroomId | Should -Be 'cls_test'
        }

        It "Registers Firefox native host after enrollment produces complete request setup" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$nativeHostConfig = Get-OpenPathConfig',
                '$nativeHostRequestSetup = Get-OpenPathRequestSetupState -Config $nativeHostConfig',
                '$nativeHostRegistered = Register-OpenPathFirefoxNativeHost -Config $nativeHostConfig -ClearWhitelist',
                '$nativeHostRequestSetup.DiagnosticMessage',
                'No se pudo registrar el host nativo de Firefox tras enrollment'
            )

            $content | Should -Match 'try \{\s+Import-Module "\$OpenPathRoot\\lib\\RequestSetup\.State\.psm1" -Force -Global\s+\$nativeHostConfig = Get-OpenPathConfig'
        }

        It "Defers local DNS activation until remote bootstrap can write Acrylic hosts" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$deferLocalDnsUntilRemoteBootstrap = $classroomModeRequested -or [bool]$WhitelistUrl',
                'DNS local se activara tras descargar y aplicar la primera whitelist',
                'Set-LocalDNS',
                'Invoke-OpenPathInstallerFirstUpdate'
            )

            $content | Should -Match '(?s)if \(\$deferLocalDnsUntilRemoteBootstrap\).*?else \{\s+Set-LocalDNS'
            $content | Should -Match '(?s)Invoke-OpenPathInstallerFirstUpdate'
            $content | Should -Not -Match '(?s)Set-LocalDNS\s+Write-InstallerVerbose ''  DNS configurado a 127\.0\.0\.1''\s+Show-InstallerProgress -Step 6'
        }

        It "Fails unattended classroom installs when enrollment or native host registration is incomplete" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'if ($classroomModeRequested -and $Unattended -and $machineRegistered -ne ''REGISTERED'')',
                'ERROR: Classroom enrollment did not complete; domain requests will not be configured.',
                'if ($classroomModeRequested -and $Unattended -and (-not $nativeHostRegistered -or -not $nativeHostRequestSetup -or -not $nativeHostRequestSetup.Ready))',
                'ERROR: Firefox native host registration incomplete; domain requests will not be configured.',
                'exit 1'
            )
        }

        It "Fails all ClassroomPath installs when Firefox managed extension runtime is not active" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $browserModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.psm1"
            $content = Get-Content $scriptPath -Raw
            $browserModule = Get-Content $browserModulePath -Raw

            $content | Should -Match 'if \(\$classroomModeRequested\)'
            $content | Should -Match 'Test-OpenPathFirefoxManagedExtensionReady -Config \$firefoxReadyConfig -RequireRuntimeRegistration'
            $content | Should -Not -Match 'if \(\$classroomModeRequested -and \$Unattended\)\s*\{\s*\$firefoxReady = Test-OpenPathFirefoxManagedExtensionReady'

            Assert-ContentContainsAll -Content $content -Needles @(
                'Test-OpenPathFirefoxManagedExtensionReady -Config $firefoxReadyConfig -RequireRuntimeRegistration',
                'ERROR: Firefox managed extension is not active after installation.',
                '$firefoxReady.FailureCode',
                '$firefoxReady.Message',
                'exit 1'
            )

            $content | Should -Match '(?s)Invoke-OpenPathInstallerFirstUpdate.*Test-OpenPathFirefoxManagedExtensionReady'
            $browserModule | Should -Match 'function Test-OpenPathFirefoxManagedExtensionReady'
        }

        It "Restores installer config after first-update rollback before Firefox readiness" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Restore-OpenPathInstallerConfigIfMissing',
                '-Config $config',
                '$firefoxReadyConfig = Get-OpenPathConfig'
            )

            $content | Should -Match '(?s)Invoke-OpenPathInstallerFirstUpdate.*Restore-OpenPathInstallerConfigIfMissing.*\$firefoxReadyConfig = Get-OpenPathConfig'
        }

        It "Exits successfully after writing the installer summary" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match 'Write-OpenPathInstallerSummary[\s\S]*exit 0'
        }

        It "Skips first update when classroom registration fails" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Invoke-OpenPathInstallerFirstUpdate',
                'Installer.Runtime.ps1'
            )

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                'Registro no completado; se omite primera actualizacion',
                '$ClassroomModeRequested -and $MachineRegistered -ne ''REGISTERED'''
            )
        }

        It "Fails closed when browser policy spec is missing from installer runtime" {
            $stagingHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $stagingHelper = Get-Content $stagingHelperPath -Raw

            Assert-ContentContainsAll -Content $stagingHelper -Needles @(
                '$browserPolicySpecInstalled = $false',
                '$browserPolicySpecInstalled = $true',
                'Browser policy spec not found in installer runtime'
            )

            $stagingHelper | Should -Match '(?s)foreach \(\$browserPolicySpecSource in \$browserPolicySpecCandidates\).*?\$browserPolicySpecInstalled = \$true.*?if \(-not \$browserPolicySpecInstalled\).*?throw'
        }

        It "Allows optional summary fields to be empty" {
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                '[string]$Classroom = ''''',
                '[string]$ClassroomId = ''''',
                '[string]$WhitelistUrl = '''''
            )

            $runtimeHelper | Should -Not -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[string\]\$Classroom\s*,'
            $runtimeHelper | Should -Not -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[string\]\$ClassroomId\s*,'
            $runtimeHelper | Should -Not -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[string\]\$WhitelistUrl\s*,'
        }

        It "Warns when classroom installs finish without enrollment" {
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                '$ClassroomModeRequested -and $MachineRegistered -ne ''REGISTERED''',
                'Solicitudes de dominio: NO CONFIGURADAS',
                'ejecuta .\OpenPath.ps1 enroll'
            )
        }
    }

    Context "Operational script installation" {
        It "Copies OpenPath.ps1 and Rotate-Token.ps1 into install root" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.Contains("'OpenPath.ps1', 'Rotate-Token.ps1'") | Should -BeTrue
        }

        It "Stages internal PowerShell helpers alongside lib modules" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$OpenPathRoot\lib\internal',
                'Get-ChildItem "$ScriptDir\lib\internal\*.ps1"',
                'Destination "$OpenPathRoot\lib\internal\"'
            )
        }

        It "Stages Chromium unmanaged browser install guidance when store URLs are configured" {
            $guidanceHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"
            $content = Get-Content $guidanceHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$OpenPathRoot\browser-extension\chromium-unmanaged',
                '[InternetShortcut]',
                'Install OpenPath for Google Chrome.url',
                'Install OpenPath for Microsoft Edge.url'
            )
        }

        It "Opens unmanaged Chromium store guidance only during interactive installs" {
            $guidanceHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"
            $content = Get-Content $guidanceHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'if (-not $Unattended)',
                'Start-Process -FilePath $browserTarget.ExecutablePath -ArgumentList $browserTarget.StoreUrl',
                'Chromium store guidance staged for unattended install'
            )
        }
    }

    Context "Pre-install validation integration" {
        It "Runs pre-install validation by default and supports SkipPreflight" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'SkipPreflight',
                'scripts\Pre-Install-Validation.ps1',
                'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
            )
            $content.Contains('tests\Pre-Install-Validation.ps1') | Should -BeFalse
        }

        It "Uses SkipPreflight in Windows CI harnesses that install inside constrained runner environments" {
            $windowsE2EPath = Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "run-windows-e2e.ps1"
            $windowsStudentPath = Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "run-windows-student-flow.ps1"
            $windowsE2EContent = Get-Content $windowsE2EPath -Raw
            $windowsStudentContent = Get-Content $windowsStudentPath -Raw

            $windowsE2EContent | Should -Match '(?s)Install-OpenPath\.ps1.*?-SkipPreflight.*?-Unattended'
            $windowsStudentContent | Should -Match '(?s)Install-OpenPath\.ps1.*?-SkipPreflight.*?-Unattended'
        }
    }

    Context "Quiet progress output" {
        It "Uses PowerShell verbose semantics and progress helpers for installer output" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $guidanceHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"
            $progressHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Progress.ps1"
            $guidanceHelper = Get-Content $guidanceHelperPath -Raw
            $progressHelper = Get-Content $progressHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[CmdletBinding(SupportsShouldProcess)]',
                'Invoke-OpenPathPlannedPhase -Name ''directories''',
                'Installer.Progress.ps1',
                "Installer.Plan.ps1",
                "Installer.ChromiumGuidance.ps1"
            )

            Assert-ContentContainsAll -Content $progressHelper -Needles @(
                'function Show-InstallerProgress',
                'Write-Progress -Activity ''Installing OpenPath''',
                'function Write-InstallerVerbose',
                'Write-Verbose $Message'
            )

            Assert-ContentContainsAll -Content $guidanceHelper -Needles @(
                'function Get-OpenPathChromiumBrowserTargets',
                'function Install-OpenPathChromiumUnmanagedGuidance'
            )
        }

        It "Does not emit empty verbose installer messages during classroom enrollment" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.Contains('Write-InstallerVerbose ""') | Should -BeFalse
        }

        It "Keeps redirected progress silent and centralizes installer output levels" {
            $progressHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Progress.ps1"
            $progressHelper = Get-Content $progressHelperPath -Raw

            Assert-ContentContainsAll -Content $progressHelper -Needles @(
                'function Write-InstallerError',
                'function Write-InstallerWarning',
                'function Write-InstallerNotice',
                "if (`$VerbosePreference -ne 'Continue') { return }",
                'Write-Progress -Activity ''Installing OpenPath'''
            )

            $progressHelper.Contains('Write-Host "Progress ${Step}/${Total}: $Status"') | Should -BeFalse
        }

        It "Suppresses non-error installer output by default" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$script:OpenPathInstallerQuietMode = $VerbosePreference -ne ''Continue''',
                '$WarningPreference = ''SilentlyContinue''',
                '$InformationPreference = ''SilentlyContinue''',
                '$env:OPENPATH_QUIET_INSTALL = ''1'''
            )
            $content | Should -Not -Match '\$ProgressPreference\s*=\s*''SilentlyContinue'''

            $content | Should -Match '(?s)if \(\$VerbosePreference -eq ''Continue''\).*?OpenPath DNS para Windows - Instalador'
            $content | Should -Not -Match 'else \{\s+Write-InstallerNotice ''Installing OpenPath DNS for Windows\.\.\.''\s+\}'
        }

        It "Keeps the PowerShell progress bar available in normal installer runs" {
            $progressHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Progress.ps1"
            $progressHelper = Get-Content $progressHelperPath -Raw
            $showProgressFunction = [regex]::Match(
                $progressHelper,
                '(?s)function Show-InstallerProgress \{.*?\n\}'
            ).Value

            $showProgressFunction | Should -Match "Write-Progress -Activity 'Installing OpenPath'"
            $showProgressFunction | Should -Not -Match "if \(\`$VerbosePreference -ne 'Continue'\)"
            $showProgressFunction | Should -Not -Match "(?s)if \(\`$VerbosePreference -eq 'Continue'\) \{[^}]*return"
        }

        It "Keeps enrollment script host output quiet during normal installer enrollment" {
            $enrollmentHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"
            $enrollScriptPath = Join-Path $PSScriptRoot ".." "scripts" "Enroll-Machine.ps1"
            $enrollmentHelper = Get-Content $enrollmentHelperPath -Raw
            $enrollScript = Get-Content $enrollScriptPath -Raw

            Assert-ContentContainsAll -Content $enrollmentHelper -Needles @(
                'if ($VerbosePreference -ne ''Continue'') {',
                '$enrollParams.Quiet = $true'
            )

            Assert-ContentContainsAll -Content $enrollScript -Needles @(
                '[switch]$Quiet',
                'function Write-EnrollmentNotice',
                'if ($Quiet) { return }'
            )

            $enrollScript | Should -Not -Match '(?m)^\s*Write-Host\s+'
        }

        It "Suppresses non-error module logs during quiet installer runs" {
            $commonSystemPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.System.ps1"
            $commonSystem = Get-Content $commonSystemPath -Raw

            $commonSystem | Should -Match 'if \(\$env:OPENPATH_QUIET_INSTALL -eq ''1'' -and \$Level -ne "ERROR"\)'
            $commonSystem | Should -Match 'return'
        }

        It "Downloads Acrylic without curl progress in quiet installer runs" {
            $acrylicInstallPath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1"
            $acrylicInstall = Get-Content $acrylicInstallPath -Raw

            $acrylicInstall | Should -Match '& \$curl\.Source -fL -sS --retry 3 --retry-delay 2'
        }

        It "Routes non-fatal installer messages through warning or verbose-only helpers" {
            $installHelperPaths = @(
                (Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1")
            )

            foreach ($helperPath in $installHelperPaths) {
                $content = Get-Content $helperPath -Raw
                $content | Should -Not -Match 'Write-Host\s+[''"][^''"]*ADVERTENCIA:'
                $content | Should -Not -Match "Write-Warning\s+"
            }
        }

        It "Supports WhatIf and distinguishes browser cleanup from enforcement" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[CmdletBinding(SupportsShouldProcess)]',
                'Browser cleanup is hygiene. Application allowlist is the enforcement boundary.',
                '$PSCmdlet.ShouldProcess(''OpenPath install root'', ''Create install directories'')',
                '-WhatIf:$WhatIfPreference',
                '$WhatIfPreference'
            )
        }
    }

    Context "Primary DNS detection" {
        It "Uses an installer helper instead of indexing directly into adapter DNS arrays" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $dnsHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Dns.ps1"
            $dnsHelper = Get-Content $dnsHelperPath -Raw

            $content.Contains('Installer.Dns.ps1') | Should -BeTrue
            $content.Contains('$primaryDNS = Get-InstallerPrimaryDNS') | Should -BeTrue
            $content.Contains('Select-Object -First 1).ServerAddresses[0]') | Should -BeFalse
            $dnsHelper.Contains('function Get-InstallerPrimaryDNS') | Should -BeTrue
        }
    }

    Context "DNS probe guidance" {
        It "Derives the suggested nslookup domain from the shared probe list" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Write-OpenPathInstallerSummary',
                'Installer.Runtime.ps1'
            )
            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                'Get-OpenPathDnsProbeDomains',
                'nslookup $dnsProbeDomain 127.0.0.1'
            )
            $content.Contains('Test-DNSResolution -Domain "google.com"') | Should -BeFalse
            $content.Contains('nslookup google.com 127.0.0.1') | Should -BeFalse
        }

        It "Does not fail the installer summary when the firewall helper is unavailable" {
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"

            function Test-AcrylicInstalled { return $true }
            function Test-DNSResolution { return $true }
            function Get-ScheduledTask { return @() }
            Remove-Item function:\Test-FirewallActive -ErrorAction SilentlyContinue

            . $runtimeHelperPath

            { Get-OpenPathInstallerChecks } | Should -Not -Throw
            $checks = @(Get-OpenPathInstallerChecks)
            ($checks | Where-Object { $_.Name -eq 'Firewall' }).Status | Should -Be 'WARN'
        }

        It "Imports runtime modules globally for dot-sourced installer helpers" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\Firewall.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\AppControl.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\DNS.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\Services.psm1" -Force -Global'
            )
        }

        It "Loads the installer cleanup helper before install steps can mutate an existing runtime" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                ". (Join-Path `$installerHelperRoot 'Installer.Cleanup.ps1')",
                'Copy-OpenPathInstallerSourceForReinstall',
                'Invoke-OpenPathInstallerExistingInstallCleanup',
                '-KeepAcrylic',
                '-KeepLogs'
            )

            $snapshotIndex = $content.IndexOf('Copy-OpenPathInstallerSourceForReinstall')
            $cleanupIndex = $content.IndexOf('Invoke-OpenPathInstallerExistingInstallCleanup')
            $directoryIndex = $content.IndexOf('Initialize-OpenPathInstallDirectories')
            $copyIndex = $content.IndexOf('Copy-OpenPathInstallerRuntime')

            $snapshotIndex | Should -BeGreaterThan -1
            $cleanupIndex | Should -BeGreaterThan -1
            $snapshotIndex | Should -BeLessThan $cleanupIndex
            $cleanupIndex | Should -BeLessThan $directoryIndex
            $cleanupIndex | Should -BeLessThan $copyIndex
        }

        It "Skips blank preflight validation lines before reporting installer errors" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match '\$validationOutput\s*\|\s*Where-Object\s*\{\s*-not\s*\[string\]::IsNullOrWhiteSpace\(\$_\)\s*\}\s*\|\s*ForEach-Object\s*\{\s*Write-InstallerError\s+"\$_"\s*\}'
        }

        It "Defines reinstall cleanup as full OpenPath removal while preserving Acrylic and logs" {
            $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
            Test-Path $cleanupHelperPath | Should -BeTrue
            $cleanupHelper = Get-Content $cleanupHelperPath -Raw

            Assert-ContentContainsAll -Content $cleanupHelper -Needles @(
                'function Test-OpenPathExistingInstallation',
                'function Copy-OpenPathInstallerSourceForReinstall',
                'function Invoke-OpenPathInstallerExistingInstallCleanup',
                '[switch]$KeepAcrylic',
                '[switch]$KeepLogs',
                'openpath-reinstall-source-',
                'browser-policy-spec.json',
                'Stop-OpenPathInstallerScheduledTasks',
                'Remove-OpenPathInstallerAppLockerRules',
                'Remove-OpenPathInstallerFirewallRules',
                'Restore-OpenPathInstallerDnsSettings',
                'Remove-OpenPathInstallerBrowserArtifacts',
                'Remove-OpenPathInstallerInstallRoot -KeepLogs:$KeepLogs'
            )
            $cleanupHelper | Should -Not -Match '/UNINSTALL'
            $cleanupHelper | Should -Not -Match 'Remove-Item.*Acrylic DNS Proxy'
        }

        It "Reads installer config values from the hashtable returned by the config helper" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Get-OpenPathInstallerConfigValue',
                '$Config -is [hashtable]',
                '$Config.ContainsKey($PropertyName)',
                '$enableNonAdminAppControl = [bool](Get-OpenPathInstallerConfigValue',
                "-PropertyName 'enableNonAdminAppControl' -DefaultValue `$true",
                "-PropertyName 'nonAdminAppControlMode' -DefaultValue 'Enforced'"
            )
        }

        It "Removes stale OpenPath AppLocker rules when managed browser boundary is disabled" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match '(?s)if \(\$enableNonAdminAppControl\).*?Set-OpenPathNonAdminAppControl.*?else \{.*?Remove-OpenPathNonAdminAppControl -Confirm:\$false.*?Managed browser boundary disabled; AppLocker boundary not applied'
        }
    }

    Context "SSE bootstrap" {
        It "Starts the SSE listener only after enrollment and first update can provide request config" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Register-OpenPathTask -UpdateIntervalMinutes 15 -WatchdogIntervalMinutes 1',
                'Invoke-OpenPathInstallerFirstUpdate',
                'Start-OpenPathInstallerRealtimeUpdates'
            )

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                'function Start-OpenPathInstallerRealtimeUpdates',
                'Get-OpenPathBrowserRequestReadiness',
                'Start-OpenPathTask -TaskType SSE'
            )

            $content | Should -Match '(?s)Invoke-OpenPathInstallerFirstUpdate.*Start-OpenPathInstallerRealtimeUpdates'
            $content | Should -Not -Match '(?s)Register-OpenPathTask -UpdateIntervalMinutes 15 -WatchdogIntervalMinutes 1.*Start-OpenPathTask -TaskType SSE.*Invoke-OpenPathInstallerEnrollment'
        }
    }

    Context "Update browser policy config handoff" {
        It "Passes the already loaded update config into browser policy application" {
            $applyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $browserPath = Join-Path $PSScriptRoot ".." "lib" "Browser.psm1"
            $reconcilerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointStateReconciler.ps1"
            $applyContent = Get-Content $applyPath -Raw
            $browserContent = Get-Content $browserPath -Raw
            $reconcilerContent = Get-Content $reconcilerPath -Raw

            Assert-ContentContainsAll -Content $applyContent -Needles @(
                'Invoke-OpenPathEndpointStateRepairPlan `',
                '-Config $Config `',
                '-BlockedPaths $Whitelist.BlockedPaths'
            )
            Assert-ContentContainsAll -Content $reconcilerContent -Needles @(
                'Set-AllBrowserPolicy -BlockedPaths $BlockedPaths -Config $Config'
            )
            Assert-ContentContainsAll -Content $browserContent -Needles @(
                'function Set-AllBrowserPolicy',
                'Sync-OpenPathFirefoxManagedExtensionPolicy -Config $Config',
                'Set-ChromePolicy -BlockedPaths $BlockedPaths -Config $Config'
            )
        }
    }
}

Describe "Uninstaller" {
    Context "Running task cleanup" {
        It "Stops scheduled tasks and OpenPath-rooted processes before removing installed files" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Stop-ScheduledTask -TaskName $task.TaskName',
                'Stop-OpenPathRootedProcess',
                '$_.Path.StartsWith($OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)',
                '$_.CommandLine -like "*$OpenPathRoot*"',
                'Remove-OpenPathInstallRoot'
            )
        }
    }

    Context "Firefox native host cleanup" {
        It "Removes Firefox native messaging registry entries and staged host artifacts" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Mozilla\NativeMessagingHosts\whitelist_native_host',
                'WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host',
                'OpenPath-NativeHost.ps1',
                'OpenPath-NativeHost.cmd',
                'NativeHost.State.ps1',
                'NativeHost.Protocol.ps1',
                'NativeHost.Actions.ps1'
            )
        }

        It "Skips registry deletion when Firefox native host keys are already absent" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Convert-ToRegistryProviderPath',
                'return "Registry::HKEY_LOCAL_MACHINE\\$($RegistryPath.Substring(5))"',
                'if ($RegistryPath -match ''^HKLM\\'')',
                'if (Test-Path $providerPath)',
                'Remove-Item -Path $providerPath -Recurse -Force -ErrorAction SilentlyContinue'
            )
            $content.Contains('& reg.exe DELETE $registryPath /f 2>$null | Out-Null') | Should -BeFalse
        }
    }
}
