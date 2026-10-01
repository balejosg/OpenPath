<##
.SYNOPSIS
    Manual utility for the Phase 3A lab lock (status/acquire/renew/release).
.DESCRIPTION
    Operator-facing wrapper around the shared lock protocol
    (tests/e2e/ci/controllers/proxmox-lab-lock.sh): a live lock is never stolen,
    manual sessions can renew their heartbeat, and every replacement records the
    previous owner. Reads the same lab inventory as the CI controller
    (OPENPATH_DESKTOP_LAB_CONFIG, default ~/.config/openpath/desktop-survival-lab.json).
.EXAMPLE
    pwsh -File tests/e2e/ci/controllers/proxmox-lab-lock.ps1 -Action status
.EXAMPLE
    pwsh -File tests/e2e/ci/controllers/proxmox-lab-lock.ps1 -Action acquire -Owner manual/investigation -TtlSeconds 7200
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('status', 'acquire', 'renew', 'release')][string]$Action,
    [string]$Owner = 'manual/lab',
    [int]$TtlSeconds = 1800,
    [int]$WaitSeconds = 900,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxmoxWindowsLab.psm1') -Force
if (-not $ConfigPath) {
    $ConfigPath = if ($env:OPENPATH_DESKTOP_LAB_CONFIG) { [string]$env:OPENPATH_DESKTOP_LAB_CONFIG } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/openpath/desktop-survival-lab.json' }
}
$config = Read-OpenPathProxmoxLabConfig -Path $ConfigPath
$transport = New-OpenPathProxmoxLabTransport -Config $config
$lockFile = [string](Get-OpenPathLabField -InputObject $config -Name 'lockFile')
if ([string]::IsNullOrWhiteSpace($lockFile)) { throw 'lab-lock-file-missing' }

switch ($Action) {
    'status' {
        $owner = & $transport.ReadLockOwner $lockFile
        if ([string]::IsNullOrWhiteSpace($owner)) { Write-Output 'free' } else { Write-Output "owner=$owner" }
    }
    'acquire' {
        $acquired = & $transport.EnsureLock $lockFile $Owner $TtlSeconds $WaitSeconds
        if ($acquired) { Write-Output "acquired owner=$Owner" } else { Write-Output 'busy'; exit 1 }
    }
    'renew' {
        $renewed = & $transport.UpdateLockHeartbeat $lockFile $Owner
        if ($renewed) { Write-Output 'renewed' } else { Write-Output 'not-owner'; exit 1 }
    }
    'release' {
        $released = & $transport.ReleaseLock $lockFile $Owner
        if ($released) { Write-Output 'released' } else { Write-Output 'not-owner'; exit 1 }
    }
}
