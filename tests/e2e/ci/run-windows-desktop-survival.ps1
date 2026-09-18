<##
.SYNOPSIS
    Records one externally controlled Windows desktop-survival phase.
.DESCRIPTION
    The worker never applies AppLocker or reboots the guest. It delegates the
    phase to an explicitly configured disposable-VM controller and fails closed
    when that controller is not available.
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Observe', 'AfterReboot', 'Cleanup')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$RunAttempt,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ScenarioId,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ArtifactsRoot,
    [string]$TemplatePath,
    [string]$PersonalizedExePath,
    [string]$ControllerCommand,
    [string]$ControllerPayloadPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DisposableWindowsTarget.psm1') -Force

$phase = switch ($Mode) {
    'Prepare' { 'prepare' }
    'Observe' { 'observe' }
    'AfterReboot' { 'afterReboot' }
    'Cleanup' { 'cleanup' }
}
$scenarioRoot = Join-Path (Join-Path (Join-Path $ArtifactsRoot $RunId) ([string]$RunAttempt)) $ScenarioId
New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
$phasePath = Join-Path $scenarioRoot "$phase.json"

function Get-OpenPathPhaseFileHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-OpenPathPhase {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Value)
    $temporary = "$phasePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $phasePath -Force -ErrorAction Stop
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

$common = [ordered]@{
    schemaVersion = 2
    runId = $RunId
    runAttempt = $RunAttempt
    sourceCommitSha = if ($env:OPENPATH_SOURCE_SHA) { $env:OPENPATH_SOURCE_SHA } else { '' }
    scenarioId = $ScenarioId
    phase = $phase
    evidenceRef = "$RunId/$RunAttempt/$ScenarioId/$phase-observation.json"
    startedAt = [DateTime]::UtcNow.ToString('O')
}
if ($TemplatePath) { $common.templateSha256 = Get-OpenPathPhaseFileHash -Path $TemplatePath }
if ($PersonalizedExePath) { $common.personalizedExeSha256 = Get-OpenPathPhaseFileHash -Path $PersonalizedExePath }

if ([string]::IsNullOrWhiteSpace($ControllerCommand)) {
    $common.status = 'blocked'
    $common.reasonCode = 'BLOCKED_PLATFORM_VALIDATION'
    $common.endedAt = [DateTime]::UtcNow.ToString('O')
    Write-OpenPathPhase -Value $common
    [Console]::Error.WriteLine('BLOCKED_PLATFORM_VALIDATION: an external disposable-VM controller is required.')
    exit 2
}

if ([string]::IsNullOrWhiteSpace($ControllerPayloadPath)) {
    throw '-ControllerPayloadPath is required when -ControllerCommand is supplied.'
}

$controllerResult = $null
try {
    $controllerResult = Invoke-OpenPathDisposableWindowsController -Command $ControllerCommand -Mode $Mode -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $ScenarioId -PayloadPath $ControllerPayloadPath -ArtifactsRoot $ArtifactsRoot
    if ($controllerResult.status -eq 'blocked') {
        $common.status = 'blocked'
        $common.reasonCode = 'BLOCKED_PLATFORM_VALIDATION'
        $common.endedAt = [DateTime]::UtcNow.ToString('O')
        Write-OpenPathPhase -Value $common
        [Console]::Error.WriteLine('BLOCKED_PLATFORM_VALIDATION: controller host is unavailable.')
        exit 2
    }
    $observationPath = [string]$controllerResult.outputPath
    $observation = Read-OpenPathDisposableWindowsObservation -Path $observationPath -Mode $Mode -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $ScenarioId -ExpectedNonce ([string]$controllerResult.correlationNonce)
    $common.status = 'passed'
    $common.correlationNonce = [string]$controllerResult.correlationNonce
    $common.observationRef = "$RunId/$RunAttempt/$ScenarioId/$(Split-Path -Leaf $observationPath)"
    $common.observationSha256 = Get-OpenPathPhaseFileHash -Path $observationPath
    $common.observation = $observation.observation
    $common.endedAt = [DateTime]::UtcNow.ToString('O')
    Write-OpenPathPhase -Value $common
    exit 0
}
catch {
    $common.status = 'failed'
    $common.reasonCode = 'CONTROLLER_PHASE_FAILED'
    $common.error = $_.Exception.Message
    $common.endedAt = [DateTime]::UtcNow.ToString('O')
    Write-OpenPathPhase -Value $common
    [Console]::Error.WriteLine(('CONTROLLER_PHASE_FAILED: {0}' -f $_.Exception.Message))
    exit 1
}
