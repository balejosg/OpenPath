function Test-InstallerDirectDnsServer {
    # returns $true if server is a reachable ipv4 dns server that can resolve probedomain;
    # loopback and all-zeros addresses always return $false.
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [string]$ProbeDomain = 'google.com'
    )

    if (-not $Server -or $Server -in @('127.0.0.1', '0.0.0.0')) { return $false }
    if ($Server -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { return $false }

    try {
        $result = Resolve-DnsName -Name $ProbeDomain -Server $Server -DnsOnly -ErrorAction Stop
        return ($null -ne $result)
    }
    catch {
        return $false
    }
}

function Test-InstallerDisfavoredDnsServer {
    # returns $true for known problematic dns servers (e.g. azure wire server 168.63.129.16)
    # that should be used only as last resort.
    param([Parameter(Mandatory = $true)][string]$Server)
    return $Server -in @('168.63.129.16')
}

function Get-InstallerPrimaryDNS {
    # selects the best available upstream dns server from adapter addresses, default gateway,
    # and well-known fallbacks; disfavored servers (azure wire) are tried last.
    $preferredCandidates = @()
    if (Get-Command -Name 'Get-DnsClientServerAddress' -ErrorAction SilentlyContinue) {
        $preferredCandidates += @(
            Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                ForEach-Object { @($_.ServerAddresses) } |
                Where-Object {
                    $_ -and
                    $_ -notin @('127.0.0.1', '0.0.0.0') -and
                    $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$'
                }
        )
    }

    if (Get-Command -Name 'Get-NetRoute' -ErrorAction SilentlyContinue) {
        $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        if ($gateway -and $gateway -notin @('127.0.0.1', '0.0.0.0') -and $gateway -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
            $preferredCandidates += $gateway
        }
    }

    $preferredCandidates = @($preferredCandidates | Select-Object -Unique)
    $disfavoredCandidates = @($preferredCandidates | Where-Object { Test-InstallerDisfavoredDnsServer -Server $_ })
    $preferredCandidates = @($preferredCandidates | Where-Object { -not (Test-InstallerDisfavoredDnsServer -Server $_) })
    $fallbackCandidates = @('8.8.8.8', '1.1.1.1', '9.9.9.9', '8.8.4.4')

    foreach ($candidate in (@($preferredCandidates) + @($fallbackCandidates) + @($disfavoredCandidates))) {
        if (Test-InstallerDirectDnsServer -Server $candidate) {
            return $candidate
        }
    }

    if ($preferredCandidates.Count -gt 0) { return $preferredCandidates[0] }
    if ($disfavoredCandidates.Count -gt 0) { return $disfavoredCandidates[0] }
    return '8.8.8.8'
}

function Ensure-InstallerRemoteBootstrapDns {
    # if the api host cannot be resolved via default dns, temporarily sets all adapters
    # to primarydns and retries; throws if resolution still fails after the override.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ApiBaseUrl = '',
        [string]$PrimaryDNS = ''
    )

    if (-not $ApiBaseUrl) { return $true }

    try {
        $hostname = ([Uri]$ApiBaseUrl).Host
    }
    catch {
        return $true
    }

    if (-not $hostname -or $hostname -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
        return $true
    }

    try {
        Resolve-DnsName -Name $hostname -Type A -QuickTimeout -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        if (-not $PrimaryDNS) { throw }
    }

    $networkAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    Save-OpenPathInstallerOriginalDnsSnapshot -OpenPathRoot 'C:\OpenPath' | Out-Null
    foreach ($adapter in $networkAdapters) {
        if ($PSCmdlet.ShouldProcess("network adapter $($adapter.ifIndex)", "Set bootstrap DNS server $PrimaryDNS")) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($PrimaryDNS) -ErrorAction SilentlyContinue
        }
    }

    if ($WhatIfPreference) {
        return $true
    }

    try {
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Resolve-DnsName -Name $hostname -Type A -QuickTimeout -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        throw "Unable to resolve $hostname before remote enrollment after setting DNS server $PrimaryDNS"
    }
}

function Get-OpenPathInstallerOriginalDnsSnapshotPath {
    # returns the full path to the original-dns.json snapshot file under data\.
    param([Parameter(Mandatory = $true)][string]$OpenPathRoot)
    return "$($OpenPathRoot.TrimEnd('\'))\data\original-dns.json"
}

function ConvertFrom-OpenPathInstallerDnsNameServerValue {
    # splits a registry NameServer or DhcpNameServer value into individual address strings.
    param([object]$Value)

    return @(
        foreach ($part in ([string]$Value -split '[,\s]+')) {
            $address = ([string]$part).Trim()
            if ($address) { $address }
        }
    )
}

function Get-OpenPathInstallerDnsInterfaceRegistryState {
    # reads the static and dhcp dns registry values for one adapter interface; an unreadable
    # key returns Readable = false so the caller can use the connectivity-safe dhcp direction.
    param([string]$InterfaceGuid)

    $state = [PSCustomObject]@{
        Readable = $false
        EnableDhcp = $false
        NameServer = @()
        DhcpNameServer = @()
    }
    if ([string]::IsNullOrWhiteSpace($InterfaceGuid)) { return $state }

    try {
        $interfaceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$InterfaceGuid"
        $properties = Get-ItemProperty -Path $interfaceKey -ErrorAction Stop
        $state.Readable = $true
        $state.NameServer = @(ConvertFrom-OpenPathInstallerDnsNameServerValue -Value $properties.NameServer)
        $state.DhcpNameServer = @(ConvertFrom-OpenPathInstallerDnsNameServerValue -Value $properties.DhcpNameServer)
        if ($null -ne $properties.EnableDHCP) {
            $state.EnableDhcp = ([int]$properties.EnableDHCP -ne 0)
        }
    }
    catch {
    }

    return $state
}

function Test-OpenPathInstallerDnsLoopbackAddress {
    # returns true for resolver addresses that point at the local machine instead of a real dns server.
    param([object]$Address)

    $text = ([string]$Address).Trim()
    return ($text -eq '::1' -or $text -eq '0.0.0.0' -or $text -match '^127\.')
}

function Save-OpenPathInstallerOriginalDnsSnapshot {
    # captures current per-adapter ipv4 dns addresses and origin to original-dns.json; skips
    # silently if the snapshot already exists or the required net cmdlets are unavailable.
    param([Parameter(Mandatory = $true)][string]$OpenPathRoot)

    $snapshotPath = Get-OpenPathInstallerOriginalDnsSnapshotPath -OpenPathRoot $OpenPathRoot
    if (Test-Path $snapshotPath) { return $true }
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Get-Command -Name Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return $false }

    $snapshot = @(
        Get-NetAdapter -ErrorAction Stop | ForEach-Object {
            $adapter = $_
            $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $registryState = Get-OpenPathInstallerDnsInterfaceRegistryState -InterfaceGuid ([string]$adapter.InterfaceGuid)
            $nameServers = @($registryState.NameServer | Where-Object {
                    $_ -and -not (Test-OpenPathInstallerDnsLoopbackAddress -Address $_)
                })
            $dhcpNameServers = @($registryState.DhcpNameServer | Where-Object {
                    $_ -and -not (Test-OpenPathInstallerDnsLoopbackAddress -Address $_)
                })
            $effectiveServers = @($dns.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object {
                    $_ -and -not (Test-OpenPathInstallerDnsLoopbackAddress -Address $_)
                })
            $origin = if ($nameServers.Count -gt 0) { 'static' } else { 'dhcp' }
            $serverAddresses = if ($origin -eq 'static') {
                @($nameServers)
            }
            elseif ($dhcpNameServers.Count -gt 0) {
                @($dhcpNameServers)
            }
            else {
                @($effectiveServers)
            }

            [PSCustomObject]@{
                InterfaceGuid = [string]$adapter.InterfaceGuid
                InterfaceAlias = [string]$adapter.Name
                InterfaceIndex = [int]$adapter.ifIndex
                Origin = [string]$origin
                ServerAddresses = @($serverAddresses)
            }
        }
    )

    $payload = [PSCustomObject]@{
        version = 3
        adapters = @($snapshot)
    }

    $snapshotDirectory = Split-Path $snapshotPath -Parent
    if (-not (Test-Path $snapshotDirectory)) {
        New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $snapshotPath -Encoding UTF8
    return $true
}
