# Phase 8e: verdict for the Smart App Control scenes (sac-eval-off, sac-on-off,
# sac-on-keep).
#
# The scenes install the offline template on VM 111 under explicit SAC
# postures and prove the posture from the product's own evidence:
#   - eval-off: the snapshot starts in evaluation and the setup receives
#     -DisableSmartAppControl; the installer must leave SAC off and verified.
#   - on-off: SAC is applied and enforced before the install; the setup
#     receives the same flag and must turn SAC off before compiling.
#   - on-keep (control): SAC is applied and enforced before the install and the
#     setup receives no flag; SAC must stay on and the install must record the
#     visible warning.
# The positive control (a freshly compiled exe with and without MOTW) is the
# truth of "SAC is off": with SAC off it must never block; with SAC on it is
# informational only (the lab already measured it oscillating).

function Get-OpenPathFirstVisitSacSceneField {
    # Resolves a property from an object, array or $null without throwing.
    param(
        [AllowNull()][object]$InputObject = $null,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-OpenPathFirstVisitSacControlRan {
    # A control sample "ran" when the process started and returned the
    # expected exit code (0 or 7); a blocked launch never starts.
    param([AllowNull()][object]$Control = $null)

    $plainSamples = @(Get-OpenPathFirstVisitSacSceneField -InputObject $Control -Name 'plainSamples' | Where-Object { $null -ne $_ })
    if ($plainSamples.Count -eq 0) {
        $plain = Get-OpenPathFirstVisitSacSceneField -InputObject $Control -Name 'plain'
        if ($null -ne $plain) { $plainSamples = @($plain) }
    }
    foreach ($sample in $plainSamples) {
        $started = Get-OpenPathFirstVisitSacSceneField -InputObject $sample -Name 'started'
        $exitCode = Get-OpenPathFirstVisitSacSceneField -InputObject $sample -Name 'exitCode'
        if (([bool]$started) -and ($null -ne $exitCode) -and ([int]$exitCode -in @(0, 7))) { return $true }
    }
    return $false
}

function Test-OpenPathFirstVisitSacControlMotwRan {
    # MOTW copy ran when any sample started with the expected exit code.
    param([AllowNull()][object]$Control = $null)

    $motwSamples = @(Get-OpenPathFirstVisitSacSceneField -InputObject $Control -Name 'motwSamples' | Where-Object { $null -ne $_ })
    if ($motwSamples.Count -eq 0) {
        $motw = Get-OpenPathFirstVisitSacSceneField -InputObject $Control -Name 'motw'
        if ($null -ne $motw) { $motwSamples = @($motw) }
    }
    foreach ($sample in $motwSamples) {
        $started = Get-OpenPathFirstVisitSacSceneField -InputObject $sample -Name 'started'
        $exitCode = Get-OpenPathFirstVisitSacSceneField -InputObject $sample -Name 'exitCode'
        if (([bool]$started) -and ($null -ne $exitCode) -and ([int]$exitCode -in @(0, 7))) { return $true }
    }
    return $false
}

function Test-OpenPathFirstVisitSacPolicyApplied {
    # CiTool -lp lists a VerifiedAndReputable (SAC) policy: json mode first,
    # text mode as the fallback.
    param([AllowNull()][object]$State = $null)

    $ciTool = Get-OpenPathFirstVisitSacSceneField -InputObject $State -Name 'ciTool'
    $json = [string](Get-OpenPathFirstVisitSacSceneField -InputObject $ciTool -Name 'json')
    if ($json -and $json -match 'VerifiedAndReputable') { return $true }
    $raw = @(Get-OpenPathFirstVisitSacSceneField -InputObject $ciTool -Name 'raw')
    return [bool](($raw -join "`n") -match 'VerifiedAndReputable')
}

function Get-OpenPathFirstVisitSacSceneVerdict {
    <#
    .SYNOPSIS
        Pure verdict for the SAC scenes from the two sampled moments.
    .DESCRIPTION
        Samples are ordered: the first is taken right after the install
        ("install-end"), the second after the visit ("post-visit"). PASS
        requires a gap of at least 300 seconds between them (the scene
        criterion is "at install end and 5 minutes later").
        eval-off/on-off additionally require the student probe to answer and a
        forced recompile to end Built; on-keep requires the watchdog reason
        code and the durable installer warning instead (the host may or may not
        work with SAC on).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('eval-off', 'on-off', 'on-keep')][string]$Kind,
        [AllowEmptyCollection()][object[]]$Samples = @(),
        [AllowNull()][object]$HostProbe = $null,
        [AllowNull()][object]$Recompile = $null,
        [AllowNull()][object]$Watchdog = $null,
        [AllowNull()][object]$ProductVerdict = $null,
        [int]$MinimumGapSeconds = 300
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $first = if ($Samples.Count -ge 1) { $Samples[0] } else { $null }
    $second = if ($Samples.Count -ge 2) { $Samples[1] } else { $null }
    $firstState = Get-OpenPathFirstVisitSacSceneField -InputObject $first -Name 'state'
    $firstControl = Get-OpenPathFirstVisitSacSceneField -InputObject $first -Name 'control'
    $secondState = Get-OpenPathFirstVisitSacSceneField -InputObject $second -Name 'state'
    $secondControl = Get-OpenPathFirstVisitSacSceneField -InputObject $second -Name 'control'

    $firstAt = $null
    $secondAt = $null
    try { $firstAt = [DateTime]::Parse([string](Get-OpenPathFirstVisitSacSceneField -InputObject $firstState -Name 'at'), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $firstAt = $null }
    try { $secondAt = [DateTime]::Parse([string](Get-OpenPathFirstVisitSacSceneField -InputObject $secondState -Name 'at'), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $secondAt = $null }
    $gapSeconds = -1
    if ($firstAt -and $secondAt) { $gapSeconds = [int]($secondAt - $firstAt).TotalSeconds }

    if ($null -eq $firstState -or $null -eq $secondState) { $reasons.Add('sac-state-missing') | Out-Null }
    if ($null -eq $firstControl -or $null -eq $secondControl) { $reasons.Add('sac-control-missing') | Out-Null }
    if ($gapSeconds -ge 0 -and $gapSeconds -lt $MinimumGapSeconds) { $reasons.Add("sac-second-sample-too-early:${gapSeconds}s") | Out-Null }

    $firstValue = Get-OpenPathFirstVisitSacSceneField -InputObject $firstState -Name 'registryValue'
    $secondValue = Get-OpenPathFirstVisitSacSceneField -InputObject $secondState -Name 'registryValue'
    $firstPolicy = Test-OpenPathFirstVisitSacPolicyApplied -State $firstState
    $secondPolicy = Test-OpenPathFirstVisitSacPolicyApplied -State $secondState
    $firstPlainRan = Test-OpenPathFirstVisitSacControlRan -Control $firstControl
    $firstMotwRan = Test-OpenPathFirstVisitSacControlMotwRan -Control $firstControl
    $secondPlainRan = Test-OpenPathFirstVisitSacControlRan -Control $secondControl
    $secondMotwRan = Test-OpenPathFirstVisitSacControlMotwRan -Control $secondControl

    $hostProbePing = [bool](Get-OpenPathFirstVisitSacSceneField -InputObject $HostProbe -Name 'pingResponded')
    $hostProbeDenied = [bool](Get-OpenPathFirstVisitSacSceneField -InputObject $HostProbe -Name 'deniedPowershell')
    $hostProbePresent = ($null -ne $HostProbe)
    $recompileStatus = [string](Get-OpenPathFirstVisitSacSceneField -InputObject (Get-OpenPathFirstVisitSacSceneField -InputObject $Recompile -Name 'buildDiagnosticsJson') -Name 'status')
    $watchdogCodes = @(Get-OpenPathFirstVisitSacSceneField -InputObject $Watchdog -Name 'reasonCodes')
    $installWarningSeen = [bool](Get-OpenPathFirstVisitSacSceneField -InputObject $Watchdog -Name 'installWarningSeen')

    if ($Kind -in @('eval-off', 'on-off')) {
        if (-not (($null -ne $firstValue) -and [int]$firstValue -eq 0)) { $reasons.Add("sac-first-value:$firstValue") | Out-Null }
        if (-not (($null -ne $secondValue) -and [int]$secondValue -eq 0)) { $reasons.Add("sac-second-value:$secondValue") | Out-Null }
        # The policy listing settles after the reboot that the scene already
        # performs before the visit: right after `CiTool -r` the disabled
        # policy can still be listed (measured on VM 111), so only the second
        # moment - the one the criterion describes - requires it gone.
        if ($secondPolicy) { $reasons.Add('sac-second-policy-applied') | Out-Null }
        if (-not $firstPlainRan) { $reasons.Add('sac-first-control-plain-blocked') | Out-Null }
        if (-not $firstMotwRan) { $reasons.Add('sac-first-control-motw-blocked') | Out-Null }
        if (-not $secondPlainRan) { $reasons.Add('sac-second-control-plain-blocked') | Out-Null }
        if (-not $secondMotwRan) { $reasons.Add('sac-second-control-motw-blocked') | Out-Null }
        if (-not $hostProbePresent) { $reasons.Add('sac-host-probe-missing') | Out-Null }
        elseif (-not $hostProbePing) { $reasons.Add('sac-host-probe-ping-failed') | Out-Null }
        if ($recompileStatus -ne 'Built') { $reasons.Add("sac-recompile:$recompileStatus") | Out-Null }
        if ($null -ne $ProductVerdict) {
            $productState = [string](Get-OpenPathFirstVisitSacSceneField -InputObject $ProductVerdict -Name 'status')
            if ($productState -and $productState -ne 'passed') { $reasons.Add("sac-product-verdict:$productState") | Out-Null }
        }
    }
    else {
        # on-keep: SAC must stay enforced and the warning must be recorded.
        if (-not (($null -ne $firstValue) -and [int]$firstValue -eq 1)) { $reasons.Add("sac-first-value:$firstValue") | Out-Null }
        if (-not (($null -ne $secondValue) -and [int]$secondValue -eq 1)) { $reasons.Add("sac-second-value:$secondValue") | Out-Null }
        if (-not $firstPolicy) { $reasons.Add('sac-first-policy-missing') | Out-Null }
        if (-not $secondPolicy) { $reasons.Add('sac-second-policy-missing') | Out-Null }
        if ($watchdogCodes -notcontains 'smart_app_control_enforced') { $reasons.Add('sac-watchdog-code-missing') | Out-Null }
        if (-not $installWarningSeen) { $reasons.Add('sac-install-warning-missing') | Out-Null }
    }

    return [ordered]@{
        kind                 = $Kind
        status               = if ($reasons.Count -eq 0) { 'SAC-PASS' } else { 'SAC-RED' }
        reasons              = @($reasons)
        gapSeconds           = $gapSeconds
        firstValue           = $firstValue
        secondValue          = $secondValue
        firstPolicyApplied   = $firstPolicy
        secondPolicyApplied  = $secondPolicy
        firstPlainRan        = $firstPlainRan
        firstMotwRan         = $firstMotwRan
        secondPlainRan       = $secondPlainRan
        secondMotwRan        = $secondMotwRan
        hostProbePing        = $hostProbePing
        hostProbeDenied      = $hostProbeDenied
        recompileStatus      = $recompileStatus
        watchdogCodes        = @($watchdogCodes)
        installWarningSeen   = $installWarningSeen
    }
}

Export-ModuleMember -Function Get-OpenPathFirstVisitSacSceneField, Get-OpenPathFirstVisitSacSceneVerdict, Test-OpenPathFirstVisitSacControlRan, Test-OpenPathFirstVisitSacControlMotwRan, Test-OpenPathFirstVisitSacPolicyApplied
