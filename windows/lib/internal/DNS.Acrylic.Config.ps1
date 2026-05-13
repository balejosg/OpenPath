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

function Get-AcrylicExactForwardRule {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Domain)

    $normalizedDomain = $Domain.Trim()
    if (-not $normalizedDomain) { return $null }
    $sslipIpv4Address = Resolve-SslipIpv4Address -Domain $normalizedDomain
    if ($sslipIpv4Address) {
        return "$sslipIpv4Address $normalizedDomain"
    }

    return "FW $normalizedDomain"
}

function Get-OpenPathRuntimeDependencyOverlayPath {
    [CmdletBinding()]
    param()

    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH) {
        return $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
    }

    $root = if ($script:OpenPathRoot) { $script:OpenPathRoot } else { 'C:\OpenPath' }
    if ($root -eq 'C:\OpenPath' -and -not (Test-Path 'C:\' -ErrorAction SilentlyContinue)) {
        return 'C:\OpenPath\data\runtime-dependency-overlay.json'
    }

    return (Join-Path $root 'data\runtime-dependency-overlay.json')
}

function Invoke-OpenPathPolicyStateLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [string]$MutexName = 'Global\OpenPathPolicyStateLock',
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

function Test-OpenPathBlockedSubdomainMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string[]]$BlockedSubdomains = @()
    )

    foreach ($blockedSubdomain in @($BlockedSubdomains)) {
        $blocked = ([string]$blockedSubdomain).Trim().Trim('.')
        if (-not $blocked) { continue }
        if ($Domain.Equals($blocked, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Domain.EndsWith(".$blocked", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    return $false
}

function Test-OpenPathWhitelistCoversHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [System.Collections.Generic.HashSet[string]]$WhitelistSet
    )

    if (-not $Hostname -or -not $WhitelistSet) { return $false }
    if ($WhitelistSet.Contains($Hostname)) { return $true }

    foreach ($whitelistedDomain in $WhitelistSet) {
        if (-not $whitelistedDomain) { continue }
        if ($Hostname.EndsWith(".$whitelistedDomain", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Read-OpenPathRuntimeDependencyOverlay {
    [CmdletBinding()]
    param([string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath))

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return @($parsed.entries)
    }
    catch {
        Write-OpenPathLog "Failed to read runtime dependency overlay: $_" -Level WARN
        return @()
    }
}

function Write-OpenPathRuntimeDependencyOverlay {
    [CmdletBinding()]
    param(
        [object[]]$Entries = @(),
        [string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath)
    )

    $directory = Split-Path $Path -Parent
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    @{
        version = 1
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        entries = @($Entries)
    } | ConvertTo-Json -Depth 8 | Set-Content $Path -Encoding UTF8 -Force
}

function Clear-OpenPathRuntimeDependencyOverlay {
    [CmdletBinding()]
    param([string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath))

    if (Test-Path $Path -ErrorAction SilentlyContinue) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathRuntimeDependencyQueuePath {
    [CmdletBinding()]
    param()

    if ($env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH) {
        return $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH
    }

    $root = if ($script:OpenPathRoot) { $script:OpenPathRoot } else { 'C:\OpenPath' }
    return (Join-Path $root 'data\runtime-dependency-queue')
}

function Get-OpenPathRuntimeDependencyOverlaySettings {
    [CmdletBinding()]
    param()

    $ttlDays = 7
    $capacity = 300
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) {
        try { $ttlDays = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) } catch { $ttlDays = 7 }
    }
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) {
        try { $capacity = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) } catch { $capacity = 300 }
    }

    return [PSCustomObject]@{
        TtlDays = $ttlDays
        Capacity = $capacity
    }
}

function Normalize-OpenPathRuntimeDependencyHost {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if (-not ($Value -is [string])) { return '' }
    $normalized = ([string]$Value).Trim().Trim('.').ToLowerInvariant()
    if (-not $normalized) { return '' }
    if ($normalized.EndsWith('.local', [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    if ($normalized.Length -lt 4 -or $normalized.Length -gt 253) { return '' }
    if ($normalized -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$') { return '' }
    return $normalized
}

function Invoke-OpenPathRuntimeDependencyQueue {
    [CmdletBinding()]
    param(
        [string[]]$WhitelistedDomains = @(),
        [string[]]$BlockedSubdomains = @(),
        [string]$QueuePath = (Get-OpenPathRuntimeDependencyQueuePath)
    )

    $result = [ordered]@{
        Changed = $false
        Processed = 0
        Rejected = 0
        OverlayWriteMs = 0
        QueuePath = $QueuePath
    }

    if (-not (Test-Path $QueuePath -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]$result
    }

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($WhitelistedDomains)) {
        $normalized = Normalize-OpenPathRuntimeDependencyHost -Value $domain
        if ($normalized) { [void]$whitelistSet.Add($normalized) }
    }

    $protectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @(Get-OpenPathProtectedDomains)) {
        $normalized = Normalize-OpenPathRuntimeDependencyHost -Value $domain
        if ($normalized) { [void]$protectedSet.Add($normalized) }
    }

    $settings = Get-OpenPathRuntimeDependencyOverlaySettings
    $now = (Get-Date).ToUniversalTime()
    $expiresAt = $now.AddDays($settings.TtlDays)
    $entries = @(Read-OpenPathRuntimeDependencyOverlay)
    $keptEntries = @()

    foreach ($entry in $entries) {
        $entryDependency = if ($entry.PSObject.Properties['dependencyHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost } else { '' }
        $entryAnchor = if ($entry.PSObject.Properties['anchorHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.anchorHost } else { '' }
        $entryExpiresAt = if ($entry.PSObject.Properties['expiresAt']) { [string]$entry.expiresAt } else { '' }
        $isExpired = $false
        if ($entryExpiresAt) {
            try { $isExpired = ([DateTimeOffset]::Parse($entryExpiresAt).UtcDateTime -le $now) }
            catch { $isExpired = $true }
        }

        if (
            -not $entryDependency -or
            -not $entryAnchor -or
            $isExpired -or
            -not (Test-OpenPathWhitelistCoversHost -Hostname $entryAnchor -WhitelistSet $whitelistSet) -or
            $protectedSet.Contains($entryAnchor) -or
            $protectedSet.Contains($entryDependency) -or
            (Test-OpenPathBlockedSubdomainMatch -Domain $entryDependency -BlockedSubdomains $BlockedSubdomains)
        ) {
            continue
        }

        $keptEntries += $entry
    }

    $requests = @(Get-ChildItem -Path $QueuePath -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)
    foreach ($requestFile in $requests) {
        try {
            $request = Get-Content $requestFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $anchorHost = Normalize-OpenPathRuntimeDependencyHost -Value $request.anchorHost
            $dependencyHost = Normalize-OpenPathRuntimeDependencyHost -Value $request.dependencyHost
            $requestType = if ($request.requestType -is [string]) { ([string]$request.requestType).Trim().ToLowerInvariant() } else { '' }

            if (
                -not $anchorHost -or
                -not $dependencyHost -or
                -not $requestType -or
                $requestType -eq 'main_frame' -or
                $anchorHost -eq $dependencyHost -or
                -not (Test-OpenPathWhitelistCoversHost -Hostname $anchorHost -WhitelistSet $whitelistSet) -or
                $protectedSet.Contains($anchorHost) -or
                $protectedSet.Contains($dependencyHost) -or
                (Test-OpenPathBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains $BlockedSubdomains)
            ) {
                $result['Rejected'] = [int]$result['Rejected'] + 1
                continue
            }

            $updated = $false
            foreach ($entry in $keptEntries) {
                $entryDependency = if ($entry.PSObject.Properties['dependencyHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost } else { '' }
                $entryAnchor = if ($entry.PSObject.Properties['anchorHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.anchorHost } else { '' }
                if ($entryDependency -eq $dependencyHost -and $entryAnchor -eq $anchorHost) {
                    $requestTypes = @($entry.requestTypes)
                    if ($requestTypes -notcontains $requestType) {
                        $requestTypes += $requestType
                    }
                    $entry.lastSeen = $now.ToString('o')
                    $entry.expiresAt = $expiresAt.ToString('o')
                    $entry.requestTypes = @($requestTypes | Sort-Object -Unique)
                    $updated = $true
                    break
                }
            }

            if (-not $updated) {
                $keptEntries += [PSCustomObject]@{
                    dependencyHost = $dependencyHost
                    anchorHost = $anchorHost
                    requestTypes = @($requestType)
                    firstSeen = $now.ToString('o')
                    lastSeen = $now.ToString('o')
                    expiresAt = $expiresAt.ToString('o')
                    source = 'firefox-webrequest-local'
                }
            }

            $result['Processed'] = [int]$result['Processed'] + 1
            $result['Changed'] = $true
        }
        catch {
            $result['Rejected'] = [int]$result['Rejected'] + 1
            Write-OpenPathLog "Rejected runtime dependency queue request $($requestFile.Name): $_" -Level WARN
        }
        finally {
            Remove-Item $requestFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if ($result['Changed']) {
        $keptEntries = @(
            $keptEntries |
                Sort-Object @{ Expression = { if ($_.PSObject.Properties['lastSeen']) { [string]$_.lastSeen } else { '' } }; Descending = $true } |
                Select-Object -First $settings.Capacity
        )
        $overlayStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-OpenPathRuntimeDependencyOverlay -Entries $keptEntries
        $overlayStopwatch.Stop()
        $result['OverlayWriteMs'] = [int]$overlayStopwatch.ElapsedMilliseconds
    }

    return [PSCustomObject]$result
}

function Get-OpenPathRuntimeDependencyDomains {
    [CmdletBinding()]
    param(
        [string[]]$WhitelistedDomains = @(),
        [string[]]$BlockedSubdomains = @(),
        [switch]$Prune
    )

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($WhitelistedDomains)) {
        $normalized = ([string]$domain).Trim().Trim('.')
        if ($normalized) { [void]$whitelistSet.Add($normalized) }
    }

    $protectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @(Get-OpenPathProtectedDomains)) {
        $normalized = ([string]$domain).Trim().Trim('.')
        if ($normalized) { [void]$protectedSet.Add($normalized) }
    }

    $now = Get-Date
    $entries = @(Read-OpenPathRuntimeDependencyOverlay)
    $keptEntries = @()
    $domains = [System.Collections.Generic.List[string]]::new()
    $seenDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $entries) {
        $dependencyHost = if ($entry.PSObject.Properties['dependencyHost']) { ([string]$entry.dependencyHost).Trim().Trim('.').ToLowerInvariant() } else { '' }
        $anchorHost = if ($entry.PSObject.Properties['anchorHost']) { ([string]$entry.anchorHost).Trim().Trim('.').ToLowerInvariant() } else { '' }
        $expiresAt = if ($entry.PSObject.Properties['expiresAt']) { [string]$entry.expiresAt } else { '' }

        $isExpired = $false
        if ($expiresAt) {
            try { $isExpired = ([DateTimeOffset]::Parse($expiresAt).UtcDateTime -le $now.ToUniversalTime()) }
            catch { $isExpired = $true }
        }

        if (
            -not $dependencyHost -or
            -not $anchorHost -or
            $isExpired -or
            -not (Test-OpenPathWhitelistCoversHost -Hostname $anchorHost -WhitelistSet $whitelistSet) -or
            $protectedSet.Contains($dependencyHost) -or
            (Test-OpenPathBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains $BlockedSubdomains) -or
            -not (Test-OpenPathDomainFormat -Domain $dependencyHost)
        ) {
            continue
        }

        $keptEntries += $entry
        if ($seenDomains.Add($dependencyHost)) {
            [void]$domains.Add($dependencyHost)
        }
    }

    if ($Prune -and ($keptEntries.Count -ne $entries.Count)) {
        Write-OpenPathRuntimeDependencyOverlay -Entries $keptEntries
    }

    return $domains.ToArray()
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
    $runtimeDependencyLines = @(
        foreach ($domain in @($RuntimeDependencyDomains)) {
            $normalizedDependency = ([string]$domain).Trim().Trim('.')
            if (-not $normalizedDependency) { continue }
            if (Test-OpenPathBlockedSubdomainMatch -Domain $normalizedDependency -BlockedSubdomains $BlockedSubdomains) { continue }
            Get-AcrylicExactForwardRule -Domain $normalizedDependency
        }
    )

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
    $sections += New-AcrylicHostsSection -Title 'DEFAULT BLOCK (NXDOMAIN for everything else)' -Description 'This MUST come last after FW rules.' -Lines @('NX *')

    $affinityMaskEntries = @(
        Get-AcrylicAffinityMaskEntries -Domains @($essentialDomains + $effectiveWhitelistedDomains)
        Get-AcrylicExactAffinityMaskEntries -Domains @($RuntimeDependencyDomains)
    ) | Select-Object -Unique

    return [PSCustomObject]@{
        UpstreamDNS = $DnsSettings.PrimaryDNS
        Sections = $sections
        WasTruncated = $wasTruncated
        OriginalWhitelistedDomainCount = $originalWhitelistedDomainCount
        EffectiveWhitelistedDomains = $effectiveWhitelistedDomains
        EssentialDomains = @($essentialDomains)
        RuntimeDependencyDomains = @($RuntimeDependencyDomains)
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

    return [bool](Invoke-OpenPathPolicyStateLocked -Action {
        $hostsPath = "$acrylicPath\AcrylicHosts.txt"
        $dnsSettings = Get-OpenPathDnsSettings
        $runtimeDependencyDomains = Get-OpenPathRuntimeDependencyDomains -WhitelistedDomains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains -Prune
        $definition = New-AcrylicHostsDefinition -WhitelistedDomains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains -RuntimeDependencyDomains $runtimeDependencyDomains -DnsSettings $dnsSettings
        if ($definition.WasTruncated) {
            Write-OpenPathLog "Truncating whitelist from $($definition.OriginalWhitelistedDomainCount) to $($dnsSettings.MaxDomains) domains" -Level WARN
        }
        Write-OpenPathLog "Generating AcrylicHosts.txt with $(@($definition.EffectiveWhitelistedDomains).Count) domains..."
        $content = ConvertTo-AcrylicHostsContent -Definition $definition
        $content | Set-Content $hostsPath -Encoding ASCII -Force

        $configurationUpdated = Set-AcrylicConfiguration -WhitelistedDomains $definition.EffectiveWhitelistedDomains -RuntimeDependencyDomains $definition.RuntimeDependencyDomains
        if (-not $configurationUpdated) {
            Write-OpenPathLog "Failed to update AcrylicConfiguration.ini" -Level ERROR
            return $false
        }
        Write-OpenPathLog "AcrylicHosts.txt updated"
        return $true
    })
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
    param(
        [AllowEmptyCollection()][string[]]$WhitelistedDomains = @(),
        [AllowEmptyCollection()][string[]]$RuntimeDependencyDomains = @()
    )

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
    $affinityMaskEntries = @(
        Get-AcrylicAffinityMaskEntries -Domains $allowedForwardDomains
        Get-AcrylicExactAffinityMaskEntries -Domains $RuntimeDependencyDomains
    ) | Select-Object -Unique
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
