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

        Context "Stale whitelist fail-safe and server confirmation" {
            BeforeEach {
                . (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.System.ps1")
                . (Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1")

                $script:dataDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $script:dataDir | Out-Null
                $script:whitelistPath = Join-Path $script:dataDir 'whitelist.txt'
                $script:stalePath = Join-Path $script:dataDir 'stale-failsafe-state.json'
                Set-Content -Path $script:whitelistPath -Value "## WHITELIST`nexample.org"
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                $script:mirrorFingerprint = (Get-Item $script:whitelistPath).LastWriteTimeUtc
                $script:failsafeEntries = 0
                $script:healthStatuses = @()

                function Write-OpenPathLog { param([string]$Message, [string]$Level) }
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $false } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $false; ProtectedModeEligible = $true } }
                function Invoke-OpenPathUpdateWritersLockScope { param([string]$Stage, [scriptblock]$Action) return $false }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) [pscustomobject]@{ Actions = @() } }
                function Invoke-OpenPathEndpointStateRepairPlan { param($Plan, $Config) }
                function Get-OpenPathRuntimeHealth { [pscustomobject]@{ DnsServiceRunning = $true; DnsResolving = $true } }
                function Send-OpenPathHealthReport { param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions) $script:healthStatuses += $Status }
                function Clear-StaleFailsafeState { param([string]$StaleFailsafeStatePath) Remove-Item $StaleFailsafeStatePath -Force }
                function Enter-StaleWhitelistFailsafe { param($Config, $WhitelistAgeHours, $StaleFailsafeStatePath) $script:failsafeEntries++; Set-Content $StaleFailsafeStatePath '{}' }
            }

            It "Leaves the fail-safe when the server confirms the cached whitelist, without touching the whitelist file" {
                Set-Content -Path $script:stalePath -Value '{}'

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                Test-Path $script:stalePath | Should -BeFalse
                Test-Path (Join-Path $script:dataDir 'whitelist.verified') | Should -BeTrue
                (Get-Item $script:whitelistPath).LastWriteTimeUtc | Should -Be $script:mirrorFingerprint
                Get-OpenPathCachedWhitelistAgeHours -WhitelistPath $script:whitelistPath | Should -BeLessThan 1
            }

            It "Keeps using a recently confirmed whitelist when a later download fails" {
                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true

                $script:failsafeEntries | Should -Be 0
                Test-Path $script:stalePath | Should -BeFalse
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
            }

            It "Still enters the fail-safe when neither the file nor a server confirmation is recent" {
                Set-Content -Path (Join-Path $script:dataDir 'whitelist.verified') -Value 'old'
                (Get-Item (Join-Path $script:dataDir 'whitelist.verified')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-30)

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true

                $script:failsafeEntries | Should -Be 1
                $script:healthStatuses[-1] | Should -Be 'STALE_FAILSAFE'
            }
        }

        It "Restarts protected DNS when runtime dependency queue changes without a new whitelist" {
            $applyHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $applyContent = Get-Content $applyHelperPath -Raw

            $applyContent | Should -Match "(?s)Handle-OpenPathNotModified.*?\`$runtimeDependencyQueueChanged = \[bool\]\(Invoke-OpenPathUpdateWritersLockScope -Stage 'not-modified-queue-apply'.*?-QueueChanged \`$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan"
            $applyContent | Should -Match "(?s)Handle-OpenPathDownloadFailure.*?\`$runtimeDependencyQueueChanged = \[bool\]\(Invoke-OpenPathUpdateWritersLockScope -Stage 'download-failure-queue-apply'.*?-QueueChanged \`$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan"
        }

        It "Logs the Acrylic host update and restart sub-step breakdown (Phase 8g G3)" {
            $configPath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Config.ps1"
            $servicePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Service.ps1"
            $restartPath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Restart.ps1"
            $configContent = Get-Content $configPath -Raw
            $serviceContent = Get-Content $servicePath -Raw
            $restartContent = Get-Content $restartPath -Raw

            Assert-ContentContainsAll -Content $configContent -Needles @(
                'Invoke-OpenPathPolicyStateLocked -Metrics $hostMetrics',
                'Acrylic host update breakdown:',
                'lockWaitMs=',
                'renderMs=',
                'writeMs=',
                'iniMs=',
                'totalMs=',
                'Acrylic host update slow:'
            )
            Assert-ContentContainsAll -Content $serviceContent -Needles @(
                'Acrylic service restarted successfully $breakdown',
                'Acrylic service restart slow:',
                'stopMs=',
                'stoppedWaitMs=',
                'purgeMs=',
                'startMs=',
                'runningWaitMs='
            )
            Assert-ContentContainsAll -Content $restartContent -Needles @(
                'preDecisionMs=',
                'lockWaitMs=',
                'decisionMs=',
                'coreMs=',
                'stateRecordMs=',
                'probeRetry=1',
                'contentChanged=1'
            )
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
                '$acrylicReloaded = [bool](Restart-AcrylicService -ContentChanged:([bool]$queueResult.AcrylicHostsChanged))',
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
                'WorkerStatePath',
                'Invoke-OpenPathAcrylicRestartLockScope'
            )

            # Phase 8f F4: the reload, the DNS flush and the applied-generation
            # stamp run inside the global restart-lock scope, so no other
            # process can restart Acrylic between the worker's reload and its
            # stamp.
            $fastApplyStart = $runtimeContent.IndexOf('function Invoke-OpenPathRuntimeDependencyFastApply')
            $updateCycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $fastApplyBody = $runtimeContent.Substring($fastApplyStart, $updateCycleStart - $fastApplyStart)
            $scopeIndex = $fastApplyBody.IndexOf('$reloadScope = Invoke-OpenPathAcrylicRestartLockScope')
            $flushIndex = $fastApplyBody.IndexOf('Clear-OpenPathDnsClientCache')
            $stampIndex = $fastApplyBody.IndexOf('Set-OpenPathRuntimeDependencyOverlayApplied | Out-Null')
            ($scopeIndex -ge 0) | Should -BeTrue
            ($flushIndex -gt $scopeIndex) | Should -BeTrue
            ($stampIndex -gt $flushIndex) | Should -BeTrue
            $fastApplyBody | Should -Match '(?s)\$reloadScope = Invoke-OpenPathAcrylicRestartLockScope.*?Clear-OpenPathDnsClientCache.*?Set-OpenPathRuntimeDependencyOverlayApplied'
            $fastApplyBody | Should -Match 'could not take the Acrylic restart lock; dependencies remain pending'

            # Hot path: the config read + mirror rebuild must not run unconditionally
            # on every dependency batch (it cost ~5 s of the Phase 2A baseline).
            $runtimeContent | Should -Match 'function Sync-FirefoxNativeHostMirrorIfChanged'
            $runtimeContent | Should -Match 'function Get-OpenPathNativeHostMirrorSyncStatePath'

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
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Common.psm1") -Force -Global
        }

        It "Backs up every existing file into a per-run directory before replacing anything" {
            $updateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'data\agent-update',
                '''backups''',
                'New-OpenPathAgentUpdateBackupRoot',
                'Save-OpenPathAgentUpdateInstalledFileBackups',
                'manifest.json',
                '$tempDestinationPath',
                'Move-Item -Path $tempDestinationPath -Destination $download.DestinationPath -Force -ErrorAction Stop',
                'Post-replacement checksum mismatch'
            )

            $content | Should -Not -Match '\$replacementBackups'

            $backupStart = $content.IndexOf('Save-OpenPathAgentUpdateInstalledFileBackups -Files $downloadedFiles')
            $journalWriteStart = $content.IndexOf('Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot')
            $firstReplacementStart = $content.IndexOf('Move-Item -Path $tempDestinationPath')

            $backupStart | Should -BeGreaterThan 0
            $backupStart | Should -BeLessThan $journalWriteStart
            $journalWriteStart | Should -BeLessThan $firstReplacementStart
        }

        It "Rolls back from this run's backups even when an older run left a backup for the same version" {
            $root = Join-Path $TestDrive ('update-stale-backup-' + [guid]::NewGuid().ToString('N'))
            $destinationA = Join-Path $root 'lib/existing-a.ps1'
            $destinationB = Join-Path $root 'lib/existing-b.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destinationA -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destinationA -Value 'Write-Output "old-a"' -Encoding ASCII
            Set-Content -LiteralPath $destinationB -Value 'Write-Output "old-b"' -Encoding ASCII

            $staleBackup = Join-Path $root 'data/agent-update/backups/9.9.8/lib/existing-a.ps1'
            New-Item -ItemType Directory -Path (Split-Path $staleBackup -Parent) -Force | Out-Null
            Set-Content -LiteralPath $staleBackup -Value 'Write-Output "stale-a"' -Encoding ASCII

            $stagedA = Join-Path $TestDrive ('staged-a-' + [guid]::NewGuid().ToString('N') + '.ps1')
            $stagedB = Join-Path $TestDrive ('staged-b-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedA -Value 'Write-Output "new-a"' -Encoding ASCII
            Set-Content -LiteralPath $stagedB -Value 'Write-Output "new-b"' -Encoding ASCII
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @(
                    [PSCustomObject]@{ path = 'lib/existing-a.ps1'; sha256 = (Get-FileHash -LiteralPath $stagedA -Algorithm SHA256).Hash.ToLowerInvariant() },
                    [PSCustomObject]@{ path = 'lib/existing-b.ps1'; sha256 = (Get-FileHash -LiteralPath $stagedB -Algorithm SHA256).Hash.ToLowerInvariant() }
                )
            }

            InModuleScope Common -Parameters @{
                Root = $root
                Manifest = $manifest
                StagedA = $stagedA
                StagedB = $stagedB
            } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedA = $StagedA
                $script:TestStagedB = $StagedB
                $script:Captured = @{ Config = $null; Integrity = 0; Baseline = 0; Tasks = 0; GateCalls = 0 }
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    if ($Uri -match 'existing-a\.ps1$') {
                        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $script:TestStagedA -Destination $OutFile -Force
                    }
                    else {
                        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $script:TestStagedB -Destination $OutFile -Force
                    }
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { $script:Captured.Config = $Config }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { $script:Captured.Tasks++ }
                Mock Enable-OpenPathTask { $script:Captured.Tasks++ }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $script:FailStagedPath = $StagedB
                Mock Copy-Item {
                    param($Path, $LiteralPath, $Destination, $Force, $ErrorAction)
                    $source = if ($Path) { $Path } else { $LiteralPath }
                    if ($source -eq $script:FailStagedPath) {
                        throw 'simulated interruption during replacement'
                    }
                    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $source -Destination $Destination -Force
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing-a.ps1') -Raw).Trim() | Should -Be 'Write-Output "old-a"'
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing-b.ps1') -Raw).Trim() | Should -Be 'Write-Output "old-b"'
                $script:Captured.Config | Should -BeNullOrEmpty
                $script:Captured.Integrity | Should -Be 0
                $script:Captured.Baseline | Should -Be 0
                $script:Captured.Tasks | Should -Be 0
                $script:Captured.GateCalls | Should -Be 0
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse
            }
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
            $applyLoopStart = $content.IndexOf('foreach ($download in $downloadedFiles)')
            $downloadLoopBody = $content.Substring($downloadLoopStart, $applyLoopStart - $downloadLoopStart)
            $downloadLoopBody | Should -Match '(?s)Invoke-WebRequest -Uri \$fileUrl.*?\$actualHash = \(Get-FileHash -Path \$stagedPath -Algorithm SHA256 -ErrorAction Stop\)\.Hash\.ToLowerInvariant\(\)\s+if \(\$actualHash -ne \$expectedHash\.ToLowerInvariant\(\)\) \{\s+throw "Checksum mismatch for \$manifestPath"'

            $postReplacementStart = $content.IndexOf('Post-replacement checksum mismatch')
            $gateStart = $content.IndexOf('Invoke-OpenPathAgentUpdateHealthGate -OpenPathRoot $script:OpenPathRoot')
            $postReplacementStart | Should -BeGreaterThan 0
            $gateStart | Should -BeGreaterThan $postReplacementStart
            $content | Should -Match '(?s)\$actualHash = \(Get-FileHash -Path \$download\.DestinationPath -Algorithm SHA256 -ErrorAction Stop\)\.Hash\.ToLowerInvariant\(\)\s+if \(\$actualHash -ne \$expectedHash\.ToLowerInvariant\(\)\) \{\s+throw "Post-replacement checksum mismatch for \$\(\$download\.RelativePath\)"'
        }

        It "Refreshes the integrity backup only after the new files are verified, under the update lock" {
            # Saving the backup before the replacement left the old files in it, and a
            # watchdog cycle during the update restored them over the new version.
            $updateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            $lockStart = $content.IndexOf('$updateLock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds')
            $replaceStart = $content.IndexOf('Move-Item -Path $tempDestinationPath')
            $verifyStart = $content.IndexOf('Post-replacement checksum mismatch')
            $commitStart = $content.IndexOf("Update-OpenPathAgentUpdateJournalPhase -OpenPathRoot `$script:OpenPathRoot -Journal `$updateJournal -Phase 'committed'")
            $finalizationCall = $content.IndexOf('Complete-OpenPathAgentUpdateFinalization `', $commitStart)
            $releaseStart = $content.IndexOf('Exit-OpenPathAgentUpdateLock -Lock $updateLock')

            $finalizationStart = $content.IndexOf('function Complete-OpenPathAgentUpdateFinalization')
            $finalizationEnd = $content.IndexOf("`nfunction ", $finalizationStart + 1)
            if ($finalizationEnd -lt 0) {
                $finalizationEnd = $content.Length
            }
            $finalizationBody = $content.Substring($finalizationStart, $finalizationEnd - $finalizationStart)
            $targetCheckStart = $finalizationBody.IndexOf('Test-OpenPathAgentUpdateJournalTargetHashes')
            $backupStart = $finalizationBody.IndexOf('Save-OpenPathIntegrityBackup | Out-Null')
            $baselineStart = $finalizationBody.IndexOf('New-OpenPathIntegrityBaseline | Out-Null')
            $journalRemovalStart = $finalizationBody.IndexOf('Remove-OpenPathAgentUpdateJournal')

            $lockStart | Should -BeGreaterThan 0
            $lockStart | Should -BeLessThan $replaceStart
            ([regex]::Matches($content, 'Save-OpenPathIntegrityBackup')).Count | Should -Be 1
            $verifyStart | Should -BeGreaterThan $replaceStart
            $commitStart | Should -BeGreaterThan $verifyStart
            $commitStart | Should -BeLessThan $finalizationCall
            $finalizationStart | Should -BeGreaterThan 0
            $targetCheckStart | Should -BeGreaterThan 0
            $backupStart | Should -BeGreaterThan $targetCheckStart
            $backupStart | Should -BeLessThan $baselineStart
            $journalRemovalStart | Should -BeGreaterThan $baselineStart
            $releaseStart | Should -BeGreaterThan $finalizationCall
        }

        It "Lets only one holder take the agent update lock at a time" {
            $commonPath = (Resolve-Path (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1")).Path
            . $commonPath
            $script:OpenPathAgentUpdateLockName = "OpenPathTestLock-$([guid]::NewGuid().ToString('N'))"
            $holderScript = @"
`$m = [System.Threading.Mutex]::new(`$false, '$($script:OpenPathAgentUpdateLockName)')
`$null = `$m.WaitOne()
[Console]::Out.WriteLine('held'); [Console]::Out.Flush()
`$null = [Console]::In.ReadLine()
`$m.ReleaseMutex()
"@
            $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $psi.ArgumentList.Add('-NoProfile')
            $psi.ArgumentList.Add('-Command')
            $psi.ArgumentList.Add($holderScript)
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $holder = [System.Diagnostics.Process]::Start($psi)
            try {
                $holder.StandardOutput.ReadLine() | Should -Be 'held'

                $busy = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 0
                $busy.Acquired | Should -BeFalse
                $busy.Mutex | Should -BeNullOrEmpty
                Exit-OpenPathAgentUpdateLock -Lock $busy

                $holder.StandardInput.WriteLine('release')
                $holder.WaitForExit(30000) | Should -BeTrue

                $free = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 5000
                try {
                    $free.Acquired | Should -BeTrue
                }
                finally {
                    Exit-OpenPathAgentUpdateLock -Lock $free
                }
            }
            finally {
                if (-not $holder.HasExited) { $holder.Kill() }
                $holder.Dispose()
            }
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

    Context "Update runtime resolution of shared helpers" {
        It "exports the overlay state helper the update apply path uses" {
            # Phase 7 fix: the update apply path reads the overlay state in the
            # writers scope. A shared helper that is not exported by its module
            # (and not listed as a session requirement) breaks the real install
            # update with "not recognized" (Windows E2E run 37731855999).
            $dnsPath = (Resolve-Path (Join-Path $PSScriptRoot ".." "lib" "DNS.psm1")).Path
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $script = "Import-Module '$($dnsPath -replace "'", "''")' -Force -ErrorAction SilentlyContinue; " +
            "if (Get-Command -Name Get-OpenPathRuntimeDependencyOverlayState -ErrorAction SilentlyContinue) { 'resolved' } else { 'missing' }"
            $result = & pwsh -NoProfile -Command $script | Select-Object -Last 1
            $result | Should -Be 'resolved'

            # The update runtime session must also require it, so a future move
            # fails the session bootstrap instead of the first update cycle.
            (Get-Content -LiteralPath $runtimePath -Raw) | Should -Match "'Get-OpenPathRuntimeDependencyOverlayState'"
        }

        It "re-exports the compiled native host entrypoints for every Browser consumer (Phase 8b)" {
            # The ensure/health entrypoints live in Browser.FirefoxNativeHost.psm1
            # and were private to it, so the self-update retry, the watchdog
            # health report and the installer SAC notice skipped them silently.
            $browserPath = (Resolve-Path (Join-Path $PSScriptRoot ".." "lib" "Browser.psm1")).Path
            $script = "Import-Module '$($browserPath -replace "'", "''")' -Force -ErrorAction SilentlyContinue; " +
            "if ((Get-Command -Name Invoke-OpenPathFirefoxNativeHostCompiledEnsure -ErrorAction SilentlyContinue) -and " +
            "(Get-Command -Name Get-OpenPathFirefoxNativeHostCompiledHealth -ErrorAction SilentlyContinue)) { 'resolved' } else { 'missing' }"
            $result = & pwsh -NoProfile -Command $script | Select-Object -Last 1
            $result | Should -Be 'resolved'
        }

        It "runs the compiled native host ensure after the cycle released the update lock (Phase 8c)" {
            # The ensure used to run inside the cycle while Global\OpenPathUpdateLock
            # was held; a host whose ping times out (compile + 20 s + 45 s) then
            # made an SSE approval wait and skip its cycle.
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw
            $cycleStart = $runtimeContent.IndexOf('function Invoke-OpenPathUpdateCycle')
            $cycleEnd = $runtimeContent.IndexOf('function Write-OpenPathUpdatePortalActiveState')
            ($cycleStart -ge 0) | Should -BeTrue
            ($cycleEnd -gt $cycleStart) | Should -BeTrue
            $cycleBody = $runtimeContent.Substring($cycleStart, $cycleEnd - $cycleStart)

            $cycleBody | Should -Match 'Invoke-OpenPathNativeHostPostCycleEnsure'
            $cycleBody | Should -Not -Match 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure'
            $cycleBody | Should -Not -Match "writeUpdateStage 'native-host'"
            $releaseIndex = $cycleBody.IndexOf('ReleaseMutex')
            $postEnsureIndex = $cycleBody.LastIndexOf('Invoke-OpenPathNativeHostPostCycleEnsure')
            ($releaseIndex -ge 0) | Should -BeTrue
            ($postEnsureIndex -gt $releaseIndex) | Should -BeTrue
        }
    }

    Context "Post-cycle native host ensure (Phase 8c)" {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1") -Force
        }

        It "does not run the ensure for SSE cycles" {
            InModuleScope Update.Runtime {
                $script:ensureCalls = 0
                $ran = Invoke-OpenPathNativeHostPostCycleEnsure -TriggerSource 'SSE' -EnsureInvoker { $script:ensureCalls = $script:ensureCalls + 1 }
                $ran | Should -BeFalse
                $script:ensureCalls | Should -Be 0
            }
        }

        It "runs after a periodic cycle and logs the stage as outside the lock" {
            InModuleScope Update.Runtime {
                $script:ensureCalls = 0
                $script:logLines = New-Object System.Collections.ArrayList
                $logLines = $script:logLines
                function Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') $null = $logLines.Add([string]$Message) }

                $ran = Invoke-OpenPathNativeHostPostCycleEnsure -TriggerSource 'Update' -EnsureInvoker { $script:ensureCalls = $script:ensureCalls + 1 }

                $ran | Should -BeTrue
                $script:ensureCalls | Should -Be 1
                ($script:logLines -join "`n") | Should -Match 'stage=native-host'
                ($script:logLines -join "`n") | Should -Match 'lock=released'
            }
        }

        It "leaves the update lock free while a slow ensure runs" {
            # Simulated long ensure (the H1 shape costs ~70 s): the post-cycle
            # ensure must never hold Global\OpenPathUpdateLock, so another
            # cycle (an SSE approval) can acquire it without waiting.
            $ready = Join-Path $TestDrive ('ensure-running-' + [guid]::NewGuid().ToString('N') + '.marker')
            $modulePath = (Resolve-Path (Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1")).Path
            $slowEnsure = {
                param($modulePath, $ready)
                function global:Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') }
                Import-Module $modulePath -Force
                & (Get-Module Update.Runtime) {
                    Invoke-OpenPathNativeHostPostCycleEnsure -TriggerSource 'Update' -EnsureInvoker {
                        Set-Content -LiteralPath $ready -Value 'running' -Encoding ASCII
                        Start-Sleep -Seconds 5
                    } | Out-Null
                }
            }
            $holder = [powershell]::Create()
            $null = $holder.AddScript($slowEnsure).AddArgument($modulePath).AddArgument($ready)
            $handle = $holder.BeginInvoke()
            try {
                $deadline = (Get-Date).AddSeconds(15)
                while (-not (Test-Path -LiteralPath $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
                (Test-Path -LiteralPath $ready) | Should -BeTrue

                $mutex = [System.Threading.Mutex]::new($false, 'Global\OpenPathUpdateLock')
                $acquired = $false
                try {
                    $acquired = $mutex.WaitOne(0)
                    $acquired | Should -BeTrue
                }
                finally {
                    if ($acquired) { $mutex.ReleaseMutex() }
                    $mutex.Dispose()
                }
            }
            finally {
                $null = $holder.EndInvoke($handle)
                $holder.Dispose()
            }
        }
    }

    Context "Dependency writers lock scoping" {        BeforeAll {
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

    Context "Self-update staged validation and journal" {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Common.psm1") -Force -Global
        }

        It "Rejects a staged script with a syntax error before replacing any installed file" {
            $root = Join-Path $TestDrive ('update-validate-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII

            $stagedSource = Join-Path $TestDrive ('bad-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'function Broken { if ( }' -Encoding ASCII
            $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-bad'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
            }

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; StagedSource = $stagedSource } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                $script:Captured = @{ Config = $null; Integrity = 0; Baseline = 0; Reports = @(); GateCalls = 0 }
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { $script:Captured.Config = $Config }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:Captured.Reports += [PSCustomObject]@{
                        Status      = $Status
                        Actions     = $Actions
                        ReasonCodes = @($ReasonCodes)
                    }
                }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "old"'
                $script:Captured.Config | Should -BeNullOrEmpty
                $script:Captured.GateCalls | Should -Be 0
                $script:Captured.Integrity | Should -Be 0
                $script:Captured.Reports.Count | Should -Be 1
                $script:Captured.Reports[0].Status | Should -Be 'DEGRADED'
                (@($script:Captured.Reports[0].ReasonCodes) -join ' ') | Should -Match 'self_update_validation_failed'

                $recordPath = Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root
                Test-Path -LiteralPath $recordPath | Should -BeTrue
                $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
                $record.build | Should -Be 'build-bad'
                $record.stage | Should -Be 'validation'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
            }
        }

        It "Writes the journal with every file before the first replacement" {
            $root = Join-Path $TestDrive ('update-journal-' + [guid]::NewGuid().ToString('N'))
            $backupRoot = Join-Path $root 'data/agent-update/backups/9.9.8'
            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'replacing'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $backupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                files           = @(
                    [PSCustomObject]@{ relativePath = 'lib\a.ps1'; existedBefore = $true; previousSha256 = ('c' * 64); sha256 = ('a' * 64) },
                    [PSCustomObject]@{ relativePath = 'lib\b.ps1'; existedBefore = $false; previousSha256 = ''; sha256 = ('b' * 64) }
                )
            }

            InModuleScope Common -Parameters @{ Root = $root; Journal = $journal } {
                Write-OpenPathAgentUpdateJournal -OpenPathRoot $Root -Journal $Journal

                $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root
                Test-Path -LiteralPath $journalPath | Should -BeTrue
                $written = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
                $written.schemaVersion | Should -Be 2
                $written.phase | Should -Be 'replacing'
                @($written.files).Count | Should -Be 2
                @($written.files | Where-Object { $_.relativePath -eq 'lib\a.ps1' }).existedBefore | Should -BeTrue
                @($written.files | Where-Object { $_.relativePath -eq 'lib\a.ps1' }).previousSha256 | Should -Be ('c' * 64)
                @($written.files | Where-Object { $_.relativePath -eq 'lib\b.ps1' }).existedBefore | Should -BeFalse

                Update-OpenPathAgentUpdateJournalPhase -OpenPathRoot $Root -Journal $Journal -Phase 'validating'
                $updated = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
                $updated.phase | Should -Be 'validating'
            }

            $updatePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $content = Get-Content $updatePath -Raw
            $lockStart = $content.IndexOf('$updateLock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds')
            $backupStart = $content.IndexOf('Save-OpenPathAgentUpdateInstalledFileBackups -Files $downloadedFiles', $lockStart)
            $journalWriteStart = $content.IndexOf('Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot', $lockStart)
            $firstReplacementStart = $content.IndexOf('Move-Item -Path $tempDestinationPath', $lockStart)

            $lockStart | Should -BeGreaterThan 0
            $backupStart | Should -BeGreaterThan $lockStart
            $backupStart | Should -BeLessThan $journalWriteStart
            $journalWriteStart | Should -BeGreaterThan $lockStart
            $firstReplacementStart | Should -BeGreaterThan $journalWriteStart
        }
    }

    Context "Self-update health gate and failure backoff" {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Common.psm1") -Force -Global
        }

        It "Rolls back, reports and records the failure when the health gate rejects the new tree" {
            $root = Join-Path $TestDrive ('update-gate-fail-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII

            $stagedSource = Join-Path $TestDrive ('new-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'Write-Output "new"' -Encoding ASCII
            $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
            }

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; StagedSource = $stagedSource } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                $script:Captured = @{ Config = $null; Integrity = 0; Baseline = 0; Tasks = 0; Reports = @(); GateCalls = 0 }
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { $script:Captured.Config = $Config }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { $script:Captured.Tasks++ }
                Mock Enable-OpenPathTask { $script:Captured.Tasks++ }
                Mock Restore-OpenPathProtectedMode { }
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:Captured.Reports += [PSCustomObject]@{
                        Status      = $Status
                        Actions     = $Actions
                        ReasonCodes = @($ReasonCodes)
                    }
                }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    if ($script:Captured.GateCalls -eq 1) {
                        return [PSCustomObject]@{ Healthy = $false; Message = 'new tree failed to load'; TimedOut = $false }
                    }
                    return [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "old"'
                $script:Captured.Config | Should -BeNullOrEmpty
                $script:Captured.Integrity | Should -Be 0
                $script:Captured.Baseline | Should -Be 0
                $script:Captured.Tasks | Should -Be 0
                $script:Captured.GateCalls | Should -Be 2
                $script:Captured.Reports.Count | Should -Be 1
                (@($script:Captured.Reports[0].ReasonCodes) -join ' ') | Should -Match 'self_update_health_gate_failed'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse

                $record = Get-Content -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) -Raw | ConvertFrom-Json
                $record.stage | Should -Be 'gate'
                $record.build | Should -Be 'build-new'
            }
        }

        It "Keeps the new tree, refreshes integrity and removes the journal when the gate passes" {
            $root = Join-Path $TestDrive ('update-gate-pass-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII

            $stagedSource = Join-Path $TestDrive ('good-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'Write-Output "new"' -Encoding ASCII
            $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
            }

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; StagedSource = $stagedSource } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                $script:Captured = @{ Config = $null; Integrity = 0; Baseline = 0; Tasks = 0; Reports = @(); GateCalls = 0 }
                $backupsRoot = Join-Path $Root 'data/agent-update/backups'
                New-Item -ItemType Directory -Path (Join-Path $backupsRoot '9.9.8') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $backupsRoot '9.9.8/stale.txt') -Value 'stale' -Encoding ASCII
                New-Item -ItemType Directory -Path (Join-Path $backupsRoot 'run-old') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $backupsRoot 'run-old/stale.txt') -Value 'stale' -Encoding ASCII
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { $script:Captured.Config = $Config }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { $script:Captured.Tasks++ }
                Mock Enable-OpenPathTask { $script:Captured.Tasks++ }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeTrue
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "new"'
                $script:Captured.Config.version | Should -Be '9.9.9'
                $script:Captured.Config.agentBuild | Should -Be 'build-new'
                $script:Captured.Integrity | Should -Be 1
                $script:Captured.Baseline | Should -Be 1
                $script:Captured.Tasks | Should -BeGreaterThan 0
                $script:Captured.GateCalls | Should -Be 1
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse

                $remainingBackups = @(Get-ChildItem -LiteralPath $backupsRoot -Directory)
                $remainingBackups.Count | Should -Be 1
                $remainingBackups[0].Name | Should -Match '^run-'
            }
        }

        It "Matches a failed build by build when present and by version when absent" {
            InModuleScope Common {
                $now = [DateTimeOffset]::UtcNow
                $failedAt = $now.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                $record = [PSCustomObject]@{ version = '9.9.9'; build = 'build-bad'; failedAt = $failedAt }

                Test-OpenPathAgentUpdateFailureMatchesTarget -Record $record -TargetVersion '9.9.9' -TargetBuild 'build-bad' | Should -BeTrue
                Test-OpenPathAgentUpdateFailureMatchesTarget -Record $record -TargetVersion '9.9.9' -TargetBuild 'build-other' | Should -BeFalse
                Test-OpenPathAgentUpdateFailureBackoffActive -Record $record -Now $now | Should -BeTrue
                Test-OpenPathAgentUpdateFailureBackoffActive -Record $record -Now $now.AddDays(8) | Should -BeFalse

                $versionOnly = [PSCustomObject]@{ version = '9.9.9'; build = ''; failedAt = $failedAt }
                Test-OpenPathAgentUpdateFailureMatchesTarget -Record $versionOnly -TargetVersion '9.9.9' -TargetBuild '' | Should -BeTrue
                Test-OpenPathAgentUpdateFailureMatchesTarget -Record $versionOnly -TargetVersion '9.9.8' -TargetBuild '' | Should -BeFalse
            }
        }

        It "Skips a recently failed target build without downloading files" {
            $root = Join-Path $TestDrive ('update-skip-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $root 'data/agent-update') -Force | Out-Null
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-bad'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = ('c' * 64) })
            }

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                Save-OpenPathAgentUpdateFailureRecord -OpenPathRoot $Root -Version '9.9.9' -Build 'build-bad' -Stage 'gate' -Message 'previous failure'
                $script:WebRequests = 0
                $script:GateCalls = 0
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest { $script:WebRequests++ }
                Mock Write-OpenPathLog { }
                Mock Invoke-OpenPathAgentUpdateHealthGate { $script:GateCalls++ }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeFalse
                $result.Message | Should -Match 'previously failed'
                $script:WebRequests | Should -Be 0
                $script:GateCalls | Should -Be 0
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeTrue
            }
        }

        It "Attempts a different build from the server and clears the failed record" {
            $root = Join-Path $TestDrive ('update-different-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII
            $stagedSource = Join-Path $TestDrive ('different-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'Write-Output "new"' -Encoding ASCII
            $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-good'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
            }

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; StagedSource = $stagedSource } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                Save-OpenPathAgentUpdateFailureRecord -OpenPathRoot $Root -Version '9.9.9' -Build 'build-bad' -Stage 'gate' -Message 'previous failure'
                $script:WebRequests = 0
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    $script:WebRequests++
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate { [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false } }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $script:WebRequests | Should -Be 1
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse
            }
        }

        It "Retries the same build after the seven-day backoff" {
            $root = Join-Path $TestDrive ('update-backoff-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII
            $stagedSource = Join-Path $TestDrive ('backoff-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'Write-Output "new"' -Encoding ASCII
            $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-bad'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
            }

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; StagedSource = $stagedSource } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                $oldTimestamp = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                $recordPath = Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root
                New-Item -ItemType Directory -Path (Split-Path $recordPath -Parent) -Force | Out-Null
                [PSCustomObject]@{
                    schemaVersion = 1
                    version       = '9.9.9'
                    build         = 'build-bad'
                    stage         = 'gate'
                    message       = 'previous failure'
                    failedAt      = $oldTimestamp
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath -Encoding UTF8
                $script:WebRequests = 0
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    $script:WebRequests++
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate { [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false } }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $script:WebRequests | Should -Be 1
            }
        }
    }

    Context "Self-update finalization" {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Common.psm1") -Force -Global
        }

        It "Keeps the committed journal and does not roll back when finalization fails at <Step>" -ForEach @(
            @{ Step = 'config' }
            @{ Step = 'tasks' }
            @{ Step = 'integrity' }
            @{ Step = 'baseline' }
            @{ Step = 'backup-cleanup' }
            @{ Step = 'journal-removal' }
        ) {
            $root = Join-Path $TestDrive ('finalize-fail-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-target' -Encoding ASCII
            $targetHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()

            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            New-Item -ItemType Directory -Path (Split-Path (Join-Path $backupRoot 'lib/existing.ps1') -Parent) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $backupRoot 'lib/existing.ps1') -Value 'old-target' -Encoding ASCII
            $previousHash = (Get-FileHash -LiteralPath (Join-Path $backupRoot 'lib/existing.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()

            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'committed'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $backupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                files           = @(
                    [PSCustomObject]@{
                        relativePath   = 'lib\existing.ps1'
                        existedBefore  = $true
                        previousSha256 = $previousHash
                        sha256         = $targetHash
                    }
                )
            }
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            New-Item -ItemType Directory -Path (Split-Path $journalPath -Parent) -Force | Out-Null
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
            $config = [PSCustomObject]@{ version = '9.9.8'; agentBuild = 'build-old' }

            InModuleScope Common -Parameters @{
                Root = $root
                Journal = $journal
                Step = $Step
                Config = $config
            } {
                $script:OpenPathRoot = $Root
                $script:ReportCount = 0
                $script:LastReasonCodes = @()
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:ReportCount++
                    $script:LastReasonCodes = @($ReasonCodes)
                }
                Mock Set-OpenPathConfig {
                    if ($Step -eq 'config') { throw 'config failure' }
                }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask {
                    if ($Step -eq 'tasks') { throw 'task failure' }
                }
                Mock Enable-OpenPathTask { }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Save-OpenPathIntegrityBackup {
                    if ($Step -eq 'integrity') { throw 'integrity failure' }
                }
                Mock New-OpenPathIntegrityBaseline {
                    if ($Step -eq 'baseline') { throw 'baseline failure' }
                }
                Mock Remove-OpenPathAgentUpdateBackupDirectories {
                    if ($Step -eq 'backup-cleanup') { throw 'cleanup failure' }
                }
                Mock Remove-OpenPathAgentUpdateJournal {
                    if ($Step -eq 'journal-removal') { throw 'journal failure' }
                }

                $result = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config

                $result.Success | Should -BeFalse
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'new-target'
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') | Should -BeTrue
                $journalOnDisk = Get-Content -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') -Raw | ConvertFrom-Json
                $journalOnDisk.phase | Should -Be 'committed'
                $script:ReportCount | Should -Be 1
                ($script:LastReasonCodes -join ' ') | Should -Be 'self_update_finalization_failed'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse
            }
        }

        It "Fails a target hash mismatch before changing config, tasks, protected mode or integrity data" {
            $root = Join-Path $TestDrive ('finalize-hash-side-effects-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'wrong-target' -Encoding ASCII

            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'committed'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $backupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                files           = @(
                    [PSCustomObject]@{
                        relativePath   = 'lib\existing.ps1'
                        existedBefore  = $true
                        previousSha256 = ('e' * 64)
                        sha256         = ('d' * 64)
                    }
                )
            }
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            New-Item -ItemType Directory -Path (Split-Path $journalPath -Parent) -Force | Out-Null
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
            $config = [PSCustomObject]@{ version = '9.9.8'; agentBuild = 'build-old' }

            InModuleScope Common -Parameters @{ Root = $root; Journal = $journal; Config = $config } {
                $script:OpenPathRoot = $Root
                $script:Captured = @{ Config = 0; Tasks = 0; Protected = 0; Integrity = 0; Baseline = 0; Cleanup = 0; Reports = 0 }
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport { $script:Captured.Reports++ }
                Mock Set-OpenPathConfig { $script:Captured.Config++ }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { $script:Captured.Tasks++ }
                Mock Enable-OpenPathTask { $script:Captured.Tasks++ }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { $script:Captured.Protected++ }
                Mock Start-OpenPathTask { }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                Mock Remove-OpenPathAgentUpdateBackupDirectories { $script:Captured.Cleanup++ }

                $result = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config

                $result.Success | Should -BeFalse
                $result.FailureCode | Should -Be 'hash_mismatch'
                $script:Captured.Config | Should -Be 0
                $script:Captured.Tasks | Should -Be 0
                $script:Captured.Protected | Should -Be 0
                $script:Captured.Integrity | Should -Be 0
                $script:Captured.Baseline | Should -Be 0
                $script:Captured.Cleanup | Should -Be 0
                $script:Captured.Reports | Should -Be 1

                $journalOnDisk = Get-Content -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') -Raw | ConvertFrom-Json
                $journalOnDisk.phase | Should -Be 'committed'
                $journalOnDisk.finalizationAttempts | Should -Be 1
            }
        }

        It "Counts each finalization attempt and treats a journal without the field as zero" {
            $root = Join-Path $TestDrive ('finalize-attempts-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-target' -Encoding ASCII
            $targetHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()

            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'committed'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $backupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                files           = @(
                    [PSCustomObject]@{
                        relativePath   = 'lib\existing.ps1'
                        existedBefore  = $true
                        previousSha256 = ('e' * 64)
                        sha256         = $targetHash
                    }
                )
            }
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            New-Item -ItemType Directory -Path (Split-Path $journalPath -Parent) -Force | Out-Null
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
            $config = [PSCustomObject]@{ version = '9.9.8'; agentBuild = 'build-old' }

            InModuleScope Common -Parameters @{ Root = $root; Journal = $journal; Config = $config } {
                $script:OpenPathRoot = $Root
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport { }
                Mock Set-OpenPathConfig { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Save-OpenPathIntegrityBackup { throw 'disk full' }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Remove-OpenPathAgentUpdateBackupDirectories { }

                $first = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config
                $first.Success | Should -BeFalse

                $journalPath = Join-Path $Root 'data/agent-update/update-journal.json'
                $afterFirst = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
                $afterFirst.finalizationAttempts | Should -Be 1

                $second = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $afterFirst -Config $Config
                $second.Success | Should -BeFalse

                $afterSecond = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
                $afterSecond.finalizationAttempts | Should -Be 2
            }
        }

        It "Stops before refreshing integrity when an installed file does not match the target hash" {
            $root = Join-Path $TestDrive ('finalize-hash-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'wrong-target' -Encoding ASCII
            $targetHash = ('d' * 64)

            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'committed'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $backupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                files           = @(
                    [PSCustomObject]@{
                        relativePath   = 'lib\existing.ps1'
                        existedBefore  = $true
                        previousSha256 = ('e' * 64)
                        sha256         = $targetHash
                    }
                )
            }
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            New-Item -ItemType Directory -Path (Split-Path $journalPath -Parent) -Force | Out-Null
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
            $config = [PSCustomObject]@{ version = '9.9.8'; agentBuild = 'build-old' }

            InModuleScope Common -Parameters @{ Root = $root; Journal = $journal; Config = $config } {
                $script:OpenPathRoot = $Root
                $script:IntegrityCalls = 0
                $script:BaselineCalls = 0
                $script:ReportCount = 0
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:ReportCount++
                }
                Mock Set-OpenPathConfig { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Save-OpenPathIntegrityBackup { $script:IntegrityCalls++ }
                Mock New-OpenPathIntegrityBaseline { $script:BaselineCalls++ }
                Mock Remove-OpenPathAgentUpdateBackupDirectories { }
                Mock Remove-OpenPathAgentUpdateJournal { }

                $result = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config

                $result.Success | Should -BeFalse
                $script:IntegrityCalls | Should -Be 0
                $script:BaselineCalls | Should -Be 0
                $script:ReportCount | Should -Be 1
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') | Should -BeTrue
                $journalOnDisk = Get-Content -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') -Raw | ConvertFrom-Json
                $journalOnDisk.phase | Should -Be 'committed'
            }
        }

        It "Completes finalization idempotently when the first attempt fails after writing config" {
            $root = Join-Path $TestDrive ('finalize-retry-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-target' -Encoding ASCII
            $targetHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()

            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'committed'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $backupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                files           = @(
                    [PSCustomObject]@{
                        relativePath   = 'lib\existing.ps1'
                        existedBefore  = $true
                        previousSha256 = ('e' * 64)
                        sha256         = $targetHash
                    }
                )
            }
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            New-Item -ItemType Directory -Path (Split-Path $journalPath -Parent) -Force | Out-Null
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
            $config = [PSCustomObject]@{ version = '9.9.8'; agentBuild = 'build-old' }

            InModuleScope Common -Parameters @{ Root = $root; Journal = $journal; Config = $config } {
                $script:OpenPathRoot = $Root
                $script:IntegrityAttempts = 0
                $script:ReportCount = 0
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:ReportCount++
                }
                Mock Set-OpenPathConfig { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Save-OpenPathIntegrityBackup {
                    $script:IntegrityAttempts++
                    if ($script:IntegrityAttempts -eq 1) {
                        throw 'disk full'
                    }
                }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Remove-OpenPathAgentUpdateBackupDirectories { }

                $first = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config

                $first.Success | Should -BeFalse
                $Config.version | Should -Be '9.9.9'
                $Config.agentBuild | Should -Be 'build-new'
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'new-target'
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') | Should -BeTrue

                $second = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config

                $second.Success | Should -BeTrue
                $Config.version | Should -Be '9.9.9'
                $Config.agentBuild | Should -Be 'build-new'
                $script:IntegrityAttempts | Should -Be 2
                $script:ReportCount | Should -Be 1
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') | Should -BeFalse
            }
        }

        It "Runs finalization from a committed journal at the start of self-update" {
            $root = Join-Path $TestDrive ('finalize-startup-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-target' -Encoding ASCII
            $targetHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()

            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'committed'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $backupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                files           = @(
                    [PSCustomObject]@{
                        relativePath   = 'lib\existing.ps1'
                        existedBefore  = $true
                        previousSha256 = ('e' * 64)
                        sha256         = $targetHash
                    }
                )
            }
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            New-Item -ItemType Directory -Path (Split-Path $journalPath -Parent) -Force | Out-Null
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $targetHash })
            }

            InModuleScope Common -Parameters @{
                Root = $root
                Manifest = $manifest
                TargetHash = $targetHash
            } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TargetHash = $TargetHash
                $script:Captured = @{ Config = $null; Integrity = 0; Baseline = 0; Tasks = 0; GateCalls = 0 }
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest { throw 'the update should not download when finalization already caught up' }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { $script:Captured.Config = $Config }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { $script:Captured.Tasks++ }
                Mock Enable-OpenPathTask { $script:Captured.Tasks++ }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeFalse
                $script:Captured.Config.version | Should -Be '9.9.9'
                $script:Captured.Config.agentBuild | Should -Be 'build-new'
                $script:Captured.Integrity | Should -Be 1
                $script:Captured.Baseline | Should -Be 1
                $script:Captured.Tasks | Should -BeGreaterThan 0
                $script:Captured.GateCalls | Should -Be 0
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
            }
        }
    }

    Context "Self-update stuck finalization" {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Common.psm1") -Force -Global

            function New-StuckFinalizationFixture {
                param(
                    [string]$InstalledContent = 'stuck-target',
                    [string]$JournalTargetContent = 'stuck-target',
                    [string]$TargetBuild = 'build-stuck'
                )

                $root = Join-Path $TestDrive ('stuck-finalization-' + [guid]::NewGuid().ToString('N'))
                $destination = Join-Path $root 'lib/existing.ps1'
                New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
                Set-Content -LiteralPath $destination -Value $InstalledContent -Encoding ASCII

                $expectedPath = Join-Path $TestDrive ('expected-' + [guid]::NewGuid().ToString('N') + '.ps1')
                Set-Content -LiteralPath $expectedPath -Value $JournalTargetContent -Encoding ASCII
                try {
                    $targetHash = (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
                finally {
                    Remove-Item -LiteralPath $expectedPath -Force -ErrorAction SilentlyContinue
                }

                $backupRoot = Join-Path $root 'data/agent-update/backups/run-stuck'
                New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
                $journal = [PSCustomObject]@{
                    schemaVersion   = 2
                    phase           = 'committed'
                    targetVersion   = '9.9.9'
                    targetBuild     = $TargetBuild
                    previousVersion = '9.9.8'
                    previousBuild   = 'build-old'
                    backupRoot      = $backupRoot
                    createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    files           = @(
                        [PSCustomObject]@{
                            relativePath   = 'lib\existing.ps1'
                            existedBefore  = $true
                            previousSha256 = ('e' * 64)
                            sha256         = $targetHash
                        }
                    )
                }
                $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
                New-Item -ItemType Directory -Path (Split-Path $journalPath -Parent) -Force | Out-Null
                $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

                return [PSCustomObject]@{
                    Root        = $root
                    Destination = $destination
                    Journal     = $journal
                    JournalPath = $journalPath
                    TargetHash  = $targetHash
                }
            }
        }

        It "Installs a different published build when a stuck finalization fails for a non-hash reason" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('published-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'published-target' -Encoding ASCII
            $publishedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $publishedHash })
            }

            InModuleScope Common -Parameters @{
                Root = $fixture.Root
                Manifest = $manifest
                StagedSource = $stagedSource
            } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                $script:Captured = @{ Config = $null; Integrity = 0; Baseline = 0; Tasks = 0; Reports = @(); GateCalls = 0; ManifestRequests = 0; WebRequests = 0 }
                $script:ConfigWrites = 0
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod {
                    $script:Captured.ManifestRequests++
                    $script:TestManifest
                }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    $script:Captured.WebRequests++
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig {
                    $script:ConfigWrites++
                    if ($script:ConfigWrites -eq 1) {
                        throw 'simulated config failure'
                    }
                    $script:Captured.Config = $Config
                }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { $script:Captured.Tasks++ }
                Mock Enable-OpenPathTask { $script:Captured.Tasks++ }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeTrue
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'published-target'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
                $script:Captured.ManifestRequests | Should -Be 1
                $script:Captured.WebRequests | Should -Be 1
                $script:Captured.Config.version | Should -Be '9.9.9'
                $script:Captured.Config.agentBuild | Should -Be 'build-published'
            }
        }

        It "Keeps the committed journal and returns the finalization error when the server still publishes the stuck target" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-stuck'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $fixture.TargetHash })
            }

            InModuleScope Common -Parameters @{ Root = $fixture.Root; Manifest = $manifest } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:Captured = @{ ManifestRequests = 0; WebRequests = 0 }
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod {
                    $script:Captured.ManifestRequests++
                    $script:TestManifest
                }
                Mock Invoke-WebRequest { $script:Captured.WebRequests++ }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { throw 'simulated config failure' }
                Mock Send-OpenPathHealthReport { }
                Mock Restore-OpenPathProtectedMode { }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                $result.Message | Should -Match 'finalization failed'
                $script:Captured.ManifestRequests | Should -Be 1
                $script:Captured.WebRequests | Should -Be 0
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeTrue
                $journalOnDisk = Get-Content -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) -Raw | ConvertFrom-Json
                $journalOnDisk.phase | Should -Be 'committed'
            }
        }

        It "Reinstalls the same published build when the stuck finalization failed at the target hash check" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'wrong-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('reinstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'stuck-target' -Encoding ASCII
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-stuck'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $fixture.TargetHash })
            }

            InModuleScope Common -Parameters @{
                Root = $fixture.Root
                Manifest = $manifest
                StagedSource = $stagedSource
            } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                $script:Captured = @{ Config = $null; Integrity = 0; Baseline = 0; Tasks = 0; WebRequests = 0; ManifestRequests = 0 }
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.9'
                        agentBuild   = 'build-stuck'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod {
                    $script:Captured.ManifestRequests++
                    $script:TestManifest
                }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    $script:Captured.WebRequests++
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { $script:Captured.Config = $Config }
                Mock Save-OpenPathIntegrityBackup { $script:Captured.Integrity++ }
                Mock New-OpenPathIntegrityBaseline { $script:Captured.Baseline++ }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { $script:Captured.Tasks++ }
                Mock Enable-OpenPathTask { $script:Captured.Tasks++ }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeTrue
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'stuck-target'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
                $script:Captured.ManifestRequests | Should -Be 1
                $script:Captured.WebRequests | Should -Be 1
                $script:Captured.Config.version | Should -Be '9.9.9'
                $script:Captured.Config.agentBuild | Should -Be 'build-stuck'
            }
        }

        It "Returns the finalization error and keeps the journal when the manifest request fails" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'

            InModuleScope Common -Parameters @{ Root = $fixture.Root } {
                $script:OpenPathRoot = $Root
                $script:ManifestRequests = 0
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod {
                    $script:ManifestRequests++
                    throw 'manifest unavailable'
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { throw 'simulated config failure' }
                Mock Send-OpenPathHealthReport { }
                Mock Restore-OpenPathProtectedMode { }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                $result.Message | Should -Match 'finalization failed'
                $result.Message | Should -Not -Match 'Manifest download failed'
                $script:ManifestRequests | Should -Be 1
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeTrue
            }
        }

        It "Does not install a build under failed-build backoff after a hash mismatch" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'wrong-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-stuck'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $fixture.TargetHash })
            }

            InModuleScope Common -Parameters @{ Root = $fixture.Root; Manifest = $manifest } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:ManifestRequests = 0
                $script:WebRequests = 0
                Save-OpenPathAgentUpdateFailureRecord -OpenPathRoot $Root -Version '9.9.9' -Build 'build-stuck' -Stage 'gate' -Message 'previous failure'
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.9'
                        agentBuild   = 'build-stuck'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod {
                    $script:ManifestRequests++
                    $script:TestManifest
                }
                Mock Invoke-WebRequest { $script:WebRequests++ }
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport { }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeFalse
                $script:ManifestRequests | Should -Be 1
                $script:WebRequests | Should -Be 0
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeTrue
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeTrue
            }
        }

        It "Does not install a different published build under failed-build backoff" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $fixture.TargetHash })
            }

            InModuleScope Common -Parameters @{ Root = $fixture.Root; Manifest = $manifest } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:ManifestRequests = 0
                $script:WebRequests = 0
                Save-OpenPathAgentUpdateFailureRecord -OpenPathRoot $Root -Version '9.9.9' -Build 'build-published' -Stage 'gate' -Message 'previous failure'
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod {
                    $script:ManifestRequests++
                    $script:TestManifest
                }
                Mock Invoke-WebRequest { $script:WebRequests++ }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { throw 'simulated config failure' }
                Mock Send-OpenPathHealthReport { }
                Mock Restore-OpenPathProtectedMode { }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeFalse
                $script:ManifestRequests | Should -Be 1
                $script:WebRequests | Should -Be 0
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeTrue
            }
        }
    }

    Context "Self-update failed-run backup cleanup" {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Common.psm1") -Force -Global
        }

        It "Removes the run backup directory when a download fails before the journal is written" {
            $root = Join-Path $TestDrive ('update-download-fail-' + [guid]::NewGuid().ToString('N'))
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = ('c' * 64) })
            }

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest { throw 'download failed' }
                Mock Write-OpenPathLog { }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
                $backupsRoot = Join-Path $Root 'data/agent-update/backups'
                @(Get-ChildItem -LiteralPath $backupsRoot -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
            }
        }

        It "Removes the journal and the run backup directory after a complete rollback" {
            $root = Join-Path $TestDrive ('update-rollback-clean-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII
            $stagedSource = Join-Path $TestDrive ('rollback-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'Write-Output "new"' -Encoding ASCII
            $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
            }

            InModuleScope Common -Parameters @{
                Root = $root
                Manifest = $manifest
                StagedSource = $stagedSource
            } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    [PSCustomObject]@{ Healthy = $false; Message = 'gate failed'; TimedOut = $false }
                }
                Mock Send-OpenPathHealthReport { }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "old"'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
                $backupsRoot = Join-Path $Root 'data/agent-update/backups'
                @(Get-ChildItem -LiteralPath $backupsRoot -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
            }
        }

        It "Keeps the journal and the run backup directory when rollback is incomplete" {
            $root = Join-Path $TestDrive ('update-rollback-incomplete-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII
            $stagedSource = Join-Path $TestDrive ('incomplete-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'Write-Output "new"' -Encoding ASCII
            $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
            }

            InModuleScope Common -Parameters @{
                Root = $root
                Manifest = $manifest
                StagedSource = $stagedSource
            } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.8'
                        agentBuild   = 'build-old'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    [PSCustomObject]@{ Healthy = $false; Message = 'gate failed'; TimedOut = $false }
                }
                Mock Restore-OpenPathAgentUpdateJournalBackups {
                    [PSCustomObject]@{ Complete = $false; Errors = @('simulated incomplete rollback') }
                }
                Mock Send-OpenPathHealthReport { }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeTrue
                $journalOnDisk = Get-Content -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) -Raw | ConvertFrom-Json
                Test-Path -LiteralPath ([string]$journalOnDisk.backupRoot) | Should -BeTrue
                $backupsRoot = Join-Path $Root 'data/agent-update/backups'
                @(Get-ChildItem -LiteralPath $backupsRoot -Directory -ErrorAction SilentlyContinue).Count | Should -Be 1
            }
        }
    }
}
