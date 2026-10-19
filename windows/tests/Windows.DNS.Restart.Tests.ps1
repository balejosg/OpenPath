Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Acrylic restart serialization (Phase 8f F1-F4)" {
    BeforeAll {
        if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) {
            function global:Get-Service { }
        }
        if (-not (Get-Command -Name Stop-Service -ErrorAction SilentlyContinue)) {
            function global:Stop-Service { }
        }
        if (-not (Get-Command -Name Start-Service -ErrorAction SilentlyContinue)) {
            function global:Start-Service { }
        }
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\DNS.psm1" -Force -Global -ErrorAction Stop
        $script:RestartModulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Restart.ps1"
    }

    Context "F2 decision" {
        It "Restarts on unknown state, content change, a down service and an unresponsive proxy only" {
            InModuleScope DNS {
                $fingerprint = [pscustomobject]@{ CombinedSha256 = 'current' }
                $loaded = [pscustomobject]@{ version = 1; combinedSha256 = 'current' }

                (Get-OpenPathAcrylicRestartDecision -LoadedState $null -Fingerprint $fingerprint -ServiceStatus 'Running').Reason | Should -Be 'state-unknown'
                (Get-OpenPathAcrylicRestartDecision -LoadedState $loaded -Fingerprint ([pscustomobject]@{ CombinedSha256 = 'other' }) -ServiceStatus 'Running').Reason | Should -Be 'content-changed'
                (Get-OpenPathAcrylicRestartDecision -LoadedState $loaded -Fingerprint $fingerprint -ServiceStatus 'Stopped').Reason | Should -Be 'service-down'
                (Get-OpenPathAcrylicRestartDecision -LoadedState $loaded -Fingerprint $fingerprint -ServiceStatus 'Missing').Reason | Should -Be 'service-down'
                (Get-OpenPathAcrylicRestartDecision -LoadedState $loaded -Fingerprint $fingerprint -ServiceStatus 'Running' -ControlQueryResponds $false).Reason | Should -Be 'control-unresponsive'

                $stable = Get-OpenPathAcrylicRestartDecision -LoadedState $loaded -Fingerprint $fingerprint -ServiceStatus 'Running' -ControlQueryResponds $true
                $stable.RestartNeeded | Should -BeFalse
                $stable.Reason | Should -Be 'stable'
                # Not-yet-probed ($null) is not a blocker: the caller probes only
                # when every other signal allows a skip.
                (Get-OpenPathAcrylicRestartDecision -LoadedState $loaded -Fingerprint $fingerprint -ServiceStatus 'Running').RestartNeeded | Should -BeFalse
            }
        }

        It "Fingerprints the effective hosts content (ignores the generated timestamp) plus the INI" {
            InModuleScope DNS {
                $acrylicDir = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-fp-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $acrylicDir -Force | Out-Null
                try {
                    Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicHosts.txt') -Value "# Generated: 2026-10-16 10:00:00`nFW example.com" -Encoding ascii
                    Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicConfiguration.ini') -Value "[GlobalSection]`nPrimaryServerAddress=8.8.8.8" -Encoding ascii
                    $first = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $acrylicDir
                    # Same effective content, new render timestamp: same fingerprint.
                    Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicHosts.txt') -Value "# Generated: 2026-10-16 10:05:00`nFW example.com" -Encoding ascii
                    $second = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $acrylicDir
                    $second.CombinedSha256 | Should -Be $first.CombinedSha256
                    # A real content change moves it.
                    Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicHosts.txt') -Value "# Generated: 2026-10-16 10:05:00`nFW other.example" -Encoding ascii
                    (Get-OpenPathAcrylicContentFingerprint -AcrylicPath $acrylicDir).CombinedSha256 | Should -Not -Be $first.CombinedSha256
                }
                finally {
                    Remove-Item -LiteralPath $acrylicDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context "F1/F2 orchestration" {
        It "Skips without touching the service when the loaded state matches and logs the skip" {
            InModuleScope DNS {
                $script:restartCalls = 0
                $script:stateWrites = 0
                $script:orchestratorLog = New-Object System.Collections.ArrayList
                Mock Get-OpenPathAcrylicLoadedState { [pscustomobject]@{ version = 1; combinedSha256 = 'hash-1' } } -ModuleName DNS
                Mock Get-OpenPathAcrylicContentFingerprint { [pscustomobject]@{ HostsSha256 = 'h'; IniSha256 = 'i'; CombinedSha256 = 'hash-1'; HostsPresent = $true; IniPresent = $true } } -ModuleName DNS
                Mock Get-AcrylicService { [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
                Mock Test-OpenPathAcrylicControlQuery { $true } -ModuleName DNS
                Mock Invoke-AcrylicServiceRestartCore { $script:restartCalls += 1; return $true } -ModuleName DNS
                Mock Set-OpenPathAcrylicLoadedState { $script:stateWrites += 1; return $true } -ModuleName DNS
                Mock Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') $null = $script:orchestratorLog.Add([string]$Message) } -ModuleName DNS

                $mutexName = 'OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')
                $result = Invoke-OpenPathAcrylicRestart -Caller 'unit-test' -MutexName $mutexName -StatePath '/nonexistent/state.json' -AcrylicPath '/nonexistent/acrylic'
                $result | Should -BeTrue
                $script:restartCalls | Should -Be 0
                $script:stateWrites | Should -Be 0
                ($script:orchestratorLog -join "`n") | Should -Match 'Acrylic restart skipped reason=stable caller=unit-test pid=\d+ ms=\d+'
            }
        }

        It "Restarts, records the post-restart content state and logs reason=content-changed" {
            InModuleScope DNS {
                $script:restartCalls = 0
                $script:savedReason = ''
                $script:savedCombined = ''
                $script:fingerprintCalls = 0
                Mock Get-OpenPathAcrylicLoadedState { [pscustomobject]@{ version = 1; combinedSha256 = 'hash-1' } } -ModuleName DNS
                Mock Get-OpenPathAcrylicContentFingerprint {
                    $script:fingerprintCalls += 1
                    if ($script:fingerprintCalls -le 1) { return [pscustomobject]@{ HostsSha256 = 'h2'; IniSha256 = 'i'; CombinedSha256 = 'hash-2'; HostsPresent = $true; IniPresent = $true } }
                    return [pscustomobject]@{ HostsSha256 = 'h2'; IniSha256 = 'i'; CombinedSha256 = 'hash-2-after'; HostsPresent = $true; IniPresent = $true }
                } -ModuleName DNS
                Mock Get-AcrylicService { [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
                Mock Test-OpenPathAcrylicControlQuery { $true } -ModuleName DNS
                Mock Invoke-AcrylicServiceRestartCore { $script:restartCalls += 1; return $true } -ModuleName DNS
                Mock Set-OpenPathAcrylicLoadedState {
                    param($Fingerprint, $Reason, $Path)
                    $script:savedReason = [string]$Reason
                    $script:savedCombined = [string]$Fingerprint.CombinedSha256
                    return $true
                } -ModuleName DNS
                $logLines = New-Object System.Collections.ArrayList
                Mock Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') $null = $logLines.Add([string]$Message) } -ModuleName DNS

                $result = Invoke-OpenPathAcrylicRestart -Caller 'unit-test' -MutexName ('OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')) -StatePath '/nonexistent/state.json' -AcrylicPath '/nonexistent/acrylic'
                $result | Should -BeTrue
                $script:restartCalls | Should -Be 1
                $script:savedReason | Should -Be 'content-changed'
                # The recorded state is the fingerprint recomputed after the
                # restart (what the service actually loaded).
                $script:savedCombined | Should -Be 'hash-2-after'
                ($logLines -join "`n") | Should -Match 'Acrylic restart reason=content-changed caller=unit-test pid=\d+ ms=\d+'
            }
        }

        It "Logs the decision breakdown and hashes the content once when the lock wait changed nothing (Phase 8g G1)" {
            InModuleScope DNS {
                $script:fingerprintCalls = 0
                Mock Get-OpenPathAcrylicLoadedState { [pscustomobject]@{ version = 1; combinedSha256 = 'hash-1'; loadedAtUtc = '2026-10-19T10:00:00.0000000Z' } } -ModuleName DNS
                Mock Get-OpenPathAcrylicContentFingerprint {
                    $script:fingerprintCalls += 1
                    [pscustomobject]@{ HostsSha256 = 'h'; IniSha256 = 'i'; CombinedSha256 = 'hash-1'; HostsPresent = $true; IniPresent = $true }
                } -ModuleName DNS
                Mock Test-OpenPathAcrylicFingerprintCurrent { $true } -ModuleName DNS
                Mock Get-AcrylicService { [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
                Mock Test-OpenPathAcrylicControlQuery { $true } -ModuleName DNS
                Mock Invoke-AcrylicServiceRestartCore { return $true } -ModuleName DNS
                Mock Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') $null = $script:orchestratorLog.Add([string]$Message) } -ModuleName DNS
                $script:orchestratorLog = New-Object System.Collections.ArrayList

                $result = Invoke-OpenPathAcrylicRestart -Caller 'unit-test' -MutexName ('OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')) -StatePath '/nonexistent/state.json' -AcrylicPath '/nonexistent/acrylic'
                $result | Should -BeTrue
                $script:fingerprintCalls | Should -Be 1
                ($script:orchestratorLog -join "`n") | Should -Match 'Acrylic restart skipped reason=stable caller=unit-test pid=\d+ ms=\d+ preDecisionMs=\d+ lockWaitMs=\d+ decisionMs=\d+'
            }
        }

        It "Hashes once for a known content change and reuses it for the loaded state (Phase 8g G1)" {
            InModuleScope DNS {
                $script:fingerprintCalls = 0
                $script:savedCombined = ''
                $script:restartCalls = 0
                Mock Get-OpenPathAcrylicLoadedState { [pscustomobject]@{ version = 1; combinedSha256 = 'stale-hash'; loadedAtUtc = '2026-10-19T10:00:00.0000000Z' } } -ModuleName DNS
                Mock Get-OpenPathAcrylicContentFingerprint {
                    $script:fingerprintCalls += 1
                    [pscustomobject]@{ HostsSha256 = 'h2'; IniSha256 = 'i'; CombinedSha256 = 'hash-2'; HostsPresent = $true; IniPresent = $true }
                } -ModuleName DNS
                Mock Test-OpenPathAcrylicFingerprintCurrent { $true } -ModuleName DNS
                Mock Get-AcrylicService { [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
                Mock Test-OpenPathAcrylicControlQuery { $true } -ModuleName DNS
                Mock Invoke-AcrylicServiceRestartCore { $script:restartCalls += 1; return $true } -ModuleName DNS
                Mock Set-OpenPathAcrylicLoadedState {
                    param($Fingerprint, $Reason, $Path)
                    $script:savedCombined = [string]$Fingerprint.CombinedSha256
                    return $true
                } -ModuleName DNS
                $script:orchestratorLog = New-Object System.Collections.ArrayList
                Mock Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') $null = $script:orchestratorLog.Add([string]$Message) } -ModuleName DNS

                $result = Invoke-OpenPathAcrylicRestart -Caller 'unit-test' -ContentChanged -MutexName ('OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')) -StatePath '/nonexistent/state.json' -AcrylicPath '/nonexistent/acrylic'
                $result | Should -BeTrue
                $script:restartCalls | Should -Be 1
                $script:fingerprintCalls | Should -Be 1
                $script:savedCombined | Should -Be 'hash-2'
                ($script:orchestratorLog -join "`n") | Should -Match 'Acrylic restart reason=content-changed caller=unit-test pid=\d+ ms=\d+.*preDecisionMs=0 .*lockWaitMs=\d+ decisionMs=\d+ coreMs=\d+ stateRecordMs=\d+ contentChanged=1'
            }
        }

        It "Logs the core restart sub-steps and warns when the restart exceeds three seconds (Phase 8g G3)" {
            InModuleScope DNS {
                $script:coreLog = New-Object System.Collections.ArrayList
                Mock Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') $null = $script:coreLog.Add("$Level $Message") } -ModuleName DNS
                Mock Get-AcrylicService { [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
                Mock Stop-Service { Start-Sleep -Milliseconds 3050 } -ModuleName DNS
                Mock Wait-AcrylicServiceStatus { [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
                Mock Clear-AcrylicCache { return $true } -ModuleName DNS
                Mock Ensure-AcrylicService { return $true } -ModuleName DNS

                $result = Invoke-AcrylicServiceRestartCore -TimeoutSeconds 5
                $result | Should -BeTrue
                $text = $script:coreLog -join "`n"
                $text | Should -Match 'Acrylic service restarted successfully.*(totalMs|ms)=\d+.*stopMs=\d+.*stoppedWaitMs=\d+.*purgeMs=\d+.*startMs=\d+.*runningWaitMs=\d+'
                $text | Should -Match 'WARN Acrylic service restart slow: totalMs=\d+.*stopMs=\d+.*stoppedWaitMs=\d+.*purgeMs=\d+.*startMs=\d+.*runningWaitMs=\d+'
            }
        }

        It "Restarts a down service and a proxy that does not answer the control query" {
            InModuleScope DNS {
                foreach ($case in @(
                        @{ status = 'Stopped'; responds = $true; expected = 'service-down' },
                        @{ status = 'Running'; responds = $false; expected = 'control-unresponsive' }
                    )) {
                    $script:restartCalls = 0
                    $logLines = New-Object System.Collections.ArrayList
                    Mock Get-OpenPathAcrylicLoadedState { [pscustomobject]@{ version = 1; combinedSha256 = 'hash-1' } } -ModuleName DNS
                    Mock Get-OpenPathAcrylicContentFingerprint { [pscustomobject]@{ CombinedSha256 = 'hash-1' } } -ModuleName DNS
                    Mock Get-AcrylicService { [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = $case.status } } -ModuleName DNS
                    Mock Test-OpenPathAcrylicControlQuery { [bool]$case.responds } -ModuleName DNS
                    Mock Invoke-AcrylicServiceRestartCore { $script:restartCalls += 1; return $true } -ModuleName DNS
                    Mock Set-OpenPathAcrylicLoadedState { return $true } -ModuleName DNS
                    Mock Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') $null = $logLines.Add([string]$Message) } -ModuleName DNS

                    $result = Invoke-OpenPathAcrylicRestart -Caller 'unit-test' -MutexName ('OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')) -StatePath '/nonexistent/state.json' -AcrylicPath '/nonexistent/acrylic'
                    $result | Should -BeTrue -Because $case.expected
                    $script:restartCalls | Should -Be 1 -Because $case.expected
                    ($logLines -join "`n") | Should -Match ("Acrylic restart reason=" + $case.expected)
                }
            }
        }

    }

    Context "F3/F4 real processes" {
        BeforeAll {
            $script:RestartDriverTemplate = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RestartFile,
    [Parameter(Mandatory)][string]$Role,
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$AcrylicPath,
    [Parameter(Mandatory)][string]$MutexName,
    [Parameter(Mandatory)][string]$LogFile,
    [Parameter(Mandatory)][string]$FakeRestartLog,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$Mode = 'restart',
    [int]$LockWaitTimeoutSeconds = 30,
    [int]$HoldMs = 4000,
    [int]$FakeRestartMs = 1500,
    [int]$StartDelayMs = 0,
    [int]$ProbeMs = 0,
    # Phase 8g G0: a flag file makes the control probe fail while another
    # process is restarting the service (the field race).
    [string]$ProbeDownFlag = ''
)
$ErrorActionPreference = 'Stop'

# Phase 8f F3 test driver: loads the product restart file and replaces the
# service seams with a simulated service (timestamped fake restarts). The
# stubs are defined AFTER the dot-source so they win over the file's own
# functions.
. $RestartFile

function Write-OpenPathLog {
    param([string]$Message, [string]$Level = 'INFO')
    Add-Content -LiteralPath $LogFile -Value ("$Level $Message")
}
function Get-AcrylicService {
    [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' }
}
function Test-OpenPathAcrylicControlQuery {
    param([int]$TimeoutSeconds = 3, [string]$Server = '127.0.0.1', [int]$Port = 53)
    $failed = ($ProbeDownFlag -and (Test-Path -LiteralPath $ProbeDownFlag))
    Add-Content -LiteralPath $LogFile -Value ("probe t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + " failed=" + [string]$failed)
    if ($ProbeMs -gt 0) { Start-Sleep -Milliseconds $ProbeMs }
    return (-not $failed)
}
function Invoke-AcrylicServiceRestartCore {
    param([int]$TimeoutSeconds = 20, [switch]$SkipBatchFallback)
    $start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Add-Content -LiteralPath $FakeRestartLog -Value ("start role=$Role t=$start")
    Start-Sleep -Milliseconds $FakeRestartMs
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Add-Content -LiteralPath $FakeRestartLog -Value ("end role=$Role t=$end")
    return $true
}

if ($StartDelayMs -gt 0) { Start-Sleep -Milliseconds $StartDelayMs }

if ($Mode -eq 'hold') {
    $scope = Invoke-OpenPathAcrylicRestartLockScope -MutexName $MutexName -Stage 'test-hold' -Action {
        Add-Content -LiteralPath $LogFile -Value ("held t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        Start-Sleep -Milliseconds $HoldMs
        Add-Content -LiteralPath $LogFile -Value ("released t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        return 'scope-done'
    }
    Add-Content -LiteralPath $LogFile -Value ("scopeResult=" + [string]$scope.Result + " acquired=" + [string]$scope.Acquired)
}
elseif ($Mode -eq 'restart-and-record') {
    # Phase 8g G0: holds the restart lock, makes the local control probe fail
    # while the "service is restarting", records a fresh loaded state (same
    # content, new loadedAtUtc) and releases. A second process that read the
    # old state and probed during the window must coalesce, not restart.
    $scope = Invoke-OpenPathAcrylicRestartLockScope -MutexName $MutexName -Stage 'test-restart-and-record' -Action {
        if ($ProbeDownFlag) { Set-Content -LiteralPath $ProbeDownFlag -Value 'down' -Encoding ascii }
        Add-Content -LiteralPath $LogFile -Value ("held t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        Start-Sleep -Milliseconds $HoldMs
        if ($ProbeDownFlag) { Remove-Item -LiteralPath $ProbeDownFlag -Force -ErrorAction SilentlyContinue }
        $fingerprint = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $AcrylicPath
        [pscustomobject]@{
            version        = 1
            hostsSha256    = [string]$fingerprint.HostsSha256
            iniSha256      = [string]$fingerprint.IniSha256
            combinedSha256 = [string]$fingerprint.CombinedSha256
            hostsPresent   = [bool]$fingerprint.HostsPresent
            iniPresent     = [bool]$fingerprint.IniPresent
            loadedAtUtc    = [DateTime]::UtcNow.ToString('o')
            reason         = 'service-down'
            pid            = $PID
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding ascii
        Add-Content -LiteralPath $LogFile -Value ("released t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        return 'state-recorded'
    }
    Add-Content -LiteralPath $LogFile -Value ("scopeResult=" + [string]$scope.Result + " acquired=" + [string]$scope.Acquired)
}
else {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [bool](Invoke-OpenPathAcrylicRestart -Caller ("driver-" + $Role) -MutexName $MutexName -StatePath $StatePath -AcrylicPath $AcrylicPath -LockWaitTimeoutSeconds $LockWaitTimeoutSeconds)
    $stopwatch.Stop()
    [pscustomobject]@{ role = $Role; result = $result; ms = $stopwatch.ElapsedMilliseconds } | ConvertTo-Json | Set-Content -LiteralPath $ResultFile
}
'@
        }

        It "Serializes two real pwsh processes and coalesces the second (F3/F4)" {
            $pwshPath = (Get-Process -Id $PID).Path
            if (-not $pwshPath -or -not (Test-Path -LiteralPath $pwshPath)) {
                $pwshPath = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue).Source
            }
            $pwshPath | Should -Not -BeNullOrEmpty

            $root = Join-Path $TestDrive ("restart-serialization-" + [guid]::NewGuid().ToString('N'))
            $acrylicDir = Join-Path $root 'acrylic'
            $statePath = Join-Path $root 'acrylic-loaded-state.json'
            $mutexName = 'OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')
            New-Item -ItemType Directory -Path $acrylicDir -Force | Out-Null
            # Content the processes will find unchanged relative to each other.
            Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicHosts.txt') -Value "# Generated: 2026-10-16 10:00:00`nFW example.com" -Encoding ascii
            Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicConfiguration.ini') -Value "[GlobalSection]`nPrimaryServerAddress=8.8.8.8" -Encoding ascii
            # A stale loaded state: process A sees a real content change,
            # restarts and records the new state; process B (waiting on the
            # restart lock) re-evaluates and coalesces.
            Set-Content -LiteralPath $statePath -Value '{"version":1,"combinedSha256":"stale-content-hash"}' -Encoding ascii

            $driverPath = Join-Path $root 'acrylic-restart-driver.ps1'
            Set-Content -LiteralPath $driverPath -Value $script:RestartDriverTemplate -Encoding UTF8

            $fakeRestartLog = Join-Path $root 'fake-restarts.log'
            $invocations = @(
                @{ role = 'A'; delay = 0 },
                @{ role = 'B'; delay = 400 }
            )
            $processes = @()
            foreach ($invocation in $invocations) {
                $arguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath,
                    '-RestartFile', $script:RestartModulePath,
                    '-Role', $invocation.role,
                    '-StatePath', $statePath,
                    '-AcrylicPath', $acrylicDir,
                    '-MutexName', $mutexName,
                    '-LogFile', (Join-Path $root ("out-" + $invocation.role + '.log')),
                    '-FakeRestartLog', $fakeRestartLog,
                    '-ResultFile', (Join-Path $root ("result-" + $invocation.role + '.json')),
                    '-LockWaitTimeoutSeconds', '30',
                    '-StartDelayMs', [string]$invocation.delay
                )
                $processes += Start-Process -FilePath $pwshPath -ArgumentList $arguments -PassThru `
                    -RedirectStandardOutput (Join-Path $root ("stdout-" + $invocation.role + '.txt')) `
                    -RedirectStandardError (Join-Path $root ("stderr-" + $invocation.role + '.txt'))
            }

            $deadline = (Get-Date).AddSeconds(120)
            while ($processes | Where-Object { -not $_.HasExited }) {
                if ((Get-Date) -gt $deadline) { break }
                Start-Sleep -Milliseconds 250
            }
            $diagnostics = ''
            foreach ($process in $processes) {
                if (-not $process.HasExited) { try { $process.Kill() } catch { } }
            }
            $resultA = Join-Path $root 'result-A.json'
            $resultB = Join-Path $root 'result-B.json'
            foreach ($file in @($resultA, $resultB)) {
                if (-not (Test-Path -LiteralPath $file)) {
                    $diagnostics = (@(
                            Get-Content -LiteralPath (Join-Path $root 'stdout-A.txt') -ErrorAction SilentlyContinue
                            Get-Content -LiteralPath (Join-Path $root 'stderr-A.txt') -ErrorAction SilentlyContinue
                            Get-Content -LiteralPath (Join-Path $root 'stdout-B.txt') -ErrorAction SilentlyContinue
                            Get-Content -LiteralPath (Join-Path $root 'stderr-B.txt') -ErrorAction SilentlyContinue
                        ) -join "`n")
                }
            }
            Test-Path -LiteralPath $resultA | Should -BeTrue -Because $diagnostics
            Test-Path -LiteralPath $resultB | Should -BeTrue -Because $diagnostics

            $results = @(
                (Get-Content -LiteralPath $resultA -Raw | ConvertFrom-Json),
                (Get-Content -LiteralPath $resultB -Raw | ConvertFrom-Json)
            )
            @($results | Where-Object { $_.result -ne $true }).Count | Should -Be 0 -Because $diagnostics

            # Exactly one simulated restart: the second process coalesced.
            $fakeLines = @(Get-Content -LiteralPath $fakeRestartLog)
            @($fakeLines | Where-Object { $_ -like 'start*' }).Count | Should -Be 1
            @($fakeLines | Where-Object { $_ -like 'end*' }).Count | Should -Be 1

            $logA = Get-Content -LiteralPath (Join-Path $root 'out-A.log') -Raw
            $logB = Get-Content -LiteralPath (Join-Path $root 'out-B.log') -Raw
            @((($logA + "`n" + $logB) -split "`n") | Where-Object { $_ -match 'Acrylic restart reason=content-changed caller=driver-' }).Count | Should -Be 1
            @((($logA + "`n" + $logB) -split "`n") | Where-Object { $_ -match 'Acrylic restart skipped reason=stable caller=driver-' }).Count | Should -Be 1

            # The loaded state records the content both processes saw.
            Test-Path -LiteralPath $statePath | Should -BeTrue
            $savedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $savedState.combinedSha256 | Should -Not -BeNullOrEmpty
        }

        It "Runs the control probe outside the restart lock (Phase 8f follow-up)" {
            $pwshPath = (Get-Process -Id $PID).Path
            if (-not $pwshPath -or -not (Test-Path -LiteralPath $pwshPath)) {
                $pwshPath = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue).Source
            }
            $pwshPath | Should -Not -BeNullOrEmpty

            $root = Join-Path $TestDrive ("restart-probe-" + [guid]::NewGuid().ToString('N'))
            $acrylicDir = Join-Path $root 'acrylic'
            $statePath = Join-Path $root 'state.json'
            New-Item -ItemType Directory -Path $acrylicDir -Force | Out-Null
            # No `# Generated:` header: the driver hashes the raw content (it
            # does not load the renderer), so raw and effective content match.
            Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicHosts.txt') -Value "FW example.com" -Encoding ascii
            Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicConfiguration.ini') -Value "[GlobalSection]`nPrimaryServerAddress=8.8.8.8" -Encoding ascii
            # Stable content: load the state the contender will match.
            $fingerprint = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $acrylicDir
            [pscustomobject]@{ version = 1; combinedSha256 = $fingerprint.CombinedSha256 } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding ascii

            $mutexName = 'OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')
            $holderLog = Join-Path $root 'hold.log'
            $contenderLog = Join-Path $root 'contender.log'
            $driverPath = Join-Path $root 'acrylic-restart-driver.ps1'
            Set-Content -LiteralPath $driverPath -Value $script:RestartDriverTemplate -Encoding UTF8

            $holder = Start-Process -FilePath $pwshPath -PassThru -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath,
                '-RestartFile', $script:RestartModulePath,
                '-Role', 'H', '-Mode', 'hold', '-HoldMs', '9000',
                '-StatePath', $statePath, '-AcrylicPath', $acrylicDir,
                '-MutexName', $mutexName, '-LogFile', $holderLog,
                '-FakeRestartLog', (Join-Path $root 'fake.log'),
                '-ResultFile', (Join-Path $root 'result-H.json')
            ) -RedirectStandardOutput (Join-Path $root 'stdout-H.txt') -RedirectStandardError (Join-Path $root 'stderr-H.txt')
            try {
                $heldDeadline = (Get-Date).AddSeconds(60)
                while (-not ((Test-Path -LiteralPath $holderLog) -and ((Get-Content -LiteralPath $holderLog -Raw) -match 'held t='))) {
                    if ((Get-Date) -gt $heldDeadline -or $holder.HasExited) { break }
                    Start-Sleep -Milliseconds 200
                }
                Test-Path -LiteralPath $holderLog | Should -BeTrue
                (Get-Content -LiteralPath $holderLog -Raw) | Should -Match 'held t='

                $contenderResult = Join-Path $root 'result-C.json'
                $contender = Start-Process -FilePath $pwshPath -PassThru -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath,
                    '-RestartFile', $script:RestartModulePath,
                    '-Role', 'C', '-StatePath', $statePath, '-AcrylicPath', $acrylicDir,
                    '-MutexName', $mutexName, '-LogFile', $contenderLog,
                    '-FakeRestartLog', (Join-Path $root 'contender-fake.log'),
                    '-ResultFile', $contenderResult,
                    '-ProbeMs', '300', '-LockWaitTimeoutSeconds', '60'
                ) -RedirectStandardOutput (Join-Path $root 'stdout-C.txt') -RedirectStandardError (Join-Path $root 'stderr-C.txt')
                try {
                    $deadline = (Get-Date).AddSeconds(90)
                    while (-not (Test-Path -LiteralPath $contenderResult)) {
                        if ((Get-Date) -gt $deadline -or $contender.HasExited) { break }
                        Start-Sleep -Milliseconds 200
                    }
                    Test-Path -LiteralPath $contenderResult | Should -BeTrue
                    $payload = Get-Content -LiteralPath $contenderResult -Raw | ConvertFrom-Json
                    $payload.result | Should -BeTrue

                    $probeMatch = [regex]::Match((Get-Content -LiteralPath $contenderLog -Raw), 'probe t=(\d+)')
                    $probeMatch.Success | Should -BeTrue
                    $probeAt = [long]$probeMatch.Groups[1].Value
                    $releasedMatch = [regex]::Match((Get-Content -LiteralPath $holderLog -Raw), 'released t=(\d+)')
                    $releasedMatch.Success | Should -BeTrue
                    $releasedAt = [long]$releasedMatch.Groups[1].Value
                    # The probe must have run while the holder still owned the
                    # lock; the old in-lock probe ran after the release.
                    ($probeAt -lt $releasedAt) | Should -BeTrue
                    (Get-Content -LiteralPath $contenderLog -Raw) | Should -Match 'Acrylic restart skipped reason=stable'
                }
                finally {
                    if (-not $contender.HasExited) { try { $contender.Kill() } catch { } }
                }
            }
            finally {
                if (-not $holder.HasExited) { try { $holder.Kill() } catch { } }
            }
        }

        It "Coalesces when the control probe failed only because another process was restarting (Phase 8g G0)" {
            $pwshPath = (Get-Process -Id $PID).Path
            if (-not $pwshPath -or -not (Test-Path -LiteralPath $pwshPath)) {
                $pwshPath = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue).Source
            }
            $pwshPath | Should -Not -BeNullOrEmpty

            $root = Join-Path $TestDrive ("restart-probe-race-" + [guid]::NewGuid().ToString('N'))
            $acrylicDir = Join-Path $root 'acrylic'
            $statePath = Join-Path $root 'state.json'
            New-Item -ItemType Directory -Path $acrylicDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicHosts.txt') -Value "FW example.com" -Encoding ascii
            Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicConfiguration.ini') -Value "[GlobalSection]`nPrimaryServerAddress=8.8.8.8" -Encoding ascii
            $fingerprint = Get-OpenPathAcrylicContentFingerprint -AcrylicPath $acrylicDir
            # The content is already the loaded one: only the control probe can
            # ask for a restart, exactly like the field cycle.
            [pscustomobject]@{
                version        = 1
                combinedSha256 = $fingerprint.CombinedSha256
                loadedAtUtc    = '2026-01-01T00:00:00.0000000Z'
                pid            = 111
            } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding ascii

            $mutexName = 'OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')
            $probeDownFlag = Join-Path $root 'probe-down.flag'
            $holderLog = Join-Path $root 'hold.log'
            $contenderLog = Join-Path $root 'contender.log'
            $contenderFakeLog = Join-Path $root 'contender-fake.log'
            $driverPath = Join-Path $root 'acrylic-restart-driver.ps1'
            Set-Content -LiteralPath $driverPath -Value $script:RestartDriverTemplate -Encoding UTF8

            $holder = Start-Process -FilePath $pwshPath -PassThru -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath,
                '-RestartFile', $script:RestartModulePath,
                '-Role', 'A', '-Mode', 'restart-and-record', '-HoldMs', '6000',
                '-StatePath', $statePath, '-AcrylicPath', $acrylicDir,
                '-MutexName', $mutexName, '-LogFile', $holderLog,
                '-ProbeDownFlag', $probeDownFlag,
                '-FakeRestartLog', (Join-Path $root 'holder-fake.log'),
                '-ResultFile', (Join-Path $root 'result-A.json')
            ) -RedirectStandardOutput (Join-Path $root 'stdout-A.txt') -RedirectStandardError (Join-Path $root 'stderr-A.txt')
            try {
                $heldDeadline = (Get-Date).AddSeconds(60)
                while (-not ((Test-Path -LiteralPath $holderLog) -and ((Get-Content -LiteralPath $holderLog -Raw) -match 'held t='))) {
                    if ((Get-Date) -gt $heldDeadline -or $holder.HasExited) { break }
                    Start-Sleep -Milliseconds 150
                }
                Test-Path -LiteralPath $holderLog | Should -BeTrue
                (Get-Content -LiteralPath $holderLog -Raw) | Should -Match 'held t='

                # B reads the state (matches the content), probes while A is
                # restarting (the probe fails), waits for the lock and must
                # re-probe once it sees that A recorded a new loaded state.
                $contenderResult = Join-Path $root 'result-C.json'
                $contender = Start-Process -FilePath $pwshPath -PassThru -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath,
                    '-RestartFile', $script:RestartModulePath,
                    '-Role', 'C', '-StatePath', $statePath, '-AcrylicPath', $acrylicDir,
                    '-MutexName', $mutexName, '-LogFile', $contenderLog,
                    '-ProbeDownFlag', $probeDownFlag,
                    '-FakeRestartLog', $contenderFakeLog,
                    '-ResultFile', $contenderResult,
                    '-LockWaitTimeoutSeconds', '60'
                ) -RedirectStandardOutput (Join-Path $root 'stdout-C.txt') -RedirectStandardError (Join-Path $root 'stderr-C.txt')
                try {
                    $deadline = (Get-Date).AddSeconds(90)
                    while (-not (Test-Path -LiteralPath $contenderResult)) {
                        if ((Get-Date) -gt $deadline -or $contender.HasExited) { break }
                        Start-Sleep -Milliseconds 200
                    }
                    $diagnostics = @(
                        Get-Content -LiteralPath (Join-Path $root 'stdout-C.txt') -ErrorAction SilentlyContinue
                        Get-Content -LiteralPath (Join-Path $root 'stderr-C.txt') -ErrorAction SilentlyContinue
                    ) -join "`n"
                    Test-Path -LiteralPath $contenderResult | Should -BeTrue -Because $diagnostics
                    $payload = Get-Content -LiteralPath $contenderResult -Raw | ConvertFrom-Json
                    $payload.result | Should -BeTrue

                    $contenderText = Get-Content -LiteralPath $contenderLog -Raw
                    $contenderText | Should -Not -Match 'reason=control-unresponsive'
                    $contenderText | Should -Match 'Acrylic restart skipped reason=stable caller=driver-C pid=\d+'
                    $contenderText | Should -Match 'probeRetry=1'
                    @([regex]::Matches($contenderText, 'probe t=\d+ failed=')).Count | Should -Be 2
                    $contenderText | Should -Match 'probe t=\d+ failed=True'
                    $contenderText | Should -Match 'probe t=\d+ failed=False'
                    # The stale false probe must not trigger a second restart.
                    Test-Path -LiteralPath $contenderFakeLog | Should -BeFalse
                }
                finally {
                    if (-not $contender.HasExited) { try { $contender.Kill() } catch { } }
                }
            }
            finally {
                if (-not $holder.HasExited) { try { $holder.Kill() } catch { } }
            }
        }

        It "Holds the restart lock across a scope action and makes a contender time out (F4)" {
            $pwshPath = (Get-Process -Id $PID).Path
            if (-not $pwshPath -or -not (Test-Path -LiteralPath $pwshPath)) {
                $pwshPath = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue).Source
            }
            $pwshPath | Should -Not -BeNullOrEmpty

            $root = Join-Path $TestDrive ("restart-scope-" + [guid]::NewGuid().ToString('N'))
            $acrylicDir = Join-Path $root 'acrylic'
            New-Item -ItemType Directory -Path $acrylicDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $acrylicDir 'AcrylicHosts.txt') -Value "# Generated: 2026-10-16 10:00:00`nFW example.com" -Encoding ascii
            $mutexName = 'OpenPathTest-AcrylicRestart-' + [guid]::NewGuid().ToString('N')
            $holderLog = Join-Path $root 'hold.log'
            $driverPath = Join-Path $root 'acrylic-restart-driver.ps1'
            Set-Content -LiteralPath $driverPath -Value $script:RestartDriverTemplate -Encoding UTF8

            $holder = Start-Process -FilePath $pwshPath -PassThru -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath,
                '-RestartFile', $script:RestartModulePath,
                '-Role', 'H', '-Mode', 'hold', '-HoldMs', '6000',
                '-StatePath', (Join-Path $root 'state.json'),
                '-AcrylicPath', $acrylicDir,
                '-MutexName', $mutexName,
                '-LogFile', $holderLog,
                '-FakeRestartLog', (Join-Path $root 'fake.log'),
                '-ResultFile', (Join-Path $root 'result-H.json')
            ) -RedirectStandardOutput (Join-Path $root 'stdout-H.txt') -RedirectStandardError (Join-Path $root 'stderr-H.txt')

            try {
                $heldDeadline = (Get-Date).AddSeconds(60)
                while (-not ((Test-Path -LiteralPath $holderLog) -and ((Get-Content -LiteralPath $holderLog -Raw) -match 'held'))) {
                    if ((Get-Date) -gt $heldDeadline) { break }
                    if ($holder.HasExited) { break }
                    Start-Sleep -Milliseconds 200
                }
                Test-Path -LiteralPath $holderLog | Should -BeTrue
                (Get-Content -LiteralPath $holderLog -Raw) | Should -Match 'held'

                # The contender is a second real process with a 1 s bounded
                # wait: it must not restart in parallel while the scope holds
                # the lock.
                $contenderLog = Join-Path $root 'contender.log'
                $contenderResult = Join-Path $root 'result-C.json'
                $contender = Start-Process -FilePath $pwshPath -PassThru -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath,
                    '-RestartFile', $script:RestartModulePath,
                    '-Role', 'C',
                    '-StatePath', (Join-Path $root 'state.json'),
                    '-AcrylicPath', $acrylicDir,
                    '-MutexName', $mutexName,
                    '-LogFile', $contenderLog,
                    '-FakeRestartLog', (Join-Path $root 'contender-fake.log'),
                    '-ResultFile', $contenderResult,
                    '-LockWaitTimeoutSeconds', '1'
                ) -RedirectStandardOutput (Join-Path $root 'stdout-C.txt') -RedirectStandardError (Join-Path $root 'stderr-C.txt')
                try {
                    $contenderDeadline = (Get-Date).AddSeconds(60)
                    while (-not (Test-Path -LiteralPath $contenderResult)) {
                        if ((Get-Date) -gt $contenderDeadline) { break }
                        if ($contender.HasExited) { break }
                        Start-Sleep -Milliseconds 200
                    }
                    $contenderDiagnostics = @(
                        Get-Content -LiteralPath (Join-Path $root 'stdout-C.txt') -ErrorAction SilentlyContinue
                        Get-Content -LiteralPath (Join-Path $root 'stderr-C.txt') -ErrorAction SilentlyContinue
                    ) -join "`n"
                    Test-Path -LiteralPath $contenderResult | Should -BeTrue -Because $contenderDiagnostics
                    $contenderPayload = Get-Content -LiteralPath $contenderResult -Raw | ConvertFrom-Json
                    $contenderPayload.result | Should -BeFalse
                    (Get-Content -LiteralPath $contenderLog -Raw) | Should -Match 'Acrylic restart skipped reason=lock-timeout caller=driver-C pid=\d+ waitMs=\d+'
                    Test-Path -LiteralPath (Join-Path $root 'contender-fake.log') | Should -BeFalse

                    # The scope completes after holding the lock across its
                    # action (HoldMs in the holder process).
                    $scopeDeadline = (Get-Date).AddSeconds(30)
                    while (-not ((Get-Content -LiteralPath $holderLog -Raw) -match 'scopeResult=scope-done acquired=True')) {
                        if ((Get-Date) -gt $scopeDeadline) { break }
                        Start-Sleep -Milliseconds 250
                    }
                    (Get-Content -LiteralPath $holderLog -Raw) | Should -Match 'scopeResult=scope-done acquired=True'
                }
                finally {
                    if (-not $contender.HasExited) { try { $contender.Kill() } catch { } }
                }
            }
            finally {
                if (-not $holder.HasExited) { try { $holder.Kill() } catch { } }
            }
        }
    }
}
