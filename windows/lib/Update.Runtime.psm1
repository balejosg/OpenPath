# OpenPath Windows update runtime helpers

$script:OpenPathUpdateRuntimeSessionInitialized = $false
$script:OpenPathUpdateRuntimeRoot = ''
. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')

function Import-OpenPathUpdateRuntimeHelper {
    <#
    .SYNOPSIS
    Dot-sources a helper file and promotes the specified functions into script scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$FunctionNames
    )

    . $Path

    foreach ($functionName in $FunctionNames) {
        $command = Get-Command -Name $functionName -CommandType Function -ErrorAction Stop
        Set-Item -Path "Function:script:$functionName" -Value $command.ScriptBlock -Force
    }
}

function Initialize-OpenPathUpdateRuntimeSession {
    <#
    .SYNOPSIS
    Loads all modules and helper functions required for an update runtime session, skipping the load when already initialized for the same root.
    .DESCRIPTION
    Idempotent per OpenPathRoot value. On first call, bootstraps the script session, imports dependent
    modules, and dot-sources internal helper files to expose their functions in script scope.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = (Resolve-OpenPathWindowsRoot)
    )

    $OpenPathRoot = Resolve-OpenPathWindowsRoot -OpenPathRoot $OpenPathRoot

    if (
        $script:OpenPathUpdateRuntimeSessionInitialized -and
        $script:OpenPathUpdateRuntimeRoot -eq $OpenPathRoot
    ) {
        return
    }

    Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force
    Initialize-OpenPathScriptSession `
        -OpenPathRoot $OpenPathRoot `
        -DependentModules @('DNS', 'Firewall', 'Browser', 'CaptivePortal') `
        -RequiredCommands @(
        'Write-OpenPathLog',
        'Get-OpenPathConfig',
        'Set-OpenPathConfig',
        'Get-OpenPathFileAgeHours',
        'Get-HostFromUrl',
        'Get-OpenPathFromUrl',
        'Get-OpenPathRuntimeHealth',
        'Get-ValidWhitelistDomainsFromFile',
        'ConvertTo-OpenPathWhitelistFileContent',
        'Restore-OpenPathLatestCheckpoint',
        'Restore-OpenPathProtectedMode',
        'Save-OpenPathWhitelistCheckpoint',
        'Send-OpenPathHealthReport',
        'Sync-OpenPathFirefoxNativeHostState',
        'Invoke-OpenPathRuntimeDependencyQueue',
        'Test-OpenPathCaptivePortalState',
        'Update-OpenPathCaptivePortalObservation',
        'Disable-OpenPathCaptivePortalMode',
        'Get-OpenPathCapabilityStoragePath',
        'Update-AcrylicHost',
        'Restart-AcrylicService',
        'Clear-OpenPathRuntimeDependencyOverlay',
        'Restore-OriginalDNS',
        'Remove-OpenPathFirewall',
        'Remove-BrowserPolicy',
        'Set-AllBrowserPolicy',
        'Test-OpenPathCaptivePortalModeActive',
        'Get-OpenPathCaptivePortalMarker'
    ) `
        -ScriptName 'Update-OpenPath.ps1' | Out-Null

    Import-OpenPathUpdateRuntimeHelper `
        -Path (Join-Path $OpenPathRoot 'lib\internal\CapabilityStorage.ps1') `
        -FunctionNames @(
        'Get-OpenPathCapabilityStoragePath'
    )
    Import-OpenPathUpdateRuntimeHelper `
        -Path (Join-Path $OpenPathRoot 'lib\internal\EndpointPolicyState.ps1') `
        -FunctionNames @(
        'Get-OpenPathEndpointPolicyState'
    )
    Import-OpenPathUpdateRuntimeHelper `
        -Path (Join-Path $OpenPathRoot 'lib\internal\EndpointStateReconciler.ps1') `
        -FunctionNames @(
        'New-OpenPathEndpointStateRepairPlan',
        'New-OpenPathWatchdogProtectedModeRepairPlan',
        'Invoke-OpenPathEndpointStateRepairPlan'
    )

    $script:OpenPathUpdateRuntimeSessionInitialized = $true
    $script:OpenPathUpdateRuntimeRoot = $OpenPathRoot
}

function Get-OpenPathMachineTokenFromWhitelistUrl {
    <#
    .SYNOPSIS
    Extracts the machine token path segment from a whitelist URL, returning an empty string when not present.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$WhitelistUrl = '')

    $candidate = ([string]$WhitelistUrl).Trim()
    if (-not $candidate) { return '' }

    try {
        $uri = [System.Uri]::new($candidate)
        $path = $uri.AbsolutePath
        $match = [regex]::Match($path, '/w/([^/]+)/whitelist\.txt$', 'IgnoreCase')
        if ($match.Success) {
            return [System.Uri]::UnescapeDataString($match.Groups[1].Value)
        }
    }
    catch {
        Write-OpenPathLog "Could not parse machine token from whitelist URL: $_" -Level WARN
    }

    return ''
}

function Normalize-OpenPathMachineClientConfigDomains {
    <#
    .SYNOPSIS
    Normalizes a list of domain strings to trimmed, deduplicated, lowercase values.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Domains = $null)

    return @(
        @($Domains) |
            ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Sync-OpenPathMachineClientConfig {
    <#
    .SYNOPSIS
    Fetches machine client config from the API and updates the local config when captive portal domains have changed.
    .DESCRIPTION
    Requires both apiUrl and a machine token in the whitelist URL. When the remote captivePortalDomains list
    differs from the locally persisted list, the local config is updated on disk. Silently skips on network
    or API errors to avoid blocking the update cycle.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][PSCustomObject]$Config)

    $apiUrl = ''
    if ($Config.PSObject.Properties['apiUrl']) {
        $apiUrl = ([string]$Config.apiUrl).Trim().TrimEnd('/')
    }

    $whitelistUrl = ''
    if ($Config.PSObject.Properties['whitelistUrl']) {
        $whitelistUrl = [string]$Config.whitelistUrl
    }
    $machineToken = Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl $whitelistUrl

    if (-not $apiUrl -or -not $machineToken) {
        return $Config
    }

    try {
        $headers = @{ Authorization = "Bearer $machineToken" }
        $response = Invoke-RestMethod `
            -Uri "$apiUrl/api/machines/client-config" `
            -Method Get `
            -Headers $headers `
            -ErrorAction Stop

        if (-not $response -or ($response.PSObject.Properties['success'] -and -not [bool]$response.success)) {
            return $Config
        }

        $responseDomains = @()
        if ($response.PSObject.Properties['captivePortalDomains']) {
            $responseDomains = $response.captivePortalDomains
        }

        $configDomains = @()
        if ($Config.PSObject.Properties['captivePortalDomains']) {
            $configDomains = $Config.captivePortalDomains
        }

        $incomingDomains = Normalize-OpenPathMachineClientConfigDomains -Domains $responseDomains
        $currentDomains = Normalize-OpenPathMachineClientConfigDomains -Domains $configDomains

        if (($incomingDomains -join "`n") -eq ($currentDomains -join "`n")) {
            return $Config
        }

        if ($Config.PSObject.Properties['captivePortalDomains']) {
            $Config.captivePortalDomains = @($incomingDomains)
        }
        else {
            $Config | Add-Member -MemberType NoteProperty -Name 'captivePortalDomains' -Value @($incomingDomains) -Force
        }

        Set-OpenPathConfig -Config $Config
        Write-OpenPathLog "Machine client config synchronized: captivePortalDomains=$(@($incomingDomains).Count)"
    }
    catch {
        Write-OpenPathLog "Machine client config sync skipped: $_" -Level WARN
    }

    return $Config
}

function Invoke-OpenPathCaptivePortalImmediateReconcile {
    <#
    .SYNOPSIS
    Probes the current captive portal state and immediately updates the local observation record.
    #>
    [CmdletBinding()]
    param([PSCustomObject]$Config = $null)

    try {
        $state = Test-OpenPathCaptivePortalState -TimeoutSec 3
        if ($state -eq 'Authenticated') {
            Update-OpenPathCaptivePortalObservation -DetectedState Authenticated | Out-Null
            Disable-OpenPathCaptivePortalMode -Config $Config | Out-Null
            return 'Authenticated'
        }

        Update-OpenPathCaptivePortalObservation -DetectedState $state | Out-Null
        return [string]$state
    }
    catch {
        Write-OpenPathLog "Startup captive portal reconcile failed: $_" -Level WARN
        return 'Error'
    }
}

function Invoke-OpenPathStartupLocalReconcile {
    <#
    .SYNOPSIS
    Reconciles local state at update startup using the cached whitelist, respecting captive portal mode and the skip-restore flag.
    .DESCRIPTION
    Returns early when no cached whitelist exists or the whitelist marks the agent as disabled.
    When captive portal mode is active, performs an immediate portal reconcile instead of restoring
    protected mode. When SkipProtectedModeRestore is set, returns without touching the firewall
    or protected-mode configuration; this is used by SSE-triggered update cycles to avoid redundant
    firewall reconfiguration before the whitelist download.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WhitelistPath,
        [PSCustomObject]$Config = $null,
        [switch]$SkipProtectedModeRestore
    )

    if (-not (Test-Path $WhitelistPath -ErrorAction SilentlyContinue)) {
        return 'NoCachedWhitelist'
    }

    $cachedSections = Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath
    if ($cachedSections.IsDisabled) {
        return 'Disabled'
    }

    if (Test-OpenPathCaptivePortalModeActive) {
        return (Invoke-OpenPathCaptivePortalImmediateReconcile -Config $Config)
    }

    if ($SkipProtectedModeRestore) {
        return 'ProtectedModeRestoreSkipped'
    }

    Restore-OpenPathProtectedMode -Config $Config | Out-Null
    return 'ProtectedModeRestored'
}

function Invoke-OpenPathRuntimeDependencyQueueApply {
    <#
    .SYNOPSIS
    Processes the runtime dependency queue and updates the Acrylic hosts file from the current whitelist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [switch]$PassThru
    )

    $result = [ordered]@{
        Changed = $false
        Processed = 0
        Rejected = 0
        QueueProcessedMs = 0
        OverlayWriteMs = 0
        AcrylicHostUpdateMs = 0
    }

    $runtimeDependencyQueueSections = Get-OpenPathWhitelistSectionsFromFile -Path $WhitelistPath
    if ($runtimeDependencyQueueSections.IsDisabled) {
        if ($PassThru) { return [PSCustomObject]$result }
        return $false
    }

    $queueStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $runtimeDependencyQueueResult = Invoke-OpenPathRuntimeDependencyQueue `
        -WhitelistedDomains $runtimeDependencyQueueSections.Whitelist `
        -BlockedSubdomains $runtimeDependencyQueueSections.BlockedSubdomains
    $queueStopwatch.Stop()

    $result['Changed'] = [bool]$runtimeDependencyQueueResult.Changed
    $result['Processed'] = [int]$runtimeDependencyQueueResult.Processed
    $result['Rejected'] = [int]$runtimeDependencyQueueResult.Rejected
    $result['QueueProcessedMs'] = [int]$queueStopwatch.ElapsedMilliseconds
    if ($runtimeDependencyQueueResult.PSObject.Properties['OverlayWriteMs']) {
        $result['OverlayWriteMs'] = [int]$runtimeDependencyQueueResult.OverlayWriteMs
    }

    if ($runtimeDependencyQueueResult.Processed -gt 0 -or $runtimeDependencyQueueResult.Rejected -gt 0) {
        Write-OpenPathLog "Runtime dependency queue processed: processed=$($runtimeDependencyQueueResult.Processed) rejected=$($runtimeDependencyQueueResult.Rejected)"
    }

    $acrylicStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Update-AcrylicHost -WhitelistedDomains $runtimeDependencyQueueSections.Whitelist -BlockedSubdomains $runtimeDependencyQueueSections.BlockedSubdomains | Out-Null
    $acrylicStopwatch.Stop()
    $result['AcrylicHostUpdateMs'] = [int]$acrylicStopwatch.ElapsedMilliseconds

    if ($PassThru) { return [PSCustomObject]$result }
    return [bool]$runtimeDependencyQueueResult.Changed
}

function Invoke-OpenPathRuntimeDependencyFastApply {
    <#
    .SYNOPSIS
    Acquires the update mutex and applies only the runtime dependency queue without a full whitelist download.
    .DESCRIPTION
    Intended for rapid in-session runtime dependency propagation triggered by the native host.
    Skips the whitelist download and post-download processing steps. Restarts the Acrylic service
    only when the queue produced changes.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = (Resolve-OpenPathWindowsRoot),

        [string]$UpdateMutexName = 'Global\OpenPathUpdateLock',

        [int]$LockWaitTimeoutSeconds = 20
    )

    $OpenPathRoot = Resolve-OpenPathWindowsRoot -OpenPathRoot $OpenPathRoot
    Initialize-OpenPathUpdateRuntimeSession -OpenPathRoot $OpenPathRoot

    $mutex = $null
    $lockAcquired = $false
    $exitCode = 0
    $whitelistPath = Join-Path $OpenPathRoot 'data\whitelist.txt'
    $metrics = [ordered]@{
        mode = 'runtime-dependency-fast-apply'
        queueProcessedMs = 0
        queueProcessed = 0
        queueRejected = 0
        overlayWriteMs = 0
        acrylicHostUpdateMs = 0
        acrylicReloadMs = 0
        changed = $false
    }

    try {
        $mutex = [System.Threading.Mutex]::new($false, $UpdateMutexName)
        try {
            $lockAcquired = $mutex.WaitOne(0)
            if (-not $lockAcquired -and $LockWaitTimeoutSeconds -gt 0) {
                $lockWaitTimeoutMs = [Math]::Max(0, $LockWaitTimeoutSeconds * 1000)
                Write-OpenPathLog "Runtime dependency fast apply waiting up to $LockWaitTimeoutSeconds seconds for OpenPath update lock" -Level WARN
                $lockAcquired = $mutex.WaitOne($lockWaitTimeoutMs)
            }
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
            Write-OpenPathLog "OpenPath update lock was abandoned by a previous process - continuing runtime dependency fast apply" -Level WARN
        }

        if (-not $lockAcquired) {
            Write-OpenPathLog "Another OpenPath update is already running - skipping runtime dependency fast apply" -Level WARN
            return 1
        }

        Write-OpenPathLog "=== Starting runtime dependency fast apply ==="
        if (-not (Test-Path $whitelistPath -ErrorAction SilentlyContinue)) {
            Write-OpenPathLog "Runtime dependency fast apply skipped because local whitelist is missing" -Level WARN
            return 1
        }

        $config = Get-OpenPathConfig
        Sync-FirefoxNativeHostMirror -Config $config -WhitelistPath $whitelistPath
        $queueResult = Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $whitelistPath -PassThru
        $metrics['queueProcessedMs'] = [int]$queueResult.QueueProcessedMs
        $metrics['queueProcessed'] = [int]$queueResult.Processed
        $metrics['queueRejected'] = [int]$queueResult.Rejected
        $metrics['overlayWriteMs'] = [int]$queueResult.OverlayWriteMs
        $metrics['acrylicHostUpdateMs'] = [int]$queueResult.AcrylicHostUpdateMs
        $metrics['changed'] = [bool]$queueResult.Changed

        if ($queueResult.Changed) {
            $reloadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            Restart-AcrylicService | Out-Null
            $reloadStopwatch.Stop()
            $metrics['acrylicReloadMs'] = [int]$reloadStopwatch.ElapsedMilliseconds
        }

        Write-OpenPathLog ("Runtime dependency fast apply metrics: processed={0} rejected={1} changed={2} queueProcessedMs={3} overlayWriteMs={4} acrylicHostUpdateMs={5} acrylicReloadMs={6}" -f `
                $metrics['queueProcessed'], `
                $metrics['queueRejected'], `
                $metrics['changed'], `
                $metrics['queueProcessedMs'], `
                $metrics['overlayWriteMs'], `
                $metrics['acrylicHostUpdateMs'], `
                $metrics['acrylicReloadMs'])
        Write-OpenPathLog "=== Runtime dependency fast apply completed ==="
    }
    catch {
        Write-UpdateCatchLog "Runtime dependency fast apply failed: $_" -Level ERROR
        $exitCode = 1
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # Ignore if mutex ownership was not held at release time
            }
        }

        if ($mutex) {
            $mutex.Dispose()
        }
    }

    return [int]$exitCode
}

function Invoke-OpenPathUpdateCycle {
    <#
    .SYNOPSIS
    Runs a complete OpenPath update cycle: startup reconcile, whitelist download, and policy apply.
    .DESCRIPTION
    Acquires the update mutex, synchronizes machine client config, performs startup local reconcile,
    downloads the whitelist, and dispatches to the appropriate apply or failure handler. Rolls back
    to the backup whitelist on unhandled errors and reports failure health. The TriggerSource parameter
    controls whether protected-mode restore is skipped before the download (SSE path).
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = (Resolve-OpenPathWindowsRoot),

        [string]$UpdateMutexName = 'Global\OpenPathUpdateLock',

        [int]$LockWaitTimeoutSeconds = 45,

        [ValidateSet('Update', 'SSE')]
        [string]$TriggerSource = 'Update'
    )

    $OpenPathRoot = Resolve-OpenPathWindowsRoot -OpenPathRoot $OpenPathRoot
    Initialize-OpenPathUpdateRuntimeSession -OpenPathRoot $OpenPathRoot
    . (Join-Path $OpenPathRoot 'lib\internal\Update.Script.Config.ps1')
    . (Join-Path $OpenPathRoot 'lib\internal\Update.Script.Apply.ps1')
    . (Join-Path $OpenPathRoot 'lib\internal\Update.Script.Rollback.ps1')

    $mutex = $null
    $lockAcquired = $false
    $shouldRunUpdate = $true
    $exitCode = 0
    $config = $null
    $whitelistPath = Join-Path $OpenPathRoot 'data\whitelist.txt'
    $backupPath = Join-Path $OpenPathRoot 'data\whitelist.backup.txt'
    $staleFailsafeStatePath = Join-Path $OpenPathRoot 'data\stale-failsafe-state.json'

    try {
        $mutex = [System.Threading.Mutex]::new($false, $UpdateMutexName)
        try {
            $lockAcquired = $mutex.WaitOne(0)
            if (-not $lockAcquired -and $LockWaitTimeoutSeconds -gt 0) {
                $lockWaitTimeoutMs = [Math]::Max(0, $LockWaitTimeoutSeconds * 1000)
                Write-OpenPathLog "Waiting up to $LockWaitTimeoutSeconds seconds for the existing OpenPath update to finish" -Level WARN
                $lockAcquired = $mutex.WaitOne($lockWaitTimeoutMs)
            }
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
            Write-OpenPathLog "OpenPath update lock was abandoned by a previous process - continuing" -Level WARN
        }

        if (-not $lockAcquired) {
            Write-OpenPathLog "Another OpenPath update is already running - skipping this cycle" -Level WARN
            $shouldRunUpdate = $false
        }

        if ($shouldRunUpdate) {
            Write-OpenPathLog "=== Starting openpath update ==="

            $config = Get-OpenPathConfig
            $config = Sync-OpenPathMachineClientConfig -Config $config
            $portalActiveState = Write-OpenPathUpdatePortalActiveState `
                -OpenPathRoot $OpenPathRoot `
                -TriggerSource $TriggerSource
            $updateSettings = Get-OpenPathUpdatePolicySettings -Config $config
            $null = Invoke-OpenPathStartupLocalReconcile `
                -WhitelistPath $whitelistPath `
                -Config $config `
                -SkipProtectedModeRestore:($TriggerSource -eq 'SSE')
            $null = Backup-OpenPathWhitelistState `
                -WhitelistPath $whitelistPath `
                -BackupPath $backupPath `
                -EnableCheckpointRollback $updateSettings.EnableCheckpointRollback `
                -MaxCheckpoints $updateSettings.MaxCheckpoints

            $downloadResult = Get-OpenPathWhitelistDownloadResult -Config $config

            if ($downloadResult.DownloadFailed) {
                $null = Handle-OpenPathDownloadFailure `
                    -Config $config `
                    -WhitelistPath $whitelistPath `
                    -StaleFailsafeStatePath $staleFailsafeStatePath `
                    -StaleWhitelistMaxAgeHours $updateSettings.StaleWhitelistMaxAgeHours `
                    -EnableStaleFailsafe $updateSettings.EnableStaleFailsafe `
                    -HealthActionSuffix $portalActiveState.HealthAction
            }
            elseif ($downloadResult.Whitelist.PSObject.Properties['NotModified'] -and $downloadResult.Whitelist.NotModified) {
                $null = Handle-OpenPathNotModified `
                    -Config $config `
                    -WhitelistPath $whitelistPath `
                    -HealthActionSuffix $portalActiveState.HealthAction
            }
            elseif ($downloadResult.Whitelist.IsDisabled) {
                $null = Handle-OpenPathDisabledWhitelist `
                    -Config $config `
                    -WhitelistPath $whitelistPath `
                    -StaleFailsafeStatePath $staleFailsafeStatePath `
                    -HealthActionSuffix $portalActiveState.HealthAction
            }
            else {
                $null = Handle-OpenPathWhitelistApply `
                    -Config $config `
                    -Whitelist $downloadResult.Whitelist `
                    -WhitelistPath $whitelistPath `
                    -StaleFailsafeStatePath $staleFailsafeStatePath `
                    -HealthActionSuffix $portalActiveState.HealthAction
            }
        }
    }
    catch {
        Write-UpdateCatchLog "Update failed: $_" -Level ERROR
        $rollbackResult = Invoke-OpenPathUpdateRollback `
            -Config $config `
            -WhitelistPath $whitelistPath `
            -BackupPath $backupPath `
            -StaleFailsafeStatePath $staleFailsafeStatePath
        $null = Send-OpenPathUpdateFailureHealth `
            -RollbackSucceeded $rollbackResult.RollbackSucceeded `
            -RollbackMethod $rollbackResult.RollbackMethod

        $exitCode = 1
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # Ignore if mutex ownership was not held at release time
            }
        }

        if ($mutex) {
            $mutex.Dispose()
        }
    }

    return [int]$exitCode
}

function Write-OpenPathUpdatePortalActiveState {
    <#
    .SYNOPSIS
    Records a JSON state file when an update cycle starts while captive portal mode is active.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = (Resolve-OpenPathWindowsRoot),

        [ValidateSet('Update', 'SSE')]
        [string]$TriggerSource = 'Update'
    )

    $result = [ordered]@{
        Active = $false
        HealthAction = ''
    }

    try {
        if (-not (Test-OpenPathCaptivePortalModeActive)) {
            return [PSCustomObject]$result
        }

        $marker = Get-OpenPathCaptivePortalMarker
        $statePath = Join-Path $OpenPathRoot 'data\update-portal-active-state.json'
        $state = if ($marker -and $marker.PSObject.Properties['state']) { [string]$marker.state } else { 'Unknown' }
        $since = if ($marker -and $marker.PSObject.Properties['since']) { [string]$marker.since } else { '' }
        $healthAction = if ($TriggerSource -eq 'SSE') { 'sse_update_while_portal_active' } else { 'update_while_portal_active' }

        $dir = Split-Path $statePath -Parent
        if (-not (Test-Path $dir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        @{
            active = $true
            triggerSource = $TriggerSource
            state = $state
            since = $since
            observedAt = (Get-Date).ToString('o')
            healthAction = $healthAction
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $statePath -Encoding UTF8 -Force

        Write-OpenPathLog "OpenPath $TriggerSource update observed while captive portal mode is active (state=$state)" -Level WARN

        $result['Active'] = $true
        $result['HealthAction'] = $healthAction
    }
    catch {
        Write-OpenPathLog "Failed to record update portal-active state: $_" -Level WARN
    }

    return [PSCustomObject]$result
}

function Clear-StaleFailsafeState {
    <#
    .SYNOPSIS
    Removes the stale fail-safe marker file when it exists.
    #>
    [CmdletBinding()]
    param(
        [string]$StaleFailsafeStatePath = 'C:\OpenPath\data\stale-failsafe-state.json'
    )

    if (Test-Path $StaleFailsafeStatePath) {
        Remove-Item $StaleFailsafeStatePath -Force -ErrorAction SilentlyContinue
        Write-OpenPathLog "Cleared stale fail-safe marker"
    }
}

function Enter-StaleWhitelistFailsafe {
    <#
    .SYNOPSIS
    Activates stale-whitelist fail-safe mode by narrowing Acrylic to control domains and persisting a state marker.
    .DESCRIPTION
    Derives control domains from the config whitelist and API URLs, then updates the Acrylic host
    configuration to allow only those domains. Writes a fail-safe state file with the entry timestamp
    and whitelist age so downstream logic can detect and exit the fail-safe state.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [double]$WhitelistAgeHours,

        [string]$StaleFailsafeStatePath = 'C:\OpenPath\data\stale-failsafe-state.json'
    )

    $controlDomains = @()
    $whitelistHost = Get-HostFromUrl -Url $Config.whitelistUrl
    if ($whitelistHost) {
        $controlDomains += $whitelistHost
    }

    if ($Config.PSObject.Properties['apiUrl']) {
        $apiHost = Get-HostFromUrl -Url $Config.apiUrl
        if ($apiHost) {
            $controlDomains += $apiHost
        }
    }

    $controlDomains = @($controlDomains | Where-Object { $_ } | Sort-Object -Unique)

    Write-OpenPathLog "Entering stale-whitelist fail-safe mode (age=$WhitelistAgeHours h)" -Level WARN
    Update-AcrylicHost -WhitelistedDomains $controlDomains -BlockedSubdomains @()
    Restore-OpenPathProtectedMode -Config $Config | Out-Null

    @{
        enteredAt = (Get-Date -Format 'o')
        whitelistAgeHours = [Math]::Round($WhitelistAgeHours, 2)
        controlDomains = $controlDomains
    } | ConvertTo-Json -Depth 8 | Set-Content $StaleFailsafeStatePath -Encoding UTF8

    Write-OpenPathLog "Stale fail-safe active. Control domains: $($controlDomains -join ', ')" -Level WARN
}

function Restore-OpenPathCheckpoint {
    <#
    .SYNOPSIS
    Restores the latest whitelist checkpoint and clears the stale fail-safe marker on success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [string]$WhitelistPath = 'C:\OpenPath\data\whitelist.txt',

        [string]$StaleFailsafeStatePath = 'C:\OpenPath\data\stale-failsafe-state.json'
    )

    $restoreResult = Restore-OpenPathLatestCheckpoint -Config $Config -WhitelistPath $WhitelistPath
    if (-not $restoreResult.Success) {
        if ($restoreResult.Error) {
            Write-OpenPathLog $restoreResult.Error -Level WARN
        }
        else {
            Write-OpenPathLog 'Checkpoint rollback failed for unknown reason' -Level WARN
        }
        return $false
    }

    if (-not $Config) {
        return
    }

    try {
        Clear-StaleFailsafeState -StaleFailsafeStatePath $StaleFailsafeStatePath
        Write-OpenPathLog "Checkpoint rollback applied from $($restoreResult.CheckpointPath)" -Level WARN
        return $true
    }
    catch {
        Write-OpenPathLog "Checkpoint rollback failed: $_" -Level WARN
        return $false
    }
}

function Write-UpdateCatchLog {
    <#
    .SYNOPSIS
    Writes a log message using the shared logger when available, or falls back to host output streams.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
        Write-OpenPathLog -Message $Message -Level $Level
        return
    }

    $fallbackEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] [Update-OpenPath.ps1] [PID:$PID] $Message"
    switch ($Level) {
        'ERROR' { Write-Error $fallbackEntry -ErrorAction Continue }
        'WARN' { Write-Warning $fallbackEntry }
        default { Write-Information $fallbackEntry -InformationAction Continue }
    }
}

function Sync-FirefoxNativeHostMirror {
    <#
    .SYNOPSIS
    Synchronizes the Firefox native host whitelist mirror, suppressing errors to avoid blocking the update cycle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [string]$WhitelistPath = 'C:\OpenPath\data\whitelist.txt',

        [switch]$ClearWhitelist
    )

    try {
        Sync-OpenPathFirefoxNativeHostState -Config $Config -WhitelistPath $WhitelistPath -ClearWhitelist:$ClearWhitelist | Out-Null
    }
    catch {
        Write-OpenPathLog "Firefox native host mirror sync failed: $_" -Level WARN
    }
}

Export-ModuleMember -Function @(
    'Initialize-OpenPathUpdateRuntimeSession',
    'Invoke-OpenPathUpdateCycle',
    'Clear-StaleFailsafeState',
    'Enter-StaleWhitelistFailsafe',
    'Restore-OpenPathCheckpoint',
    'Write-UpdateCatchLog',
    'Write-OpenPathUpdatePortalActiveState',
    'Invoke-OpenPathRuntimeDependencyQueueApply',
    'Invoke-OpenPathRuntimeDependencyFastApply',
    'Sync-FirefoxNativeHostMirror'
)
