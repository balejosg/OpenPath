function Get-OpenPathScheduledTaskCatalog {
    $prefix = 'OpenPath'
    $tasks = [ordered]@{
        Update = [PSCustomObject]@{
            Type = 'Update'
            Name = "$prefix-Update"
            Script = 'scripts\Update-OpenPath.ps1'
            GrantUsersRunAccess = $true
        }
        RuntimeDependencyApply = [PSCustomObject]@{
            Type = 'RuntimeDependencyApply'
            Name = "$prefix-RuntimeDependencyApply"
            Script = 'scripts\Apply-RuntimeDependencyQueue.ps1'
            GrantUsersRunAccess = $true
        }
        CaptivePortalRecovery = [PSCustomObject]@{
            Type = 'CaptivePortalRecovery'
            Name = "$prefix-CaptivePortalRecovery"
            Script = 'scripts\Recover-CaptivePortal.ps1'
            GrantUsersRunAccess = $true
        }
        Watchdog = [PSCustomObject]@{
            Type = 'Watchdog'
            Name = "$prefix-Watchdog"
            Script = 'scripts\Test-DNSHealth.ps1'
            GrantUsersRunAccess = $false
        }
        Startup = [PSCustomObject]@{
            Type = 'Startup'
            Name = "$prefix-Startup"
            Script = 'scripts\Update-OpenPath.ps1'
            GrantUsersRunAccess = $false
        }
        SSE = [PSCustomObject]@{
            Type = 'SSE'
            Name = "$prefix-SSE"
            Script = 'scripts\Start-SSEListener.ps1'
            GrantUsersRunAccess = $false
        }
        AgentUpdate = [PSCustomObject]@{
            Type = 'AgentUpdate'
            Name = "$prefix-AgentUpdate"
            Script = 'OpenPath.ps1'
            Arguments = 'self-update --silent'
            GrantUsersRunAccess = $false
        }
    }

    [PSCustomObject]@{
        Prefix = $prefix
        UsersRunTaskAce = '(A;;GRGX;;;BU)'
        Tasks = [PSCustomObject]$tasks
        ValidTaskTypes = @($tasks.Keys)
    }
}

function Get-OpenPathScheduledTaskSpec {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Update', 'RuntimeDependencyApply', 'CaptivePortalRecovery', 'Watchdog', 'Startup', 'SSE', 'AgentUpdate')]
        [string]$TaskType
    )

    $catalog = Get-OpenPathScheduledTaskCatalog
    return $catalog.Tasks.$TaskType
}
