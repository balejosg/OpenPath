function Get-OpenPathUpdatePolicySettings {
    # reads stale-whitelist age, failsafe, checkpoint rollback, and max-checkpoint settings from $Config, applying defaults for any missing or invalid values.
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $settings = [ordered]@{
        StaleWhitelistMaxAgeHours = 24
        EnableStaleFailsafe = $true
        EnableCheckpointRollback = $true
        MaxCheckpoints = 3
    }

    if ($Config.PSObject.Properties['staleWhitelistMaxAgeHours']) {
        try {
            $configuredMaxAge = [int]$Config.staleWhitelistMaxAgeHours
            if ($configuredMaxAge -ge 0) {
                $settings.StaleWhitelistMaxAgeHours = $configuredMaxAge
            }
        }
        catch {
            Write-OpenPathLog "Invalid staleWhitelistMaxAgeHours value, using default: $_" -Level WARN
        }
    }

    if ($Config.PSObject.Properties['enableStaleFailsafe']) {
        $settings.EnableStaleFailsafe = [bool]$Config.enableStaleFailsafe
    }

    if ($Config.PSObject.Properties['enableCheckpointRollback']) {
        $settings.EnableCheckpointRollback = [bool]$Config.enableCheckpointRollback
    }

    if ($Config.PSObject.Properties['maxCheckpoints']) {
        try {
            $configuredMaxCheckpoints = [int]$Config.maxCheckpoints
            if ($configuredMaxCheckpoints -ge 1) {
                $settings.MaxCheckpoints = $configuredMaxCheckpoints
            }
        }
        catch {
            Write-OpenPathLog "Invalid maxCheckpoints value, using default: $_" -Level WARN
        }
    }

    return [PSCustomObject]$settings
}

function Backup-OpenPathWhitelistState {
    # copies $WhitelistPath to $BackupPath and, when checkpoint rollback is enabled, saves a pre-update checkpoint capped at $MaxCheckpoints.
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [bool]$EnableCheckpointRollback,

        [Parameter(Mandatory = $true)]
        [int]$MaxCheckpoints
    )

    if (-not (Test-Path $WhitelistPath)) {
        return
    }

    Copy-Item $WhitelistPath $BackupPath -Force
    Write-OpenPathLog "Backed up current whitelist for rollback"

    if ($EnableCheckpointRollback) {
        $checkpointResult = Save-OpenPathWhitelistCheckpoint -WhitelistPath $WhitelistPath -MaxCheckpoints $MaxCheckpoints -Reason 'pre-update'
        if ($checkpointResult.Success) {
            Write-OpenPathLog "Checkpoint created at $($checkpointResult.CheckpointPath)"
        }
        else {
            Write-OpenPathLog "Checkpoint creation failed (non-critical): $($checkpointResult.Error)" -Level WARN
        }
    }
}
