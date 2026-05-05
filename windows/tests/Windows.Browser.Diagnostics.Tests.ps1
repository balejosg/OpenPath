# OpenPath Windows browser diagnostics tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.psm1" -Force -Global -ErrorAction Stop

Describe "Browser Module - Diagnostics" {
    BeforeAll {
        $browserModulePath = Join-Path (Join-Path $PSScriptRoot ".." "lib") "Browser.psm1"
        Import-Module $browserModulePath -Force -Global -ErrorAction Stop
    }

    Context "Browser doctor" {
        It "Exports a focused browser doctor report helper" {
            $browserDiagnosticsPath = Join-Path $PSScriptRoot ".." "lib" "Browser.Diagnostics.psm1"
            $content = Get-Content $browserDiagnosticsPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Get-OpenPathBrowserDoctorReport',
                'Firefox metadata path:',
                'Firefox XPI ACL summary:',
                'Resolved install_url:',
                'Machine Firefox policy:',
                'Machine Firefox policy install_url:',
                'Policy JSON parse:'
            )
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

        It "Reports Firefox native host diagnostics alongside browser policy state" {
            $browserDiagnosticsPath = Join-Path $PSScriptRoot ".." "lib" "Browser.Diagnostics.psm1"
            $content = Get-Content $browserDiagnosticsPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Native host manifest path:',
                'Native host manifest parse:',
                'Native host registry path:',
                'Native host manifest name:',
                'Native host wrapper path:',
                'Native host state helper readable:',
                'Native host protocol helper readable:',
                'Native host actions helper readable:',
                'Native host whitelist readable:',
                'Native host state readable:',
                'Native host request API configured:',
                'Native host whitelist token configured:',
                'Native host request setup complete:',
                'Native host update task check:',
                'Native host update task present:',
                'Native host update task user access:',
                'Browser request readiness:',
                'Browser request readiness facts:',
                'Browser request readiness failures:',
                'firefox_machine_policy='
            )
        }

        It "Exports Firefox native host helpers used by browser diagnostics" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $content = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Get-OpenPathFirefoxNativeHostRoot',
                "'Get-OpenPathFirefoxNativeHostRoot'"
            )
        }

        It "Bounds scheduled task diagnostics so browser doctor cannot hang indefinitely" {
            $browserDiagnosticsPath = Join-Path $PSScriptRoot ".." "lib" "Browser.Diagnostics.psm1"
            $content = Get-Content $browserDiagnosticsPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Get-OpenPathBrowserDoctorScheduledTaskDiagnostic',
                'WaitForExit($TimeoutMilliseconds)',
                'Native host update task check timed out'
            )

            $content.Contains('Get-ScheduledTask -TaskName $nativeHostUpdateTaskName') | Should -BeFalse
        }

        It "Imports browser inventory and reports unmanaged browser risk" {
            $browserDiagnosticsPath = Join-Path $PSScriptRoot ".." "lib" "Browser.Diagnostics.psm1"
            $content = Get-Content $browserDiagnosticsPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Browser.Inventory.psm1',
                'Get-OpenPathBrowserInventory',
                'Approved managed browsers:',
                'Unmanaged browsers detected:',
                'Portable browser risk:',
                'Web rendering surfaces:'
            )
        }
    }
}
