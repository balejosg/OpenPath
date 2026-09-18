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
        $result = Invoke-OpenPathAppControlTransactionRollback -Transaction $tx -ApplyLocalPolicy { param($xml) } -ReadLocalPolicy { 'different' }
        $result | Should -BeFalse
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
}
