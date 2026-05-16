function Restore-CheckpointFromWatchdog {
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

function Invoke-OpenPathWatchdogPrechecks {
    param(
        [AllowNull()]
        [PSCustomObject]$Config
    )

    $portalModeActive = Test-OpenPathCaptivePortalModeActive
    $captiveState = 'NoNetwork'
    try {
        $captiveState = Test-OpenPathCaptivePortalState -TimeoutSec 3
    }
    catch {
        $captiveState = 'NoNetwork'
    }

    $portalObservation = Update-OpenPathCaptivePortalObservation -DetectedState $captiveState

    if ($portalObservation.ShouldEnterPortal) {
        Enable-OpenPathCaptivePortalMode -State $captiveState | Out-Null
    }
    elseif ($portalObservation.ShouldExitPortal -and $portalModeActive) {
        Disable-OpenPathCaptivePortalMode -Config $Config | Out-Null
    }

    return [PSCustomObject]@{
        PortalModeActive = (Test-OpenPathCaptivePortalModeActive)
        CaptiveState = $captiveState
    }
}

function Get-OpenPathActiveIpv4AdaptersMissingLocalDns {
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

        if ($serverAddresses -notcontains '127.0.0.1') {
            $missingAdapters += [PSCustomObject]@{
                Name = [string]$adapter.Name
                InterfaceIndex = $interfaceIndex
            }
        }
    }

    return @($missingAdapters)
}

function Invoke-OpenPathWatchdogChecks {
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [bool]$PortalModeActive,

        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath
    )

    $issues = @()
    $recoveryEligibleIssues = @()
    $localWhitelistPath = Join-Path $OpenPathRoot 'data\whitelist.txt'
    $localWhitelistSections = $null
    $policyState = Get-OpenPathEndpointPolicyState -PortalModeActive:$PortalModeActive

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
        if (Get-Command -Name 'Test-OpenPathNonAdminAppControlActive' -ErrorAction SilentlyContinue) {
            $enableNonAdminAppControl = $true
            if ($Config -and $Config.PSObject.Properties['enableNonAdminAppControl']) {
                $enableNonAdminAppControl = [bool]$Config.enableNonAdminAppControl
            }
            if ($enableNonAdminAppControl -and -not (Test-OpenPathNonAdminAppControlActive)) {
                $mode = 'Enforced'
                if ($Config -and $Config.PSObject.Properties['nonAdminAppControlMode'] -and $Config.nonAdminAppControlMode) {
                    $mode = [string]$Config.nonAdminAppControlMode
                }
                Set-OpenPathNonAdminAppControl -OpenPathRoot $OpenPathRoot -Mode $mode | Out-Null
            }
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: AppLocker non-admin app control refresh failed: $_" -Level WARN
    }

    return [PSCustomObject]@{
        Issues = @($issues)
        RecoveryEligibleIssues = @($recoveryEligibleIssues)
        StaleFailsafeActive = $staleFailsafeActive
        IntegrityTampered = $integrityTampered
        FailOpenActive = [bool]$policyState.FailOpenActive
    }
}

function Get-OpenPathWatchdogOutcome {
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string[]]$Issues,

        [Parameter(Mandatory = $true)]
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
    elseif ($Issues.Count -gt 0) {
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
    }
}
