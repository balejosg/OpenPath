# Phase 5.2 C4: first-visit lane budgets.
#
# The Phase 5 nightly ran 8 scenes (4 scenarios x 2) for ~30 min each because
# the collect step hung, and the workflow's 300-minute timeout cancelled the
# run mid-suite. The per-phase budgets below bound one scene; the contract test
# asserts the nightly plan fits with margin inside the workflow timeout.
#
# Observed phase durations (nightly 37189105161, before the collect fix):
#   prepare 421-498 s, cleanup 40-306 s; observe was unbounded by the hung
#   collect and is now bounded by the 120 s collect step.

function Get-OpenPathFirstVisitPhaseBudget {
    <#
    .SYNOPSIS
    Seconds allowed for one first-visit phase before a clean cancellation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Observe', 'AfterReboot', 'Cleanup')][string]$Mode
    )
    switch ($Mode) {
        'Prepare' { return 600 }
        'Observe' { return 600 }
        'AfterReboot' { return 600 }
        'Cleanup' { return 420 }
        default { return 600 }
    }
}

function Get-OpenPathFirstVisitSceneBudgetSeconds {
    <#
    .SYNOPSIS
    Upper bound of one scene (prepare + observe + cleanup) in seconds.
    #>
    [CmdletBinding()]
    param()
    return (Get-OpenPathFirstVisitPhaseBudget -Mode Prepare) + (Get-OpenPathFirstVisitPhaseBudget -Mode Observe) + (Get-OpenPathFirstVisitPhaseBudget -Mode Cleanup)
}

function Test-OpenPathFirstVisitPlanFitsBudget {
    <#
    .SYNOPSIS
    Checks scenes x scene budget + suite overhead against a workflow timeout.
    .DESCRIPTION
    Pure so the contract test can feed the real workflow timeout-minutes and
    the real scheduled plan. The limit uses 80% of the workflow timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$SceneCount,
        [Parameter(Mandatory = $true)][int]$WorkflowTimeoutMinutes,
        [int]$SuiteOverheadMinutes = 15,
        [int]$LimitPercent = 80
    )
    $sceneMinutes = [double](Get-OpenPathFirstVisitSceneBudgetSeconds) / 60.0
    $totalMinutes = ($SceneCount * $sceneMinutes) + $SuiteOverheadMinutes
    $limitMinutes = [double]$WorkflowTimeoutMinutes * ($LimitPercent / 100.0)
    return [pscustomobject][ordered]@{
        sceneCount        = $SceneCount
        sceneBudgetMinutes = [math]::Round($sceneMinutes, 2)
        overheadMinutes   = $SuiteOverheadMinutes
        totalMinutes      = [math]::Round($totalMinutes, 2)
        limitMinutes      = [math]::Round($limitMinutes, 2)
        fits              = ($totalMinutes -le $limitMinutes)
    }
}

Export-ModuleMember -Function Get-OpenPathFirstVisitPhaseBudget, Get-OpenPathFirstVisitSceneBudgetSeconds, Test-OpenPathFirstVisitPlanFitsBudget
