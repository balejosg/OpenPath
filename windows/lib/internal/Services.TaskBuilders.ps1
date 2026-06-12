if (-not (Get-Command -Name 'Get-OpenPathScheduledTaskCatalog' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ScheduledTaskCatalog.ps1')
}

function New-OpenPathTaskAction {
    <#
    .SYNOPSIS
    Creates a scheduled task action that runs a PowerShell script with bypass execution policy.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    New-ScheduledTaskAction -Execute "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Target`""
}

function New-OpenPathTaskDefinition {
    <#
    .SYNOPSIS
    Packages a task name, action, trigger, principal, and settings into a single definition object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [object]$Action,

        [Parameter(Mandatory = $true)]
        [object]$Trigger,

        [Parameter(Mandatory = $true)]
        [object]$Principal,

        [Parameter(Mandatory = $true)]
        [object]$Settings
    )

    [PSCustomObject]@{
        TaskName = $TaskName
        Action = $Action
        Trigger = $Trigger
        Principal = $Principal
        Settings = $Settings
    }
}

function Register-OpenPathTaskDefinition {
    <#
    .SYNOPSIS
    Registers a task definition with the Windows task scheduler, replacing any existing task with the same name.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Definition
    )

    Register-ScheduledTask -TaskName $Definition.TaskName `
        -Action $Definition.Action `
        -Trigger $Definition.Trigger `
        -Principal $Definition.Principal `
        -Settings $Definition.Settings `
        -Force | Out-Null
}

function Join-OpenPathTaskScriptPath {
    <#
    .SYNOPSIS
    Joins an OpenPath root and a relative script path, using backslash joining for absolute Windows paths.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ($OpenPathRoot -match '^[A-Za-z]:\\') {
        return ("{0}\{1}" -f $OpenPathRoot.TrimEnd('\'), $RelativePath.TrimStart('\'))
    }

    return (Join-Path $OpenPathRoot $RelativePath)
}

function New-OpenPathUpdateTaskDefinition {
    <#
    .SYNOPSIS
    Builds the recurring whitelist update task definition with the given interval and principal.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string]$TaskPrefix = '',

        [Parameter(Mandatory = $true)]
        [int]$UpdateIntervalMinutes,

        [Parameter(Mandatory = $true)]
        [object]$Principal,

        [Parameter(Mandatory = $true)]
        [object]$DefaultSettings
    )

    $taskSpec = Get-OpenPathScheduledTaskSpec -TaskType Update
    $updateAction = New-OpenPathTaskAction -Target (Join-OpenPathTaskScriptPath -OpenPathRoot $OpenPathRoot -RelativePath $taskSpec.Script)
    $updateTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes $UpdateIntervalMinutes)

    New-OpenPathTaskDefinition `
        -TaskName $taskSpec.Name `
        -Action $updateAction `
        -Trigger $updateTrigger `
        -Principal $Principal `
        -Settings $DefaultSettings
}

function New-OpenPathRuntimeDependencyApplyTaskDefinition {
    <#
    .SYNOPSIS
    Builds the on-demand runtime dependency apply task definition with a far-future trigger and short execution limit.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string]$TaskPrefix = '',

        [Parameter(Mandatory = $true)]
        [object]$Principal
    )

    $taskSpec = Get-OpenPathScheduledTaskSpec -TaskType RuntimeDependencyApply
    $runtimeDependencyAction = New-OpenPathTaskAction -Target (Join-OpenPathTaskScriptPath -OpenPathRoot $OpenPathRoot -RelativePath $taskSpec.Script)
    $runtimeDependencyTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
    $runtimeDependencySettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 1 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    New-OpenPathTaskDefinition `
        -TaskName $taskSpec.Name `
        -Action $runtimeDependencyAction `
        -Trigger $runtimeDependencyTrigger `
        -Principal $Principal `
        -Settings $runtimeDependencySettings
}

function New-OpenPathWatchdogTaskDefinition {
    <#
    .SYNOPSIS
    Builds the recurring watchdog task definition with the given interval and principal.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string]$TaskPrefix = '',

        [Parameter(Mandatory = $true)]
        [int]$WatchdogIntervalMinutes,

        [Parameter(Mandatory = $true)]
        [object]$Principal,

        [Parameter(Mandatory = $true)]
        [object]$DefaultSettings
    )

    $taskSpec = Get-OpenPathScheduledTaskSpec -TaskType Watchdog
    $watchdogAction = New-OpenPathTaskAction -Target (Join-OpenPathTaskScriptPath -OpenPathRoot $OpenPathRoot -RelativePath $taskSpec.Script)
    $watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $WatchdogIntervalMinutes)

    New-OpenPathTaskDefinition `
        -TaskName $taskSpec.Name `
        -Action $watchdogAction `
        -Trigger $watchdogTrigger `
        -Principal $Principal `
        -Settings $DefaultSettings
}

function New-OpenPathStartupTaskDefinition {
    <#
    .SYNOPSIS
    Builds the at-startup task definition that runs the startup reconcile script.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string]$TaskPrefix = '',

        [Parameter(Mandatory = $true)]
        [object]$Principal,

        [Parameter(Mandatory = $true)]
        [object]$DefaultSettings
    )

    $taskSpec = Get-OpenPathScheduledTaskSpec -TaskType Startup
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup

    New-OpenPathTaskDefinition `
        -TaskName $taskSpec.Name `
        -Action (New-OpenPathTaskAction -Target (Join-OpenPathTaskScriptPath -OpenPathRoot $OpenPathRoot -RelativePath $taskSpec.Script)) `
        -Trigger $startupTrigger `
        -Principal $Principal `
        -Settings $DefaultSettings
}

function New-OpenPathSseTaskDefinition {
    <#
    .SYNOPSIS
    Builds the SSE listener task definition that runs at startup with unlimited duration and auto-restart.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string]$TaskPrefix = '',

        [Parameter(Mandatory = $true)]
        [object]$Principal
    )

    $taskSpec = Get-OpenPathScheduledTaskSpec -TaskType SSE
    $sseTrigger = New-ScheduledTaskTrigger -AtStartup
    $sseSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 9999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Days 0)

    New-OpenPathTaskDefinition `
        -TaskName $taskSpec.Name `
        -Action (New-OpenPathTaskAction -Target (Join-OpenPathTaskScriptPath -OpenPathRoot $OpenPathRoot -RelativePath $taskSpec.Script)) `
        -Trigger $sseTrigger `
        -Principal $Principal `
        -Settings $sseSettings
}

function New-OpenPathAgentUpdateTaskDefinition {
    <#
    .SYNOPSIS
    Builds the daily silent agent self-update task definition with a randomized start delay.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string]$TaskPrefix = '',

        [Parameter(Mandatory = $true)]
        [object]$Principal
    )

    $taskSpec = Get-OpenPathScheduledTaskSpec -TaskType AgentUpdate
    $agentUpdateAction = New-ScheduledTaskAction -Execute "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-OpenPathTaskScriptPath -OpenPathRoot $OpenPathRoot -RelativePath $taskSpec.Script)`" $($taskSpec.Arguments)"
    $agentUpdateTrigger = New-ScheduledTaskTrigger -Daily -At 3am -RandomDelay (New-TimeSpan -Minutes 45)
    $agentUpdateSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 10) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    New-OpenPathTaskDefinition `
        -TaskName $taskSpec.Name `
        -Action $agentUpdateAction `
        -Trigger $agentUpdateTrigger `
        -Principal $Principal `
        -Settings $agentUpdateSettings
}
