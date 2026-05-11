param(
    [ValidateSet('Run')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-browser-dependency-observability-spike')
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:ResultPath = Join-Path $script:ArtifactsRoot 'browser-dependency-observability-spike-result.json'

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
}

function Get-RunnerHostSuffix {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.PrefixOrigin -ne 'WellKnown'
        } |
        Sort-Object InterfaceMetric, InterfaceIndex |
        Select-Object -First 1
    if (-not $address -or -not $address.IPAddress) {
        throw 'Unable to derive a non-loopback Windows runner IPv4 address for browser dependency observability.'
    }

    return (($address.IPAddress -replace '\.', '-') + '.sslip.io')
}

function Write-InsufficientResult {
    param([Parameter(Mandatory = $true)][string]$ErrorText)

    $decisions = @(
        'runtimeRouteViable',
        'observerOnlyViable',
        'nativeOnlyViable',
        'ambiguousCorrelation',
        'insufficientEvidence'
    )
    [pscustomobject]@{
        profile = 'browser-dependency-observability-spike'
        resultPath = 'browser-dependency-observability-spike-result.json'
        success = $false
        decision = 'insufficientEvidence'
        allowedDecisions = $decisions
        error = $ErrorText
        writtenAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8
}

function Invoke-SpikeRun {
    Ensure-ArtifactRoot
    $studentFlowPath = Join-Path $script:RepoRoot 'tests\e2e\ci\run-windows-student-flow.ps1'
    if (-not (Test-Path -LiteralPath $studentFlowPath)) {
        throw "run-windows-student-flow.ps1 not found: $studentFlowPath"
    }

    $previousCoverage = $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE
    $previousArtifacts = $env:OPENPATH_STUDENT_ARTIFACTS_DIR
    $previousSuffix = $env:OPENPATH_STUDENT_HOST_SUFFIX
    try {
        $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE = 'browser-dependency-observability-spike'
        $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $script:ArtifactsRoot
        $env:OPENPATH_STUDENT_HOST_SUFFIX = Get-RunnerHostSuffix
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $studentFlowPath
        if ($LASTEXITCODE -ne 0) {
            throw "run-windows-student-flow.ps1 exited with code $LASTEXITCODE"
        }
        if (-not (Test-Path -LiteralPath $script:ResultPath)) {
            throw "Browser dependency observability result was not written: $script:ResultPath"
        }
    }
    finally {
        if ($null -eq $previousCoverage) {
            Remove-Item Env:\OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE = $previousCoverage
        }
        if ($null -eq $previousArtifacts) {
            Remove-Item Env:\OPENPATH_STUDENT_ARTIFACTS_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $previousArtifacts
        }
        if ($null -eq $previousSuffix) {
            Remove-Item Env:\OPENPATH_STUDENT_HOST_SUFFIX -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_STUDENT_HOST_SUFFIX = $previousSuffix
        }
    }
}

try {
    switch ($Mode) {
        'Run' {
            Invoke-SpikeRun
        }
    }
}
catch {
    try {
        Ensure-ArtifactRoot
        Write-InsufficientResult -ErrorText ([string]$_)
    }
    catch {
        Write-Warning "Unable to write browser dependency observability failure artifact: $_"
    }
    Write-Error $_
    exit 1
}
