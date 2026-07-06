# Single owner of machine-token extraction from a tokenized whitelist URL.
# Previously duplicated with divergent behavior in Common.Http.Whitelist.ps1
# (loose match, no unescape) and Update.Runtime.psm1 (anchored, '' on miss).
# Canonical: anchored '/w/<token>/whitelist.txt' at the end of the URL path,
# URL-unescaped token, $null when no token is present. Pure function.

function Get-OpenPathMachineTokenFromWhitelistUrl {
    <#
    .SYNOPSIS
        Extracts the machine token path segment from a tokenized whitelist URL.
    .PARAMETER WhitelistUrl
        Absolute whitelist URL of the form https://<host>/w/<token>/whitelist.txt
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$WhitelistUrl = '')

    $candidate = ([string]$WhitelistUrl).Trim()
    if (-not $candidate) { return $null }

    try {
        $uri = [System.Uri]::new($candidate)
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https')) {
            return $null
        }
        $match = [regex]::Match($uri.AbsolutePath, '/w/([^/]+)/whitelist\.txt$', 'IgnoreCase')
        if ($match.Success) {
            return [System.Uri]::UnescapeDataString($match.Groups[1].Value)
        }
    }
    catch {
        if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
            Write-OpenPathLog "Could not parse machine token from whitelist URL: $_" -Level WARN
        }
    }

    return $null
}
