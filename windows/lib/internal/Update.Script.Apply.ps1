function Get-OpenPathWhitelistDownloadResult {
    # fetches the whitelist from whitelistUrl and returns DownloadFailed and Whitelist fields; sets DownloadFailed on any exception
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $result = [ordered]@{
        DownloadFailed = $false
        Whitelist = $null
    }

    try {
        $result.Whitelist = Get-OpenPathFromUrl -Url $Config.whitelistUrl
    }
    catch {
        $result.DownloadFailed = $true
        Write-OpenPathLog "Whitelist download failed: $_" -Level WARN
    }

    return [PSCustomObject]$result
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
    # applies the cached whitelist when a download fails; triggers stale-failsafe when age exceeds the threshold; always sends a health report
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

        [string]$HealthActionSuffix = ''
    )

    if (-not (Test-Path $WhitelistPath)) {
        throw "No local whitelist available and download failed"
    }

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
    if ($EnableStaleFailsafe -and $StaleWhitelistMaxAgeHours -gt 0 -and $cachedAgeHours -ge $StaleWhitelistMaxAgeHours) {
        Enter-StaleWhitelistFailsafe -Config $Config -WhitelistAgeHours $cachedAgeHours -StaleFailsafeStatePath $StaleFailsafeStatePath
        $runtimeHealth = Get-OpenPathRuntimeHealth
        Send-OpenPathHealthReport -Status 'STALE_FAILSAFE' `
            -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
            -DnsResolving $runtimeHealth.DnsResolving `
            -FailCount 0 `
            -Actions (Join-OpenPathUpdateHealthActions -Action "stale_whitelist_failsafe age=${cachedAgeHours}h" -Suffix $HealthActionSuffix) | Out-Null
        Write-OpenPathLog "Stale fail-safe activated after download failure (age=$cachedAgeHours h)" -Level WARN
        return
    }

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'DEGRADED' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions (Join-OpenPathUpdateHealthActions -Action 'download_failed_cached_whitelist' -Suffix $HealthActionSuffix) | Out-Null
    Write-OpenPathLog "Using cached whitelist (age=$cachedAgeHours h) until next successful download" -Level WARN
}

function Handle-OpenPathNotModified {
    # applies cached whitelist policy when the server returns not-modified; enters fail-open path if the local marker is active
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [string]$StaleFailsafeStatePath = '',

        [string]$HealthActionSuffix = ''
    )

    $localWhitelistSections = Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath
    $policyState = Get-OpenPathEndpointPolicyState -WhitelistSections $localWhitelistSections
    if ($policyState.IsDisabled) {
        $repairPlan = New-OpenPathEndpointStateRepairPlan -PolicyState $policyState -Mode 'FailOpenMarkerOnly'
        Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
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
    if ($StaleFailsafeStatePath -and (Test-Path $StaleFailsafeStatePath)) {
        Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath
        Write-OpenPathLog "Server confirmed the cached whitelist is current; left stale fail-safe mode"
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

        [string]$HealthActionSuffix = ''
    )

    Write-OpenPathLog "DEACTIVATION FLAG detected - entering fail-open mode" -Level WARN

    Invoke-OpenPathUpdateWritersLockScope -Stage 'fail-open-marker' -Action {
        "# DESACTIVADO" | Set-Content $WhitelistPath -Encoding UTF8
    } | Out-Null
    $policyState = Get-OpenPathEndpointPolicyState `
        -WhitelistSections ([PSCustomObject]@{ IsDisabled = $true })
    $repairPlan = New-OpenPathEndpointStateRepairPlan -PolicyState $policyState -Mode 'FailOpen'
    Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
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

        [string]$HealthActionSuffix = ''
    )

    $serializedWhitelist = ConvertTo-OpenPathWhitelistFileContent `
        -Whitelist $Whitelist.Whitelist `
        -BlockedSubdomains $Whitelist.BlockedSubdomains `
        -BlockedPaths $Whitelist.BlockedPaths
    # Phase 7 P2: whitelist write + mirror + queue apply are the shared writers;
    # they run in one short Acrylic writers scope so the dependency fast path can
    # interleave with the rest of the cycle (network, restarts, policies).
    $queueScope = Invoke-OpenPathUpdateWritersLockScope -Stage 'whitelist-queue-apply' -Action {
        $serializedWhitelist | Set-Content $WhitelistPath -Encoding UTF8
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
