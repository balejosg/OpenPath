# OpenPath - Captive portal recovery task
# Thin SYSTEM-task shim: session bootstrap + the harness-patchable captive
# portal state probe. All queue/request/result logic lives in
# lib\internal\CaptivePortal.RecoveryRunner.ps1.

#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

# Repair a tree left mid-update before any module is imported.
try { & (Join-Path $OpenPathRoot 'scripts\Recover-OpenPathAgentUpdate.ps1') -OpenPathRoot $OpenPathRoot } catch { }

Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force
Initialize-OpenPathScriptSession `
    -OpenPathRoot $OpenPathRoot `
    -DependentModules @('DNS', 'Firewall', 'CaptivePortal') `
    -RequiredCommands @(
    'Write-OpenPathLog',
    'Get-OpenPathCapabilityStoragePath',
    'Get-OpenPathCaptivePortalMarker',
    'Get-OpenPathCaptivePortalAllowedHosts',
    'Select-OpenPathCaptivePortalAllowedRecoveryHosts',
    'Get-OpenPathConfiguredCaptivePortalDomains',
    'Get-OpenPathCaptivePortalProtectedModeExitEvidence',
    'Test-OpenPathCaptivePortalState',
    'Test-OpenPathCaptivePortalModeActive',
    'Test-OpenPathCaptivePortalClassroomDisabled',
    'Update-OpenPathCaptivePortalObservation',
    'Enable-OpenPathCaptivePortalMode',
    'Disable-OpenPathCaptivePortalMode'
) `
    -ScriptName 'Recover-CaptivePortal.ps1' | Out-Null

. (Join-Path $OpenPathRoot 'lib\internal\CaptivePortal.RecoveryTransition.ps1')
. (Join-Path $OpenPathRoot 'lib\internal\CaptivePortal.RecoveryRunner.ps1')

function Get-OpenPathCaptivePortalRecoveryState {
    param([Parameter(Mandatory = $true)][DateTime]$NowUtc)

    return (Test-OpenPathCaptivePortalState -TimeoutSec 3)
}

Invoke-OpenPathCaptivePortalRecoveryQueue -OpenPathRoot $OpenPathRoot
