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
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Line = '')
    if (-not $Line) { return $null }
    $match = [regex]::Match([string]$Line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
    if (-not $match.Success) { return $null }
    try {
        $parsed = [datetimeoffset]::ParseExact($match.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
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
        verdict             = if ($passed) { 'CONTENTION-PASS' } else { 'CONTENTION-RED' }
        reasons             = @($reasons.ToArray())
    }
}

Export-ModuleMember -Function `
    Get-OpenPathFirstVisitContentionField, `
    Get-OpenPathFirstVisitLogTimestampMs, `
    Get-OpenPathFirstVisitUpdateRuns, `
    Get-OpenPathFirstVisitFirstRetentionMs, `
    Get-OpenPathFirstVisitUpdateContention
