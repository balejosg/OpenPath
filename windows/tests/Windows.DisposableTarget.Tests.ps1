BeforeAll {
    foreach ($commandName in @(
        'Get-LocalUser', 'New-LocalUser', 'Enable-LocalUser', 'Remove-LocalUser',
        'Get-LocalGroup', 'Get-LocalGroupMember', 'Add-LocalGroupMember',
        'Get-CimInstance', 'Remove-CimInstance',
        'Invoke-StudentExecutableTaskProbe'
    )) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            Set-Item -Path "Function:global:$commandName" -Value { param() }
        }
    }
    Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\DisposableWindowsTarget.psm1') -Force
}

Describe 'Canonical offline installer disposable target' {
    BeforeEach {
        $script:testSid = 'S-1-5-21-100-200-300-400'
        $script:testPath = Join-Path $TestDrive 'op-e2e-test'
        New-Item -ItemType Directory -Path $script:testPath -Force | Out-Null
        $script:testProfile = if (Get-Command New-CimInstance -ErrorAction SilentlyContinue) {
            New-CimInstance -ClassName Win32_UserProfile -Namespace root/cimv2 -ClientOnly -Property @{
                SID = $script:testSid
                LocalPath = $script:testPath
                Special = $false
                Loaded = $false
            }
        }
        else {
            [pscustomobject]@{ SID = $script:testSid; LocalPath = $script:testPath; Special = $false; Loaded = $false }
        }
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'op-e2e-test'; Enabled = $true; SID = $script:testSid } } -ModuleName DisposableWindowsTarget
        Mock Get-LocalGroup { [pscustomobject]@{ Name = 'Administrators' } } -ModuleName DisposableWindowsTarget
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = 'S-1-5-21-1-2-3-500' }) } -ModuleName DisposableWindowsTarget
        Mock Get-CimInstance {
            $script:testProfile
        } -ModuleName DisposableWindowsTarget
        Mock New-LocalUser { [pscustomobject]@{ Name = 'op-e2e-test'; SID = $script:testSid } } -ModuleName DisposableWindowsTarget
        Mock Enable-LocalUser {} -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathCreateDisposableProfile { $script:testPath } -ModuleName DisposableWindowsTarget
        Mock Grant-OpenPathDisposableTargetUserRight {} -ModuleName DisposableWindowsTarget
        Mock Revoke-OpenPathDisposableTargetUserRight {} -ModuleName DisposableWindowsTarget
        Mock Remove-CimInstance {} -ModuleName DisposableWindowsTarget
        Mock Remove-LocalUser {} -ModuleName DisposableWindowsTarget
        Mock Add-LocalGroupMember {} -ModuleName DisposableWindowsTarget
        Mock Start-Sleep {} -ModuleName DisposableWindowsTarget
    }

    It 'stores the denied PE control under edge boundary evidence without replacing the Edge cause' {
        $primary = [pscustomobject]@{ probeName='Canonical Edge deny'; failureCode='exact-student-process-observed-without-block-event'; executablePath='C:\Edge\msedge.exe'; studentSid=$script:testSid }
        $exception = [System.InvalidOperationException]::new('boundary-edge-execution-failed')
        $exception.Data['OpenPathEdgeBoundaryEvidence'] = $primary
        $control = [pscustomobject]@{ status='observed'; outcome='blocked'; executablePath='C:\Target\openpath-e2e-probe.exe'; studentSid=$script:testSid; policyReapplied=$false }
        Mock Invoke-OpenPathDisposableEdgeBoundaryDiagnostic { [pscustomobject]@{ attempts=@() } } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { $control } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid }

        $resolved = Resolve-OpenPathDisposableEdgeBoundaryFailure -Exception $exception -Target $target

        $resolved.initial.failureCode | Should -Be 'exact-student-process-observed-without-block-event'
        $resolved.deniedPeControl.outcome | Should -Be 'blocked'
        $resolved.deniedPeControl.policyReapplied | Should -BeFalse
    }

    It 'runs one direct Edge probe and one PE control after an actual native-observed 8001' {
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='must-not-serialize'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $failure = [ordered]@{
            failureDetailCode = 'boundary-edge-execution-failed'
            edgeBoundaryEvidence = [ordered]@{ initial = [ordered]@{ probeName='Canonical Edge deny'; executablePath=$edgePath; studentSid=$script:testSid } }
        }
        $lifecycle = [ordered]@{
            status='observed'
            window=[ordered]@{ launchRequestedAtUtc='2026-09-13T10:11:12.1234567Z'; captureEndedAtUtc='2026-09-13T10:12:02.7891234Z' }
            queries=[ordered]@{
                '8001'=[ordered]@{
                    status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1
                    events=@([ordered]@{ id=8001; recordId=201; timeCreatedUtc='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' })
                    nativePowerShellComparison=[ordered]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1; runtime=[ordered]@{ edition='Desktop'; version='5.1.26100'; bitness='64-bit'; processId=7722 } }
                }
            }
        }
        $script:postProbeArgs = $null
        Mock Invoke-StudentExecutableTaskProbe {
            param($ProbeName, $ExecutablePath, $StudentSid, $ProcessName, $Expectation, $SuppressFailureDiagnostics)
            $script:postProbeArgs = [pscustomobject]@{ ProbeName=$ProbeName; ExecutablePath=$ExecutablePath; StudentSid=$StudentSid; ProcessName=$ProcessName; Expectation=$Expectation; SuppressFailureDiagnostics=$SuppressFailureDiagnostics }
            [pscustomobject]@{ status='pass'; evidence=[pscustomobject]@{ correlatedEvent=[pscustomobject]@{ id=8004; observedPath=$edgePath; observedUserSid=$script:testSid } } }
        } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { [pscustomobject]@{ status='observed'; outcome='execution-observed'; studentSid=$script:testSid } } -ModuleName DisposableWindowsTarget

        $pair = Invoke-OpenPathDisposablePostApplicationPair -FailureResult $failure -Target $target -Lifecycle $lifecycle

        $pair.status | Should -Be 'observed'
        $pair.trigger | Should -Be 'actual-8001-with-native-match'
        $pair.anchor.id | Should -Be 8001
        $pair.anchor.recordId | Should -Be 201
        $pair.anchor.timeCreatedUtc | Should -Be '2026-09-13T10:11:43.4567891Z'
        $pair.edge.outcome | Should -Be 'blocked'
        $pair.deniedPeControl.outcome | Should -Be 'execution-observed'
        $pair.policyReapplied | Should -BeFalse
        Should -Invoke Invoke-StudentExecutableTaskProbe -ModuleName DisposableWindowsTarget -Times 1 -Exactly
        $script:postProbeArgs.ProbeName | Should -Be 'Post-application Edge deny'
        $script:postProbeArgs.ExecutablePath | Should -Be $edgePath
        $script:postProbeArgs.StudentSid | Should -Be $script:testSid
        $script:postProbeArgs.ProcessName | Should -Be 'msedge'
        $script:postProbeArgs.Expectation | Should -Be 'ExpectDenied'
        $script:postProbeArgs.SuppressFailureDiagnostics | Should -BeTrue
        Should -Invoke Invoke-OpenPathDisposableDeniedPeControl -ModuleName DisposableWindowsTarget -Times 1 -Exactly
        ($pair | ConvertTo-Json -Depth 14) | Should -Not -Match 'must-not-serialize|Password|UserName|rawMessage'
        $evidencePath = Join-Path $TestDrive 'post-application-pair.json'
        Write-OpenPathOfflineInstallerEvidence -Payload ([ordered]@{ failureDetailCode=$failure.failureDetailCode; appLockerPolicyLifecycle=$lifecycle; postApplicationPair=$pair; explicitNull=$null }) -Path $evidencePath
        $raw = Get-Content -LiteralPath $evidencePath -Raw
        $roundTrip = $raw | ConvertFrom-Json
        $raw | Should -Match '2026-09-13T10:11:43\.4567891Z'
        $roundTrip.postApplicationPair.anchor.recordId | Should -Be 201
        $roundTrip.appLockerPolicyLifecycle.queries.'8001'.nativePowerShellComparison.runtime.version | Should -Be '5.1.26100'
        $roundTrip.appLockerPolicyLifecycle.queries.'8001'.nativePowerShellComparison.runtime.PSObject.Properties['supported'] | Should -BeNullOrEmpty
        $roundTrip.explicitNull | Should -BeNullOrEmpty
    }

    It 'does not call a non-deny or mismatched returned Edge correlation blocked' -ForEach @(
        @{ case='absent'; id=$null; path=$null; sid=$null }
        @{ case='allow audit'; id=8002; path='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; sid='S-1-5-21-100-200-300-400' }
        @{ case='wrong path'; id=8004; path='C:\other\msedge.exe'; sid='S-1-5-21-100-200-300-400' }
        @{ case='wrong sid'; id=8004; path='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; sid='S-1-5-21-wrong' }
    ) {
        param($case, $id, $path, $sid)
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='must-not-serialize'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $failure = [ordered]@{ failureDetailCode='boundary-edge-execution-failed'; edgeBoundaryEvidence=[ordered]@{ initial=[ordered]@{ probeName='Canonical Edge deny'; executablePath=$edgePath; studentSid=$script:testSid } } }
        $lifecycle = [ordered]@{ status='observed'; window=[ordered]@{ launchRequestedAtUtc='2026-09-13T10:11:12.1234567Z'; captureEndedAtUtc='2026-09-13T10:12:02.7891234Z' }; queries=[ordered]@{ '8001'=[ordered]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1; events=@([ordered]@{ id=8001; recordId=201; timeCreatedUtc='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }); nativePowerShellComparison=[ordered]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1 } } } }
        $script:postCorrelation = if ($null -eq $id) { $null } else { [pscustomobject]@{ id=$id; observedPath=$path; observedUserSid=$sid } }
        Mock Invoke-StudentExecutableTaskProbe { [pscustomobject]@{ status='pass'; evidence=[pscustomobject]@{ correlatedEvent=$script:postCorrelation } } } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { [pscustomobject]@{ status='observed'; outcome='blocked' } } -ModuleName DisposableWindowsTarget

        $pair = Invoke-OpenPathDisposablePostApplicationPair -FailureResult $failure -Target $target -Lifecycle $lifecycle

        $pair.edge.outcome | Should -Be 'inconclusive' -Because $case
        Should -Invoke Invoke-StudentExecutableTaskProbe -ModuleName DisposableWindowsTarget -Times 1 -Exactly
        Should -Invoke Invoke-OpenPathDisposableDeniedPeControl -ModuleName DisposableWindowsTarget -Times 1 -Exactly
    }

    It 'records distinct bounded PE fallback timestamps without replacing the pair result' {
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='must-not-serialize'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $failure = [ordered]@{ failureDetailCode='boundary-edge-execution-failed'; edgeBoundaryEvidence=[ordered]@{ initial=[ordered]@{ probeName='Canonical Edge deny'; executablePath=$edgePath; studentSid=$script:testSid } } }
        $lifecycle = [ordered]@{ status='observed'; window=[ordered]@{ launchRequestedAtUtc='2026-09-13T10:11:12.1234567Z'; captureEndedAtUtc='2026-09-13T10:12:02.7891234Z' }; queries=[ordered]@{ '8001'=[ordered]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1; events=@([ordered]@{ id=8001; recordId=201; timeCreatedUtc='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }); nativePowerShellComparison=[ordered]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1 } } } }
        Mock Invoke-StudentExecutableTaskProbe { [pscustomobject]@{ status='pass'; evidence=[pscustomobject]@{ correlatedEvent=$null } } } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { throw 'unsafe-pe-error' } -ModuleName DisposableWindowsTarget

        $pair = Invoke-OpenPathDisposablePostApplicationPair -FailureResult $failure -Target $target -Lifecycle $lifecycle

        $pair.status | Should -Be 'observed'
        $pair.deniedPeControl.status | Should -Be 'unavailable'
        [datetime]$pair.deniedPeControl.startedAtUtc | Should -BeLessOrEqual ([datetime]$pair.deniedPeControl.endedAtUtc)
        ($pair | ConvertTo-Json -Depth 14) | Should -Not -Match 'unsafe-pe-error'
    }

    It 'still runs PE once when the single post-application Edge probe fails' {
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='must-not-serialize'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $failure = [pscustomobject]@{ failureDetailCode='boundary-edge-execution-failed'; edgeBoundaryEvidence=[pscustomobject]@{ initial=[pscustomobject]@{ probeName='Canonical Edge deny'; executablePath=$edgePath; studentSid=$script:testSid } } }
        $lifecycle = [pscustomobject]@{ status='observed'; window=[pscustomobject]@{ launchRequestedAtUtc='2026-09-13T10:11:12.1234567Z'; captureEndedAtUtc='2026-09-13T10:12:02.7891234Z' }; queries=[pscustomobject]@{ '8001'=[pscustomobject]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1; events=@([pscustomobject]@{ id=8001; recordId=201; timeCreatedUtc='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }); nativePowerShellComparison=[pscustomobject]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1 } } } }
        Mock Invoke-StudentExecutableTaskProbe { $script:postRegisteredAt = [DateTime]::UtcNow.ToString('o'); throw 'unsafe simulated edge detail' } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathDisposableBoundaryFailureEvidence { [pscustomobject]@{ probeName='Post-application Edge deny'; executablePath=$edgePath; studentSid=$script:testSid; taskRegisteredAtUtc=$script:postRegisteredAt; failureCode='exact-student-process-observed-without-block-event'; processes=@([pscustomobject]@{ executablePath=$edgePath; matchesStudentSid=$true; tokenUserSid=$script:testSid; samSid=$script:testSid; samTokenSidMatch=$true }) } } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { [pscustomobject]@{ status='observed'; outcome='blocked'; studentSid=$script:testSid } } -ModuleName DisposableWindowsTarget

        $pair = Invoke-OpenPathDisposablePostApplicationPair -FailureResult $failure -Target $target -Lifecycle $lifecycle

        $pair.edge.outcome | Should -Be 'execution-observed'
        $pair.edge.evidence.failureCode | Should -Be 'exact-student-process-observed-without-block-event'
        $pair.deniedPeControl.outcome | Should -Be 'blocked'
        Should -Invoke Invoke-StudentExecutableTaskProbe -ModuleName DisposableWindowsTarget -Times 1 -Exactly
        Should -Invoke Invoke-OpenPathDisposableDeniedPeControl -ModuleName DisposableWindowsTarget -Times 1 -Exactly
        ($pair | ConvertTo-Json -Depth 14) | Should -Not -Match 'unsafe simulated edge detail|must-not-serialize'
    }

    It 'does not infer Edge execution from a failure label without an observed matching token' {
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='must-not-serialize'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $failure = [ordered]@{ failureDetailCode='boundary-edge-execution-failed'; edgeBoundaryEvidence=[ordered]@{ initial=[ordered]@{ probeName='Canonical Edge deny'; executablePath=$edgePath; studentSid=$script:testSid } } }
        $lifecycle = [ordered]@{ status='observed'; window=[ordered]@{ launchRequestedAtUtc='2026-09-13T10:11:12.1234567Z'; captureEndedAtUtc='2026-09-13T10:12:02.7891234Z' }; queries=[ordered]@{ '8001'=[ordered]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1; events=@([ordered]@{ id=8001; recordId=201; timeCreatedUtc='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }); nativePowerShellComparison=[ordered]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1 } } } }
        Mock Invoke-StudentExecutableTaskProbe { $script:postRegisteredAt = [DateTime]::UtcNow.ToString('o'); throw 'edge-failed' } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathDisposableBoundaryFailureEvidence { [pscustomobject]@{ probeName='Post-application Edge deny'; executablePath=$edgePath; studentSid=$script:testSid; taskRegisteredAtUtc=$script:postRegisteredAt; failureCode='exact-student-process-observed-without-block-event'; processes=@([pscustomobject]@{ executablePath=$edgePath; matchesStudentSid=$true; tokenUserSid='S-1-5-21-wrong'; samSid='S-1-5-21-wrong'; samTokenSidMatch=$false }) } } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { [pscustomobject]@{ status='observed'; outcome='blocked' } } -ModuleName DisposableWindowsTarget

        $pair = Invoke-OpenPathDisposablePostApplicationPair -FailureResult $failure -Target $target -Lifecycle $lifecycle

        $pair.status | Should -Be 'observed'
        $pair.edge.outcome | Should -Be 'inconclusive'
        $pair.anchor.timeCreatedUtc | Should -Be '2026-09-13T10:11:43.4567891Z'
        Should -Invoke Invoke-StudentExecutableTaskProbe -ModuleName DisposableWindowsTarget -Times 1 -Exactly
        Should -Invoke Invoke-OpenPathDisposableDeniedPeControl -ModuleName DisposableWindowsTarget -Times 1 -Exactly
    }

    It 'rejects stale post-application Edge evidence without serializing it' {
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='must-not-serialize'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $failure = [pscustomobject]@{ failureDetailCode='boundary-edge-execution-failed'; edgeBoundaryEvidence=[pscustomobject]@{ initial=[pscustomobject]@{ probeName='Canonical Edge deny'; executablePath=$edgePath; studentSid=$script:testSid } } }
        $lifecycle = [pscustomobject]@{ status='observed'; window=[pscustomobject]@{ launchRequestedAtUtc='2026-09-13T10:11:12.1234567Z'; captureEndedAtUtc='2026-09-13T10:12:02.7891234Z' }; queries=[pscustomobject]@{ '8001'=[pscustomobject]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1; events=@([pscustomobject]@{ id=8001; recordId=201; timeCreatedUtc='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }); nativePowerShellComparison=[pscustomobject]@{ status='QUERY_SUCCEEDED_MATCHES'; querySucceeded=$true; eventCount=1 } } } }
        Mock Invoke-StudentExecutableTaskProbe { throw 'edge-failed' } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathDisposableBoundaryFailureEvidence { [pscustomobject]@{ probeName='Canonical Edge deny'; executablePath='C:\stale\msedge.exe'; studentSid=$script:testSid; failureCode='stale-must-not-serialize' } } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { [pscustomobject]@{ status='observed'; outcome='blocked' } } -ModuleName DisposableWindowsTarget

        $pair = Invoke-OpenPathDisposablePostApplicationPair -FailureResult $failure -Target $target -Lifecycle $lifecycle

        $pair.edge.status | Should -Be 'unavailable'
        $pair.edge.code | Should -Be 'post-application-edge-evidence-unavailable'
        $pair.edge.PSObject.Properties['evidence'] | Should -BeNullOrEmpty
        Should -Invoke Invoke-OpenPathDisposableDeniedPeControl -ModuleName DisposableWindowsTarget -Times 1 -Exactly
        ($pair | ConvertTo-Json -Depth 14) | Should -Not -Match 'stale-must-not-serialize'
    }

    It 'does not start the pair for invalid or unsupported lifecycle anchors' -ForEach @(
        @{ case='wrong primary failure'; failureCode='different-failure'; queryStatus='QUERY_SUCCEEDED_MATCHES'; primarySucceeded=$true; nativeStatus='QUERY_SUCCEEDED_MATCHES'; nativeSucceeded=$true; nativeCount=1; eventId=8001; recordId=201; eventTime='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }
        @{ case='primary query failed'; failureCode='boundary-edge-execution-failed'; queryStatus='QUERY_FAILED'; primarySucceeded=$false; nativeStatus='QUERY_SUCCEEDED_MATCHES'; nativeSucceeded=$true; nativeCount=1; eventId=8001; recordId=201; eventTime='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }
        @{ case='native query empty'; failureCode='boundary-edge-execution-failed'; queryStatus='QUERY_SUCCEEDED_MATCHES'; primarySucceeded=$true; nativeStatus='QUERY_SUCCEEDED_NO_MATCHES'; nativeSucceeded=$true; nativeCount=0; eventId=8001; recordId=201; eventTime='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }
        @{ case='missing actual id'; failureCode='boundary-edge-execution-failed'; queryStatus='QUERY_SUCCEEDED_MATCHES'; primarySucceeded=$true; nativeStatus='QUERY_SUCCEEDED_MATCHES'; nativeSucceeded=$true; nativeCount=1; eventId=$null; recordId=201; eventTime='2026-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }
        @{ case='future event'; failureCode='boundary-edge-execution-failed'; queryStatus='QUERY_SUCCEEDED_MATCHES'; primarySucceeded=$true; nativeStatus='QUERY_SUCCEEDED_MATCHES'; nativeSucceeded=$true; nativeCount=1; eventId=8001; recordId=201; eventTime='2099-09-13T10:11:43.4567891Z'; parsingStatus='fieldless' }
        @{ case='out of window'; failureCode='boundary-edge-execution-failed'; queryStatus='QUERY_SUCCEEDED_MATCHES'; primarySucceeded=$true; nativeStatus='QUERY_SUCCEEDED_MATCHES'; nativeSucceeded=$true; nativeCount=1; eventId=8001; recordId=201; eventTime='2026-09-13T10:10:43.4567891Z'; parsingStatus='fieldless' }
        @{ case='malformed fieldless observation'; failureCode='boundary-edge-execution-failed'; queryStatus='QUERY_SUCCEEDED_MATCHES'; primarySucceeded=$true; nativeStatus='QUERY_SUCCEEDED_MATCHES'; nativeSucceeded=$true; nativeCount=1; eventId=8001; recordId=201; eventTime='2026-09-13T10:11:43.4567891Z'; parsingStatus='unavailable' }
    ) {
        param($case, $failureCode, $queryStatus, $primarySucceeded, $nativeStatus, $nativeSucceeded, $nativeCount, $eventId, $recordId, $eventTime, $parsingStatus)
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='must-not-serialize'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $failure = [pscustomobject]@{ failureDetailCode=$failureCode; edgeBoundaryEvidence=[pscustomobject]@{ initial=[pscustomobject]@{ probeName='Canonical Edge deny'; executablePath=$edgePath; studentSid=$script:testSid } } }
        $event = [pscustomobject]@{ recordId=$recordId; timeCreatedUtc=$eventTime; parsingStatus=$parsingStatus }
        if ($null -ne $eventId) { $event | Add-Member -NotePropertyName id -NotePropertyValue $eventId }
        $lifecycle = [pscustomobject]@{ status='observed'; window=[pscustomobject]@{ launchRequestedAtUtc='2026-09-13T10:11:12.1234567Z'; captureEndedAtUtc='2026-09-13T10:12:02.7891234Z' }; queries=[pscustomobject]@{ '8001'=[pscustomobject]@{ status=$queryStatus; querySucceeded=$primarySucceeded; eventCount=1; events=@($event); nativePowerShellComparison=[pscustomobject]@{ status=$nativeStatus; querySucceeded=$nativeSucceeded; eventCount=$nativeCount } } } }
        Mock Invoke-StudentExecutableTaskProbe { throw 'must-not-run' } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { throw 'must-not-run' } -ModuleName DisposableWindowsTarget

        $pair = Invoke-OpenPathDisposablePostApplicationPair -FailureResult $failure -Target $target -Lifecycle $lifecycle

        $pair.status | Should -Be 'not-started' -Because $case
        Should -Invoke Invoke-StudentExecutableTaskProbe -ModuleName DisposableWindowsTarget -Times 0 -Exactly
        Should -Invoke Invoke-OpenPathDisposableDeniedPeControl -ModuleName DisposableWindowsTarget -Times 0 -Exactly
    }

    It 'returns an unavailable PE control when the target PE is missing' {
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target
        $control.status | Should -Be 'unavailable'
        $control.code | Should -Be 'benign-pe-missing'
    }

    It 'keeps PE control inconclusive for null or unrelated process evidence' {
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1') -Force
        Mock Get-OpenPathTestAppLockerPolicyDecision { [pscustomobject]@{ status='unknown'; decision='unknown'; exactPath=$probe; exactSid=$script:testSid; runtime=$null; nativePowerShellComparison=$null } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe { throw 'probe-failed' } -ModuleName BrowserBoundaryProbe
        Mock Invoke-StudentExecutableTaskProbe { throw 'probe-failed' } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence { [pscustomobject]@{ failureCode='exact-student-process-observed-without-block-event'; processes=@([pscustomobject]@{ executablePath='C:\other.exe'; studentSid='S-1-5-21-other' }) } } -ModuleName BrowserBoundaryProbe
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence { [pscustomobject]@{ failureCode='exact-student-process-observed-without-block-event'; processes=@([pscustomobject]@{ executablePath='C:\other.exe'; studentSid='S-1-5-21-other' }) } } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $control.outcome | Should -Be 'inconclusive'
        $control.markerObserved | Should -BeFalse
        $control.testAppLockerPolicyDecision.decision | Should -Be 'unknown'
        Should -Invoke Get-OpenPathTestAppLockerPolicyDecision -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Invoke-StudentExecutableTaskProbe -ModuleName DisposableWindowsTarget -Times 1
    }

    It 'passes the marker only as an argument so exact target process evidence is retained' {
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1') -Force
        $script:capturedMarkerArgument = $null
        $script:capturedMarkerParameter = $null
        Mock Get-OpenPathTestAppLockerPolicyDecision { [pscustomobject]@{ status='observed'; decision='Allowed'; exactPath=$probe; exactSid=$script:testSid; runtime=$null; nativePowerShellComparison=$null } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe {
            param($Arguments, $MarkerPath)
            $script:capturedMarkerArgument = [string]$Arguments
            $script:capturedMarkerParameter = [string]$MarkerPath
            $marker = ([string]$Arguments).Trim('"')
            Set-Content -LiteralPath $marker -Value 'executed' -Encoding ASCII
            throw 'exact-process-observed'
        } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence {
            [pscustomobject]@{
                failureCode='exact-student-process-observed-without-block-event'
                processes=@([pscustomobject]@{
                    executablePath=$probe; matchesStudentSid=$true; tokenUserSid=$script:testSid
                    samSid=$script:testSid; samTokenSidMatch=$true; processId=4242
                })
            }
        } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $script:capturedMarkerParameter | Should -BeNullOrEmpty
        $script:capturedMarkerArgument | Should -Match 'openpath-e2e-probe-[0-9a-f]{32}\.marker'
        $control.outcome | Should -Be 'execution-observed'
        $control.markerObserved | Should -BeTrue
        $control.evidence.processes[0].tokenUserSid | Should -Be $script:testSid
    }

    It 'lets a fresh marker override a simultaneous block-shaped result' {
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Mock Get-OpenPathTestAppLockerPolicyDecision { [pscustomobject]@{ status='observed'; decision='Denied'; exactPath=$probe; exactSid=$script:testSid; runtime=$null; nativePowerShellComparison=$null } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe {
            param($Arguments)
            Set-Content -LiteralPath ([string]$Arguments).Trim('"') -Value 'executed' -Encoding ASCII
            [pscustomobject]@{ evidence=[pscustomobject]@{ correlatedEvent=[pscustomobject]@{ id=8004; observedPath=$probe; observedUserSid=$script:testSid } } }
        } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $control.markerObserved | Should -BeTrue
        $control.outcome | Should -Be 'execution-observed'
    }

    It 'does not call allow audit or mismatched event evidence a PE block' -TestCases @(
        @{ EventId=8002; EventPath='exact'; EventSid='exact' }
        @{ EventId=8003; EventPath='exact'; EventSid='exact' }
        @{ EventId=8004; EventPath='other'; EventSid='exact' }
        @{ EventId=8004; EventPath='exact'; EventSid='other' }
    ) {
        param($EventId, $EventPath, $EventSid)
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        $observedPath = if ($EventPath -eq 'exact') { $probe } else { 'C:\other.exe' }
        $observedSid = if ($EventSid -eq 'exact') { $script:testSid } else { 'S-1-5-21-other' }
        Mock Get-OpenPathTestAppLockerPolicyDecision { [pscustomobject]@{ status='observed'; decision='Denied'; exactPath=$probe; exactSid=$script:testSid; runtime=$null; nativePowerShellComparison=$null } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe { [pscustomobject]@{ evidence=[pscustomobject]@{ correlatedEvent=[pscustomobject]@{ id=$EventId; observedPath=$observedPath; observedUserSid=$observedSid } } } } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $control.markerObserved | Should -BeFalse
        $control.outcome | Should -Be 'inconclusive'
    }

    It 'does not treat the expected studentSid field as an observed process token' {
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Mock Get-OpenPathTestAppLockerPolicyDecision { [pscustomobject]@{ status='unknown'; decision='unknown'; exactPath=$probe; exactSid=$script:testSid; runtime=$null; nativePowerShellComparison=$null } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe { throw 'probe-failed' } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence {
            [pscustomobject]@{ failureCode='exact-student-process-observed-without-block-event'; processes=@([pscustomobject]@{ executablePath=$probe; studentSid=$script:testSid; matchesStudentSid=$true }) }
        } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $control.outcome | Should -Be 'inconclusive'
    }

    It 'classifies an exact observed target token as execution without a marker' {
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Mock Get-OpenPathTestAppLockerPolicyDecision { [pscustomobject]@{ status='unknown'; decision='unknown'; exactPath=$probe; exactSid=$script:testSid; runtime=$null; nativePowerShellComparison=$null } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe { throw 'probe-failed' } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence {
            [pscustomobject]@{ failureCode='exact-student-process-observed-without-block-event'; processes=@([pscustomobject]@{ executablePath=$probe; studentSid=$script:testSid; matchesStudentSid=$true; tokenUserSid=$script:testSid; processId=4242 }) }
        } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $control.markerObserved | Should -BeFalse
        $control.outcome | Should -Be 'execution-observed'
        $control.evidence.processes[0].tokenUserSid | Should -Be $script:testSid
    }

    It 'rejects an expected SID label when the observed token belongs to another SID' {
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Mock Get-OpenPathTestAppLockerPolicyDecision { [pscustomobject]@{ status='unknown'; decision='unknown'; exactPath=$probe; exactSid=$script:testSid; runtime=$null; nativePowerShellComparison=$null } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe { throw 'probe-failed' } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence {
            [pscustomobject]@{ failureCode='exact-student-process-observed-without-block-event'; processes=@([pscustomobject]@{ executablePath=$probe; studentSid=$script:testSid; matchesStudentSid=$true; tokenUserSid='S-1-5-21-other'; processId=4242 }) }
        } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $control.markerObserved | Should -BeFalse
        $control.outcome | Should -Be 'inconclusive'
    }

    It 'keeps the original Edge cause when the PE control itself throws' {
        $primary = [pscustomobject]@{ probeName='Canonical Edge deny'; failureCode='exact-student-process-observed-without-block-event'; executablePath='C:\Edge\msedge.exe'; studentSid=$script:testSid }
        $exception = [System.InvalidOperationException]::new('boundary-edge-execution-failed')
        $exception.Data['OpenPathEdgeBoundaryEvidence'] = $primary
        Mock Invoke-OpenPathDisposableEdgeBoundaryDiagnostic { [pscustomobject]@{ attempts=@() } } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableDeniedPeControl { throw 'control-infrastructure-failed' } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid }

        $resolved = Resolve-OpenPathDisposableEdgeBoundaryFailure -Exception $exception -Target $target

        $resolved.initial.failureCode | Should -Be 'exact-student-process-observed-without-block-event'
        $resolved.deniedPeControl.status | Should -Be 'unavailable'
        $resolved.deniedPeControl.code | Should -Be 'benign-pe-control-failed'
    }

    It 'projects a producer-shaped native runtime through the real helper and writer' {
        $path = Join-Path $TestDrive 'successful-pe-control.json'
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1') -Force
        Mock Get-OpenPathTestAppLockerPolicyDecision {
            [pscustomobject]@{
                status='observed'; decision='Denied'; exactPath=$probe; exactSid=$script:testSid
                runtime=[pscustomobject]@{ supported=$true; edition='Core'; version='7.6.0'; bitness='64-bit'; processId=4200; rawMessage='drop-me'; credential='drop-me'; XML='<drop />' }
                nativePowerShellComparison=[pscustomobject]@{
                    status='observed'; decision='DeniedByDefault'; path=$probe; userSid=$script:testSid; rawMessage='drop-me'; credential='drop-me'; XML='<drop />'
                    runtime=[pscustomobject]@{ edition='Desktop'; version='5.1.26100'; bitness='64-bit'; processId=5100; rawMessage='drop-me'; credential='drop-me'; XML='<drop />' }
                }
            }
        } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe {
            [pscustomobject]@{ evidence=[pscustomobject]@{ correlatedEvent=[pscustomobject]@{ id=8004; observedPath=$probe; observedUserSid=$script:testSid } } }
        } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }
        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        Write-OpenPathOfflineInstallerEvidence -Payload ([ordered]@{ edgeBoundaryEvidence=[ordered]@{ deniedPeControl=$control } }) -Path $path
        $rawRoundTrip = Get-Content -LiteralPath $path -Raw
        $roundTrip = $rawRoundTrip | ConvertFrom-Json

        $roundTrip.edgeBoundaryEvidence.deniedPeControl.outcome | Should -Be 'blocked'
        $roundTrip.edgeBoundaryEvidence.deniedPeControl.testAppLockerPolicyDecision.nativePowerShellComparison.decision | Should -Be 'DeniedByDefault'
        $roundTrip.edgeBoundaryEvidence.deniedPeControl.testAppLockerPolicyDecision.nativePowerShellComparison.runtime.PSObject.Properties['supported'] | Should -BeNullOrEmpty
        $rawRoundTrip | Should -Match ([regex]::Escape($control.startedAtUtc))
        $rawRoundTrip | Should -Match ([regex]::Escape($control.endedAtUtc))
        ($roundTrip | ConvertTo-Json -Depth 14) | Should -Not -Match 'Password|not-serialized|rawMessage|credential|<drop'
    }

    It 'retains an explicitly present null runtime field without adding absent fields' {
        $projection = InModuleScope DisposableWindowsTarget {
            ConvertTo-OpenPathDisposableRuntimeProjection -Runtime ([pscustomobject]@{ supported=$null; edition='Desktop' })
        }

        $projection.PSObject.Properties['supported'] | Should -Not -BeNullOrEmpty
        $projection.supported | Should -BeNullOrEmpty
        $projection.PSObject.Properties['edition'] | Should -Not -BeNullOrEmpty
        $projection.PSObject.Properties['version'] | Should -BeNullOrEmpty
    }

    It 'recognizes the producer safe event shape for a correlated PE block' {
        $probe = Join-Path $script:testPath 'openpath-e2e-probe.exe'
        Set-Content -LiteralPath $probe -Value 'fixture' -Encoding ASCII
        Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1') -Force
        $event = [pscustomobject]@{ Id=8004; Xml=@"
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><EventID>8004</EventID></System><UserData><RuleAndFileData><TargetUser>$($script:testSid)</TargetUser><FullFilePath>$probe</FullFilePath></RuleAndFileData></UserData></Event>
"@ }
        Add-Member -InputObject $event -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
        $correlation = Get-OpenPathCorrelatedAppLockerEvent -Events @($event) -AllowedEventIds @(8004) -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -BinaryLeaf 'openpath-e2e-probe.exe' -ExpectedExecutablePath $probe -StudentSid $script:testSid
        $correlation.matched | Should -BeTrue
        Mock Get-OpenPathTestAppLockerPolicyDecision { return [pscustomobject]@{ status='observed'; decision='DeniedByDefault'; exactPath=$probe; exactSid=$script:testSid; runtime=[pscustomobject]@{ supported=$true; edition='Desktop'; version='5.1'; bitness='64-bit'; processId=1 }; nativePowerShellComparison=[pscustomobject]@{ status='unavailable'; runtime=$null; path=$probe; userSid=$script:testSid } } } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe { return [pscustomobject]@{ status='pass'; evidence=[pscustomobject]@{ correlatedEvent=$correlation.event } } } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName='op-e2e-test'; Password='not-serialized'; Sid=$script:testSid; ProfilePath=$script:testPath }

        $control = Invoke-OpenPathDisposableDeniedPeControl -Target $target

        $control.outcome | Should -Be 'blocked'
        $control.testAppLockerPolicyDecision.decision | Should -Be 'DeniedByDefault'
        $control.testAppLockerPolicyDecision.nativePowerShellComparison.decision | Should -BeNullOrEmpty
        $control.executableSha256 | Should -Not -BeNullOrEmpty
    }

    It 'creates an enabled non-admin account with a materialized non-special profile without pre-populating the restricted group' {
        $target = New-OpenPathDisposableStandardTarget
        $target.Sid | Should -Be $script:testSid
        $target.ProfilePath | Should -Be $script:testPath
        [string]::IsNullOrWhiteSpace($target.Password) | Should -BeFalse
        Should -Invoke New-LocalUser -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Enable-LocalUser -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Grant-OpenPathDisposableTargetUserRight -ModuleName DisposableWindowsTarget -Times 1 -ParameterFilter {
            $Sid -eq $script:testSid -and $Right -eq 'SeBatchLogonRight'
        }
        Should -Invoke Add-LocalGroupMember -ModuleName DisposableWindowsTarget -Times 0
    }

    It 'rejects a target whose profile was not materialized' {
        Mock Get-CimInstance { @() } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath }
        { Assert-OpenPathDisposableTarget -Target $target } | Should -Throw '*disposable-target-profile-not-materialized*'
    }

    It 'rejects an administrator target' {
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = $script:testSid }) } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath }
        { Assert-OpenPathDisposableTarget -Target $target } | Should -Throw '*disposable-target-is-administrator*'
    }

    It 'removes the profile and account and clears the ephemeral credential' {
        $script:profileQueryCount = 0
        Mock Get-CimInstance {
            $script:profileQueryCount++
            if ($script:profileQueryCount -eq 1) {
                return $script:testProfile
            }
            return @()
        } -ModuleName DisposableWindowsTarget
        Mock Get-LocalUser { $null } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath; Password = 'not-serialized'; BatchLogonRightGranted = $true }
        $cleanup = Remove-OpenPathDisposableStandardTarget -Target $target
        $cleanup.profileRemoved | Should -BeTrue
        $cleanup.userRemoved | Should -BeTrue
        $cleanup.credentialDestroyed | Should -BeTrue
        $target.Password | Should -BeNullOrEmpty
        Should -Invoke Remove-CimInstance -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Revoke-OpenPathDisposableTargetUserRight -ModuleName DisposableWindowsTarget -Times 1 -ParameterFilter {
            $Sid -eq $script:testSid -and $Right -eq 'SeBatchLogonRight'
        }
        Should -Invoke Remove-LocalUser -ModuleName DisposableWindowsTarget -Times 1
    }

    It 'waits for a task-loaded disposable profile to unload before removing it' {
        $loadedProfile = if (Get-Command New-CimInstance -ErrorAction SilentlyContinue) {
            New-CimInstance -ClassName Win32_UserProfile -Namespace root/cimv2 -ClientOnly -Property @{
                SID = $script:testSid
                LocalPath = $script:testPath
                Special = $false
                Loaded = $true
            }
        }
        else {
            [pscustomobject]@{ SID = $script:testSid; LocalPath = $script:testPath; Special = $false; Loaded = $true }
        }
        $script:profileQueryCount = 0
        Mock Get-CimInstance {
            $script:profileQueryCount++
            if ($script:profileQueryCount -eq 1) { return $loadedProfile }
            if ($script:profileQueryCount -eq 2) { return $script:testProfile }
            return @()
        } -ModuleName DisposableWindowsTarget
        Mock Get-LocalUser { $null } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath; Password = 'not-serialized'; BatchLogonRightGranted = $true }

        $cleanup = Remove-OpenPathDisposableStandardTarget -Target $target

        $cleanup.profileRemoved | Should -BeTrue
        Should -Invoke Start-Sleep -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Remove-CimInstance -ModuleName DisposableWindowsTarget -Times 1
    }

    It 'transports sanitized Edge failure evidence across the nested Browser module boundary' {
        if (-not (Get-Command icacls.exe -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:global:icacls.exe -Value { $global:LASTEXITCODE = 0 }
        }
        Mock icacls.exe { $global:LASTEXITCODE = 0 } -ModuleName DisposableWindowsTarget
        if (-not (Get-Command New-OpenPathProbePayloadBinary -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:global:New-OpenPathProbePayloadBinary -Value { }
        }
        foreach ($commandName in @('Get-OpenPathLastBoundaryProbeFailureEvidence', 'Invoke-StudentExecutableTaskProbe', 'Invoke-OpenPathEdgeBoundaryDiagnostic')) {
            if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Function:global:$commandName" -Value { param() }
            }
        }
        $target = [pscustomobject]@{
            UserName = 'op-e2e-test'
            Password = 'not-serialized'
            Sid = $script:testSid
            ProfilePath = $script:testPath
        }
        $edgeEvidence = [pscustomobject][ordered]@{
            probeName = 'Canonical Edge deny'
            executablePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            studentSid = $script:testSid
            processes = @([pscustomobject]@{ processId = 5436; tokenUserSid = $script:testSid; restrictedGroupPresent = $true })
        }
        Mock Test-Path {
            param($LiteralPath, $PathType)
            if ([string]$LiteralPath -match '(?i)(firefox|msedge)\.exe$') { return $true }
            return $false
        } -ModuleName DisposableWindowsTarget
        Mock Import-Module {} -ModuleName DisposableWindowsTarget -ParameterFilter {
            [string]$Name -like '*BrowserBoundaryProbe.psm1'
        }
        Mock New-OpenPathProbePayloadBinary {} -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathNativePolicyProbe { [pscustomobject]@{ status = 'ok' } } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence { $edgeEvidence } -ModuleName DisposableWindowsTarget
        Mock Invoke-StudentExecutableTaskProbe {
            param([string]$ProbeName)
            if ($ProbeName -eq 'Canonical Edge deny') {
                throw 'simulated-edge-boundary-failure'
            }
            [pscustomobject]@{ status = 'pass'; evidence = [pscustomobject]@{} }
        } -ModuleName DisposableWindowsTarget

        $capturedException = $null
        try {
            Invoke-OpenPathInstalledBoundaryProbes -Target $target -OpenPathRoot 'C:\OpenPath'
        }
        catch {
            $capturedException = $_.Exception
        }

        $capturedException | Should -Not -BeNullOrEmpty
        $capturedException.Message | Should -Be 'boundary-edge-execution-failed'
        $capturedException.Data.Contains('OpenPathEdgeBoundaryEvidence') | Should -BeTrue
        $transportedEvidence = $capturedException.Data['OpenPathEdgeBoundaryEvidence']
        $transportedEvidence.probeName | Should -Be 'Canonical Edge deny'
        $transportedEvidence.processes[0].processId | Should -Be 5436
        ($transportedEvidence | ConvertTo-Json -Depth 8) | Should -Not -Match 'not-serialized|Password'

        Mock Invoke-OpenPathEdgeBoundaryDiagnostic { [pscustomobject]@{ status = 'pass'; attempts = @() } } -ModuleName DisposableWindowsTarget
        $repeat = Invoke-OpenPathDisposableEdgeBoundaryDiagnostic -UserName $target.UserName -Password $target.Password -ExecutablePath $edgeEvidence.executablePath -StudentSid $target.Sid
        $repeat.status | Should -Be 'pass'
    }

    It 'resolves transported Edge evidence before running bounded diagnostics' {
        $initial = [pscustomobject][ordered]@{
            probeName = 'Canonical Edge deny'; executableName = 'msedge.exe'
            executablePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            studentSid = $script:testSid; failureCode = 'exact-student-process-observed-without-block-event'
            expectedEventIds = @(8004, 8022); samGroupName = 'OpenPath-Restricted'
            samGroupSid = 'S-1-5-21-100-200-300-401'; samGroupMemberPresent = $true
            processes = @([pscustomobject]@{ processId = 5436; restrictedGroupPresent = $null; restrictedGroupQueryStatus = 'unavailable' })
            events = @(); matchedEvent = $null; appLocker8002 = $null; appLocker8004 = $null; appLocker8020 = $false; appLocker8022 = $false
            testAppLockerPolicyDecision = [pscustomobject]@{ status = 'observed'; decision = 'Denied' }
            enforcementObservation = [pscustomobject][ordered]@{
                before = [pscustomobject][ordered]@{ phase = 'before-launch'; status = 'observed'; appIdSvc = [pscustomobject]@{ running = $true } }
                after = [pscustomobject][ordered]@{ phase = 'after-launch'; status = 'unknown'; reason = 'enforcement-observer-failed' }
            }
        }
        $exception = [InvalidOperationException]::new('boundary-edge-execution-failed')
        $exception.Data['OpenPathEdgeBoundaryEvidence'] = $initial
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Password = 'must-not-serialize'; Sid = $script:testSid }
        Mock Get-OpenPathDisposableBoundaryFailureEvidence { throw 'transported-capture-must-win' } -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathDisposableEdgeBoundaryDiagnostic {
            [pscustomobject]@{ status = 'complete'; policyReapplied = $false; attempts = @(
                [pscustomobject]@{ label = 'T0'; offsetSeconds = 0; elapsedSeconds = 0.3; taskName = 'edge-t0'; evidence = [pscustomobject]@{ appLocker8004 = $null; queryStatus = 'failed' } },
                [pscustomobject]@{ label = 'T+5'; offsetSeconds = 5; elapsedSeconds = 5.4; taskName = 'edge-t5'; evidence = [pscustomobject]@{ appLocker8004 = $true; queryStatus = 'observed' } }
            ) }
        } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathDisposableFlatEdgeBoundaryFailureContract {
            param($Evidence, $Diagnostic)
            [pscustomobject]@{ edgeFailureCode = $Evidence.failureCode; edgeAttempts = @($Diagnostic.attempts); edge = [pscustomobject]@{ restrictedGroupTokenMember = $null } }
        } -ModuleName DisposableWindowsTarget

        $resolved = Resolve-OpenPathDisposableEdgeBoundaryFailure -Exception $exception -Target $target

        $resolved.initial.failureCode | Should -Be 'exact-student-process-observed-without-block-event'
        $resolved.initial.processes[0].restrictedGroupPresent | Should -BeNullOrEmpty
        $resolved.initial.enforcementObservation.before.phase | Should -Be 'before-launch'
        $resolved.initial.enforcementObservation.after.reason | Should -Be 'enforcement-observer-failed'
        $resolved.repeat.attempts[1].elapsedSeconds | Should -Be 5.4
        $resolved.contract.edgeFailureCode | Should -Be 'exact-student-process-observed-without-block-event'
        ($resolved | ConvertTo-Json -Depth 12) | Should -Not -Match 'must-not-serialize|Password|UserName'
    }

    It 'exposes the real nested Browser getter flat contract and diagnostic through the disposable module' {
        $browserPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1'
        InModuleScope DisposableWindowsTarget -Parameters @{ BrowserPath = $browserPath } {
            Import-Module $BrowserPath -Force
        }
        $browserModule = Get-Module BrowserBoundaryProbe -All | Select-Object -Last 1
        $browserModule | Should -Not -BeNullOrEmpty
        & $browserModule {
            Set-OpenPathBoundaryProbeFailureEvidence `
                -ProbeName 'Canonical Edge deny' `
                -ExecutablePath 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' `
                -StudentSid 'S-1-5-21-100-200-300-400' `
                -FailureCode 'exact-student-process-observed-without-block-event' `
                -Processes @([pscustomobject]@{
                        processId = 5436
                        restrictedGroupSid = 'S-1-5-21-100-200-300-401'
                        restrictedGroupPresent = $null
                        restrictedGroupAttributes = $null
                        restrictedGroupQueryStatus = 'unavailable'
                        tokenObserver = [pscustomobject]@{
                            processId = 5436
                            processExists = $true
                            processExistsStatus = 'observed'
                            errorCode = 87
                            errorName = 'ERROR_INVALID_PARAMETER'
                            failureStage = 'OpenProcessToken'
                            observerArchitecture = '64-bit'
                            observerPid = 9882
                            nativeStages = @([pscustomobject]@{ stage = 'OpenProcessToken'; accessMask = '0x00000008'; win32Code = 87; win32Name = 'ERROR_INVALID_PARAMETER' })
                        }
                    }) `
                -Events @([pscustomobject]@{ id = 8002; observedProcessId = 5436; observedPath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; observedUserSid = 'S-1-5-21-100-200-300-400'; pidStatus = 'matched'; pidMatched = $true; nameMatched = $true; pathMatched = $true; sidMatched = $true; packageMatched = $true }) `
                -ExpectedEventIds @(8004, 8022) `
                -SamEvidence ([pscustomobject]@{ groupName = 'OpenPath-Restricted'; groupSid = 'S-1-5-21-100-200-300-401'; targetMemberPresent = $true; memberCount = 1; status = 'observed' }) `
                -TestAppLockerPolicyDecision ([pscustomobject]@{
                        status = 'observed'
                        decision = 'Denied'
                    runtime = [pscustomobject]@{ edition = 'Core'; version = '7.6.5'; bitness = '64-bit'; processId = 9883 }
                    testAppLockerPolicy = [pscustomobject]@{ available = $true; source = 'AppLocker' }
                    import = [pscustomobject]@{ attempted = $false; result = 'not-required' }
                    nativePowerShellComparison = [pscustomobject]@{
                        status = 'observed'
                        decision = 'Allowed'
                        path = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
                        userSid = 'S-1-5-21-100-200-300-400'
                        runtime = [pscustomobject]@{ edition = 'Desktop'; version = '5.1.26100'; bitness = '64-bit'; processId = 7780 }
                    }
                }) `
                -AppLockerQueryStatuses @{ '8002' = 'observed'; '8004' = 'failed'; '8020' = 'observed'; '8022' = 'observed' } `
                -AppLockerEventQueries ([ordered]@{
                    '8002' = [pscustomobject]@{
                        status = 'QUERY_SUCCEEDED_MATCHES'
                        channel = 'Microsoft-Windows-AppLocker/EXE and DLL'
                        eventId = 8002
                        channelExists = $true
                        queryAttempted = $true
                        querySucceeded = $true
                        eventCount = 1
                        exception = $null
                    }
                    '8004' = [pscustomobject]@{
                        status = 'QUERY_FAILED'
                        channel = 'Microsoft-Windows-AppLocker/EXE and DLL'
                        eventId = 8004
                        channelExists = $true
                        queryAttempted = $true
                        querySucceeded = $false
                        eventCount = 0
                        exception = [pscustomobject]@{ type = 'System.InvalidOperationException'; fullyQualifiedErrorId = 'event-query-failed'; hResult = -1; safeReason = 'event-query-failed' }
                    }
                    '8020' = [pscustomobject]@{
                        status = 'QUERY_SUCCEEDED_MATCHES'
                        channel = 'Microsoft-Windows-AppLocker/Packaged app-Execution'
                        eventId = 8020
                        channelExists = $true
                        queryAttempted = $true
                        querySucceeded = $true
                        eventCount = 1
                        exception = $null
                        correlationStatus = 'CORRELATION_FAILED'
                        correlationException = [pscustomobject]@{ type = 'System.InvalidOperationException'; fullyQualifiedErrorId = 'correlation-failed'; hResult = -1; safeReason = 'event-correlation-failed' }
                    }
                    '8022' = [pscustomobject]@{
                        status = 'QUERY_SUCCEEDED_NO_MATCHES'
                        channel = 'Microsoft-Windows-AppLocker/Packaged app-Execution'
                        eventId = 8022
                        channelExists = $true
                        queryAttempted = $true
                        querySucceeded = $true
                        eventCount = 0
                        exception = $null
                    }
                }) `
                -EnforcementObservation ([pscustomobject][ordered]@{
                    before = [pscustomobject][ordered]@{
                        phase = 'before-launch'
                        status = 'observed'
                        appIdSvc = [pscustomobject]@{ running = $false }
                    }
                    after = [pscustomobject][ordered]@{
                        phase = 'after-launch'
                        status = 'observed'
                        appLocker = [pscustomobject][ordered]@{
                            policy = [pscustomobject]@{ hashAlgorithm = 'SHA256'; hashScope = 'UTF8-AppLockerPolicy-OuterXml' }
                            queries = [ordered]@{
                                '8004' = [pscustomobject][ordered]@{
                                    status = 'QUERY_SUCCEEDED_NO_MATCHES'
                                    nativePowerShellComparison = [pscustomobject]@{ status = 'QUERY_SUCCEEDED_NO_MATCHES' }
                                }
                            }
                        }
                    }
                }) | Out-Null
        }

        $retrieved = Get-OpenPathDisposableBoundaryFailureEvidence
        $flat = Get-OpenPathDisposableFlatEdgeBoundaryFailureContract -Evidence $retrieved
        $retrieved.failureCode | Should -Be 'exact-student-process-observed-without-block-event'
        $flat.edgeFailureCode | Should -Be 'exact-student-process-observed-without-block-event'
        $flat.edge.tokenObserver.failureStage | Should -Be 'OpenProcessToken'
        $flat.edge.policyObserver.runtime.edition | Should -Be 'Core'
        $flat.edge.policyObserver.nativePowerShellComparison.decision | Should -Be 'Allowed'
        $flat.edge.eventQueries.'8004'.status | Should -Be 'QUERY_FAILED'
        $flat.edge.eventQueries.'8020'.correlationStatus | Should -Be 'CORRELATION_FAILED'
        $flat.edge.eventQueries.'8020'.correlationException.safeReason | Should -Be 'event-correlation-failed'
        $flat.edge.appLocker8020 | Should -BeNullOrEmpty
        $flat.edge.enforcementObservation.before.appIdSvc.running | Should -BeFalse
        $flat.edgeEnforcementObservation.after.appLocker.queries.'8004'.nativePowerShellComparison.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
        @($flat.edge.eventQueries.Keys | Sort-Object) | Should -Be @('8002', '8004', '8020', '8022')

        Mock Start-Sleep {} -ModuleName BrowserBoundaryProbe
        Mock Invoke-StudentExecutableTaskProbe {
            [pscustomobject]@{ evidence = [pscustomobject]@{ failureCode = 'appLocker-block-event-observed' } }
        } -ModuleName BrowserBoundaryProbe
        $diagnostic = Invoke-OpenPathDisposableEdgeBoundaryDiagnostic `
            -UserName 'op-e2e-test' -Password 'must-not-serialize' `
            -ExecutablePath $retrieved.executablePath -StudentSid $retrieved.studentSid
        $diagnostic.policyReapplied | Should -BeFalse
        @($diagnostic.attempts).Count | Should -Be 4
        @($diagnostic.attempts | ForEach-Object offsetSeconds) | Should -Be @(0, 5, 15, 30)
        ($diagnostic | ConvertTo-Json -Depth 12) | Should -Not -Match 'must-not-serialize|Password|UserName'

        $translated = New-OpenPathDisposableEdgeBoundaryException
        $translated.Message | Should -Be 'boundary-edge-execution-failed'
        $translated.Data.Contains('OpenPathEdgeBoundaryEvidence') | Should -BeTrue
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Password = 'must-not-serialize'; Sid = $retrieved.studentSid }
        Mock Invoke-OpenPathDisposableEdgeBoundaryDiagnostic { $diagnostic } -ModuleName DisposableWindowsTarget
        $resolved = Resolve-OpenPathDisposableEdgeBoundaryFailure -Exception $translated -Target $target
        $path = Join-Path $TestDrive 'cross-module-edge-failure.json'
        $payload = [ordered]@{
            status = 'failed'; failureDetailCode = $translated.Message
            edgeBoundaryEvidence = [ordered]@{ initial = $resolved.initial; repeat = $resolved.repeat; deniedPeControl = $resolved.deniedPeControl }
            cleanupAttempted = $true; cleanupSucceeded = $false
        }
        Write-OpenPathOfflineInstallerEvidence -Payload $payload -Path $path
        $roundTrip = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $roundTrip.status | Should -Be 'failed'
        $roundTrip.failureDetailCode | Should -Be 'boundary-edge-execution-failed'
        $roundTrip.edgeBoundaryEvidence.initial.failureCode | Should -Be 'exact-student-process-observed-without-block-event'
        $roundTrip.edgeBoundaryEvidence.deniedPeControl.status | Should -Be 'unavailable'
        $roundTrip.edgeBoundaryEvidence.initial.samGroupMemberPresent | Should -BeTrue
        $roundTrip.edgeBoundaryEvidence.initial.processes[0].restrictedGroupPresent | Should -BeNullOrEmpty
        $roundTrip.edgeBoundaryEvidence.initial.processes[0].restrictedGroupQueryStatus | Should -Be 'unavailable'
        $roundTrip.edgeBoundaryEvidence.initial.testAppLockerPolicyDecision.decision | Should -Be 'Denied'
        $roundTrip.edgeBoundaryEvidence.initial.testAppLockerPolicyDecision.nativePowerShellComparison.decision | Should -Be 'Allowed'
        $roundTrip.edgeBoundaryEvidence.initial.processes[0].tokenObserver.failureStage | Should -Be 'OpenProcessToken'
        $roundTrip.edgeBoundaryEvidence.initial.testAppLockerPolicyDecision.runtime.processId | Should -Be 9883
        $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8004'.status | Should -Be 'QUERY_FAILED'
        @($roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.PSObject.Properties.Name | Sort-Object) | Should -Be @('8002', '8004', '8020', '8022')
        $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8002'.eventCount | Should -Be 1
        $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8020'.eventCount | Should -Be 1
        $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8020'.correlationStatus | Should -Be 'CORRELATION_FAILED'
        $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8020'.correlationException.safeReason | Should -Be 'event-correlation-failed'
        $roundTrip.edgeBoundaryEvidence.initial.appLocker8002 | Should -BeTrue
        $roundTrip.edgeBoundaryEvidence.initial.appLocker8004 | Should -BeNullOrEmpty
        $roundTrip.edgeBoundaryEvidence.initial.appLocker8020 | Should -BeNullOrEmpty
        $roundTrip.edgeBoundaryEvidence.initial.enforcementObservation.before.appIdSvc.running | Should -BeFalse
        $roundTrip.edgeBoundaryEvidence.initial.enforcementObservation.after.appLocker.queries.'8004'.nativePowerShellComparison.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
        $roundTrip.edgeBoundaryEvidence.initial.appLockerQueryStatuses.'8004' | Should -Be 'failed'
        $roundTrip.edgeBoundaryEvidence.repeat.attempts[3].offsetSeconds | Should -Be 30
        $roundTrip.cleanupSucceeded | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match 'must-not-serialize|Password|UserName'
        # Discovery imports the Browser module globally for its own suite. The
        # nested import above mirrors the canonical caller, so restore the
        # independent suite's global command surface before Pester advances.
        Import-Module $browserPath -Force -Global
    }
}
