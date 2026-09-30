function Test-NativeHostRuntimeDependencyOverlayContainsDomains {
    <#
    .SYNOPSIS
    Returns true when all supplied domains appear as dependency hosts in the runtime dependency overlay file.
    #>
    param([string[]]$Domains = @())

    if (@($Domains).Count -eq 0) {
        return $true
    }

    $path = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $script:OpenPathRoot
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $entryHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($parsed.entries)) {
            if ($entry.PSObject.Properties['dependencyHost'] -and $entry.dependencyHost) {
                [void]$entryHosts.Add(([string]$entry.dependencyHost).Trim().Trim('.').ToLowerInvariant())
            }
        }

        foreach ($domain in @($Domains)) {
            $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $domain
            if (-not $normalized -or -not $entryHosts.Contains($normalized)) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-NativeHostLog "Failed to inspect runtime dependency overlay: $_"
        return $false
    }
}

function Test-NativeHostRuntimeDependencyQueueRequestProcessed {
    <#
    .SYNOPSIS
    Returns true when the given queue request file no longer exists, indicating the request was processed.
    #>
    param([AllowNull()][string]$RequestPath = '')

    if ([string]::IsNullOrWhiteSpace($RequestPath)) {
        return $true
    }

    return -not (Test-Path $RequestPath -ErrorAction SilentlyContinue)
}

function Test-NativeHostRuntimeDependencyOverlayApplied {
    <#
    .SYNOPSIS
    Returns true when the on-disk overlay content generation was confirmed as reloaded into the local DNS service.
    #>
    param()

    $path = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $script:OpenPathRoot
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $generation = if ($parsed.PSObject.Properties['generation']) { [int]$parsed.generation } else { 0 }
        $appliedGeneration = if ($parsed.PSObject.Properties['appliedGeneration']) { [int]$parsed.appliedGeneration } else { 0 }
        return ($appliedGeneration -ge $generation)
    }
    catch {
        Write-NativeHostLog "Failed to inspect runtime dependency overlay applied state: $_"
        return $false
    }
}

function Test-NativeHostRuntimeDependencyWorkerFresh {
    <#
    .SYNOPSIS
    Returns true when the resident runtime dependency worker heartbeat or a recent busy mark is recent enough to skip the scheduled-task fallback trigger.
    #>
    param(
        [int]$MaxAgeSeconds = 10,
        [int]$BusyMaxAgeSeconds = 120
    )

    $statePath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyWorkerState -OpenPathRoot $script:OpenPathRoot
    if (-not (Test-Path $statePath -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $raw = Get-Content -Path $statePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop

        $referenceMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        $heartbeatMs = $null
        if ($parsed.PSObject.Properties['heartbeatEpochMs'] -and $parsed.heartbeatEpochMs) {
            $heartbeatMs = [long]$parsed.heartbeatEpochMs
        }
        elseif ($parsed.PSObject.Properties['heartbeatAt'] -and $parsed.heartbeatAt) {
            # ps-culture-allow: InvariantCulture and RoundtripKind are passed explicitly on the following lines.
            $heartbeatMs = [long][DateTimeOffset]::Parse(
                [string]$parsed.heartbeatAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ).ToUnixTimeMilliseconds()
        }
        if ($null -ne $heartbeatMs) {
            $ageMs = $referenceMs - $heartbeatMs
            if ($ageMs -ge -30000 -and $ageMs -le ([Math]::Max(1, $MaxAgeSeconds) * 1000)) {
                return $true
            }
        }

        # A worker applying a long batch refreshes its busy mark instead of the idle
        # heartbeat; that still proves the worker is alive and applying.
        $busySinceMs = $null
        if ($parsed.PSObject.Properties['busySinceEpochMs'] -and $parsed.busySinceEpochMs) {
            $busySinceMs = [long]$parsed.busySinceEpochMs
        }
        elseif ($parsed.PSObject.Properties['busySince'] -and $parsed.busySince) {
            # ps-culture-allow: InvariantCulture and RoundtripKind are passed explicitly on the following lines.
            $busySinceMs = [long][DateTimeOffset]::Parse(
                [string]$parsed.busySince,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ).ToUnixTimeMilliseconds()
        }
        if ($null -ne $busySinceMs) {
            $busyAgeMs = $referenceMs - $busySinceMs
            return ($busyAgeMs -ge -30000 -and $busyAgeMs -le ([Math]::Max(1, $BusyMaxAgeSeconds) * 1000))
        }

        return $false
    }
    catch {
        return $false
    }
}

function Get-NativeHostRuntimeDependencySnapshot {
    <#
    .SYNOPSIS
    Reads the runtime dependency overlay once and returns document/applied generations plus entries.
    #>
    param()

    $snapshot = [PSCustomObject]@{
        Generation = 0
        AppliedGeneration = 0
        Entries = @()
    }

    $path = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $script:OpenPathRoot
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        return $snapshot
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $snapshot }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $generation = if ($parsed.PSObject.Properties['generation']) { [int]$parsed.generation } else { 0 }
        $appliedGeneration = if ($parsed.PSObject.Properties['appliedGeneration']) { [int]$parsed.appliedGeneration } else { 0 }
        $snapshot.Generation = $generation
        $snapshot.AppliedGeneration = $appliedGeneration
        $snapshot.Entries = @($parsed.entries)
        return $snapshot
    }
    catch {
        Write-NativeHostLog "Failed to inspect runtime dependency overlay: $_"
        return $snapshot
    }
}

function Test-NativeHostRuntimeDependencyEntryReady {
    <#
    .SYNOPSIS
    Per-entry readiness: stamped entries gate on their own generation, legacy entries fall back to the document rule.
    #>
    param(
        [AllowNull()][object]$Entry,
        [int]$AppliedGeneration = 0,
        [int]$DocumentGeneration = 0
    )

    if ($null -eq $Entry) { return $false }

    $entryGeneration = 0
    if ($Entry.PSObject.Properties['generation']) {
        try { $entryGeneration = [int]$Entry.generation } catch { $entryGeneration = 0 }
    }

    if ($entryGeneration -gt 0) {
        return ($AppliedGeneration -ge $entryGeneration)
    }

    return ($DocumentGeneration -gt 0 -and $AppliedGeneration -ge $DocumentGeneration)
}

function Get-NativeHostRuntimeDependencyEntryState {
    <#
    .SYNOPSIS
    Returns the readiness state for one anchor/dependency pair from an already-read overlay snapshot.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost
    )

    $state = @{
        ready = $false
        runtimeDependencyState = 'pending'
        expiresAt = ''
    }

    foreach ($entry in @($Snapshot.Entries)) {
        $entryDependency = Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost
        $entryAnchor = Normalize-OpenPathRuntimeDependencyHost -Value $entry.anchorHost
        if ($entryDependency -ne $DependencyHost -or $entryAnchor -ne $AnchorHost) {
            continue
        }
        $ready = [bool](Test-NativeHostRuntimeDependencyEntryReady -Entry $entry -AppliedGeneration ([int]$Snapshot.AppliedGeneration) -DocumentGeneration ([int]$Snapshot.Generation))
        $state['ready'] = $ready
        $state['runtimeDependencyState'] = if ($ready) { 'ready' } else { 'pending' }
        if ($entry.PSObject.Properties['expiresAt']) { $state['expiresAt'] = [string]$entry.expiresAt }
        return $state
    }

    return $state
}

function Test-NativeHostRuntimeDependencyDomainsReady {
    <#
    .SYNOPSIS
    Returns true when every dependency host has an overlay entry that is ready under the per-entry rule.
    #>
    param(
        [string[]]$Domains = @(),
        [AllowNull()][object]$Snapshot = $null
    )

    if (@($Domains).Count -eq 0) { return $true }
    if ($null -eq $Snapshot) {
        $Snapshot = Get-NativeHostRuntimeDependencySnapshot
    }

    foreach ($domain in @($Domains)) {
        $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $domain
        if (-not $normalized) { return $false }
        $matched = $false
        foreach ($entry in @($Snapshot.Entries)) {
            $entryDependency = Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost
            if ($entryDependency -ne $normalized) { continue }
            if (Test-NativeHostRuntimeDependencyEntryReady -Entry $entry -AppliedGeneration ([int]$Snapshot.AppliedGeneration) -DocumentGeneration ([int]$Snapshot.Generation)) {
                $matched = $true
                break
            }
        }
        if (-not $matched) { return $false }
    }

    return $true
}

function Test-NativeHostRuntimeDependencyReady {
    <#
    .SYNOPSIS
    Returns true when every requested dependency is present in the overlay and the overlay generation was reloaded into the local DNS service.
    .DESCRIPTION
    Used by the update task wait condition. When no runtime dependency domains are given,
    readiness only requires the queue request to be processed (plain whitelist updates).
    #>
    param(
        [AllowNull()][string]$RequestPath = '',
        [string[]]$Domains = @()
    )

    if (-not (Test-NativeHostRuntimeDependencyQueueRequestProcessed -RequestPath $RequestPath)) {
        return $false
    }
    if (@($Domains).Count -eq 0) {
        return $true
    }
    # Per-entry readiness: reading the overlay once avoids the old global
    # appliedGeneration gate, where an applied entry fell back to `pending`
    # as soon as a later batch bumped the document generation.
    $snapshot = Get-NativeHostRuntimeDependencySnapshot
    return (Test-NativeHostRuntimeDependencyDomainsReady -Domains $Domains -Snapshot $snapshot)
}

function Add-NativeHostRuntimeDependencyReadinessToResult {
    <#
    .SYNOPSIS
    Adds readiness fields to skipped resolution results so the extension can release already-satisfied dependencies.
    #>
    param([Parameter(Mandatory = $true)][object]$Result)

    if ($Result -isnot [System.Collections.IDictionary]) {
        return $Result
    }
    if (-not $Result.Contains('reason')) {
        return $Result
    }

    switch ([string]$Result['reason']) {
        'dependency-already-whitelisted' {
            $Result['ready'] = $true
            $Result['runtimeDependencyState'] = 'ready'
        }
        'runtime-dependency-overlay-present' {
            $anchorHost = if ($Result.Contains('anchorHost')) { Normalize-OpenPathRuntimeDependencyHost -Value $Result['anchorHost'] } else { '' }
            $dependencyHost = if ($Result.Contains('dependencyHost')) { Normalize-OpenPathRuntimeDependencyHost -Value $Result['dependencyHost'] } else { '' }
            $ready = $false
            if ($anchorHost -and $dependencyHost) {
                $snapshot = Get-NativeHostRuntimeDependencySnapshot
                $entryState = Get-NativeHostRuntimeDependencyEntryState -Snapshot $snapshot -AnchorHost $anchorHost -DependencyHost $dependencyHost
                $ready = [bool]$entryState.ready
            }
            $Result['ready'] = $ready
            $Result['runtimeDependencyState'] = if ($ready) { 'ready' } else { 'pending' }
        }
    }
    return $Result
}

function Get-NativeHostRuntimeDependencyPolicyContext {
    <#
    .SYNOPSIS
    Returns the process-cached runtime dependency validation sets for a message batch.
    .DESCRIPTION
    The protected-host catalog and whitelist set are expensive to rebuild per request. The
    cache key is derived from the staged whitelist mirror and native state file metadata, so
    a staged policy change invalidates it. This benefits the blocking per-message path today
    and the persistent native host of Phase 2C.
    #>
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Sections,
        [AllowNull()][PSCustomObject]$State = $null
    )

    $fingerprintParts = @()
    foreach ($pathVariable in @('WhitelistPath', 'StatePath')) {
        $pathValue = ''
        $variable = Get-Variable -Name $pathVariable -Scope Script -ErrorAction SilentlyContinue
        if ($variable -and $variable.Value) { $pathValue = [string]$variable.Value }
        if (-not $pathValue) { continue }

        $item = Get-Item -LiteralPath $pathValue -ErrorAction SilentlyContinue
        if ($item) {
            $fingerprintParts += ('{0}|{1}|{2}' -f $pathValue, $item.LastWriteTimeUtc.Ticks, $item.Length)
        }
        else {
            $fingerprintParts += "$pathValue|missing"
        }
    }
    $cacheKey = ($fingerprintParts -join '#')
    if (-not $cacheKey) { $cacheKey = 'runtime-dependency-policy-no-inputs' }

    return (Get-OpenPathRuntimeDependencyPolicyContext `
            -CacheKey $cacheKey `
            -WhitelistedDomains @($Sections.Whitelist) `
            -BlockedSubdomains @($Sections.BlockedSubdomains) `
            -State $State)
}

function Resolve-NativeHostLocalRuntimeDependencyCandidate {
    <#
    .SYNOPSIS
    Evaluates a dependency candidate message against the current whitelist and state to determine its validity.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections,

        [switch]$SkipOverlayCheck
    )

    $context = Get-NativeHostRuntimeDependencyPolicyContext -Sections $Sections -State $State
    return (Test-OpenPathRuntimeDependencyCandidate `
            -Message $Message `
            -WhitelistedDomains @($Sections.Whitelist) `
            -BlockedSubdomains @($Sections.BlockedSubdomains) `
            -State $State `
            -SkipOverlayCheck:$SkipOverlayCheck `
            -WhitelistSet $context.WhitelistSet `
            -ProtectedHosts $context.ProtectedHosts `
            -BlockedSubdomainSet $context.BlockedSubdomainSet)
}

function Get-NativeHostRuntimeDependencyMode {
    <#
    .SYNOPSIS
    Returns 'blocking' (default, unchanged behavior), 'enqueue', or 'invalid' for an unsupported mode value.
    #>
    param([AllowNull()][object]$Message)

    if ($null -eq $Message -or -not $Message.PSObject.Properties['mode'] -or -not $Message.mode) {
        return 'blocking'
    }

    $mode = ([string]$Message.mode).Trim().ToLowerInvariant()
    switch ($mode) {
        '' { return 'blocking' }
        'blocking' { return 'blocking' }
        'enqueue' { return 'enqueue' }
        default { return 'invalid' }
    }
}

function Send-NativeHostRuntimeDependencyEnqueueTrigger {
    <#
    .SYNOPSIS
    Fire-and-forget fallback trigger for enqueue-mode requests when the resident worker is not fresh.
    .DESCRIPTION
    The resident worker watches the queue and applies enqueue-mode batches without a
    scheduled-task hop. When its heartbeat and busy mark are both stale, the scheduled
    apply task is nudged so the batch is still applied without making the caller wait.
    #>
    param()

    try {
        if (Test-NativeHostRuntimeDependencyWorkerFresh -MaxAgeSeconds 10 -BusyMaxAgeSeconds 120) {
            return $false
        }
        $taskName = if (
            (Get-Variable -Name RuntimeDependencyTaskName -Scope Script -ErrorAction SilentlyContinue) -and
            -not [string]::IsNullOrWhiteSpace($script:RuntimeDependencyTaskName)
        ) {
            [string]$script:RuntimeDependencyTaskName
        }
        else {
            'OpenPath-RuntimeDependencyApply'
        }
        $runner = Get-NativeHostTaskRunner
        $runResult = & $runner.RunTask $taskName
        return ($runResult.success -eq $true)
    }
    catch {
        Write-NativeHostStageLog -Stage 'enqueue-trigger-failed' -Fields @{ error = [string]$_ }
        return $false
    }
}

function Invoke-NativeHostLocalRuntimeDependencyAction {
    <#
    .SYNOPSIS
    Queues a single runtime dependency request and triggers the update task, waiting for the dependency to be applied.
    .DESCRIPTION
    Without a `mode` field the historical blocking behavior is unchanged. `mode: 'enqueue'`
    validates and queues the request and answers immediately with the per-entry state.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $mode = Get-NativeHostRuntimeDependencyMode -Message $Message
    if ($mode -eq 'invalid') {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'Unsupported runtime dependency mode' }
    }
    if ($mode -eq 'enqueue') {
        return (Invoke-NativeHostLocalRuntimeDependencyEnqueueAction -Message $Message -State $State -Sections $Sections)
    }

    $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $Message -State $State -Sections $Sections
    if ($candidate.Valid -ne $true) {
        return (Add-NativeHostRuntimeDependencyReadinessToResult -Result $candidate.Result)
    }

    $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $requestPath = Write-OpenPathRuntimeDependencyQueueRequest `
        -AnchorHost $candidate.AnchorHost `
        -DependencyHost $candidate.DependencyHost `
        -RequestType $candidate.RequestType
    $queueWriteStopwatch.Stop()
    Write-NativeHostStageLog -Stage 'queue-written' `
        -Domains @($candidate.DependencyHost) `
        -ElapsedMs $queueWriteStopwatch.ElapsedMilliseconds `
        -Fields @{ anchorHost = $candidate.AnchorHost; requestType = $candidate.RequestType; request = $requestPath }

    $updateResult = Invoke-UpdateTask `
        -RuntimeDependencyDomains @($candidate.DependencyHost) `
        -RuntimeDependencyRequestPath $requestPath `
        -TimeoutSeconds 14
    Write-NativeHostStageLog -Stage 'readiness-observed' `
        -Domains @($candidate.DependencyHost) `
        -Fields @{
            ready            = [bool]($updateResult.success -eq $true)
            worker           = if ($updateResult.ContainsKey('runtimeDependencyWorker')) { [bool]$updateResult.runtimeDependencyWorker } else { $false }
            updateTriggerMs  = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            updateWaitMs     = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            updateTaskName   = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        }
    if ($updateResult.success -ne $true) {
        return @{
            success = $false
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            runtimeDependencyState = 'error'
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            runtimeDependencyWorker = if ($updateResult.ContainsKey('runtimeDependencyWorker')) { [bool]$updateResult.runtimeDependencyWorker } else { $false }
            updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
            error = $updateResult.error
        }
    }

    return @{
        success = $true
        action = $script:OpenPathRuntimeDependencyActionAllowLocal
        anchorHost = $candidate.AnchorHost
        dependencyHost = $candidate.DependencyHost
        requestType = $candidate.RequestType
        queued = $true
        ready = $true
        runtimeDependencyState = 'ready'
        requestPath = $requestPath
        queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
        updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        runtimeDependencyWorker = if ($updateResult.ContainsKey('runtimeDependencyWorker')) { [bool]$updateResult.runtimeDependencyWorker } else { $false }
        updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
    }
}

function Invoke-NativeHostLocalRuntimeDependencyEnqueueAction {
    <#
    .SYNOPSIS
    Non-blocking allow: validates and queues one dependency, answering immediately with its per-entry state.
    .DESCRIPTION
    `mode: 'enqueue'` returns as soon as the request is written (or immediately as `ready`
    when the dependency is already applied) instead of waiting for the DNS reload. The
    resident worker applies the queued batch; the scheduled apply task is nudged only when
    the worker heartbeat and busy mark are both stale.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $Message -State $State -Sections $Sections -SkipOverlayCheck
    if ($candidate.Valid -ne $true) {
        return (Add-NativeHostRuntimeDependencyReadinessToResult -Result $candidate.Result)
    }

    $snapshot = Get-NativeHostRuntimeDependencySnapshot
    $entryState = Get-NativeHostRuntimeDependencyEntryState -Snapshot $snapshot -AnchorHost $candidate.AnchorHost -DependencyHost $candidate.DependencyHost
    if ($entryState.ready) {
        return @{
            success = $true
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $false
            ready = $true
            runtimeDependencyState = 'ready'
            mode = 'enqueue'
            source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
        }
    }

    $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $requestPath = Write-OpenPathRuntimeDependencyQueueRequest `
        -AnchorHost $candidate.AnchorHost `
        -DependencyHost $candidate.DependencyHost `
        -RequestType $candidate.RequestType
    $queueWriteStopwatch.Stop()
    $workerTriggered = Send-NativeHostRuntimeDependencyEnqueueTrigger
    Write-NativeHostStageLog -Stage 'queue-written' `
        -Domains @($candidate.DependencyHost) `
        -ElapsedMs $queueWriteStopwatch.ElapsedMilliseconds `
        -Fields @{ anchorHost = $candidate.AnchorHost; requestType = $candidate.RequestType; request = $requestPath; mode = 'enqueue'; workerTriggered = [bool]$workerTriggered }

    return @{
        success = $true
        action = $script:OpenPathRuntimeDependencyActionAllowLocal
        anchorHost = $candidate.AnchorHost
        dependencyHost = $candidate.DependencyHost
        requestType = $candidate.RequestType
        queued = $true
        ready = $false
        runtimeDependencyState = 'pending'
        mode = 'enqueue'
        requestPath = $requestPath
        queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
        workerTriggered = [bool]$workerTriggered
        source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
    }
}

function Invoke-NativeHostLocalRuntimeDependencyBatchEnqueueAction {
    <#
    .SYNOPSIS
    Non-blocking batch allow: validates and queues every entry, answering per-entry states immediately.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    # `$Message.entries` on a single-pair message yields `$null`; `@($null)` is a
    # one-element array and would wrongly route the message into the batch branch.
    $entries = @($Message.entries | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0) {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch; error = 'Invalid runtime dependency batch payload'; results = @() }
    }

    $results = @()
    $queuedResults = @()
    $snapshot = $null
    $pairStateCache = @{}

    foreach ($entry in @($entries | Select-Object -First $script:OpenPathRuntimeDependencyBatchMaxEntries)) {
        $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $entry -State $State -Sections $Sections -SkipOverlayCheck
        if ($candidate.Valid -ne $true) {
            $results += (Add-NativeHostRuntimeDependencyReadinessToResult -Result $candidate.Result)
            continue
        }

        if ($null -eq $snapshot) {
            $snapshot = Get-NativeHostRuntimeDependencySnapshot
        }
        $pairKey = "$($candidate.AnchorHost)|$($candidate.DependencyHost)"
        if (-not $pairStateCache.ContainsKey($pairKey)) {
            $pairStateCache[$pairKey] = Get-NativeHostRuntimeDependencyEntryState -Snapshot $snapshot -AnchorHost $candidate.AnchorHost -DependencyHost $candidate.DependencyHost
        }
        $entryState = $pairStateCache[$pairKey]

        if ($entryState.ready) {
            $results += @{
                success = $true
                action = $script:OpenPathRuntimeDependencyActionAllowLocal
                anchorHost = $candidate.AnchorHost
                dependencyHost = $candidate.DependencyHost
                requestType = $candidate.RequestType
                queued = $false
                ready = $true
                runtimeDependencyState = 'ready'
                source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
            }
            continue
        }

        $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $requestPath = Write-OpenPathRuntimeDependencyQueueRequest `
            -AnchorHost $candidate.AnchorHost `
            -DependencyHost $candidate.DependencyHost `
            -RequestType $candidate.RequestType
        $queueWriteStopwatch.Stop()
        $result = @{
            success = $true
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            ready = $false
            runtimeDependencyState = 'pending'
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
        }
        $results += $result
        $queuedResults += $result
    }

    if ($entries.Count -gt $script:OpenPathRuntimeDependencyBatchMaxEntries) {
        $results += @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'Runtime dependency batch limit exceeded' }
    }

    $workerTriggered = $false
    if ($queuedResults.Count -gt 0) {
        $workerTriggered = Send-NativeHostRuntimeDependencyEnqueueTrigger
        foreach ($result in $queuedResults) {
            $result['workerTriggered'] = [bool]$workerTriggered
        }
        Write-NativeHostStageLog -Stage 'queue-written' `
            -Domains @($queuedResults | ForEach-Object { $_.dependencyHost }) `
            -ElapsedMs ([int](@($queuedResults | ForEach-Object { if ($_.ContainsKey('queueWriteMs')) { [int]$_.queueWriteMs } else { 0 } } | Measure-Object -Sum).Sum)) `
            -Fields @{ count = $queuedResults.Count; mode = 'enqueue'; workerTriggered = [bool]$workerTriggered }
    }

    $failedResults = @($results | Where-Object { $_.success -ne $true })
    return @{
        success = ($failedResults.Count -eq 0)
        action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch
        mode = 'enqueue'
        count = $results.Count
        queuedCount = $queuedResults.Count
        workerTriggered = [bool]$workerTriggered
        results = $results
    }
}

function Invoke-NativeHostLocalRuntimeDependencyBatchAction {
    <#
    .SYNOPSIS
    Queues multiple runtime dependency requests from a batch message and triggers a single update task for all of them.
    .DESCRIPTION
    Without a `mode` field the historical blocking behavior is unchanged. `mode: 'enqueue'`
    validates and queues every entry and answers per-entry states immediately.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $mode = Get-NativeHostRuntimeDependencyMode -Message $Message
    if ($mode -eq 'invalid') {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch; error = 'Unsupported runtime dependency mode' }
    }
    if ($mode -eq 'enqueue') {
        return (Invoke-NativeHostLocalRuntimeDependencyBatchEnqueueAction -Message $Message -State $State -Sections $Sections)
    }

    # `$Message.entries` on a single-pair message yields `$null`; `@($null)` is a
    # one-element array and would wrongly route the message into the batch branch.
    $entries = @($Message.entries | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0) {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch; error = 'Invalid runtime dependency batch payload'; results = @() }
    }

    $results = @()
    $queuedResults = @()
    $queuedDependencyHosts = @()
    $updateResult = $null

    foreach ($entry in @($entries | Select-Object -First $script:OpenPathRuntimeDependencyBatchMaxEntries)) {
        $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $entry -State $State -Sections $Sections
        if ($candidate.Valid -ne $true) {
            $results += (Add-NativeHostRuntimeDependencyReadinessToResult -Result $candidate.Result)
            continue
        }

        $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $requestPath = Write-OpenPathRuntimeDependencyQueueRequest `
            -AnchorHost $candidate.AnchorHost `
            -DependencyHost $candidate.DependencyHost `
            -RequestType $candidate.RequestType
        $queueWriteStopwatch.Stop()
        $result = @{
            success = $true
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
        }
        $results += $result
        $queuedResults += $result
        $queuedDependencyHosts += $candidate.DependencyHost
    }

    if ($entries.Count -gt $script:OpenPathRuntimeDependencyBatchMaxEntries) {
        $results += @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'Runtime dependency batch limit exceeded' }
    }

    if ($queuedDependencyHosts.Count -gt 0) {
        $queuedDependencyHosts = @($queuedDependencyHosts | Sort-Object -Unique)
        Write-NativeHostStageLog -Stage 'queue-written' `
            -Domains $queuedDependencyHosts `
            -ElapsedMs ([int](@($queuedResults | ForEach-Object { if ($_.ContainsKey('queueWriteMs')) { [int]$_.queueWriteMs } else { 0 } } | Measure-Object -Sum).Sum)) `
            -Fields @{ count = $queuedResults.Count }
        $updateResult = Invoke-UpdateTask `
            -RuntimeDependencyDomains $queuedDependencyHosts `
            -TimeoutSeconds 14
        Write-NativeHostStageLog -Stage 'readiness-observed' `
            -Domains $queuedDependencyHosts `
            -Fields @{
                ready           = [bool]($updateResult.success -eq $true)
                worker          = if ($updateResult.ContainsKey('runtimeDependencyWorker')) { [bool]$updateResult.runtimeDependencyWorker } else { $false }
                updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
                updateWaitMs    = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
                updateTaskName  = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
            }
        if ($updateResult.success -ne $true) {
            foreach ($result in $queuedResults) {
                $result.success = $false
                $result.runtimeDependencyState = 'error'
                $result.error = $updateResult.error
            }
        }
        else {
            foreach ($result in $queuedResults) {
                $result.ready = $true
                $result.runtimeDependencyState = 'ready'
            }
        }
        foreach ($result in $queuedResults) {
            $result.updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            $result.updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            $result.updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            $result.runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            $result.runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            $result.runtimeDependencyWorker = if ($updateResult.ContainsKey('runtimeDependencyWorker')) { [bool]$updateResult.runtimeDependencyWorker } else { $false }
            $result.updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        }
    }

    $failedResults = @($results | Where-Object { $_.success -ne $true })
    return @{
        success = ($failedResults.Count -eq 0)
        action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch
        count = $results.Count
        queuedCount = $queuedResults.Count
        queueWriteMs = [int](@($queuedResults | ForEach-Object { if ($_.ContainsKey('queueWriteMs')) { [int]$_.queueWriteMs } else { 0 } } | Measure-Object -Sum).Sum)
        updateTriggerMs = if ($updateResult -and $updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult -and $updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult -and $updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        updateTaskName = if ($updateResult -and $updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        results = $results
    }
}

function Invoke-NativeHostLocalRuntimeDependencyCheckAction {
    <#
    .SYNOPSIS
    Reports whether previously learned runtime dependencies are currently operative in the local DNS path.
    .DESCRIPTION
    Accepts either the historical single pair (`anchorHost`/`dependencyHost`) or a batch
    (`entries: [{anchorHost, dependencyHost}]`). The overlay is read once per message and
    every answer uses the per-entry readiness rule.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message
    )

    if (Test-OpenPathRuntimeDependencySensitiveField -Message $Message) {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionCheckLocal; error = 'Sensitive fields are not accepted' }
    }

    # `$Message.entries` on a single-pair message yields `$null`; `@($null)` is a
    # one-element array and would wrongly route the message into the batch branch.
    $entries = @($Message.entries | Where-Object { $null -ne $_ })
    if ($entries.Count -gt 0) {
        $snapshot = Get-NativeHostRuntimeDependencySnapshot
        $results = @()
        foreach ($entry in @($entries | Select-Object -First $script:OpenPathRuntimeDependencyBatchMaxEntries)) {
            $anchorHost = Normalize-OpenPathRuntimeDependencyHost -Value $entry.anchorHost
            $dependencyHost = Normalize-OpenPathRuntimeDependencyHost -Value $entry.dependencyHost
            if (-not $anchorHost -or -not $dependencyHost) {
                $results += @{ success = $false; action = $script:OpenPathRuntimeDependencyActionCheckLocal; error = 'Invalid runtime dependency payload' }
                continue
            }
            $entryState = Get-NativeHostRuntimeDependencyEntryState -Snapshot $snapshot -AnchorHost $anchorHost -DependencyHost $dependencyHost
            Update-NativeHostDependencyReadyState -AnchorHost $anchorHost -DependencyHost $dependencyHost -Ready ([bool]$entryState.ready) | Out-Null
            $result = @{
                success = $true
                action = $script:OpenPathRuntimeDependencyActionCheckLocal
                anchorHost = $anchorHost
                dependencyHost = $dependencyHost
                ready = [bool]$entryState.ready
                runtimeDependencyState = [string]$entryState.runtimeDependencyState
            }
            if ($entryState.expiresAt) { $result['expiresAt'] = [string]$entryState.expiresAt }
            $results += $result
        }
        if ($entries.Count -gt $script:OpenPathRuntimeDependencyBatchMaxEntries) {
            $results += @{ success = $false; action = $script:OpenPathRuntimeDependencyActionCheckLocal; error = 'Runtime dependency batch limit exceeded' }
        }

        $failedResults = @($results | Where-Object { $_.success -ne $true })
        return @{
            success = ($failedResults.Count -eq 0)
            action = $script:OpenPathRuntimeDependencyActionCheckLocal
            count = $results.Count
            results = $results
        }
    }

    $anchorHost = Normalize-OpenPathRuntimeDependencyHost -Value $Message.anchorHost
    $dependencyHost = Normalize-OpenPathRuntimeDependencyHost -Value $Message.dependencyHost
    if (-not $anchorHost -or -not $dependencyHost) {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionCheckLocal; error = 'Invalid runtime dependency payload' }
    }

    $snapshot = Get-NativeHostRuntimeDependencySnapshot
    $entryState = Get-NativeHostRuntimeDependencyEntryState -Snapshot $snapshot -AnchorHost $anchorHost -DependencyHost $dependencyHost
    Update-NativeHostDependencyReadyState -AnchorHost $anchorHost -DependencyHost $dependencyHost -Ready ([bool]$entryState.ready) | Out-Null
    $response = @{
        success = $true
        action = $script:OpenPathRuntimeDependencyActionCheckLocal
        anchorHost = $anchorHost
        dependencyHost = $dependencyHost
        ready = [bool]$entryState.ready
        runtimeDependencyState = [string]$entryState.runtimeDependencyState
    }
    if ($entryState.expiresAt) {
        $response['expiresAt'] = [string]$entryState.expiresAt
    }
    return $response
}

function Invoke-NativeHostSharedUpdateTrigger {
    <#
    .SYNOPSIS
    Coordinates update triggering so only one caller triggers the task while others wait on the same result.
    .DESCRIPTION
    Acquires a non-blocking mutex to elect one caller as the trigger. The elected caller runs TriggerAction;
    all other concurrent callers run WaitAction instead.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$TriggerAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$WaitAction
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\OpenPathNativeWhitelistUpdateTrigger')
        try {
            $lockAcquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if ($lockAcquired) {
            $triggerResult = & $TriggerAction
            if (
                $triggerResult -is [System.Collections.IDictionary] -and
                $triggerResult.ContainsKey('success')
            ) {
                return $triggerResult
            }
        }

        return (& $WaitAction)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # Ignore if mutex ownership was already released by the runtime.
            }
        }

        if ($mutex) {
            $mutex.Dispose()
        }
    }
}

function Invoke-UpdateTask {
    <#
    .SYNOPSIS
    Triggers the appropriate scheduled update task and waits for the expected domains and overlay entries to appear.
    .DESCRIPTION
    When RuntimeDependencyDomains are provided, prefers the runtime dependency fast-apply task.
    Uses shared update trigger coordination to avoid duplicate task triggers from concurrent callers.
    #>
    param(
        [string[]]$Domains = @(),
        [string[]]$RuntimeDependencyDomains = @(),
        [AllowNull()][string]$RuntimeDependencyRequestPath = '',
        [int]$TimeoutSeconds = 45
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $hasRuntimeDependencyWait = @($RuntimeDependencyDomains).Count -gt 0
        if ((-not $hasRuntimeDependencyWait) -and (Test-NativeWhitelistContainsDomains -Domains $Domains)) {
            $result = @{
                success = $true
                action = 'update-whitelist'
                message = 'OpenPath update task triggered'
                domains = @($Domains)
            }
        }
        else {
            $workerFresh = $false
            if ($hasRuntimeDependencyWait) {
                try {
                    $workerFresh = [bool](Test-NativeHostRuntimeDependencyWorkerFresh -MaxAgeSeconds 10)
                }
                catch {
                    $workerFresh = $false
                }
            }

            if ($workerFresh) {
                # The resident worker is alive: skip the schtasks cold start and wait
                # directly for the overlay generation marker at a short poll interval.
                Write-NativeHostStageLog -Stage 'worker-fresh' -Domains $RuntimeDependencyDomains -Fields @{ skippedTaskTrigger = 'true' }
                $workerWaitRunner = Get-NativeHostTaskRunner
                $workerWaitResult = & $workerWaitRunner.WaitFor 'OpenPath-RuntimeDependencyWorker' {
                    $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                    $runtimeDependencyReady = Test-NativeHostRuntimeDependencyReady `
                        -RequestPath $RuntimeDependencyRequestPath `
                        -Domains $RuntimeDependencyDomains
                    return ($whitelistReady -and $runtimeDependencyReady)
                } $TimeoutSeconds 100

                $workerWaitMs = if ($workerWaitResult.ContainsKey('elapsedMs')) { [int]$workerWaitResult.elapsedMs } else { 0 }
                if ($workerWaitResult.success -ne $true) {
                    $result = @{
                        success = $false
                        action = 'update-whitelist'
                        error = "Runtime dependency worker did not apply expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')"
                        domains = @($Domains)
                        runtimeDependencyFastPath = $true
                        runtimeDependencyWorker = $true
                        runtimeDependencyFallback = $false
                        updateTaskName = 'OpenPath-RuntimeDependencyWorker'
                        updateTriggerMs = 0
                        updateWaitMs = $workerWaitMs
                    }
                }
                else {
                    $result = @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath runtime dependency worker applied expected domains'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $true
                        runtimeDependencyWorker = $true
                        runtimeDependencyFallback = $false
                        updateTaskName = 'OpenPath-RuntimeDependencyWorker'
                        updateTriggerMs = 0
                        updateWaitMs = $workerWaitMs
                    }
                }
            }
            else {
                $triggeredTaskName = if (
                $hasRuntimeDependencyWait -and
                (Get-Variable -Name RuntimeDependencyTaskName -Scope Script -ErrorAction SilentlyContinue) -and
                -not [string]::IsNullOrWhiteSpace($script:RuntimeDependencyTaskName)
            ) {
                [string]$script:RuntimeDependencyTaskName
            }
            else {
                [string]$script:UpdateTaskName
            }
            $triggerState = @{
                TaskName = $triggeredTaskName
                Fallback = $false
                TriggerMs = 0
            }
            $result = Invoke-NativeHostSharedUpdateTrigger `
                -TriggerAction {
                    $taskResult = Invoke-OpenPathScheduledTask `
                        -TaskName $triggerState['TaskName'] `
                        -FallbackTaskName $script:UpdateTaskName `
                        -ShouldFallback $hasRuntimeDependencyWait `
                        -Runner (Get-NativeHostTaskRunner) `
                        -TimeoutSeconds $TimeoutSeconds `
                        -WaitCondition {
                            $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                            $runtimeDependencyReady = Test-NativeHostRuntimeDependencyReady `
                                -RequestPath $RuntimeDependencyRequestPath `
                                -Domains $RuntimeDependencyDomains
                            return ($whitelistReady -and $runtimeDependencyReady)
                        }
                    $triggerState['Fallback'] = [bool]$taskResult.fallback
                    $triggerState['TaskName'] = [string]$taskResult.taskName
                    $triggerState['TriggerMs'] = [int]$taskResult.triggerMs

                    if ($taskResult.success -ne $true) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = if ($taskResult.ContainsKey('timedOut') -and $taskResult.timedOut) { "OpenPath update task did not write expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')" } elseif ($taskResult.ContainsKey('error')) { [string]$taskResult.error } else { 'Scheduled task update failed' }
                            domains = @($Domains)
                            runtimeDependencyFastPath = $hasRuntimeDependencyWait
                            runtimeDependencyFallback = [bool]$taskResult.fallback
                            updateTaskName = [string]$taskResult.taskName
                            updateTriggerMs = [int]$taskResult.triggerMs
                            updateWaitMs = [int]$taskResult.waitMs
                        }
                    }

                    $taskRunnerResult = @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task wrote expected domains'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$taskResult.fallback
                        updateTaskName = [string]$taskResult.taskName
                        updateTriggerMs = [int]$taskResult.triggerMs
                        updateWaitMs = [int]$taskResult.waitMs
                    }
                    return $taskRunnerResult
                } `
                -WaitAction {
                    $waitRunner = Get-NativeHostTaskRunner
                    $waitResult = & $waitRunner.WaitFor $triggerState['TaskName'] {
                        $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                        $runtimeDependencyReady = Test-NativeHostRuntimeDependencyReady `
                            -RequestPath $RuntimeDependencyRequestPath `
                            -Domains $RuntimeDependencyDomains
                        return ($whitelistReady -and $runtimeDependencyReady)
                    } $TimeoutSeconds 100

                    if ($waitResult.success -ne $true) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = "OpenPath update task did not write expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')"
                            domains = @($Domains)
                            runtimeDependencyFastPath = $hasRuntimeDependencyWait
                            runtimeDependencyFallback = [bool]$triggerState['Fallback']
                            updateTaskName = [string]$triggerState['TaskName']
                            updateTriggerMs = [int]$triggerState['TriggerMs']
                            updateWaitMs = if ($waitResult.ContainsKey('elapsedMs')) { [int]$waitResult.elapsedMs } else { 0 }
                        }
                    }

                    return @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task wrote expected domains'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$triggerState['Fallback']
                        updateTaskName = [string]$triggerState['TaskName']
                        updateTriggerMs = [int]$triggerState['TriggerMs']
                        updateWaitMs = if ($waitResult.ContainsKey('elapsedMs')) { [int]$waitResult.elapsedMs } else { 0 }
                    }
                }
            }
        }
    }
    catch {
        $result = @{
            success = $false
            action = 'update-whitelist'
            error = [string]$_
            domains = @($Domains)
        }
    }

    $stopwatch.Stop()
    $logMessage = ''
    if ($result.ContainsKey('message')) {
        $logMessage = [string]$result.message
    }
    $logError = ''
    if ($result.ContainsKey('error')) {
        $logError = [string]$result.error
    }

    Write-NativeHostActionLog -Action 'update-whitelist' `
        -Domains $Domains `
        -Success ($result.success -eq $true) `
        -Message $logMessage `
        -ErrorMessage $logError `
        -ElapsedMs $stopwatch.ElapsedMilliseconds

    $result['elapsedMs'] = [int]$stopwatch.ElapsedMilliseconds
    return $result
}
