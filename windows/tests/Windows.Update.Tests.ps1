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
                '-DependentModules @(''DNS'', ''Network'', ''Firewall'', ''Browser'', ''CaptivePortal'')',
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
        It "Synchronizes machine client config before local protected-mode reconciliation" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'function Sync-OpenPathMachineClientConfig',
                '/api/machines/client-config',
                'captivePortalDomains',
                'Set-OpenPathConfig -Config $Config',
                '$config = Sync-OpenPathMachineClientConfig -Config $config',
                'Update-AcrylicHost -WhitelistedDomains $runtimeDependencyQueueSections.Whitelist'
            )

            $cycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $cycleEnd = $runtimeContent.IndexOf('function Write-OpenPathUpdatePortalActiveState')
            $cycleBody = $runtimeContent.Substring($cycleStart, $cycleEnd - $cycleStart)
            $cycleBody.IndexOf('Sync-OpenPathMachineClientConfig') |
                Should -BeLessThan $cycleBody.IndexOf('Invoke-OpenPathStartupLocalReconcile')
        }

        It "Fetches and persists changed captive portal domains from the machine client-config endpoint" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            Import-Module $runtimePath -Force

            InModuleScope Update.Runtime {
                $global:OpenPathTestClientConfigUri = ''
                $global:OpenPathTestClientConfigAuth = ''
                $global:OpenPathTestPersistedDomains = @()

                function Set-OpenPathConfig { param([PSCustomObject]$Config) }
                function Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') }

                Mock Invoke-RestMethod {
                    $global:OpenPathTestClientConfigUri = $Uri
                    $global:OpenPathTestClientConfigAuth = $Headers.Authorization

                    [PSCustomObject]@{
                        success = $true
                        captivePortalDomains = @(' NCE.WEDU.COMUNIDAD.MADRID ', 'nce.wedu.comunidad.madrid.')
                    }
                }

                Mock Set-OpenPathConfig {
                    $global:OpenPathTestPersistedDomains = @($Config.captivePortalDomains)
                }

                Mock Write-OpenPathLog {}

                $config = [PSCustomObject]@{
                    apiUrl = 'https://classroompath.eu/'
                    whitelistUrl = 'https://classroompath.eu/api/machines/w/machine-token-123/whitelist.txt'
                    captivePortalDomains = @()
                }

                $updated = Sync-OpenPathMachineClientConfig -Config $config

                $global:OpenPathTestClientConfigUri | Should -Be 'https://classroompath.eu/api/machines/client-config'
                $global:OpenPathTestClientConfigAuth | Should -Be 'Bearer machine-token-123'
                $global:OpenPathTestPersistedDomains | Should -Be @('nce.wedu.comunidad.madrid')
                $updated.captivePortalDomains | Should -Be @('nce.wedu.comunidad.madrid')
            }
        }

        It "Runs local protected-mode or portal reconciliation before remote whitelist download" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'Invoke-OpenPathStartupLocalReconcile',
                'Test-Path $WhitelistPath',
                'Get-OpenPathWhitelistSectionsFromFile',
                '[switch]$SkipProtectedModeRestore',
                'Test-OpenPathCaptivePortalModeActive',
                'ProtectedModeRestoreSkipped',
                'Restore-OpenPathProtectedMode -Config $Config',
                'Invoke-OpenPathCaptivePortalImmediateReconcile -Config $Config'
            )

            $cycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $cycleEnd = $runtimeContent.IndexOf('function Write-OpenPathUpdatePortalActiveState')
            $cycleBody = $runtimeContent.Substring($cycleStart, $cycleEnd - $cycleStart)
            $cycleBody.IndexOf('Invoke-OpenPathStartupLocalReconcile') |
                Should -BeLessThan $cycleBody.IndexOf('Get-OpenPathWhitelistDownloadResult')
            $cycleBody | Should -Match "-SkipProtectedModeRestore:\(\`$TriggerSource -eq 'SSE'\)"
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
            $runtimeContent | Should -Match "(?s)if \(\`$Config\) \{\s+Invoke-OpenPathUpdateWritersLockScope -Stage 'checkpoint-rollback-mirror' -Action \{\s+Sync-FirefoxNativeHostMirror -Config \`$Config -WhitelistPath \`$WhitelistPath"
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

            $applyContent | Should -Match "(?s)Handle-OpenPathNotModified.*?\`$runtimeDependencyQueueChanged = \[bool\]\(Invoke-OpenPathUpdateWritersLockScope -Stage 'not-modified-queue-apply'.*?-QueueChanged \`$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan"
            $applyContent | Should -Match "(?s)Handle-OpenPathDownloadFailure.*?\`$runtimeDependencyQueueChanged = \[bool\]\(Invoke-OpenPathUpdateWritersLockScope -Stage 'download-failure-queue-apply'.*?-QueueChanged \`$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan"
        }

        It "Keeps runtime dependency queue apply scalar when Acrylic emits helper output" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            $runtimeContent | Should -Match '(?s)function Invoke-OpenPathRuntimeDependencyQueueApply.*?\$acrylicHostWritten = \[bool\]\(Update-AcrylicHost.*?return \[bool\]\$runtimeDependencyQueueResult\.Changed'
            # The update runtime session does not autoload PowerShell modules, so
            # the apply path must not rely on cmdlets like Get-FileHash.
            $runtimeContent | Should -Not -Match 'Get-FileHash'
        }

        It "Provides a queue-only runtime dependency fast apply without remote download" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Apply-RuntimeDependencyQueue.ps1"
            $runtimeContent = Get-Content $runtimePath -Raw
            $scriptContent = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'function Invoke-OpenPathRuntimeDependencyFastApply',
                'Sync-FirefoxNativeHostMirrorIfChanged -OpenPathRoot $OpenPathRoot -WhitelistPath $whitelistPath',
                'Invoke-OpenPathRuntimeDependencyQueueApply -WhitelistPath $whitelistPath -PassThru',
                '$overlayUnappliedBefore',
                '$maxDrainIterations',
                '$queueResult.AcrylicHostsChanged',
                '$acrylicReloaded = [bool](Restart-AcrylicService)',
                'Set-OpenPathRuntimeDependencyOverlayApplied | Out-Null',
                'Runtime dependency fast apply could not write the Acrylic hosts file',
                'Runtime dependency fast apply metrics',
                'iterations=',
                'acrylicHostsChanged=',
                'queueProcessedMs',
                'overlayWriteMs',
                'acrylicReloadMs',
                'mirrorSynced',
                'mirrorSyncMs',
                '[System.Threading.Thread]::Sleep(150)',
                '$updateWorkerBusyStage',
                'WorkerStatePath'
            )

            # Hot path: the config read + mirror rebuild must not run unconditionally
            # on every dependency batch (it cost ~5 s of the Phase 2A baseline).
            $runtimeContent | Should -Match 'function Sync-FirefoxNativeHostMirrorIfChanged'
            $runtimeContent | Should -Match 'function Get-OpenPathNativeHostMirrorSyncStatePath'

            $fastApplyStart = $runtimeContent.IndexOf('function Invoke-OpenPathRuntimeDependencyFastApply')
            $updateCycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $fastApplyBody = $runtimeContent.Substring($fastApplyStart, $updateCycleStart - $fastApplyStart)
            $fastApplyBody | Should -Match '(?s)Test-Path \$whitelistPath.*?Invoke-OpenPathRuntimeDependencyQueueApply'
            $fastApplyBody | Should -Not -Match 'Get-OpenPathWhitelistDownloadResult'
            $fastApplyBody | Should -Not -Match 'Sync-FirefoxNativeHostMirror -Config \$config'
            $fastApplyBody | Should -Not -Match 'Get-OpenPathConfig'

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                '#Requires -RunAsAdministrator',
                'Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force',
                'Invoke-OpenPathRuntimeDependencyFastApply -OpenPathRoot $OpenPathRoot',
                'exit $exitCode'
            )
        }

        It "Stamps the applied generation at the end of every drain iteration" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw
            $fastApplyStart = $runtimeContent.IndexOf('function Invoke-OpenPathRuntimeDependencyFastApply')
            $updateCycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $fastApplyBody = $runtimeContent.Substring($fastApplyStart, $updateCycleStart - $fastApplyStart)

            # Reload branch (after the DNS flush) and the unchanged branch: the
            # entries of each iteration must become ready without waiting for a
            # later, still-pending iteration.
            ([regex]::Matches($fastApplyBody, 'Set-OpenPathRuntimeDependencyOverlayApplied \| Out-Null')).Count | Should -Be 2
            $fastApplyBody | Should -Match '(?s)\$dnsFlushOk.*?Set-OpenPathRuntimeDependencyOverlayApplied \| Out-Null'
            $fastApplyBody | Should -Match 'overlay generation stamped: appliedGeneration='
        }

        It "Skips the native host mirror sync until the whitelist or config inputs change" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'function Sync-FirefoxNativeHostMirrorIfChanged',
                'Get-OpenPathFileStateFingerprint',
                '$previous -eq $fingerprint',
                'data\native-host-mirror-sync.json'
            )

            Import-Module $runtimePath -Force -ErrorAction SilentlyContinue
            $mirrorRoot = Join-Path $TestDrive 'mirror-root'
            $dataDir = Join-Path $mirrorRoot 'data'
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            Set-Content -Path (Join-Path $dataDir 'whitelist.txt') -Value "## WHITELIST$([Environment]::NewLine)reddit.com"
            Set-Content -Path (Join-Path $dataDir 'config.json') -Value '{}'

            # Recording the current inputs makes the gate skip without reading the
            # config or rebuilding the mirror.
            Update-OpenPathNativeHostMirrorSyncState -OpenPathRoot $mirrorRoot | Out-Null
            $statePath = Get-OpenPathNativeHostMirrorSyncStatePath -OpenPathRoot $mirrorRoot
            Test-Path $statePath | Should -BeTrue
            (Get-Content $statePath -Raw).Trim() | Should -Not -BeNullOrEmpty
            (Sync-FirefoxNativeHostMirrorIfChanged -OpenPathRoot $mirrorRoot) | Should -BeFalse

            # Changing the whitelist makes the fingerprint stale.
            Add-Content -Path (Join-Path $dataDir 'whitelist.txt') -Value ([Environment]::NewLine + 'example.com')
            $recorded = (Get-Content $statePath -Raw).Trim()
            $current = ('{0}|{1}' -f (Get-OpenPathFileStateFingerprint -Path (Join-Path $dataDir 'whitelist.txt')), (Get-OpenPathFileStateFingerprint -Path (Join-Path $dataDir 'config.json')))
            $recorded | Should -Not -Be $current
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

    Context "Self-update artifact integrity" {
        It "Requires a well-formed sha256 for every manifest file entry before downloading it" {
            $updateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$declaredHash = if ($file.PSObject.Properties[''sha256'']) { [string]$file.sha256 } else { '''' }',
                '[string]::IsNullOrWhiteSpace($declaredHash) -or $declaredHash -notmatch ''^[0-9a-fA-F]{64}$''',
                'Manifest entry missing/invalid sha256 for $manifestPath'
            )

            # The mandatory-hash guard must run before the file is downloaded.
            $downloadStart = $content.IndexOf('Invoke-WebRequest -Uri $fileUrl')
            $guardStart = $content.IndexOf('Manifest entry missing/invalid sha256 for $manifestPath')
            $guardStart | Should -BeGreaterThan 0
            $downloadStart | Should -BeGreaterThan $guardStart
        }

        It "Compares the downloaded and post-replacement hashes unconditionally, without an optional-check guard" {
            $updateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            $content | Should -Not -Match 'if \(\$expectedHash\) \{'

            $downloadLoopStart = $content.IndexOf('foreach ($file in $manifestFiles)')
            $applyLoopStart = $content.IndexOf('Save-OpenPathIntegrityBackup')
            $downloadLoopBody = $content.Substring($downloadLoopStart, $applyLoopStart - $downloadLoopStart)
            $downloadLoopBody | Should -Match '(?s)Invoke-WebRequest -Uri \$fileUrl.*?\$actualHash = \(Get-FileHash -Path \$stagedPath -Algorithm SHA256 -ErrorAction Stop\)\.Hash\.ToLowerInvariant\(\)\s+if \(\$actualHash -ne \$expectedHash\.ToLowerInvariant\(\)\) \{\s+throw "Checksum mismatch for \$manifestPath"'

            $postReplacementStart = $content.IndexOf('foreach ($download in $downloadedFiles)', $applyLoopStart)
            $postReplacementStart = $content.IndexOf('foreach ($download in $downloadedFiles)', $postReplacementStart + 1)
            $configUpdateStart = $content.IndexOf('if ($config.PSObject.Properties[''version''])')
            $postReplacementBody = $content.Substring($postReplacementStart, $configUpdateStart - $postReplacementStart)
            $postReplacementBody | Should -Match '(?s)\$actualHash = \(Get-FileHash -Path \$download\.DestinationPath -Algorithm SHA256 -ErrorAction Stop\)\.Hash\.ToLowerInvariant\(\)\s+if \(\$actualHash -ne \$expectedHash\.ToLowerInvariant\(\)\) \{\s+throw "Post-replacement checksum mismatch for \$\(\$download\.RelativePath\)"'
        }

        It "Gates staged .ps1/.psm1 artifacts behind an opt-in Authenticode signature check" {
            $updateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$enforceSignature = ($env:OPENPATH_SELFUPDATE_REQUIRE_SIGNATURE -eq ''1'')',
                'if ($enforceSignature -and ($download.StagedPath -match ''\.psm?1$''))',
                '$sig = Get-AuthenticodeSignature -FilePath $download.StagedPath',
                'if ($sig.Status -ne ''Valid'')',
                'Self-update artifact failed Authenticode verification: $($download.RelativePath) ($($sig.Status))'
            )

            # The signature gate must run per downloaded file, before it replaces the live destination file.
            $applyLoopStart = $content.IndexOf('foreach ($download in $downloadedFiles)')
            $moveStart = $content.IndexOf('Move-Item -Path $tempDestinationPath', $applyLoopStart)
            $sigGateStart = $content.IndexOf('$enforceSignature = ', $applyLoopStart)
            $sigGateStart | Should -BeGreaterThan $applyLoopStart
            $sigGateStart | Should -BeLessThan $moveStart
        }
    }

    Context "Dependency writers lock scoping" {
        BeforeAll {
            $cycleLockScript = {
                param([string]$MutexName, $Ready, $Release)
                $mutex = [System.Threading.Mutex]::new($false, $MutexName)
                $acquired = $mutex.WaitOne(0)
                $Ready.Set()
                $null = $Release.Wait(10000)
                if ($acquired) { $mutex.ReleaseMutex() }
            }
            $writersLockScript = {
                param([string]$MutexName, $Ready, $Release)
                $mutex = [System.Threading.Mutex]::new($false, $MutexName)
                $acquired = $mutex.WaitOne(0)
                $Ready.Set()
                $null = $Release.Wait(10000)
                if ($acquired) { $mutex.ReleaseMutex() }
            }

            # Shared stubs for the update apply path (Phase 7 P2 stamping tests).
            . (Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1")
            function ConvertTo-OpenPathWhitelistFileContent { param($Whitelist, $BlockedSubdomains, $BlockedPaths) 'WHITELIST' }
            function Sync-FirefoxNativeHostMirror { param($Config, $WhitelistPath, [switch]$ClearWhitelist) }
            function Invoke-OpenPathRuntimeDependencyQueueApply {
                param($WhitelistPath, [switch]$PassThru)
                $script:queueApplyCalls++
                [PSCustomObject]@{ Changed = $true; Processed = 2; Rejected = 0; QueueProcessedMs = 5; OverlayWriteMs = 1; AcrylicHostUpdateMs = 1; AcrylicHostWritten = $true; AcrylicHostsChanged = $true }
            }
            function Get-OpenPathWhitelistSectionsFromFile { param($Path) [PSCustomObject]@{ Whitelist = @('example.com'); BlockedSubdomains = @(); IsDisabled = $false } }
            function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [PSCustomObject]@{ IsDisabled = $false; ProtectedModeEligible = $true } }
            function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $EnableBrowserPolicies, $QueueChanged) [PSCustomObject]@{ Mode = $Mode; Actions = @('RestoreProtectedMode'); QueueChanged = $false; ProtectedModeEligible = $true } }
            function Invoke-OpenPathEndpointStateRepairPlan {
                param($Plan, $Config, $BlockedPaths)
                [PSCustomObject]@{
                    AppliedActions = @('RestoreProtectedMode')
                    AcrylicRunning = $script:repairAcrylicRunning
                    DnsFlushed     = $script:repairDnsFlushed
                }
            }
            function Get-OpenPathRuntimeDependencyOverlayState {
                param([string]$Path = '')
                [PSCustomObject]@{ Exists = $true; Generation = $script:overlayGeneration; AppliedGeneration = $script:overlayApplied }
            }
            function Set-OpenPathRuntimeDependencyOverlayApplied {
                param([string]$Path = '', [int]$Generation = -1)
                $script:stampCalls += [PSCustomObject]@{ Generation = $Generation }
                return $true
            }
            function Invoke-OpenPathUpdateWritersLockScope {
                param([scriptblock]$Action, [string]$MutexName = '', [int]$TimeoutSeconds = 60, [string]$Stage = '')
                $script:lockScopes += $Stage
                return (& $Action)
            }
            function Clear-StaleFailsafeState { param($StaleFailsafeStatePath) }
            function Get-OpenPathRuntimeHealth { [PSCustomObject]@{ DnsServiceRunning = $true; DnsResolving = $true } }
            function Send-OpenPathHealthReport { param() [PSCustomObject]@{} }
            function Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') }
        }

        It "keeps the dependency writers path free while the update cycle lock is held" {
            $ready = [System.Threading.ManualResetEventSlim]::new($false)
            $release = [System.Threading.ManualResetEventSlim]::new($false)
            $holder = [powershell]::Create()
            $null = $holder.AddScript($cycleLockScript).AddArgument('Global\OpenPathUpdateLock').AddArgument($ready).AddArgument($release)
            $handle = $holder.BeginInvoke()
            try {
                $ready.Wait(5000) | Should -BeTrue
                Import-Module (Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1") -Force
                InModuleScope Update.Runtime {
                    # The dependency fast path takes the Acrylic writers lock; the
                    # whole-cycle exclusion lock must not gate it (Phase 7 P2).
                    (Invoke-OpenPathUpdateWritersLockScope -TimeoutSeconds 5 -Action { 'writers-ran' }) | Should -Be 'writers-ran'
                }
            }
            finally {
                $release.Set()
                $null = $holder.EndInvoke($handle)
                $holder.Dispose()
            }
        }

        It "times out when another writer holds the Acrylic writers lock" {
            $ready = [System.Threading.ManualResetEventSlim]::new($false)
            $release = [System.Threading.ManualResetEventSlim]::new($false)
            $holder = [powershell]::Create()
            $null = $holder.AddScript($writersLockScript).AddArgument('Global\OpenPathAcrylicWriteLock').AddArgument($ready).AddArgument($release)
            $handle = $holder.BeginInvoke()
            try {
                $ready.Wait(5000) | Should -BeTrue
                Import-Module (Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1") -Force
                InModuleScope Update.Runtime {
                    { Invoke-OpenPathUpdateWritersLockScope -TimeoutSeconds 1 -Action { 'blocked' } } |
                        Should -Throw '*Acrylic writers lock*'
                }
            }
            finally {
                $release.Set()
                $null = $holder.EndInvoke($handle)
                $holder.Dispose()
            }
        }

        It "keeps the shared writers scoped in the update cycle instead of held for the whole cycle" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'function Invoke-OpenPathUpdateWritersLockScope',
                "'Global\OpenPathAcrylicWriteLock'",
                "OpenPath update stage=",
                "OpenPath update stages totalMs=",
                'waited $($lockWaitStopwatch.ElapsedMilliseconds) ms for the Acrylic writers lock'
            )

            $fastApplyStart = $runtimeContent.IndexOf('function Invoke-OpenPathRuntimeDependencyFastApply')
            $updateCycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $fastApplyBody = $runtimeContent.Substring($fastApplyStart, $updateCycleStart - $fastApplyStart)
            $fastApplyBody | Should -Match "WriteMutexName = 'Global\\OpenPathAcrylicWriteLock'"
            ([regex]::Matches($fastApplyBody, 'Mutex\]::new\(\$false, \$WriteMutexName\)')).Count | Should -Be 1
        }

        It "stamps the overlay generation after a successful restart and DNS flush" {
            $script:repairAcrylicRunning = $true
            $script:repairDnsFlushed = $true
            $script:overlayGeneration = 3
            $script:overlayApplied = 1
            $script:stampCalls = @()
            $script:lockScopes = @()
            $script:queueApplyCalls = 0

            $config = [PSCustomObject]@{ enableBrowserPolicies = $false; outboundEgressFloorEnabled = $false }
            $whitelist = [PSCustomObject]@{ Whitelist = @('example.com'); BlockedSubdomains = @(); BlockedPaths = @() }
            Handle-OpenPathWhitelistApply `
                -Config $config `
                -Whitelist $whitelist `
                -WhitelistPath (Join-Path $TestDrive 'whitelist.txt') `
                -StaleFailsafeStatePath (Join-Path $TestDrive 'stale-failsafe-state.json') | Out-Null

            $script:queueApplyCalls | Should -Be 1
            $script:stampCalls.Count | Should -Be 1
            $script:stampCalls[0].Generation | Should -Be 3
            $script:lockScopes | Should -Contain 'whitelist-queue-apply'
            $script:lockScopes | Should -Contain 'overlay-stamp'
        }

        It "does not stamp when the repair plan did not prove both a restart and a flush" {
            $script:repairAcrylicRunning = $true
            $script:repairDnsFlushed = $false
            $script:overlayGeneration = 3
            $script:overlayApplied = 1
            $script:stampCalls = @()
            $script:lockScopes = @()
            $script:queueApplyCalls = 0

            $config = [PSCustomObject]@{ enableBrowserPolicies = $false; outboundEgressFloorEnabled = $false }
            $whitelist = [PSCustomObject]@{ Whitelist = @('example.com'); BlockedSubdomains = @(); BlockedPaths = @() }
            Handle-OpenPathWhitelistApply `
                -Config $config `
                -Whitelist $whitelist `
                -WhitelistPath (Join-Path $TestDrive 'whitelist.txt') `
                -StaleFailsafeStatePath (Join-Path $TestDrive 'stale-failsafe-state.json') | Out-Null

            $script:stampCalls.Count | Should -Be 0
            $script:lockScopes | Should -Contain 'whitelist-queue-apply'
            $script:lockScopes | Should -Not -Contain 'overlay-stamp'
        }

        It "does not stamp when the overlay generation was already applied" {
            $script:repairAcrylicRunning = $true
            $script:repairDnsFlushed = $true
            $script:overlayGeneration = 4
            $script:overlayApplied = 4
            $script:stampCalls = @()
            $script:lockScopes = @()
            $script:queueApplyCalls = 0

            $config = [PSCustomObject]@{ enableBrowserPolicies = $false; outboundEgressFloorEnabled = $false }
            $whitelist = [PSCustomObject]@{ Whitelist = @('example.com'); BlockedSubdomains = @(); BlockedPaths = @() }
            Handle-OpenPathWhitelistApply `
                -Config $config `
                -Whitelist $whitelist `
                -WhitelistPath (Join-Path $TestDrive 'whitelist.txt') `
                -StaleFailsafeStatePath (Join-Path $TestDrive 'stale-failsafe-state.json') | Out-Null

            $script:stampCalls.Count | Should -Be 0
        }
    }
}
