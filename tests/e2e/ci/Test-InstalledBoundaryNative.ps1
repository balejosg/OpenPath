[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OpenPathRoot,
    [Parameter(Mandatory = $true)][string]$StudentSid,
    [Parameter(Mandatory = $true)][string]$FirefoxPath,
    [Parameter(Mandatory = $true)][string]$EdgePath,
    [Parameter(Mandatory = $true)][string]$ProbePath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$nativeStage = 'load-boundary-contract'
try {
    Import-Module (Join-Path $PSScriptRoot 'BrowserBoundaryProbe.psm1') -Force -ErrorAction Stop
    $nativeStage = 'assert-installed-boundary'
    Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $OpenPathRoot
    $nativeStage = 'read-effective-policy'
    $effective = Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop
    $nativeStage = 'evaluate-policy'
    $paths = @($FirefoxPath, $EdgePath, $ProbePath)
    $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-installed-boundary-$([guid]::NewGuid()).xml"
    try {
        Set-Content -LiteralPath $policyPath -Value $effective -Encoding UTF8 -ErrorAction Stop
        $evaluationPaths = [System.Collections.Generic.List[string]]::new()
        foreach ($candidatePath in $paths) { $evaluationPaths.Add([string]$candidatePath) }
        $decisions = @(Test-AppLockerPolicy -XmlPolicy $policyPath -Path $evaluationPaths -User $StudentSid)
    }
    finally {
        Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
    }
    $byPath = @{}
    foreach ($decision in $decisions) {
        $byPath[[System.IO.Path]::GetFullPath([string]$decision.FilePath)] = [string]$decision.PolicyDecision
    }
    $policy = [ordered]@{
        status = 'ok'
        firefox = [string]$byPath[[System.IO.Path]::GetFullPath($FirefoxPath)]
        edge = [string]$byPath[[System.IO.Path]::GetFullPath($EdgePath)]
        benignPe = [string]$byPath[[System.IO.Path]::GetFullPath($ProbePath)]
    }
    if ($policy.firefox -ne 'Allowed') { throw 'unexpected-firefox-decision' }
    if ($policy.edge -notin @('Denied', 'DeniedByDefault')) { throw 'unexpected-edge-decision' }
    if ($policy.benignPe -notin @('Denied', 'DeniedByDefault')) { throw 'unexpected-benign-pe-decision' }
    $policy | ConvertTo-Json -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop
}
catch {
    [ordered]@{ status = 'failed'; code = "boundary-native-$nativeStage-failed" } |
        ConvertTo-Json -Compress |
        Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop
    exit 1
}
