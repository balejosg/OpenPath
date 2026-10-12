# Phase 8d D1: host-recovery scene analysis for the first-visit lane.
#
# The host-recovery scenario reproduces the state a failed install health check
# leaves behind (the Phase 8c E2E 38208889929: no compiled executable or build
# manifest, an expired HealthCheckFailed backoff and the Firefox messaging
# manifest pointing at the cmd fallback), keeps a student Firefox session with
# the PowerShell host denied, then runs the real periodic OpenPath-Update task.
# The acceptance bound is: the messaging manifest points at the recovered
# executable within 6 minutes of the trigger and the student probe passes (the
# executable pongs and powershell.exe stays denied). The helpers are pure so the
# lane tests can execute them without a VM; the data comes from the guest step
# evidence only.

function Get-OpenPathFirstVisitHostRecoveryField {
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

function Get-OpenPathFirstVisitHostRecovery {
    <#
    .SYNOPSIS
    Host-recovery acceptance analysis for one scene.
    .DESCRIPTION
    Returns the trigger evidence, the recovered state and the student probe
    classification. HOST-RECOVERY-PASS requires the manifest to point at the
    recovered executable within the budget (or to have been recovered before
    the explicit trigger), the ensure stage line actually observed and the
    student probe ping + powershell denial. The extension's no-restart
    behaviour is informational and never changes the verdict.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$TriggerEvidence = $null,
        # Explicit probe override; the trigger evidence's embedded probe wins
        # when this is absent.
        [AllowNull()][object]$StudentProbe = $null,
        [int]$MaxRecoveryMs = 360000
    )

    $manifestAfter = [string](Get-OpenPathFirstVisitHostRecoveryField -InputObject $TriggerEvidence -Name 'manifestAfter')
    $recovered = ($manifestAfter -eq 'exe')
    $recoveredBeforeTrigger = [bool](Get-OpenPathFirstVisitHostRecoveryField -InputObject $TriggerEvidence -Name 'recoveredBeforeTrigger')
    $recoveryMs = -1
    $rawRecoveryMs = Get-OpenPathFirstVisitHostRecoveryField -InputObject $TriggerEvidence -Name 'recoveryMs'
    if ($null -ne $rawRecoveryMs) { $recoveryMs = [int]$rawRecoveryMs }
    $ensureLine = [string](Get-OpenPathFirstVisitHostRecoveryField -InputObject $TriggerEvidence -Name 'ensureLine')
    $triggerError = [string](Get-OpenPathFirstVisitHostRecoveryField -InputObject $TriggerEvidence -Name 'error')
    if (-not $StudentProbe) {
        $StudentProbe = Get-OpenPathFirstVisitHostRecoveryField -InputObject $TriggerEvidence -Name 'studentProbe'
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $TriggerEvidence) {
        $reasons.Add('trigger-step-missing') | Out-Null
    }
    else {
        if (-not $recovered) {
            $reasons.Add('manifest-not-recovered') | Out-Null
        }
        elseif ($recoveryMs -ge 0) {
            if ($recoveryMs -gt $MaxRecoveryMs) { $reasons.Add("recovery-over-budget:$recoveryMs") | Out-Null }
        }
        elseif (-not $recoveredBeforeTrigger) {
            $reasons.Add('recovery-time-not-measured') | Out-Null
        }
        if (-not $ensureLine) { $reasons.Add('ensure-stage-line-missing') | Out-Null }
        if ($triggerError) { $reasons.Add("trigger-error:$triggerError") | Out-Null }
    }

    $probePresent = ($null -ne $StudentProbe)
    $probePing = $false
    $probeDenied = $false
    $probeMeasured = $false
    if ($probePresent) {
        $probePing = [bool](Get-OpenPathFirstVisitHostRecoveryField -InputObject $StudentProbe -Name 'pingResponded')
        $probeDenied = [bool](Get-OpenPathFirstVisitHostRecoveryField -InputObject $StudentProbe -Name 'deniedPowershell')
        $probeMeasured = [bool](Get-OpenPathFirstVisitHostRecoveryField -InputObject $StudentProbe -Name 'events8004Measured')
    }
    if (-not $probePresent) {
        $reasons.Add('student-probe-missing') | Out-Null
    }
    else {
        if (-not $probePing) { $reasons.Add('student-probe-ping-missing') | Out-Null }
        if (-not $probeDenied) { $reasons.Add('powershell-not-denied') | Out-Null }
    }

    $passed = ($reasons.Count -eq 0)
    return [ordered]@{
        scenario              = 'first-visit-host-recovery'
        manifestAfter         = $manifestAfter
        recovered             = $recovered
        recoveredBeforeTrigger = $recoveredBeforeTrigger
        recoveryMs            = $recoveryMs
        maxRecoveryMs         = $MaxRecoveryMs
        ensureLine            = $ensureLine
        probePresent          = $probePresent
        probePing             = $probePing
        probePowershellDenied = $probeDenied
        probeMeasured         = $probeMeasured
        extensionRecovery     = Get-OpenPathFirstVisitHostRecoveryField -InputObject $TriggerEvidence -Name 'extensionRecovery'
        verdict               = if ($passed) { 'HOST-RECOVERY-PASS' } else { 'HOST-RECOVERY-RED' }
        reasons               = @($reasons.ToArray())
    }
}

Export-ModuleMember -Function `
    Get-OpenPathFirstVisitHostRecoveryField, `
    Get-OpenPathFirstVisitHostRecovery
