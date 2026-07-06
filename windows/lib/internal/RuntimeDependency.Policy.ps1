if (-not (Get-Variable -Name OpenPathRuntimeDependencyActionAllowLocal -Scope Script -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $runtimeDependencyProtocolPath = Join-Path $PSScriptRoot 'RuntimeDependency.Protocol.ps1'
    if (Test-Path $runtimeDependencyProtocolPath -ErrorAction SilentlyContinue) {
        . $runtimeDependencyProtocolPath
    }
}

if (-not (Get-Command -Name 'Get-OpenPathMicrosoftSystemDomains' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $commonDomainsCatalogPath = Join-Path $PSScriptRoot 'Common.Domains.Catalog.ps1'
    if (Test-Path $commonDomainsCatalogPath -ErrorAction SilentlyContinue) {
        . $commonDomainsCatalogPath
    }
}

function Normalize-OpenPathRuntimeDependencyHost {
    # trims, lowercases, and validates a host string; returns empty string for .local hosts, single-label names, or format violations
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

function Test-OpenPathBlockedSubdomainMatch {
    # returns true when $Domain equals or is a subdomain of any entry in $BlockedSubdomains
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string[]]$BlockedSubdomains = @()
    )

    foreach ($blockedSubdomain in @($BlockedSubdomains)) {
        $blocked = Normalize-OpenPathRuntimeDependencyHost -Value $blockedSubdomain
        if (-not $blocked) { continue }
        if ($Domain.Equals($blocked, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Domain.EndsWith(".$blocked", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    return $false
}

function Test-OpenPathWhitelistCoversHost {
    # returns true when $Hostname is present in $WhitelistSet directly or as a subdomain of a set entry
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

function Get-OpenPathRuntimeDependencyProtectedHosts {
    # builds the set of hosts that may never appear as runtime dependency candidates; includes os/browser infrastructure and api/whitelist urls from $State
    [CmdletBinding()]
    param([AllowNull()][PSCustomObject]$State = $null)

    $hosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $domainSources = @()
    if (Get-Command -Name 'Get-OpenPathProtectedDomains' -ErrorAction SilentlyContinue) {
        $domainSources += @(Get-OpenPathProtectedDomains)
    }
    if (Get-Command -Name 'Get-OpenPathAlwaysAllowedDomains' -ErrorAction SilentlyContinue) {
        $domainSources += @(Get-OpenPathAlwaysAllowedDomains)
    }
    foreach ($requiredCatalogCommand in @('Get-OpenPathCaptivePortalProbeDomains', 'Get-OpenPathMicrosoftSystemDomains', 'Get-OpenPathFirefoxSystemDomains')) {
        if (-not (Get-Command -Name $requiredCatalogCommand -ErrorAction SilentlyContinue)) {
            throw "Common.Domains.Catalog.ps1 is required for the runtime dependency protected-host floor ($requiredCatalogCommand missing)"
        }
    }
    # Composition is set-equal to the previous inline list: the catalog's extra
    # '*.windowsupdate.com' wildcard is dropped by Normalize-OpenPathRuntimeDependencyHost
    # and the msftconnecttest pair dedupes into the probe set (pinned at 58 by
    # Windows.Common.Core.Tests.ps1 'Domain catalog characterization').
    $domainSources += @(Get-OpenPathCaptivePortalProbeDomains)
    $domainSources += @('time.windows.com', 'time.google.com')
    $domainSources += @(Get-OpenPathMicrosoftSystemDomains)
    $domainSources += @(Get-OpenPathFirefoxSystemDomains)

    foreach ($domain in $domainSources) {
        $normalized = Normalize-OpenPathRuntimeDependencyHost -Value $domain
        if ($normalized) { [void]$hosts.Add($normalized) }
    }

    if ($State) {
        foreach ($propertyName in @('apiUrl', 'requestApiUrl', 'whitelistUrl')) {
            if (-not $State.PSObject.Properties[$propertyName]) { continue }
            try {
                $uri = [System.Uri]([string]$State.$propertyName)
                $normalized = Normalize-OpenPathRuntimeDependencyHost -Value $uri.Host
                if ($normalized) { [void]$hosts.Add($normalized) }
            }
            catch { }
        }
    }

    return $hosts
}

function Test-OpenPathProtectedRuntimeDependencyHost {
    # returns true when $Hostname is in $ProtectedHosts or is a subdomain of any entry in that set
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts
    )

    if (-not $Hostname -or -not $ProtectedHosts) { return $false }
    if ($ProtectedHosts.Contains($Hostname)) { return $true }

    foreach ($protectedHost in $ProtectedHosts) {
        if (-not $protectedHost) { continue }
        if ($Hostname.EndsWith(".$protectedHost", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-OpenPathRuntimeDependencySensitiveField {
    # returns true when $Message contains any field that could carry url, header, body, or credential data
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Message)

    foreach ($field in @(
            'url',
            'resourceUrl',
            'target_url',
            'targetUrl',
            'originUrl',
            'documentUrl',
            'pageUrl',
            'headers',
            'body',
            'path',
            'query',
            'dom',
            'title',
            'resources',
            'token',
            'authorization',
            'cookie',
            'cookies'
        )) {
        if ($Message.PSObject.Properties[$field]) { return $true }
    }

    return $false
}

function New-OpenPathRuntimeDependencyWhitelistSet {
    # builds a case-insensitive hashset of normalized domain strings from $WhitelistedDomains for fast host coverage checks
    [CmdletBinding()]
    param([string[]]$WhitelistedDomains = @())

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($WhitelistedDomains)) {
        $normalized = Normalize-OpenPathRuntimeDependencyHost -Value $domain
        if ($normalized) { [void]$whitelistSet.Add($normalized) }
    }
    return $whitelistSet
}

function Test-OpenPathRuntimeDependencyCandidate {
    # validates a dependency message against whitelist, protected host, and blocked subdomain rules; returns Valid flag plus resolved host/type or a failure result
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Message,
        [string[]]$WhitelistedDomains = @(),
        [string[]]$BlockedSubdomains = @(),
        [AllowNull()][PSCustomObject]$State = $null,
        [switch]$SkipOverlayCheck
    )

    if (Test-OpenPathRuntimeDependencySensitiveField -Message $Message) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'Sensitive fields are not accepted' }
        }
    }

    $anchorHost = Normalize-OpenPathRuntimeDependencyHost -Value $Message.anchorHost
    $dependencyHost = Normalize-OpenPathRuntimeDependencyHost -Value $Message.dependencyHost
    $requestType = if ($Message.requestType -is [string]) { ([string]$Message.requestType).Trim().ToLowerInvariant() } else { '' }

    if (-not $anchorHost -or -not $dependencyHost -or -not $requestType) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'Invalid runtime dependency payload' }
        }
    }
    if ($requestType -eq 'main_frame') {
        return @{
            Valid = $false
            Result = @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'main_frame dependencies are not supported' }
        }
    }
    if ($anchorHost -eq $dependencyHost) {
        return @{
            Valid = $false
            Result = @{ success = $true; action = $script:OpenPathRuntimeDependencyActionAllowLocal; skipped = $true; reason = 'same-host' }
        }
    }

    $whitelistSet = New-OpenPathRuntimeDependencyWhitelistSet -WhitelistedDomains $WhitelistedDomains
    if (-not (Test-OpenPathWhitelistCoversHost -Hostname $anchorHost -WhitelistSet $whitelistSet)) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Anchor host is not locally whitelisted' }
        }
    }

    $protectedHosts = Get-OpenPathRuntimeDependencyProtectedHosts -State $State
    if (
        (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $anchorHost -ProtectedHosts $protectedHosts) -or
        (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $dependencyHost -ProtectedHosts $protectedHosts)
    ) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Protected hosts are not accepted as runtime dependencies' }
        }
    }
    if (Test-OpenPathBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains $BlockedSubdomains) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Blocked hosts are not accepted as runtime dependencies' }
        }
    }
    if (Test-OpenPathWhitelistCoversHost -Hostname $dependencyHost -WhitelistSet $whitelistSet) {
        return @{
            Valid = $false
            Result = @{ success = $true; action = $script:OpenPathRuntimeDependencyActionAllowLocal; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; skipped = $true; reason = 'dependency-already-whitelisted' }
        }
    }
    if (-not $SkipOverlayCheck -and (Get-Command -Name 'Test-OpenPathRuntimeDependencyOverlayContainsDomains' -ErrorAction SilentlyContinue)) {
        if (Test-OpenPathRuntimeDependencyOverlayContainsDomains -Domains @($dependencyHost)) {
            return @{
                Valid = $false
                Result = @{ success = $true; action = $script:OpenPathRuntimeDependencyActionAllowLocal; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; skipped = $true; reason = 'runtime-dependency-overlay-present' }
            }
        }
    }

    return @{
        Valid = $true
        AnchorHost = $anchorHost
        DependencyHost = $dependencyHost
        RequestType = $requestType
    }
}
