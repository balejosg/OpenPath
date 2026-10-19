# Phase 7 P1: first-visit stall diagnosis.
#
# The 6.1 canary left one unexplained stall (the second real site, r1: the
# worker detected the batch and then its own stopwatch jumped ~10 s with no log
# line in between; hypothesis: a whole-VM pause, never demonstrated). This
# module classifies every observed >2 s gap with data:
#   - vm-stall: the guest sampler itself has the same gap (the VM did not run),
#   - guest-saturated: the sampler is alive and system CPU is pinned (the
#     window carries the culprit process names),
#   - worker-only: the sampler is alive, CPU is normal and only the worker/
#     native-host sequence paused,
#   - unknown: not enough data to decide.
# All functions are pure so the lane tests can exercise them without a VM.

function Get-OpenPathFirstVisitStallField {
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

function Get-OpenPathFirstVisitStallSampleTimestampMs {
    # accepts a sampler sample (object with t) or a raw JSON line.
    [CmdletBinding()]
    param([AllowNull()][object]$Sample = $null)
    if ($null -eq $Sample) { return $null }
    if ($Sample -is [string]) {
        try { $Sample = $Sample | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    }
    $t = Get-OpenPathFirstVisitStallField -InputObject $Sample -Name 't'
    if ($null -eq $t) { return $null }
    return [long]$t
}

function Get-OpenPathFirstVisitSamplerTickValues {
    <#
    .SYNOPSIS
    Tick values (`t` epoch ms) from raw sampler JSONL lines.
    .DESCRIPTION
    The stop step reads tens of thousands of 50 ms lines; building a
    PSCustomObject per line timed the step out (partial results in the first
    Phase 7 runs). This is the cheap pre-parse: regex `"t":<n>` on every line
    that is not a CPU census line. CPU lines are excluded here and parsed
    separately (they are only one per second).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$Lines = @(),
        [int]$Stride = 1,
        [int]$MaxLines = 0
    )
    $ticks = New-Object System.Collections.Generic.List[long]
    if ($Stride -lt 1) { $Stride = 1 }
    for ($i = 0; $i -lt @($Lines).Count; $i += $Stride) {
        if ($MaxLines -gt 0 -and $ticks.Count -ge $MaxLines) { break }
        $line = [string]$Lines[$i]
        if (-not $line -or $line.IndexOf('cpuSample') -ge 0) { continue }
        $match = [regex]::Match($line, '"t":(\d+)')
        if ($match.Success) { $ticks.Add([long]$match.Groups[1].Value) | Out-Null }
    }
    return @($ticks.ToArray())
}

function Get-OpenPathFirstVisitSamplerGapsFromTicks {
    # gaps over the threshold between consecutive tick values.
    [CmdletBinding()]
    param(
        [AllowNull()][long[]]$Ticks = @(),
        [int]$ThresholdMs = 2000
    )
    $sorted = @(@($Ticks) | Sort-Object)
    $gaps = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $gap = [long]$sorted[$i] - [long]$sorted[$i - 1]
        if ($gap -gt $ThresholdMs) {
            $gaps.Add([ordered]@{ startMs = [long]$sorted[$i - 1]; endMs = [long]$sorted[$i]; gapMs = [int]$gap; kind = 'sampler' }) | Out-Null
        }
    }
    return @($gaps.ToArray())
}

function Get-OpenPathFirstVisitSamplerGaps {
    <#
    .SYNOPSIS
    Gaps between consecutive sampler ticks (a whole-VM pause shows up here).
    .DESCRIPTION
    A tick carrying `cpuSample = true` is written by the sampler right after
    its periodic CPU collection; the gap that ends on such a tick is sampler
    self-busy time, not a VM pause, and is not reported.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Samples = @(),
        [int]$ThresholdMs = 2000
    )
    $points = New-Object System.Collections.Generic.List[object]
    foreach ($sample in @($Samples)) {
        $ts = Get-OpenPathFirstVisitStallSampleTimestampMs -Sample $sample
        if ($null -ne $ts) { $points.Add([ordered]@{ ts = [long]$ts; cpuSample = [bool](Get-OpenPathFirstVisitStallField -InputObject $sample -Name 'cpuSample') }) | Out-Null }
    }
    $sorted = @($points | Sort-Object { $_.ts })
    $gaps = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i].cpuSample) { continue }
        $gap = [long]$sorted[$i].ts - [long]$sorted[$i - 1].ts
        if ($gap -gt $ThresholdMs) {
            $gaps.Add([ordered]@{ startMs = [long]$sorted[$i - 1].ts; endMs = [long]$sorted[$i].ts; gapMs = [int]$gap; kind = 'sampler' }) | Out-Null
        }
    }
    return @($gaps.ToArray())
}

function Get-OpenPathFirstVisitCpuSaturation {
    <#
    .SYNOPSIS
    Windows where the sampler saw system CPU above the threshold.
    .DESCRIPTION
    Consecutive CPU samples over the threshold merge into one window; the
    window carries the busiest process names reported by the samples.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Samples = @(),
        [double]$ThresholdPercent = 90,
        [int]$MinDurationMs = 2000
    )
    $windows = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($sample in @($Samples)) {
        $ts = Get-OpenPathFirstVisitStallSampleTimestampMs -Sample $sample
        if ($null -eq $ts) { continue }
        $cpu = Get-OpenPathFirstVisitStallField -InputObject $sample -Name 'systemCpu'
        $busy = ($null -ne $cpu -and [double]$cpu -ge $ThresholdPercent)
        if ($busy) {
            if (-not $current) {
                $current = [ordered]@{ startMs = [long]$ts; endMs = [long]$ts; maxCpu = [double]$cpu; processes = New-Object System.Collections.Generic.List[string] }
            }
            $current.endMs = [long]$ts
            if ([double]$cpu -gt $current.maxCpu) { $current.maxCpu = [double]$cpu }
            $processes = Get-OpenPathFirstVisitStallField -InputObject $sample -Name 'processes'
            if ($processes) {
                foreach ($property in @($processes.PSObject.Properties)) {
                    try {
                        if ([double]$property.Value -ge 10 -and -not $current.processes.Contains([string]$property.Name)) {
                            $current.processes.Add([string]$property.Name) | Out-Null
                        }
                    }
                    catch { }
                }
            }
        }
        elseif ($current) {
            $duration = [long]$current.endMs - [long]$current.startMs
            if ($duration -ge $MinDurationMs) {
                $current['durationMs'] = [int]$duration
                $current['processes'] = @($current.processes.ToArray())
                $windows.Add($current) | Out-Null
            }
            $current = $null
        }
    }
    if ($current) {
        $duration = [long]$current.endMs - [long]$current.startMs
        if ($duration -ge $MinDurationMs) {
            $current['durationMs'] = [int]$duration
            $current['processes'] = @($current.processes.ToArray())
            $windows.Add($current) | Out-Null
        }
    }
    return @($windows.ToArray())
}

function Get-OpenPathFirstVisitWorkerGaps {
    <#
    .SYNOPSIS
    Worker / dependency fast-apply gaps over the threshold in the agent log.
    .DESCRIPTION
    Only windows with work in flight count: the earlier line must be a worker
    detection, a fast-apply start or a fast-apply iteration, and the next
    worker/update line within the same region is the completion side. Idle
    silence between unrelated lines is not a gap.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$OpenPathLines = @(),
        [int]$ThresholdMs = 2000
    )
    $gaps = New-Object System.Collections.Generic.List[object]
    $pending = $null
    foreach ($line in @($OpenPathLines)) {
        $text = [string]$line
        $match = [regex]::Match($text, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if (-not $match.Success) { continue }
        if ($text -notmatch 'RuntimeDependency\.Worker|Update\.Runtime\.psm1') { continue }
        $ts = $null
        try {
            $parsed = [datetimeoffset]::ParseExact($match.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            $ts = [long]$parsed.ToUnixTimeMilliseconds()
        }
        catch { continue }
        $isWork = ($text -match 'worker detected \d+ queue file' -or
            $text -match 'Starting runtime dependency fast apply' -or
            $text -match 'fast apply iteration' -or
            $text -match 'queue batch')
        if ($isWork) {
            if ($null -ne $pending) {
                $gap = $ts - [long]$pending.ts
                if ($gap -gt $ThresholdMs) {
                    $gaps.Add([ordered]@{
                            startMs = [long]$pending.ts
                            endMs   = $ts
                            gapMs   = [int]$gap
                            first   = [string]$pending.line
                            next    = $text
                            source  = 'worker'
                        }) | Out-Null
                }
            }
            $pending = [ordered]@{ ts = $ts; line = $text }
        }
    }
    return @($gaps.ToArray())
}

function Get-OpenPathFirstVisitSamplerSummary {
    <#
    .SYNOPSIS
    Parses raw sampler JSONL lines into the guest stall evidence shape.
    .DESCRIPTION
    Phase 8g G2: the guest stop step used to lose its body when the step was
    killed, leaving the controller with sampleCount=0 and no gaps. The
    controller recovers the sampler file with this same pure parser, so the
    evidence survives a lost step result.
    #>
    [CmdletBinding()]
    param([AllowNull()][string[]]$Lines = @())

    $raw = @(@($Lines) | Where-Object { $null -ne $_ })
    $summary = [ordered]@{
        sampleCount       = [int]$raw.Count
        samplerGaps       = @()
        saturationWindows = @()
        maxSystemCpu      = -1
        decimated         = @()
    }
    if ($raw.Count -eq 0) { return [pscustomobject]$summary }

    $ticks = @(Get-OpenPathFirstVisitSamplerTickValues -Lines $raw)
    $summary.samplerGaps = @(Get-OpenPathFirstVisitSamplerGapsFromTicks -Ticks $ticks)
    $cpuSamples = New-Object System.Collections.Generic.List[object]
    $maxCpu = -1.0
    foreach ($line in @($raw | Where-Object { $_ -and $_.IndexOf('cpuSample') -ge 0 })) {
        try { $sample = $line | ConvertFrom-Json } catch { continue }
        $cpuSamples.Add($sample) | Out-Null
        if ($null -ne $sample.systemCpu -and [double]$sample.systemCpu -gt $maxCpu) { $maxCpu = [double]$sample.systemCpu }
    }
    $summary.saturationWindows = @(Get-OpenPathFirstVisitCpuSaturation -Samples $cpuSamples.ToArray())
    $summary.maxSystemCpu = [math]::Round($maxCpu, 1)
    $decimated = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $raw.Count; $i += 20) {
        if ($decimated.Count -ge 900) { break }
        $decimated.Add([string]$raw[$i]) | Out-Null
    }
    $summary.decimated = @($decimated.ToArray())
    return [pscustomobject]$summary
}

function Get-OpenPathFirstVisitStallClassification {
    <#
    .SYNOPSIS
    Classifies each log gap with the sampler / host evidence.
    .DESCRIPTION
    Priority: a sampler gap that covers the log gap is a whole-VM stall; an
    overlapping CPU-saturation window is guest saturation (the culprit names
    travel); otherwise the window is worker-only (the VM ran, the CPU was
    normal and only the worker/native sequence paused). Host pressure (PSI
    cpu/io some avg10) annotates the result.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$LogGaps = @(),
        [AllowNull()][object[]]$SamplerGaps = @(),
        [AllowNull()][object[]]$SaturationWindows = @(),
        [AllowNull()][object[]]$HostPressure = @(),
        # Phase 8g G2: 0 means the guest sampler produced no evidence. A
        # worker gap can then never be called a vm-stall; the record stays
        # 'unknown' until the sampler is fixed. -1 keeps the legacy behavior
        # for callers that pass parsed gaps but no count.
        [int]$SamplerSampleCount = -1
    )
    $classified = New-Object System.Collections.Generic.List[object]
    $vmStall = $false
    $guestSaturated = $false
    $logGapList = @(@($LogGaps) | Where-Object { $null -ne $_ })
    $samplerGapList = @(@($SamplerGaps) | Where-Object { $null -ne $_ })
    $saturationList = @(@($SaturationWindows) | Where-Object { $null -ne $_ })
    $pressureList = @(@($HostPressure) | Where-Object { $null -ne $_ })
    $samplerAvailable = if ($SamplerSampleCount -ge 0) { $SamplerSampleCount -gt 0 } else { $true }
    foreach ($gap in $logGapList) {
        $start = [long](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'startMs')
        $end = [long](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'endMs')
        $classification = 'worker-only'
        $evidence = ''
        $culprits = @()
        if ($samplerAvailable) {
            foreach ($samplerGap in $samplerGapList) {
                $samplerStart = [long](Get-OpenPathFirstVisitStallField -InputObject $samplerGap -Name 'startMs')
                $samplerEnd = [long](Get-OpenPathFirstVisitStallField -InputObject $samplerGap -Name 'endMs')
                if ($samplerStart -le $end -and $samplerEnd -ge $start) {
                    $classification = 'vm-stall'
                    $evidence = "sampler gap $samplerStart-$samplerEnd"
                    $vmStall = $true
                    break
                }
            }
        }
        else {
            $classification = 'unknown'
            $evidence = 'guest sampler produced no samples (sampleCount=0)'
        }
        if ($classification -eq 'worker-only') {
            foreach ($window in $saturationList) {
                $windowStart = [long](Get-OpenPathFirstVisitStallField -InputObject $window -Name 'startMs')
                $windowEnd = [long](Get-OpenPathFirstVisitStallField -InputObject $window -Name 'endMs')
                if ($windowStart -le $end -and $windowEnd -ge $start) {
                    $classification = 'guest-saturated'
                    $evidence = "system CPU $([double](Get-OpenPathFirstVisitStallField -InputObject $window -Name 'maxCpu'))%"
                    $culprits = @(Get-OpenPathFirstVisitStallField -InputObject $window -Name 'processes')
                    $guestSaturated = $true
                    break
                }
            }
        }
        $pressureNote = ''
        $nearestSample = $null
        $nearestDelta = [long]::MaxValue
        foreach ($sample in $pressureList) {
            $pressureTs = Get-OpenPathFirstVisitStallField -InputObject $sample -Name 't'
            if ($null -eq $pressureTs) { continue }
            if ([long]$pressureTs -ge $start -and [long]$pressureTs -le $end) {
                $nearestSample = $sample
                $nearestDelta = 0
                break
            }
            $midpoint = $start + [long](($end - $start) / 2)
            $delta = [math]::Abs([long]$pressureTs - $midpoint)
            if ($delta -lt $nearestDelta) { $nearestDelta = $delta; $nearestSample = $sample }
        }
        # Phase 8g G2: a small guest/host clock skew must not hide the pressure
        # sample; use the nearest one within 10 s and say how far it was.
        if ($null -ne $nearestSample -and $nearestDelta -le 10000) {
            $cpuSome = Get-OpenPathFirstVisitStallField -InputObject $nearestSample -Name 'cpuSome'
            $ioSome = Get-OpenPathFirstVisitStallField -InputObject $nearestSample -Name 'ioSome'
            $memorySome = Get-OpenPathFirstVisitStallField -InputObject $nearestSample -Name 'memorySome'
            $memAvailable = Get-OpenPathFirstVisitStallField -InputObject $nearestSample -Name 'memAvailableMb'
            $swapFree = Get-OpenPathFirstVisitStallField -InputObject $nearestSample -Name 'swapFreeMb'
            $qemuCpu = Get-OpenPathFirstVisitStallField -InputObject $nearestSample -Name 'qemuCpu'
            $qemuRss = Get-OpenPathFirstVisitStallField -InputObject $nearestSample -Name 'qemuRssMb'
            $pressureNote = "host cpu=$cpuSome io=$ioSome"
            if ($null -ne $memorySome) { $pressureNote += " mem=$memorySome" }
            if ($null -ne $memAvailable) { $pressureNote += " memAvailMb=$memAvailable" }
            if ($null -ne $swapFree) { $pressureNote += " swapFreeMb=$swapFree" }
            $pressureNote += " qemu=$qemuCpu"
            if ($null -ne $qemuRss) { $pressureNote += " qemuRssMb=$qemuRss" }
            if ($nearestDelta -gt 0) { $pressureNote += " deltaMs=$nearestDelta" }
        }
        $classified.Add([ordered]@{
                source         = [string](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'source')
                startMs        = $start
                endMs          = $end
                gapMs          = [int](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'gapMs')
                classification = $classification
                evidence       = $evidence
                culprits       = @($culprits)
                hostPressure   = $pressureNote
                firstLine      = [string](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'first')
                nextLine       = [string](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'next')
            }) | Out-Null
    }
    # Sampler gaps that do not cover any worker/native gap are still whole-VM
    # pauses: keep them classified in the record (source=sampler) so acceptance
    # (c) has every >2 s gap, including the ones with no product log gap.
    if ($samplerAvailable) {
        foreach ($samplerGap in $samplerGapList) {
            $samplerStart = [long](Get-OpenPathFirstVisitStallField -InputObject $samplerGap -Name 'startMs')
            $samplerEnd = [long](Get-OpenPathFirstVisitStallField -InputObject $samplerGap -Name 'endMs')
            $overlaps = $false
            foreach ($gap in $logGapList) {
                $logStart = [long](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'startMs')
                $logEnd = [long](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'endMs')
                if ($samplerStart -le $logEnd -and $samplerEnd -ge $logStart) { $overlaps = $true; break }
            }
            if ($overlaps) { continue }
            $classified.Add([ordered]@{
                    source         = 'sampler'
                    startMs        = $samplerStart
                    endMs          = $samplerEnd
                    gapMs          = [int](Get-OpenPathFirstVisitStallField -InputObject $samplerGap -Name 'gapMs')
                    classification = 'vm-stall'
                    evidence       = 'sampler gap with no worker/native gap in the same window'
                    culprits       = @()
                    hostPressure   = ''
                    firstLine      = ''
                    nextLine       = ''
                }) | Out-Null
            $vmStall = $true
        }
    }
    return [ordered]@{
        gaps             = @($classified.ToArray())
        vmStall          = $vmStall
        guestSaturated   = $guestSaturated
        samplerAvailable = $samplerAvailable
        classification   = if ($classified.Count -eq 0) { 'none' }
            elseif ($vmStall) { 'vm-stall' }
            elseif ($guestSaturated) { 'guest-saturated' }
            elseif (-not $samplerAvailable) { 'unknown' }
            else { 'worker-only' }
    }
}

Export-ModuleMember -Function `
    Get-OpenPathFirstVisitStallField, `
    Get-OpenPathFirstVisitSamplerTickValues, `
    Get-OpenPathFirstVisitSamplerGapsFromTicks, `
    Get-OpenPathFirstVisitSamplerGaps, `
    Get-OpenPathFirstVisitCpuSaturation, `
    Get-OpenPathFirstVisitWorkerGaps, `
    Get-OpenPathFirstVisitSamplerSummary, `
    Get-OpenPathFirstVisitStallClassification
