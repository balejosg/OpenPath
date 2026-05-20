function Get-OpenPathFromUrl {
    <#
    .SYNOPSIS
        Downloads and parses whitelist from URL
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    Write-OpenPathLog "Downloading whitelist from $Url"

    $etagPath = Join-Path $script:OpenPathRoot 'data\whitelist.etag'
    $cachedEtag = $null
    if (Test-Path $etagPath) {
        try {
            $cachedEtag = (Get-Content $etagPath -Raw -ErrorAction Stop).Trim()
        }
        catch {
            $cachedEtag = $null
        }
    }

    $httpResult = $null
    try {
        $httpResult = Invoke-OpenPathHttpGetText -RequestUrl $Url -IfNoneMatch $cachedEtag -TimeoutSec 30
    }
    catch {
        Write-OpenPathLog "Failed to download whitelist: $_" -Level ERROR
        throw
    }

    $result = [PSCustomObject]@{
        Whitelist         = @()
        BlockedSubdomains = @()
        BlockedPaths      = @()
        IsDisabled        = $false
        NotModified       = $false
    }

    if ($httpResult -and $httpResult.StatusCode -eq 304) {
        $result.NotModified = $true
        Write-OpenPathLog "Whitelist unchanged (ETag match)"
        return $result
    }

    $content = if ($httpResult) { [string]$httpResult.Content } else { '' }
    $newEtag = if ($httpResult) { [string]$httpResult.ETag } else { $null }
    $currentSection = 'WHITELIST'

    foreach ($line in $content -split "`n") {
        $line = $line.Trim()
        if (-not $line) { continue }

        if ($line -match '^#\s*DESACTIVADO\b') {
            $result.IsDisabled = $true
            continue
        }

        if ($line -match "^##\s*(.+)$") {
            $currentSection = $Matches[1].Trim().ToUpper()
            continue
        }

        if ($line.StartsWith('#')) { continue }

        switch ($currentSection) {
            'WHITELIST'          { $result.Whitelist += $line }
            'BLOCKED-SUBDOMAINS' { $result.BlockedSubdomains += $line }
            'BLOCKED-PATHS'      { $result.BlockedPaths += $line }
        }
    }

    if ($result.IsDisabled) {
        Write-OpenPathLog "Parsed: $($result.Whitelist.Count) whitelisted, $($result.BlockedSubdomains.Count) blocked subdomains, $($result.BlockedPaths.Count) blocked paths, disabled=$($result.IsDisabled)"
        Write-OpenPathLog 'Remote disable marker detected - skipping minimum-domain validation' -Level WARN
        if ($newEtag) {
            try {
                $dir = Split-Path $etagPath -Parent
                if (-not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                $newEtag | Set-Content -Path $etagPath -Encoding ASCII
            }
            catch {
            }
        }
        return $result
    }

    $protectedDomains = @(Get-OpenPathProtectedDomains)
    $alwaysAllowedDomains = @(Get-OpenPathAlwaysAllowedDomains)
    $protectedDomainSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in $alwaysAllowedDomains) {
        if ($domain) {
            $protectedDomainSet.Add($domain) | Out-Null
        }
    }

    if ($protectedDomainSet.Count -gt 0) {
        $effectiveWhitelist = [System.Collections.Generic.List[string]]::new()
        $whitelistSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($domain in @($result.Whitelist) + $protectedDomains) {
            $normalizedDomain = ([string]$domain).Trim().Trim('.')
            if (-not $normalizedDomain) { continue }

            if ((Test-OpenPathDomainFormat -Domain $normalizedDomain) -and $whitelistSeen.Add($normalizedDomain)) {
                $effectiveWhitelist.Add($normalizedDomain) | Out-Null
            }
        }

        $blockedSubdomainRemovals = 0
        $filteredBlockedSubdomains = @(
            foreach ($subdomain in @($result.BlockedSubdomains)) {
                $normalizedSubdomain = ([string]$subdomain).Trim().Trim('.')
                if (-not $normalizedSubdomain) { continue }

                if ($protectedDomainSet.Contains($normalizedSubdomain)) {
                    $blockedSubdomainRemovals++
                    continue
                }

                $normalizedSubdomain
            }
        )

        $blockedPathRemovals = 0
        $filteredBlockedPaths = @(
            foreach ($pathRule in @($result.BlockedPaths)) {
                $protectedPathHost = Get-OpenPathHostFromBlockedPathRule -Rule $pathRule
                if ($protectedPathHost -and $protectedDomainSet.Contains($protectedPathHost)) {
                    $blockedPathRemovals++
                    continue
                }

                $pathRule
            }
        )

        if ($blockedSubdomainRemovals -gt 0 -or $blockedPathRemovals -gt 0) {
            Write-OpenPathLog "Removed $blockedSubdomainRemovals blocked subdomains and $blockedPathRemovals blocked paths targeting protected always-allowed domains" -Level WARN
        }

        $result.Whitelist = @($effectiveWhitelist)
        $result.BlockedSubdomains = @($filteredBlockedSubdomains)
        $result.BlockedPaths = @($filteredBlockedPaths)
    }

    Write-OpenPathLog "Parsed: $($result.Whitelist.Count) whitelisted, $($result.BlockedSubdomains.Count) blocked subdomains, $($result.BlockedPaths.Count) blocked paths, disabled=$($result.IsDisabled)"

    $validDomains = $result.Whitelist | Where-Object { Test-OpenPathDomainFormat -Domain $_ }
    $minRequiredDomains = 1
    if ($validDomains.Count -lt $minRequiredDomains) {
        Write-OpenPathLog "Downloaded whitelist appears invalid ($($validDomains.Count) valid domains, minimum $minRequiredDomains required)" -Level ERROR
        throw "Invalid whitelist content: insufficient valid domains ($($validDomains.Count)/$minRequiredDomains)"
    }

    if ($newEtag) {
        try {
            $dir = Split-Path $etagPath -Parent
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $newEtag | Set-Content -Path $etagPath -Encoding ASCII
        }
        catch {
        }
    }

    return $result
}

function Get-OpenPathMachineTokenFromWhitelistUrl {
    <#
    .SYNOPSIS
        Extracts machine token from tokenized whitelist URL
    #>
    param(
        [string]$WhitelistUrl
    )

    if (-not $WhitelistUrl) {
        return $null
    }

    if ($WhitelistUrl -match '/w/([^/]+)/') {
        return [string]$Matches[1]
    }

    return $null
}
