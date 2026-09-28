<##
.SYNOPSIS
    Releases the desktop-survival lab lock for a cancelled workflow run.
.DESCRIPTION
    Cancelled runs can leave the remote lock directory behind, blocking the next
    scenario until the TTL expires.  The release step runs with
    `if: cancelled()` and releases only lock entries whose owner belongs to this
    run/attempt; another run's lock is left untouched.  A release failure is
    reported but never fails the workflow again.

    Exit codes:
      0  lock released, not owned by this run, or lab configuration unavailable
.PARAMETER RunId
    Workflow run identifier.
.PARAMETER RunAttempt
    Workflow run attempt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$RunAttempt
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxmoxWindowsLab.psm1') -Force

$configPath = if ($env:OPENPATH_DESKTOP_LAB_CONFIG) { [string]$env:OPENPATH_DESKTOP_LAB_CONFIG } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/openpath/desktop-survival-lab.json' }
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Output 'desktop-lab-config-missing; no lock to release.'
    exit 0
}

try {
    $config = Read-OpenPathProxmoxLabConfig -Path $configPath
    $transport = New-OpenPathProxmoxLabTransport -Config $config
    $released = @(Invoke-OpenPathProxmoxLabLockRelease -Config $config -Transport $transport -RunId $RunId -RunAttempt $RunAttempt)
    if ($released.Count -gt 0) {
        Write-Output ("released=" + ($released -join ','))
    }
    else {
        Write-Output 'not-owner'
    }
}
catch {
    Write-Output ("release-failed: " + ([string]$_.Exception.Message).Trim())
}
exit 0
