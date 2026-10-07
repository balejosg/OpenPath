# Phase 6 C: first-visit real-site canary metrics.
#
# The canary runs a real, public SPA (only by dispatch) through the same lane:
# real domains, real DNS. The page self-report does not exist there, so the
# metrics come from the extension diagnostics (holds and their outcomes, E1
# reload decisions, navigation marks), the bounded MOZ_LOG nsHostResolver
# extract and the agent's openpath.log (worker generation stamps).
#
# The canary is diagnostic: it never fails the run. CANARY-PASS requires every
# hold to end in `ready`, no negative lookup for a learned host after its ready,
# and at most one reload. This module is pure so the lane tests can execute it
# without a VM.

function Get-OpenPathFirstVisitCanaryField {
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

function ConvertFrom-OpenPathFirstVisitDiagnosticLine {
    <#
    .SYNOPSIS
    Parses one `stage=extension-diagnostic {json}` native-host.log line.
    .DESCRIPTION
    Returns the parsed event (ts, kind, dependencyHost, outcome, ms, tabId...)
    or $null for any other line. The marker may appear anywhere in the logged
    line (the host prefixes level, caller and pid).
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Line = '')
    if (-not $Line) { return $null }
    $marker = 'stage=extension-diagnostic '
    $index = $Line.IndexOf($marker)
    if ($index -lt 0) { return $null }
    $json = $Line.Substring($index + $marker.Length)
    try { return ($json | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-OpenPathFirstVisitCanaryMetrics {
    <#
    .SYNOPSIS
    Per-scene canary metrics from the extension diagnostics.
    .DESCRIPTION
    Returns the hold outcome counts, the ready retention times (p50/max), the
    last ready time relative to the first navigation, the E1 reloads and
    reasons, the service-worker holds (tabId < 0) and the worker stamp->ready
    gaps over 2 s.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$DiagnosticLines = @(),
        [AllowNull()][string[]]$OpenPathLines = @(),
        # Phase 6.1 B: the site host the canary must see navigated.
        [string]$SiteHost = ''
    )
    $outcomes = New-Object System.Collections.Generic.List[object]
    $holds = 0
    $serviceWorkerHolds = 0
    $reloadReasons = New-Object System.Collections.Generic.List[string]
    $reloadDecisions = 0
    $navigationTs = $null
    $navigationEvents = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($DiagnosticLines)) {
        $event = ConvertFrom-OpenPathFirstVisitDiagnosticLine -Line $line
        if (-not $event) { continue }
        $kind = [string](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'kind')
        switch ($kind) {
            'hold' {
                $holds += 1
                $tabId = Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'tabId'
                if ($null -ne $tabId -and [int]$tabId -lt 0) { $serviceWorkerHolds += 1 }
            }
            'hold-outcome' {
                $outcomes.Add([ordered]@{
                        host    = [string](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'dependencyHost')
                        outcome = [string](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'outcome')
                        ms      = [int](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'ms')
                        ts      = [long](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'ts')
                    }) | Out-Null
            }
            'reload-decision' {
                $reloadDecisions += 1
                $reason = [string](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'reason')
                if ($reason) { $reloadReasons.Add($reason) | Out-Null }
            }
            'navigation' {
                $ts = Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'ts'
                $hostName = [string](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'host')
                if ($null -ne $ts) {
                    $value = [long]$ts
                    if ($null -eq $navigationTs -or $value -lt $navigationTs) { $navigationTs = $value }
                    if ($navigationEvents.Count -lt 50) {
                        $navigationEvents.Add([ordered]@{
                                host   = $hostName
                                ts     = $value
                                source = [string](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'source')
                            }) | Out-Null
                    }
                }
            }
        }
    }
    $outcomeCounts = [ordered]@{}
    $readyTimes = @{}
    $readyDurations = New-Object System.Collections.Generic.List[int]
    $lastReadyTs = $null
    # PowerShell 7.6: @() over a List[object] hits an enumerable-binder bug when
    # the elements are ordered dictionaries; ToArray() is the safe form.
    foreach ($entry in $outcomes.ToArray()) {
        $outcome = [string]$entry.outcome
        if (-not $outcomeCounts.Contains($outcome)) { $outcomeCounts[$outcome] = 0 }
        $outcomeCounts[$outcome] = [int]$outcomeCounts[$outcome] + 1
        if ($outcome -eq 'ready') {
            $host = [string]$entry.host
            $ts = [long]$entry.ts
            if ($host -and ($null -eq $readyTimes[$host] -or $ts -gt [long]$readyTimes[$host])) { $readyTimes[$host] = $ts }
            if ($null -eq $lastReadyTs -or $ts -gt $lastReadyTs) { $lastReadyTs = $ts }
            $duration = [int]$entry.ms
            if ($duration -ge 0) { $readyDurations.Add($duration) | Out-Null }
        }
    }
    $sortedDurations = @($readyDurations.ToArray() | Sort-Object)
    $readyP50 = if ($sortedDurations.Count -gt 0) { $sortedDurations[[int][math]::Floor(($sortedDurations.Count - 1) / 2)] } else { -1 }
    $readyMax = if ($sortedDurations.Count -gt 0) { $sortedDurations[-1] } else { -1 }
    $lastReadyFromNavigationMs = -1
    if ($null -ne $navigationTs -and $null -ne $lastReadyTs) {
        $delta = [long]$lastReadyTs - [long]$navigationTs
        if ($delta -ge 0) { $lastReadyFromNavigationMs = [int]$delta }
    }
    # Phase 6.1 B: did any navigation event reach the site host?
    $normalizedSiteHost = ([string]$SiteHost).Trim().TrimEnd('.').ToLowerInvariant()
    $siteNavigationTs = 0
    if ($normalizedSiteHost) {
        foreach ($nav in $navigationEvents.ToArray()) {
            $navHost = ([string]$nav.host).Trim().TrimEnd('.').ToLowerInvariant()
            if ($navHost -and $navHost -eq $normalizedSiteHost) {
                if ($siteNavigationTs -eq 0 -or [long]$nav.ts -lt $siteNavigationTs) { $siteNavigationTs = [long]$nav.ts }
            }
        }
    }
    $siteNavigated = ($siteNavigationTs -gt 0)
    $stampGaps = @(Get-OpenPathFirstVisitStampGaps -OpenPathLines $OpenPathLines -ReadyEvents @($outcomes | Where-Object { $_.outcome -eq 'ready' }))
    return [ordered]@{
        holds                  = $holds
        holdOutcomes           = $outcomes.ToArray()
        outcomeCounts          = $outcomeCounts
        readyP50Ms             = [int]$readyP50
        readyMaxMs             = [int]$readyMax
        readyCount             = $sortedDurations.Count
        lastReadyTs            = if ($null -ne $lastReadyTs) { [long]$lastReadyTs } else { 0 }
        navigationTs           = if ($null -ne $navigationTs) { [long]$navigationTs } else { 0 }
        lastReadyFromNavigationMs = [int]$lastReadyFromNavigationMs
        readyTimes             = $readyTimes
        reloads                = $reloadDecisions
        reloadReasons          = @($reloadReasons.ToArray())
        serviceWorkerHolds     = $serviceWorkerHolds
        stampGaps              = @($stampGaps)
        siteHost               = $normalizedSiteHost
        siteNavigated          = $siteNavigated
        siteNavigationTs       = $siteNavigationTs
        navigationEvents       = $navigationEvents.ToArray()
    }
}

function Get-OpenPathFirstVisitStampGaps {
    <#
    .SYNOPSIS
    Worker generation stamp -> extension ready gaps over the threshold.
    .DESCRIPTION
    The openpath.log "stamped: appliedGeneration=N" line (one per generation
    batch, second resolution) marks when the worker applied the overlay. For
    every ready event the newest stamp before it is matched and the gap is
    reported when it exceeds 2 s.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$OpenPathLines = @(),
        [AllowNull()][object[]]$ReadyEvents = @(),
        [int]$ThresholdMs = 2000
    )
    $stamps = New-Object System.Collections.Generic.List[long]
    foreach ($line in @($OpenPathLines)) {
        if ([string]$line -notmatch 'stamped') { continue }
        $match = [regex]::Match([string]$line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if (-not $match.Success) { continue }
        try {
            $parsed = [datetimeoffset]::ParseExact($match.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            $stamps.Add([long]$parsed.ToUnixTimeMilliseconds()) | Out-Null
        }
        catch { }
    }
    $gaps = New-Object System.Collections.Generic.List[object]
    if ($stamps.Count -eq 0) { return @() }
    $sortedStamps = @($stamps | Sort-Object)
    foreach ($event in @($ReadyEvents)) {
        $readyTs = [long](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'ts')
        if ($readyTs -le 0) { continue }
        $candidate = $null
        foreach ($stamp in $sortedStamps) {
            if ($stamp -le $readyTs) { $candidate = $stamp } else { break }
        }
        if ($null -eq $candidate) { continue }
        $gap = [int]($readyTs - [long]$candidate)
        if ($gap -gt $ThresholdMs) {
            $gaps.Add([ordered]@{
                    host    = [string](Get-OpenPathFirstVisitCanaryField -InputObject $event -Name 'dependencyHost')
                    readyTs = $readyTs
                    stampTs = [long]$candidate
                    gapMs   = $gap
                }) | Out-Null
        }
    }
    return @($gaps.ToArray())
}

function Select-OpenPathFirstVisitMozHostLines {
    <#
    .SYNOPSIS
    Bounded MOZ_LOG nsHostResolver lines for the learned overlay hosts.
    .DESCRIPTION
    Keeps at most MaxPerHost lines per learned host and classifies a line as a
    negative lookup when it matches the negative pattern (unknown host,
    NS_ERROR_UNKNOWN_HOST, NXDOMAIN, refused, failure...). A negative counts as
    "after ready" only when its log timestamp is later than the host's last
    ready event.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$MozLines = @(),
        [AllowNull()][string[]]$Hosts = @(),
        [AllowNull()][object]$ReadyTimes = $null,
        [int]$MaxPerHost = 20,
        [string]$NegativePattern = '(?i)NS_ERROR_UNKNOWN_HOST|UNKNOWN_HOST|NXDOMAIN|unknown host|refused|failed|failure'
    )
    $hostMap = @{}
    $negative = New-Object System.Collections.Generic.List[object]
    if (@($Hosts).Count -eq 0) {
        return [ordered]@{ linesByHost = [ordered]@{}; negativesAfterReady = @(); negativeCount = 0 }
    }
    $patterns = @(@($Hosts) | ForEach-Object { [regex]::Escape([string]$_) })
    foreach ($line in @($MozLines)) {
        $text = [string]$line
        $matchedHost = ''
        foreach ($host in @($Hosts)) {
            if ($text -match [regex]::Escape([string]$host)) { $matchedHost = [string]$host; break }
        }
        if (-not $matchedHost) { continue }
        if (-not $hostMap.ContainsKey($matchedHost)) { $hostMap[$matchedHost] = New-Object System.Collections.Generic.List[string] }
        if ($hostMap[$matchedHost].Count -lt $MaxPerHost) { $hostMap[$matchedHost].Add($text) | Out-Null }
        if ($text -notmatch $NegativePattern) { continue }
        $lineTs = 0
        $match = [regex]::Match($text, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)')
        if ($match.Success) {
            try {
                $parsed = [datetime]::ParseExact($match.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss.ffffff', [System.Globalization.CultureInfo]::InvariantCulture)
                $lineTs = [long]([datetimeoffset]::new([datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc))).ToUnixTimeMilliseconds()
            }
            catch { $lineTs = 0 }
        }
        $readyTs = 0
        if ($ReadyTimes -and (Get-OpenPathFirstVisitCanaryField -InputObject $ReadyTimes -Name $matchedHost)) {
            $readyTs = [long](Get-OpenPathFirstVisitCanaryField -InputObject $ReadyTimes -Name $matchedHost)
        }
        if ($lineTs -gt 0 -and $readyTs -gt 0 -and $lineTs -le $readyTs) { continue }
        $negative.Add([ordered]@{ host = $matchedHost; line = $text; ts = $lineTs; readyTs = $readyTs }) | Out-Null
    }
    $linesByHost = [ordered]@{}
    foreach ($key in @($hostMap.Keys)) { $linesByHost[$key] = @($hostMap[$key].ToArray()) }
    return [ordered]@{
        linesByHost        = $linesByHost
        negativesAfterReady = @($negative.ToArray())
        negativeCount      = $negative.Count
    }
}

function Get-OpenPathFirstVisitCanaryVerdict {
    <#
    .SYNOPSIS
    CANARY-PASS / CANARY-RED decision for one real-site scene.
    .DESCRIPTION
    CANARY-PASS requires every observed hold to end in `ready`, no negative
    lookup for a learned host after its ready, and at most one reload. The
    canary never fails the run by itself (only INFRA does); the reasons name
    exactly what was measured.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Metrics = $null,
        [AllowNull()][object]$MozResult = $null,
        [int]$MaxReloads = 1
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $outcomeCounts = Get-OpenPathFirstVisitCanaryField -InputObject $Metrics -Name 'outcomeCounts'
    $holds = [int](Get-OpenPathFirstVisitCanaryField -InputObject $Metrics -Name 'holds')
    if ($holds -le 0) { $reasons.Add('no-holds-observed') | Out-Null }
    $notReady = 0
    if ($outcomeCounts -is [System.Collections.IDictionary]) {
        foreach ($key in @($outcomeCounts.Keys)) {
            if ([string]$key -eq 'ready') { continue }
            $notReady += [int]$outcomeCounts[$key]
        }
    }
    elseif ($outcomeCounts) {
        foreach ($property in @($outcomeCounts.PSObject.Properties)) {
            if ([string]$property.Name -eq 'ready') { continue }
            $notReady += [int]$property.Value
        }
    }
    if ($notReady -gt 0) { $reasons.Add("holds-not-ready:$notReady") | Out-Null }
    $negatives = [int](Get-OpenPathFirstVisitCanaryField -InputObject $MozResult -Name 'negativeCount')
    if ($negatives -gt 0) { $reasons.Add("negative-lookups-after-ready:$negatives") | Out-Null }
    $reloads = [int](Get-OpenPathFirstVisitCanaryField -InputObject $Metrics -Name 'reloads')
    if ($reloads -gt $MaxReloads) { $reasons.Add("too-many-reloads:$reloads") | Out-Null }
    return [ordered]@{
        status  = if ($reasons.Count -eq 0) { 'CANARY-PASS' } else { 'CANARY-RED' }
        reasons = @($reasons.ToArray())
    }
}

Export-ModuleMember -Function `
    ConvertFrom-OpenPathFirstVisitDiagnosticLine, `
    Get-OpenPathFirstVisitCanaryMetrics, `
    Get-OpenPathFirstVisitCanaryVerdict, `
    Get-OpenPathFirstVisitStampGaps, `
    Select-OpenPathFirstVisitMozHostLines
