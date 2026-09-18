<#
.SYNOPSIS
    Records externally controlled Windows desktop-survival phases.
.DESCRIPTION
    This harness is intentionally fail-closed. It never applies AppLocker or
    requests a reboot itself. A disposable VM controller must invoke each phase
    and provide the phase observation. Without that controller the phase is
    recorded as BLOCKED_PLATFORM_VALIDATION and the caller must not publish.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Observe', 'AfterReboot', 'Cleanup')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ArtifactsRoot,
    [string]$TemplatePath,
    [string]$PersonalizedExePath,
    [string]$ControllerCommand,
    [string]$ControllerPayloadPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DisposableWindowsTarget.psm1') -Force

function Write-OpenPathDesktopPhaseEvidence {
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][hashtable]$Evidence)
    $runRoot = Join-Path $ArtifactsRoot $RunId
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $target = Join-Path $runRoot "$Phase.json"
    $temporary = "$target.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Evidence | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    return $target
}

function Get-OpenPathDesktopSha256 {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$phase = $Mode.ToLowerInvariant()
$base = @{ schemaVersion = 1; runId = $RunId; phase = $phase; status = 'blocked'; createdAt = [DateTime]::UtcNow.ToString('O'); evidenceRef = "$phase.json" }
if ($TemplatePath) { $base.templateSha256 = Get-OpenPathDesktopSha256 -Path $TemplatePath }
if ($PersonalizedExePath) { $base.personalizedExeSha256 = Get-OpenPathDesktopSha256 -Path $PersonalizedExePath }

if (-not $ControllerCommand) {
    $base.reasonCode = 'BLOCKED_PLATFORM_VALIDATION'
    Write-OpenPathDesktopPhaseEvidence -Phase $phase -Evidence $base | Out-Null
    [Console]::Error.WriteLine('BLOCKED_PLATFORM_VALIDATION: an external disposable-VM controller is required.')
    exit 2
}

if (-not $ControllerPayloadPath) { throw '-ControllerPayloadPath is required when -ControllerCommand is supplied.' }
if (-not (Test-Path -LiteralPath $ControllerPayloadPath -PathType Leaf)) { throw 'Controller payload does not exist.' }
$controllerOutput = Join-Path $ArtifactsRoot $RunId "$phase-controller.json"
Invoke-OpenPathDisposableWindowsController -Command $ControllerCommand -Mode $Mode -RunId $RunId -PayloadPath $ControllerPayloadPath -ArtifactsRoot $ArtifactsRoot
$observation = Read-OpenPathDisposableWindowsObservation -Path $controllerOutput -Mode $Mode -RunId $RunId
$base.status = 'passed'
$base.observation = $observation.observation
Write-OpenPathDesktopPhaseEvidence -Phase $phase -Evidence $base | Out-Null
