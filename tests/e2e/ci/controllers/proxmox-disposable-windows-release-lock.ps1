<##
.SYNOPSIS
    Releases or reclaims the desktop-survival lab lock for a workflow run.
.DESCRIPTION
    Cancelled or otherwise dead runs can leave the remote lock directory
    behind, blocking the next scenario until the TTL expires.  Two modes are
    supported:

    - Default: release only lock entries whose owner belongs to this
      run/attempt.  The release step runs with `if: cancelled()`, and another
      run's lock is left untouched.
    - `-ReclaimFinishedOwners`: read the current lock owner and reclaim it only
      when it has the canonical <runId>/<runAttempt>/<scenario> shape and its
      workflow run is no longer active.  Locks owned by the current run, by
      still-active runs, by manual lab sessions, or with an unreadable owner
      or run state are left untouched.

    A release or reclaim failure is reported but never fails the workflow.

    Exit codes:
      0  lock released/reclaimed, not owned by this run, unreclaimable, or lab
         configuration unavailable
.PARAMETER RunId
    Workflow run identifier.
.PARAMETER RunAttempt
    Workflow run attempt.
.PARAMETER ReclaimFinishedOwners
    Reclaim a lock whose owning workflow run has finished instead of releasing
    only this run's own lock entries.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$RunAttempt,
    [switch]$ReclaimFinishedOwners
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
    if ($ReclaimFinishedOwners) {
        $apiUrl = if ($env:GITHUB_API_URL) { [string]$env:GITHUB_API_URL } else { 'https://api.github.com' }
        $isRunActive = {
            param([string]$OwnerRunId)
            if ($OwnerRunId -eq $RunId) { return $true }
            if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -or [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
                throw 'missing-gh-token-or-repository'
            }
            $run = Invoke-RestMethod -Uri "$apiUrl/repos/$($env:GITHUB_REPOSITORY)/actions/runs/$OwnerRunId" `
                -Headers @{ Authorization = "Bearer $($env:GH_TOKEN)"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' } `
                -TimeoutSec 20
            return $run.status -in @('queued', 'in_progress', 'waiting', 'requested', 'pending')
        }
        $result = Invoke-OpenPathProxmoxLabStaleLockReclaim -Config $config -Transport $transport -IsRunActive $isRunActive
        Write-Output $result
        exit 0
    }
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
