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

function Invoke-OpenPathPolicyStateLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [string]$MutexName = 'Global\OpenPathPolicyStateLock',
        # bounds the wait for the named system mutex before throwing a timeout error.
        [int]$TimeoutMilliseconds = 15000
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $lockAcquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if (-not $lockAcquired) {
            throw "Timed out waiting for $MutexName"
        }

        return (& $Action)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try { $mutex.ReleaseMutex() }
            catch [System.ApplicationException] { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
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

    return [bool](Invoke-OpenPathPolicyStateLocked -Action {
        $hostsPath = "$acrylicPath\AcrylicHosts.txt"
        $dnsSettings = Get-OpenPathDnsSettings
        $captivePortalDomains = @()
        try {
            $openPathConfig = Get-OpenPathConfig
            if ($openPathConfig.PSObject.Properties['captivePortalDomains']) {
                $captivePortalDomains = @($openPathConfig.captivePortalDomains)
            }
        }
        catch {
            Write-Debug "OpenPath captive portal domains unavailable, using none: $_"
        }
        $runtimeDependencyDomains = Get-OpenPathRuntimeDependencyDomains -WhitelistedDomains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains -Prune
        $definition = New-AcrylicHostsDefinition -WhitelistedDomains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains -RuntimeDependencyDomains $runtimeDependencyDomains -CaptivePortalDomains $captivePortalDomains -DnsSettings $dnsSettings
        if ($definition.WasTruncated) {
            Write-OpenPathLog "Truncating whitelist from $($definition.OriginalWhitelistedDomainCount) to $($dnsSettings.MaxDomains) domains" -Level WARN
        }
        Write-OpenPathLog "Generating AcrylicHosts.txt with $(@($definition.EffectiveWhitelistedDomains).Count) domains..."
        $content = ConvertTo-AcrylicHostsContent -Definition $definition
        Write-AcrylicHostsFile -Path $hostsPath -Content $content

        $configurationUpdated = Set-AcrylicConfiguration -WhitelistedDomains $definition.EffectiveWhitelistedDomains -BlockedSubdomains $definition.BlockedSubdomains -RuntimeDependencyDomains $definition.RuntimeDependencyDomains -CaptivePortalDomains $definition.CaptivePortalDomains
        if (-not $configurationUpdated) {
            Write-OpenPathLog "Failed to update AcrylicConfiguration.ini" -Level ERROR
            return $false
        }
        Write-OpenPathLog "AcrylicHosts.txt updated"
        return $true
    })
}

function Set-AcrylicConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowEmptyCollection()][string[]]$WhitelistedDomains = @(),
        [AllowEmptyCollection()][string[]]$BlockedSubdomains = @(),
        [AllowEmptyCollection()][string[]]$RuntimeDependencyDomains = @(),
        [AllowEmptyCollection()][string[]]$CaptivePortalDomains = @()
    )

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }
    if (-not $PSCmdlet.ShouldProcess("AcrylicConfiguration.ini", "Configure Acrylic settings")) { return $false }

    $configPath = "$acrylicPath\AcrylicConfiguration.ini"
    $dnsSettings = Get-OpenPathDnsSettings
    Write-OpenPathLog "Configuring Acrylic..."

    $essentialForwardDomains = @(
        foreach ($group in @(Get-AcrylicEssentialDomainGroups)) {
            @($group.Domains)
        }
    )
    $affinityMaskEntries = @(
        Get-AcrylicAffinityMaskEntries -Domains $essentialForwardDomains
        Get-AcrylicAffinityMaskEntries -Domains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains
        Get-AcrylicExactAffinityMaskEntries -Domains (Get-AcrylicAllowedRuntimeDependencyDomains -Domains $RuntimeDependencyDomains -BlockedSubdomains $BlockedSubdomains)
        Get-AcrylicExactAffinityMaskEntries -Domains $CaptivePortalDomains
    ) | Select-Object -Unique
    $domainAffinityMask = ($affinityMaskEntries -join ';')

    # Permanent split DNS for the admin-declared captive-portal domains: they are
    # internal names only the network's own (DHCP-offered) resolver can answer --
    # the configured upstreams return NXDOMAIN for them, which is exactly the
    # production failure this replaces the stateful limited-mode lifecycle for.
    # ONLY the declared portal domains ride the network resolver; everything else,
    # including the connectivity-probe endpoints, resolves exclusively through the
    # configured upstreams. Probe domains are intentionally NOT routed to the
    # network DNS: captive detection already works via transport failure
    # (Test-OpenPathCaptivePortalState returns 'Portal' when every probe fails and
    # a gateway exists), and routing them to the network resolver would make them
    # answer with the portal's own address even after authentication.
    $normalizedPortalDomains = @(
        $CaptivePortalDomains |
            ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    $portalUpstreams = @()
    if ($normalizedPortalDomains.Count -gt 0 -and (Get-Command -Name 'Get-OpenPathSplitDnsPortalUpstreams' -ErrorAction SilentlyContinue)) {
        $portalUpstreams = @(Get-OpenPathSplitDnsPortalUpstreams -ExcludeAddresses @($dnsSettings.PrimaryDNS, $dnsSettings.SecondaryDNS))
    }
    $portalExclusionEntries = @(
        foreach ($portalDomain in $normalizedPortalDomains) {
            "^$portalDomain"
            "^*.$portalDomain"
        }
    )
    $splitDnsActive = ($portalUpstreams.Count -gt 0)
    # The captive-portal domains are also rendered as POSITIVE exact entries in
    # $affinityMaskEntries (line above). When split DNS is active they must NOT
    # stay on the configured upstreams: Acrylic forwards a query to EVERY server
    # whose mask matches it, first response wins, so a portal host left positively
    # on the primary races a fast public NXDOMAIN against the network resolver's
    # real answer. Drop the portal positives (the negations + tertiary placement
    # do the routing). Probe domains stay on the configured upstreams only.
    $portalPositiveEntries = @(Get-AcrylicExactAffinityMaskEntries -Domains $normalizedPortalDomains)
    $configuredUpstreamMask = if ($splitDnsActive) {
        (@($portalExclusionEntries) + @($affinityMaskEntries | Where-Object { $portalPositiveEntries -notcontains $_ })) -join ';'
    }
    else {
        $domainAffinityMask
    }
    $portalUpstreamMask = if ($splitDnsActive) {
        (@(Get-AcrylicAffinityMaskEntries -Domains $normalizedPortalDomains -BlockedSubdomains $BlockedSubdomains) |
            Select-Object -Unique) -join ';'
    }
    else {
        ''
    }
    $addressCacheBaseMask = '^dns.msftncsi.com;^ipv6.msftncsi.com;^www.msftncsi.com;*'
    $addressCacheMask = if ($splitDnsActive) {
        # Network-local portal answers must never be cached across networks.
        (@($portalExclusionEntries) + @($addressCacheBaseMask)) -join ';'
    }
    else {
        $addressCacheBaseMask
    }

    $existingIniContent = $null
    try {
        if (Test-Path $configPath -ErrorAction SilentlyContinue) {
            $existingIniContent = Get-Content $configPath -Raw -ErrorAction Stop
        }
    }
    catch {
        Write-OpenPathLog "AcrylicConfiguration.ini is unreadable; rebuilding required resolver defaults: $_" -Level WARN
        $existingIniContent = $null
    }

    $iniContent = if ([string]::IsNullOrWhiteSpace([string]$existingIniContent)) {
        "[GlobalSection]`n"
    }
    else {
        [string]$existingIniContent
    }
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
        "TertiaryServerAddress" = $(if ($portalUpstreams.Count -ge 1) { [string]$portalUpstreams[0] } else { '' })
        "TertiaryServerPort" = "53"
        "TertiaryServerProtocol" = "UDP"
        "TertiaryServerDomainNameAffinityMask" = $(if ($portalUpstreams.Count -ge 1) { $portalUpstreamMask } else { '' })
        "QuaternaryServerAddress" = $(if ($portalUpstreams.Count -ge 2) { [string]$portalUpstreams[1] } else { '' })
        "QuaternaryServerPort" = "53"
        "QuaternaryServerProtocol" = "UDP"
        "QuaternaryServerDomainNameAffinityMask" = $(if ($portalUpstreams.Count -ge 2) { $portalUpstreamMask } else { '' })
        "LocalIPv4BindingAddress" = "0.0.0.0"
        "LocalIPv4BindingPort" = "53"
        "LocalIPv6BindingAddress" = ""
        "LocalIPv6BindingPort" = "53"
        "LocalIPv6BindingEnabledOnWindowsVersionsPriorToWindowsVistaOrWindowsServer2008" = "No"
        "GeneratedResponseTimeToLive" = "300"
        "PrimaryServerDomainNameAffinityMask" = $configuredUpstreamMask
        "SecondaryServerDomainNameAffinityMask" = $configuredUpstreamMask
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
        "AddressCacheDomainNameAffinityMask" = $addressCacheMask
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

    Write-AcrylicConfigFile -Path $configPath -Content $iniContent
    Write-OpenPathLog "Acrylic configuration updated"
    if ($splitDnsActive) {
        Write-OpenPathLog "Acrylic split DNS active: $($normalizedPortalDomains -join ', ') -> $($portalUpstreams -join ', ')"
    }
    return $true
}

function Get-OpenPathExpectedSplitDnsPortalUpstreams {
    $declaredPortalDomains = @()
    try {
        $config = Get-OpenPathConfig
        if ($config.PSObject.Properties['captivePortalDomains']) {
            $declaredPortalDomains = @($config.captivePortalDomains | Where-Object { $_ })
        }
    }
    catch {
        $declaredPortalDomains = @()
    }
    if ($declaredPortalDomains.Count -le 0) {
        return @()
    }
    if (-not (Get-Command -Name 'Get-OpenPathSplitDnsPortalUpstreams' -ErrorAction SilentlyContinue)) {
        return @()
    }

    $dnsSettings = Get-OpenPathDnsSettings
    return @(Get-OpenPathSplitDnsPortalUpstreams -ExcludeAddresses @($dnsSettings.PrimaryDNS, $dnsSettings.SecondaryDNS))
}

function Test-OpenPathSplitDnsActive {
    <#
    .SYNOPSIS
        True when permanent split DNS is the active mechanism for the current
        network: admin-declared captive-portal domains exist AND a usable network
        (DHCP-offered) resolver was found to serve them on Acrylic's third upstream.
        When true, the legacy limited/passthrough captive-portal lifecycle is
        redundant -- the declared portal hosts already resolve in protected mode.
    #>
    return [bool](@(Get-OpenPathExpectedSplitDnsPortalUpstreams).Count -gt 0)
}

function Test-OpenPathSplitDnsTopologyDrift {
    <#
    .SYNOPSIS
        Detects whether the third/fourth Acrylic upstreams no longer match the
        network's current DHCP resolvers (e.g. after roaming to another network).
        The INI itself is the persisted state -- no extra state file.
    #>
    $expected = @(Get-OpenPathExpectedSplitDnsPortalUpstreams | Sort-Object -Unique)

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) {
        return [PSCustomObject]@{ Drifted = $false; Reason = 'acrylic-missing'; Expected = $expected; Current = @() }
    }
    $configPath = "$acrylicPath\AcrylicConfiguration.ini"
    $current = @()
    try {
        $content = Get-Content $configPath -Raw -ErrorAction Stop
        foreach ($key in @('TertiaryServerAddress', 'QuaternaryServerAddress')) {
            # Match only on the key's own line. \s would swallow the LF that
            # Set-AcrylicGlobalSetting writes after an empty value, letting the
            # capture grab the NEXT line (e.g. an empty QuaternaryServerAddress
            # reading as "QuaternaryServerPort=53") and falsely report drift every
            # cycle -> a perpetual Acrylic rewrite/restart loop.
            $match = [regex]::Match($content, "(?m)^[ \t]*$key[ \t]*=[ \t]*([^\r\n]*?)[ \t]*$")
            if ($match.Success -and $match.Groups[1].Value) {
                $current += [string]$match.Groups[1].Value
            }
        }
    }
    catch {
        return [PSCustomObject]@{ Drifted = $false; Reason = 'config-unreadable'; Expected = $expected; Current = @() }
    }

    $currentSet = @($current | Sort-Object -Unique)
    return [PSCustomObject]@{
        Drifted = (($expected -join ',') -ne ($currentSet -join ','))
        Reason = "expected=[$($expected -join ',')] current=[$($currentSet -join ',')]"
        Expected = $expected
        Current = $currentSet
    }
}
