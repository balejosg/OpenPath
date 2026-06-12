function Get-OpenPathEndpointPolicyState {
    # derives the current endpoint policy flags from $WhitelistSections and the portal/stale-failsafe boolean inputs; returns a psobject with IsDisabled, PortalModeActive, StaleFailsafeActive, and ProtectedModeEligible.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$WhitelistSections,

        [bool]$PortalModeActive = $false,

        [bool]$StaleFailsafeActive = $false
    )

    $isDisabled = $false
    if ($WhitelistSections -and $WhitelistSections.PSObject.Properties['IsDisabled']) {
        $isDisabled = [bool]$WhitelistSections.IsDisabled
    }

    return [PSCustomObject]@{
        IsDisabled = $isDisabled
        FailOpenActive = $isDisabled
        PortalModeActive = [bool]$PortalModeActive
        StaleFailsafeActive = [bool]$StaleFailsafeActive
        ProtectedModeEligible = (-not $PortalModeActive -and -not $isDisabled)
    }
}
