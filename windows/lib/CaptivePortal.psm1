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

    if ($marker.PSObject.Properties['expiresAt'] -and $marker.expiresAt) {
        try {
            $expiresAt = ([DateTimeOffset]::Parse([string]$marker.expiresAt)).UtcDateTime
            if ([DateTime]::UtcNow -ge $expiresAt) {
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
        }
        catch {
            Write-OpenPathLog 'Watchdog: failed to close expired captive portal passthrough marker; keeping marker active (details redacted)' -Level WARN
            return $true
        }
    }

    return $true
}

function Get-OpenPathCaptivePortalMarker {
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
    $enforcementRestored = ($normalProtected -and $dnsResolutionHealthy -and $sinkholeHealthy -and ((-not $firewallExpected) -or $firewallHealthy))

    return [PSCustomObject]@{
        localDnsLoopbackRestored = $localDnsLoopbackRestored
        acrylicNormalRestored = $acrylicNormalRestored
        dnsResolutionHealthy = $dnsResolutionHealthy
        sinkholeHealthy = $sinkholeHealthy
        firewallExpectedActive = $firewallExpected
        firewallHealthy = $firewallHealthy
        markerPresent = $markerPresent
        markerCleared = $markerCleared
        enforcementRestored = $enforcementRestored
        protectedModeRestored = ($enforcementRestored -and $markerCleared)
    }
}

function Get-OpenPathCaptivePortalUpstreamFromMarker {
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
    return [PSCustomObject]@{
        Address = ''
        Source = 'unavailable'
        Verified = $false
        UsableForLimited = $false
        PreReset = $false
    }
}

function Resolve-OpenPathCaptivePortalUpstreamDns {
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
        Write-OpenPathLog 'Watchdog: captive portal limited mode verification failed; falling back to bounded passthrough' -Level WARN
        Restore-OpenPathLimitedCaptivePortalAttempt
        return (Enable-OpenPathCaptivePortalPassthroughMode -State $State -TtlSeconds $TtlSeconds -ExistingMarker $Marker -ForcePassthrough)
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

        $expectedRule = Get-AcrylicExactForwardRule -Domain $Domain
        if (-not $expectedRule) {
            return $false
        }

        $content = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction Stop
        $match = [regex]::Match($content, "(?m)^\s*$([regex]::Escape($expectedRule))\s*$")
        if (-not $match.Success) {
            return $false
        }

        $defaultBlockIndex = $content.IndexOf("NX *")
        if (-not ($defaultBlockIndex -lt 0 -or $match.Index -lt $defaultBlockIndex)) {
            return $false
        }

        return [bool](Test-OpenPathLimitedCaptivePortalDnsResolution -Domain $Domain -DnsMaxAttempts $DnsMaxAttempts -DnsDelayMilliseconds $DnsDelayMilliseconds -DnsAttemptTimeoutSeconds $DnsAttemptTimeoutSeconds)
    }
    catch {
        return $false
    }
}

function Set-OpenPathLimitedCaptivePortalAcrylicConfiguration {
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
    $recoveryAffinityMask = (@(
        @(Get-AcrylicExactAffinityMaskEntries -Domains $exactRecoveryDomains)
        @(Get-AcrylicAffinityMaskEntries -Domains $inclusiveRecoveryDomains)
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
        "LocalIPv4BindingAddress" = "0.0.0.0"
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
    try {
        Remove-Item -Path $script:CaptivePortalStatePath -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Get-OpenPathCaptivePortalObservation {
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
            try { $portalSince = [datetime]::Parse([string]$existing.portalSince) } catch { $portalSince = $null }
        }
    }

    if (-not (Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore)) {
        $portalSince = $null
    }
    elseif (-not $portalSince) {
        $marker = Get-OpenPathCaptivePortalMarker
        if ($marker -and $marker.PSObject.Properties['since'] -and $marker.since) {
            try { $portalSince = [datetime]::Parse([string]$marker.since) } catch { $portalSince = $now }
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
    $allowedHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts $PortalRecoveryDomains)
    if ($allowedHosts.Count -le 0) {
        return (Enable-OpenPathCaptivePortalPassthroughMode -State $State -TtlSeconds $TtlSeconds -ExistingMarker $marker)
    }

    if ($marker -and $marker.mode -eq 'passthrough') {
        return (Enable-OpenPathCaptivePortalLimitedMode -State $State -AllowedHosts $allowedHosts -TtlSeconds $TtlSeconds -Marker $marker)
    }

    return (Enable-OpenPathCaptivePortalLimitedMode -State $State -AllowedHosts $allowedHosts -TtlSeconds $TtlSeconds -Marker $marker)
}

function Disable-OpenPathCaptivePortalMode {
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
            $restoreSucceeded = [bool]$restoreEvidence.enforcementRestored
            if ($restoreSucceeded) {
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
        if (-not [bool]$postRestoreEvidence.protectedModeRestored) {
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
    if (-not [bool]$postClearEvidence.protectedModeRestored) {
        Write-OpenPathLog 'Watchdog: protected mode verification failed after marker clear; keeping captive portal marker active' -Level WARN
        return $false
    }

    return $true
}

Export-ModuleMember -Function @(
    'Test-OpenPathCaptivePortalModeActive',
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
