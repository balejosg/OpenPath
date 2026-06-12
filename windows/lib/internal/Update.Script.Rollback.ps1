function Invoke-OpenPathUpdateRollback {
    # attempts a checkpoint rollback first; falls back to restoring $BackupPath when checkpoint rollback is disabled or fails; returns the rollback method and success flag.
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath
    )

    $checkpointRollbackEnabled = $true
    if ($Config -and $Config.PSObject.Properties['enableCheckpointRollback']) {
        $checkpointRollbackEnabled = [bool]$Config.enableCheckpointRollback
    }

    $rollbackMethod = 'none'
    $rollbackSucceeded = $false
    if ($checkpointRollbackEnabled -and $Config) {
        Write-UpdateCatchLog 'Attempting checkpoint rollback...' -Level WARN
        $rollbackSucceeded = Restore-OpenPathCheckpoint -Config $Config -WhitelistPath $WhitelistPath -StaleFailsafeStatePath $StaleFailsafeStatePath
        if ($rollbackSucceeded) {
            $rollbackMethod = 'checkpoint'
            if ($Config) {
                Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath
            }
        }
    }

    if (-not $rollbackSucceeded -and (Test-Path $BackupPath)) {
        Write-UpdateCatchLog 'Falling back to backup whitelist rollback...' -Level WARN
        try {
            Copy-Item $BackupPath $WhitelistPath -Force
            if ($Config) {
                Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath
            }
            $backupSections = Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath
            Update-AcrylicHost -WhitelistedDomains $backupSections.Whitelist -BlockedSubdomains $backupSections.BlockedSubdomains -ErrorAction SilentlyContinue
            if ($Config) {
                Restore-OpenPathProtectedMode -Config $Config -ErrorAction SilentlyContinue | Out-Null
            }
            $rollbackSucceeded = $true
            $rollbackMethod = 'backup'
            Write-UpdateCatchLog 'Backup rollback completed successfully' -Level WARN
        }
        catch {
            Write-UpdateCatchLog "Backup rollback also failed: $_" -Level ERROR
        }
    }

    return [PSCustomObject]@{
        RollbackSucceeded = $rollbackSucceeded
        RollbackMethod = $rollbackMethod
    }
}

function Send-OpenPathUpdateFailureHealth {
    # submits a health report reflecting the update failure; uses DEGRADED status when rollback succeeded and CRITICAL when it did not.
    param(
        [Parameter(Mandatory = $true)]
        [bool]$RollbackSucceeded,

        [Parameter(Mandatory = $true)]
        [string]$RollbackMethod
    )

    try {
        $runtimeHealth = Get-OpenPathRuntimeHealth
        $failureAction = if ($RollbackSucceeded) { "update_failed_rollback_$RollbackMethod" } else { 'update_failed_no_rollback' }
        $failureStatus = if ($RollbackSucceeded) { 'DEGRADED' } else { 'CRITICAL' }
        $failureCount = if ($RollbackSucceeded) { 0 } else { 1 }
        Send-OpenPathHealthReport -Status $failureStatus `
            -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
            -DnsResolving $runtimeHealth.DnsResolving `
            -FailCount $failureCount `
            -Actions $failureAction | Out-Null
    }
    catch {
        # Ignore health reporting errors while handling critical failure
    }
}
