if (-not (Get-Command -Name 'Get-OpenPathCapabilityStoragePath' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $capabilityStoragePath = Join-Path $PSScriptRoot 'CapabilityStorage.ps1'
    if (Test-Path $capabilityStoragePath -ErrorAction SilentlyContinue) {
        . $capabilityStoragePath
    }
}

if (-not (Get-Variable -Name OpenPathRuntimeDependencyOverlayVersion -Scope Script -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $runtimeDependencyProtocolPath = Join-Path $PSScriptRoot 'RuntimeDependency.Protocol.ps1'
    if (Test-Path $runtimeDependencyProtocolPath -ErrorAction SilentlyContinue) {
        . $runtimeDependencyProtocolPath
    }
}

function Get-OpenPathRuntimeDependencyOverlayPath {
    # returns the capability storage path for the runtime dependency overlay json file
    [CmdletBinding()]
    param()

    return (Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay)
}

function Get-OpenPathRuntimeDependencyOverlaySettings {
    # returns ttl and capacity for the overlay, reading env overrides OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS and _CAPACITY
    [CmdletBinding()]
    param()

    $ttlDays = 7
    $capacity = 300
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) {
        try { $ttlDays = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) } catch { $ttlDays = 7 }
    }
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) {
        try { $capacity = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) } catch { $capacity = 300 }
    }

    return [PSCustomObject]@{
        TtlDays = $ttlDays
        Capacity = $capacity
    }
}

function Read-OpenPathRuntimeDependencyOverlay {
    # deserializes the overlay json from disk and returns the entries array; returns an empty array when the file is absent or unreadable
    [CmdletBinding()]
    param([string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath))

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return @() }

    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return @($parsed.entries)
    }
    catch {
        Write-OpenPathLog "Failed to read runtime dependency overlay: $_" -Level WARN
        return @()
    }
}

function Write-OpenPathRuntimeDependencyOverlay {
    # serializes entries with version and updatedAt to the overlay json file, creating the directory if needed
    [CmdletBinding()]
    param(
        [object[]]$Entries = @(),
        [string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath)
    )

    $directory = Split-Path $Path -Parent
    if ($directory) {
        Ensure-OpenPathCapabilityStorageDirectory -Path $directory | Out-Null
    }

    @{
        version = $script:OpenPathRuntimeDependencyOverlayVersion
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        entries = @($Entries)
    } | ConvertTo-Json -Depth 8 | Set-Content $Path -Encoding UTF8 -Force
}

function Clear-OpenPathRuntimeDependencyOverlay {
    # removes the overlay file from disk if it exists; silently does nothing when absent
    [CmdletBinding()]
    param([string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath))

    if (Test-Path $Path -ErrorAction SilentlyContinue) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }
}

function Update-OpenPathRuntimeDependencyOverlay {
    # merges new requests into existing entries, evicts expired/invalid/protected/blocked entries, bounds to Capacity; returns Entries, Processed, Rejected, Changed
    [CmdletBinding()]
    param(
        [object[]]$Entries = @(),
        [object[]]$Requests = @(),
        [string[]]$WhitelistedDomains = @(),
        [string[]]$BlockedSubdomains = @(),
        [int]$Capacity = 300,
        [int]$TtlDays = 7
    )

    $whitelistSet = New-OpenPathRuntimeDependencyWhitelistSet -WhitelistedDomains $WhitelistedDomains
    $protectedSet = Get-OpenPathRuntimeDependencyProtectedHosts
    $now = (Get-Date).ToUniversalTime()
    $expiresAt = $now.AddDays([Math]::Max(1, $TtlDays))
    $keptEntries = @()

    foreach ($entry in @($Entries)) {
        $entryDependency = if ($entry.PSObject.Properties['dependencyHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost } else { '' }
        $entryAnchor = if ($entry.PSObject.Properties['anchorHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.anchorHost } else { '' }
        $entryExpiresAt = if ($entry.PSObject.Properties['expiresAt']) { [string]$entry.expiresAt } else { '' }
        $isExpired = $false
        if ($entryExpiresAt) {
            try { $isExpired = ([DateTimeOffset]::Parse($entryExpiresAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime -le $now) }
            catch { $isExpired = $true }
        }

        if (
            -not $entryDependency -or
            -not $entryAnchor -or
            $isExpired -or
            -not (Test-OpenPathWhitelistCoversHost -Hostname $entryAnchor -WhitelistSet $whitelistSet) -or
            (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $entryAnchor -ProtectedHosts $protectedSet) -or
            (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $entryDependency -ProtectedHosts $protectedSet) -or
            (Test-OpenPathBlockedSubdomainMatch -Domain $entryDependency -BlockedSubdomains $BlockedSubdomains)
        ) {
            continue
        }

        $keptEntries += $entry
    }

    $processed = 0
    $rejected = 0
    foreach ($request in @($Requests)) {
        $candidate = Test-OpenPathRuntimeDependencyCandidate `
            -Message $request `
            -WhitelistedDomains $WhitelistedDomains `
            -BlockedSubdomains $BlockedSubdomains `
            -SkipOverlayCheck
        if ($candidate.Valid -ne $true) {
            $rejected += 1
            continue
        }

        $updated = $false
        foreach ($entry in $keptEntries) {
            $entryDependency = if ($entry.PSObject.Properties['dependencyHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost } else { '' }
            $entryAnchor = if ($entry.PSObject.Properties['anchorHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.anchorHost } else { '' }
            if ($entryDependency -eq $candidate.DependencyHost -and $entryAnchor -eq $candidate.AnchorHost) {
                $requestTypes = @($entry.requestTypes)
                if ($requestTypes -notcontains $candidate.RequestType) { $requestTypes += $candidate.RequestType }
                $entry.lastSeen = $now.ToString('o')
                $entry.expiresAt = $expiresAt.ToString('o')
                $entry.requestTypes = @($requestTypes | Sort-Object -Unique)
                $updated = $true
                break
            }
        }

        if (-not $updated) {
            $keptEntries += [PSCustomObject]@{
                dependencyHost = $candidate.DependencyHost
                anchorHost = $candidate.AnchorHost
                requestTypes = @($candidate.RequestType)
                firstSeen = $now.ToString('o')
                lastSeen = $now.ToString('o')
                expiresAt = $expiresAt.ToString('o')
                source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
            }
            # Auditability: every NET-NEW auto-allow makes a domain newly resolvable. Log it so
            # teachers/operators can review runtime-dependency grants and detect queue abuse
            # (the queue is user-writable and self-asserted; see red-team F2).
            Write-OpenPathLog "runtime-dependency auto-allow: anchor=$($candidate.AnchorHost) dependency=$($candidate.DependencyHost) type=$($candidate.RequestType)" -Level INFO
        }
        $processed += 1
    }

    $boundedEntries = @(
        $keptEntries |
            Sort-Object @{ Expression = { if ($_.PSObject.Properties['lastSeen']) { [string]$_.lastSeen } else { '' } }; Descending = $true } |
            Select-Object -First ([Math]::Max(1, $Capacity))
    )

    return [PSCustomObject]@{
        Entries = $boundedEntries
        Processed = $processed
        Rejected = $rejected
        Changed = ($processed -gt 0)
    }
}

function Test-OpenPathRuntimeDependencyOverlayContainsDomains {
    # returns true only when every domain in $Domains is present as a dependencyHost in the on-disk overlay
    [CmdletBinding()]
    param([string[]]$Domains = @())

    if (@($Domains).Count -eq 0) { return $true }
    $entries = @(Read-OpenPathRuntimeDependencyOverlay)
    $entryHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if ($entry.PSObject.Properties['dependencyHost']) {
            $normalized = Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost
            if ($normalized) { [void]$entryHosts.Add($normalized) }
        }
    }
    foreach ($domain in @($Domains)) {
        $normalized = Normalize-OpenPathRuntimeDependencyHost -Value $domain
        if (-not $normalized -or -not $entryHosts.Contains($normalized)) { return $false }
    }
    return $true
}

function Get-OpenPathRuntimeDependencyDomains {
    # returns unique dependency host strings from valid non-expired overlay entries; prunes the file when $Prune is set and stale entries were dropped
    [CmdletBinding()]
    param(
        [string[]]$WhitelistedDomains = @(),
        [string[]]$BlockedSubdomains = @(),
        [switch]$Prune
    )

    $whitelistSet = New-OpenPathRuntimeDependencyWhitelistSet -WhitelistedDomains $WhitelistedDomains
    $protectedSet = Get-OpenPathRuntimeDependencyProtectedHosts
    $now = Get-Date
    $entries = @(Read-OpenPathRuntimeDependencyOverlay)
    $keptEntries = @()
    $domains = [System.Collections.Generic.List[string]]::new()
    $seenDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $entries) {
        $dependencyHost = if ($entry.PSObject.Properties['dependencyHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost } else { '' }
        $anchorHost = if ($entry.PSObject.Properties['anchorHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $entry.anchorHost } else { '' }
        $expiresAt = if ($entry.PSObject.Properties['expiresAt']) { [string]$entry.expiresAt } else { '' }
        $isExpired = $false
        if ($expiresAt) {
            try { $isExpired = ([DateTimeOffset]::Parse($expiresAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime -le $now.ToUniversalTime()) }
            catch { $isExpired = $true }
        }

        if (
            -not $dependencyHost -or
            -not $anchorHost -or
            $isExpired -or
            -not (Test-OpenPathWhitelistCoversHost -Hostname $anchorHost -WhitelistSet $whitelistSet) -or
            (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $dependencyHost -ProtectedHosts $protectedSet) -or
            (Test-OpenPathBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains $BlockedSubdomains) -or
            -not (Test-OpenPathDomainFormat -Domain $dependencyHost)
        ) {
            continue
        }

        $keptEntries += $entry
        if ($seenDomains.Add($dependencyHost)) { [void]$domains.Add($dependencyHost) }
    }

    if ($Prune -and ($keptEntries.Count -ne $entries.Count)) {
        Write-OpenPathRuntimeDependencyOverlay -Entries $keptEntries
    }

    return $domains.ToArray()
}
