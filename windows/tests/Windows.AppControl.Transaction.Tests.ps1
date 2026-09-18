Get-Module AppControl.Transaction | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.Transaction.psm1') -Force -Global

Describe 'AppControl transaction journal' {
    BeforeEach {
        # AppControl imports this dependency privately during the combined suite;
        # restore the public test surface before each direct transaction assertion.
        Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.Transaction.psm1') -Force -Global
    }

    It 'writes immutable snapshots and a prepared journal before apply' {
        $root = Join-Path $TestDrive 'openpath'
        $tx = New-OpenPathAppControlTransaction -OpenPathRoot $root -LocalPolicyXml '<AppLockerPolicy Version="1" />' -EffectivePolicyXml '<AppLockerPolicy Version="1" />'
        $tx.State | Should -Be 'prepared'
        Test-Path -LiteralPath $tx.BeforeLocal -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $tx.BeforeEffective -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $tx.StateFile -PathType Leaf | Should -BeTrue
        Write-OpenPathAppControlTransactionCandidate -Transaction $tx -CandidateXml '<AppLockerPolicy Version="1"><RuleCollection Type="Exe" /></AppLockerPolicy>' | Out-Null
        (Get-Content -LiteralPath $tx.Candidate -Raw) | Should -Match 'RuleCollection'
    }

    It 'marks recovery-required when rollback readback differs' {
        $root = Join-Path $TestDrive 'openpath'
        $tx = New-OpenPathAppControlTransaction -OpenPathRoot $root -LocalPolicyXml 'before' -EffectivePolicyXml 'effective'
        Write-OpenPathAppControlTransactionCandidate -Transaction $tx -CandidateXml 'candidate' | Out-Null
        Set-OpenPathAppControlTransactionState -Transaction $tx -State 'apply-attempted' | Out-Null
        $result = Invoke-OpenPathAppControlTransactionRollback -Transaction $tx -ApplyLocalPolicy { param($xml) } -ReadLocalPolicy { 'different' }
        $result | Should -BeFalse
        (Get-OpenPathAppControlTransaction -StateFile $tx.StateFile).State | Should -Be 'recovery-required'
    }

    It 'rejects a candidate write after apply-attempted without rewinding the journal' {
        $root = Join-Path $TestDrive 'openpath'
        $tx = New-OpenPathAppControlTransaction -OpenPathRoot $root -LocalPolicyXml 'before' -EffectivePolicyXml 'effective'
        Write-OpenPathAppControlTransactionCandidate -Transaction $tx -CandidateXml 'candidate' | Out-Null
        Set-OpenPathAppControlTransactionState -Transaction $tx -State 'apply-attempted' | Out-Null
        { Write-OpenPathAppControlTransactionCandidate -Transaction $tx -CandidateXml 'different' } | Should -Throw 'appcontrol_recovery_required'
        (Get-OpenPathAppControlTransaction -StateFile $tx.StateFile).State | Should -Be 'apply-attempted'
    }

    It 'reconciles an interrupted candidate only through verified before-policy readback' {
        $root = Join-Path $TestDrive 'reconcile'
        $tx = New-OpenPathAppControlTransaction -OpenPathRoot $root -LocalPolicyXml 'before' -EffectivePolicyXml 'effective'
        Write-OpenPathAppControlTransactionCandidate -Transaction $tx -CandidateXml 'candidate' | Out-Null
        Set-OpenPathAppControlTransactionState -Transaction $tx -State 'apply-attempted' | Out-Null
        $applyCalls = [ref]0
        $readCalls = [ref]0
        $result = Invoke-OpenPathAppControlTransactionRecovery -OpenPathRoot $root -ApplyLocalPolicy {
            param($snapshot)
            $applyCalls.Value++
        } -ReadLocalPolicy {
            $readCalls.Value++
            if ($readCalls.Value -eq 1) { 'candidate' } else { 'before' }
        } -ComparePolicy {
            param($expected, $actual)
            $expected -eq $actual
        }
        $result.Resolved | Should -BeTrue
        $result.Pending.Count | Should -Be 0
        $applyCalls.Value | Should -Be 1
        (Get-OpenPathAppControlTransaction -StateFile $tx.StateFile).State | Should -Be 'rolled-back'
    }

    It 'leaves an interrupted journal recovery-required when local policy drift is not attributable' {
        $root = Join-Path $TestDrive 'drift'
        $tx = New-OpenPathAppControlTransaction -OpenPathRoot $root -LocalPolicyXml 'before' -EffectivePolicyXml 'effective'
        Write-OpenPathAppControlTransactionCandidate -Transaction $tx -CandidateXml 'candidate' | Out-Null
        Set-OpenPathAppControlTransactionState -Transaction $tx -State 'apply-attempted' | Out-Null
        Set-OpenPathAppControlTransactionState -Transaction $tx -State 'applied' | Out-Null
        $result = Invoke-OpenPathAppControlTransactionRecovery -OpenPathRoot $root -ApplyLocalPolicy { param($snapshot) } -ReadLocalPolicy { 'unrelated-policy' } -ComparePolicy {
            param($expected, $actual)
            $expected -eq $actual
        }
        $result.Resolved | Should -BeFalse
        (Get-OpenPathAppControlTransaction -StateFile $tx.StateFile).State | Should -Be 'recovery-required'
    }

    It 'returns busy without applying when the same machine lock is held' {
        $root = Join-Path $TestDrive 'openpath'
        $first = Enter-OpenPathAppControlTransaction -OpenPathRoot $root -TimeoutMilliseconds 100
        try {
            $second = Enter-OpenPathAppControlTransaction -OpenPathRoot $root -TimeoutMilliseconds 1
            $second.Acquired | Should -BeFalse
            $second.ReasonCode | Should -Be 'appcontrol_transaction_busy'
        }
        finally { Exit-OpenPathAppControlTransaction -Lock $first }
    }

    It 'serializes two processes and reports an abandoned owner' {
        $childHost = (Get-Command pwsh -ErrorAction SilentlyContinue)
        if ($null -eq $childHost) { $childHost = Get-Command powershell.exe -ErrorAction SilentlyContinue }
        if ($null -eq $childHost) {
            Set-ItResult -Skipped -Because 'No second PowerShell host is available for the process boundary test.'
            return
        }

        $root = Join-Path $TestDrive 'root-one'
        $otherRoot = Join-Path $TestDrive 'root-two'
        $childScript = Join-Path $TestDrive 'hold-transaction.ps1'
        $signalPath = Join-Path $TestDrive 'child-ready.txt'
        @'
param([string]$ModulePath, [string]$Root, [string]$SignalPath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force -Global
$lock = Enter-OpenPathAppControlTransaction -OpenPathRoot $Root -TimeoutMilliseconds 5000
if (-not $lock.Acquired) { [IO.File]::WriteAllText($SignalPath, 'failed'); exit 3 }
[IO.File]::WriteAllText($SignalPath, 'ready')
Start-Sleep -Seconds 10
'@ | Set-Content -LiteralPath $childScript -Encoding UTF8

        $child = Start-Process -FilePath $childHost.Source -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $childScript,
            (Join-Path $PSScriptRoot '..\lib\AppControl.Transaction.psm1'), $root, $signalPath
        ) -PassThru
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath $signalPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            (Get-Content -LiteralPath $signalPath -Raw).Trim() | Should -Be 'ready'

            $busy = Enter-OpenPathAppControlTransaction -OpenPathRoot $otherRoot -TimeoutMilliseconds 100
            $busy.Acquired | Should -BeFalse
            $busy.ReasonCode | Should -Be 'appcontrol_transaction_busy'

            Stop-Process -Id $child.Id -Force
            Wait-Process -Id $child.Id -Timeout 5 -ErrorAction SilentlyContinue
            $abandoned = Enter-OpenPathAppControlTransaction -OpenPathRoot $otherRoot -TimeoutMilliseconds 1000
            try {
                $abandoned.Acquired | Should -BeTrue
                $hostIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -or [string]$env:OS -eq 'Windows_NT'
                if ($hostIsWindows) { $abandoned.Abandoned | Should -BeTrue }
                else { $abandoned.Abandoned | Should -BeIn @($false, $true) }
            }
            finally { Exit-OpenPathAppControlTransaction -Lock $abandoned }
        }
        finally {
            if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}
