function Test-InstallerDirectDnsServer {
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
    param([Parameter(Mandatory = $true)][string]$Server)
    return $Server -in @('168.63.129.16')
}

function Get-InstallerPrimaryDNS {
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
    if ($gateway -and $gateway -notin @('127.0.0.1', '0.0.0.0') -and $gateway -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
        $preferredCandidates += $gateway
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
