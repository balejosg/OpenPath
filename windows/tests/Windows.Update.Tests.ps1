Describe "Update Script" {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    }

    Context "Concurrency guard" {
        It "Update runtime uses a global mutex lock" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $content = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'System.Threading.Mutex',
                'Global\OpenPathUpdateLock',
                'WaitOne(0)',
                '[int]$LockWaitTimeoutSeconds = 45',
                '$mutex.WaitOne($lockWaitTimeoutMs)',
                'Waiting up to $LockWaitTimeoutSeconds seconds for the existing OpenPath update to finish',
                'Another OpenPath update is already running - skipping this cycle'
            )
        }
    }

    Context "Module import resilience" {
        It "Uses the shared standalone bootstrap helper from the runtime module" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Update-OpenPath.ps1"
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $scriptContent = Get-Content $scriptPath -Raw
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                'Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force',
                'Invoke-OpenPathUpdateCycle -OpenPathRoot $OpenPathRoot'
            )

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force',
                'Initialize-OpenPathScriptSession `',
                '-OpenPathRoot $OpenPathRoot',
                '-DependentModules @(''DNS'', ''Firewall'', ''Browser'', ''CaptivePortal'')',
                '-RequiredCommands @(',
                'Get-OpenPathCapabilityStoragePath',
                'Test-OpenPathCaptivePortalModeActive',
                'Get-OpenPathCaptivePortalMarker',
                'CapabilityStorage.ps1',
                '-ScriptName ''Update-OpenPath.ps1'''
            )
        }
    }

    Context "Startup captive portal reconciliation" {
        It "Runs local protected-mode or portal reconciliation before remote whitelist download" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'Invoke-OpenPathStartupLocalReconcile',
                'Test-Path $WhitelistPath',
                'Get-OpenPathWhitelistSectionsFromFile',
                'Test-OpenPathCaptivePortalModeActive',
                'Restore-OpenPathProtectedMode -Config $Config',
                'Invoke-OpenPathCaptivePortalImmediateReconcile -Config $Config'
            )

            $cycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $cycleEnd = $runtimeContent.IndexOf('function Write-OpenPathUpdatePortalActiveState')
            $cycleBody = $runtimeContent.Substring($cycleStart, $cycleEnd - $cycleStart)
            $cycleBody.IndexOf('Invoke-OpenPathStartupLocalReconcile') |
                Should -BeLessThan $cycleBody.IndexOf('Get-OpenPathWhitelistDownloadResult')
        }
    }

    Context "Rollback system" {
        It "Creates rolling checkpoints before applying new whitelist" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Config.ps1"
            $whitelistHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Whitelist.ps1"
            $content = Get-Content $runtimePath -Raw
            $configHelperContent = Get-Content $configHelperPath -Raw
            $commonContent = Get-Content $whitelistHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'whitelist.backup.txt',
                'Backup-OpenPathWhitelistState',
                'Get-OpenPathUpdatePolicySettings'
            )

            Assert-ContentContainsAll -Content $configHelperContent -Needles @(
                'Copy-Item $WhitelistPath $BackupPath -Force',
                'Save-OpenPathWhitelistCheckpoint',
                'MaxCheckpoints'
            )

            Assert-ContentContainsAll -Content $commonContent -Needles @(
                'Save-OpenPathWhitelistCheckpoint',
                'Get-OpenPathLatestCheckpoint',
                'Restore-OpenPathLatestCheckpoint'
            )
        }

        It "Restores checkpoint and falls back to backup on update failure" {
            $runtimeModulePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Rollback.ps1"
            $content = Get-Content $runtimeModulePath -Raw
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Invoke-OpenPathUpdateRollback',
                'Write-UpdateCatchLog "Update failed: $_" -Level ERROR'
            )

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'Attempting checkpoint rollback',
                'Falling back to backup whitelist rollback',
                'Copy-Item $BackupPath $WhitelistPath -Force',
                'Restore-OpenPathCheckpoint'
            )
        }

        It "Allows backup rollback when config was never loaded" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Rollback.ps1"
            $runtimeContent = Get-Content $runtimePath -Raw

            $runtimeContent | Should -Match '\[AllowNull\(\)\]\s+\[PSCustomObject\]\$Config'
            $runtimeContent | Should -Match '(?s)if \(\$Config\) \{\s+Sync-FirefoxNativeHostMirror -Config \$Config -WhitelistPath \$WhitelistPath\s+\}'
            $runtimeContent | Should -Match '(?s)if \(\$Config\) \{\s+Restore-OpenPathProtectedMode -Config \$Config -ErrorAction SilentlyContinue \| Out-Null\s+\}'
        }

        It "Resolves the Windows root from helper while preserving C:\OpenPath as the default" {
            $rootHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "WindowsRoot.ps1"
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $updateScriptPath = Join-Path $PSScriptRoot ".." "scripts" "Update-OpenPath.ps1"
            $rootHelperContent = Get-Content $rootHelperPath -Raw
            $runtimeContent = Get-Content $runtimePath -Raw
            $updateScriptContent = Get-Content $updateScriptPath -Raw

            Assert-ContentContainsAll -Content $rootHelperContent -Needles @(
                'function Resolve-OpenPathWindowsRoot',
                '$env:OPENPATH_WINDOWS_ROOT',
                '$env:OPENPATH_ROOT',
                'return ''C:\OpenPath'''
            )
            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                "Resolve-OpenPathWindowsRoot",
                '$OpenPathRoot = Resolve-OpenPathWindowsRoot -OpenPathRoot $OpenPathRoot'
            )
            Assert-ContentContainsAll -Content $updateScriptContent -Needles @(
                'WindowsRoot.ps1',
                '$OpenPathRoot = Resolve-OpenPathWindowsRoot'
            )
        }
    }

    Context "Health report" {
        It "Sends health report to API after successful update" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $commonPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Http.Health.ps1"
            $updateContent = Get-Content $runtimePath -Raw
            $commonContent = Get-Content $commonPath -Raw

            $updateContent.Contains('Send-OpenPathHealthReport') | Should -BeTrue
            $commonContent.Contains('/trpc/healthReports.submit') | Should -BeTrue
            $commonContent.Contains('dnsmasqRunning') | Should -BeTrue
        }

        It "Persists update portal-active state and annotates health actions" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $applyHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $sseScriptPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $runtimeContent = Get-Content $runtimePath -Raw
            $applyContent = Get-Content $applyHelperPath -Raw
            $sseContent = Get-Content $sseScriptPath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'function Write-OpenPathUpdatePortalActiveState',
                'Test-OpenPathCaptivePortalModeActive',
                'Get-OpenPathCaptivePortalMarker',
                'data\update-portal-active-state.json',
                'triggerSource = $TriggerSource',
                'healthAction = $healthAction',
                'update_while_portal_active',
                'sse_update_while_portal_active',
                'OpenPath $TriggerSource update observed while captive portal mode is active',
                '-HealthActionSuffix $portalActiveState.HealthAction'
            )

            Assert-ContentContainsAll -Content $applyContent -Needles @(
                'function Join-OpenPathUpdateHealthActions',
                '[string]$HealthActionSuffix = ''''',
                'Join-OpenPathUpdateHealthActions -Action ''update'' -Suffix $HealthActionSuffix',
                'Join-OpenPathUpdateHealthActions -Action ''not_modified'' -Suffix $HealthActionSuffix',
                'Join-OpenPathUpdateHealthActions -Action ''download_failed_cached_whitelist'' -Suffix $HealthActionSuffix'
            )

            Assert-ContentContainsAll -Content $sseContent -Needles @(
                'Invoke-OpenPathUpdateCycle -OpenPathRoot $OpenPathRoot -TriggerSource SSE'
            )
        }
    }

    Context "Stale whitelist fail-safe" {
        It "Includes stale threshold logic and restores protected mode via shared helper" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $content = Get-Content $runtimePath -Raw
            $helperContent = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathUpdatePolicySettings',
                'Handle-OpenPathDownloadFailure'
            )

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'StaleWhitelistMaxAgeHours',
                'Enter-StaleWhitelistFailsafe',
                'STALE_FAILSAFE'
            )

            $helperContent | Should -Match 'Invoke-OpenPathEndpointStateRepairPlan -Plan \$repairPlan -Config \$Config'
        }
    }

    Context "Protected mode recovery" {
        It "Uses the shared endpoint reconciler for update/apply protected-mode decisions" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $applyHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $stateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointPolicyState.ps1"
            $reconcilerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointStateReconciler.ps1"
            $runtimeContent = Get-Content $runtimePath -Raw
            $applyContent = Get-Content $applyHelperPath -Raw
            $stateContent = Get-Content $stateHelperPath -Raw
            $reconcilerContent = Get-Content $reconcilerPath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'EndpointPolicyState.ps1',
                'EndpointStateReconciler.ps1',
                'Import-OpenPathUpdateRuntimeHelper',
                'Function:script:$functionName'
            )

            Assert-ContentContainsAll -Content $stateContent -Needles @(
                'function Get-OpenPathEndpointPolicyState',
                'IsDisabled',
                'ProtectedModeEligible'
            )

            Assert-ContentContainsAll -Content $reconcilerContent -Needles @(
                'function New-OpenPathEndpointStateRepairPlan',
                'function Invoke-OpenPathEndpointStateRepairPlan',
                'RestoreProtectedMode',
                'RemoveBrowserPolicy'
            )

            Assert-ContentContainsAll -Content $applyContent -Needles @(
                'Get-OpenPathEndpointPolicyState',
                'New-OpenPathEndpointStateRepairPlan',
                'Invoke-OpenPathEndpointStateRepairPlan'
            )
        }

        It "Restores local DNS and firewall through the shared helper after applying a valid whitelist" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $applyHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $rollbackHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Rollback.ps1"
            $content = Get-Content $runtimePath -Raw
            $applyContent = Get-Content $applyHelperPath -Raw
            $rollbackContent = Get-Content $rollbackHelperPath -Raw

            $content | Should -Match '(?s)elseif \(\$downloadResult\.Whitelist\.IsDisabled\).*?Handle-OpenPathDisabledWhitelist'
            $applyContent | Should -Match '(?s)Handle-OpenPathDisabledWhitelist.*?Invoke-OpenPathEndpointStateRepairPlan'
            $applyContent | Should -Match '(?s)Handle-OpenPathDisabledWhitelist.*?# DESACTIVADO.*?Set-Content \$WhitelistPath'
            $applyContent | Should -Match '(?s)Handle-OpenPathNotModified.*?IsDisabled.*?FAIL_OPEN.*?remote_disable_marker_not_modified'
            $applyContent | Should -Match '(?s)Handle-OpenPathWhitelistApply.*?Invoke-OpenPathRuntimeDependencyQueueApply.*?Invoke-OpenPathEndpointStateRepairPlan'
            $rollbackContent | Should -Match '(?s)Falling back to backup whitelist rollback.*?Restore-OpenPathProtectedMode -Config \$Config -ErrorAction SilentlyContinue'
        }

        It "Restarts protected DNS when runtime dependency queue changes without a new whitelist" {
            $applyHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $applyContent = Get-Content $applyHelperPath -Raw

            $applyContent | Should -Match '(?s)Handle-OpenPathNotModified.*?\$runtimeDependencyQueueChanged = Invoke-OpenPathRuntimeDependencyQueueApply.*?-QueueChanged \$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan'
            $applyContent | Should -Match '(?s)Handle-OpenPathDownloadFailure.*?\$runtimeDependencyQueueChanged = Invoke-OpenPathRuntimeDependencyQueueApply.*?-QueueChanged \$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan'
        }

        It "Keeps runtime dependency queue apply scalar when Acrylic emits helper output" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            $runtimeContent | Should -Match '(?s)function Invoke-OpenPathRuntimeDependencyQueueApply.*?Update-AcrylicHost .*?\| Out-Null.*?return \[bool\]\$runtimeDependencyQueueResult\.Changed'
        }

        It "Provides a queue-only runtime dependency fast apply without remote download" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Apply-RuntimeDependencyQueue.ps1"
            $runtimeContent = Get-Content $runtimePath -Raw
            $scriptContent = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'function Invoke-OpenPathRuntimeDependencyFastApply',
                'Sync-FirefoxNativeHostMirror -Config $config -WhitelistPath $whitelistPath',
                'Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $whitelistPath -PassThru',
                'Restart-AcrylicService | Out-Null',
                'Runtime dependency fast apply metrics',
                'queueProcessedMs',
                'overlayWriteMs',
                'acrylicReloadMs'
            )

            $fastApplyStart = $runtimeContent.IndexOf('function Invoke-OpenPathRuntimeDependencyFastApply')
            $updateCycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $fastApplyBody = $runtimeContent.Substring($fastApplyStart, $updateCycleStart - $fastApplyStart)
            $fastApplyBody | Should -Match '(?s)Test-Path \$whitelistPath.*?Invoke-OpenPathRuntimeDependencyQueueApply'
            $fastApplyBody | Should -Not -Match 'Get-OpenPathWhitelistDownloadResult'

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                '#Requires -RunAsAdministrator',
                'Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force',
                'Invoke-OpenPathRuntimeDependencyFastApply -OpenPathRoot $OpenPathRoot',
                'exit $exitCode'
            )
        }
    }

    Context "Self-update transactions" {
        It "Backs up the current version and rolls back file replacements on failure" {
            $updateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'data\agent-update',
                '''backups''',
                '$currentVersion',
                'manifest.json',
                '$replacementBackups',
                '$tempDestinationPath',
                'Move-Item -Path $tempDestinationPath -Destination $download.DestinationPath -Force -ErrorAction Stop',
                'Post-replacement checksum mismatch',
                'Rollback failed for $($replacement.DestinationPath)'
            )

            $replacementStart = $content.IndexOf('foreach ($download in $downloadedFiles)')
            $configUpdateStart = $content.IndexOf('if ($config.PSObject.Properties[''version''])')
            $postReplacementBody = $content.Substring($replacementStart, $configUpdateStart - $replacementStart)
            $postReplacementBody | Should -Match 'Post-replacement checksum mismatch'
        }
    }
}
