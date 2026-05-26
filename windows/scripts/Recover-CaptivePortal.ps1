# OpenPath - Captive portal recovery task

#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$MaxRequestAgeSeconds = 60
$RecentSuccessSeconds = 30
$RecoveryDnsMaxAttempts = 1
$RecoveryDnsDelayMilliseconds = 250
$RecoveryDnsAttemptTimeoutSeconds = 1

. (Join-Path $PSScriptRoot '..\lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force
Initialize-OpenPathScriptSession `
    -OpenPathRoot $OpenPathRoot `
    -DependentModules @('DNS', 'Firewall', 'CaptivePortal') `
    -RequiredCommands @(
    'Write-OpenPathLog',
    'Get-OpenPathCapabilityStoragePath',
    'Get-OpenPathCaptivePortalMarker',
    'Get-OpenPathCaptivePortalProtectedModeExitEvidence',
    'Test-OpenPathCaptivePortalState',
    'Test-OpenPathCaptivePortalModeActive',
    'Update-OpenPathCaptivePortalObservation',
    'Enable-OpenPathCaptivePortalMode',
    'Disable-OpenPathCaptivePortalMode'
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
        $marker = $null
        try {
            $marker = Get-Content $activeMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $marker = $null
        }
        return [PSCustomObject]@{
            Source = 'active-marker'
            Path = $activeMarkerPath
            Marker = $marker
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
                Payload = $payload
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

function Write-OpenPathCaptivePortalRecoveryProgress {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [ValidateSet('request-read', 'state-probe', 'enable', 'disable', 'write-result', 'error')]
        [Parameter(Mandatory = $true)][string]$Phase,
        [hashtable]$Payload = @{}
    )

    if (-not (Test-Path $ProgressPath -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $ProgressPath -Force | Out-Null
    }

    $progress = [ordered]@{
        requestId = $RequestId
        phase = $Phase
        updatedAt = (Get-OpenPathRecoveryUtcNow).ToString('o')
    }

    foreach ($key in @($Payload.Keys | Sort-Object)) {
        if ($key -in @('requestId', 'phase', 'updatedAt')) {
            continue
        }
        $progress[$key] = $Payload[$key]
    }

    $targetPath = Join-Path $ProgressPath "$RequestId.json"
    $progress | ConvertTo-Json -Depth 6 | Set-Content -Path $targetPath -Encoding ASCII
    return $targetPath
}

function Get-OpenPathCaptivePortalRecoveryState {
    param([Parameter(Mandatory = $true)][DateTime]$NowUtc)

    return (Test-OpenPathCaptivePortalState -TimeoutSec 3)
}

function Get-OpenPathCaptivePortalRecoveryMarkerSummary {
    param(
        [AllowNull()][object]$Marker,
        [string]$TriggerHost = ''
    )

    $allowedHosts = if ($Marker -and $Marker.PSObject.Properties['allowedHosts']) {
        @($Marker.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        @()
    }
    $mode = if ($Marker -and $Marker.PSObject.Properties['mode'] -and $Marker.mode) { [string]$Marker.mode } else { '' }
    $recoveryHostsApplied = ($mode -eq 'limited' -and $allowedHosts.Count -gt 0)
    $recentSuccessEligible = $recoveryHostsApplied
    if ($recentSuccessEligible -and $TriggerHost) {
        $recentSuccessEligible = ($allowedHosts -contains $TriggerHost)
    }

    return [PSCustomObject]@{
        activeMarkerMode = $mode
        allowedHosts = @($allowedHosts)
        recoveryHostsApplied = $recoveryHostsApplied
        recentSuccessEligible = [bool]$recentSuccessEligible
    }
}

function Test-OpenPathRecentCaptivePortalRecoverySuccessEligible {
    param(
        [AllowNull()][object]$RecentSuccess,
        [string]$TriggerHost = ''
    )

    if (-not $RecentSuccess) {
        return $false
    }

    if ($RecentSuccess.Source -eq 'active-marker') {
        $summary = Get-OpenPathCaptivePortalRecoveryMarkerSummary -Marker $RecentSuccess.Marker -TriggerHost $TriggerHost
        return [bool]$summary.recentSuccessEligible
    }

    $payload = if ($RecentSuccess.PSObject.Properties['Payload']) { $RecentSuccess.Payload } else { $null }
    if (-not $payload) {
        return $false
    }

    $eligible = if ($payload.PSObject.Properties['recentSuccessEligible']) { [bool]$payload.recentSuccessEligible } else { $false }
    if (-not $eligible) {
        return $false
    }

    if ($payload.PSObject.Properties['activeMarkerMode'] -and [string]$payload.activeMarkerMode -eq 'passthrough') {
        return $false
    }

    if ($TriggerHost) {
        $allowedHosts = if ($payload.PSObject.Properties['allowedHosts']) {
            @($payload.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        else {
            @()
        }
        if ($allowedHosts.Count -le 0 -or $allowedHosts -notcontains $TriggerHost) {
            return $false
        }
    }

    return $true
}

function Invoke-OpenPathCaptivePortalRecoveryRequest {
    param(
        [Parameter(Mandatory = $true)][object]$RequestEnvelope,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][DateTime]$NowUtc
    )

    $requestId = [string]$RequestEnvelope.Request.requestId
    $operation = 'open'
    if ($RequestEnvelope.Request.PSObject.Properties['operation'] -and $RequestEnvelope.Request.operation) {
        $candidateOperation = ([string]$RequestEnvelope.Request.operation).Trim().ToLowerInvariant()
        if ($candidateOperation -in @('open', 'reconcile')) {
            $operation = $candidateOperation
        }
    }
    $triggerHost = ''
    if ($RequestEnvelope.Request.PSObject.Properties['triggerHost'] -and $RequestEnvelope.Request.triggerHost) {
        $triggerHost = [string]$RequestEnvelope.Request.triggerHost
    }

    try {
        Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'request-read' -Payload @{
            operation = $operation
            hasTriggerHost = (-not [string]::IsNullOrWhiteSpace($triggerHost))
        } | Out-Null

        if (-not (Test-OpenPathRecoveryRequestFresh -RequestEnvelope $RequestEnvelope -NowUtc $NowUtc)) {
            Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'write-result' -Payload @{
                state = 'StaleRequest'
            } | Out-Null
            Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
                success = $false
                state = 'StaleRequest'
                error = 'Request is older than 60 seconds'
                activeMarker = $false
                portalModeActive = $false
            } | Out-Null
            return
        }

        if ($operation -eq 'reconcile') {
            Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'state-probe' -Payload @{
                operation = $operation
            } | Out-Null
            $state = Get-OpenPathCaptivePortalRecoveryState -NowUtc $NowUtc
            if ($state -eq 'Authenticated') {
                Update-OpenPathCaptivePortalObservation -DetectedState Authenticated | Out-Null
                Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'disable' -Payload @{
                    state = [string]$state
                } | Out-Null
                $disabled = [bool](Disable-OpenPathCaptivePortalMode -DnsMaxAttempts $RecoveryDnsMaxAttempts -DnsDelayMilliseconds $RecoveryDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $RecoveryDnsAttemptTimeoutSeconds)
                $postAuthEvidence = Get-OpenPathCaptivePortalProtectedModeExitEvidence -DnsMaxAttempts $RecoveryDnsMaxAttempts -DnsDelayMilliseconds $RecoveryDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $RecoveryDnsAttemptTimeoutSeconds
                Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'write-result' -Payload @{
                    state = [string]$state
                    disabled = [bool]$disabled
                } | Out-Null
                Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
                    success = $disabled
                    operation = $operation
                    state = [string]$state
                    triggerHost = ''
                    activeMarker = (-not $disabled)
                    portalModeActive = (-not $disabled)
                    portalExitRoute = if ($disabled) { 'reconcile-authenticated' } else { 'reconcile-authenticated-restore-failed' }
                    localDnsLoopbackRestored = [bool]$postAuthEvidence.localDnsLoopbackRestored
                    acrylicNormalRestored = [bool]$postAuthEvidence.acrylicNormalRestored
                    dnsResolutionHealthy = [bool]$postAuthEvidence.dnsResolutionHealthy
                    sinkholeHealthy = [bool]$postAuthEvidence.sinkholeHealthy
                    firewallExpectedActive = [bool]$postAuthEvidence.firewallExpectedActive
                    firewallHealthy = [bool]$postAuthEvidence.firewallHealthy
                    markerCleared = [bool]$postAuthEvidence.markerCleared
                    protectedModeRestored = [bool]$postAuthEvidence.protectedModeRestored
                } | Out-Null
                return
            }

            $activeMarker = if (Test-OpenPathCaptivePortalModeActive) { Get-OpenPathCaptivePortalMarker } else { $null }
            $markerSummary = Get-OpenPathCaptivePortalRecoveryMarkerSummary -Marker $activeMarker
            Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'write-result' -Payload @{
                state = [string]$state
            } | Out-Null
            Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
                success = $false
                operation = $operation
                state = [string]$state
                triggerHost = ''
                activeMarker = (Test-OpenPathCaptivePortalModeActive)
                portalModeActive = (Test-OpenPathCaptivePortalModeActive)
                portalExitRoute = 'reconcile-not-authenticated'
                activeMarkerMode = [string]$markerSummary.activeMarkerMode
                allowedHosts = @($markerSummary.allowedHosts)
                recoveryHostsApplied = [bool]$markerSummary.recoveryHostsApplied
                recentSuccessEligible = [bool]$markerSummary.recentSuccessEligible
            } | Out-Null
            return
        }

        $recentSuccess = Get-OpenPathRecentCaptivePortalRecoverySuccess -ResultPath $ResultPath -NowUtc $NowUtc
        if ($recentSuccess -and (Test-OpenPathRecentCaptivePortalRecoverySuccessEligible -RecentSuccess $recentSuccess -TriggerHost $triggerHost)) {
            $recentMarker = if ($recentSuccess.Source -eq 'active-marker') { $recentSuccess.Marker } else { $recentSuccess.Payload }
            $markerSummary = Get-OpenPathCaptivePortalRecoveryMarkerSummary -Marker $recentMarker -TriggerHost $triggerHost
            if ($recentSuccess.Source -eq 'result' -and $recentSuccess.PSObject.Properties['Payload']) {
                $payload = $recentSuccess.Payload
                $markerSummary = [PSCustomObject]@{
                    activeMarkerMode = if ($payload.PSObject.Properties['activeMarkerMode']) { [string]$payload.activeMarkerMode } else { '' }
                    allowedHosts = if ($payload.PSObject.Properties['allowedHosts']) { @($payload.allowedHosts) } else { @() }
                    recoveryHostsApplied = if ($payload.PSObject.Properties['recoveryHostsApplied']) { [bool]$payload.recoveryHostsApplied } else { $false }
                    recentSuccessEligible = if ($payload.PSObject.Properties['recentSuccessEligible']) { [bool]$payload.recentSuccessEligible } else { $false }
                }
            }

                Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'write-result' -Payload @{
                    state = 'RecentSuccess'
                    recentSuccessSource = $recentSuccess.Source
                } | Out-Null
                Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
                    success = $true
                    operation = $operation
                    state = 'RecentSuccess'
                    activeMarker = $true
                    portalModeActive = $true
                    triggerHost = $triggerHost
                    activeMarkerMode = [string]$markerSummary.activeMarkerMode
                    allowedHosts = @($markerSummary.allowedHosts)
                    recoveryHostsApplied = [bool]$markerSummary.recoveryHostsApplied
                    recentSuccessEligible = [bool]$markerSummary.recentSuccessEligible
                    recentSuccessSource = $recentSuccess.Source
                    recentSuccessRequestId = $recentSuccess.RequestId
                } | Out-Null
                return
        }

        Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'state-probe' -Payload @{
            operation = $operation
        } | Out-Null
        $state = Get-OpenPathCaptivePortalRecoveryState -NowUtc $NowUtc
        $success = $false
        $activeMarker = $null

        if ($state -eq 'Portal') {
            Update-OpenPathCaptivePortalObservation -DetectedState Portal | Out-Null
            Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'enable' -Payload @{
                state = [string]$state
                triggerHost = $triggerHost
            } | Out-Null
            $success = [bool](Enable-OpenPathCaptivePortalMode -State Portal -PortalRecoveryDomains @($triggerHost))
            if ($success) {
                $activeMarker = Get-OpenPathCaptivePortalMarker
            }
        }

        $markerSummary = Get-OpenPathCaptivePortalRecoveryMarkerSummary -Marker $activeMarker -TriggerHost $triggerHost
        $portalModeActive = [bool]$success

        Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'write-result' -Payload @{
            state = [string]$state
            portalModeActive = $portalModeActive
        } | Out-Null
        Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $requestId -Payload @{
            success = $success
            operation = $operation
            state = [string]$state
            triggerHost = $triggerHost
            activeMarker = $portalModeActive
            portalModeActive = $portalModeActive
            activeMarkerMode = [string]$markerSummary.activeMarkerMode
            allowedHosts = @($markerSummary.allowedHosts)
            recoveryHostsApplied = [bool]$markerSummary.recoveryHostsApplied
            recentSuccessEligible = [bool]$markerSummary.recentSuccessEligible
        } | Out-Null
    }
    catch {
        Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'error' -Payload @{
            error = [string]$_
        } | Out-Null
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
$progressPath = Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryProgress -OpenPathRoot $OpenPathRoot
$nowUtc = Get-OpenPathRecoveryUtcNow
$requestEnvelopes = @(Get-OpenPathCaptivePortalRecoveryRequests -QueuePath $queuePath)

if ($requestEnvelopes.Count -eq 0) {
    Write-OpenPathLog 'Captive portal recovery: no pending request found' -Level WARN
    return
}

foreach ($requestEnvelope in $requestEnvelopes) {
    Invoke-OpenPathCaptivePortalRecoveryRequest -RequestEnvelope $requestEnvelope -ResultPath $resultPath -ProgressPath $progressPath -NowUtc $nowUtc
}
