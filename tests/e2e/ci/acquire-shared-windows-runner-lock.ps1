[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 120,
    [int]$StaleAfterMinutes = 240
)

$ErrorActionPreference = 'Stop'

$lockPath = 'C:\ProgramData\OpenPathRunnerLocks\destructive-openpath-windows'
$lockParent = Split-Path $lockPath -Parent
$ownerPath = Join-Path $lockPath 'owner.json'
$ownerToken = @(
    $env:GITHUB_REPOSITORY,
    $env:GITHUB_RUN_ID,
    $env:GITHUB_RUN_ATTEMPT,
    $env:GITHUB_JOB
) -join '#'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

if (-not (Test-Path $lockParent)) {
    New-Item -ItemType Directory -Path $lockParent -Force | Out-Null
}

while ((Get-Date) -lt $deadline) {
    try {
        New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
        $owner = [PSCustomObject]@{
            token = $ownerToken
            repository = $env:GITHUB_REPOSITORY
            runId = $env:GITHUB_RUN_ID
            runAttempt = $env:GITHUB_RUN_ATTEMPT
            job = $env:GITHUB_JOB
            runner = $env:RUNNER_NAME
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        $owner | ConvertTo-Json -Depth 4 | Set-Content -Path $ownerPath -Encoding UTF8
        "OPENPATH_WINDOWS_RUNNER_LOCK_PATH=$lockPath" >> $env:GITHUB_ENV
        "OPENPATH_WINDOWS_RUNNER_LOCK_TOKEN=$ownerToken" >> $env:GITHUB_ENV
        Write-Host "Acquired shared Windows runner lock: $lockPath"
        exit 0
    }
    catch {
        $stale = $false
        $ownerSummary = 'unknown owner'

        if (Test-Path $ownerPath) {
            try {
                $existingOwner = Get-Content -Path $ownerPath -Raw | ConvertFrom-Json
                $ownerSummary = "$($existingOwner.repository) run $($existingOwner.runId) job $($existingOwner.job)"
                $createdAt = [datetime]::Parse([string]$existingOwner.createdAt).ToUniversalTime()
                $stale = ((Get-Date).ToUniversalTime() - $createdAt).TotalMinutes -gt $StaleAfterMinutes
            }
            catch {
                $ownerSummary = 'unreadable owner metadata'
                $stale = $true
            }
        }
        else {
            $stale = $true
        }

        if ($stale) {
            Write-Warning "Removing stale shared Windows runner lock held by $ownerSummary"
            Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            continue
        }

        Write-Host "Waiting for shared Windows runner lock held by $ownerSummary"
        Start-Sleep -Seconds 15
    }
}

throw "Timed out after $TimeoutMinutes minutes waiting for shared Windows runner lock at $lockPath"
