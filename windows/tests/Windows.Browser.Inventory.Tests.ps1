# OpenPath Windows browser inventory tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"

Describe "Browser Module - Inventory" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        $inventoryModulePath = Join-Path $modulePath "Browser.Inventory.psm1"
        Import-Module $inventoryModulePath -Force -Global -ErrorAction Stop
    }

    It "Exports browser inventory helpers" {
        $module = Get-Module Browser.Inventory

        $module.ExportedFunctions.Keys | Should -Contain "Get-OpenPathBrowserInventory"
        $module.ExportedFunctions.Keys | Should -Contain "Get-OpenPathBrowserInventoryUninstallEntries"
        $module.ExportedFunctions.Keys | Should -Contain "Get-OpenPathBrowserInventoryFileCandidates"
    }

    It "Detects approved browsers from registry-like uninstall entries" {
        $entries = @(
            [PSCustomObject]@{
                DisplayName = "Mozilla Firefox"
                DisplayVersion = "125.0"
                InstallLocation = "C:\Program Files\Mozilla Firefox"
                UninstallString = "C:\Program Files\Mozilla Firefox\uninstall\helper.exe"
                QuietUninstallString = "C:\Program Files\Mozilla Firefox\uninstall\helper.exe /S"
            },
            [PSCustomObject]@{
                DisplayName = "Microsoft Edge"
                DisplayVersion = "124.0"
                InstallLocation = "C:\Program Files (x86)\Microsoft\Edge\Application"
                UninstallString = "msiexec /x edge"
                QuietUninstallString = "msiexec /x edge /qn"
            },
            [PSCustomObject]@{
                DisplayName = "Google Chrome"
                DisplayVersion = "123.0"
                InstallLocation = "C:\Program Files\Google\Chrome\Application"
                UninstallString = "msiexec /x chrome"
                QuietUninstallString = "msiexec /x chrome /qn"
            }
        )

        $inventory = Get-OpenPathBrowserInventory -UninstallEntries $entries -FileCandidates @()

        @($inventory.ApprovedBrowsers | ForEach-Object Name) | Should -Contain "Mozilla Firefox"
        @($inventory.ApprovedBrowsers | ForEach-Object Name) | Should -Contain "Microsoft Edge"
        @($inventory.ApprovedBrowsers | ForEach-Object Name) | Should -Contain "Google Chrome"
        $inventory.Ready | Should -BeTrue
    }

    It "Does not classify Edge updater components as approved browsers" {
        $entries = @(
            [PSCustomObject]@{
                DisplayName = "Microsoft Edge Update"
                DisplayVersion = "1.3.187.37"
                InstallLocation = "C:\Program Files (x86)\Microsoft\EdgeUpdate"
                UninstallString = "MicrosoftEdgeUpdate.exe /uninstall"
                QuietUninstallString = ""
            }
        )

        $inventory = Get-OpenPathBrowserInventory -UninstallEntries $entries -FileCandidates @()

        @($inventory.ApprovedBrowsers | ForEach-Object Name) | Should -Not -Contain "Microsoft Edge"
        @($inventory.UnmanagedBrowsers).Count | Should -Be 0
    }

    It "Detects approved browsers from mocked filesystem candidates" {
        $candidates = @(
            [PSCustomObject]@{
                Path = "C:\Program Files\Mozilla Firefox\firefox.exe"
                SourceRoot = "ProgramFiles"
                IsUserWritable = $false
            },
            [PSCustomObject]@{
                Path = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
                SourceRoot = "ProgramFilesX86"
                IsUserWritable = $false
            },
            [PSCustomObject]@{
                Path = "C:\Program Files\Google\Chrome\Application\chrome.exe"
                SourceRoot = "ProgramFiles"
                IsUserWritable = $false
            }
        )

        $inventory = Get-OpenPathBrowserInventory -UninstallEntries @() -FileCandidates $candidates

        @($inventory.ApprovedBrowsers | ForEach-Object Name) | Should -Contain "Mozilla Firefox"
        @($inventory.ApprovedBrowsers | ForEach-Object Name) | Should -Contain "Microsoft Edge"
        @($inventory.ApprovedBrowsers | ForEach-Object Name) | Should -Contain "Google Chrome"
        @($inventory.PortableBrowserRisks).Count | Should -Be 0
    }

    It "Detects non-approved browsers and portable browser risks from file candidates" {
        $candidates = @(
            [PSCustomObject]@{
                Path = "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
                SourceRoot = "ProgramFiles"
                IsUserWritable = $false
            },
            [PSCustomObject]@{
                Path = "C:\Users\student\Downloads\Tor Browser\Browser\firefox.exe"
                SourceRoot = "Downloads"
                IsUserWritable = $true
            },
            [PSCustomObject]@{
                Path = "C:\Users\student\Desktop\FirefoxPortable\App\Firefox64\firefox.exe"
                SourceRoot = "Desktop"
                IsUserWritable = $true
            },
            [PSCustomObject]@{
                Path = "C:\Users\student\AppData\Local\Chromium\Application\chrome.exe"
                SourceRoot = "LocalAppData"
                IsUserWritable = $true
            }
        )

        $inventory = Get-OpenPathBrowserInventory -UninstallEntries @() -FileCandidates $candidates

        @($inventory.UnmanagedBrowsers | ForEach-Object Name) | Should -Contain "Brave"
        @($inventory.UnmanagedBrowsers | ForEach-Object Name) | Should -Contain "Tor Browser"
        @($inventory.PortableBrowserRisks | ForEach-Object Name) | Should -Contain "Firefox portable"
        @($inventory.PortableBrowserRisks | ForEach-Object Name) | Should -Contain "Chromium portable"
        $inventory.Ready | Should -BeFalse
        $inventory.ExitCode | Should -Be 1
    }

    It "Reports WebView2 separately and never marks it automatically removable" {
        $entries = @(
            [PSCustomObject]@{
                DisplayName = "Microsoft Edge WebView2 Runtime"
                DisplayVersion = "124.0"
                InstallLocation = "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"
                UninstallString = "setup.exe --uninstall"
                QuietUninstallString = "setup.exe --uninstall --silent"
            }
        )

        $inventory = Get-OpenPathBrowserInventory -UninstallEntries $entries -FileCandidates @() -Mode RemoveKnownInstallers

        @($inventory.WebRenderingSurfaces | ForEach-Object Name) | Should -Contain "Microsoft Edge WebView2 Runtime"
        @($inventory.WebRenderingSurfaces | Where-Object { $_.Name -eq "Microsoft Edge WebView2 Runtime" }).AutomaticallyRemovable | Should -BeFalse
        @($inventory.RemovalCandidates | ForEach-Object Name) | Should -Not -Contain "Microsoft Edge WebView2 Runtime"
    }

    It "Defaults to report-only posture for cleanup/reporting shape" {
        $entries = @(
            [PSCustomObject]@{
                DisplayName = "Brave Browser"
                DisplayVersion = "1.66"
                InstallLocation = "C:\Program Files\BraveSoftware\Brave-Browser\Application"
                UninstallString = "setup.exe --uninstall"
                QuietUninstallString = "setup.exe --uninstall --silent"
            }
        )

        $inventory = Get-OpenPathBrowserInventory -UninstallEntries $entries -FileCandidates @()

        $inventory.Mode | Should -Be "ReportOnly"
        @($inventory.RemovalCandidates).Count | Should -Be 0
        @($inventory.UnmanagedBrowsers | Where-Object { $_.Name -eq "Brave" }).AutomaticallyRemovable | Should -BeFalse
    }
}
