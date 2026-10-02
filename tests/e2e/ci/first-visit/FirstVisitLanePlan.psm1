# Phase 3A.2 K2: first-visit lane trigger planning.
#
# The change detection works on a push *range* (head_sha against the newest
# comparable base), never the last commit alone, and the scenario plan depends
# on the trigger (REL completion, nightly schedule or manual dispatch). Both are
# pure functions so the contract tests can exercise them without a runner.

function Test-OpenPathFirstVisitRelevantPath {
    <#
    .SYNOPSIS
    True when any changed path can affect the first-visit lane.
    #>
    [CmdletBinding()]
    param([string[]]$Paths = @())
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $normalized = ([string]$path).Trim() -replace '\\', '/'
        if ($normalized -like 'firefox-extension/src/*' -or
            $normalized -like 'firefox-extension/native/*' -or
            $normalized -like 'windows/lib/*' -or
            $normalized -like 'windows/scripts/*' -or
            $normalized -like 'tests/e2e/ci/first-visit/*' -or
            $normalized -like 'tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1' -or
            $normalized -like 'tests/e2e/ci/aggregate-windows-first-visit.ps1' -or
            $normalized -like '*run-windows-first-visit-suite.ps1*' -or
            $normalized -like '*windows-first-visit-lab.yml*') {
            return $true
        }
    }
    return $false
}

function Get-OpenPathFirstVisitScenarioPlan {
    <#
    .SYNOPSIS
    Scenarios and repetitions for the current trigger.
    .DESCRIPTION
    workflow_run (after a successful REL): W and B, each with the X pass in the
    same session.  schedule (nightly): W, W2, B and C with X, two repetitions.
    workflow_dispatch: whatever the caller asked for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventName,
        [string]$RequestedScenarios = '',
        [string]$RequestedRepetitions = ''
    )
    switch ($EventName) {
        'schedule' {
            return [pscustomobject]@{ scenarios = 'settled,hot,class-boot,control'; repetitions = 2; source = 'schedule' }
        }
        'workflow_dispatch' {
            $scenarios = if ([string]::IsNullOrWhiteSpace($RequestedScenarios)) { 'settled,class-boot' } else { $RequestedScenarios.Trim() }
            $repetitions = 1
            if (-not [string]::IsNullOrWhiteSpace($RequestedRepetitions)) {
                $parsed = 0
                if ([int]::TryParse($RequestedRepetitions.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 20) { $repetitions = $parsed }
            }
            return [pscustomobject]@{ scenarios = $scenarios; repetitions = $repetitions; source = 'dispatch' }
        }
        default {
            return [pscustomobject]@{ scenarios = 'settled,class-boot'; repetitions = 1; source = 'workflow_run' }
        }
    }
}

function Get-OpenPathFirstVisitScopeDecision {
    <#
    .SYNOPSIS
    Pure decision for the workflow_run range check.
    .DESCRIPTION
    Candidates are the previous evaluations of this lane and the previous
    successful release-scripts runs, newest first. The first candidate that is
    an ancestor of the head provides the base for the diff. No comparable base
    (or an undeterminable diff) fails open: the lane that captures the broken
    first visit must never silently skip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventName,
        [string]$HeadSha = '',
        [object[]]$Candidates = @(),
        [scriptblock]$IsAncestor = $null,
        [scriptblock]$DiffFiles = $null
    )
    if ($EventName -ne 'workflow_run') {
        return [pscustomobject]@{ run = $true; base = ''; reason = 'non-workflow-run' }
    }
    if ([string]::IsNullOrWhiteSpace($HeadSha)) {
        return [pscustomobject]@{ run = $true; base = ''; reason = 'missing-head-sha' }
    }
    foreach ($candidate in @($Candidates)) {
        $sha = [string](Get-FirstVisitPlanField -InputObject $candidate -Name 'sha')
        if ([string]::IsNullOrWhiteSpace($sha) -or $sha -eq $HeadSha) { continue }
        $ancestor = $false
        if ($IsAncestor) {
            try { $ancestor = [bool](& $IsAncestor $sha $HeadSha) } catch { $ancestor = $false }
        }
        if (-not $ancestor) { continue }
        $files = @()
        if ($DiffFiles) {
            try { $files = @(& $DiffFiles $sha $HeadSha) } catch { $files = @() }
        }
        if ($files.Count -eq 0) {
            return [pscustomobject]@{ run = $true; base = $sha; reason = 'empty-diff-fail-open' }
        }
        $relevant = Test-OpenPathFirstVisitRelevantPath -Paths $files
        return [pscustomobject]@{
            run    = $relevant
            base   = $sha
            reason = if ($relevant) { 'relevant-change' } else { 'no-relevant-change' }
        }
    }
    return [pscustomobject]@{ run = $true; base = ''; reason = 'no-comparable-base-fail-open' }
}

function Get-FirstVisitPlanField {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

Export-ModuleMember -Function Test-OpenPathFirstVisitRelevantPath, Get-OpenPathFirstVisitScenarioPlan, Get-OpenPathFirstVisitScopeDecision
