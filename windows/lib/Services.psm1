# OpenPath Services Module for Windows
# Manages Task Scheduler tasks for periodic updates

# Import common functions
$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot 'internal\ScheduledTaskCatalog.ps1')
. (Join-Path $PSScriptRoot 'internal\TaskRunner.ps1')
. (Join-Path $PSScriptRoot 'internal\Services.TaskBuilders.ps1')

$script:ScheduledTaskCatalog = Get-OpenPathScheduledTaskCatalog
$script:TaskPrefix = $script:ScheduledTaskCatalog.Prefix
$script:UsersRunTaskAce = $script:ScheduledTaskCatalog.UsersRunTaskAce

function Grant-OpenPathTaskRunAccessToUsers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    try {
        $schedule = New-Object -ComObject 'Schedule.Service'
        $schedule.Connect()
        $task = $schedule.GetFolder('\').GetTask($TaskName)
        $currentSecurityDescriptor = [string]$task.GetSecurityDescriptor(0xF)

        if ($currentSecurityDescriptor.Contains($script:UsersRunTaskAce)) {
            return $true
        }

        $updatedSecurityDescriptor = if ($currentSecurityDescriptor -match '^(.*?D:)(.*)$') {
            "$($Matches[1])$script:UsersRunTaskAce$($Matches[2])"
        }
        else {
            "D:$script:UsersRunTaskAce$currentSecurityDescriptor"
        }

        $task.SetSecurityDescriptor($updatedSecurityDescriptor, 0)
        Write-OpenPathLog "Granted BUILTIN\\Users read/execute access to scheduled task $TaskName"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to grant BUILTIN\\Users access to scheduled task $TaskName : $_" -Level WARN
        return $false
    }
}

function Register-OpenPathTask {
    <#
    .SYNOPSIS
        Registers all scheduled tasks for whitelist system
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$UpdateIntervalMinutes = 15,
        [int]$WatchdogIntervalMinutes = 1
    )

    if (-not $PSCmdlet.ShouldProcess("Task Scheduler", "Register OpenPath scheduled tasks")) {
        return $false
    }

    Write-OpenPathLog "Registering scheduled tasks..."

    $openPathRoot = "C:\OpenPath"
    $updatePrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $updateSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $updateDefinition = New-OpenPathUpdateTaskDefinition `
        -OpenPathRoot $openPathRoot `
        -UpdateIntervalMinutes $UpdateIntervalMinutes `
        -Principal $updatePrincipal `
        -DefaultSettings $updateSettings
    Register-OpenPathTaskDefinition -Definition $updateDefinition
    Grant-OpenPathTaskRunAccessToUsers -TaskName $updateDefinition.TaskName | Out-Null
    Write-OpenPathLog "Registered: $($updateDefinition.TaskName) (every $UpdateIntervalMinutes min)"

    $runtimeDependencyDefinition = New-OpenPathRuntimeDependencyApplyTaskDefinition `
        -OpenPathRoot $openPathRoot `
        -Principal $updatePrincipal
    Register-OpenPathTaskDefinition -Definition $runtimeDependencyDefinition
    Grant-OpenPathTaskRunAccessToUsers -TaskName $runtimeDependencyDefinition.TaskName | Out-Null
    Write-OpenPathLog "Registered: $($runtimeDependencyDefinition.TaskName) (on demand runtime dependencies)"

    $captivePortalRecoverySpec = Get-OpenPathScheduledTaskSpec -TaskType CaptivePortalRecovery
    $captivePortalRecoveryAction = New-OpenPathTaskAction -Target (Join-OpenPathTaskScriptPath -OpenPathRoot $openPathRoot -RelativePath $captivePortalRecoverySpec.Script)
    $captivePortalRecoveryTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
    $captivePortalRecoverySettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 1 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    $captivePortalRecoveryDefinition = New-OpenPathTaskDefinition `
        -TaskName $captivePortalRecoverySpec.Name `
        -Action $captivePortalRecoveryAction `
        -Trigger $captivePortalRecoveryTrigger `
        -Principal $updatePrincipal `
        -Settings $captivePortalRecoverySettings
    Register-OpenPathTaskDefinition -Definition $captivePortalRecoveryDefinition
    Grant-OpenPathTaskRunAccessToUsers -TaskName $captivePortalRecoveryDefinition.TaskName | Out-Null
    Write-OpenPathLog "Registered: $($captivePortalRecoveryDefinition.TaskName) (on demand captive portal recovery)"

    $watchdogDefinition = New-OpenPathWatchdogTaskDefinition `
        -OpenPathRoot $openPathRoot `
        -WatchdogIntervalMinutes $WatchdogIntervalMinutes `
        -Principal $updatePrincipal `
        -DefaultSettings $updateSettings
    Register-OpenPathTaskDefinition -Definition $watchdogDefinition
    Write-OpenPathLog "Registered: $($watchdogDefinition.TaskName) (every $WatchdogIntervalMinutes min)"

    $startupDefinition = New-OpenPathStartupTaskDefinition `
        -OpenPathRoot $openPathRoot `
        -Principal $updatePrincipal `
        -DefaultSettings $updateSettings
    Register-OpenPathTaskDefinition -Definition $startupDefinition
    Write-OpenPathLog "Registered: $($startupDefinition.TaskName) (at boot)"

    $sseDefinition = New-OpenPathSseTaskDefinition `
        -OpenPathRoot $openPathRoot `
        -Principal $updatePrincipal
    Register-OpenPathTaskDefinition -Definition $sseDefinition
    Write-OpenPathLog "Registered: $($sseDefinition.TaskName) (persistent SSE listener)"

    $agentUpdateDefinition = New-OpenPathAgentUpdateTaskDefinition `
        -OpenPathRoot $openPathRoot `
        -Principal $updatePrincipal
    Register-OpenPathTaskDefinition -Definition $agentUpdateDefinition
    Write-OpenPathLog "Registered: $($agentUpdateDefinition.TaskName) (daily silent software update)"

    return $true
}

function Unregister-OpenPathTask {
    <#
    .SYNOPSIS
        Removes all whitelist scheduled tasks
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Task Scheduler", "Remove OpenPath scheduled tasks")) {
        return
    }

    Write-OpenPathLog "Removing scheduled tasks..."

    $tasks = Get-ScheduledTask -TaskName "$script:TaskPrefix-*" -ErrorAction SilentlyContinue
    
    foreach ($task in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
            Write-OpenPathLog "Removed task: $($task.TaskName)"
        }
        catch {
            Write-OpenPathLog "Failed to remove $($task.TaskName): $_" -Level WARN
        }
    }
}

function Get-OpenPathTaskStatus {
    <#
    .SYNOPSIS
        Gets status of all whitelist tasks
    #>
    $tasks = Get-ScheduledTask -TaskName "$script:TaskPrefix-*" -ErrorAction SilentlyContinue
    
    $status = @()
    foreach ($task in $tasks) {
        $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction SilentlyContinue
        $status += [PSCustomObject]@{
            Name = $task.TaskName
            State = $task.State
            LastRunTime = $info.LastRunTime
            LastResult = $info.LastTaskResult
            NextRunTime = $info.NextRunTime
        }
    }
    
    return $status
}

function Start-OpenPathTask {
    <#
    .SYNOPSIS
        Manually starts a whitelist task
    .PARAMETER TaskType
        Type of task: Update, Watchdog, or Startup
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet("Update", "RuntimeDependencyApply", "CaptivePortalRecovery", "Watchdog", "Startup", "SSE", "AgentUpdate")]
        [string]$TaskType = "Update"
    )

    $taskName = (Get-OpenPathScheduledTaskSpec -TaskType $TaskType).Name

    if (-not $PSCmdlet.ShouldProcess($taskName, "Start scheduled task")) {
        return $false
    }

    try {
        $taskResult = Invoke-OpenPathScheduledTask -TaskName $taskName
        if ($taskResult.success -ne $true) {
            throw $taskResult.error
        }
        Write-OpenPathLog "Started task: $taskName"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to start $taskName : $_" -Level ERROR
        return $false
    }
}

function Enable-OpenPathTask {
    <#
    .SYNOPSIS
        Enables all whitelist scheduled tasks
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Task Scheduler", "Enable OpenPath scheduled tasks")) {
        return
    }

    Get-ScheduledTask -TaskName "$script:TaskPrefix-*" -ErrorAction SilentlyContinue |
        Enable-ScheduledTask | Out-Null
    Write-OpenPathLog "All openpath tasks enabled"
}

function Disable-OpenPathTask {
    <#
    .SYNOPSIS
        Disables all whitelist scheduled tasks
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Task Scheduler", "Disable OpenPath scheduled tasks")) {
        return
    }

    Get-ScheduledTask -TaskName "$script:TaskPrefix-*" -ErrorAction SilentlyContinue |
        Disable-ScheduledTask | Out-Null
    Write-OpenPathLog "All openpath tasks disabled"
}

# Export module members
Export-ModuleMember -Function @(
    'Register-OpenPathTask',
    'Unregister-OpenPathTask',
    'Get-OpenPathTaskStatus',
    'Start-OpenPathTask',
    'Enable-OpenPathTask',
    'Disable-OpenPathTask'
)
