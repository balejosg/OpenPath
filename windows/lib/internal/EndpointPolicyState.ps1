function Get-OpenPathEndpointPolicyState {
    # derives the current endpoint policy flags from $WhitelistSections, the portal/stale-failsafe booleans, and the DNS failure-mode marker; returns a psobject with IsDisabled, PortalModeActive, StaleFailsafeActive, FailureModeOpenActive, and ProtectedModeEligible.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$WhitelistSections,

        [bool]$PortalModeActive = $false,

        [bool]$StaleFailsafeActive = $false,

        [AllowNull()]
        [object]$FailureModeState = $null
    )

    if ($null -eq $FailureModeState -and (Get-Command -Name Read-OpenPathDnsFailureModeState -ErrorAction SilentlyContinue)) {
        try {
            $FailureModeState = Read-OpenPathDnsFailureModeState
        }
        catch {
            $FailureModeState = $null
        }
    }

    $isDisabled = $false
    if ($WhitelistSections -and $WhitelistSections.PSObject.Properties['IsDisabled']) {
        $isDisabled = [bool]$WhitelistSections.IsDisabled
    }

    $failureModeOpen = $false
    if ($FailureModeState -and $FailureModeState.PSObject.Properties['mode']) {
        $failureModeOpen = ([string]$FailureModeState.mode -eq 'open')
    }

    return [PSCustomObject]@{
        IsDisabled = $isDisabled
        FailOpenActive = $isDisabled
        PortalModeActive = [bool]$PortalModeActive
        StaleFailsafeActive = [bool]$StaleFailsafeActive
        FailureModeOpenActive = $failureModeOpen
        ProtectedModeEligible = (-not $PortalModeActive -and -not $isDisabled -and -not $failureModeOpen)
    }
}
