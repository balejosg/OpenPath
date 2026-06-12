function Get-OpenPathWatchdogCaptivePortalPolicyOutcome {
    # maps the combination of portal mode, marker state, captive state, and entry/exit signals to a single action label such as unsafeMarker, keepLimited, closeAuthenticated, restoreProtected, or noAction.
    [CmdletBinding()]
    param(
        [bool]$PortalModeActive = $false,

        [bool]$MarkerPresent = $false,

        [string]$MarkerMode = '',

        [string]$CaptiveState = 'Unknown',

        [bool]$ShouldEnterPortal = $false,

        [bool]$ShouldExitPortal = $false,

        [AllowNull()]
        [Nullable[bool]]$PassthroughLocalDnsConfigured = $null
    )

    if ($PortalModeActive -and -not $MarkerPresent) {
        return 'unsafeMarker'
    }

    if ($PortalModeActive -and $MarkerMode -eq 'passthrough' -and $null -ne $PassthroughLocalDnsConfigured) {
        if ([bool]$PassthroughLocalDnsConfigured -or $CaptiveState -eq 'Authenticated') {
            return 'emergencyPassthrough'
        }
        return 'noAction'
    }

    if ($PortalModeActive -and $MarkerMode -ne '' -and $CaptiveState -eq 'Authenticated') {
        return 'closeAuthenticated'
    }

    if ($PortalModeActive -and $MarkerMode -eq 'limited' -and $CaptiveState -eq 'Portal') {
        return 'keepLimited'
    }

    if ($ShouldEnterPortal) {
        return 'keepLimited'
    }

    if ($ShouldExitPortal -and $PortalModeActive) {
        return 'restoreProtected'
    }

    return 'noAction'
}
