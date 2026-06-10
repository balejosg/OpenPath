function Test-DirectDnsServer {
    <#
    .SYNOPSIS
        Checks whether a DNS server can answer direct recursive queries
    .PARAMETER Server
        IPv4 DNS server to probe
    .PARAMETER ProbeDomain
        Public domain used for the probe
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [string]$ProbeDomain = 'google.com'
    )

    if (-not $Server -or $Server -in @('127.0.0.1', '0.0.0.0')) {
        return $false
    }

    if ($Server -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') {
        return $false
    }

    try {
        $result = Resolve-DnsName -Name $ProbeDomain -Server $Server -DnsOnly -ErrorAction Stop
        return ($null -ne $result)
    }
    catch {
        return $false
    }
}

function Test-OpenPathDnsServerForDomains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [string[]]$ProbeDomains = @()
    )

    if (-not $Server -or $Server -in @('127.0.0.1', '0.0.0.0')) {
        return $false
    }

    if ($Server -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') {
        return $false
    }

    foreach ($domain in @($ProbeDomains)) {
        $probeDomain = ([string]$domain).Trim().TrimEnd('.').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($probeDomain)) {
            continue
        }

        try {
            $result = Resolve-DnsName -Name $probeDomain -Server $Server -DnsOnly -ErrorAction Stop
            if ($null -ne $result) {
                return $true
            }
        }
        catch {
            continue
        }
    }

    return $false
}

function Test-DisfavoredDnsServer {
    <#
    .SYNOPSIS
        Flags platform-managed resolvers that should be tried after public fallbacks
    .PARAMETER Server
        IPv4 DNS server candidate
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    return $Server -in @(
        '168.63.129.16'
    )
}

function Get-OpenPathCaptivePortalOriginalDnsCandidates {
    try {
        if ([string]::IsNullOrWhiteSpace([string]$script:OpenPathRoot)) {
            return @()
        }

        $path = "$script:OpenPathRoot\data\original-dns.json"
        if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
            return @()
        }

        $payload = Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $entries = if ($payload.PSObject.Properties['adapters']) { @($payload.adapters) } else { @($payload) }
        return @(
            foreach ($entry in @($entries)) {
                foreach ($server in @($entry.ServerAddresses)) {
                    $candidate = ([string]$server).Trim()
                    if (
                        $candidate -and
                        $candidate -notin @('127.0.0.1', '0.0.0.0') -and
                        $candidate -match '^\d{1,3}(?:\.\d{1,3}){3}$'
                    ) {
                        $candidate
                    }
                }
            }
        ) | Select-Object -Unique
    }
    catch {
        return @()
    }
}

function Get-OpenPathCaptivePortalDhcpServerCandidates {
    try {
        return @(
            foreach ($line in @(ipconfig /all)) {
                if ($line -match '(?i)(?:DHCP Server|Servidor DHCP)[^:]*:\s*(\d{1,3}(?:\.\d{1,3}){3})') {
                    $matches[1]
                }
            }
        ) | Select-Object -Unique
    }
    catch {
        return @()
    }
}

function Get-OpenPathCaptivePortalConfiguredUpstreamCandidates {
    # The configured Acrylic upstream (config primaryDNS/secondaryDNS) is the one
    # address the OpenPath firewall explicitly allows AcrylicService.exe to reach,
    # so it remains a viable limited-mode forwarder even when probe traffic from
    # this PowerShell process is dropped by OpenPath's own anti-bypass DNS rules.
    $candidates = [System.Collections.Generic.List[string]]::new()
    try {
        if (-not (Test-Path $script:ConfigPath -ErrorAction SilentlyContinue)) {
            return @()
        }
        $config = Get-OpenPathConfig
        foreach ($name in @('primaryDNS', 'secondaryDNS')) {
            if (-not ($config -and $config.PSObject.Properties[$name] -and $config.$name)) { continue }
            $address = ([string]$config.$name).Trim()
            if ($address -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { continue }
            if ($address -in @('127.0.0.1', '0.0.0.0')) { continue }
            if (-not $candidates.Contains($address)) { $candidates.Add($address) }
        }
    }
    catch {
        return @()
    }
    return $candidates.ToArray()
}

function Get-OpenPathCaptivePortalDhcpNameServerCandidates {
    # The DHCP-offered DNS servers are preserved by Windows in the registry
    # (DhcpNameServer) even after OpenPath pins the adapter DNS to 127.0.0.1.
    # This is the authoritative source of the network's real resolver -- the only
    # one that knows internal captive-portal hostnames -- so it must be consulted
    # before the (overwritten) adapter DNS or the poisoned original-dns snapshot.
    try {
        $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        if (-not (Test-Path $root -ErrorAction SilentlyContinue)) {
            return @()
        }

        return @(
            foreach ($iface in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -Path $iface.PSPath -ErrorAction SilentlyContinue
                $value = [string]$props.DhcpNameServer
                if ([string]::IsNullOrWhiteSpace($value)) { continue }
                foreach ($server in @($value -split '[,\s]+')) {
                    $candidate = ([string]$server).Trim()
                    if (
                        $candidate -and
                        $candidate -notin @('127.0.0.1', '0.0.0.0') -and
                        $candidate -match '^\d{1,3}(?:\.\d{1,3}){3}$'
                    ) {
                        $candidate
                    }
                }
            }
        ) | Select-Object -Unique
    }
    catch {
        return @()
    }
}

function Get-PrimaryDNS {
    <#
    .SYNOPSIS
        Detects the primary DNS server from active network adapters
    .OUTPUTS
        String with the primary DNS IP address
    #>
    $preferredCandidates = @(
        Get-DnsClientServerAddress -AddressFamily IPv4 |
            ForEach-Object { @($_.ServerAddresses) } |
            Where-Object {
                $_ -and
                $_ -notin @('127.0.0.1', '0.0.0.0') -and
                $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$'
            }
    )

    $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).NextHop
    if (
        $gateway -and
        $gateway -notin @('127.0.0.1', '0.0.0.0') -and
        $gateway -match '^\d{1,3}(?:\.\d{1,3}){3}$'
    ) {
        $preferredCandidates += $gateway
    }

    $preferredCandidates = @($preferredCandidates | Select-Object -Unique)
    $disfavoredCandidates = @(
        $preferredCandidates | Where-Object { Test-DisfavoredDnsServer -Server $_ }
    )
    $preferredCandidates = @(
        $preferredCandidates | Where-Object { -not (Test-DisfavoredDnsServer -Server $_) }
    )
    $fallbackCandidates = @('8.8.8.8', '1.1.1.1', '9.9.9.9', '8.8.4.4')

    foreach ($candidate in (@($preferredCandidates) + @($fallbackCandidates) + @($disfavoredCandidates))) {
        if (Test-DirectDnsServer -Server $candidate) {
            return $candidate
        }
    }

    if ($preferredCandidates.Count -gt 0) {
        return $preferredCandidates[0]
    }

    if ($disfavoredCandidates.Count -gt 0) {
        return $disfavoredCandidates[0]
    }

    return '8.8.8.8'
}

function Get-OpenPathCaptivePortalUpstreamDns {
    <#
    .SYNOPSIS
        Selects a DNS upstream candidate after captive portal DNS reset.
    .OUTPUTS
        Object with Address, Source, Verified, UsableForLimited, and PreReset.
    #>
    [CmdletBinding()]
    param(
        [switch]$AfterAdapterReset,
        [string[]]$ProbeDomains = @()
    )

    function New-OpenPathCaptivePortalUpstreamCandidate {
        param(
            [string]$Address,
            [string]$Source,
            [bool]$Verified = $false,
            [bool]$UsableForLimited = $false
        )

        return [PSCustomObject]@{
            Address = [string]$Address
            Source = [string]$Source
            Verified = [bool]$Verified
            UsableForLimited = [bool]$UsableForLimited
            PreReset = (-not [bool]$AfterAdapterReset)
        }
    }

    $limitedProbeDomains = @(
        @($ProbeDomains) |
            ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    function Test-OpenPathCaptivePortalLimitedUpstream {
        param([Parameter(Mandatory = $true)][string]$Address)

        if ($limitedProbeDomains.Count -le 0) {
            return $true
        }

        return [bool](Test-OpenPathDnsServerForDomains -Server $Address -ProbeDomains $limitedProbeDomains)
    }

    # Highest-priority source: the DHCP-offered DNS preserved in the registry.
    # It survives the static 127.0.0.1 override and is the only resolver that knows
    # internal captive-portal hostnames. Only returned when it actually resolves the
    # declared portal probe domains, so it never weakens normal selection.
    foreach ($candidate in @(Get-OpenPathCaptivePortalDhcpNameServerCandidates)) {
        if (Test-OpenPathCaptivePortalLimitedUpstream -Address ([string]$candidate)) {
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$candidate) `
                    -Source 'dhcp-nameserver' `
                    -Verified:($limitedProbeDomains.Count -gt 0) `
                    -UsableForLimited:$true)
        }
    }

    $adapterDnsCandidates = @()
    try {
        $activeInterfaceIndexes = @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' } |
                ForEach-Object {
                    if ($_.PSObject.Properties['ifIndex']) { [int]$_.ifIndex }
                    elseif ($_.PSObject.Properties['InterfaceIndex']) { [int]$_.InterfaceIndex }
                } |
                Where-Object { $null -ne $_ }
        )

        $adapterDnsCandidates = @(
            Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $activeInterfaceIndexes.Count -eq 0 -or $activeInterfaceIndexes -contains [int]$_.InterfaceIndex
                } |
                ForEach-Object { @($_.ServerAddresses) } |
                Where-Object {
                    $_ -and
                    $_ -notin @('127.0.0.1', '0.0.0.0') -and
                    $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$'
                } |
                Select-Object -Unique
        )
    }
    catch {
        $adapterDnsCandidates = @()
    }

    if ($adapterDnsCandidates.Count -gt 0) {
        foreach ($candidate in @($adapterDnsCandidates)) {
            $usableForLimited = Test-OpenPathCaptivePortalLimitedUpstream -Address ([string]$candidate)
            if ($usableForLimited) {
                return (New-OpenPathCaptivePortalUpstreamCandidate `
                        -Address ([string]$candidate) `
                        -Source 'active-adapter-dns' `
                        -Verified:($limitedProbeDomains.Count -gt 0) `
                        -UsableForLimited:$true)
            }
        }

        if ($limitedProbeDomains.Count -le 0) {
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address $adapterDnsCandidates[0] `
                    -Source 'active-adapter-dns' `
                    -Verified:$false `
                    -UsableForLimited:$true)
        }
    }

    foreach ($candidate in @(Get-OpenPathCaptivePortalOriginalDnsCandidates)) {
        $usableForLimited = Test-OpenPathCaptivePortalLimitedUpstream -Address ([string]$candidate)
        if ($usableForLimited) {
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$candidate) `
                    -Source 'original-dns' `
                    -Verified:($limitedProbeDomains.Count -gt 0) `
                    -UsableForLimited:$true)
        }

        if ($limitedProbeDomains.Count -le 0) {
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$candidate) `
                    -Source 'original-dns' `
                    -Verified:$false `
                    -UsableForLimited:$true)
        }
    }

    foreach ($candidate in @(Get-OpenPathCaptivePortalDhcpServerCandidates)) {
        $usableForLimited = Test-OpenPathCaptivePortalLimitedUpstream -Address ([string]$candidate)
        if ($usableForLimited) {
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$candidate) `
                    -Source 'dhcp-server' `
                    -Verified:($limitedProbeDomains.Count -gt 0) `
                    -UsableForLimited:$true)
        }

        if ($limitedProbeDomains.Count -le 0) {
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$candidate) `
                    -Source 'dhcp-server' `
                    -Verified:$false `
                    -UsableForLimited:$true)
        }
    }

    $deferredGatewayCandidate = $null
    try {
        $gateway = (
            Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.NextHop -and
                    [string]$_.NextHop -ne '0.0.0.0' -and
                    -not ([string]$_.NextHop).StartsWith('127.') -and
                    [string]$_.NextHop -match '^\d{1,3}(?:\.\d{1,3}){3}$'
                } |
                Select-Object -First 1
        ).NextHop
        if ($gateway) {
            if ($limitedProbeDomains.Count -gt 0) {
                $portalVerified = Test-OpenPathCaptivePortalLimitedUpstream -Address ([string]$gateway)
                if ($portalVerified) {
                    return (New-OpenPathCaptivePortalUpstreamCandidate `
                            -Address ([string]$gateway) `
                            -Source 'gateway' `
                            -Verified:$true `
                            -UsableForLimited:$true)
                }
            }

            $verified = Test-DirectDnsServer -Server ([string]$gateway)
            $gatewayCandidate = (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$gateway) `
                    -Source 'gateway' `
                    -Verified:$verified `
                    -UsableForLimited:($limitedProbeDomains.Count -le 0))
            if ($gatewayCandidate.UsableForLimited) {
                return $gatewayCandidate
            }
            # A gateway that cannot resolve the declared portal domains is only a
            # diagnostic candidate; defer it so the configured upstream below can
            # still provide a usable limited-mode forwarder.
            $deferredGatewayCandidate = $gatewayCandidate
        }
    }
    catch {
        # Continue to legacy primary DNS fallback.
    }

    if ($limitedProbeDomains.Count -gt 0) {
        $configuredUpstreams = @(Get-OpenPathCaptivePortalConfiguredUpstreamCandidates)
        foreach ($candidate in $configuredUpstreams) {
            if (Test-OpenPathCaptivePortalLimitedUpstream -Address ([string]$candidate)) {
                return (New-OpenPathCaptivePortalUpstreamCandidate `
                        -Address ([string]$candidate) `
                        -Source 'configured-upstream' `
                        -Verified:$true `
                        -UsableForLimited:$true)
            }
        }
        if ($configuredUpstreams.Count -gt 0) {
            # A failed probe of the configured upstream is a false negative: OpenPath's
            # own anti-bypass firewall drops resolver traffic from this PowerShell
            # process, while AcrylicService.exe holds an explicit allow to this address.
            # Treat it as usable; limited mode stays fail-closed (adapter on 127.0.0.1,
            # NX *, TTL-bounded) if the upstream turns out not to resolve the portal.
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$configuredUpstreams[0]) `
                    -Source 'configured-upstream' `
                    -Verified:$false `
                    -UsableForLimited:$true)
        }
    }

    if ($deferredGatewayCandidate) {
        return $deferredGatewayCandidate
    }

    try {
        $primaryDns = [string](Get-PrimaryDNS)
        if ($primaryDns -and $primaryDns -notin @('127.0.0.1', '0.0.0.0')) {
            $isPublicFallback = $primaryDns -in @('8.8.8.8', '1.1.1.1', '9.9.9.9', '8.8.4.4')
            if ($limitedProbeDomains.Count -gt 0) {
                $portalVerified = Test-OpenPathCaptivePortalLimitedUpstream -Address $primaryDns
                if ($portalVerified) {
                    return (New-OpenPathCaptivePortalUpstreamCandidate `
                            -Address $primaryDns `
                            -Source $(if ($isPublicFallback) { 'fallback' } else { 'primary-dns' }) `
                            -Verified:$true `
                            -UsableForLimited:$true)
                }
            }

            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address $primaryDns `
                    -Source $(if ($isPublicFallback) { 'fallback' } else { 'primary-dns' }) `
                    -Verified:(-not $isPublicFallback) `
                    -UsableForLimited:(($limitedProbeDomains.Count -le 0) -and (-not $isPublicFallback)))
        }
    }
    catch {
        # Fall through to diagnostic fallback.
    }

    return (New-OpenPathCaptivePortalUpstreamCandidate `
            -Address '8.8.8.8' `
            -Source 'fallback' `
            -Verified:$false `
            -UsableForLimited:$false)
}
