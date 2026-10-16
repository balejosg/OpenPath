# Phase 7 L1: update-contention analysis for the first-visit lane.
#
# The `update-contention` scenario starts the product update right before the
# visit so the dependency fast path contends with a real update cycle. These
# helpers are pure so the lane tests can execute them without a VM; the data
# comes from the persisted evidence only:
#   - openpath.log: update run boundaries (start/completed or stage summary),
#   - native-host.log diagnostics: the first retention and hold outcomes,
#   - the canary metrics: ready durations and outcome counts.
#
# The acceptance bound is: a dependency queued while an update is still in
# course becomes ready in <= 3 s (p95) with zero cancelled-budget holds.

function Get-OpenPathFirstVisitContentionField {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-OpenPathFirstVisitLogTimestampMs {
    <#
    .SYNOPSIS
    Parses the second-resolution log prefix (yyyy-MM-dd HH:mm:ss) into epoch ms.
    .DESCRIPTION
    The guest agent logs UTC wall-clock prefixes (the lab VMs run on UTC), and
    every consumer compares the result against epoch-ms values from the guest
    evidence (extension diagnostics `ts`, trigger evidence). AssumeUniversal
    keeps the frame correct regardless of the runner's local timezone; a local
    parse silently shifted every comparison by the runner offset (measured
    +2 h on the development host vs the UTC lane runner).
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Line = '')
    if (-not $Line) { return $null }
    $match = [regex]::Match([string]$Line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
    if (-not $match.Success) { return $null }
    try {
        # ps-culture-allow: the guest log prefix is a UTC wall-clock stamp; AssumeUniversal (not RoundtripKind) is the intended parse frame.
        $parsed = [datetimeoffset]::ParseExact(
            $match.Groups[1].Value,
            'yyyy-MM-dd HH:mm:ss',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
        return [long]$parsed.ToUnixTimeMilliseconds()
    }
    catch {
        return $null
    }
}

function Get-OpenPathFirstVisitUpdateRuns {
    <#
    .SYNOPSIS
    Update-cycle windows from the agent log.
    .DESCRIPTION
    A run starts at `=== Starting openpath update ===` and ends at any
    `OpenPath update completed` marker or at the Phase 7 stage summary line.
    A run that never logs an end (still running when the log was copied) keeps
    endMs = $null, which the overlap check treats as open-ended.
    #>
    [CmdletBinding()]
    param([AllowNull()][string[]]$OpenPathLines = @())

    $runs = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in @($OpenPathLines)) {
        $text = [string]$line
        $ts = Get-OpenPathFirstVisitLogTimestampMs -Line $text
        if ($text -match '=== Starting openpath update ===') {
            if ($current) { $runs.Add($current) | Out-Null }
            $current = if ($null -ne $ts) { [ordered]@{ startMs = [long]$ts; endMs = $null } } else { $null }
            continue
        }
        if ($current -and ($text -match 'OpenPath update completed' -or $text -match 'OpenPath update stages totalMs=')) {
            if ($null -ne $ts) { $current.endMs = [long]$ts }
            $runs.Add($current) | Out-Null
            $current = $null
        }
    }
    if ($current) { $runs.Add($current) | Out-Null }
    return @($runs.ToArray())
}

function ConvertFrom-OpenPathFirstVisitContentionDiagnostic {
    # Parses one `stage=extension-diagnostic {json}` line; $null for anything else.
    [CmdletBinding()]
    param([AllowNull()][string]$Line = '')
    if (-not $Line) { return $null }
    $marker = 'stage=extension-diagnostic '
    $index = $Line.IndexOf($marker)
    if ($index -lt 0) { return $null }
    try { return ($Line.Substring($index + $marker.Length) | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-OpenPathFirstVisitFirstRetentionMs {
    <#
    .SYNOPSIS
    Earliest dependency retention (enqueue) timestamp in the diagnostics.
    .DESCRIPTION
    Uses the first `hold` event ts; when no hold event was captured, falls back
    to the earliest `hold-outcome` ts minus its measured retention ms.
    #>
    [CmdletBinding()]
    param([AllowNull()][string[]]$DiagnosticLines = @())

    $first = $null
    foreach ($line in @($DiagnosticLines)) {
        $event = ConvertFrom-OpenPathFirstVisitContentionDiagnostic -Line ([string]$line)
        if (-not $event) { continue }
        $kind = [string](Get-OpenPathFirstVisitContentionField -InputObject $event -Name 'kind')
        $candidate = $null
        if ($kind -eq 'hold') {
            $ts = Get-OpenPathFirstVisitContentionField -InputObject $event -Name 'ts'
            if ($null -ne $ts) { $candidate = [long]$ts }
        }
        elseif ($kind -eq 'hold-outcome') {
            $ts = Get-OpenPathFirstVisitContentionField -InputObject $event -Name 'ts'
            $ms = Get-OpenPathFirstVisitContentionField -InputObject $event -Name 'ms'
            if ($null -ne $ts) {
                $duration = if ($null -ne $ms) { [int]$ms } else { 0 }
                $candidate = [long]$ts - [long]$duration
            }
        }
        if ($null -ne $candidate -and ($null -eq $first -or $candidate -lt $first)) { $first = $candidate }
    }
    return $first
}

function Get-OpenPathFirstVisitAcrylicRestarts {
    <#
    .SYNOPSIS
        Acrylic restart intervals from the agent log, paired per process.
    .DESCRIPTION
        Phase 8f F1/F5. A restart starts at `Restarting Acrylic service...` and
        ends at the next `Acrylic service restarted successfully` (or `Could not
        restart Acrylic service`) from the same PID. The Phase 8f reason line
        (`Acrylic restart reason=...`) attaches the product's reason when the
        log carries it; `Acrylic restart skipped ...` lines are not restarts.
        An unfinished interval (log cut mid-restart) is treated as ending at the
        log's last timestamp, so a later different-PID restart still overlaps it.
    #>
    [CmdletBinding()]
    param([AllowNull()][string[]]$OpenPathLines = @())

    $restarts = New-Object System.Collections.Generic.List[object]
    $lastMs = $null
    foreach ($line in @($OpenPathLines)) {
        $text = [string]$line
        $ts = Get-OpenPathFirstVisitLogTimestampMs -Line $text
        if ($null -ne $ts) { $lastMs = [long]$ts }
        $pidMatch = [regex]::Match($text, '\[PID:(\d+)\]')
        $pid = if ($pidMatch.Success) { [int]$pidMatch.Groups[1].Value } else { 0 }

        if ($text -match 'Restarting Acrylic service\.\.\.' -and $null -ne $ts) {
            $restarts.Add([ordered]@{
                    startMs  = [long]$ts
                    endMs    = $null
                    failed   = $false
                    pid      = $pid
                    reason   = ''
                    startLine = $text
                }) | Out-Null
            continue
        }
        if ($text -match 'Acrylic service restarted successfully' -or $text -match 'Could not restart Acrylic service') {
            $failed = ($text -match 'Could not restart Acrylic service')
            for ($index = $restarts.Count - 1; $index -ge 0; $index--) {
                if ($null -eq $restarts[$index].endMs -and [int]$restarts[$index].pid -eq $pid) {
                    $restarts[$index].endMs = $ts
                    $restarts[$index].failed = $failed
                    break
                }
            }
            continue
        }
        if ($text -match 'Acrylic restart reason=' -and $null -ne $ts) {
            $reasonMatch = [regex]::Match($text, 'Acrylic restart reason=(?<reason>\S+) caller=\S+ pid=(?<pid>\d+)')
            if ($reasonMatch.Success) {
                $reasonPid = [int]$reasonMatch.Groups['pid'].Value
                for ($index = $restarts.Count - 1; $index -ge 0; $index--) {
                    if ([int]$restarts[$index].pid -eq $reasonPid) {
                        $restarts[$index].reason = [string]$reasonMatch.Groups['reason'].Value
                        break
                    }
                }
            }
        }
    }

    if ($null -eq $lastMs) { $lastMs = 0 }
    foreach ($restart in $restarts) {
        if ($null -eq $restart.endMs) { $restart.endMs = [long]$lastMs }
    }
    return @($restarts.ToArray())
}

function Get-OpenPathFirstVisitAcrylicRestartInvariants {
    <#
    .SYNOPSIS
        Phase 8f F5 invariants over the update-contention evidence.
    .DESCRIPTION
        (i) `acrylic-restart-unchanged`: 0 restarts inside an Update cycle whose
            hosts file and INI were both unchanged (the cycle shows the
            "effective content unchanged" / "configuration unchanged" markers,
            or it never rendered either file). Restarts of ANY process inside
            the cycle window count.
        (ii) `acrylic-restart-overlap`: 0 overlapping restart intervals between
            distinct PIDs (the pre-8f serialization defect).
        (iii) `acrylic-restart-near-ready`: 0 restarts within +/-2 s of a
            `hold-outcome ... "outcome":"ready"` event unless the restart is
            identified as `reason=content-changed` (Phase 8f F4: a content
            change is the designed way to load new content and the worker's
            ready legitimately follows its own restart; legacy logs without a
            reason line have no exemption).
        The Update cycle windows come from Get-OpenPathFirstVisitUpdateRuns and
        the ready events from the extension diagnostics (`ts` is epoch ms).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$OpenPathLines = @(),
        [AllowNull()][string[]]$DiagnosticLines = @(),
        [int]$ReadyProximityMs = 2000
    )

    $restarts = @(Get-OpenPathFirstVisitAcrylicRestarts -OpenPathLines $OpenPathLines)
    $runs = @(Get-OpenPathFirstVisitUpdateRuns -OpenPathLines $OpenPathLines)
    $reasons = New-Object System.Collections.Generic.List[string]
    $violations = New-Object System.Collections.Generic.List[object]

    # (i) restarts inside unchanged Update cycles
    $unchangedCycleCount = 0
    $unchangedCycleRestarts = 0
    foreach ($run in $runs) {
        # Only completed cycles are evaluated: a run that never logged its end
        # (still in course when the log was copied, or an aborted start) has
        # unknown content status, and letting it swallow every later cycle
        # would misattribute restarts.
        if ($null -eq $run.endMs) { continue }
        $cycleStart = [long]$run.startMs
        $cycleEnd = [long]$run.endMs
        $hostsUnchanged = $false
        $hostsRendered = $false
        $iniUnchanged = $false
        $iniWritten = $false
        foreach ($line in @($OpenPathLines)) {
            $ts = Get-OpenPathFirstVisitLogTimestampMs -Line ([string]$line)
            if ($null -eq $ts -or [long]$ts -lt $cycleStart -or [long]$ts -gt $cycleEnd) { continue }
            $text = [string]$line
            if ($text -match 'AcrylicHosts\.txt effective content unchanged; skipping rewrite' -or $text -match 'AcrylicHosts\.txt unchanged; skipping rewrite') { $hostsUnchanged = $true }
            if ($text -match 'Generating AcrylicHosts\.txt with') { $hostsRendered = $true }
            if ($text -match 'Acrylic configuration unchanged; skipping rewrite') { $iniUnchanged = $true }
            if ($text -match 'Acrylic configuration updated') { $iniWritten = $true }
        }
        $contentUnchanged = ((-not $hostsRendered -or $hostsUnchanged) -and (-not $iniWritten -or $iniUnchanged))
        if (-not $contentUnchanged) { continue }
        $unchangedCycleCount += 1
        foreach ($restart in $restarts) {
            # Phase 8f F4: a restart the log identifies as a real content change
            # is a justified loader (typically the fast apply serving the queue
            # while the cycle's own render found the file already updated);
            # legacy logs without a reason line have no exemption.
            if ([string]$restart.reason -eq 'content-changed') { continue }
            if ([long]$restart.startMs -ge $cycleStart -and [long]$restart.startMs -le $cycleEnd) {
                $unchangedCycleRestarts += 1
                $violations.Add([pscustomobject]@{
                        code = 'acrylic-restart-unchanged'
                        detail = "restart pid=$($restart.pid) at=$($restart.startMs) in unchanged cycle start=$cycleStart end=$cycleEnd reason='$($restart.reason)'"
                    }) | Out-Null
            }
        }
    }
    if ($unchangedCycleRestarts -gt 0) { $reasons.Add('acrylic-restart-unchanged') | Out-Null }

    # (ii) overlapping restart intervals between distinct PIDs
    $overlapCount = 0
    for ($left = 0; $left -lt $restarts.Count; $left++) {
        for ($right = $left + 1; $right -lt $restarts.Count; $right++) {
            $a = $restarts[$left]
            $b = $restarts[$right]
            if ([int]$a.pid -eq [int]$b.pid) { continue }
            if ([long]$a.startMs -lt [long]$b.endMs -and [long]$b.startMs -lt [long]$a.endMs) {
                $overlapCount += 1
                $violations.Add([pscustomobject]@{
                        code = 'acrylic-restart-overlap'
                        detail = "pid=$($a.pid) [$($a.startMs),$($a.endMs)] overlaps pid=$($b.pid) [$($b.startMs),$($b.endMs)]"
                    }) | Out-Null
            }
        }
    }
    if ($overlapCount -gt 0) { $reasons.Add('acrylic-restart-overlap') | Out-Null }

    # (iii) restarts within +/-ReadyProximityMs of a ready event.
    # Phase 8f F4: a restart the log identifies as a real content change
    # (`reason=content-changed`) is the designed way to load new content; the
    # worker's stamp runs after that restart's window, so the ready it
    # publishes legitimately follows it. The invariant keeps its teeth against
    # restarts near a ready that are NOT identifiable as a content change
    # (legacy logs carry no reason line and therefore count).
    $readyTs = New-Object System.Collections.Generic.List[long]
    foreach ($line in @($DiagnosticLines)) {
        $text = [string]$line
        if ($text -notmatch '"outcome":"ready"') { continue }
        $tsMatch = [regex]::Match($text, '"ts"\s*:\s*(?<ts>\d{10,})')
        if ($tsMatch.Success) { $readyTs.Add([long]$tsMatch.Groups['ts'].Value) | Out-Null }
    }
    $nearReadyCount = 0
    $unjustifiedNearReadyCount = 0
    foreach ($restart in $restarts) {
        $restartReason = [string]$restart.reason
        foreach ($ready in $readyTs) {
            if ([long]$ready -ge ([long]$restart.startMs - $ReadyProximityMs) -and [long]$ready -le ([long]$restart.endMs + $ReadyProximityMs)) {
                $nearReadyCount += 1
                if ($restartReason -eq 'content-changed') { continue }
                $unjustifiedNearReadyCount += 1
                $violations.Add([pscustomobject]@{
                        code = 'acrylic-restart-near-ready'
                        detail = "ready ts=$ready within +/-${ReadyProximityMs}ms of unjustified restart pid=$($restart.pid) [$($restart.startMs),$($restart.endMs)] reason='$restartReason'"
                    }) | Out-Null
            }
        }
    }
    if ($unjustifiedNearReadyCount -gt 0) { $reasons.Add('acrylic-restart-near-ready') | Out-Null }

    return [ordered]@{
        restarts                  = @($restarts)
        restartCount              = $restarts.Count
        updateCycles              = $runs.Count
        unchangedCycles           = $unchangedCycleCount
        unchangedCycleRestarts    = $unchangedCycleRestarts
        overlapCount              = $overlapCount
        readyEvents               = $readyTs.Count
        nearReadyCount            = $nearReadyCount
        unjustifiedNearReadyCount = $unjustifiedNearReadyCount
        readyProximityMs          = $ReadyProximityMs
        reasons                   = @($reasons.ToArray())
        violations                = @($violations.ToArray())
    }
}

function Get-OpenPathFirstVisitUpdateContention {
    <#
    .SYNOPSIS
    Update-contention acceptance analysis for one scene.
    .DESCRIPTION
    Returns the update windows, whether an update run was still in course when
    the first retention arrived (the scenario precondition), and the retention
    budget counters (p95 <= 3 s, zero cancelled-budget) from the canary metrics.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$OpenPathLines = @(),
        [AllowNull()][string[]]$DiagnosticLines = @(),
        [AllowNull()][object]$CanaryMetrics = $null,
        # Phase 7 L1: the guest trigger step confirms the update was in course
        # before navigating the anchor. It is the authoritative precondition
        # evidence when the collected log tail no longer carries the run start.
        [AllowNull()][object]$TriggerEvidence = $null,
        [int]$MaxReadyP95Ms = 3000
    )

    $runs = Get-OpenPathFirstVisitUpdateRuns -OpenPathLines $OpenPathLines
    $firstRetention = Get-OpenPathFirstVisitFirstRetentionMs -DiagnosticLines $DiagnosticLines
    $inCourse = $false
    $activeStart = 0
    $activeEnd = 0
    if ($null -ne $firstRetention) {
        foreach ($run in $runs) {
            $start = [long]$run.startMs
            $end = if ($null -ne $run.endMs) { [long]$run.endMs } else { [long]::MaxValue }
            if ($start -le [long]$firstRetention -and [long]$firstRetention -le $end) {
                $inCourse = $true
                $activeStart = $start
                if ($null -ne $run.endMs) { $activeEnd = [long]$run.endMs }
                break
            }
        }
    }
    if (-not $inCourse -and $TriggerEvidence -and ([bool](Get-OpenPathFirstVisitContentionField -InputObject $TriggerEvidence -Name 'inCourse'))) {
        $inCourse = $true
        $runningStartMs = Get-OpenPathFirstVisitLogTimestampMs -Line ([string](Get-OpenPathFirstVisitContentionField -InputObject $TriggerEvidence -Name 'runningStart'))
        if ($null -ne $runningStartMs) { $activeStart = [long]$runningStartMs }
    }

    $holds = [int](Get-OpenPathFirstVisitContentionField -InputObject $CanaryMetrics -Name 'holds')
    $readyP95 = [int](Get-OpenPathFirstVisitContentionField -InputObject $CanaryMetrics -Name 'readyP95Ms')
    $readyMax = [int](Get-OpenPathFirstVisitContentionField -InputObject $CanaryMetrics -Name 'readyMaxMs')
    $readyCount = [int](Get-OpenPathFirstVisitContentionField -InputObject $CanaryMetrics -Name 'readyCount')
    $cancelledBudget = 0
    $outcomeCounts = Get-OpenPathFirstVisitContentionField -InputObject $CanaryMetrics -Name 'outcomeCounts'
    if ($outcomeCounts -is [System.Collections.IDictionary]) {
        foreach ($key in @($outcomeCounts.Keys)) {
            if ([string]$key -ne 'ready') { $cancelledBudget += [int]$outcomeCounts[$key] }
        }
    }
    elseif ($outcomeCounts) {
        foreach ($property in @($outcomeCounts.PSObject.Properties)) {
            if ([string]$property.Name -ne 'ready') { $cancelledBudget += [int]$property.Value }
        }
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($null -eq $firstRetention) { $reasons.Add('no-retention-observed') | Out-Null }
    elseif (-not $inCourse) { $reasons.Add('update-not-in-course-at-first-retention') | Out-Null }
    if ($holds -le 0) { $reasons.Add('no-holds-observed') | Out-Null }
    if ($cancelledBudget -gt 0) { $reasons.Add("holds-not-ready:$cancelledBudget") | Out-Null }
    if ($readyP95 -gt $MaxReadyP95Ms) { $reasons.Add("ready-p95-over-budget:$readyP95") | Out-Null }

    # Phase 8f F5: the restart invariants (see the function's doc) join the
    # verdict; the controller merges these three codes into productReasons so
    # the scene files as PRODUCT red even when the page waves pass.
    $restartInvariants = Get-OpenPathFirstVisitAcrylicRestartInvariants -OpenPathLines $OpenPathLines -DiagnosticLines $DiagnosticLines
    foreach ($restartReason in @($restartInvariants.reasons)) { $reasons.Add([string]$restartReason) | Out-Null }

    $passed = ($reasons.Count -eq 0)
    return [ordered]@{
        updateRuns          = @($runs)
        updateCount         = $runs.Count
        firstRetentionMs    = if ($null -ne $firstRetention) { [long]$firstRetention } else { 0 }
        updateInCourse      = $inCourse
        activeRunStartMs    = $activeStart
        activeRunEndMs      = $activeEnd
        holds               = $holds
        readyCount          = $readyCount
        readyP95Ms          = $readyP95
        readyMaxMs          = $readyMax
        cancelledBudget     = $cancelledBudget
        maxReadyP95Ms       = $MaxReadyP95Ms
        acrylicRestarts     = $restartInvariants
        verdict             = if ($passed) { 'CONTENTION-PASS' } else { 'CONTENTION-RED' }
        reasons             = @($reasons.ToArray())
    }
}

Export-ModuleMember -Function `
    Get-OpenPathFirstVisitContentionField, `
    Get-OpenPathFirstVisitLogTimestampMs, `
    Get-OpenPathFirstVisitUpdateRuns, `
    Get-OpenPathFirstVisitFirstRetentionMs, `
    Get-OpenPathFirstVisitAcrylicRestarts, `
    Get-OpenPathFirstVisitAcrylicRestartInvariants, `
    Get-OpenPathFirstVisitUpdateContention
