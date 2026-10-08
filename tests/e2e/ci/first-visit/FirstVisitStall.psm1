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
        [AllowNull()][object[]]$HostPressure = @()
    )
    $classified = New-Object System.Collections.Generic.List[object]
    $vmStall = $false
    $guestSaturated = $false
    foreach ($gap in @($LogGaps)) {
        $start = [long](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'startMs')
        $end = [long](Get-OpenPathFirstVisitStallField -InputObject $gap -Name 'endMs')
        $classification = 'worker-only'
        $evidence = ''
        $culprits = @()
        foreach ($samplerGap in @($SamplerGaps)) {
            $samplerStart = [long](Get-OpenPathFirstVisitStallField -InputObject $samplerGap -Name 'startMs')
            $samplerEnd = [long](Get-OpenPathFirstVisitStallField -InputObject $samplerGap -Name 'endMs')
            if ($samplerStart -le $end -and $samplerEnd -ge $start) {
                $classification = 'vm-stall'
                $evidence = "sampler gap $samplerStart-$samplerEnd"
                $vmStall = $true
                break
            }
        }
        if ($classification -eq 'worker-only') {
            foreach ($window in @($SaturationWindows)) {
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
        foreach ($sample in @($HostPressure)) {
            $pressureTs = Get-OpenPathFirstVisitStallField -InputObject $sample -Name 't'
            if ($null -eq $pressureTs) { continue }
            if ([long]$pressureTs -ge $start -and [long]$pressureTs -le $end) {
                $cpuSome = Get-OpenPathFirstVisitStallField -InputObject $sample -Name 'cpuSome'
                $ioSome = Get-OpenPathFirstVisitStallField -InputObject $sample -Name 'ioSome'
                $pressureNote = "host cpu=$cpuSome io=$ioSome qemu=$([string](Get-OpenPathFirstVisitStallField -InputObject $sample -Name 'qemuCpu'))"
                break
            }
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
    return [ordered]@{
        gaps            = @($classified.ToArray())
        vmStall         = $vmStall
        guestSaturated  = $guestSaturated
        classification  = if ($classified.Count -eq 0) { 'none' }
            elseif ($vmStall) { 'vm-stall' }
            elseif ($guestSaturated) { 'guest-saturated' }
            else { 'worker-only' }
    }
}

Export-ModuleMember -Function `
    Get-OpenPathFirstVisitStallField, `
    Get-OpenPathFirstVisitSamplerGaps, `
    Get-OpenPathFirstVisitCpuSaturation, `
    Get-OpenPathFirstVisitWorkerGaps, `
    Get-OpenPathFirstVisitStallClassification
