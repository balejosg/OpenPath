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
    }
}

function New-OpenPathFakeTaskRunner {
    param(
        [hashtable]$RunResults = @{},
        [hashtable]$WaitResults = @{},
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
            return @{
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
