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
