function Test-NativeHostRuntimeDependencyOverlayContainsDomains {
    <#
    .SYNOPSIS
    Returns true when all supplied domains appear as dependency hosts in the runtime dependency overlay file.
    #>
    param([string[]]$Domains = @())

    if (@($Domains).Count -eq 0) {
        return $true
    }

    $path = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $script:OpenPathRoot
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $entryHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($parsed.entries)) {
            if ($entry.PSObject.Properties['dependencyHost'] -and $entry.dependencyHost) {
                [void]$entryHosts.Add(([string]$entry.dependencyHost).Trim().Trim('.').ToLowerInvariant())
            }
        }

        foreach ($domain in @($Domains)) {
            $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $domain
            if (-not $normalized -or -not $entryHosts.Contains($normalized)) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-NativeHostLog "Failed to inspect runtime dependency overlay: $_"
        return $false
    }
}

function Test-NativeHostRuntimeDependencyQueueRequestProcessed {
    <#
    .SYNOPSIS
    Returns true when the given queue request file no longer exists, indicating the request was processed.
    #>
    param([AllowNull()][string]$RequestPath = '')

    if ([string]::IsNullOrWhiteSpace($RequestPath)) {
        return $true
    }

    return -not (Test-Path $RequestPath -ErrorAction SilentlyContinue)
}

function Resolve-NativeHostLocalRuntimeDependencyCandidate {
    <#
    .SYNOPSIS
    Evaluates a dependency candidate message against the current whitelist and state to determine its validity.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    return (Test-OpenPathRuntimeDependencyCandidate `
            -Message $Message `
            -WhitelistedDomains @($Sections.Whitelist) `
            -BlockedSubdomains @($Sections.BlockedSubdomains) `
            -State $State)
}

function Invoke-NativeHostLocalRuntimeDependencyAction {
    <#
    .SYNOPSIS
    Queues a single runtime dependency request and triggers the update task, waiting for the dependency to be applied.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $Message -State $State -Sections $Sections
    if ($candidate.Valid -ne $true) {
        return $candidate.Result
    }

    $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $requestPath = Write-OpenPathRuntimeDependencyQueueRequest `
        -AnchorHost $candidate.AnchorHost `
        -DependencyHost $candidate.DependencyHost `
        -RequestType $candidate.RequestType
    $queueWriteStopwatch.Stop()

    $updateResult = Invoke-UpdateTask `
        -RuntimeDependencyDomains @($candidate.DependencyHost) `
        -RuntimeDependencyRequestPath $requestPath `
        -TimeoutSeconds 14
    if ($updateResult.success -ne $true) {
        return @{
            success = $false
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
            error = $updateResult.error
        }
    }

    return @{
        success = $true
        action = $script:OpenPathRuntimeDependencyActionAllowLocal
        anchorHost = $candidate.AnchorHost
        dependencyHost = $candidate.DependencyHost
        requestType = $candidate.RequestType
        queued = $true
        requestPath = $requestPath
        queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
        updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
    }
}

function Invoke-NativeHostLocalRuntimeDependencyBatchAction {
    <#
    .SYNOPSIS
    Queues multiple runtime dependency requests from a batch message and triggers a single update task for all of them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $entries = @($Message.entries)
    if ($entries.Count -eq 0) {
        return @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch; error = 'Invalid runtime dependency batch payload'; results = @() }
    }

    $results = @()
    $queuedResults = @()
    $queuedDependencyHosts = @()
    $updateResult = $null

    foreach ($entry in @($entries | Select-Object -First $script:OpenPathRuntimeDependencyBatchMaxEntries)) {
        $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $entry -State $State -Sections $Sections
        if ($candidate.Valid -ne $true) {
            $results += $candidate.Result
            continue
        }

        $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $requestPath = Write-OpenPathRuntimeDependencyQueueRequest `
            -AnchorHost $candidate.AnchorHost `
            -DependencyHost $candidate.DependencyHost `
            -RequestType $candidate.RequestType
        $queueWriteStopwatch.Stop()
        $result = @{
            success = $true
            action = $script:OpenPathRuntimeDependencyActionAllowLocal
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
        }
        $results += $result
        $queuedResults += $result
        $queuedDependencyHosts += $candidate.DependencyHost
    }

    if ($entries.Count -gt $script:OpenPathRuntimeDependencyBatchMaxEntries) {
        $results += @{ success = $false; action = $script:OpenPathRuntimeDependencyActionAllowLocal; error = 'Runtime dependency batch limit exceeded' }
    }

    if ($queuedDependencyHosts.Count -gt 0) {
        $queuedDependencyHosts = @($queuedDependencyHosts | Sort-Object -Unique)
        $updateResult = Invoke-UpdateTask `
            -RuntimeDependencyDomains $queuedDependencyHosts `
            -TimeoutSeconds 14
        if ($updateResult.success -ne $true) {
            foreach ($result in $queuedResults) {
                $result.success = $false
                $result.error = $updateResult.error
            }
        }
        foreach ($result in $queuedResults) {
            $result.updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            $result.updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            $result.updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            $result.runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            $result.runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            $result.updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        }
    }

    $failedResults = @($results | Where-Object { $_.success -ne $true })
    return @{
        success = ($failedResults.Count -eq 0)
        action = $script:OpenPathRuntimeDependencyActionAllowLocalBatch
        count = $results.Count
        queuedCount = $queuedResults.Count
        queueWriteMs = [int](@($queuedResults | ForEach-Object { if ($_.ContainsKey('queueWriteMs')) { [int]$_.queueWriteMs } else { 0 } } | Measure-Object -Sum).Sum)
        updateTriggerMs = if ($updateResult -and $updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult -and $updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult -and $updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        updateTaskName = if ($updateResult -and $updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        results = $results
    }
}

function Invoke-NativeHostSharedUpdateTrigger {
    <#
    .SYNOPSIS
    Coordinates update triggering so only one caller triggers the task while others wait on the same result.
    .DESCRIPTION
    Acquires a non-blocking mutex to elect one caller as the trigger. The elected caller runs TriggerAction;
    all other concurrent callers run WaitAction instead.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$TriggerAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$WaitAction
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\OpenPathNativeWhitelistUpdateTrigger')
        try {
            $lockAcquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if ($lockAcquired) {
            $triggerResult = & $TriggerAction
            if (
                $triggerResult -is [System.Collections.IDictionary] -and
                $triggerResult.ContainsKey('success')
            ) {
                return $triggerResult
            }
        }

        return (& $WaitAction)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # Ignore if mutex ownership was already released by the runtime.
            }
        }

        if ($mutex) {
            $mutex.Dispose()
        }
    }
}

function Invoke-UpdateTask {
    <#
    .SYNOPSIS
    Triggers the appropriate scheduled update task and waits for the expected domains and overlay entries to appear.
    .DESCRIPTION
    When RuntimeDependencyDomains are provided, prefers the runtime dependency fast-apply task.
    Uses shared update trigger coordination to avoid duplicate task triggers from concurrent callers.
    #>
    param(
        [string[]]$Domains = @(),
        [string[]]$RuntimeDependencyDomains = @(),
        [AllowNull()][string]$RuntimeDependencyRequestPath = '',
        [int]$TimeoutSeconds = 45
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $hasRuntimeDependencyWait = @($RuntimeDependencyDomains).Count -gt 0
        if ((-not $hasRuntimeDependencyWait) -and (Test-NativeWhitelistContainsDomains -Domains $Domains)) {
            $result = @{
                success = $true
                action = 'update-whitelist'
                message = 'OpenPath update task triggered'
                domains = @($Domains)
            }
        }
        else {
            $triggeredTaskName = if (
                $hasRuntimeDependencyWait -and
                (Get-Variable -Name RuntimeDependencyTaskName -Scope Script -ErrorAction SilentlyContinue) -and
                -not [string]::IsNullOrWhiteSpace($script:RuntimeDependencyTaskName)
            ) {
                [string]$script:RuntimeDependencyTaskName
            }
            else {
                [string]$script:UpdateTaskName
            }
            $triggerState = @{
                TaskName = $triggeredTaskName
                Fallback = $false
                TriggerMs = 0
            }
            $result = Invoke-NativeHostSharedUpdateTrigger `
                -TriggerAction {
                    $taskResult = Invoke-OpenPathScheduledTask `
                        -TaskName $triggerState['TaskName'] `
                        -FallbackTaskName $script:UpdateTaskName `
                        -ShouldFallback $hasRuntimeDependencyWait `
                        -Runner (Get-NativeHostTaskRunner) `
                        -TimeoutSeconds $TimeoutSeconds `
                        -WaitCondition {
                            $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                            $runtimeDependencyReady = (
                                (Test-NativeHostRuntimeDependencyQueueRequestProcessed -RequestPath $RuntimeDependencyRequestPath) -and
                                (
                                    -not [string]::IsNullOrWhiteSpace($RuntimeDependencyRequestPath) -or
                                    (Test-NativeHostRuntimeDependencyOverlayContainsDomains -Domains $RuntimeDependencyDomains)
                                )
                            )
                            return ($whitelistReady -and $runtimeDependencyReady)
                        }
                    $triggerState['Fallback'] = [bool]$taskResult.fallback
                    $triggerState['TaskName'] = [string]$taskResult.taskName
                    $triggerState['TriggerMs'] = [int]$taskResult.triggerMs

                    if ($taskResult.success -ne $true) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = if ($taskResult.ContainsKey('timedOut') -and $taskResult.timedOut) { "OpenPath update task did not write expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')" } elseif ($taskResult.ContainsKey('error')) { [string]$taskResult.error } else { 'Scheduled task update failed' }
                            domains = @($Domains)
                            runtimeDependencyFastPath = $hasRuntimeDependencyWait
                            runtimeDependencyFallback = [bool]$taskResult.fallback
                            updateTaskName = [string]$taskResult.taskName
                            updateTriggerMs = [int]$taskResult.triggerMs
                            updateWaitMs = [int]$taskResult.waitMs
                        }
                    }

                    $taskRunnerResult = @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task wrote expected domains'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$taskResult.fallback
                        updateTaskName = [string]$taskResult.taskName
                        updateTriggerMs = [int]$taskResult.triggerMs
                        updateWaitMs = [int]$taskResult.waitMs
                    }
                    return $taskRunnerResult
                } `
                -WaitAction {
                    $waitRunner = Get-NativeHostTaskRunner
                    $waitResult = & $waitRunner.WaitFor $triggerState['TaskName'] {
                        $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                        $runtimeDependencyReady = (
                            (Test-NativeHostRuntimeDependencyQueueRequestProcessed -RequestPath $RuntimeDependencyRequestPath) -and
                            (
                                -not [string]::IsNullOrWhiteSpace($RuntimeDependencyRequestPath) -or
                                (Test-NativeHostRuntimeDependencyOverlayContainsDomains -Domains $RuntimeDependencyDomains)
                            )
                        )
                        return ($whitelistReady -and $runtimeDependencyReady)
                    } $TimeoutSeconds 1000

                    if ($waitResult.success -ne $true) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = "OpenPath update task did not write expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')"
                            domains = @($Domains)
                            runtimeDependencyFastPath = $hasRuntimeDependencyWait
                            runtimeDependencyFallback = [bool]$triggerState['Fallback']
                            updateTaskName = [string]$triggerState['TaskName']
                            updateTriggerMs = [int]$triggerState['TriggerMs']
                            updateWaitMs = if ($waitResult.ContainsKey('elapsedMs')) { [int]$waitResult.elapsedMs } else { 0 }
                        }
                    }

                    return @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task wrote expected domains'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$triggerState['Fallback']
                        updateTaskName = [string]$triggerState['TaskName']
                        updateTriggerMs = [int]$triggerState['TriggerMs']
                        updateWaitMs = if ($waitResult.ContainsKey('elapsedMs')) { [int]$waitResult.elapsedMs } else { 0 }
                    }
                }
        }
    }
    catch {
        $result = @{
            success = $false
            action = 'update-whitelist'
            error = [string]$_
            domains = @($Domains)
        }
    }

    $stopwatch.Stop()
    $logMessage = ''
    if ($result.ContainsKey('message')) {
        $logMessage = [string]$result.message
    }
    $logError = ''
    if ($result.ContainsKey('error')) {
        $logError = [string]$result.error
    }

    Write-NativeHostActionLog -Action 'update-whitelist' `
        -Domains $Domains `
        -Success ($result.success -eq $true) `
        -Message $logMessage `
        -ErrorMessage $logError `
        -ElapsedMs $stopwatch.ElapsedMilliseconds

    $result['elapsedMs'] = [int]$stopwatch.ElapsedMilliseconds
    return $result
}
