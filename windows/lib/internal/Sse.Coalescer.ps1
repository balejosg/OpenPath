################################################################################
# Sse.Coalescer.ps1 - SSE update coalescer for Windows
#
# Mirrors the semantics of linux/lib/sse-update-coalescer.sh:
#   - Default cooldown: 10 seconds (sseUpdateCooldown config key, camelCase)
#   - On event: if elapsed >= cooldown -> trigger immediately (trailing-edge)
#   - On event within cooldown: schedule one deferred update at the end of the
#     remaining window; further events within that window are no-ops (idempotent)
#   - No separate max-wait cap beyond the cooldown window itself
#
# Design: pure, testable functions with an injectable clock (NowTime parameter).
# The update trigger callback is passed as a [scriptblock] so Pester can count
# invocations without touching any external process.
#
# Deferred dispatch is mandatory (DeferAction parameter) so that callers own
# the scheduling strategy. Production callers pass an in-process DeferAction
# that sleeps inline (blocking the listener loop for the remainder of the
# cooldown window). Tests inject a no-op or counter DeferAction instead.
################################################################################

function Get-SseCoalescerDefaultCooldown {
    <#
    .SYNOPSIS
        Returns the default SSE update cooldown in seconds.
        Mirrors SSE_UPDATE_COOLDOWN default (10) from sse-update-coalescer.sh.
    #>
    return 10
}

function New-SseCoalescerState {
    <#
    .SYNOPSIS
        Creates a fresh coalescer state object.
    .DESCRIPTION
        The state object is passed into and returned from each coalescer call so
        that callers maintain state explicitly. This keeps the functions pure and
        easy to test.
    .OUTPUTS
        PSCustomObject with LastUpdateTime and PendingUpdateDueAt fields.
    #>
    return [PSCustomObject]@{
        LastUpdateTime     = [datetime]::MinValue
        PendingUpdateDueAt = [datetime]::MinValue
    }
}

function Invoke-SseCoalescerUpdate {
    <#
    .SYNOPSIS
        Processes one SSE event through the coalescer, mirroring sse_trigger_update().
    .DESCRIPTION
        Implements the trailing-edge debounce / cooldown logic:

          - If (now - LastUpdateTime) >= CooldownSeconds: fire UpdateAction
            immediately, clear any pending marker, record LastUpdateTime = now.
          - Otherwise: if no pending update is already queued, invoke DeferAction
            (which schedules the update after the remaining window). Further events
            within the same window are idempotent (no additional DeferAction call).

        DeferAction is mandatory — callers own the scheduling strategy. Production
        callers pass an in-process DeferAction that calls Start-OpenPathSseUpdateProcess
        with -DelaySeconds, blocking the listener loop for the cooldown remainder.
        Tests inject a no-op or counter DeferAction instead.

    .PARAMETER State
        The coalescer state object from New-SseCoalescerState. Mutated in place
        and returned so callers can chain calls.

    .PARAMETER UpdateAction
        A [scriptblock] invoked when the coalescer decides to trigger an update
        immediately. Receives no arguments.

    .PARAMETER CooldownSeconds
        The debounce window in seconds. Defaults to Get-SseCoalescerDefaultCooldown (10).

    .PARAMETER NowTime
        Optional override for the current time. When supplied the live clock is
        bypassed. Intended for unit tests that need deterministic time without
        mocking global state.

    .PARAMETER DeferAction
        Mandatory scriptblock called when a deferred update is scheduled. Receives
        two named arguments: -DelaySeconds [int] and -UpdateAction [scriptblock].

        Tests inject a no-op or counter here instead of overriding an inner function.

    .OUTPUTS
        The (mutated) State object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [scriptblock]$UpdateAction,

        [int]$CooldownSeconds = -1,

        [Nullable[datetime]]$NowTime = $null,

        [Parameter(Mandatory = $true)]
        [scriptblock]$DeferAction
    )

    if ($CooldownSeconds -lt 0) {
        $CooldownSeconds = Get-SseCoalescerDefaultCooldown
    }

    $now = if ($null -ne $NowTime) { $NowTime } else { [datetime]::UtcNow }

    $elapsed = ($now - $State.LastUpdateTime).TotalSeconds
    if ($elapsed -lt 0) {
        $elapsed = $CooldownSeconds
    }

    if ($elapsed -ge $CooldownSeconds) {
        # Cooldown has expired — trigger immediately (trailing-edge).
        $State.LastUpdateTime     = $now
        $State.PendingUpdateDueAt = [datetime]::MinValue
        Write-SseCoalescerLog "SSE: Whitelist change detected - triggering immediate update"
        & $UpdateAction
    }
    else {
        # Within the cooldown window — schedule at most one deferred update.
        if ($State.PendingUpdateDueAt -gt $now) {
            $dueStr = $State.PendingUpdateDueAt.ToString('o')
            Write-SseCoalescerLog "SSE: Deferred update already queued for $dueStr"
        }
        else {
            $remaining = [Math]::Max(1, [int][Math]::Ceiling($CooldownSeconds - $elapsed))
            $State.PendingUpdateDueAt = $now.AddSeconds($remaining)
            Write-SseCoalescerLog "SSE: Deferring update (last update ${elapsed}s ago, cooldown ${CooldownSeconds}s) - scheduled in ${remaining}s"

            & $DeferAction -DelaySeconds $remaining -UpdateAction $UpdateAction
        }
    }

    return $State
}


function Write-SseCoalescerLog {
    <#
    .SYNOPSIS
        Logging shim. Delegates to Write-OpenPathLog if available, otherwise
        writes to the host (for standalone/test runs).
    #>
    param([string]$Message)

    if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
        Write-OpenPathLog $Message
    }
    else {
        Write-Host $Message
    }
}

function Get-SseUpdateCooldownFromConfig {
    <#
    .SYNOPSIS
        Reads the sseUpdateCooldown value from a config object, returning the
        default (10) if the key is absent or invalid. Mirrors the config
        read in Get-SSEConfig in Start-SSEListener.ps1 and the Linux default.
    .PARAMETER Config
        A PSCustomObject from Get-OpenPathConfig (or a mock thereof).
    #>
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    if (-not $Config -or -not $Config.PSObject -or -not $Config.PSObject.Properties['sseUpdateCooldown']) {
        return Get-SseCoalescerDefaultCooldown
    }

    $raw = $Config.sseUpdateCooldown
    $parsed = try { [int]$raw } catch { -1 }
    if ($parsed -lt 1) {
        return Get-SseCoalescerDefaultCooldown
    }

    return $parsed
}

function Invoke-SseCanarySelfUpdateProcess {
    <#
    .SYNOPSIS
        Runs the canary-only agent self-update in its own Windows PowerShell process.
    .DESCRIPTION
        The self-update imports every agent module, may replace files and
        re-registers the scheduled tasks, so it runs as `OpenPath.ps1
        self-update --canary-only --silent` in a separate process instead of
        inside the listener. Success is that process's exit code: OpenPath.ps1
        exits 1 on a failed self-update and 0 otherwise, so no stale
        $LASTEXITCODE from the listener session can be read as a failure.
    .PARAMETER ProcessRunner
        Test seam: receives the executable path and argument string, returns the
        exit code. The default starts a hidden process and waits for it.
    .OUTPUTS
        PSCustomObject with Success, ExitCode and Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string]$PowerShellPath = '',

        [int]$TimeoutSeconds = 1800,

        [scriptblock]$ProcessRunner = $null
    )

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $systemRoot = [string]$env:SystemRoot
        $candidate = if ($systemRoot) { Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
        $PowerShellPath = if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $candidate } else { 'powershell.exe' }
    }

    # String join, not Join-Path: the root is a Windows path that must not be
    # resolved against the drives of the current session.
    $entry = $OpenPathRoot.TrimEnd('\', '/') + '\OpenPath.ps1'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$entry`" self-update --canary-only --silent"

    if ($null -eq $ProcessRunner) {
        $ProcessRunner = {
            param([string]$FilePath, [string]$ArgumentList, [int]$WaitSeconds)
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $FilePath
            $startInfo.Arguments = $ArgumentList
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                if (-not $process.WaitForExit($WaitSeconds * 1000)) {
                    # Never kill an update mid-way; the update lock and journal
                    # keep a later run safe.
                    return $null
                }
                return $process.ExitCode
            }
            finally {
                $process.Dispose()
            }
        }
    }

    try {
        $exitCode = & $ProcessRunner $PowerShellPath $arguments $TimeoutSeconds
    }
    catch {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = $null
            Message  = "could not start the canary self-update process: $($_.Exception.Message)"
        }
    }

    if ($null -eq $exitCode) {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = $null
            Message  = "the canary self-update process is still running after $TimeoutSeconds seconds"
        }
    }
    if ([int]$exitCode -ne 0) {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = [int]$exitCode
            Message  = "the canary self-update process exited with code $exitCode"
        }
    }
    return [PSCustomObject]@{
        Success  = $true
        ExitCode = 0
        Message  = ''
    }
}
