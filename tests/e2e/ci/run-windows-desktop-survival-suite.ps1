<##
.SYNOPSIS
    Runs the four-scenario desktop-survival matrix through the external controller.
##>
[CmdletBinding()]
param(
    [ValidateSet('DesktopSurvival', 'PolicyConverterContrast')][string]$SuiteKind = 'DesktopSurvival',
    [ValidateSet('Untouched', 'Started')][string]$PolicyConverterMode = 'Untouched',
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$RunAttempt,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ArtifactsRoot,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TemplatePath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$PersonalizedExePath,
    [string]$ControllerCommand
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ControllerCommand) -or -not (Test-Path -LiteralPath $ControllerCommand -PathType Leaf)) {
    [Console]::Error.WriteLine('BLOCKED_PLATFORM_VALIDATION: no authorized disposable Windows controller is configured.')
    exit 2
}
$scenarioIds = @(
    'win11-pro-profileless-empty',
    'win11-pro-existing-empty',
    'win11-education-profileless-empty',
    'win11-education-existing-empty'
)
$scenarioIds = if ($SuiteKind -eq 'DesktopSurvival') {
    $scenarioIds
}
else {
    # The PolicyConverter contrast is intentionally a separate scenario and
    # must never be mistaken for a desktop-survival aggregate.  The external
    # controller receives the kind/mode in the payload and runs the existing
    # contrast harness inside its independent disposable guest.
    @("win11-policy-converter-$($PolicyConverterMode.ToLowerInvariant())")
}
$phaseScript = Join-Path $PSScriptRoot 'run-windows-desktop-survival.ps1'

$hostCommand = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue
if ($null -eq $hostCommand) { $hostCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue }
if ($null -eq $hostCommand) { [Console]::Error.WriteLine('BLOCKED_PLATFORM_VALIDATION: PowerShell host unavailable.'); exit 2 }
$env:OPENPATH_SUITE_KIND = $SuiteKind
$env:OPENPATH_POLICY_CONVERTER_MODE = if ($SuiteKind -eq 'PolicyConverterContrast') { $PolicyConverterMode } else { '' }
$failed = $false
$blocked = $false
foreach ($scenarioId in $scenarioIds) {
    # Inputs and observations share the same immutable run/attempt/scenario
    # boundary. The external controller must not be given a writable path
    # outside that boundary.
    $scenarioRoot = Join-Path (Join-Path (Join-Path $ArtifactsRoot $RunId) ([string]$RunAttempt)) $scenarioId
    New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
    $scenarioPayload = Join-Path $scenarioRoot 'controller-payload.json'
    if (-not (Test-Path -LiteralPath $scenarioPayload -PathType Leaf)) {
        [IO.File]::WriteAllText($scenarioPayload, '{"schemaVersion":2}', [Text.UTF8Encoding]::new($false))
    }

    $scenarioFailed = $false
    try {
        foreach ($mode in @('Prepare', 'Observe', 'AfterReboot')) {
            # PolicyConverter uses the same external process boundary.  Its
            # payload is enriched by the controller adapter; this worker still
            # never starts PolicyConverter or mutates the guest itself.
            $phaseArguments = @('-NoProfile', '-NonInteractive')
            if ([IO.Path]::GetFileName($hostCommand.Source) -ieq 'powershell.exe') { $phaseArguments += @('-ExecutionPolicy', 'Bypass') }
            & $hostCommand.Source @phaseArguments -File $phaseScript -Mode $mode -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $scenarioId -ArtifactsRoot $ArtifactsRoot -TemplatePath $TemplatePath -PersonalizedExePath $PersonalizedExePath -ControllerCommand $ControllerCommand -ControllerPayloadPath $scenarioPayload
            $phaseExit = $LASTEXITCODE
            if ($phaseExit -ne 0) {
                $scenarioFailed = $true
                if ($phaseExit -eq 2) { $blocked = $true }
                break
            }
        }
    }
    catch {
        $scenarioFailed = $true
        [Console]::Error.WriteLine(('DESKTOP_SURVIVAL_SCENARIO_FAILED: {0}' -f $_.Exception.Message))
    }
    finally {
        # Cleanup is attempted even when Prepare, Observe, or AfterReboot
        # fails.  A successful cleanup never turns the scenario green.
        $cleanupArguments = @('-NoProfile', '-NonInteractive')
        if ([IO.Path]::GetFileName($hostCommand.Source) -ieq 'powershell.exe') { $cleanupArguments += @('-ExecutionPolicy', 'Bypass') }
        & $hostCommand.Source @cleanupArguments -File $phaseScript -Mode Cleanup -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $scenarioId -ArtifactsRoot $ArtifactsRoot -TemplatePath $TemplatePath -PersonalizedExePath $PersonalizedExePath -ControllerCommand $ControllerCommand -ControllerPayloadPath $scenarioPayload
        $cleanupExit = $LASTEXITCODE
        if ($cleanupExit -ne 0) {
            $scenarioFailed = $true
            if ($cleanupExit -eq 2) { $blocked = $true }
        }
    }
    if ($scenarioFailed) {
        $failed = $true
    }
}
if ($blocked) { exit 2 }
if ($failed) { exit 1 }
exit 0
