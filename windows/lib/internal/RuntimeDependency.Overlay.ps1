if (-not (Get-Command -Name 'Get-OpenPathCapabilityStoragePath' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $capabilityStoragePath = Join-Path $PSScriptRoot 'CapabilityStorage.ps1'
    if (Test-Path $capabilityStoragePath -ErrorAction SilentlyContinue) {
        . $capabilityStoragePath
    }
}
# Module contexts (DNS.psm1, native host bootstrap) often already import the
# capability-storage path helper through Common, which would otherwise skip the
# dot-source above and leave the read-access helper undefined. The overlay write
# path must always be able to grant the browser user read access to the file.
if (-not (Get-Command -Name 'Set-OpenPathRuntimeDependencyReadAccess' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
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

    return @((Read-OpenPathRuntimeDependencyOverlayDocument -Path $Path).Entries)
}

function Read-OpenPathRuntimeDependencyOverlayDocument {
    # deserializes the full overlay document (document generation, applied generation, entries)
    [CmdletBinding()]
    param([string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath))

    $document = [PSCustomObject]@{
        Generation = 0
        AppliedGeneration = 0
        Entries = @()
    }
    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return $document }

    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $document }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $generation = if ($parsed.PSObject.Properties['generation']) { [int]$parsed.generation } else { 0 }
        $appliedGeneration = if ($parsed.PSObject.Properties['appliedGeneration']) { [int]$parsed.appliedGeneration } else { 0 }
        return [PSCustomObject]@{
            Generation = $generation
            AppliedGeneration = $appliedGeneration
            Entries = @($parsed.entries)
        }
    }
    catch {
        Write-OpenPathLog "Failed to read runtime dependency overlay: $_" -Level WARN
        return $document
    }
}

function Get-OpenPathRuntimeDependencyEntryGeneration {
    # returns the per-entry generation when present and positive, else 0 (legacy entry without a stamp)
    [CmdletBinding()]
    param([AllowNull()][object]$Entry)

    if ($null -eq $Entry) { return 0 }

    $value = $null
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('generation')) { $value = $Entry['generation'] }
    }
    elseif ($Entry.PSObject.Properties['generation']) {
        $value = $Entry.generation
    }

    if ($null -eq $value) { return 0 }
    try {
        $generation = [int]$value
    }
    catch {
        return 0
    }
    if ($generation -le 0) { return 0 }
    return $generation
}

function Test-OpenPathRuntimeDependencyEntryReady {
    <#
    .SYNOPSIS
    Returns true when an overlay entry is operative: stamped entries gate on their own generation,
    legacy entries without a generation fall back to the document-level rule.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Entry,
        [int]$AppliedGeneration = 0,
        [int]$DocumentGeneration = 0
    )

    if ($null -eq $Entry) { return $false }

    $entryGeneration = Get-OpenPathRuntimeDependencyEntryGeneration -Entry $Entry
    if ($entryGeneration -gt 0) {
        return ($AppliedGeneration -ge $entryGeneration)
    }

    return ($DocumentGeneration -gt 0 -and $AppliedGeneration -ge $DocumentGeneration)
}

function Get-OpenPathRuntimeDependencyPairKey {
    # builds the case-insensitive anchor|dependency key used to compare overlay entry sets
    [CmdletBinding()]
    param([AllowNull()][object]$Entry)

    if ($null -eq $Entry) { return '' }
    $anchor = if ($Entry.PSObject.Properties['anchorHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $Entry.anchorHost } else { '' }
    $dependency = if ($Entry.PSObject.Properties['dependencyHost']) { Normalize-OpenPathRuntimeDependencyHost -Value $Entry.dependencyHost } else { '' }
    if (-not $anchor -or -not $dependency) { return '' }
    return "$anchor|$dependency"
}

function Set-OpenPathRuntimeDependencyEntryGeneration {
    # stamps a per-entry generation on an overlay entry object
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][int]$Generation
    )

    if ($Entry -is [System.Collections.IDictionary]) {
        $Entry['generation'] = $Generation
        return
    }
    $Entry | Add-Member -MemberType NoteProperty -Name 'generation' -Value $Generation -Force
}

function Write-OpenPathRuntimeDependencyOverlay {
    <#
    .SYNOPSIS
    Serializes entries with version, content generation, applied generation, and updatedAt to the overlay json file.
    .DESCRIPTION
    Entries that were not present in the previous document (newly resolvable pairs) are stamped
    with a fresh per-entry generation and move the document generation. Metadata-only refreshes
    and prune rewrites keep the document generation, so already-applied entries never fall back
    to `pending` because another entry is still waiting to be applied.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Entries = @(),
        [string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath)
    )

    $directory = Split-Path $Path -Parent
    if ($directory) {
        Ensure-OpenPathCapabilityStorageDirectory -Path $directory | Out-Null
    }

    $previousDocument = Read-OpenPathRuntimeDependencyOverlayDocument -Path $Path
    $previousGeneration = [int]$previousDocument.Generation
    $previousAppliedGeneration = [int]$previousDocument.AppliedGeneration
    $previousPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($previousEntry in @($previousDocument.Entries)) {
        $previousKey = Get-OpenPathRuntimeDependencyPairKey -Entry $previousEntry
        if ($previousKey) { [void]$previousPairs.Add($previousKey) }
    }

    $addedPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Entries)) {
        $key = Get-OpenPathRuntimeDependencyPairKey -Entry $entry
        if ($key -and -not $previousPairs.Contains($key)) {
            [void]$addedPairs.Add($key)
        }
    }

    $nextGeneration = $previousGeneration
    if ($addedPairs.Count -gt 0) {
        $nextGeneration = $previousGeneration + 1
        foreach ($entry in @($Entries)) {
            $key = Get-OpenPathRuntimeDependencyPairKey -Entry $entry
            if ($key -and $addedPairs.Contains($key)) {
                Set-OpenPathRuntimeDependencyEntryGeneration -Entry $entry -Generation $nextGeneration
            }
        }
    }

    foreach ($entry in @($Entries)) {
        $entryGeneration = Get-OpenPathRuntimeDependencyEntryGeneration -Entry $entry
        if ($entryGeneration -gt $nextGeneration) { $nextGeneration = $entryGeneration }
    }

    @{
        version = $script:OpenPathRuntimeDependencyOverlayVersion
        generation = $nextGeneration
        appliedGeneration = $previousAppliedGeneration
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        entries = @($Entries)
    } | ConvertTo-Json -Depth 8 | Set-Content $Path -Encoding UTF8 -Force

    if (Get-Command -Name 'Set-OpenPathRuntimeDependencyReadAccess' -ErrorAction SilentlyContinue) {
        Set-OpenPathRuntimeDependencyReadAccess -Path $Path | Out-Null
    }
}

function Get-OpenPathRuntimeDependencyOverlayState {
    # reads the overlay document generation and applied generation from disk; returns zeros when the file is absent or unreadable.
    [CmdletBinding()]
    param([string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath))

    $state = [PSCustomObject]@{
        Exists            = $false
        Generation        = 0
        AppliedGeneration = 0
    }

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return $state }

    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $state.Exists = $true
        if ($parsed.PSObject.Properties['generation']) { $state.Generation = [int]$parsed.generation }
        if ($parsed.PSObject.Properties['appliedGeneration']) { $state.AppliedGeneration = [int]$parsed.appliedGeneration }
    }
    catch {
        return $state
    }

    return $state
}

function Set-OpenPathRuntimeDependencyOverlayApplied {
    # marks an overlay content generation as reloaded into the local DNS service; called only after a successful Acrylic reload.
    # -Generation stamps that exact generation (monotonic, never lowers an existing stamp); without it the current document generation is stamped.
    [CmdletBinding()]
    param(
        [string]$Path = (Get-OpenPathRuntimeDependencyOverlayPath),

        [int]$Generation = -1
    )

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return $false }

    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $documentGeneration = if ($parsed.PSObject.Properties['generation']) { [int]$parsed.generation } else { 0 }
        $targetGeneration = if ($Generation -ge 0) { [Math]::Min([int]$Generation, $documentGeneration) } else { $documentGeneration }
        $appliedGeneration = if ($parsed.PSObject.Properties['appliedGeneration']) { [int]$parsed.appliedGeneration } else { 0 }
        if ($appliedGeneration -ge $targetGeneration) { return $true }

        $parsed | Add-Member -MemberType NoteProperty -Name 'appliedGeneration' -Value $targetGeneration -Force
        $parsed | Add-Member -MemberType NoteProperty -Name 'appliedAt' -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $parsed | ConvertTo-Json -Depth 8 | Set-Content $Path -Encoding UTF8 -Force

        if (Get-Command -Name 'Set-OpenPathRuntimeDependencyReadAccess' -ErrorAction SilentlyContinue) {
            Set-OpenPathRuntimeDependencyReadAccess -Path $Path | Out-Null
        }
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to mark runtime dependency overlay applied: $_" -Level WARN
        return $false
    }
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
    $blockedSubdomainSet = New-OpenPathRuntimeDependencyBlockedSubdomainSet -BlockedSubdomains $BlockedSubdomains
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
            (Test-OpenPathBlockedSubdomainMatch -Domain $entryDependency -BlockedSubdomains $BlockedSubdomains -BlockedSubdomainSet $blockedSubdomainSet)
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
            -SkipOverlayCheck `
            -WhitelistSet $whitelistSet `
            -ProtectedHosts $protectedSet `
            -BlockedSubdomainSet $blockedSubdomainSet
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
    $blockedSubdomainSet = New-OpenPathRuntimeDependencyBlockedSubdomainSet -BlockedSubdomains $BlockedSubdomains
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
            (Test-OpenPathBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains $BlockedSubdomains -BlockedSubdomainSet $blockedSubdomainSet) -or
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
