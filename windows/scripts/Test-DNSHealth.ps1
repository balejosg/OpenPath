# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Watchdog script to verify DNS health and auto-recover
.DESCRIPTION
    Runs periodically to ensure Acrylic DNS and firewall are working correctly.
    Attempts auto-recovery if problems are detected.
#>

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot '..\lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot
. (Join-Path $OpenPathRoot 'lib\internal\Watchdog.FailCount.ps1')
. (Join-Path $OpenPathRoot 'lib\internal\Watchdog.Runtime.ps1')

# Initialize standalone script session via the shared bootstrap helper.
Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force
Initialize-OpenPathScriptSession `
    -OpenPathRoot $OpenPathRoot `
    -DependentModules @('DNS', 'Network', 'Firewall', 'Browser', 'CaptivePortal', 'AppControl') `
    -RequiredCommands @(
    'Write-OpenPathLog',
    'Get-OpenPathConfig',
    'Get-OpenPathRuntimeHealth',
    'Get-OpenPathWhitelistSectionsFromFile',
    'Restore-OpenPathProtectedMode',
    'Send-OpenPathHealthReport',
    'Test-OpenPathIntegrity',
    'Restore-OpenPathIntegrity',
    'Test-OpenPathCaptivePortalModeActive',
    'Test-OpenPathCaptivePortalMarkerExpired',
    'Test-OpenPathCaptivePortalState',
    'Test-DNSResolution',
    'Test-DNSSinkhole',
    'Test-FirewallActive',
    'Get-AcrylicPath',
    'Set-OpenPathFirewall',
    'Sync-OpenPathFirefoxManagedExtensionPolicy',
    'Set-LocalDNS',
    'Start-AcrylicService',
    'Restart-AcrylicService',
    'Restore-OpenPathCaptivePortalDNS',
    'Enable-OpenPathCaptivePortalMode',
    'Disable-OpenPathCaptivePortalMode'
) `
    -ScriptName 'Test-DNSHealth.ps1' | Out-Null

$issues = @()
$recoveryEligibleIssues = @()
$watchdogFailCountPath = "$OpenPathRoot\data\watchdog-fails.txt"
$staleFailsafeStatePath = "$OpenPathRoot\data\stale-failsafe-state.json"
$config = $null

try {
    $config = Get-OpenPathConfig
}
catch {
    $issues += "Configuration load failed"
    $recoveryEligibleIssues += "Configuration load failed"
    Write-OpenPathLog "Watchdog: Error loading configuration: $_" -Level ERROR
}

$precheckResult = Invoke-OpenPathWatchdogPrechecks -Config $config
$portalModeActive = $precheckResult.PortalModeActive
if ($portalModeActive) {
    $issues += 'Captive portal mode active'
}
if ($precheckResult.CaptiveState -eq 'Portal') {
    $declaredCount = 0
    if (Get-Command -Name 'Get-OpenPathConfiguredCaptivePortalDomains' -ErrorAction SilentlyContinue) {
        try { $declaredCount = @(Get-OpenPathConfiguredCaptivePortalDomains).Count } catch { $declaredCount = 0 }
    }
    if ($declaredCount -le 0) {
        $issues += 'captive_portal_detected_no_declared_domains'
    }
}

$checkResult = Invoke-OpenPathWatchdogChecks `
    -Config $config `
    -PortalModeActive $portalModeActive `
    -CaptiveState $precheckResult.CaptiveState `
    -OpenPathRoot $OpenPathRoot `
    -StaleFailsafeStatePath $staleFailsafeStatePath
$issues += @($checkResult.Issues)
$recoveryEligibleIssues += @($checkResult.RecoveryEligibleIssues)

$outcome = Get-OpenPathWatchdogOutcome `
    -Config $config `
    -Issues @($issues) `
    -RecoveryEligibleIssues @($recoveryEligibleIssues) `
    -StaleFailsafeActive $checkResult.StaleFailsafeActive `
    -IntegrityTampered $checkResult.IntegrityTampered `
    -FailOpenActive $checkResult.FailOpenActive `
    -PortalModeActive $portalModeActive `
    -WatchdogFailCountPath $watchdogFailCountPath `
    -OpenPathRoot $OpenPathRoot

$runtimeHealth = Get-OpenPathRuntimeHealth
Send-OpenPathHealthReport -Status $outcome.Status `
    -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
    -DnsResolving $runtimeHealth.DnsResolving `
    -FailCount $outcome.WatchdogFailCount `
    -Actions $outcome.Actions | Out-Null

if ($outcome.Status -ne 'HEALTHY') {
    Write-OpenPathLog "Watchdog status=$($outcome.Status) failCount=$($outcome.WatchdogFailCount) actions=$($outcome.Actions)"
}

exit 0
