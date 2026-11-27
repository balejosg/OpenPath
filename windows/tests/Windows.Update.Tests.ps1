Describe "Update Script" {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    }

    Context "Concurrency guard" {
        It "Update runtime uses a global mutex lock" {
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            $scriptPath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "scripts") "Update-OpenPath.ps1"
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
                # Without a timeout, PowerShell 5.1 waits forever on a stalled connection and the
                # hung cycle keeps the update lock, so the PC ignores classroom changes.
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                    $TimeoutSec -gt 0 -and $TimeoutSec -le 30
                }
                $global:OpenPathTestPersistedDomains | Should -Be @('nce.wedu.comunidad.madrid')
                $updated.captivePortalDomains | Should -Be @('nce.wedu.comunidad.madrid')
            }
        }

        It "Runs local protected-mode or portal reconciliation before remote whitelist download" {
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $configHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Config.ps1"
            $whitelistHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Whitelist.ps1"
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
            $runtimeModulePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $runtimePath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Rollback.ps1"
            $content = Get-Content $runtimeModulePath -Raw
            $runtimeContent = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Invoke-OpenPathUpdateRollback',
                'Write-UpdateCatchLog "Update failed: $_" -Level ERROR'
            )

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'Attempting checkpoint rollback',
                'Falling back to backup whitelist rollback',
                'Write-OpenPathAtomicTextFile -Path $WhitelistPath -Content $backupContent',
                'Restore-OpenPathCheckpoint'
            )
        }

        It "Clears the cached whitelist ETag when an update cycle fails" {
            $runtimeModulePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $content = Get-Content $runtimeModulePath -Raw
            $catchStart = $content.IndexOf('Write-UpdateCatchLog "Update failed: $_" -Level ERROR')
            $etagClear = $content.IndexOf("Remove-Item -LiteralPath `$cachedEtagPath -Force", $catchStart)
            $rollback = $content.IndexOf('$rollbackResult = Invoke-OpenPathUpdateRollback', $catchStart)

            $catchStart | Should -BeGreaterThan 0
            $content | Should -Match "\`$cachedEtagPath = Join-Path \`$OpenPathRoot 'data\\whitelist\.etag'"
            $etagClear | Should -BeGreaterThan $catchStart
            $etagClear | Should -BeLessThan $rollback
        }

        It "Allows backup rollback when config was never loaded" {
            $runtimePath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Rollback.ps1"
            $runtimeContent = Get-Content $runtimePath -Raw

            $runtimeContent | Should -Match '\[AllowNull\(\)\]\s+\[PSCustomObject\]\$Config'
            $runtimeContent | Should -Match "(?s)if \(\`$Config\) \{\s+Invoke-OpenPathUpdateWritersLockScope -Stage 'checkpoint-rollback-mirror' -Action \{\s+Sync-FirefoxNativeHostMirror -Config \`$Config -WhitelistPath \`$WhitelistPath"
            $runtimeContent | Should -Match '(?s)if \(\$Config -and -not \$backupDisabled\) \{\s+Restore-OpenPathProtectedMode -Config \$Config -ErrorAction SilentlyContinue \| Out-Null\s+\}'
        }

        It "Keeps fail-open state when a backup rollback restores a disabled marker" {
            . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Config.ps1")
            . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Rollback.ps1")

            $dir = Join-Path $TestDrive ("rollback-disabled-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $backupPath = Join-Path $dir 'whitelist.backup.txt'
            $whitelistPath = Join-Path $dir 'whitelist.txt'
            Set-Content -LiteralPath $backupPath -Value '# DESACTIVADO' -Encoding UTF8

            $script:acrylicUpdates = 0
            $script:protectedModeRestores = 0
            function Invoke-OpenPathUpdateWritersLockScope { param([string]$Stage, [scriptblock]$Action) return (& $Action) }
            function Get-OpenPathWhitelistSectionsFromFile {
                param([string]$Path)
                [pscustomobject]@{ IsDisabled = $true; ReadSucceeded = $true; Whitelist = @(); BlockedSubdomains = @() }
            }
            function Sync-FirefoxNativeHostMirror { param($Config, $WhitelistPath) }
            function Update-AcrylicHost { param($WhitelistedDomains, $BlockedSubdomains, $ErrorAction) $script:acrylicUpdates++ }
            function Restore-OpenPathProtectedMode { param($Config, $ErrorAction) $script:protectedModeRestores++ }
            function Write-UpdateCatchLog { param([string]$Message, [string]$Level) }
            function Write-OpenPathLog { param([string]$Message, [string]$Level) }

            try {
                $result = Invoke-OpenPathUpdateRollback `
                    -Config ([pscustomobject]@{ enableCheckpointRollback = $false }) `
                    -WhitelistPath $whitelistPath `
                    -BackupPath $backupPath `
                    -StaleFailsafeStatePath (Join-Path $dir 'stale-failsafe-state.json')

                $result.RollbackSucceeded | Should -BeTrue
                $result.RollbackMethod | Should -Be 'backup'
                (Get-Content -LiteralPath $whitelistPath -Raw) | Should -Match '# DESACTIVADO'
                $script:acrylicUpdates | Should -Be 0
                $script:protectedModeRestores | Should -Be 0
            }
            finally {
                Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Resolves the Windows root from helper while preserving C:\OpenPath as the default" {
            $rootHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "WindowsRoot.ps1"
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $updateScriptPath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "scripts") "Update-OpenPath.ps1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $commonPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Http.Health.ps1"
            $updateContent = Get-Content $runtimePath -Raw
            $commonContent = Get-Content $commonPath -Raw

            $updateContent.Contains('Send-OpenPathHealthReport') | Should -BeTrue
            $commonContent.Contains('/trpc/healthReports.submit') | Should -BeTrue
            $commonContent.Contains('dnsmasqRunning') | Should -BeTrue
        }

        It "Persists update portal-active state and annotates health actions" {
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $applyHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1"
            $sseScriptPath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "scripts") "Start-SSEListener.ps1"
            $runtimeContent = Get-Content $runtimePath -Raw
            $applyContent = Get-Content $applyHelperPath -Raw
            $sseContent = Get-Content $sseScriptPath -Raw

            Assert-ContentContainsAll -Content $runtimeContent -Needles @(
                'function Write-OpenPathUpdatePortalActiveState',
                'Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore',
                'Get-OpenPathCaptivePortalMarker',
                'data\update-portal-active-state.json',
                'triggerSource = $TriggerSource',
                'healthAction = $healthAction',
                'classroom_state_unknown',
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
                'Join-OpenPathUpdateHealthActions -Action $healthAction -Suffix $HealthActionSuffix',
                'download_failed_cached_whitelist'
            )

            Assert-ContentContainsAll -Content $sseContent -Needles @(
                'Invoke-OpenPathUpdateCycle -OpenPathRoot $OpenPathRoot -TriggerSource SSE'
            )
        }
    }

    Context "Whitelist download retry" {
        BeforeEach {
            . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1")
            function Write-OpenPathLog { param([string]$Message, [string]$Level) }

            $script:downloadErrors = [System.Collections.Generic.Queue[string]]::new()
            $script:downloadCalls = 0
            $script:sleeps = [System.Collections.Generic.List[int]]::new()
            function Get-OpenPathFromUrl {
                param([string]$Url)
                $script:downloadCalls++
                if ($script:downloadErrors.Count -gt 0) {
                    throw $script:downloadErrors.Dequeue()
                }
                return [pscustomobject]@{ Whitelist = @('example.org'); NotModified = $false }
            }
            $script:sleepAction = { param([int]$Seconds) $script:sleeps.Add($Seconds) }
            $script:config = [pscustomobject]@{ whitelistUrl = 'https://example.invalid/w/token/whitelist.txt' }
        }

        It "Does not wait when the first download succeeds" {
            $result = Get-OpenPathWhitelistDownloadResult -Config $script:config -SleepAction $script:sleepAction

            $result.DownloadFailed | Should -BeFalse
            $result.Whitelist.Whitelist | Should -Be @('example.org')
            $script:downloadCalls | Should -Be 1
            $script:sleeps.Count | Should -Be 0
        }

        It "Retries a transport failure (network not up after resume) and returns the fresh whitelist" {
            $script:downloadErrors.Enqueue('Error al enviar la solicitud.')
            $script:downloadErrors.Enqueue('No such host is known.')

            $result = Get-OpenPathWhitelistDownloadResult -Config $script:config -SleepAction $script:sleepAction

            $result.DownloadFailed | Should -BeFalse
            $result.ErrorText | Should -Be ''
            $result.Whitelist.Whitelist | Should -Be @('example.org')
            $script:downloadCalls | Should -Be 3
            @($script:sleeps) | Should -Be @(5, 10)
        }

        It "Retries a server error" {
            $script:downloadErrors.Enqueue('HTTP 502')

            $result = Get-OpenPathWhitelistDownloadResult -Config $script:config -SleepAction $script:sleepAction

            $result.DownloadFailed | Should -BeFalse
            $script:downloadCalls | Should -Be 2
        }

        It "Does not retry a 4xx answer from the server" {
            $script:downloadErrors.Enqueue('HTTP 404')

            $result = Get-OpenPathWhitelistDownloadResult -Config $script:config -SleepAction $script:sleepAction

            $result.DownloadFailed | Should -BeTrue
            $result.ErrorText | Should -Be 'HTTP 404'
            $script:downloadCalls | Should -Be 1
            $script:sleeps.Count | Should -Be 0
        }

        It "Gives up after the configured delays and reports the last error" {
            foreach ($i in 1..5) { $script:downloadErrors.Enqueue("transport error $i") }

            $result = Get-OpenPathWhitelistDownloadResult -Config $script:config -SleepAction $script:sleepAction

            $result.DownloadFailed | Should -BeTrue
            $result.ErrorText | Should -Be 'transport error 5'
            $script:downloadCalls | Should -Be 5
            @($script:sleeps) | Should -Be @(5, 10, 20, 40)
        }

        It "Can disable retries with an empty delay list" {
            $script:downloadErrors.Enqueue('transport error')

            $result = Get-OpenPathWhitelistDownloadResult -Config $script:config -RetryDelaySeconds @() -SleepAction $script:sleepAction

            $result.DownloadFailed | Should -BeTrue
            $script:downloadCalls | Should -Be 1
        }

        It "Keeps the update cycle on the default retry schedule" {
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            (Get-Content $runtimePath -Raw) | Should -Match '\$downloadResult = Get-OpenPathWhitelistDownloadResult -Config \$config\r?\n'
        }
    }

    Context "Stale whitelist fail-safe" {
        It "Includes stale threshold logic and restores protected mode via shared helper" {
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $helperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $applyHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1"
            $stateHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "EndpointPolicyState.ps1"
            $reconcilerPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "EndpointStateReconciler.ps1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $applyHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1"
            $rollbackHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Rollback.ps1"
            $content = Get-Content $runtimePath -Raw
            $applyContent = Get-Content $applyHelperPath -Raw
            $rollbackContent = Get-Content $rollbackHelperPath -Raw

            $content | Should -Match '(?s)elseif \(\$downloadResult\.Whitelist\.IsDisabled\).*?Handle-OpenPathDisabledWhitelist'
            $applyContent | Should -Match '(?s)Handle-OpenPathDisabledWhitelist.*?Invoke-OpenPathEndpointStateRepairPlan'
            $applyContent | Should -Match '(?s)Handle-OpenPathDisabledWhitelist.*?# DESACTIVADO.*?Write-OpenPathAtomicTextFile -Path \$WhitelistPath'
            $applyContent | Should -Match '(?s)Handle-OpenPathWhitelistApply.*?Write-OpenPathAtomicTextFile -Path \$WhitelistPath'
            $applyContent | Should -Match '(?s)Handle-OpenPathNotModified.*?IsDisabled.*?FAIL_OPEN.*?remote_disable_marker_not_modified'
            $applyContent | Should -Match '(?s)Handle-OpenPathWhitelistApply.*?Invoke-OpenPathRuntimeDependencyQueueApply.*?Invoke-OpenPathEndpointStateRepairPlan'
            $rollbackContent | Should -Match '(?s)Falling back to backup whitelist rollback.*?Restore-OpenPathProtectedMode -Config \$Config -ErrorAction SilentlyContinue'
        }

        Context "Stale whitelist fail-safe and server confirmation" {
            BeforeEach {
                . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.System.ps1")
                . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Config.ps1")
                . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Redaction.ps1")
                . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Config.ps1")
                . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1")
                # The runtime imports the adapter DNS probe from this leaf; Apply no longer defines it.
                . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "EndpointPosture.ps1")

                $script:dataDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $script:dataDir | Out-Null
                $script:whitelistPath = Join-Path $script:dataDir 'whitelist.txt'
                $script:stalePath = Join-Path $script:dataDir 'stale-failsafe-state.json'
                $script:failureStatePath = Join-Path $script:dataDir 'whitelist-download-failures.json'
                Set-Content -Path $script:whitelistPath -Value "## WHITELIST`nexample.org"
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                $script:mirrorFingerprint = (Get-Item $script:whitelistPath).LastWriteTimeUtc
                $script:failsafeEntries = 0
                $script:healthStatuses = @()
                $script:healthActions = @()
                $script:protectedModeRestores = 0

                function Write-OpenPathLog { param([string]$Message, [string]$Level) }
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $false } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $false; ProtectedModeEligible = $true } }
                function Invoke-OpenPathUpdateWritersLockScope { param([string]$Stage, [scriptblock]$Action) return $false }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) [pscustomobject]@{ Actions = @() } }
                function Invoke-OpenPathEndpointStateRepairPlan { param($Plan, $Config) }
                function Get-OpenPathRuntimeHealth { [pscustomobject]@{ DnsServiceRunning = $true; DnsResolving = $true } }
                function Send-OpenPathHealthReport { param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions) $script:healthStatuses += $Status; $script:healthActions += $Actions }
                function Clear-StaleFailsafeState { param([string]$StaleFailsafeStatePath) if (Test-Path $StaleFailsafeStatePath) { Remove-Item $StaleFailsafeStatePath -Force } }
                function Enter-StaleWhitelistFailsafe { param($Config, $WhitelistAgeHours, $StaleFailsafeStatePath) $script:failsafeEntries++; Set-Content $StaleFailsafeStatePath '{}' }
                function Restore-OpenPathProtectedMode { param($Config) $script:protectedModeRestores++ }
                function Sync-FirefoxNativeHostMirror { param($Config, $WhitelistPath, [switch]$ClearWhitelist) }
                function ConvertTo-OpenPathWhitelistFileContent { param($Whitelist, $BlockedSubdomains, $BlockedPaths) return "## WHITELIST`nexample.org" }
                function Invoke-OpenPathRuntimeDependencyQueueApply { param($WhitelistPath, [switch]$PassThru) if ($PassThru) { return [pscustomobject]@{ Changed = $false; Processed = 0; Rejected = 0 } } return $false }
                function Get-OpenPathRuntimeDependencyOverlayState { return $null }

                function Set-OpenPathTestFailureState {
                    param([string]$StatePath, [int]$Count, [datetime]$LastFailureUtc)

                    [ordered]@{
                        schemaVersion       = 1
                        consecutiveFailures = $Count
                        lastFailureUtc      = $LastFailureUtc.ToUniversalTime().ToString('o')
                        lastError           = 'seeded'
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path $StatePath -Encoding UTF8
                }
            }

            It "Leaves the fail-safe when the server confirms the cached whitelist, without touching the whitelist file" {
                Set-Content -Path $script:stalePath -Value '{}'

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                Test-Path $script:stalePath | Should -BeFalse
                Test-Path (Join-Path $script:dataDir 'whitelist.verified') | Should -BeTrue
                (Get-Item $script:whitelistPath).LastWriteTimeUtc | Should -Be $script:mirrorFingerprint
                Get-OpenPathCachedWhitelistAgeHours -WhitelistPath $script:whitelistPath | Should -BeLessThan 1
                $script:protectedModeRestores | Should -Be 1
            }

            It "Reopens a disabled classroom on a 304 cycle when protection was re-armed" {
                $script:repairModes = @()
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) $script:repairModes += $Mode; [pscustomobject]@{ Actions = @() } }
                function Test-FirewallActive { $true }

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                $script:repairModes | Should -Be @('FailOpen')
            }

            It "Reopens a disabled classroom on a 304 cycle when only the adapter DNS is still pinned locally" {
                $script:repairModes = @()
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) $script:repairModes += $Mode; [pscustomobject]@{ Actions = @() } }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('127.0.0.1') } }

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                $script:repairModes | Should -Be @('FailOpen')
            }

            It "Keeps a disabled classroom untouched on a 304 cycle when protection is already off" {
                $script:repairModes = @()
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) $script:repairModes += $Mode; [pscustomobject]@{ Actions = @() } }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('172.23.140.92') } }

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                $script:repairModes | Should -Be @('FailOpenMarkerOnly')
            }

            It "Clears a stale captive portal marker when the classroom is disabled" {
                $script:markerClears = 0
                function Clear-OpenPathCaptivePortalMarker { $script:markerClears++; $true }
                function Invoke-OpenPathUpdateWritersLockScope { param([string]$Stage, [scriptblock]$Action) return (& $Action) }
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true; ReadSucceeded = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) [pscustomobject]@{ Actions = @() } }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('192.0.2.53') } }

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath
                $script:markerClears | Should -Be 1

                Handle-OpenPathDisabledWhitelist -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath
                $script:markerClears | Should -Be 2
                (Get-Content -LiteralPath $script:whitelistPath -Raw) | Should -Match '# DESACTIVADO'
            }

            It "Records the server confirmation and clears the stale fail-safe when the classroom is disabled" {
                Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                Set-Content -Path $script:stalePath -Value '{}'
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('192.0.2.53') } }

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                Test-Path (Join-Path $script:dataDir 'whitelist.verified') | Should -BeTrue
                Get-OpenPathCachedWhitelistAgeHours -WhitelistPath $script:whitelistPath | Should -BeLessThan 1
                Test-Path $script:stalePath | Should -BeFalse
                $script:protectedModeRestores | Should -Be 0
            }

            It "Does not re-enter the stale fail-safe after one failed download following a disabled-classroom 304" {
                Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                Set-Content -Path $script:stalePath -Value '{}'
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('192.0.2.53') } }

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath
                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath

                $script:failsafeEntries | Should -Be 0
                Test-Path $script:stalePath | Should -BeFalse
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
            }

            It "Clears the stale fail-safe when the server answers the remote disable with a 200" {
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                Set-Content -Path $script:stalePath -Value '{}'
                function Invoke-OpenPathUpdateWritersLockScope { param([string]$Stage, [scriptblock]$Action) return (& $Action) }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('192.0.2.53') } }

                Handle-OpenPathDisabledWhitelist -Config ([pscustomobject]@{ enableFirewall = $false }) `
                    -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath `
                    -DownloadFailureStatePath $script:failureStatePath

                (Get-Content -LiteralPath $script:whitelistPath -Raw) | Should -Match '# DESACTIVADO'
                Get-OpenPathCachedWhitelistAgeHours -WhitelistPath $script:whitelistPath | Should -BeLessThan 1
                Test-Path $script:stalePath | Should -BeFalse
            }

            It "Does not enter the stale fail-safe on a failed download while the classroom is disabled" {
                Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                Set-Content -Path $script:stalePath -Value '{}'
                $script:repairModes = @()
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) $script:repairModes += $Mode; [pscustomobject]@{ Actions = @() } }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('192.0.2.53') } }

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath

                $script:failsafeEntries | Should -Be 0
                Test-Path $script:stalePath | Should -BeFalse
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
                $script:healthActions[-1] | Should -Match 'stale_failsafe_skipped_classroom_disabled'
                $script:healthActions[-1] | Should -Match 'stale_failsafe_progress=1/6'
                $script:repairModes | Should -Contain 'FailOpenMarkerOnly'
                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 1
            }

            It "Restores fail-open on a failed download while the classroom is disabled and protection is still active" {
                Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                Set-Content -Path $script:stalePath -Value '{}'
                $script:repairModes = @()
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) $script:repairModes += $Mode; [pscustomobject]@{ Actions = @() } }
                function Test-FirewallActive { $true }

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath

                $script:repairModes | Should -Be @('FailOpen')
                $script:failsafeEntries | Should -Be 0
                Test-Path $script:stalePath | Should -BeFalse
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
            }

            It "Does not enter the stale fail-safe after six failures while the classroom is disabled" {
                Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-93)
                $script:repairModes = @()
                function Get-OpenPathWhitelistSectionsFromFile { param([string]$Path) [pscustomobject]@{ IsDisabled = $true } }
                function Get-OpenPathEndpointPolicyState { param($WhitelistSections) [pscustomobject]@{ IsDisabled = $true; ProtectedModeEligible = $false } }
                function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, $QueueChanged) $script:repairModes += $Mode; [pscustomobject]@{ Actions = @() } }
                function Test-FirewallActive { $false }
                function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ Status = 'Up'; ifIndex = 7 } }
                function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ ServerAddresses = @('192.0.2.53') } }
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-23T08:00:00', [System.DateTimeKind]::Utc)

                for ($i = 0; $i -lt 6; $i++) {
                    Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                        -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                        -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0.AddMinutes(5 * $i)
                }

                $script:failsafeEntries | Should -Be 0
                Test-Path $script:stalePath | Should -BeFalse
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
                $script:healthActions[-1] | Should -Match 'stale_failsafe_progress=6/6'
                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 6
            }

            It "Does not restore protected mode on an ordinary 304 cycle" {
                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                $script:protectedModeRestores | Should -Be 0
            }

            It "Keeps using a recently confirmed whitelist when a later download fails" {
                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath -StaleFailsafeStatePath $script:stalePath

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -DownloadFailureStatePath $script:failureStatePath

                $script:failsafeEntries | Should -Be 0
                Test-Path $script:stalePath | Should -BeFalse
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
            }

            It "Degrades and counts the first failed download with an old cached whitelist" {
                Set-Content -Path (Join-Path $script:dataDir 'whitelist.verified') -Value 'old'
                (Get-Item (Join-Path $script:dataDir 'whitelist.verified')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-30)

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath

                $script:failsafeEntries | Should -Be 0
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
                $script:healthActions[-1] | Should -Match 'download_failed_cached_whitelist'
                $script:healthActions[-1] | Should -Match 'stale_failsafe_progress=1/6'
                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 1
            }

            It "Does not count a failure that arrives less than four minutes after the last counted failure" {
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0
                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0.AddMinutes(3)

                $state = Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath
                $state.ConsecutiveFailures | Should -Be 1
                $state.LastFailureUtc | Should -Be $t0
            }

            It "Enters the fail-safe on the sixth counted failure" {
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)

                for ($i = 0; $i -lt 5; $i++) {
                    Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                        -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                        -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0.AddMinutes(5 * $i)
                }
                $script:failsafeEntries | Should -Be 0

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0.AddMinutes(25)

                $script:failsafeEntries | Should -Be 1
                $script:healthStatuses[-1] | Should -Be 'STALE_FAILSAFE'
                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 6
            }

            It "Keeps a recent cached whitelist out of the fail-safe even after many counted failures" {
                (Get-Item $script:whitelistPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)

                for ($i = 0; $i -lt 10; $i++) {
                    Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                        -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                        -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0.AddMinutes(5 * $i)
                }

                $script:failsafeEntries | Should -Be 0
                $script:healthStatuses[-1] | Should -Be 'DEGRADED'
                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 10
            }

            It "Resets the failure run when a 304 confirms the cached whitelist" {
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)
                Set-OpenPathTestFailureState -StatePath $script:failureStatePath -Count 3 -LastFailureUtc $t0

                Handle-OpenPathNotModified -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -DownloadFailureStatePath $script:failureStatePath

                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 0
            }

            It "Resets the failure run when a 200 applies a new whitelist" {
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)
                Set-OpenPathTestFailureState -StatePath $script:failureStatePath -Count 3 -LastFailureUtc $t0

                Handle-OpenPathWhitelistApply `
                    -Config ([pscustomobject]@{ enableBrowserPolicies = $false }) `
                    -Whitelist ([pscustomobject]@{ Whitelist = @('example.org'); BlockedSubdomains = @(); BlockedPaths = @() }) `
                    -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath `
                    -DownloadFailureStatePath $script:failureStatePath

                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 0
            }

            It "Resets the failure run when the server returns the remote-disable answer" {
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)
                Set-OpenPathTestFailureState -StatePath $script:failureStatePath -Count 3 -LastFailureUtc $t0

                Handle-OpenPathDisabledWhitelist `
                    -Config ([pscustomobject]@{ enableFirewall = $false }) `
                    -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath `
                    -DownloadFailureStatePath $script:failureStatePath

                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 0
            }

            It "Reads the persisted count after a simulated restart" {
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)
                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0

                . (Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1")

                Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath | Should -Not -BeNullOrEmpty
                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 1
            }

            It "Treats a corrupt failure state file as zero and rewrites it" {
                Set-Content -Path $script:failureStatePath -Value 'not-json' -Encoding UTF8

                { Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                        -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                        -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath } | Should -Not -Throw

                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 1
            }

            It "Treats an unknown failure state schema as zero" {
                [ordered]@{
                    schemaVersion       = 99
                    consecutiveFailures = 9
                    lastFailureUtc      = (Get-Date).ToUniversalTime().ToString('o')
                    lastError           = 'future schema'
                } | ConvertTo-Json -Depth 4 | Set-Content -Path $script:failureStatePath -Encoding UTF8

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath

                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 1
            }

            It "Counts a new failure when the last counted failure is in the future" {
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-17T10:00:00', [System.DateTimeKind]::Utc)
                Set-OpenPathTestFailureState -StatePath $script:failureStatePath -Count 3 -LastFailureUtc $t0.AddMinutes(10)

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath -Now $t0

                (Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath).ConsecutiveFailures | Should -Be 4
            }

            It "Reads the consecutive-failure threshold with a default of 6 and a minimum of 1" {
                (Get-OpenPathUpdatePolicySettings -Config ([pscustomobject]@{})).StaleFailsafeMinConsecutiveFailures | Should -Be 6
                (Get-OpenPathUpdatePolicySettings -Config ([pscustomobject]@{ staleFailsafeMinConsecutiveFailures = 1 })).StaleFailsafeMinConsecutiveFailures | Should -Be 1

                foreach ($invalid in @(0, -1, 'not-a-number')) {
                    (Get-OpenPathUpdatePolicySettings -Config ([pscustomobject]@{ staleFailsafeMinConsecutiveFailures = $invalid })).StaleFailsafeMinConsecutiveFailures | Should -Be 6
                }
            }

            It "Enters the fail-safe on the first failure when the configured threshold is 1" {
                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 1 -DownloadFailureStatePath $script:failureStatePath

                $script:failsafeEntries | Should -Be 1
                $script:healthStatuses[-1] | Should -Be 'STALE_FAILSAFE'
            }

            It "Stays in the fail-safe when the marker already exists, regardless of the threshold" {
                Set-Content -Path $script:stalePath -Value '{}'

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath

                $script:failsafeEntries | Should -Be 1
                $script:healthStatuses[-1] | Should -Be 'STALE_FAILSAFE'
            }

            It "Stores a redacted and bounded download error without the machine token" {
                $token = 'machine-token-abc123'
                $errorText = "GET https://api.example/api/machines/w/$token/whitelist.txt?token=$token failed with 500 " + ('x' * 400)

                Handle-OpenPathDownloadFailure -Config ([pscustomobject]@{}) -WhitelistPath $script:whitelistPath `
                    -StaleFailsafeStatePath $script:stalePath -StaleWhitelistMaxAgeHours 24 -EnableStaleFailsafe $true `
                    -StaleFailsafeMinConsecutiveFailures 6 -DownloadFailureStatePath $script:failureStatePath `
                    -DownloadErrorText $errorText

                $raw = Get-Content $script:failureStatePath -Raw
                $raw | Should -Not -Match [regex]::Escape($token)
                $state = Get-OpenPathWhitelistDownloadFailureState -StatePath $script:failureStatePath
                $state.LastError | Should -Match '\[redacted\]'
                $state.LastError.Length | Should -BeLessOrEqual 200
            }
        }

        It "Restarts protected DNS when runtime dependency queue changes without a new whitelist" {
            $applyHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1"
            $applyContent = Get-Content $applyHelperPath -Raw

            $applyContent | Should -Match "(?s)Handle-OpenPathNotModified.*?\`$runtimeDependencyQueueChanged = \[bool\]\(Invoke-OpenPathUpdateWritersLockScope -Stage 'not-modified-queue-apply'.*?-QueueChanged \`$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan"
            $applyContent | Should -Match "(?s)Handle-OpenPathDownloadFailure.*?\`$runtimeDependencyQueueChanged = \[bool\]\(Invoke-OpenPathUpdateWritersLockScope -Stage 'download-failure-queue-apply'.*?-QueueChanged \`$runtimeDependencyQueueChanged.*?Invoke-OpenPathEndpointStateRepairPlan"
        }

        It "Logs the Acrylic host update and restart sub-step breakdown (Phase 8g G3)" {
            $configPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "DNS.Acrylic.Config.ps1"
            $servicePath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "DNS.Acrylic.Service.ps1"
            $restartPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "DNS.Acrylic.Restart.ps1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $runtimeContent = Get-Content $runtimePath -Raw

            $runtimeContent | Should -Match '(?s)function Invoke-OpenPathRuntimeDependencyQueueApply.*?\$acrylicHostWritten = \[bool\]\(Update-AcrylicHost.*?return \[bool\]\$runtimeDependencyQueueResult\.Changed'
            # The update runtime session does not autoload PowerShell modules, so
            # the apply path must not rely on cmdlets like Get-FileHash.
            $runtimeContent | Should -Not -Match 'Get-FileHash'
        }

        It "Provides a queue-only runtime dependency fast apply without remote download" {
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
            $scriptPath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "scripts") "Apply-RuntimeDependencyQueue.ps1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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

    Context "Durable update primitives" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
        }

        It "Writes a JSON record durably over a <State> destination" -ForEach @(
            @{ State = 'new' }
            @{ State = 'existing' }
        ) {
            $root = Join-Path $TestDrive ('durable-json-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $path = Join-Path $root 'update-journal.json'
            if ($State -eq 'existing') {
                Set-Content -LiteralPath $path -Value '{"phase":"old"}' -Encoding UTF8
            }

            InModuleScope Common -Parameters @{ Path = $path } {
                Write-OpenPathAgentUpdateJsonFile -Path $Path -Object ([PSCustomObject]@{ schemaVersion = 2; phase = 'replacing' })
            }

            (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).phase | Should -Be 'replacing'
            @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '\.tmp$|\.bak$' }).Count | Should -Be 0
        }

        It "Leaves the previous destination and no temp file when the atomic write cannot finish" {
            $root = Join-Path $TestDrive ('durable-json-fail-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $destinationDirectory = Join-Path $root 'destination.json'
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null

            InModuleScope Common -Parameters @{ Path = $destinationDirectory } {
                { Write-OpenPathAgentUpdateJsonFile -Path $Path -Object ([PSCustomObject]@{ phase = 'new' }) } |
                    Should -Throw
            }

            Test-Path -LiteralPath $destinationDirectory -PathType Container | Should -BeTrue
            @(Get-ChildItem -LiteralPath $root -File).Count | Should -Be 0
        }

        It "Durable copy returns the SHA-256 of the bytes it copied (<Case>)" -ForEach @(
            @{ Case = 'zero-byte'; Size = 0 }
            @{ Case = 'small'; Size = 37 }
            @{ Case = 'larger-than-buffer'; Size = 2097152 }
            @{ Case = 'destination-missing-directory'; Size = 4096 }
            @{ Case = 'destination-exists'; Size = 4096 }
        ) {
            $root = Join-Path $TestDrive ('durable-copy-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $source = Join-Path $root 'source.bin'
            $bytes = New-Object byte[] $Size
            if ($Size -gt 0) {
                $random = [System.Random]::new(1234)
                $random.NextBytes($bytes)
            }
            [System.IO.File]::WriteAllBytes($source, $bytes)

            $destination = if ($Case -eq 'destination-missing-directory') {
                Join-Path (Join-Path $root 'nested/dir') 'copy.bin'
            }
            else {
                Join-Path $root 'copy.bin'
            }
            if ($Case -eq 'destination-exists') {
                Set-Content -LiteralPath $destination -Value 'old' -Encoding ASCII
            }

            $hash = InModuleScope Common -Parameters @{ Source = $source; Destination = $destination } {
                Copy-OpenPathAgentUpdateFileDurable -SourcePath $Source -DestinationPath $Destination
            }

            $hash | Should -Be (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            [System.IO.File]::ReadAllBytes($destination).Length | Should -Be $Size
            if ($Size -gt 0) {
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $hash
            }
        }

        It "Fails durable copy without leaving the destination when the source is missing" {
            $root = Join-Path $TestDrive ('durable-copy-fail-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $source = Join-Path $root 'missing.bin'
            $destination = Join-Path $root 'copy.bin'

            InModuleScope Common -Parameters @{ Source = $source; Destination = $destination } {
                { Copy-OpenPathAgentUpdateFileDurable -SourcePath $Source -DestinationPath $Destination } | Should -Throw
            }

            Test-Path -LiteralPath $destination | Should -BeFalse
        }

        It "Swaps a flushed temp sibling into place, creating a missing destination and replacing an existing one" {
            $root = Join-Path $TestDrive ('durable-swap-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $newFile = Join-Path $root 'new.ps1'
            $missingFile = Join-Path $root 'missing.ps1'
            Set-Content -LiteralPath $newFile -Value 'new-content' -Encoding ASCII

            InModuleScope Common -Parameters @{ Temp = $newFile; Destination = $missingFile } {
                Move-OpenPathAgentUpdateFileIntoPlace -TempPath $Temp -DestinationPath $Destination
            }
            (Get-Content -LiteralPath $missingFile -Raw).Trim() | Should -Be 'new-content'
            Test-Path -LiteralPath $newFile | Should -BeFalse

            $replacement = Join-Path $root 'replacement.ps1'
            $existing = Join-Path $root 'existing.ps1'
            Set-Content -LiteralPath $replacement -Value 'replacement-content' -Encoding ASCII
            Set-Content -LiteralPath $existing -Value 'old-content' -Encoding ASCII

            InModuleScope Common -Parameters @{ Temp = $replacement; Destination = $existing } {
                Move-OpenPathAgentUpdateFileIntoPlace -TempPath $Temp -DestinationPath $Destination
            }
            (Get-Content -LiteralPath $existing -Raw).Trim() | Should -Be 'replacement-content'
            Test-Path -LiteralPath $replacement | Should -BeFalse
            @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '\.tmp$|\.bak$' }).Count | Should -Be 0
        }

        It "Retries a sharing or lock violation in the swap primitive (<Hex>) and succeeds on the second attempt" -ForEach @(
            @{ Hex = '0x80070020'; HResult = -2147024864 }
            @{ Hex = '0x80070021'; HResult = -2147024863 }
        ) {
            $root = Join-Path $TestDrive ('durable-swap-retry-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $temp = Join-Path $root 'replacement.ps1'
            $destination = Join-Path $root 'existing.ps1'
            Set-Content -LiteralPath $temp -Value 'replacement-content' -Encoding ASCII
            Set-Content -LiteralPath $destination -Value 'old-content' -Encoding ASCII

            InModuleScope Common -Parameters @{ Temp = $temp; Destination = $destination; HResult = $HResult } {
                Mock Start-Sleep { }
                $script:SwapAttempts = 0
                Mock Invoke-OpenPathAgentUpdateFileReplace {
                    param($TempPath, $DestinationPath, $BackupPath)
                    $script:SwapAttempts += 1
                    if ($script:SwapAttempts -eq 1) {
                        throw [System.IO.IOException]::new('being used by another process', [int]$HResult)
                    }
                    [System.IO.File]::Replace($TempPath, $DestinationPath, $BackupPath, $true)
                }

                Move-OpenPathAgentUpdateFileIntoPlace -TempPath $Temp -DestinationPath $Destination
                $script:SwapAttempts | Should -Be 2
            }

            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'replacement-content'
            Test-Path -LiteralPath $temp | Should -BeFalse
            @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '\.tmp$|\.bak$' }).Count | Should -Be 0
        }

        It "Stops after the bounded attempts when the swap keeps hitting a sharing violation" {
            $root = Join-Path $TestDrive ('durable-swap-exhaust-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $temp = Join-Path $root 'replacement.ps1'
            $destination = Join-Path $root 'existing.ps1'
            Set-Content -LiteralPath $temp -Value 'replacement-content' -Encoding ASCII
            Set-Content -LiteralPath $destination -Value 'old-content' -Encoding ASCII

            InModuleScope Common -Parameters @{ Temp = $temp; Destination = $destination } {
                Mock Start-Sleep { }
                $script:SwapAttempts = 0
                Mock Invoke-OpenPathAgentUpdateFileReplace {
                    param($TempPath, $DestinationPath, $BackupPath)
                    $script:SwapAttempts += 1
                    throw [System.IO.IOException]::new('being used by another process', [int]-2147024864)
                }

                { Move-OpenPathAgentUpdateFileIntoPlace -TempPath $Temp -DestinationPath $Destination } | Should -Throw
                $script:SwapAttempts | Should -Be 5
            }

            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'old-content'
            Test-Path -LiteralPath $temp | Should -BeFalse
            @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '\.tmp$|\.bak$' }).Count | Should -Be 0
        }

        It "Does not retry a swap error that is not a sharing or lock violation" {
            $root = Join-Path $TestDrive ('durable-swap-no-retry-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $temp = Join-Path $root 'replacement.ps1'
            $destination = Join-Path $root 'existing.ps1'
            Set-Content -LiteralPath $temp -Value 'replacement-content' -Encoding ASCII
            Set-Content -LiteralPath $destination -Value 'old-content' -Encoding ASCII

            InModuleScope Common -Parameters @{ Temp = $temp; Destination = $destination } {
                Mock Start-Sleep { }
                $script:SwapAttempts = 0
                Mock Invoke-OpenPathAgentUpdateFileReplace {
                    param($TempPath, $DestinationPath, $BackupPath)
                    $script:SwapAttempts += 1
                    throw [System.IO.IOException]::new('invalid parameter', [int]-2147024809)
                }

                { Move-OpenPathAgentUpdateFileIntoPlace -TempPath $Temp -DestinationPath $Destination } | Should -Throw
                $script:SwapAttempts | Should -Be 1
            }

            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'old-content'
        }

        It "Reports the relative path, exception type and HResult when a restore fails definitively" {
            $root = Join-Path $TestDrive ('durable-restore-failure-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/a.ps1'
            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            $backup = Join-Path $backupRoot 'lib/a.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-a' -Encoding ASCII
            Set-Content -LiteralPath $backup -Value 'old-a' -Encoding ASCII

            $journal = [PSCustomObject]@{
                schemaVersion = 2
                phase         = 'replacing'
                backupRoot    = $backupRoot
                files         = @(
                    [PSCustomObject]@{
                        relativePath   = 'lib\a.ps1'
                        existedBefore  = $true
                        previousSha256 = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant()
                        sha256         = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                )
            }

            $result = InModuleScope Common -Parameters @{ Root = $root; Journal = $journal } {
                $script:OpenPathRoot = $Root
                Mock Start-Sleep { }
                Mock Move-OpenPathAgentUpdateFileIntoPlace {
                    param($TempPath, $DestinationPath)
                    throw [System.IO.IOException]::new('being used by another process', [int]-2147024864)
                }
                Restore-OpenPathAgentUpdateJournalBackups -OpenPathRoot $Root -Journal $Journal
            }

            $result.Complete | Should -BeFalse
            @($result.Failures).Count | Should -Be 1
            $result.Failures[0].RelativePath | Should -Be 'lib\a.ps1'
            $result.Failures[0].ExceptionType | Should -Be 'System.IO.IOException'
            $result.Failures[0].HResult | Should -Be '0x80070020'
            ($result.Errors -join "`n") | Should -Match 'lib\\a\.ps1'
            ($result.Errors -join "`n") | Should -Match 'System\.IO\.IOException'
            ($result.Errors -join "`n") | Should -Match '0x80070020'
        }
    }

    Context "Durable update write guard" {
        BeforeAll {
            function Get-NonDurableWriteLocations {
                param([Parameter(Mandatory = $true)][string]$Path)

                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
                if ($parseErrors.Count -gt 0) {
                    throw "Parse errors in ${Path}: $($parseErrors[0].Message)"
                }

                $locations = New-Object System.Collections.ArrayList
                $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
                foreach ($command in $commands) {
                    $name = [string]$command.GetCommandName()
                    if ($name -notin @('Copy-Item', 'Set-Content', 'Add-Content', 'Out-File')) {
                        continue
                    }
                    $owner = $command
                    while ($owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                        $owner = $owner.Parent
                    }
                    $functionName = if ($owner) { $owner.Name } else { '<script>' }
                    [void]$locations.Add(('{0}|{1}|{2}' -f (Split-Path $Path -Leaf), $functionName, $name))
                }

                $memberCalls = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
                foreach ($memberCall in $memberCalls) {
                    $name = [string]$memberCall.Member.Value
                    if ($name -notin @('WriteAllText', 'WriteAllBytes')) {
                        continue
                    }
                    $owner = $memberCall
                    while ($owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                        $owner = $owner.Parent
                    }
                    $functionName = if ($owner) { $owner.Name } else { '<script>' }
                    [void]$locations.Add(('{0}|{1}|{2}' -f (Split-Path $Path -Leaf), $functionName, $name))
                }

                return @($locations.ToArray())
            }
        }

        It "Has no non-durable write outside the explicit allow-list" {
            $files = @(
                'windows/lib/internal/Common.Update.ps1',
                'windows/scripts/Recover-OpenPathAgentUpdate.ps1',
                'windows/lib/internal/Common.Integrity.ps1'
            )
            $root = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
            $actual = @()
            foreach ($relativePath in $files) {
                $actual += Get-NonDurableWriteLocations -Path (Join-Path $root $relativePath)
            }

            # Temporary allow-list while the remaining commits convert these
            # paths. Every entry must shrink to the staging validator write.
            $allowed = @(
                # The staged-artifact validator is a short-lived temp script
                # outside the installed tree; it is read back only by the same
                # process and never becomes a name the recovery protocol uses.
                'Common.Update.ps1|Test-OpenPathAgentUpdateStagedArtifacts|WriteAllText'
            )

            $unexpected = @($actual | Where-Object { $_ -notin $allowed } | Sort-Object -Unique)
            $unexpected | Should -BeNullOrEmpty
        }

        It "Writes the run manifest, journal, failure record and superseded journal through the durable writer" {
            $content = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'internal') 'Common.Update.ps1') -Raw

            $content | Should -Match 'Write-OpenPathAgentUpdateJsonFile -Path \(Join-Path \$backupRoot ''manifest\.json''\) -Object \$manifest'
            $content | Should -Not -Match 'Set-Content -Path \(Join-Path \$backupRoot ''manifest\.json''\)'
            $content | Should -Match 'Copy-OpenPathAgentUpdateFileDurable -SourcePath \$JournalPath -DestinationPath \$temporaryPath'
        }
    }

    Context "Self-update unchanged files" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
        }

        It "Classifies matching files unchanged without a backup and backs up only changed files" {
            $root = Join-Path $TestDrive ('update-classify-' + [guid]::NewGuid().ToString('N'))
            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            $unchangedPath = Join-Path $root 'lib/unchanged.ps1'
            $changedPath = Join-Path $root 'lib/changed.ps1'
            $newPath = Join-Path $root 'lib/new.ps1'
            New-Item -ItemType Directory -Path (Split-Path $unchangedPath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $unchangedPath -Value 'same' -Encoding ASCII
            Set-Content -LiteralPath $changedPath -Value 'old' -Encoding ASCII

            $files = @(
                [PSCustomObject]@{
                    RelativePath    = 'lib/unchanged.ps1'
                    DestinationPath = $unchangedPath
                    BackupPath      = Join-Path $backupRoot 'lib/unchanged.ps1'
                    ExpectedSha256  = (Get-FileHash -LiteralPath $unchangedPath -Algorithm SHA256).Hash.ToLowerInvariant()
                },
                [PSCustomObject]@{
                    RelativePath    = 'lib/changed.ps1'
                    DestinationPath = $changedPath
                    BackupPath      = Join-Path $backupRoot 'lib/changed.ps1'
                    ExpectedSha256  = ('a' * 64)
                },
                [PSCustomObject]@{
                    RelativePath    = 'lib/new.ps1'
                    DestinationPath = $newPath
                    BackupPath      = Join-Path $backupRoot 'lib/new.ps1'
                    ExpectedSha256  = ('b' * 64)
                }
            )

            InModuleScope Common -Parameters @{ Files = $files } {
                Save-OpenPathAgentUpdateInstalledFileBackups -Files $Files
            }

            $files[0].Unchanged | Should -BeTrue
            $files[0].PreviousSha256 | Should -Be $files[0].ExpectedSha256
            Test-Path -LiteralPath $files[0].BackupPath | Should -BeFalse

            $files[1].Unchanged | Should -BeFalse
            $files[1].PreviousSha256 | Should -Be (Get-FileHash -LiteralPath $changedPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Test-Path -LiteralPath $files[1].BackupPath | Should -BeTrue

            $files[2].Unchanged | Should -BeFalse
            $files[2].PreviousSha256 | Should -Be ''
            Test-Path -LiteralPath $files[2].BackupPath | Should -BeFalse
            @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File).Count | Should -Be 1
        }

        It "Aborts when the backup re-read does not match the previous file" {
            $root = Join-Path $TestDrive ('update-backup-mismatch-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/a.ps1'
            $backup = Join-Path $root 'data/agent-update/backups/run-test/lib/a.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'old-a' -Encoding ASCII

            $files = @(
                [PSCustomObject]@{
                    RelativePath    = 'lib/a.ps1'
                    DestinationPath = $destination
                    BackupPath      = $backup
                    ExpectedSha256  = ('a' * 64)
                }
            )

            InModuleScope Common -Parameters @{ Files = $files } {
                Mock Copy-OpenPathAgentUpdateFileDurable {
                    param($SourcePath, $DestinationPath, $BufferSize)
                    $directory = Split-Path $DestinationPath -Parent
                    if (-not (Test-Path -LiteralPath $directory)) {
                        New-Item -ItemType Directory -Path $directory -Force | Out-Null
                    }
                    [System.IO.File]::WriteAllText($DestinationPath, 'corrupt-backup')
                    return (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
                }

                { Save-OpenPathAgentUpdateInstalledFileBackups -Files $Files } |
                    Should -Throw '*Backup checksum mismatch*'
            }

            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'old-a'
        }

        It "Skips unchanged files in the replacement loop but verifies every manifest file afterwards" {
            $content = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'internal') 'Common.Update.ps1') -Raw

            $loopStart = $content.IndexOf('foreach ($download in $downloadedFiles)')
            $unchangedSkip = $content.IndexOf('if ([bool]$download.Unchanged) {', $loopStart)
            $unchangedSkip | Should -BeGreaterThan $loopStart

            $postCheckStart = $content.IndexOf('Post-replacement checksum mismatch')
            $unchangedSkip | Should -BeLessThan $postCheckStart
            $postCheckLoopStart = $content.LastIndexOf('foreach ($download in $downloadedFiles)', $postCheckStart)
            $postCheckLoopStart | Should -BeGreaterThan $unchangedSkip
        }
    }

    Context "Self-update transactions" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
        }

        It "Backs up every existing file into a per-run directory before replacing anything" {
            $updateHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'data\agent-update',
                '''backups''',
                'New-OpenPathAgentUpdateBackupRoot',
                'Save-OpenPathAgentUpdateInstalledFileBackups',
                'manifest.json',
                '$tempDestinationPath',
                'Move-OpenPathAgentUpdateFileIntoPlace `',
                '-TempPath $tempDestinationPath `',
                '-DestinationPath $download.DestinationPath',
                'Post-replacement checksum mismatch'
            )

            $content | Should -Not -Match '\$replacementBackups'

            $backupStart = $content.IndexOf('Save-OpenPathAgentUpdateInstalledFileBackups -Files $downloadedFiles')
            $journalWriteStart = $content.IndexOf('Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot', $backupStart)
            $firstReplacementStart = $content.IndexOf('Move-OpenPathAgentUpdateFileIntoPlace', $journalWriteStart)

            $backupStart | Should -BeGreaterThan 0
            $backupStart | Should -BeLessThan $journalWriteStart
            $journalWriteStart | Should -BeLessThan $firstReplacementStart
        }

        It "Sweeps temp siblings and staging trees left by an interrupted run" {
            $root = Join-Path $TestDrive ('update-sweep-' + [guid]::NewGuid().ToString('N'))
            $lib = Join-Path $root 'lib'
            $updateRoot = Join-Path $root 'data/agent-update'
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $updateRoot 'staging-old') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $lib 'kept.ps1') -Value 'kept' -Encoding ASCII
            foreach ($name in @('a.ps1.openpath-update-run-x.tmp', 'a.ps1.openpath-update-run-x.tmp.bak', 'a.ps1.openpath-update-recovery-x.tmp')) {
                Set-Content -LiteralPath (Join-Path $lib $name) -Value 'leftover' -Encoding ASCII
            }
            Set-Content -LiteralPath (Join-Path $updateRoot 'staging-old/partial.ps1') -Value 'partial' -Encoding ASCII

            InModuleScope Common -Parameters @{ Root = $root } {
                Remove-OpenPathAgentUpdateLeftovers -OpenPathRoot $Root
            }

            @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -match 'openpath-update-' }).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $updateRoot 'staging-old') | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $lib 'kept.ps1') -Raw).Trim() | Should -Be 'kept'
        }

        It "Sweeps leftovers before the download loop" {
            $content = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'internal') 'Common.Update.ps1') -Raw
            $sweep = $content.IndexOf('Remove-OpenPathAgentUpdateLeftovers -OpenPathRoot $script:OpenPathRoot')
            $download = $content.IndexOf('Invoke-WebRequest -Uri $fileUrl')
            $sweep | Should -BeGreaterThan 0
            $sweep | Should -BeLessThan $download
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
                    if ($Uri -match 'existing-a\.ps1(\?|$)') {
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
            $updateHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1"
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
            $updateHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1"
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
            $updateHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1"
            $content = Get-Content $updateHelperPath -Raw

            $lockStart = $content.IndexOf('$updateLock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds')
            $replaceStart = $content.IndexOf('Move-OpenPathAgentUpdateFileIntoPlace', $lockStart)
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
            $commonPath = (Resolve-Path (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1")).Path
            . $commonPath
            $script:OpenPathAgentUpdateLockName = "OpenPathTestLock-$([guid]::NewGuid().ToString('N'))"
            $holderScript = @"
`$m = [System.Threading.Mutex]::new(`$false, '$($script:OpenPathAgentUpdateLockName)')
`$null = `$m.WaitOne()
[Console]::Out.WriteLine('held'); [Console]::Out.Flush()
`$null = [Console]::In.ReadLine()
`$m.ReleaseMutex()
"@
            $holderScriptPath = Join-Path $TestDrive ("update-lock-holder-$([guid]::NewGuid().ToString('N')).ps1")
            Set-Content -LiteralPath $holderScriptPath -Value $holderScript -Encoding UTF8
            $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$holderScriptPath`""
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

        It "Waits for an update lock held by another security context instead of failing" {
            $commonPath = (Resolve-Path (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1")).Path
            . $commonPath
            $script:deniedOpens = 0
            # A SYSTEM-owned mutex denies an elevated admin session until it is released.
            function New-OpenPathAgentUpdateMutex {
                if ($script:deniedOpens -lt 2) {
                    $script:deniedOpens++
                    throw [System.UnauthorizedAccessException]::new("Access to the path 'Global\OpenPathAgentUpdateLock' is denied.")
                }
                return [System.Threading.Mutex]::new($false)
            }

            $lock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 5000 -RetryDelayMilliseconds 10
            try {
                $lock.Acquired | Should -BeTrue
                $script:deniedOpens | Should -Be 2
            }
            finally {
                Exit-OpenPathAgentUpdateLock -Lock $lock
            }
        }

        It "Restarts only this installation's resident processes after an agent update" {
            $commonPath = (Resolve-Path (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1")).Path
            . $commonPath
            $installRoot = Join-Path $TestDrive 'resident-root'
            $otherRoot = Join-Path $TestDrive 'other-root'
            $sse = Join-Path (Join-Path $installRoot 'scripts') 'Start-SSEListener.ps1'
            $worker = Join-Path (Join-Path $installRoot 'scripts') 'Start-RuntimeDependencyWorker.ps1'
            $foreignSse = Join-Path (Join-Path $otherRoot 'scripts') 'Start-SSEListener.ps1'
            $script:residentProcesses = @(
                [pscustomobject]@{ ProcessId = 4101; CommandLine = "PowerShell.exe -File `"$sse`"" },
                [pscustomobject]@{ ProcessId = 4102; CommandLine = "PowerShell.exe -File `"$worker`"" },
                [pscustomobject]@{ ProcessId = 4103; CommandLine = "PowerShell.exe -File `"$foreignSse`"" },
                [pscustomobject]@{ ProcessId = $PID; CommandLine = "PowerShell.exe -File `"$sse`"" },
                [pscustomobject]@{ ProcessId = 4104; CommandLine = 'PowerShell.exe -File "C:\Other\Tool.ps1"' }
            )
            $script:stoppedIds = @()
            function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) $script:residentProcesses }
            function Stop-Process { param([int]$Id, [switch]$Force, $ErrorAction) $script:stoppedIds += $Id }
            function Start-Sleep { param($Seconds, $Milliseconds) }
            function Write-OpenPathLog { param([string]$Message, [string]$Level) }

            $restarted = @(Restart-OpenPathResidentAgentProcesses -OpenPathRoot $installRoot)

            @($script:stoppedIds | Sort-Object) | Should -Be @(4101, 4102)
            @($restarted | Sort-Object) | Should -Be @('Start-RuntimeDependencyWorker.ps1', 'Start-SSEListener.ps1')
        }

        It "Reports a lock held by another security context as busy without throwing" {
            $commonPath = (Resolve-Path (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1")).Path
            . $commonPath
            $script:deniedOpens = 0
            function New-OpenPathAgentUpdateMutex {
                $script:deniedOpens++
                throw [System.UnauthorizedAccessException]::new("Access to the path 'Global\OpenPathAgentUpdateLock' is denied.")
            }

            $busy = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 0
            $busy.Acquired | Should -BeFalse
            $busy.Mutex | Should -BeNullOrEmpty
            $script:deniedOpens | Should -Be 1

            $timedOut = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 60 -RetryDelayMilliseconds 10
            $timedOut.Acquired | Should -BeFalse
            $script:deniedOpens | Should -BeGreaterThan 2
        }

        It "Gates staged .ps1/.psm1 artifacts behind an opt-in Authenticode signature check" {
            $updateHelperPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1"
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
            $moveStart = $content.IndexOf('Move-OpenPathAgentUpdateFileIntoPlace', $applyLoopStart)
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
            $dnsPath = (Resolve-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "DNS.psm1")).Path
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            $browserPath = (Resolve-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Browser.psm1")).Path
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1") -Force
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
            $modulePath = (Resolve-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1")).Path
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
            . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Config.ps1")
            . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Update.Script.Apply.ps1")
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
                Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1") -Force
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
                Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1") -Force
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
            $runtimePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Update.Runtime.psm1"
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
            (Get-Content -LiteralPath (Join-Path $TestDrive 'whitelist.txt') -Raw).Trim() | Should -Be 'WHITELIST'
            @(Get-ChildItem -LiteralPath $TestDrive -Filter 'whitelist.txt.tmp.*').Count | Should -Be 0
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
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
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

            $updatePath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "internal") "Common.Update.ps1"
            $content = Get-Content $updatePath -Raw
            $lockStart = $content.IndexOf('$updateLock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds')
            $backupStart = $content.IndexOf('Save-OpenPathAgentUpdateInstalledFileBackups -Files $downloadedFiles', $lockStart)
            $intentWriteStart = $content.IndexOf('Write-OpenPathAgentUpdateJsonFile -Path $intentPath -Object $updateJournal', $lockStart)
            $journalWriteStart = $content.IndexOf('Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot', $intentWriteStart)
            $firstReplacementStart = $content.IndexOf('Move-OpenPathAgentUpdateFileIntoPlace', $lockStart)
            $markerWriteStart = $content.IndexOf('Write-OpenPathAgentUpdateCommittedMarker', $lockStart)
            $committedPhaseStart = $content.IndexOf("Update-OpenPathAgentUpdateJournalPhase -OpenPathRoot `$script:OpenPathRoot -Journal `$updateJournal -Phase 'committed'", $markerWriteStart)

            $lockStart | Should -BeGreaterThan 0
            $backupStart | Should -BeGreaterThan $lockStart
            $backupStart | Should -BeLessThan $intentWriteStart
            $intentWriteStart | Should -BeGreaterThan $backupStart
            $intentWriteStart | Should -BeLessThan $journalWriteStart
            $journalWriteStart | Should -BeGreaterThan $lockStart
            $firstReplacementStart | Should -BeGreaterThan $journalWriteStart
            $markerWriteStart | Should -BeGreaterThan 0
            $committedPhaseStart | Should -BeGreaterThan $markerWriteStart
        }
    }

    Context "Self-update intent and commit marker" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
        }

        It "Writes a commit marker for one run and rejects a marker from another run" {
            $root = Join-Path $TestDrive ('update-marker-' + [guid]::NewGuid().ToString('N'))
            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

            InModuleScope Common -Parameters @{ BackupRoot = $backupRoot } {
                $markerPath = Write-OpenPathAgentUpdateCommittedMarker `
                    -BackupRoot $BackupRoot `
                    -RunId 'run-test' `
                    -TargetVersion '9.9.9' `
                    -TargetBuild 'build-new'
                (Read-OpenPathAgentUpdateCommittedMarker -MarkerPath $markerPath -RunId 'run-test').targetVersion | Should -Be '9.9.9'
                (Read-OpenPathAgentUpdateCommittedMarker -MarkerPath $markerPath -RunId 'run-test').targetBuild | Should -Be 'build-new'
                Read-OpenPathAgentUpdateCommittedMarker -MarkerPath $markerPath -RunId 'run-other' | Should -BeNullOrEmpty
                (Test-OpenPathAgentUpdateCommitEvidence -BackupRoot $BackupRoot) | Should -BeTrue
            }
        }

        It "Fails at <Point> with the expected rollback or finalization outcome" -ForEach @(
            @{ Point = 'marker' }
            @{ Point = 'committed-journal' }
        ) {
            $root = Join-Path $TestDrive ('update-commit-fail-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII

            $stagedSource = Join-Path $TestDrive ('staged-' + [guid]::NewGuid().ToString('N') + '.ps1')
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
                Point = $Point
            } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStagedSource = $StagedSource
                $script:FailPoint = $Point
                $script:FailCommittedWrite = $true
                $script:Captured = @{ Config = $null }
                $script:RealJsonWriter = Get-Command -Name Write-OpenPathAgentUpdateJsonFile

                Mock Write-OpenPathAgentUpdateJsonFile {
                    param($Path, $Object)
                    if ($script:FailCommittedWrite) {
                        if ($script:FailPoint -eq 'marker' -and $Path -like '*committed.marker') {
                            throw 'simulated marker write failure'
                        }
                        if ($script:FailPoint -eq 'committed-journal' -and
                            $Path -like '*update-journal.json' -and
                            [string]$Object.phase -eq 'committed') {
                            throw 'simulated committed journal write failure'
                        }
                    }
                    & $script:RealJsonWriter -Path $Path -Object $Object
                }

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
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent
                $result.Success | Should -BeFalse

                $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root
                $backupRoot = @(Get-ChildItem -LiteralPath (Join-Path $Root 'data/agent-update/backups') -Directory -Filter 'run-*' -ErrorAction SilentlyContinue)[0]
                $markerPath = if ($backupRoot) { Join-Path $backupRoot.FullName 'committed.marker' } else { '' }

                if ($script:FailPoint -eq 'marker') {
                    (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "old"'
                    Test-Path -LiteralPath $journalPath | Should -BeFalse
                    @(Get-ChildItem -LiteralPath (Join-Path $Root 'data/agent-update/backups') -Directory -Filter 'run-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
                }
                else {
                    (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "new"'
                    Test-Path -LiteralPath $journalPath | Should -BeTrue
                    Test-Path -LiteralPath $markerPath | Should -BeTrue
                    $script:Captured.Config | Should -BeNullOrEmpty

                    $script:FailCommittedWrite = $false
                    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
                    $final = Complete-OpenPathAgentUpdateFinalization `
                        -OpenPathRoot $Root `
                        -Journal $journal `
                        -Config ([PSCustomObject]@{ version = '9.9.8'; agentBuild = 'build-old' })
                    $final.Success | Should -BeTrue
                    Test-Path -LiteralPath $journalPath | Should -BeFalse
                    Test-Path -LiteralPath $markerPath | Should -BeFalse
                    $script:Captured.Config.version | Should -Be '9.9.9'
                    $script:Captured.Config.agentBuild | Should -Be 'build-new'
                }
            }
        }

        It "Writes the journal intent as the same bytes as the first journal" {
            $root = Join-Path $TestDrive ('update-intent-bytes-' + [guid]::NewGuid().ToString('N'))
            $backupRoot = Join-Path $root 'data/agent-update/backups/run-test'
            $journal = [PSCustomObject]@{
                schemaVersion = 2
                phase         = 'replacing'
                runId         = 'run-test'
                durable       = $true
                targetVersion = '9.9.9'
                targetBuild   = 'build-new'
                backupRoot    = $backupRoot
                createdAt     = '2026-11-14T10:00:00.0000000Z'
                updatedAt     = '2026-11-14T10:00:00.0000000Z'
                files         = @([PSCustomObject]@{ relativePath = 'lib/a.ps1'; existedBefore = $true; previousSha256 = ('a' * 64); sha256 = ('b' * 64); unchanged = $false })
            }
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

            InModuleScope Common -Parameters @{ BackupRoot = $backupRoot; Journal = $journal } {
                $intentPath = Get-OpenPathAgentUpdateJournalIntentPath -BackupRoot $BackupRoot
                $journalPath = Join-Path $BackupRoot 'update-journal.json'
                Write-OpenPathAgentUpdateJsonFile -Path $intentPath -Object $Journal
                Write-OpenPathAgentUpdateJsonFile -Path $journalPath -Object $Journal
                [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($intentPath)) |
                    Should -Be ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)))
            }
        }
    }

    Context "Self-update blocked repair" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global

            function Write-RepairState {
                param(
                    [Parameter(Mandatory = $true)][string]$Root,
                    [int]$RepairAttempts = 0,
                    [int]$MinutesAgo = -1
                )

                $updateRoot = Join-Path $Root 'data/agent-update'
                New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
                $lastRepairAt = if ($MinutesAgo -ge 0) {
                    [DateTime]::UtcNow.AddMinutes(-$MinutesAgo).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    ''
                }
                [PSCustomObject]@{
                    schemaVersion  = 1
                    state          = 'blocked'
                    reasonCode     = 'self_update_recovery_journal_unreadable'
                    attempts       = 1
                    firstSeenAt    = [DateTime]::UtcNow.AddHours(-1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    lastAttemptAt  = [DateTime]::UtcNow.AddHours(-1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    repairAttempts = $RepairAttempts
                    lastRepairAt   = $lastRepairAt
                    runId          = 'run-blocked'
                } | ConvertTo-Json -Depth 5 |
                    Set-Content -LiteralPath (Join-Path $updateRoot 'recovery-state.json') -Encoding UTF8
            }
        }

        It "Forces the published build over a blocked tree even when version and build match" {
            $root = Join-Path $TestDrive ('update-repair-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/changed.ps1'
            $unchangedDestination = Join-Path $root 'lib/unchanged.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'old' -Encoding ASCII
            Set-Content -LiteralPath $unchangedDestination -Value 'same' -Encoding ASCII
            (Get-Item -LiteralPath $unchangedDestination).LastWriteTimeUtc = [DateTime]::UtcNow.AddYears(-2)
            $unchangedTimestamp = (Get-Item -LiteralPath $unchangedDestination).LastWriteTimeUtc

            $staged = Join-Path $TestDrive ('repair-staged-' + [guid]::NewGuid().ToString('N') + '.ps1')
            $stagedUnchanged = Join-Path $TestDrive ('repair-staged-unchanged-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $staged -Value 'new' -Encoding ASCII
            Set-Content -LiteralPath $stagedUnchanged -Value 'same' -Encoding ASCII
            $changedHash = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
            $unchangedHash = (Get-FileHash -LiteralPath $stagedUnchanged -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @(
                    [PSCustomObject]@{ path = 'lib/changed.ps1'; sha256 = $changedHash },
                    [PSCustomObject]@{ path = 'lib/unchanged.ps1'; sha256 = $unchangedHash }
                )
            }
            Write-RepairState -Root $root

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; Staged = $staged; StagedUnchanged = $stagedUnchanged; UnchangedTimestamp = $unchangedTimestamp } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStaged = $Staged
                $script:TestStagedUnchanged = $StagedUnchanged
                $script:Captured = @{ Config = $null; GateCalls = 0 }
                Mock Get-OpenPathConfig {
                    [PSCustomObject]@{
                        apiUrl       = 'https://api.test'
                        whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                        version      = '9.9.9'
                        agentBuild   = 'build-new'
                    }
                }
                Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
                Mock Invoke-RestMethod { $script:TestManifest }
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    $source = if ($Uri -match 'unchanged\.ps1(\?|$)') { $script:TestStagedUnchanged } else { $script:TestStaged }
                    Copy-Item -LiteralPath $source -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { $script:Captured.Config = $Config }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue -Because $result.Message
                $result.Updated | Should -BeTrue -Because $result.Message
                $script:Captured.GateCalls | Should -Be 1
                (Get-Content -LiteralPath (Join-Path $Root 'lib/changed.ps1') -Raw).Trim() | Should -Be 'new'
                (Get-Item -LiteralPath (Join-Path $Root 'lib/unchanged.ps1')).LastWriteTimeUtc | Should -Be $UnchangedTimestamp
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateRecoveryStatePath -OpenPathRoot $Root) | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
            }
        }

        It "Repairs a blocked tree even when the target build has a failed-build record" {
            $root = Join-Path $TestDrive ('update-repair-backoff-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'old' -Encoding ASCII

            $staged = Join-Path $TestDrive ('repair-staged-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $staged -Value 'new' -Encoding ASCII
            $hash = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $hash })
            }
            Write-RepairState -Root $root
            [PSCustomObject]@{
                schemaVersion = 1
                version       = '9.9.9'
                build         = 'build-new'
                stage         = 'gate'
                message       = 'previous failure'
                failedAt      = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            } | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath (Join-Path $root 'data/agent-update/failed-update.json') -Encoding UTF8

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; Staged = $staged } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStaged = $Staged
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
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStaged -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Send-OpenPathHealthReport { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue
                $result.Updated | Should -BeTrue
                $script:GateCalls | Should -Be 1
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'new'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateRecoveryStatePath -OpenPathRoot $Root) | Should -BeFalse
            }
        }

        It "Does not start a repair before its <Case> bound" -ForEach @(
            @{ Case = 'ten-minute'; RepairAttempts = 1; MinutesAgo = 5 }
            @{ Case = 'daily'; RepairAttempts = 3; MinutesAgo = 60 }
        ) {
            $root = Join-Path $TestDrive ('update-repair-bound-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'old' -Encoding ASCII

            $staged = Join-Path $TestDrive ('repair-staged-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $staged -Value 'new' -Encoding ASCII
            $hash = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-new'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $hash })
            }
            $attempts = if ($Case -eq 'ten-minute') { 1 } else { 3 }
            $minutesAgo = if ($Case -eq 'ten-minute') { 5 } else { 60 }
            Write-RepairState -Root $root -RepairAttempts $attempts -MinutesAgo $minutesAgo

            InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; Staged = $staged } {
                $script:OpenPathRoot = $Root
                $script:TestManifest = $Manifest
                $script:TestStaged = $Staged
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
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStaged -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:GateCalls++
                    [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeTrue -Because $result.Message
                $result.Updated | Should -BeFalse -Because $result.Message
                $script:GateCalls | Should -Be 0
                (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'old'
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateRecoveryStatePath -OpenPathRoot $Root) | Should -BeTrue
            }
        }
    }

    Context "Self-update health gate and failure backoff" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
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
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/superseded-update-journal.json') | Should -BeFalse

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
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/superseded-update-journal.json') | Should -BeFalse
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

        It "Treats a failure timestamp ahead of this clock as an elapsed backoff" {
            InModuleScope Common {
                $now = [DateTimeOffset]::Parse('2026-11-15T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
                $future = [PSCustomObject]@{
                    version  = '9.9.9'
                    build    = 'build-bad'
                    failedAt = $now.AddHours(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }

                Test-OpenPathAgentUpdateFailureBackoffActive -Record $future -Now $now | Should -BeFalse
                Test-OpenPathAgentUpdateFailureBackoffActive -Record $future -Now $now.AddDays(8) | Should -BeFalse

                $rounding = [PSCustomObject]@{
                    version  = '9.9.9'
                    build    = 'build-bad'
                    failedAt = $now.AddSeconds(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }
                Test-OpenPathAgentUpdateFailureBackoffActive -Record $rounding -Now $now | Should -BeTrue
            }
        }

        It "Does not apply the seven-day backoff until the health gate times out three times in a row" {
            $root = Join-Path $TestDrive ('update-gate-timeout-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII

            $stagedSource = Join-Path $TestDrive ('gate-timeout-' + [guid]::NewGuid().ToString('N') + '.ps1')
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
                $script:Captured = @{ Reports = @(); GateCalls = 0 }
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
                Mock Set-OpenPathConfig { }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:Captured.Reports += [PSCustomObject]@{
                        Status      = $Status
                        ReasonCodes = @($ReasonCodes)
                    }
                }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:Captured.GateCalls++
                    [PSCustomObject]@{ Healthy = $false; TimedOut = $true; ExitCode = -1; Message = 'Health gate timed out after 60 seconds' }
                }

                $recordPath = Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root
                $timeoutStatePath = Get-OpenPathAgentUpdateTimeoutStatePath -OpenPathRoot $Root

                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    $result = Invoke-OpenPathAgentSelfUpdate -Silent

                    $result.Success | Should -BeFalse
                    (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "old"'
                    $script:Captured.Reports.Count | Should -Be $attempt
                    (@($script:Captured.Reports[$attempt - 1].ReasonCodes) -join ' ') | Should -Match 'self_update_health_gate_failed'
                    $state = Get-Content -LiteralPath $timeoutStatePath -Raw | ConvertFrom-Json
                    $state.consecutiveTimeouts | Should -Be $attempt
                    $state.build | Should -Be 'build-new'
                    $state.stage | Should -Be 'gate'

                    if ($attempt -lt 3) {
                        Test-Path -LiteralPath $recordPath | Should -BeFalse
                    }
                    else {
                        Test-Path -LiteralPath $recordPath | Should -BeTrue
                    }
                }

                $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
                $record.stage | Should -Be 'gate'
                $record.build | Should -Be 'build-new'
            }
        }

        It "Does not apply the seven-day backoff when staged validation times out" {
            $root = Join-Path $TestDrive ('update-validation-timeout-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $root 'data/agent-update') -Force | Out-Null
            $stagedSource = Join-Path $TestDrive ('validation-timeout-' + [guid]::NewGuid().ToString('N') + '.ps1')
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
                $script:Captured = @{ Reports = @() }
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
                Mock Test-OpenPathAgentUpdateStagedArtifacts {
                    [PSCustomObject]@{ Healthy = $false; TimedOut = $true; Message = 'Staged artifact validation timed out after 30 seconds' }
                }
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:Captured.Reports += [PSCustomObject]@{ Status = $Status; ReasonCodes = @($ReasonCodes) }
                }

                $result = Invoke-OpenPathAgentSelfUpdate -Silent

                $result.Success | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse
                $state = Get-Content -LiteralPath (Get-OpenPathAgentUpdateTimeoutStatePath -OpenPathRoot $Root) -Raw | ConvertFrom-Json
                $state.consecutiveTimeouts | Should -Be 1
                $state.stage | Should -Be 'validation'
                $script:Captured.Reports.Count | Should -Be 1
                (@($script:Captured.Reports[0].ReasonCodes) -join ' ') | Should -Match 'self_update_validation_failed'
            }
        }

        It "Clears the timeout streak after a successful health gate" {
            $root = Join-Path $TestDrive ('update-timeout-clear-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII
            $stagedSource = Join-Path $TestDrive ('timeout-clear-' + [guid]::NewGuid().ToString('N') + '.ps1')
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
                Mock Invoke-WebRequest {
                    param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                    Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                }
                Mock Write-OpenPathLog { }
                Mock Set-OpenPathConfig { }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Send-OpenPathHealthReport { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Start-OpenPathTask { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Invoke-OpenPathAgentUpdateHealthGate {
                    $script:GateCalls++
                    if ($script:GateCalls -eq 1) {
                        return [PSCustomObject]@{ Healthy = $false; TimedOut = $true; ExitCode = -1; Message = 'Health gate timed out' }
                    }
                    return [PSCustomObject]@{ Healthy = $true; TimedOut = $false; ExitCode = 0; Message = '' }
                }

                $first = Invoke-OpenPathAgentSelfUpdate -Silent
                $first.Success | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateTimeoutStatePath -OpenPathRoot $Root) | Should -BeTrue

                $second = Invoke-OpenPathAgentSelfUpdate -Silent
                $second.Success | Should -BeTrue
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateTimeoutStatePath -OpenPathRoot $Root) | Should -BeFalse
                Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse
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
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
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

        It "Restores protected mode after an update only when the local whitelist is not disabled" -TestCases @(
            @{ Whitelist = '# DESACTIVADO'; ExpectedRestores = 0; ExpectedAcrylicRestarts = 0; ExpectedUnknownLogs = 0 }
            @{ Whitelist = "## WHITELIST`nexample.org"; ExpectedRestores = 1; ExpectedAcrylicRestarts = 0; ExpectedUnknownLogs = 0 }
            @{ Whitelist = $null; ExpectedRestores = 1; ExpectedAcrylicRestarts = 0; ExpectedUnknownLogs = 1 }
        ) {
            $root = Join-Path $TestDrive ('finalize-fail-open-' + [guid]::NewGuid().ToString('N'))
            $destination = Join-Path $root 'lib/existing.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-target' -Encoding ASCII
            $targetHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()

            $journal = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = 'committed'
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = (Join-Path $root 'data/agent-update/backups/run-test')
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
            if ($null -ne $Whitelist) {
                Set-Content -LiteralPath (Join-Path $root 'data/whitelist.txt') -Value $Whitelist -Encoding UTF8
            }
            $config = [PSCustomObject]@{ version = '9.9.8'; agentBuild = 'build-old' }

            InModuleScope Common -Parameters @{
                Root = $root
                Journal = $journal
                Config = $config
                ExpectedRestores = $ExpectedRestores
                ExpectedAcrylicRestarts = $ExpectedAcrylicRestarts
                ExpectedUnknownLogs = $ExpectedUnknownLogs
            } {
                $script:OpenPathRoot = $Root
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport { }
                Mock Set-OpenPathConfig { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Restore-OpenPathProtectedMode', 'Restart-AcrylicService', 'Start-OpenPathTask', 'Save-OpenPathIntegrityBackup', 'New-OpenPathIntegrityBaseline')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Register-OpenPathTask { }
                Mock Enable-OpenPathTask { }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Restart-AcrylicService { }
                Mock Start-OpenPathTask { }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Remove-OpenPathAgentUpdateBackupDirectories { }
                Mock Restart-OpenPathResidentAgentProcesses { @('Start-SSEListener.ps1', 'Start-RuntimeDependencyWorker.ps1') }

                $result = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config

                $result.Success | Should -BeTrue
                Should -Invoke Restore-OpenPathProtectedMode -Times $ExpectedRestores -Exactly
                Should -Invoke Restart-AcrylicService -Times $ExpectedAcrylicRestarts -Exactly
                Should -Invoke Restart-OpenPathResidentAgentProcesses -Times 1 -Exactly -ParameterFilter { $OpenPathRoot -eq $Root }
                Should -Invoke Start-OpenPathTask -Times 1 -Exactly -ParameterFilter { $TaskType -eq 'RuntimeDependencyWorker' -or @($Rest) -contains 'RuntimeDependencyWorker' }
                Should -Invoke Start-OpenPathTask -Times 1 -Exactly -ParameterFilter { $TaskType -eq 'SSE' -or @($Rest) -contains 'SSE' }
                Should -Invoke Write-OpenPathLog -Times $ExpectedUnknownLogs -Exactly -ParameterFilter {
                    $Message -match 'classroom_state_unknown'
                }
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

        It "Keeps the agent update task as it was before the update (<Before>), also across a retried finalization" -TestCases @(
            @{ Before = 'disabled'; FailFirstDisable = $false; Expected = $false }
            @{ Before = 'disabled'; FailFirstDisable = $true; Expected = $false }
            @{ Before = 'enabled'; FailFirstDisable = $false; Expected = $true }
        ) {
            param($Before, $FailFirstDisable, $Expected)

            $root = Join-Path $TestDrive ('finalize-agent-task-' + [guid]::NewGuid().ToString('N'))
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

            InModuleScope Common -Parameters @{
                Root = $root; Journal = $journal; Config = $config
                Before = $Before; FailFirstDisable = $FailFirstDisable; Expected = $Expected
            } {
                $script:OpenPathRoot = $Root
                # One simulated task store: re-registration and Enable-OpenPathTask enable the
                # task, as the real Register-ScheduledTask -Force and Enable-ScheduledTask do.
                $script:AgentTaskEnabled = ($Before -eq 'enabled')
                $script:DisableCalls = 0
                Mock Write-OpenPathLog { }
                Mock Send-OpenPathHealthReport { }
                Mock Set-OpenPathConfig { }
                foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask', 'Get-ScheduledTask', 'Disable-ScheduledTask')) {
                    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                        Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                    }
                }
                Mock Get-ScheduledTask {
                    [PSCustomObject]@{ TaskName = 'OpenPath-AgentUpdate'; Settings = [PSCustomObject]@{ Enabled = $script:AgentTaskEnabled } }
                }
                Mock Disable-ScheduledTask {
                    $script:DisableCalls++
                    if ($FailFirstDisable -and $script:DisableCalls -eq 1) { throw 'task scheduler busy' }
                    $script:AgentTaskEnabled = $false
                }
                Mock Register-OpenPathTask { $script:AgentTaskEnabled = $true }
                Mock Enable-OpenPathTask { $script:AgentTaskEnabled = $true }
                Mock Invoke-OpenPathFirefoxNativeHostCompiledEnsure { }
                Mock Register-OpenPathFirefoxNativeHost { }
                Mock Restore-OpenPathProtectedMode { }
                Mock Start-OpenPathTask { }
                Mock Save-OpenPathIntegrityBackup { }
                Mock New-OpenPathIntegrityBaseline { }
                Mock Remove-OpenPathAgentUpdateBackupDirectories { }

                $result = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $Journal -Config $Config
                if ($FailFirstDisable) {
                    $result.Success | Should -BeFalse
                    # the failed attempt left the task enabled; the journal still knows better
                    $script:AgentTaskEnabled | Should -BeTrue
                    $onDisk = Get-Content -LiteralPath (Join-Path $Root 'data/agent-update/update-journal.json') -Raw | ConvertFrom-Json
                    $onDisk.agentUpdateTaskState | Should -Be 'disabled'
                    $result = Complete-OpenPathAgentUpdateFinalization -OpenPathRoot $Root -Journal $onDisk -Config $Config
                }

                $result.Success | Should -BeTrue
                $script:AgentTaskEnabled | Should -Be $Expected
                if ($Expected) { $script:DisableCalls | Should -Be 0 }
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

        It "Runs finalization from a committed journal at the start of self-update (<JournalLocation>)" -ForEach @(
            @{ JournalLocation = 'journal' }
            @{ JournalLocation = 'superseded' }
        ) {
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
            $journalPath = if ($JournalLocation -eq 'superseded') {
                Join-Path $root 'data/agent-update/superseded-update-journal.json'
            }
            else {
                Join-Path $root 'data/agent-update/update-journal.json'
            }
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
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/superseded-update-journal.json') | Should -BeFalse
            }
        }
    }

    Context "Self-update stuck finalization" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global

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

            function Invoke-SupersededReplacementScenario {
                param(
                    [Parameter(Mandatory = $true)][string]$Root,
                    [Parameter(Mandatory = $true)][object]$Manifest,
                    [string]$StagedSource = '',
                    [Parameter(Mandatory = $true)][ValidateSet(
                        'gate-failure',
                        'replace-failure',
                        'success',
                        'download-failure',
                        'incomplete-rollback',
                        'save-failure',
                        'hash-mismatch-gate-failure'
                    )][string]$Mode
                )

                InModuleScope Common -Parameters @{
                    Root = $Root
                    Manifest = $Manifest
                    StagedSource = $StagedSource
                    Mode = $Mode
                } {
                    $script:OpenPathRoot = $Root
                    $script:TestManifest = $Manifest
                    $script:TestStagedSource = $StagedSource
                    $script:TestMode = $Mode
                    $script:Captured = @{
                        Config              = $null
                        Integrity           = 0
                        Baseline            = 0
                        Tasks               = 0
                        Reports             = @()
                        GateCalls           = 0
                        ManifestRequests    = 0
                        WebRequests         = 0
                        ConfigWrites        = 0
                        StuckJournalBase64  = ''
                        SupersededBase64    = ''
                    }

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
                        if ($script:TestMode -eq 'download-failure') {
                            throw 'download failed'
                        }
                        Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
                    }
                    Mock Write-OpenPathLog { }
                    Mock Set-OpenPathConfig {
                        $script:Captured.ConfigWrites++
                        if ($script:TestMode -ne 'hash-mismatch-gate-failure' -and $script:Captured.ConfigWrites -eq 1) {
                            $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $script:OpenPathRoot
                            $script:Captured.StuckJournalBase64 = [Convert]::ToBase64String(
                                [System.IO.File]::ReadAllBytes($journalPath)
                            )
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
                        $supersededPath = Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $script:OpenPathRoot
                        if (Test-Path -LiteralPath $supersededPath -PathType Leaf) {
                            $script:Captured.SupersededBase64 = [Convert]::ToBase64String(
                                [System.IO.File]::ReadAllBytes($supersededPath)
                            )
                        }
                        [PSCustomObject]@{
                            Healthy  = [bool]($script:TestMode -eq 'success')
                            Message  = 'gate failed'
                            TimedOut = $false
                        }
                    }

                    if ($script:TestMode -eq 'replace-failure') {
                        Mock Copy-Item {
                            $supersededPath = Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $script:OpenPathRoot
                            if (Test-Path -LiteralPath $supersededPath -PathType Leaf) {
                                $script:Captured.SupersededBase64 = [Convert]::ToBase64String(
                                    [System.IO.File]::ReadAllBytes($supersededPath)
                                )
                            }
                            throw 'simulated interruption during replacement'
                        } -ParameterFilter {
                            $Destination -and [string]$Destination -match '\.openpath-update-'
                        }
                    }
                    if ($script:TestMode -eq 'incomplete-rollback') {
                        Mock Restore-OpenPathAgentUpdateJournalBackups {
                            [PSCustomObject]@{ Complete = $false; Errors = @('simulated incomplete rollback') }
                        }
                    }
                    if ($script:TestMode -eq 'save-failure') {
                        Mock Save-OpenPathAgentUpdateSupersededJournal {
                            throw 'simulated superseded journal failure'
                        }
                    }

                    $result = Invoke-OpenPathAgentSelfUpdate -Silent
                    [PSCustomObject]@{
                        Result   = $result
                        Captured = $script:Captured
                    }
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

        It "Restores the stuck journal after a replacement build fails the health gate" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('gate-replacement-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'published-target' -Encoding ASCII
            $publishedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $publishedHash })
            }

            $scenario = Invoke-SupersededReplacementScenario -Root $fixture.Root -Manifest $manifest `
                -StagedSource $stagedSource -Mode 'gate-failure'

            $scenario.Result.Success | Should -BeFalse
            (Get-Content -LiteralPath $fixture.Destination -Raw).Trim() | Should -Be 'stuck-target'
            $scenario.Captured.SupersededBase64 | Should -Not -BeNullOrEmpty

            $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
            $supersededPath = Join-Path $fixture.Root 'data/agent-update/superseded-update-journal.json'
            Test-Path -LiteralPath $journalPath | Should -BeTrue
            Test-Path -LiteralPath $supersededPath | Should -BeFalse
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be $scenario.Captured.SupersededBase64

            $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $journalOnDisk.phase | Should -Be 'committed'
            $journalOnDisk.targetBuild | Should -Be 'build-stuck'
            $journalOnDisk.finalizationAttempts | Should -Be 1

            $backupDirectories = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'data/agent-update/backups') -Directory)
            $backupDirectories.Count | Should -Be 1
            $backupDirectories[0].Name | Should -Be 'run-stuck'

            $record = Get-Content -LiteralPath (Join-Path $fixture.Root 'data/agent-update/failed-update.json') -Raw | ConvertFrom-Json
            $record.build | Should -Be 'build-published'
            $record.stage | Should -Be 'gate'
        }

        It "Restores the stuck journal after a replacement build fails during file replacement" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('replace-replacement-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'published-target' -Encoding ASCII
            $publishedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $publishedHash })
            }

            $scenario = Invoke-SupersededReplacementScenario -Root $fixture.Root -Manifest $manifest `
                -StagedSource $stagedSource -Mode 'replace-failure'

            $scenario.Result.Success | Should -BeFalse
            (Get-Content -LiteralPath $fixture.Destination -Raw).Trim() | Should -Be 'stuck-target'
            $scenario.Captured.SupersededBase64 | Should -Not -BeNullOrEmpty

            $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
            $supersededPath = Join-Path $fixture.Root 'data/agent-update/superseded-update-journal.json'
            Test-Path -LiteralPath $journalPath | Should -BeTrue
            Test-Path -LiteralPath $supersededPath | Should -BeFalse
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be $scenario.Captured.SupersededBase64

            $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $journalOnDisk.phase | Should -Be 'committed'
            $journalOnDisk.targetBuild | Should -Be 'build-stuck'

            $backupDirectories = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'data/agent-update/backups') -Directory)
            $backupDirectories.Count | Should -Be 1
            $backupDirectories[0].Name | Should -Be 'run-stuck'
        }

        It "Restores the stuck journal after a hash-mismatch reinstall fails the health gate" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'wrong-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('hash-reinstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'stuck-target' -Encoding ASCII
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-stuck'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $fixture.TargetHash })
            }

            $scenario = Invoke-SupersededReplacementScenario -Root $fixture.Root -Manifest $manifest `
                -StagedSource $stagedSource -Mode 'hash-mismatch-gate-failure'

            $scenario.Result.Success | Should -BeFalse
            (Get-Content -LiteralPath $fixture.Destination -Raw).Trim() | Should -Be 'wrong-target'
            $scenario.Captured.SupersededBase64 | Should -Not -BeNullOrEmpty

            $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
            $supersededPath = Join-Path $fixture.Root 'data/agent-update/superseded-update-journal.json'
            Test-Path -LiteralPath $journalPath | Should -BeTrue
            Test-Path -LiteralPath $supersededPath | Should -BeFalse
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be $scenario.Captured.SupersededBase64

            $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $journalOnDisk.phase | Should -Be 'committed'
            $journalOnDisk.targetBuild | Should -Be 'build-stuck'

            $record = Get-Content -LiteralPath (Join-Path $fixture.Root 'data/agent-update/failed-update.json') -Raw | ConvertFrom-Json
            $record.build | Should -Be 'build-stuck'
            $record.stage | Should -Be 'gate'
        }

        It "Removes the superseded journal when the replacement build finalizes successfully" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('success-replacement-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'published-target' -Encoding ASCII
            $publishedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $publishedHash })
            }

            $scenario = Invoke-SupersededReplacementScenario -Root $fixture.Root -Manifest $manifest `
                -StagedSource $stagedSource -Mode 'success'

            $scenario.Result.Success | Should -BeTrue
            $scenario.Result.Updated | Should -BeTrue
            (Get-Content -LiteralPath $fixture.Destination -Raw).Trim() | Should -Be 'published-target'
            $scenario.Captured.SupersededBase64 | Should -Not -BeNullOrEmpty
            $scenario.Captured.Config.version | Should -Be '9.9.9'
            $scenario.Captured.Config.agentBuild | Should -Be 'build-published'
            Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/update-journal.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/superseded-update-journal.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/failed-update.json') | Should -BeFalse

            $backupDirectories = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'data/agent-update/backups') -Directory)
            $backupDirectories.Count | Should -Be 1
            $backupDirectories[0].Name | Should -Not -Be 'run-stuck'
        }

        It "Leaves the stuck journal untouched when the replacement fails before its journal is written" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('download-replacement-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'published-target' -Encoding ASCII
            $publishedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $publishedHash })
            }

            $scenario = Invoke-SupersededReplacementScenario -Root $fixture.Root -Manifest $manifest `
                -StagedSource $stagedSource -Mode 'download-failure'

            $scenario.Result.Success | Should -BeFalse
            $scenario.Captured.StuckJournalBase64 | Should -Not -BeNullOrEmpty
            (Get-Content -LiteralPath $fixture.Destination -Raw).Trim() | Should -Be 'stuck-target'

            $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be $scenario.Captured.StuckJournalBase64
            Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/superseded-update-journal.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/failed-update.json') | Should -BeFalse

            $backupDirectories = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'data/agent-update/backups') -Directory)
            $backupDirectories.Count | Should -Be 1
            $backupDirectories[0].Name | Should -Be 'run-stuck'
        }

        It "Keeps the replacement journal and the superseded journal when the rollback is incomplete" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('incomplete-replacement-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'published-target' -Encoding ASCII
            $publishedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $publishedHash })
            }

            $scenario = Invoke-SupersededReplacementScenario -Root $fixture.Root -Manifest $manifest `
                -StagedSource $stagedSource -Mode 'incomplete-rollback'

            $scenario.Result.Success | Should -BeFalse
            $scenario.Captured.SupersededBase64 | Should -Not -BeNullOrEmpty

            $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
            $supersededPath = Join-Path $fixture.Root 'data/agent-update/superseded-update-journal.json'
            Test-Path -LiteralPath $journalPath | Should -BeTrue
            Test-Path -LiteralPath $supersededPath | Should -BeTrue
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($supersededPath)) |
                Should -Be $scenario.Captured.SupersededBase64

            $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $journalOnDisk.phase | Should -Be 'validating'
            $journalOnDisk.targetBuild | Should -Be 'build-published'
            Test-Path -LiteralPath ([string]$journalOnDisk.backupRoot) | Should -BeTrue
            (Get-Content -LiteralPath $fixture.Destination -Raw).Trim() | Should -Be 'published-target'
        }

        It "Aborts before any installed file changes when saving the superseded journal fails" {
            $fixture = New-StuckFinalizationFixture -InstalledContent 'stuck-target' -JournalTargetContent 'stuck-target' -TargetBuild 'build-stuck'
            $stagedSource = Join-Path $TestDrive ('save-failure-replacement-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $stagedSource -Value 'published-target' -Encoding ASCII
            $publishedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [PSCustomObject]@{
                version = '9.9.9'
                build   = 'build-published'
                files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $publishedHash })
            }

            $scenario = Invoke-SupersededReplacementScenario -Root $fixture.Root -Manifest $manifest `
                -StagedSource $stagedSource -Mode 'save-failure'

            $scenario.Result.Success | Should -BeFalse
            $scenario.Result.Message | Should -Match 'simulated superseded journal failure'
            $scenario.Captured.StuckJournalBase64 | Should -Not -BeNullOrEmpty
            $scenario.Captured.GateCalls | Should -Be 0
            (Get-Content -LiteralPath $fixture.Destination -Raw).Trim() | Should -Be 'stuck-target'

            $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be $scenario.Captured.StuckJournalBase64
            Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/superseded-update-journal.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/failed-update.json') | Should -BeFalse

            $backupDirectories = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'data/agent-update/backups') -Directory)
            $backupDirectories.Count | Should -Be 1
            $backupDirectories[0].Name | Should -Be 'run-stuck'
        }
    }

    Context "Self-update failed-run backup cleanup" {
        BeforeAll {
            Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
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

Describe "Self-update cut matrix" {
    BeforeAll {
        $script:WindowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $script:ModulePath = Join-Path $script:WindowsRoot 'lib/Common.psm1'
        $script:RecoveryScriptPath = Join-Path $script:WindowsRoot 'scripts/Recover-OpenPathAgentUpdate.ps1'
        $script:PwshPath = (Get-Process -Id $PID).Path

        $script:ChildUpdater = @'
param(
    [Parameter(Mandatory = $true)][string]$OpenPathRoot,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$StagedRoot,
    [Parameter(Mandatory = $true)][string]$ModulePath,
    [string]$CutPoint = 'none'
)
$ErrorActionPreference = 'Stop'
$env:OPENPATH_CUT_ROOT = $OpenPathRoot
$env:OPENPATH_CUT_MANIFEST = $ManifestPath
$env:OPENPATH_CUT_STAGED = $StagedRoot
$env:OPENPATH_CUT_POINT = $CutPoint
Import-Module $ModulePath -Force
& (Get-Module Common) {
    $script:OpenPathRoot = $env:OPENPATH_CUT_ROOT
    $script:Manifest = Get-Content -LiteralPath $env:OPENPATH_CUT_MANIFEST -Raw | ConvertFrom-Json
    $script:CutPoint = $env:OPENPATH_CUT_POINT

    Set-Item -Path 'function:script:Cut-Now' -Value { [Environment]::Exit(97) }
    Set-Item -Path 'function:script:Get-OpenPathConfig' -Value {
        [PSCustomObject]@{
            apiUrl       = 'https://api.test'
            whitelistUrl = 'https://api.test/w/token/whitelist.txt'
            version      = '9.9.8'
            agentBuild   = 'build-old'
        }
    }
    Set-Item -Path 'function:script:Get-OpenPathMachineTokenFromWhitelistUrl' -Value { 'token' }
    Set-Item -Path 'function:script:Invoke-RestMethod' -Value { $script:Manifest }
    Set-Item -Path 'function:script:Invoke-WebRequest' -Value {
        param($Uri, $Method, $Headers, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
        $relative = ($Uri -split '/files/')[1]
        $relative = ($relative -split '\?')[0]
        $relative = [System.Uri]::UnescapeDataString($relative)
        $source = Join-Path $env:OPENPATH_CUT_STAGED (($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar) -replace '\\', [System.IO.Path]::DirectorySeparatorChar)
        Copy-Item -LiteralPath $source -Destination $OutFile -Force
    }
    Set-Item -Path 'function:script:Write-OpenPathLog' -Value { param($Message, $Level) }
    Set-Item -Path 'function:script:Set-OpenPathConfig' -Value {
        param($Config)
        $configPath = Join-Path $env:OPENPATH_CUT_ROOT 'data/config.json'
        $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
        if ($script:CutPoint -eq 'config') { Cut-Now }
    }
    Set-Item -Path 'function:script:Save-OpenPathIntegrityBackup' -Value { }
    Set-Item -Path 'function:script:New-OpenPathIntegrityBaseline' -Value { }
    Set-Item -Path 'function:script:Restore-OpenPathProtectedMode' -Value { }
    Set-Item -Path 'function:script:Send-OpenPathHealthReport' -Value { }
    Set-Item -Path 'function:script:Invoke-OpenPathAgentUpdateHealthGate' -Value {
        [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false }
    }
    foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
        Set-Item -Path "function:script:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
    }

    switch ($script:CutPoint) {
        'intent' {
            Set-Item -Path 'function:script:Write-OpenPathAgentUpdateJournal' -Value { param($OpenPathRoot, $Journal) Cut-Now }
        }
        'before-swap' {
            Set-Item -Path 'function:script:Move-OpenPathAgentUpdateFileIntoPlace' -Value { param($TempPath, $DestinationPath) Cut-Now }
        }
        'after-first-swap' {
            Set-Item -Path 'function:script:Move-OpenPathAgentUpdateFileIntoPlace' -Value {
                param($TempPath, $DestinationPath)
                if ([System.IO.File]::Exists($DestinationPath)) {
                    [System.IO.File]::Replace($TempPath, $DestinationPath, "$TempPath.bak", $true)
                }
                else {
                    [System.IO.File]::Move($TempPath, $DestinationPath)
                }
                Cut-Now
            }
        }
        'validating' {
            Set-Item -Path 'function:script:Update-OpenPathAgentUpdateJournalPhase' -Value {
                param($OpenPathRoot, $Journal, $Phase)
                if ($Phase -eq 'validating') { Cut-Now }
                $Journal.phase = $Phase
                $Journal.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                Write-OpenPathAgentUpdateJournal -OpenPathRoot $OpenPathRoot -Journal $Journal
            }
        }
        'gate' {
            Set-Item -Path 'function:script:Invoke-OpenPathAgentUpdateHealthGate' -Value { Cut-Now }
        }
        'marker' {
            Set-Item -Path 'function:script:Write-OpenPathAgentUpdateCommittedMarker' -Value { param($BackupRoot, $RunId, $TargetVersion, $TargetBuild) Cut-Now }
        }
        'committed' {
            Set-Item -Path 'function:script:Update-OpenPathAgentUpdateJournalPhase' -Value {
                param($OpenPathRoot, $Journal, $Phase)
                $Journal.phase = $Phase
                $Journal.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                Write-OpenPathAgentUpdateJournal -OpenPathRoot $OpenPathRoot -Journal $Journal
                if ($Phase -eq 'committed') { Cut-Now }
            }
        }
        'finalization' {
            Set-Item -Path 'function:script:Complete-OpenPathAgentUpdateFinalization' -Value { param($OpenPathRoot, $Journal, $Config) Cut-Now }
        }
        'journal-removal' {
            Set-Item -Path 'function:script:Remove-OpenPathAgentUpdateJournal' -Value { param($OpenPathRoot) Cut-Now }
        }
    }

    Invoke-OpenPathAgentSelfUpdate -Silent | Out-Null
}

'@

        function New-CutFixture {
        $root = Join-Path $TestDrive ('cut-' + [guid]::NewGuid().ToString('N'))
        $stagedRoot = Join-Path $TestDrive ('cut-staged-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $stagedRoot 'lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Value 'Write-Output "old-a"' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root 'lib/b.ps1') -Value 'Write-Output "old-b"' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $stagedRoot 'lib/a.ps1') -Value 'Write-Output "new-a"' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $stagedRoot 'lib/b.ps1') -Value 'Write-Output "new-b"' -Encoding ASCII
        [PSCustomObject]@{
            version = '9.9.9'
            build   = 'build-new'
            files   = @(
                [PSCustomObject]@{ path = 'lib/a.ps1'; sha256 = (Get-FileHash -LiteralPath (Join-Path $stagedRoot 'lib/a.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() },
                [PSCustomObject]@{ path = 'lib/b.ps1'; sha256 = (Get-FileHash -LiteralPath (Join-Path $stagedRoot 'lib/b.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding UTF8
        [PSCustomObject]@{
            version    = '9.9.8'
            agentBuild = 'build-old'
            apiUrl     = 'https://api.test'
            whitelistUrl = 'https://api.test/w/token/whitelist.txt'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'data/config.json') -Encoding UTF8
        return [PSCustomObject]@{ Root = $root; StagedRoot = $stagedRoot; Manifest = (Join-Path $root 'manifest.json') }
        }

        function Invoke-CutChild {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [string]$CutPoint = 'none'
        )

        $scriptPath = Join-Path $Fixture.Root "cut-$CutPoint.ps1"
        Set-Content -LiteralPath $scriptPath -Value $script:ChildUpdater -Encoding UTF8
        $output = & $script:PwshPath -NoProfile -NonInteractive -File $scriptPath `
            -OpenPathRoot $Fixture.Root `
            -ManifestPath $Fixture.Manifest `
            -StagedRoot $Fixture.StagedRoot `
            -ModulePath $script:ModulePath `
            -CutPoint $CutPoint 2>&1
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join [Environment]::NewLine) }
    }

    function Invoke-RecoveryChild {
        param([Parameter(Mandatory = $true)]$Fixture)

        $output = & $script:PwshPath -NoProfile -NonInteractive -File $script:RecoveryScriptPath -OpenPathRoot $Fixture.Root 2>&1
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join [Environment]::NewLine) }
    }

    function Get-SingleBuild {
        param([Parameter(Mandatory = $true)]$Fixture)

        $a = (Get-Content -LiteralPath (Join-Path $Fixture.Root 'lib/a.ps1') -Raw).Trim()
        $b = (Get-Content -LiteralPath (Join-Path $Fixture.Root 'lib/b.ps1') -Raw).Trim()
        $build = if ($a -match 'old') { 'old' } elseif ($a -match 'new') { 'new' } else { 'invalid' }
        $matches = if ($build -eq 'old') { ($b -match 'old') } elseif ($build -eq 'new') { ($b -match 'new') } else { $false }
        return [PSCustomObject]@{ Build = $build; Consistent = [bool]$matches; A = $a; B = $b }
        }
    }

    It "Leaves a single-build tree and matching config after a cut at <Point>" -ForEach @(
        @{ Point = 'intent' }
        @{ Point = 'before-swap' }
        @{ Point = 'after-first-swap' }
        @{ Point = 'validating' }
        @{ Point = 'gate' }
        @{ Point = 'marker' }
        @{ Point = 'committed' }
        @{ Point = 'finalization' }
        @{ Point = 'config' }
        @{ Point = 'journal-removal' }
    ) {
        $fixture = New-CutFixture
        $cut = Invoke-CutChild -Fixture $fixture -CutPoint $Point
        $cut.ExitCode | Should -Be 97 -Because $cut.Output

        $recovery = Invoke-RecoveryChild -Fixture $fixture
        $recovery.ExitCode | Should -Be 0 -Because $recovery.Output

        $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
        $statePath = Join-Path $fixture.Root 'data/agent-update/recovery-state.json'
        $needsFinalization = (Test-Path -LiteralPath $journalPath) -or (Test-Path -LiteralPath $statePath)
        if ($needsFinalization) {
            $finish = Invoke-CutChild -Fixture $fixture -CutPoint 'none'
            $finish.ExitCode | Should -Be 0 -Because $finish.Output
        }

        $tree = Get-SingleBuild -Fixture $fixture
        $tree.Consistent | Should -BeTrue -Because "tree was A=$($tree.A) B=$($tree.B)"
        $config = Get-Content -LiteralPath (Join-Path $fixture.Root 'data/config.json') -Raw | ConvertFrom-Json
        if ($tree.Build -eq 'new') {
            $config.version | Should -Be '9.9.9'
            $config.agentBuild | Should -Be 'build-new'
        }
        else {
            $config.version | Should -Be '9.9.8'
            $config.agentBuild | Should -Be 'build-old'
        }

        $updateRoot = Join-Path $fixture.Root 'data/agent-update'
        Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $updateRoot 'recovery-state.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -File -Filter '*.openpath-update-*.tmp' -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -File -Filter 'journal-intent.json' -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -File -Filter 'committed.marker' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It "Rolls back from the intent when the journal is zero-filled at full length" {
        $fixture = New-CutFixture
        $cut = Invoke-CutChild -Fixture $fixture -CutPoint 'after-first-swap'
        $cut.ExitCode | Should -Be 97 -Because $cut.Output
        $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
        [System.IO.File]::WriteAllBytes($journalPath, (New-Object byte[] 47241))

        $recovery = Invoke-RecoveryChild -Fixture $fixture
        $recovery.ExitCode | Should -Be 0 -Because $recovery.Output

        $tree = Get-SingleBuild -Fixture $fixture
        $tree.Build | Should -Be 'old'
        $tree.Consistent | Should -BeTrue
        $report = Get-Content -LiteralPath (Join-Path $fixture.Root 'data/agent-update/recovery-report.json') -Raw | ConvertFrom-Json
        $report.reasonCode | Should -Match 'self_update_recovery_rolled_back'
    }

    It "Repairs to the published build when the journal and the intent are zero-filled" {
        $fixture = New-CutFixture
        $cut = Invoke-CutChild -Fixture $fixture -CutPoint 'after-first-swap'
        $cut.ExitCode | Should -Be 97 -Because $cut.Output
        $journalPath = Join-Path $fixture.Root 'data/agent-update/update-journal.json'
        [System.IO.File]::WriteAllBytes($journalPath, (New-Object byte[] 47241))
        $intentPath = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'data/agent-update/backups') -Recurse -File -Filter 'journal-intent.json')[0].FullName
        [System.IO.File]::WriteAllBytes($intentPath, (New-Object byte[] 47241))

        $recovery = Invoke-RecoveryChild -Fixture $fixture
        $recovery.ExitCode | Should -Be 0 -Because $recovery.Output
        Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/recovery-state.json') | Should -BeTrue

        $repair = Invoke-CutChild -Fixture $fixture -CutPoint 'none'
        $repair.ExitCode | Should -Be 0 -Because $repair.Output

        $tree = Get-SingleBuild -Fixture $fixture
        $tree.Build | Should -Be 'new'
        $tree.Consistent | Should -BeTrue
        $config = Get-Content -LiteralPath (Join-Path $fixture.Root 'data/config.json') -Raw | ConvertFrom-Json
        $config.version | Should -Be '9.9.9'
        $config.agentBuild | Should -Be 'build-new'
        Test-Path -LiteralPath (Join-Path $fixture.Root 'data/agent-update/recovery-state.json') | Should -BeFalse
    }
}

Describe "Self-update repair timing with a backward clock" {
    BeforeAll {
        Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
    }

    It "Allows the first repair when lastRepairAt is one hour in the future" {
        InModuleScope Common {
            $now = [DateTimeOffset]::Parse('2026-11-15T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            $state = [PSCustomObject]@{
                repairAttempts = 0
                lastRepairAt   = $now.AddHours(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }

            $decision = Test-OpenPathAgentUpdateRepairAllowed -State $state -Now $now

            $decision.Allowed | Should -BeTrue
            $decision.RequiredMinutes | Should -Be 10
            $decision.WaitedMinutes | Should -Be ([double]::PositiveInfinity)
        }
    }

    It "Allows the daily repair when lastRepairAt is one hour in the future after three repairs" {
        InModuleScope Common {
            $now = [DateTimeOffset]::Parse('2026-11-15T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            $state = [PSCustomObject]@{
                repairAttempts = 3
                lastRepairAt   = $now.AddHours(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }

            $decision = Test-OpenPathAgentUpdateRepairAllowed -State $state -Now $now

            $decision.Allowed | Should -BeTrue
            $decision.RequiredMinutes | Should -Be 1440
            $decision.WaitedMinutes | Should -Be ([double]::PositiveInfinity)
        }
    }

    It "Keeps the wait for a timestamp only seconds in the future" {
        InModuleScope Common {
            $now = [DateTimeOffset]::Parse('2026-11-15T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            $state = [PSCustomObject]@{
                repairAttempts = 0
                lastRepairAt   = $now.AddSeconds(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }

            $decision = Test-OpenPathAgentUpdateRepairAllowed -State $state -Now $now

            $decision.Allowed | Should -BeFalse
            $decision.WaitedMinutes | Should -Be 0
        }
    }

    It "Keeps the ten-minute wait when the clock stays behind and does not loop" {
        InModuleScope Common {
            $slowNow = [DateTimeOffset]::Parse('2026-11-14T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            $state = [PSCustomObject]@{
                repairAttempts = 0
                lastRepairAt   = $slowNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }

            $early = Test-OpenPathAgentUpdateRepairAllowed -State $state -Now $slowNow.AddMinutes(9)
            $due = Test-OpenPathAgentUpdateRepairAllowed -State $state -Now $slowNow.AddMinutes(10)

            $early.Allowed | Should -BeFalse
            $due.Allowed | Should -BeTrue
        }
    }
}

Describe "Canary self-update" {
    BeforeAll {
        Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "lib") "Common.psm1") -Force -Global
    }

    It "pins the manifest build on every file request and advertises signed-release support" {
        $root = Join-Path $TestDrive ('canary-pin-' + [guid]::NewGuid().ToString('N'))
        $destination = Join-Path $root 'lib/existing.ps1'
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII

        $stagedSource = Join-Path $TestDrive ('pin-' + [guid]::NewGuid().ToString('N') + '.ps1')
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
            $script:Captured = @{ ManifestHeaders = $null; FileUris = @() }
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
                param($Uri, $Method, $Headers, $TimeoutSec, $ErrorAction)
                $script:Captured.ManifestHeaders = $Headers
                $script:TestManifest
            }
            Mock Invoke-WebRequest {
                param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                $script:Captured.FileUris += $Uri
                Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
            }
            Mock Write-OpenPathLog { }
            Mock Set-OpenPathConfig { }
            Mock Save-OpenPathIntegrityBackup { }
            Mock New-OpenPathIntegrityBaseline { }
            Mock Restore-OpenPathProtectedMode { }
            Mock Send-OpenPathHealthReport { }
            Mock Invoke-OpenPathAgentUpdateHealthGate { [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false } }
            foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                    Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                }
            }
            Mock Register-OpenPathTask { }
            Mock Enable-OpenPathTask { }
            Mock Start-OpenPathTask { }

            $result = Invoke-OpenPathAgentSelfUpdate -Silent

            $result.Success | Should -BeTrue
            $script:Captured.ManifestHeaders['X-OpenPath-Agent-Capabilities'] | Should -Be 'signed-release-v1'
            $script:Captured.FileUris.Count | Should -Be 1
            $script:Captured.FileUris[0] | Should -Match ([regex]::Escape('?build=build-new'))
        }
    }

    It "aborts on HTTP 409 without replacing a file and without recording a failed build" {
        $root = Join-Path $TestDrive ('canary-409-' + [guid]::NewGuid().ToString('N'))
        $destination = Join-Path $root 'lib/existing.ps1'
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $destination -Value 'Write-Output "old"' -Encoding ASCII

        $stagedSource = Join-Path $TestDrive ('conflict-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $stagedSource -Value 'Write-Output "new"' -Encoding ASCII
        $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = [PSCustomObject]@{
            version = '9.9.9'
            build   = 'build-retiring'
            files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
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
            Mock Invoke-WebRequest {
                $response = [PSCustomObject]@{ StatusCode = 409 }
                $exception = New-Object System.Exception('conflict')
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
                throw $exception
            }
            Mock Write-OpenPathLog { }
            Mock Send-OpenPathHealthReport { }

            $result = Invoke-OpenPathAgentSelfUpdate -Silent

            $result.Success | Should -BeFalse
            $result.Message | Should -Match '409'
            (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "old"'
            Test-Path -LiteralPath (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $Root) | Should -BeFalse
            Test-Path -LiteralPath (Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $Root) | Should -BeFalse
        }
    }

    It "skips a machine that is not on the canary ring in canary-only mode" {
        $root = Join-Path $TestDrive ('canary-only-' + [guid]::NewGuid().ToString('N'))
        $manifest = [PSCustomObject]@{
            version = '9.9.9'
            build   = 'build-stable'
            files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = ('a' * 64) })
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
            Mock Invoke-WebRequest { throw 'the stable build must not be downloaded in canary-only mode' }
            Mock Write-OpenPathLog { }

            $result = Invoke-OpenPathAgentSelfUpdate -Silent -CanaryOnly

            $result.Success | Should -BeTrue
            $result.Updated | Should -BeFalse
            $result.Message | Should -Match 'not on the canary ring'
        }
    }

    It "checks the ring first and does nothing else on a non-canary machine" {
        $root = Join-Path $TestDrive ('canary-first-' + [guid]::NewGuid().ToString('N'))
        $manifest = [PSCustomObject]@{
            version = '9.9.9'
            build   = 'build-stable'
            files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = ('a' * 64) })
        }

        InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest } {
            $script:OpenPathRoot = $Root
            $script:TestManifest = $Manifest
            # A superseded journal and a committed journal would normally be
            # restored and finalized before the manifest is read.
            $updateRoot = Join-Path (Join-Path $Root 'data') 'agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            Set-Content -LiteralPath (Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $Root) -Value '{"schemaVersion":2,"phase":"committed"}' -Encoding ASCII
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
            Mock Invoke-WebRequest { throw 'no file may be requested on a stable machine' }
            Mock Restore-OpenPathAgentUpdateSupersededJournal { throw 'the superseded journal must not be touched' }
            Mock Complete-OpenPathAgentUpdateFinalization { throw 'no finalization may run' }
            Mock Enter-OpenPathAgentUpdateLock { throw 'the update lock must not be taken' }
            Mock Write-OpenPathLog { }

            $result = Invoke-OpenPathAgentSelfUpdate -Silent -CanaryOnly

            $result.Success | Should -BeTrue
            $result.Updated | Should -BeFalse
            $result.Message | Should -Match 'not on the canary ring'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
            Should -Invoke Restore-OpenPathAgentUpdateSupersededJournal -Times 0 -Exactly
            Should -Invoke Enter-OpenPathAgentUpdateLock -Times 0 -Exactly
            Test-Path -LiteralPath (Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $Root) | Should -BeTrue
        }
    }

    It "records the canary ring when a canary release is installed" {
        $root = Join-Path $TestDrive ('canary-ring-' + [guid]::NewGuid().ToString('N'))
        $destination = Join-Path $root 'lib/existing.ps1'
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $destination -Value 'Write-Output "stable"' -Encoding ASCII

        $stagedSource = Join-Path $TestDrive ('canary-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $stagedSource -Value 'Write-Output "canary"' -Encoding ASCII
        $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = [PSCustomObject]@{
            version   = '9.9.8'
            build     = 'build-canary'
            ring      = 'canary'
            sourceSha = ('a' * 40)
            signature = 'signed'
            files     = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
        }

        InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; StagedSource = $stagedSource } {
            $script:OpenPathRoot = $Root
            $script:TestManifest = $Manifest
            $script:TestStagedSource = $StagedSource
            $script:SavedConfigs = @()
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    apiUrl       = 'https://api.test'
                    whitelistUrl = 'https://api.test/w/token/whitelist.txt'
                    version      = '9.9.8'
                    agentBuild   = 'build-stable'
                }
            }
            Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
            Mock Test-OpenPathAgentReleaseSignature { $true }
            Mock Invoke-RestMethod { $script:TestManifest }
            Mock Invoke-WebRequest {
                param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
            }
            Mock Write-OpenPathLog { }
            Mock Set-OpenPathConfig { param($Config) $script:SavedConfigs += ($Config | ConvertTo-Json -Compress) }
            Mock Save-OpenPathIntegrityBackup { }
            Mock New-OpenPathIntegrityBaseline { }
            Mock Restore-OpenPathProtectedMode { }
            Mock Send-OpenPathHealthReport { }
            Mock Invoke-OpenPathAgentUpdateHealthGate { [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false } }
            foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                    Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                }
            }
            Mock Register-OpenPathTask { }
            Mock Enable-OpenPathTask { }
            Mock Start-OpenPathTask { }

            $result = Invoke-OpenPathAgentSelfUpdate -Silent -CanaryOnly

            $result.Success | Should -BeTrue
            $result.Updated | Should -BeTrue
            $saved = $script:SavedConfigs[-1] | ConvertFrom-Json
            $saved.agentBuild | Should -Be 'build-canary'
            $saved.agentReleaseRing | Should -Be 'canary'
        }
    }

    It "returns a retired canary to the stable build in canary-only mode, without the nightly task" {
        $root = Join-Path $TestDrive ('canary-retired-' + [guid]::NewGuid().ToString('N'))
        $destination = Join-Path $root 'lib/existing.ps1'
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $destination -Value 'Write-Output "canary"' -Encoding ASCII

        $stagedSource = Join-Path $TestDrive ('stable-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $stagedSource -Value 'Write-Output "stable"' -Encoding ASCII
        $stagedHash = (Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
        # After the retire the server serves this canary-ring machine the stable
        # manifest: same version, different build, no ring.
        $manifest = [PSCustomObject]@{
            version = '9.9.8'
            build   = 'build-stable'
            files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = $stagedHash })
        }

        InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest; StagedSource = $stagedSource } {
            $script:OpenPathRoot = $Root
            $script:TestManifest = $Manifest
            $script:TestStagedSource = $StagedSource
            $script:SavedConfigs = @()
            $script:FileUris = @()
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    apiUrl           = 'https://api.test'
                    whitelistUrl     = 'https://api.test/w/token/whitelist.txt'
                    version          = '9.9.8'
                    agentBuild       = 'build-canary'
                    agentReleaseRing = 'canary'
                }
            }
            Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
            Mock Invoke-RestMethod { $script:TestManifest }
            Mock Invoke-WebRequest {
                param($Uri, $Method, $Headers, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction)
                $script:FileUris += $Uri
                Copy-Item -LiteralPath $script:TestStagedSource -Destination $OutFile -Force
            }
            Mock Write-OpenPathLog { }
            Mock Set-OpenPathConfig { param($Config) $script:SavedConfigs += ($Config | ConvertTo-Json -Compress) }
            Mock Save-OpenPathIntegrityBackup { }
            Mock New-OpenPathIntegrityBaseline { }
            Mock Restore-OpenPathProtectedMode { }
            Mock Send-OpenPathHealthReport { }
            Mock Invoke-OpenPathAgentUpdateHealthGate { [PSCustomObject]@{ Healthy = $true; Message = ''; TimedOut = $false } }
            foreach ($commandName in @('Register-OpenPathTask', 'Enable-OpenPathTask', 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure', 'Register-OpenPathFirefoxNativeHost', 'Start-OpenPathTask')) {
                if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                    Set-Item -Path "function:$commandName" -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
                }
            }
            Mock Register-OpenPathTask { }
            Mock Enable-OpenPathTask { }
            Mock Start-OpenPathTask { }

            $result = Invoke-OpenPathAgentSelfUpdate -Silent -CanaryOnly

            $result.Success | Should -BeTrue
            $result.Updated | Should -BeTrue
            $script:FileUris[0] | Should -Match ([regex]::Escape('?build=build-stable'))
            (Get-Content -LiteralPath (Join-Path $Root 'lib/existing.ps1') -Raw).Trim() | Should -Be 'Write-Output "stable"'
            $saved = $script:SavedConfigs[-1] | ConvertFrom-Json
            $saved.agentBuild | Should -Be 'build-stable'
            $saved.agentReleaseRing | Should -Be 'stable'
            Should -Invoke New-OpenPathIntegrityBaseline -Times 1 -Exactly
        }
    }

    It "keeps the seven-day backoff when the stable build already failed on a retired canary" {
        $root = Join-Path $TestDrive ('canary-backoff-' + [guid]::NewGuid().ToString('N'))
        $manifest = [PSCustomObject]@{
            version = '9.9.8'
            build   = 'build-stable'
            files   = @([PSCustomObject]@{ path = 'lib/existing.ps1'; sha256 = ('a' * 64) })
        }

        InModuleScope Common -Parameters @{ Root = $root; Manifest = $manifest } {
            $script:OpenPathRoot = $Root
            $script:TestManifest = $Manifest
            New-Item -ItemType Directory -Path (Join-Path (Join-Path $Root 'data') 'agent-update') -Force | Out-Null
            Save-OpenPathAgentUpdateFailureRecord -OpenPathRoot $Root -Version '9.9.8' -Build 'build-stable' -Stage 'gate' -Message 'previous failure'
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    apiUrl           = 'https://api.test'
                    whitelistUrl     = 'https://api.test/w/token/whitelist.txt'
                    version          = '9.9.8'
                    agentBuild       = 'build-canary'
                    agentReleaseRing = 'canary'
                }
            }
            Mock Get-OpenPathMachineTokenFromWhitelistUrl { 'token' }
            Mock Invoke-RestMethod { $script:TestManifest }
            Mock Invoke-WebRequest { throw 'a build inside its failure backoff must not be downloaded' }
            Mock Write-OpenPathLog { }

            $result = Invoke-OpenPathAgentSelfUpdate -Silent -CanaryOnly

            $result.Success | Should -BeTrue
            $result.Updated | Should -BeFalse
            $result.Message | Should -Match 'previously failed'
        }
    }

    It "reads the HTTP status from an HttpStatusCode enum" {
        InModuleScope Common {
            $response = [PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]::Conflict }
            $exception = New-Object System.Exception('conflict')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
            $record = New-Object System.Management.Automation.ErrorRecord($exception, 'test', 'NotSpecified', $null)

            Get-OpenPathAgentUpdateHttpStatusCode -ErrorRecord $record | Should -Be 409
        }
    }
}
