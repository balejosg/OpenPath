function Import-NativeHostRequestSetupStateModule {
    if (Get-Command -Name 'Get-OpenPathRequestSetupState' -ErrorAction SilentlyContinue) {
        return
    }

    $candidatePaths = @()
    if (Get-Variable -Name NativeRoot -Scope Script -ErrorAction SilentlyContinue) {
        $candidatePaths += (Join-Path $script:NativeRoot 'RequestSetup.State.psm1')
    }
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $candidatePaths += (Join-Path $script:OpenPathRoot 'lib\RequestSetup.State.psm1')
    }
    if ($PSScriptRoot) {
        $candidatePaths += (Join-Path $PSScriptRoot 'RequestSetup.State.psm1')
        $candidatePaths += (Join-Path (Split-Path $PSScriptRoot -Parent) 'RequestSetup.State.psm1')
    }

    foreach ($candidatePath in ($candidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $candidatePath -ErrorAction SilentlyContinue) {
            Import-Module $candidatePath -Force -ErrorAction Stop
            return
        }
    }

    throw 'RequestSetup.State.psm1 is required for native host request setup interpretation.'
}

Import-NativeHostRequestSetupStateModule

$nativeHostRedactionCandidatePaths = @()
if (Get-Variable -Name NativeRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostRedactionCandidatePaths += (Join-Path $script:NativeRoot 'Common.Redaction.ps1')
}
if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostRedactionCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\Common.Redaction.ps1')
}
if ($PSScriptRoot) {
    $nativeHostRedactionCandidatePaths += (Join-Path $PSScriptRoot 'Common.Redaction.ps1')
}

foreach ($nativeHostRedactionCandidatePath in ($nativeHostRedactionCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $nativeHostRedactionCandidatePath -ErrorAction SilentlyContinue) {
        . $nativeHostRedactionCandidatePath
        break
    }
}

if (-not (Get-Command -Name 'ConvertTo-OpenPathRedactedValue' -ErrorAction SilentlyContinue)) {
    throw 'Common.Redaction.ps1 is required for native host log redaction.'
}

if (-not (Get-Variable -Name NativeHostPortalProbeCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:NativeHostPortalProbeCache = @{}
}

$nativeHostTaskRunnerCandidatePaths = @()
if ($PSScriptRoot) {
    $nativeHostTaskRunnerCandidatePaths += (Join-Path $PSScriptRoot 'TaskRunner.ps1')
}
if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostTaskRunnerCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\TaskRunner.ps1')
}

foreach ($nativeHostTaskRunnerCandidatePath in ($nativeHostTaskRunnerCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $nativeHostTaskRunnerCandidatePath -ErrorAction SilentlyContinue) {
        . $nativeHostTaskRunnerCandidatePath
        break
    }
}

if (-not (Get-Command -Name 'Invoke-OpenPathScheduledTask' -ErrorAction SilentlyContinue)) {
    throw 'TaskRunner.ps1 is required for native host scheduled task execution.'
}

$nativeHostRuntimeDependencyCandidatePaths = @()
if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\CapabilityStorage.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Protocol.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Policy.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Queue.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Overlay.ps1')
}
if ($PSScriptRoot) {
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'CapabilityStorage.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Protocol.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Policy.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Queue.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Overlay.ps1')
}

foreach ($nativeHostRuntimeDependencyCandidatePath in ($nativeHostRuntimeDependencyCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $nativeHostRuntimeDependencyCandidatePath -ErrorAction SilentlyContinue) {
        . $nativeHostRuntimeDependencyCandidatePath
    }
}

if (-not (Get-Command -Name 'Test-OpenPathRuntimeDependencyCandidate' -ErrorAction SilentlyContinue)) {
    throw 'RuntimeDependency.Policy.ps1 is required for native host runtime dependency validation.'
}

# Native-host runtime dependency actions delegate validation to RuntimeDependency.Policy.ps1.
# Policy result strings preserved: Sensitive fields are not accepted;
# reason = 'dependency-already-whitelisted'
# reason = 'runtime-dependency-overlay-present'

function Get-NativeHostValidDomains {
    param(
        [AllowNull()]
        [object[]]$Domains = @()
    )

    $maxDomains = 200
    if ($script:MaxDomains) {
        try { $maxDomains = [Math]::Max(1, [int]$script:MaxDomains) } catch { $maxDomains = 200 }
    }

    return @($Domains) |
        Where-Object { $_ -is [string] } |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { $_ -match '^[a-z0-9.-]+$' } |
        Select-Object -First $maxDomains
}

function Get-NativeHostRuntimeDependencyQueuePath {
    return (Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue -OpenPathRoot $script:OpenPathRoot)
}

function Get-NativeHostRuntimeDependencySettings {
    $ttlDays = 7
    $capacity = 300
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) {
        try { $ttlDays = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) } catch { $ttlDays = 7 }
    }
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) {
        try { $capacity = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) } catch { $capacity = 300 }
    }

    return [PSCustomObject]@{
        TtlDays = $ttlDays
        Capacity = $capacity
    }
}

function Normalize-NativeHostRuntimeDependencyHost {
    param([AllowNull()][object]$Value)

    return (Normalize-OpenPathRuntimeDependencyHost -Value $Value)
}

function Normalize-NativeHostCaptivePortalTriggerHost {
    param([AllowNull()][object]$Value)

    return (Normalize-NativeHostRuntimeDependencyHost -Value $Value)
}

function Get-NativeHostCaptivePortalRecoveryQueuePath {
    if ($env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH) {
        return $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH
    }

    return (Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryQueue -OpenPathRoot $script:OpenPathRoot)
}

function Get-NativeHostCaptivePortalRecoveryResultPath {
    if ($env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH) {
        return $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH
    }

    return (Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryResult -OpenPathRoot $script:OpenPathRoot)
}

function Get-NativeHostCaptivePortalRecoveryProgressPath {
    if ($env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH) {
        return $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH
    }

    return (Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryProgress -OpenPathRoot $script:OpenPathRoot)
}

function Get-NativeHostCaptivePortalRecoveryFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$PhaseProperty = ''
    )

    $files = @()
    $requestIds = @()
    $latestPhase = ''

    if (Test-Path $Path -ErrorAction SilentlyContinue) {
        $files = @(Get-ChildItem -Path $Path -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name)
    }

    foreach ($file in $files) {
        $requestId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        try {
            $payload = Get-Content -Path $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($payload.PSObject.Properties['requestId'] -and $payload.requestId) {
                $requestId = [string]$payload.requestId
            }
        }
        catch {
            $payload = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($requestId)) {
            $requestIds += $requestId
        }

        if ($PhaseProperty -and $file -eq $files[-1] -and $payload -and $payload.PSObject.Properties[$PhaseProperty]) {
            $latestPhase = [string]$payload.$PhaseProperty
        }
    }

    return @{
        count = [int]$files.Count
        requestIds = @($requestIds | Select-Object -Unique)
        latestPhase = $latestPhase
    }
}

function Get-NativeHostCaptivePortalRecoveryDiagnosticSnapshot {
    $queuePath = Get-NativeHostCaptivePortalRecoveryQueuePath
    $resultPath = Get-NativeHostCaptivePortalRecoveryResultPath
    $progressPath = Get-NativeHostCaptivePortalRecoveryProgressPath
    $queue = Get-NativeHostCaptivePortalRecoveryFileSnapshot -Path $queuePath
    $result = Get-NativeHostCaptivePortalRecoveryFileSnapshot -Path $resultPath
    $progress = Get-NativeHostCaptivePortalRecoveryFileSnapshot -Path $progressPath -PhaseProperty 'phase'

    return @{
        queuePath = $queuePath
        resultPath = $resultPath
        progressPath = $progressPath
        queueFileCount = [int]$queue.count
        resultFileCount = [int]$result.count
        progressFileCount = [int]$progress.count
        pendingRequestIds = @($queue.requestIds)
        resultRequestIds = @($result.requestIds)
        progressRequestIds = @($progress.requestIds)
        latestProgressPhase = [string]$progress.latestPhase
    }
}

function Add-NativeHostCaptivePortalRecoveryDiagnostics {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Response,
        [AllowNull()][hashtable]$TaskResult = $null
    )

    if ($TaskResult) {
        foreach ($key in @(
                'taskState',
                'taskLastResult',
                'taskLastResultHex',
                'taskLastRunTime',
                'taskNextRunTime',
                'taskNumberOfMissedRuns',
                'taskDiagnosticsError'
            )) {
            if ($TaskResult.ContainsKey($key)) {
                $Response[$key] = $TaskResult[$key]
            }
        }
    }

    $snapshot = Get-NativeHostCaptivePortalRecoveryDiagnosticSnapshot
    foreach ($key in $snapshot.Keys) {
        $Response[$key] = $snapshot[$key]
    }

    return $Response
}

function Write-NativeHostCaptivePortalRecoveryRequest {
    param(
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TriggerHost,
        [ValidateSet('open', 'reconcile')]
        [string]$Operation = 'open',
        [string]$PortalState = 'Unknown',
        [string]$Source = 'native-host',
        [AllowNull()][object]$TabId = $null
    )

    $queuePath = Get-NativeHostCaptivePortalRecoveryQueuePath
    New-Item -ItemType Directory -Path $queuePath -Force | Out-Null

    $request = [ordered]@{
        requestId = $RequestId
        operation = $Operation
        triggerHost = $TriggerHost
        portalState = $PortalState
        source = $Source
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    if ($null -ne $TabId) {
        try {
            $request['tabId'] = [int]$TabId
        }
        catch {
            $request['tabId'] = [string]$TabId
        }
    }

    $requestPath = Join-Path $queuePath "$RequestId.json"
    $request | ConvertTo-Json -Depth 4 | Set-Content -Path $requestPath -Encoding UTF8
    return $requestPath
}

function Read-NativeHostCaptivePortalRecoveryResult {
    param(
        [Parameter(Mandatory = $true)][string]$RequestId
    )

    $resultPath = Join-Path (Get-NativeHostCaptivePortalRecoveryResultPath) "$RequestId.json"
    if (-not (Test-Path $resultPath -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $result = Get-Content -Path $resultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $result.PSObject.Properties['requestId']) {
            return $null
        }
        if (-not ([string]$result.requestId).Equals($RequestId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        return $result
    }
    catch {
        return $null
    }
}

function Get-NativeHostCaptivePortalActiveMarker {
    $markerPath = 'C:\OpenPath\data\captive-portal-active.json'
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $markerPath = Join-Path (Join-Path $script:OpenPathRoot 'data') 'captive-portal-active.json'
    }

    if (-not (Test-Path $markerPath -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $payload = Get-Content -Path $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($payload.PSObject.Properties['active'] -and -not [bool]$payload.active) {
            return $null
        }
        if (-not $payload.PSObject.Properties['expiresAt'] -or -not $payload.expiresAt) {
            return $null
        }
        $expiresAt = [DateTime]::Parse([string]$payload.expiresAt).ToUniversalTime()
        if ([DateTime]::UtcNow -ge $expiresAt) {
            return $null
        }
        $payload | Add-Member -NotePropertyName Path -NotePropertyValue $markerPath -Force
        $payload | Add-Member -NotePropertyName LastWriteTimeUtc -NotePropertyValue (Get-Item $markerPath).LastWriteTimeUtc -Force
        return $payload
    }
    catch {
        return $null
    }
}

function Get-NativeHostCaptivePortalMarkerSummary {
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

function Get-NativeHostRecentCaptivePortalRecoverySuccess {
    param([int]$RecentSuccessSeconds = 30)

    $activeMarker = Get-NativeHostCaptivePortalActiveMarker
    if ($activeMarker -and $activeMarker.PSObject.Properties['LastWriteTimeUtc']) {
        $markerAgeSeconds = ([DateTime]::UtcNow - $activeMarker.LastWriteTimeUtc).TotalSeconds
        if ($markerAgeSeconds -le [Math]::Max(1, $RecentSuccessSeconds)) {
            $markerSummary = Get-NativeHostCaptivePortalMarkerSummary -Marker $activeMarker
            return [PSCustomObject]@{
                Source = 'active-marker'
                RequestId = ''
                State = if ($activeMarker.PSObject.Properties['state']) { [string]$activeMarker.state } else { 'Portal' }
                PortalModeActive = $true
                Marker = $activeMarker
                ActiveMarkerMode = [string]$markerSummary.activeMarkerMode
                AllowedHosts = @($markerSummary.allowedHosts)
                RecoveryHostsApplied = [bool]$markerSummary.recoveryHostsApplied
                RecentSuccessEligible = [bool]$markerSummary.recentSuccessEligible
                Path = if ($activeMarker.PSObject.Properties['Path']) { [string]$activeMarker.Path } else { '' }
                LastWriteTimeUtc = $activeMarker.LastWriteTimeUtc
            }
        }
    }

    $resultRoot = Get-NativeHostCaptivePortalRecoveryResultPath
    if (-not (Test-Path $resultRoot -ErrorAction SilentlyContinue)) {
        return $null
    }

    $cutoffUtc = [DateTime]::UtcNow.AddSeconds(-1 * [Math]::Max(1, $RecentSuccessSeconds))
    $recentResultFile = Get-ChildItem -Path $resultRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $cutoffUtc } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $recentResultFile) {
        return $null
    }

    try {
        $payload = Get-Content -Path $recentResultFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $state = if ($payload.PSObject.Properties['state'] -and $payload.state) { [string]$payload.state } else { 'Unknown' }
        $portalModeActive = if ($payload.PSObject.Properties['portalModeActive']) { [bool]$payload.portalModeActive } else { $false }
        $success = if ($payload.PSObject.Properties['success']) { [bool]$payload.success } else { $false }
        if (-not ($success -and ($portalModeActive -or $state -in @('Portal', 'RecentSuccess')))) {
            return $null
        }

        return [PSCustomObject]@{
            Source = 'result'
            RequestId = if ($payload.PSObject.Properties['requestId']) { [string]$payload.requestId } else { '' }
            State = $state
            PortalModeActive = $true
            ActiveMarkerMode = if ($payload.PSObject.Properties['activeMarkerMode']) { [string]$payload.activeMarkerMode } else { '' }
            AllowedHosts = if ($payload.PSObject.Properties['allowedHosts']) { @($payload.allowedHosts) } else { @() }
            RecoveryHostsApplied = if ($payload.PSObject.Properties['recoveryHostsApplied']) { [bool]$payload.recoveryHostsApplied } else { $false }
            RecentSuccessEligible = if ($payload.PSObject.Properties['recentSuccessEligible']) { [bool]$payload.recentSuccessEligible } else { $false }
            Payload = $payload
            Path = $recentResultFile.FullName
            LastWriteTimeUtc = $recentResultFile.LastWriteTimeUtc
        }
    }
    catch {
        return $null
    }
}

function Test-NativeHostRecentCaptivePortalSuccessEligible {
    param(
        [AllowNull()][object]$RecentSuccess,
        [string]$TriggerHost = ''
    )

    if (-not $RecentSuccess) {
        return $false
    }

    $eligible = if ($RecentSuccess.PSObject.Properties['RecentSuccessEligible']) { [bool]$RecentSuccess.RecentSuccessEligible } else { $false }
    if (-not $eligible) {
        return $false
    }

    if ($RecentSuccess.PSObject.Properties['ActiveMarkerMode'] -and [string]$RecentSuccess.ActiveMarkerMode -eq 'passthrough') {
        return $false
    }

    if ($TriggerHost) {
        $allowedHosts = if ($RecentSuccess.PSObject.Properties['AllowedHosts']) {
            @($RecentSuccess.AllowedHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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

function Test-NativeHostBlockedSubdomainMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string[]]$BlockedSubdomains = @()
    )

    foreach ($blockedSubdomain in @($BlockedSubdomains)) {
        if (Test-OpenPathBlockedSubdomainMatch -Domain $Domain -BlockedSubdomains @($blockedSubdomain)) { return $true }
    }

    return $false
}

function Test-NativeHostWhitelistCoversHost {
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [System.Collections.Generic.HashSet[string]]$WhitelistSet
    )

    return (Test-OpenPathWhitelistCoversHost -Hostname $Hostname -WhitelistSet $WhitelistSet)
}

function Get-NativeHostMicrosoftSystemRuntimeDependencyRoots {
    return @(
        'windowsupdate.com',
        'windowsupdate.microsoft.com',
        'update.microsoft.com',
        'delivery.mp.microsoft.com',
        'do.dsp.mp.microsoft.com',
        'api.cdp.microsoft.com',
        'definitionupdates.microsoft.com',
        'download.microsoft.com',
        'download.windowsupdate.com',
        'go.microsoft.com',
        'adl.windows.com',
        'tsfe.trafficshaping.dsp.mp.microsoft.com',
        'wdcp.microsoft.com',
        'wdcpalt.microsoft.com',
        'wd.microsoft.com',
        'smartscreen-prod.microsoft.com',
        'crl.microsoft.com',
        'www.microsoft.com',
        'msftconnecttest.com',
        'www.msftconnecttest.com',
        'wns.windows.com',
        'displaycatalog.mp.microsoft.com',
        'storequality.microsoft.com',
        'dsx.mp.microsoft.com',
        'edge.microsoft.com',
        'config.edge.skype.com',
        'iecvlist.microsoft.com',
        'manage.microsoft.com',
        'dm.microsoft.com',
        'graph.microsoft.com',
        'login.microsoft.com',
        'login.live.com',
        'login.microsoftonline.com',
        'aadcdn.msauth.net',
        'aadcdn.msftauth.net',
        'azureedge.net',
        'blob.core.windows.net'
    )
}

function Get-NativeHostProtectedRuntimeDependencyHosts {
    param([Parameter(Mandatory = $true)][PSCustomObject]$State)

    $hosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($protectedHost in @(
            'raw.githubusercontent.com',
            'github.com',
            'githubusercontent.com',
            'api.github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
            'sourceforge.net',
            'downloads.sourceforge.net',
            'detectportal.firefox.com',
            'connectivity-check.ubuntu.com',
            'captive.apple.com',
            'www.msftconnecttest.com',
            'msftconnecttest.com',
            'clients3.google.com',
            'time.windows.com',
            'time.google.com'
        ) + @(Get-NativeHostMicrosoftSystemRuntimeDependencyRoots)) {
        $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $protectedHost
        if ($normalized) { [void]$hosts.Add($normalized) }
    }

    foreach ($propertyName in @('apiUrl', 'requestApiUrl', 'whitelistUrl')) {
        if (-not $State.PSObject.Properties[$propertyName]) { continue }
        try {
            $uri = [System.Uri]([string]$State.$propertyName)
            $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $uri.Host
            if ($normalized) { [void]$hosts.Add($normalized) }
        }
        catch { }
    }

    return $hosts
}

function Test-NativeHostProtectedRuntimeDependencyHost {
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [System.Collections.Generic.HashSet[string]]$ProtectedHosts
    )

    return (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $Hostname -ProtectedHosts $ProtectedHosts)
}

function Test-NativeHostSensitiveRuntimeDependencyField {
    param([Parameter(Mandatory = $true)][object]$Message)

    return (Test-OpenPathRuntimeDependencySensitiveField -Message $Message)
}

function Find-NativeHostRuntimeDependencyQueueRequest {
    param(
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost,
        [Parameter(Mandatory = $true)][string]$RequestType,
        [Parameter(Mandatory = $true)][string]$QueuePath
    )

    return (Find-OpenPathRuntimeDependencyQueueRequest `
            -AnchorHost $AnchorHost `
            -DependencyHost $DependencyHost `
            -RequestType $RequestType `
            -QueuePath $QueuePath)
}

function Write-NativeHostRuntimeDependencyQueueRequest {
    param(
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost,
        [Parameter(Mandatory = $true)][string]$RequestType
    )

    $queuePath = Get-NativeHostRuntimeDependencyQueuePath
    return (Write-OpenPathRuntimeDependencyQueueRequest `
        -AnchorHost $AnchorHost `
        -DependencyHost $DependencyHost `
        -RequestType $RequestType `
        -QueuePath $queuePath)
}

function Test-NativeHostRuntimeDependencyOverlayContainsDomains {
    param([string[]]$Domains = @())

    if (@($Domains).Count -eq 0) {
        return $true
    }

    $path = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $script:OpenPathRoot
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $entryHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($parsed.entries)) {
            if ($entry.PSObject.Properties['dependencyHost'] -and $entry.dependencyHost) {
                [void]$entryHosts.Add(([string]$entry.dependencyHost).Trim().Trim('.').ToLowerInvariant())
            }
        }

        foreach ($domain in @($Domains)) {
            $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $domain
            if (-not $normalized -or -not $entryHosts.Contains($normalized)) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-NativeHostLog "Failed to inspect runtime dependency overlay: $_"
        return $false
    }
}

function Test-NativeHostRuntimeDependencyQueueRequestProcessed {
    param([AllowNull()][string]$RequestPath = '')

    if ([string]::IsNullOrWhiteSpace($RequestPath)) {
        return $true
    }

    return -not (Test-Path $RequestPath -ErrorAction SilentlyContinue)
}

function Invoke-NativeHostMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$TimeoutMilliseconds = 15000
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $Name)
        try { $lockAcquired = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [System.Threading.AbandonedMutexException] { $lockAcquired = $true }
        if (-not $lockAcquired) {
            throw "Timed out waiting for $Name"
        }
        return (& $Action)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try { $mutex.ReleaseMutex() } catch [System.ApplicationException] { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Import-NativeHostDnsModule {
    $dnsModulePath = Join-Path $script:OpenPathRoot 'lib\DNS.psm1'
    if (Test-Path $dnsModulePath -ErrorAction SilentlyContinue) {
        Import-Module $dnsModulePath -Force -ErrorAction Stop
    }
}

function Get-NativeHostTaskRunner {
    return (New-OpenPathSchtasksRunner)
}

function Resolve-NativeHostLocalRuntimeDependencyCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    return (Test-OpenPathRuntimeDependencyCandidate `
            -Message $Message `
            -WhitelistedDomains @($Sections.Whitelist) `
            -BlockedSubdomains @($Sections.BlockedSubdomains) `
            -State $State)
}

function Invoke-NativeHostLocalRuntimeDependencyAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $Message -State $State -Sections $Sections
    if ($candidate.Valid -ne $true) {
        return $candidate.Result
    }

    $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $requestPath = Write-NativeHostRuntimeDependencyQueueRequest `
        -AnchorHost $candidate.AnchorHost `
        -DependencyHost $candidate.DependencyHost `
        -RequestType $candidate.RequestType
    $queueWriteStopwatch.Stop()

    $updateResult = Invoke-UpdateTask `
        -RuntimeDependencyDomains @($candidate.DependencyHost) `
        -RuntimeDependencyRequestPath $requestPath `
        -TimeoutSeconds 14
    if ($updateResult.success -ne $true) {
        return @{
            success = $false
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
            error = $updateResult.error
        }
    }

    return @{
        success = $true
        action = $script:OpenPathRuntimeDependencyActionAllowLocal
        anchorHost = $candidate.AnchorHost
        dependencyHost = $candidate.DependencyHost
        requestType = $candidate.RequestType
        queued = $true
        requestPath = $requestPath
        queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
        updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
    }
}

function Invoke-NativeHostLocalRuntimeDependencyBatchAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $entries = @($Message.entries)
    if ($entries.Count -eq 0) {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch; error = 'Invalid runtime dependency batch payload'; results = @() }
    }

    $results = @()
    $queuedResults = @()
    $queuedDependencyHosts = @()
    $updateResult = $null

    foreach ($entry in @($entries | Select-Object -First $script:OpenPathRuntimeDependencyBatchMaxEntries)) {
        $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $entry -State $State -Sections $Sections
        if ($candidate.Valid -ne $true) {
            $results += $candidate.Result
            continue
        }

        $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $requestPath = Write-NativeHostRuntimeDependencyQueueRequest `
            -AnchorHost $candidate.AnchorHost `
            -DependencyHost $candidate.DependencyHost `
            -RequestType $candidate.RequestType
        $queueWriteStopwatch.Stop()
        $result = @{
            success = $true
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
        }
        $results += $result
        $queuedResults += $result
        $queuedDependencyHosts += $candidate.DependencyHost
    }

    if ($entries.Count -gt $script:OpenPathRuntimeDependencyBatchMaxEntries) {
        $results += @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'Runtime dependency batch limit exceeded' }
    }

    if ($queuedDependencyHosts.Count -gt 0) {
        $queuedDependencyHosts = @($queuedDependencyHosts | Sort-Object -Unique)
        $updateResult = Invoke-UpdateTask `
            -RuntimeDependencyDomains $queuedDependencyHosts `
            -TimeoutSeconds 14
        if ($updateResult.success -ne $true) {
            foreach ($result in $queuedResults) {
                $result.success = $false
                $result.error = $updateResult.error
            }
        }
        foreach ($result in $queuedResults) {
            $result.updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            $result.updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            $result.updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            $result.runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            $result.runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            $result.updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        }
    }

    $failedResults = @($results | Where-Object { $_.success -ne $true })
    return @{
        success = ($failedResults.Count -eq 0)
        action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch
        count = $results.Count
        queuedCount = $queuedResults.Count
        queueWriteMs = [int](@($queuedResults | ForEach-Object { if ($_.ContainsKey('queueWriteMs')) { [int]$_.queueWriteMs } else { 0 } } | Measure-Object -Sum).Sum)
        updateTriggerMs = if ($updateResult -and $updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult -and $updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult -and $updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        updateTaskName = if ($updateResult -and $updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        results = $results
    }
}

function Invoke-NativeHostCaptivePortalRecoveryAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message
    )

    $action = 'recover-captive-portal-navigation'
    $taskName = 'OpenPath-CaptivePortalRecovery'
    $operation = 'open'
    if ($Message.PSObject.Properties['operation'] -and $Message.operation) {
        $candidateOperation = ([string]$Message.operation).Trim().ToLowerInvariant()
        if ($candidateOperation -in @('open', 'reconcile')) {
            $operation = $candidateOperation
        }
    }
    $portalState = if ($Message.PSObject.Properties['portalState'] -and $Message.portalState) { [string]$Message.portalState } else { 'Unknown' }
    $source = if ($Message.PSObject.Properties['source'] -and $Message.source) { [string]$Message.source } else { 'native-host' }
    $triggerHost = ''
    if ($Message.PSObject.Properties['triggerHost'] -and $Message.triggerHost) {
        $triggerHost = Normalize-NativeHostCaptivePortalTriggerHost -Value $Message.triggerHost
    }

    if ($operation -eq 'open' -and -not $triggerHost) {
        return @{
            success = $false
            action = $action
            state = 'InvalidHost'
            portalModeActive = $false
            triggerHost = ''
            requestId = ''
            taskName = $taskName
            triggerMs = 0
            waitMs = 0
            error = 'Invalid captive portal trigger host'
        }
    }

    $recentSuccess = if ($operation -eq 'open') { Get-NativeHostRecentCaptivePortalRecoverySuccess } else { $null }
    if ($recentSuccess -and (Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $recentSuccess -TriggerHost $triggerHost)) {
            return @{
                success = $true
                action = $action
                operation = $operation
                state = 'RecentSuccess'
                portalModeActive = $true
                triggerHost = $triggerHost
                requestId = [string]$recentSuccess.RequestId
                taskName = $taskName
                triggerMs = 0
                waitMs = 0
                recentSuccess = $true
                recentSuccessSource = [string]$recentSuccess.Source
                recentSuccessEligible = if ($recentSuccess.PSObject.Properties['RecentSuccessEligible']) { [bool]$recentSuccess.RecentSuccessEligible } else { $false }
                activeMarkerMode = if ($recentSuccess.PSObject.Properties['ActiveMarkerMode']) { [string]$recentSuccess.ActiveMarkerMode } else { '' }
                allowedHosts = if ($recentSuccess.PSObject.Properties['AllowedHosts']) { @($recentSuccess.AllowedHosts) } else { @() }
                recoveryHostsApplied = if ($recentSuccess.PSObject.Properties['RecoveryHostsApplied']) { [bool]$recentSuccess.RecoveryHostsApplied } else { $false }
            }
    }

    $requestId = (New-Guid).Guid
    $tabId = $null
    if ($Message.PSObject.Properties['tabId']) {
        $tabId = $Message.tabId
    }

    $null = Write-NativeHostCaptivePortalRecoveryRequest `
        -RequestId $requestId `
        -TriggerHost $triggerHost `
        -Operation $operation `
        -PortalState $portalState `
        -Source $source `
        -TabId $tabId

    try {
        $taskResult = Invoke-NativeHostMutex `
            -Name 'Global\OpenPathCaptivePortalRecoveryTrigger' `
            -TimeoutMilliseconds 20000 `
            -Action {
                Invoke-OpenPathScheduledTask `
                    -TaskName $taskName `
                    -Runner (Get-NativeHostTaskRunner) `
                    -TimeoutSeconds 20 `
                    -PollMilliseconds 250 `
                    -WaitCondition {
                        return ($null -ne (Read-NativeHostCaptivePortalRecoveryResult -RequestId $requestId))
                    }
            }
    }
    catch {
        $response = @{
            success = $false
            action = $action
            operation = $operation
            state = 'TriggerFailed'
            portalModeActive = $false
            triggerHost = $triggerHost
            requestId = $requestId
            taskName = $taskName
            triggerMs = 0
            waitMs = 0
            error = [string]$_
        }
        return (Add-NativeHostCaptivePortalRecoveryDiagnostics -Response $response)
    }

    $taskNameResult = if ($taskResult.ContainsKey('taskName') -and $taskResult.taskName) { [string]$taskResult.taskName } else { $taskName }
    $triggerMs = if ($taskResult.ContainsKey('triggerMs')) { [int]$taskResult.triggerMs } else { 0 }
    $waitMs = if ($taskResult.ContainsKey('waitMs')) { [int]$taskResult.waitMs } else { 0 }

    $result = Read-NativeHostCaptivePortalRecoveryResult -RequestId $requestId
    if (-not $result) {
        $response = @{
            success = $false
            action = $action
            operation = $operation
            state = 'Timeout'
            portalModeActive = $false
            triggerHost = $triggerHost
            requestId = $requestId
            taskName = $taskNameResult
            triggerMs = $triggerMs
            waitMs = $waitMs
            error = if ($taskResult.ContainsKey('error') -and $taskResult.error) { [string]$taskResult.error } else { 'Timed out waiting for captive portal recovery result' }
        }
        return (Add-NativeHostCaptivePortalRecoveryDiagnostics -Response $response -TaskResult $taskResult)
    }

    $state = if ($result.PSObject.Properties['state'] -and $result.state) { [string]$result.state } else { 'Unknown' }
    $portalModeActive = if ($result.PSObject.Properties['portalModeActive']) { [bool]$result.portalModeActive } else { $false }
    $success = (($result.PSObject.Properties['success'] -and [bool]$result.success) -or $portalModeActive)
    $operationSucceeded = if ($operation -eq 'reconcile') {
        ($success -and $state -eq 'Authenticated' -and -not $portalModeActive)
    }
    else {
        ($success -and ($state -eq 'Portal' -or $portalModeActive))
    }

    return @{
        success = $operationSucceeded
        action = $action
        operation = $operation
        state = $state
        portalModeActive = $portalModeActive
        triggerHost = $triggerHost
        requestId = $requestId
        taskName = $taskNameResult
        triggerMs = $triggerMs
        waitMs = $waitMs
        portalExitRoute = if ($result.PSObject.Properties['portalExitRoute']) { [string]$result.portalExitRoute } else { '' }
        localDnsLoopbackRestored = if ($result.PSObject.Properties['localDnsLoopbackRestored']) { [bool]$result.localDnsLoopbackRestored } else { $false }
        acrylicNormalRestored = if ($result.PSObject.Properties['acrylicNormalRestored']) { [bool]$result.acrylicNormalRestored } else { $false }
        dnsResolutionHealthy = if ($result.PSObject.Properties['dnsResolutionHealthy']) { [bool]$result.dnsResolutionHealthy } else { $false }
        sinkholeHealthy = if ($result.PSObject.Properties['sinkholeHealthy']) { [bool]$result.sinkholeHealthy } else { $false }
        firewallExpectedActive = if ($result.PSObject.Properties['firewallExpectedActive']) { [bool]$result.firewallExpectedActive } else { $false }
        firewallHealthy = if ($result.PSObject.Properties['firewallHealthy']) { [bool]$result.firewallHealthy } else { $false }
        markerCleared = if ($result.PSObject.Properties['markerCleared']) { [bool]$result.markerCleared } else { $false }
        protectedModeRestored = if ($result.PSObject.Properties['protectedModeRestored']) { [bool]$result.protectedModeRestored } else { $false }
        activeMarkerMode = if ($result.PSObject.Properties['activeMarkerMode']) { [string]$result.activeMarkerMode } else { '' }
        allowedHosts = if ($result.PSObject.Properties['allowedHosts']) { @($result.allowedHosts) } else { @() }
        recoveryHostsApplied = if ($result.PSObject.Properties['recoveryHostsApplied']) { [bool]$result.recoveryHostsApplied } else { $false }
        recentSuccessEligible = if ($result.PSObject.Properties['recentSuccessEligible']) { [bool]$result.recentSuccessEligible } else { $false }
    }
}

function Test-NativeWhitelistContainsDomains {
    param(
        [string[]]$Domains = @()
    )

    if (@($Domains).Count -eq 0) {
        return $true
    }

    $sections = Get-WhitelistSections
    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($sections.Whitelist)) {
        if ($domain) {
            $null = $whitelistSet.Add([string]$domain)
        }
    }

    foreach ($domain in @($Domains)) {
        if (-not $whitelistSet.Contains($domain)) {
            return $false
        }
    }

    return $true
}

function Format-NativeHostActionLogValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = ([string]$Value).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
    $text = ConvertTo-OpenPathRedactedValue -Value $text
    $text = $text -replace '\s+', ' '
    if ($text.Length -gt 240) {
        return $text.Substring(0, 240)
    }

    return $text
}

function Write-NativeHostActionLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string[]]$Domains = @(),
        [bool]$Success = $false,
        [AllowNull()]
        [string]$Message = '',
        [AllowNull()]
        [string]$ErrorMessage = '',
        [long]$ElapsedMs = 0,
        [hashtable]$ExtraFields = @{}
    )

    try {
        if (-not (Get-Command Write-NativeHostLog -ErrorAction SilentlyContinue)) {
            return
        }

        $safeDomains = @(Get-NativeHostValidDomains -Domains $Domains)
        $fields = @(
            "action=$Action",
            "success=$($Success -eq $true)",
            "elapsedMs=$ElapsedMs",
            "domains=$($safeDomains -join ',')"
        )
        if ($Message) {
            $fields += "message=$(Format-NativeHostActionLogValue -Value $Message)"
        }
        if ($ErrorMessage) {
            $fields += "error=$(Format-NativeHostActionLogValue -Value $ErrorMessage)"
        }
        foreach ($key in @($ExtraFields.Keys | Sort-Object)) {
            if ($key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { continue }
            $value = $ExtraFields[$key]
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
            $fields += "$key=$(Format-NativeHostActionLogValue -Value $value)"
        }

        Write-NativeHostLog ("Native host {0}" -f ($fields -join ' '))
    }
    catch {
        return
    }
}

function Invoke-NativeHostSharedUpdateTrigger {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$TriggerAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$WaitAction
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\OpenPathNativeWhitelistUpdateTrigger')
        try {
            $lockAcquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if ($lockAcquired) {
            $triggerResult = & $TriggerAction
            if (
                $triggerResult -is [System.Collections.IDictionary] -and
                $triggerResult.ContainsKey('success')
            ) {
                return $triggerResult
            }
        }

        return (& $WaitAction)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # Ignore if mutex ownership was already released by the runtime.
            }
        }

        if ($mutex) {
            $mutex.Dispose()
        }
    }
}

function Invoke-UpdateTask {
    param(
        [string[]]$Domains = @(),
        [string[]]$RuntimeDependencyDomains = @(),
        [AllowNull()][string]$RuntimeDependencyRequestPath = '',
        [int]$TimeoutSeconds = 45
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $hasRuntimeDependencyWait = @($RuntimeDependencyDomains).Count -gt 0
        if ((-not $hasRuntimeDependencyWait) -and (Test-NativeWhitelistContainsDomains -Domains $Domains)) {
            $result = @{
                success = $true
                action = 'update-whitelist'
                message = 'OpenPath update task triggered'
                domains = @($Domains)
            }
        }
        else {
            $triggeredTaskName = if (
                $hasRuntimeDependencyWait -and
                (Get-Variable -Name RuntimeDependencyTaskName -Scope Script -ErrorAction SilentlyContinue) -and
                -not [string]::IsNullOrWhiteSpace($script:RuntimeDependencyTaskName)
            ) {
                [string]$script:RuntimeDependencyTaskName
            }
            else {
                [string]$script:UpdateTaskName
            }
            $triggerState = @{
                TaskName = $triggeredTaskName
                Fallback = $false
                TriggerMs = 0
            }
            $result = Invoke-NativeHostSharedUpdateTrigger `
                -TriggerAction {
                    $taskResult = Invoke-OpenPathScheduledTask `
                        -TaskName $triggerState['TaskName'] `
                        -FallbackTaskName $script:UpdateTaskName `
                        -ShouldFallback $hasRuntimeDependencyWait `
                        -Runner (Get-NativeHostTaskRunner) `
                        -TimeoutSeconds $TimeoutSeconds `
                        -WaitCondition {
                            $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                            $runtimeDependencyReady = (
                                (Test-NativeHostRuntimeDependencyQueueRequestProcessed -RequestPath $RuntimeDependencyRequestPath) -and
                                (
                                    -not [string]::IsNullOrWhiteSpace($RuntimeDependencyRequestPath) -or
                                    (Test-NativeHostRuntimeDependencyOverlayContainsDomains -Domains $RuntimeDependencyDomains)
                                )
                            )
                            return ($whitelistReady -and $runtimeDependencyReady)
                        }
                    $triggerState['Fallback'] = [bool]$taskResult.fallback
                    $triggerState['TaskName'] = [string]$taskResult.taskName
                    $triggerState['TriggerMs'] = [int]$taskResult.triggerMs

                    if ($taskResult.success -ne $true) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = if ($taskResult.ContainsKey('timedOut') -and $taskResult.timedOut) { "OpenPath update task did not write expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')" } elseif ($taskResult.ContainsKey('error')) { [string]$taskResult.error } else { 'Scheduled task update failed' }
                            domains = @($Domains)
                            runtimeDependencyFastPath = $hasRuntimeDependencyWait
                            runtimeDependencyFallback = [bool]$taskResult.fallback
                            updateTaskName = [string]$taskResult.taskName
                            updateTriggerMs = [int]$taskResult.triggerMs
                            updateWaitMs = [int]$taskResult.waitMs
                        }
                    }

                    $taskRunnerResult = @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task wrote expected domains'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$taskResult.fallback
                        updateTaskName = [string]$taskResult.taskName
                        updateTriggerMs = [int]$taskResult.triggerMs
                        updateWaitMs = [int]$taskResult.waitMs
                    }
                    return $taskRunnerResult
                } `
                -WaitAction {
                    $waitRunner = Get-NativeHostTaskRunner
                    $waitResult = & $waitRunner.WaitFor $triggerState['TaskName'] {
                        $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                        $runtimeDependencyReady = (
                            (Test-NativeHostRuntimeDependencyQueueRequestProcessed -RequestPath $RuntimeDependencyRequestPath) -and
                            (
                                -not [string]::IsNullOrWhiteSpace($RuntimeDependencyRequestPath) -or
                                (Test-NativeHostRuntimeDependencyOverlayContainsDomains -Domains $RuntimeDependencyDomains)
                            )
                        )
                        return ($whitelistReady -and $runtimeDependencyReady)
                    } $TimeoutSeconds 1000

                    if ($waitResult.success -ne $true) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = "OpenPath update task did not write expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')"
                            domains = @($Domains)
                            runtimeDependencyFastPath = $hasRuntimeDependencyWait
                            runtimeDependencyFallback = [bool]$triggerState['Fallback']
                            updateTaskName = [string]$triggerState['TaskName']
                            updateTriggerMs = [int]$triggerState['TriggerMs']
                            updateWaitMs = if ($waitResult.ContainsKey('elapsedMs')) { [int]$waitResult.elapsedMs } else { 0 }
                        }
                    }

                    return @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task wrote expected domains'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$triggerState['Fallback']
                        updateTaskName = [string]$triggerState['TaskName']
                        updateTriggerMs = [int]$triggerState['TriggerMs']
                        updateWaitMs = if ($waitResult.ContainsKey('elapsedMs')) { [int]$waitResult.elapsedMs } else { 0 }
                    }
                }
        }
    }
    catch {
        $result = @{
            success = $false
            action = 'update-whitelist'
            error = [string]$_
            domains = @($Domains)
        }
    }

    $stopwatch.Stop()
    $logMessage = ''
    if ($result.ContainsKey('message')) {
        $logMessage = [string]$result.message
    }
    $logError = ''
    if ($result.ContainsKey('error')) {
        $logError = [string]$result.error
    }

    Write-NativeHostActionLog -Action 'update-whitelist' `
        -Domains $Domains `
        -Success ($result.success -eq $true) `
        -Message $logMessage `
        -ErrorMessage $logError `
        -ElapsedMs $stopwatch.ElapsedMilliseconds

    $result['elapsedMs'] = [int]$stopwatch.ElapsedMilliseconds
    return $result
}

function Get-NativeHostMachineName {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    if ($State.PSObject.Properties['machineName'] -and $State.machineName) {
        return [string]$State.machineName
    }

    return [string]$env:COMPUTERNAME
}

function Get-NativeHostApiUrl {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    $requestSetupState = Get-OpenPathRequestSetupState -Config $State
    return [string]$requestSetupState.RequestApiUrl
}

function Get-NativeHostMachineToken {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    $requestSetupState = Get-OpenPathRequestSetupState -Config $State
    return [string]$requestSetupState.MachineToken
}

function Get-NativeHostBlockedPathResponse {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $paths = @($Sections.BlockedPaths)
    $digest = ''
    if ($paths.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($paths -join "`n"))
            $digest = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }

    $mtime = 0
    if (Test-Path $script:WhitelistPath) {
        $whitelistItem = Get-Item $script:WhitelistPath
        $mtime = [int]([DateTimeOffset]$whitelistItem.LastWriteTimeUtc).ToUnixTimeSeconds()
    }

    return @{
        success = $true
        action = 'get-blocked-paths'
        paths = $paths
        count = $paths.Count
        hash = $digest
        mtime = $mtime
        source = $script:WhitelistPath
    }
}

function Get-NativeHostBlockedSubdomainResponse {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $subdomains = @($Sections.BlockedSubdomains)
    $digest = ''
    if ($subdomains.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($subdomains -join "`n"))
            $digest = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }

    $mtime = 0
    if (Test-Path $script:WhitelistPath) {
        $whitelistItem = Get-Item $script:WhitelistPath
        $mtime = [int]([DateTimeOffset]$whitelistItem.LastWriteTimeUtc).ToUnixTimeSeconds()
    }

    return @{
        success = $true
        action = 'get-blocked-subdomains'
        subdomains = $subdomains
        count = $subdomains.Count
        hash = $digest
        mtime = $mtime
        source = $script:WhitelistPath
    }
}

function Get-NativeHostCaptivePortalObservation {
    $observationPath = 'C:\OpenPath\data\captive-portal-observation.json'
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $observationPath = Join-Path (Join-Path $script:OpenPathRoot 'data') 'captive-portal-observation.json'
    }

    if (-not (Test-Path $observationPath -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        return (Get-Content -Path $observationPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Test-NativeHostCaptivePortalObservationRecent {
    param(
        [object]$Observation,
        [int]$MaxAgeSeconds = 120
    )

    if (-not $Observation -or -not $Observation.PSObject.Properties['detectedState'] -or [string]$Observation.detectedState -ne 'Portal') {
        return $false
    }

    $timestamp = $null
    foreach ($propertyName in @('updatedAt', 'observedAt', 'detectedAt')) {
        $property = $Observation.PSObject.Properties[$propertyName]
        if ($property -and $property.Value) {
            try {
                $timestamp = [DateTime]::Parse([string]$property.Value).ToUniversalTime()
                break
            }
            catch {
                $timestamp = $null
            }
        }
    }

    if (-not $timestamp) {
        return $false
    }

    return (([DateTime]::UtcNow - $timestamp).TotalSeconds -le [Math]::Max(1, $MaxAgeSeconds))
}

function Test-NativeHostRecoverablePortalError {
    param([string]$ErrorName)

    return $ErrorName -in @(
        'NS_ERROR_UNKNOWN_HOST',
        'NS_ERROR_CONNECTION_REFUSED',
        'NS_ERROR_NET_TIMEOUT'
    )
}

function Invoke-NativeHostCaptivePortalSyncProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [int]$CooldownSeconds = 15
    )

    $cacheKey = $Domain.Trim().ToLowerInvariant()
    $now = [DateTime]::UtcNow
    if ($script:NativeHostPortalProbeCache.ContainsKey($cacheKey)) {
        $cached = $script:NativeHostPortalProbeCache[$cacheKey]
        if ($cached -and $cached.PSObject.Properties['ProbedAt'] -and (($now - $cached.ProbedAt).TotalSeconds -lt [Math]::Max(1, $CooldownSeconds))) {
            return [string]$cached.Signal
        }
    }

    $signal = 'none'
    try {
        if ((Test-OpenPathCaptivePortalState -TimeoutSec 2) -eq 'Portal') {
            $signal = 'sync-probe'
        }
    }
    catch {
        $signal = 'none'
    }

    $script:NativeHostPortalProbeCache[$cacheKey] = [PSCustomObject]@{
        ProbedAt = $now
        Signal = $signal
    }
    return $signal
}

function Get-NativeHostPortalRecoverySignal {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][object]$Message
    )

    $marker = Get-NativeHostCaptivePortalActiveMarker
    if ($marker) {
        return 'marker'
    }

    $observation = Get-NativeHostCaptivePortalObservation
    if (Test-NativeHostCaptivePortalObservationRecent -Observation $observation) {
        return 'observation'
    }

    if ($Message.PSObject.Properties['portalState'] -and [string]$Message.portalState -eq 'locked_portal') {
        return 'firefox-locked'
    }

    $errorName = if ($Message.PSObject.Properties['error']) { [string]$Message.error } else { '' }
    $source = if ($Message.PSObject.Properties['source']) { [string]$Message.source } else { '' }
    if (
        $source -eq 'blocked-screen-navigation' -and
        (Test-NativeHostRecoverablePortalError -ErrorName $errorName) -and
        (Get-Command -Name 'Test-OpenPathCaptivePortalState' -ErrorAction SilentlyContinue)
    ) {
        return (Invoke-NativeHostCaptivePortalSyncProbe -Domain $Domain)
    }

    return 'none'
}

function Invoke-NativeHostCheckAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $validDomains = Get-NativeHostValidDomains -Domains @($Message.domains)

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($Sections.Whitelist)) {
        if ($domain) {
            $null = $whitelistSet.Add([string]$domain)
        }
    }

    $results = foreach ($domain in $validDomains) {
        $portalRecoverySignal = Get-NativeHostPortalRecoverySignal -Domain $domain -Message $Message
        @{
            domain = $domain
            in_whitelist = $whitelistSet.Contains($domain)
            resolved_ip = (Resolve-DomainIp -Domain $domain)
            portal_recovery_eligible = ((-not $whitelistSet.Contains($domain)) -and $portalRecoverySignal -ne 'none')
            portal_recovery_signal = $portalRecoverySignal
        }
    }

    return @{
        success = $true
        action = 'check'
        results = @($results)
    }
}

function Invoke-NativeHostMessageAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [object]$Sections,

        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    switch ($Action) {
        'ping' {
            return @{
                success = $true
                action = 'ping'
                message = 'pong'
                version = if ($State.PSObject.Properties['version']) { [string]$State.version } else { '' }
            }
        }

        'get-hostname' {
            return @{
                success = $true
                action = 'get-hostname'
                hostname = (Get-NativeHostMachineName -State $State)
            }
        }

        'get-machine-token' {
            $token = Get-NativeHostMachineToken -State $State
            if (-not $token) {
                return @{
                    success = $false
                    action = 'get-machine-token'
                    error = 'Machine token not available'
                }
            }

            return @{
                success = $true
                action = 'get-machine-token'
                token = $token
            }
        }

        'get-config' {
            $requestSetupState = Get-OpenPathRequestSetupState -Config $State
            $apiUrl = [string]$requestSetupState.RequestApiUrl

            if (-not $apiUrl) {
                return @{
                    success = $false
                    action = 'get-config'
                    error = 'API URL is not configured'
                }
            }

            return @{
                success = $true
                action = 'get-config'
                apiUrl = $apiUrl
                requestApiUrl = $apiUrl
                fallbackApiUrls = @()
                hostname = (Get-NativeHostMachineName -State $State)
                machineToken = [string]$requestSetupState.MachineToken
                whitelistUrl = [string]$requestSetupState.WhitelistUrl
            }
        }

        'get-blocked-paths' {
            return (Get-NativeHostBlockedPathResponse -Sections $sections)
        }

        'get-blocked-subdomains' {
            return (Get-NativeHostBlockedSubdomainResponse -Sections $sections)
        }

        'check' {
            return (Invoke-NativeHostCheckAction -Message $Message -Sections $sections)
        }

        'update-whitelist' {
            $domains = Get-NativeHostValidDomains -Domains @($Message.domains)
            return (Invoke-UpdateTask -Domains $domains)
        }

        $script:OpenPathRuntimeDependencyActionAllowLocal {
            return (Invoke-NativeHostLocalRuntimeDependencyAction -Message $Message -State $State -Sections $sections)
        }

        $script:OpenPathRuntimeDependencyActionAllowLocalBatch {
            return (Invoke-NativeHostLocalRuntimeDependencyBatchAction -Message $Message -State $State -Sections $sections)
        }

        'recover-captive-portal-navigation' {
            return (Invoke-NativeHostCaptivePortalRecoveryAction -Message $Message)
        }

        default {
            return @{
                success = $false
                error = "Unknown action: $action"
            }
        }
    }
}

function Handle-Message {
    param(
        [AllowNull()]
        [object]$Message
    )

    if (-not ($Message -is [System.Collections.IDictionary]) -and -not $Message.PSObject) {
        return @{ success = $false; error = 'Invalid message format' }
    }

    $state = Read-NativeState
    $sections = Get-WhitelistSections
    $action = [string]$Message.action
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null

    try {
        $result = Invoke-NativeHostMessageAction -Message $Message -State $state -Sections $sections -Action $action
    }
    catch {
        $result = @{
            success = $false
            action = $action
            error = [string]$_
        }
    }
    finally {
        $stopwatch.Stop()
    }

    if ($action -ne 'update-whitelist') {
        $logMessage = ''
        if ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('message')) {
            $logMessage = [string]$result.message
        }
        $logError = ''
        if ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('error')) {
            $logError = [string]$result.error
        }
        $domains = @()
        if ($action -eq 'check') {
            $domains = @(Get-NativeHostValidDomains -Domains @($Message.domains))
        }
        elseif ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('dependencyHost')) {
            $domains = @(Get-NativeHostValidDomains -Domains @($result.dependencyHost))
        }
        elseif ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('results')) {
            $domains = @(Get-NativeHostValidDomains -Domains @($result.results | ForEach-Object { $_.dependencyHost }))
        }

        $extraFields = @{}
        if ($result -is [System.Collections.IDictionary]) {
            foreach ($key in @(
                    'queueWriteMs',
                    'updateTriggerMs',
                    'updateWaitMs',
                    'updateElapsedMs',
                    'runtimeDependencyFastPath',
                    'runtimeDependencyFallback',
                    'updateTaskName'
                )) {
                if ($result.ContainsKey($key)) {
                    $extraFields[$key] = $result[$key]
                }
            }
        }

        Write-NativeHostActionLog -Action $action `
            -Domains $domains `
            -Success ($result.success -eq $true) `
            -Message $logMessage `
            -ErrorMessage $logError `
            -ElapsedMs $stopwatch.ElapsedMilliseconds `
            -ExtraFields $extraFields
    }

    return $result
}
