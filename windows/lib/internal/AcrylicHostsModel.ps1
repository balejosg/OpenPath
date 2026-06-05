function Resolve-SslipIpv4Address {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Domain)

    $match = [regex]::Match($Domain, '(?i)(?:^|\.)(?<ip>\d{1,3}(?:[.-]\d{1,3}){3})\.sslip\.io$')
    if (-not $match.Success) { return $null }

    $octets = @($match.Groups['ip'].Value -split '[.-]' | ForEach-Object { [int]$_ })
    foreach ($octet in $octets) {
        if ($octet -lt 0 -or $octet -gt 255) { return $null }
    }

    return ($octets -join '.')
}

function Test-AcrylicStaticAddressDomain {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Domain)

    return ($null -ne (Resolve-SslipIpv4Address -Domain $Domain))
}

function Get-AcrylicForwardRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string[]]$BlockedSubdomains = @()
    )

    $normalizedDomain = $Domain.Trim()
    if (-not $normalizedDomain) { return @() }
    $sslipIpv4Address = Resolve-SslipIpv4Address -Domain $normalizedDomain

    $blockedDescendants = @(
        foreach ($subdomain in @($BlockedSubdomains)) {
            $normalizedSubdomain = ([string]$subdomain).Trim().Trim('.')
            if (-not $normalizedSubdomain) { continue }
            if ($normalizedSubdomain.Length -le ($normalizedDomain.Length + 1)) { continue }
            if (-not $normalizedSubdomain.EndsWith(".$normalizedDomain", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            [regex]::Escape($normalizedSubdomain)
        }
    )

    if ($sslipIpv4Address) {
        if ($blockedDescendants.Count -eq 0) {
            return @("$sslipIpv4Address $normalizedDomain", "FW >$normalizedDomain")
        }

        $escapedDomain = [regex]::Escape($normalizedDomain)
        $escapedBlockedPattern = ($blockedDescendants -join '|')
        return @("$sslipIpv4Address $normalizedDomain", "FW /^(?!(?:.*\.)?(?:$escapedBlockedPattern)$).*\.$escapedDomain$")
    }

    if ($blockedDescendants.Count -eq 0) {
        return @("FW $normalizedDomain", "FW >$normalizedDomain")
    }

    $escapedDomain = [regex]::Escape($normalizedDomain)
    $escapedBlockedPattern = ($blockedDescendants -join '|')
    return @("FW $normalizedDomain", "FW /^(?!(?:.*\.)?(?:$escapedBlockedPattern)$).*\.$escapedDomain$")
}

function Get-AcrylicEssentialDomainGroups {
    [CmdletBinding()]
    param()

    return @(Get-OpenPathAlwaysAllowedDomainGroups)
}

function Get-AcrylicAffinityMaskEntries {
    [CmdletBinding()]
    param(
        [string[]]$Domains = @(),
        [string[]]$BlockedSubdomains = @()
    )

    $entries = [System.Collections.Generic.List[string]]::new()
    $seenEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($domain in @($Domains)) {
        $normalizedDomain = ([string]$domain).Trim().TrimEnd('.')
        if ($normalizedDomain.StartsWith('*.')) { $normalizedDomain = $normalizedDomain.Substring(2) }
        if (-not $normalizedDomain) { continue }

        $hasBlockedDescendant = $false
        foreach ($subdomain in @($BlockedSubdomains)) {
            $normalizedSubdomain = ([string]$subdomain).Trim().TrimEnd('.')
            if (-not $normalizedSubdomain) { continue }
            if ($normalizedSubdomain.Length -le ($normalizedDomain.Length + 1)) { continue }
            if ($normalizedSubdomain.EndsWith(".$normalizedDomain", [System.StringComparison]::OrdinalIgnoreCase)) {
                $hasBlockedDescendant = $true
                break
            }
        }

        $domainEntries = if ($hasBlockedDescendant) { @($normalizedDomain) } else { @($normalizedDomain, "*.$normalizedDomain") }
        foreach ($entry in $domainEntries) {
            if ($seenEntries.Add($entry)) { [void]$entries.Add($entry) }
        }
    }

    return $entries.ToArray()
}

function Get-AcrylicExactAffinityMaskEntries {
    [CmdletBinding()]
    param([string[]]$Domains = @())

    $entries = [System.Collections.Generic.List[string]]::new()
    $seenEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($domain in @($Domains)) {
        $normalizedDomain = ([string]$domain).Trim().TrimEnd('.')
        if ($normalizedDomain.StartsWith('*.')) { $normalizedDomain = $normalizedDomain.Substring(2) }
        if (-not $normalizedDomain) { continue }
        if ($seenEntries.Add($normalizedDomain)) { [void]$entries.Add($normalizedDomain) }
    }

    return $entries.ToArray()
}

function Get-AcrylicAllowedRuntimeDependencyDomains {
    [CmdletBinding()]
    param(
        [string[]]$Domains = @(),
        [string[]]$BlockedSubdomains = @()
    )

    return @(
        foreach ($domain in @($Domains)) {
            $normalizedDependency = ([string]$domain).Trim().Trim('.')
            if (-not $normalizedDependency) { continue }
            if (Test-OpenPathBlockedSubdomainMatch -Domain $normalizedDependency -BlockedSubdomains $BlockedSubdomains) { continue }
            $normalizedDependency
        }
    )
}

function Get-AcrylicExactForwardRule {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Domain)

    $normalizedDomain = $Domain.Trim()
    if (-not $normalizedDomain) { return $null }
    return "FW $normalizedDomain"
}

function New-AcrylicHostsSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Description = "",
        [string[]]$Lines = @()
    )

    return [PSCustomObject]@{
        Title = $Title
        Description = $Description
        Lines = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function New-AcrylicHostsDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$WhitelistedDomains,
        [string[]]$BlockedSubdomains = @(),
        [string[]]$RuntimeDependencyDomains = @(),
        [string[]]$CaptivePortalDomains = @(),
        [pscustomobject]$DnsSettings = (Get-OpenPathDnsSettings)
    )

    $effectiveWhitelistedDomains = @($WhitelistedDomains)
    $originalWhitelistedDomainCount = $effectiveWhitelistedDomains.Count
    $wasTruncated = $false
    if ($effectiveWhitelistedDomains.Count -gt $DnsSettings.MaxDomains) {
        $effectiveWhitelistedDomains = @($effectiveWhitelistedDomains | Select-Object -First $DnsSettings.MaxDomains)
        $wasTruncated = $true
    }

    $essentialLines = @()
    $essentialDomains = @()
    $seenEssentialDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($group in @(Get-AcrylicEssentialDomainGroups)) {
        $groupLines = @()
        foreach ($domain in @($group.Domains)) {
            $normalizedDomain = Normalize-OpenPathAlwaysAllowedDomain -Domain $domain
            if (-not $normalizedDomain) { continue }
            if (-not $seenEssentialDomains.Add($normalizedDomain)) { continue }
            $essentialDomains += $normalizedDomain
            $groupLines += @(Get-AcrylicForwardRules -Domain $normalizedDomain)
        }
        if ($groupLines.Count -eq 0) { continue }
        if ($essentialLines.Count -gt 0) { $essentialLines += '' }
        $essentialLines += $group.Comment
        $essentialLines += $groupLines
    }

    $blockedLines = @(foreach ($subdomain in $BlockedSubdomains) { $normalizedSubdomain = ([string]$subdomain).Trim(); if ($normalizedSubdomain) { "NX >$normalizedSubdomain" } })
    $whitelistLines = @(foreach ($domain in $effectiveWhitelistedDomains) { @(Get-AcrylicForwardRules -Domain $domain -BlockedSubdomains $BlockedSubdomains) })
    $effectiveRuntimeDependencyDomains = @(Get-AcrylicAllowedRuntimeDependencyDomains -Domains $RuntimeDependencyDomains -BlockedSubdomains $BlockedSubdomains)
    $runtimeDependencyLines = @(foreach ($domain in $effectiveRuntimeDependencyDomains) { Get-AcrylicExactForwardRule -Domain $domain })
    $effectiveCaptivePortalDomains = @($CaptivePortalDomains | ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    $captivePortalLines = @(foreach ($domain in $effectiveCaptivePortalDomains) { Get-AcrylicExactForwardRule -Domain $domain })

    $sections = @(
        (New-AcrylicHostsSection -Title 'ESSENTIAL DOMAINS (always allowed)' -Description 'Required for system operation' -Lines $essentialLines)
    )
    if ($blockedLines.Count -gt 0) {
        $sections += New-AcrylicHostsSection -Title "BLOCKED SUBDOMAINS ($($blockedLines.Count))" -Lines $blockedLines
    }
    $sections += New-AcrylicHostsSection -Title "WHITELISTED DOMAINS ($($effectiveWhitelistedDomains.Count))" -Lines @($whitelistLines)
    if ($runtimeDependencyLines.Count -gt 0) {
        $sections += New-AcrylicHostsSection -Title "LOCAL RUNTIME DEPENDENCIES ($($runtimeDependencyLines.Count))" -Lines @($runtimeDependencyLines)
    }
    if ($captivePortalLines.Count -gt 0) {
        $sections += New-AcrylicHostsSection -Title 'Captive portal infrastructure (configured)' -Description 'Configured exact-host captive portal access' -Lines @($captivePortalLines)
    }
    $sections += New-AcrylicHostsSection -Title 'DEFAULT BLOCK (NXDOMAIN for everything else)' -Description 'This MUST come last after FW rules.' -Lines @('NX *')

    $affinityMaskEntries = @(
        Get-AcrylicAffinityMaskEntries -Domains @($essentialDomains)
        Get-AcrylicAffinityMaskEntries -Domains @($effectiveWhitelistedDomains) -BlockedSubdomains $BlockedSubdomains
        Get-AcrylicExactAffinityMaskEntries -Domains @($effectiveRuntimeDependencyDomains)
        Get-AcrylicExactAffinityMaskEntries -Domains @($effectiveCaptivePortalDomains)
    ) | Select-Object -Unique

    return [PSCustomObject]@{
        UpstreamDNS = $DnsSettings.PrimaryDNS
        Sections = $sections
        WasTruncated = $wasTruncated
        OriginalWhitelistedDomainCount = $originalWhitelistedDomainCount
        EffectiveWhitelistedDomains = $effectiveWhitelistedDomains
        EssentialDomains = @($essentialDomains)
        RuntimeDependencyDomains = @($effectiveRuntimeDependencyDomains)
        CaptivePortalDomains = @($effectiveCaptivePortalDomains)
        AffinityMaskEntries = @($affinityMaskEntries)
        DomainAffinityMask = ($affinityMaskEntries -join ';')
        BlockedSubdomains = @($BlockedSubdomains)
    }
}
