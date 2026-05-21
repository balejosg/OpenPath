# OpenPath - Captive portal recovery task

#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$MaxRequestAgeSeconds = 60
$RecentSuccessSeconds = 30

. (Join-Path $PSScriptRoot '..\lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force
Initialize-OpenPathScriptSession `
    -OpenPathRoot $OpenPathRoot `
    -DependentModules @('DNS', 'Firewall', 'CaptivePortal') `
    -RequiredCommands @(
    'Write-OpenPathLog',
    'Get-OpenPathCapabilityStoragePath',
    'Test-OpenPathCaptivePortalState',
    'Update-OpenPathCaptivePortalObservation',
    'Enable-OpenPathCaptivePortalMode'
) `
    -ScriptName 'Recover-CaptivePortal.ps1' | Out-Null

function Get-OpenPathRecoveryUtcNow {
    return [DateTime]::UtcNow
}

function ConvertFrom-OpenPathRecoveryRequestFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    try {
        $request = Get-Content $File.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $request.requestId) {
            return $null
        }

        return [PSCustomObject]@{
            File = $File
            Request = $request
        }
    }
    catch {
        Write-OpenPathLog "Captive portal recovery: ignoring unreadable request $($File.FullName): $_" -Level WARN
        return $null
    }
}

function Get-OpenPathCaptivePortalRecoveryRequests {
    param([Parameter(Mandatory = $true)][string]$QueuePath)

    if (-not (Test-Path $QueuePath -ErrorAction SilentlyContinue)) {
        return @()
    }

    return @(
        Get-ChildItem -Path $QueuePath -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc, Name |
            ForEach-Object { ConvertFrom-OpenPathRecoveryRequestFile -File $_ } |
            Where-Object { $null -ne $_ }
    )
}

function Test-OpenPathRecoveryRequestFresh {
    param(
        [Parameter(Mandatory = $true)][object]$RequestEnvelope,
        [Parameter(Mandatory = $true)][DateTime]$NowUtc
    )

    $createdAtUtc = $RequestEnvelope.File.LastWriteTimeUtc
    if ($RequestEnvelope.Request.PSObject.Properties['createdAtUtc'] -and $RequestEnvelope.Request.createdAtUtc) {
        try {
            $createdAtUtc = ([DateTimeOffset]::Parse([string]$RequestEnvelope.Request.createdAtUtc)).UtcDateTime
        }
        catch {
            $createdAtUtc = $RequestEnvelope.File.LastWriteTimeUtc
        }
    }
    elseif ($RequestEnvelope.Request.PSObject.Properties['createdAt'] -and $RequestEnvelope.Request.createdAt) {
        try {
            $createdAtUtc = ([DateTimeOffset]::Parse([string]$RequestEnvelope.Request.createdAt)).UtcDateTime
        }
        catch {
            $createdAtUtc = $RequestEnvelope.File.LastWriteTimeUtc
        }
    }

    return (($NowUtc - $createdAtUtc).TotalSeconds -le $MaxRequestAgeSeconds)
}

function Get-OpenPathRecentCaptivePortalRecoverySuccess {
    param(
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][DateTime]$NowUtc
    )

    $activeMarkerPath = Join-Path (Join-Path $OpenPathRoot 'data') 'captive-portal-active.json'
    if ((Test-Path $activeMarkerPath -ErrorAction SilentlyContinue) -and (($NowUtc - (Get-Item $activeMarkerPath).LastWriteTimeUtc).TotalSeconds -le $RecentSuccessSeconds)) {
        return [PSCustomObject]@{
            Source = 'active-marker'
            Path = $activeMarkerPath
        }
    }

    if (-not (Test-Path $ResultPath -ErrorAction SilentlyContinue)) {
        return $null
    }

    $newestResult = Get-ChildItem -Path $ResultPath -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $newestResult -or (($NowUtc - $newestResult.LastWriteTimeUtc).TotalSeconds -gt $RecentSuccessSeconds)) {
        return $null
    }

    try {
        $payload = Get-Content $newestResult.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($payload.success -eq $true) {
            return [PSCustomObject]@{
                Source = 'result'
                Path = $newestResult.FullName
                RequestId = $payload.requestId
            }
        }
    }
    catch {
        Write-OpenPathLog "Captive portal recovery: ignoring unreadable recent result $($newestResult.FullName): $_" -Level WARN
    }

    return $null
}

function Write-OpenPathCaptivePortalRecoveryResult {
    param(
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )

    if (-not (Test-Path $ResultPath -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $ResultPath -Force | Out-Null
    }

    $targetPath = Join-Path $ResultPath "$RequestId.json"
    $Payload.requestId = $RequestId
    $Payload.completedAt = (Get-OpenPathRecoveryUtcNow).ToString('o')
    $Payload | ConvertTo-Json -Depth 6 | Set-Content -Path $targetPath -Encoding ASCII
    return $targetPath
}

function Get-OpenPathCaptivePortalRecoveryState {
    param([Parameter(Mandatory = $true)][DateTime]$NowUtc)

    return (Test-OpenPathCaptivePortalState -TimeoutSec 3)
}

function Invoke-OpenPathCaptivePortalRecoveryRequest {
    param(
        [Parameter(Mandatory = $true)][object]$RequestEnvelope,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][DateTime]$NowUtc
    )

    $requestId = [string]$RequestEnvelope.Request.requestId

    try {
        if (-not (Test-OpenPathRecoveryRequestFresh -RequestEnvelope $RequestEnvelope -NowUtc $NowUtc)) {
            Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
                success = $false
                state = 'StaleRequest'
                error = 'Request is older than 60 seconds'
                activeMarker = $false
                portalModeActive = $false
            } | Out-Null
            return
        }

        $recentSuccess = Get-OpenPathRecentCaptivePortalRecoverySuccess -ResultPath $ResultPath -NowUtc $NowUtc
        if ($recentSuccess) {
            Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
                success = $true
                state = 'RecentSuccess'
                activeMarker = $true
                portalModeActive = $true
                recentSuccessSource = $recentSuccess.Source
                recentSuccessRequestId = $recentSuccess.RequestId
            } | Out-Null
            return
        }

        $state = Get-OpenPathCaptivePortalRecoveryState -NowUtc $NowUtc
        $success = $false
        $activeMarker = $false

        if ($state -eq 'Portal') {
            Update-OpenPathCaptivePortalObservation -DetectedState Portal | Out-Null
            Enable-OpenPathCaptivePortalMode -State Portal | Out-Null
            $success = $true
            $activeMarker = $true
        }

        Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
            success = $success
            state = [string]$state
            activeMarker = $activeMarker
            portalModeActive = $activeMarker
        } | Out-Null
    }
    catch {
        Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
            success = $false
            state = 'Error'
            error = [string]$_
            activeMarker = $false
            portalModeActive = $false
        } | Out-Null
        throw
    }
    finally {
        Remove-Item -Path $RequestEnvelope.File.FullName -Force -ErrorAction SilentlyContinue
    }
}

$queuePath = Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryQueue -OpenPathRoot $OpenPathRoot
$resultPath = Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryResult -OpenPathRoot $OpenPathRoot
$nowUtc = Get-OpenPathRecoveryUtcNow
$requestEnvelopes = @(Get-OpenPathCaptivePortalRecoveryRequests -QueuePath $queuePath)

if ($requestEnvelopes.Count -eq 0) {
    Write-OpenPathLog 'Captive portal recovery: no pending request found' -Level WARN
    return
}

foreach ($requestEnvelope in $requestEnvelopes) {
    Invoke-OpenPathCaptivePortalRecoveryRequest -RequestEnvelope $requestEnvelope -ResultPath $resultPath -NowUtc $nowUtc
}
