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

    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath

    $runtimeDependencyQueueChanged = Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $WhitelistPath
    $policyState = Get-OpenPathEndpointPolicyState `
        -WhitelistSections (Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath)
    $repairPlan = New-OpenPathEndpointStateRepairPlan `
        -PolicyState $policyState `
        -Mode 'CachedWhitelist' `
        -QueueChanged $runtimeDependencyQueueChanged
    Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null

    $cachedAgeHours = Get-OpenPathFileAgeHours -Path $WhitelistPath
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

    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath
    $runtimeDependencyQueueChanged = Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $WhitelistPath
    $repairPlan = New-OpenPathEndpointStateRepairPlan `
        -PolicyState $policyState `
        -Mode 'CachedWhitelist' `
        -QueueChanged $runtimeDependencyQueueChanged
    Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
    Write-OpenPathLog "Whitelist not modified (ETag) - skipping apply"

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

    "# DESACTIVADO" | Set-Content $WhitelistPath -Encoding UTF8
    $policyState = Get-OpenPathEndpointPolicyState `
        -WhitelistSections ([PSCustomObject]@{ IsDisabled = $true })
    $repairPlan = New-OpenPathEndpointStateRepairPlan -PolicyState $policyState -Mode 'FailOpen'
    Invoke-OpenPathEndpointStateRepairPlan -Plan $repairPlan -Config $Config | Out-Null
    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath -ClearWhitelist
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
    $serializedWhitelist | Set-Content $WhitelistPath -Encoding UTF8
    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath

    Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $WhitelistPath | Out-Null
    $policyState = Get-OpenPathEndpointPolicyState `
        -WhitelistSections (Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath)
    $repairPlan = New-OpenPathEndpointStateRepairPlan `
        -PolicyState $policyState `
        -Mode 'ApplyWhitelist' `
        -EnableBrowserPolicies:([bool]$Config.enableBrowserPolicies)
    Invoke-OpenPathEndpointStateRepairPlan `
        -Plan $repairPlan `
        -Config $Config `
        -BlockedPaths $Whitelist.BlockedPaths | Out-Null

    Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'HEALTHY' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions (Join-OpenPathUpdateHealthActions -Action 'update' -Suffix $HealthActionSuffix) | Out-Null

    Write-OpenPathLog "=== OpenPath update completed successfully ==="
}
