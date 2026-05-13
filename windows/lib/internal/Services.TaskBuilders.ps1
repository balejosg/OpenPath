function New-OpenPathTaskAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    New-ScheduledTaskAction -Execute "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Target`""
}

function New-OpenPathTaskDefinition {
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

function New-OpenPathUpdateTaskDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$TaskPrefix,

        [Parameter(Mandatory = $true)]
        [int]$UpdateIntervalMinutes,

        [Parameter(Mandatory = $true)]
        [object]$Principal,

        [Parameter(Mandatory = $true)]
        [object]$DefaultSettings
    )

    $updateAction = New-OpenPathTaskAction -Target "$OpenPathRoot\scripts\Update-OpenPath.ps1"
    $updateTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes $UpdateIntervalMinutes)

    New-OpenPathTaskDefinition `
        -TaskName "$TaskPrefix-Update" `
        -Action $updateAction `
        -Trigger $updateTrigger `
        -Principal $Principal `
        -Settings $DefaultSettings
}

function New-OpenPathRuntimeDependencyApplyTaskDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$TaskPrefix,

        [Parameter(Mandatory = $true)]
        [object]$Principal
    )

    $runtimeDependencyAction = New-OpenPathTaskAction -Target "$OpenPathRoot\scripts\Apply-RuntimeDependencyQueue.ps1"
    $runtimeDependencyTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
    $runtimeDependencySettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 1 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    New-OpenPathTaskDefinition `
        -TaskName "$TaskPrefix-RuntimeDependencyApply" `
        -Action $runtimeDependencyAction `
        -Trigger $runtimeDependencyTrigger `
        -Principal $Principal `
        -Settings $runtimeDependencySettings
}

function New-OpenPathWatchdogTaskDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$TaskPrefix,

        [Parameter(Mandatory = $true)]
        [int]$WatchdogIntervalMinutes,

        [Parameter(Mandatory = $true)]
        [object]$Principal,

        [Parameter(Mandatory = $true)]
        [object]$DefaultSettings
    )

    $watchdogAction = New-OpenPathTaskAction -Target "$OpenPathRoot\scripts\Test-DNSHealth.ps1"
    $watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $WatchdogIntervalMinutes)

    New-OpenPathTaskDefinition `
        -TaskName "$TaskPrefix-Watchdog" `
        -Action $watchdogAction `
        -Trigger $watchdogTrigger `
        -Principal $Principal `
        -Settings $DefaultSettings
}

function New-OpenPathStartupTaskDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$TaskPrefix,

        [Parameter(Mandatory = $true)]
        [object]$Principal,

        [Parameter(Mandatory = $true)]
        [object]$DefaultSettings
    )

    $startupTrigger = New-ScheduledTaskTrigger -AtStartup

    New-OpenPathTaskDefinition `
        -TaskName "$TaskPrefix-Startup" `
        -Action (New-OpenPathTaskAction -Target "$OpenPathRoot\scripts\Update-OpenPath.ps1") `
        -Trigger $startupTrigger `
        -Principal $Principal `
        -Settings $DefaultSettings
}

function New-OpenPathSseTaskDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$TaskPrefix,

        [Parameter(Mandatory = $true)]
        [object]$Principal
    )

    $sseTrigger = New-ScheduledTaskTrigger -AtStartup
    $sseSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 9999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Days 0)

    New-OpenPathTaskDefinition `
        -TaskName "$TaskPrefix-SSE" `
        -Action (New-OpenPathTaskAction -Target "$OpenPathRoot\scripts\Start-SSEListener.ps1") `
        -Trigger $sseTrigger `
        -Principal $Principal `
        -Settings $sseSettings
}

function New-OpenPathAgentUpdateTaskDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$TaskPrefix,

        [Parameter(Mandatory = $true)]
        [object]$Principal
    )

    $agentUpdateAction = New-ScheduledTaskAction -Execute "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$OpenPathRoot\OpenPath.ps1`" self-update --silent"
    $agentUpdateTrigger = New-ScheduledTaskTrigger -Daily -At 3am -RandomDelay (New-TimeSpan -Minutes 45)
    $agentUpdateSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 10) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    New-OpenPathTaskDefinition `
        -TaskName "$TaskPrefix-AgentUpdate" `
        -Action $agentUpdateAction `
        -Trigger $agentUpdateTrigger `
        -Principal $Principal `
        -Settings $agentUpdateSettings
}
