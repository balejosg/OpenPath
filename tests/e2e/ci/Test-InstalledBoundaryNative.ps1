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
Import-Module (Join-Path $PSScriptRoot 'BrowserBoundaryProbe.psm1') -Force -ErrorAction Stop
Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $OpenPathRoot

$effective = Get-AppLockerPolicy -Effective -ErrorAction Stop
$paths = @($FirefoxPath, $EdgePath, $ProbePath)
$decisions = @($effective | Test-AppLockerPolicy -Path $paths -User $StudentSid -ErrorAction Stop)
$byPath = @{}
foreach ($decision in $decisions) {
    $byPath[[System.IO.Path]::GetFullPath([string]$decision.FilePath)] = [string]$decision.PolicyDecision
}
$policy = [ordered]@{
    firefox = [string]$byPath[[System.IO.Path]::GetFullPath($FirefoxPath)]
    edge = [string]$byPath[[System.IO.Path]::GetFullPath($EdgePath)]
    benignPe = [string]$byPath[[System.IO.Path]::GetFullPath($ProbePath)]
}
if ($policy.firefox -ne 'Allowed') { throw "boundary-firefox-policy-$($policy.firefox)" }
if ($policy.edge -notin @('Denied', 'DeniedByDefault')) { throw "boundary-edge-policy-$($policy.edge)" }
if ($policy.benignPe -notin @('Denied', 'DeniedByDefault')) { throw "boundary-benign-pe-policy-$($policy.benignPe)" }
$policy | ConvertTo-Json -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop

