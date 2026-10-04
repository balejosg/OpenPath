# Phase 5.2 C5: auto-run supersede guard.
#
# A release-scripts run that finishes triggers the lane through workflow_run.
# When several REL runs are queued behind the lab lock, every completion
# schedules a lane evaluation of an older SHA. The newest non-cancelled REL run
# owns the verdict; older auto-runs end as skipped-superseded with a summary.
#
# Pure decision over the REST workflow_runs shape so the contract tests can
# feed recorded responses.

function Get-OpenPathFirstVisitSupersedeDecision {
    <#
    .SYNOPSIS
    True when a newer, non-cancelled release-scripts run exists.
    .DESCRIPTION
    `Runs` are workflow_run objects (id, created_at, status, conclusion) of the
    same workflow on main. A run that completed as cancelled does not supersede;
    a queued/in-progress or successful newer run does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TriggerRunId,
        [Parameter(Mandatory = $true)][string]$TriggerCreatedAt,
        [AllowNull()][object[]]$Runs = @()
    )
    $triggerTime = $null
    try { $triggerTime = ([datetime]$TriggerCreatedAt).ToUniversalTime() } catch { $triggerTime = $null }
    if ($null -eq $triggerTime) {
        return [pscustomobject][ordered]@{ superseded = $false; newerRunId = ''; reason = 'trigger-time-unparseable' }
    }
    $newest = $null
    foreach ($run in @($Runs)) {
        if ($null -eq $run) { continue }
        $id = [string](Get-FirstVisitSupersedeField -InputObject $run -Name 'id')
        if (-not $id -or $id -eq [string]$TriggerRunId) { continue }
        $createdAt = Get-FirstVisitSupersedeField -InputObject $run -Name 'created_at'
        if (-not $createdAt) { continue }
        $created = $null
        try { $created = ([datetime]$createdAt).ToUniversalTime() } catch { continue }
        if ($created -le $triggerTime) { continue }
        $status = [string](Get-FirstVisitSupersedeField -InputObject $run -Name 'status')
        $conclusion = [string](Get-FirstVisitSupersedeField -InputObject $run -Name 'conclusion')
        if ($status -eq 'completed' -and $conclusion -eq 'cancelled') { continue }
        if ($null -eq $newest -or $created -gt $newest.created) { $newest = [pscustomobject]@{ id = $id; created = $created } }
    }
    if ($newest) {
        return [pscustomobject][ordered]@{ superseded = $true; newerRunId = $newest.id; reason = 'newer-release-scripts-run' }
    }
    return [pscustomobject][ordered]@{ superseded = $false; newerRunId = ''; reason = 'newest-run' }
}

function Get-FirstVisitSupersedeField {
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

Export-ModuleMember -Function Get-OpenPathFirstVisitSupersedeDecision
