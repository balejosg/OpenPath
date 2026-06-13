function Get-OpenPathBridgeFilterCatalog {
    <#
    .SYNOPSIS
        Returns the known NDIS bridge-filter ComponentIDs that desktop hypervisors bind
        to a physical adapter to provide "bridged" guest networking.
    .DESCRIPTION
        Disabling these bindings on the host's physical adapters removes bridged mode for
        VirtualBox/VMware guests (which would otherwise be peers on the LAN, invisible to
        the host DNS/firewall policy) while still letting the VM run in NAT mode -- NAT
        egress traverses the host stack and is filtered by the default-deny DNS policy.

        This is an enumerate-known catalog (like the DoH resolver list); a new hypervisor
        with a different bridge driver needs a new entry here. Hyper-V "bridged" is an
        external virtual switch, NOT a bindable filter, so it is intentionally NOT covered
        and must be controlled by policy (do not grant Hyper-V Administrators / do not
        create an external vSwitch).
    #>
    [CmdletBinding()]
    param()

    return @(
        'VBoxNetLwf',      # VirtualBox NDIS6 Bridged Networking Driver (current)
        'VBoxNetFlt',      # VirtualBox bridged networking (legacy NDIS5 filter)
        'sun_VBoxNetFlt',  # VirtualBox bridged networking (legacy component id)
        'VMnetBridge',     # VMware Bridge Protocol
        'vmware_bridge'    # VMware Bridge Protocol (alternate component id)
    )
}

function Get-OpenPathBridgeFilterSnapshotPath {
    <#
    .SYNOPSIS
        Returns the fixed path where the pre-change bridge-filter binding states are stored.
    #>
    return 'C:\OpenPath\data\original-bridge-filters.json'
}

function Get-OpenPathBridgeFilterComponentIdSet {
    # builds a case-insensitive set of the catalog component ids plus any extra ids from config
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$ExtraComponentIds = @()
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in (@(Get-OpenPathBridgeFilterCatalog) + @($ExtraComponentIds))) {
        $trimmed = ([string]$id).Trim()
        if ($trimmed) { [void]$set.Add($trimmed) }
    }
    return $set
}

function Test-OpenPathBridgeFilterAllowlisted {
    # returns true when the adapter name or component id matches a configured allowlist entry
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$AdapterName,

        [AllowNull()]
        [string]$ComponentId,

        [AllowNull()]
        [string[]]$Allowlist = @()
    )

    foreach ($entry in @($Allowlist)) {
        $value = ([string]$entry).Trim()
        if (-not $value) { continue }
        if ($value -ieq [string]$AdapterName) { return $true }
        if ($value -ieq [string]$ComponentId) { return $true }
    }
    return $false
}

function Get-OpenPathAdaptersWithBridgeFilters {
    <#
    .SYNOPSIS
        Returns physical adapters that have an ENABLED hypervisor bridge filter bound,
        minus any allowlisted adapter name or component id. Mirrors the local-DNS
        adapter detector used by the watchdog.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$ExtraComponentIds = @(),

        [AllowNull()]
        [string[]]$Allowlist = @()
    )

    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return @() }
    if (-not (Get-Command -Name Get-NetAdapterBinding -ErrorAction SilentlyContinue)) { return @() }

    $componentIds = Get-OpenPathBridgeFilterComponentIdSet -ExtraComponentIds $ExtraComponentIds
    $affected = @()

    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) {
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    }

    foreach ($adapter in $adapters) {
        $bindings = @()
        try {
            $bindings = @(Get-NetAdapterBinding -InterfaceAlias $adapter.Name -ErrorAction SilentlyContinue)
        }
        catch {
            continue
        }

        $enabledBridgeFilters = @()
        foreach ($binding in $bindings) {
            $componentId = [string]$binding.ComponentID
            if (-not $componentIds.Contains($componentId)) { continue }
            if (-not [bool]$binding.Enabled) { continue }
            if (Test-OpenPathBridgeFilterAllowlisted -AdapterName $adapter.Name -ComponentId $componentId -Allowlist $Allowlist) { continue }
            $enabledBridgeFilters += $componentId
        }

        if ($enabledBridgeFilters.Count -gt 0) {
            $affected += [PSCustomObject]@{
                Name = [string]$adapter.Name
                InterfaceAlias = [string]$adapter.Name
                ComponentIds = @($enabledBridgeFilters)
            }
        }
    }

    return @($affected)
}

function Save-OpenPathOriginalBridgeFilterSnapshot {
    <#
    .SYNOPSIS
        Records the pre-change Enabled state of every catalog bridge filter so uninstall
        can restore exactly what OpenPath disabled. Does not overwrite an existing
        snapshot, so the first save captures the true original state.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Get-OpenPathBridgeFilterSnapshotPath),
        [switch]$Force
    )

    if ((Test-Path $Path) -and -not $Force) { return $true }
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Get-Command -Name Get-NetAdapterBinding -ErrorAction SilentlyContinue)) { return $false }

    try {
        $componentIds = Get-OpenPathBridgeFilterComponentIdSet
        $entries = @()
        foreach ($adapter in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
            $bindings = @(Get-NetAdapterBinding -InterfaceAlias $adapter.Name -ErrorAction SilentlyContinue)
            foreach ($binding in $bindings) {
                $componentId = [string]$binding.ComponentID
                if (-not $componentIds.Contains($componentId)) { continue }
                $entries += [PSCustomObject]@{
                    InterfaceAlias = [string]$adapter.Name
                    ComponentId = $componentId
                    Enabled = [bool]$binding.Enabled
                }
            }
        }

        $payload = [PSCustomObject]@{
            version = 1
            bindings = @($entries)
        }

        $directory = Split-Path $Path -Parent
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
        Write-OpenPathLog "Saved original bridge-filter snapshot to $Path"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to save bridge-filter snapshot: $_" -Level WARN
        return $false
    }
}

function Disable-OpenPathBridgeFilters {
    <#
    .SYNOPSIS
        Disables hypervisor bridge-filter bindings on physical adapters so guest VMs
        cannot use bridged networking to bypass the host DNS/firewall policy.
    .DESCRIPTION
        Saves the original binding state first (for uninstall), then unbinds each catalog
        filter found enabled. NAT-mode guests are unaffected and remain subject to the
        host's filtered DNS egress. Requires admin/SYSTEM (the watchdog runs as SYSTEM).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string[]]$ExtraComponentIds = @(),

        [AllowNull()]
        [string[]]$Allowlist = @()
    )

    if (-not $PSCmdlet.ShouldProcess('Network adapters', 'Disable hypervisor bridge filter bindings')) { return }
    if (-not (Get-Command -Name Disable-NetAdapterBinding -ErrorAction SilentlyContinue)) {
        Write-OpenPathLog 'Disable-NetAdapterBinding unavailable; cannot neutralize bridged adapters' -Level WARN
        return
    }

    Save-OpenPathOriginalBridgeFilterSnapshot | Out-Null

    foreach ($adapter in @(Get-OpenPathAdaptersWithBridgeFilters -ExtraComponentIds $ExtraComponentIds -Allowlist $Allowlist)) {
        foreach ($componentId in @($adapter.ComponentIds)) {
            try {
                Disable-NetAdapterBinding -InterfaceAlias $adapter.InterfaceAlias -ComponentID $componentId -ErrorAction Stop
                Write-OpenPathLog "Disabled bridge filter $componentId on adapter: $($adapter.Name)"
            }
            catch {
                Write-OpenPathLog "Failed to disable bridge filter $componentId on $($adapter.Name): $_" -Level WARN
            }
        }
    }
}

function Restore-OpenPathOriginalBridgeFilters {
    <#
    .SYNOPSIS
        Re-enables the bridge-filter bindings that OpenPath disabled, using the snapshot
        written before the first unbind. Called during uninstall.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path = (Get-OpenPathBridgeFilterSnapshotPath)
    )

    if (-not $PSCmdlet.ShouldProcess('Network adapters', 'Restore original bridge filter bindings')) { return }
    if (-not (Test-Path $Path)) { return }
    if (-not (Get-Command -Name Enable-NetAdapterBinding -ErrorAction SilentlyContinue)) { return }

    try {
        $payload = Get-Content $Path -Raw | ConvertFrom-Json
        $bindings = if ($payload.PSObject.Properties['bindings']) { @($payload.bindings) } else { @() }
        foreach ($entry in $bindings) {
            # Only re-enable filters that were enabled before OpenPath touched them.
            if (-not [bool]$entry.Enabled) { continue }
            try {
                Enable-NetAdapterBinding -InterfaceAlias ([string]$entry.InterfaceAlias) -ComponentID ([string]$entry.ComponentId) -ErrorAction Stop
                Write-OpenPathLog "Restored bridge filter $($entry.ComponentId) on adapter: $($entry.InterfaceAlias)"
            }
            catch {
                Write-OpenPathLog "Failed to restore bridge filter $($entry.ComponentId) on $($entry.InterfaceAlias): $_" -Level WARN
            }
        }
    }
    catch {
        Write-OpenPathLog "Bridge-filter restore failed: $_" -Level WARN
    }
}
