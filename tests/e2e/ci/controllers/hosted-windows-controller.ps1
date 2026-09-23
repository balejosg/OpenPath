<#
.SYNOPSIS
    Runs one acceptance phase on a GitHub-hosted Windows runner.

.DESCRIPTION
    The PolicyConverter contrast harness only publishes comparable evidence from
    a GitHub-hosted runner: its provenance gate rejects every other host, and a
    hosted runner already is the independent disposable guest. This controller
    therefore performs the phase work locally instead of provisioning an
    external VM.

    Phases:
      prepare      verify the contrast inputs and hashes from controller-input.json
      observe      run tests/e2e/ci/run-windows-policy-converter-contrast.ps1 and
                   fail unless the harness reports a comparable (observed) result
      afterReboot  capture a post-run policy snapshot for the record
      cleanup      nothing to destroy on a disposable runner

    The emitted observation matches the contract used by the external VM
    controller so the same aggregate and validators apply.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PayloadPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Observe', 'AfterReboot', 'Cleanup')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][int]$RunAttempt,
    [Parameter(Mandatory = $true)][string]$ScenarioId,
    [Parameter(Mandatory = $true)][string]$CorrelationNonce
)

$ErrorActionPreference = 'Stop'

function Get-PayloadField {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -ne $InputObject.PSObject.Properties[$Name]) { return $InputObject.$Name }
    return $null
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
}

$payload = Get-Content -LiteralPath $PayloadPath -Raw | ConvertFrom-Json
$phase = switch ($Mode) {
    'Prepare' { 'prepare' }
    'Observe' { 'observe' }
    'AfterReboot' { 'afterReboot' }
    'Cleanup' { 'cleanup' }
}
$scenarioRoot = [string](Get-PayloadField -InputObject $payload -Name 'artifactsRoot')
if ([string]::IsNullOrWhiteSpace($scenarioRoot) -or -not (Test-Path -LiteralPath $scenarioRoot -PathType Container)) {
    throw 'hosted-controller-scenario-root-missing'
}
$runRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scenarioRoot))

function Write-OpenPathHostedObservation {
    param(
        [Parameter(Mandatory = $true)][string]$PhaseName,
        [Parameter(Mandatory = $true)][object]$Body
    )
    $observation = [ordered]@{
        schemaVersion    = 2
        status           = 'passed'
        synthetic        = $false
        runId            = [string](Get-PayloadField -InputObject $payload -Name 'runId')
        runAttempt       = [int](Get-PayloadField -InputObject $payload -Name 'runAttempt')
        sourceCommitSha  = [string](Get-PayloadField -InputObject $payload -Name 'sourceCommitSha')
        scenarioId       = [string](Get-PayloadField -InputObject $payload -Name 'scenarioId')
        phase            = $PhaseName
        correlationNonce = [string](Get-PayloadField -InputObject $payload -Name 'correlationNonce')
        observation      = $Body
    }
    Write-JsonFile -Path $OutputPath -Value $observation
}

function Get-OpenPathHostedContrastInputs {
    $controllerInputPath = Join-Path $runRoot 'controller-input.json'
    if (-not (Test-Path -LiteralPath $controllerInputPath -PathType Leaf)) { throw 'hosted-controller-input-missing' }
    $controllerInput = Get-Content -LiteralPath $controllerInputPath -Raw | ConvertFrom-Json
    $inputsRoot = [string](Get-PayloadField -InputObject $controllerInput -Name 'contrastInputs')
    if ([string]::IsNullOrWhiteSpace($inputsRoot) -or -not (Test-Path -LiteralPath $inputsRoot -PathType Container)) { throw 'hosted-contrast-inputs-missing' }
    $manifestPath = Join-Path $inputsRoot 'sha256-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'hosted-contrast-manifest-missing' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $executablePath = Join-Path $inputsRoot ([string]$manifest.executableFile)
    $probePayloadPath = Join-Path $inputsRoot ([string]$manifest.probePayloadFile)
    foreach ($candidate in @(
            [pscustomobject]@{ Path = $executablePath; Field = 'executableSha256' },
            [pscustomobject]@{ Path = $probePayloadPath; Field = 'probePayloadSha256' }
        )) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { throw ('hosted-contrast-input-missing-' + $candidate.Field) }
        $expected = [string](Get-PayloadField -InputObject $controllerInput -Name $candidate.Field)
        if ([string]::IsNullOrWhiteSpace($expected)) { $expected = [string](Get-PayloadField -InputObject $manifest -Name $candidate.Field) }
        if ((Get-FileSha256 -Path $candidate.Path) -ne $expected) { throw ('hosted-contrast-input-hash-mismatch-' + $candidate.Field) }
    }
    return [pscustomobject][ordered]@{
        InputsRoot       = $inputsRoot
        Manifest         = $manifest
        ExecutablePath   = $executablePath
        ProbePayloadPath = $probePayloadPath
        ExecutableSha256 = [string]$manifest.executableSha256
        ProbePayloadSha256 = [string]$manifest.probePayloadSha256
        TargetHarness    = [string](Get-PayloadField -InputObject $controllerInput -Name 'targetHarness')
    }
}

switch ($phase) {
    'prepare' {
        $inputs = Get-OpenPathHostedContrastInputs
        Write-OpenPathHostedObservation -PhaseName $phase -Body ([ordered]@{
                contrastInputs     = $inputs.InputsRoot
                executableFile     = [string]$inputs.Manifest.executableFile
                probePayloadFile   = [string]$inputs.Manifest.probePayloadFile
                executableSha256   = $inputs.ExecutableSha256
                probePayloadSha256 = $inputs.ProbePayloadSha256
                targetHarness      = $inputs.TargetHarness
                hostedRunner       = ($env:GITHUB_ACTIONS -eq 'true')
                runnerEnvironment  = [string]$env:RUNNER_ENVIRONMENT
                imageOS            = [string]$env:ImageOS
                imageVersion       = [string]$env:ImageVersion
            })
    }
    'observe' {
        $inputs = Get-OpenPathHostedContrastInputs
        $pwsh = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) { throw 'hosted-contrast-pwsh-unavailable' }
        $harness = Join-Path (Split-Path -Parent $PSScriptRoot) 'run-windows-policy-converter-contrast.ps1'
        if (-not (Test-Path -LiteralPath $harness -PathType Leaf)) { throw 'hosted-contrast-harness-missing' }
        # Do not reuse $mode: PowerShell variable names are case-insensitive and
        # the $Mode parameter carries the phase ValidateSet.
        $contrastMode = [string](Get-PayloadField -InputObject $payload -Name 'policyConverterMode')
        if ($contrastMode -notin @('Untouched', 'Started')) { throw 'hosted-contrast-mode-invalid' }
        $childEvidence = Join-Path $scenarioRoot 'contrast-child-evidence.json'
        $harnessEvidence = Join-Path $scenarioRoot 'contrast-evidence.json'
        & $pwsh.Source -NoProfile -NonInteractive -File $harness `
            -Mode $contrastMode `
            -ExecutablePath $inputs.ExecutablePath `
            -ProbePayloadPath $inputs.ProbePayloadPath `
            -ExpectedExecutableSha256 $inputs.ExecutableSha256 `
            -ExpectedProbePayloadSha256 $inputs.ProbePayloadSha256 `
            -ChildEvidencePath $childEvidence `
            -EvidencePath $harnessEvidence
        if ($LASTEXITCODE -ne 0) { throw ('hosted-contrast-harness-exit-' + $LASTEXITCODE) }
        if (-not (Test-Path -LiteralPath $harnessEvidence -PathType Leaf)) { throw 'hosted-contrast-evidence-missing' }
        $result = Get-Content -LiteralPath $harnessEvidence -Raw | ConvertFrom-Json
        if ([string]$result.status -ne 'observed') {
            # A non-comparable harness result (wrong provenance, cold baseline,
            # missing child evidence) must fail the phase instead of publishing
            # hollow contrast evidence.
            throw ('hosted-contrast-not-comparable-' + [string]$result.code)
        }
        $body = [ordered]@{
            harnessStatus         = [string]$result.status
            harnessCode           = [string]$result.code
            harnessMode           = [string]$result.mode
            childExitCode         = $result.childExitCode
            childEvidenceAvailable = $result.childEvidenceAvailable
            hostedRunner          = [bool]$result.hostedRunner
            runnerEnvironment     = [string]$result.runnerEnvironment
            evidenceSha256        = Get-FileSha256 -Path $harnessEvidence
        }
        if (Test-Path -LiteralPath $childEvidence -PathType Leaf) {
            $body.childEvidenceSha256 = Get-FileSha256 -Path $childEvidence
        }
        Write-OpenPathHostedObservation -PhaseName $phase -Body $body
    }
    'afterReboot' {
        $policyXml = ''
        if (Get-Command -Name 'Get-AppLockerPolicy' -ErrorAction SilentlyContinue) {
            try { $policyXml = [string](Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop) } catch { $policyXml = '' }
        }
        Write-OpenPathHostedObservation -PhaseName $phase -Body ([ordered]@{
                policySha256      = Get-TextSha256 -Text $policyXml
                openPathInstalled = Test-Path -LiteralPath 'C:\OpenPath'
                hostedRunner      = ($env:GITHUB_ACTIONS -eq 'true')
                bootTimeUtc       = ([datetime](Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime).ToUniversalTime().ToString('o')
            })
    }
    'cleanup' {
        Write-OpenPathHostedObservation -PhaseName $phase -Body ([ordered]@{
                cleaned          = $true
                disposableRunner = ($env:GITHUB_ACTIONS -eq 'true')
            })
    }
}

exit 0
