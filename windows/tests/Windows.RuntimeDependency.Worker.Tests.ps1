Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Runtime dependency worker" {
    BeforeAll {
        $repoLib = Join-Path $PSScriptRoot ".." "lib"
        $internalLib = Join-Path $repoLib "internal"

        $previousOpenPathRoot = $script:OpenPathRoot
        . (Join-Path $internalLib "CapabilityStorage.ps1")
        . (Join-Path $internalLib "RuntimeDependency.Worker.ps1")

        $queuePath = Join-Path $TestDrive 'runtime-dependency-queue'
        New-Item -ItemType Directory -Path $queuePath -Force | Out-Null
        $statePath = Join-Path $TestDrive 'worker-state.json'
    }

    AfterAll {
        $script:OpenPathRoot = $previousOpenPathRoot
    }

    Context "Worker heartbeat" {
        It "round-trips a fresh heartbeat and keeps the state fields" {
            Write-OpenPathRuntimeDependencyWorkerState -State @{ pid = 4242; cycles = 7 } -StatePath $statePath -SkipReadAccess |
                Should -BeTrue

            Test-Path $statePath | Should -BeTrue
            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $statePath -MaxAgeSeconds 10 | Should -BeTrue

            $parsed = Get-Content $statePath -Raw | ConvertFrom-Json
            $parsed.pid | Should -Be 4242
            $parsed.cycles | Should -Be 7
            $parsed.heartbeatEpochMs | Should -BeGreaterThan 0
        }

        It "treats stale, missing, and malformed state as not fresh" {
            $stalePath = Join-Path $TestDrive 'stale.json'
            $stale = @{
                heartbeatEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-60).ToUnixTimeMilliseconds()
            } | ConvertTo-Json
            Set-Content -Path $stalePath -Value $stale -Encoding UTF8
            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $stalePath -MaxAgeSeconds 10 | Should -BeFalse

            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath (Join-Path $TestDrive 'missing.json') | Should -BeFalse

            $malformedPath = Join-Path $TestDrive 'malformed.json'
            Set-Content -Path $malformedPath -Value 'not-json{' -Encoding UTF8
            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $malformedPath | Should -BeFalse
        }

        It "accepts an ISO heartbeat timestamp when the epoch field is absent" {
            $isoPath = Join-Path $TestDrive 'iso.json'
            $iso = @{
                heartbeatAt = [DateTimeOffset]::UtcNow.AddSeconds(-2).ToString('o')
            } | ConvertTo-Json
            Set-Content -Path $isoPath -Value $iso -Encoding UTF8
            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $isoPath -MaxAgeSeconds 10 | Should -BeTrue
        }

        It "treats a recent busy mark as alive while a long batch is applying" {
            $busyPath = Join-Path $TestDrive 'busy.json'
            # An in-flight 30 s batch does not refresh the idle heartbeat every few
            # seconds; the fresh busy mark must keep the native host from falling
            # back to the scheduled task.
            $state = @{
                heartbeatEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-25).ToUnixTimeMilliseconds()
                busySince = [DateTimeOffset]::UtcNow.AddSeconds(-5).ToString('o')
                busySinceEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeMilliseconds()
                busyStage = 'acrylic-reload'
            } | ConvertTo-Json
            Set-Content -Path $busyPath -Value $state -Encoding UTF8

            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $busyPath -MaxAgeSeconds 10 -BusyMaxAgeSeconds 120 | Should -BeTrue
            # Beyond the busy window the worker is not considered alive either.
            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $busyPath -MaxAgeSeconds 10 -BusyMaxAgeSeconds 2 | Should -BeFalse
        }

        It "marks the worker busy without discarding the recorded state fields" {
            $busyStatePath = Join-Path $TestDrive 'busy-state.json'
            Write-OpenPathRuntimeDependencyWorkerState -State @{ pid = 1234; cycles = 9; applied = 2 } -StatePath $busyStatePath -SkipReadAccess | Out-Null

            # Age the heartbeat so the busy refresh is observable.
            $aged = Get-Content $busyStatePath -Raw | ConvertFrom-Json
            $aged.heartbeatEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-40).ToUnixTimeMilliseconds()
            $aged.heartbeatAt = [DateTimeOffset]::UtcNow.AddSeconds(-40).ToString('o')
            $aged | ConvertTo-Json -Depth 6 | Set-Content -Path $busyStatePath -Encoding UTF8

            Set-OpenPathRuntimeDependencyWorkerBusyState -StatePath $busyStatePath -Stage 'acrylic-reload' | Should -BeTrue
            $first = Get-Content $busyStatePath -Raw | ConvertFrom-Json
            $first.pid | Should -Be 1234
            $first.cycles | Should -Be 9
            $first.applied | Should -Be 2
            $first.busyStage | Should -Be 'acrylic-reload'
            $first.busySince | Should -Not -BeNullOrEmpty
            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $busyStatePath -MaxAgeSeconds 10 -BusyMaxAgeSeconds 120 | Should -BeTrue

            # A later stage refresh keeps the original busySince and advances the stage.
            $busySince = [string]$first.busySince
            Set-OpenPathRuntimeDependencyWorkerBusyState -StatePath $busyStatePath -Stage 'generation-stamp' | Should -BeTrue
            $second = Get-Content $busyStatePath -Raw | ConvertFrom-Json
            $second.busySince | Should -Be $busySince
            $second.busyStage | Should -Be 'generation-stamp'
            [long]$second.heartbeatEpochMs | Should -BeGreaterOrEqual ([long]$first.heartbeatEpochMs)
        }
    }

    Context "Apply retry" {
        It "retries while the update mutex is busy and never drops the queued batch" {
            $retryQueue = Join-Path $TestDrive 'retry-queue'
            New-Item -ItemType Directory -Path $retryQueue -Force | Out-Null
            Set-Content -Path (Join-Path $retryQueue 'request-1.json') -Value '{}' -Encoding UTF8

            $script:applyCalls = 0
            $apply = {
                $script:applyCalls++
                if ($script:applyCalls -lt 3) {
                    return @{ ExitCode = 1; LockBusy = $true }
                }
                return @{ ExitCode = 0; LockBusy = $false }
            }

            $result = Invoke-OpenPathRuntimeDependencyWorkerApply `
                -ApplyAction $apply `
                -QueuePath $retryQueue `
                -RetryDelayMs 10

            $script:applyCalls | Should -Be 3
            $result.ExitCode | Should -Be 0
            $result.WorkerRetries | Should -Be 2
        }

        It "returns the busy result without spinning when the queue is already empty" {
            $emptyQueue = Join-Path $TestDrive 'empty-queue'
            New-Item -ItemType Directory -Path $emptyQueue -Force | Out-Null
            $script:emptyCalls = 0
            $apply = {
                $script:emptyCalls++
                return @{ ExitCode = 1; LockBusy = $true }
            }

            $result = Invoke-OpenPathRuntimeDependencyWorkerApply `
                -ApplyAction $apply `
                -QueuePath $emptyQueue `
                -RetryDelayMs 10

            $script:emptyCalls | Should -Be 1
            $result.LockBusy | Should -BeTrue
        }
    }

    Context "Worker loop" {
        It "applies a queued batch and records the heartbeat state" {
            $loopQueue = Join-Path $TestDrive 'loop-queue'
            New-Item -ItemType Directory -Path $loopQueue -Force | Out-Null
            Set-Content -Path (Join-Path $loopQueue 'request-1.json') -Value '{}' -Encoding UTF8
            $loopState = Join-Path $TestDrive 'loop-state.json'

            $script:loopApplyCount = 0
            $apply = {
                $script:loopApplyCount++
                return @{ ExitCode = 0; LockBusy = $false }
            }

            Start-OpenPathRuntimeDependencyWorker `
                -QueuePath $loopQueue `
                -StatePath $loopState `
                -ApplyAction $apply `
                -Once `
                -DebounceMs 10 `
                -WatcherTimeoutMs 100 | Should -Be 0

            $script:loopApplyCount | Should -Be 1
            $state = Get-Content $loopState -Raw | ConvertFrom-Json
            $state.lastResult | Should -Be 'applied'
            $state.cycles | Should -Be 1
        }

        It "returns after one cycle on an empty queue and still heartbeats" {
            $emptyLoopQueue = Join-Path $TestDrive 'empty-loop-queue'
            New-Item -ItemType Directory -Path $emptyLoopQueue -Force | Out-Null
            $emptyState = Join-Path $TestDrive 'empty-state.json'

            $script:emptyApplyCount = 0
            Start-OpenPathRuntimeDependencyWorker `
                -QueuePath $emptyLoopQueue `
                -StatePath $emptyState `
                -ApplyAction { $script:emptyApplyCount++; return @{ ExitCode = 0; LockBusy = $false } } `
                -Once `
                -WatcherTimeoutMs 100 | Should -Be 0

            $script:emptyApplyCount | Should -Be 0
            Test-OpenPathRuntimeDependencyWorkerFresh -StatePath $emptyState -MaxAgeSeconds 10 | Should -BeTrue
        }

        It "writes a heartbeat before invoking the apply action" {
            # Runtime-probing this ordering through the worker loop fights Pester scoping;
            # assert the source ordering instead: the in-flight heartbeat write must come
            # before the apply action call so the native host never sees a stale worker
            # while a batch is being applied.
            $workerContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "RuntimeDependency.Worker.ps1") -Raw
            $heartbeatIndex = $workerContent.IndexOf("`$state['lastResult'] = 'applying'")
            $applyIndex = $workerContent.IndexOf('$applyResult = Invoke-OpenPathRuntimeDependencyWorkerApply')
            $heartbeatIndex | Should -BeGreaterThan 0
            $applyIndex | Should -BeGreaterThan $heartbeatIndex
        }

        It "logs the oldest queue file age when it detects a batch" {
            $ageQueue = Join-Path $TestDrive 'age-queue'
            New-Item -ItemType Directory -Path $ageQueue -Force | Out-Null
            Set-Content -Path (Join-Path $ageQueue 'request-age.json') -Value '{}' -Encoding UTF8
            $ageState = Join-Path $TestDrive 'age-state.json'

            $script:capturedWorkerLogs = @()
            function Write-OpenPathLog {
                param([string]$Message, [string]$Level = 'INFO')
                $script:capturedWorkerLogs += [string]$Message
            }

            try {
                Start-OpenPathRuntimeDependencyWorker `
                    -QueuePath $ageQueue `
                    -StatePath $ageState `
                    -ApplyAction { return @{ ExitCode = 0; LockBusy = $false } } `
                    -Once `
                    -DebounceMs 10 `
                    -WatcherTimeoutMs 100 | Should -Be 0
            }
            finally {
                Remove-Item Function:\Write-OpenPathLog -ErrorAction SilentlyContinue
            }

            $detected = @($script:capturedWorkerLogs | Where-Object { $_ -match 'detected 1 queue file' })
            $detected.Count | Should -Be 1
            $detected[0] | Should -Match 'queueFileAgeMs=\d+'
        }
    }

    Context "Worker prewarm" {
        It "runs every prewarm stage with read-only doubles and logs stage=prewarm" {
            $prewarmRoot = Join-Path $TestDrive 'prewarm-root'
            $prewarmData = Join-Path $prewarmRoot 'data'
            New-Item -ItemType Directory -Path $prewarmData -Force | Out-Null
            $prewarmWhitelist = Join-Path $prewarmData 'whitelist.txt'
            Set-Content -Path $prewarmWhitelist -Value "## WHITELIST`nreddit.com`n" -Encoding UTF8

            $script:prewarmCalls = @()
            $prewarmNativeRoot = Join-Path $TestDrive 'prewarm-native'
            New-Item -ItemType Directory -Path $prewarmNativeRoot -Force | Out-Null
            Set-Content -Path (Join-Path $prewarmNativeRoot 'NativeHost.State.ps1') -Value '# warm-read fixture' -Encoding UTF8
            function Get-OpenPathCapabilityStoragePath {
                param([string]$Name, [string]$OpenPathRoot = '')
                if ($Name -eq 'FirefoxNativeHostRoot') { return $prewarmNativeRoot }
                return (Join-Path $TestDrive "capability-$Name")
            }
            function Get-OpenPathWhitelistSectionsFromFile {
                param([string]$Path)
                $script:prewarmCalls += 'sections'
                return [PSCustomObject]@{ Whitelist = @('reddit.com'); BlockedSubdomains = @(); IsDisabled = $false }
            }
            function Initialize-OpenPathDnsFlushType {
                $script:prewarmCalls += 'dnsType'
                return $true
            }
            function Get-OpenPathRuntimeDependencyDomains {
                param([string[]]$WhitelistedDomains = @(), [string[]]$BlockedSubdomains = @(), [switch]$Prune)
                $script:prewarmCalls += 'policySets'
                return @('cdn.example')
            }
            function Read-OpenPathRuntimeDependencyOverlay {
                $script:prewarmCalls += 'overlayRead'
                return @()
            }
            function Invoke-OpenPathRuntimeDependencyQueue {
                param([string[]]$WhitelistedDomains = @(), [string[]]$BlockedSubdomains = @(), [string]$QueuePath = '')
                $script:prewarmCalls += 'overlayUpdate'
                # The invalid prewarm request must not reach policy state.
                @(Get-ChildItem -Path $QueuePath -Filter '*.json' -ErrorAction SilentlyContinue).Count | Should -Be 1
                return [PSCustomObject]@{ Changed = $false; Processed = 0; Rejected = 1; OverlayWriteMs = 0; QueuePath = $QueuePath }
            }
            function Initialize-OpenPathAcrylicHostRenderDryRun {
                param([string[]]$WhitelistedDomains = @(), [string[]]$BlockedSubdomains = @())
                $script:prewarmCalls += 'acrylic'
                return [PSCustomObject]@{ Success = $true; ContentLength = 128; RuntimeDependencyDomains = 1 }
            }
            $script:capturedPrewarmLogs = @()
            function Write-OpenPathLog {
                param([string]$Message, [string]$Level = 'INFO')
                $script:capturedPrewarmLogs += [string]$Message
            }

            try {
                $metrics = Invoke-OpenPathRuntimeDependencyWorkerPrewarm -OpenPathRoot $prewarmRoot
            }
            finally {
                foreach ($functionName in @(
                        'Get-OpenPathCapabilityStoragePath',
                        'Get-OpenPathWhitelistSectionsFromFile',
                        'Initialize-OpenPathDnsFlushType',
                        'Get-OpenPathRuntimeDependencyDomains',
                        'Read-OpenPathRuntimeDependencyOverlay',
                        'Invoke-OpenPathRuntimeDependencyQueue',
                        'Initialize-OpenPathAcrylicHostRenderDryRun',
                        'Write-OpenPathLog'
                    )) {
                    Remove-Item "Function:\$functionName" -ErrorAction SilentlyContinue
                }
            }

            $script:prewarmCalls | Should -Contain 'dnsType'
            $script:prewarmCalls | Should -Contain 'sections'
            $script:prewarmCalls | Should -Contain 'policySets'
            $script:prewarmCalls | Should -Contain 'overlayRead'
            $script:prewarmCalls | Should -Contain 'overlayUpdate'
            $script:prewarmCalls | Should -Contain 'acrylic'
            $metrics.ready | Should -BeTrue
            $metrics.totalMs | Should -BeGreaterOrEqual 0
            $prewarmLog = @($script:capturedPrewarmLogs | Where-Object { $_ -match 'stage=prewarm' })
            $prewarmLog.Count | Should -Be 1
            $prewarmLog[0] | Should -Match 'stage=prewarm ms=\d+ nativeHostWarmMs=\d+'
        }

        It "keeps the worker session prewarm in the startup script before the watch loop" {
            $startupContent = Get-Content (Join-Path $PSScriptRoot ".." "scripts" "Start-RuntimeDependencyWorker.ps1") -Raw
            $prewarmIndex = $startupContent.IndexOf('Invoke-OpenPathRuntimeDependencyWorkerPrewarm')
            $loopIndex = $startupContent.IndexOf('Start-OpenPathRuntimeDependencyWorker -OpenPathRoot')
            $prewarmIndex | Should -BeGreaterThan 0
            $loopIndex | Should -BeGreaterThan $prewarmIndex
        }
    }

    Context "Task registration and packaging" {
        It "declares the worker task in the scheduled task catalog" {
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "ScheduledTaskCatalog.ps1"
            . $catalogPath
            $catalog = Get-OpenPathScheduledTaskCatalog

            $catalog.Tasks.RuntimeDependencyWorker.Name | Should -Be 'OpenPath-RuntimeDependencyWorker'
            $catalog.Tasks.RuntimeDependencyWorker.Script | Should -Be 'scripts\Start-RuntimeDependencyWorker.ps1'
            $catalog.Tasks.RuntimeDependencyWorker.GrantUsersRunAccess | Should -BeFalse
            @($catalog.ValidTaskTypes) | Should -Contain 'RuntimeDependencyWorker'
        }

        It "builds a startup, auto-restart, single-instance, unlimited worker task definition" {
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "ScheduledTaskCatalog.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Services.TaskBuilders.ps1"
            . $catalogPath
            . $helperPath

            function New-ScheduledTaskAction {
                param([string]$Execute, [string]$Argument)
                [PSCustomObject]@{ Execute = $Execute; Argument = $Argument }
            }
            function New-ScheduledTaskTrigger {
                param([switch]$Once, [datetime]$At, [timespan]$RepetitionInterval, [switch]$AtStartup, [switch]$Daily, [timespan]$RandomDelay)
                [PSCustomObject]@{ Once = [bool]$Once; At = $At; RepetitionInterval = $RepetitionInterval; AtStartup = [bool]$AtStartup; Daily = [bool]$Daily; RandomDelay = $RandomDelay }
            }
            function New-ScheduledTaskSettingsSet {
                param(
                    [switch]$AllowStartIfOnBatteries,
                    [switch]$DontStopIfGoingOnBatteries,
                    [switch]$StartWhenAvailable,
                    [int]$RestartCount,
                    [timespan]$RestartInterval,
                    [timespan]$ExecutionTimeLimit,
                    [string]$MultipleInstances
                )
                [PSCustomObject]@{ RestartCount = $RestartCount; RestartInterval = $RestartInterval; ExecutionTimeLimit = $ExecutionTimeLimit; MultipleInstances = $MultipleInstances }
            }

            $definition = New-OpenPathRuntimeDependencyWorkerTaskDefinition `
                -OpenPathRoot "C:\OpenPath" `
                -Principal ([PSCustomObject]@{ UserId = "SYSTEM" })

            $definition.TaskName | Should -Be "OpenPath-RuntimeDependencyWorker"
            $definition.Action.Argument | Should -Match ([regex]::Escape('C:\OpenPath\scripts\Start-RuntimeDependencyWorker.ps1'))
            $definition.Trigger.AtStartup | Should -BeTrue
            $definition.Settings.RestartCount | Should -BeGreaterThan 0
            $definition.Settings.MultipleInstances | Should -Be 'IgnoreNew'
            $definition.Settings.ExecutionTimeLimit.TotalDays | Should -Be 0
        }

        It "registers, stages, protects, and supervises the worker script and module" {
            $servicesContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "Services.psm1") -Raw
            $stagingContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1") -Raw
            $integrityContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Integrity.ps1") -Raw
            $watchdogContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1") -Raw

            Assert-ContentContainsAll -Content $servicesContent -Needles @(
                '$runtimeDependencyWorkerDefinition = New-OpenPathRuntimeDependencyWorkerTaskDefinition',
                '"RuntimeDependencyWorker"'
            )
            Assert-ContentContainsAll -Content $stagingContent -Needles @(
                "'Start-RuntimeDependencyWorker.ps1'"
            )
            Assert-ContentContainsAll -Content $integrityContent -Needles @(
                'Start-RuntimeDependencyWorker.ps1',
                'RuntimeDependency.Worker.ps1'
            )
            Assert-ContentContainsAll -Content $watchdogContent -Needles @(
                'OpenPath-RuntimeDependencyWorker',
                '$issues += "Runtime dependency worker not running"',
                'Start-ScheduledTask -TaskName "OpenPath-RuntimeDependencyWorker"'
            )
        }
    }

    Context "Fast apply readiness flush contract" {
        It "flushes the Windows DNS client cache before stamping the applied generation" {
            $runtimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $content = Get-Content $runtimePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[switch]$PassThru',
                'LockBusy = [bool]$lockBusy',
                '$dnsFlushOk = [bool](Clear-OpenPathDnsClientCache)',
                'dnsFlushMs',
                'dnsFlushOk',
                'detectedQueueFiles',
                'overlay generation stamped: appliedGeneration='
            )

            $fastApplyStart = $content.IndexOf('function Invoke-OpenPathRuntimeDependencyFastApply')
            $updateCycleStart = $content.IndexOf('function Invoke-OpenPathUpdateCycle')
            $fastApplyBody = $content.Substring($fastApplyStart, $updateCycleStart - $fastApplyStart)

            $flushIndex = $fastApplyBody.IndexOf('Clear-OpenPathDnsClientCache')
            $stampIndex = $fastApplyBody.IndexOf('Set-OpenPathRuntimeDependencyOverlayApplied')
            $flushIndex | Should -BeGreaterThan 0
            $stampIndex | Should -BeGreaterThan $flushIndex
        }

        It "keeps the runtime dependency files readable by the browser user" {
            $overlayContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "RuntimeDependency.Overlay.ps1") -Raw
            $capabilityContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "CapabilityStorage.ps1") -Raw
            $serviceContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Service.ps1") -Raw
            $dnsModuleContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "DNS.psm1") -Raw

            $overlayContent | Should -Match 'Set-OpenPathRuntimeDependencyReadAccess'
            # The DNS module imports the path helper through Common, so the overlay
            # file must explicitly ensure the read-access helper is loaded too.
            $overlayContent | Should -Match "Get-Command -Name 'Set-OpenPathRuntimeDependencyReadAccess'"
            Assert-ContentContainsAll -Content $capabilityContent -Needles @(
                'function Set-OpenPathRuntimeDependencyReadAccess',
                "'RuntimeDependencyWorkerState'",
                'RuntimeDependencyRead'
            )
            Assert-ContentContainsAll -Content $serviceContent -Needles @(
                'function Clear-OpenPathDnsClientCache',
                'ipconfig'
            )
            $dnsModuleContent.Contains("'Clear-OpenPathDnsClientCache'") | Should -BeTrue
        }

        It "consults the worker heartbeat before applying a fallback task trigger" {
            $actionsContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.RuntimeDependency.ps1") -Raw
            $hostScriptContent = Get-Content (Join-Path $PSScriptRoot ".." "scripts" "OpenPath-NativeHost.ps1") -Raw

            Assert-ContentContainsAll -Content $actionsContent -Needles @(
                'function Test-NativeHostRuntimeDependencyWorkerFresh',
                'Test-NativeHostRuntimeDependencyWorkerFresh -MaxAgeSeconds 10',
                "'worker-fresh'",
                'OpenPath-RuntimeDependencyWorker',
                '100'
            )
            Assert-ContentContainsAll -Content $hostScriptContent -Needles @(
                'Resolve-OpenPathNativeHostLogPath',
                'LOCALAPPDATA',
                '$script:LogMaxBytes',
                "'message-received'",
                "'response-sent'"
            )
        }
    }

    Context "Writers lock wait warning" {
        It "stays quiet during a short busy round and warns once the interval elapses" {
            # Phase 7 P2: the fast apply now contends with the short Acrylic
            # writers scopes, so a short busy round is expected and must not
            # warn; the worker warns only after the (30 s default) interval.
            $quietQueue = Join-Path $TestDrive 'warn-quiet-queue'
            New-Item -ItemType Directory -Path $quietQueue -Force | Out-Null
            Set-Content -Path (Join-Path $quietQueue 'request-1.json') -Value '{}' -Encoding UTF8
            $script:warnLogs = @()
            function Write-OpenPathLog {
                param([string]$Message, [string]$Level = 'INFO')
                $script:warnLogs += [string]$Message
            }

            try {
                $script:warnCalls = 0
                $quietApply = {
                    $script:warnCalls++
                    Remove-Item -LiteralPath (Join-Path $quietQueue 'request-1.json') -Force -ErrorAction SilentlyContinue
                    return @{ ExitCode = 1; LockBusy = $true }
                }
                $result = Invoke-OpenPathRuntimeDependencyWorkerApply `
                    -ApplyAction $quietApply `
                    -QueuePath $quietQueue `
                    -RetryDelayMs 10
                $result.LockBusy | Should -BeTrue
                @($script:warnLogs | Where-Object { $_ -match 'writers lock' }).Count | Should -Be 0

                $busyQueue = Join-Path $TestDrive 'warn-busy-queue'
                New-Item -ItemType Directory -Path $busyQueue -Force | Out-Null
                Set-Content -Path (Join-Path $busyQueue 'request-1.json') -Value '{}' -Encoding UTF8
                $script:warnCalls = 0
                $busyApply = {
                    $script:warnCalls++
                    if ($script:warnCalls -lt 3) { return @{ ExitCode = 1; LockBusy = $true } }
                    return @{ ExitCode = 0; LockBusy = $false }
                }
                $null = Invoke-OpenPathRuntimeDependencyWorkerApply `
                    -ApplyAction $busyApply `
                    -QueuePath $busyQueue `
                    -RetryDelayMs 10 `
                    -LogIntervalSeconds 0
                @($script:warnLogs | Where-Object { $_ -match 'Acrylic writers lock' }).Count | Should -BeGreaterThan 0
            }
            finally {
                Remove-Item Function:\Write-OpenPathLog -ErrorAction SilentlyContinue
            }
        }

        It "defaults the first wait warning to the 30 s interval" {
            $workerContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "RuntimeDependency.Worker.ps1") -Raw
            Assert-ContentContainsAll -Content $workerContent -Needles @(
                '[int]$LogIntervalSeconds = 30',
                'for the Acrylic writers lock (retries=$retries pending=$pending)'
            )
            $fastApplyContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1") -Raw
            # No immediate warning on every fast-apply attempt: only the measured
            # wait is logged, and the worker escalates after 30 s.
            $fastApplyContent | Should -Match 'waited \$\(\$lockWaitStopwatch\.ElapsedMilliseconds\) ms for the Acrylic writers lock'
            $fastApplyContent | Should -Not -Match 'fast apply waiting up to'
        }
    }
}
