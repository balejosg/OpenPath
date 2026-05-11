function Get-OpenPathWhitelistDownloadResult {
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

function Handle-OpenPathDownloadFailure {
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
        [bool]$EnableStaleFailsafe
    )

    if (-not (Test-Path $WhitelistPath)) {
        throw "No local whitelist available and download failed"
    }

    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath

    $cachedAgeHours = Get-OpenPathFileAgeHours -Path $WhitelistPath
    if ($EnableStaleFailsafe -and $StaleWhitelistMaxAgeHours -gt 0 -and $cachedAgeHours -ge $StaleWhitelistMaxAgeHours) {
        Enter-StaleWhitelistFailsafe -Config $Config -WhitelistAgeHours $cachedAgeHours -StaleFailsafeStatePath $StaleFailsafeStatePath
        $runtimeHealth = Get-OpenPathRuntimeHealth
        Send-OpenPathHealthReport -Status 'STALE_FAILSAFE' `
            -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
            -DnsResolving $runtimeHealth.DnsResolving `
            -FailCount 0 `
            -Actions "stale_whitelist_failsafe age=${cachedAgeHours}h" | Out-Null
        Write-OpenPathLog "Stale fail-safe activated after download failure (age=$cachedAgeHours h)" -Level WARN
        return
    }

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'DEGRADED' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions 'download_failed_cached_whitelist' | Out-Null
    Write-OpenPathLog "Using cached whitelist (age=$cachedAgeHours h) until next successful download" -Level WARN
}

function Handle-OpenPathNotModified {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath
    )

    $localWhitelistSections = Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath
    if ($localWhitelistSections.IsDisabled) {
        if (Get-Command -Name 'Clear-OpenPathRuntimeDependencyOverlay' -ErrorAction SilentlyContinue) {
            Clear-OpenPathRuntimeDependencyOverlay | Out-Null
        }
        Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath -ClearWhitelist
        Write-OpenPathLog "Whitelist not modified and local fail-open marker remains active"

        try {
            $runtimeHealth = Get-OpenPathRuntimeHealth
            Send-OpenPathHealthReport -Status 'FAIL_OPEN' `
                -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
                -DnsResolving $runtimeHealth.DnsResolving `
                -FailCount 0 `
                -Actions 'remote_disable_marker_not_modified' | Out-Null
        }
        catch {
            # Ignore health reporting errors
        }

        Write-OpenPathLog "=== OpenPath update completed (fail-open unchanged) ==="
        return
    }

    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath
    Update-AcrylicHost -WhitelistedDomains $localWhitelistSections.Whitelist -BlockedSubdomains $localWhitelistSections.BlockedSubdomains
    Write-OpenPathLog "Whitelist not modified (ETag) - skipping apply"

    try {
        $runtimeHealth = Get-OpenPathRuntimeHealth
        Send-OpenPathHealthReport -Status 'HEALTHY' `
            -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
            -DnsResolving $runtimeHealth.DnsResolving `
            -FailCount 0 `
            -Actions 'not_modified' | Out-Null
    }
    catch {
        # Ignore health reporting errors
    }

    Write-OpenPathLog "=== OpenPath update completed (no changes) ==="
}

function Handle-OpenPathDisabledWhitelist {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath
    )

    Write-OpenPathLog "DEACTIVATION FLAG detected - entering fail-open mode" -Level WARN

    "# DESACTIVADO" | Set-Content $WhitelistPath -Encoding UTF8
    if (Get-Command -Name 'Clear-OpenPathRuntimeDependencyOverlay' -ErrorAction SilentlyContinue) {
        Clear-OpenPathRuntimeDependencyOverlay | Out-Null
    }
    Restore-OriginalDNS
    Remove-OpenPathFirewall
    Remove-BrowserPolicy
    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath -ClearWhitelist
    Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'FAIL_OPEN' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions 'remote_disable_marker' | Out-Null

    Write-OpenPathLog "System in fail-open mode"
}

function Handle-OpenPathWhitelistApply {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Whitelist,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [Parameter(Mandatory = $true)]
        [string]$StaleFailsafeStatePath
    )

    $serializedWhitelist = ConvertTo-OpenPathWhitelistFileContent `
        -Whitelist $Whitelist.Whitelist `
        -BlockedSubdomains $Whitelist.BlockedSubdomains `
        -BlockedPaths $Whitelist.BlockedPaths
    $serializedWhitelist | Set-Content $WhitelistPath -Encoding UTF8
    Sync-FirefoxNativeHostMirror -Config $Config -WhitelistPath $WhitelistPath

    Update-AcrylicHost -WhitelistedDomains $Whitelist.Whitelist -BlockedSubdomains $Whitelist.BlockedSubdomains
    Restore-OpenPathProtectedMode -Config $Config | Out-Null

    if ($Config.enableBrowserPolicies) {
        Set-AllBrowserPolicy -BlockedPaths $Whitelist.BlockedPaths -Config $Config
    }

    Restore-OpenPathProtectedMode -Config $Config -SkipAcrylicRestart | Out-Null

    Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath

    $runtimeHealth = Get-OpenPathRuntimeHealth
    Send-OpenPathHealthReport -Status 'HEALTHY' `
        -DnsServiceRunning $runtimeHealth.DnsServiceRunning `
        -DnsResolving $runtimeHealth.DnsResolving `
        -FailCount 0 `
        -Actions 'update' | Out-Null

    Write-OpenPathLog "=== OpenPath update completed successfully ==="
}
