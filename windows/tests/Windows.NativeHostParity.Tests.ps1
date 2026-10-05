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
$script:ParityListFields = @(Get-NativeHostParityListFields)

Describe 'Native host parity (Phase 5 B1)' {
    BeforeAll {
        # Pester 5: recompute the discovery-time pure values in the run scope.
        $script:ParityCases = @(New-NativeHostParitySequence)
        $script:ParityCompilerAvailable = [bool](Get-NativeHostParityCompiler)
        $script:ParityMaskedKeys = @(Get-NativeHostParityMaskedKeys)
$script:ParityListFields = @(Get-NativeHostParityListFields)
        $script:ParityRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ParityHostCommand = Get-NativeHostParityHostCommand
        $script:ParityReferenceFixture = New-NativeHostParityFixture -RepoRoot $script:ParityRepoRoot -Root (Join-Path $TestDrive 'parity-reference')
        $script:ParityCandidateFixture = New-NativeHostParityFixture -RepoRoot $script:ParityRepoRoot -Root (Join-Path $TestDrive 'parity-candidate')
        $referenceTouch = @{ 'recover-recent-success' = (Join-Path $script:ParityReferenceFixture.Data 'captive-portal-active.json') }
        $script:ParityReferenceResponses = @(Invoke-NativeHostParitySession `
                -FilePath $script:ParityHostCommand.FilePath `
                -Arguments (@($script:ParityHostCommand.Arguments) + (Join-Path $script:ParityReferenceFixture.Native 'OpenPath-NativeHost.ps1')) `
                -Cases $script:ParityCases `
                -PerMessageTimeoutSeconds 60 `
                -TouchFilesByCase $referenceTouch)
        $script:ParityCompiledExecutable = ''
        if ($script:ParityCompilerAvailable) {
            $script:ParityCompiledExecutable = Build-NativeHostParityExecutable -NativeRoot $script:ParityCandidateFixture.Native -CompilerPath (Get-NativeHostParityCompiler)
        }
        $script:ParityCandidateResponses = @()
        if ($script:ParityCompiledExecutable) {
            $candidateTouch = @{ 'recover-recent-success' = (Join-Path $script:ParityCandidateFixture.Data 'captive-portal-active.json') }
            $script:ParityCandidateResponses = @(Invoke-NativeHostParitySession `
                    -FilePath $script:ParityCompiledExecutable `
                    -Cases $script:ParityCases `
                    -PerMessageTimeoutSeconds 60 `
                    -TouchFilesByCase $candidateTouch)
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

    Context 'Hook mechanism (Phase 5.3 P1)' {
        It 'Runs BeforeCaseScripts before the matching case on every platform' {
            # The mechanism must be exercised on Linux too: the producer suite
            # (which needs powershell.exe) used to hide this until CI.
            $hookFixture = New-NativeHostParityFixture -RepoRoot $script:ParityRepoRoot -Root (Join-Path $TestDrive 'hook-fixture')
            $statePath = Join-Path $hookFixture.Native 'native-state.json'
            $cases = @(
                @{ name = 'hook-before'; message = @{ action = 'get-config' } },
                @{ name = 'hook-after'; message = @{ action = 'get-config' } }
            )
            $hooks = @{}
            $hooks['hook-after'] = { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }.GetNewClosure()
            $responses = @(Invoke-NativeHostParitySession `
                    -FilePath $script:ParityHostCommand.FilePath `
                    -Arguments (@($script:ParityHostCommand.Arguments) + (Join-Path $hookFixture.Native 'OpenPath-NativeHost.ps1')) `
                    -Cases $cases `
                    -PerMessageTimeoutSeconds 60 `
                    -BeforeCaseScripts $hooks)
            $responses[0].response.success | Should -BeTrue -Because 'the state is still present before the hook'
            $responses[1].response.success | Should -BeFalse -Because 'the hook removed native-state.json before the second case'
            ([string]$responses[1].response.error) | Should -Match 'not configured'
        }
    }

    Context 'Comparison rules' {
        It 'Treats a single-element array and its element as equivalent' {
            (Compare-NativeHostParityValue -Reference @('one') -Candidate 'one') | Should -Be ''
            (Compare-NativeHostParityValue -Reference 'one' -Candidate @('one')) | Should -Be ''
            (Compare-NativeHostParityValue -Reference @('one', 'two') -Candidate 'one') | Should -Not -Be ''
            (Compare-NativeHostParityValue -Reference 'one' -Candidate 'two') | Should -Not -Be ''
        }

        It 'Equates an empty string, empty object and empty list on list fields only (Phase 5.3 P1)' {
            $listFields = @(Get-NativeHostParityListFields)
            (Compare-NativeHostParityValue -Reference '' -Candidate @() -KeyName 'bootstrapHosts' -ListFields $listFields) | Should -Be ''
            (Compare-NativeHostParityValue -Reference @() -Candidate $null -KeyName 'bootstrapHosts' -ListFields $listFields) | Should -Be ''
            # Windows PowerShell 5.1 renders empty recovery lists as {}.
            (Compare-NativeHostParityValue -Reference ('{}' | ConvertFrom-Json) -Candidate @() -KeyName 'bootstrapHosts' -ListFields $listFields) | Should -Be ''
            (Compare-NativeHostParityValue -Reference ('{}' | ConvertFrom-Json) -Candidate 'portal.parity.invalid' -KeyName 'bootstrapHosts' -ListFields $listFields) | Should -Not -Be ''
            (Compare-NativeHostParityValue -Reference '' -Candidate @('x') -KeyName 'bootstrapHosts' -ListFields $listFields) | Should -Not -Be ''
            (Compare-NativeHostParityValue -Reference '' -Candidate @() -KeyName 'someOtherField' -ListFields $listFields) | Should -Not -Be ''
        }

        It 'Treats null and an empty array as equivalent but not a value' {
            (Compare-NativeHostParityValue -Reference $null -Candidate @()) | Should -Be ''
            (Compare-NativeHostParityValue -Reference @() -Candidate $null) | Should -Be ''
            (Compare-NativeHostParityValue -Reference $null -Candidate @('x')) | Should -Not -Be ''
        }

        It 'Masks only the documented nondeterministic keys' {
            (Compare-NativeHostParityValue -Reference 'a' -Candidate 'b' -KeyName 'expiresAt' -MaskedKeys @('expiresAt')) | Should -Be ''
            (Compare-NativeHostParityValue -Reference 'a' -Candidate 'b' -KeyName 'source') | Should -Not -Be ''
            (Compare-NativeHostParityValue -Reference 'a' -Candidate 'b' -KeyName 'state') | Should -Not -Be ''
        }
    }

    Context 'Compiled host equivalence' -Skip:(-not $script:ParityCompilerAvailable) {
        It 'Compiles the payload source with the in-box compiler' {
            $script:ParityCompiledExecutable | Should -Not -BeNullOrEmpty
        }

        It 'Answers the same persistent session as the PowerShell host' {
            $script:ParityCandidateResponses.Count | Should -Be $script:ParityCases.Count
        }

        It 'Matches the reference: <ParityName>' -TestCases (@($script:ParityCases | ForEach-Object { @{ ParityCase = $_; ParityName = $_.name } })) -Skip:(-not $script:ParityCompilerAvailable) {
            param($ParityCase)
            $reference = @($script:ParityReferenceResponses | Where-Object { $_.name -eq $ParityCase.name })
            $candidate = @($script:ParityCandidateResponses | Where-Object { $_.name -eq $ParityCase.name })
            $reference.Count | Should -Be 1
            $candidate.Count | Should -Be 1
            $candidate[0].response | Should -Not -BeNullOrEmpty -Because $ParityCase.name
            $difference = Compare-NativeHostParityValue -Reference $reference[0].response -Candidate $candidate[0].response -MaskedKeys $script:ParityMaskedKeys -ListFields $script:ParityListFields
            if ($difference) {
                # Full evidence in the job log: the assertion message is budget-capped.
                Write-Host ("PARITY-DIFF " + $ParityCase.name + " :: " + $difference)
                Write-Host ("PARITY-REF " + $ParityCase.name + " :: " + (($reference[0].response | ConvertTo-Json -Depth 10 -Compress)))
                Write-Host ("PARITY-CAND " + $ParityCase.name + " :: " + (($candidate[0].response | ConvertTo-Json -Depth 10 -Compress)))
            }
            $difference | Should -Be '' -Because $ParityCase.name
        }

        It 'Fails closed on malformed JSON like the reference' -Skip:(-not $script:ParityCompilerAvailable) {
            $process = Start-NativeHostParityProcess -FilePath $script:ParityCompiledExecutable
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
