# Smart App Control (SAC) installer decision (Phase 8e E1).
#
# SAC (VerifiedAndReputablePolicyState in
# HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy: 0 off, 1 enforcement,
# 2 evaluation) protects Windows from unsigned binaries, including the
# locally compiled OpenPath native host. Windows offers no per-app bypass
# ("There is currently no way to bypass Smart App Control protection for
# individual apps"), and the evaluation state ends on its own: in managed
# classroom images it "switches off within 48 hours", so a host that works
# today can be blocked later without any OpenPath change.
#
# This step runs early (right after preflight, before Acrylic or the native
# host compile). It only ever changes the machine on an explicit
# administrator decision:
#   - off/not-configured: nothing to decide;
#   - evaluation/enforcement + interactive: explain, ask yes/no, apply only
#     on an explicit yes;
#   - evaluation/enforcement + unattended: only -DisableSmartAppControl
#     applies; otherwise SAC stays untouched and the install records a
#     visible warning.
# It never touches other Code Integrity or AppLocker policies.

function Get-OpenPathInstallerSmartAppControlState {
    <#
    .SYNOPSIS
        Minimal SAC state reader for the early installer phase.
    .DESCRIPTION
        Get-OpenPathSmartAppControlState (lib/internal/NativeHost.Build.ps1) is
        not loaded this early in the install. The value set is the same: off,
        not-configured, evaluation or enforcement; unknown never throws.
    #>
    [CmdletBinding()]
    param()

    $state = [ordered]@{
        State                     = 'unknown'
        VerifiedAndReputableState = $null
    }
    if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') { return [pscustomobject]$state }
    try {
        $policy = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue
        if ($policy -and $null -ne $policy.PSObject.Properties['VerifiedAndReputablePolicyState']) {
            $value = [int]$policy.VerifiedAndReputablePolicyState
            $state.VerifiedAndReputableState = $value
            switch ($value) {
                0 { $state.State = 'off' }
                1 { $state.State = 'enforcement' }
                2 { $state.State = 'evaluation' }
                default { $state.State = 'unknown' }
            }
        }
        else {
            $state.State = 'not-configured'
        }
    }
    catch { }
    return [pscustomobject]$state
}

function Invoke-OpenPathSmartAppControlStep {
    <#
    .SYNOPSIS
        Explicit Smart App Control decision before any unsigned binary runs.
    .DESCRIPTION
        Returns an outcome record (PreviousState, Action, Result,
        RebootRequired, DecidedAtUtc, Warning). Actions: none, declined,
        disabled or failed. The step never throws; a failing CiTool's
        refresh/verification leaves a reboot-required warning instead of
        aborting the install.
    #>
    [CmdletBinding()]
    param(
        [switch]$Unattended,
        [switch]$DisableSmartAppControl,
        [string]$OpenPathRoot = '',
        # Test seams.
        [scriptblock]$StateReader = $null,
        [scriptblock]$RegistryWriter = $null,
        [scriptblock]$CiToolInvoker = $null,
        [scriptblock]$Prompt = $null
    )

    $outcome = [ordered]@{
        PreviousState  = 'unknown'
        Action         = 'none'
        Result         = 'not-needed'
        RebootRequired = $false
        DecidedAtUtc   = [DateTime]::UtcNow.ToString('o')
        Warning        = ''
    }

    $state = $null
    try {
        $state = if ($StateReader) { & $StateReader } else { Get-OpenPathInstallerSmartAppControlState }
    }
    catch {
        $state = $null
    }
    if ($state -and $state.PSObject.Properties['State']) {
        $outcome.PreviousState = [string]$state.State
    }
    $previous = [string]$outcome.PreviousState

    if ($previous -notin @('evaluation', 'enforcement')) {
        Write-InstallerVerbose "  Smart App Control: $previous (no decision needed)"
        return [pscustomobject]$outcome
    }

    $explicit = [bool]$DisableSmartAppControl
    if (-not $explicit -and -not $Unattended) {
        Write-InstallerNotice '  Smart App Control can block the unsigned OpenPath native host, now or after Windows turns it on.'
        Write-InstallerNotice '  Turning it off affects the whole machine; students stay under the OpenPath AppLocker boundary.'
        Write-InstallerNotice '  Windows Security can turn it back on later.'
        $question = '  Disable Smart App Control now? (yes/no)'
        $answer = $false
        try {
            if ($Prompt) { $answer = [bool](& $Prompt $question) }
            else {
                $answerText = Read-Host $question
                $answer = [bool]($answerText -match '^(?i)(y|yes|s|si|sí)$')
            }
        }
        catch {
            $answer = $false
        }
        if (-not $answer) {
            $outcome.Action = 'declined'
            $outcome.Result = 'not-applied'
            $outcome.Warning = "Smart App Control is $previous and was left untouched by operator decision."
            Write-InstallerWarning "  WARNING: $($outcome.Warning)"
            return [pscustomobject]$outcome
        }
        $explicit = $true
    }

    if (-not $explicit) {
        # Unattended without the explicit switch: never change SAC silently.
        $outcome.Action = 'none'
        $outcome.Result = 'not-requested'
        $outcome.Warning = "Smart App Control is $previous and -DisableSmartAppControl was not passed; SAC stays untouched. The unsigned native host may be blocked now or after Windows enforces SAC. See windows/DEPLOYMENT.md (Smart App Control)."
        Write-InstallerWarning "  WARNING: $($outcome.Warning)"
        return [pscustomobject]$outcome
    }

    $writer = if ($RegistryWriter) {
        $RegistryWriter
    }
    else {
        {
            param([string]$Name, [int]$Value)
            Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name $Name -Value $Value -Type DWord -ErrorAction Stop
        }
    }
    $invoker = if ($CiToolInvoker) {
        $CiToolInvoker
    }
    else {
        {
            param([string[]]$Arguments)
            $systemRoot = if ($env:SystemRoot) { [string]$env:SystemRoot } else { 'C:\Windows' }
            $ciTool = Join-Path $systemRoot 'System32\CiTool.exe'
            if (-not (Test-Path -LiteralPath $ciTool -PathType Leaf)) {
                return [pscustomobject]@{ ExitCode = -1; Output = ''; Missing = $true }
            }
            try {
                $output = (& $ciTool @Arguments 2>&1 | Out-String)
                return [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = $output; Missing = $false }
            }
            catch {
                return [pscustomobject]@{ ExitCode = -1; Output = [string]$_; Missing = $false }
            }
        }
    }

    $refreshOk = $false
    $policyGone = $false
    $valueOff = $false
    $applyError = ''
    try {
        & $writer 'VerifiedAndReputablePolicyState' 0
        $refresh = & $invoker @('-r')
        $refreshOk = ($refresh -and $null -ne $refresh.ExitCode -and [int]$refresh.ExitCode -eq 0)
        if (-not $refreshOk) {
            $applyError = if ($refresh -and $refresh.PSObject.Properties['Missing'] -and [bool]$refresh.Missing) { 'CiTool.exe is not available' } else { "CiTool.exe -r failed (exit $($refresh.ExitCode))" }
        }
        elseif ($refresh.PSObject.Properties['Output'] -and ([string]$refresh.Output).Trim()) {
            # `CiTool -r` answers with a JSON policy list; a refused refresh can
            # still return exit 0, so the ASCII output is logged, never trusted.
            Write-InstallerVerbose "  CiTool -r output: $(([string]$refresh.Output).Trim())"
        }
        $afterState = if ($StateReader) { & $StateReader } else { Get-OpenPathInstallerSmartAppControlState }
        $afterValue = if ($afterState -and $afterState.PSObject.Properties['VerifiedAndReputableState']) { $afterState.VerifiedAndReputableState } else { $null }
        $valueOff = ($null -ne $afterValue -and [int]$afterValue -eq 0)
        if (-not $valueOff) { $applyError = 'the policy value did not settle to 0' }
        $list = & $invoker @('-lp')
        $listOk = ($list -and $null -ne $list.ExitCode -and [int]$list.ExitCode -eq 0)
        $listOutput = if ($list -and $list.PSObject.Properties['Output']) { [string]$list.Output } else { '' }
        $policyGone = $listOk -and ($listOutput -notmatch 'VerifiedAndReputable')
        if (-not $policyGone -and -not $applyError) { $applyError = 'CiTool.exe -lp still lists a VerifiedAndReputable policy' }
    }
    catch {
        $applyError = [string]$_
    }

    $outcome.Action = 'disabled'
    if ($refreshOk -and $valueOff -and $policyGone) {
        $outcome.Result = 'verified'
        Write-InstallerNotice '  Smart App Control disabled and verified (no VerifiedAndReputable policy applied).'
    }
    else {
        $outcome.Result = 'reboot-required'
        $outcome.RebootRequired = $true
        $outcome.Warning = "Smart App Control was set to off but the change could not be verified ($applyError). A reboot may be required for Windows to stop enforcing SAC. See windows/DEPLOYMENT.md (Smart App Control)."
        Write-InstallerWarning "  WARNING: $($outcome.Warning)"
    }
    return [pscustomobject]$outcome
}

function Write-OpenPathSmartAppControlDecision {
    <#
    .SYNOPSIS
        Records the SAC decision in the product log (previous state, action,
        result and date), when the logging helpers are available.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Outcome = $null)

    if (-not $Outcome) { return }
    $logCommand = Get-Command -Name Write-OpenPathLog -ErrorAction SilentlyContinue
    if (-not $logCommand) { return }
    $line = "Smart App Control decision: previous=$($Outcome.PreviousState) action=$($Outcome.Action) result=$($Outcome.Result) rebootRequired=$([bool]$Outcome.RebootRequired) decidedAt=$($Outcome.DecidedAtUtc)"
    # Phase 8e: the warning must survive unattended installs (the console
    # summary is ephemeral there), so the decision line is WARN when the
    # outcome carries one.
    $level = if ($Outcome.PSObject.Properties['Warning'] -and $Outcome.Warning) { 'WARN' } else { 'INFO' }
    Write-OpenPathLog $line -Level $level
}
