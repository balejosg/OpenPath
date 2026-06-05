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
    'Get-OpenPathCaptivePortalAllowedHosts',
    'Get-OpenPathConfiguredCaptivePortalDomains',
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

function Get-OpenPathRecoveryConfiguredCaptivePortalDomains {
    if (-not (Get-Command -Name 'Get-OpenPathConfiguredCaptivePortalDomains' -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        return @(Get-OpenPathConfiguredCaptivePortalDomains)
    }
    catch {
        return @()
    }
}

function Test-OpenPathRecoveryConfiguredCaptivePortalDomainsApplied {
    param(
        [string[]]$AllowedHosts = @(),
        [string[]]$ConfiguredCaptivePortalDomains = @()
    )

    $configuredDomains = @(
        $ConfiguredCaptivePortalDomains |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    foreach ($configuredDomain in @($configuredDomains)) {
        if (@($AllowedHosts) -notcontains $configuredDomain) {
            return $false
        }
    }

    return $true
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
    $bootstrapHosts = if ($Marker -and $Marker.PSObject.Properties['bootstrapHosts']) { @($Marker.bootstrapHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
    $redirectHosts = if ($Marker -and $Marker.PSObject.Properties['redirectHosts']) { @($Marker.redirectHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
    $resourceHosts = if ($Marker -and $Marker.PSObject.Properties['resourceHosts']) { @($Marker.resourceHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
    $observedRuntimeHosts = if ($Marker -and $Marker.PSObject.Properties['observedRuntimeHosts']) { @($Marker.observedRuntimeHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
    $pendingRuntimeHosts = if ($Marker -and $Marker.PSObject.Properties['pendingRuntimeHosts']) { @($Marker.pendingRuntimeHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
    $discoveryTruncated = if ($Marker -and $Marker.PSObject.Properties['discoveryTruncated']) { [bool]$Marker.discoveryTruncated } else { $false }
    $fallbackMode = if ($Marker -and $Marker.PSObject.Properties['fallbackMode'] -and $Marker.fallbackMode) { [string]$Marker.fallbackMode } elseif ($mode -eq 'passthrough') { 'passthrough' } else { 'none' }
    $recoveryHostsApplied = ($mode -eq 'limited' -and $allowedHosts.Count -gt 0)
    $configuredCaptivePortalDomains = @(Get-OpenPathRecoveryConfiguredCaptivePortalDomains)
    $configuredCaptivePortalDomainsApplied = Test-OpenPathRecoveryConfiguredCaptivePortalDomainsApplied -AllowedHosts $allowedHosts -ConfiguredCaptivePortalDomains $configuredCaptivePortalDomains
    $effectiveHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($allowedHosts) + @($bootstrapHosts) + @($redirectHosts) + @($resourceHosts) + @($observedRuntimeHosts) + @($configuredCaptivePortalDomains)))
    $declaredRecoveryHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($TriggerHost) + @($configuredCaptivePortalDomains)))
    if ($declaredRecoveryHosts.Count -le 0) {
        $declaredRecoveryHosts = @($allowedHosts)
    }
    $declaredRecoveryHostsApplied = ($declaredRecoveryHosts.Count -gt 0)
    foreach ($hostName in @($declaredRecoveryHosts)) {
        if ($allowedHosts -notcontains $hostName) {
            $declaredRecoveryHostsApplied = $false
            break
        }
    }
    $limitedModeReady = ($mode -eq 'limited' -and $recoveryHostsApplied -and $declaredRecoveryHostsApplied -and $configuredCaptivePortalDomainsApplied)
    if (-not ($Marker -and $Marker.PSObject.Properties['limitedModeReady'] -and [bool]$Marker.limitedModeReady)) {
        $limitedModeReady = $false
    }
    $recentSuccessEligible = $limitedModeReady
    if ($recentSuccessEligible -and $TriggerHost) {
        $recentSuccessEligible = ($allowedHosts -contains $TriggerHost)
    }

    return [PSCustomObject]@{
        activeMarkerMode = $mode
        allowedHosts = @($allowedHosts)
        effectiveExactHosts = @($effectiveHosts)
        configuredCaptivePortalDomains = @($configuredCaptivePortalDomains)
        configuredCaptivePortalDomainsApplied = [bool]$configuredCaptivePortalDomainsApplied
        bootstrapHosts = @($bootstrapHosts)
        redirectHosts = @($redirectHosts)
        resourceHosts = @($resourceHosts)
        observedRuntimeHosts = @($observedRuntimeHosts)
        pendingRuntimeHosts = @($pendingRuntimeHosts)
        discoveryTruncated = [bool]$discoveryTruncated
        fallbackMode = [string]$fallbackMode
        limitedModeReady = [bool]$limitedModeReady
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

    if (-not ($payload.PSObject.Properties['limitedModeReady'] -and [bool]$payload.limitedModeReady)) {
        return $false
    }

    if ($payload.PSObject.Properties['fallbackMode'] -and [string]$payload.fallbackMode -eq 'passthrough') {
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

    $configuredCaptivePortalDomains = @(Get-OpenPathRecoveryConfiguredCaptivePortalDomains)
    if ($configuredCaptivePortalDomains.Count -gt 0) {
        $allowedHosts = if ($payload.PSObject.Properties['allowedHosts']) {
            @($payload.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        else {
            @()
        }
        if (-not (Test-OpenPathRecoveryConfiguredCaptivePortalDomainsApplied -AllowedHosts $allowedHosts -ConfiguredCaptivePortalDomains $configuredCaptivePortalDomains)) {
            return $false
        }
    }

    return $true
}

function Invoke-OpenPathCaptivePortalAuthenticatedRestore {
    param(
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [string]$TriggerHost = ''
    )

    Update-OpenPathCaptivePortalObservation -DetectedState Authenticated | Out-Null
    Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $RequestId -Phase 'disable' -Payload @{
        state = 'Authenticated'
        operation = $Operation
    } | Out-Null
    $disabled = [bool](Disable-OpenPathCaptivePortalMode -DnsMaxAttempts $RecoveryDnsMaxAttempts -DnsDelayMilliseconds $RecoveryDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $RecoveryDnsAttemptTimeoutSeconds)
    $postAuthEvidence = Get-OpenPathCaptivePortalProtectedModeExitEvidence -DnsMaxAttempts $RecoveryDnsMaxAttempts -DnsDelayMilliseconds $RecoveryDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $RecoveryDnsAttemptTimeoutSeconds
    $protectedModeRestored = ([bool]$disabled -and [bool]$postAuthEvidence.protectedModeRestored)
    $portalModeStillActive = Test-OpenPathCaptivePortalModeActive
    Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $RequestId -Phase 'write-result' -Payload @{
        state = 'Authenticated'
        disabled = [bool]$disabled
        protectedModeRestored = [bool]$postAuthEvidence.protectedModeRestored
    } | Out-Null
    Write-OpenPathCaptivePortalRecoveryResult -ResultPath $ResultPath -RequestId $RequestId -Payload @{
        success = $protectedModeRestored
        operation = $Operation
        state = 'Authenticated'
        triggerHost = $TriggerHost
        activeMarker = $portalModeStillActive
        portalModeActive = $portalModeStillActive
        portalExitRoute = if ($protectedModeRestored) { "$Operation-authenticated" } else { "$Operation-authenticated-restore-failed" }
        localDnsLoopbackRestored = [bool]$postAuthEvidence.localDnsLoopbackRestored
        acrylicNormalRestored = [bool]$postAuthEvidence.acrylicNormalRestored
        dnsResolutionHealthy = [bool]$postAuthEvidence.dnsResolutionHealthy
        sinkholeHealthy = [bool]$postAuthEvidence.sinkholeHealthy
        firewallExpectedActive = [bool]$postAuthEvidence.firewallExpectedActive
        firewallHealthy = [bool]$postAuthEvidence.firewallHealthy
        markerCleared = [bool]$postAuthEvidence.markerCleared
        protectedModeRestored = [bool]$postAuthEvidence.protectedModeRestored
    } | Out-Null
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
    $portalRecoveryHostCandidates = @($triggerHost)
    if ($RequestEnvelope.Request.PSObject.Properties['portalRecoveryHosts']) {
        $portalRecoveryHostCandidates += @($RequestEnvelope.Request.portalRecoveryHosts)
    }
    $portalRecoveryHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts $portalRecoveryHostCandidates)

    try {
        Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'request-read' -Payload @{
            operation = $operation
            hasTriggerHost = (-not [string]::IsNullOrWhiteSpace($triggerHost))
            portalRecoveryHostCount = @($portalRecoveryHosts).Count
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
                Invoke-OpenPathCaptivePortalAuthenticatedRestore -RequestId $requestId -Operation $operation -ResultPath $ResultPath -ProgressPath $ProgressPath
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
                effectiveExactHosts = @($markerSummary.effectiveExactHosts)
                configuredCaptivePortalDomains = @($markerSummary.configuredCaptivePortalDomains)
                configuredCaptivePortalDomainsApplied = [bool]$markerSummary.configuredCaptivePortalDomainsApplied
                bootstrapHosts = @($markerSummary.bootstrapHosts)
                redirectHosts = @($markerSummary.redirectHosts)
                resourceHosts = @($markerSummary.resourceHosts)
                observedRuntimeHosts = @($markerSummary.observedRuntimeHosts)
                pendingRuntimeHosts = @($markerSummary.pendingRuntimeHosts)
                discoveryTruncated = [bool]$markerSummary.discoveryTruncated
                fallbackMode = [string]$markerSummary.fallbackMode
                limitedModeReady = [bool]$markerSummary.limitedModeReady
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
                    effectiveExactHosts = if ($payload.PSObject.Properties['effectiveExactHosts']) { @($payload.effectiveExactHosts) } elseif ($payload.PSObject.Properties['allowedHosts']) { @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($payload.allowedHosts) + @(Get-OpenPathRecoveryConfiguredCaptivePortalDomains))) } else { @(Get-OpenPathRecoveryConfiguredCaptivePortalDomains) }
                    configuredCaptivePortalDomains = if ($payload.PSObject.Properties['configuredCaptivePortalDomains']) { @($payload.configuredCaptivePortalDomains) } else { @(Get-OpenPathRecoveryConfiguredCaptivePortalDomains) }
                    configuredCaptivePortalDomainsApplied = if ($payload.PSObject.Properties['configuredCaptivePortalDomainsApplied']) { [bool]$payload.configuredCaptivePortalDomainsApplied } else { Test-OpenPathRecoveryConfiguredCaptivePortalDomainsApplied -AllowedHosts $(if ($payload.PSObject.Properties['allowedHosts']) { @($payload.allowedHosts) } else { @() }) -ConfiguredCaptivePortalDomains @(Get-OpenPathRecoveryConfiguredCaptivePortalDomains) }
                    bootstrapHosts = if ($payload.PSObject.Properties['bootstrapHosts']) { @($payload.bootstrapHosts) } else { @() }
                    redirectHosts = if ($payload.PSObject.Properties['redirectHosts']) { @($payload.redirectHosts) } else { @() }
                    resourceHosts = if ($payload.PSObject.Properties['resourceHosts']) { @($payload.resourceHosts) } else { @() }
                    observedRuntimeHosts = if ($payload.PSObject.Properties['observedRuntimeHosts']) { @($payload.observedRuntimeHosts) } else { @() }
                    pendingRuntimeHosts = if ($payload.PSObject.Properties['pendingRuntimeHosts']) { @($payload.pendingRuntimeHosts) } else { @() }
                    discoveryTruncated = if ($payload.PSObject.Properties['discoveryTruncated']) { [bool]$payload.discoveryTruncated } else { $false }
                    fallbackMode = if ($payload.PSObject.Properties['fallbackMode']) { [string]$payload.fallbackMode } else { 'none' }
                    limitedModeReady = if ($payload.PSObject.Properties['limitedModeReady']) { [bool]$payload.limitedModeReady } else { $false }
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
                    effectiveExactHosts = @($markerSummary.effectiveExactHosts)
                    configuredCaptivePortalDomains = @($markerSummary.configuredCaptivePortalDomains)
                    configuredCaptivePortalDomainsApplied = [bool]$markerSummary.configuredCaptivePortalDomainsApplied
                    bootstrapHosts = @($markerSummary.bootstrapHosts)
                    redirectHosts = @($markerSummary.redirectHosts)
                    resourceHosts = @($markerSummary.resourceHosts)
                    observedRuntimeHosts = @($markerSummary.observedRuntimeHosts)
                    pendingRuntimeHosts = @($markerSummary.pendingRuntimeHosts)
                    discoveryTruncated = [bool]$markerSummary.discoveryTruncated
                    fallbackMode = [string]$markerSummary.fallbackMode
                    limitedModeReady = [bool]$markerSummary.limitedModeReady
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

        if ($state -eq 'Authenticated') {
            Invoke-OpenPathCaptivePortalAuthenticatedRestore -RequestId $requestId -Operation $operation -ResultPath $ResultPath -ProgressPath $ProgressPath -TriggerHost $triggerHost
            return
        }

        if ($state -eq 'Portal') {
            Update-OpenPathCaptivePortalObservation -DetectedState Portal | Out-Null
            Write-OpenPathCaptivePortalRecoveryProgress -ProgressPath $ProgressPath -RequestId $requestId -Phase 'enable' -Payload @{
                state = [string]$state
                triggerHost = $triggerHost
                portalRecoveryHostCount = @($portalRecoveryHosts).Count
            } | Out-Null
            $success = [bool](Enable-OpenPathCaptivePortalMode -State Portal -PortalRecoveryDomains $portalRecoveryHosts)
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
            portalRecoveryHosts = @($portalRecoveryHosts)
            activeMarker = $portalModeActive
            portalModeActive = $portalModeActive
            activeMarkerMode = [string]$markerSummary.activeMarkerMode
            allowedHosts = @($markerSummary.allowedHosts)
            effectiveExactHosts = @($markerSummary.effectiveExactHosts)
            configuredCaptivePortalDomains = @($markerSummary.configuredCaptivePortalDomains)
            configuredCaptivePortalDomainsApplied = [bool]$markerSummary.configuredCaptivePortalDomainsApplied
            bootstrapHosts = @($markerSummary.bootstrapHosts)
            redirectHosts = @($markerSummary.redirectHosts)
            resourceHosts = @($markerSummary.resourceHosts)
            observedRuntimeHosts = @($markerSummary.observedRuntimeHosts)
            pendingRuntimeHosts = @($markerSummary.pendingRuntimeHosts)
            discoveryTruncated = [bool]$markerSummary.discoveryTruncated
            fallbackMode = [string]$markerSummary.fallbackMode
            limitedModeReady = [bool]$markerSummary.limitedModeReady
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
