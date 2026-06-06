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
        [string[]]$PortalRecoveryHosts = @(),
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
        portalRecoveryHosts = @($PortalRecoveryHosts)
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

function Read-NativeHostCaptivePortalRecoveryResultEnvelope {
    param(
        [Parameter(Mandatory = $true)][string]$RequestId
    )

    $resultRoot = Get-NativeHostCaptivePortalRecoveryResultPath
    $resultPath = Join-Path $resultRoot "$RequestId.json"
    if (-not (Test-Path $resultPath -ErrorAction SilentlyContinue)) {
        $staleResult = $false
        if (Test-Path $resultRoot -ErrorAction SilentlyContinue) {
            $staleResult = ($null -ne (Get-ChildItem -Path $resultRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1))
        }
        return [PSCustomObject]@{
            Result = $null
            Classification = if ($staleResult) { 'stale-result' } else { 'missing-result' }
            Path = $resultPath
        }
    }

    try {
        $result = Get-Content -Path $resultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $result.PSObject.Properties['requestId']) {
            return [PSCustomObject]@{ Result = $null; Classification = 'stale-result'; Path = $resultPath }
        }
        if (-not ([string]$result.requestId).Equals($RequestId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{ Result = $null; Classification = 'stale-result'; Path = $resultPath }
        }

        return [PSCustomObject]@{
            Result = $result
            Classification = 'success'
            Path = $resultPath
        }
    }
    catch {
        return [PSCustomObject]@{ Result = $null; Classification = 'stale-result'; Path = $resultPath }
    }
}

function Read-NativeHostCaptivePortalRecoveryResult {
    param(
        [Parameter(Mandatory = $true)][string]$RequestId
    )

    $envelope = Read-NativeHostCaptivePortalRecoveryResultEnvelope -RequestId $RequestId
    return $envelope.Result
}

function Get-NativeHostCaptivePortalRecoveryQueueClassification {
    param(
        [string]$ReadClassification = 'missing-result',
        [AllowNull()][hashtable]$TaskResult = $null,
        [AllowNull()][object]$Result = $null,
        [string]$Operation = 'open',
        [bool]$OperationSucceeded = $false
    )

    if ($Result) {
        $state = if ($Result.PSObject.Properties['state'] -and $Result.state) { [string]$Result.state } else { '' }
        $portalExitRoute = if ($Result.PSObject.Properties['portalExitRoute'] -and $Result.portalExitRoute) { [string]$Result.portalExitRoute } else { '' }
        if ($state -eq 'Authenticated' -and -not $OperationSucceeded -and ($portalExitRoute -match 'authenticated-restore-failed' -or $Operation -eq 'reconcile')) {
            return 'authenticated-restore-failed'
        }
        return 'success'
    }

    if ($TaskResult) {
        $taskState = if ($TaskResult.ContainsKey('taskState')) { [string]$TaskResult.taskState } else { '' }
        $taskError = if ($TaskResult.ContainsKey('error')) { [string]$TaskResult.error } else { '' }
        if ($taskState -match '(?i)disabled' -or $taskError -match '(?i)disabled') {
            return 'task-disabled'
        }
        if (($TaskResult.ContainsKey('timedOut') -and [bool]$TaskResult.timedOut) -or $taskError -match '(?i)timed out|timeout') {
            return 'task-timeout'
        }
    }

    if ($ReadClassification -eq 'stale-result') {
        return 'stale-result'
    }

    return 'missing-result'
}
