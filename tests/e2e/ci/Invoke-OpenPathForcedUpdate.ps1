# Phase 8c T3: forced-update launcher for the Windows E2E.
#
# The Selenium suite runs under pwsh 7, so the Windows PowerShell 5.1 child
# that performs the forced update inherits PowerShell 7's PSModulePath. That
# environment does not auto-load Microsoft.PowerShell.Utility and any
# Get-FileHash call fails with "The term 'Get-FileHash' is not recognized"
# (observed in E2E run 38144922322: build.json status=Failed attempts=16 while
# the installed host itself stayed healthy). The product no longer uses
# Get-FileHash for the native host (Phase 8c T1); this wrapper additionally
# restores the production environment so the E2E exercises the same
# PowerShell the scheduled task uses.
#
# It records the inherited environment first (literal cause data for the
# artifact, no secrets), then normalizes PSModulePath to the machine+user
# values and runs the installed update script in this same interpreter.
[CmdletBinding()]
param(
    [string]$UpdateScriptPath = 'C:\OpenPath\scripts\Update-OpenPath.ps1'
)

$inherited = [string]$env:PSModulePath
$getFileHashResolved = [bool](Get-Command -Name Get-FileHash -ErrorAction SilentlyContinue)
$probeLine = "Forced-update child environment: inheritedPSModulePath='$inherited' Get-FileHashResolves=$getFileHashResolved"
Write-Host $probeLine

$diagnosticsDir = [string]$env:OPENPATH_STUDENT_DIAGNOSTICS_DIR
if ($diagnosticsDir) {
    try {
        New-Item -ItemType Directory -Path $diagnosticsDir -Force | Out-Null
        Add-Content -Path (Join-Path $diagnosticsDir 'forced-update-environment.log') -Value $probeLine
    }
    catch { }
}

$machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
$user = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
$env:PSModulePath = (@($machine, $user) | Where-Object { $_ }) -join ';'
Write-Host "Forced-update child PSModulePath (production machine+user): $env:PSModulePath"

& (Resolve-Path -LiteralPath $UpdateScriptPath).Path
exit $LASTEXITCODE
