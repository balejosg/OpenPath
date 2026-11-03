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

function Get-OpenPathTaskSecurityDescriptorWithUsersRunAccess {
    <#
    .SYNOPSIS
        Returns the task security descriptor with BUILTIN\Users read/execute added,
        or $null when Users already have that access
    .DESCRIPTION
        Task Scheduler stores the generic rights it is given as a file-rights mask,
        so the (A;;GRGX;;;BU) ACE written on install reads back as
        (A;;0x1200a9;;;BU). The new ACE goes after the DACL flags (P, AI, AR):
        placing it between "D:" and the flags yields an invalid ACL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$SecurityDescriptor,

        [string]$UsersRunTaskAce = '(A;;GRGX;;;BU)'
    )

    $genericAll = 0x10000000L
    $genericRead = 0x80000000L
    $genericExecute = 0x20000000L
    $readExecuteMask = 0x1200a9L
    $namedRights = @{
        GA = $genericAll; GR = $genericRead; GX = $genericExecute
        FA = 0x1f01ffL; FR = 0x120089L; FX = 0x1200a0L
    }

    foreach ($ace in [regex]::Matches($SecurityDescriptor, '\(A;([^;]*);([^;]*);[^;]*;[^;]*;(BU|S-1-5-32-545)\)')) {
        $aceFlags = $ace.Groups[1].Value
        $inheritOnly = $false
        for ($i = 0; $i + 1 -lt $aceFlags.Length; $i += 2) {
            if ($aceFlags.Substring($i, 2).ToUpperInvariant() -eq 'IO') {
                $inheritOnly = $true
            }
        }
        if ($inheritOnly) {
            continue
        }

        $rightsText = $ace.Groups[2].Value
        [long]$mask = 0
        if ($rightsText -match '^0x[0-9a-fA-F]+$') {
            $mask = [Convert]::ToInt64($rightsText.Substring(2), 16)
        }
        else {
            for ($i = 0; $i + 1 -lt $rightsText.Length; $i += 2) {
                $right = $rightsText.Substring($i, 2).ToUpperInvariant()
                if ($namedRights.ContainsKey($right)) {
                    $mask = $mask -bor $namedRights[$right]
                }
            }
        }

        $hasGenericReadExecute = (($mask -band $genericAll) -ne 0) -or ((($mask -band $genericRead) -ne 0) -and (($mask -band $genericExecute) -ne 0))
        if ($hasGenericReadExecute -or (($mask -band $readExecuteMask) -eq $readExecuteMask)) {
            return $null
        }
    }

    if ($SecurityDescriptor -match '^(?<head>.*?D:(?:P|AI|AR|NO_ACCESS_CONTROL)*)(?<tail>.*)$') {
        return "$($Matches['head'])$UsersRunTaskAce$($Matches['tail'])"
    }

    if ($SecurityDescriptor -match '^(?<head>.*?)(?<sacl>S:.*)$') {
        return "$($Matches['head'])D:$UsersRunTaskAce$($Matches['sacl'])"
    }

    return "${SecurityDescriptor}D:$UsersRunTaskAce"
}

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

        $updatedSecurityDescriptor = Get-OpenPathTaskSecurityDescriptorWithUsersRunAccess `
            -SecurityDescriptor $currentSecurityDescriptor `
            -UsersRunTaskAce $script:UsersRunTaskAce
        if ($null -eq $updatedSecurityDescriptor) {
            return $true
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
        [int]$WatchdogIntervalMinutes = 1,
        [string]$OpenPathRoot = 'C:\OpenPath'
    )

    if (-not $PSCmdlet.ShouldProcess("Task Scheduler", "Register OpenPath scheduled tasks")) {
        return $false
    }

    Write-OpenPathLog "Registering scheduled tasks..."

    $updatePrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $updateSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $updateDefinition = New-OpenPathUpdateTaskDefinition `
        -OpenPathRoot $OpenPathRoot `
        -UpdateIntervalMinutes $UpdateIntervalMinutes `
        -Principal $updatePrincipal `
        -DefaultSettings $updateSettings
    Register-OpenPathTaskDefinition -Definition $updateDefinition
    Grant-OpenPathTaskRunAccessToUsers -TaskName $updateDefinition.TaskName | Out-Null
    Write-OpenPathLog "Registered: $($updateDefinition.TaskName) (every $UpdateIntervalMinutes min)"

    $runtimeDependencyDefinition = New-OpenPathRuntimeDependencyApplyTaskDefinition `
        -OpenPathRoot $OpenPathRoot `
        -Principal $updatePrincipal
    Register-OpenPathTaskDefinition -Definition $runtimeDependencyDefinition
    Grant-OpenPathTaskRunAccessToUsers -TaskName $runtimeDependencyDefinition.TaskName | Out-Null
    Write-OpenPathLog "Registered: $($runtimeDependencyDefinition.TaskName) (on demand runtime dependencies)"

    $runtimeDependencyWorkerDefinition = New-OpenPathRuntimeDependencyWorkerTaskDefinition `
        -OpenPathRoot $OpenPathRoot `
        -Principal $updatePrincipal
    Register-OpenPathTaskDefinition -Definition $runtimeDependencyWorkerDefinition
    Write-OpenPathLog "Registered: $($runtimeDependencyWorkerDefinition.TaskName) (resident runtime dependency worker)"

    $captivePortalRecoverySpec = Get-OpenPathScheduledTaskSpec -TaskType CaptivePortalRecovery
    $captivePortalRecoveryAction = New-OpenPathTaskAction -Target (Join-OpenPathTaskScriptPath -OpenPathRoot $OpenPathRoot -RelativePath $captivePortalRecoverySpec.Script)
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
        -OpenPathRoot $OpenPathRoot `
        -WatchdogIntervalMinutes $WatchdogIntervalMinutes `
        -Principal $updatePrincipal `
        -DefaultSettings $updateSettings
    Register-OpenPathTaskDefinition -Definition $watchdogDefinition
    Write-OpenPathLog "Registered: $($watchdogDefinition.TaskName) (every $WatchdogIntervalMinutes min)"

    $startupDefinition = New-OpenPathStartupTaskDefinition `
        -OpenPathRoot $OpenPathRoot `
        -Principal $updatePrincipal `
        -DefaultSettings $updateSettings
    Register-OpenPathTaskDefinition -Definition $startupDefinition
    Write-OpenPathLog "Registered: $($startupDefinition.TaskName) (at boot)"

    $sseDefinition = New-OpenPathSseTaskDefinition `
        -OpenPathRoot $OpenPathRoot `
        -Principal $updatePrincipal
    Register-OpenPathTaskDefinition -Definition $sseDefinition
    Write-OpenPathLog "Registered: $($sseDefinition.TaskName) (persistent SSE listener)"

    $agentUpdateDefinition = New-OpenPathAgentUpdateTaskDefinition `
        -OpenPathRoot $OpenPathRoot `
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
        [ValidateSet("Update", "RuntimeDependencyApply", "RuntimeDependencyWorker", "CaptivePortalRecovery", "Watchdog", "Startup", "SSE", "AgentUpdate")]
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
