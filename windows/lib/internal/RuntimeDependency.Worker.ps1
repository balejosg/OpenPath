# OpenPath runtime dependency resident worker
#
# The worker removes the per-batch cold start from the runtime dependency path:
# instead of triggering OpenPath-RuntimeDependencyApply through schtasks.exe and
# paying a fresh PowerShell process plus module import for every learned batch,
# a single SYSTEM process watches the queue directory and applies learned
# dependencies in-process through Invoke-OpenPathRuntimeDependencyFastApply.
#
# The native host consults the heartbeat written here to decide whether a
# scheduled-task fallback trigger is still required.

if (-not (Get-Command -Name 'Get-OpenPathCapabilityStoragePath' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $capabilityStoragePath = Join-Path $PSScriptRoot 'CapabilityStorage.ps1'
    if (Test-Path $capabilityStoragePath -ErrorAction SilentlyContinue) {
        . $capabilityStoragePath
    }
}

function Get-OpenPathRuntimeDependencyWorkerStatePath {
    <#
    .SYNOPSIS
    Returns the capability storage path for the runtime dependency worker heartbeat file.
    #>
    [CmdletBinding()]
    param()

    return (Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyWorkerState)
}

function Write-OpenPathRuntimeDependencyWorkerState {
    <#
    .SYNOPSIS
    Persists the worker heartbeat/state file atomically, keeping it readable by the browser user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [string]$StatePath = '',
        [switch]$SkipReadAccess
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-OpenPathRuntimeDependencyWorkerStatePath
    }

    $directory = Split-Path $StatePath -Parent
    if ($directory -and -not [System.IO.Directory]::Exists($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $payload = @{}
    foreach ($key in $State.Keys) { $payload[$key] = $State[$key] }
    $payload['heartbeatAt'] = (Get-Date).ToUniversalTime().ToString('o')
    $payload['heartbeatEpochMs'] = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $tempPath = "$StatePath.tmp"
    try {
        $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $tempPath -Encoding UTF8 -Force
        [System.IO.File]::Copy($tempPath, $StatePath, $true)
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        if (-not $SkipReadAccess -and (Get-Command -Name 'Set-OpenPathRuntimeDependencyReadAccess' -ErrorAction SilentlyContinue)) {
            Set-OpenPathRuntimeDependencyReadAccess -Path $StatePath | Out-Null
        }
        return $true
    }
    catch {
        if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
            Write-OpenPathLog "Failed to write runtime dependency worker state: $_" -Level WARN
        }
        return $false
    }
}

function Set-OpenPathRuntimeDependencyWorkerBusyState {
    <#
    .SYNOPSIS
    Marks the worker busy for a pipeline stage with a read-modify-write of the state file.
    .DESCRIPTION
    Called by the worker before starting a batch and by the fast apply around its own stages
    (queue iteration, Acrylic reload, DNS flush, generation stamp). A long batch keeps
    `busySince` fresh so the native host never falls back to the scheduled task while the
    worker is demonstrably applying, even when the idle heartbeat age exceeds its window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path $StatePath -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $parsed = Get-Content -Path $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $state = @{}
        foreach ($property in $parsed.PSObject.Properties) { $state[$property.Name] = $property.Value }

        $now = (Get-Date).ToUniversalTime()
        if (-not $state['busySince']) {
            $state['busySince'] = $now.ToString('o')
            $state['busySinceEpochMs'] = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }
        $state['busyStage'] = $Stage
        return (Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $StatePath)
    }
    catch {
        return $false
    }
}

function Test-OpenPathRuntimeDependencyWorkerFresh {
    <#
    .SYNOPSIS
    Returns true when the resident worker heartbeat (or a recent busy mark) is recent enough to be considered alive.
    .DESCRIPTION
    Used by the Firefox native host to skip the schtasks fallback trigger when the
    resident worker is demonstrably running. A worker applying a long batch refreshes
    `busySince`; that counts as alive for a wider window than the idle heartbeat.
    Timestamps slightly in the future are tolerated up to 30 seconds to absorb clock
    adjustment noise.
    #>
    [CmdletBinding()]
    param(
        [string]$StatePath = '',
        [int]$MaxAgeSeconds = 10,
        [int]$BusyMaxAgeSeconds = 120,
        [AllowNull()][object]$Now = $null
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-OpenPathRuntimeDependencyWorkerStatePath
    }
    if (-not (Test-Path $StatePath -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $raw = Get-Content -Path $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop

        $reference = if ($null -ne $Now) { [DateTimeOffset]$Now } else { [DateTimeOffset]::UtcNow }
        $referenceMs = $reference.ToUnixTimeMilliseconds()

        $heartbeatMs = $null
        if ($parsed.PSObject.Properties['heartbeatEpochMs'] -and $parsed.heartbeatEpochMs) {
            $heartbeatMs = [long]$parsed.heartbeatEpochMs
        }
        elseif ($parsed.PSObject.Properties['heartbeatAt'] -and $parsed.heartbeatAt) {
            # ps-culture-allow: InvariantCulture and RoundtripKind are passed explicitly on the following lines.
            $heartbeatMs = [long][DateTimeOffset]::Parse(
                [string]$parsed.heartbeatAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ).ToUnixTimeMilliseconds()
        }
        if ($null -ne $heartbeatMs) {
            $ageMs = $referenceMs - $heartbeatMs
            if ($ageMs -ge -30000 -and $ageMs -le ([Math]::Max(1, $MaxAgeSeconds) * 1000)) {
                return $true
            }
        }

        $busySinceMs = $null
        if ($parsed.PSObject.Properties['busySinceEpochMs'] -and $parsed.busySinceEpochMs) {
            $busySinceMs = [long]$parsed.busySinceEpochMs
        }
        elseif ($parsed.PSObject.Properties['busySince'] -and $parsed.busySince) {
            # ps-culture-allow: InvariantCulture and RoundtripKind are passed explicitly on the following lines.
            $busySinceMs = [long][DateTimeOffset]::Parse(
                [string]$parsed.busySince,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ).ToUnixTimeMilliseconds()
        }
        if ($null -ne $busySinceMs) {
            $busyAgeMs = $referenceMs - $busySinceMs
            return ($busyAgeMs -ge -30000 -and $busyAgeMs -le ([Math]::Max(1, $BusyMaxAgeSeconds) * 1000))
        }

        return $false
    }
    catch {
        return $false
    }
}

function Invoke-OpenPathRuntimeDependencyWorkerApply {
    <#
    .SYNOPSIS
    Runs the fast-apply action for the queue, retrying while the update mutex is busy instead of dropping the batch.
    .DESCRIPTION
    Invoke-OpenPathRuntimeDependencyFastApply returns LockBusy=$true when another update
    holds the global mutex. The worker must never discard learned dependencies, so it keeps
    retrying while queue files remain instead of waiting for another trigger.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ApplyAction,
        [string]$QueuePath = '',
        [int]$RetryDelayMs = 500,
        [scriptblock]$OnWait = $null,
        [int]$LogIntervalSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($QueuePath)) {
        $QueuePath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLogMs = 0
    $retries = 0
    while ($true) {
        $result = & $ApplyAction
        $lockBusy = ($result -is [System.Collections.IDictionary] -and $result.Contains('LockBusy') -and [bool]$result['LockBusy'])
        if (-not $lockBusy) {
            if ($result -is [System.Collections.IDictionary]) { $result['WorkerRetries'] = $retries }
            return $result
        }

        $pending = 0
        if ([System.IO.Directory]::Exists($QueuePath)) {
            $pending = @([System.IO.Directory]::GetFiles($QueuePath, '*.json')).Count
        }
        if ($pending -le 0) {
            # The mutex holder may have drained the queue already; report the busy outcome.
            if ($result -is [System.Collections.IDictionary]) { $result['WorkerRetries'] = $retries }
            return $result
        }

        $retries += 1
        if (($stopwatch.Elapsed.TotalSeconds - $lastLogMs) -ge $LogIntervalSeconds) {
            $lastLogMs = [int]$stopwatch.Elapsed.TotalSeconds
            if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
                Write-OpenPathLog "Runtime dependency worker waiting for the update lock (retries=$retries pending=$pending)"
            }
        }
        if ($OnWait) { & $OnWait }
        Start-Sleep -Milliseconds ([Math]::Max(50, $RetryDelayMs))
    }
}

function Start-OpenPathRuntimeDependencyWorker {
    <#
    .SYNOPSIS
    Runs the resident runtime dependency worker loop: watches the queue, applies in-process, and heartbeats.
    .DESCRIPTION
    Uses a FileSystemWatcher for immediate wake-ups plus a periodic backup sweep so no
    queue file can be missed. Modules are imported once by the caller; every batch is
    applied through the supplied ApplyAction without re-importing. The heartbeat file is
    refreshed at least every HeartbeatSeconds while idle so the native host can avoid
    triggering the scheduled fallback task.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = '',
        [string]$QueuePath = '',
        [string]$StatePath = '',
        [scriptblock]$ApplyAction = $null,
        [int]$WatcherTimeoutMs = 1000,
        [int]$DebounceMs = 100,
        [int]$RetryDelayMs = 500,
        [int]$HeartbeatSeconds = 5,
        [switch]$Once,
        [int]$MaxCycles = 0
    )

    if ([string]::IsNullOrWhiteSpace($QueuePath)) {
        $QueuePath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue -OpenPathRoot $OpenPathRoot
    }
    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-OpenPathRuntimeDependencyWorkerStatePath
    }
    if (-not $ApplyAction) {
        $ApplyAction = {
            Invoke-OpenPathRuntimeDependencyFastApply -OpenPathRoot $OpenPathRoot -WorkerStatePath $StatePath -PassThru
        }
    }

    if (-not [System.IO.Directory]::Exists($QueuePath)) {
        [System.IO.Directory]::CreateDirectory($QueuePath) | Out-Null
    }

    $state = @{
        pid = $PID
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        cycles = 0
        applied = 0
        queueFiles = 0
        lastResult = 'starting'
        lastError = ''
    }
    Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $StatePath | Out-Null
    if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
        Write-OpenPathLog "Runtime dependency worker started (pid=$PID queue=$QueuePath)"
    }

    $watcher = $null
    try {
        try {
            $watcher = New-Object System.IO.FileSystemWatcher
            $watcher.Path = $QueuePath
            $watcher.Filter = '*.json'
            $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
            $watcher.EnableRaisingEvents = $true
        }
        catch {
            $watcher = $null
            if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
                Write-OpenPathLog "Runtime dependency worker file watcher unavailable; using periodic sweep only: $_" -Level WARN
            }
        }

        $lastHeartbeat = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $cycles = [int]$state['cycles'] + 1
            $state['cycles'] = $cycles

            $queueFiles = @()
            if ([System.IO.Directory]::Exists($QueuePath)) {
                $queueFiles = @([System.IO.Directory]::GetFiles($QueuePath, '*.json'))
            }
            $state['queueFiles'] = $queueFiles.Count

            if ($queueFiles.Count -gt 0) {
                # Debounce: a page fan-out lands its queue files within milliseconds of
                # each other; waiting a short beat collapses the burst into one overlay
                # write and one Acrylic reload.
                if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
                    Write-OpenPathLog "Runtime dependency worker detected $($queueFiles.Count) queue file(s)"
                }
                [System.Threading.Thread]::Sleep([Math]::Max(0, $DebounceMs))
                $applyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    # Mark the worker busy for the whole batch and refresh the heartbeat so
                    # the native host does not fall back to the scheduled task while the
                    # worker is busy applying; a recent busy mark counts as alive.
                    $state['lastResult'] = 'applying'
                    $state['busySince'] = (Get-Date).ToUniversalTime().ToString('o')
                    $state['busySinceEpochMs'] = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $state['busyStage'] = 'queue'
                    Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $StatePath | Out-Null
                    $applyResult = Invoke-OpenPathRuntimeDependencyWorkerApply `
                        -ApplyAction $ApplyAction `
                        -QueuePath $QueuePath `
                        -RetryDelayMs $RetryDelayMs `
                        -OnWait { Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $StatePath | Out-Null }
                    $applyStopwatch.Stop()

                    $exitCode = 0
                    if ($applyResult -is [System.Collections.IDictionary] -and $applyResult.Contains('ExitCode')) {
                        $exitCode = [int]$applyResult['ExitCode']
                    }
                    $state['applied'] = [int]$state['applied'] + 1
                    $state['lastApplyMs'] = [int]$applyStopwatch.ElapsedMilliseconds
                    $state['lastResult'] = if ($exitCode -eq 0) { 'applied' } else { 'apply-failed' }
                    $state['lastError'] = ''
                    if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
                        Write-OpenPathLog ("Runtime dependency worker applied queue batch: cycles={0} ms={1} exitCode={2}" -f $cycles, $applyStopwatch.ElapsedMilliseconds, $exitCode)
                    }
                }
                catch {
                    $applyStopwatch.Stop()
                    $state['lastResult'] = 'error'
                    $state['lastError'] = [string]$_
                    if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
                        Write-OpenPathLog "Runtime dependency worker apply failed: $_" -Level ERROR
                    }
                }
                $state['busySince'] = ''
                $state['busySinceEpochMs'] = 0
                $state['busyStage'] = ''
                Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $StatePath | Out-Null
            }
            elseif ($lastHeartbeat.Elapsed.TotalSeconds -ge [Math]::Max(1, $HeartbeatSeconds)) {
                $lastHeartbeat.Restart()
                Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $StatePath | Out-Null
            }

            if ($Once -or ($MaxCycles -gt 0 -and $cycles -ge $MaxCycles)) {
                return 0
            }

            if ($watcher) {
                try {
                    $null = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, [Math]::Max(200, $WatcherTimeoutMs))
                }
                catch {
                    # Watcher errors (directory replaced, buffer overflow) must not kill the
                    # worker: fall back to a plain sleep for the sweep interval.
                    Start-Sleep -Milliseconds ([Math]::Max(200, $WatcherTimeoutMs))
                }
            }
            else {
                Start-Sleep -Milliseconds ([Math]::Max(200, $WatcherTimeoutMs))
            }
        }
    }
    finally {
        if ($watcher) {
            try { $watcher.Dispose() } catch { }
        }
        if (-not $Once) {
            $state['lastResult'] = 'stopped'
            Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $StatePath | Out-Null
        }
    }
}
