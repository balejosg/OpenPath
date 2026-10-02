# Phase 3A.2 K2: resolves whether the first-visit lane must run for a
# workflow_run completion, using a push range instead of the last commit only.
#
# Candidates, newest first, are queried from the GitHub REST API (the lab
# runner does not ship the gh CLI):
#   1. previous runs of this workflow on main (evaluated, any conclusion),
#   2. previous successful release-scripts runs on main.
# The first candidate that is an ancestor of head_sha provides the diff base.
# Without a comparable base the lane fails open and runs.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [string]$EventName = $env:GITHUB_EVENT_NAME,
    [string]$HeadSha = $env:HEAD_SHA,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Token = $env:GH_TOKEN,
    [string]$ApiBase = 'https://api.github.com',
    [string]$OutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FirstVisitLanePlan.psm1') -Force

function Get-FirstVisitRunShas {
    param([string]$Workflow, [string]$Status = '')
    if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($Repository)) { return @() }
    $uri = "$ApiBase/repos/$Repository/actions/workflows/$Workflow/runs?branch=main&per_page=30"
    if ($Status) { $uri += "&status=$Status" }
    try {
        $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json' }
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60 -ErrorAction Stop
        return @($response.workflow_runs | ForEach-Object { [string]$_.head_sha })
    }
    catch {
        Write-Host "first-visit scope: unable to list $Workflow runs: $($_.Exception.Message)"
        return @()
    }
}

$candidates = @()
$seen = @{}
foreach ($sha in @(Get-FirstVisitRunShas -Workflow 'windows-first-visit-lab.yml') + @(Get-FirstVisitRunShas -Workflow 'release-scripts.yml' -Status 'success')) {
    if ([string]::IsNullOrWhiteSpace($sha) -or $seen.ContainsKey($sha)) { continue }
    $seen[$sha] = $true
    $candidates += [pscustomobject]@{ sha = $sha }
}

$isAncestor = {
    param($Base, $Head)
    & git -C $RepoRoot merge-base --is-ancestor $Base $Head 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
$diffFiles = {
    param($Base, $Head)
    $names = & git -C $RepoRoot diff --name-only $Base $Head 2>$null
    return @($names | Where-Object { $_ })
}

$decision = Get-OpenPathFirstVisitScopeDecision -EventName $EventName -HeadSha $HeadSha -Candidates $candidates -IsAncestor $isAncestor -DiffFiles $diffFiles
Write-Host "first-visit scope: run=$($decision.run) base=$($decision.base) reason=$($decision.reason)"
if ($OutputPath) {
    $runValue = if ($decision.run) { 'true' } else { 'false' }
    Add-Content -LiteralPath $OutputPath -Value "run=$runValue"
    Add-Content -LiteralPath $OutputPath -Value "base=$($decision.base)"
}
exit 0
