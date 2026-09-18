Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.psm1') -Force -Global
if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Set-AppLockerPolicy { param($XMLPolicy, $ErrorAction) } }
if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Get-AppLockerPolicy { param([switch]$Local, [switch]$Effective, [switch]$Xml, $ErrorAction); '<AppLockerPolicy Version="1" />' } }

Describe 'AppControl recovery integration' {
    BeforeAll {
        # AppControl.Tests reloads the module during its own execution; load
        # the public surface and its platform shims immediately before these
        # integration assertions run in a combined Pester shard.
        Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.psm1') -Force -Global -ErrorAction Stop
        if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Set-AppLockerPolicy { param($XMLPolicy, $ErrorAction) } }
        if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Get-AppLockerPolicy { param([switch]$Local, [switch]$Effective, [switch]$Xml, $ErrorAction); '<AppLockerPolicy Version="1" />' } }
    }

    It 'blocks a new public mutation while an incomplete journal is pending' {
        InModuleScope AppControl {
            $root = Join-Path $TestDrive 'openpath'
            New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
            [ordered]@{
                installState = 'complete'
                appControlProfile = 'ManagedBrowserCompatibility'
                nonAdminAppControlMode = 'Enforced'
                appControlCommitState = 'committed'
                activeAppControlProfile = 'ManagedBrowserCompatibility'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'data/config.json')
            $transaction = New-OpenPathAppControlTransaction -OpenPathRoot $root -LocalPolicyXml '<AppLockerPolicy Version="1" />' -EffectivePolicyXml '<AppLockerPolicy Version="1" />'
            Write-OpenPathAppControlTransactionCandidate -Transaction $transaction -CandidateXml '<AppLockerPolicy Version="1" />' | Out-Null
            Set-OpenPathAppControlTransactionState -Transaction $transaction -State 'apply-attempted' | Out-Null
            Set-OpenPathAppControlTransactionState -Transaction $transaction -State 'recovery-required' -ReasonCodes @('appcontrol_recovery_required') | Out-Null
            Mock Test-AdminPrivileges { $true }
            Mock Test-OpenPathAppControlAvailable { $true }
            Mock Set-AppLockerPolicy {}
            $result = Set-OpenPathNonAdminAppControl -OpenPathRoot $root -Confirm:$false
            $result | Should -BeFalse
            Should -Invoke Set-AppLockerPolicy -Times 0 -Exactly
            @((Get-OpenPathAppControlPendingRecovery -OpenPathRoot $root)).Count | Should -Be 1
        }
    }

    It 'reports malformed journals as recovery-required rather than no pending work' {
        InModuleScope AppControl {
            $root = Join-Path $TestDrive 'malformed'
            $journal = Join-Path (Join-Path $root 'data') 'appcontrol-transactions/bad/state.json'
            New-Item -ItemType Directory -Path (Split-Path $journal -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($journal, '{"State":"prepared"}')
            $pending = @(Get-OpenPathAppControlPendingRecovery -OpenPathRoot $root)
            $pending.Count | Should -Be 1
            $pending[0].State | Should -Be 'recovery-required'
        }
    }
}
