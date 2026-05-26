function ConvertTo-OpenPathTaskResultHex {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }

    try {
        return ('0x{0:X8}' -f ([uint32]([long]$Value -band 0xffffffff)))
    }
    catch {
        return ''
    }
}

function Get-OpenPathScheduledTaskDiagnostics {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $diagnostics = @{
        taskState = ''
        taskLastResult = $null
        taskLastResultHex = ''
        taskLastRunTime = ''
        taskNextRunTime = ''
        taskNumberOfMissedRuns = $null
        taskDiagnosticsError = ''
    }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and $task.PSObject.Properties['State']) {
            $diagnostics.taskState = [string]$task.State
        }

        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($taskInfo) {
            if ($taskInfo.PSObject.Properties['LastTaskResult']) {
                $diagnostics.taskLastResult = [long]$taskInfo.LastTaskResult
                $diagnostics.taskLastResultHex = ConvertTo-OpenPathTaskResultHex -Value $taskInfo.LastTaskResult
            }
            if ($taskInfo.PSObject.Properties['LastRunTime'] -and $taskInfo.LastRunTime) {
                $diagnostics.taskLastRunTime = ([DateTime]$taskInfo.LastRunTime).ToString('o')
            }
            if ($taskInfo.PSObject.Properties['NextRunTime'] -and $taskInfo.NextRunTime) {
                $diagnostics.taskNextRunTime = ([DateTime]$taskInfo.NextRunTime).ToString('o')
            }
            if ($taskInfo.PSObject.Properties['NumberOfMissedRuns']) {
                $diagnostics.taskNumberOfMissedRuns = [int]$taskInfo.NumberOfMissedRuns
            }
        }
    }
    catch {
        $diagnostics.taskDiagnosticsError = [string]$_
    }

    return $diagnostics
}

function Add-OpenPathScheduledTaskDiagnostics {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Result,
        [AllowNull()][object]$Runner,
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    $diagnostics = $null
    try {
        if ($Runner -and $Runner.PSObject.Properties['GetDiagnostics']) {
            $diagnostics = & $Runner.GetDiagnostics $TaskName
        }
    }
    catch {
        $diagnostics = @{ taskDiagnosticsError = [string]$_ }
    }

    if (-not $diagnostics) {
        $diagnostics = Get-OpenPathScheduledTaskDiagnostics -TaskName $TaskName
    }

    foreach ($key in @(
            'taskState',
            'taskLastResult',
            'taskLastResultHex',
            'taskLastRunTime',
            'taskNextRunTime',
            'taskNumberOfMissedRuns',
            'taskDiagnosticsError'
        )) {
        if ($diagnostics -is [System.Collections.IDictionary] -and $diagnostics.ContainsKey($key)) {
            $Result[$key] = $diagnostics[$key]
        }
        elseif ($diagnostics.PSObject.Properties[$key]) {
            $Result[$key] = $diagnostics.$key
        }
    }

    return $Result
}

function New-OpenPathSchtasksRunner {
    [PSCustomObject]@{
        RunTask = {
            param([string]$TaskName)
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $null = & schtasks.exe /Run /TN $TaskName 2>$null
            $exitCode = $LASTEXITCODE
            $stopwatch.Stop()

            @{
                success = ($exitCode -eq 0)
                exitCode = [int]$exitCode
                elapsedMs = [int]$stopwatch.ElapsedMilliseconds
                error = if ($exitCode -eq 0) { '' } else { "schtasks exit code $exitCode" }
            }
        }
        WaitFor = {
            param(
                [string]$TaskName,
                [scriptblock]$Condition,
                [int]$TimeoutSeconds,
                [int]$PollMilliseconds
            )

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds $PollMilliseconds
                if (& $Condition) {
                    $stopwatch.Stop()
                    return @{
                        success = $true
                        taskName = $TaskName
                        timedOut = $false
                        elapsedMs = [int]$stopwatch.ElapsedMilliseconds
                    }
                }
            }

            $stopwatch.Stop()
            @{
                success = $false
                taskName = $TaskName
                timedOut = $true
                elapsedMs = [int]$stopwatch.ElapsedMilliseconds
                error = 'Timed out waiting for task condition'
            }
        }
        GetDiagnostics = {
            param([string]$TaskName)
            Get-OpenPathScheduledTaskDiagnostics -TaskName $TaskName
        }
    }
}

function New-OpenPathFakeTaskRunner {
    param(
        [hashtable]$RunResults = @{},
        [hashtable]$WaitResults = @{},
        [hashtable]$Diagnostics = @{},
        [scriptblock]$OnRun = $null
    )

    [PSCustomObject]@{
        RunTask = {
            param([string]$TaskName)
            if ($OnRun) { & $OnRun $TaskName }
            if ($RunResults.ContainsKey($TaskName)) {
                return $RunResults[$TaskName]
            }

            @{ success = $true; exitCode = 0; elapsedMs = 0; error = '' }
        }.GetNewClosure()
        WaitFor = {
            param(
                [string]$TaskName,
                [scriptblock]$Condition,
                [int]$TimeoutSeconds,
                [int]$PollMilliseconds
            )

            if ($WaitResults.ContainsKey($TaskName)) {
                return $WaitResults[$TaskName]
            }
            if ($Condition -and (& $Condition)) {
                return @{ success = $true; taskName = $TaskName; timedOut = $false; elapsedMs = 0 }
            }

            @{ success = $false; taskName = $TaskName; timedOut = $true; elapsedMs = ($TimeoutSeconds * 1000); error = 'Timed out waiting for task condition' }
        }.GetNewClosure()
        GetDiagnostics = {
            param([string]$TaskName)
            if ($Diagnostics.ContainsKey($TaskName)) {
                return $Diagnostics[$TaskName]
            }

            return @{}
        }.GetNewClosure()
    }
}

function Invoke-OpenPathScheduledTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [AllowNull()]
        [string]$FallbackTaskName = '',

        [bool]$ShouldFallback = $false,

        [object]$Runner = $null,

        [int]$TimeoutSeconds = 0,

        [scriptblock]$WaitCondition = $null,

        [int]$PollMilliseconds = 1000
    )

    if (-not $Runner) {
        $Runner = New-OpenPathSchtasksRunner
    }

    $selectedTaskName = $TaskName
    $fallback = $false
    $runResult = & $Runner.RunTask $selectedTaskName
    if (
        $runResult.success -ne $true -and
        $ShouldFallback -and
        -not [string]::IsNullOrWhiteSpace($FallbackTaskName) -and
        $FallbackTaskName -ne $selectedTaskName
    ) {
        $fallback = $true
        $selectedTaskName = $FallbackTaskName
        $runResult = & $Runner.RunTask $selectedTaskName
    }

    $triggerMs = if ($runResult.ContainsKey('elapsedMs')) { [int]$runResult.elapsedMs } else { 0 }
    if ($runResult.success -ne $true) {
        return @{
            success = $false
            taskName = $selectedTaskName
            fallback = $fallback
            exitCode = if ($runResult.ContainsKey('exitCode')) { [int]$runResult.exitCode } else { 1 }
            triggerMs = $triggerMs
            waitMs = 0
            elapsedMs = $triggerMs
            error = if ($runResult.ContainsKey('error') -and $runResult.error) { [string]$runResult.error } else { 'Scheduled task trigger failed' }
        }
    }

    if ($WaitCondition) {
        $waitResult = & $Runner.WaitFor $selectedTaskName $WaitCondition $TimeoutSeconds $PollMilliseconds
        $waitMs = if ($waitResult.ContainsKey('elapsedMs')) { [int]$waitResult.elapsedMs } else { 0 }
        if ($waitResult.success -ne $true) {
            $result = @{
                success = $false
                taskName = $selectedTaskName
                fallback = $fallback
                exitCode = if ($runResult.ContainsKey('exitCode')) { [int]$runResult.exitCode } else { 0 }
                triggerMs = $triggerMs
                waitMs = $waitMs
                elapsedMs = ($triggerMs + $waitMs)
                timedOut = if ($waitResult.ContainsKey('timedOut')) { [bool]$waitResult.timedOut } else { $false }
                error = if ($waitResult.ContainsKey('error') -and $waitResult.error) { [string]$waitResult.error } else { 'Scheduled task wait failed' }
            }
            return (Add-OpenPathScheduledTaskDiagnostics -Result $result -Runner $Runner -TaskName $selectedTaskName)
        }

        return @{
            success = $true
            taskName = $selectedTaskName
            fallback = $fallback
            exitCode = if ($runResult.ContainsKey('exitCode')) { [int]$runResult.exitCode } else { 0 }
            triggerMs = $triggerMs
            waitMs = $waitMs
            elapsedMs = ($triggerMs + $waitMs)
        }
    }

    @{
        success = $true
        taskName = $selectedTaskName
        fallback = $fallback
        exitCode = if ($runResult.ContainsKey('exitCode')) { [int]$runResult.exitCode } else { 0 }
        triggerMs = $triggerMs
        waitMs = 0
        elapsedMs = $triggerMs
    }
}
