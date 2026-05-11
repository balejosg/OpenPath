[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$lockPath = if ($env:OPENPATH_WINDOWS_RUNNER_LOCK_PATH) {
    $env:OPENPATH_WINDOWS_RUNNER_LOCK_PATH
}
else {
    'C:\ProgramData\OpenPathRunnerLocks\destructive-openpath-windows'
}
$ownerPath = Join-Path $lockPath 'owner.json'
$ownerToken = $env:OPENPATH_WINDOWS_RUNNER_LOCK_TOKEN

if (-not (Test-Path $lockPath)) {
    Write-Host "Shared Windows runner lock is already absent: $lockPath"
    exit 0
}

if (-not $ownerToken) {
    Write-Warning 'No OPENPATH_WINDOWS_RUNNER_LOCK_TOKEN is set; leaving shared lock untouched.'
    exit 0
}

try {
    $existingOwner = Get-Content -Path $ownerPath -Raw | ConvertFrom-Json
    if ([string]$existingOwner.token -ne $ownerToken) {
        Write-Warning "Shared Windows runner lock is owned by another job; leaving it untouched."
        exit 0
    }
}
catch {
    Write-Warning "Unable to verify shared Windows runner lock owner: $_"
    exit 0
}

Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Released shared Windows runner lock: $lockPath"
