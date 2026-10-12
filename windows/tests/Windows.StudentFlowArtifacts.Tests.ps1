# Phase 8b R3 / Phase 8d D3: the Windows student-policy artifact directory must
# never ship the raw per-machine token, and the final host state must be
# reported from the complete product log (with rotations), the Firefox
# messaging manifest and the product's own health. The runner source is read as
# text for the wiring contracts and the extracted helpers are executed against
# real fixture files. Set OPENPATH_STUDENT_FLOW_RUNNER_PATH to point the
# extraction at another copy of the runner (used for the red capture against
# 6f4c1c58).

Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

Describe 'Windows student-policy artifact hygiene (Phase 8b/8d)' {
    BeforeAll {
        $script:RunnerPath = if ($env:OPENPATH_STUDENT_FLOW_RUNNER_PATH) {
            $env:OPENPATH_STUDENT_FLOW_RUNNER_PATH
        }
        else {
            Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-student-flow.ps1'
        }
        $resolvedRunner = (Resolve-Path $script:RunnerPath).Path
        $script:RunnerSource = Get-Content -LiteralPath $resolvedRunner -Raw
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedRunner, [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @(
                'Protect-OpenPathDiagnosticText',
                'Protect-OpenPathStudentScenarioArtifact',
                'Get-OpenPathNativeHostLogNoHostCount',
                'Get-OpenPathNativeHostManifestDestination',
                'Get-OpenPathHarnessFileSha256',
                'Get-OpenPathNativeHostHealthFileFallback',
                'Get-OpenPathNativeHostE2eSummaryState',
                'Save-OpenPathNativeHostFirstRunProbe',
                'Invoke-OpenPathNativeHostFirstRunProbe',
                'Write-OpenPathNativeHostE2eSummary')) {
            $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
            if (-not $definition) { throw "windows-student-flow-function-missing: $name" }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    It 'Redacts the scenario artifact in place without leaking the raw token' {
        $root = Join-Path $TestDrive ('scenario-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $token = 'machine-token-abcdef1234567890'
        $scenarioPath = Join-Path $root 'student-scenario.json'
        [IO.File]::WriteAllText($scenarioPath, (@{
                    machine = @{
                        whitelistUrl = "https://api.example.test/w/$token/whitelist.txt"
                        machineToken = $token
                    }
                    auth    = @{
                        admin   = @{ email = 'admin@openpath.local'; accessToken = 'eyJhbGciOiJIUzI1NiJ9.fixture-access-token' }
                        teacher = @{ email = 'teacher@openpath.local'; accessToken = 'eyJhbGciOiJIUzI1NiJ9.fixture-teacher-token' }
                    }
                } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

        Protect-OpenPathStudentScenarioArtifact -ArtifactsRoot $root

        $redacted = Get-Content -LiteralPath $scenarioPath -Raw
        $redacted.Contains($token) | Should -BeFalse
        $redacted.Contains('fixture-access-token') | Should -BeFalse
        $redacted.Contains('fixture-teacher-token') | Should -BeFalse
        $redacted | Should -Match '/w/\[redacted\]/whitelist\.txt'
        $redacted | Should -Match '"machineToken"\s*:\s*"\[redacted\]"'
        $redacted | Should -Match '"accessToken"\s*:\s*"\[redacted\]"'
        # Idempotent, and harmless when the file does not exist.
        Protect-OpenPathStudentScenarioArtifact -ArtifactsRoot $root
        (Get-Content -LiteralPath $scenarioPath -Raw) | Should -Be $redacted
        Protect-OpenPathStudentScenarioArtifact -ArtifactsRoot (Join-Path $root 'missing') | Should -BeNullOrEmpty
    }

    It 'Runs the redaction after every suite, in the cleanup path' {
        $script:RunnerSource | Should -Match 'function Protect-OpenPathStudentScenarioArtifact'
        $script:RunnerSource | Should -Match "Invoke-TimedStep -Name 'Redact student scenario artifact' -ScriptBlock \{ Protect-OpenPathStudentScenarioArtifact \}"
        # The call sits in the finally block so a failing suite cannot skip it.
        $finallyIndex = $script:RunnerSource.LastIndexOf('finally {')
        $redactIndex = $script:RunnerSource.IndexOf("Invoke-TimedStep -Name 'Redact student scenario artifact'")
        ($redactIndex -gt $finallyIndex) | Should -BeTrue
    }

    It 'Extracts the install-time privacy notice from the product log for the artifact' {
        $script:RunnerSource | Should -Match '=== Installer Privacy Notice \(product log\) ==='
        $script:RunnerSource | Should -Match "Select-String -LiteralPath \`$logPath -Pattern 'Privacy notice:' -SimpleMatch"
    }

    It 'Counts the no-host errors across the complete log and its rotations' {
        $root = Join-Path $TestDrive ('host-log-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $logPath = Join-Path $root 'openpath.log'
        Set-Content -LiteralPath $logPath -Encoding UTF8 -Value @(
            '2026-10-12 INFO openpath update',
            '2026-10-12 ERROR Restricted student users have no native host: first',
            'line'
        )
        Set-Content -LiteralPath "$logPath.1" -Encoding UTF8 -Value @(
            'Restricted student users have no native host: rotated',
            'other'
        )
        # A gap in the numbering must not stop the scan.
        Set-Content -LiteralPath "$logPath.3" -Encoding UTF8 -Value @(
            'Restricted student users have no native host: gap'
        )
        (Get-OpenPathNativeHostLogNoHostCount -LogPath $logPath) | Should -Be 3
        (Get-OpenPathNativeHostLogNoHostCount -LogPath (Join-Path $root 'absent.log')) | Should -Be 0
    }

    It 'Reports the manifest destination of the registered host' {
        $root = Join-Path $TestDrive ('host-manifest-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $manifest = Join-Path $root 'whitelist_native_host.json'
        [ordered]@{ name = 'whitelist_native_host'; path = (Join-Path $root 'OpenPath-NativeHost.exe'); type = 'stdio' } |
            ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
        (Get-OpenPathNativeHostManifestDestination -ManifestPath $manifest) | Should -Be 'exe'
        [ordered]@{ name = 'whitelist_native_host'; path = (Join-Path $root 'OpenPath-NativeHost.cmd'); type = 'stdio' } |
            ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
        (Get-OpenPathNativeHostManifestDestination -ManifestPath $manifest) | Should -Be 'cmd'
        (Get-OpenPathNativeHostManifestDestination -ManifestPath (Join-Path $root 'absent.json')) | Should -Be 'missing'
    }

    It 'Summarizes the final native host state from the complete log, the manifest and the product health' {
        $root = Join-Path $TestDrive ('host-summary-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $buildJson = Join-Path $root 'OpenPath-NativeHost.build.json'
        [ordered]@{
            status       = 'HealthCheckFailed'
            error        = 'health-check-timeout'
            attempts     = 2
            pingAttempts = 2
            lastPings    = @(
                [ordered]@{ attempt = 1; error = 'health-check-timeout'; pid = 41; hasExited = $false }
                [ordered]@{ attempt = 2; error = 'health-check-exited'; pid = 42; hasExited = $true; exitCode = 3 }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $buildJson -Encoding UTF8
        $logPath = Join-Path $root 'openpath.log'
        Set-Content -LiteralPath $logPath -Encoding UTF8 -Value @(
            'Restricted student users have no native host: truth one',
            'Restricted student users have no native host: truth two'
        )
        Set-Content -LiteralPath "$logPath.1" -Encoding UTF8 -Value @('Restricted student users have no native host: rotated')
        $manifest = Join-Path $root 'whitelist_native_host.json'
        [ordered]@{ name = 'whitelist_native_host'; path = (Join-Path $root 'OpenPath-NativeHost.cmd'); type = 'stdio' } |
            ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
        $fallbackState = Join-Path $root 'fallback-state.json'
        [ordered]@{ reason = 'native_host_health_ping_failed'; status = 'Fallback' } |
            ConvertTo-Json | Set-Content -LiteralPath $fallbackState -Encoding UTF8
        $summary = Join-Path $root 'step-summary.md'
        $healthProbe = {
            [ordered]@{ BoundaryActive = $true; RegisteredPath = ''; UsesCompiledHost = $false; CompiledHealthy = $false; ReasonCode = 'native_host_health_ping_failed' }
        }

        $captured = @(& {
                Write-OpenPathNativeHostE2eSummary -BuildJsonPath $buildJson -LogPath $logPath -ManifestPath $manifest -FallbackStatePath $fallbackState -ConfigPath (Join-Path $root 'config.json') -HealthProbe $healthProbe -SummaryPath $summary
            } 6>&1)
        $line = @($captured | Where-Object { $_ -is [string] -and $_ -match 'Native host \(final E2E state\)' }) | Select-Object -Last 1

        $line | Should -Match 'status=HealthCheckFailed'
        $line | Should -Match 'attempts=2'
        $line | Should -Match 'pingAttempts=2'
        $line | Should -Match 'lastPings=2'
        $line | Should -Match 'manifest=cmd'
        $line | Should -Match 'usesCompiledHost=False'
        $line | Should -Match 'compiledHealthy=False'
        $line | Should -Match "reasonCode='native_host_health_ping_failed'"
        $line | Should -Match "fallbackState='native_host_health_ping_failed'"
        $line | Should -Match 'lines: 3'
        @($captured | ForEach-Object { [string]$_ } | Where-Object { $_ -match '::warning title=Student has no compiled native host::' }).Count | Should -Be 1
        (Get-Content -LiteralPath $summary -Raw) | Should -Match 'Native host \(final E2E state\)'

        # A missing build.json is reported, never thrown (this is evidence,
        # not a gate).
        $missingLine = Write-OpenPathNativeHostE2eSummary -BuildJsonPath (Join-Path $root 'absent.json') -LogPath $logPath -ManifestPath $manifest -FallbackStatePath $fallbackState -ConfigPath (Join-Path $root 'config.json') -HealthProbe $healthProbe -SummaryPath '' 6>$null
        $missingLine | Should -Match 'status=missing'
    }

    It 'Does not warn when the student ends with the healthy compiled host' {
        $root = Join-Path $TestDrive ('host-ok-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $logPath = Join-Path $root 'openpath.log'
        Set-Content -LiteralPath $logPath -Encoding UTF8 -Value @('2026-10-12 INFO steady state')
        $manifest = Join-Path $root 'whitelist_native_host.json'
        [ordered]@{ name = 'whitelist_native_host'; path = (Join-Path $root 'OpenPath-NativeHost.exe'); type = 'stdio' } |
            ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
        $healthProbe = {
            [ordered]@{ BoundaryActive = $true; RegisteredPath = (Join-Path $root 'OpenPath-NativeHost.exe'); UsesCompiledHost = $true; CompiledHealthy = $true; ReasonCode = '' }
        }

        $captured = @(& {
                Write-OpenPathNativeHostE2eSummary -BuildJsonPath (Join-Path $root 'absent.json') -LogPath $logPath -ManifestPath $manifest -FallbackStatePath (Join-Path $root 'absent-state.json') -ConfigPath (Join-Path $root 'config.json') -HealthProbe $healthProbe -SummaryPath ''
            } 6>&1)

        @($captured | Where-Object { $_ -is [string] -and $_ -match '::warning' }).Count | Should -Be 0
        ($captured | Where-Object { $_ -is [string] -and $_ -match 'usesCompiledHost=True' }) | Should -Not -BeNullOrEmpty
        ($captured | Where-Object { $_ -is [string] -and $_ -match 'lines: 0' }) | Should -Not -BeNullOrEmpty
    }

    It 'Runs the first-run probe with a unique copy, records the ping fields and cleans it up' {
        $root = Join-Path $TestDrive ('first-run-' + [guid]::NewGuid().ToString('N'))
        $nativeRoot = Join-Path $root 'native'
        $installedRoot = Join-Path $root 'install'
        New-Item -ItemType Directory -Path (Join-Path $installedRoot 'native-host'), $nativeRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $installedRoot 'native-host\OpenPathNativeHost.cs') -Value '// fixture source' -Encoding ASCII
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ArtifactsRoot = Join-Path $root 'artifacts'
        New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null

        $compiler = {
            param($sourcePath, $outputPath)
            Set-Content -LiteralPath $outputPath -Value 'MZ-probe' -Encoding ASCII
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $pingTimeouts = New-Object System.Collections.ArrayList
        $ping = {
            param($executablePath, $timeoutSeconds)
            $null = $pingTimeouts.Add([int]$timeoutSeconds)
            [pscustomobject]@{ Healthy = $true; ElapsedMs = 120; Error = '' }
        }.GetNewClosure()

        $probe = Invoke-OpenPathNativeHostFirstRunProbe -NativeRoot $nativeRoot -OpenPathRoot $installedRoot -CompilerInvoker $compiler -ProcessInvoker $ping

        $probe.status | Should -Be 'healthy'
        $probe.compiled | Should -BeTrue
        $probe.timeToPongFirstMs | Should -Be 120
        [int]$pingTimeouts[0] | Should -Be 180
        [int]$pingTimeouts[1] | Should -Be 30
        # The copy is removed and the product state is untouched.
        @(Get-ChildItem -LiteralPath $nativeRoot -Filter 'OpenPath-NativeHost.probe-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $nativeRoot 'OpenPath-NativeHost.build.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $nativeRoot 'whitelist_native_host.json')) | Should -BeFalse
        $probeArtifact = Join-Path $script:ArtifactsRoot 'native-host\first-run-probe.json'
        (Test-Path -LiteralPath $probeArtifact) | Should -BeTrue
        (Get-Content -LiteralPath $probeArtifact -Raw) | Should -Match '"status":\s*"healthy"'
    }

    It 'Wires the first-run probe and the host security artifacts into the runner' {
        $script:RunnerSource | Should -Match 'function Invoke-OpenPathNativeHostFirstRunProbe'
        $probeIndex = $script:RunnerSource.IndexOf("Invoke-TimedStep -Name 'First-run native host probe'")
        $collectIndex = $script:RunnerSource.IndexOf("Invoke-TimedStep -Name 'Collect Windows diagnostics'")
        ($probeIndex -ge 0) | Should -BeTrue
        ($collectIndex -gt $probeIndex) | Should -BeTrue
        $script:RunnerSource | Should -Match 'System32\\config\\systemprofile'
        $script:RunnerSource | Should -Match 'native-host-system\.log'
        $script:RunnerSource | Should -Match 'openpath-native-host-lines\.log'
        $script:RunnerSource | Should -Match 'Microsoft-Windows-CodeIntegrity/Operational'
        $script:RunnerSource | Should -Match 'Microsoft-Windows-Windows Defender/Operational'
        $script:RunnerSource | Should -Match 'security-events\.json'
        $script:RunnerSource | Should -Match 'Get-OpenPathNativeHostLogNoHostCount -LogPath \$LogPath'
        $script:RunnerSource | Should -Match '\$script:InstallStartedAtUtc'
    }

    It 'Wires the host summary before the uninstall tears the state down' {
        $script:RunnerSource | Should -Match "Invoke-TimedStep -Name 'Summarize native host state'"
        $summaryIndex = $script:RunnerSource.IndexOf("Invoke-TimedStep -Name 'Summarize native host state'")
        $uninstallIndex = $script:RunnerSource.IndexOf("Invoke-TimedStep -Name 'Uninstall OpenPath client'")
        ($summaryIndex -ge 0) | Should -BeTrue
        ($uninstallIndex -gt $summaryIndex) | Should -BeTrue
    }

    It 'Runs the forced update in the production Windows PowerShell environment' {
        $wrapperPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\Invoke-OpenPathForcedUpdate.ps1'
        (Test-Path -LiteralPath $wrapperPath -PathType Leaf) | Should -BeTrue

        # The wrapper records the inherited child environment (literal cause
        # data) and then runs the update under the machine+user PSModulePath.
        $root = Join-Path $TestDrive ('forced-update-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $envSnapshot = Join-Path $root 'child-env.txt'
        $fakeUpdate = Join-Path $root 'fake-update.ps1'
        [IO.File]::WriteAllText($fakeUpdate, "[IO.File]::WriteAllText('$envSnapshot', [string]`$env:PSModulePath)`nexit 0`n", [Text.UTF8Encoding]::new($false))

        $output = @(& pwsh -NoProfile -File (Resolve-Path $wrapperPath).Path -UpdateScriptPath $fakeUpdate 2>&1)
        $text = $output -join "`n"
        $text | Should -Match 'inheritedPSModulePath='
        $text | Should -Match 'Get-FileHashResolves='
        (Test-Path -LiteralPath $envSnapshot) | Should -BeTrue

        $expected = (@(
                [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
                [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
            ) | Where-Object { $_ }) -join ';'
        [IO.File]::ReadAllText($envSnapshot) | Should -Be $expected
    }
}
