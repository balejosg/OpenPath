# Phase 5.2 C5: the newest non-cancelled release-scripts run owns the verdict.

Describe 'First-visit auto-run supersede guard (Phase 5.2 C5)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitSupersedeGuard.psm1') -Force

        function New-RelRun {
            param([string]$Id, [string]$CreatedAt, [string]$Status = 'completed', [string]$Conclusion = 'success')
            return [pscustomobject]@{ id = $Id; created_at = $CreatedAt; status = $Status; conclusion = $Conclusion }
        }
    }

    It 'does not supersede the newest run' {
        $runs = @(
            (New-RelRun -Id '900' -CreatedAt '2026-10-04T13:48:13Z'),
            (New-RelRun -Id '800' -CreatedAt '2026-10-04T12:37:45Z')
        )
        $decision = Get-OpenPathFirstVisitSupersedeDecision -TriggerRunId '900' -TriggerCreatedAt '2026-10-04T13:48:13Z' -Runs $runs
        $decision.superseded | Should -BeFalse
        $decision.reason | Should -Be 'newest-run'
    }

    It 'supersedes an auto-run when a newer queued run exists' {
        $runs = @(
            (New-RelRun -Id '900' -CreatedAt '2026-10-04T13:48:13Z'),
            (New-RelRun -Id '901' -CreatedAt '2026-10-04T13:55:00Z' -Status 'queued' -Conclusion '')
        )
        $decision = Get-OpenPathFirstVisitSupersedeDecision -TriggerRunId '900' -TriggerCreatedAt '2026-10-04T13:48:13Z' -Runs $runs
        $decision.superseded | Should -BeTrue
        $decision.newerRunId | Should -Be '901'
    }

    It 'ignores a newer run that was cancelled' {
        $runs = @(
            (New-RelRun -Id '900' -CreatedAt '2026-10-04T13:48:13Z'),
            (New-RelRun -Id '901' -CreatedAt '2026-10-04T13:55:00Z' -Status 'completed' -Conclusion 'cancelled')
        )
        $decision = Get-OpenPathFirstVisitSupersedeDecision -TriggerRunId '900' -TriggerCreatedAt '2026-10-04T13:48:13Z' -Runs $runs
        $decision.superseded | Should -BeFalse
    }

    It 'ignores older runs and the trigger itself' {
        $runs = @(
            (New-RelRun -Id '700' -CreatedAt '2026-10-04T10:00:00Z'),
            (New-RelRun -Id '900' -CreatedAt '2026-10-04T13:48:13Z')
        )
        (Get-OpenPathFirstVisitSupersedeDecision -TriggerRunId '900' -TriggerCreatedAt '2026-10-04T13:48:13Z' -Runs $runs).superseded | Should -BeFalse
    }

    It 'fails open when the trigger timestamp cannot be parsed' {
        $decision = Get-OpenPathFirstVisitSupersedeDecision -TriggerRunId '900' -TriggerCreatedAt 'not-a-time' -Runs @()
        $decision.superseded | Should -BeFalse
        $decision.reason | Should -Be 'trigger-time-unparseable'
    }
}
