BeforeAll {
    foreach ($commandName in @('Enable-ScheduledTask','Disable-ScheduledTask')) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) { Set-Item -Path "Function:global:$commandName" -Value { param() } }
    }
    Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\DisposableWindowsTarget.psm1') -Force
    . (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-policy-converter-contrast.ps1')
}

Describe 'PolicyConverter hosted contrast wrapper' {
    BeforeEach {
        $script:snapshots = @(
            [pscustomobject]@{ status='observed'; task=[pscustomobject]@{ queryStatus='observed'; exists=$true; enabled=$false }; service=[pscustomobject]@{ queryStatus='observed'; state='Stopped'; processId=0 } },
            [pscustomobject]@{ status='observed'; task=[pscustomobject]@{ queryStatus='observed'; exists=$true; enabled=$true }; service=[pscustomobject]@{ queryStatus='observed'; state='Stopped'; processId=0 } },
            [pscustomobject]@{ status='observed'; task=[pscustomobject]@{ queryStatus='observed'; exists=$true; enabled=$true }; service=[pscustomobject]@{ queryStatus='observed'; state='Running'; processId=1234 } },
            [pscustomobject]@{ status='observed'; task=[pscustomobject]@{ queryStatus='observed'; exists=$true; enabled=$false }; service=[pscustomobject]@{ queryStatus='observed'; state='Running'; processId=1234 } }
        )
        $script:index = 0
        $script:trace = [System.Collections.Generic.List[string]]::new()
        $script:childMode = $null
        Mock Get-OpenPathDisposablePolicyConverterObservation { $value=$script:snapshots[$script:index]; $script:index++; $value }
        Mock Get-OpenPathContrastPolicySnapshot { [pscustomobject]@{ status='observed'; appLocker=[pscustomobject]@{ policy=[pscustomobject]@{ policySha256='abc'; ruleCollections=@() } } } }
        Mock Get-OpenPathContrastHostContext { [pscustomobject]@{ hostedRunner=$true; runnerEnvironment='github-hosted'; imageOS='win25'; imageVersion='x'; bootTimeUtc='2026-09-13T00:00:00.0000000Z' } }
        Mock Get-FileHash { [pscustomobject]@{ Hash=if($LiteralPath -like '*probe*'){'PROBE'}else{'EXE'} } }
        Mock Enable-ScheduledTask { $script:trace.Add('enable') }
        Mock Disable-ScheduledTask { $script:trace.Add('restore') }
        Mock Invoke-OpenPathContrastChild { param($ExecutablePath,$ProbePayloadPath,$ChildEvidencePath,$TargetUserName,$PolicyConverterMode); $script:childMode=$PolicyConverterMode; $script:trace.Add('child'); [pscustomobject]@{ exitCode=1; evidenceAvailable=$true } }
        Mock Write-OpenPathContrastEvidence {}
    }

    It 'delegates Started treatment to the child after a cold baseline' {
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Started -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json' -TargetUserName 'op-e2e-converter'

        $result.status | Should -Be 'observed'
        $result.childExitCode | Should -Be 1
        $result.snapshots.beforeIntervention.task.enabled | Should -BeFalse
        $result.snapshots.beforeChild.task.enabled | Should -BeFalse
        $script:childMode | Should -Be 'Started'
        $script:trace | Should -Be @('child')
        Should -Invoke Enable-ScheduledTask -Times 0 -Exactly
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
        Should -Invoke Write-OpenPathContrastEvidence -Times 1 -Exactly
    }

    It 'does not coerce an unavailable baseline task to false or invoke the child' {
        $failed = [pscustomobject]@{ status='observed'; task=[pscustomobject]@{ queryStatus='failed'; exists=$null; enabled=$null }; service=[pscustomobject]@{ queryStatus='observed'; state='Stopped'; processId=0 } }
        $script:snapshots = @($failed,$failed,$failed)

        $result = Invoke-OpenPathPolicyConverterContrast -Mode Untouched -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json' -TargetUserName 'op-e2e-converter'

        $result.status | Should -Be 'baseline-not-comparable'
        $result.snapshots.beforeIntervention.task.enabled | Should -BeNullOrEmpty
        Should -Invoke Invoke-OpenPathContrastChild -Times 0 -Exactly
    }

    It 'rejects a stopped service whose PID is missing or stale' -ForEach @(
        @{ ServiceProcessId=$null; Label='missing' },
        @{ ServiceProcessId=8124; Label='stale' }
    ) {
        $cold = [pscustomobject]@{ status='observed'; task=[pscustomobject]@{ queryStatus='observed'; exists=$true; enabled=$false }; service=[pscustomobject]@{ queryStatus='observed'; state='Stopped'; processId=$ServiceProcessId } }
        $script:snapshots = @($cold,$cold,$cold)
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Untouched -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json'
        $result.status | Should -Be 'baseline-not-comparable'
        $result.code | Should -Be 'cold-baseline-not-observed'
        Should -Invoke Invoke-OpenPathContrastChild -Times 0 -Exactly
    }

    It 'runs the control without task mutation' {
        $script:snapshots = @($script:snapshots[0],$script:snapshots[0],$script:snapshots[2],$script:snapshots[2])
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Untouched -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json'
        $result.status | Should -Be 'observed'
        Should -Invoke Enable-ScheduledTask -Times 0 -Exactly
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }

    It 'records child invocation failure without wrapper-owned restoration' {
        Mock Invoke-OpenPathContrastChild { $script:trace.Add('child'); throw 'child-launch-failed' }
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Started -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json'
        $result.status | Should -Be 'child-evidence-unavailable'
        $script:trace | Should -Be @('child')
    }

    It 'writes evidence when the after-child snapshot throws' {
        Mock Get-OpenPathDisposablePolicyConverterObservation {
            if ($Context -eq 'contrast-after-child') { throw 'snapshot-failed' }
            if ($Context -eq 'contrast-after-restoration') { return $script:snapshots[3] }
            $value=$script:snapshots[$script:index]; $script:index++; $value
        }
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Started -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json'
        $result.childExitCode | Should -Be 1
        $result.snapshots.afterChild.status | Should -Be 'unavailable'
        $result.snapshots.afterChild.reason | Should -Be 'policy-converter-observer-failed'
        $result.restoration.succeeded | Should -BeNullOrEmpty
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
        Should -Invoke Write-OpenPathContrastEvidence -Times 1 -Exactly
    }

    It 'preserves child-owned restoration when wrapper verification query fails' {
        Mock Get-OpenPathDisposablePolicyConverterObservation {
            if ($Context -eq 'contrast-after-restoration') { throw 'snapshot-failed' }
            $value=$script:snapshots[$script:index]; $script:index++; $value
        }
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Started -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json'
        $result.snapshots.afterRestoration.status | Should -Be 'unavailable'
        $result.restoration.succeeded | Should -BeNullOrEmpty
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }

    It 'stops before intervention when either input hash mismatches' {
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Started -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 WRONG -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json'
        $result.status | Should -Be 'baseline-not-comparable'
        $result.code | Should -Be 'contrast-input-hash-mismatch'
        Should -Invoke Enable-ScheduledTask -Times 0 -Exactly
        Should -Invoke Invoke-OpenPathContrastChild -Times 0 -Exactly
    }

    It 'refuses to run the experiment outside a GitHub-hosted runner' {
        Mock Get-OpenPathContrastHostContext { [pscustomobject]@{ hostedRunner=$false; runnerEnvironment='self-hosted'; imageOS=''; imageVersion=''; bootTimeUtc='2026-09-13T00:00:00.0000000Z' } }
        $result = Invoke-OpenPathPolicyConverterContrast -Mode Started -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath 'C:\wrapper.json'
        $result.status | Should -Be 'baseline-not-comparable'
        $result.code | Should -Be 'github-hosted-runner-required'
        Should -Invoke Enable-ScheduledTask -Times 0 -Exactly
        Should -Invoke Invoke-OpenPathContrastChild -Times 0 -Exactly
    }

    It 'writes the actual failure-path result with null baseline fields intact' {
        $failed = [pscustomobject]@{ status='observed'; task=[pscustomobject]@{ queryStatus='failed'; exists=$null; enabled=$null }; service=[pscustomobject]@{ queryStatus='observed'; state='Stopped'; processId=0 } }
        $script:snapshots = @($failed,$failed,$failed)
        Mock Write-OpenPathContrastEvidence { Write-OpenPathOfflineInstallerEvidence -Payload $Payload -Path $Path } -ParameterFilter { $Path -eq $script:actualEvidencePath }
        $path = Join-Path $TestDrive 'wrapper.json'
        $script:actualEvidencePath = $path
        $null = Invoke-OpenPathPolicyConverterContrast -Mode Untouched -ExecutablePath 'C:\fixture.exe' -ProbePayloadPath 'C:\probe.exe' -ExpectedExecutableSha256 EXE -ExpectedProbePayloadSha256 PROBE -ChildEvidencePath 'C:\child.json' -EvidencePath $path
        $written = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $written.status | Should -Be 'baseline-not-comparable'
        $written.snapshots.beforeIntervention.task.enabled | Should -BeNullOrEmpty
    }


    It 'propagates an actual encoded child exit and restores inherited environment values' {
        $fixtureRoot = Join-Path $TestDrive 'fixture with spaces'
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        $fixture = Join-Path $fixtureRoot 'exit7-fixture.ps1'
        @'
param($ExecutablePath,$ExpectedClassroomId,$ExpectedApiUrl,$EvidencePath,$ProbePayloadPath,$TargetUserName)
exit 7
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
        $previous = [Environment]::GetEnvironmentVariable('OPENPATH_CONTRAST_EXECUTABLE','Process')
        [Environment]::SetEnvironmentVariable('OPENPATH_CONTRAST_EXECUTABLE','sentinel','Process')
        try {
            $result = Invoke-OpenPathEncodedContrastChild -HarnessPath $fixture -ExecutablePath (Join-Path $fixtureRoot 'input.exe') -ProbePayloadPath (Join-Path $fixtureRoot 'probe.exe') -ChildEvidencePath (Join-Path $fixtureRoot 'child.json') -TargetUserName 'op-e2e-converter'
            $result.exitCode | Should -Be 7
            [Environment]::GetEnvironmentVariable('OPENPATH_CONTRAST_EXECUTABLE','Process') | Should -Be 'sentinel'
        }
        finally { [Environment]::SetEnvironmentVariable('OPENPATH_CONTRAST_EXECUTABLE',$previous,'Process') }
    }
}
