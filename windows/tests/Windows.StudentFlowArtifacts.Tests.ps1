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
        foreach ($name in @('Protect-OpenPathDiagnosticText', 'Protect-OpenPathStudentScenarioArtifact')) {
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
                } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

        Protect-OpenPathStudentScenarioArtifact -ArtifactsRoot $root

        $redacted = Get-Content -LiteralPath $scenarioPath -Raw
        $redacted.Contains($token) | Should -BeFalse
        $redacted | Should -Match '/w/\[redacted\]/whitelist\.txt'
        $redacted | Should -Match '"machineToken"\s*:\s*"\[redacted\]"'
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
}
