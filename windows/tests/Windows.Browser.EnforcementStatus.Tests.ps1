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
            'function Get-OpenPathAppLockerStatus',
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

    Context "Get-OpenPathAppLockerStatus lifecycle gating" {
        BeforeAll {
            if (-not (Get-Command Get-LocalGroup -ErrorAction SilentlyContinue)) {
                function global:Get-LocalGroup { param($Name) }
            }
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Browser.EnforcementStatus.psm1") -Force
        }

        It "Returns Inactive when appControlCommitState is pending" {
            InModuleScope Browser.EnforcementStatus {
                $cfg = [pscustomobject]@{
                    appControlCommitState = 'pending'
                    installState = 'complete'
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $cfg | Should -Be 'Inactive'
            }
        }

        It "Returns Inactive when installState is installing or failed" {
            InModuleScope Browser.EnforcementStatus {
                $cfgInstalling = [pscustomobject]@{
                    appControlCommitState = 'committed'
                    installState = 'installing'
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $cfgInstalling | Should -Be 'Inactive'

                $cfgFailed = [pscustomobject]@{
                    appControlCommitState = 'committed'
                    installState = 'failed'
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $cfgFailed | Should -Be 'Inactive'
            }
        }

        It "Returns Inactive when Test-OpenPathNonAdminAppControlActive returns false" {
            InModuleScope Browser.EnforcementStatus {
                Mock Test-OpenPathNonAdminAppControlActive { return $false }
                $cfg = [pscustomobject]@{
                    appControlCommitState = 'committed'
                    installState = 'complete'
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $cfg | Should -Be 'Inactive'
            }
        }

        It "Returns Enforced when committed, complete, and AppControl is active" {
            InModuleScope Browser.EnforcementStatus {
                Mock Test-OpenPathNonAdminAppControlActive { return $true }
                $cfg = [pscustomobject]@{
                    appControlCommitState = 'committed'
                    installState = 'complete'
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $cfg | Should -Be 'Enforced'
            }
        }

        It "Returns AuditOnly when configured for AuditOnly" {
            InModuleScope Browser.EnforcementStatus {
                Mock Test-OpenPathNonAdminAppControlActive { return $true }
                $cfg = [pscustomobject]@{
                    appControlCommitState = 'committed'
                    installState = 'complete'
                    nonAdminAppControlMode = 'AuditOnly'
                }
                Get-OpenPathAppLockerStatus -Config $cfg | Should -Be 'AuditOnly'
            }
        }

        It "Legacy config without appControlCommitState returns Enforced when group exists and boundary active" {
            InModuleScope Browser.EnforcementStatus {
                Mock Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted' } }
                Mock Test-OpenPathNonAdminAppControlActive { return $true }
                $legacyCfg = [pscustomobject]@{
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $legacyCfg | Should -Be 'Enforced'
            }
        }

        It "Legacy config without appControlCommitState returns Inactive when OpenPath-Restricted group is missing" {
            InModuleScope Browser.EnforcementStatus {
                Mock Get-LocalGroup { throw 'Group not found' }
                Mock Test-OpenPathNonAdminAppControlActive { return $true }
                $legacyCfg = [pscustomobject]@{
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $legacyCfg | Should -Be 'Inactive'
            }
        }

        It "Legacy config without appControlCommitState returns Inactive when boundary is inactive" {
            InModuleScope Browser.EnforcementStatus {
                Mock Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted' } }
                Mock Test-OpenPathNonAdminAppControlActive { return $false }
                $legacyCfg = [pscustomobject]@{
                    nonAdminAppControlMode = 'Enforced'
                }
                Get-OpenPathAppLockerStatus -Config $legacyCfg | Should -Be 'Inactive'
            }
        }
    }
}
