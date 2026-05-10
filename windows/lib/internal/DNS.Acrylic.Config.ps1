function Get-OpenPathDnsSettings {
    [CmdletBinding()]
    param()

    $settings = [ordered]@{
        PrimaryDNS = "8.8.8.8"
        SecondaryDNS = "8.8.4.4"
        MaxDomains = 500
    }

    try {
        $config = Get-OpenPathConfig
        if ($config.PSObject.Properties['primaryDNS'] -and $config.primaryDNS) { $settings.PrimaryDNS = [string]$config.primaryDNS }
        if ($config.PSObject.Properties['secondaryDNS'] -and $config.secondaryDNS) { $settings.SecondaryDNS = [string]$config.secondaryDNS }
        if ($config.PSObject.Properties['maxDomains'] -and ($config.maxDomains -as [int]) -gt 0) { $settings.MaxDomains = [int]$config.maxDomains }
    }
    catch {
        Write-Debug "OpenPath DNS settings unavailable, using defaults: $_"
    }

    return [PSCustomObject]$settings
}

function Resolve-SslipIpv4Address {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Domain)

    $match = [regex]::Match($Domain, '(?i)(?:^|\.)(?<ip>(?:\d{1,3}\.){3}\d{1,3})\.sslip\.io$')
    if (-not $match.Success) { return $null }

    $octets = @($match.Groups['ip'].Value.Split('.') | ForEach-Object { [int]$_ })
    foreach ($octet in $octets) {
        if ($octet -lt 0 -or $octet -gt 255) { return $null }
    }

    return ($octets -join '.')
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

    if ($blockedDescendants.Count -eq 0) {
        if ($sslipIpv4Address) {
            return @("$sslipIpv4Address $normalizedDomain", "$sslipIpv4Address >$normalizedDomain")
        }

        return @("FW $normalizedDomain", "FW >$normalizedDomain")
    }

    $escapedDomain = [regex]::Escape($normalizedDomain)
    $escapedBlockedPattern = ($blockedDescendants -join '|')
    return @("FW $normalizedDomain", "FW /^(?!(?:.*\.)?(?:$escapedBlockedPattern)$).*\.$escapedDomain$")
}

function Get-AcrylicEssentialDomainGroups {
    [CmdletBinding()]
    param()

    return @(
        [PSCustomObject]@{ Comment = '# Control plane and bootstrap/download'; Domains = @(Get-OpenPathProtectedDomains) },
        [PSCustomObject]@{ Comment = '# Captive portal detection'; Domains = @('detectportal.firefox.com', 'connectivity-check.ubuntu.com', 'captive.apple.com', 'www.msftconnecttest.com', 'msftconnecttest.com', 'clients3.google.com') },
        [PSCustomObject]@{ Comment = '# Windows Update (optional, comment out if not needed)'; Domains = @('windowsupdate.microsoft.com', 'update.microsoft.com') },
        [PSCustomObject]@{ Comment = '# NTP'; Domains = @('time.windows.com', 'time.google.com') }
    )
}

function Get-AcrylicAffinityMaskEntries {
    [CmdletBinding()]
    param([string[]]$Domains = @())

    $entries = [System.Collections.Generic.List[string]]::new()
    $seenEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($domain in @($Domains)) {
        $normalizedDomain = ([string]$domain).Trim().TrimEnd('.')
        if ($normalizedDomain.StartsWith('*.')) { $normalizedDomain = $normalizedDomain.Substring(2) }
        if (-not $normalizedDomain) { continue }

        foreach ($entry in @($normalizedDomain, "*.$normalizedDomain")) {
            if ($seenEntries.Add($entry)) { [void]$entries.Add($entry) }
        }
    }

    return $entries.ToArray()
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
    foreach ($group in @(Get-AcrylicEssentialDomainGroups)) {
        if ($essentialLines.Count -gt 0) { $essentialLines += '' }
        $essentialLines += $group.Comment
        foreach ($domain in @($group.Domains)) {
            $essentialDomains += $domain
            $essentialLines += @(Get-AcrylicForwardRules -Domain $domain)
        }
    }

    $blockedLines = @(foreach ($subdomain in $BlockedSubdomains) { $normalizedSubdomain = ([string]$subdomain).Trim(); if ($normalizedSubdomain) { "NX >$normalizedSubdomain" } })
    $whitelistLines = @(foreach ($domain in $effectiveWhitelistedDomains) { @(Get-AcrylicForwardRules -Domain $domain -BlockedSubdomains $BlockedSubdomains) })

    $sections = @(
        (New-AcrylicHostsSection -Title 'ESSENTIAL DOMAINS (always allowed)' -Description 'Required for system operation' -Lines $essentialLines)
    )
    if ($blockedLines.Count -gt 0) {
        $sections += New-AcrylicHostsSection -Title "BLOCKED SUBDOMAINS ($($blockedLines.Count))" -Lines $blockedLines
    }
    $sections += New-AcrylicHostsSection -Title "WHITELISTED DOMAINS ($($effectiveWhitelistedDomains.Count))" -Lines @($whitelistLines)
    $sections += New-AcrylicHostsSection -Title 'DEFAULT BLOCK (NXDOMAIN for everything else)' -Description 'This MUST come last after FW rules.' -Lines @('NX *')

    $affinityMaskEntries = Get-AcrylicAffinityMaskEntries -Domains @($essentialDomains + $effectiveWhitelistedDomains)

    return [PSCustomObject]@{
        UpstreamDNS = $DnsSettings.PrimaryDNS
        Sections = $sections
        WasTruncated = $wasTruncated
        OriginalWhitelistedDomainCount = $originalWhitelistedDomainCount
        EffectiveWhitelistedDomains = $effectiveWhitelistedDomains
        EssentialDomains = @($essentialDomains)
        AffinityMaskEntries = @($affinityMaskEntries)
        DomainAffinityMask = ($affinityMaskEntries -join ';')
        BlockedSubdomains = @($BlockedSubdomains)
    }
}

function ConvertTo-AcrylicHostsContent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Definition)

    $lines = @(
        '# ========================================',
        '# OpenPath DNS - Generated by openpath-windows',
        "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "# Upstream DNS: $($Definition.UpstreamDNS)",
        '# ========================================',
        ''
    )

    foreach ($section in @($Definition.Sections)) {
        $lines += '# ========================================'
        $lines += "# $($section.Title)"
        if ($section.Description) { $lines += "# $($section.Description)" }
        $lines += '# ========================================'
        $lines += ''
        $sectionLines = @($section.Lines)
        if ($sectionLines.Count -gt 0) { $lines += $sectionLines }
        $lines += ''
    }

    return (($lines -join "`n").TrimEnd() + "`n")
}

function Update-AcrylicHost {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$WhitelistedDomains,
        [string[]]$BlockedSubdomains = @()
    )

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) {
        Write-OpenPathLog "Acrylic not found" -Level ERROR
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("AcrylicHosts.txt", "Update whitelist configuration")) { return $false }

    $hostsPath = "$acrylicPath\AcrylicHosts.txt"
    $dnsSettings = Get-OpenPathDnsSettings
    $definition = New-AcrylicHostsDefinition -WhitelistedDomains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains -DnsSettings $dnsSettings
    if ($definition.WasTruncated) {
        Write-OpenPathLog "Truncating whitelist from $($definition.OriginalWhitelistedDomainCount) to $($dnsSettings.MaxDomains) domains" -Level WARN
    }
    Write-OpenPathLog "Generating AcrylicHosts.txt with $(@($definition.EffectiveWhitelistedDomains).Count) domains..."
    $content = ConvertTo-AcrylicHostsContent -Definition $definition
    $content | Set-Content $hostsPath -Encoding ASCII -Force

    $configurationUpdated = Set-AcrylicConfiguration -WhitelistedDomains $definition.EffectiveWhitelistedDomains
    if (-not $configurationUpdated) {
        Write-OpenPathLog "Failed to update AcrylicConfiguration.ini" -Level ERROR
        return $false
    }
    Write-OpenPathLog "AcrylicHosts.txt updated"
    return $true
}

function Set-AcrylicGlobalSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value
    )

    $escapedKey = [regex]::Escape($Key)
    $pattern = "(?m)^$escapedKey=.*$"
    $replacement = "$Key=$Value"
    if ($Content -match $pattern) {
        return ($Content -replace $pattern, $replacement)
    }

    $nextSection = [regex]::Match($Content, '(?m)^\[(?!GlobalSection\])[^]]+\]\s*$')
    if ($nextSection.Success) {
        return $Content.Insert($nextSection.Index, "$replacement`n")
    }

    return ($Content.TrimEnd() + "`n$replacement`n")
}

function Set-AcrylicAllowedAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Content -notmatch '(?m)^\[AllowedAddressesSection\]\s*$') {
        $Content = $Content.TrimEnd() + "`n`n[AllowedAddressesSection]`n"
    }

    $escapedKey = [regex]::Escape($Key)
    $pattern = "(?m)^$escapedKey=.*$"
    $replacement = "$Key=$Value"
    if ($Content -match $pattern) {
        return ($Content -replace $pattern, $replacement)
    }

    $allowedSection = [regex]::Match($Content, '(?m)^\[AllowedAddressesSection\]\s*$')
    if ($allowedSection.Success) {
        return $Content.Insert($allowedSection.Index + $allowedSection.Length, "`n$replacement")
    }

    return ($Content.TrimEnd() + "`n`n[AllowedAddressesSection]`n$replacement`n")
}

function Set-AcrylicConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowEmptyCollection()][string[]]$WhitelistedDomains = @())

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }
    if (-not $PSCmdlet.ShouldProcess("AcrylicConfiguration.ini", "Configure Acrylic settings")) { return $false }

    $configPath = "$acrylicPath\AcrylicConfiguration.ini"
    $dnsSettings = Get-OpenPathDnsSettings
    Write-OpenPathLog "Configuring Acrylic..."

    $allowedForwardDomains = @(
        foreach ($group in @(Get-AcrylicEssentialDomainGroups)) {
            @($group.Domains)
        }
    ) + @($WhitelistedDomains)
    $affinityMaskEntries = Get-AcrylicAffinityMaskEntries -Domains $allowedForwardDomains
    $domainAffinityMask = ($affinityMaskEntries -join ';')

    $iniContent = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { "" }
    if ($iniContent -notmatch '(?m)^\[GlobalSection\]\s*$') {
        $iniContent = "[GlobalSection]`n$iniContent"
    }
    $settings = [ordered]@{
        "PrimaryServerAddress" = $dnsSettings.PrimaryDNS
        "PrimaryServerPort" = "53"
        "PrimaryServerProtocol" = "UDP"
        "PrimaryServerQueryTypeAffinityMask" = ""
        "SecondaryServerAddress" = $dnsSettings.SecondaryDNS
        "SecondaryServerPort" = "53"
        "SecondaryServerProtocol" = "UDP"
        "SecondaryServerQueryTypeAffinityMask" = ""
        "LocalIPv4BindingAddress" = "0.0.0.0"
        "LocalIPv4BindingPort" = "53"
        "LocalIPv6BindingAddress" = ""
        "LocalIPv6BindingPort" = "53"
        "LocalIPv6BindingEnabledOnWindowsVersionsPriorToWindowsVistaOrWindowsServer2008" = "No"
        "GeneratedResponseTimeToLive" = "300"
        "PrimaryServerDomainNameAffinityMask" = $domainAffinityMask
        "SecondaryServerDomainNameAffinityMask" = $domainAffinityMask
        "IgnoreFailureResponsesFromPrimaryServer" = "No"
        "IgnoreNegativeResponsesFromPrimaryServer" = "No"
        "IgnoreFailureResponsesFromSecondaryServer" = "No"
        "IgnoreNegativeResponsesFromSecondaryServer" = "No"
        "SinkholeIPv6Lookups" = "No"
        "ForwardPrivateReverseLookups" = "No"
        "AddressCacheFailureTime" = "0"
        "AddressCacheDisabled" = "No"
        "AddressCacheInMemoryOnly" = "Yes"
        "AddressCacheNegativeTime" = "0"
        "AddressCacheScavengingTime" = "5760"
        "AddressCacheSilentUpdateTime" = "1440"
        "AddressCachePeriodicPruningTime" = "360"
        "AddressCacheDomainNameAffinityMask" = "^dns.msftncsi.com;^ipv6.msftncsi.com;^www.msftncsi.com;*"
        "AddressCacheQueryTypeAffinityMask" = "A;AAAA;CNAME;MX;NS;PTR;SOA;SRV;TXT"
        "CacheSize" = "65536"
        "HitLogFileName" = ""
        "HitLogFileWhat" = "XHCF"
        "HitLogFullDump" = "No"
        "HitLogMaxPendingHits" = "512"
        "ErrorLogFileName" = ""
    }

    foreach ($key in $settings.Keys) {
        $iniContent = Set-AcrylicGlobalSetting -Content $iniContent -Key $key -Value $settings[$key]
    }

    if ($iniContent -notmatch '(?m)^\[AllowedAddressesSection\]\s*$') {
        $iniContent = $iniContent.TrimEnd() + "`n`n[AllowedAddressesSection]`n"
    }
    $iniContent = Set-AcrylicAllowedAddress -Content $iniContent -Key 'IP1' -Value '127.*'
    $iniContent = Set-AcrylicAllowedAddress -Content $iniContent -Key 'IP2' -Value '::1'

    $iniContent | Set-Content $configPath -Encoding ASCII -Force
    Write-OpenPathLog "Acrylic configuration updated"
    return $true
}
