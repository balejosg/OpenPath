# Adapter DNS snapshot and restore: the single owner of the rule that decides how
# each network adapter gets its original DNS back once OpenPath's local resolver
# pin is removed. Dependency-free leaf: it calls no OpenPath function it does not
# define and never logs. Expected failures are returned to the caller, which
# chooses an error policy and writes its own messages. Dot-sourced by DNS.psm1,
# the installer helpers and the standalone uninstaller.

function Select-OpenPathDnsScalarValue {
    <#
    .SYNOPSIS
    Returns the first non-null item from a value that may be an array or a scalar.
    #>
    param([object]$Value)

    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            return $item
        }
    }

    return $null
}

function ConvertTo-OpenPathDnsNullableInt {
    <#
    .SYNOPSIS
    Converts a DNS adapter value to an integer, returning null when the value is absent or unparseable.
    #>
    param([object]$Value)

    $scalarValue = Select-OpenPathDnsScalarValue -Value $Value
    if ($null -eq $scalarValue) { return $null }

    $stringValue = [string]$scalarValue
    if ([string]::IsNullOrWhiteSpace($stringValue)) { return $null }

    try {
        return [int]$stringValue
    }
    catch {
        return $null
    }
}

function Get-OpenPathDnsNetworkFingerprint {
    <#
    .SYNOPSIS
    Builds a stable string fingerprint from adapter identity and gateway fields for snapshot change detection.
    #>
    param([object[]]$Entries = @())

    $parts = @(
        foreach ($entry in @($Entries)) {
            $gateway = if ($entry.PSObject.Properties['Gateway']) { [string]$entry.Gateway } else { '' }
            @(
                [string]$entry.InterfaceGuid,
                [string]$entry.InterfaceAlias,
                [string]$entry.InterfaceIndex,
                [string]$gateway
            ) -join '|'
        }
    ) | Sort-Object

    return ($parts -join ';')
}

function ConvertFrom-OpenPathDnsNameServerValue {
    <#
    .SYNOPSIS
    Splits a registry NameServer or DhcpNameServer value into individual address strings.
    #>
    param([object]$Value)

    return @(
        foreach ($part in ([string]$Value -split '[,\s]+')) {
            $address = ([string]$part).Trim()
            if ($address) { $address }
        }
    )
}

function Get-OpenPathDnsInterfaceRegistryState {
    <#
    .SYNOPSIS
    Reads the static and DHCP DNS registry values for one adapter interface.
    .DESCRIPTION
    NameServer is the manual DNS value and is empty when DNS comes from DHCP. DhcpNameServer is
    what DHCP offered. EnableDHCP tells whether the adapter currently uses DHCP. An unreadable
    key returns Readable = false so callers can use the connectivity-safe DHCP direction.
    #>
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
        $state.NameServer = @(ConvertFrom-OpenPathDnsNameServerValue -Value $properties.NameServer)
        $state.DhcpNameServer = @(ConvertFrom-OpenPathDnsNameServerValue -Value $properties.DhcpNameServer)
        if ($null -ne $properties.EnableDHCP) {
            $state.EnableDhcp = ([int]$properties.EnableDHCP -ne 0)
        }
    }
    catch {
        # A missing or unreadable key is treated as DHCP origin by the caller.
    }

    return $state
}

function Get-OpenPathCurrentDnsSnapshotEntries {
    <#
    .SYNOPSIS
    Reads the current adapter list and returns a snapshot object per active adapter including its IPv4 DNS, gateway, and origin.
    #>
    if (-not (Get-Command -Name Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return @() }
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return @() }

    return @(
        Get-NetAdapter -ErrorAction Stop | ForEach-Object {
            $adapter = $_
            $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $gateway = ''
            try {
                $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($route -and $route.NextHop) { $gateway = [string]$route.NextHop }
            }
            catch {
                $gateway = ''
            }

            $registryState = Get-OpenPathDnsInterfaceRegistryState -InterfaceGuid ([string]$adapter.InterfaceGuid)
            $nameServers = @($registryState.NameServer | Where-Object {
                    $_ -and -not (Test-OpenPathDnsLoopbackAddress -Address $_)
                })
            $dhcpNameServers = @($registryState.DhcpNameServer | Where-Object {
                    $_ -and -not (Test-OpenPathDnsLoopbackAddress -Address $_)
                })
            $effectiveServers = @($dns.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object {
                    $_ -and -not (Test-OpenPathDnsLoopbackAddress -Address $_)
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
                Gateway = [string]$gateway
                Origin = [string]$origin
                ServerAddresses = @($serverAddresses)
            }
        }
    )
}

function Test-OpenPathDnsLoopbackAddress {
    <#
    .SYNOPSIS
    Returns true for resolver addresses that point at the local machine instead of a real DNS server.
    .DESCRIPTION
    OpenPath pins adapters to 127.0.0.1 while Acrylic owns the local resolver. A loopback
    address captured in the original snapshot is therefore OpenPath's own pin, not a user
    setting, and must never be restored after the proxy is gone.
    #>
    param([object]$Address)

    $text = ([string]$Address).Trim()
    return ($text -eq '::1' -or $text -eq '0.0.0.0' -or $text -match '^127\.')
}

function Test-OpenPathDnsLegacyDhcpOrigin {
    <#
    .SYNOPSIS
    Returns true when a live adapter still uses DHCP and has a DHCP-offered DNS server.
    .DESCRIPTION
    Legacy snapshots have no origin field. Resetting them to DHCP is the connectivity-safe rule
    whenever the adapter is still DHCP-backed with a real DHCP DNS value.
    #>
    param([object]$Adapter)

    $registryState = Get-OpenPathDnsInterfaceRegistryState -InterfaceGuid ([string]$Adapter.InterfaceGuid)
    return [bool]($registryState.Readable -and $registryState.EnableDhcp -and @($registryState.DhcpNameServer).Count -gt 0)
}

function New-OpenPathOriginalDnsSnapshot {
    <#
    .SYNOPSIS
    Builds the version 3 original DNS snapshot payload (networkFingerprint plus one entry per adapter).
    .DESCRIPTION
    Returns null when Get-NetAdapter or Get-DnsClientServerAddress is unavailable on this platform.
    The caller decides where and how the payload is written.
    #>
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Get-Command -Name Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return $null }

    $snapshot = @(Get-OpenPathCurrentDnsSnapshotEntries)
    $networkFingerprint = Get-OpenPathDnsNetworkFingerprint -Entries $snapshot
    return [PSCustomObject]@{
        version = 3
        networkFingerprint = [string]$networkFingerprint
        adapters = @($snapshot)
    }
}

function Get-OpenPathOriginalDnsRestorePlan {
    <#
    .SYNOPSIS
    Decides, per snapshot entry, which live adapter it belongs to and whether to set its servers or reset it to DHCP.
    .DESCRIPTION
    Matches adapters by GUID first, then by index, then by alias. Loopback addresses are
    OpenPath's own pin and are dropped. A static origin with servers is set; any other origin
    is reset to DHCP. Legacy entries (no Origin) are reset when the live adapter is DHCP-backed,
    or when no real server remains. Entries without a matching adapter produce no plan entry.
    #>
    param(
        [object[]]$SnapshotEntries = @(),
        [object[]]$Adapters = @()
    )

    $adapters = @($Adapters)
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($SnapshotEntries)) {
        if ($null -eq $entry) { continue }

        $adapter = $adapters | Where-Object { [string]$_.InterfaceGuid -eq [string]$entry.InterfaceGuid } | Select-Object -First 1
        $entryInterfaceIndex = ConvertTo-OpenPathDnsNullableInt -Value $entry.InterfaceIndex
        if (-not $adapter -and $null -ne $entryInterfaceIndex) {
            $adapter = $adapters | Where-Object {
                (ConvertTo-OpenPathDnsNullableInt -Value $_.ifIndex) -eq $entryInterfaceIndex
            } | Select-Object -First 1
        }
        if (-not $adapter -and $entry.InterfaceAlias) {
            $adapter = $adapters | Where-Object { $_.Name -eq [string]$entry.InterfaceAlias } | Select-Object -First 1
        }
        if (-not $adapter) { continue }

        $adapterInterfaceIndex = ConvertTo-OpenPathDnsNullableInt -Value $adapter.ifIndex
        if ($null -eq $adapterInterfaceIndex) { continue }

        # A loopback entry is OpenPath's own pin (Acrylic); never restore it.
        $servers = @($entry.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object {
                $_ -and -not (Test-OpenPathDnsLoopbackAddress -Address $_)
            })
        $origin = ''
        if ($entry.PSObject.Properties['Origin']) {
            $origin = ([string]$entry.Origin).Trim().ToLowerInvariant()
        }

        $reason = 'static'
        if ($origin -eq 'static') {
            # Keep an administrator-configured static DNS, but never a loopback-only one.
            if ($servers.Count -le 0) { $reason = 'no-servers' }
        }
        elseif ($origin) {
            # v3 DHCP origin: returning to DHCP is the whole point of the origin field.
            $reason = 'dhcp-origin'
        }
        elseif (Test-OpenPathDnsLegacyDhcpOrigin -Adapter $adapter) {
            # Legacy snapshot on a DHCP-backed adapter: do not freeze DHCP DNS as static.
            $reason = 'legacy-dhcp'
        }
        elseif ($servers.Count -le 0) {
            $reason = 'no-servers'
        }

        $action = if ($reason -eq 'static') { 'set' } else { 'reset' }
        $plan.Add([PSCustomObject]@{
                InterfaceIndex = [int]$adapterInterfaceIndex
                AdapterName = [string]$adapter.Name
                Action = $action
                ServerAddresses = [string[]]@(if ($action -eq 'set') { $servers })
                Reason = $reason
            })
    }

    return @($plan)
}

function Reset-OpenPathDnsLoopbackResolverAddresses {
    <#
    .SYNOPSIS
    Resets every adapter that still has a loopback resolver back to DHCP-assigned DNS.
    .DESCRIPTION
    Final safety net of the restore: whatever the snapshot said, no adapter may keep a loopback
    resolver once the local DNS proxy has been removed. Returns the interface indexes it reset.
    #>
    if (-not (Get-Command -Name Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return [int[]]@() }
    if (-not (Get-Command -Name Set-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return [int[]]@() }

    $resetIndexes = [System.Collections.Generic.List[int]]::new()
    foreach ($dnsEntry in @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) {
        if ($null -eq $dnsEntry) { continue }
        $stillLoopback = @($dnsEntry.ServerAddresses | Where-Object {
                $_ -and (Test-OpenPathDnsLoopbackAddress -Address $_)
            })
        if ($stillLoopback.Count -gt 0) {
            try {
                Set-DnsClientServerAddress -InterfaceIndex $dnsEntry.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            }
            catch {
                # Best effort, as before: the sweep never stops the restore.
            }
            $resetIndexes.Add([int]$dnsEntry.InterfaceIndex)
        }
    }

    return [int[]]@($resetIndexes)
}

function Reset-OpenPathDnsUpAdapters {
    <#
    .SYNOPSIS
    Resets every adapter whose Status is Up to DHCP-assigned DNS; returns the error messages.
    .PARAMETER StopOnError
    End at the first failing adapter instead of trying the rest.
    #>
    param([switch]$StopOnError)

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($adapter in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
        }
        catch {
            $errors.Add([string]$_)
            if ($StopOnError) { break }
        }
    }

    return [string[]]@($errors)
}

function Invoke-OpenPathOriginalDnsRestore {
    <#
    .SYNOPSIS
    Restores every adapter to its original DNS from the snapshot file, then sweeps loopback resolvers and flushes the cache.
    .DESCRIPTION
    Without a snapshot file every Up adapter is reset to DHCP. With one, the plan of
    Get-OpenPathOriginalDnsRestorePlan is applied. OnAdapterError Stop ends the restore phase at
    the first failing adapter; Continue records the failure and goes on. With
    FallbackResetAllOnFailure, a restore phase that ended with an error is followed by a reset of
    every Up adapter (errors in that fallback are ignored, as before). The loopback sweep and the
    cache flush always run last. Returns immediately with an empty result when Get-NetAdapter or
    Set-DnsClientServerAddress is unavailable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotPath,
        [ValidateSet('Stop', 'Continue')][string]$OnAdapterError = 'Stop',
        [switch]$FallbackResetAllOnFailure
    )

    $result = [PSCustomObject]@{
        UsedSnapshot = $false
        Applied = @()
        LoopbackResets = [int[]]@()
        FallbackUsed = $false
        Errors = [string[]]@()
    }
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return $result }
    if (-not (Get-Command -Name Set-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return $result }

    $stopOnError = ($OnAdapterError -eq 'Stop')
    $applied = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    if (Test-Path $SnapshotPath) {
        $result.UsedSnapshot = $true
        try {
            # v3 and v2 snapshots wrap the entries in an `adapters` property; legacy ones are a bare array.
            $snapshotPayload = Get-Content $SnapshotPath -Raw | ConvertFrom-Json
            if ($null -eq $snapshotPayload) { throw "DNS snapshot $SnapshotPath is empty" }
            $snapshot = if ($snapshotPayload.PSObject.Properties['adapters']) { @($snapshotPayload.adapters) } else { @($snapshotPayload) }
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)

            foreach ($step in @(Get-OpenPathOriginalDnsRestorePlan -SnapshotEntries $snapshot -Adapters $adapters)) {
                try {
                    if ($step.Action -eq 'reset') {
                        Set-DnsClientServerAddress -InterfaceIndex $step.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    }
                    else {
                        Set-DnsClientServerAddress -InterfaceIndex $step.InterfaceIndex -ServerAddresses $step.ServerAddresses -ErrorAction Stop
                    }
                    $applied.Add($step)
                }
                catch {
                    $errors.Add([string]$_)
                    if ($stopOnError) { break }
                }
            }
        }
        catch {
            $errors.Add([string]$_)
        }
    }
    else {
        foreach ($message in @(Reset-OpenPathDnsUpAdapters -StopOnError:$stopOnError)) {
            $errors.Add($message)
        }
    }

    if ($FallbackResetAllOnFailure -and $errors.Count -gt 0) {
        Reset-OpenPathDnsUpAdapters | Out-Null
        $result.FallbackUsed = $true
    }

    $result.LoopbackResets = [int[]]@(Reset-OpenPathDnsLoopbackResolverAddresses)
    if (Get-Command -Name Clear-DnsClientCache -ErrorAction SilentlyContinue) {
        try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
    }

    $result.Applied = @($applied)
    $result.Errors = [string[]]@($errors)
    return $result
}
