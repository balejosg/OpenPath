<##
.SYNOPSIS
    Aggregates first-visit lane evidence into a JSON and Markdown summary.
.DESCRIPTION
    Reads every <EvidenceRoot>/<RunId>/<RunAttempt>/<scenario>/{observe.json,metrics.json}
    and reports per-scenario verdicts plus the metric baseline (median and max).
    A missing metrics file is a finding, never a silent pass.
##>
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

$attemptRoot = Join-Path (Join-Path $EvidenceRoot $RunId) ([string]$RunAttempt)
if (-not (Test-Path -LiteralPath $attemptRoot -PathType Container)) { throw 'first-visit-evidence-root-missing' }
$rows = @()
foreach ($scenarioDir in @(Get-ChildItem -LiteralPath $attemptRoot -Directory | Sort-Object Name)) {
    $metricsPath = Join-Path $scenarioDir.FullName 'metrics.json'
    $observePath = Join-Path $scenarioDir.FullName 'observe.json'
    $row = [ordered]@{
        scenario    = $scenarioDir.Name
        status      = 'missing'
        verdict     = 'unknown'
        reasons     = @('no-metrics')
        reloads     = -1
        waveTimesMs = $null
        visitDelaySeconds = -1
        haveObserve = (Test-Path -LiteralPath $observePath)
    }
    if (Test-Path -LiteralPath $metricsPath) {
        $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
        $row.status = 'observed'
        $row.verdict = [string]$metrics.verdict
        $row.reasons = @($metrics.reasons)
        $row.reloads = [int]$metrics.reloads
        $row.waveTimesMs = $metrics.waveTimesMs
        $row.hostProfile = @($metrics.hostProfile)
        $row.diagnosticLines = [int]$metrics.diagnosticLines
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
    $wave1 = @($group.Group | Where-Object { $_.waveTimesMs } | ForEach-Object { [int]$_.waveTimesMs.wave1 } | Sort-Object)
    $reloads = @($group.Group | Where-Object { $_.reloads -ge 0 } | ForEach-Object { [int]$_.reloads })
    $statuses = @($group.Group | ForEach-Object { $_.verdict })
    $baselines[$group.Name] = [ordered]@{
        runs     = $group.Count
        passed   = @($statuses | Where-Object { $_ -eq 'passed' }).Count
        failed   = @($statuses | Where-Object { $_ -ne 'passed' }).Count
        wave1Ms  = if ($wave1.Count -gt 0) { [ordered]@{ median = $wave1[[int][math]::Floor(($wave1.Count - 1) / 2)]; max = $wave1[-1] } } else { $null }
        reloadsMax = if ($reloads.Count -gt 0) { ($reloads | Measure-Object -Maximum).Maximum } else { $null }
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
if ($SummaryJsonPath) { [IO.File]::WriteAllText($SummaryJsonPath, ($summary | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)) }
$lines = @(
    '# First-visit lane summary',
    '',
    "Run: $RunId attempt $RunAttempt - overall: $statusOverall",
    '',
    '| scenario | verdict | reasons | reloads | wave1 ms | visit delay s |',
    '| --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $rows) {
    $wave1 = if ($row.waveTimesMs) { [string]$row.waveTimesMs.wave1 } else { '' }
    $lines += "| $($row.scenario) | $($row.verdict) | $(@($row.reasons) -join ',') | $($row.reloads) | $wave1 | $($row.visitDelaySeconds) |"
}
$lines += ''
$lines += '## Baselines'
$lines += ''
$lines += '| scenario | runs | passed | failed | wave1 median ms | wave1 max ms | reloads max |'
$lines += '| --- | --- | --- | --- | --- | --- | --- |'
foreach ($name in ($baselines.Keys | Sort-Object)) {
    $baseline = $baselines[$name]
    $median = if ($baseline.wave1Ms) { [string]$baseline.wave1Ms.median } else { '' }
    $max = if ($baseline.wave1Ms) { [string]$baseline.wave1Ms.max } else { '' }
    $lines += "| $name | $($baseline.runs) | $($baseline.passed) | $($baseline.failed) | $median | $max | $($baseline.reloadsMax) |"
}
$markdown = $lines -join "`n"
if ($SummaryMarkdownPath) { [IO.File]::WriteAllText($SummaryMarkdownPath, $markdown, [Text.UTF8Encoding]::new($false)) }
Write-Output $markdown
if ($statusOverall -ne 'passed') { exit 1 }
exit 0
