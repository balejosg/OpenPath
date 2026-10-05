# Phase 5.2 C4: the nightly plan must fit the lane workflow timeout with
# margin, or the run is cancelled mid-suite as in Phase 5.

Describe 'First-visit lane budgets (Phase 5.2 C4)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitBudget.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitLanePlan.psm1') -Force
        $workflowPath = Join-Path $PSScriptRoot '..\..\.github\workflows\windows-first-visit-lab.yml'
        $workflowText = Get-Content -LiteralPath $workflowPath -Raw
        $timeoutMatch = [regex]::Match($workflowText, 'timeout-minutes:\s*(\d+)')
        $script:WorkflowTimeoutMinutes = if ($timeoutMatch.Success) { [int]$timeoutMatch.Groups[1].Value } else { -1 }
    }

    It 'bounds every phase and one whole scene' {
        (Get-OpenPathFirstVisitPhaseBudget -Mode Prepare) | Should -Be 720
        (Get-OpenPathFirstVisitPhaseBudget -Mode Observe) | Should -Be 660
        (Get-OpenPathFirstVisitPhaseBudget -Mode Cleanup) | Should -Be 420
        (Get-OpenPathFirstVisitSceneBudgetSeconds) | Should -Be 1800
        # The collect step may only consume a fraction of the observe budget.
        (Get-OpenPathFirstVisitSceneBudgetSeconds) | Should -BeLessOrEqual 1800
    }

    It 'keeps the scheduled plan inside 80 percent of the workflow timeout' {
        $script:WorkflowTimeoutMinutes | Should -BeGreaterThan 0
        $plan = Get-OpenPathFirstVisitScenarioPlan -EventName 'schedule'
        $scenes = @($plan.scenarios -split ',').Count * [int]$plan.repetitions
        $scenes | Should -Be 8
        $check = Test-OpenPathFirstVisitPlanFitsBudget -SceneCount $scenes -WorkflowTimeoutMinutes $script:WorkflowTimeoutMinutes
        $check.fits | Should -BeTrue -Because ("{0} scenes x {1} min + overhead = {2} min vs limit {3} min" -f $check.sceneCount, $check.sceneBudgetMinutes, $check.totalMinutes, $check.limitMinutes)
    }

    It 'keeps the acceptance dispatch plan inside the same budget' {
        $plan = Get-OpenPathFirstVisitScenarioPlan -EventName 'workflow_dispatch' -RequestedScenarios 'settled,class-boot' -RequestedRepetitions '2'
        $scenes = @($plan.scenarios -split ',').Count * [int]$plan.repetitions
        $check = Test-OpenPathFirstVisitPlanFitsBudget -SceneCount $scenes -WorkflowTimeoutMinutes $script:WorkflowTimeoutMinutes
        $check.fits | Should -BeTrue
    }
}
