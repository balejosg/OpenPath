# OpenPath Captive Portal Module for Windows
# Detects captive portals and manages temporary fail-open mode.

# Import common functions
$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
. (Join-Path $PSScriptRoot 'internal\AcrylicHostsModel.ps1')
. (Join-Path $PSScriptRoot 'internal\AcrylicHostsRenderer.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
$script:CaptivePortalStatePath = "$script:OpenPathRoot\data\captive-portal-active.json"
$script:CaptivePortalObservationPath = "$script:OpenPathRoot\data\captive-portal-observation.json"

function Test-OpenPathCaptivePortalModeActive {
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
                $disabled = Disable-OpenPathCaptivePortalMode
                return (-not [bool]$disabled)
            }
        }
        catch {
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

        $payload = @{
            active = $true
            state = [string]$State
            mode = [string]$Mode
            allowedHosts = @($AllowedHosts)
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
        [switch]$AfterAdapterReset
    )

    $markerUpstream = Get-OpenPathCaptivePortalUpstreamFromMarker -Marker $Marker
    if ($markerUpstream -and $markerUpstream.Address) {
        return $markerUpstream
    }

    if (Get-Command -Name 'Get-OpenPathCaptivePortalUpstreamDns' -ErrorAction SilentlyContinue) {
        try {
            return (Get-OpenPathCaptivePortalUpstreamDns -AfterAdapterReset:$AfterAdapterReset)
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
        [object]$ExistingMarker = $null
    )

    if ($ExistingMarker -and (Get-OpenPathCaptivePortalMarkerMode -Marker $ExistingMarker) -eq 'limited') {
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

    $markerMode = Get-OpenPathCaptivePortalMarkerMode -Marker $Marker
    if ($Marker -and $marker.mode -eq 'passthrough') {
        $markerMode = 'passthrough'
    }

    $existingHosts = @()
    if ($Marker -and $Marker.PSObject.Properties['allowedHosts']) {
        $existingHosts = @($Marker.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    $mergedHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($existingHosts) + @($AllowedHosts)))
    if ($mergedHosts.Count -le 0) {
        return (Enable-OpenPathCaptivePortalPassthroughMode -State $State -TtlSeconds $TtlSeconds -ExistingMarker $Marker)
    }

    $upstream = Resolve-OpenPathCaptivePortalUpstreamDns -Marker $Marker
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
                -TtlSeconds $TtlSeconds | Out-Null
        }
        return $false
    }

    Write-OpenPathLog 'Watchdog: Captive portal detected - entering limited portal mode for exact recovery hosts' -Level WARN

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }
    $hostsPath = Join-Path $acrylicPath 'AcrylicHosts.txt'
    $definition = New-OpenPathLimitedCaptivePortalHostsDefinition -PortalRecoveryDomains $mergedHosts -UpstreamDns ([string]$upstream.Address)
    $content = ConvertTo-AcrylicHostsContent -Definition $definition
    Set-Content -Path $hostsPath -Value $content -Encoding ASCII -Force
    if (-not (Set-OpenPathLimitedCaptivePortalAcrylicConfiguration -UpstreamDns ([string]$upstream.Address))) {
        Restore-OpenPathLimitedCaptivePortalAttempt
        return $false
    }

    if (Get-Command -Name 'Set-LocalDNS' -ErrorAction SilentlyContinue) {
        Set-LocalDNS | Out-Null
    }
    if (Get-Command -Name 'Restart-AcrylicService' -ErrorAction SilentlyContinue) {
        Restart-AcrylicService | Out-Null
    }

    if (-not (Test-OpenPathLimitedCaptivePortalProtection)) {
        Write-OpenPathLog 'Watchdog: captive portal limited mode verification failed; staying protected' -Level WARN
        Restore-OpenPathLimitedCaptivePortalAttempt
        return $false
    }

    Set-OpenPathCaptivePortalMarker -State $State -Mode limited `
        -AllowedHosts $mergedHosts `
        -UpstreamDns ([string]$upstream.Address) `
        -UpstreamDnsSource ([string]$upstream.Source) `
        -UpstreamUsableForLimited ([bool]$upstream.UsableForLimited) `
        -UpstreamVerified ([bool]$upstream.Verified) `
        -TtlSeconds $TtlSeconds | Out-Null
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
    $portalRecoveryLines = @(
        foreach ($domain in @($PortalRecoveryDomains)) {
            Get-AcrylicExactForwardRule -Domain $domain
        }
    )

    $sections = @()
    foreach ($section in @($definition.Sections)) {
        if ([string]$section.Title -like 'DEFAULT BLOCK*') {
            if ($portalRecoveryLines.Count -gt 0) {
                $sections += New-AcrylicHostsSection -Title 'CAPTIVE PORTAL RECOVERY' -Description 'Temporary exact-host recovery access' -Lines @($portalRecoveryLines)
            }
        }
        $sections += $section
    }
    $definition.Sections = @($sections)
    $definition.UpstreamDNS = $UpstreamDns
    return $definition
}

function Set-OpenPathLimitedCaptivePortalAcrylicConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UpstreamDns)

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }

    $configPath = Join-Path $acrylicPath 'AcrylicConfiguration.ini'
    $iniContent = if (Test-Path $configPath -ErrorAction SilentlyContinue) { Get-Content $configPath -Raw } else { "[GlobalSection]`n" }
    if ($iniContent -notmatch '(?m)^\[GlobalSection\]\s*$') {
        $iniContent = "[GlobalSection]`n$iniContent"
    }

    $settings = [ordered]@{
        PrimaryServerAddress = $UpstreamDns
        SecondaryServerAddress = $UpstreamDns
        PrimaryServerDomainNameAffinityMask = ''
        SecondaryServerDomainNameAffinityMask = ''
    }
    foreach ($key in $settings.Keys) {
        $escapedKey = [regex]::Escape($key)
        $pattern = "(?m)^$escapedKey=.*$"
        $replacement = "$key=$($settings[$key])"
        if ($iniContent -match $pattern) {
            $iniContent = $iniContent -replace $pattern, $replacement
        }
        else {
            $globalSection = [regex]::Match($iniContent, '(?m)^\[GlobalSection\]\s*$')
            $iniContent = $iniContent.Insert($globalSection.Index + $globalSection.Length, "`n$replacement")
        }
    }

    Set-Content -Path $configPath -Value $iniContent -Encoding ASCII -Force
    return $true
}

function Test-OpenPathLimitedCaptivePortalProtection {
    [CmdletBinding()]
    param()

    try {
        if ((Get-Command -Name 'Test-FirewallActive' -ErrorAction SilentlyContinue) -and -not (Test-FirewallActive)) {
            return $false
        }
        if ((Get-Command -Name 'Test-DNSResolution' -ErrorAction SilentlyContinue) -and -not (Test-DNSResolution)) {
            return $false
        }
        if ((Get-Command -Name 'Test-DNSSinkhole' -ErrorAction SilentlyContinue) -and -not (Test-DNSSinkhole -Domain 'this-should-be-blocked-test-12345.com')) {
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

        [int]$ExitAuthenticatedCount = 3
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

    if (-not (Test-OpenPathCaptivePortalModeActive)) {
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

    $shouldEnterPortal = ($DetectedState -eq 'Portal' -and $portalCount -ge $EnterPortalCount -and -not (Test-OpenPathCaptivePortalModeActive))
    $shouldExitPortal = ($DetectedState -eq 'Authenticated' -and $authenticatedCount -ge $ExitAuthenticatedCount -and (Test-OpenPathCaptivePortalModeActive))

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
    if (Test-OpenPathCaptivePortalModeActive) {
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
        [PSCustomObject]$Config = $null
    )

    if (-not $PSCmdlet.ShouldProcess('OpenPath', 'Disable captive portal mode')) {
        return $false
    }

    if (-not (Test-Path $script:CaptivePortalStatePath)) {
        return $true
    }

    Write-OpenPathLog 'Watchdog: Captive portal resolved - restoring DNS protection' -Level WARN

    if (-not $Config) {
        try {
            $Config = Get-OpenPathConfig
        }
        catch {
            $Config = $null
        }
    }

    try {
        if (-not (Restore-OpenPathCaptivePortalAcrylicHostState)) {
            Write-OpenPathLog 'Watchdog: Acrylic host restore failed; keeping captive portal marker active' -Level WARN
            return $false
        }

        $restored = Restore-OpenPathProtectedMode -Config $Config
        if (-not $restored) {
            Write-OpenPathLog 'Watchdog: protected mode restore failed; keeping captive portal marker active' -Level WARN
            return $false
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: protected mode restore failed; keeping captive portal marker active: $_" -Level WARN
        return $false
    }

    $enforcementHealthy = $true
    $firewallExpected = $true
    if ($Config -and $Config.PSObject.Properties['enableFirewall']) {
        $firewallExpected = [bool]$Config.enableFirewall
    }

    try {
        if ((Get-Command -Name 'Test-DNSResolution' -ErrorAction SilentlyContinue) -and -not (Test-DNSResolution)) {
            $enforcementHealthy = $false
        }
        if ((Get-Command -Name 'Test-DNSSinkhole' -ErrorAction SilentlyContinue) -and -not (Test-DNSSinkhole -Domain 'this-should-be-blocked-test-12345.com')) {
            $enforcementHealthy = $false
        }
        if ($firewallExpected -and (Get-Command -Name 'Test-FirewallActive' -ErrorAction SilentlyContinue) -and -not (Test-FirewallActive)) {
            $enforcementHealthy = $false
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: protected mode verification failed; keeping captive portal marker active: $_" -Level WARN
        return $false
    }

    if (-not $enforcementHealthy) {
        Write-OpenPathLog 'Watchdog: protected mode verification failed; keeping captive portal marker active' -Level WARN
        return $false
    }

    Clear-OpenPathCaptivePortalMarker | Out-Null
    return $true
}

Export-ModuleMember -Function @(
    'Test-OpenPathCaptivePortalModeActive',
    'Get-OpenPathCaptivePortalMarker',
    'Set-OpenPathCaptivePortalMarker',
    'Clear-OpenPathCaptivePortalMarker',
    'Get-OpenPathCaptivePortalObservation',
    'Update-OpenPathCaptivePortalObservation',
    'Test-OpenPathPotentialCaptiveNetwork',
    'Test-OpenPathCaptivePortalState',
    'Enable-OpenPathCaptivePortalMode',
    'Disable-OpenPathCaptivePortalMode'
)
