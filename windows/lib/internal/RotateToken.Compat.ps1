function Get-LegacyRotationAuthToken {
    # returns the shared-secret override when provided, or an empty string; serves as the legacy fallback before machine tokens
    param(
        [Parameter(Mandatory = $true)][string]$SecretOverride
    )

    if ($SecretOverride) {
        return $SecretOverride
    }

    return ''
}

function Resolve-OpenPathRotationAuth {
    # prefers the machine token derived from whitelistUrl; falls back to the legacy shared secret; returns Token and Source
    param(
        [Parameter(Mandatory = $true)][psobject]$Config,
        [Parameter(Mandatory = $true)][string]$SecretOverride
    )

    $machineToken = ''
    if ($Config.PSObject.Properties['whitelistUrl'] -and $Config.whitelistUrl) {
        $machineToken = Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl ([string]$Config.whitelistUrl)
    }

    if ($machineToken) {
        return [pscustomobject]@{
            Token = $machineToken
            Source = 'machine token'
        }
    }

    $legacyToken = Get-LegacyRotationAuthToken -SecretOverride $SecretOverride
    if ($legacyToken) {
        return [pscustomobject]@{
            Token = $legacyToken
            Source = 'legacy shared secret'
        }
    }

    return [pscustomobject]@{
        Token = ''
        Source = ''
    }
}
