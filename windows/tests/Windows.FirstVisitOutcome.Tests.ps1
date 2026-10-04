# Phase 5.2 C1: scene outcome classification contract.
#
# The three shapes below are the recorded nightly 37189105161 scenes
# (settled-r1/hot-r1/class-boot-r1): the page self-report was complete with
# every wave false while the collect step hung, and the scene must stay
# PRODUCT red instead of INFRA.

Describe 'First-visit scene outcome (Phase 5.2 C1)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitOutcome.psm1') -Force

        function New-NightlyVerdictFile {
            param(
                [bool]$ReportPresent = $true,
                [string]$VerdictStatus = 'failed',
                [string[]]$ProductReasons = @(),
                [bool]$EvidenceIncomplete = $false,
                [string]$CollectError = ''
            )
            return [pscustomobject]@{
                schemaVersion       = 1
                scenario            = 'first-visit-settled'
                source              = 'self-report+prepare'
                verdict             = [pscustomobject]@{ status = $VerdictStatus; reasons = @('wave1-incomplete-or-over-threshold', 'wave2-incomplete-or-over-threshold', 'wave3-incomplete-or-over-threshold') }
                reportPresent       = $ReportPresent
                productReasons      = $ProductReasons
                hostStarted         = $true
                blockedByAppControl = $false
                blockedPathEnforced = $false
                blockedPathFinal    = $true
                evidenceIncomplete  = $EvidenceIncomplete
                collectError        = $CollectError
            }
        }

        function New-MetricsObject {
            param(
                [string]$Verdict = 'failed',
                [bool]$EvidenceIncomplete = $false,
                [string[]]$ProductReasons = @()
            )
            return [pscustomobject]@{
                verdict            = $Verdict
                reasons            = @('wave1-incomplete-or-over-threshold')
                evidenceIncomplete = $EvidenceIncomplete
                warmup             = [pscustomobject]@{ productReasons = $ProductReasons; hostStarted = $true }
            }
        }
    }

    It 'Keeps the nightly failed self-report as PRODUCT even without metrics' {
        $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile (New-NightlyVerdictFile) -Metrics $null -ObserveError 'controller-timeout: in-step=collect runningMs=1500000'
        $outcome.category | Should -Be 'PRODUCT'
        $outcome.verdict | Should -Be 'failed'
        $outcome.productReasons.Count | Should -Be 0
    }

    It 'Classifies the control scene as PRODUCT from the prepare product reasons even with a hung collect' {
        $verdictFile = New-NightlyVerdictFile -ProductReasons @('native-host-blocked-by-appcontrol')
        $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile $verdictFile -Metrics $null
        $outcome.category | Should -Be 'PRODUCT'
        $outcome.productReasons | Should -Contain 'native-host-blocked-by-appcontrol'
    }

    It 'Passes only with a passed verdict, metrics and complete evidence' {
        $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile (New-NightlyVerdictFile -VerdictStatus 'passed') -Metrics (New-MetricsObject -Verdict 'passed')
        $outcome.category | Should -Be 'PASS'
    }

    It 'Never claims a pass when the collect evidence is incomplete' {
        $verdictFile = New-NightlyVerdictFile -VerdictStatus 'passed' -EvidenceIncomplete $true -CollectError 'first-visit-guest-report-missing-observe-collect'
        $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile $verdictFile -Metrics (New-MetricsObject -Verdict 'passed' -EvidenceIncomplete $true)
        $outcome.category | Should -Be 'INFRA'
        $outcome.evidenceIncomplete | Should -BeTrue
        $outcome.error | Should -Be 'first-visit-guest-report-missing-observe-collect'
    }

    It 'Treats a missing self-report as INFRA, not as a product failure' {
        $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile (New-NightlyVerdictFile -ReportPresent $false) -Metrics $null -ObserveError 'first-visit-guest-result-missing-observe-collect'
        $outcome.category | Should -Be 'INFRA'
        $outcome.error | Should -Be 'first-visit-guest-result-missing-observe-collect'
    }

    It 'Falls back to the metrics verdict for legacy scenes without a verdict file' {
        $outcome = Get-OpenPathFirstVisitSceneOutcome -Metrics (New-MetricsObject -Verdict 'failed')
        $outcome.category | Should -Be 'PRODUCT'
        $outcome.verdict | Should -Be 'failed'
    }

    It 'Reports INFRA with a literal cause when nothing was measured' {
        $withObserve = Get-OpenPathFirstVisitSceneOutcome -ObserveError 'controller-exit-1: CONTROLLER_PHASE_FAILED: boom'
        $withObserve.category | Should -Be 'INFRA'
        $withObserve.error | Should -Be 'controller-exit-1: CONTROLLER_PHASE_FAILED: boom'
        $bare = Get-OpenPathFirstVisitSceneOutcome
        $bare.category | Should -Be 'INFRA'
        $bare.error | Should -Be 'no-metrics-no-error'
    }

    It 'Exposes the blocked-path probe result and the collect error' {
        $verdictFile = New-NightlyVerdictFile -VerdictStatus 'passed' -CollectError 'collect-timeout'
        $verdictFile.blockedPathEnforced = $false
        $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile $verdictFile -Metrics (New-MetricsObject -Verdict 'passed' -EvidenceIncomplete $true)
        $outcome.blockedPathEnforced | Should -BeFalse
        $outcome.collectError | Should -Be 'collect-timeout'
    }
}
