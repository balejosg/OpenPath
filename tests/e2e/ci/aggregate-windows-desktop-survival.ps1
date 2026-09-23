[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$RunAttempt,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$EvidenceRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceCommitSha,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TemplatePath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$PersonalizedExePath,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$scenarioIds = @('win11-pro-profileless-empty', 'win11-pro-existing-empty', 'win11-education-profileless-empty', 'win11-education-existing-empty')
$phases = @('prepare', 'observe', 'afterReboot', 'cleanup')
$now = [DateTime]::UtcNow.ToString('O')
$toRelative = {
    param([string]$Path)
    $rootFull = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'desktop-survival-reference-outside-root' }
    $relative = $pathFull.Substring($rootFull.Length).Replace('\', '/')
    if ($relative.StartsWith('../') -or [IO.Path]::IsPathRooted($relative)) { throw 'desktop-survival-reference-outside-root' }
    return $relative
}
$hash = { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$files = New-Object System.Collections.Generic.List[object]
$scenarios = New-Object System.Collections.Generic.List[object]

foreach ($scenarioId in $scenarioIds) {
    $scenarioRoot = Join-Path (Join-Path (Join-Path $EvidenceRoot $RunId) ([string]$RunAttempt)) $scenarioId
    $phaseRecords = [ordered]@{}
    $scenarioObservation = $null
    foreach ($phase in $phases) {
        $phasePath = Join-Path $scenarioRoot "$phase.json"
        $phaseRecord = Get-Content -LiteralPath $phasePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($phaseRecord.status -ne 'passed' -or $phaseRecord.runId -ne $RunId -or [int]$phaseRecord.runAttempt -ne $RunAttempt -or $phaseRecord.scenarioId -ne $scenarioId -or $phaseRecord.phase -ne $phase) { throw "desktop-survival-phase-invalid-$scenarioId-$phase" }
        $observationPath = Join-Path $scenarioRoot "$phase-observation.json"
        $observation = Get-Content -LiteralPath $observationPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($observation.status -ne 'passed' -or $observation.synthetic -eq $true -or $observation.runId -ne $RunId -or [int]$observation.runAttempt -ne $RunAttempt -or $observation.sourceCommitSha -ne $SourceCommitSha -or $observation.scenarioId -ne $scenarioId -or $observation.phase -ne $phase -or $observation.correlationNonce -ne $phaseRecord.correlationNonce) { throw "desktop-survival-observation-invalid-$scenarioId-$phase" }
        if ($observation.PSObject.Properties['scenario']) {
            if ($null -eq $scenarioObservation) { $scenarioObservation = $observation.scenario }
        }
        $observationRelative = & $toRelative $observationPath
        $phaseRelative = & $toRelative $phasePath
        $observationHash = & $hash $observationPath
        $phaseHash = & $hash $phasePath
        if ([string]$phaseRecord.observationSha256 -ne $observationHash) { throw "desktop-survival-observation-hash-invalid-$scenarioId-$phase" }
        $files.Add([ordered]@{ path = $observationRelative; size = (Get-Item -LiteralPath $observationPath).Length; sha256 = $observationHash })
        $files.Add([ordered]@{ path = $phaseRelative; size = (Get-Item -LiteralPath $phasePath).Length; sha256 = $phaseHash })
        $phaseRecords[$phase] = [ordered]@{ status = 'passed'; evidenceRef = $observationRelative; sha256 = $observationHash; startedAt = [string]$phaseRecord.startedAt; endedAt = [string]$phaseRecord.endedAt; correlationNonce = [string]$phaseRecord.correlationNonce }
    }
    if ($null -eq $scenarioObservation) { throw "desktop-survival-scenario-metadata-missing-$scenarioId" }
    if ($scenarioObservation.PSObject.Properties['phases']) { $scenarioObservation.phases = $phaseRecords }
    else { Add-Member -InputObject $scenarioObservation -NotePropertyName phases -NotePropertyValue $phaseRecords }
    $scenarios.Add($scenarioObservation)
}

$manifest = [ordered]@{ schemaVersion = 2; sourceCommitSha = $SourceCommitSha; runId = $RunId; runAttempt = $RunAttempt; generatedAt = $now; files = $files.ToArray() }
$manifestPath = Join-Path $EvidenceRoot 'manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$manifestHash = & $hash $manifestPath
$templateHash = & $hash $TemplatePath
$exeHash = & $hash $PersonalizedExePath
$aggregate = [ordered]@{ schemaVersion = 2; sourceCommitSha = $SourceCommitSha; runId = $RunId; runAttempt = $RunAttempt; templateSha256 = $templateHash; personalizedExeSha256 = $exeHash; evidenceManifestSha256 = $manifestHash; generatedAt = $now; synthetic = $false; scenarios = $scenarios.ToArray() }
if (-not $OutputPath) { $OutputPath = Join-Path $EvidenceRoot 'aggregate.json' }
[IO.File]::WriteAllText($OutputPath, ($aggregate | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
Write-Output $OutputPath
