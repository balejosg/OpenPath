if (-not (Get-Command -Name 'Write-OpenPathAtomicJsonFile' -ErrorAction SilentlyContinue)) {
    $configHelperPath = Join-Path $PSScriptRoot 'Common.Config.ps1'
    if (Test-Path -LiteralPath $configHelperPath) {
        . $configHelperPath
    }
}

function Restore-CheckpointFromWatchdog {
    # rolls back to the most recent stored checkpoint when dns verification fails
    # after rollback: waits for acrylic to settle, then re-verifies resolution and sinkhole
    # returns true only when both checks pass after the rollback
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [string]$OpenPathRoot = 'C:\OpenPath'
    )

    $whitelistPath = Join-Path $OpenPathRoot 'data\whitelist.txt'

    $restoreResult = Restore-OpenPathLatestCheckpoint -Config $Config -WhitelistPath $whitelistPath
    if (-not $restoreResult.Success) {
        if ($restoreResult.Error) {
            Write-OpenPathLog "Watchdog: $($restoreResult.Error)" -Level WARN
        }
        else {
            Write-OpenPathLog 'Watchdog: Checkpoint recovery failed for unknown reason' -Level WARN
        }
        return $false
    }

    try {
        Start-Sleep -Seconds 2

        if ((Test-DNSResolution) -and (Test-DNSSinkhole -Domain "this-should-be-blocked-test-12345.com")) {
            Write-OpenPathLog "Watchdog: Checkpoint recovery succeeded from $($restoreResult.CheckpointPath)" -Level WARN
            return $true
        }

        Write-OpenPathLog "Watchdog: Checkpoint recovery did not fully restore DNS behavior" -Level WARN
        return $false
    }
    catch {
        Write-OpenPathLog "Watchdog: Checkpoint recovery failed: $_" -Level ERROR
        return $false
    }
}

. (Join-Path $PSScriptRoot 'EndpointPolicyState.ps1')
. (Join-Path $PSScriptRoot 'EndpointStateReconciler.ps1')
. (Join-Path $PSScriptRoot 'Watchdog.CaptivePortalPolicy.ps1')

if (-not (Get-Command -Name 'Get-OpenPathScheduledTaskSpec' -ErrorAction SilentlyContinue)) {
    $scheduledTaskCatalogPath = Join-Path $PSScriptRoot 'ScheduledTaskCatalog.ps1'
    if (Test-Path -LiteralPath $scheduledTaskCatalogPath) {
        . $scheduledTaskCatalogPath
    }
}

function ConvertTo-OpenPathWatchdogCanonicalPath {
    # Canonical task-builder paths are compared as full paths. Do not collapse
    # dot segments here: accepting a path that only becomes equal after
    # resolving .. would allow an action outside the installed OpenPath root.
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $normalized = $Path.Trim().Trim('"').Trim("'").Replace('/', '\')
    return $normalized.TrimEnd('\').ToLowerInvariant()
}

function Get-OpenPathWatchdogTaskHealth {
    <#
    .SYNOPSIS
        Observes whether the installed OpenPath watchdog task is runnable.
    .DESCRIPTION
        This helper is deliberately read-only. A task is healthy only when the
        catalog name, exact absolute script path, SYSTEM/Highest principal,
        enabled recurring trigger, and Ready/Running state all agree.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = 'C:\OpenPath'
    )

    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    $addReasonCode = {
        param([string]$Code)
        if (-not $reasonCodes.Contains($Code)) {
            [void]$reasonCodes.Add($Code)
        }
    }

    $present = $false
    $enabled = $false
    $runnable = $false
    $state = ''
    $actionPath = ''
    $expectedActionPath = ''

    $spec = $null
    try {
        if (-not (Get-Command -Name 'Get-OpenPathScheduledTaskSpec' -ErrorAction SilentlyContinue)) {
            throw 'OpenPath scheduled-task catalog is unavailable'
        }
        $spec = Get-OpenPathScheduledTaskSpec -TaskType Watchdog
        if (-not $spec -or [string]::IsNullOrWhiteSpace([string]$spec.Name) -or [string]::IsNullOrWhiteSpace([string]$spec.Script)) {
            throw 'OpenPath watchdog task descriptor is invalid'
        }

        if ($OpenPathRoot -match '^[A-Za-z]:\\|^\\\\') {
            $expectedActionPath = "{0}\{1}" -f $OpenPathRoot.TrimEnd('\'), ([string]$spec.Script).TrimStart('\')
        }
        else {
            $expectedActionPath = Join-Path $OpenPathRoot ([string]$spec.Script)
        }
    }
    catch {
        & $addReasonCode 'watchdog_task_not_runnable'
        return [PSCustomObject][ordered]@{
            Healthy = $false
            ReasonCodes = @($reasonCodes.ToArray())
            Present = $false
            Enabled = $false
            Runnable = $false
            State = $state
            ActionPath = $actionPath
            ExpectedActionPath = $expectedActionPath
        }
    }

    if (-not (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        & $addReasonCode 'watchdog_task_not_runnable'
        return [PSCustomObject][ordered]@{
            Healthy = $false
            ReasonCodes = @($reasonCodes.ToArray())
            Present = $false
            Enabled = $false
            Runnable = $false
            State = $state
            ActionPath = $actionPath
            ExpectedActionPath = $expectedActionPath
        }
    }

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName ([string]$spec.Name) -ErrorAction SilentlyContinue
    }
    catch {
        $task = $null
    }

    if (-not $task) {
        & $addReasonCode 'watchdog_task_missing'
        return [PSCustomObject][ordered]@{
            Healthy = $false
            ReasonCodes = @($reasonCodes.ToArray())
            Present = $false
            Enabled = $false
            Runnable = $false
            State = $state
            ActionPath = $actionPath
            ExpectedActionPath = $expectedActionPath
        }
    }

    $present = $true
    $state = if ($task.PSObject.Properties['State']) { [string]$task.State } else { '' }
    $taskEnabled = $true
    if ($task.PSObject.Properties['Enabled']) {
        $taskEnabled = [bool]$task.Enabled
    }
    if ($task.PSObject.Properties['Settings'] -and $task.Settings -and $task.Settings.PSObject.Properties['Enabled']) {
        $taskEnabled = $taskEnabled -and [bool]$task.Settings.Enabled
    }

    if ($state -eq 'Disabled' -or -not $taskEnabled) {
        & $addReasonCode 'watchdog_task_disabled'
    }
    $enabled = [bool]($taskEnabled -and $state -ne 'Disabled')

    if ($state -notin @('Ready', 'Running')) {
        if ($state -ne 'Disabled') {
            & $addReasonCode 'watchdog_task_not_runnable'
        }
    }

    $scriptExists = $false
    try {
        $scriptExists = [bool](Test-Path -LiteralPath $expectedActionPath -PathType Leaf)
    }
    catch {
        $scriptExists = $false
    }
    if (-not $scriptExists) {
        & $addReasonCode 'watchdog_task_not_runnable'
    }

    $expectedCanonicalPath = ConvertTo-OpenPathWatchdogCanonicalPath -Path $expectedActionPath
    $actionMatches = $false
    $actions = @()
    if ($task.PSObject.Properties['Actions']) {
        $actions = @($task.Actions)
    }
    elseif ($task.PSObject.Properties['Action']) {
        $actions = @($task.Action)
    }

    foreach ($action in $actions) {
        if (-not $action) { continue }
        $execute = if ($action.PSObject.Properties['Execute']) { [string]$action.Execute } else { '' }
        $arguments = if ($action.PSObject.Properties['Arguments']) {
            [string]$action.Arguments
        }
        elseif ($action.PSObject.Properties['Argument']) {
            [string]$action.Argument
        }
        else {
            ''
        }

        # This is the exact action shape emitted by New-OpenPathTaskAction.
        # Anchoring the expression is important: a string such as
        # `-Command "... -File C:\attacker\..."` is not a -File action.
        $canonicalArgumentMatch = [regex]::Match(
            $arguments,
            '(?is)^\s*-ExecutionPolicy\s+Bypass\s+-WindowStyle\s+Hidden\s+-File\s+(?:"(?<quoted>[^"]+)"|(?<bare>\S+))\s*$'
        )
        $candidate = if ($canonicalArgumentMatch.Success) {
            if ($canonicalArgumentMatch.Groups['quoted'].Success) {
                $canonicalArgumentMatch.Groups['quoted'].Value
            }
            else {
                $canonicalArgumentMatch.Groups['bare'].Value
            }
        }
        else {
            ''
        }

        $actionPath = if ($candidate) { $candidate } else { $actionPath }
        $executeCanonical = ConvertTo-OpenPathWatchdogCanonicalPath -Path $execute
        $trustedExecutables = @('powershell.exe')
        $systemRoots = @(
            [Environment]::GetEnvironmentVariable('SystemRoot'),
            [Environment]::GetEnvironmentVariable('WINDIR')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
        foreach ($systemRoot in $systemRoots) {
            $trustedExecutables += @(
                "$(([string]$systemRoot).TrimEnd('\'))\System32\WindowsPowerShell\v1.0\powershell.exe",
                "$(([string]$systemRoot).TrimEnd('\'))\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
            )
        }
        $trustedExecutable = $false
        foreach ($trustedExecutablePath in @($trustedExecutables)) {
            if ($executeCanonical -eq (ConvertTo-OpenPathWatchdogCanonicalPath -Path $trustedExecutablePath)) {
                $trustedExecutable = $true
                break
            }
        }
        if ($trustedExecutable -and $canonicalArgumentMatch.Success -and
            (ConvertTo-OpenPathWatchdogCanonicalPath -Path $candidate) -eq $expectedCanonicalPath) {
            $actionMatches = $true
            break
        }
    }
    if ($actions.Count -ne 1) {
        $actionMatches = $false
    }
    if (-not $actionMatches) {
        & $addReasonCode 'watchdog_task_not_runnable'
    }

    $principalValid = $false
    if ($task.PSObject.Properties['Principal'] -and $task.Principal) {
        $userId = if ($task.Principal.PSObject.Properties['UserId']) { [string]$task.Principal.UserId } else { '' }
        $runLevel = if ($task.Principal.PSObject.Properties['RunLevel']) { [string]$task.Principal.RunLevel } else { '' }
        $normalizedUserId = $userId.Trim().ToUpperInvariant()
        $principalValid = ($normalizedUserId -in @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')) -and
            $runLevel.Trim().ToLowerInvariant() -eq 'highest'
    }
    if (-not $principalValid) {
        & $addReasonCode 'watchdog_task_not_runnable'
    }

    $recurringTriggerValid = $false
    $triggers = @()
    if ($task.PSObject.Properties['Triggers']) {
        $triggers = @($task.Triggers)
    }
    elseif ($task.PSObject.Properties['Trigger']) {
        $triggers = @($task.Trigger)
    }
    foreach ($trigger in $triggers) {
        if (-not $trigger) { continue }
        if (-not $trigger.PSObject.Properties['Enabled'] -or -not [bool]$trigger.Enabled) { continue }
        $interval = $null
        if ($trigger.PSObject.Properties['Repetition'] -and $trigger.Repetition) {
            if ($trigger.Repetition.PSObject.Properties['Interval']) {
                $interval = $trigger.Repetition.Interval
            }
        }
        if ($null -eq $interval -and $trigger.PSObject.Properties['RepetitionInterval']) {
            $interval = $trigger.RepetitionInterval
        }
        if ($null -eq $interval -or [string]::IsNullOrWhiteSpace([string]$interval)) { continue }
        try {
            $duration = if ($interval -is [TimeSpan]) { $interval } else { [System.Xml.XmlConvert]::ToTimeSpan([string]$interval) }
            if ($duration -gt [TimeSpan]::Zero) {
                $recurringTriggerValid = $true
            }
        }
        catch {
            try {
                if ([TimeSpan]::Parse([string]$interval, [System.Globalization.CultureInfo]::InvariantCulture) -gt [TimeSpan]::Zero) {
                    $recurringTriggerValid = $true
                }
            }
            catch {}
        }
        if (-not $recurringTriggerValid) { continue }

        $endBoundary = if ($trigger.PSObject.Properties['EndBoundary']) { [string]$trigger.EndBoundary } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($endBoundary)) {
            try {
                $parsedEndBoundary = [DateTimeOffset]::Parse($endBoundary, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                if ($parsedEndBoundary -le [DateTimeOffset]::UtcNow) {
                    $recurringTriggerValid = $false
                }
            }
            catch {
                $recurringTriggerValid = $false
            }
        }
        if ($recurringTriggerValid) { break }
    }
    if (-not $recurringTriggerValid) {
        & $addReasonCode 'watchdog_task_not_runnable'
    }

    $runnable = $scriptExists -and $actionMatches -and $principalValid -and $recurringTriggerValid -and $enabled -and $state -in @('Ready', 'Running')
    [PSCustomObject][ordered]@{
        Healthy = ($reasonCodes.Count -eq 0)
        ReasonCodes = @($reasonCodes.ToArray())
        Present = $present
        Enabled = $enabled
        Runnable = $runnable
        State = $state
        ActionPath = $actionPath
        ExpectedActionPath = $expectedActionPath
    }
}

function Invoke-OpenPathWatchdogPrechecks {
    # runs before every main watchdog cycle
    # probes the captive portal state and decides whether to enter, refresh, or exit portal mode
    # returns a summary of the current portal observation for use by the caller
    param(
        [AllowNull()]
        [PSCustomObject]$Config
    )

    $enableNonAdminAppControl = $true
    if ($Config -and $Config.PSObject.Properties['enableNonAdminAppControl']) {
        $enableNonAdminAppControl = [bool]$Config.enableNonAdminAppControl
    }

    $groupSyncFailed = $false
    if ($enableNonAdminAppControl -and -not (Get-Command -Name 'Sync-OpenPathRestrictedGroup' -ErrorAction SilentlyContinue)) {
        $groupSyncFailed = $true
        Write-OpenPathLog 'Watchdog: OpenPath-Restricted group sync command unavailable' -Level WARN
    }
    elseif ($enableNonAdminAppControl -and (Get-Command -Name 'Sync-OpenPathRestrictedGroup' -ErrorAction SilentlyContinue)) {
        try {
            $groupSynced = [bool](Sync-OpenPathRestrictedGroup -CreateIfMissing $true)
            if (-not $groupSynced) {
                $groupSyncFailed = $true
                Write-OpenPathLog "Watchdog: OpenPath-Restricted group sync failed" -Level WARN
            }
        }
        catch {
            $groupSyncFailed = $true
            Write-OpenPathLog "Watchdog: OpenPath-Restricted group sync failed: $_" -Level WARN
        }
    }

    $portalModeActive = Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore
    $captiveState = 'NoNetwork'
    try {
        $captiveState = Test-OpenPathCaptivePortalState -TimeoutSec 3
    }
    catch {
        $captiveState = 'NoNetwork'
    }

    $portalObservation = Update-OpenPathCaptivePortalObservation -DetectedState $captiveState
    $activeMarker = if ($portalModeActive) { Get-OpenPathCaptivePortalMarker } else { $null }
    $markerMode = Get-OpenPathCaptivePortalMarkerMode -Marker $activeMarker
    $captivityOutcome = Get-OpenPathWatchdogCaptivePortalPolicyOutcome `
        -PortalModeActive $portalModeActive `
        -MarkerPresent ($null -ne $activeMarker) `
        -MarkerMode $markerMode `
        -CaptiveState $captiveState `
        -ShouldEnterPortal ([bool]$portalObservation.ShouldEnterPortal) `
        -ShouldExitPortal ([bool]$portalObservation.ShouldExitPortal)

    $splitDnsActive = $false
    if (Get-Command -Name 'Test-OpenPathSplitDnsActive' -ErrorAction SilentlyContinue) {
        try { $splitDnsActive = [bool](Test-OpenPathSplitDnsActive) }
        catch { $splitDnsActive = $false }
    }

    if ($splitDnsActive -and $captivityOutcome -eq 'keepLimited') {
        # Stage C2: permanent split DNS already resolves the declared portal
        # domains in protected mode, so autonomous entry into the legacy
        # limited/passthrough lifecycle is redundant (and was the source of the
        # post-auth "stuck unrestricted navigation" bug). Do NOT enter portal
        # mode. If a legacy marker is somehow still active, close it so split DNS
        # owns the portal -- the drift refresh in Invoke-OpenPathWatchdogChecks
        # keeps the third upstream applied.
        if ($portalModeActive) {
            $disabled = [bool](Disable-OpenPathCaptivePortalMode -Config $Config)
            if (-not $disabled) {
                Write-OpenPathLog 'Watchdog: split DNS active; failed to close a legacy captive portal marker' -Level WARN
            }
        }
        else {
            Write-OpenPathLog 'Watchdog: split DNS active; not entering captive portal mode (declared domains resolve in protected mode)'
        }
    }
    elseif ($captivityOutcome -eq 'closeAuthenticated') {
        $disabled = [bool](Disable-OpenPathCaptivePortalMode -Config $Config)
        if (-not $disabled) {
            Write-OpenPathLog 'Watchdog: failed to close authenticated captive portal mode; marker preserved' -Level WARN
        }
    }
    elseif ($captivityOutcome -eq 'keepLimited' -and $portalModeActive -and $markerMode -eq 'limited' -and $captiveState -eq 'Portal') {
        $portalRecoveryHosts = @()
        if ($activeMarker -and $activeMarker.PSObject.Properties['allowedHosts']) {
            $portalRecoveryHosts = @($activeMarker.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if ($portalRecoveryHosts.Count -gt 0) {
            Enable-OpenPathCaptivePortalMode -State $captiveState -PortalRecoveryDomains $portalRecoveryHosts | Out-Null
        }
    }
    elseif ($captivityOutcome -eq 'keepLimited') {
        Enable-OpenPathCaptivePortalMode -State $captiveState | Out-Null
    }
    elseif ($captivityOutcome -eq 'restoreProtected') {
        $disabled = [bool](Disable-OpenPathCaptivePortalMode -Config $Config)
        if (-not $disabled) {
            Write-OpenPathLog 'Watchdog: failed to close authenticated captive portal mode; marker preserved' -Level WARN
        }
    }
    elseif ($captivityOutcome -eq 'unsafeMarker') {
        Write-OpenPathLog 'Watchdog: captive portal mode is active without a readable marker; leaving protected-mode state unchanged' -Level WARN
    }
    elseif ($captivityOutcome -eq 'noAction' -and $portalModeActive -and (Test-OpenPathCaptivePortalMarkerExpired -Marker $activeMarker)) {
        # The per-cycle reads above intentionally use -SkipExpiredRestore (a state
        # read must not have side effects), so without this branch an expired
        # marker would sit in limbo until a native-host request or the update
        # runtime happened to run. Disable is gated by local-posture evidence and
        # is safe to retry every cycle.
        $disabled = [bool](Disable-OpenPathCaptivePortalMode -Config $Config)
        if (-not $disabled) {
            Write-OpenPathLog 'Watchdog: failed to close expired captive portal marker; marker preserved' -Level WARN
        }
    }

    return [PSCustomObject]@{
        PortalModeActive = (Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore)
        CaptiveState = $captiveState
        PortalSince = $portalObservation.PortalSince
        PortalAgeSeconds = $portalObservation.PortalAgeSeconds
        AuthenticatedCount = $portalObservation.AuthenticatedCount
        MinimumPortalElapsed = $portalObservation.MinimumPortalElapsed
        ShouldExitPortal = $portalObservation.ShouldExitPortal
        GroupSyncFailed = $groupSyncFailed
    }
}

function Test-OpenPathAdapterDnsLoopbackPrimary {
    # returns true only when 127.0.0.1 (the local Acrylic proxy) is the PRIMARY IPv4 DNS
    # server. A loopback entry sitting behind another resolver (e.g. '8.8.8.8','127.0.0.1')
    # lets Windows prefer the non-loopback server and bypass the filter, so it is not primary.
    [CmdletBinding()]
    param([string[]]$ServerAddresses = @())

    $servers = @($ServerAddresses | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($servers.Count -eq 0) { return $false }
    return ($servers[0] -eq '127.0.0.1')
}

function Get-OpenPathActiveIpv4AdaptersMissingLocalDns {
    # returns a list of active ipv4 adapters whose primary ipv4 dns server is not 127.0.0.1
    # used to detect adapters that bypass or deprioritize the local acrylic proxy
    [CmdletBinding()]
    param()

    $activeAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    $missingAdapters = @()

    foreach ($adapter in $activeAdapters) {
        $interfaceIndex = if ($adapter.PSObject.Properties['ifIndex']) { $adapter.ifIndex } else { $adapter.InterfaceIndex }
        if ($null -eq $interfaceIndex) {
            continue
        }

        $address = Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue
        $serverAddresses = @()
        foreach ($entry in @($address)) {
            $serverAddresses += @($entry.ServerAddresses)
        }

        if (-not (Test-OpenPathAdapterDnsLoopbackPrimary -ServerAddresses $serverAddresses)) {
            $missingAdapters += [PSCustomObject]@{
                Name = [string]$adapter.Name
                InterfaceIndex = $interfaceIndex
            }
        }
    }

    return @($missingAdapters)
}

function Invoke-OpenPathCaptivePortalPassthroughEmergencyChecks {
    # runs every cycle regardless of whether protected-mode checks are skipped
    # when portal mode is active in passthrough, verifies that local dns is still configured
    # closes passthrough automatically when the emergency policy outcome requires it
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [bool]$PortalModeActive,

        [string]$CaptiveState = 'Unknown'
    )

    $issues = @()
    if (-not $PortalModeActive) {
        return [PSCustomObject]@{
            Issues = @()
            MarkerMode = ''
            LocalDnsConfigured = $null
        }
    }

    $marker = Get-OpenPathCaptivePortalMarker
    if (-not $marker) {
        return [PSCustomObject]@{
            Issues = @('Captive portal marker missing while portal mode is active')
            MarkerMode = ''
            LocalDnsConfigured = $null
        }
    }

    $markerMode = Get-OpenPathCaptivePortalMarkerMode -Marker $marker
    if ($markerMode -ne 'passthrough') {
        return [PSCustomObject]@{
            Issues = @()
            MarkerMode = $markerMode
            LocalDnsConfigured = $null
        }
    }

    $adaptersMissingLocalDns = @(Get-OpenPathActiveIpv4AdaptersMissingLocalDns)
    $localDnsConfigured = ($adaptersMissingLocalDns.Count -eq 0)
    $passthroughOutcome = Get-OpenPathWatchdogCaptivePortalPolicyOutcome `
        -PortalModeActive $PortalModeActive `
        -MarkerPresent $true `
        -MarkerMode $markerMode `
        -CaptiveState $CaptiveState `
        -PassthroughLocalDnsConfigured $localDnsConfigured
    if ($passthroughOutcome -eq 'emergencyPassthrough') {
        $disabled = [bool](Disable-OpenPathCaptivePortalMode -Config $Config)
        if (-not $disabled) {
            Write-OpenPathLog 'Watchdog: failed to close authenticated captive portal mode; marker preserved' -Level WARN
        }
    }

    return [PSCustomObject]@{
        Issues = @($issues)
        MarkerMode = $markerMode
        LocalDnsConfigured = $localDnsConfigured
    }
}

function Invoke-OpenPathWatchdogAppControlHealth {
    <#
        Runs the AppControl/group observation and repair transaction. Findings
        remain local until the final post-repair observation is selected so a
        stale initial reason code cannot make a verified repair look unhealthy.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [bool]$GroupSyncFailed = $false
    )

    if (-not $Config) {
        return [pscustomobject]@{
            Healthy = $false
            ReasonCodes = @('configuration_unavailable')
            Issues = @('Configuration unavailable for AppControl checks')
            RecoveryEligibleIssues = @()
        }
    }
    if ($Config.PSObject.Properties['enableNonAdminAppControl'] -and -not [bool]$Config.enableNonAdminAppControl) {
        return [pscustomobject]@{
            Healthy = $true
            ReasonCodes = @()
            Issues = @()
            RecoveryEligibleIssues = @()
        }
    }

    $issues = [System.Collections.Generic.List[string]]::new()
    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    $recoveryEligibleIssues = [System.Collections.Generic.List[string]]::new()
    $addCode = {
        param([string]$Code)
        if (-not [string]::IsNullOrWhiteSpace($Code) -and -not $reasonCodes.Contains($Code)) {
            [void]$reasonCodes.Add($Code)
        }
    }
    $addIssue = {
        param([string]$Issue)
        if (-not [string]::IsNullOrWhiteSpace($Issue) -and -not $issues.Contains($Issue)) {
            [void]$issues.Add($Issue)
        }
    }
    $addRecoveryIssue = {
        param([string]$Issue)
        if (-not [string]::IsNullOrWhiteSpace($Issue) -and -not $recoveryEligibleIssues.Contains($Issue)) {
            [void]$recoveryEligibleIssues.Add($Issue)
        }
    }
    $reasonToIssue = @{
        appcontrol_capability_unavailable = 'AppControl capability unavailable'
        appcontrol_restricted_target_missing = 'OpenPath-Restricted target is missing'
        appcontrol_appidsvc_not_running = 'AppIDSvc is not running'
        appcontrol_local_policy_absent = 'AppControl local policy is absent'
        appcontrol_local_policy_invalid = 'AppControl local policy is invalid'
        appcontrol_effective_policy_absent = 'AppControl effective policy is absent'
        appcontrol_effective_policy_invalid = 'AppControl effective policy invalid'
        appcontrol_runtime_evaluation_unavailable = 'AppControl runtime evaluation unavailable'
        appcontrol_runtime_evaluation_failed = 'AppControl runtime evaluation failed'
        appcontrol_runtime_arbitrary_exe_allowed = 'AppControl arbitrary executable is allowed'
        appcontrol_runtime_edge_allowed = 'AppControl Edge executable is allowed'
        appcontrol_runtime_firefox_not_allowed = 'AppControl Firefox executable is not allowed'
        appcontrol_probe_cleanup_failed = 'AppControl probe cleanup failed'
        appcontrol_health_check_unavailable = 'AppControl structured health check unavailable'
    }
    $addHealthObservation = {
        param([string[]]$Codes)
        foreach ($code in @($Codes)) {
            & $addCode ([string]$code)
            if ($reasonToIssue.ContainsKey([string]$code)) {
                & $addIssue $reasonToIssue[[string]$code]
            }
        }
    }

    $groupReconciliationFailed = [bool]$GroupSyncFailed
    $groupExists = $false
    $syncAvailable = [bool](Get-Command -Name 'Sync-OpenPathRestrictedGroup' -ErrorAction SilentlyContinue)
    if (-not $syncAvailable -or $GroupSyncFailed) {
        $groupReconciliationFailed = $true
        & $addCode 'appcontrol_group_sync_failed'
        & $addIssue 'OpenPath-Restricted group membership reconciliation failed'
        & $addRecoveryIssue 'OpenPath-Restricted group membership reconciliation failed'
    }

    if (Get-Command -Name 'Get-LocalGroup' -ErrorAction SilentlyContinue) {
        try {
            $null = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
            $groupExists = $true
        }
        catch {
            Write-OpenPathLog 'Watchdog: Required OpenPath-Restricted group missing; attempting recreation' -Level WARN
            $recreated = $false
            if ($syncAvailable) {
                try {
                    $recreated = [bool](Sync-OpenPathRestrictedGroup -CreateIfMissing $true)
                }
                catch {
                    $recreated = $false
                }
            }
            if ($recreated) {
                $groupExists = $true
            }
            else {
                & $addCode 'appcontrol_restricted_target_missing'
                & $addIssue 'OpenPath-Restricted local group is absent'
                & $addRecoveryIssue 'OpenPath-Restricted group missing'
                Write-OpenPathLog 'Watchdog: Failed to recreate required OpenPath-Restricted local group' -Level ERROR
            }
        }
    }
    else {
        $groupReconciliationFailed = $true
        & $addCode 'appcontrol_group_sync_failed'
        & $addIssue 'OpenPath-Restricted group membership reconciliation failed'
        & $addRecoveryIssue 'OpenPath-Restricted group membership reconciliation failed'
    }

    if ($groupExists -and $syncAvailable -and -not $GroupSyncFailed) {
        try {
            if (-not [bool](Sync-OpenPathRestrictedGroup -CreateIfMissing $false)) {
                throw 'group synchronization returned false'
            }
        }
        catch {
            $groupReconciliationFailed = $true
            & $addCode 'appcontrol_group_sync_failed'
            & $addIssue 'OpenPath-Restricted group membership reconciliation failed'
            & $addRecoveryIssue 'OpenPath-Restricted group membership reconciliation failed'
            Write-OpenPathLog 'Watchdog: OpenPath-Restricted group membership reconciliation failed' -Level ERROR
        }
    }

    $mode = 'Enforced'
    if ($Config -and $Config.PSObject.Properties['nonAdminAppControlMode'] -and $Config.nonAdminAppControlMode) {
        $mode = [string]$Config.nonAdminAppControlMode
    }
    $approvedStudentBrowsers = @('Firefox')
    if ($Config -and $Config.PSObject.Properties['approvedStudentBrowsers'] -and $Config.approvedStudentBrowsers) {
        $approvedStudentBrowsers = @($Config.approvedStudentBrowsers)
    }

    $healthCommandAvailable = [bool](Get-Command -Name 'Get-OpenPathNonAdminAppControlHealth' -ErrorAction SilentlyContinue)
    $initialHealthHealthy = $false
    $initialHealthCodes = @()
    if ($healthCommandAvailable) {
        try {
            $initialHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedStudentBrowsers
            if (-not $initialHealth -or -not $initialHealth.PSObject.Properties['Healthy']) {
                throw 'structured AppControl health result is invalid'
            }
            $initialHealthHealthy = [bool]$initialHealth.Healthy
            if ($initialHealth.PSObject.Properties['ReasonCodes']) {
                $initialHealthCodes = @($initialHealth.ReasonCodes | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
            if (-not $initialHealthHealthy -and $initialHealthCodes.Count -eq 0) {
                $initialHealthCodes = @('appcontrol_health_check_unavailable')
            }
        }
        catch {
            $healthCommandAvailable = $false
            $initialHealthCodes = @('appcontrol_health_check_unavailable')
            Write-OpenPathLog 'Watchdog: structured AppControl health check unavailable' -Level WARN
        }
    }
    else {
        $initialHealthCodes = @('appcontrol_health_check_unavailable')
        Write-OpenPathLog 'Watchdog: structured AppControl health check unavailable' -Level WARN
    }
    & $addHealthObservation $initialHealthCodes

    $commitState = if ($Config -and $Config.PSObject.Properties['appControlCommitState']) { [string]$Config.appControlCommitState } else { '' }
    $uncommittedState = $commitState -ne 'committed'
    if ($uncommittedState) {
        & $addCode 'appcontrol_uncommitted'
        if ([string]::IsNullOrWhiteSpace($commitState)) {
            & $addIssue 'AppControl commit state is uncommitted'
        }
        else {
            & $addIssue "AppControl commit state is uncommitted ($commitState)"
        }
        & $addRecoveryIssue 'AppControl uncommitted'
        Write-OpenPathLog 'Watchdog: AppControl commit state is not durably committed' -Level WARN
    }

    $initialBoundaryHealthy = [bool]($healthCommandAvailable -and $initialHealthHealthy -and $initialHealthCodes.Count -eq 0)
    $needsRepair = -not $initialBoundaryHealthy
    $postRepairHealthy = $false
    if ($needsRepair) {
        Write-OpenPathLog "Watchdog: AppControl is not active or uncommitted in $mode mode; attempting repair" -Level WARN
        $repairResult = $false
        if (Get-Command -Name 'Set-OpenPathNonAdminAppControl' -ErrorAction SilentlyContinue) {
            try {
                $repairResult = [bool](Set-OpenPathNonAdminAppControl -OpenPathRoot $OpenPathRoot -Mode $mode -ApprovedBrowsers $approvedStudentBrowsers)
            }
            catch {
                $repairResult = $false
                Write-OpenPathLog 'Watchdog: Exception during AppControl repair' -Level ERROR
            }
        }

        if (-not $repairResult) {
            & $addCode 'appcontrol_repair_failed'
            & $addIssue "AppControl repair failed; policy is not active in $mode mode"
            & $addRecoveryIssue 'AppControl repair failed'
            Write-OpenPathLog "Watchdog: AppControl repair failed; effective policy is not active in $mode mode" -Level ERROR
        }
        else {
            $postRepairCodes = @()
            try {
                if (-not $healthCommandAvailable) {
                    throw 'structured AppControl health check unavailable after repair'
                }
                $postRepairHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedStudentBrowsers
                if (-not $postRepairHealth -or -not $postRepairHealth.PSObject.Properties['Healthy']) {
                    throw 'structured AppControl post-repair health result is invalid'
                }
                if ($postRepairHealth.PSObject.Properties['ReasonCodes']) {
                    $postRepairCodes = @($postRepairHealth.ReasonCodes | ForEach-Object { [string]$_ } | Where-Object { $_ })
                }
                $postRepairHealthy = [bool]($postRepairHealth.Healthy -and $postRepairCodes.Count -eq 0)
            }
            catch {
                $postRepairHealthy = $false
                $postRepairCodes = @('appcontrol_health_check_unavailable')
            }

            # A successful repair changes the authoritative observation. Clear
            # the initial AppControl findings as a collection, then retain only
            # independent commit state and the post-repair result.
            $reasonCodes.Clear()
            $issues.Clear()
            $recoveryEligibleIssues.Clear()
            if ($uncommittedState) {
                & $addCode 'appcontrol_uncommitted'
                if ([string]::IsNullOrWhiteSpace($commitState)) {
                    & $addIssue 'AppControl commit state is uncommitted'
                }
                else {
                    & $addIssue "AppControl commit state is uncommitted ($commitState)"
                }
                & $addRecoveryIssue 'AppControl uncommitted'
            }
            if (-not $postRepairHealthy) {
                foreach ($code in @($postRepairCodes)) {
                    & $addCode $code
                    if ($reasonToIssue.ContainsKey([string]$code)) {
                        & $addIssue $reasonToIssue[[string]$code]
                    }
                }
                & $addCode 'appcontrol_repair_unverified'
                & $addIssue 'AppControl effective policy could not be verified after repair'
                & $addRecoveryIssue 'AppControl effective policy invalid'
                Write-OpenPathLog "Watchdog: AppControl repair reported success but effective policy is invalid in $mode mode" -Level ERROR
            }
            else {
                Write-OpenPathLog "Watchdog: AppControl repair verified in $mode mode"
            }
        }
    }

    $finalBoundaryHealthy = if ($needsRepair) { $postRepairHealthy } else { $initialBoundaryHealthy }
    if ($finalBoundaryHealthy -and $healthCommandAvailable -and $groupExists -and -not $groupReconciliationFailed -and $uncommittedState) {
        $configPath = if ($OpenPathRoot -match '^[A-Za-z]:\\|^\\\\') { "$($OpenPathRoot.TrimEnd('\\'))\data\config.json" } else { Join-Path $OpenPathRoot 'data\config.json' }
        $persisted = $false
        try {
            if (-not $Config -or -not (Test-Path -LiteralPath $configPath)) {
                throw 'AppControl commit config is missing'
            }
            if (-not (Get-Command -Name 'Write-OpenPathAtomicJsonFile' -ErrorAction SilentlyContinue)) {
                throw 'durable AppControl config writer is unavailable'
            }
            $currentConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if (Get-Command -Name 'Set-OpenPathConfigValue' -ErrorAction SilentlyContinue) {
                Set-OpenPathConfigValue -Config $currentConfig -Name 'appControlCommitState' -Value 'committed'
            }
            elseif ($currentConfig.PSObject.Properties['appControlCommitState']) {
                $currentConfig.appControlCommitState = 'committed'
            }
            else {
                $currentConfig | Add-Member -MemberType NoteProperty -Name 'appControlCommitState' -Value 'committed' -Force
            }
            Write-OpenPathAtomicJsonFile -Path $configPath -Data $currentConfig -Depth 10
            $persisted = $true
        }
        catch {
            Write-OpenPathLog 'Watchdog: Failed to persist AppControl commit state' -Level WARN
        }

        if ($persisted) {
            if (Get-Command -Name 'Set-OpenPathConfigValue' -ErrorAction SilentlyContinue) {
                Set-OpenPathConfigValue -Config $Config -Name 'appControlCommitState' -Value 'committed'
            }
            elseif ($Config.PSObject.Properties['appControlCommitState']) {
                $Config.appControlCommitState = 'committed'
            }
            else {
                $Config | Add-Member -MemberType NoteProperty -Name 'appControlCommitState' -Value 'committed' -Force
            }
            $reasonCodes.Clear()
            $issues.Clear()
            $recoveryEligibleIssues.Clear()
            Write-OpenPathLog 'Watchdog: AppControl converged and committed to config.json'
        }
        else {
            & $addCode 'appcontrol_commit_persist_failed'
            & $addIssue 'AppControl commit state persistence failed'
            & $addRecoveryIssue 'AppControl commit state persistence failed'
        }
    }

    # Policy repair cannot repair or erase a failed membership reconciliation.
    # Add these independent findings after selecting the final policy snapshot.
    if ($groupReconciliationFailed) {
        & $addCode 'appcontrol_group_sync_failed'
        & $addIssue 'OpenPath-Restricted group membership reconciliation failed'
        & $addRecoveryIssue 'OpenPath-Restricted group membership reconciliation failed'
    }
    if (-not $groupExists) {
        & $addCode 'appcontrol_restricted_target_missing'
        & $addIssue 'OpenPath-Restricted local group is absent'
        & $addRecoveryIssue 'OpenPath-Restricted group missing'
    }
    return [PSCustomObject]@{
        Issues = @($issues.ToArray())
        ReasonCodes = @($reasonCodes.ToArray())
        RecoveryEligibleIssues = @($recoveryEligibleIssues.ToArray())
        Healthy = [bool]($finalBoundaryHealthy -and $healthCommandAvailable -and $groupExists -and -not $groupReconciliationFailed -and $reasonCodes.Count -eq 0)
    }
}

function Invoke-OpenPathWatchdogChecks {
    # main body of the per-minute watchdog cycle
    # checks acrylic, dns resolution, sinkhole, firewall, local dns adapters, split-dns drift,
    # sse listener, integrity, firefox extension policy, and applocker app control
    # protected-mode checks are gated on the policy state so portal mode and fail-open are respected
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [bool]$PortalModeActive,

        [string]$CaptiveState = 'Unknown',

        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath,

        [bool]$GroupSyncFailed = $false
    )

    $issues = @()
    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    $addReasonCode = {
        param([string]$Code)
        if (-not [string]::IsNullOrWhiteSpace($Code) -and -not $reasonCodes.Contains($Code)) {
            [void]$reasonCodes.Add($Code)
        }
    }
    $recoveryEligibleIssues = @()
    $localWhitelistPath = Join-Path $OpenPathRoot 'data\whitelist.txt'
    $localWhitelistSections = $null
    $policyState = Get-OpenPathEndpointPolicyState -PortalModeActive:$PortalModeActive

    try {
        $watchdogTaskHealth = Get-OpenPathWatchdogTaskHealth -OpenPathRoot $OpenPathRoot
    }
    catch {
        $watchdogTaskHealth = [PSCustomObject]@{
            Healthy = $false
            ReasonCodes = @('watchdog_task_not_runnable')
            Present = $false
            Enabled = $false
            Runnable = $false
        }
    }
    foreach ($code in @($watchdogTaskHealth.ReasonCodes)) {
        & $addReasonCode ([string]$code)
        $issues += switch ([string]$code) {
            'watchdog_task_missing' { 'OpenPath-Watchdog task is missing'; break }
            'watchdog_task_disabled' { 'OpenPath-Watchdog task is disabled'; break }
            'watchdog_task_not_runnable' { 'OpenPath-Watchdog task is not runnable'; break }
            default { 'OpenPath-Watchdog task health is unavailable'; break }
        }
    }

    try {
        $localWhitelistSections = Get-OpenPathWhitelistSectionsFromFile -Path $localWhitelistPath
        $staleFailsafeCurrentlyActive = Test-Path $StaleFailsafeStatePath
        $policyState = Get-OpenPathEndpointPolicyState `
            -WhitelistSections $localWhitelistSections `
            -PortalModeActive:$PortalModeActive `
            -StaleFailsafeActive:$staleFailsafeCurrentlyActive
        if ($policyState.FailOpenActive) {
            Write-OpenPathLog "Watchdog: local fail-open whitelist marker active; skipping protected-mode DNS/firewall recovery" -Level WARN
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error reading local whitelist state: $_" -Level WARN
    }

    if ($Config -and $Config.PSObject.Properties['installState'] -and $Config.installState -in @('installing', 'failed')) {
        $issues += "Installation incomplete (state: $($Config.installState))"
        Write-OpenPathLog "Watchdog: OpenPath installation is incomplete (state: $($Config.installState))" -Level WARN
    }

    $passthroughEmergency = Invoke-OpenPathCaptivePortalPassthroughEmergencyChecks `
        -Config $Config `
        -PortalModeActive:$PortalModeActive `
        -CaptiveState $CaptiveState
    $issues += @($passthroughEmergency.Issues)

    $shouldRunProtectedModeChecks = [bool]$policyState.ProtectedModeEligible

    try {
        $acrylicService = if ($shouldRunProtectedModeChecks) { Get-Service -DisplayName "*Acrylic*" -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
        $repairPlan = New-OpenPathWatchdogProtectedModeRepairPlan `
            -PolicyState $policyState `
            -AcrylicServiceRunning:(-not $shouldRunProtectedModeChecks -or ($acrylicService -and $acrylicService.Status -eq 'Running'))
        if ($repairPlan.Actions.Count -gt 0) {
            $issues += @($repairPlan.Issues)
            $recoveryEligibleIssues += @($repairPlan.RecoveryEligibleIssues)
            Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error checking Acrylic service: $_" -Level ERROR
    }

    try {
        if ($shouldRunProtectedModeChecks -and -not (Test-DNSResolution)) {
            $repairPlan = New-OpenPathWatchdogProtectedModeRepairPlan `
                -PolicyState $policyState `
                -DnsResolutionHealthy:$false
            $issues += @($repairPlan.Issues)
            $recoveryEligibleIssues += @($repairPlan.RecoveryEligibleIssues)
            Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error checking DNS resolution: $_" -Level ERROR
    }

    try {
        if ($shouldRunProtectedModeChecks -and -not (Test-DNSSinkhole -Domain "this-should-be-blocked-test-12345.com")) {
            $repairPlan = New-OpenPathWatchdogProtectedModeRepairPlan `
                -PolicyState $policyState `
                -DnsSinkholeHealthy:$false
            $issues += @($repairPlan.Issues)
            $recoveryEligibleIssues += @($repairPlan.RecoveryEligibleIssues)
            Write-OpenPathLog "Watchdog: Sinkhole not working properly" -Level WARN
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error checking DNS sinkhole: $_" -Level ERROR
    }

    try {
        if ($shouldRunProtectedModeChecks -and -not (Test-FirewallActive)) {
            $repairPlan = New-OpenPathWatchdogProtectedModeRepairPlan `
                -PolicyState $policyState `
                -FirewallActive:$false
            $issues += @($repairPlan.Issues)
            $recoveryEligibleIssues += @($repairPlan.RecoveryEligibleIssues)
            Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error checking/reconfiguring firewall: $_" -Level ERROR
    }

    try {
        $adaptersMissingLocalDns = @(Get-OpenPathActiveIpv4AdaptersMissingLocalDns)

        if ($shouldRunProtectedModeChecks -and $adaptersMissingLocalDns.Count -gt 0) {
            $affectedAdapterNames = @($adaptersMissingLocalDns | ForEach-Object { $_.Name })
            Write-OpenPathLog "Watchdog: active IPv4 adapters missing local DNS: $($affectedAdapterNames -join ', ')" -Level WARN
            $repairPlan = New-OpenPathWatchdogProtectedModeRepairPlan `
                -PolicyState $policyState `
                -LocalDnsConfigured:$false `
                -AffectedLocalDnsAdapterNames $affectedAdapterNames
            $issues += @($repairPlan.Issues)
            $recoveryEligibleIssues += @($repairPlan.RecoveryEligibleIssues)
            Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error checking local DNS: $_" -Level ERROR
    }

    try {
        $blockBridgedAdapters = $false
        if ($Config -and $Config.PSObject.Properties['blockBridgedAdapters']) {
            $blockBridgedAdapters = [bool]$Config.blockBridgedAdapters
        }

        if ($shouldRunProtectedModeChecks -and $blockBridgedAdapters) {
            $bridgeExtraComponentIds = @()
            $bridgeAllowlist = @()
            if ($Config -and $Config.PSObject.Properties['bridgeFilterComponentIds']) {
                $bridgeExtraComponentIds = @($Config.bridgeFilterComponentIds)
            }
            if ($Config -and $Config.PSObject.Properties['bridgeFilterAllowlist']) {
                $bridgeAllowlist = @($Config.bridgeFilterAllowlist)
            }

            $adaptersWithBridgeFilters = @(Get-OpenPathAdaptersWithBridgeFilters -ExtraComponentIds $bridgeExtraComponentIds -Allowlist $bridgeAllowlist)
            if ($adaptersWithBridgeFilters.Count -gt 0) {
                $affectedBridgeAdapterNames = @($adaptersWithBridgeFilters | ForEach-Object { $_.Name })
                Write-OpenPathLog "Watchdog: bridged VM networking detected on adapters: $($affectedBridgeAdapterNames -join ', ')" -Level WARN
                $repairPlan = New-OpenPathWatchdogProtectedModeRepairPlan `
                    -PolicyState $policyState `
                    -BridgeFiltersDetected:$true `
                    -AffectedBridgeFilterAdapterNames $affectedBridgeAdapterNames
                $issues += @($repairPlan.Issues)
                $recoveryEligibleIssues += @($repairPlan.RecoveryEligibleIssues)
                Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
            }
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error checking bridged adapter filters: $_" -Level ERROR
    }

    try {
        # Roaming: when the network's DHCP resolvers change, the third/fourth
        # Acrylic upstreams that answer the declared captive-portal domains go
        # stale. The INI is the persisted state; refresh it from the current
        # network. Skipped while portal mode is active (ProtectedModeEligible
        # gates it) and when the local whitelist could not be read -- a refresh
        # must never render from an unknown whitelist.
        if ($shouldRunProtectedModeChecks -and
            $null -ne $localWhitelistSections -and
            -not $localWhitelistSections.IsDisabled -and
            (Get-Command -Name 'Test-OpenPathSplitDnsTopologyDrift' -ErrorAction SilentlyContinue)) {
            $splitDnsDrift = Test-OpenPathSplitDnsTopologyDrift
            if ([bool]$splitDnsDrift.Drifted) {
                Write-OpenPathLog "Watchdog: split-DNS portal upstreams drifted ($($splitDnsDrift.Reason)); refreshing Acrylic topology" -Level WARN
                if (Update-AcrylicHost -WhitelistedDomains @($localWhitelistSections.Whitelist) -BlockedSubdomains @($localWhitelistSections.BlockedSubdomains)) {
                    Restart-AcrylicService | Out-Null
                    $enableFirewallForSplitDns = $true
                    if ($Config -and $Config.PSObject.Properties['enableFirewall']) {
                        $enableFirewallForSplitDns = [bool]$Config.enableFirewall
                    }
                    if ($enableFirewallForSplitDns) {
                        $splitDnsUpstream = '8.8.8.8'
                        if ($Config -and $Config.PSObject.Properties['primaryDNS'] -and $Config.primaryDNS) {
                            $splitDnsUpstream = [string]$Config.primaryDNS
                        }
                        $acrylicPathForSplitDns = Get-AcrylicPath
                        if ($acrylicPathForSplitDns) {
                            Set-OpenPathFirewall -UpstreamDNS $splitDnsUpstream -AcrylicPath $acrylicPathForSplitDns | Out-Null
                        }
                    }
                }
                else {
                    Write-OpenPathLog 'Watchdog: split-DNS topology refresh failed to rewrite Acrylic configuration' -Level WARN
                }
            }
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error refreshing split-DNS topology: $_" -Level ERROR
    }

    try {
        # W-1(b): outbound egress floor refresh. CDN IPs behind whitelisted domains
        # rotate, so a static per-IP allow set goes stale and starts blocking legit
        # whitelisted sites. When the floor is enabled in config, re-resolve the
        # whitelist through Acrylic and, only when the allow-IP set drifts, re-apply.
        # DEFAULT OFF: the config flag stays $false until WEDU-lab validation, so this
        # block is normally a no-op. Gated on the same protected-mode/whitelist-readable
        # conditions as the split-DNS refresh: never refresh from an unknown whitelist,
        # and the apply path fails open on an empty resolution (never bricks HTTPS).
        $egressFloorEnabled = $false
        if ($Config -and $Config.PSObject.Properties['outboundEgressFloorEnabled']) {
            $egressFloorEnabled = [bool]$Config.outboundEgressFloorEnabled
        }
        if ($egressFloorEnabled -and
            $shouldRunProtectedModeChecks -and
            $null -ne $localWhitelistSections -and
            -not $localWhitelistSections.IsDisabled -and
            (Get-Command -Name 'Test-OpenPathEgressFloorDrift' -ErrorAction SilentlyContinue)) {
            $egressStaticAllowIps = @()
            if ($Config.PSObject.Properties['outboundEgressFloorAllowIps'] -and $Config.outboundEgressFloorAllowIps) {
                $egressStaticAllowIps = @($Config.outboundEgressFloorAllowIps | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
            }
            $egressFloorDrift = Test-OpenPathEgressFloorDrift -StaticAllowIps $egressStaticAllowIps
            if ([bool]$egressFloorDrift.Drifted) {
                Write-OpenPathLog "Watchdog: egress-floor allow IPs drifted ($($egressFloorDrift.Reason)); refreshing floor" -Level WARN
                $egressFloorSystemPrograms = @()
                if ($Config.PSObject.Properties['outboundEgressFloorSystemPrograms'] -and $Config.outboundEgressFloorSystemPrograms) {
                    $egressFloorSystemPrograms = @($Config.outboundEgressFloorSystemPrograms | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
                }
                $acrylicPathForEgress = Get-AcrylicPath
                Update-OpenPathEgressFloor `
                    -StaticAllowIps $egressStaticAllowIps `
                    -SystemServicePrograms $egressFloorSystemPrograms `
                    -AcrylicPath $acrylicPathForEgress | Out-Null
            }
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error refreshing outbound egress floor: $_" -Level ERROR
    }

    try {
        $sseTask = Get-ScheduledTask -TaskName "OpenPath-SSE" -ErrorAction SilentlyContinue
        if ($sseTask -and $sseTask.State -ne 'Running') {
            $issues += "SSE listener not running"
            Write-OpenPathLog "Watchdog: SSE listener not running, restarting..." -Level WARN
            Start-ScheduledTask -TaskName "OpenPath-SSE" -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Error checking SSE listener: $_" -Level ERROR
    }

    $staleFailsafeActive = $false
    if (Test-Path $StaleFailsafeStatePath) {
        $staleFailsafeActive = $true
        Write-OpenPathLog "Watchdog: stale whitelist fail-safe mode is currently active" -Level WARN
    }

    $integrityTampered = $false
    try {
        $integrityChecksEnabled = $true
        if ($Config -and $Config.PSObject.Properties['enableIntegrityChecks']) {
            $integrityChecksEnabled = [bool]$Config.enableIntegrityChecks
        }

        if ($integrityChecksEnabled) {
            $integrityResult = Test-OpenPathIntegrity

            if (-not $integrityResult.BaselinePresent) {
                Write-OpenPathLog "Watchdog: Integrity baseline missing, creating baseline" -Level WARN
                Save-OpenPathIntegrityBackup | Out-Null
                New-OpenPathIntegrityBaseline | Out-Null
            }
            elseif (-not $integrityResult.Healthy) {
                Write-OpenPathLog "Watchdog: Integrity mismatch detected, attempting restore" -Level WARN
                $restoreResult = Restore-OpenPathIntegrity -IntegrityResult $integrityResult
                if (-not $restoreResult.Healthy) {
                    $integrityTampered = $true
                    $issues += "Integrity tampering detected"
                    Write-OpenPathLog "Watchdog: Integrity restore incomplete" -Level ERROR
                }
                else {
                    Write-OpenPathLog "Watchdog: Integrity restored from backup" -Level WARN
                }
            }
        }
    }
    catch {
        $issues += "Integrity check error"
        Write-OpenPathLog "Watchdog: Error during integrity checks: $_" -Level ERROR
    }

    try {
        if (Sync-OpenPathFirefoxManagedExtensionPolicy) {
            Write-OpenPathLog "Watchdog: refreshed Firefox managed extension policy"
        }
        if (Get-Command -Name 'Sync-OpenPathFirefoxNetworkAutoconfig' -ErrorAction SilentlyContinue) {
            Sync-OpenPathFirefoxNetworkAutoconfig | Out-Null
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: Firefox managed extension policy refresh failed: $_" -Level WARN
    }

    try {
        $appControlResult = Invoke-OpenPathWatchdogAppControlHealth `
            -Config $Config `
            -OpenPathRoot $OpenPathRoot `
            -GroupSyncFailed:$GroupSyncFailed
        $issues += @($appControlResult.Issues)
        $recoveryEligibleIssues += @($appControlResult.RecoveryEligibleIssues)
        foreach ($code in @($appControlResult.ReasonCodes)) {
            & $addReasonCode ([string]$code)
        }
    }
    catch {
        & $addReasonCode 'appcontrol_health_check_unavailable'
        $issues += 'AppControl watchdog check failed'
        $recoveryEligibleIssues += 'AppControl watchdog check failed'
        Write-OpenPathLog 'Watchdog: AppLocker non-admin app control refresh failed' -Level ERROR
    }

    return [PSCustomObject]@{
        Issues = @($issues)
        ReasonCodes = @($reasonCodes.ToArray())
        RecoveryEligibleIssues = @($recoveryEligibleIssues)
        StaleFailsafeActive = $staleFailsafeActive
        IntegrityTampered = $integrityTampered
        FailOpenActive = [bool]$policyState.FailOpenActive
    }
}

function Get-OpenPathWatchdogOutcome {
    # combines the issues from the cycle into a status string and a fail-count decision
    # promotes degraded to critical after three consecutive recovery-eligible failures
    # triggers checkpoint rollback at critical and resets the counter on success
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Issues,

        [AllowEmptyCollection()]
        [string[]]$ReasonCodes = @(),

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RecoveryEligibleIssues,

        [Parameter(Mandatory = $true)]
        [bool]$StaleFailsafeActive,

        [Parameter(Mandatory = $true)]
        [bool]$IntegrityTampered,

        [Parameter(Mandatory = $true)]
        [bool]$FailOpenActive,

        [Parameter(Mandatory = $true)]
        [bool]$PortalModeActive,

        [Parameter(Mandatory = $true)]
        [string]$WatchdogFailCountPath,

        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot
    )

    $reasonCodesList = [System.Collections.Generic.List[string]]::new()
    foreach ($code in @($ReasonCodes)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$code) -and -not $reasonCodesList.Contains([string]$code)) {
            [void]$reasonCodesList.Add([string]$code)
        }
    }

    $status = 'HEALTHY'
    if ($FailOpenActive) {
        $status = 'FAIL_OPEN'
    }
    elseif ($IntegrityTampered) {
        $status = 'TAMPERED'
    }
    elseif ($StaleFailsafeActive) {
        $status = 'STALE_FAILSAFE'
    }
    elseif ($Issues.Count -gt 0 -or $reasonCodesList.Count -gt 0) {
        $status = 'DEGRADED'
    }

    $watchdogFailCount = 0
    $shouldIncrementFailCount = $status -eq 'DEGRADED' -and $RecoveryEligibleIssues.Count -gt 0
    if (
        $status -eq 'HEALTHY' -or
        $status -eq 'FAIL_OPEN' -or
        $status -eq 'STALE_FAILSAFE' -or
        ($PortalModeActive -and $status -eq 'DEGRADED') -or
        (-not $shouldIncrementFailCount)
    ) {
        Reset-WatchdogFailCount -WatchdogFailCountPath $WatchdogFailCountPath
    }
    else {
        $watchdogFailCount = Increment-WatchdogFailCount -WatchdogFailCountPath $WatchdogFailCountPath
        if ($status -eq 'DEGRADED' -and $watchdogFailCount -ge 3) {
            $status = 'CRITICAL'
        }
    }

    $issuesList = @($Issues)
    $checkpointRecovered = $false
    if ($status -eq 'CRITICAL' -and $Config) {
        $checkpointRollbackEnabled = $true
        if ($Config.PSObject.Properties['enableCheckpointRollback']) {
            $checkpointRollbackEnabled = [bool]$Config.enableCheckpointRollback
        }

        if ($checkpointRollbackEnabled) {
            Write-OpenPathLog "Watchdog: CRITICAL state reached, attempting checkpoint recovery" -Level WARN
            if (Restore-CheckpointFromWatchdog -Config $Config -OpenPathRoot $OpenPathRoot) {
                $checkpointRecovered = $true
                $status = 'DEGRADED'
                $watchdogFailCount = 0
                Reset-WatchdogFailCount -WatchdogFailCountPath $WatchdogFailCountPath
                $issuesList += "Checkpoint rollback restored DNS state"
            }
            else {
                $issuesList += "Checkpoint rollback failed"
            }
        }
    }

    $actions = if ($issuesList.Count -gt 0) {
        ($issuesList | Sort-Object -Unique) -join '; '
    }
    else {
        'watchdog_ok'
    }

    if ($StaleFailsafeActive) {
        $actions = if ($actions -eq 'watchdog_ok') { 'stale_failsafe_active' } else { "$actions; stale_failsafe_active" }
    }

    if ($IntegrityTampered) {
        $actions = if ($actions -eq 'watchdog_ok') { 'integrity_tampered' } else { "$actions; integrity_tampered" }
    }

    if ($FailOpenActive) {
        $actions = if ($actions -eq 'watchdog_ok') { 'fail_open_active' } else { "$actions; fail_open_active" }
    }

    if ($checkpointRecovered) {
        $actions = if ($actions -eq 'watchdog_ok') { 'checkpoint_recovery_applied' } else { "$actions; checkpoint_recovery_applied" }
    }

    return [PSCustomObject]@{
        Status = $status
        WatchdogFailCount = $watchdogFailCount
        Actions = $actions
        ReasonCodes = @($reasonCodesList.ToArray())
    }
}
