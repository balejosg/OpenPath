# OpenPath Windows update runtime helpers

$script:OpenPathUpdateRuntimeSessionInitialized = $false
$script:OpenPathUpdateRuntimeRoot = ''

function Import-OpenPathUpdateRuntimeHelper {
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
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = 'C:\OpenPath'
    )

    if (
        $script:OpenPathUpdateRuntimeSessionInitialized -and
        $script:OpenPathUpdateRuntimeRoot -eq $OpenPathRoot
    ) {
        return
    }

    Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force
    Initialize-OpenPathScriptSession `
        -OpenPathRoot $OpenPathRoot `
        -DependentModules @('DNS', 'Firewall', 'Browser') `
        -RequiredCommands @(
        'Write-OpenPathLog',
        'Get-OpenPathConfig',
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
        'Get-OpenPathCapabilityStoragePath',
        'Update-AcrylicHost',
        'Restart-AcrylicService',
        'Clear-OpenPathRuntimeDependencyOverlay',
        'Restore-OriginalDNS',
        'Remove-OpenPathFirewall',
        'Remove-BrowserPolicy',
        'Set-AllBrowserPolicy'
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

function Invoke-OpenPathRuntimeDependencyQueueApply {
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
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = 'C:\OpenPath',

        [string]$UpdateMutexName = 'Global\OpenPathUpdateLock',

        [int]$LockWaitTimeoutSeconds = 20
    )

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
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = 'C:\OpenPath',

        [string]$UpdateMutexName = 'Global\OpenPathUpdateLock',

        [int]$LockWaitTimeoutSeconds = 45
    )

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
            $updateSettings = Get-OpenPathUpdatePolicySettings -Config $config
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
                    -EnableStaleFailsafe $updateSettings.EnableStaleFailsafe
            }
            elseif ($downloadResult.Whitelist.PSObject.Properties['NotModified'] -and $downloadResult.Whitelist.NotModified) {
                $null = Handle-OpenPathNotModified -Config $config -WhitelistPath $whitelistPath
            }
            elseif ($downloadResult.Whitelist.IsDisabled) {
                $null = Handle-OpenPathDisabledWhitelist `
                    -Config $config `
                    -WhitelistPath $whitelistPath `
                    -StaleFailsafeStatePath $staleFailsafeStatePath
            }
            else {
                $null = Handle-OpenPathWhitelistApply `
                    -Config $config `
                    -Whitelist $downloadResult.Whitelist `
                    -WhitelistPath $whitelistPath `
                    -StaleFailsafeStatePath $staleFailsafeStatePath
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

function Clear-StaleFailsafeState {
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
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
    'Invoke-OpenPathRuntimeDependencyQueueApply',
    'Invoke-OpenPathRuntimeDependencyFastApply',
    'Sync-FirefoxNativeHostMirror'
)
