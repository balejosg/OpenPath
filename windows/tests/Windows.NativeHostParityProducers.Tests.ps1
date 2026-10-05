# Phase 5.3 A4: native host parity on files written by the real producers.
#
# The base parity fixture writes every parsed file with UTF8Encoding($false),
# which hid the production encoding: the agent's scheduled tasks run Windows
# PowerShell 5.1, where `Set-Content -Encoding UTF8` writes UTF-8 *with* a BOM
# (overlay, worker state, queue, captive marker). This suite generates both
# fixtures with the producer functions themselves under PowerShell 5.1 and
# requires the compiled host to answer exactly like the reference.
#
# The WorkerFresh case also proves the enqueue path does not nudge the
# scheduled task while the worker heartbeat is fresh: the test creates a
# harmless sentinel task with the apply task name (when it does not exist) and
# asserts `schtasks` never ran it.

Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NativeHostParity.Helper.psm1') -Force

$script:ProducerCases = @(New-NativeHostParityProducerSequence)
$script:ProducerCompilerAvailable = [bool](Get-NativeHostParityCompiler)
$script:ProducerPowerShellAvailable = [bool](Get-NativeHostParityWindowsPowerShellPath)
$script:ProducerMaskedKeys = @(Get-NativeHostParityMaskedKeys)
        $script:ProducerListFields = @(Get-NativeHostParityListFields)

Describe 'Native host parity on producer files (Phase 5.3 A4)' {
    BeforeAll {
        $script:ProducerCases = @(New-NativeHostParityProducerSequence)
        $script:ProducerCompilerAvailable = [bool](Get-NativeHostParityCompiler)
        $script:ProducerPowerShellAvailable = [bool](Get-NativeHostParityWindowsPowerShellPath)
        $script:ProducerMaskedKeys = @(Get-NativeHostParityMaskedKeys)
        $script:ProducerListFields = @(Get-NativeHostParityListFields)
        $script:ProducerRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

        # 1) Sentinel scheduled task with the apply task name, created only when
        #    the name is free. `schtasks /Run` on a missing task returns false in
        #    both hosts, which would hide the regression; with a real task the
        #    fresh-worker fast path must not run it.
        $script:ProducerTaskName = 'OpenPath-RuntimeDependencyApply'
        $script:ProducerSentinel = 'C:\Windows\Temp\openpath-parity-schtasks-sentinel.txt'
        $script:ProducerCreatedTask = $false
        if ($script:ProducerPowerShellAvailable) {
            Remove-Item -LiteralPath $script:ProducerSentinel -Force -ErrorAction SilentlyContinue
            $existing = & schtasks.exe /Query /TN $script:ProducerTaskName 2>$null
            if ($LASTEXITCODE -ne 0) {
                & schtasks.exe /Create /TN $script:ProducerTaskName /SC ONCE /SD 12/31/2030 /ST 12:00 /TR "cmd /c copy /Y NUL $($script:ProducerSentinel)" /F 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $script:ProducerCreatedTask = $true }
            }
        }

        if ($script:ProducerPowerShellAvailable) {
            $script:ProducerReferenceFixture = New-NativeHostParityFixture -RepoRoot $script:ProducerRepoRoot -Root (Join-Path $TestDrive 'producer-reference')
            $script:ProducerCandidateFixture = New-NativeHostParityFixture -RepoRoot $script:ProducerRepoRoot -Root (Join-Path $TestDrive 'producer-candidate')
            # Both fixtures carry the same real-producer encodings (including the
            # explicit BOM variants), so the policy hash stays comparable.
            $script:ProducerReferenceMeta = Set-NativeHostParityProducerFiles -RepoRoot $script:ProducerRepoRoot -Root $script:ProducerReferenceFixture.Root -AddBomVariants
            $script:ProducerCandidateMeta = Set-NativeHostParityProducerFiles -RepoRoot $script:ProducerRepoRoot -Root $script:ProducerCandidateFixture.Root -AddBomVariants
            $script:ProducerHostCommand = Get-NativeHostParityHostCommand
            $referenceTouch = @{ 'probe-recover-recent-success' = (Join-Path $script:ProducerReferenceFixture.Data 'captive-portal-active.json') }
            # The worker freshness window is 10 s: refresh the heartbeat with the
            # real writer right before every case that depends on it, in both
            # sessions (the sessions run minutes apart).
            # Phase 5.3 P1: capture the values as function parameters, never
            # `$script:` inside a closure (dynamic module scope).
            $parityRepoRoot = $script:ProducerRepoRoot
            $parityReferenceRoot = $script:ProducerReferenceFixture.Root
            $parityCandidateRoot = $script:ProducerCandidateFixture.Root
            $script:ProducerFreshCases = @{}
            foreach ($caseName in @('probe-dependency-enqueue-pending', 'probe-dependency-queue-dedup', 'probe-dependency-fresh-worker-blocking')) {
                $script:ProducerFreshCases[$caseName] = New-NativeHostParityWorkerStateHook -RepoRoot $parityRepoRoot -Root $parityReferenceRoot
            }
            $script:ProducerReferenceResponses = @(Invoke-NativeHostParitySession `
                    -FilePath $script:ProducerHostCommand.FilePath `
                    -Arguments (@($script:ProducerHostCommand.Arguments) + (Join-Path $script:ProducerReferenceFixture.Native 'OpenPath-NativeHost.ps1')) `
                    -Cases $script:ProducerCases `
                    -PerMessageTimeoutSeconds 60 `
                    -TouchFilesByCase $referenceTouch `
                    -BeforeCaseScripts $script:ProducerFreshCases)
            $script:ProducerCompiledExecutable = ''
            if ($script:ProducerCompilerAvailable) {
                $script:ProducerCompiledExecutable = Build-NativeHostParityExecutable -NativeRoot $script:ProducerCandidateFixture.Native -CompilerPath (Get-NativeHostParityCompiler)
            }
            $script:ProducerCandidateResponses = @()
            if ($script:ProducerCompiledExecutable) {
                $candidateTouch = @{ 'probe-recover-recent-success' = (Join-Path $script:ProducerCandidateFixture.Data 'captive-portal-active.json') }
                $candidateFreshCases = @{}
                foreach ($caseName in @('probe-dependency-enqueue-pending', 'probe-dependency-queue-dedup', 'probe-dependency-fresh-worker-blocking')) {
                    $candidateFreshCases[$caseName] = New-NativeHostParityWorkerStateHook -RepoRoot $parityRepoRoot -Root $parityCandidateRoot
                }
                $script:ProducerCandidateResponses = @(Invoke-NativeHostParitySession `
                        -FilePath $script:ProducerCompiledExecutable `
                        -Cases $script:ProducerCases `
                        -PerMessageTimeoutSeconds 60 `
                        -TouchFilesByCase $candidateTouch `
                        -BeforeCaseScripts $candidateFreshCases)
            }
        }
    }

    AfterAll {
        if ($script:ProducerCreatedTask) {
            & schtasks.exe /Delete /TN $script:ProducerTaskName /F 2>$null | Out-Null
        }
        Remove-Item -LiteralPath $script:ProducerSentinel -Force -ErrorAction SilentlyContinue
    }

    Context 'Producer encodings' -Skip:(-not $script:ProducerPowerShellAvailable) {
        It 'Wrote every parsed file with its real producer' {
            foreach ($name in @('whitelist-mirror', 'config', 'native-state', 'overlay-ready', 'worker-state', 'queue-request', 'captive-marker', 'captive-observation')) {
                $entry = $script:ProducerCandidateMeta.producers.$name
                $entry | Should -Not -BeNullOrEmpty -Because $name
                $entry.exists | Should -BeTrue -Because $name
            }
            foreach ($name in @('config-bom', 'native-state-bom')) {
                $script:ProducerCandidateMeta.producers.$name.bom | Should -BeTrue -Because $name
                $script:ProducerReferenceMeta.producers.$name.bom | Should -BeTrue -Because "reference $name"
            }
            foreach ($name in @('overlay-ready', 'worker-state', 'queue-request', 'captive-marker')) {
                $script:ProducerCandidateMeta.producers.$name.bom | Should -BeTrue -Because "$name must carry the PowerShell 5.1 BOM"
                if ($script:ProducerCandidateMeta.producers.$name.error) {
                    Write-Host "producer warning [$name]: $($script:ProducerCandidateMeta.producers[$name].error)"
                }
            }
        }

        It 'Left the produced JSON readable by the reference parser' {
            foreach ($name in @('overlay-ready', 'worker-state', 'captive-marker')) {
                $path = $script:ProducerCandidateMeta.producers.$name.path
                $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                $parsed | Should -Not -BeNullOrEmpty -Because $name
            }
        }
    }

    Context 'Compiled host equivalence on producer files' -Skip:(-not $script:ProducerCompilerAvailable) {
        It 'Answers the producer sequence like the PowerShell host' {
            $script:ProducerCandidateResponses.Count | Should -Be $script:ProducerCases.Count
        }

        It 'Matches the reference: <ParityName>' -TestCases (@($script:ProducerCases | ForEach-Object { @{ ParityCase = $_; ParityName = $_.name } })) {
            param($ParityCase)
            $reference = @($script:ProducerReferenceResponses | Where-Object { $_.name -eq $ParityCase.name })
            $candidate = @($script:ProducerCandidateResponses | Where-Object { $_.name -eq $ParityCase.name })
            $reference.Count | Should -Be 1
            $candidate.Count | Should -Be 1
            $candidate[0].response | Should -Not -BeNullOrEmpty -Because $ParityCase.name
            $difference = Compare-NativeHostParityValue -Reference $reference[0].response -Candidate $candidate[0].response -MaskedKeys $script:ProducerMaskedKeys -ListFields $script:ProducerListFields
            if ($difference) {
                Write-Host ("PARITY-DIFF " + $ParityCase.name + " :: " + $difference)
                Write-Host ("PARITY-REF " + $ParityCase.name + " :: " + (($reference[0].response | ConvertTo-Json -Depth 10 -Compress)))
                Write-Host ("PARITY-CAND " + $ParityCase.name + " :: " + (($candidate[0].response | ConvertTo-Json -Depth 10 -Compress)))
            }
            $difference | Should -Be '' -Because $ParityCase.name
        }

        It 'Keeps the enqueue fast path: workerTriggered=false with a fresh worker' {
            $candidate = @($script:ProducerCandidateResponses | Where-Object { $_.name -eq 'probe-dependency-enqueue-pending' })[0].response
            $candidate.workerTriggered | Should -BeFalse
        }

        It 'Never ran the scheduled task sentinel while the worker was fresh' {
            if ($script:ProducerCreatedTask) {
                Start-Sleep -Seconds 2
                Test-Path -LiteralPath $script:ProducerSentinel | Should -BeFalse -Because 'schtasks /Run on every enqueue was the 2B B3 regression'
            }
            else {
                Write-Host 'schtasks sentinel task unavailable (name busy or task creation failed); workerTriggered assertion still ran.'
            }
        }

        It 'Deduplicates a queue request written by the PowerShell host' {
            $queueDir = Join-Path $script:ProducerCandidateFixture.Data 'runtime-dependency-queue'
            $queueFiles = @(Get-ChildItem -LiteralPath $queueDir -Filter '*.json' -File)
            $queueddepFiles = @($queueFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'queueddep\.parity\.invalid' })
            $queueddepFiles.Count | Should -Be 1 -Because 'the C# host must find the BOM-prefixed request the PowerShell host queued'
            $queueddepFiles[0].Name | Should -Be 'parity-fixed-request.json'
            $candidate = @($script:ProducerCandidateResponses | Where-Object { $_.name -eq 'probe-dependency-queue-dedup' })[0].response
            if ($candidate) {
                ([string]$candidate.requestPath) | Should -BeLike '*parity-fixed-request.json'
            }
        }
    }
}
