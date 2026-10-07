# Phase 5.2 C1: first-visit scene outcome classification.
#
# The scene verdict is written by the controller BEFORE the heavy collect step
# (observe-verdict.json), so this pure function decides PASS / PRODUCT / INFRA
# from persisted evidence only. It is shared by the lane aggregator and the
# contract tests; the nightly of Phase 5 showed that a complete page
# self-report (all waves false) plus a hung collect must stay PRODUCT red, not
# INFRA.

function Get-OpenPathFirstVisitOutcomeField {
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

function Get-OpenPathFirstVisitSceneOutcome {
    <#
    .SYNOPSIS
    Pure PASS / PRODUCT / INFRA decision for one first-visit scene.
    .DESCRIPTION
    Inputs are the persisted artifacts, not live state:
      - VerdictFile: observe-verdict.json (verdict + product reasons + probe),
      - Metrics: metrics.json (legacy authoritative verdict when no file),
      - observe/prepare errors for the literal cause.
    Rules:
      - a settled self-report with a failed verdict or product reasons is
        PRODUCT, even when metrics are missing (the Phase 5 nightly case);
      - a scene without a self-report cannot be measured: INFRA;
      - a green verdict with incomplete collect evidence is INFRA
        (evidence-incomplete), never a claimed pass;
      - without a verdict file the metrics verdict keeps deciding (legacy runs).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$VerdictFile = $null,
        [AllowNull()][object]$Metrics = $null,
        [string]$ObserveStatus = '',
        [string]$ObserveError = '',
        [string]$ObserveReasonCode = '',
        [string]$PrepareError = '',
        # Phase 5.3 B4: the floor scenario is the environment control. Its
        # failures are fixture/DNS evidence, never a product verdict.
        [string]$Scenario = ''
    )
    $isFloor = ($Scenario -match 'first-visit-floor')
    # Phase 6 C: the real-site canary never fails the run: CANARY-PASS and
    # CANARY-RED are both non-blocking categories; only INFRA is a failure.
    $isSite = ($Scenario -match 'first-visit-site')
    $outcome = [ordered]@{
        category            = 'UNKNOWN'
        verdict             = 'unknown'
        reasons             = @()
        error               = ''
        productReasons      = @()
        evidenceIncomplete  = $false
        blockedPathEnforced = $null
        blockedPathFinal    = $false
        hostStarted         = $null
        collectError        = ''
    }
    if ($VerdictFile) {
        $verdictObject = Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'verdict'
        $outcome.verdict = [string](Get-OpenPathFirstVisitOutcomeField -InputObject $verdictObject -Name 'status')
        $outcome.reasons = @(Get-OpenPathFirstVisitOutcomeField -InputObject $verdictObject -Name 'reasons')
        $outcome.productReasons = @(Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'productReasons')
        $outcome.evidenceIncomplete = [bool](Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'evidenceIncomplete')
        $outcome.blockedPathFinal = [bool](Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'blockedPathFinal')
        $outcome.collectError = [string](Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'collectError')
        $blockedPath = Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'blockedPathEnforced'
        if ($null -ne $blockedPath) { $outcome.blockedPathEnforced = [bool]$blockedPath }
        $hostStarted = Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'hostStarted'
        if ($null -ne $hostStarted) { $outcome.hostStarted = [bool]$hostStarted }
        if ($isSite) {
            # Canary classification: the document was written by the controller
            # after the collect; evidence incompleteness (or an observe error
            # without a canary status) is INFRA, otherwise the canary status
            # itself is the category. Phase 6.1 B: a scene that never navigated
            # to the site host is INFRA site-not-navigated.
            $canaryStatus = [string](Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'canaryStatus')
            $siteNavigated = Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'siteNavigated'
            if ($outcome.evidenceIncomplete) {
                $outcome.category = 'INFRA'
                $outcome.error = if ($outcome.collectError) { $outcome.collectError } elseif ($ObserveError) { $ObserveError } else { 'evidence-incomplete' }
            }
            elseif ($null -ne $siteNavigated -and -not [bool]$siteNavigated) {
                $outcome.category = 'INFRA'
                $outcome.error = 'site-not-navigated'
            }
            elseif ($canaryStatus -in @('CANARY-PASS', 'CANARY-RED')) {
                $outcome.category = $canaryStatus
                $outcome.error = ''
                $canaryReasons = @(Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'canaryReasons')
                if ($canaryReasons.Count -gt 0) { $outcome.reasons = @($canaryReasons) }
            }
            elseif ($ObserveError) {
                $outcome.category = 'INFRA'
                $outcome.error = $ObserveError
            }
            else {
                $outcome.category = 'INFRA'
                $outcome.error = 'canary-status-missing'
            }
            return [pscustomobject]$outcome
        }
        if ($Metrics) {
            $outcome.evidenceIncomplete = $outcome.evidenceIncomplete -or [bool](Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'evidenceIncomplete')
            if (-not $outcome.collectError) { $outcome.collectError = [string](Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'collectError') }
            if ($null -eq $outcome.blockedPathEnforced) {
                $metricsBlocked = Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'blockedPathEnforced'
                if ($null -ne $metricsBlocked) { $outcome.blockedPathEnforced = [bool]$metricsBlocked }
            }
        }
        $reportPresent = [bool](Get-OpenPathFirstVisitOutcomeField -InputObject $VerdictFile -Name 'reportPresent')
        if (-not $reportPresent) {
            $outcome.category = 'INFRA'
            $outcome.error = if ($ObserveError) { $ObserveError } else { 'no-self-report' }
        }
        elseif ($outcome.verdict -ne 'passed' -or $outcome.productReasons.Count -gt 0) {
            $outcome.category = 'PRODUCT'
            if ($ObserveError) { $outcome.error = $ObserveError }
            elseif ($outcome.reasons.Count -gt 0) { $outcome.error = (@($outcome.reasons) -join ',') }
            else { $outcome.error = (@($outcome.productReasons) -join ',') }
        }
        elseif (($null -ne $Metrics) -and -not $outcome.evidenceIncomplete) {
            $outcome.category = 'PASS'
        }
        else {
            $outcome.category = 'INFRA'
            $outcome.evidenceIncomplete = $true
            if ($outcome.collectError) { $outcome.error = $outcome.collectError }
            elseif ($ObserveError) { $outcome.error = $ObserveError }
            else { $outcome.error = 'evidence-incomplete' }
        }
        if ($isFloor -and $outcome.category -eq 'PRODUCT') {
            # The floor is an environment control: a red floor means the
            # fixture/DNS/warm-session path could not deliver the waves, not a
            # product regression.
            $outcome.category = 'INFRA'
            $outcome.error = 'floor-not-green: ' + [string]$outcome.error
        }
        return [pscustomobject]$outcome
    }
    if ($Metrics) {
        $outcome.verdict = [string](Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'verdict')
        $outcome.reasons = @(Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'reasons')
        $warmup = Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'warmup'
        $outcome.productReasons = @(Get-OpenPathFirstVisitOutcomeField -InputObject $warmup -Name 'productReasons')
        $outcome.evidenceIncomplete = [bool](Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'evidenceIncomplete')
        $metricsBlocked = Get-OpenPathFirstVisitOutcomeField -InputObject $Metrics -Name 'blockedPathEnforced'
        if ($null -ne $metricsBlocked) { $outcome.blockedPathEnforced = [bool]$metricsBlocked }
        $outcome.hostStarted = [bool](Get-OpenPathFirstVisitOutcomeField -InputObject $warmup -Name 'hostStarted')
        if ($outcome.verdict -ne 'passed' -or $outcome.productReasons.Count -gt 0) { $outcome.category = 'PRODUCT' }
        elseif ($outcome.evidenceIncomplete) {
            $outcome.category = 'INFRA'
            $outcome.error = if ($ObserveError) { $ObserveError } else { 'evidence-incomplete' }
        }
        else { $outcome.category = 'PASS' }
        if ($isFloor -and $outcome.category -eq 'PRODUCT') {
            $outcome.category = 'INFRA'
            $outcome.error = 'floor-not-green: ' + [string]$outcome.error
        }
        return [pscustomobject]$outcome
    }
    $outcome.category = 'INFRA'
    $outcome.error = if ($ObserveError) { $ObserveError }
        elseif ($PrepareError) { $PrepareError }
        else { 'no-metrics-no-error' }
    if ($ObserveReasonCode -and $outcome.error -eq 'no-metrics-no-error') { $outcome.error = "no-metrics-$ObserveReasonCode" }
    return [pscustomobject]$outcome
}

Export-ModuleMember -Function Get-OpenPathFirstVisitSceneOutcome, Get-OpenPathFirstVisitOutcomeField
