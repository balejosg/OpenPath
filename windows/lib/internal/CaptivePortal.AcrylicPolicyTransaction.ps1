function Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction {
    # runs $Action inside the acrylic policy state lock for the given $State label; executes $Rollback on failure, then re-throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('normalProtected', 'limitedRecovery', 'restoredProtected')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [scriptblock]$Rollback = $null,

        [switch]$SkipPolicyStateLock
    )

    $transactionAction = {
        try {
            return (& $Action)
        }
        catch {
            if ($Rollback) {
                try { & $Rollback | Out-Null }
                catch {
                    if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
                        Write-OpenPathLog "Watchdog: captive portal Acrylic $State rollback failed: $_" -Level WARN
                    }
                }
            }
            throw
        }
    }.GetNewClosure()

    if (-not $SkipPolicyStateLock -and (Get-Command -Name 'Invoke-AcrylicPolicyStateLocked' -ErrorAction SilentlyContinue)) {
        return (Invoke-AcrylicPolicyStateLocked -Action $transactionAction)
    }

    return (& $transactionAction)
}

function Get-OpenPathCaptivePortalAcrylicPolicyState {
    # returns $true when the combination of boolean flags satisfies the readiness criteria for the requested $State label.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('normalProtected', 'limitedRecovery', 'restoredProtected')]
        [string]$State,

        [bool]$LocalDnsLoopbackRestored = $false,

        [bool]$AcrylicNormalRestored = $false,

        [bool]$MarkerCleared = $false,

        [bool]$LimitedExactHostsVerified = $false
    )

    switch ($State) {
        'normalProtected' {
            return ($LocalDnsLoopbackRestored -and $AcrylicNormalRestored)
        }
        'limitedRecovery' {
            return $LimitedExactHostsVerified
        }
        'restoredProtected' {
            return ($LocalDnsLoopbackRestored -and $AcrylicNormalRestored -and $MarkerCleared)
        }
    }

    return $false
}
