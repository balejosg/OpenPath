# Endpoint posture: reads what protection is live on this PC and reports
# contradictions with the classroom state. Leaf helper, dot-sourced by the
# watchdog script and the update runtime; it holds no module state.

function Test-OpenPathAdapterDnsPinnedToLocalResolver {
    # true when an active adapter still resolves through the local Acrylic proxy; the
    # firewall alone cannot prove a disabled classroom is open because a concurrent
    # protected-mode restore pins DNS before it rebuilds the rules
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name 'Get-DnsClientServerAddress' -ErrorAction SilentlyContinue)) {
        return $false
    }

    foreach ($adapter in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $address = Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
        $servers = @($address | ForEach-Object { @($_.ServerAddresses) } | Where-Object { $_ })
        if ($servers.Count -gt 0 -and [string]$servers[0] -eq '127.0.0.1') {
            return $true
        }
    }

    return $false
}

function Get-OpenPathOpenClassroomPostureFindings {
    <#
    .SYNOPSIS
        Names the contradictions between an open classroom and active protection.
    .DESCRIPTION
        Pure. A classroom whose whitelist is disabled is meant to be open, so
        firewall rules or a DNS pin to the local resolver still being in force
        means browsing fails with nothing showing why. Returns reason codes in a
        stable order, and an empty array when the classroom is enabled or captive
        portal mode is active (protection is expected to be partial then).
    .OUTPUTS
        string[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ClassroomDisabled,

        [Parameter(Mandatory = $true)]
        [bool]$PortalModeActive,

        [Parameter(Mandatory = $true)]
        [bool]$FirewallActive,

        [Parameter(Mandatory = $true)]
        [bool]$DnsPinned
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($ClassroomDisabled -and -not $PortalModeActive) {
        if ($FirewallActive) { [void]$findings.Add('open_classroom_firewall_active') }
        if ($DnsPinned) { [void]$findings.Add('open_classroom_dns_pinned') }
    }

    return $findings.ToArray()
}

function Get-OpenPathOpenClassroomPosture {
    <#
    .SYNOPSIS
        Reads live classroom and protection state and reports open-classroom findings.
    .DESCRIPTION
        Never throws. Classroom state that cannot be read counts as an enabled
        classroom (no findings); a failed firewall, DNS or portal probe counts as
        not active for that signal. Portal state is read without the expired-marker
        restore, so reading posture never changes the endpoint.

        FirewallActive and DnsPinned are probed only when the classroom is disabled
        and portal mode is inactive. In every other case both are $false and mean
        "not probed", not "probed and found inactive".
    .OUTPUTS
        PSCustomObject with ClassroomDisabled, PortalModeActive, FirewallActive,
        DnsPinned and Findings.
    #>
    [CmdletBinding()]
    param()

    $classroomDisabled = $false
    $portalModeActive = $false
    $firewallActive = $false
    $dnsPinned = $false

    try { $classroomDisabled = [bool](Test-OpenPathCaptivePortalClassroomDisabled) } catch { $classroomDisabled = $false }
    try { $portalModeActive = [bool](Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore) } catch { $portalModeActive = $false }
    # The watchdog runs every minute and the protection probes only matter for an
    # open classroom outside portal mode, so they are skipped otherwise.
    if ($classroomDisabled -and -not $portalModeActive) {
        try { $firewallActive = [bool](Test-FirewallActive) } catch { $firewallActive = $false }
        try { $dnsPinned = [bool](Test-OpenPathAdapterDnsPinnedToLocalResolver) } catch { $dnsPinned = $false }
    }

    $findings = @(Get-OpenPathOpenClassroomPostureFindings `
            -ClassroomDisabled $classroomDisabled `
            -PortalModeActive $portalModeActive `
            -FirewallActive $firewallActive `
            -DnsPinned $dnsPinned)

    return [PSCustomObject]@{
        ClassroomDisabled = $classroomDisabled
        PortalModeActive  = $portalModeActive
        FirewallActive    = $firewallActive
        DnsPinned         = $dnsPinned
        Findings          = $findings
    }
}

function Merge-OpenPathReasonCodes {
    <#
    .SYNOPSIS
        Appends reason codes to an existing list, dropping blanks and duplicates.
    .OUTPUTS
        string[]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ReasonCodes = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$AdditionalReasonCodes = @()
    )

    $merged = [System.Collections.Generic.List[string]]::new()
    foreach ($code in @(@($ReasonCodes) + @($AdditionalReasonCodes))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$code) -and -not $merged.Contains([string]$code)) {
            [void]$merged.Add([string]$code)
        }
    }

    return $merged.ToArray()
}

function Get-OpenPathOutcomeReasonCodesWithPosture {
    <#
    .SYNOPSIS
        Returns the watchdog outcome's reason codes plus any open-classroom findings.
    .DESCRIPTION
        Reason codes only: the outcome's Status and Actions are neither read nor
        changed. If the posture cannot be evaluated the existing codes are returned
        unchanged and a warning is logged.
    .OUTPUTS
        string[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Outcome
    )

    $existingCodes = @()
    if ($Outcome -and $Outcome.PSObject.Properties['ReasonCodes']) {
        $existingCodes = @($Outcome.ReasonCodes | ForEach-Object { [string]$_ })
    }

    try {
        $posture = Get-OpenPathOpenClassroomPosture
        return Merge-OpenPathReasonCodes -ReasonCodes $existingCodes -AdditionalReasonCodes @($posture.Findings)
    }
    catch {
        try { Write-OpenPathLog "Watchdog: Could not evaluate open-classroom posture: $_" -Level WARN } catch { }
        return Merge-OpenPathReasonCodes -ReasonCodes $existingCodes -AdditionalReasonCodes @()
    }
}

function Read-OpenPathPostureStateNumber {
    # reads one non-negative integer from a small state file; a missing, empty,
    # corrupt or unreadable file is $null so a damaged file never blocks the watchdog
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (-not [System.IO.File]::Exists($Path)) { return $null }
        $text = ([System.IO.File]::ReadAllText($Path)).Trim()
        $value = [long]0
        if ([long]::TryParse($text, [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            return $value
        }
    }
    catch { }

    return $null
}

function Write-OpenPathPostureStateNumber {
    # writes one integer through a temp file and an atomic replace so a crash or a
    # concurrent reader never sees a partial file; returns $false instead of throwing
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [long]$Value
    )

    $token = [guid]::NewGuid().ToString('N')
    $tempPath = "$Path.tmp.$token"
    $backupPath = "$Path.bak.$token"
    try {
        $directory = [System.IO.Path]::GetDirectoryName($Path)
        if ($directory -and -not [System.IO.Directory]::Exists($directory)) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }
        $text = $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        [System.IO.File]::WriteAllText($tempPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($Path)) {
            # a null backup name reaches .NET as an empty string and throws
            [System.IO.File]::Replace($tempPath, $Path, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
        return $true
    }
    catch {
        return $false
    }
    finally {
        foreach ($leftover in @($tempPath, $backupPath)) {
            try { if ([System.IO.File]::Exists($leftover)) { [System.IO.File]::Delete($leftover) } } catch { }
        }
    }
}

function Remove-OpenPathPostureStateFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try { if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) } } catch { }
}

function Enter-OpenPathPostureNamedMutex {
    # takes a named machine-wide mutex without waiting; Acquired is $false when it
    # is busy or cannot be opened, and the caller then skips instead of waiting
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $mutex = $null
    $acquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $Name)
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
    }
    catch {
        $acquired = $false
    }

    if (-not $acquired -and $mutex) {
        $mutex.Dispose()
        $mutex = $null
    }

    return [PSCustomObject]@{ Acquired = [bool]$acquired; Mutex = $mutex }
}

function Exit-OpenPathPostureNamedMutex {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Lock
    )

    if (-not $Lock -or -not $Lock.Mutex) { return }
    try { if ($Lock.Acquired) { $Lock.Mutex.ReleaseMutex() } } catch { }
    try { $Lock.Mutex.Dispose() } catch { }
}

function Clear-OpenPathOpenClassroomPostureState {
    <#
    .SYNOPSIS
        Forgets the open-classroom repair streak and backoff.
    .DESCRIPTION
        Called by the watchdog on every cycle that is not an eligible open
        classroom (enabled, portal mode, DNS failure mode, stale fail-safe), so a
        streak recorded before such a cycle can never count as consecutive.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($OpenPathRoot)) {
        $OpenPathRoot = if ($script:OpenPathRoot) { [string]$script:OpenPathRoot } else { 'C:\OpenPath' }
    }
    $dataRoot = Join-Path $OpenPathRoot 'data'
    Remove-OpenPathPostureStateFile -Path (Join-Path $dataRoot 'open-classroom-posture-streak.txt')
    Remove-OpenPathPostureStateFile -Path (Join-Path $dataRoot 'open-classroom-posture-repair-attempt.txt')
}

function Invoke-OpenPathOpenClassroomPostureRepair {
    <#
    .SYNOPSIS
        Reopens a disabled classroom that was left protected.
    .DESCRIPTION
        An open classroom (whitelist disabled, not in captive portal mode, no DNS
        failure mode) must not keep firewall rules or a DNS pin to the local
        resolver. A protected-mode restore that is still in progress briefly shows
        the same state, so the repair waits for a second consecutive watchdog cycle
        with findings. The streak file holds the UTC ticks of the last such cycle
        and counts only while recent (StreakMaxAgeMinutes); busy and backoff
        cycles refresh it. It then takes, without waiting, the whitelist update
        cycle's mutex (Global\OpenPathUpdateLock, so no update can apply a
        whitelist meanwhile) and the agent update lock, re-reads the whitelist and
        the posture, and repairs with the FailOpen plan only if the classroom is
        still open and findings still exist. Both locks are held through the repair.

        After an attempt it does not try again for BackoffMinutes while findings
        persist, so a third-party local resolver that also uses 127.0.0.1 does not
        get its adapter reset every cycle. A clean cycle clears the streak and the
        backoff. State lives in data\open-classroom-posture-streak.txt and
        data\open-classroom-posture-repair-attempt.txt (UTC ticks).

        Never throws. Skipped is $true whenever no repair was attempted; Reason
        says why. A successful repair has Repaired $true and Reason
        'open_classroom_reopened'; a failed attempt has Skipped $false, Repaired
        $false and Reason 'repair_failed'.
    .OUTPUTS
        PSCustomObject with Repaired, Skipped and Reason.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config,

        [string]$OpenPathRoot = '',

        [int]$BackoffMinutes = 30,

        [int]$StreakMaxAgeMinutes = 5,

        [string]$UpdateMutexName = 'Global\OpenPathUpdateLock',

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $result = [PSCustomObject]@{ Repaired = $false; Skipped = $true; Reason = '' }

    try {
        if ([string]::IsNullOrWhiteSpace($OpenPathRoot)) {
            $OpenPathRoot = if ($script:OpenPathRoot) { [string]$script:OpenPathRoot } else { 'C:\OpenPath' }
        }
        $dataRoot = Join-Path $OpenPathRoot 'data'
        $whitelistPath = Join-Path $dataRoot 'whitelist.txt'
        $streakPath = Join-Path $dataRoot 'open-classroom-posture-streak.txt'
        $attemptPath = Join-Path $dataRoot 'open-classroom-posture-repair-attempt.txt'

        # $null means the classroom state cannot be read, and then nothing is done.
        $readSections = {
            try {
                if (-not (Test-Path -LiteralPath $whitelistPath -PathType Leaf)) { return $null }
                $sections = Get-OpenPathWhitelistSectionsFromFile -Path $whitelistPath
                if ($sections -and $sections.PSObject.Properties['IsDisabled']) { return $sections }
            }
            catch { }
            return $null
        }

        # Returns '' when a repair is warranted, otherwise the reason it is not.
        $assess = {
            param($Sections, $Posture)
            if (-not ([bool]$Sections.IsDisabled -and [bool]$Posture.ClassroomDisabled -and -not [bool]$Posture.PortalModeActive)) {
                return 'classroom_not_open'
            }
            if (@($Posture.Findings).Count -eq 0) { return 'no_findings' }
            return ''
        }

        $sections = & $readSections
        if (-not $sections) {
            $result.Reason = 'whitelist_unreadable'
            return $result
        }

        # A DNS failure mode, or the stale-whitelist fail-safe (which deliberately
        # re-arms protection), makes a reopen inappropriate; reopening would only
        # flap against them. Returns the reason, or '' when neither is active.
        $blockedByOtherMode = {
            $failureModeState = $null
            if (Get-Command -Name 'Read-OpenPathDnsFailureModeState' -ErrorAction SilentlyContinue) {
                try { $failureModeState = Read-OpenPathDnsFailureModeState -OpenPathRoot $OpenPathRoot } catch { $failureModeState = $null }
            }
            if ($failureModeState -and [string]$failureModeState.mode -in @('protected', 'open')) {
                return 'dns_failure_mode_active'
            }
            if (Test-Path -LiteralPath (Join-Path $dataRoot 'stale-failsafe-state.json') -PathType Leaf) {
                return 'stale_failsafe_active'
            }
            return ''
        }

        $blocked = & $blockedByOtherMode
        if ($blocked) {
            Remove-OpenPathPostureStateFile -Path $streakPath
            $result.Reason = $blocked
            return $result
        }

        $posture = $null
        try { $posture = Get-OpenPathOpenClassroomPosture } catch { $posture = $null }
        if (-not $posture) {
            $result.Reason = 'posture_unavailable'
            return $result
        }

        $notWarranted = & $assess $sections $posture
        if ($notWarranted) {
            Remove-OpenPathPostureStateFile -Path $streakPath
            Remove-OpenPathPostureStateFile -Path $attemptPath
            $result.Reason = $notWarranted
            return $result
        }

        # The streak is the time of the last cycle with findings and counts only
        # while recent: an old, future-dated or corrupt value starts a new streak.
        $refreshStreak = {
            if (-not (Write-OpenPathPostureStateNumber -Path $streakPath -Value $NowUtc.Ticks)) {
                Write-OpenPathLog "Watchdog: Could not record the open-classroom posture streak at $streakPath" -Level WARN
            }
        }
        $streakTicks = Read-OpenPathPostureStateNumber -Path $streakPath
        $streakIsRecent = $false
        if ($null -ne $streakTicks -and $streakTicks -le $NowUtc.Ticks) {
            $streakIsRecent = ([TimeSpan]::FromTicks($NowUtc.Ticks - $streakTicks) -le [TimeSpan]::FromMinutes($StreakMaxAgeMinutes))
        }
        if (-not $streakIsRecent) {
            & $refreshStreak
            $result.Reason = 'streak_recorded'
            return $result
        }

        $lastAttemptTicks = Read-OpenPathPostureStateNumber -Path $attemptPath
        if ($null -ne $lastAttemptTicks -and $lastAttemptTicks -le $NowUtc.Ticks) {
            $elapsed = [TimeSpan]::FromTicks($NowUtc.Ticks - $lastAttemptTicks)
            if ($elapsed -lt [TimeSpan]::FromMinutes($BackoffMinutes)) {
                & $refreshStreak
                $result.Reason = 'repair_backoff'
                return $result
            }
        }

        # The whitelist update cycle holds its own mutex (outermost lock) while it
        # downloads and applies a whitelist; the agent update lock does not exclude
        # it. Take both without waiting and hold them through the repair, so a
        # whitelist that re-enables the classroom is never undone by this repair.
        $updateCycleLock = Enter-OpenPathPostureNamedMutex -Name $UpdateMutexName
        if (-not $updateCycleLock.Acquired) {
            & $refreshStreak
            $result.Reason = 'update_lock_busy'
            return $result
        }

        $lock = $null
        try {
            if (-not (Get-Command -Name 'Enter-OpenPathAgentUpdateLock' -ErrorAction SilentlyContinue)) {
                & $refreshStreak
                $result.Reason = 'update_lock_unavailable'
                return $result
            }
            $lock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 0
            if (-not $lock -or -not $lock.Acquired) {
                $lock = $null
                & $refreshStreak
                $result.Reason = 'update_lock_busy'
                return $result
            }

            # Judge the state as it is now, never the state the streak saw.
            $sections = & $readSections
            if (-not $sections) {
                $result.Reason = 'whitelist_unreadable'
                return $result
            }
            $blocked = & $blockedByOtherMode
            if ($blocked) {
                Remove-OpenPathPostureStateFile -Path $streakPath
                $result.Reason = $blocked
                return $result
            }
            $posture = $null
            try { $posture = Get-OpenPathOpenClassroomPosture } catch { $posture = $null }
            if (-not $posture) {
                $result.Reason = 'posture_unavailable'
                return $result
            }
            $notWarranted = & $assess $sections $posture
            if ($notWarranted) {
                Remove-OpenPathPostureStateFile -Path $streakPath
                Remove-OpenPathPostureStateFile -Path $attemptPath
                $result.Reason = if ($notWarranted -eq 'classroom_not_open') { 'classroom_no_longer_open' } else { $notWarranted }
                return $result
            }

            # Record the attempt first so a repair that hangs or crashes still backs off.
            if (-not (Write-OpenPathPostureStateNumber -Path $attemptPath -Value $NowUtc.Ticks)) {
                Write-OpenPathLog "Watchdog: Could not record the open-classroom repair attempt at $attemptPath; not repairing" -Level WARN
                $result.Reason = 'state_unwritable'
                return $result
            }

            $result.Skipped = $false
            $result.Reason = 'repair_failed'
            try {
                Write-OpenPathLog "Watchdog: Protection is active while the classroom is disabled ($(@($posture.Findings) -join ', ')); reopening" -Level WARN
                $policyState = Get-OpenPathEndpointPolicyState -WhitelistSections $sections
                $plan = New-OpenPathEndpointStateRepairPlan -PolicyState $policyState -Mode FailOpen
                Invoke-OpenPathEndpointStateRepairPlan -Plan $plan -Config $Config | Out-Null

                $after = Get-OpenPathOpenClassroomPosture
                if (-not ([bool]$after.ClassroomDisabled -and -not [bool]$after.PortalModeActive)) {
                    # success would be misleading: the classroom is no longer open or
                    # portal mode started; the next cycle judges the new state
                    $result.Reason = 'classroom_changed_during_repair'
                    Write-OpenPathLog 'Watchdog: Classroom state changed during the open-classroom repair; not reporting a reopen' -Level WARN
                }
                elseif (@($after.Findings).Count -eq 0) {
                    Remove-OpenPathPostureStateFile -Path $streakPath
                    $result.Repaired = $true
                    $result.Reason = 'open_classroom_reopened'
                    Write-OpenPathLog 'Watchdog: Reopened a disabled classroom that was left protected'
                }
                else {
                    & $refreshStreak
                    Write-OpenPathLog "Watchdog: Open-classroom repair left findings in place ($(@($after.Findings) -join ', ')); next attempt after $BackoffMinutes minutes" -Level WARN
                }
            }
            catch {
                & $refreshStreak
                Write-OpenPathLog "Watchdog: Open-classroom repair failed: $_; next attempt after $BackoffMinutes minutes" -Level WARN
            }
            return $result
        }
        finally {
            if ($lock) { Exit-OpenPathAgentUpdateLock -Lock $lock }
            Exit-OpenPathPostureNamedMutex -Lock $updateCycleLock
        }
    }
    catch {
        try { Write-OpenPathLog "Watchdog: Open-classroom posture repair could not run: $_" -Level WARN } catch { }
        $result.Repaired = $false
        $result.Skipped = $true
        $result.Reason = 'posture_repair_error'
        return $result
    }
}
