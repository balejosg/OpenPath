# OpenPath Windows browser diagnostics tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.psm1" -Force -Global -ErrorAction Stop
Import-Module "$modulePath\Browser.Diagnostics.psm1" -Force -Global -ErrorAction Stop

Describe "Browser Module - Diagnostics" {
    BeforeAll {
        $browserModulePath = Join-Path (Join-Path $PSScriptRoot ".." "lib") "Browser.psm1"
        $browserDiagnosticsPath = Join-Path (Join-Path $PSScriptRoot ".." "lib") "Browser.Diagnostics.psm1"
        Import-Module $browserModulePath -Force -Global -ErrorAction Stop
        Import-Module $browserDiagnosticsPath -Force -Global -ErrorAction Stop
    }

    Context "Browser doctor" {
        It "Exports browser doctor report and evidence helpers" {
            Get-Command -Name Get-OpenPathBrowserDoctorReport -ErrorAction Stop | Should -Not -BeNullOrEmpty
            Get-Command -Name Get-OpenPathBrowserDoctorEvidence -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }

        It "OpenPath.ps1 routes doctor browser to the browser report" {
            $scriptPath = Join-Path $PSScriptRoot ".." "OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                "Write-Host '  doctor        Print focused diagnostics (for example: browser)'",
                "Write-Host '  .\OpenPath.ps1 doctor browser'",
                "'doctor' {",
                "'browser' {",
                'Get-OpenPathBrowserDoctorReport'
            )
        }

        It "Collects Firefox native host and request readiness facts as structured evidence" {
            $nativeHostStatePath = Join-Path $TestDrive "native-host-state.json"
            Set-Content -Path $nativeHostStatePath -Value '{"apiUrl":"https://school.example","whitelistUrl":"https://school.example/w/token/whitelist.txt"}'
            $global:OpenPathDoctorExistingPaths = @($nativeHostStatePath)

            $requestSetupState = [PSCustomObject]@{
                Ready = $true
                ApiUrlConfigured = $true
                WhitelistTokenConfigured = $true
            }
            $script:capturedReadinessConfig = $null

            Mock Get-OpenPathBrowserInventory {
                [PSCustomObject]@{
                    ApprovedBrowsers = @([PSCustomObject]@{ Name = "Mozilla Firefox" })
                    UnmanagedBrowsers = @()
                    PortableBrowserRisks = @()
                    WebRenderingSurfaces = @([PSCustomObject]@{ DisplayName = "Microsoft Edge WebView2" })
                }
            } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxReleaseMetadataPath { Join-Path $TestDrive "metadata.json" } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxReleaseXpiPath { Join-Path $TestDrive "openpath.xpi" } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeHostManifestPath { Join-Path $TestDrive "manifest.json" } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeHostWrapperPath { Join-Path $TestDrive "wrapper.cmd" } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeHostScriptPath { Join-Path $TestDrive "native-host.ps1" } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeHostRoot { $TestDrive } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeStatePath { $nativeHostStatePath } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeWhitelistMirrorPath { Join-Path $TestDrive "whitelist.txt" } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeHostUpdateTaskName { "OpenPathFirefoxNativeHostUpdate" } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxNativeHostRegistryPaths { @("HKLM:\SOFTWARE\OpenPath\TestNativeHost") } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathBrowserDoctorScheduledTaskDiagnostic {
                [PSCustomObject]@{ Present = $true; UserAccess = "granted"; Status = "ok" }
            } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxManagedExtensionPolicy {
                [PSCustomObject]@{
                    ExtensionId = "monitor-bloqueos@openpath"
                    InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                }
            } -ModuleName Browser.Diagnostics
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $true } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathFirefoxMachineExtensionSettings {
                @{
                    "monitor-bloqueos@openpath" = [PSCustomObject]@{
                        install_url = "https://school.example/api/extensions/firefox/openpath.xpi"
                    }
                }
            } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathRequestSetupState { $requestSetupState } -ModuleName Browser.Diagnostics
            Mock Get-OpenPathBrowserRequestReadiness {
                param(
                    [object]$Config,
                    [object]$ManagedExtensionPolicy,
                    [object]$NativeHostRegistered,
                    [object]$NativeHostStatePresent,
                    [object]$FirefoxMachinePolicyApplied
                )

                $script:capturedReadinessConfig = $Config
                [PSCustomObject]@{
                    Ready = $true
                    Facts = [PSCustomObject]@{
                        request_setup = "ready"
                        firefox_managed_extension = "ready"
                        firefox_machine_policy = "ready"
                        firefox_native_host = "missing"
                    }
                    FailureReasons = @()
                }
            } -ModuleName Browser.Diagnostics
            Mock Test-Path { $global:OpenPathDoctorExistingPaths -contains [string]$Path } -ModuleName Browser.Diagnostics

            try {
                $evidence = Get-OpenPathBrowserDoctorEvidence
            }
            finally {
                Remove-Variable -Name OpenPathDoctorExistingPaths -Scope Global -ErrorAction SilentlyContinue
            }

            [object]::ReferenceEquals($script:capturedReadinessConfig, $requestSetupState) | Should -BeTrue
            $evidence.NativeHost.RequestSetup.Ready | Should -BeTrue
            $evidence.NativeHost.RequestSetup.ApiUrlConfigured | Should -BeTrue
            $evidence.NativeHost.RequestSetup.WhitelistTokenConfigured | Should -BeTrue
            $evidence.BrowserRequestReadiness.Ready | Should -BeTrue
            $evidence.BrowserRequestReadiness.Facts.firefox_machine_policy | Should -Be "ready"
            $evidence.BrowserRequestReadiness.FactSummary | Should -Be "request_setup=ready; firefox_managed_extension=ready; firefox_machine_policy=ready; firefox_native_host=missing"
            $evidence.BrowserInventory.ApprovedBrowserSummary | Should -Be "Mozilla Firefox"
            $evidence.BrowserInventory.WebRenderingSurfaceSummary | Should -Be "Microsoft Edge WebView2"
        }

        It "Renders structured evidence with existing operator-facing labels" {
            Mock Get-OpenPathBrowserDoctorEvidence {
                [PSCustomObject]@{
                    BrowserInventory = [PSCustomObject]@{
                        ApprovedBrowserSummary = "Mozilla Firefox"
                        UnmanagedBrowserSummary = "Brave (C:\Tools\brave.exe)"
                        PortableBrowserRiskSummary = "C:\Users\student\Downloads\browser.exe"
                        WebRenderingSurfaceSummary = "Microsoft Edge WebView2 Runtime"
                    }
                    Firefox = [PSCustomObject]@{
                        MetadataPath = "C:\OpenPath\browser-extension\firefox\metadata.json"
                        MetadataPresent = $true
                        MetadataParseResult = "ok"
                        ExtensionId = "monitor-bloqueos@openpath"
                        ExtensionVersion = "1.2.3"
                        MetadataSha256 = "metadata-sha"
                        XpiPath = "C:\OpenPath\browser-extension\firefox\openpath.xpi"
                        XpiPresent = $true
                        XpiBytes = 12345
                        XpiSha256 = "xpi-sha"
                        XpiAclSummary = "BUILTIN\Users:Read:Allow"
                        ResolvedInstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                    }
                    NativeHost = [PSCustomObject]@{
                        ManifestPath = "C:\OpenPath\native-host\manifest.json"
                        ManifestParse = "ok"
                        ManifestName = "openpath"
                        AllowedExtensions = "monitor-bloqueos@openpath"
                        RegistryPath = "HKLM:\Software\Mozilla\NativeMessagingHosts\openpath"
                        RegistrySummary = "HKLM:\Software\Mozilla\NativeMessagingHosts\openpath=present"
                        WrapperPath = "C:\OpenPath\native-host\openpath.cmd"
                        WrapperPresent = $true
                        ScriptPath = "C:\OpenPath\native-host\openpath.ps1"
                        ScriptPresent = $true
                        StateHelperReadable = $true
                        ProtocolHelperReadable = $true
                        ActionsHelperReadable = $true
                        StatePath = "C:\ProgramData\OpenPath\native-host-state.json"
                        StateReadable = $true
                        WhitelistReadable = $true
                        RequestSetup = [PSCustomObject]@{
                            ApiUrlConfigured = $true
                            WhitelistTokenConfigured = $true
                            Ready = $true
                        }
                        UpdateTaskName = "OpenPathFirefoxNativeHostUpdate"
                        UpdateTaskCheck = "ok"
                        UpdateTaskPresent = $true
                        UpdateTaskUserAccess = "granted"
                    }
                    BrowserRequestReadiness = [PSCustomObject]@{
                        Ready = $true
                        FactSummary = "request_setup=ready; firefox_managed_extension=ready; firefox_machine_policy=ready; firefox_native_host=ready"
                        FailureSummary = "(none)"
                    }
                    MachineFirefoxPolicy = [PSCustomObject]@{
                        Status = "ready"
                        InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                    }
                    Policy = [PSCustomObject]@{
                        Path = "C:\Program Files\Mozilla Firefox\distribution\policies.json"
                        Present = $true
                        Encoding = "utf8-no-bom"
                        JsonParse = "ok"
                        InstallMode = "force_installed"
                        InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                    }
                }
            } -ModuleName Browser.Diagnostics

            $report = Browser.Diagnostics\Get-OpenPathBrowserDoctorReport

            $report | Should -Match "OpenPath Browser Doctor"
            $report | Should -Match "Firefox metadata path: C:\\OpenPath\\browser-extension\\firefox\\metadata.json"
            $report | Should -Match "Firefox XPI ACL summary: BUILTIN\\Users:Read:Allow"
            $report | Should -Match "Native host request setup complete: True"
            $report | Should -Match "Browser request readiness facts: request_setup=ready; firefox_managed_extension=ready; firefox_machine_policy=ready; firefox_native_host=ready"
            $report | Should -Match "Approved managed browsers: Mozilla Firefox"
            $report | Should -Match "Unmanaged browsers detected: Brave"
            $report | Should -Match "Resolved install_url: https://school.example/api/extensions/firefox/openpath.xpi"
            $report | Should -Match "Machine Firefox policy: ready"
            $report | Should -Match "Policy JSON parse: ok"
        }

        It "Bounds scheduled task diagnostics so browser doctor cannot hang indefinitely" {
            $command = Get-Command -Name Get-OpenPathBrowserDoctorScheduledTaskDiagnostic -ErrorAction Stop
            $command.Parameters.Keys | Should -Contain "TimeoutMilliseconds"

            $result = Get-OpenPathBrowserDoctorScheduledTaskDiagnostic -TaskName "OpenPathUnitTestMissingTask" -TimeoutMilliseconds 1
            $result.Present | Should -BeFalse
            $result.Status | Should -Not -BeNullOrEmpty
        }

        It "Exposes the Browser module doctor facade" {
            (Get-Module Browser).ExportedFunctions.Keys | Should -Contain "Get-OpenPathBrowserDoctorReport"
        }
    }
}
