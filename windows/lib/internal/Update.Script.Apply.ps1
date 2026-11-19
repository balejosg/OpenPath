function Get-OpenPathWhitelistDownloadResult {
    # fetches the whitelist from whitelistUrl and returns DownloadFailed, Whitelist, and ErrorText fields; sets DownloadFailed on any exception
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $result = [ordered]@{
        DownloadFailed = $false
        Whitelist = $null
        ErrorText = ''
    }

    try {
        $result.Whitelist = Get-OpenPathFromUrl -Url $Config.whitelistUrl
    }
    catch {
        $result.DownloadFailed = $true
        $result.ErrorText = [string]$_
        Write-OpenPathLog "Whitelist download failed: $_" -Level WARN
    }

    return [PSCustomObject]$result
}

function Get-OpenPathWhitelistDownloadFailureState {
    # reads the persisted run of failed whitelist downloads; missing, unreadable, or unknown-schema state counts as zero
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    $emptyState = [PSCustomObject][ordered]@{
        SchemaVersion       = 1
        ConsecutiveFailures = 0
        LastFailureUtc      = $null
        LastError           = ''
    }

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return $emptyState
    }

    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $emptyState
        }

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed -or -not $parsed.PSObject.Properties['schemaVersion']) {
            return $emptyState
        }

        $schemaVersion = 0
        try {
            $schemaVersion = [int]$parsed.schemaVersion
        }
        catch {
            return $emptyState
        }
        if ($schemaVersion -ne 1) {
            return $emptyState
        }

        $consecutiveFailures = 0
        if ($parsed.PSObject.Properties['consecutiveFailures']) {
            try {
                $consecutiveFailures = [int]$parsed.consecutiveFailures
            }
            catch {
                $consecutiveFailures = 0
            }
        }
        if ($consecutiveFailures -lt 0) {
            $consecutiveFailures = 0
        }

        $lastFailureUtc = $null
        if ($parsed.PSObject.Properties['lastFailureUtc'] -and $parsed.lastFailureUtc) {
            try {
                $parsedLastFailure = $parsed.lastFailureUtc
                if ($parsedLastFailure -is [datetime]) {
                    $parsedLastFailureDate = [datetime]$parsedLastFailure
                    if ($parsedLastFailureDate.Kind -eq [System.DateTimeKind]::Unspecified) {
                        $lastFailureUtc = [datetime]::SpecifyKind($parsedLastFailureDate, [System.DateTimeKind]::Utc)
                    }
                    else {
                        $lastFailureUtc = $parsedLastFailureDate.ToUniversalTime()
                    }
                }
                else {
                    $parsedLastFailureDate = [datetime]::Parse([string]$parsedLastFailure, [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
                    if ($parsedLastFailureDate.Kind -eq [System.DateTimeKind]::Unspecified) {
                        $parsedLastFailureDate = [datetime]::SpecifyKind($parsedLastFailureDate, [System.DateTimeKind]::Utc)
                    }
                    $lastFailureUtc = $parsedLastFailureDate.ToUniversalTime()
                }
            }
            catch {
                $lastFailureUtc = $null
            }
        }

        $lastError = ''
        if ($parsed.PSObject.Properties['lastError']) {
            $lastError = [string]$parsed.lastError
        }

        return [PSCustomObject]@{
            SchemaVersion       = 1
            ConsecutiveFailures = $consecutiveFailures
            LastFailureUtc      = $lastFailureUtc
            LastError           = $lastError
        }
    }
    catch {
        return $emptyState
    }
}

function Save-OpenPathWhitelistDownloadFailureState {
    # persists the failed-download run with the shared atomic JSON helper
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        [int]$ConsecutiveFailures,

        [AllowNull()]
        [object]$LastFailureUtc = $null,

        [string]$LastError = ''
    )

    $lastFailureValue = $null
    if ($LastFailureUtc) {
        $lastFailureValue = ([datetime]$LastFailureUtc).ToUniversalTime().ToString('o')
    }

    Write-OpenPathAtomicJsonFile -Path $StatePath -Data ([ordered]@{
            schemaVersion       = 1
            consecutiveFailures = [Math]::Max([int]$ConsecutiveFailures, 0)
            lastFailureUtc      = $lastFailureValue
            lastError           = [string]$LastError
        }) -Depth 4
}

function Register-OpenPathWhitelistDownloadFailure {
    # counts a failed whitelist download when it is the first of a run or at least four minutes after the last counted failure
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [string]$ErrorText = '',

        [datetime]$Now = (Get-Date).ToUniversalTime()
    )

    $nowUtc = $Now
    if ($nowUtc.Kind -ne [System.DateTimeKind]::Utc) {
        $nowUtc = $nowUtc.ToUniversalTime()
    }

    $state = Get-OpenPathWhitelistDownloadFailureState -StatePath $StatePath
    $consecutiveFailures = [int]$state.ConsecutiveFailures
    $lastFailureUtc = $state.LastFailureUtc
    $shouldCount = $true

    if ($consecutiveFailures -gt 0 -and $lastFailureUtc) {
        if ($lastFailureUtc -le $nowUtc -and ($nowUtc - $lastFailureUtc).TotalMinutes -lt 4) {
            $shouldCount = $false
        }
    }

    if ($shouldCount) {
        $consecutiveFailures += 1
        $lastFailureUtc = $nowUtc
    }

    $redactedError = ConvertTo-OpenPathRedactedValue -Value ([string]$ErrorText)
    if ($null -eq $redactedError) {
        $redactedError = ''
    }
    $redactedError = [string]$redactedError
    if ($redactedError.Length -gt 200) {
        $redactedError = $redactedError.Substring(0, 200)
    }

    try {
        Save-OpenPathWhitelistDownloadFailureState `
            -StatePath $StatePath `
            -ConsecutiveFailures $consecutiveFailures `
            -LastFailureUtc $lastFailureUtc `
            -LastError $redactedError
    }
    catch {
        Write-OpenPathLog "Could not persist the whitelist download failure run: $_" -Level WARN
    }

    return [PSCustomObject]@{
        ConsecutiveFailures = $consecutiveFailures
        LastFailureUtc      = $lastFailureUtc
        LastError           = $redactedError
    }
}

function Reset-OpenPathWhitelistDownloadFailureState {
    # clears the failed-download run after any successful contact with the server
    param(
        [string]$StatePath = ''
    )

    if (-not $StatePath) {
        return
    }

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            Save-OpenPathWhitelistDownloadFailureState `
                -StatePath $StatePath `
                -ConsecutiveFailures 0 `
                -LastFailureUtc $null `
                -LastError ''
        }
        catch {
            Write-OpenPathLog "Could not reset the whitelist download failure run: $_" -Level WARN
        }
    }
}

function Join-OpenPathUpdateHealthActions {
    # concatenates a primary action string with an optional suffix using a semicolon separator; returns the action alone when suffix is empty
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [string]$Suffix = ''
    )

    if ($Suffix) {
        return "$Action; $Suffix"
    }

    return $Action
}

function Get-OpenPathWhitelistVerifiedPath {
    # returns the marker file that records when the server last confirmed the cached whitelist is current
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath
    )

    return (Join-Path (Split-Path $WhitelistPath -Parent) 'whitelist.verified')
}

function Set-OpenPathWhitelistVerified {
    # records that the server confirmed the cached whitelist (HTTP 304); the whitelist file itself is not touched
    # because its timestamp fingerprints the native-host mirror
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath
    )

    try {
        Set-Content -Path (Get-OpenPathWhitelistVerifiedPath -WhitelistPath $WhitelistPath) `
            -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII -ErrorAction Stop
    }
    catch {
        Write-OpenPathLog "Could not record whitelist verification: $_" -Level WARN
    }
}

function Get-OpenPathCachedWhitelistAgeHours {
    # returns hours since the cached whitelist was last written or last confirmed current by the server, whichever is newer
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath
    )

    $writtenAgeHours = Get-OpenPathFileAgeHours -Path $WhitelistPath
    $verifiedAgeHours = Get-OpenPathFileAgeHours -Path (Get-OpenPathWhitelistVerifiedPath -WhitelistPath $WhitelistPath)
    return [Math]::Min([double]$writtenAgeHours, [double]$verifiedAgeHours)
}

function Handle-OpenPathDownloadFailure {
    # applies the cached whitelist when a download fails; counts consecutive failures and enters the stale fail-safe only after the configured threshold; always sends a health report
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath,

        [Parameter(Mandatory = $true)]
        [double]$StaleWhitelistMaxAgeHours,

        [Parameter(Mandatory = $true)]
        [bool]$EnableStaleFailsafe,

        [int]$StaleFailsafeMinConsecutiveFailures = 6,

        [string]$DownloadFailureStatePath = '',

        [string]$DownloadErrorText = '',

        [datetime]$Now = (Get-Date).ToUniversalTime(),

        [string]$HealthActionSuffix = ''
    )

    if (-not (Test-Path $WhitelistPath)) {
        throw "No local whitelist available and download failed"
    }

    if (-not $DownloadFailureStatePath) {
        $DownloadFailureStatePath = Join-Path (Split-Path $StaleFailsafeStatePath -Parent) 'whitelist-download-failures.json'
    }

    $failureState = Register-OpenPathWhitelistDownloadFailure `
        -StatePath $DownloadFailureStatePath `
        -ErrorText $DownloadErrorText `
        -Now $Now
    $consecutiveFailures = [int]$failureState.ConsecutiveFailures
    $failureThreshold = [Math]::Max([int]$StaleFailsafeMinConsecutiveFailures, 1)
    $staleFailsafeCurrentlyActive = Test-Path -LiteralPath $StaleFailsafeStatePath

    # Phase 7 P2: the queue apply writes the overlay and AcrylicHosts.txt; it runs
    # inside the Acrylic writers lock so the dependency fast path (which waits on
    # that lock, not on the update cycle) can interleave between the cycle stages.
    $runtimeDependencyQueueChanged = [bool](Invoke-OpenPathUpdateWritersLockScope -Stage 'download-failure-queue-apply' -Action {
            Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath | Out-Null
            return (Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $WhitelistPath)
        })
    $policyState = Get-OpenPathEndpointPolicyState `
        -WhitelistSections (Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath)
    $repairPlan = New-OpenPathEndpointStateRepairPlan `
        -PolicyState $policyState `
        -Mode 'CachedWhitelist' `
        -QueueChanged $runtimeDependencyQueueChanged
    Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null

    $cachedAgeHours = Get-OpenPathCachedWhitelistAgeHours -WhitelistPath $WhitelistPath
    $ageThresholdReached = $EnableStaleFailsafe -and $StaleWhitelistMaxAgeHours -gt 0 -and $cachedAgeHours -ge $StaleWhitelistMaxAgeHours
    $failureThresholdReached = $consecutiveFailures -ge $failureThreshold
    if ($ageThresholdReached -and ($staleFailsafeCurrentlyActive -or $failureThresholdReached)) {
        Enter-StaleWhitelistFailsafe -Config $Config -WhitelistAgeHours $cachedAgeHours -StaleFailsafeStatePath $StaleFailsafeStatePath
        $runtimeHealth = Get-OpenPathRuntimeHealth
        Send-OpenPathHealthReport -Status 'STALE_FAILSAFE' `
            -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
            -DnsResolving $runtimeHealth.DnsResolving `
            -FailCount 0 `
            -Actions (Join-OpenPathUpdateHealthActions -Action "stale_whitelist_failsafe age=${cachedAgeHours}h" -Suffix $HealthActionSuffix) | Out-Null
        Write-OpenPathLog "Stale fail-safe activated after download failure (age=$cachedAgeHours h, failures=$consecutiveFailures/$failureThreshold)" -Level WARN
        return
    }

    $healthAction = 'download_failed_cached_whitelist'
    if ($ageThresholdReached -and -not $staleFailsafeCurrentlyActive) {
        $healthAction = "$healthAction; stale_failsafe_progress=$consecutiveFailures/$failureThreshold"
    }

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'DEGRADED' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions (Join-OpenPathUpdateHealthActions -Action $healthAction -Suffix $HealthActionSuffix) | Out-Null
    Write-OpenPathLog "Using cached whitelist (age=$cachedAgeHours h, failures=$consecutiveFailures/$failureThreshold) until next successful download" -Level WARN
}

function Handle-OpenPathNotModified {
    # applies cached whitelist policy when the server returns not-modified; enters fail-open path if the local marker is active
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [string]$StaleFailsafeStatePath = '',

        [string]$DownloadFailureStatePath = '',

        [string]$HealthActionSuffix = ''
    )

    Reset-OpenPathWhitelistDownloadFailureState -StatePath $DownloadFailureStatePath
    $staleFailsafeWasActive = [bool]($StaleFailsafeStatePath -and (Test-Path -LiteralPath $StaleFailsafeStatePath))
    $localWhitelistSections = Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath
    $policyState = Get-OpenPathEndpointPolicyState -WhitelistSections $localWhitelistSections
    if ($policyState.IsDisabled) {
        # A 304 does not prove the endpoint is still open: anything that re-armed
        # protection after the disable would otherwise stay in force until the
        # whitelist changes on the server.
        $protectionActive = $false
        try {
            $protectionActive = [bool](Test-FirewallActive) -or [bool](Test-OpenPathAdapterDnsPinnedToLocalResolver)
        }
        catch {
            Write-OpenPathLog "Could not check firewall state while fail-open is active: $_" -Level WARN
        }
        $repairMode = 'FailOpenMarkerOnly'
        if ($protectionActive) {
            Write-OpenPathLog "Protection is active while the classroom is disabled; re-entering fail-open mode" -Level WARN
            $repairMode = 'FailOpen'
        }
        $repairPlan = New-OpenPathEndpointStateRepairPlan -PolicyState $policyState -Mode $repairMode
        Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
        if (Get-Command -Name 'Clear-OpenPathCaptivePortalMarker' -ErrorAction SilentlyContinue) {
            try { Clear-OpenPathCaptivePortalMarker | Out-Null } catch { Write-OpenPathLog "Could not clear the captive portal marker while the classroom is disabled: $_" -Level WARN }
        }
        Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath -ClearWhitelist
        Write-OpenPathLog "Whitelist not modified and local fail-open marker remains active"

        try {
            $runtimeHealth = Get-OpenPathRuntimeHealth
            Send-OpenPathHealthReport -Status 'FAIL_OPEN' `
                -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
                -DnsResolving $runtimeHealth.DnsResolving `
                -FailCount 0 `
                -Actions (Join-OpenPathUpdateHealthActions -Action 'remote_disable_marker_not_modified' -Suffix $HealthActionSuffix) | Out-Null
        }
        catch {
            # Ignore health reporting errors
        }

        Write-OpenPathLog "=== OpenPath update completed (fail-open unchanged) ==="
        return
    }

    $runtimeDependencyQueueChanged = [bool](Invoke-OpenPathUpdateWritersLockScope -Stage 'not-modified-queue-apply' -Action {
            Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath | Out-Null
            return (Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $WhitelistPath)
        })
    $repairPlan = New-OpenPathEndpointStateRepairPlan `
        -PolicyState $policyState `
        -Mode 'CachedWhitelist' `
        -QueueChanged $runtimeDependencyQueueChanged
    Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
    Write-OpenPathLog "Whitelist not modified (ETag) - skipping apply"

    # The server just confirmed the cached whitelist is current: it is no longer
    # stale, so record that and leave the stale fail-safe. Without this a 304
    # kept the marker forever and the next failed download re-entered the
    # fail-safe at once, judging freshness by the last time the file changed.
    Set-OpenPathWhitelistVerified -WhitelistPath $WhitelistPath
    if ($staleFailsafeWasActive) {
        # Acrylic keeps serving the narrowed control-domain hosts file until it
        # reloads; the queue apply above only rewrites the file. Restore protected
        # mode in this cycle, but never on an ordinary 304 that was not in the
        # fail-safe.
        Restore-OpenPathProtectedMode -Config $Config | Out-Null
        Write-OpenPathLog "Server confirmed the cached whitelist is current; restored protected mode and left stale fail-safe mode"
    }
    if ($StaleFailsafeStatePath -and (Test-Path $StaleFailsafeStatePath)) {
        Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath
    }

    try {
        $runtimeHealth = Get-OpenPathRuntimeHealth
        Send-OpenPathHealthReport -Status 'HEALTHY' `
            -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
            -DnsResolving $runtimeHealth.DnsResolving `
            -FailCount 0 `
            -Actions (Join-OpenPathUpdateHealthActions -Action 'not_modified' -Suffix $HealthActionSuffix) | Out-Null
    }
    catch {
        # Ignore health reporting errors
    }

    Write-OpenPathLog "=== OpenPath update completed (no changes) ==="
}

function Handle-OpenPathDisabledWhitelist {
    # writes the deactivation marker to disk and transitions the endpoint to fail-open mode, clearing any stale-failsafe state
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath,

        [string]$DownloadFailureStatePath = '',

        [string]$HealthActionSuffix = ''
    )

    Reset-OpenPathWhitelistDownloadFailureState -StatePath $DownloadFailureStatePath
    Write-OpenPathLog "DEACTIVATION FLAG detected - entering fail-open mode" -Level WARN

    Invoke-OpenPathUpdateWritersLockScope -Stage 'fail-open-marker' -Action {
        Write-OpenPathAtomicTextFile -Path $WhitelistPath -Content '# DESACTIVADO'
    } | Out-Null
    $policyState = Get-OpenPathEndpointPolicyState `
        -WhitelistSections ([PSCustomObject]@{ IsDisabled = $true })
    $repairPlan = New-OpenPathEndpointStateRepairPlan -PolicyState $policyState -Mode 'FailOpen'
    Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
    if (Get-Command -Name 'Clear-OpenPathCaptivePortalMarker' -ErrorAction SilentlyContinue) {
        try { Clear-OpenPathCaptivePortalMarker | Out-Null } catch { Write-OpenPathLog "Could not clear the captive portal marker after entering fail-open mode: $_" -Level WARN }
    }
    Invoke-OpenPathUpdateWritersLockScope -Stage 'fail-open-mirror' -Action {
        Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath -ClearWhitelist | Out-Null
    } | Out-Null
    Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'FAIL_OPEN' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions (Join-OpenPathUpdateHealthActions -Action 'remote_disable_marker' -Suffix $HealthActionSuffix) | Out-Null

    Write-OpenPathLog "System in fail-open mode"
}

function Handle-OpenPathWhitelistApply {
    # persists the new whitelist, syncs the firefox mirror, drains the runtime dependency queue, repairs endpoint state, and sends a health report
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Whitelist,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath,

        [string]$DownloadFailureStatePath = '',

        [string]$HealthActionSuffix = ''
    )

    Reset-OpenPathWhitelistDownloadFailureState -StatePath $DownloadFailureStatePath
    $serializedWhitelist = ConvertTo-OpenPathWhitelistFileContent `
        -Whitelist $Whitelist.Whitelist `
        -BlockedSubdomains $Whitelist.BlockedSubdomains `
        -BlockedPaths $Whitelist.BlockedPaths
    # Phase 7 P2: whitelist write + mirror + queue apply are the shared writers;
    # they run in one short Acrylic writers scope so the dependency fast path can
    # interleave with the rest of the cycle (network, restarts, policies).
    $queueScope = Invoke-OpenPathUpdateWritersLockScope -Stage 'whitelist-queue-apply' -Action {
        Write-OpenPathAtomicTextFile -Path $WhitelistPath -Content $serializedWhitelist
        Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath | Out-Null
        $queueResult = Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $WhitelistPath -PassThru
        return [PSCustomObject]@{
            Queue   = $queueResult
            Overlay = (Get-OpenPathRuntimeDependencyOverlayState)
        }
    }
    $policyState = Get-OpenPathEndpointPolicyState `
        -WhitelistSections (Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath)
    $repairPlan = New-OpenPathEndpointStateRepairPlan `
        -PolicyState $policyState `
        -Mode 'ApplyWhitelist' `
        -EnableBrowserPolicies:([bool]$Config.enableBrowserPolicies)
    $repairResult = Invoke-OpenPathEndpointStateRepairPlan `
        -Plan $repairPlan `
        -Config $Config `
        -BlockedPaths $Whitelist.BlockedPaths

    # Phase 7 P2: when this cycle left unapplied overlay content and its repair
    # plan restarted Acrylic and flushed DNS, stamp exactly the generation this
    # cycle applied. The dependency fast apply then only confirms it instead of
    # paying a redundant restart for content the update already made operative.
    if ($queueScope.Overlay -and
        ($queueScope.Overlay.Generation -gt $queueScope.Overlay.AppliedGeneration) -and
        $repairResult -and
        ($repairResult.AcrylicRunning -eq $true) -and
        ($repairResult.DnsFlushed -eq $true)) {
        $stampedGeneration = [int]$queueScope.Overlay.Generation
        Invoke-OpenPathUpdateWritersLockScope -Stage 'overlay-stamp' -Action {
            Set-OpenPathRuntimeDependencyOverlayApplied -Generation $stampedGeneration | Out-Null
        } | Out-Null
        Write-OpenPathLog "OpenPath update stamped runtime dependency overlay appliedGeneration=$stampedGeneration"
    }

    Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'HEALTHY' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions (Join-OpenPathUpdateHealthActions -Action 'update' -Suffix $HealthActionSuffix) | Out-Null

    Write-OpenPathLog "=== OpenPath update completed successfully ==="
}
