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

function Invoke-OpenPathWatchdogPrechecks {
    # runs before every main watchdog cycle
    # probes the captive portal state and decides whether to enter, refresh, or exit portal mode
    # returns a summary of the current portal observation for use by the caller
    param(
        [AllowNull()]
        [PSCustomObject]$Config
    )

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
        if (Get-Command -Name 'Test-OpenPathNonAdminAppControlActive' -ErrorAction SilentlyContinue) {
            $enableNonAdminAppControl = $true
            if ($Config -and $Config.PSObject.Properties['enableNonAdminAppControl']) {
                $enableNonAdminAppControl = [bool]$Config.enableNonAdminAppControl
            }
            $mode = 'Enforced'
            if ($Config -and $Config.PSObject.Properties['nonAdminAppControlMode'] -and $Config.nonAdminAppControlMode) {
                $mode = [string]$Config.nonAdminAppControlMode
            }
            $approvedStudentBrowsers = @('Firefox')
            if ($Config -and $Config.PSObject.Properties['approvedStudentBrowsers'] -and $Config.approvedStudentBrowsers) {
                $approvedStudentBrowsers = @($Config.approvedStudentBrowsers)
            }
            if ($enableNonAdminAppControl -and -not (Test-OpenPathNonAdminAppControlActive `
                        -Mode $mode `
                        -ApprovedBrowsers $approvedStudentBrowsers)) {
                Set-OpenPathNonAdminAppControl -OpenPathRoot $OpenPathRoot -Mode $mode -ApprovedBrowsers $approvedStudentBrowsers | Out-Null
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
    # combines the issues from the cycle into a status string and a fail-count decision
    # promotes degraded to critical after three consecutive recovery-eligible failures
    # triggers checkpoint rollback at critical and resets the counter on success
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
