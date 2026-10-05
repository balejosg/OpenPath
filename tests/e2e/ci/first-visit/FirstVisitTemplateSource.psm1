# Phase 3A.3 L1: first-visit lane template resolution.
#
# Resolves which release-scripts run provides the windows-offline-template
# artifact for a lane trigger. The resolution is a pure function over the GitHub
# REST shapes so the contract tests can execute it with recorded responses; the
# only side effect is the injectable `-ApiGet` call.
#
# Facts learned in Phase 3A.2/3A.3:
#   - the REST API returns `id` on a run object; `database_id` is null and must
#     never be read (workflow_run resolution failed with
#     "no successful release-scripts run" because of exactly that);
#   - a schedule trigger has no SHA in the event, so it must look up the newest
#     successful release-scripts run on main that still carries the artifact;
#   - a dispatch may name a run id directly, or a target SHA to search for.

function Get-FirstVisitTemplateField {
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

function Get-FirstVisitTemplateSourcePlan {
    <#
    .SYNOPSIS
    Trigger-specific intent for the template source (no API calls).
    .DESCRIPTION
    workflow_run: the completing release-scripts run id comes straight from the
    event. schedule: search the newest successful main run. dispatch: an
    explicit run id, a target SHA, or the newest successful main run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [string]$InputRunId = '',
        [string]$InputSha = '',
        [string]$WorkflowRunId = '',
        [string]$WorkflowRunHeadSha = ''
    )
    switch ($EventName) {
        'workflow_run' {
            if ([string]::IsNullOrWhiteSpace($WorkflowRunId)) { throw 'first-visit-template-plan-invalid' }
            return [pscustomobject]@{
                mode = 'workflow-run'
                runId = $WorkflowRunId
                sha = $WorkflowRunHeadSha
                search = $false
            }
        }
        'schedule' {
            return [pscustomobject]@{ mode = 'latest'; runId = ''; sha = ''; search = $true }
        }
        'workflow_dispatch' {
            if (-not [string]::IsNullOrWhiteSpace($InputRunId)) {
                return [pscustomobject]@{ mode = 'dispatch-run'; runId = $InputRunId.Trim(); sha = ''; search = $false }
            }
            if (-not [string]::IsNullOrWhiteSpace($InputSha)) {
                return [pscustomobject]@{ mode = 'sha'; runId = ''; sha = $InputSha.Trim(); search = $true }
            }
            return [pscustomobject]@{ mode = 'latest'; runId = ''; sha = ''; search = $true }
        }
        default {
            # Any other trigger (for example a future push trigger) behaves like
            # the nightly: the lane must never silently skip a template lookup.
            return [pscustomobject]@{ mode = 'latest'; runId = ''; sha = ''; search = $true }
        }
    }
}

function Test-FirstVisitTemplateArtifact {
    <#
    .SYNOPSIS
    True when an artifacts listing contains the offline template artifact.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$ArtifactsResponse, [string]$ArtifactName = 'windows-offline-template')
    foreach ($artifact in @(Get-FirstVisitTemplateField -InputObject $ArtifactsResponse -Name 'artifacts')) {
        if ([string](Get-FirstVisitTemplateField -InputObject $artifact -Name 'name') -eq $ArtifactName) { return $true }
    }
    return $false
}

function Get-FirstVisitTemplateRunIdFromResponse {
    <#
    .SYNOPSIS
    Reads the REST run id (`id`, never `database_id`) from one listing entry.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$RunEntry)
    $id = [string](Get-FirstVisitTemplateField -InputObject $RunEntry -Name 'id')
    if ($id) { return $id }
    return ''
}

function Resolve-FirstVisitTemplateRun {
    <#
    .SYNOPSIS
    Resolves the release-scripts run id and template SHA for a plan.
    .DESCRIPTION
    `-ApiGet` is injectable for the contract tests; the default calls the GitHub
    REST API with the workflow token. Throws first-visit-template-not-found when
    no candidate carries the offline template artifact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [scriptblock]$ApiGet = $null,
        [string]$Repository = $env:GITHUB_REPOSITORY,
        [string]$ApiBase = 'https://api.github.com',
        [string]$ArtifactName = 'windows-offline-template',
        [int]$MaxCandidates = 30
    )
    if (-not $ApiGet) {
        if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -or [string]::IsNullOrWhiteSpace($Repository)) {
            throw 'first-visit-template-not-found'
        }
        $ApiGet = {
            param($Url)
            $headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json' }
            return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 60 -ErrorAction Stop
        }
    }
    $mode = [string](Get-FirstVisitTemplateField -InputObject $Plan -Name 'mode')

    if ($mode -eq 'workflow-run') {
        # No search: the completing release-scripts run is the source. The SHA is
        # available from the event for capability derivation.
        return [pscustomobject][ordered]@{
            runId               = [string](Get-FirstVisitTemplateField -InputObject $Plan -Name 'runId')
            templateSha         = [string](Get-FirstVisitTemplateField -InputObject $Plan -Name 'sha')
            mode                = $mode
            candidates          = 0
            lag                 = 0
            newestSuccessRunId  = [string](Get-FirstVisitTemplateField -InputObject $Plan -Name 'runId')
        }
    }

    if ($mode -eq 'dispatch-run') {
        $runId = [string](Get-FirstVisitTemplateField -InputObject $Plan -Name 'runId')
        $run = & $ApiGet "$ApiBase/repos/$Repository/actions/runs/$runId"
        $headSha = [string](Get-FirstVisitTemplateField -InputObject $run -Name 'head_sha')
        return [pscustomobject][ordered]@{
            runId               = $runId
            templateSha         = $headSha
            mode                = $mode
            candidates          = 0
            lag                 = 0
            newestSuccessRunId  = $runId
        }
    }

    # Phase 5.3 P3: never combine branch/head_sha with status=success. The REST
    # listing with that filter returns stale runs (the nightly of 2026-10-05
    # resolved a 2026-10-03 template). List completed runs and filter
    # conclusion=success on the client, which also lets us report the lag
    # against the newest successful main run.
    $query = if ($mode -eq 'sha') { 'head_sha=' + [string](Get-FirstVisitTemplateField -InputObject $Plan -Name 'sha') + '&per_page=50' } else { 'branch=main&per_page=50' }
    $listing = & $ApiGet "$ApiBase/repos/$Repository/actions/workflows/release-scripts.yml/runs?$query"
    $runs = @(Get-FirstVisitTemplateField -InputObject $listing -Name 'workflow_runs')
    $successful = @($runs | Where-Object { [string](Get-FirstVisitTemplateField -InputObject $_ -Name 'conclusion') -eq 'success' })
    $newestSuccessRunId = if ($successful.Count -gt 0) { [string](Get-FirstVisitTemplateRunIdFromResponse -RunEntry $successful[0]) } else { '' }
    $successIndex = 0
    $candidates = 0
    foreach ($run in $successful) {
        if ($candidates -ge $MaxCandidates) { break }
        $runId = Get-FirstVisitTemplateRunIdFromResponse -RunEntry $run
        if (-not $runId) { continue }
        $candidates += 1
        $artifacts = & $ApiGet "$ApiBase/repos/$Repository/actions/runs/$runId/artifacts?per_page=100"
        if (-not (Test-FirstVisitTemplateArtifact -ArtifactsResponse $artifacts -ArtifactName $ArtifactName)) { $successIndex += 1; continue }
        return [pscustomobject][ordered]@{
            runId               = $runId
            templateSha         = [string](Get-FirstVisitTemplateField -InputObject $run -Name 'head_sha')
            mode                = $mode
            candidates          = $candidates
            lag                 = if ($mode -eq 'latest') { $successIndex } else { 0 }
            newestSuccessRunId  = $newestSuccessRunId
        }
    }
    throw 'first-visit-template-not-found'
}

Export-ModuleMember -Function Get-FirstVisitTemplateSourcePlan, Resolve-FirstVisitTemplateRun, Test-FirstVisitTemplateArtifact, Get-FirstVisitTemplateRunIdFromResponse
