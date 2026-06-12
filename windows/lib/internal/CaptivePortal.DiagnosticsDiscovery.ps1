function Get-OpenPathCaptivePortalEvidenceContract {
    <#
    .SYNOPSIS
        Documents the captive portal evidence fields and their decision roles.
    .DESCRIPTION
        The product path may use productGate fields for limited-mode readiness
        and postAuthGate fields for authenticated restoration. diagnosticOnly
        fields are retained for operator evidence and compatibility, but must
        not decide success, RecentSuccess, or limitedModeReady.
    #>
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        productGate = @(
            'mode',
            'allowedHosts',
            'configuredCaptivePortalDomains',
            'configuredCaptivePortalDomainsApplied',
            'limitedModeReady',
            'recoveryHostsApplied',
            'fallbackMode'
        )
        postAuthGate = @(
            'localDnsLoopbackRestored',
            'acrylicNormalRestored',
            'dnsResolutionHealthy',
            'sinkholeHealthy',
            'firewallHealthy',
            'enforcementRestored',
            'markerCleared',
            'protectedModeRestored'
        )
        diagnosticOnly = @(
            'bootstrapHosts',
            'redirectHosts',
            'resourceHosts',
            'observedRuntimeHosts',
            'pendingRuntimeHosts',
            'effectiveHosts',
            'effectiveExactHosts',
            'discoveryTruncated',
            'errors'
        )
        compatibility = @(
            'Get-OpenPathCaptivePortalBootstrapHosts',
            'Get-OpenPathCaptivePortalDynamicHosts',
            'bootstrapHosts',
            'redirectHosts',
            'resourceHosts',
            'observedRuntimeHosts',
            'pendingRuntimeHosts',
            'effectiveHosts',
            'discoveryTruncated'
        )
    }
}

function Reject-OpenPathCaptivePortalDynamicHost {
    # returns a non-empty rejection reason string when the host is not safe to use as a recovery host
    # accepted: multi-label public hostnames that are not ip addresses, .local names, wildcards, or protected hosts
    param(
        [string]$HostName,
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null
    )

    if (-not $HostName) { return 'invalid-host' }
    if ($HostName.StartsWith('*.') -or $HostName.StartsWith('.')) { return 'parent-wildcard' }
    if ($HostName -match '^\d{1,3}(?:\.\d{1,3}){3}$' -or $HostName -match '^\[[0-9a-f:]+\]$') { return 'ip-address' }
    if ($HostName.EndsWith('.local', [System.StringComparison]::OrdinalIgnoreCase)) { return '.local' }
    if ($HostName -notmatch '\.') { return 'single-label' }
    if ($HostName.Length -lt 4 -or $HostName.Length -gt 253) { return 'invalid-host' }
    if ($HostName -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$') { return 'invalid-host' }
    if ($ProtectedHosts -and (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $HostName -ProtectedHosts $ProtectedHosts)) { return 'protected-host' }
    return ''
}

function Normalize-OpenPathCaptivePortalDynamicHost {
    # extracts a hostname from a uri object or string, lowercases it, and rejects unsafe candidates
    # returns an empty string when the value is absent or rejected
    param(
        [AllowNull()][object]$Value,
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null
    )

    $candidate = ''
    if ($Value -is [System.Uri]) {
        $candidate = [string]$Value.Host
    }
    elseif ($Value -is [string]) {
        $raw = ([string]$Value).Trim()
        if (-not $raw) { return '' }
        try {
            if ($raw -match '^[a-z][a-z0-9+.-]*://') {
                $candidate = ([System.Uri]$raw).Host
            }
            else {
                $candidate = $raw
            }
        }
        catch {
            $candidate = $raw
        }
    }

    $candidate = $candidate.Trim().TrimEnd('.').ToLowerInvariant()
    if (Reject-OpenPathCaptivePortalDynamicHost -HostName $candidate -ProtectedHosts $ProtectedHosts) { return '' }
    return $candidate
}

function Extract-OpenPathCaptivePortalHostsFromText {
    # scans html or plaintext for https/http host references using regex patterns
    # stops collecting once the host count reaches the limit and returns only safe, normalized hosts
    param(
        [AllowNull()][string]$Text = '',
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null,
        [int]$MaxHosts = 32
    )

    $hosts = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $patterns = @(
        '(?i)\bhttps?://(?<host>[a-z0-9.-]+)',
        '(?i)\b(?:href|src|action)\s*=\s*["'']https?://(?<host>[a-z0-9.-]+)',
        '(?i)\bfetch\s*\(\s*["'']https?://(?<host>[a-z0-9.-]+)'
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            $hostName = Normalize-OpenPathCaptivePortalDynamicHost -Value $match.Groups['host'].Value -ProtectedHosts $ProtectedHosts
            if ($hostName -and -not $hosts.Contains($hostName)) {
                $hosts.Add($hostName)
                if ($hosts.Count -ge $MaxHosts) { return @($hosts) }
            }
        }
    }

    return @($hosts)
}

function Add-OpenPathCaptivePortalHostCandidate {
    # normalizes a single host candidate and appends it to the provided list when it passes validation
    # records a rejection reason in errors when the candidate is unsafe; no-ops when the list is full
    param(
        [System.Collections.Generic.List[string]]$Hosts,
        [System.Collections.Generic.List[string]]$Errors,
        [AllowNull()][object]$Value,
        [string]$Kind = 'host',
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null,
        [int]$MaxHosts = 32
    )

    $raw = if ($null -eq $Value) { '' } else { ([string]$Value).Trim() }
    $hostName = ''
    if ($Value -is [System.Uri]) {
        $hostName = ([System.Uri]$Value).Host
    }
    elseif ($raw) {
        try {
            if ($raw -match '^[a-z][a-z0-9+.-]*://') {
                $hostName = ([System.Uri]$raw).Host
            }
            else {
                $hostName = $raw
            }
        }
        catch {
            $hostName = $raw
        }
    }

    $hostName = $hostName.Trim().TrimEnd('.').ToLowerInvariant()
    $rejection = Reject-OpenPathCaptivePortalDynamicHost -HostName $hostName -ProtectedHosts $ProtectedHosts
    if ($rejection) {
        if (-not $Errors.Contains("$Kind`:$rejection")) {
            $Errors.Add("$Kind`:$rejection")
        }
        return
    }

    if ($Hosts.Count -lt $MaxHosts -and -not $Hosts.Contains($hostName)) {
        $Hosts.Add($hostName)
    }
}

function Get-OpenPathCaptivePortalBootstrapHosts {
    # classifies each seed url or text snippet into bootstrap, redirect, and resource host buckets
    # optionally fetches each seed url to follow redirect chains and extract resource hosts from html
    # returns a result object with truncated flag when the host limit is reached
    param(
        [string[]]$SeedUrls = @(),
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null,
        [int]$MaxHosts = 32,
        [int]$MaxTextBytes = 32768,
        [int]$HttpTimeoutSeconds = 2,
        [int]$MaxHttpRedirects = 4,
        [scriptblock]$RequestFactory = $null,
        [switch]$FetchSeedUrls
    )

    $bootstrapHosts = [System.Collections.Generic.List[string]]::new()
    $redirectHosts = [System.Collections.Generic.List[string]]::new()
    $resourceHosts = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $truncated = $false
    if (-not $ProtectedHosts -and (Get-Command -Name 'Get-OpenPathRuntimeDependencyProtectedHosts' -ErrorAction SilentlyContinue)) {
        $ProtectedHosts = Get-OpenPathRuntimeDependencyProtectedHosts
    }

    foreach ($seed in @($SeedUrls)) {
        $totalHosts = $bootstrapHosts.Count + $redirectHosts.Count + $resourceHosts.Count
        if ($totalHosts -ge $MaxHosts) {
            $truncated = $true
            break
        }

        $seedLooksLikeUrl = ([string]$seed -match '^[a-z][a-z0-9+.-]*://')
        $seedIsRedirect = ($seedLooksLikeUrl -and $bootstrapHosts.Count -gt 0)
        if ($seedIsRedirect) {
            Add-OpenPathCaptivePortalHostCandidate -Hosts $redirectHosts -Errors $errors -Value $seed -Kind 'redirect' -ProtectedHosts $ProtectedHosts -MaxHosts $MaxHosts
        }
        else {
            Add-OpenPathCaptivePortalHostCandidate -Hosts $bootstrapHosts -Errors $errors -Value $seed -Kind 'bootstrap' -ProtectedHosts $ProtectedHosts -MaxHosts $MaxHosts
        }
        $remaining = [Math]::Max(0, $MaxHosts - ($bootstrapHosts.Count + $redirectHosts.Count + $resourceHosts.Count))
        if ($remaining -le 0) {
            $truncated = $true
            break
        }

        if ([string]$seed -and -not $seedLooksLikeUrl -and ([string]$seed).Length -le $MaxTextBytes) {
            foreach ($textHost in @(Extract-OpenPathCaptivePortalHostsFromText -Text ([string]$seed) -ProtectedHosts $ProtectedHosts -MaxHosts $remaining)) {
                Add-OpenPathCaptivePortalHostCandidate -Hosts $resourceHosts -Errors $errors -Value $textHost -Kind 'resource' -ProtectedHosts $ProtectedHosts -MaxHosts $MaxHosts
            }
        }
        elseif ([string]$seed -and -not $seedLooksLikeUrl) {
            $truncated = $true
        }

        if (-not $FetchSeedUrls -or -not $seedLooksLikeUrl) {
            continue
        }

        $probe = Invoke-OpenPathCaptivePortalBootstrapProbe `
            -SeedUrl ([string]$seed) `
            -ProtectedHosts $ProtectedHosts `
            -MaxHosts ([Math]::Max(1, $MaxHosts - ($bootstrapHosts.Count + $redirectHosts.Count + $resourceHosts.Count))) `
            -MaxTextBytes $MaxTextBytes `
            -TimeoutSeconds $HttpTimeoutSeconds `
            -MaxRedirects $MaxHttpRedirects `
            -RequestFactory $RequestFactory
        foreach ($probeHost in @($probe.bootstrapHosts)) {
            if ($seedIsRedirect) {
                Add-OpenPathCaptivePortalHostCandidate -Hosts $redirectHosts -Errors $errors -Value $probeHost -Kind 'redirect' -ProtectedHosts $ProtectedHosts -MaxHosts $MaxHosts
            }
            else {
                Add-OpenPathCaptivePortalHostCandidate -Hosts $bootstrapHosts -Errors $errors -Value $probeHost -Kind 'bootstrap' -ProtectedHosts $ProtectedHosts -MaxHosts $MaxHosts
            }
        }
        foreach ($probeHost in @($probe.redirectHosts)) {
            Add-OpenPathCaptivePortalHostCandidate -Hosts $redirectHosts -Errors $errors -Value $probeHost -Kind 'redirect' -ProtectedHosts $ProtectedHosts -MaxHosts $MaxHosts
        }
        foreach ($probeHost in @($probe.resourceHosts)) {
            Add-OpenPathCaptivePortalHostCandidate -Hosts $resourceHosts -Errors $errors -Value $probeHost -Kind 'resource' -ProtectedHosts $ProtectedHosts -MaxHosts $MaxHosts
        }
        if ([bool]$probe.truncated) {
            $truncated = $true
        }
    }

    return [PSCustomObject]@{
        bootstrapHosts = @($bootstrapHosts)
        redirectHosts = @($redirectHosts)
        resourceHosts = @($resourceHosts)
        errors = @($errors)
        truncated = [bool]$truncated
    }
}

function Get-OpenPathCaptivePortalBootstrapSeedUrls {
    # converts a list of host names into http seed urls for use as bootstrap probe targets
    # skips any host that does not pass normalization
    param(
        [string[]]$Hosts = @(),
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null
    )

    return @(
        foreach ($hostName in @($Hosts)) {
            $normalizedHost = Normalize-OpenPathCaptivePortalDynamicHost -Value $hostName -ProtectedHosts $ProtectedHosts
            if (-not $normalizedHost) { continue }
            "http://$normalizedHost/"
        }
    ) | Select-Object -Unique
}

function Resolve-OpenPathCaptivePortalRedirectUri {
    # resolves a location header value relative to the base uri used in the request
    # returns null when the location string is absent or the uri cannot be constructed
    param(
        [Parameter(Mandatory = $true)][System.Uri]$BaseUri,
        [AllowNull()][string]$Location = ''
    )

    if ([string]::IsNullOrWhiteSpace($Location)) { return $null }
    try {
        return [System.Uri]::new($BaseUri, $Location)
    }
    catch {
        return $null
    }
}

function Invoke-OpenPathCaptivePortalBootstrapProbe {
    # fetches a single seed url and follows its redirect chain up to the redirect limit
    # classifies the initial request host as bootstrap, each redirect as redirect, and body urls as resource
    # does not send credentials or cookies; uses a bounded read to avoid large response handling
    param(
        [Parameter(Mandatory = $true)][string]$SeedUrl,
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null,
        [int]$MaxHosts = 32,
        [int]$MaxTextBytes = 32768,
        [int]$TimeoutSeconds = 2,
        [int]$MaxRedirects = 4,
        [scriptblock]$RequestFactory = $null
    )

    $hosts = [System.Collections.Generic.List[string]]::new()
    $bootstrapHosts = [System.Collections.Generic.List[string]]::new()
    $redirectHosts = [System.Collections.Generic.List[string]]::new()
    $resourceHosts = [System.Collections.Generic.List[string]]::new()
    $truncated = $false
    $currentUrl = $SeedUrl

    for ($attempt = 0; $attempt -le [Math]::Max(0, $MaxRedirects); $attempt++) {
        if ($hosts.Count -ge $MaxHosts) {
            $truncated = $true
            break
        }

        try {
            $uri = [System.Uri]$currentUrl
        }
        catch {
            break
        }
        if ($uri.Scheme -notin @('http', 'https')) { break }

        $seedHost = Normalize-OpenPathCaptivePortalDynamicHost -Value $uri -ProtectedHosts $ProtectedHosts
        $isBootstrapRequest = ($attempt -eq 0)
        if ($seedHost -and -not $hosts.Contains($seedHost)) {
            $hosts.Add($seedHost)
        }
        if ($seedHost -and $isBootstrapRequest -and -not $bootstrapHosts.Contains($seedHost)) {
            $bootstrapHosts.Add($seedHost)
        }
        elseif ($seedHost -and -not $isBootstrapRequest -and -not $redirectHosts.Contains($seedHost)) {
            $redirectHosts.Add($seedHost)
        }

        $response = $null
        try {
            if ($RequestFactory) {
                $response = & $RequestFactory $uri $TimeoutSeconds
            }
            else {
                $request = [System.Net.HttpWebRequest]::Create($uri)
                $request.Method = 'GET'
                $request.AllowAutoRedirect = $false
                $request.Timeout = [Math]::Max(1, $TimeoutSeconds) * 1000
                $request.ReadWriteTimeout = [Math]::Max(1, $TimeoutSeconds) * 1000
                $request.UserAgent = 'OpenPath captive portal recovery'
                $response = $request.GetResponse()
            }
        }
        catch [System.Net.WebException] {
            $response = $_.Exception.Response
            if (-not $response) { break }
        }
        catch {
            break
        }

        try {
            $location = [string]$response.Headers['Location']
            if (-not [string]::IsNullOrWhiteSpace($location)) {
                $redirectUri = Resolve-OpenPathCaptivePortalRedirectUri -BaseUri $uri -Location $location
                if ($redirectUri) {
                    $redirectHost = Normalize-OpenPathCaptivePortalDynamicHost -Value $redirectUri -ProtectedHosts $ProtectedHosts
                    if ($redirectHost -and -not $hosts.Contains($redirectHost)) {
                        $hosts.Add($redirectHost)
                    }
                    if ($redirectHost -and -not $redirectHosts.Contains($redirectHost)) {
                        $redirectHosts.Add($redirectHost)
                    }
                    $currentUrl = $redirectUri.AbsoluteUri
                    continue
                }
            }

            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                try {
                    $buffer = New-Object char[] ([Math]::Max(1, $MaxTextBytes + 1))
                    $read = $reader.ReadBlock($buffer, 0, $buffer.Length)
                    if ($read -gt $MaxTextBytes) {
                        $truncated = $true
                        $read = $MaxTextBytes
                    }
                    if ($read -gt 0) {
                        $body = [string]::new($buffer, 0, $read)
                        foreach ($textHost in @(Extract-OpenPathCaptivePortalHostsFromText -Text $body -ProtectedHosts $ProtectedHosts -MaxHosts ($MaxHosts - $hosts.Count))) {
                            if ($textHost -and -not $hosts.Contains($textHost)) { $hosts.Add($textHost) }
                            if ($textHost -and -not $resourceHosts.Contains($textHost)) { $resourceHosts.Add($textHost) }
                            if ($hosts.Count -ge $MaxHosts) {
                                $truncated = $true
                                break
                            }
                        }
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
        finally {
            $response.Close()
        }
        break
    }

    return [PSCustomObject]@{
        hosts = @($hosts)
        bootstrapHosts = @($bootstrapHosts)
        redirectHosts = @($redirectHosts)
        resourceHosts = @($resourceHosts)
        truncated = [bool]$truncated
    }
}

function Get-OpenPathCaptivePortalRuntimeOverlayHosts {
    # reads the runtime dependency overlay and returns the safe host names it contains
    # returns an empty array when the overlay reader function is not available
    param(
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts = $null
    )

    if (-not (Get-Command -Name 'Read-OpenPathRuntimeDependencyOverlay' -ErrorAction SilentlyContinue)) {
        return @()
    }

    return @(
        foreach ($entry in @(Read-OpenPathRuntimeDependencyOverlay)) {
            foreach ($propertyName in @('DependencyHost', 'dependencyHost', 'Host', 'host')) {
                if (-not $entry.PSObject.Properties[$propertyName]) { continue }
                $hostName = Normalize-OpenPathCaptivePortalDynamicHost -Value $entry.$propertyName -ProtectedHosts $ProtectedHosts
                if ($hostName) { $hostName }
            }
        }
    ) | Select-Object -Unique
}

function Get-OpenPathCaptivePortalDynamicHosts {
    # diagnostic-only discovery entry point; results are retained for operator evidence
    # combines bootstrap discovery, runtime overlay, trigger hosts, and existing hosts
    # the limitedModeReady and fallbackMode fields are fixed at false/none for diagnostic use
    param(
        [string[]]$SeedUrls = @(),
        [string[]]$TriggerHosts = @(),
        [string[]]$ExistingHosts = @(),
        [int]$MaxHosts = 32,
        [int]$MaxTextBytes = 32768,
        [int]$HttpTimeoutSeconds = 2,
        [int]$MaxHttpRedirects = 4,
        [switch]$FetchSeedUrls
    )

    $protectedHosts = $null
    if (Get-Command -Name 'Get-OpenPathRuntimeDependencyProtectedHosts' -ErrorAction SilentlyContinue) {
        $protectedHosts = Get-OpenPathRuntimeDependencyProtectedHosts
    }

    $bootstrapDiscovery = Get-OpenPathCaptivePortalBootstrapHosts `
        -SeedUrls $SeedUrls `
        -ProtectedHosts $protectedHosts `
        -MaxHosts $MaxHosts `
        -MaxTextBytes $MaxTextBytes `
        -HttpTimeoutSeconds $HttpTimeoutSeconds `
        -MaxHttpRedirects $MaxHttpRedirects `
        -FetchSeedUrls:$FetchSeedUrls
    $bootstrapHosts = @($bootstrapDiscovery.bootstrapHosts) | Select-Object -Unique
    $redirectHosts = @($bootstrapDiscovery.redirectHosts) | Select-Object -Unique
    $resourceHosts = @($bootstrapDiscovery.resourceHosts) | Select-Object -Unique
    $discoveredHosts = @($bootstrapHosts) + @($redirectHosts) + @($resourceHosts) | Select-Object -Unique
    $discoveryTruncated = [bool]$bootstrapDiscovery.truncated

    $observedRuntimeHosts = @(Get-OpenPathCaptivePortalRuntimeOverlayHosts -ProtectedHosts $protectedHosts)
    $preRenderHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($TriggerHosts) + @($ExistingHosts) + @($discoveredHosts)))
    $effectiveHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($preRenderHosts) + @($observedRuntimeHosts)))
    $pendingRuntimeHosts = @(
        foreach ($hostName in @($observedRuntimeHosts)) {
            if ($preRenderHosts -notcontains $hostName) { $hostName }
        }
    )

    return [PSCustomObject]@{
        bootstrapHosts = @($bootstrapHosts)
        redirectHosts = @($redirectHosts)
        resourceHosts = @($resourceHosts)
        observedRuntimeHosts = @($observedRuntimeHosts)
        pendingRuntimeHosts = @($pendingRuntimeHosts)
        effectiveHosts = @($effectiveHosts)
        discoveryTruncated = [bool]$discoveryTruncated
        fallbackMode = 'none'
        limitedModeReady = $false
    }
}
