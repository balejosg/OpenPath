# Guarded live harness for the cross-platform firewall contract scenarios.
# Applies the REAL OpenPath firewall policy and asserts the windows-scoped
# scenarios in tests/contracts/scenarios/ against Get-NetFirewallRule state.
# Runs ONLY on the self-hosted lab runner (e2e-tests.yml sets
# OPENPATH_CONTRACT_REAL_FIREWALL=1); everywhere else use the mocked rung
# windows/tests/Windows.ContractScenarios.Tests.ps1.
[CmdletBinding()]
param(
    [string]$ResultsPath = 'tests/e2e/artifacts/windows-contract-scenarios/windows-contract-results.xml'
)

$ErrorActionPreference = 'Stop'

if ($env:RUNNER_ENVIRONMENT -ne 'self-hosted' -or $env:OPENPATH_CONTRACT_REAL_FIREWALL -ne '1') {
    throw ('Refusing to run: this harness mutates REAL Windows Firewall state. ' +
        'It requires RUNNER_ENVIRONMENT=self-hosted AND OPENPATH_CONTRACT_REAL_FIREWALL=1 ' +
        '(set only by the windows-contract-scenarios job in e2e-tests.yml). ' +
        'For developer machines and hosted runners use the mocked rung: ' +
        'windows/tests/Windows.ContractScenarios.Tests.ps1.')
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
Set-Location $repoRoot

if (-not [System.IO.Path]::IsPathRooted($ResultsPath)) {
    $ResultsPath = Join-Path $repoRoot $ResultsPath
}
$resultsDirectory = Split-Path $ResultsPath -Parent
if ($resultsDirectory -and -not (Test-Path $resultsDirectory)) {
    New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
}

$minimumPesterVersion = [version]'5.0.0'
$availablePester = Get-Module -ListAvailable -Name Pester |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $availablePester -or $availablePester.Version -lt $minimumPesterVersion) {
    Install-Module -Name Pester -MinimumVersion $minimumPesterVersion.ToString() -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion $minimumPesterVersion -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path = @((Join-Path $repoRoot 'tests' 'e2e' 'Windows-ContractScenarios.Tests.ps1'))
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = $ResultsPath
$config.TestResult.OutputFormat = 'NUnitXml'

$result = Invoke-Pester -Configuration $config

if (-not (Test-Path $ResultsPath)) {
    throw 'Windows live contract scenarios did not produce a results file.'
}
if ($null -eq $result) {
    throw 'Invoke-Pester returned no result object.'
}
if ($result.FailedCount -gt 0) {
    throw "Windows live contract scenarios reported $($result.FailedCount) failure(s)."
}

Write-Host "Windows live contract scenarios passed ($($result.PassedCount) passed, $($result.SkippedCount) skipped)."
