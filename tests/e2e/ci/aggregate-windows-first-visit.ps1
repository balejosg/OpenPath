<##
.SYNOPSIS
    Aggregates first-visit lane evidence into a JSON and Markdown summary.
.DESCRIPTION
    Reads every <EvidenceRoot>/<RunId>/<RunAttempt>/<scenario>/{prepare,observe,metrics}.json
    and reports per-scenario verdicts, the metric baseline (median and max per
    scenario and wave) and an INFRA/PRODUCT classification: a missing metrics
    file with an infrastructure error is INFRA, a failed verdict is PRODUCT.

    Every timing segment comes from a single clock (page waves from the in-page
    self-report, warm-up fetch deltas from the fixture clock, host segments from
    the native host's own startup-profile lines).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][int]$RunAttempt,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [string]$SummaryJsonPath = '',
    [string]$SummaryMarkdownPath = ''
)

$ErrorActionPreference = 'Stop'
function Get-FirstVisitProperty {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name, [object]$Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Measure-FirstVisitNumbers {
    param([double[]]$Values = @())
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    return [ordered]@{ median = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]; max = $sorted[-1]; count = $sorted.Count }
}

function Format-FirstVisitMeasure {
    param([AllowNull()][object]$Measure)
    if ($Measure) { return "$($Measure.median) / $($Measure.max)" }
    return ''
}

$attemptRoot = Join-Path (Join-Path $EvidenceRoot $RunId) ([string]$RunAttempt)
if (-not (Test-Path -LiteralPath $attemptRoot -PathType Container)) { throw 'first-visit-evidence-root-missing' }
$infraPattern = 'controller-timeout|guest-query-failed|guest-not-ready|guest-result-missing|guest-result-invalid|fixture-unavailable|fixture-plan|dns-fixture|lock-busy|lock|reboot-timeout|host-unreachable|desktop-lab-guest'
$rows = @()
foreach ($scenarioDir in @(Get-ChildItem -LiteralPath $attemptRoot -Directory | Sort-Object Name)) {
    $metricsPath = Join-Path $scenarioDir.FullName 'metrics.json'
    $observePath = Join-Path $scenarioDir.FullName 'observe.json'
    $preparePath = Join-Path $scenarioDir.FullName 'prepare.json'
    $row = [ordered]@{
        scenario    = $scenarioDir.Name
        status      = 'missing'
        verdict     = 'unknown'
        category    = 'UNKNOWN'
        reasons     = @('no-metrics')
        error       = ''
        reloads     = -1
        waveTimesMs = $null
        visitDelaySeconds = -1
        warmup      = $null
        hostProfile = @()
        diagnostics = $null
        workerApplyMs = -1
        overlayStamps = 0
        acrylicLines  = 0
    }
    if (Test-Path -LiteralPath $preparePath) {
        try {
            $prepare = Get-Content -LiteralPath $preparePath -Raw | ConvertFrom-Json
            if ([string]$prepare.status -ne 'passed') { $row.error = [string]$prepare.error }
        }
        catch { }
    }
    if (Test-Path -LiteralPath $metricsPath) {
        $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
        $row.status = 'observed'
        $row.verdict = [string]$metrics.verdict
        $row.reasons = @($metrics.reasons)
        $row.reloads = [int]$metrics.reloads
        $row.waveTimesMs = $metrics.waveTimesMs
        $row.hostProfile = @($metrics.hostProfile)
        $row.warmup = Get-FirstVisitProperty -InputObject $metrics -Name 'warmup'
        $row.diagnostics = Get-FirstVisitProperty -InputObject $metrics -Name 'diagnostics'
        $row.workerApplyMs = [int](Get-FirstVisitProperty -InputObject $metrics -Name 'workerApplyMs' -Default -1)
        $row.overlayStamps = [int](Get-FirstVisitProperty -InputObject $metrics -Name 'overlayStamps' -Default 0)
        $row.acrylicLines = [int](Get-FirstVisitProperty -InputObject $metrics -Name 'acrylicLines' -Default 0)
        $row.category = if ($row.verdict -eq 'passed') { 'PASS' } else { 'PRODUCT' }
    }
    elseif ($row.error -match $infraPattern) {
        $row.category = 'INFRA'
    }
    elseif ($row.error -match 'first-visit-guest-step-failed|first-visit-guest-step') {
        $row.category = 'PRODUCT'
    }
    if (Test-Path -LiteralPath $observePath) {
        try {
            $observe = Get-Content -LiteralPath $observePath -Raw | ConvertFrom-Json
            $row.visitDelaySeconds = [int](Get-FirstVisitProperty -InputObject $observe -Name 'visitDelaySeconds' -Default -1)
            $state = Get-FirstVisitProperty -InputObject $observe -Name 'observation'
            if ($state) {
                $inner = Get-FirstVisitProperty -InputObject $state -Name 'state'
                if ($inner) { $row.visitDelaySeconds = [int](Get-FirstVisitProperty -InputObject $inner -Name 'visitDelaySeconds' -Default -1) }
            }
        }
        catch { }
    }
    $rows += [pscustomobject]$row
}

$baselines = @{}
foreach ($group in @($rows | Group-Object { ($_.scenario -replace '-r\d+$', '') })) {
    $waveValues = @{ wave1 = @(); wave2 = @(); wave3 = @() }
    $hostPing = @()
    $hostProcessToScript = @()
    $warmupFetch = @()
    $reloads = @()
    $reloadReasons = @{}
    $statuses = @()
    foreach ($entry in $group.Group) {
        $statuses += $entry.verdict
        if ($entry.waveTimesMs) {
            foreach ($wave in @('wave1', 'wave2', 'wave3')) {
                $value = [double](Get-FirstVisitProperty -InputObject $entry.waveTimesMs -Name $wave -Default 0)
                if ($value -gt 0) { $waveValues[$wave] += $value }
            }
        }
        foreach ($profile in @($entry.hostProfile)) {
            $ping = Get-FirstVisitProperty -InputObject $profile -Name 'pingMs'
            if ($null -ne $ping -and [double]$ping -gt 0) { $hostPing += [double]$ping }
            $processMs = Get-FirstVisitProperty -InputObject $profile -Name 'processToScriptMs'
            if ($null -ne $processMs -and [double]$processMs -gt 0) { $hostProcessToScript += [double]$processMs }
        }
        if ($entry.warmup) {
            $fetchDelay = [double](Get-FirstVisitProperty -InputObject $entry.warmup -Name 'xpiFetchDelaySeconds' -Default -1)
            if ($fetchDelay -ge 0) { $warmupFetch += $fetchDelay }
        }
        if ($entry.reloads -ge 0) { $reloads += [int]$entry.reloads }
        foreach ($reason in @(Get-FirstVisitProperty -InputObject $entry.diagnostics -Name 'reloadReasons' -Default @())) {
            if (-not $reason) { continue }
            if (-not $reloadReasons.ContainsKey([string]$reason)) { $reloadReasons[[string]$reason] = 0 }
            $reloadReasons[[string]$reason] += 1
        }
    }
    $baselines[$group.Name] = [ordered]@{
        runs     = $group.Count
        passed   = @($statuses | Where-Object { $_ -eq 'passed' }).Count
        failed   = @($statuses | Where-Object { $_ -ne 'passed' }).Count
        categories = @($group.Group | Group-Object category | ForEach-Object { "$($_.Name)=$($_.Count)" })
        waves    = [ordered]@{
            wave1 = Measure-FirstVisitNumbers -Values @($waveValues.wave1)
            wave2 = Measure-FirstVisitNumbers -Values @($waveValues.wave2)
            wave3 = Measure-FirstVisitNumbers -Values @($waveValues.wave3)
        }
        warmupFetchDelaySeconds = Measure-FirstVisitNumbers -Values @($warmupFetch)
        hostPingMs = Measure-FirstVisitNumbers -Values @($hostPing)
        hostProcessToScriptMs = Measure-FirstVisitNumbers -Values @($hostProcessToScript)
        reloadsMax = if ($reloads.Count -gt 0) { ($reloads | Measure-Object -Maximum).Maximum } else { $null }
        reloadReasons = $reloadReasons
    }
}

$summary = [ordered]@{
    schemaVersion = 1
    runId         = $RunId
    runAttempt    = $RunAttempt
    generatedAt   = [DateTime]::UtcNow.ToString('o')
    scenarios     = $rows
    baselines     = $baselines
}
$statusOverall = if (@($rows | Where-Object { $_.verdict -ne 'passed' }).Count -gt 0) { 'failed' } else { 'passed' }
$summary.status = $statusOverall

if ($SummaryJsonPath) { [IO.File]::WriteAllText($SummaryJsonPath, ($summary | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false)) }
$lines = @(
    '# First-visit lane summary',
    '',
    "Run: $RunId attempt $RunAttempt - overall: $statusOverall",
    '',
    '| scenario | verdict | category | reasons | reloads | wave1 ms | visit delay s |',
    '| --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $rows) {
    $wave1 = if ($row.waveTimesMs) { [string]$row.waveTimesMs.wave1 } else { '' }
    $lines += "| $($row.scenario) | $($row.verdict) | $($row.category) | $(@($row.reasons) -join ',') | $($row.reloads) | $wave1 | $($row.visitDelaySeconds) |"
}
$lines += ''
$lines += '## Baselines (median / max, one clock per segment)'
$lines += ''
$lines += '| scenario | runs | passed | failed | wave1 | wave2 | wave3 | xpi fetch s | host ping ms | process->script ms | reloads max |'
$lines += '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
foreach ($name in ($baselines.Keys | Sort-Object)) {
    $baseline = $baselines[$name]
    $lines += "| $name | $($baseline.runs) | $($baseline.passed) | $($baseline.failed) | $(Format-FirstVisitMeasure $baseline.waves.wave1) | $(Format-FirstVisitMeasure $baseline.waves.wave2) | $(Format-FirstVisitMeasure $baseline.waves.wave3) | $(Format-FirstVisitMeasure $baseline.warmupFetchDelaySeconds) | $(Format-FirstVisitMeasure $baseline.hostPingMs) | $(Format-FirstVisitMeasure $baseline.hostProcessToScriptMs) | $($baseline.reloadsMax) |"
}
$lines += ''
$lines += '## Reload decisions (E1 reasons)'
$lines += ''
foreach ($name in ($baselines.Keys | Sort-Object)) {
    $reasons = $baselines[$name].reloadReasons
    $lines += "- ${name}: " + $(if ($reasons.Count -gt 0) { ($reasons.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' } else { 'none' })
}
$markdown = $lines -join "`n"
if ($SummaryMarkdownPath) { [IO.File]::WriteAllText($SummaryMarkdownPath, $markdown, [Text.UTF8Encoding]::new($false)) }
Write-Output $markdown
if ($statusOverall -ne 'passed') { exit 1 }
exit 0
