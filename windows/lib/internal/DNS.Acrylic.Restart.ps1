# Phase 8f F1-F4: the single Acrylic restart entry point.
#
# Every caller of Restart-AcrylicService (Update reconcile/fast apply, watchdog,
# captive portal, rollback, self-update, checkpoint restore and the CLI) goes
# through these helpers:
#
#   - F1: every restart and every skip is logged with reason, caller, pid and
#     duration (`Acrylic restart reason=<...> caller=<...> pid=<...> ms=<...>`,
#     `Acrylic restart skipped reason=<...> caller=<...> pid=<...>`).
#   - F2: a restart happens only when the effective AcrylicHosts.txt content
#     plus the INI differ from the state the running service last loaded
#     (`data/acrylic-loaded-state.json`), when the service is not Running or
#     does not answer the local control query, or when the loaded state is
#     unknown (fail-safe: restart).
#   - F3: all restarts serialize on `Global\OpenPathAcrylicRestartLock`; the
#     wait is bounded and a waiter re-evaluates F2 after acquiring the lock, so
#     a second process coalesces instead of restarting twice.
#   - F4: `Invoke-OpenPathAcrylicRestartLockScope` lets the runtime dependency
#     fast apply hold the restart lock across its restart, DNS flush and
#     appliedGeneration stamp, so no other process can restart Acrylic between
#     the worker's reload and its stamp.
#
# Lock order (never taken upward, never reversed):
#   Global\OpenPathUpdateLock
#     -> Global\OpenPathAcrylicWriteLock (short shared-write scopes)
#       -> Global\OpenPathAcrylicRestartLock (this file; always innermost)
# The restart lock is never held while taking the update or the writers lock,
# and Global\OpenPathPolicyStateLock (Update-AcrylicHost) never wraps a restart.
#
# On a restart-lock wait timeout the caller never restarts in parallel: the
# restart is logged as skipped (reason=lock-timeout) and left to the next cycle,
# or reported as a failure to its caller (captive portal transitions roll back
# and retry; the fast apply leaves the dependencies pending).

function Get-OpenPathAcrylicCallerName {
    <#
    .SYNOPSIS
        Best-effort name of the function/script that asked for the restart.
    .DESCRIPTION
        Used for the F1 `caller=` field. Skips this module's own frames and
        generic scriptblock frames so a restart issued from inside a scope
        scriptblock still reports the enclosing function.
    #>
    [CmdletBinding()]
    param()

    try {
        foreach ($frame in (Get-PSCallStack)) {
            $name = [string]$frame.Command
            if (-not $name) { continue }
            if ($name -like '<*') { continue }
            if ($name -in @('Get-OpenPathAcrylicCallerName', 'Invoke-OpenPathAcrylicRestart', 'Restart-AcrylicService')) { continue }
            return $name
        }
    }
    catch { }
    return 'unknown'
}

function Get-OpenPathAcrylicLoadedStatePath {
    <#
    .SYNOPSIS
        Path of the JSON that records what the running Acrylic loaded last.
    .DESCRIPTION
        OPENPATH_ACRYLIC_LOADED_STATE_PATH overrides the location (tests and the
        two-process serialization test). On non-Windows platforms the state
        tracking returns '' (disabled): the agent is Windows-only and the
        restart then evaluates as state-unknown, which keeps the historical
        restart-on-call behavior for cross-platform test runs.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    if ($env:OPENPATH_ACRYLIC_LOADED_STATE_PATH) { return [string]$env:OPENPATH_ACRYLIC_LOADED_STATE_PATH }
    if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') { return '' }

    $dataRoot = ''
    if ($OpenPathRoot) {
        $dataRoot = $OpenPathRoot
    }
    elseif (Get-Command -Name 'Get-OpenPathCapabilityStorageRoot' -ErrorAction SilentlyContinue) {
        $dataRoot = [string](Get-OpenPathCapabilityStorageRoot)
    }
    elseif ($script:OpenPathRoot) {
        $dataRoot = [string]$script:OpenPathRoot
    }
    else {
        $dataRoot = 'C:\OpenPath'
    }

    if ($dataRoot -match '^[A-Za-z]:\\' -and -not (Test-Path ([System.IO.Path]::GetPathRoot($dataRoot)) -ErrorAction SilentlyContinue)) {
        return "$($dataRoot.TrimEnd('\'))\data\acrylic-loaded-state.json"
    }
    return (Join-Path (Join-Path $dataRoot 'data') 'acrylic-loaded-state.json')
}

function Get-OpenPathAcrylicContentFingerprint {
    <#
    .SYNOPSIS
        Content fingerprint of the Acrylic hosts file (effective content) and INI.
    .DESCRIPTION
        The hosts render carries a `# Generated:` timestamp, so the fingerprint
        uses Get-AcrylicHostsEffectiveContent (the renderer's timestamp-free
        view): a re-render of the same effective content keeps the fingerprint
        stable. The combined hash is what the F2 decision compares.
    #>
    [CmdletBinding()]
    param([string]$AcrylicPath = '')

    if (-not $AcrylicPath) {
        if (Get-Command -Name 'Get-AcrylicPath' -ErrorAction SilentlyContinue) { $AcrylicPath = [string](Get-AcrylicPath) }
    }

    $hostsRaw = ''
    $iniRaw = ''
    $hostsPresent = $false
    $iniPresent = $false
    if ($AcrylicPath) {
        $hostsPath = Join-Path $AcrylicPath 'AcrylicHosts.txt'
        if (Test-Path -LiteralPath $hostsPath -ErrorAction SilentlyContinue) {
            try {
                $hostsRaw = [System.IO.File]::ReadAllText($hostsPath)
                $hostsPresent = $true
            }
            catch { $hostsRaw = '' }
        }
        $iniPath = Join-Path $AcrylicPath 'AcrylicConfiguration.ini'
        if (Test-Path -LiteralPath $iniPath -ErrorAction SilentlyContinue) {
            try {
                $iniRaw = [System.IO.File]::ReadAllText($iniPath)
                $iniPresent = $true
            }
            catch { $iniRaw = '' }
        }
    }

    $hostsEffective = $hostsRaw
    if (Get-Command -Name 'Get-AcrylicHostsEffectiveContent' -ErrorAction SilentlyContinue) {
        $hostsEffective = [string](Get-AcrylicHostsEffectiveContent -Content $hostsRaw)
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hostsHash = [BitConverter]::ToString($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hostsEffective))).Replace('-', '').ToLowerInvariant()
        $iniHash = [BitConverter]::ToString($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($iniRaw))).Replace('-', '').ToLowerInvariant()
        $combinedSource = "hosts:$hostsHash`nini:$iniHash"
        $combinedHash = [BitConverter]::ToString($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combinedSource))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return [pscustomobject]@{
        AcrylicPath      = $AcrylicPath
        HostsPresent     = $hostsPresent
        IniPresent       = $iniPresent
        HostsSha256      = $hostsHash
        IniSha256        = $iniHash
        CombinedSha256   = $combinedHash
    }
}

function Get-OpenPathAcrylicLoadedState {
    <#
    .SYNOPSIS
        Reads the loaded-state document; $null when absent or unreadable.
    #>
    [CmdletBinding()]
    param([string]$Path = '')

    if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = Get-OpenPathAcrylicLoadedStatePath }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return $null }

    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $parsed.PSObject.Properties['version'] -or [int]$parsed.version -ne 1) { return $null }
        if (-not $parsed.PSObject.Properties['combinedSha256'] -or -not [string]$parsed.combinedSha256) { return $null }
        return $parsed
    }
    catch {
        return $null
    }
}

function Set-OpenPathAcrylicLoadedState {
    <#
    .SYNOPSIS
        Records what the running Acrylic loaded after a successful restart.
    #>
    [CmdletBinding()]
    param(
        [object]$Fingerprint,

        [string]$Reason = '',

        [string]$Path = ''
    )

    if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = Get-OpenPathAcrylicLoadedStatePath }
    if (-not $Path -or -not $Fingerprint) { return $false }

    try {
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        }
        [pscustomobject][ordered]@{
            version        = 1
            hostsSha256    = [string]$Fingerprint.HostsSha256
            iniSha256      = [string]$Fingerprint.IniSha256
            combinedSha256 = [string]$Fingerprint.CombinedSha256
            hostsPresent   = [bool]$Fingerprint.HostsPresent
            iniPresent     = [bool]$Fingerprint.IniPresent
            loadedAtUtc    = [DateTime]::UtcNow.ToString('o')
            reason         = [string]$Reason
            pid            = $PID
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8 -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to record the Acrylic loaded state at $($Path): $_" -Level WARN
        return $false
    }
}

function Test-OpenPathAcrylicControlQuery {
    <#
    .SYNOPSIS
        Sends one local UDP DNS query to the proxy and reports whether it answered.
    .DESCRIPTION
        The F2 "not responding" arm. A DNS response - any rcode - proves the
        proxy is accepting and processing control traffic; a stopped service
        (no listener) or a wedged process (no answer within the timeout) fails.
        Only used to decide whether a restart is needed, never as a resolution
        health gate: on a network with no reachable upstream the proxy can
        exceed the timeout and is then restarted, which stays harmless because
        the restart is idempotent. Non-Windows platforms report responsive (the
        agent does not run there; the decision is exercised through test seams).
    #>
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 3,
        [string]$Server = '127.0.0.1',
        [int]$Port = 53
    )

    if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') { return $true }

    $udp = $null
    try {
        $queryName = 'openpath-control.local'
        $labels = @($queryName -split '\.')
        $bytes = New-Object System.Collections.Generic.List[byte]
        # DNS header: id 0x4F50, flags RD=1, QDCOUNT=1, AN/NS/AR=0.
        $bytes.AddRange([byte[]]@(0x4F, 0x50, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        foreach ($label in $labels) {
            $bytes.Add([byte]$label.Length)
            $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($label))
        }
        $bytes.Add(0x00)
        $bytes.AddRange([byte[]]@(0x00, 0x01, 0x00, 0x01))  # QTYPE A, QCLASS IN

        $udp = [System.Net.Sockets.UdpClient]::new()
        $udp.Client.ReceiveTimeout = [Math]::Max(1, $TimeoutSeconds) * 1000
        $udp.Connect($Server, [int]$Port)
        $null = $udp.Send($bytes.ToArray(), $bytes.Count)
        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $null = $udp.Receive([ref]$remote)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($udp) { $udp.Dispose() }
    }
}

function Get-OpenPathAcrylicRestartDecision {
    <#
    .SYNOPSIS
        Pure F2 decision: restart or not, and why.
    .DESCRIPTION
        Conditions (in evaluation order):
          - loaded state missing/unreadable  -> state-unknown (fail-safe)
          - effective content differs        -> content-changed
          - service not Running              -> service-down
          - control query did not answer     -> control-unresponsive
          - otherwise                        -> stable (skip)
        ControlQueryResponds $null means "not probed yet": the caller probes
        only when every other signal allows a skip.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$LoadedState = $null,
        [AllowNull()][object]$Fingerprint = $null,
        [AllowNull()][string]$ServiceStatus = '',
        [AllowNull()][object]$ControlQueryResponds = $null
    )

    if ($null -eq $LoadedState -or -not $LoadedState.PSObject.Properties['combinedSha256'] -or -not [string]$LoadedState.combinedSha256) {
        return [pscustomobject]@{ RestartNeeded = $true; Reason = 'state-unknown'; Detail = 'no readable loaded state; restarting to be safe' }
    }
    if ($null -eq $Fingerprint -or -not $Fingerprint.PSObject.Properties['CombinedSha256'] -or -not [string]$Fingerprint.CombinedSha256) {
        return [pscustomobject]@{ RestartNeeded = $true; Reason = 'state-unknown'; Detail = 'the current Acrylic content fingerprint is unavailable' }
    }
    if ([string]$Fingerprint.CombinedSha256 -ne [string]$LoadedState.combinedSha256) {
        return [pscustomobject]@{ RestartNeeded = $true; Reason = 'content-changed'; Detail = "loaded=$($LoadedState.combinedSha256) current=$($Fingerprint.CombinedSha256)" }
    }
    if ([string]$ServiceStatus -ne 'Running') {
        return [pscustomobject]@{ RestartNeeded = $true; Reason = 'service-down'; Detail = "serviceStatus=$ServiceStatus" }
    }
    if ($null -ne $ControlQueryResponds -and -not [bool]$ControlQueryResponds) {
        return [pscustomobject]@{ RestartNeeded = $true; Reason = 'control-unresponsive'; Detail = 'the local control query did not answer within the timeout' }
    }
    return [pscustomobject]@{ RestartNeeded = $false; Reason = 'stable'; Detail = 'the running service already loaded the current content and answers control queries' }
}

function Invoke-OpenPathAcrylicRestart {
    <#
    .SYNOPSIS
        The single, serialized Acrylic restart entry point (F1-F3).
    .DESCRIPTION
        Evaluates the cheap F2 arms and runs the local control probe BEFORE
        taking Global\OpenPathAcrylicRestartLock: the UDP probe can take
        seconds on a slow upstream (0.4-1.3 s typical, a 4.2 s hold measured in
        the lab) and holding the lock across it delayed other processes'
        restarts and the dependency ready path (worker lock waits 452-527 ms).
        It then acquires the lock with a bounded wait and re-evaluates the F2
        decision inside it (a waiter whose content another process already
        loaded coalesces), performs the restart and records the loaded state.
        Returns $true when the service is left running with the current content
        (restarted, or already stable) and $false on lock timeout or restart
        failure; a lock timeout never restarts in parallel.
    #>
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 20,

        [switch]$SkipBatchFallback,

        [string]$Caller = '',

        [int]$LockWaitTimeoutSeconds = 60,

        [string]$MutexName = 'Global\OpenPathAcrylicRestartLock',

        [string]$AcrylicPath = '',

        [string]$StatePath = '',

        # Test seam: replaces the local control probe (the two-process driver);
        # production leaves it empty.
        [scriptblock]$ControlProbeInvoker = $null
    )

    $callerName = if ($Caller) { $Caller } else { Get-OpenPathAcrylicCallerName }
    if (-not $PSBoundParameters.ContainsKey('StatePath')) { $StatePath = Get-OpenPathAcrylicLoadedStatePath }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $mutex = $null
    $lockAcquired = $false
    $probe = if ($ControlProbeInvoker) { $ControlProbeInvoker } else { { Test-OpenPathAcrylicControlQuery } }

    try {
        # Cheap arms + control probe OUTSIDE the restart lock (see the doc).
        $loadedState = Get-OpenPathAcrylicLoadedState -Path $StatePath
        $fingerprint = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $AcrylicPath
        $service = Get-AcrylicService
        $serviceStatus = if ($service) { [string]$service.Status } else { 'Missing' }
        $controlResponds = $null
        $preDecision = Get-OpenPathAcrylicRestartDecision -LoadedState $loadedState -Fingerprint $fingerprint -ServiceStatus $serviceStatus
        if (-not $preDecision.RestartNeeded) {
            $controlResponds = [bool](& $probe)
        }

        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $lockAcquired = $mutex.WaitOne(0)
            if (-not $lockAcquired -and $LockWaitTimeoutSeconds -gt 0) {
                $lockAcquired = $mutex.WaitOne([Math]::Max(0, $LockWaitTimeoutSeconds * 1000))
            }
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
            Write-OpenPathLog "Acrylic restart lock was abandoned by a previous process - continuing caller=$callerName pid=$PID" -Level WARN
        }

        if (-not $lockAcquired) {
            $stopwatch.Stop()
            Write-OpenPathLog "Acrylic restart skipped reason=lock-timeout caller=$callerName pid=$PID waitMs=$($stopwatch.ElapsedMilliseconds)" -Level WARN
            return $false
        }

        # Coalescing: re-evaluate inside the lock with the state as it is now
        # (another process may have loaded the content while the probe ran).
        $loadedState = Get-OpenPathAcrylicLoadedState -Path $StatePath
        $fingerprint = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $AcrylicPath
        $service = Get-AcrylicService
        $serviceStatus = if ($service) { [string]$service.Status } else { 'Missing' }
        $decision = Get-OpenPathAcrylicRestartDecision -LoadedState $loadedState -Fingerprint $fingerprint -ServiceStatus $serviceStatus -ControlQueryResponds $controlResponds

        if (-not $decision.RestartNeeded) {
            $stopwatch.Stop()
            Write-OpenPathLog "Acrylic restart skipped reason=stable caller=$callerName pid=$PID ms=$($stopwatch.ElapsedMilliseconds)"
            return $true
        }

        $coreCommand = Get-Command -Name 'Invoke-AcrylicServiceRestartCore' -ErrorAction SilentlyContinue
        if (-not $coreCommand) {
            $stopwatch.Stop()
            Write-OpenPathLog "Acrylic restart failed reason=$($decision.Reason) caller=$callerName pid=$PID detail=restart core unavailable" -Level ERROR
            return $false
        }

        $restarted = [bool](Invoke-AcrylicServiceRestartCore -TimeoutSeconds $TimeoutSeconds -SkipBatchFallback:$SkipBatchFallback)
        $stopwatch.Stop()
        if (-not $restarted) {
            Write-OpenPathLog "Acrylic restart failed reason=$($decision.Reason) caller=$callerName pid=$PID ms=$($stopwatch.ElapsedMilliseconds)" -Level WARN
            return $false
        }

        # Recompute the fingerprint after the restart: the on-disk content at the
        # moment the service started is what it actually loaded.
        $loadedFingerprint = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $AcrylicPath
        if (-not $loadedFingerprint.CombinedSha256) { $loadedFingerprint = $fingerprint }
        $null = Set-OpenPathAcrylicLoadedState -Fingerprint $loadedFingerprint -Reason $decision.Reason -Path $StatePath
        Write-OpenPathLog "Acrylic restart reason=$($decision.Reason) caller=$callerName pid=$PID ms=$($stopwatch.ElapsedMilliseconds)"
        return $true
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try { $mutex.ReleaseMutex() }
            catch [System.ApplicationException] { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Invoke-OpenPathAcrylicRestartLockScope {
    <#
    .SYNOPSIS
        Runs an action while holding the global Acrylic restart lock (F4).
    .DESCRIPTION
        The runtime dependency fast apply wraps its restart + DNS flush +
        appliedGeneration stamp in this scope: no other process can restart
        Acrylic between the worker's reload and its stamp, so a `ready` that is
        published afterwards can only be invalidated by a real content change.
        Returns [pscustomobject]@{ Acquired; Result; TimedOut }: on a bounded
        wait timeout the action never runs (no parallel restart) and the caller
        leaves the work for the next cycle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,

        [string]$MutexName = 'Global\OpenPathAcrylicRestartLock',

        [int]$LockWaitTimeoutSeconds = 60,

        [string]$Stage = ''
    )

    $mutex = $null
    $lockAcquired = $false
    $abandoned = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $lockAcquired = $mutex.WaitOne(0)
            if (-not $lockAcquired -and $LockWaitTimeoutSeconds -gt 0) {
                $scopeWaitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $lockAcquired = $mutex.WaitOne([Math]::Max(0, $LockWaitTimeoutSeconds * 1000))
                $scopeWaitStopwatch.Stop()
                if ($lockAcquired -and $Stage) {
                    Write-OpenPathLog "Acrylic restart lock scope=$Stage waited $($scopeWaitStopwatch.ElapsedMilliseconds) ms for another process" -Level WARN
                }
            }
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
            $abandoned = $true
        }

        if (-not $lockAcquired) {
            Write-OpenPathLog "Acrylic restart lock scope=$Stage waiting up to $LockWaitTimeoutSeconds seconds timed out; the action was left for the next cycle" -Level WARN
            return [pscustomobject]@{ Acquired = $false; Result = $null; TimedOut = $true }
        }
        if ($abandoned) {
            Write-OpenPathLog "Acrylic restart lock was abandoned by a previous process - continuing scope=$Stage" -Level WARN
        }

        $result = & $Action
        return [pscustomobject]@{ Acquired = $true; Result = $result; TimedOut = $false }
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try { $mutex.ReleaseMutex() }
            catch [System.ApplicationException] { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}
