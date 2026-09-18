[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$Mode,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][int]$RunAttempt,
    [Parameter(Mandatory)][string]$ScenarioId,
    [Parameter(Mandatory)][string]$CorrelationNonce
)

$payload = Get-Content -LiteralPath $PayloadPath -Raw | ConvertFrom-Json
$phase = switch ($Mode) { 'Prepare' { 'prepare' } 'Observe' { 'observe' } 'AfterReboot' { 'afterReboot' } 'Cleanup' { 'cleanup' } default { throw 'invalid-mode' } }
$result = [ordered]@{
    schemaVersion = 2
    status = 'passed'
    runId = $RunId
    runAttempt = $RunAttempt
    scenarioId = $ScenarioId
    phase = $phase
    correlationNonce = $CorrelationNonce
    observation = [ordered]@{
        synthetic = $true
        controller = 'test-fixture-only'
        phase = $phase
        note = 'This fixture is never valid release evidence.'
    }
}
$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
exit 0
