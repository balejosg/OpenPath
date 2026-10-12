# Phase 8b R3: the Windows student-policy artifact directory must never ship
# the raw per-machine token. The scenario file is redacted in place after the
# suites; the runner source is read as text for the wiring contract and the
# redaction helpers are executed against a real scenario file.

Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

Describe 'Windows student-policy artifact hygiene (Phase 8b)' {
    BeforeAll {
        $script:RunnerPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-student-flow.ps1'
        $resolvedRunner = (Resolve-Path $script:RunnerPath).Path
        $script:RunnerSource = Get-Content -LiteralPath $resolvedRunner -Raw
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedRunner, [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Protect-OpenPathDiagnosticText', 'Protect-OpenPathStudentScenarioArtifact', 'Write-OpenPathNativeHostE2eSummary')) {
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

    It 'Summarizes the final native host state and the false no-host errors in one line' {
        $root = Join-Path $TestDrive ('host-summary-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $buildJson = Join-Path $root 'OpenPath-NativeHost.build.json'
        [ordered]@{ status = 'Built'; error = ''; attempts = 4; pingAttempts = 2 } |
            ConvertTo-Json | Set-Content -LiteralPath $buildJson -Encoding UTF8
        $diagnostics = Join-Path $root 'windows-diagnostics.txt'
        Set-Content -LiteralPath $diagnostics -Encoding UTF8 -Value @(
            'line one',
            '2026-10-12 ERROR Restricted student users have no native host: reason=native_host_compile_failed',
            'Restricted student users have no native host: second',
            'line four'
        )
        $summary = Join-Path $root 'step-summary.md'

        $line = Write-OpenPathNativeHostE2eSummary -BuildJsonPath $buildJson -DiagnosticsPath $diagnostics -SummaryPath $summary

        $line | Should -Match "status=Built"
        $line | Should -Match "attempts=4"
        $line | Should -Match "pingAttempts=2"
        $line | Should -Match 'lines: 2'
        $line | Should -Match 'Native host \(final E2E state\)'
        (Get-Content -LiteralPath $summary -Raw) | Should -Match 'Native host \(final E2E state\)'

        # A missing build.json is reported, never thrown (this is evidence,
        # not a gate).
        $missingLine = Write-OpenPathNativeHostE2eSummary -BuildJsonPath (Join-Path $root 'absent.json') -DiagnosticsPath $diagnostics -SummaryPath ''
        $missingLine | Should -Match 'status=missing'
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
