[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Untouched', 'Started')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$RunAttempt,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$EvidenceRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceCommitSha,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TemplatePath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$PersonalizedExePath,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$phaseNames = @('prepare', 'observe', 'afterReboot', 'cleanup')
$scenarioId = "win11-policy-converter-$($Mode.ToLowerInvariant())"
$scenarioRoot = Join-Path (Join-Path (Join-Path $EvidenceRoot $RunId) ([string]$RunAttempt)) $scenarioId
$rootFull = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$toRelative = {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'contrast-reference-outside-root' }
    return $full.Substring($rootFull.Length).Replace('\', '/')
}
$hash = { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$files = New-Object System.Collections.Generic.List[object]
$phases = [ordered]@{}
$now = [DateTime]::UtcNow.ToString('O')

foreach ($phase in $phaseNames) {
    $phasePath = Join-Path $scenarioRoot "$phase.json"
    $phaseRecord = Get-Content -LiteralPath $phasePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($phaseRecord.status -ne 'passed' -or $phaseRecord.runId -ne $RunId -or [int]$phaseRecord.runAttempt -ne $RunAttempt -or $phaseRecord.scenarioId -ne $scenarioId -or $phaseRecord.phase -ne $phase) { throw "contrast-phase-invalid-$phase" }
    $observationPath = Join-Path $scenarioRoot "$phase-observation.json"
    $observation = Get-Content -LiteralPath $observationPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($observation.status -ne 'passed' -or $observation.synthetic -ne $false -or $observation.runId -ne $RunId -or [int]$observation.runAttempt -ne $RunAttempt -or $observation.sourceCommitSha -ne $SourceCommitSha -or $observation.scenarioId -ne $scenarioId -or $observation.phase -ne $phase -or $observation.correlationNonce -ne $phaseRecord.correlationNonce) { throw "contrast-observation-invalid-$phase" }
    $observationHash = & $hash $observationPath
    if ([string]$phaseRecord.observationSha256 -ne $observationHash) { throw "contrast-observation-hash-invalid-$phase" }
    $phaseRelative = & $toRelative $phasePath
    $observationRelative = & $toRelative $observationPath
    $phaseHash = & $hash $phasePath
    $files.Add([ordered]@{ path = $phaseRelative; size = (Get-Item -LiteralPath $phasePath).Length; sha256 = $phaseHash })
    $files.Add([ordered]@{ path = $observationRelative; size = (Get-Item -LiteralPath $observationPath).Length; sha256 = $observationHash })
    $phases[$phase] = [ordered]@{ status = 'passed'; evidenceRef = $observationRelative; sha256 = $observationHash; startedAt = [string]$phaseRecord.startedAt; endedAt = [string]$phaseRecord.endedAt; correlationNonce = [string]$phaseRecord.correlationNonce }
}

$manifest = [ordered]@{ schemaVersion = 2; suiteKind = 'PolicyConverterContrast'; policyConverterMode = $Mode; sourceCommitSha = $SourceCommitSha; runId = $RunId; runAttempt = $RunAttempt; generatedAt = $now; files = $files.ToArray() }
$manifestPath = Join-Path $EvidenceRoot "contrast-$($Mode.ToLowerInvariant())-manifest.json"
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$manifestHash = & $hash $manifestPath
$templateHash = & $hash $TemplatePath
$exeHash = & $hash $PersonalizedExePath
$aggregate = [ordered]@{
    schemaVersion = 2
    suiteKind = 'PolicyConverterContrast'
    policyConverterMode = $Mode
    sourceCommitSha = $SourceCommitSha
    runId = $RunId
    runAttempt = $RunAttempt
    templateSha256 = $templateHash
    personalizedExeSha256 = $exeHash
    evidenceManifestSha256 = $manifestHash
    generatedAt = $now
    synthetic = $false
    scenarioId = $scenarioId
    phases = $phases
}
if (-not $OutputPath) { $OutputPath = Join-Path $EvidenceRoot "contrast-$($Mode.ToLowerInvariant())-aggregate.json" }
[IO.File]::WriteAllText($OutputPath, ($aggregate | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
Write-Output $OutputPath
