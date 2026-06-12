function Clear-AcrylicCache {
    <#
    .SYNOPSIS
    Removes the Acrylic address cache file so the proxy starts fresh on its next lookup.
    #>
    [CmdletBinding()] param()
    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }
    $cachePath = "$acrylicPath\AcrylicCache.dat"
    if (-not (Test-Path $cachePath)) { return $true }
    try {
        Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
        Write-OpenPathLog "Purged Acrylic address cache"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to purge Acrylic address cache: $_" -Level WARN
        return $false
    }
}

function Set-LocalDNS {
    <#
    .SYNOPSIS
    Points all active network adapters at the local Acrylic proxy and flushes the DNS client cache.
    .DESCRIPTION
    Saves the current adapter DNS configuration before redirecting each active adapter to 127.0.0.1,
    so the original settings can be recovered during uninstall.
    #>
    [CmdletBinding(SupportsShouldProcess)] param()
    if (-not $PSCmdlet.ShouldProcess("Network adapters", "Set DNS to 127.0.0.1")) { return }
    Write-OpenPathLog "Configuring local DNS..."
    Save-OpenPathOriginalDnsSnapshot | Out-Null
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($adapter in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses "127.0.0.1"
            Write-OpenPathLog "Set DNS for adapter: $($adapter.Name)"
        }
        catch {
            Write-OpenPathLog "Failed to set DNS for $($adapter.Name): $_" -Level WARN
        }
    }
    Clear-DnsClientCache
    Write-OpenPathLog "DNS cache flushed"
}

function Get-OpenPathOriginalDnsSnapshotPath {
    <#
    .SYNOPSIS
    Returns the fixed path where the pre-installation DNS adapter snapshot is stored on disk.
    #>
    return 'C:\OpenPath\data\original-dns.json'
}

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

function Get-OpenPathCurrentDnsSnapshotEntries {
    <#
    .SYNOPSIS
    Reads the current adapter list and returns a snapshot object per active adapter including its IPv4 DNS and gateway.
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

            [PSCustomObject]@{
                InterfaceGuid = [string]$adapter.InterfaceGuid
                InterfaceAlias = [string]$adapter.Name
                InterfaceIndex = [int]$adapter.ifIndex
                Gateway = [string]$gateway
                ServerAddresses = @($dns.ServerAddresses | ForEach-Object { [string]$_ })
            }
        }
    )
}

function Save-OpenPathOriginalDnsSnapshot {
    <#
    .SYNOPSIS
    Captures the current adapter DNS configuration to a JSON snapshot file for later restoration.
    .DESCRIPTION
    Skips writing when the snapshot already exists and Force is not set. Returns true on success
    and false when the required DNS commands are unavailable on this platform.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Get-OpenPathOriginalDnsSnapshotPath),
        [switch]$Force
    )

    if ((Test-Path $Path) -and -not $Force) { return $true }
    if (-not (Get-Command -Name Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return $false }

    try {
        $snapshot = @(Get-OpenPathCurrentDnsSnapshotEntries)
        $networkFingerprint = Get-OpenPathDnsNetworkFingerprint -Entries $snapshot
        $payload = [PSCustomObject]@{
            version = 2
            networkFingerprint = [string]$networkFingerprint
            adapters = @($snapshot)
        }

        $directory = Split-Path $Path -Parent
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
        Write-OpenPathLog "Saved original DNS snapshot to $Path"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to save original DNS snapshot: $_" -Level WARN
        return $false
    }
}

function Update-OpenPathOriginalDnsSnapshotForCurrentNetwork {
    <#
    .SYNOPSIS
    Refreshes the adapter DNS snapshot when the network topology has changed since the last save.
    .DESCRIPTION
    Computes the current network fingerprint and compares it against the stored one. Only overwrites
    the snapshot when the topology differs and at least one non-loopback DNS address is visible.
    #>
    [CmdletBinding()]
    param([string]$Path = (Get-OpenPathOriginalDnsSnapshotPath))

    try {
        $snapshot = @(Get-OpenPathCurrentDnsSnapshotEntries)
        $visibleDns = @(
            $snapshot |
                ForEach-Object { @($_.ServerAddresses) } |
                Where-Object {
                    $_ -and
                    $_ -notin @('127.0.0.1', '0.0.0.0') -and
                    $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$'
                }
        )
        if ($visibleDns.Count -le 0) {
            return $false
        }

        $currentFingerprint = Get-OpenPathDnsNetworkFingerprint -Entries $snapshot
        $existingFingerprint = ''
        if (Test-Path $Path -ErrorAction SilentlyContinue) {
            try {
                $existing = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($existing.PSObject.Properties['networkFingerprint']) {
                    $existingFingerprint = [string]$existing.networkFingerprint
                }
                elseif ($existing.PSObject.Properties['adapters']) {
                    $existingFingerprint = Get-OpenPathDnsNetworkFingerprint -Entries @($existing.adapters)
                }
                else {
                    $existingFingerprint = Get-OpenPathDnsNetworkFingerprint -Entries @($existing)
                }
            }
            catch {
                $existingFingerprint = ''
            }
        }

        if ($currentFingerprint -and $currentFingerprint -ne $existingFingerprint) {
            return (Save-OpenPathOriginalDnsSnapshot -Path $Path -Force)
        }

        return $true
    }
    catch {
        Write-OpenPathLog "Failed to refresh DNS snapshot for current network: $_" -Level WARN
        return $false
    }
}

function Restore-OriginalDNS {
    <#
    .SYNOPSIS
    Restores each adapter to its pre-installation DNS addresses using the saved snapshot, falling back to a full reset.
    .DESCRIPTION
    Matches adapters by GUID first, then by index, then by alias. Adapters with an empty saved address list
    are reset to DHCP-assigned DNS rather than set to a specific address.
    #>
    [CmdletBinding(SupportsShouldProcess)] param()
    if (-not $PSCmdlet.ShouldProcess("Network adapters", "Restore original DNS settings")) { return }
    Write-OpenPathLog "Restoring original DNS settings..."

    $snapshotPath = Get-OpenPathOriginalDnsSnapshotPath
    if (Test-Path $snapshotPath) {
        try {
            $snapshotPayload = Get-Content $snapshotPath -Raw | ConvertFrom-Json
            $snapshot = if ($snapshotPayload.PSObject.Properties['adapters']) { @($snapshotPayload.adapters) } else { @($snapshotPayload) }
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
            foreach ($entry in $snapshot) {
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

                $servers = @($entry.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($servers.Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $adapterInterfaceIndex -ServerAddresses $servers -ErrorAction Stop
                    Write-OpenPathLog "Restored DNS for adapter: $($adapter.Name)"
                }
                else {
                    Set-DnsClientServerAddress -InterfaceIndex $adapterInterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    Write-OpenPathLog "Reset DNS for adapter: $($adapter.Name)"
                }
            }
            Clear-DnsClientCache
            return
        }
        catch {
            Write-OpenPathLog "Snapshot DNS restore failed: $_" -Level WARN
        }
    }

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($adapter in $adapters) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    }
    Clear-DnsClientCache
}

function Restore-OpenPathCaptivePortalDNS {
    <#
    .SYNOPSIS
    Resets each active adapter to DHCP-assigned DNS so a captive portal can be reached.
    #>
    [CmdletBinding(SupportsShouldProcess)] param()
    if (-not $PSCmdlet.ShouldProcess("Network adapters", "Reset DNS server addresses for captive portal access")) { return $false }
    Write-OpenPathLog "Resetting DNS settings for captive portal access..."

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    $resetSucceeded = ($null -ne $adapters -and @($adapters).Count -gt 0)
    foreach ($adapter in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
            Write-OpenPathLog "Reset DNS for adapter: $($adapter.Name)"
        }
        catch {
            $resetSucceeded = $false
            Write-OpenPathLog "Failed to reset DNS for $($adapter.Name): $_" -Level WARN
        }
    }
    Clear-DnsClientCache
    return [bool]$resetSucceeded
}

function Get-AcrylicService {
    <#
    .SYNOPSIS
    Returns the Acrylic DNS proxy service object, trying both the canonical name and a display-name wildcard.
    #>
    $service = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
    if ($service) { return $service }

    return Get-Service -DisplayName '*Acrylic*' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Wait-AcrylicServiceStatus {
    <#
    .SYNOPSIS
    Polls the Acrylic service until it reaches the requested status or the timeout expires.
    .DESCRIPTION
    Uses the ServiceController wait method when available, then falls back to a polling loop
    at 500 ms intervals until the deadline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return $null }

    if ($service.PSObject.Methods.Name -contains 'WaitForStatus') {
        try {
            $remainingSeconds = [Math]::Max(1, [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
            $service.WaitForStatus($Status, [TimeSpan]::FromSeconds($remainingSeconds))
        }
        catch {
            Write-OpenPathLog "Acrylic service wait via ServiceController failed: $_" -Level WARN
        }
    }

    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service -and ([string]$service.Status) -eq $Status) {
            return $service
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return (Get-Service -Name $Name -ErrorAction SilentlyContinue)
}

function Ensure-AcrylicService {
    <#
    .SYNOPSIS
    Verifies that the Acrylic service is registered and optionally starts it, registering from disk if needed.
    #>
    [CmdletBinding()]
    param(
        [switch]$Start,
        [int]$TimeoutSeconds = 20
    )

    try {
        $acrylicPath = Get-AcrylicPath
        if (-not $acrylicPath) { return $false }

        $service = Get-AcrylicService
        if (-not $service -and (Test-Path (Join-Path $acrylicPath 'AcrylicService.exe'))) {
            Register-AcrylicServiceFromPath -AcrylicPath $acrylicPath | Out-Null
            Start-Sleep -Seconds 2
            $service = Get-AcrylicService
        }

        if (-not $service) {
            Write-OpenPathLog 'Acrylic service is not registered' -Level WARN
            return $false
        }

        if ($Start -and $service.Status -ne 'Running') {
            Start-Service -Name $service.Name -ErrorAction Stop
            $service = Wait-AcrylicServiceStatus -Name $service.Name -Status 'Running' -TimeoutSeconds $TimeoutSeconds
        }

        if ($Start) {
            return ($service.Status -eq 'Running')
        }

        return $true
    }
    catch {
        Write-OpenPathLog "Failed to ensure Acrylic service: $_" -Level WARN
        return $false
    }
}

function Restart-AcrylicService {
    <#
    .SYNOPSIS
    Clears the Acrylic cache and restarts the service, falling back to the batch file when the service cmdlet fails.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$TimeoutSeconds = 20,
        [switch]$SkipBatchFallback
    )

    if (-not $PSCmdlet.ShouldProcess("Acrylic DNS Proxy service", "Restart")) { return $false }
    Write-OpenPathLog "Restarting Acrylic service..."
    try {
        Clear-AcrylicCache | Out-Null
        $service = Get-AcrylicService
        if (-not $service) {
            Ensure-AcrylicService -Start -TimeoutSeconds $TimeoutSeconds | Out-Null
            $service = Get-AcrylicService
        }
        if ($service) {
            $serviceName = $service.Name
            if ($service.Status -eq 'Running') {
                try {
                    Restart-Service -Name $serviceName -Force -ErrorAction Stop
                }
                catch {
                    Write-OpenPathLog "Restart-Service failed for Acrylic; retrying stop/start: $_" -Level WARN
                    if (-not (Stop-AcrylicService -Confirm:$false)) {
                        throw
                    }
                    if (-not (Ensure-AcrylicService -Start -TimeoutSeconds $TimeoutSeconds)) {
                        throw
                    }
                }
            }
            else {
                Start-Service -Name $serviceName -ErrorAction Stop
            }
            $service = Wait-AcrylicServiceStatus -Name $serviceName -Status 'Running' -TimeoutSeconds $TimeoutSeconds
            if ($service.Status -eq 'Running') {
                Write-OpenPathLog "Acrylic service restarted successfully"
                return $true
            }
        }
        $acrylicPath = Get-AcrylicPath
        if (-not $SkipBatchFallback -and $acrylicPath -and (Test-Path "$acrylicPath\RestartAcrylicService.bat")) {
            & cmd /c "$acrylicPath\RestartAcrylicService.bat" 2>$null
            Start-Sleep -Seconds 2
            if (Ensure-AcrylicService -Start -TimeoutSeconds $TimeoutSeconds) {
                Write-OpenPathLog "Acrylic service restarted via batch file"
                return $true
            }
        }
        Write-OpenPathLog "Could not restart Acrylic service" -Level ERROR
        return $false
    }
    catch {
        Write-OpenPathLog "Error restarting Acrylic: $_" -Level ERROR
        return $false
    }
}

function Start-AcrylicService {
    <#
    .SYNOPSIS
    Starts the Acrylic service, using the batch file helper when the service cmdlet is unavailable.
    #>
    [CmdletBinding(SupportsShouldProcess)] param()
    if (-not $PSCmdlet.ShouldProcess("Acrylic DNS Proxy service", "Start")) { return $false }
    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }
    try {
        if (Ensure-AcrylicService -Start) {
            return $true
        }
        if (Test-Path "$acrylicPath\StartAcrylicService.bat") {
            & cmd /c "$acrylicPath\StartAcrylicService.bat" 2>$null
            Start-Sleep -Seconds 2
            return (Ensure-AcrylicService -Start)
        }
        return $false
    }
    catch {
        Write-OpenPathLog "Error starting Acrylic: $_" -Level ERROR
        return $false
    }
}

function Stop-AcrylicService {
    <#
    .SYNOPSIS
    Stops the Acrylic DNS proxy service if it is currently running.
    #>
    [CmdletBinding(SupportsShouldProcess)] param()
    if (-not $PSCmdlet.ShouldProcess("Acrylic DNS Proxy service", "Stop")) { return $false }
    try {
        $service = Get-Service -DisplayName "*Acrylic*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($service -and $service.Status -eq 'Running') {
            Stop-Service -Name $service.Name -Force
            Start-Sleep -Seconds 1
        }
        return $true
    }
    catch {
        Write-OpenPathLog "Error stopping Acrylic: $_" -Level ERROR
        return $false
    }
}
