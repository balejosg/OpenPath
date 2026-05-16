Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Services Module" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\Services.psm1" -Force -ErrorAction SilentlyContinue
    }

    Context "Get-OpenPathTaskStatus" {
        It "Returns an array or empty result" -Skip:(-not (Test-FunctionExists 'Get-OpenPathTaskStatus')) {
            $status = Get-OpenPathTaskStatus
            # Status can be empty array, null, or array of objects
            { $status } | Should -Not -Throw
        }
    }

    Context "Register-OpenPathTask" {
        It "Defines scheduled task names and user run permissions in the catalog" {
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "ScheduledTaskCatalog.ps1"
            Test-Path $catalogPath | Should -BeTrue

            . $catalogPath
            $catalog = Get-OpenPathScheduledTaskCatalog

            $catalog.Prefix | Should -Be "OpenPath"
            $catalog.UsersRunTaskAce | Should -Be "(A;;GRGX;;;BU)"
            $catalog.Tasks.Update.Name | Should -Be "OpenPath-Update"
            $catalog.Tasks.RuntimeDependencyApply.Name | Should -Be "OpenPath-RuntimeDependencyApply"
            $catalog.Tasks.RuntimeDependencyApply.Script | Should -Be "scripts\Apply-RuntimeDependencyQueue.ps1"
            $catalog.Tasks.RuntimeDependencyApply.GrantUsersRunAccess | Should -BeTrue
            $catalog.Tasks.SSE.Name | Should -Be "OpenPath-SSE"
            @($catalog.ValidTaskTypes) | Should -Contain "RuntimeDependencyApply"
        }

        It "Builds scheduled task definitions from catalog specs without changing task names" {
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "ScheduledTaskCatalog.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Services.TaskBuilders.ps1"
            . $catalogPath
            . $helperPath

            function New-ScheduledTaskAction {
                param([string]$Execute, [string]$Argument)
                [PSCustomObject]@{ Execute = $Execute; Argument = $Argument }
            }
            function New-ScheduledTaskTrigger {
                param(
                    [switch]$Once,
                    [datetime]$At,
                    [timespan]$RepetitionInterval,
                    [switch]$AtStartup,
                    [switch]$Daily,
                    [timespan]$RandomDelay
                )
                [PSCustomObject]@{
                    Once = [bool]$Once
                    At = $At
                    RepetitionInterval = $RepetitionInterval
                    AtStartup = [bool]$AtStartup
                    Daily = [bool]$Daily
                    RandomDelay = $RandomDelay
                }
            }
            function New-ScheduledTaskSettingsSet {
                param(
                    [switch]$AllowStartIfOnBatteries,
                    [switch]$DontStopIfGoingOnBatteries,
                    [switch]$StartWhenAvailable,
                    [int]$RestartCount,
                    [timespan]$RestartInterval,
                    [timespan]$ExecutionTimeLimit
                )
                [PSCustomObject]@{
                    RestartCount = $RestartCount
                    RestartInterval = $RestartInterval
                    ExecutionTimeLimit = $ExecutionTimeLimit
                }
            }

            $definition = New-OpenPathRuntimeDependencyApplyTaskDefinition `
                -OpenPathRoot "C:\OpenPath" `
                -Principal ([PSCustomObject]@{ UserId = "SYSTEM" })

            $definition.TaskName | Should -Be "OpenPath-RuntimeDependencyApply"
            $definition.Action.Argument | Should -Match ([regex]::Escape('C:\OpenPath\scripts\Apply-RuntimeDependencyQueue.ps1'))
            $definition.Settings.ExecutionTimeLimit.TotalMinutes | Should -Be 2
        }

        It "Accepts custom interval parameters" -Skip:(-not ((Test-FunctionExists 'Register-OpenPathTask') -and (Test-IsAdmin))) {
            # Just verify the function signature works
            { Register-OpenPathTask -UpdateIntervalMinutes 15 -WatchdogIntervalMinutes 2 -WhatIf } | Should -Not -Throw
        }

        It "Includes daily silent agent update task" {
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "ScheduledTaskCatalog.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Services.TaskBuilders.ps1"
            $catalogContent = Get-Content $catalogPath -Raw
            $content = Get-Content $helperPath -Raw

            $catalogContent.Contains('$prefix-AgentUpdate') | Should -BeTrue
            $catalogContent.Contains('self-update --silent') | Should -BeTrue
            $content.Contains('Get-OpenPathScheduledTaskSpec -TaskType AgentUpdate') | Should -BeTrue
        }

        It "Includes on-demand runtime dependency apply task" {
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "ScheduledTaskCatalog.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Services.TaskBuilders.ps1"
            $servicesPath = Join-Path $PSScriptRoot ".." "lib" "Services.psm1"
            $installerPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $catalogContent = Get-Content $catalogPath -Raw
            $helperContent = Get-Content $helperPath -Raw
            $servicesContent = Get-Content $servicesPath -Raw
            $installerContent = Get-Content $installerPath -Raw

            Assert-ContentContainsAll -Content $catalogContent -Needles @(
                '$prefix-RuntimeDependencyApply',
                'scripts\Apply-RuntimeDependencyQueue.ps1',
                'GrantUsersRunAccess = $true'
            )
            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'function New-OpenPathRuntimeDependencyApplyTaskDefinition',
                'Get-OpenPathScheduledTaskSpec -TaskType RuntimeDependencyApply',
                '-TaskName $taskSpec.Name',
                '-ExecutionTimeLimit (New-TimeSpan -Minutes 2)'
            )
            Assert-ContentContainsAll -Content $servicesContent -Needles @(
                '$runtimeDependencyDefinition = New-OpenPathRuntimeDependencyApplyTaskDefinition',
                'Grant-OpenPathTaskRunAccessToUsers -TaskName $runtimeDependencyDefinition.TaskName',
                '"RuntimeDependencyApply"'
            )
            $installerContent.Contains("'Apply-RuntimeDependencyQueue.ps1'") | Should -BeTrue
        }

        It "Avoids explicit max repetition duration for recurring tasks" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Services.TaskBuilders.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$updateTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)',
                '-RepetitionInterval (New-TimeSpan -Minutes $UpdateIntervalMinutes)',
                '$watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)',
                '-RepetitionInterval (New-TimeSpan -Minutes $WatchdogIntervalMinutes)'
            )

            $content.Contains('RepetitionDuration ([TimeSpan]::MaxValue)') | Should -BeFalse
        }
    }

    Context "Agent self-update" {
        It "Re-registers the Firefox native host after applying updated files" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Copy-Item -Path $download.StagedPath -Destination $tempDestinationPath -Force -ErrorAction Stop',
                'Move-Item -Path $tempDestinationPath -Destination $download.DestinationPath -Force -ErrorAction Stop',
                'Register-OpenPathFirefoxNativeHost -Config $config | Out-Null'
            )
        }

        It "Reapplies protected DNS mode after applying updated files" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $modulePath -Raw

            $content | Should -Match '(?s)Register-OpenPathTask.*?Enable-OpenPathTask.*?Register-OpenPathFirefoxNativeHost.*?Restore-OpenPathProtectedMode -Config \$config.*?Start-OpenPathTask -TaskType SSE'
        }
    }

    Context "Start-OpenPathTask" {
        It "uses the TaskRunner adapter for successful task starts" {
            $runnerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "TaskRunner.ps1"
            Test-Path $runnerPath | Should -BeTrue

            . $runnerPath
            $calls = @()
            $runner = New-OpenPathFakeTaskRunner -RunResults @{
                "OpenPath-Update" = @{ success = $true; exitCode = 0; elapsedMs = 3 }
            } -OnRun {
                param([string]$TaskName)
                $script:calls += $TaskName
            }

            $result = Invoke-OpenPathScheduledTask -TaskName "OpenPath-Update" -Runner $runner

            $result.success | Should -BeTrue
            $result.taskName | Should -Be "OpenPath-Update"
            $script:calls | Should -Contain "OpenPath-Update"
        }

        It "returns timeout evidence from the fake TaskRunner wait path" {
            $runnerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "TaskRunner.ps1"
            . $runnerPath
            $runner = New-OpenPathFakeTaskRunner -RunResults @{
                "OpenPath-RuntimeDependencyApply" = @{ success = $true; exitCode = 0; elapsedMs = 2 }
            } -WaitResults @{
                "OpenPath-RuntimeDependencyApply" = @{ success = $false; timedOut = $true; elapsedMs = 14000; error = "Timed out waiting for task condition" }
            }

            $result = Invoke-OpenPathScheduledTask `
                -TaskName "OpenPath-RuntimeDependencyApply" `
                -Runner $runner `
                -TimeoutSeconds 14 `
                -WaitCondition { $false }

            $result.success | Should -BeFalse
            $result.timedOut | Should -BeTrue
            $result.error | Should -Be "Timed out waiting for task condition"
            $result.waitMs | Should -Be 14000
        }

        It "Accepts SSE as a valid task type" -Skip:(-not (Test-FunctionExists 'Start-OpenPathTask')) {
            # Verify the SSE task type is accepted in the ValidateSet
            { Start-OpenPathTask -TaskType SSE -WhatIf } | Should -Not -Throw
        }

        It "Accepts AgentUpdate as a valid task type" -Skip:(-not (Test-FunctionExists 'Start-OpenPathTask')) {
            { Start-OpenPathTask -TaskType AgentUpdate -WhatIf } | Should -Not -Throw
        }

        It "Accepts RuntimeDependencyApply as a valid task type" -Skip:(-not (Test-FunctionExists 'Start-OpenPathTask')) {
            { Start-OpenPathTask -TaskType RuntimeDependencyApply -WhatIf } | Should -Not -Throw
        }
    }
}

Describe "Script Bootstrap Module" {
    Context "Standalone script initialization" {
        It "Provides a shared initializer for standalone Windows scripts" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "ScriptBootstrap.psm1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Initialize-OpenPathScriptSession',
                '[string[]]$DependentModules = @()',
                '[string[]]$RequiredCommands = @()',
                '[string]$ScriptName = ''OpenPath script''',
                '$orderedModules = @($DependentModules)',
                'Import-Module (Join-Path $OpenPathRoot "lib\$moduleName.psm1") -Force -Global',
                'Import-Module (Join-Path $OpenPathRoot ''lib\Common.psm1'') -Global',
                'failed to import required commands',
                'Export-ModuleMember -Function @('
            )
        }

        It "Keeps firewall commands available after browser-dependent module imports" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "ScriptBootstrap.psm1"
            Import-Module $modulePath -Force

            {
                Initialize-OpenPathScriptSession `
                    -OpenPathRoot (Join-Path $PSScriptRoot '..') `
                    -DependentModules @('DNS', 'Firewall', 'Browser', 'CaptivePortal', 'AppControl') `
                    -RequiredCommands @(
                    'Get-OpenPathConfig',
                    'Update-AcrylicHost',
                    'Remove-OpenPathFirewall',
                    'Test-FirewallActive',
                    'Remove-BrowserPolicy',
                    'Test-OpenPathCaptivePortalState',
                    'Set-OpenPathNonAdminAppControl'
                ) `
                    -ScriptName 'test-bootstrap'
            } | Should -Not -Throw
        }
    }
}

Describe "SSE Listener" {
    Context "Script existence" {
        It "Start-SSEListener.ps1 exists" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            Test-Path $scriptPath | Should -BeTrue
        }

        It "Keeps parser-sensitive messages ASCII-only" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.Contains('—') | Should -BeFalse
        }

        It "Uses the shared standalone bootstrap helper and loads HTTP assembly support" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force',
                'Initialize-OpenPathScriptSession `',
                '-OpenPathRoot $OpenPathRoot',
                '-RequiredCommands @(',
                '-ScriptName ''Start-SSEListener.ps1''',
                "Add-Type -AssemblyName 'System.Net.Http' -ErrorAction Stop",
                "[System.Reflection.Assembly]::Load('System.Net.Http')",
                '[System.Net.Http.HttpClientHandler]::new()'
            )
        }
    }

    Context "Update process triggering" {
        It "runs the shared OpenPath update runtime directly for SSE-triggered local policy refreshes" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force',
                'Initialize-OpenPathUpdateRuntimeSession -OpenPathRoot $OpenPathRoot',
                '[int]$exitCode = Invoke-OpenPathUpdateCycle',
                'SSE: Starting in-process OpenPath update',
                'SSE: In-process OpenPath update completed'
            )

            $content | Should -Not -Match 'Start-ScheduledTask\s+-TaskName\s+''OpenPath-Update'''
        }

        It "does not rely on detached PowerShell launchers for SSE-triggered updates" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Start-OpenPathSseUpdateProcess',
                'SSE: In-process OpenPath update failed'
            )

            $content | Should -Not -Match '\.ArgumentList\.Add'
            $content | Should -Not -Match 'Start-Job\s+-ScriptBlock'
            $content | Should -Not -Match 'Get-Job\s+-Name'
            $content | Should -Not -Match '\[System\.Diagnostics\.ProcessStartInfo\]::new'
            $content | Should -Not -Match '\[System\.Diagnostics\.Process\]::Start'
        }

        It "queues one delayed catch-up update when whitelist changes arrive during cooldown" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$script:DelayedUpdateDueAt = [datetime]::MinValue',
                'function Start-OpenPathSseUpdateProcess',
                '-DelaySeconds $delaySeconds',
                'Start-Sleep -Seconds',
                'SSE: Queuing delayed update'
            )
        }

        It "logs SSE update process boundaries for production diagnostics" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'SSE: Starting in-process OpenPath update',
                'SSE: In-process OpenPath update completed',
                'SSE: In-process OpenPath update failed'
            )
        }
    }
}

Describe "Update Runtime" {
    Context "Reusable update cycle" {
        It "exposes the OpenPath update cycle as a reusable runtime function" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Initialize-OpenPathUpdateRuntimeSession',
                '$script:OpenPathUpdateRuntimeSessionInitialized',
                'function Invoke-OpenPathUpdateCycle',
                'function Invoke-OpenPathRuntimeDependencyFastApply',
                '[string]$OpenPathRoot = (Resolve-OpenPathWindowsRoot)',
                '$OpenPathRoot = Resolve-OpenPathWindowsRoot -OpenPathRoot $OpenPathRoot',
                '[string]$UpdateMutexName = ''Global\OpenPathUpdateLock''',
                '$null = Backup-OpenPathWhitelistState',
                '$null = Handle-OpenPathWhitelistApply',
                'Write-OpenPathLog "=== Starting openpath update ==="',
                'return [int]$exitCode',
                "'Initialize-OpenPathUpdateRuntimeSession'",
                "'Invoke-OpenPathUpdateCycle'",
                "'Invoke-OpenPathRuntimeDependencyFastApply'"
            )
        }

        It "keeps Update-OpenPath.ps1 as a thin wrapper around the reusable runtime" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Update-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force',
                '$exitCode = Invoke-OpenPathUpdateCycle -OpenPathRoot $OpenPathRoot',
                'exit $exitCode'
            )

            $content | Should -Not -Match '\[System\.Threading\.Mutex\]::new'
            $content | Should -Not -Match 'Handle-OpenPathWhitelistApply'
        }
    }
}
