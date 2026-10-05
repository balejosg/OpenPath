<##
.SYNOPSIS
    Runs the first-visit lane scenarios through the external Proxmox controller.
.DESCRIPTION
    Scenario matrix (each one uses the repo guest harness and the per-run
    fixture plan; no site-specific hostnames anywhere):

      first-visit-settled    W  settled system, fresh Firefox -> anchor 1
      first-visit-hot        W2 same Firefox open >=5 min -> anchor 2
      first-visit-class-boot B  install, warm-up, reboot, autologon, Firefox <=60 s
      first-visit-floor      C  like W but with the dependency hosts pre-whitelisted
                                (environment floor; `control` is accepted as alias)

    Each repetition creates a fresh run/attempt/scenario artifact boundary. The
    verdict comes from the page self-report; the caller aggregates metrics.
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$RunAttempt,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ArtifactsRoot,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TemplatePath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$PersonalizedExePath,
    [string]$ControllerCommand,
    [string[]]$Scenarios = @('settled', 'class-boot'),
    [ValidateRange(1, 20)][int]$Repetitions = 1
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ControllerCommand) -or -not (Test-Path -LiteralPath $ControllerCommand -PathType Leaf)) {
    [Console]::Error.WriteLine('BLOCKED_PLATFORM_VALIDATION: no authorized disposable Windows controller is configured.')
    exit 2
}
$phaseScript = Join-Path $PSScriptRoot 'run-windows-desktop-survival.ps1'
$hostCommand = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue
if ($null -eq $hostCommand) { $hostCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue }
if ($null -eq $hostCommand) { [Console]::Error.WriteLine('BLOCKED_PLATFORM_VALIDATION: PowerShell host unavailable.'); exit 2 }
$env:OPENPATH_SUITE_KIND = 'FirstVisit'
$env:OPENPATH_POLICY_CONVERTER_MODE = ''
$failed = $false
$blocked = $false
# The template artifact ships the payload manifest with the exact signed xpi
# digest the fixture must serve on the managed API path (Phase 3A.2 K1).
$templateXpiSha = ''
try {
    $manifestPath = Join-Path (Split-Path -Parent $TemplatePath) 'payload-manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $xpiEntry = @($manifest.payloads | Where-Object { [string]$_.path -like '*openpath-firefox-extension.xpi' }) | Select-Object -First 1
        if ($xpiEntry) { $templateXpiSha = [string]$xpiEntry.sha256 }
    }
}
catch { $templateXpiSha = '' }
foreach ($repetition in 1..$Repetitions) {
    foreach ($scenario in $Scenarios) {
        # Phase 5.3 B4: floor is the real environment control; `control` was
        # the old name and stays accepted as an alias.
        if ($scenario -eq 'control') { $scenario = 'floor' }
        $scenarioId = "first-visit-$scenario-r$repetition"
        $scenarioRoot = Join-Path (Join-Path (Join-Path $ArtifactsRoot $RunId) ([string]$RunAttempt)) $scenarioId
        New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
        $payloadPath = Join-Path $scenarioRoot 'controller-payload.json'
        $labScenario = if ($env:OPENPATH_FIRST_VISIT_LAB_SCENARIO) { [string]$env:OPENPATH_FIRST_VISIT_LAB_SCENARIO } else { 'win11-education-existing-empty' }
        $payload = [ordered]@{
            schemaVersion = 2
            firstVisit    = [ordered]@{ scenario = "first-visit-$scenario"; repetition = $repetition; labScenario = $labScenario; templateXpiSha256 = $templateXpiSha }
        }
        [IO.File]::WriteAllText($payloadPath, ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $scenarioFailed = $false
        foreach ($mode in @('Prepare', 'Observe')) {
            $phaseArguments = @('-NoProfile', '-NonInteractive')
            if ([IO.Path]::GetFileName($hostCommand.Source) -ieq 'powershell.exe') { $phaseArguments += @('-ExecutionPolicy', 'Bypass') }
            & $hostCommand.Source @phaseArguments -File $phaseScript -Mode $mode -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $scenarioId -ArtifactsRoot $ArtifactsRoot -TemplatePath $TemplatePath -PersonalizedExePath $PersonalizedExePath -ControllerCommand $ControllerCommand -ControllerPayloadPath $payloadPath
            $phaseExit = $LASTEXITCODE
            if ($phaseExit -ne 0) {
                $scenarioFailed = $true
                if ($phaseExit -eq 2) { $blocked = $true }
                break
            }
        }
        # Teardown is unconditional: cleanup rolls the VM back and releases the
        # lab lock even when prepare or observe failed (Phase 3A requirement).
        $cleanupArguments = @('-NoProfile', '-NonInteractive')
        if ([IO.Path]::GetFileName($hostCommand.Source) -ieq 'powershell.exe') { $cleanupArguments += @('-ExecutionPolicy', 'Bypass') }
        & $hostCommand.Source @cleanupArguments -File $phaseScript -Mode 'Cleanup' -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $scenarioId -ArtifactsRoot $ArtifactsRoot -TemplatePath $TemplatePath -PersonalizedExePath $PersonalizedExePath -ControllerCommand $ControllerCommand -ControllerPayloadPath $payloadPath
        $cleanupExit = $LASTEXITCODE
        if ($cleanupExit -ne 0) {
            $scenarioFailed = $true
            if ($cleanupExit -eq 2) { $blocked = $true }
        }
        if ($scenarioFailed) { $failed = $true }
    }
}
if ($blocked) { exit 2 }
if ($failed) { exit 1 }
exit 0
