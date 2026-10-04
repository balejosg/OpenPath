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
        observeStatus = 'missing'
        observeReasonCode = ''
        cleanupError = ''
        reloads     = -1
        waveTimesMs = $null
        visitDelaySeconds = -1
        warmup      = $null
        productReasons = @()
        appControlBlocked = $false
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
    $observePath = Join-Path $scenarioDir.FullName 'observe.json'
    if (Test-Path -LiteralPath $observePath) {
        try {
            $observe = Get-Content -LiteralPath $observePath -Raw | ConvertFrom-Json
            $row.observeStatus = if ([string]$observe.status) { [string]$observe.status } else { 'unknown' }
            $row.observeReasonCode = if ($observe.PSObject.Properties['reasonCode']) { [string]$observe.reasonCode } else { '' }
            if ([string]$observe.status -ne 'passed') {
                # Phase 5 A2: the observe failure reason is the scene failure
                # reason. Previously only prepare.json errors were read, so a
                # failed observe left 'unknown/no-metrics' with an empty error.
                $observeError = if ($observe.PSObject.Properties['error']) { [string]$observe.error } else { '' }
                if (-not $observeError) {
                    $observeError = "observe-$($row.observeStatus)"
                    if ($row.observeReasonCode) { $observeError += ":$($row.observeReasonCode)" }
                }
                if (-not $row.error) { $row.error = $observeError }
                if ($row.reasons -notcontains 'observe-failed') { $row.reasons += 'observe-failed' }
            }
        }
        catch { }
    }
    $cleanupPath = Join-Path $scenarioDir.FullName 'cleanup.json'
    if (Test-Path -LiteralPath $cleanupPath) {
        try {
            $cleanup = Get-Content -LiteralPath $cleanupPath -Raw | ConvertFrom-Json
            if ([string]$cleanup.status -ne 'passed') {
                $cleanupMessage = if ($cleanup.PSObject.Properties['error']) { [string]$cleanup.error } else { 'cleanup-not-passed' }
                $row.cleanupError = if ($cleanupMessage) { $cleanupMessage } else { 'cleanup-not-passed' }
            }
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
        $row.productReasons = @(Get-FirstVisitProperty -InputObject $row.warmup -Name 'productReasons' -Default @())
        $hostSignals = Get-FirstVisitProperty -InputObject $row.warmup -Name 'hostSignals'
        if ($hostSignals) { $row.appControlBlocked = [bool](Get-FirstVisitProperty -InputObject $hostSignals -Name 'blockedByAppControl') }
        # A measured visit is a product verdict; explicit warm-up product
        # reasons (native host blocked/not started) make it PRODUCT even when
        # the page waves happened to load.
        $row.category = if ($row.verdict -eq 'passed' -and $row.productReasons.Count -eq 0) { 'PASS' } else { 'PRODUCT' }
    }
    elseif ($row.error) {
        # Without a verdict the run is INFRA with the demonstrated cause:
        # preconditions, timeouts, lost results and lab transport failures are
        # never green by design (Phase 3A.3 policy).
        $row.category = 'INFRA'
    }
    else {
        # Phase 5 A2: a scene with no verdict and no recorded error is still
        # never UNKNOWN. It is INFRA with an explicit cause.
        $row.category = 'INFRA'
        $row.error = 'no-metrics-no-error'
        if ($row.reasons -notcontains 'no-metrics-no-error') { $row.reasons += 'no-metrics-no-error' }
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
            $fetchDelay = Get-FirstVisitProperty -InputObject $entry.warmup -Name 'xpiFetchAfterArmSeconds'
            if ($null -eq $fetchDelay) { $fetchDelay = Get-FirstVisitProperty -InputObject $entry.warmup -Name 'xpiFetchDelaySeconds' }
            if ($null -ne $fetchDelay -and [double]$fetchDelay -ge 0) { $warmupFetch += [double]$fetchDelay }
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
        warmupXpiFetchAfterArmSeconds = Measure-FirstVisitNumbers -Values @($warmupFetch)
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
$statusOverall = if (@($rows | Where-Object { $_.category -ne 'PASS' }).Count -gt 0) { 'failed' } else { 'passed' }
$summary.status = $statusOverall

if ($SummaryJsonPath) { [IO.File]::WriteAllText($SummaryJsonPath, ($summary | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false)) }
$lines = @(
    '# First-visit lane summary',
    '',
    "Run: $RunId attempt $RunAttempt - overall: $statusOverall",
    '',
    '| scenario | verdict | category | observe | reasons | error | product reasons | reloads | wave1 ms | visit delay s |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $rows) {
    $wave1 = if ($row.waveTimesMs) { [string]$row.waveTimesMs.wave1 } else { '' }
    $errorText = ([string]$row.error) -replace '\|', '/'
    if ($errorText.Length -gt 240) { $errorText = $errorText.Substring(0, 240) + '...' }
    $lines += "| $($row.scenario) | $($row.verdict) | $($row.category) | $($row.observeStatus) | $(@($row.reasons) -join ',') | $errorText | $(@($row.productReasons) -join ',') | $($row.reloads) | $wave1 | $($row.visitDelaySeconds) |"
}
$lines += ''
$lines += '## Baselines (median / max, one clock per segment)'
$lines += ''
$lines += '| scenario | runs | passed | failed | wave1 | wave2 | wave3 | xpi fetch s | host ping ms | process->script ms | reloads max |'
$lines += '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
foreach ($name in ($baselines.Keys | Sort-Object)) {
    $baseline = $baselines[$name]
    $lines += "| $name | $($baseline.runs) | $($baseline.passed) | $($baseline.failed) | $(Format-FirstVisitMeasure $baseline.waves.wave1) | $(Format-FirstVisitMeasure $baseline.waves.wave2) | $(Format-FirstVisitMeasure $baseline.waves.wave3) | $(Format-FirstVisitMeasure $baseline.warmupXpiFetchAfterArmSeconds) | $(Format-FirstVisitMeasure $baseline.hostPingMs) | $(Format-FirstVisitMeasure $baseline.hostProcessToScriptMs) | $($baseline.reloadsMax) |"
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
