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
        [switch]$AfterAdapterReset
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
        return (New-OpenPathCaptivePortalUpstreamCandidate `
                -Address $adapterDnsCandidates[0] `
                -Source 'active-adapter-dns' `
                -Verified:$false `
                -UsableForLimited:$true)
    }

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
            $verified = Test-DirectDnsServer -Server ([string]$gateway)
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address ([string]$gateway) `
                    -Source 'gateway' `
                    -Verified:$verified `
                    -UsableForLimited:$verified)
        }
    }
    catch {
        # Continue to legacy primary DNS fallback.
    }

    try {
        $primaryDns = [string](Get-PrimaryDNS)
        if ($primaryDns -and $primaryDns -notin @('127.0.0.1', '0.0.0.0')) {
            $isPublicFallback = $primaryDns -in @('8.8.8.8', '1.1.1.1', '9.9.9.9', '8.8.4.4')
            return (New-OpenPathCaptivePortalUpstreamCandidate `
                    -Address $primaryDns `
                    -Source $(if ($isPublicFallback) { 'fallback' } else { 'primary-dns' }) `
                    -Verified:(-not $isPublicFallback) `
                    -UsableForLimited:(-not $isPublicFallback))
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
