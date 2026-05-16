function New-OpenPathEndpointStateRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$PolicyState,

        [ValidateSet('ApplyWhitelist', 'FailOpen', 'FailOpenMarkerOnly', 'CachedWhitelist')]
        [string]$Mode = 'CachedWhitelist',

        [bool]$QueueChanged = $false,

        [bool]$EnableBrowserPolicies = $false
    )

    $actions = @()
    if ($Mode -eq 'FailOpen') {
        $actions += 'ClearRuntimeDependencyOverlay'
        $actions += 'RestoreOriginalDns'
        $actions += 'RemoveFirewall'
        $actions += 'RemoveBrowserPolicy'
    }
    elseif ($Mode -eq 'FailOpenMarkerOnly') {
        $actions += 'ClearRuntimeDependencyOverlay'
    }
    elseif ($Mode -eq 'ApplyWhitelist') {
        $actions += 'RestoreProtectedMode'
        if ($EnableBrowserPolicies) {
            $actions += 'SetAllBrowserPolicy'
        }
        $actions += 'RestoreProtectedModeNoRestart'
    }
    elseif ($QueueChanged -and $PolicyState.ProtectedModeEligible) {
        $actions += 'RestoreProtectedMode'
    }

    return [PSCustomObject]@{
        Mode = $Mode
        Actions = @($actions)
        QueueChanged = [bool]$QueueChanged
        ProtectedModeEligible = [bool]$PolicyState.ProtectedModeEligible
    }
}

function New-OpenPathWatchdogProtectedModeRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$PolicyState,

        [bool]$AcrylicServiceRunning = $true,

        [bool]$DnsResolutionHealthy = $true,

        [bool]$DnsSinkholeHealthy = $true,

        [bool]$FirewallActive = $true,

        [bool]$LocalDnsConfigured = $true,

        [string[]]$AffectedLocalDnsAdapterNames = @()
    )

    $issues = @()
    $recoveryEligibleIssues = @()
    $actions = @()

    if (-not $PolicyState.ProtectedModeEligible) {
        return [PSCustomObject]@{
            Actions = @()
            Issues = @()
            RecoveryEligibleIssues = @()
        }
    }

    if (-not $AcrylicServiceRunning) {
        $issues += 'Acrylic service not running'
        $recoveryEligibleIssues += 'Acrylic service not running'
        $actions += 'StartAcrylicService'
    }

    if (-not $DnsResolutionHealthy) {
        $issues += 'DNS resolution failed for allowed domain'
        $recoveryEligibleIssues += 'DNS resolution failed for allowed domain'
        $actions += 'RestartAcrylicService'
    }

    if (-not $DnsSinkholeHealthy) {
        $issues += 'DNS sinkhole not working'
        $recoveryEligibleIssues += 'DNS sinkhole not working'
    }

    if (-not $FirewallActive) {
        $issues += 'Firewall rules not active'
        $recoveryEligibleIssues += 'Firewall rules not active'
        $actions += 'SetOpenPathFirewall'
    }

    if (-not $LocalDnsConfigured) {
        $adapterSuffix = ''
        if (@($AffectedLocalDnsAdapterNames).Count -gt 0) {
            $adapterSuffix = ": $(@($AffectedLocalDnsAdapterNames) -join ', ')"
        }
        $issues += "Local DNS not configured$adapterSuffix"
        $recoveryEligibleIssues += "Local DNS not configured$adapterSuffix"
        $actions += 'SetLocalDns'
    }

    return [PSCustomObject]@{
        Actions = @($actions)
        Issues = @($issues)
        RecoveryEligibleIssues = @($recoveryEligibleIssues)
    }
}

function Invoke-OpenPathEndpointStateRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [AllowNull()]
        [object]$Config,

        [AllowNull()]
        [string[]]$BlockedPaths = @()
    )

    $applied = @()
    foreach ($action in @($Plan.Actions)) {
        switch ($action) {
            'ClearRuntimeDependencyOverlay' {
                if (Get-Command -Name 'Clear-OpenPathRuntimeDependencyOverlay' -ErrorAction SilentlyContinue) {
                    Clear-OpenPathRuntimeDependencyOverlay | Out-Null
                }
            }
            'RestoreOriginalDns' {
                Restore-OriginalDNS
            }
            'RemoveFirewall' {
                Remove-OpenPathFirewall
            }
            'RemoveBrowserPolicy' {
                Remove-BrowserPolicy -PreserveFirefoxManagedExtension
            }
            'RestoreProtectedMode' {
                Restore-OpenPathProtectedMode -Config $Config | Out-Null
            }
            'RestoreProtectedModeNoRestart' {
                Restore-OpenPathProtectedMode -Config $Config -SkipAcrylicRestart | Out-Null
            }
            'SetAllBrowserPolicy' {
                Set-AllBrowserPolicy -BlockedPaths $BlockedPaths -Config $Config
            }
            'StartAcrylicService' {
                Write-OpenPathLog "Watchdog: Acrylic service not running, attempting restart..." -Level WARN
                Start-AcrylicService
            }
            'RestartAcrylicService' {
                Write-OpenPathLog "Watchdog: DNS resolution failed, restarting Acrylic..." -Level WARN
                Restart-AcrylicService
                Start-Sleep -Seconds 3
            }
            'SetOpenPathFirewall' {
                Write-OpenPathLog "Watchdog: Firewall rules missing, reconfiguring..." -Level WARN
                if (-not $Config) {
                    $Config = Get-OpenPathConfig
                }
                $acrylicPath = Get-AcrylicPath
                Set-OpenPathFirewall -UpstreamDNS $Config.primaryDNS -AcrylicPath $acrylicPath
            }
            'SetLocalDns' {
                Write-OpenPathLog "Watchdog: Local DNS not configured, fixing..." -Level WARN
                Set-LocalDNS
            }
        }

        $applied += $action
    }

    return [PSCustomObject]@{
        AppliedActions = @($applied)
    }
}
