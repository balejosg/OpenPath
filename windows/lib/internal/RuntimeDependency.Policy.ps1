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

function Test-OpenPathBlockedSubdomainMatch {
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
    $domainSources += @(
        'detectportal.firefox.com',
        'connectivity-check.ubuntu.com',
        'captive.apple.com',
        'www.msftconnecttest.com',
        'msftconnecttest.com',
        'clients3.google.com',
        'time.windows.com',
        'time.google.com',
        'windowsupdate.com',
        'windowsupdate.microsoft.com',
        'update.microsoft.com',
        'delivery.mp.microsoft.com',
        'do.dsp.mp.microsoft.com',
        'api.cdp.microsoft.com',
        'definitionupdates.microsoft.com',
        'download.microsoft.com',
        'download.windowsupdate.com',
        'go.microsoft.com',
        'adl.windows.com',
        'tsfe.trafficshaping.dsp.mp.microsoft.com',
        'wdcp.microsoft.com',
        'wdcpalt.microsoft.com',
        'wd.microsoft.com',
        'smartscreen-prod.microsoft.com',
        'crl.microsoft.com',
        'www.microsoft.com',
        'wns.windows.com',
        'displaycatalog.mp.microsoft.com',
        'storequality.microsoft.com',
        'dsx.mp.microsoft.com',
        'edge.microsoft.com',
        'config.edge.skype.com',
        'iecvlist.microsoft.com',
        'manage.microsoft.com',
        'dm.microsoft.com',
        'graph.microsoft.com',
        'login.microsoft.com',
        'login.live.com',
        'login.microsoftonline.com',
        'aadcdn.msauth.net',
        'aadcdn.msftauth.net',
        'azureedge.net',
        'blob.core.windows.net',
        'aus5.mozilla.org',
        'firefox.settings.services.mozilla.com',
        'firefox-settings-attachments.cdn.mozilla.net',
        'content-signature-2.cdn.mozilla.net',
        'download.mozilla.org',
        'download.cdn.mozilla.net',
        'archive.mozilla.org',
        'ftp.mozilla.org',
        'safebrowsing.googleapis.com',
        'addons.mozilla.org',
        'versioncheck.addons.mozilla.org',
        'services.addons.mozilla.org',
        'ciscobinary.openh264.org',
        'redirector.gvt1.com',
        'clients2.googleusercontent.com'
    )

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
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Sensitive fields are not accepted' }
        }
    }

    $anchorHost = Normalize-OpenPathRuntimeDependencyHost -Value $Message.anchorHost
    $dependencyHost = Normalize-OpenPathRuntimeDependencyHost -Value $Message.dependencyHost
    $requestType = if ($Message.requestType -is [string]) { ([string]$Message.requestType).Trim().ToLowerInvariant() } else { '' }

    if (-not $anchorHost -or -not $dependencyHost -or -not $requestType) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Invalid runtime dependency payload' }
        }
    }
    if ($requestType -eq 'main_frame') {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'main_frame dependencies are not supported' }
        }
    }
    if ($anchorHost -eq $dependencyHost) {
        return @{
            Valid = $false
            Result = @{ success = $true; action = 'allow-local-runtime-dependency'; skipped = $true; reason = 'same-host' }
        }
    }

    $whitelistSet = New-OpenPathRuntimeDependencyWhitelistSet -WhitelistedDomains $WhitelistedDomains
    if (-not (Test-OpenPathWhitelistCoversHost -Hostname $anchorHost -WhitelistSet $whitelistSet)) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Anchor host is not locally whitelisted' }
        }
    }

    $protectedHosts = Get-OpenPathRuntimeDependencyProtectedHosts -State $State
    if (
        (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $anchorHost -ProtectedHosts $protectedHosts) -or
        (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $dependencyHost -ProtectedHosts $protectedHosts)
    ) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Protected hosts are not accepted as runtime dependencies' }
        }
    }
    if (Test-OpenPathBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains $BlockedSubdomains) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Blocked hosts are not accepted as runtime dependencies' }
        }
    }
    if (Test-OpenPathWhitelistCoversHost -Hostname $dependencyHost -WhitelistSet $whitelistSet) {
        return @{
            Valid = $false
            Result = @{ success = $true; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; skipped = $true; reason = 'dependency-already-whitelisted' }
        }
    }
    if (-not $SkipOverlayCheck -and (Get-Command -Name 'Test-OpenPathRuntimeDependencyOverlayContainsDomains' -ErrorAction SilentlyContinue)) {
        if (Test-OpenPathRuntimeDependencyOverlayContainsDomains -Domains @($dependencyHost)) {
            return @{
                Valid = $false
                Result = @{ success = $true; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; skipped = $true; reason = 'runtime-dependency-overlay-present' }
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
