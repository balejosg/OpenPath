function Get-HostFromUrl {
    <#
    .SYNOPSIS
        Returns host component from a URL string
    #>
    param(
        [string]$Url
    )

    if (-not $Url) {
        return $null
    }

    try {
        return ([System.Uri]$Url).Host
    }
    catch {
        return $null
    }
}

function Normalize-OpenPathAlwaysAllowedDomain {
    <#
    .SYNOPSIS
        Normalizes static always-allowed domain entries to root host form
    #>
    param(
        [AllowNull()][string]$Domain
    )

    if (-not $Domain) {
        return $null
    }

    $normalizedDomain = $Domain.Trim().Trim('.').ToLowerInvariant()
    if ($normalizedDomain.StartsWith('*.')) {
        $normalizedDomain = $normalizedDomain.Substring(2)
    }

    if ($normalizedDomain -and (Test-OpenPathDomainFormat -Domain $normalizedDomain)) {
        return $normalizedDomain
    }

    return $null
}

function Get-OpenPathProtectedDomains {
    <#
    .SYNOPSIS
        Returns OpenPath control-plane and bootstrap/download domains that must never be blocked
    #>
    $domains = [System.Collections.Generic.List[string]]::new()
    $seenDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($domain in @(
            'raw.githubusercontent.com',
            'github.com',
            'githubusercontent.com',
            'api.github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
            'sourceforge.net',
            'downloads.sourceforge.net'
        )) {
        if ($domain -and $seenDomains.Add($domain)) {
            $domains.Add($domain) | Out-Null
        }
    }

    try {
        $config = Get-OpenPathConfig
        foreach ($urlProperty in @('whitelistUrl', 'apiUrl')) {
            if (-not $config.PSObject.Properties[$urlProperty]) {
                continue
            }

            $host = Get-HostFromUrl -Url ([string]$config.$urlProperty)
            if (-not $host) {
                continue
            }

            $normalizedHost = $host.Trim().Trim('.')
            if ($normalizedHost -and (Test-OpenPathDomainFormat -Domain $normalizedHost) -and $seenDomains.Add($normalizedHost)) {
                $domains.Add($normalizedHost) | Out-Null
            }
        }
    }
    catch {
        Write-Debug "Protected domains unavailable from config: $_"
    }

    return @($domains)
}

function Get-OpenPathMicrosoftSystemDomains {
    <#
    .SYNOPSIS
        Returns Microsoft system, component update, identity, and CDN roots that must stay reachable
    #>
    return @(
        '*.windowsupdate.com',
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
        'msftconnecttest.com',
        'www.msftconnecttest.com',
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
        'blob.core.windows.net'
    )
}

function Get-OpenPathFirefoxSystemDomains {
    <#
    .SYNOPSIS
        Returns Firefox update, security, extension, and component service roots that must stay reachable
    #>
    return @(
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
}

function Get-OpenPathAlwaysAllowedDomainGroups {
    <#
    .SYNOPSIS
        Returns grouped Windows domains that are always rendered before the default DNS block
    #>
    return @(
        [PSCustomObject]@{ Comment = '# Control plane and bootstrap/download'; Domains = @(Get-OpenPathProtectedDomains) },
        [PSCustomObject]@{ Comment = '# Captive portal detection'; Domains = @('detectportal.firefox.com', 'connectivity-check.ubuntu.com', 'captive.apple.com', 'www.msftconnecttest.com', 'msftconnecttest.com', 'clients3.google.com') },
        [PSCustomObject]@{ Comment = '# Microsoft system and component updates'; Domains = @(Get-OpenPathMicrosoftSystemDomains) },
        [PSCustomObject]@{ Comment = '# Firefox system and component updates'; Domains = @(Get-OpenPathFirefoxSystemDomains) },
        [PSCustomObject]@{ Comment = '# NTP'; Domains = @('time.windows.com', 'time.google.com') }
    )
}

function Get-OpenPathAlwaysAllowedDomains {
    <#
    .SYNOPSIS
        Returns normalized, de-duplicated always-allowed domain roots
    #>
    $domains = [System.Collections.Generic.List[string]]::new()
    $seenDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($group in @(Get-OpenPathAlwaysAllowedDomainGroups)) {
        foreach ($domain in @($group.Domains)) {
            $normalizedDomain = Normalize-OpenPathAlwaysAllowedDomain -Domain $domain
            if ($normalizedDomain -and $seenDomains.Add($normalizedDomain)) {
                $domains.Add($normalizedDomain) | Out-Null
            }
        }
    }

    return @($domains)
}

function Get-OpenPathHostFromBlockedPathRule {
    <#
    .SYNOPSIS
        Extracts the host portion from a blocked path rule when one is present
    #>
    param(
        [string]$Rule
    )

    if (-not $Rule) {
        return $null
    }

    $candidate = $Rule.Trim()
    if (-not $candidate) {
        return $null
    }

    $candidate = $candidate -replace '^\*://', ''
    $candidate = $candidate -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $candidate = $candidate.TrimStart('*').TrimStart('.')

    if (-not $candidate -or $candidate.StartsWith('/')) {
        return $null
    }

    $host = ($candidate -split '[/?#]')[0]
    $host = ($host -split ':')[0]
    $host = $host.Trim().Trim('*').Trim('.')

    if (-not $host) {
        return $null
    }

    if (Test-OpenPathDomainFormat -Domain $host) {
        return $host
    }

    return $null
}

function Test-OpenPathDomainFormat {
    <#
    .SYNOPSIS
        Validates a domain using OpenPath's shared allowlist domain format
    #>
    param(
        [string]$Domain
    )

    if (-not $Domain) {
        return $false
    }

    $trimmedDomain = $Domain.Trim()

    if ($trimmedDomain.Length -lt 4 -or $trimmedDomain.Length -gt 253) {
        return $false
    }

    if ($trimmedDomain.EndsWith('.local', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return ($trimmedDomain -match $script:DomainPattern)
}

function Get-OpenPathRuntimeHealth {
    <#
    .SYNOPSIS
        Returns current DNS runtime health status
    .OUTPUTS
        PSCustomObject with DnsServiceRunning and DnsResolving booleans
    #>
    $acrylicRunning = $false
    $dnsResolving = $false

    try {
        $acrylicService = Get-Service -DisplayName "*Acrylic*" -ErrorAction SilentlyContinue | Select-Object -First 1
        $acrylicRunning = [bool]($acrylicService -and $acrylicService.Status -eq 'Running')
    }
    catch {
        $acrylicRunning = $false
    }

    if (Get-Command -Name 'Test-DNSResolution' -ErrorAction SilentlyContinue) {
        try {
            $dnsResolving = [bool](Test-DNSResolution)
        }
        catch {
            $dnsResolving = $false
        }
    }

    return [PSCustomObject]@{
        DnsServiceRunning = [bool]$acrylicRunning
        DnsResolving = [bool]$dnsResolving
    }
}

function Restore-OpenPathProtectedMode {
    <#
    .SYNOPSIS
        Restores protected DNS enforcement using the currently loaded OpenPath modules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$Config = $null,

        [switch]$SkipAcrylicRestart
    )

    if (-not $PSCmdlet.ShouldProcess('OpenPath', 'Restore protected DNS enforcement')) {
        return $false
    }

    if (-not $SkipAcrylicRestart -and (Get-Command -Name 'Restart-AcrylicService' -ErrorAction SilentlyContinue)) {
        Restart-AcrylicService | Out-Null
    }

    if (Get-Command -Name 'Set-LocalDNS' -ErrorAction SilentlyContinue) {
        Set-LocalDNS
    }

    $enableFirewall = $true
    if ($Config -and $Config.PSObject.Properties['enableFirewall']) {
        $enableFirewall = [bool]$Config.enableFirewall
    }

    if (-not $enableFirewall) {
        return $true
    }

    $upstream = '8.8.8.8'
    if ($Config -and $Config.PSObject.Properties['primaryDNS'] -and $Config.primaryDNS) {
        $upstream = [string]$Config.primaryDNS
    }

    if ((Get-Command -Name 'Set-OpenPathFirewall' -ErrorAction SilentlyContinue) -and
        (Get-Command -Name 'Get-AcrylicPath' -ErrorAction SilentlyContinue)) {
        $acrylicPath = Get-AcrylicPath
        if ($acrylicPath) {
            Set-OpenPathFirewall -UpstreamDNS $upstream -AcrylicPath $acrylicPath | Out-Null
            return $true
        }
    }

    if (Get-Command -Name 'Enable-OpenPathFirewall' -ErrorAction SilentlyContinue) {
        Enable-OpenPathFirewall | Out-Null
    }

    return $true
}

function Get-OpenPathDnsProbeDomains {
    <#
    .SYNOPSIS
        Returns candidate domains for DNS health probes based on the effective allowlist
    #>
    $domains = [System.Collections.Generic.List[string]]::new()
    $seenDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $whitelistPath = Join-Path $script:OpenPathRoot 'data\whitelist.txt'

    try {
        foreach ($domain in @(Get-ValidWhitelistDomainsFromFile -Path $whitelistPath)) {
            $normalizedDomain = ([string]$domain).Trim().Trim('.')
            if ($normalizedDomain -and (Test-OpenPathDomainFormat -Domain $normalizedDomain) -and $seenDomains.Add($normalizedDomain)) {
                $domains.Add($normalizedDomain) | Out-Null
            }
        }
    }
    catch {
        Write-Debug "DNS probe domains unavailable from whitelist: $_"
    }

    foreach ($domain in @(Get-OpenPathProtectedDomains)) {
        $normalizedDomain = ([string]$domain).Trim().Trim('.')
        if ($normalizedDomain -and (Test-OpenPathDomainFormat -Domain $normalizedDomain) -and $seenDomains.Add($normalizedDomain)) {
            $domains.Add($normalizedDomain) | Out-Null
        }
    }

    return @($domains)
}
