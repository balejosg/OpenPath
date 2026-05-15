function Get-OpenPathEndpointPolicyState {
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
