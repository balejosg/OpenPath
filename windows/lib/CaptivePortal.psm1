# OpenPath Captive Portal Module for Windows
# Detects captive portals and manages temporary fail-open mode.

# Import common functions
$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
. (Join-Path $PSScriptRoot 'internal\AcrylicHostsModel.ps1')
. (Join-Path $PSScriptRoot 'internal\AcrylicHostsRenderer.ps1')
. (Join-Path $PSScriptRoot 'internal\AcrylicConfigWriter.ps1')
. (Join-Path $PSScriptRoot 'internal\CaptivePortal.AcrylicPolicyTransaction.ps1')
$runtimeDependencyOverlayPath = Join-Path $PSScriptRoot 'internal\RuntimeDependency.Overlay.ps1'
if (Test-Path $runtimeDependencyOverlayPath -ErrorAction SilentlyContinue) {
    . $runtimeDependencyOverlayPath
}
$runtimeDependencyPolicyPath = Join-Path $PSScriptRoot 'internal\RuntimeDependency.Policy.ps1'
if (Test-Path $runtimeDependencyPolicyPath -ErrorAction SilentlyContinue) {
    . $runtimeDependencyPolicyPath
}
. (Join-Path $PSScriptRoot 'internal\CaptivePortal.DiagnosticsDiscovery.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
$script:CaptivePortalStatePath = "$script:OpenPathRoot\data\captive-portal-active.json"
$script:CaptivePortalObservationPath = "$script:OpenPathRoot\data\captive-portal-observation.json"
$script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds = 8
$script:CaptivePortalLimitedModeDnsMaxAttempts = 5
$script:CaptivePortalLimitedModeDnsDelayMilliseconds = 500
$script:CaptivePortalLimitedModeDnsAttemptTimeoutSeconds = 1
$script:CaptivePortalBootstrapMaxIterations = 3

function Test-OpenPathCaptivePortalModeActive {
    <#
    .SYNOPSIS
        Returns true when a captive portal marker file is present and not yet expired.
    .DESCRIPTION
        Reads the state file at $script:CaptivePortalStatePath. If the marker has
        expired and $SkipExpiredRestore is not set, calls Disable-OpenPathCaptivePortalMode
        to restore protected mode before returning. Writes a WARN log entry on
        expiry-restore failure.
    .PARAMETER SkipExpiredRestore
        When set, skips the automatic restore on an expired marker and simply
        returns true (the marker is still considered active for caller decisions).
    .OUTPUTS
        Boolean
    #>
    param(
        [switch]$SkipExpiredRestore
    )

    if (-not (Test-Path $script:CaptivePortalStatePath)) {
        return $false
    }

    $marker = Get-OpenPathCaptivePortalMarker
    if (-not $marker) {
        return $true
    }

    if (Test-OpenPathCaptivePortalMarkerExpired -Marker $marker) {
        if ($SkipExpiredRestore) { return $true }
        if ((Get-OpenPathCaptivePortalMarkerMode -Marker $marker) -eq 'passthrough') {
            Write-OpenPathLog 'Watchdog: captive portal passthrough deadline expired; attempting protected-mode restore' -Level WARN
        }
        $disabled = Disable-OpenPathCaptivePortalMode
        if (-not [bool]$disabled) {
            Write-OpenPathLog 'Watchdog: failed to close expired captive portal passthrough marker; keeping marker active (details redacted)' -Level WARN
        }
        return (-not [bool]$disabled)
    }

    return $true
}

function Test-OpenPathCaptivePortalMarkerExpired {
    <#
    .SYNOPSIS
        Returns true when the marker's expiresAt timestamp is in the past.
    .PARAMETER Marker
        Deserialized marker object from Get-OpenPathCaptivePortalMarker. If null,
        the marker is fetched from disk automatically.
    .OUTPUTS
        Boolean
    #>
    param([object]$Marker = $null)

    if (-not $Marker) {
        $Marker = Get-OpenPathCaptivePortalMarker
    }
    if (-not $Marker -or -not $Marker.PSObject.Properties['expiresAt'] -or -not $Marker.expiresAt) {
        return $false
    }

    try {
        return ([DateTime]::UtcNow -ge ([DateTimeOffset]::Parse([string]$Marker.expiresAt)).UtcDateTime)
    }
    catch {
        return $false
    }
}

function Get-OpenPathCaptivePortalMarker {
    <#
    .SYNOPSIS
        Reads and deserializes the captive portal state file from disk.
    .DESCRIPTION
        Reads $script:CaptivePortalStatePath (C:\OpenPath\data\captive-portal-active.json).
        Returns null when the file is absent, empty, or unparseable.
    .OUTPUTS
        PSCustomObject or $null
    #>
    if (-not (Test-Path $script:CaptivePortalStatePath)) {
        return $null
    }

    try {
        $raw = Get-Content $script:CaptivePortalStatePath -Raw -ErrorAction Stop
        if (-not $raw) {
            return $null
        }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Set-OpenPathCaptivePortalMarker {
    <#
    .SYNOPSIS
        Writes the captive portal state JSON file to disk, creating its parent directory if needed.
    .DESCRIPTION
        Serializes portal state to $script:CaptivePortalStatePath
        (C:\OpenPath\data\captive-portal-active.json). Preserves the original
        'since' timestamp from any existing marker. Computes configuredCaptivePortalDomainsApplied
        automatically when ConfiguredCaptivePortalDomainsApplied is not explicitly supplied.
    .PARAMETER State
        Arbitrary state label (e.g. 'Portal', 'Authenticated') stored in the marker.
    .PARAMETER AllowedHosts
        Normalized hostnames whose DNS queries are forwarded in limited mode.
    .PARAMETER UpstreamDns
        IP address of the temporary upstream DNS resolver used during portal mode.
    .PARAMETER Mode
        Portal operating mode: 'limited' (adapter stays on 127.0.0.1, NX * in effect)
        or 'passthrough' (adapter DNS reset to network resolver, full egress open).
    .PARAMETER UpstreamDnsSource
        Label describing how the upstream DNS address was obtained (e.g. 'dhcp', 'marker').
    .PARAMETER UpstreamUsableForLimited
        Whether the upstream is safe to use for limited-mode forwarding.
    .PARAMETER UpstreamVerified
        Whether the upstream DNS address has been verified reachable.
    .PARAMETER DnsResetAt
        ISO-8601 timestamp recorded when the adapter DNS was reset (passthrough entry).
    .PARAMETER UpstreamCapturedAt
        ISO-8601 timestamp recorded when the upstream address was captured.
    .PARAMETER PassthroughEgress
        Object from Test-OpenPathCaptivePortalPassthroughEgress describing egress connectivity.
    .PARAMETER BootstrapHosts
        Hostnames used as the initial set of portal recovery domains.
    .PARAMETER RedirectHosts
        Hostnames discovered via redirect following during portal recovery.
    .PARAMETER ResourceHosts
        Hostnames discovered as static resources during portal recovery.
    .PARAMETER ObservedRuntimeHosts
        Additional hostnames discovered at runtime and already applied.
    .PARAMETER PendingRuntimeHosts
        Hostnames discovered but not yet applied to Acrylic.
    .PARAMETER DiscoveryTruncated
        True when the discovery phase hit its domain-count limit.
    .PARAMETER FallbackMode
        Fallback escalation mode recorded in the marker: 'none' or 'passthrough'.
    .PARAMETER LimitedModeReady
        True when all declared recovery hosts are confirmed resolvable.
    .PARAMETER ConfiguredCaptivePortalDomains
        Admin-declared captive portal domains from the local config.
    .PARAMETER ConfiguredCaptivePortalDomainsApplied
        Override for the computed configuredCaptivePortalDomainsApplied field.
    .PARAMETER TtlSeconds
        Seconds until the marker expires; clamped to at least 1 second.
    .OUTPUTS
        Boolean — true on success, false on I/O error
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$State,

        [string[]]$AllowedHosts = @(),

        [string]$UpstreamDns = '',

        [ValidateSet('limited', 'passthrough')]
        [string]$Mode = 'limited',

        [string]$UpstreamDnsSource = '',

        [bool]$UpstreamUsableForLimited = $false,

        [bool]$UpstreamVerified = $false,

        [string]$DnsResetAt = '',

        [string]$UpstreamCapturedAt = '',

        [object]$PassthroughEgress = $null,

        [string[]]$BootstrapHosts = @(),

        [string[]]$RedirectHosts = @(),

        [string[]]$ResourceHosts = @(),

        [string[]]$ObservedRuntimeHosts = @(),

        [string[]]$PendingRuntimeHosts = @(),

        [bool]$DiscoveryTruncated = $false,

        [ValidateSet('none', 'passthrough')]
        [string]$FallbackMode = 'none',

        [bool]$LimitedModeReady = $false,

        [string[]]$ConfiguredCaptivePortalDomains = @(),

        [bool]$ConfiguredCaptivePortalDomainsApplied = $false,

        [int]$TtlSeconds = 300
    )

    try {
        $dir = Split-Path $script:CaptivePortalStatePath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $existing = Get-OpenPathCaptivePortalMarker
        $since = (Get-Date).ToString('o')
        if ($existing -and $existing.PSObject.Properties['since'] -and $existing.since) {
            $since = [string]$existing.since
        }

        $configuredDomains = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts $ConfiguredCaptivePortalDomains)
        $configuredDomainsApplied = if ($PSBoundParameters.ContainsKey('ConfiguredCaptivePortalDomainsApplied')) {
            [bool]$ConfiguredCaptivePortalDomainsApplied
        }
        else {
            $allConfiguredDomainsApplied = $true
            foreach ($configuredDomain in @($configuredDomains)) {
                if (@($AllowedHosts) -notcontains $configuredDomain) {
                    $allConfiguredDomainsApplied = $false
                    break
                }
            }
            $allConfiguredDomainsApplied
        }

        $payload = @{
            active = $true
            state = [string]$State
            mode = [string]$Mode
            allowedHosts = @($AllowedHosts)
            configuredCaptivePortalDomains = @($configuredDomains)
            configuredCaptivePortalDomainsApplied = [bool]$configuredDomainsApplied
            bootstrapHosts = @($BootstrapHosts)
            redirectHosts = @($RedirectHosts)
            resourceHosts = @($ResourceHosts)
            observedRuntimeHosts = @($ObservedRuntimeHosts)
            pendingRuntimeHosts = @($PendingRuntimeHosts)
            discoveryTruncated = [bool]$DiscoveryTruncated
            fallbackMode = [string]$FallbackMode
            limitedModeReady = [bool]$LimitedModeReady
            expiresAt = ([DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TtlSeconds))).ToString('o')
            upstreamDns = [string]$UpstreamDns
            upstreamDnsSource = [string]$UpstreamDnsSource
            upstreamUsableForLimited = [bool]$UpstreamUsableForLimited
            upstreamVerified = [bool]$UpstreamVerified
            dnsResetAt = [string]$DnsResetAt
            upstreamCapturedAt = [string]$UpstreamCapturedAt
            passthroughEgress = $PassthroughEgress
            since = [string]$since
            updatedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 8

        $payload | Set-Content -Path $script:CaptivePortalStatePath -Encoding UTF8 -Force
        return $true
    }
    catch {
        return $false
    }
}

function Get-OpenPathConfiguredCaptivePortalDomains {
    <#
    .SYNOPSIS
        Returns admin-declared captive portal domains from the local OpenPath config file.
    .DESCRIPTION
        Reads captivePortalDomains from C:\OpenPath\data\config.json via Get-OpenPathConfig.
        Strips URL-scheme and path characters, normalises to lowercase, and filters
        out dynamic/invalid hostnames via Reject-OpenPathCaptivePortalDynamicHost.
        Returns an empty array when the config is absent, unreadable, or has no declared domains.
    .OUTPUTS
        String[]
    #>
    $domains = [System.Collections.Generic.List[string]]::new()

    try {
        $configCommand = Get-Command -Name 'Get-OpenPathConfig' -ErrorAction SilentlyContinue
        if (-not $configCommand) {
            return @()
        }

        $localConfigPath = if ($script:OpenPathRoot -match '^[A-Za-z]:\\') {
            "$($script:OpenPathRoot.TrimEnd('\'))\data\config.json"
        }
        else {
            Join-Path (Join-Path $script:OpenPathRoot 'data') 'config.json'
        }
        if ($configCommand.ModuleName -eq 'Common' -and -not (Test-Path $localConfigPath -ErrorAction SilentlyContinue)) {
            return @()
        }

        $config = Get-OpenPathConfig
        if (-not ($config -and $config.PSObject.Properties['captivePortalDomains'])) {
            return @()
        }

        foreach ($entry in @($config.captivePortalDomains)) {
            if ($null -eq $entry) { continue }
            $raw = ([string]$entry).Trim()
            if (-not $raw) { continue }
            if ($raw -match '^[a-z][a-z0-9+.-]*://') { continue }
            if ($raw -match '[/?#@]') { continue }

            $hostName = $raw.TrimEnd('.').ToLowerInvariant()
            if (Reject-OpenPathCaptivePortalDynamicHost -HostName $hostName) { continue }
            if (-not $domains.Contains($hostName)) {
                $domains.Add($hostName)
            }
        }
    }
    catch {
        return @()
    }

    return @($domains)
}

function Get-OpenPathCaptivePortalAllowedHosts {
    <#
    .SYNOPSIS
        Normalises and deduplicates a list of hostnames for use as portal allowed hosts.
    .PARAMETER Hosts
        Raw hostname strings to normalise; invalid or empty entries are silently dropped.
    .OUTPUTS
        String[] — unique, lowercase, dot-trimmed hostnames matching [a-z0-9.-]+
    #>
    param([string[]]$Hosts = @())

    return @(
        foreach ($hostName in @($Hosts)) {
            $normalizedHost = ([string]$hostName).Trim().TrimEnd('.').ToLowerInvariant()
            if (-not $normalizedHost) { continue }
            if ($normalizedHost -notmatch '^[a-z0-9.-]+$') { continue }
            if ($normalizedHost.StartsWith('.') -or $normalizedHost.EndsWith('.') -or $normalizedHost.Contains('..')) { continue }
            $normalizedHost
        }
    ) | Select-Object -Unique
}

function Get-OpenPathCaptivePortalMarkerMode {
    <#
    .SYNOPSIS
        Extracts the mode field from a marker object, defaulting to 'limited'.
    .PARAMETER Marker
        Deserialized marker object; the 'mode' property must be 'limited' or 'passthrough'.
    .OUTPUTS
        String — 'limited' or 'passthrough'
    #>
    param([object]$Marker)

    if ($Marker -and $Marker.PSObject.Properties['mode'] -and $Marker.mode) {
        $mode = ([string]$Marker.mode).Trim().ToLowerInvariant()
        if ($mode -in @('limited', 'passthrough')) {
            return $mode
        }
    }

    return 'limited'
}

function Get-OpenPathCaptivePortalMarkerAllowedHosts {
    <#
    .SYNOPSIS
        Returns the allowedHosts array from a marker object as a string array.
    .PARAMETER Marker
        Deserialized marker object containing an 'allowedHosts' property.
    .OUTPUTS
        String[]
    #>
    param([object]$Marker)

    if (-not $Marker -or -not $Marker.PSObject.Properties['allowedHosts']) {
        return @()
    }

    return @(
        $Marker.allowedHosts |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-OpenPathCaptivePortalAdaptersUseLocalDns {
    <#
    .SYNOPSIS
        Returns true when every active network adapter has 127.0.0.1 as its IPv4 DNS server.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param()

    try {
        $activeAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    }
    catch {
        $activeAdapters = @()
    }

    if ($activeAdapters.Count -le 0) {
        return $false
    }

    $allDnsAddresses = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)

    foreach ($adapter in $activeAdapters) {
        $interfaceIndex = if ($adapter.PSObject.Properties['ifIndex']) { $adapter.ifIndex } else { $adapter.InterfaceIndex }
        if ($null -eq $interfaceIndex) {
            continue
        }

        $addressRows = @($allDnsAddresses | Where-Object { [int]$_.InterfaceIndex -eq [int]$interfaceIndex })
        $serverAddresses = @()
        foreach ($entry in $addressRows) {
            $serverAddresses += @($entry.ServerAddresses | ForEach-Object { [string]$_ })
        }

        if ($serverAddresses -notcontains '127.0.0.1') {
            return $false
        }
    }

    return $true
}

function Test-OpenPathCaptivePortalAcrylicNormalState {
    <#
    .SYNOPSIS
        Returns true when AcrylicHosts.txt has no captive portal recovery section and
        AcrylicConfiguration.ini matches the expected protected-mode upstream DNS addresses.
    .DESCRIPTION
        Reads AcrylicHosts.txt and AcrylicConfiguration.ini from the Acrylic install path.
        Checks that the hosts file does not contain the string 'CAPTIVE PORTAL RECOVERY' and
        that PrimaryServerAddress/SecondaryServerAddress match the values from Get-OpenPathDnsSettings.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param()

    $acrylicPath = $null
    if (Get-Command -Name 'Get-AcrylicPath' -ErrorAction SilentlyContinue) {
        $acrylicPath = Get-AcrylicPath
    }
    if (-not $acrylicPath) {
        return $false
    }

    $hostsPath = Join-Path $acrylicPath 'AcrylicHosts.txt'
    $configPath = Join-Path $acrylicPath 'AcrylicConfiguration.ini'
    if (-not (Test-Path $hostsPath -ErrorAction SilentlyContinue) -or -not (Test-Path $configPath -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $hostsContent = Get-Content $hostsPath -Raw -ErrorAction Stop
        if ($hostsContent -match 'CAPTIVE PORTAL RECOVERY') {
            return $false
        }

        $dnsSettings = [PSCustomObject]@{
            PrimaryDNS = '8.8.8.8'
            SecondaryDNS = '8.8.4.4'
        }
        if (Get-Command -Name 'Get-OpenPathDnsSettings' -ErrorAction SilentlyContinue) {
            $dnsSettings = Get-OpenPathDnsSettings
        }

        $configContent = Get-Content $configPath -Raw -ErrorAction Stop
        $expectedSettings = [ordered]@{
            PrimaryServerAddress = [string]$dnsSettings.PrimaryDNS
            SecondaryServerAddress = [string]$dnsSettings.SecondaryDNS
        }
        foreach ($key in $expectedSettings.Keys) {
            $pattern = "(?m)^$([regex]::Escape($key))=$([regex]::Escape([string]$expectedSettings[$key]))$"
            if ($configContent -notmatch $pattern) {
                return $false
            }
        }
    }
    catch {
        return $false
    }

    return $true
}

function Get-OpenPathCaptivePortalProtectedModeExitEvidence {
    <#
    .SYNOPSIS
        Collects evidence that the machine has fully exited captive portal mode and
        returned to the protected DNS posture.
    .DESCRIPTION
        Tests local enforcement signals independently of upstream network health:
        adapter loopback (127.0.0.1), normal Acrylic policy, DNS sinkhole, and
        firewall (when enableFirewall is true). Upstream resolution is reported as
        upstreamHealthy but is intentionally excluded from localPostureRestored so
        a blocked upstream never pins the machine in portal mode.
    .PARAMETER Config
        OpenPath config object used to determine whether a firewall is expected.
        Fetched automatically when null.
    .PARAMETER DnsMaxAttempts
        Maximum retry attempts passed to Test-DNSResolution and Test-DNSSinkhole.
    .PARAMETER DnsDelayMilliseconds
        Delay between DNS retry attempts in milliseconds.
    .PARAMETER DnsAttemptTimeoutSeconds
        Per-attempt DNS timeout in seconds; 0 means no timeout.
    .OUTPUTS
        PSCustomObject with fields: localDnsLoopbackRestored, acrylicNormalRestored,
        dnsResolutionHealthy, upstreamHealthy, sinkholeHealthy, firewallExpectedActive,
        firewallHealthy, markerPresent, markerCleared, localPostureRestored,
        enforcementRestored, protectedModeRestored
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Config = $null,
        [int]$DnsMaxAttempts = 12,
        [int]$DnsDelayMilliseconds = 1000,
        [int]$DnsAttemptTimeoutSeconds = 0
    )

    $firewallExpected = $true
    if ($Config -and $Config.PSObject.Properties['enableFirewall']) {
        $firewallExpected = [bool]$Config.enableFirewall
    }

    $dnsResolutionHealthy = $false
    $sinkholeHealthy = $false
    $firewallHealthy = (-not $firewallExpected)
    $localDnsLoopbackRestored = $false
    $acrylicNormalRestored = $false

    try {
        if (Get-Command -Name 'Test-DNSResolution' -ErrorAction SilentlyContinue) {
            $dnsResolutionHealthy = [bool](Test-DNSResolution -MaxAttempts $DnsMaxAttempts -DelayMilliseconds $DnsDelayMilliseconds -AttemptTimeoutSeconds $DnsAttemptTimeoutSeconds)
        }
    }
    catch {
        $dnsResolutionHealthy = $false
    }

    try {
        if (Get-Command -Name 'Test-DNSSinkhole' -ErrorAction SilentlyContinue) {
            $sinkholeHealthy = [bool](Test-DNSSinkhole -Domain 'this-should-be-blocked-test-12345.com' -AttemptTimeoutSeconds $DnsAttemptTimeoutSeconds)
        }
    }
    catch {
        $sinkholeHealthy = $false
    }

    try {
        if ($firewallExpected -and (Get-Command -Name 'Test-FirewallActive' -ErrorAction SilentlyContinue)) {
            $firewallHealthy = [bool](Test-FirewallActive)
        }
    }
    catch {
        $firewallHealthy = $false
    }

    try {
        $localDnsLoopbackRestored = [bool](Test-OpenPathCaptivePortalAdaptersUseLocalDns)
    }
    catch {
        $localDnsLoopbackRestored = $false
    }

    try {
        $acrylicNormalRestored = [bool](Test-OpenPathCaptivePortalAcrylicNormalState)
    }
    catch {
        $acrylicNormalRestored = $false
    }

    $markerPresent = Test-Path $script:CaptivePortalStatePath -ErrorAction SilentlyContinue
    $markerCleared = (-not $markerPresent)
    $normalProtected = [bool](Get-OpenPathCaptivePortalAcrylicPolicyState -State normalProtected -LocalDnsLoopbackRestored $localDnsLoopbackRestored -AcrylicNormalRestored $acrylicNormalRestored)
    # Local enforcement posture: adapter loopback, normal Acrylic policy, sinkhole
    # and firewall are all decided by this machine alone. Upstream resolution is a
    # NETWORK health signal: it must never decide whether a portal marker -- and
    # with it a relaxed DNS posture -- stays alive, or a network whose configured
    # upstream stays blocked would pin the machine in the relaxed mode forever.
    $localPostureRestored = ($normalProtected -and $sinkholeHealthy -and ((-not $firewallExpected) -or $firewallHealthy))
    $enforcementRestored = ($localPostureRestored -and $dnsResolutionHealthy)

    return [PSCustomObject]@{
        localDnsLoopbackRestored = $localDnsLoopbackRestored
        acrylicNormalRestored = $acrylicNormalRestored
        dnsResolutionHealthy = $dnsResolutionHealthy
        upstreamHealthy = $dnsResolutionHealthy
        sinkholeHealthy = $sinkholeHealthy
        firewallExpectedActive = $firewallExpected
        firewallHealthy = $firewallHealthy
        markerPresent = $markerPresent
        markerCleared = $markerCleared
        localPostureRestored = $localPostureRestored
        enforcementRestored = $enforcementRestored
        protectedModeRestored = ($enforcementRestored -and $markerCleared)
    }
}

function Get-OpenPathCaptivePortalUpstreamFromMarker {
    <#
    .SYNOPSIS
        Extracts the upstream DNS descriptor from a portal marker object.
    .PARAMETER Marker
        Deserialized marker object; must have a non-empty 'upstreamDns' property to return a result.
    .OUTPUTS
        PSCustomObject with fields Address, Source, Verified, UsableForLimited, PreReset; or $null
    #>
    param([object]$Marker)

    if (-not $Marker -or -not $Marker.PSObject.Properties['upstreamDns'] -or -not $Marker.upstreamDns) {
        return $null
    }

    $source = if ($Marker.PSObject.Properties['upstreamDnsSource'] -and $Marker.upstreamDnsSource) { [string]$Marker.upstreamDnsSource } else { 'marker' }
    $usableForLimited = if ($Marker.PSObject.Properties['upstreamUsableForLimited']) { [bool]$Marker.upstreamUsableForLimited } else { $true }
    $verified = if ($Marker.PSObject.Properties['upstreamVerified']) { [bool]$Marker.upstreamVerified } else { $false }

    return [PSCustomObject]@{
        Address = [string]$Marker.upstreamDns
        Source = $source
        Verified = $verified
        UsableForLimited = $usableForLimited
        PreReset = $false
    }
}

function New-OpenPathCaptivePortalFallbackUpstream {
    <#
    .SYNOPSIS
        Returns an empty upstream descriptor signalling that no upstream DNS is available.
    .OUTPUTS
        PSCustomObject with Address='', Source='unavailable', Verified=$false,
        UsableForLimited=$false, PreReset=$false
    #>
    return [PSCustomObject]@{
        Address = ''
        Source = 'unavailable'
        Verified = $false
        UsableForLimited = $false
        PreReset = $false
    }
}

function Resolve-OpenPathCaptivePortalUpstreamDns {
    <#
    .SYNOPSIS
        Selects the best available upstream DNS for portal mode, falling back through
        marker, policy helper, primary DNS, and finally an unavailable sentinel.
    .PARAMETER Marker
        Existing portal marker whose upstreamDns is preferred when present.
    .PARAMETER AfterAdapterReset
        When set, indicates the adapter DNS has already been reset; passed through to
        Get-OpenPathCaptivePortalUpstreamDns.
    .PARAMETER ProbeDomains
        Domains to probe when discovering the upstream via Get-OpenPathCaptivePortalUpstreamDns.
    .OUTPUTS
        PSCustomObject with fields Address, Source, Verified, UsableForLimited, PreReset
    #>
    param(
        [object]$Marker = $null,
        [switch]$AfterAdapterReset,
        [string[]]$ProbeDomains = @()
    )

    $markerUpstream = Get-OpenPathCaptivePortalUpstreamFromMarker -Marker $Marker
    if ($markerUpstream -and $markerUpstream.Address) {
        return $markerUpstream
    }

    if (Get-Command -Name 'Get-OpenPathCaptivePortalUpstreamDns' -ErrorAction SilentlyContinue) {
        try {
            return (Get-OpenPathCaptivePortalUpstreamDns -AfterAdapterReset:$AfterAdapterReset -ProbeDomains @($ProbeDomains))
        }
        catch {
            Write-OpenPathLog "Watchdog: captive portal upstream selection failed: $_" -Level WARN
        }
    }

    try {
        $primaryDns = [string](Get-PrimaryDNS)
        if ($primaryDns) {
            return [PSCustomObject]@{
                Address = $primaryDns
                Source = 'primary-dns'
                Verified = $true
                UsableForLimited = $true
                PreReset = (-not [bool]$AfterAdapterReset)
            }
        }
    }
    catch {
        # Fall through to unavailable marker.
    }

    return (New-OpenPathCaptivePortalFallbackUpstream)
}

function Test-OpenPathCaptivePortalPassthroughEgress {
    <#
    .SYNOPSIS
        Probes DNS (1.1.1.1:53), HTTP (port 80), and HTTPS (port 443) egress to
        detectportal.firefox.com to confirm that adapter DNS reset has exposed network access.
    .OUTPUTS
        PSCustomObject with Boolean fields: dns, http, https
    #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        dns = $null
        http = $null
        https = $null
    }

    if (Get-Command -Name Test-NetConnection -ErrorAction SilentlyContinue) {
        try {
            $result.dns = [bool](Test-NetConnection -ComputerName '1.1.1.1' -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue)
        }
        catch {
            $result.dns = $false
        }
        try {
            $result.http = [bool](Test-NetConnection -ComputerName 'detectportal.firefox.com' -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue)
        }
        catch {
            $result.http = $false
        }
        try {
            $result.https = [bool](Test-NetConnection -ComputerName 'detectportal.firefox.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)
        }
        catch {
            $result.https = $false
        }
    }

    return [PSCustomObject]$result
}

function Test-OpenPathCaptivePortalPassthroughEgressUsable {
    <#
    .SYNOPSIS
        Returns true when at least one of the dns/http/https egress probes succeeded.
    .PARAMETER Egress
        Object returned by Test-OpenPathCaptivePortalPassthroughEgress.
    .OUTPUTS
        Boolean
    #>
    param([object]$Egress)

    if (-not $Egress) { return $false }

    foreach ($propertyName in @('dns', 'http', 'https')) {
        $property = $Egress.PSObject.Properties[$propertyName]
        if ($property -and [bool]$property.Value) {
            return $true
        }
    }

    return $false
}

function Enable-OpenPathCaptivePortalPassthroughMode {
    <#
    .SYNOPSIS
        Enters passthrough mode by resetting adapter DNS to the network resolver and
        writing a passthrough portal marker.
    .DESCRIPTION
        When an existing limited-mode marker is present and ForcePassthrough is not set,
        upgrades the marker TTL without changing the DNS posture. Otherwise calls
        Restore-OpenPathCaptivePortalDNS to reset adapter DNS to the network DHCP resolver,
        waits 500 ms for DHCP to settle, probes egress via Test-OpenPathCaptivePortalPassthroughEgress,
        and writes a passthrough marker. Fails closed if adapter reset fails or egress is unusable.
        Logs WARN entries on failure paths.
    .PARAMETER State
        State label to record in the marker (e.g. 'Portal').
    .PARAMETER TtlSeconds
        Requested TTL in seconds; clamped to [1, 120].
    .PARAMETER ExistingMarker
        Current marker object used to decide limited-vs-passthrough upgrade path.
    .PARAMETER ForcePassthrough
        When set, always performs the full adapter DNS reset regardless of existing mode.
    .OUTPUTS
        Boolean — true when passthrough mode was successfully entered
    #>
    [CmdletBinding()]
    param(
        [string]$State = 'Portal',
        [int]$TtlSeconds = 120,
        [object]$ExistingMarker = $null,
        [switch]$ForcePassthrough
    )

    if (-not $ForcePassthrough -and $ExistingMarker -and (Get-OpenPathCaptivePortalMarkerMode -Marker $ExistingMarker) -eq 'limited') {
        $existingHosts = @($ExistingMarker.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $existingUpstream = Get-OpenPathCaptivePortalUpstreamFromMarker -Marker $ExistingMarker
        Set-OpenPathCaptivePortalMarker `
            -State $State `
            -AllowedHosts $existingHosts `
            -Mode limited `
            -UpstreamDns $(if ($existingUpstream) { [string]$existingUpstream.Address } else { '' }) `
            -UpstreamDnsSource $(if ($existingUpstream) { [string]$existingUpstream.Source } else { '' }) `
            -UpstreamUsableForLimited $(if ($existingUpstream) { [bool]$existingUpstream.UsableForLimited } else { $false }) `
            -UpstreamVerified $(if ($existingUpstream) { [bool]$existingUpstream.Verified } else { $false }) `
            -TtlSeconds $TtlSeconds | Out-Null
        return $true
    }

    Write-OpenPathLog 'Watchdog: Captive portal detected without exact recovery hosts; entering passthrough mode' -Level WARN

    $dnsResetAt = (Get-Date).ToUniversalTime().ToString('o')
    $dnsResetSucceeded = $false
    if (Get-Command -Name 'Restore-OpenPathCaptivePortalDNS' -ErrorAction SilentlyContinue) {
        $dnsResetSucceeded = [bool](Restore-OpenPathCaptivePortalDNS)
    }
    if (-not $dnsResetSucceeded) {
        Write-OpenPathLog 'Watchdog: captive portal passthrough failed because adapter DNS reset did not complete' -Level WARN
        return $false
    }

    Start-Sleep -Milliseconds 500
    if (Get-Command -Name 'Update-OpenPathOriginalDnsSnapshotForCurrentNetwork' -ErrorAction SilentlyContinue) {
        Update-OpenPathOriginalDnsSnapshotForCurrentNetwork | Out-Null
    }

    $upstream = Resolve-OpenPathCaptivePortalUpstreamDns -AfterAdapterReset
    $upstreamCapturedAt = (Get-Date).ToUniversalTime().ToString('o')
    $egress = Test-OpenPathCaptivePortalPassthroughEgress
    if (-not (Test-OpenPathCaptivePortalPassthroughEgressUsable -Egress $egress)) {
        Write-OpenPathLog 'Watchdog: captive portal passthrough failed because reset DNS did not expose DNS/HTTP/HTTPS egress' -Level WARN
        return $false
    }

    Set-OpenPathCaptivePortalMarker `
        -State $State `
        -AllowedHosts @() `
        -Mode passthrough `
        -UpstreamDns ([string]$upstream.Address) `
        -UpstreamDnsSource ([string]$upstream.Source) `
        -UpstreamUsableForLimited ([bool]$upstream.UsableForLimited) `
        -UpstreamVerified ([bool]$upstream.Verified) `
        -DnsResetAt $dnsResetAt `
        -UpstreamCapturedAt $upstreamCapturedAt `
        -PassthroughEgress $egress `
        -FallbackMode passthrough `
        -TtlSeconds ([Math]::Min([Math]::Max(1, $TtlSeconds), 120)) | Out-Null

    return $true
}

function Enable-OpenPathCaptivePortalLimitedMode {
    <#
    .SYNOPSIS
        Enters limited mode: keeps adapter DNS on 127.0.0.1 with NX * and forwards
        only the declared portal recovery domains to the network resolver via Acrylic.
    .DESCRIPTION
        Merges AllowedHosts, existing marker hosts, and configured captive portal domains
        into a recovery set. Calls Resolve-OpenPathCaptivePortalUpstreamDns to pick a
        temporary upstream. Writes the CAPTIVE PORTAL RECOVERY section to AcrylicHosts.txt
        and adjusts AcrylicConfiguration.ini upstream/affinity settings, then restarts
        the Acrylic service. Verifies DNS resolution for every recovery host before
        committing the marker; fails closed via Restore-OpenPathLimitedCaptivePortalAttempt
        on any failure. Adds a Windows Firewall allow rule for the upstream DNS IP via
        Add-OpenPathCaptivePortalUpstreamFirewallAllow.
    .PARAMETER State
        State label to record in the marker.
    .PARAMETER AllowedHosts
        Caller-supplied recovery hostnames merged with configured and existing hosts.
    .PARAMETER TtlSeconds
        Requested TTL in seconds; clamped to [1, 120].
    .PARAMETER Marker
        Existing portal marker used to inherit prior upstream and allowed-host state.
    .OUTPUTS
        Boolean — true when limited mode was successfully entered and verified
    #>
    [CmdletBinding()]
    param(
        [string]$State = 'Portal',
        [string[]]$AllowedHosts = @(),
        [int]$TtlSeconds = 300,
        [object]$Marker = $null
    )

    $limitedModeTtlSeconds = [Math]::Min([Math]::Max(1, $TtlSeconds), 120)
    $markerMode = Get-OpenPathCaptivePortalMarkerMode -Marker $Marker
    if ($Marker -and $marker.mode -eq 'passthrough') {
        $markerMode = 'passthrough'
    }

    $existingHosts = @()
    if ($Marker -and $Marker.PSObject.Properties['allowedHosts']) {
        $existingHosts = @($Marker.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    $configuredCaptivePortalDomains = @(Get-OpenPathConfiguredCaptivePortalDomains)
    $baseRecoveryHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($existingHosts) + @($AllowedHosts) + @($configuredCaptivePortalDomains)))
    if ($baseRecoveryHosts.Count -le 0) {
        return (Enable-OpenPathCaptivePortalPassthroughMode -State $State -TtlSeconds $TtlSeconds -ExistingMarker $Marker -ForcePassthrough)
    }

    $upstream = Resolve-OpenPathCaptivePortalUpstreamDns -Marker $Marker -ProbeDomains @($baseRecoveryHosts)
    if (-not $upstream -or -not $upstream.Address) {
        Write-OpenPathLog 'Watchdog: captive portal limited mode failed because no temporary upstream DNS was available' -Level WARN
        return $false
    }

    if (-not [bool]$upstream.UsableForLimited) {
        Write-OpenPathLog "Watchdog: captive portal limited mode deferred because upstream source $($upstream.Source) is not usable for limited mode" -Level WARN
        if ($markerMode -eq 'passthrough') {
            Set-OpenPathCaptivePortalMarker `
                -State $State `
                -Mode passthrough `
                -AllowedHosts @() `
                -UpstreamDns ([string]$upstream.Address) `
                -UpstreamDnsSource ([string]$upstream.Source) `
                -UpstreamUsableForLimited ([bool]$upstream.UsableForLimited) `
                -UpstreamVerified ([bool]$upstream.Verified) `
                -TtlSeconds $limitedModeTtlSeconds | Out-Null
        }
        return $false
    }

    Write-OpenPathLog 'Watchdog: Captive portal detected - entering limited portal mode for exact recovery hosts' -Level WARN

    # The anti-bypass firewall only allows Acrylic to reach the configured upstream;
    # open it for this portal upstream so Acrylic can forward the declared portal
    # domains to the network resolver. Removed by the firewall rebuild on protected-mode restore.
    if (Get-Command -Name 'Add-OpenPathCaptivePortalUpstreamFirewallAllow' -ErrorAction SilentlyContinue) {
        try { Add-OpenPathCaptivePortalUpstreamFirewallAllow -Address ([string]$upstream.Address) | Out-Null }
        catch { Write-OpenPathLog "Watchdog: captive portal upstream firewall allow failed: $_" -Level WARN }
    }

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }
    $hostsPath = Join-Path $acrylicPath 'AcrylicHosts.txt'
    $allBootstrapHosts = [System.Collections.Generic.List[string]]::new()
    foreach ($hostName in @($baseRecoveryHosts)) {
        if ($hostName -and -not $allBootstrapHosts.Contains($hostName)) { $allBootstrapHosts.Add($hostName) }
    }
    $allRedirectHosts = [System.Collections.Generic.List[string]]::new()
    $allResourceHosts = [System.Collections.Generic.List[string]]::new()
    $observedRuntimeHosts = @()
    $renderedHosts = @($baseRecoveryHosts)
    $definition = New-OpenPathLimitedCaptivePortalHostsDefinition -PortalRecoveryDomains $renderedHosts -UpstreamDns ([string]$upstream.Address)
    $content = ConvertTo-AcrylicHostsContent -Definition $definition
    $limitedAcrylicUpdated = [bool](Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction -State limitedRecovery -Action {
        Write-AcrylicHostsFile -Path $hostsPath -Content $content
        return (Set-OpenPathLimitedCaptivePortalAcrylicConfiguration -UpstreamDns ([string]$upstream.Address) -PortalRecoveryDomains $renderedHosts -SkipPolicyStateLock)
    } -Rollback {
        Restore-OpenPathLimitedCaptivePortalAttempt
    })
    if (-not $limitedAcrylicUpdated) {
        Restore-OpenPathLimitedCaptivePortalAttempt
        return $false
    }

    if (Get-Command -Name 'Set-LocalDNS' -ErrorAction SilentlyContinue) {
        Set-LocalDNS | Out-Null
    }
    if (Get-Command -Name 'Restart-AcrylicService' -ErrorAction SilentlyContinue) {
        $restartSucceeded = Restart-AcrylicService -TimeoutSeconds $script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds -SkipBatchFallback
        if (-not ([bool]$restartSucceeded)) {
            Write-OpenPathLog 'Watchdog: captive portal limited mode failed because Acrylic service restart did not complete within the native host budget' -Level WARN
            Restore-OpenPathLimitedCaptivePortalAttempt
            return $false
        }
    }

    if (-not (Test-OpenPathLimitedCaptivePortalProtection -PortalRecoveryDomains $renderedHosts -DnsMaxAttempts $script:CaptivePortalLimitedModeDnsMaxAttempts -DnsDelayMilliseconds $script:CaptivePortalLimitedModeDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $script:CaptivePortalLimitedModeDnsAttemptTimeoutSeconds)) {
        # Fail closed: a failed limited-mode verification must never trade
        # enforcement for connectivity. Return to the protected posture and leave
        # a short-lived not-ready marker so the next watchdog cycle retries
        # limited entry (keepLimited reuses the marker's allowedHosts). The
        # portal stays unreachable for one cycle instead of the whole machine
        # opening up, which is what the old bounded-passthrough downgrade did.
        Write-OpenPathLog 'Watchdog: captive portal limited mode verification failed; staying protected and retrying next cycle' -Level WARN
        Restore-OpenPathLimitedCaptivePortalAttempt
        Set-OpenPathCaptivePortalMarker -State $State -Mode limited `
            -AllowedHosts @($renderedHosts) `
            -ConfiguredCaptivePortalDomains @($configuredCaptivePortalDomains) `
            -LimitedModeReady $false `
            -UpstreamDns ([string]$upstream.Address) `
            -UpstreamDnsSource ([string]$upstream.Source) `
            -UpstreamUsableForLimited ([bool]$upstream.UsableForLimited) `
            -UpstreamVerified ([bool]$upstream.Verified) `
            -TtlSeconds 60 | Out-Null
        return $false
    }

    $allowedMarkerHosts = @($renderedHosts)
    $configuredCaptivePortalDomainsApplied = $true
    foreach ($configuredDomain in @($configuredCaptivePortalDomains)) {
        if ($allowedMarkerHosts -notcontains $configuredDomain) {
            $configuredCaptivePortalDomainsApplied = $false
            break
        }
    }
    $declaredRecoveryHostsApplied = ($baseRecoveryHosts.Count -gt 0)
    foreach ($hostName in @($baseRecoveryHosts)) {
        if ($allowedMarkerHosts -notcontains $hostName) {
            $declaredRecoveryHostsApplied = $false
            break
        }
    }
    $limitedModeReady = ($declaredRecoveryHostsApplied -and $configuredCaptivePortalDomainsApplied)

    Set-OpenPathCaptivePortalMarker -State $State -Mode limited `
        -AllowedHosts $allowedMarkerHosts `
        -ConfiguredCaptivePortalDomains @($configuredCaptivePortalDomains) `
        -ConfiguredCaptivePortalDomainsApplied $configuredCaptivePortalDomainsApplied `
        -BootstrapHosts @($allBootstrapHosts) `
        -RedirectHosts @($allRedirectHosts) `
        -ResourceHosts @($allResourceHosts) `
        -ObservedRuntimeHosts @($observedRuntimeHosts) `
        -PendingRuntimeHosts @() `
        -DiscoveryTruncated $false `
        -FallbackMode 'none' `
        -LimitedModeReady $limitedModeReady `
        -UpstreamDns ([string]$upstream.Address) `
        -UpstreamDnsSource ([string]$upstream.Source) `
        -UpstreamUsableForLimited ([bool]$upstream.UsableForLimited) `
        -UpstreamVerified ([bool]$upstream.Verified) `
        -TtlSeconds $limitedModeTtlSeconds | Out-Null
    return $true
}

function New-OpenPathLimitedCaptivePortalHostsDefinition {
    <#
    .SYNOPSIS
        Builds the AcrylicHosts definition object for limited captive portal mode.
    .DESCRIPTION
        Creates a hosts definition with a CAPTIVE PORTAL RECOVERY section inserted
        before the DEFAULT BLOCK section. Configured captive portal domains receive
        subdomain-inclusive forward rules (Get-AcrylicForwardRules); all other
        discovery hosts receive exact forward rules (Get-AcrylicExactForwardRule).
        Both primary and secondary DNS are set to UpstreamDns.
    .PARAMETER PortalRecoveryDomains
        Normalised hostnames to include as forward rules in the recovery section.
    .PARAMETER UpstreamDns
        IP address of the temporary upstream DNS resolver to embed in the definition.
    .OUTPUTS
        PSCustomObject — Acrylic hosts definition object suitable for ConvertTo-AcrylicHostsContent
    #>
    [CmdletBinding()]
    param(
        [string[]]$PortalRecoveryDomains = @(),
        [Parameter(Mandatory = $true)][string]$UpstreamDns
    )

    $dnsSettings = [PSCustomObject]@{
        PrimaryDNS = $UpstreamDns
        SecondaryDNS = $UpstreamDns
        MaxDomains = 500
    }
    $definition = New-AcrylicHostsDefinition -WhitelistedDomains @() -BlockedSubdomains @() -RuntimeDependencyDomains @() -DnsSettings $dnsSettings
    $subdomainInclusiveSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($configuredDomain in @(Get-OpenPathConfiguredCaptivePortalDomains)) {
        $normalizedConfigured = ([string]$configuredDomain).Trim().TrimEnd('.')
        if ($normalizedConfigured) { [void]$subdomainInclusiveSet.Add($normalizedConfigured) }
    }
    $portalRecoveryLines = @(
        foreach ($domain in @($PortalRecoveryDomains)) {
            $normalizedRecoveryDomain = ([string]$domain).Trim().TrimEnd('.')
            if ($subdomainInclusiveSet.Contains($normalizedRecoveryDomain)) {
                @(Get-AcrylicForwardRules -Domain $domain)
            }
            else {
                Get-AcrylicExactForwardRule -Domain $domain
            }
        }
    )

    $sections = @()
    foreach ($section in @($definition.Sections)) {
        if ([string]$section.Title -like 'DEFAULT BLOCK*') {
            if ($portalRecoveryLines.Count -gt 0) {
                $sections += New-AcrylicHostsSection -Title 'CAPTIVE PORTAL RECOVERY' -Description 'Temporary recovery access (configured portal domains cover subdomains; discovered hosts exact)' -Lines @($portalRecoveryLines)
            }
        }
        $sections += $section
    }
    $definition.Sections = @($sections)
    $definition.UpstreamDNS = $UpstreamDns
    return $definition
}

function Test-OpenPathLimitedCaptivePortalDnsResolution {
    <#
    .SYNOPSIS
        Verifies that a domain resolves via the local Acrylic listener (127.0.0.1) in limited mode.
    .PARAMETER Domain
        Hostname to resolve against 127.0.0.1.
    .PARAMETER DnsMaxAttempts
        Maximum resolution attempts before giving up.
    .PARAMETER DnsDelayMilliseconds
        Delay between resolution attempts in milliseconds.
    .PARAMETER DnsAttemptTimeoutSeconds
        Per-attempt DNS timeout in seconds; 0 means no timeout.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [int]$DnsMaxAttempts = 12,
        [int]$DnsDelayMilliseconds = 1000,
        [int]$DnsAttemptTimeoutSeconds = 0
    )

    try {
        if (Get-Command -Name 'Resolve-OpenPathDnsWithRetry' -ErrorAction SilentlyContinue) {
            $result = Resolve-OpenPathDnsWithRetry -Domain $Domain -Server '127.0.0.1' -MaxAttempts $DnsMaxAttempts -DelayMilliseconds $DnsDelayMilliseconds -AttemptTimeoutSeconds $DnsAttemptTimeoutSeconds
            return ($null -ne $result)
        }

        $resolveParams = @{
            Name = $Domain
            Server = '127.0.0.1'
            DnsOnly = $true
            ErrorAction = 'Stop'
        }
        $resolveCommand = Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue
        if ($DnsAttemptTimeoutSeconds -gt 0 -and $resolveCommand -and $resolveCommand.Parameters.ContainsKey('QuickTimeout')) {
            $resolveParams.QuickTimeout = $true
        }

        $result = Resolve-DnsName @resolveParams
        return ($null -ne $result)
    }
    catch {
        Write-OpenPathLog "Watchdog: captive portal limited DNS verification failed for $Domain via 127.0.0.1: $_" -Level WARN
        return $false
    }
}

function Test-OpenPathLimitedCaptivePortalRecoveryHost {
    <#
    .SYNOPSIS
        Verifies that a single recovery host has its expected forward rule in AcrylicHosts.txt
        before the default-block line, and that the domain resolves via 127.0.0.1.
    .DESCRIPTION
        Mirrors the rule-type logic of New-OpenPathLimitedCaptivePortalHostsDefinition:
        configured captive portal domains expect subdomain-inclusive rules; all others expect
        exact forward rules. The rule must appear before the 'NX *' default-block entry.
    .PARAMETER Domain
        Hostname to verify in AcrylicHosts.txt and via DNS.
    .PARAMETER DnsMaxAttempts
        Maximum DNS resolution attempts.
    .PARAMETER DnsDelayMilliseconds
        Delay between DNS attempts in milliseconds.
    .PARAMETER DnsAttemptTimeoutSeconds
        Per-attempt DNS timeout in seconds; 0 means no timeout.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [int]$DnsMaxAttempts = 12,
        [int]$DnsDelayMilliseconds = 1000,
        [int]$DnsAttemptTimeoutSeconds = 0
    )

    try {
        $acrylicPath = Get-AcrylicPath
        if (-not $acrylicPath) {
            return $false
        }

        $hostsPath = Join-Path $acrylicPath 'AcrylicHosts.txt'
        if (-not (Test-Path -LiteralPath $hostsPath -ErrorAction SilentlyContinue)) {
            return $false
        }

        # Mirror New-OpenPathLimitedCaptivePortalHostsDefinition: configured captive
        # portal domains render subdomain-inclusive rules (for sslip hosts a static
        # mapping plus "FW >domain", with no exact "FW domain" line), so the
        # verification must expect the same lines the renderer emits for this domain.
        $normalizedDomain = ([string]$Domain).Trim().TrimEnd('.')
        $subdomainInclusive = $false
        foreach ($configuredDomain in @(Get-OpenPathConfiguredCaptivePortalDomains)) {
            if (([string]$configuredDomain).Trim().TrimEnd('.') -ieq $normalizedDomain) {
                $subdomainInclusive = $true
                break
            }
        }
        $expectedRules = @(
            if ($subdomainInclusive) { Get-AcrylicForwardRules -Domain $Domain }
            else { Get-AcrylicExactForwardRule -Domain $Domain }
        ) | Where-Object { $_ }
        if ($expectedRules.Count -le 0) {
            return $false
        }

        $content = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction Stop
        $defaultBlockIndex = $content.IndexOf("NX *")
        foreach ($expectedRule in $expectedRules) {
            $match = [regex]::Match($content, "(?m)^\s*$([regex]::Escape($expectedRule))\s*$")
            if (-not $match.Success) {
                return $false
            }

            if (-not ($defaultBlockIndex -lt 0 -or $match.Index -lt $defaultBlockIndex)) {
                return $false
            }
        }

        return [bool](Test-OpenPathLimitedCaptivePortalDnsResolution -Domain $Domain -DnsMaxAttempts $DnsMaxAttempts -DnsDelayMilliseconds $DnsDelayMilliseconds -DnsAttemptTimeoutSeconds $DnsAttemptTimeoutSeconds)
    }
    catch {
        return $false
    }
}

function Set-OpenPathLimitedCaptivePortalAcrylicConfiguration {
    <#
    .SYNOPSIS
        Writes AcrylicConfiguration.ini settings for limited captive portal mode.
    .DESCRIPTION
        Sets PrimaryServerAddress and SecondaryServerAddress to UpstreamDns, configures
        domain-name affinity masks so only recovery domains and probe domains are forwarded
        to the portal upstream, and writes allowed-address entries for 127.0.0.1 and ::1.
        Wraps itself in an Acrylic policy transaction unless SkipPolicyStateLock is set.
        Does not restart the Acrylic service; the caller is responsible for that.
    .PARAMETER UpstreamDns
        IP address of the temporary portal upstream DNS to configure in Acrylic.
    .PARAMETER PortalRecoveryDomains
        Recovery hostnames used to build the domain-name affinity mask.
    .PARAMETER SkipPolicyStateLock
        When set, skips the Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction wrapper;
        used when the caller has already acquired the transaction.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UpstreamDns,
        [string[]]$PortalRecoveryDomains = @(),
        [switch]$SkipPolicyStateLock
    )

    if (-not $SkipPolicyStateLock) {
        return [bool](Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction -State limitedRecovery -Action {
            return (Set-OpenPathLimitedCaptivePortalAcrylicConfiguration -UpstreamDns $UpstreamDns -PortalRecoveryDomains $PortalRecoveryDomains -SkipPolicyStateLock)
        })
    }

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }

    $configPath = Join-Path $acrylicPath 'AcrylicConfiguration.ini'
    $existingIniContent = $null
    try {
        if (Test-Path $configPath -ErrorAction SilentlyContinue) {
            $existingIniContent = Get-Content $configPath -Raw -ErrorAction Stop
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: limited captive portal Acrylic configuration was unreadable; rebuilding required resolver defaults: $_" -Level WARN
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

    $subdomainInclusiveSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($configuredDomain in @(Get-OpenPathConfiguredCaptivePortalDomains)) {
        $normalizedConfigured = ([string]$configuredDomain).Trim().TrimEnd('.')
        if ($normalizedConfigured) { [void]$subdomainInclusiveSet.Add($normalizedConfigured) }
    }
    $exactRecoveryDomains = @($PortalRecoveryDomains | Where-Object { -not $subdomainInclusiveSet.Contains(([string]$_).Trim().TrimEnd('.')) })
    $inclusiveRecoveryDomains = @($PortalRecoveryDomains | Where-Object { $subdomainInclusiveSet.Contains(([string]$_).Trim().TrimEnd('.')) })
    # The watchdog's connectivity probes MUST stay resolvable in limited mode or
    # 'Authenticated' is unobservable: every probe transport-fails against a mask
    # that only matches the portal domains, the state stays 'Portal', and the
    # autonomous close never fires -- the portal marker survives authentication.
    $probeDomains = @()
    if (Get-Command -Name 'Get-OpenPathCaptivePortalProbeDomains' -ErrorAction SilentlyContinue) {
        $probeDomains = @(Get-OpenPathCaptivePortalProbeDomains)
    }
    $recoveryAffinityMask = (@(
        @(Get-AcrylicExactAffinityMaskEntries -Domains $exactRecoveryDomains)
        @(Get-AcrylicAffinityMaskEntries -Domains $inclusiveRecoveryDomains)
        @(Get-AcrylicExactAffinityMaskEntries -Domains $probeDomains)
    ) | Select-Object -Unique) -join ';'
    $settings = [ordered]@{
        "PrimaryServerAddress" = $UpstreamDns
        "PrimaryServerPort" = "53"
        "PrimaryServerProtocol" = "UDP"
        "PrimaryServerQueryTypeAffinityMask" = ""
        "SecondaryServerAddress" = $UpstreamDns
        "SecondaryServerPort" = "53"
        "SecondaryServerProtocol" = "UDP"
        "SecondaryServerQueryTypeAffinityMask" = ""
        "LocalIPv4BindingAddress" = "127.0.0.1"
        "LocalIPv4BindingPort" = "53"
        "LocalIPv6BindingAddress" = ""
        "LocalIPv6BindingPort" = "53"
        "LocalIPv6BindingEnabledOnWindowsVersionsPriorToWindowsVistaOrWindowsServer2008" = "No"
        "GeneratedResponseTimeToLive" = "300"
        "PrimaryServerDomainNameAffinityMask" = $recoveryAffinityMask
        "SecondaryServerDomainNameAffinityMask" = $recoveryAffinityMask
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

    $iniContent = Set-AcrylicAllowedAddress -Content $iniContent -Key 'IP1' -Value '127.*'
    $iniContent = Set-AcrylicAllowedAddress -Content $iniContent -Key 'IP2' -Value '::1'

    Write-AcrylicConfigFile -Path $configPath -Content $iniContent
    return $true
}

function Test-OpenPathLimitedCaptivePortalProtection {
    <#
    .SYNOPSIS
        Verifies that limited captive portal mode is correctly enforced: all recovery hosts
        resolve, the NX * sinkhole rule is present, and all adapters use 127.0.0.1 for DNS.
    .PARAMETER PortalRecoveryDomains
        Hostnames that must be individually verified via Test-OpenPathLimitedCaptivePortalRecoveryHost.
    .PARAMETER DnsMaxAttempts
        Maximum DNS resolution attempts per recovery host.
    .PARAMETER DnsDelayMilliseconds
        Delay between DNS attempts in milliseconds.
    .PARAMETER DnsAttemptTimeoutSeconds
        Per-attempt DNS timeout in seconds; 0 means no timeout.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param(
        [string[]]$PortalRecoveryDomains = @(),
        [int]$DnsMaxAttempts = 12,
        [int]$DnsDelayMilliseconds = 1000,
        [int]$DnsAttemptTimeoutSeconds = 0
    )

    try {
        $recoveryHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts $PortalRecoveryDomains)
        if ($recoveryHosts.Count -le 0) {
            return $false
        }

        foreach ($recoveryHost in $recoveryHosts) {
            if (-not (Test-OpenPathLimitedCaptivePortalRecoveryHost -Domain $recoveryHost -DnsMaxAttempts $DnsMaxAttempts -DnsDelayMilliseconds $DnsDelayMilliseconds -DnsAttemptTimeoutSeconds $DnsAttemptTimeoutSeconds)) {
                return $false
            }
        }

        $acrylicPath = Get-AcrylicPath
        if (-not $acrylicPath) {
            return $false
        }
        $hostsPath = Join-Path $acrylicPath 'AcrylicHosts.txt'
        if (-not (Test-Path -LiteralPath $hostsPath -ErrorAction SilentlyContinue)) {
            return $false
        }
        $content = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction Stop
        if ($content -notmatch '(?m)^\s*NX \*\s*$') {
            return $false
        }
        if (-not (Test-OpenPathCaptivePortalAdaptersUseLocalDns)) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

function Restore-OpenPathCaptivePortalAcrylicHostState {
    <#
    .SYNOPSIS
        Restores AcrylicHosts.txt to the normal protected-mode whitelist content.
    .DESCRIPTION
        Reads the current whitelist from C:\OpenPath\data\whitelist.txt and calls
        Update-AcrylicHost inside an Acrylic policy transaction (state: restoredProtected).
        Logs a WARN entry and returns false on failure.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param()

    try {
        return [bool](Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction -State restoredProtected -Action {
            if (-not (Get-Command -Name 'Update-AcrylicHost' -ErrorAction SilentlyContinue)) {
                return $true
            }

            $whitelistDomains = @()
            $blockedSubdomains = @()
            $whitelistPath = Join-Path $script:OpenPathRoot 'data\whitelist.txt'
            if ((Get-Command -Name 'Get-OpenPathWhitelistSectionsFromFile' -ErrorAction SilentlyContinue) -and
                (Test-Path $whitelistPath -ErrorAction SilentlyContinue)) {
                $sections = Get-OpenPathWhitelistSectionsFromFile -Path $whitelistPath
                if ($sections -and -not $sections.IsDisabled) {
                    $whitelistDomains = @($sections.Whitelist)
                    $blockedSubdomains = @($sections.BlockedSubdomains)
                }
            }

            return [bool](Update-AcrylicHost -WhitelistedDomains $whitelistDomains -BlockedSubdomains $blockedSubdomains)
        })
    }
    catch {
        Write-OpenPathLog "Watchdog: failed to restore Acrylic host state after captive portal mode: $_" -Level WARN
        return $false
    }
}

function Restore-OpenPathLimitedCaptivePortalAttempt {
    <#
    .SYNOPSIS
        Rolls back a failed limited-mode entry attempt by restoring Acrylic host state
        and calling Restore-OpenPathProtectedMode.
    .DESCRIPTION
        Called as the rollback path when Enable-OpenPathCaptivePortalLimitedMode fails.
        Logs a WARN entry if either restore step throws.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-OpenPathConfig
        Restore-OpenPathCaptivePortalAcrylicHostState | Out-Null
        Restore-OpenPathProtectedMode -Config $config | Out-Null
    }
    catch {
        Write-OpenPathLog "Watchdog: failed to restore protected mode after limited captive portal setup failure: $_" -Level WARN
    }
}

function Clear-OpenPathCaptivePortalMarker {
    <#
    .SYNOPSIS
        Deletes the captive portal state file from disk.
    .DESCRIPTION
        Removes $script:CaptivePortalStatePath (C:\OpenPath\data\captive-portal-active.json).
        Returns true on success or when the file was already absent; false on I/O error.
    .OUTPUTS
        Boolean
    #>
    try {
        Remove-Item -Path $script:CaptivePortalStatePath -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Get-OpenPathCaptivePortalObservation {
    <#
    .SYNOPSIS
        Reads and deserializes the captive portal observation file from disk.
    .DESCRIPTION
        Reads $script:CaptivePortalObservationPath
        (C:\OpenPath\data\captive-portal-observation.json).
        Returns null when the file is absent, empty, or unparseable.
    .OUTPUTS
        PSCustomObject or $null
    #>
    if (-not (Test-Path $script:CaptivePortalObservationPath)) {
        return $null
    }

    try {
        $raw = Get-Content $script:CaptivePortalObservationPath -Raw -ErrorAction Stop
        if (-not $raw) {
            return $null
        }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Update-OpenPathCaptivePortalObservation {
    <#
    .SYNOPSIS
        Records a captive portal detection result and computes whether portal mode
        should be entered or exited based on consecutive-observation thresholds.
    .DESCRIPTION
        Reads the existing observation file, increments the appropriate consecutive
        counter (portalCount or authenticatedCount), resets the other, and writes the
        updated observation to $script:CaptivePortalObservationPath
        (C:\OpenPath\data\captive-portal-observation.json). Persistence is best-effort;
        the in-memory decision object is always returned even when the file write fails.
    .PARAMETER DetectedState
        Current detection result: 'Authenticated', 'Portal', or 'NoNetwork'.
    .PARAMETER EnterPortalCount
        Number of consecutive Portal detections required before ShouldEnterPortal is true.
    .PARAMETER ExitAuthenticatedCount
        Number of consecutive Authenticated detections required before ShouldExitPortal is true.
    .OUTPUTS
        PSCustomObject with fields ShouldEnterPortal, ShouldExitPortal, DetectedState,
        PortalCount, AuthenticatedCount, PortalSince, PortalAgeSeconds, MinimumPortalElapsed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Authenticated', 'Portal', 'NoNetwork')]
        [string]$DetectedState,

        [int]$EnterPortalCount = 2,

        [int]$ExitAuthenticatedCount = 1
    )

    $now = Get-Date
    $existing = Get-OpenPathCaptivePortalObservation
    $portalCount = 0
    $authenticatedCount = 0
    $portalSince = $null

    if ($existing) {
        if ($existing.PSObject.Properties['portalCount']) { $portalCount = [int]$existing.portalCount }
        if ($existing.PSObject.Properties['authenticatedCount']) { $authenticatedCount = [int]$existing.authenticatedCount }
        if ($existing.PSObject.Properties['portalSince'] -and $existing.portalSince) {
            try { $portalSince = [datetime]::Parse([string]$existing.portalSince, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $portalSince = $null }
        }
    }

    if (-not (Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore)) {
        $portalSince = $null
    }
    elseif (-not $portalSince) {
        $marker = Get-OpenPathCaptivePortalMarker
        if ($marker -and $marker.PSObject.Properties['since'] -and $marker.since) {
            try { $portalSince = [datetime]::Parse([string]$marker.since, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $portalSince = $now }
        }
        else {
            $portalSince = $now
        }
    }

    if ($DetectedState -eq 'Portal') {
        $portalCount += 1
        $authenticatedCount = 0
    }
    elseif ($DetectedState -eq 'Authenticated') {
        $authenticatedCount += 1
        $portalCount = 0
    }

    $portalAgeSeconds = $null
    $minimumPortalElapsed = $true
    if ($portalSince) {
        $portalAgeSeconds = [Math]::Max(0, [int][Math]::Floor(($now - $portalSince).TotalSeconds))
    }

    $shouldEnterPortal = ($DetectedState -eq 'Portal' -and $portalCount -ge $EnterPortalCount -and -not (Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore))
    $shouldExitPortal = ($DetectedState -eq 'Authenticated' -and $authenticatedCount -ge $ExitAuthenticatedCount -and (Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore))

    try {
        $dir = Split-Path $script:CaptivePortalObservationPath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        [PSCustomObject]@{
            detectedState = $DetectedState
            portalCount = $portalCount
            authenticatedCount = $authenticatedCount
            portalSince = if ($portalSince) { $portalSince.ToString('o') } else { $null }
            portalAgeSeconds = $portalAgeSeconds
            minimumPortalElapsed = [bool]$minimumPortalElapsed
            shouldEnterPortal = [bool]$shouldEnterPortal
            shouldExitPortal = [bool]$shouldExitPortal
            updatedAt = $now.ToString('o')
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $script:CaptivePortalObservationPath -Encoding UTF8 -Force
    }
    catch {
        # Observation persistence is best-effort; callers still get the in-memory decision.
    }

    return [PSCustomObject]@{
        ShouldEnterPortal = [bool]$shouldEnterPortal
        ShouldExitPortal = [bool]$shouldExitPortal
        DetectedState = $DetectedState
        PortalCount = $portalCount
        AuthenticatedCount = $authenticatedCount
        PortalSince = if ($portalSince) { $portalSince.ToString('o') } else { $null }
        PortalAgeSeconds = $portalAgeSeconds
        MinimumPortalElapsed = [bool]$minimumPortalElapsed
    }
}

function Test-OpenPathPotentialCaptiveNetwork {
    <#
    .SYNOPSIS
        Detects local IPv4 network evidence before captive portal probes succeed.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param()

    try {
        $activeAdapters = @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' }
        )
    }
    catch {
        $activeAdapters = @()
    }

    if ($activeAdapters.Count -le 0) {
        return $false
    }

    $activeInterfaceIndexes = @(
        $activeAdapters |
            ForEach-Object {
                if ($_.PSObject.Properties['ifIndex']) {
                    [int]$_.ifIndex
                }
                elseif ($_.PSObject.Properties['InterfaceIndex']) {
                    [int]$_.InterfaceIndex
                }
            } |
            Where-Object { $null -ne $_ }
    )

    if ($activeInterfaceIndexes.Count -le 0) {
        return $false
    }

    try {
        $defaultRoutes = @(
            Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object {
                    $activeInterfaceIndexes -contains [int]$_.InterfaceIndex -and
                    $_.NextHop -and
                    [string]$_.NextHop -ne '0.0.0.0' -and
                    -not ([string]$_.NextHop).StartsWith('127.')
                }
        )
        if ($defaultRoutes.Count -gt 0) {
            return $true
        }
    }
    catch {
        # Fall through to gateway evidence.
    }

    try {
        $ipConfigurations = @(
            Get-NetIPConfiguration -ErrorAction SilentlyContinue |
                Where-Object {
                    $activeInterfaceIndexes -contains [int]$_.InterfaceIndex -and
                    $_.IPv4DefaultGateway -and
                    $_.IPv4DefaultGateway.NextHop -and
                    [string]$_.IPv4DefaultGateway.NextHop -ne '0.0.0.0' -and
                    -not ([string]$_.IPv4DefaultGateway.NextHop).StartsWith('127.')
                }
        )
        return ($ipConfigurations.Count -gt 0)
    }
    catch {
        return $false
    }
}

function Test-OpenPathCaptivePortalState {
    <#
    .SYNOPSIS
        Detects captive portal state using multiple endpoints.
    .OUTPUTS
        String: Authenticated | Portal | NoNetwork
    #>
    [CmdletBinding()]
    param(
        [int]$TimeoutSec = 3
    )

    $checks = @(
        @{ Url = 'http://www.msftconnecttest.com/connecttest.txt'; ExpectedStatus = 200; ExpectedBody = 'Microsoft Connect Test' },
        @{ Url = 'http://detectportal.firefox.com/success.txt'; ExpectedStatus = 200; ExpectedBody = 'success' },
        @{ Url = 'http://clients3.google.com/generate_204'; ExpectedStatus = 204; ExpectedBody = '' }
    )

    $total = 0
    $success = 0
    $transportFail = 0

    foreach ($check in $checks) {
        $total += 1

        $statusCode = $null
        $content = ''

        try {
            $resp = Invoke-WebRequest -Uri $check.Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
            $statusCode = [int]$resp.StatusCode
            if ($resp.PSObject.Properties['Content'] -and $resp.Content) {
                $content = [string]$resp.Content
            }
        }
        catch {
            $ex = $_.Exception

            # Attempt to extract HTTP status code from the exception if present
            try {
                if ($ex -and $ex.Response -and $ex.Response.StatusCode) {
                    $statusCode = [int]$ex.Response.StatusCode
                }
            }
            catch {
                # Ignore
            }

            try {
                if (-not $statusCode -and $ex -and $ex.PSObject.Properties['StatusCode']) {
                    $statusCode = [int]$ex.StatusCode
                }
            }
            catch {
                # Ignore
            }

            if (-not $statusCode) {
                $transportFail += 1
            }
            continue
        }

        $content = $content.Trim()
        if ($statusCode -eq [int]$check.ExpectedStatus) {
            if ([string]$check.ExpectedBody -eq '' -or $content -eq [string]$check.ExpectedBody) {
                $success += 1
            }
        }
    }

    if ($total -le 0) {
        return 'NoNetwork'
    }
    if ($transportFail -ge $total) {
        if (Test-OpenPathPotentialCaptiveNetwork) {
            return 'Portal'
        }
        return 'NoNetwork'
    }

    $threshold = [Math]::Floor($total / 2) + 1
    if ($success -ge $threshold) {
        return 'Authenticated'
    }
    return 'Portal'
}

function Enable-OpenPathCaptivePortalMode {
    <#
    .SYNOPSIS
        Enters captive portal mode by routing to limited mode when recovery hosts are
        available, or passthrough mode when none are known.
    .DESCRIPTION
        Merges PortalRecoveryDomains with admin-configured captive portal domains.
        When the combined set is non-empty, delegates to Enable-OpenPathCaptivePortalLimitedMode,
        which keeps the adapter on 127.0.0.1 and forwards only the declared domains.
        When no recovery hosts are available, delegates to Enable-OpenPathCaptivePortalPassthroughMode,
        which resets the adapter DNS to the network resolver (fail-open).
        Supports -WhatIf via SupportsShouldProcess.
    .PARAMETER State
        State label to record in the portal marker (e.g. 'Portal').
    .PARAMETER PortalRecoveryDomains
        Caller-supplied recovery hostnames merged with configured domains.
    .PARAMETER TtlSeconds
        Requested TTL in seconds for the portal marker.
    .OUTPUTS
        Boolean — true when portal mode was successfully entered
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$State = 'Portal',

        [string[]]$PortalRecoveryDomains = @(),

        [int]$TtlSeconds = 300
    )

    if (-not $PSCmdlet.ShouldProcess('OpenPath', 'Enable captive portal mode')) {
        return $false
    }

    $marker = $null
    if (Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore) {
        $marker = Get-OpenPathCaptivePortalMarker
    }
    # Include the admin-declared captive portal domains as recovery hosts so the
    # autonomous watchdog path (which calls this without -PortalRecoveryDomains) enters
    # LIMITED mode -- keeping the adapter on 127.0.0.1 and NX * (fail-closed) and
    # forwarding the declared domains to the network DHCP DNS -- instead of falling back
    # to passthrough (which resets the adapter DNS and is fail-open).
    $allowedHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($PortalRecoveryDomains) + @(Get-OpenPathConfiguredCaptivePortalDomains)))
    if ($allowedHosts.Count -le 0) {
        return (Enable-OpenPathCaptivePortalPassthroughMode -State $State -TtlSeconds $TtlSeconds -ExistingMarker $marker)
    }

    if ($marker -and $marker.mode -eq 'passthrough') {
        return (Enable-OpenPathCaptivePortalLimitedMode -State $State -AllowedHosts $allowedHosts -TtlSeconds $TtlSeconds -Marker $marker)
    }

    return (Enable-OpenPathCaptivePortalLimitedMode -State $State -AllowedHosts $allowedHosts -TtlSeconds $TtlSeconds -Marker $marker)
}

function Disable-OpenPathCaptivePortalMode {
    <#
    .SYNOPSIS
        Exits captive portal mode by restoring the protected DNS posture and clearing
        the portal marker file.
    .DESCRIPTION
        Calls Restore-OpenPathCaptivePortalAcrylicHostState and Restore-OpenPathProtectedMode
        up to three times, then verifies local enforcement posture via
        Get-OpenPathCaptivePortalProtectedModeExitEvidence. Closes on localPostureRestored
        (adapter loopback, normal Acrylic policy, sinkhole, firewall) only — never on
        upstream DNS health, to avoid pinning the machine in portal mode when the
        configured upstream is temporarily blocked. Deletes the portal marker file
        (marker-clear helper) only after posture is confirmed. Supports
        -WhatIf via SupportsShouldProcess.
    .PARAMETER Config
        OpenPath config object used to determine firewall expectation; fetched automatically when null.
    .PARAMETER DnsMaxAttempts
        Maximum retry attempts passed to Get-OpenPathCaptivePortalProtectedModeExitEvidence.
    .PARAMETER DnsDelayMilliseconds
        Delay between DNS retry attempts in milliseconds.
    .PARAMETER DnsAttemptTimeoutSeconds
        Per-attempt DNS timeout in seconds; 0 means no timeout.
    .OUTPUTS
        Boolean — true when protected mode was fully restored and the marker was cleared
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$Config = $null,
        [int]$DnsMaxAttempts = 12,
        [int]$DnsDelayMilliseconds = 1000,
        [int]$DnsAttemptTimeoutSeconds = 0
    )

    if (-not $PSCmdlet.ShouldProcess('OpenPath', 'Disable captive portal mode')) {
        return $false
    }

    $markerPresentAtStart = Test-Path $script:CaptivePortalStatePath
    if ($markerPresentAtStart) {
        Write-OpenPathLog 'Watchdog: Captive portal resolved - restoring DNS protection' -Level WARN
    }
    else {
        Write-OpenPathLog 'Watchdog: captive portal marker is absent - verifying protected DNS mode before closing recovery' -Level WARN
    }

    if (-not $Config) {
        try {
            $Config = Get-OpenPathConfig
        }
        catch {
            $Config = $null
        }
    }

    $maxRestoreAttempts = 3
    $restoreSucceeded = $false
    $restoreEvidence = $null
    for ($attempt = 1; $attempt -le $maxRestoreAttempts; $attempt++) {
        try {
            if (-not (Restore-OpenPathCaptivePortalAcrylicHostState)) {
                Write-OpenPathLog "Watchdog: Acrylic host restore failed on attempt $attempt; keeping captive portal marker active" -Level WARN
                continue
            }

            $restored = Restore-OpenPathProtectedMode -Config $Config
            if (-not $restored) {
                Write-OpenPathLog "Watchdog: protected mode restore failed on attempt $attempt; keeping captive portal marker active" -Level WARN
                continue
            }

            $restoreEvidence = Get-OpenPathCaptivePortalProtectedModeExitEvidence -Config $Config -DnsMaxAttempts $DnsMaxAttempts -DnsDelayMilliseconds $DnsDelayMilliseconds -DnsAttemptTimeoutSeconds $DnsAttemptTimeoutSeconds
            # Close on the LOCAL posture only. Upstream resolution is a network
            # condition; once the marker is gone the normal protected-mode repair
            # plan owns it (it becomes eligible again as soon as portal mode ends).
            $restoreSucceeded = [bool]$restoreEvidence.localPostureRestored
            if ($restoreSucceeded) {
                if (-not [bool]$restoreEvidence.upstreamHealthy) {
                    Write-OpenPathLog 'Watchdog: captive portal closed with the configured upstream still unhealthy (portal_closed_upstream_unhealthy); protected-mode repair owns upstream recovery' -Level WARN
                }
                break
            }

            Write-OpenPathLog "Watchdog: protected mode verification failed on attempt $attempt; keeping captive portal marker active" -Level WARN
        }
        catch {
            Write-OpenPathLog "Watchdog: protected mode restore failed on attempt $attempt; keeping captive portal marker active: $_" -Level WARN
            $restoreSucceeded = $false
        }
    }

    if (-not $restoreSucceeded) {
        if ($markerPresentAtStart) {
            Write-OpenPathLog 'Watchdog: protected mode verification failed; keeping captive portal marker active' -Level WARN
        }
        else {
            Write-OpenPathLog 'Watchdog: no captive portal marker exists but protected mode is still not restored' -Level WARN
        }
        return $false
    }

    if (-not $markerPresentAtStart) {
        $postRestoreEvidence = Get-OpenPathCaptivePortalProtectedModeExitEvidence -Config $Config -DnsMaxAttempts $DnsMaxAttempts -DnsDelayMilliseconds $DnsDelayMilliseconds -DnsAttemptTimeoutSeconds $DnsAttemptTimeoutSeconds
        if (-not ([bool]$postRestoreEvidence.localPostureRestored -and [bool]$postRestoreEvidence.markerCleared)) {
            Write-OpenPathLog 'Watchdog: protected mode verification failed after marker-absent restore' -Level WARN
            return $false
        }
        return $true
    }

    if (-not (Clear-OpenPathCaptivePortalMarker)) {
        Write-OpenPathLog 'Watchdog: captive portal marker could not be cleared after protected mode restore' -Level WARN
        return $false
    }

    $postClearEvidence = Get-OpenPathCaptivePortalProtectedModeExitEvidence -Config $Config -DnsMaxAttempts $DnsMaxAttempts -DnsDelayMilliseconds $DnsDelayMilliseconds -DnsAttemptTimeoutSeconds $DnsAttemptTimeoutSeconds
    if (-not ([bool]$postClearEvidence.localPostureRestored -and [bool]$postClearEvidence.markerCleared)) {
        Write-OpenPathLog 'Watchdog: protected mode verification failed after marker clear; keeping captive portal marker active' -Level WARN
        return $false
    }

    return $true
}

Export-ModuleMember -Function @(
    'Test-OpenPathCaptivePortalModeActive',
    'Test-OpenPathCaptivePortalMarkerExpired',
    'Get-OpenPathCaptivePortalMarker',
    'Get-OpenPathCaptivePortalMarkerMode',
    'Set-OpenPathCaptivePortalMarker',
    'Get-OpenPathConfiguredCaptivePortalDomains',
    'Get-OpenPathCaptivePortalAllowedHosts',
    'Get-OpenPathCaptivePortalProtectedModeExitEvidence',
    'Clear-OpenPathCaptivePortalMarker',
    'Get-OpenPathCaptivePortalObservation',
    'Update-OpenPathCaptivePortalObservation',
    'Get-OpenPathCaptivePortalBootstrapHosts',
    'Get-OpenPathCaptivePortalDynamicHosts',
    'Test-OpenPathPotentialCaptiveNetwork',
    'Test-OpenPathCaptivePortalState',
    'Enable-OpenPathCaptivePortalMode',
    'Disable-OpenPathCaptivePortalMode'
)
