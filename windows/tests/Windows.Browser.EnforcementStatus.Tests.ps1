# OpenPath Windows browser enforcement status tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Browser Module - Enforcement status" {
    It "Exports an operator-facing browser enforcement status helper" {
        $browserModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.psm1"
        $content = Get-Content $browserModulePath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'Browser.EnforcementStatus.psm1',
            'function Get-OpenPathBrowserEnforcementStatus',
            'Browser.EnforcementStatus\Get-OpenPathBrowserEnforcementStatus',
            "'Get-OpenPathBrowserEnforcementStatus'"
        )
    }

    It "Builds status from inventory, readiness, AppControl, and firewall helpers" {
        $statusModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.EnforcementStatus.psm1"
        Test-Path $statusModulePath | Should -BeTrue
        $content = Get-Content $statusModulePath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'function Get-OpenPathBrowserEnforcementStatus',
            'Get-OpenPathBrowserInventory',
            'Get-OpenPathBrowserRequestReadiness',
            'Test-OpenPathNonAdminAppControlActive',
            'AppControl currently exposes active/inactive only',
            "return 'Inactive'",
            "return 'AuditOnly'",
            "return 'Enforced'",
            'Get-FirewallStatus',
            'browserCleanupMode',
            'AppLocker',
            'ApprovedStudentBrowsers',
            'ApprovedBrowsers',
            'BlockedByAppLockerBrowsers',
            'UnmanagedBrowsers',
            'Firewall',
            'Overall'
        )
    }
}
