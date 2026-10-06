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
Import-Module (Join-Path $PSScriptRoot 'first-visit\FirstVisitOutcome.psm1') -Force
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
# Phase 5.3 P3: the template SHA travels in every phase file (sourceCommitSha).
$templateSha = ''
foreach ($templateScenarioDir in @(Get-ChildItem -LiteralPath $attemptRoot -Directory | Sort-Object Name)) {
    if ($templateSha) { break }
    foreach ($phaseName in @('prepare.json', 'observe.json')) {
        $phaseCandidate = Join-Path $templateScenarioDir.FullName $phaseName
        if (-not (Test-Path -LiteralPath $phaseCandidate -PathType Leaf)) { continue }
        try {
            $phaseObject = Get-Content -LiteralPath $phaseCandidate -Raw | ConvertFrom-Json
            $candidateSha = [string](Get-FirstVisitProperty -InputObject $phaseObject -Name 'sourceCommitSha' -Default '')
            if ($candidateSha) { $templateSha = $candidateSha; break }
        }
        catch { }
    }
}
$templateLag = if ($env:OPENPATH_TEMPLATE_LAG -match '^[0-9]+$') { [int]$env:OPENPATH_TEMPLATE_LAG } else { -1 }
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
        # Phase 5.2: verdict-before-collect evidence.
        evidenceIncomplete = $false
        collectError = ''
        collectTimings = $null
        blockedPathEnforced = $null
        # Phase 5.2 E2: student host probe (compiled exe as the student).
        hostProbePresent = $false
        hostProbePing = $false
        hostProbeReads = $false
        hostProbeDeniedPowershell = $false
        hostProbeManifestExe = $false
        hostProbeError = ''
        # Phase 6 C: real-site canary summary (empty for every other scenario).
        canaryStatus = ''
        canarySummary = ''
    }
    $prepareError = ''
    if (Test-Path -LiteralPath $preparePath) {
        try {
            $prepare = Get-Content -LiteralPath $preparePath -Raw | ConvertFrom-Json
            if ([string]$prepare.status -ne 'passed') { $row.error = [string]$prepare.error; $prepareError = [string]$prepare.error }
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
    $metricsObject = $null
    if (Test-Path -LiteralPath $metricsPath) {
        $metricsObject = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
        $row.status = 'observed'
        $row.verdict = [string]$metricsObject.verdict
        $row.reasons = @($metricsObject.reasons)
        $row.reloads = [int]$metricsObject.reloads
        $row.waveTimesMs = $metricsObject.waveTimesMs
        $row.hostProfile = @($metricsObject.hostProfile)
        $row.warmup = Get-FirstVisitProperty -InputObject $metricsObject -Name 'warmup'
        $row.diagnostics = Get-FirstVisitProperty -InputObject $metricsObject -Name 'diagnostics'
        $row.workerApplyMs = [int](Get-FirstVisitProperty -InputObject $metricsObject -Name 'workerApplyMs' -Default -1)
        $row.overlayStamps = [int](Get-FirstVisitProperty -InputObject $metricsObject -Name 'overlayStamps' -Default 0)
        $row.acrylicLines = [int](Get-FirstVisitProperty -InputObject $metricsObject -Name 'acrylicLines' -Default 0)
        $row.productReasons = @(Get-FirstVisitProperty -InputObject $row.warmup -Name 'productReasons' -Default @())
        $hostSignals = Get-FirstVisitProperty -InputObject $row.warmup -Name 'hostSignals'
        if ($hostSignals) { $row.appControlBlocked = [bool](Get-FirstVisitProperty -InputObject $hostSignals -Name 'blockedByAppControl') }
        $row.evidenceIncomplete = [bool](Get-FirstVisitProperty -InputObject $metricsObject -Name 'evidenceIncomplete' -Default $false)
        $row.collectError = [string](Get-FirstVisitProperty -InputObject $metricsObject -Name 'collectError' -Default '')
        $row.collectTimings = Get-FirstVisitProperty -InputObject $metricsObject -Name 'collectTimings'
        $metricsBlockedPath = Get-FirstVisitProperty -InputObject $metricsObject -Name 'blockedPathEnforced'
        if ($null -ne $metricsBlockedPath) { $row.blockedPathEnforced = [bool]$metricsBlockedPath }
        $hostProbe = Get-FirstVisitProperty -InputObject $metricsObject -Name 'studentHostProbe'
        $row.hostProbeError = [string](Get-FirstVisitProperty -InputObject $metricsObject -Name 'studentHostProbeError' -Default '')
        if ($hostProbe) {
            $row.hostProbePresent = [bool](Get-FirstVisitProperty -InputObject $hostProbe -Name 'compiledHostPresent' -Default $false)
            $row.hostProbePing = [bool](Get-FirstVisitProperty -InputObject $hostProbe -Name 'pingResponded' -Default $false)
            $row.hostProbeReads = [bool](Get-FirstVisitProperty -InputObject $hostProbe -Name 'readsResponded' -Default $false)
            $row.hostProbeDeniedPowershell = [bool](Get-FirstVisitProperty -InputObject $hostProbe -Name 'deniedPowershell' -Default $false)
            $row.hostProbeManifestExe = [bool](Get-FirstVisitProperty -InputObject $hostProbe -Name 'manifestTargetsCompiledHost' -Default $false)
        }
        # Phase 6 C: canary details for the row summary.
        $canaryObject = Get-FirstVisitProperty -InputObject $metricsObject -Name 'canary'
        if ($canaryObject) {
            $row.canaryStatus = [string](Get-FirstVisitProperty -InputObject $canaryObject -Name 'status' -Default '')
            $canaryMetrics = Get-FirstVisitProperty -InputObject $canaryObject -Name 'metrics'
            $canaryHolds = [int](Get-FirstVisitProperty -InputObject $canaryMetrics -Name 'holds' -Default 0)
            $canaryP50 = [int](Get-FirstVisitProperty -InputObject $canaryMetrics -Name 'readyP50Ms' -Default -1)
            $canaryMax = [int](Get-FirstVisitProperty -InputObject $canaryMetrics -Name 'readyMaxMs' -Default -1)
            $canaryReloads = [int](Get-FirstVisitProperty -InputObject $canaryMetrics -Name 'reloads' -Default 0)
            $canaryNegatives = [int](Get-FirstVisitProperty -InputObject $canaryObject -Name 'negativeCount' -Default 0)
            $row.canarySummary = "holds=$canaryHolds readyP50/max=${canaryP50}/${canaryMax}ms reloads=$canaryReloads negatives=$canaryNegatives"
        }
    }
    # Phase 5.2 C1: the controller persists the scene verdict (from the page
    # self-report plus the prepare product signals) before the collect step;
    # it is the authoritative classification even when metrics are missing.
    $verdictFilePath = Join-Path $scenarioDir.FullName 'observe-verdict.json'
    $verdictFile = $null
    if (Test-Path -LiteralPath $verdictFilePath) {
        try { $verdictFile = Get-Content -LiteralPath $verdictFilePath -Raw | ConvertFrom-Json } catch { $verdictFile = $null }
    }
    $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile $verdictFile -Metrics $metricsObject `
        -ObserveStatus ([string]$row.observeStatus) -ObserveError ([string]$row.error) `
        -ObserveReasonCode ([string]$row.observeReasonCode) -PrepareError $prepareError `
        -Scenario ([string]$row.scenario)
    $row.verdict = $outcome.verdict
    $row.category = $outcome.category
    if (@($outcome.reasons).Count -gt 0) { $row.reasons = @($outcome.reasons) }
    if (@($outcome.productReasons).Count -gt 0) { $row.productReasons = @($outcome.productReasons) }
    $row.error = $outcome.error
    $row.evidenceIncomplete = $outcome.evidenceIncomplete
    if ($outcome.collectError) { $row.collectError = $outcome.collectError }
    if ($null -ne $outcome.blockedPathEnforced) { $row.blockedPathEnforced = $outcome.blockedPathEnforced }
    if ($row.category -eq 'INFRA' -and -not $row.error) { $row.error = 'no-metrics-no-error' }
    if ($row.category -eq 'INFRA' -and $row.reasons -notcontains 'no-metrics') { $row.reasons += 'no-metrics' }
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
    templateSha   = $templateSha
    templateLag   = $templateLag
    scenarios     = $rows
    baselines     = $baselines
}
$statusOverall = if (@($rows | Where-Object { $_.category -eq 'INFRA' -or $_.category -notin @('PASS', 'CANARY-PASS', 'CANARY-RED') }).Count -gt 0) { 'failed' } else { 'passed' }
$summary.status = $statusOverall

if ($SummaryJsonPath) { [IO.File]::WriteAllText($SummaryJsonPath, ($summary | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false)) }
$lines = @(
    '# First-visit lane summary',
    '',
    "Run: $RunId attempt $RunAttempt - overall: $statusOverall",
    '',
    "- Template: $templateSha (lag $templateLag successful main RELs)",
    '',
    '| scenario | verdict | category | canary | observe | evidence | blocked path | probe | reasons | error | product reasons | reloads | wave1 ms | visit delay s |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $rows) {
    $wave1 = if ($row.waveTimesMs) { [string]$row.waveTimesMs.wave1 } else { '' }
    $errorText = ([string]$row.error) -replace '\|', '/'
    if ($errorText.Length -gt 240) { $errorText = $errorText.Substring(0, 240) + '...' }
    $evidenceText = if ($row.evidenceIncomplete) { 'incomplete' } else { 'complete' }
    $blockedPathText = if ($null -eq $row.blockedPathEnforced) { '' } else { [string][bool]$row.blockedPathEnforced }
    $probeText = if ($row.hostProbeError) { "error: $($row.hostProbeError)" }
        elseif ($row.hostProbePresent) { "exe ping=$([int]$row.hostProbePing) reads=$([int]$row.hostProbeReads) deny=$([int]$row.hostProbeDeniedPowershell) manifest=$([int]$row.hostProbeManifestExe)" }
        elseif ($row.status -eq 'observed') { "no-exe deny=$([int]$row.hostProbeDeniedPowershell)" }
        else { '' }
    $canaryText = if ($row.canaryStatus) { "$($row.canaryStatus) $($row.canarySummary)" } else { '' }
    $lines += "| $($row.scenario) | $($row.verdict) | $($row.category) | $canaryText | $($row.observeStatus) | $evidenceText | $blockedPathText | $probeText | $(@($row.reasons) -join ',') | $errorText | $(@($row.productReasons) -join ',') | $($row.reloads) | $wave1 | $($row.visitDelaySeconds) |"
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
$lines += ''
$lines += '## Collect timings (ms per guest block, Phase 5.2 C2)'
$lines += ''
$lines += '| scenario | total | addons | native | prof | openpath | worker | moz | overlay | whitelist | process | serialize | moz files | truncated |'
$lines += '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
foreach ($row in $rows) {
    $t = $row.collectTimings
    if (-not $t) {
        $lines += "| $($row.scenario) | - | | | | | | | | | | | | |"
        continue
    }
    $get = { param($name) $value = Get-FirstVisitProperty -InputObject $t -Name $name; if ($null -eq $value) { '' } else { [string]$value } }
    $lines += "| $($row.scenario) | $(& $get 'totalMs') | $(& $get 'addonsMs') | $(& $get 'nativeHostMs') | $(& $get 'profilesMs') | $(& $get 'openpathMs') | $(& $get 'workerStateMs') | $(& $get 'mozScanMs') | $(& $get 'overlayHostsMs') | $(& $get 'whitelistMs') | $(& $get 'processesMs') | $(& $get 'serializationMs') | $(& $get 'mozFiles') | $(& $get 'mozTruncated') |"
}
$markdown = $lines -join "`n"
if ($SummaryMarkdownPath) { [IO.File]::WriteAllText($SummaryMarkdownPath, $markdown, [Text.UTF8Encoding]::new($false)) }
Write-Output $markdown
if ($statusOverall -ne 'passed') { exit 1 }
exit 0
