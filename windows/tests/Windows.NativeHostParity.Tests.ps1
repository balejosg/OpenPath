# Phase 5 B1: native host parity.
#
# The PowerShell host is the protocol reference. Every request below is framed
# exactly like Firefox native messaging and the parsed responses of the
# compiled C# host must be equivalent (timings, generated ids and live task
# scheduler fields are masked). Compiled assertions are skipped when the
# in-box csc.exe is unavailable (non-Windows dev machines); the reference
# protocol contract still runs everywhere.

Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NativeHostParity.Helper.psm1') -Force

$script:ParityCases = @(New-NativeHostParitySequence)
$script:ParityCompilerAvailable = [bool](Get-NativeHostParityCompiler)
$script:ParityMaskedKeys = @(Get-NativeHostParityMaskedKeys)

Describe 'Native host parity (Phase 5 B1)' {
    BeforeAll {
        # Pester 5: recompute the discovery-time pure values in the run scope.
        $script:ParityCases = @(New-NativeHostParitySequence)
        $script:ParityCompilerAvailable = [bool](Get-NativeHostParityCompiler)
        $script:ParityMaskedKeys = @(Get-NativeHostParityMaskedKeys)
        $script:ParityRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ParityHostCommand = Get-NativeHostParityHostCommand
        $script:ParityReferenceFixture = New-NativeHostParityFixture -RepoRoot $script:ParityRepoRoot -Root (Join-Path $TestDrive 'parity-reference')
        $script:ParityCandidateFixture = New-NativeHostParityFixture -RepoRoot $script:ParityRepoRoot -Root (Join-Path $TestDrive 'parity-candidate')
        $script:ParityReferenceResponses = @(Invoke-NativeHostParitySession `
                -FilePath $script:ParityHostCommand.FilePath `
                -Arguments (@($script:ParityHostCommand.Arguments) + (Join-Path $script:ParityReferenceFixture.Native 'OpenPath-NativeHost.ps1')) `
                -Cases $script:ParityCases `
                -PerMessageTimeoutSeconds 60)
        $script:ParityCompiledExecutable = ''
        if ($script:ParityCompilerAvailable) {
            $script:ParityCompiledExecutable = Build-NativeHostParityExecutable -NativeRoot $script:ParityCandidateFixture.Native -CompilerPath (Get-NativeHostParityCompiler)
        }
        $script:ParityCandidateResponses = @()
        if ($script:ParityCompiledExecutable) {
            $script:ParityCandidateResponses = @(Invoke-NativeHostParitySession `
                    -FilePath $script:ParityCompiledExecutable `
                    -Cases $script:ParityCases `
                    -PerMessageTimeoutSeconds 60)
        }
    }

    Context 'Reference protocol contract' {
        It 'Answers every request of a persistent session with a JSON object' {
            $script:ParityReferenceResponses.Count | Should -Be $script:ParityCases.Count
            foreach ($entry in $script:ParityReferenceResponses) {
                $entry.response | Should -Not -BeNullOrEmpty -Because $entry.name
                $entry.response.PSObject.Properties['success'] | Should -Not -BeNullOrEmpty -Because $entry.name
            }
        }

        It 'Echoes ids with their original JSON type and only when provided' {
            $byName = @{}
            foreach ($entry in $script:ParityReferenceResponses) { $byName[$entry.name] = $entry.response }
            $byName['ping'].PSObject.Properties['id'] | Should -BeNullOrEmpty
            $byName['ping-id-number'].id | Should -Be 42
            $byName['ping-id-string'].id | Should -Be 'client-7'
        }

        It 'Fails closed on malformed JSON and idles until stdin closes' {
            $process = Start-NativeHostParityProcess -FilePath $script:ParityHostCommand.FilePath -Arguments (@($script:ParityHostCommand.Arguments) + (Join-Path $script:ParityReferenceFixture.Native 'OpenPath-NativeHost.ps1'))
            try {
                Write-NativeHostParityFrame -Process $process -Json '{"action":"ping",'
                $response = Read-NativeHostParityFrame -Process $process -TimeoutSeconds 30
                $response | Should -Not -BeNullOrEmpty
                $response.success | Should -BeFalse
                ([string]$response.error).Length | Should -BeGreaterThan 0
            }
            finally {
                try { $process.StandardInput.Close() } catch { }
                if (-not $process.WaitForExit(10000)) { try { $process.Kill($true) } catch { } }
                $process.Dispose()
            }
        }

        It 'Closes the session on an oversized frame instead of answering' {
            $process = Start-NativeHostParityProcess -FilePath $script:ParityHostCommand.FilePath -Arguments (@($script:ParityHostCommand.Arguments) + (Join-Path $script:ParityReferenceFixture.Native 'OpenPath-NativeHost.ps1'))
            try {
                $process.StandardInput.BaseStream.Write([System.BitConverter]::GetBytes([int](2MB)), 0, 4)
                $payload = [System.Text.Encoding]::UTF8.GetBytes('{"action":"ping"}')
                $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
                $process.StandardInput.BaseStream.Flush()
                $exited = $process.WaitForExit(15000)
                $exited | Should -BeTrue -Because 'a frame over 1MB is a protocol violation'
            }
            finally {
                try { $process.StandardInput.Close() } catch { }
                if (-not $process.HasExited) { try { $process.Kill($true) } catch { } }
                $process.Dispose()
            }
        }

        It 'Closes the session on a truncated frame instead of answering' {
            $process = Start-NativeHostParityProcess -FilePath $script:ParityHostCommand.FilePath -Arguments (@($script:ParityHostCommand.Arguments) + (Join-Path $script:ParityReferenceFixture.Native 'OpenPath-NativeHost.ps1'))
            try {
                $process.StandardInput.BaseStream.Write([System.BitConverter]::GetBytes([int]100), 0, 4)
                $partial = [System.Text.Encoding]::UTF8.GetBytes('{"action"')
                $process.StandardInput.BaseStream.Write($partial, 0, $partial.Length)
                $process.StandardInput.BaseStream.Flush()
                $process.StandardInput.Close()
                $exited = $process.WaitForExit(15000)
                $exited | Should -BeTrue
            }
            finally {
                try { $process.StandardInput.Close() } catch { }
                if (-not $process.HasExited) { try { $process.Kill($true) } catch { } }
                $process.Dispose()
            }
        }
    }

    Context 'Compiled host equivalence' -Skip:(-not $script:ParityCompilerAvailable) {
        It 'Compiles the payload source with the in-box compiler' {
            $script:ParityCompiledExecutable | Should -Not -BeNullOrEmpty
        }

        It 'Answers the same persistent session as the PowerShell host' {
            $script:ParityCandidateResponses.Count | Should -Be $script:ParityCases.Count
        }

        foreach ($case in $script:ParityCases) {
            It "Matches the reference: $($case.name)" -Skip:(-not $script:ParityCompilerAvailable) {
                $reference = @($script:ParityReferenceResponses | Where-Object { $_.name -eq $case.name })
                $candidate = @($script:ParityCandidateResponses | Where-Object { $_.name -eq $case.name })
                $reference.Count | Should -Be 1
                $candidate.Count | Should -Be 1
                $candidate[0].response | Should -Not -BeNullOrEmpty -Because $case.name
                $difference = Compare-NativeHostParityValue -Reference $reference[0].response -Candidate $candidate[0].response -MaskedKeys $script:ParityMaskedKeys
                $difference | Should -Be '' -Because $case.name
            }
        }

        It 'Closes the compiled session on an oversized frame like the reference' {
            $process = Start-NativeHostParityProcess -FilePath $script:ParityCompiledExecutable
            try {
                $process.StandardInput.BaseStream.Write([System.BitConverter]::GetBytes([int](2MB)), 0, 4)
                $payload = [System.Text.Encoding]::UTF8.GetBytes('{"action":"ping"}')
                $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
                $process.StandardInput.BaseStream.Flush()
                $process.WaitForExit(15000) | Should -BeTrue
            }
            finally {
                try { $process.StandardInput.Close() } catch { }
                if (-not $process.HasExited) { try { $process.Kill($true) } catch { } }
                $process.Dispose()
            }
        }
    }
}
