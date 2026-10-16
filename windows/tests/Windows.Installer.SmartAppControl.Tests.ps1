Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

Describe 'Installer Smart App Control phase (Phase 8e E1)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'lib' 'install' 'Installer.Progress.ps1')
        . (Join-Path $PSScriptRoot '..' 'lib' 'install' 'Installer.SmartAppControl.ps1')
    }

    BeforeEach {
        $script:SacWriterCalls = New-Object System.Collections.ArrayList
        $script:SacCiToolCalls = New-Object System.Collections.ArrayList
        $script:SacStateCalls = 0
        $script:SacRegistryWriter = {
            param([string]$Name, [int]$Value)
            $null = $script:SacWriterCalls.Add([pscustomobject]@{ Name = $Name; Value = $Value })
        }
        $script:SacCiToolInvoker = {
            param([string[]]$Arguments)
            $null = $script:SacCiToolCalls.Add((@($Arguments) -join ' '))
            if ($Arguments -contains '-lp') {
                return [pscustomobject]@{ ExitCode = 0; Output = 'Policies: none' ; Missing = $false }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = ''; Missing = $false }
        }
        $script:SacStateReaderEvaluationThenOff = {
            $script:SacStateCalls = [int]$script:SacStateCalls + 1
            if ([int]$script:SacStateCalls -le 1) {
                return [pscustomobject]@{ State = 'evaluation'; VerifiedAndReputableState = 2 }
            }
            return [pscustomobject]@{ State = 'off'; VerifiedAndReputableState = 0 }
        }
    }

    Context 'No silent changes' {
        It 'Does nothing when Smart App Control is off or not configured' {
            foreach ($state in @('off', 'not-configured')) {
                $script:SacWriterCalls.Clear() | Out-Null
                $stateReader = { [pscustomobject]@{ State = $state; VerifiedAndReputableState = 0 } }.GetNewClosure()
                $outcome = Invoke-OpenPathSmartAppControlStep `
                    -StateReader $stateReader `
                    -RegistryWriter $script:SacRegistryWriter `
                    -CiToolInvoker $script:SacCiToolInvoker
                $outcome.PreviousState | Should -Be $state
                $outcome.Action | Should -Be 'none'
                $outcome.Result | Should -Be 'not-needed'
                @($script:SacWriterCalls).Count | Should -Be 0
                @($script:SacCiToolCalls).Count | Should -Be 0
            }
        }

        It 'Leaves SAC untouched in an unattended install without the explicit switch' {
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -Unattended `
                -StateReader { [pscustomobject]@{ State = 'evaluation'; VerifiedAndReputableState = 2 } } `
                -RegistryWriter $script:SacRegistryWriter `
                -CiToolInvoker $script:SacCiToolInvoker
            $outcome.PreviousState | Should -Be 'evaluation'
            $outcome.Action | Should -Be 'none'
            $outcome.Result | Should -Be 'not-requested'
            $outcome.Warning | Should -Match 'DisableSmartAppControl'
            @($script:SacWriterCalls).Count | Should -Be 0
            @($script:SacCiToolCalls).Count | Should -Be 0
        }

        It 'Never disables SAC when the interactive operator answers no' {
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -StateReader { [pscustomobject]@{ State = 'enforcement'; VerifiedAndReputableState = 1 } } `
                -RegistryWriter $script:SacRegistryWriter `
                -CiToolInvoker $script:SacCiToolInvoker `
                -Prompt { return $false }
            $outcome.Action | Should -Be 'declined'
            $outcome.Result | Should -Be 'not-applied'
            @($script:SacWriterCalls).Count | Should -Be 0
            @($script:SacCiToolCalls).Count | Should -Be 0
        }

        It 'Never disables SAC without any decision, across states and modes' {
            foreach ($state in @('evaluation', 'enforcement')) {
                foreach ($mode in @('unattended', 'interactive-no')) {
                    $script:SacWriterCalls.Clear() | Out-Null
                    $parameters = @{
                        StateReader    = { [pscustomobject]@{ State = $state; VerifiedAndReputableState = 2 } }.GetNewClosure()
                        RegistryWriter = $script:SacRegistryWriter
                        CiToolInvoker  = $script:SacCiToolInvoker
                    }
                    if ($mode -eq 'unattended') { $parameters['Unattended'] = $true }
                    else { $parameters['Prompt'] = { return $false }.GetNewClosure() }
                    $outcome = Invoke-OpenPathSmartAppControlStep @parameters
                    $outcome.Action | Should -Not -Be 'disabled'
                    @($script:SacWriterCalls).Count | Should -Be 0 -Because "$state/$mode"
                }
            }
        }
    }

    Context 'Explicit decision' {
        It 'Disables and verifies SAC in an unattended install with the explicit switch' {
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -Unattended `
                -DisableSmartAppControl `
                -StateReader $script:SacStateReaderEvaluationThenOff `
                -RegistryWriter $script:SacRegistryWriter `
                -CiToolInvoker $script:SacCiToolInvoker
            $outcome.PreviousState | Should -Be 'evaluation'
            $outcome.Action | Should -Be 'disabled'
            $outcome.Result | Should -Be 'verified'
            $outcome.RebootRequired | Should -BeFalse
            @($script:SacWriterCalls).Count | Should -Be 1
            $script:SacWriterCalls[0].Name | Should -Be 'VerifiedAndReputablePolicyState'
            $script:SacWriterCalls[0].Value | Should -Be 0
            @($script:SacCiToolCalls).Count | Should -Be 2
            $script:SacCiToolCalls[0] | Should -Be '-r'
            $script:SacCiToolCalls[1] | Should -Be '-lp'
        }

        It 'Disables SAC in an interactive install only on an explicit yes' {
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -DisableSmartAppControl:$false `
                -StateReader $script:SacStateReaderEvaluationThenOff `
                -RegistryWriter $script:SacRegistryWriter `
                -CiToolInvoker $script:SacCiToolInvoker `
                -Prompt { return $true }
            $outcome.Action | Should -Be 'disabled'
            $outcome.Result | Should -Be 'verified'
            @($script:SacWriterCalls).Count | Should -Be 1
        }

        It 'Reports a reboot requirement when CiTool cannot refresh or verify' {
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -Unattended `
                -DisableSmartAppControl `
                -StateReader $script:SacStateReaderEvaluationThenOff `
                -RegistryWriter $script:SacRegistryWriter `
                -CiToolInvoker {
                    param([string[]]$Arguments)
                    if ($Arguments -contains '-lp') { return [pscustomobject]@{ ExitCode = 0; Output = 'Policies: VerifiedAndReputable' ; Missing = $false } }
                    return [pscustomobject]@{ ExitCode = -1; Output = ''; Missing = $true }
                }
            $outcome.Action | Should -Be 'disabled'
            $outcome.Result | Should -Be 'reboot-required'
            $outcome.RebootRequired | Should -BeTrue
            $outcome.Warning | Should -Match 'reboot'
        }
    }

    Context 'Installer wiring' {
        It 'Declares the phase in the plan and runs it right after preflight' {
            $installerPath = Join-Path $PSScriptRoot '..' 'Install-OpenPath.ps1'
            $planPath = Join-Path $PSScriptRoot '..' 'lib' 'install' 'Installer.Plan.ps1'
            $installer = Get-Content -LiteralPath $installerPath -Raw
            $plan = Get-Content -LiteralPath $planPath -Raw

            $plan | Should -Match "-Name 'smart-app-control'"
            $installer | Should -Match "Invoke-OpenPathPlannedPhase -Name 'smart-app-control'"
            $installer | Should -Match "Installer.SmartAppControl.ps1"
            $installer | Should -Match '\[switch\]\$DisableSmartAppControl'

            $preflightIndex = $installer.IndexOf("Invoke-OpenPathPlannedPhase -Name 'preflight'")
            $sacIndex = $installer.IndexOf("Invoke-OpenPathPlannedPhase -Name 'smart-app-control'")
            $directoriesIndex = $installer.IndexOf("Invoke-OpenPathPlannedPhase -Name 'directories'")
            ($preflightIndex -ge 0) | Should -BeTrue
            ($sacIndex -gt $preflightIndex) | Should -BeTrue
            ($directoriesIndex -gt $sacIndex) | Should -BeTrue
        }

        It 'Persists the decision with the config and records it in the product log' {
            $configHelper = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'lib' 'install' 'Installer.Config.ps1') -Raw
            $installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'Install-OpenPath.ps1') -Raw
            $configHelper | Should -Match 'smartAppControl'
            $installer | Should -Match '-SmartAppControl \$script:smartAppControlOutcome'
            $installer | Should -Match 'Write-OpenPathSmartAppControlDecision'

            $script:SacLogLines = New-Object System.Collections.ArrayList
            function global:Write-OpenPathLog {
                param([Parameter(Mandatory = $true)][string]$Message, [string]$Level = 'INFO')
                $null = $script:SacLogLines.Add("$Level $Message")
            }
            try {
                Write-OpenPathSmartAppControlDecision -Outcome ([pscustomobject]@{
                        PreviousState  = 'evaluation'
                        Action         = 'disabled'
                        Result         = 'verified'
                        RebootRequired = $false
                        DecidedAtUtc   = '2026-10-13T00:00:00.0000000Z'
                    })
                @($script:SacLogLines).Count | Should -Be 1
                $script:SacLogLines[0] | Should -Match '^INFO '
                $script:SacLogLines[0] | Should -Match 'previous=evaluation'
                $script:SacLogLines[0] | Should -Match 'action=disabled'
                $script:SacLogLines[0] | Should -Match 'result=verified'
                $script:SacLogLines[0] | Should -Match 'decidedAt=2026-10-13T00:00:00.0000000Z'

                # Phase 8e: a decision that carries the unattended warning is
                # logged as WARN so the warning survives the install summary.
                Write-OpenPathSmartAppControlDecision -Outcome ([pscustomobject]@{
                        PreviousState  = 'evaluation'
                        Action         = 'none'
                        Result         = 'not-requested'
                        RebootRequired = $false
                        Warning        = 'Smart App Control is evaluation and -DisableSmartAppControl was not passed'
                        DecidedAtUtc   = '2026-10-13T00:00:01.0000000Z'
                    })
                @($script:SacLogLines).Count | Should -Be 2
                $script:SacLogLines[1] | Should -Match '^WARN '
                $script:SacLogLines[1] | Should -Match 'result=not-requested'
            }
            finally {
                Remove-Item function:global:Write-OpenPathLog -ErrorAction SilentlyContinue
            }
        }
        It 'Keeps the post-install SAC notice truthful, with evaluation and enforcement covered (Phase 8e E3)' {
            $installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'Install-OpenPath.ps1') -Raw
            $installer | Should -Not -Match 'Phase 8\.1'
            $installer | Should -Match "sacState\.State -in @\('evaluation', 'enforcement'\)"
            $installer | Should -Match 'windows/DEPLOYMENT\.md'
            $installer | Should -Not -Match 'Sign the native host'
        }

        It 'Gives CiTool a closed stdin and a bounded wait in the default invoker (Phase 8e)' {
            # The plain `& CiTool -r` invocation hangs forever in the hidden
            # installer child started by the NSIS (reproduced on VM 111 with
            # cpuMs=0): CiTool blocks on an invalid stdin handle. The default
            # invoker redirects and closes stdin and bounds the wait.
            $helper = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'lib' 'install' 'Installer.SmartAppControl.ps1') -Raw
            $helper | Should -Match 'RedirectStandardInput = \$true'
            $helper | Should -Match 'StandardInput\.Close\(\)'
            $helper | Should -Match 'WaitForExit\(60000\)'
            $helper | Should -Match 'TimedOut'
        }
    }


    Context 'CiTool listing parser and the second signal (Phase 8f F0)' {
        BeforeAll {
            # Literal `CiTool.exe -lp` text measured on VM 111 (run 38868428115,
            # sac-eval-off; identical in run 38868444409, sac-on-off, at both
            # sampled moments). The disabled VerifiedAndReputableDesktop policy
            # stays listed with 'Is Currently Enforced: false'.
            $script:SacListOff = @'
Policy:
    Policy ID: 0283ac0f-fff1-49ae-ada1-8a933130cad6
    Base Policy ID: 0283ac0f-fff1-49ae-ada1-8a933130cad6
    Friendly Name: VerifiedAndReputableDesktop
    Version: 0.0.0.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: false
    Is Authorized: false
    Status: 0
Policy:
    Policy ID: 1283ac0f-fff1-49ae-ada1-8a933130cad6
    Base Policy ID: 1283ac0f-fff1-49ae-ada1-8a933130cad6
    Friendly Name: VerifiedAndReputableDesktopEvaluation
    Version: 0.0.0.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: false
    Is Authorized: false
    Status: 0
Policy:
    Policy ID: 784c4414-79f4-4c32-a6a5-f0fb42a51d0d
    Base Policy ID: 784c4414-79f4-4c32-a6a5-f0fb42a51d0d
    Friendly Name: Microsoft Windows Cross Certificates for Code Integrity Exceptions Policy
    Version: 10.27766.0.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: true
    Is Authorized: true
    Status: 0
Policy:
    Policy ID: 82443e1e-8a39-4b4a-96a8-f40ddc00b9f3
    Base Policy ID: 82443e1e-8a39-4b4a-96a8-f40ddc00b9f3
    Friendly Name: WindowsE_Lockdown_Policy
    Version: 10.0.22117.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: false
    Is Authorized: false
    Status: 0
Policy:
    Policy ID: cdd5cb55-db68-4d71-aa38-3df2b6473a52
    Base Policy ID: 82443e1e-8a39-4b4a-96a8-f40ddc00b9f3
    Friendly Name: WindowsE_Lockdown_Test_Policy_Supplemental
    Version: 10.0.21349.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: false
    Is Authorized: false
    Status: 0
Policy:
    Policy ID: 5951a96a-e0b5-4d3d-8fb8-3e5b61030784
    Base Policy ID: 5951a96a-e0b5-4d3d-8fb8-3e5b61030784
    Friendly Name: Windows10S_Lockdown_Policy_Supplementable
    Version: 10.0.15039.0
'@
            # Literal output from run 38868461616 (sac-on-keep): the policy
            # block says 'Is Currently Enforced: true' (SAC enforced).
            $script:SacListOn = @'
Policy:
    Policy ID: 0283ac0f-fff1-49ae-ada1-8a933130cad6
    Base Policy ID: 0283ac0f-fff1-49ae-ada1-8a933130cad6
    Friendly Name: VerifiedAndReputableDesktop
    Version: 0.0.0.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: true
    Is Authorized: true
    Status: 0
Policy:
    Policy ID: 1283ac0f-fff1-49ae-ada1-8a933130cad6
    Base Policy ID: 1283ac0f-fff1-49ae-ada1-8a933130cad6
    Friendly Name: VerifiedAndReputableDesktopEvaluation
    Version: 0.0.0.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: false
    Is Authorized: false
    Status: 0
Policy:
    Policy ID: 784c4414-79f4-4c32-a6a5-f0fb42a51d0d
    Base Policy ID: 784c4414-79f4-4c32-a6a5-f0fb42a51d0d
    Friendly Name: Microsoft Windows Cross Certificates for Code Integrity Exceptions Policy
    Version: 10.27766.0.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: true
    Is Authorized: true
    Status: 0
Policy:
    Policy ID: 82443e1e-8a39-4b4a-96a8-f40ddc00b9f3
    Base Policy ID: 82443e1e-8a39-4b4a-96a8-f40ddc00b9f3
    Friendly Name: WindowsE_Lockdown_Policy
    Version: 10.0.22117.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: false
    Is Authorized: false
    Status: 0
Policy:
    Policy ID: cdd5cb55-db68-4d71-aa38-3df2b6473a52
    Base Policy ID: 82443e1e-8a39-4b4a-96a8-f40ddc00b9f3
    Friendly Name: WindowsE_Lockdown_Test_Policy_Supplemental
    Version: 10.0.21349.0
    Platform Policy: true
    Policy is Signed: true
    Has File on Disk: true
    Is Currently Enforced: false
    Is Authorized: false
    Status: 0
Policy:
    Policy ID: 5951a96a-e0b5-4d3d-8fb8-3e5b61030784
    Base Policy ID: 5951a96a-e0b5-4d3d-8fb8-3e5b61030784
    Friendly Name: Windows10S_Lockdown_Policy_Supplementable
    Version: 10.0.15039.0
'@
        }

        It 'Counts a VerifiedAndReputable policy as applied only while its block is enforced' {
            Test-OpenPathSmartAppControlPolicyApplied -ListOutput $script:SacListOff | Should -BeFalse
            Test-OpenPathSmartAppControlPolicyApplied -ListOutput $script:SacListOn | Should -BeTrue
            # The unrelated enforced policy in the same listing must not count.
            Test-OpenPathSmartAppControlPolicyApplied -ListOutput ($script:SacListOff.Replace('VerifiedAndReputableDesktop', 'SomeOtherPolicy')) | Should -BeFalse
            # A listing that names the policy without the enforcement field, and
            # empty/no-policy outputs, keep the fail-safe mapping.
            Test-OpenPathSmartAppControlPolicyApplied -ListOutput 'Policies: VerifiedAndReputable' | Should -BeTrue
            Test-OpenPathSmartAppControlPolicyApplied -ListOutput 'Policies: none' | Should -BeFalse
            Test-OpenPathSmartAppControlPolicyApplied -ListOutput '' | Should -BeFalse
        }

        It 'Verifies the disable from the real post-disable listing with umci at 0' {
            # 1c363288 passed the step only when `CiTool -lp` did *not* contain
            # the policy name, so this exact listing produced
            # `result=reboot-required` on the two flag scenes (openpath.log
            # 12:40:58 and 12:57:59, guest time) even though SAC was already
            # off. The listing plus umci=0 must verify.
            $script:SacF0Calls = 0
            $stateReader = {
                $script:SacF0Calls = [int]$script:SacF0Calls + 1
                if ([int]$script:SacF0Calls -le 1) {
                    return [pscustomobject]@{ State = 'evaluation'; VerifiedAndReputableState = 2; UsermodeCodeIntegrityPolicyEnforcementStatus = 1 }
                }
                return [pscustomobject]@{ State = 'off'; VerifiedAndReputableState = 0; UsermodeCodeIntegrityPolicyEnforcementStatus = 0 }
            }
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -Unattended `
                -DisableSmartAppControl `
                -StateReader $stateReader `
                -RegistryWriter { param([string]$Name, [int]$Value) } `
                -CiToolInvoker {
                    param([string[]]$Arguments)
                    if ($Arguments -contains '-lp') { return [pscustomobject]@{ ExitCode = 0; Output = $script:SacListOff; Missing = $false } }
                    return [pscustomobject]@{ ExitCode = 0; Output = ''; Missing = $false }
                }
            $outcome.Action | Should -Be 'disabled'
            $outcome.Result | Should -Be 'verified'
            $outcome.RebootRequired | Should -BeFalse
            $outcome.Warning | Should -Be ''
        }

        It 'Requires a reboot when the listing and the Device Guard signal disagree' {
            $script:SacF0Calls = 0
            $stateReader = {
                $script:SacF0Calls = [int]$script:SacF0Calls + 1
                if ([int]$script:SacF0Calls -le 1) {
                    return [pscustomobject]@{ State = 'evaluation'; VerifiedAndReputableState = 2; UsermodeCodeIntegrityPolicyEnforcementStatus = 2 }
                }
                return [pscustomobject]@{ State = 'off'; VerifiedAndReputableState = 0; UsermodeCodeIntegrityPolicyEnforcementStatus = 2 }
            }
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -Unattended `
                -DisableSmartAppControl `
                -StateReader $stateReader `
                -RegistryWriter { param([string]$Name, [int]$Value) } `
                -CiToolInvoker {
                    param([string[]]$Arguments)
                    if ($Arguments -contains '-lp') { return [pscustomobject]@{ ExitCode = 0; Output = $script:SacListOff; Missing = $false } }
                    return [pscustomobject]@{ ExitCode = 0; Output = ''; Missing = $false }
                }
            $outcome.Result | Should -Be 'reboot-required'
            $outcome.RebootRequired | Should -BeTrue
            $outcome.Warning | Should -Match 'UsermodeCodeIntegrityPolicyEnforcementStatus=2'
            $outcome.Warning | Should -Match 'disagree'
        }

        It 'Keeps a still-enforced policy a reboot requirement' {
            $script:SacF0Calls = 0
            $stateReader = {
                $script:SacF0Calls = [int]$script:SacF0Calls + 1
                if ([int]$script:SacF0Calls -le 1) {
                    return [pscustomobject]@{ State = 'enforcement'; VerifiedAndReputableState = 1; UsermodeCodeIntegrityPolicyEnforcementStatus = 2 }
                }
                return [pscustomobject]@{ State = 'off'; VerifiedAndReputableState = 0; UsermodeCodeIntegrityPolicyEnforcementStatus = 0 }
            }
            $outcome = Invoke-OpenPathSmartAppControlStep `
                -Unattended `
                -DisableSmartAppControl `
                -StateReader $stateReader `
                -RegistryWriter { param([string]$Name, [int]$Value) } `
                -CiToolInvoker {
                    param([string[]]$Arguments)
                    if ($Arguments -contains '-lp') { return [pscustomobject]@{ ExitCode = 0; Output = $script:SacListOn; Missing = $false } }
                    return [pscustomobject]@{ ExitCode = 0; Output = ''; Missing = $false }
                }
            $outcome.Result | Should -Be 'reboot-required'
            $outcome.Warning | Should -Match 'still reports an enforced VerifiedAndReputable policy'
        }
    }
}
