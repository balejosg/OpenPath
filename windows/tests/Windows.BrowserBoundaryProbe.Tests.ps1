# OpenPath Windows browser boundary probe and report validation unit tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1") -Force
$script:OpenPathWindowsDirect = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)

Describe "Windows Browser Boundary CI Probes" {
    BeforeAll {
        $env:OPENPATH_TEST_FORCE_SCHTASKS = '1'
        if (-not (Get-Command schtasks.exe -ErrorAction SilentlyContinue)) {
            function global:schtasks.exe { }
        }
        if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) {
            function global:Get-WinEvent { param($FilterHashtable) }
        }
        if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
            function global:Get-CimInstance { param($ClassName, $Filter) }
        }
        if (-not (Get-Command Invoke-CimMethod -ErrorAction SilentlyContinue)) {
            function global:Invoke-CimMethod { param($InputObject, $MethodName) }
        }
        if (-not (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue)) {
            function global:Get-LocalGroupMember { param($Group) }
        }
        if (-not (Get-Command Stop-Process -ErrorAction SilentlyContinue)) {
            function global:Stop-Process { param($Id, $Name, [switch]$Force) }
        }
        if (-not (Get-Command Get-LocalGroup -ErrorAction SilentlyContinue)) {
            function global:Get-LocalGroup { param($Name) }
        }
        if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
            function global:Get-Service { param($Name) }
        }
        if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) {
            function global:Get-AppLockerPolicy { param([switch]$Local, [switch]$Xml) }
        }
        if (-not (Get-Command Test-AppLockerPolicy -ErrorAction SilentlyContinue)) {
            function global:Test-AppLockerPolicy { param($Path, $User, [Parameter(ValueFromPipeline = $true)]$PolicyObject) }
        }
        if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            function global:Get-ScheduledTask { param($TaskName) }
        }
        if (-not (Get-Command Get-ScheduledTaskInfo -ErrorAction SilentlyContinue)) {
            function global:Get-ScheduledTaskInfo { param($TaskName) }
        }
        if (-not (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue)) { function global:New-ScheduledTaskAction { param($Execute, $Argument) } }
        if (-not (Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue)) { function global:New-ScheduledTaskTrigger { param([switch]$Once, $At) } }
        if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Register-ScheduledTask { param($TaskName, $Action, $Trigger, $User, $Password, $RunLevel, [switch]$Force) } }
        if (-not (Get-Command Start-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Start-ScheduledTask { param($TaskName) } }
        if (-not (Get-Command Stop-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Stop-ScheduledTask { param($TaskName) } }
        if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) } }
    }

    AfterAll {
        Remove-Item Env:OPENPATH_TEST_FORCE_SCHTASKS -ErrorAction SilentlyContinue
    }

    Context "Invoke-StudentExecutableTaskProbe" {
        It 'stops an active credentialed probe task before unregistering it' {
            $testExe = Join-Path $TestDrive 'probe-task-cleanup.exe'
            $markerPath = Join-Path $TestDrive 'probe-task-cleanup.marker'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            Set-Content -LiteralPath $markerPath -Value 'ran'
            $env:OPENPATH_TEST_FORCE_SCHTASKS = '0'
            $env:OPENPATH_TEST_FORCE_SCHEDULED_TASK_CMDLETS = '1'
            Mock Register-ScheduledTask {} -ModuleName BrowserBoundaryProbe
            Mock Start-ScheduledTask {} -ModuleName BrowserBoundaryProbe
            $script:taskStateQueryCount = 0
            Mock Get-ScheduledTask {
                $script:taskStateQueryCount++
                [pscustomobject]@{ State = $(if ($script:taskStateQueryCount -eq 1) { 'Running' } else { 'Ready' }) }
            } -ModuleName BrowserBoundaryProbe
            Mock Start-Sleep {} -ModuleName BrowserBoundaryProbe
            Mock Stop-ScheduledTask {} -ModuleName BrowserBoundaryProbe
            Mock Unregister-ScheduledTask {} -ModuleName BrowserBoundaryProbe
            try {
                $result = Invoke-StudentExecutableTaskProbe -ProbeName 'Task cleanup probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectAllowed -MarkerPath $markerPath -TimeoutSeconds 1
                $result.status | Should -Be 'pass'
                Should -Invoke Stop-ScheduledTask -ModuleName BrowserBoundaryProbe -Times 1
                Should -Invoke Start-Sleep -ModuleName BrowserBoundaryProbe -Times 1
                Should -Invoke Unregister-ScheduledTask -ModuleName BrowserBoundaryProbe -Times 1
            }
            finally {
                Remove-Item Env:OPENPATH_TEST_FORCE_SCHEDULED_TASK_CMDLETS -ErrorAction SilentlyContinue
                $env:OPENPATH_TEST_FORCE_SCHTASKS = '1'
            }
        }

        It "Throws when probe executable does not exist on host (fail preparation, no silent pass)" {
            $nonExistentExe = Join-Path $TestDrive "missing-test-binary.exe"
            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Missing PE test" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $nonExistentExe `
                    -Expectation ExpectDenied
            } | Should -Throw "*does not exist on host*"
        }

        It "Throws when schtasks /Create fails under ExpectDenied" {
            $testExe = Join-Path $TestDrive "probe-create-fail.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"

            Mock schtasks.exe {
                if ($args -contains '/Create') {
                    $global:LASTEXITCODE = 1
                }
                else {
                    $global:LASTEXITCODE = 0
                }
            } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Create fail probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied
            } | Should -Throw "*Task creation for * failed under student credentials*"
        }

        It "Throws when schtasks /Run fails" {
            $testExe = Join-Path $TestDrive "probe-run-fail.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"

            Mock schtasks.exe {
                if ($args -contains '/Run') {
                    $global:LASTEXITCODE = 1
                }
                else {
                    $global:LASTEXITCODE = 0
                }
            } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Run fail probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied
            } | Should -Throw "*Task execution for * failed*"
        }

        It "Does not treat a successful schtasks warning as task-registration failure" {
            $testExe = Join-Path $TestDrive "probe-create-warning.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"

            Mock schtasks.exe {
                if ($args -contains '/Create') {
                    & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('WARNING: Batch logon privilege needs to be enabled for the task principal.')"
                }
                $global:LASTEXITCODE = 0
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                [pscustomobject]@{
                    Id = 8004
                    Message = 'probe-create-warning.exe was prevented from running'
                    UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' }
                }
            } -ModuleName BrowserBoundaryProbe

            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Stop'
                $result = Invoke-StudentExecutableTaskProbe `
                    -ProbeName 'Create warning probe' `
                    -UserName 'student01' `
                    -Password 'secret' `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -TimeoutSeconds 1
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            $result.status | Should -Be 'pass'
        }

        It "Preserves quotes around executable paths with spaces for schtasks /TR" {
            $testDirectory = Join-Path $TestDrive "Program Files\OpenPath Probe"
            New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
            $testExe = Join-Path $testDirectory "probe.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"
            $global:openPathCapturedTaskCreateArguments = $null

            Mock schtasks.exe {
                if ($args -contains '/Create') {
                    $global:openPathCapturedTaskCreateArguments = @($args)
                }
                $global:LASTEXITCODE = 0
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                return @(
                    [pscustomobject]@{
                        Id = 8004
                        Message = "probe.exe was prevented from running"
                        UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' }
                    }
                )
            } -ModuleName BrowserBoundaryProbe

            try {
                $result = Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Quoted path probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Arguments '--new-window about:blank' `
                    -Expectation ExpectDenied `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -TimeoutSeconds 1

                $result.status | Should -Be 'pass'
                $trIndex = [array]::IndexOf($global:openPathCapturedTaskCreateArguments, '/TR')
                $trIndex | Should -BeGreaterThan -1
                $global:openPathCapturedTaskCreateArguments[$trIndex + 1] |
                    Should -Be ('\"' + $testExe + '\" --new-window about:blank')
            }
            finally {
                Remove-Variable -Name openPathCapturedTaskCreateArguments -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It "Throws when ExpectDenied but no 8004 event and no process observed" {
            $testExe = Join-Path $TestDrive "probe-no-8004.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { return @() } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "No 8004 probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied `
                    -TimeoutSeconds 1
            } | Should -Throw "*AppLocker 8004 block event was not observed*"
        }

        It 'collects 8002 and 8020 correlation diagnostics without weakening the denied gate' {
            $testExe = Join-Path $TestDrive 'probe-denied-allow-diagnostics.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $queryIds = [System.Collections.Generic.List[int]]::new()
            $studentProcess = [pscustomobject]@{
                processId = 4242
                name = 'msedge.exe'
                executablePath = $testExe
                matchesStudentSid = $true
                tokenIdentityVerified = $true
            }
            $allowEvent = [pscustomobject]@{
                Id = 8002
                FilePath = $testExe
                PackageName = 'Microsoft.MicrosoftEdge.Stable'
                UserSid = 'S-1-5-21-student-sid'
                ProcessId = 4242
            }

            Mock Invoke-OpenPathSchtasksCommand { 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathSamBoundaryEvidence { $null } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathTaskIdentityEvidence { [pscustomobject]@{ status = 'unknown' } } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathTestAppLockerPolicyDecision {
                [pscustomobject]@{ status = 'unknown'; decision = 'unknown'; path = $testExe; userSid = 'S-1-5-21-student-sid' }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathExactProcessBoundaryEvidence { $studentProcess } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathAppLockerEventQuery {
                param([int]$EventId, [string]$LogName, [datetime]$StartTime)
                [void]$queryIds.Add($EventId)
                $events = if ($EventId -in @(8002, 8020)) {
                    @([pscustomobject]@{
                            Id = $EventId
                            FilePath = $allowEvent.FilePath
                            PackageName = $allowEvent.PackageName
                            UserSid = $allowEvent.UserSid
                            ProcessId = $allowEvent.ProcessId
                        })
                }
                else { @() }
                [pscustomobject]@{
                    status = if ($events.Count -gt 0) { 'QUERY_SUCCEEDED_MATCHES' } else { 'QUERY_SUCCEEDED_NO_MATCHES' }
                    channel = $LogName
                    logName = $LogName
                    eventId = $EventId
                    startTime = $StartTime
                    channelExists = $true
                    queryAttempted = $true
                    querySucceeded = $true
                    eventCount = $events.Count
                    events = $events
                }
            } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName 'Denied allow diagnostics probe' `
                    -UserName 'student01' `
                    -Password 'secret' `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied `
                    -ProcessName msedge `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -PackagedAppPattern 'MicrosoftEdge|Edge' `
                    -TimeoutSeconds 1
            } | Should -Throw '*no correlated AppLocker block event was observed*'

            @($queryIds | Sort-Object -Unique) | Should -Be @(8002, 8004, 8020, 8022)
            $failureEvidence = Get-OpenPathLastBoundaryProbeFailureEvidence
            @($failureEvidence.appLockerEventQueries.Keys | Sort-Object) | Should -Be @('8002', '8004', '8020', '8022')
            $failureEvidence.appLockerEventQueries.'8002'.status | Should -Be 'QUERY_SUCCEEDED_MATCHES'
            $failureEvidence.appLockerEventQueries.'8020'.status | Should -Be 'QUERY_SUCCEEDED_MATCHES'
            $failureEvidence.appLockerEventQueries.'8004'.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            $failureEvidence.appLockerEventQueries.'8022'.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            @($failureEvidence.events | Where-Object {
                    $_.id -in @(8002, 8020) -and $_.pidMatched -and $_.pathMatched -and $_.sidMatched -and $_.packageMatched
                }).Count | Should -Be 2
        }

        It 'does not mark uncorrelated AppLocker candidates as observed' {
            $candidateEvents = @(
                [pscustomobject]@{ id = 8002; pidMatched = $true; nameMatched = $true; pathMatched = $true; sidMatched = $false; packageMatched = $true }
                [pscustomobject]@{ id = 8004; pidMatched = $true; nameMatched = $true; pathMatched = $false; sidMatched = $true; packageMatched = $true }
                [pscustomobject]@{ id = 8020; pidMatched = $false; nameMatched = $true; pathMatched = $true; sidMatched = $true; packageMatched = $true }
                [pscustomobject]@{ id = 8022; pidMatched = $true; nameMatched = $false; pathMatched = $true; sidMatched = $true; packageMatched = $true }
            )
            $queryStatuses = @{
                '8002' = 'QUERY_SUCCEEDED_MATCHES'
                '8004' = 'QUERY_SUCCEEDED_MATCHES'
                '8020' = 'QUERY_SUCCEEDED_MATCHES'
                '8022' = 'QUERY_SUCCEEDED_MATCHES'
            }
            $evidence = InModuleScope BrowserBoundaryProbe -Parameters @{ CandidateEvents = $candidateEvents; QueryStatuses = $queryStatuses } {
                param($CandidateEvents, $QueryStatuses)
                Set-OpenPathBoundaryProbeFailureEvidence `
                    -ProbeName 'Uncorrelated candidate probe' `
                    -ExecutablePath 'C:\msedge.exe' `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -FailureCode 'appLocker-block-event-not-observed' `
                    -Events $CandidateEvents `
                    -AppLockerQueryStatuses $QueryStatuses
            }

            $evidence.appLocker8002 | Should -BeFalse
            $evidence.appLocker8004 | Should -BeFalse
            $evidence.appLocker8020 | Should -BeFalse
            $evidence.appLocker8022 | Should -BeFalse
        }

        It 'preserves successful allow queries when allow-event correlation fails' {
            $testExe = Join-Path $TestDrive 'probe-allow-correlation-failure.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $queryIds = [System.Collections.Generic.List[int]]::new()
            $studentProcess = [pscustomobject]@{
                processId = 4242
                name = 'msedge.exe'
                executablePath = $testExe
                matchesStudentSid = $true
                tokenIdentityVerified = $true
            }

            Mock Invoke-OpenPathSchtasksCommand { 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathSamBoundaryEvidence { $null } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathTaskIdentityEvidence { [pscustomobject]@{ status = 'unknown' } } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathTestAppLockerPolicyDecision {
                [pscustomobject]@{ status = 'unknown'; decision = 'unknown'; path = $testExe; userSid = 'S-1-5-21-student-sid' }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathExactProcessBoundaryEvidence { $studentProcess } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathAppLockerEventQuery {
                param([int]$EventId, [string]$LogName, [datetime]$StartTime)
                [void]$queryIds.Add($EventId)
                $events = if ($EventId -in @(8002, 8020)) {
                    @([pscustomobject]@{ Id = $EventId; FilePath = $testExe; PackageName = 'Microsoft.MicrosoftEdge.Stable'; UserSid = 'S-1-5-21-student-sid'; ProcessId = 4242 })
                }
                else { @() }
                [pscustomobject]@{
                    status = if ($events.Count -gt 0) { 'QUERY_SUCCEEDED_MATCHES' } else { 'QUERY_SUCCEEDED_NO_MATCHES' }
                    channel = $LogName
                    logName = $LogName
                    eventId = $EventId
                    startTime = $StartTime
                    channelExists = $true
                    queryAttempted = $true
                    querySucceeded = $true
                    eventCount = $events.Count
                    events = $events
                }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathCorrelatedAppLockerEvent {
                param($AllowedEventIds)
                if ($AllowedEventIds -contains 8002 -or $AllowedEventIds -contains 8020) {
                    throw [System.InvalidOperationException]::new('correlation-secret-message')
                }
                [pscustomobject]@{ matched = $false; event = $null; candidates = @() }
            } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName 'Allow correlation failure probe' `
                    -UserName 'student01' `
                    -Password 'secret' `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied `
                    -ProcessName msedge `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -PackagedAppPattern 'MicrosoftEdge|Edge' `
                    -TimeoutSeconds 1
            } | Should -Throw '*no correlated AppLocker block event was observed*'

            $failureEvidence = Get-OpenPathLastBoundaryProbeFailureEvidence
            $failureEvidence.appLockerEventQueries.'8002'.status | Should -Be 'QUERY_SUCCEEDED_MATCHES'
            $failureEvidence.appLockerEventQueries.'8002'.querySucceeded | Should -BeTrue
            $failureEvidence.appLockerEventQueries.'8002'.correlationStatus | Should -Be 'CORRELATION_FAILED'
            $failureEvidence.appLockerEventQueries.'8002'.correlationException.safeReason | Should -Be 'event-correlation-failed'
            $failureEvidence.appLockerEventQueries.'8002'.correlationException.PSObject.Properties['Message'] | Should -Be $null
            ($failureEvidence | ConvertTo-Json -Depth 20) | Should -Not -Match 'correlation-secret-message|Password|Message'
            $failureEvidence.appLockerEventQueries.'8020'.status | Should -Be 'QUERY_SUCCEEDED_MATCHES'
            $failureEvidence.appLockerEventQueries.'8020'.querySucceeded | Should -BeTrue
            $failureEvidence.appLockerEventQueries.'8020'.correlationStatus | Should -Be 'CORRELATION_FAILED'
            $failureEvidence.appLockerEventQueries.'8020'.correlationException.safeReason | Should -Be 'event-correlation-failed'
            $failureEvidence.appLocker8002 | Should -BeNullOrEmpty
            $failureEvidence.appLocker8020 | Should -BeNullOrEmpty
            @($queryIds | Sort-Object -Unique) | Should -Be @(8002, 8004, 8020, 8022)
        }

        It 'emits bounded scheduled-task state when a denied probe has no correlated event' {
            $testExe = Join-Path $TestDrive 'probe-no-event.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $env:OPENPATH_TEST_FORCE_SCHTASKS = '0'
            $env:OPENPATH_TEST_FORCE_SCHEDULED_TASK_CMDLETS = '1'
            Mock Register-ScheduledTask {} -ModuleName BrowserBoundaryProbe
            Mock Start-ScheduledTask {} -ModuleName BrowserBoundaryProbe
            Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } } -ModuleName BrowserBoundaryProbe
            Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastTaskResult = 3221225506; LastRunTime = [datetime]'2026-09-10T08:00:00Z' } } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { @() } -ModuleName BrowserBoundaryProbe
            Mock Unregister-ScheduledTask {} -ModuleName BrowserBoundaryProbe
            Mock Write-Host {} -ModuleName BrowserBoundaryProbe
            try {
                { Invoke-StudentExecutableTaskProbe -ProbeName 'No event probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -StudentSid 'S-1-5-21-student-sid' -PackagedAppPattern 'MicrosoftEdge|Edge' -TimeoutSeconds 1 } |
                    Should -Throw '*AppLocker 8004/8022 block event was not observed*'
                Should -Invoke Write-Host -ModuleName BrowserBoundaryProbe -ParameterFilter {
                    $Object -match '^OPENPATH_BOUNDARY_PROBE_FAILURE state=Ready lastTaskResult=0xC0000022 lastRunObserved=true$'
                } -Times 1
                $failureEvidence = Get-OpenPathLastBoundaryProbeFailureEvidence
                $failureEvidence.appLockerEventQueries.'8002'.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
                $failureEvidence.appLockerEventQueries.'8020'.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
                $failureEvidence.appLocker8002 | Should -BeFalse
                $failureEvidence.appLocker8020 | Should -BeFalse
            }
            finally {
                Remove-Item Env:OPENPATH_TEST_FORCE_SCHEDULED_TASK_CMDLETS -ErrorAction SilentlyContinue
                $env:OPENPATH_TEST_FORCE_SCHTASKS = '1'
            }
        }

        It "Throws immediately when ExpectDenied but payload marker file is created" {
            $testExe = Join-Path $TestDrive "probe-marker-appeared.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"
            $markerPath = Join-Path $TestDrive "marker-appeared.txt"
            Set-Content -LiteralPath $markerPath -Value "ran"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Marker appeared probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied `
                    -MarkerPath $markerPath `
                    -TimeoutSeconds 1
            } | Should -Throw "*executable ran and created marker file*"
        }

        It "Passes when ExpectDenied and matching AppLocker 8004 event is observed" {
            $testExe = Join-Path $TestDrive "probe-denied-pass.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"
            $markerPath = Join-Path $TestDrive "marker-absent.txt"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                return @(
                    [pscustomobject]@{
                        Id = 8004
                        Message = "probe-denied-pass.exe was prevented from running"
                        UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' }
                    }
                )
            } -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe `
                -ProbeName "Denied pass probe" `
                -UserName "student01" `
                -Password "secret" `
                -ExecutablePath $testExe `
                -Expectation ExpectDenied `
                -StudentSid 'S-1-5-21-student-sid' `
                -MarkerPath $markerPath `
                -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            $result.evidence.appLocker8004Observed | Should -BeTrue
        }

        It 'does not attribute an unrelated admin process to the denied student launch' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = [pscustomobject]@{ ProcessId = 1234; Name = 'msedge.exe'; ExecutablePath = '' }
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-Process { [pscustomobject]@{ Id = 1234; ProcessName = 'msedge' } } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-32-544' } } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                [pscustomobject]@{ Id = 8004; Message = 'msedge.exe was prevented from running'; UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' } }
            } -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe -ProbeName 'Denied Edge ownership probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName msedge -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            Should -Invoke Stop-Process -ModuleName BrowserBoundaryProbe -Times 0
        }

        It 'accepts a matching packaged-app 8022 denial for Edge under the student SID' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { @() } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                if ($FilterHashtable.LogName -eq 'Microsoft-Windows-AppLocker/Packaged app-Execution') {
                    return [pscustomobject]@{ Id = 8022; Message = 'Microsoft.MicrosoftEdge.Stable was prevented from running'; UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' } }
                }
                return @()
            } -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe -ProbeName 'Denied packaged Edge probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName msedge -StudentSid 'S-1-5-21-student-sid' -PackagedAppPattern 'MicrosoftEdge|Edge' -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            $result.evidence.appLocker8022Observed | Should -BeTrue
        }

        It 'rejects a matching packaged-app 8022 denial attributed to another SID' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { @() } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                if ($FilterHashtable.LogName -eq 'Microsoft-Windows-AppLocker/Packaged app-Execution') {
                    return [pscustomobject]@{ Id = 8022; Message = 'Microsoft.MicrosoftEdge.Stable was prevented from running'; UserId = [pscustomobject]@{ Value = 'S-1-5-21-other-sid' } }
                }
                return @()
            } -ModuleName BrowserBoundaryProbe

            { Invoke-StudentExecutableTaskProbe -ProbeName 'Denied packaged Edge wrong SID probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName msedge -StudentSid 'S-1-5-21-student-sid' -PackagedAppPattern 'MicrosoftEdge|Edge' -TimeoutSeconds 1 } |
                Should -Throw '*AppLocker 8004/8022 block event was not observed*'
        }

        It 'does not classify an owned process without a matching executable path as the requested launch' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = if (Get-Command New-CimInstance -ErrorAction SilentlyContinue) {
                New-CimInstance -ClassName Win32_Process -Namespace root/cimv2 -ClientOnly -Property @{ ProcessId = 1234; Name = 'msedge.exe' }
            } else { [pscustomobject]@{ ProcessId = 1234; Name = 'msedge.exe' } }
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-Process { [pscustomobject]@{ Id = 1234; ProcessName = 'msedge' } } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-21-student-sid' } } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe
            Mock Write-Host {} -ModuleName BrowserBoundaryProbe

            { Invoke-StudentExecutableTaskProbe -ProbeName 'Denied student ownership probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName msedge -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1 } |
                Should -Throw '*AppLocker 8004 block event was not observed*'
            Should -Invoke Stop-Process -ModuleName BrowserBoundaryProbe -Times 0
        }

        It 'does not treat an owned msedgewebview2 process as the requested msedge executable' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = [pscustomobject]@{ ProcessId = 1234; Name = 'msedgewebview2.exe'; ExecutablePath = (Join-Path $TestDrive 'msedgewebview2.exe') }
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-21-student-sid' } } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { @() } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe

            { Invoke-StudentExecutableTaskProbe -ProbeName 'Exact Edge identity probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName msedge -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1 } |
                Should -Throw '*AppLocker 8004 block event was not observed*'
            Should -Invoke Stop-Process -ModuleName BrowserBoundaryProbe -Times 0
        }

        It 'collects the correlated block event before classifying a transient exact process' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = [pscustomobject]@{ ProcessId = 1234; Name = 'msedge.exe'; ExecutablePath = $testExe }
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-21-student-sid' } } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                [pscustomobject]@{ Id = 8004; Message = "msedge.exe was prevented from running"; UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' } }
            } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe -ProbeName 'Transient Edge block probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName msedge -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1
            $result.status | Should -Be 'pass'
            $result.evidence.blockEventId | Should -Be 8004
        }

        It "Passes when ExpectAllowed and marker file is present" {
            $testExe = Join-Path $TestDrive "probe-allowed-marker.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"
            $markerPath = Join-Path $TestDrive "marker-allowed.txt"
            Set-Content -LiteralPath $markerPath -Value "ran"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe `
                -ProbeName "Allowed marker probe" `
                -UserName "student01" `
                -Password "secret" `
                -ExecutablePath $testExe `
                -Expectation ExpectAllowed `
                -MarkerPath $markerPath `
                -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            $result.evidence.allowedObserved | Should -BeTrue
        }

        It "Passes when ExpectAllowed and 8002 allow event is observed with matching student SID" {
            $testExe = Join-Path $TestDrive "probe-allowed-8002.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"
            $markerPath = Join-Path $TestDrive "marker-allowed-absent.txt"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                return @(
                    [pscustomobject]@{
                        Id = 8002
                        Message = "probe-allowed-8002.exe was allowed to run"
                        UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' }
                    }
                )
            } -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe `
                -ProbeName "Allowed 8002 probe" `
                -UserName "student01" `
                -Password "secret" `
                -ExecutablePath $testExe `
                -Expectation ExpectAllowed `
                -StudentSid 'S-1-5-21-student-sid' `
                -MarkerPath $markerPath `
                -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            $result.evidence.allowedObserved | Should -BeTrue
        }

        It 'preserves only the first bounded exact process and task identity on an allowed launch' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = [pscustomobject]@{ ProcessId = 4242; Name = 'msedge.exe'; ExecutablePath = $testExe }
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-21-sam-owner' } } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathSamBoundaryEvidence {
                [pscustomobject]@{
                    status = 'observed'
                    groupName = 'OpenPath-Restricted'
                    groupSid = 'S-1-5-21-openpath-restricted'
                    targetMemberPresent = $true
                    memberCount = 1
                }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessTokenBoundaryEvidence {
                [pscustomobject]@{
                    status = 'ok'
                    tokenUserSid = 'S-1-5-21-student-sid'
                    restrictedGroupSid = 'S-1-5-21-openpath-restricted'
                    restrictedGroupPresent = $true
                    restrictedGroupAttributes = 4
                    restrictedGroupEnabled = $true
                    restrictedGroupDenyOnly = $false
                    restrictedGroupDisabled = $false
                }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { @() } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe -ProbeName 'Allowed process evidence probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectAllowed -ProcessName 'msedge' -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            $result.evidence.observedExactProcess.Count | Should -Be 1
            $result.evidence.observedExactProcess[0].processId | Should -Be 4242
            $result.evidence.observedExactProcess[0].tokenUserSid | Should -Be 'S-1-5-21-student-sid'
            $result.evidence.observedExactProcess[0].restrictedGroupSid | Should -Be 'S-1-5-21-openpath-restricted'
            $result.evidence.observedExactProcess[0].restrictedGroupPresent | Should -BeTrue
            $result.evidence.observedExactProcess[0].restrictedGroupAttributes | Should -Be 4
            $result.evidence.taskIdentity.taskName | Should -Match '^OpenPathProbe-'
            $result.evidence.taskIdentity.registeredAtUtc | Should -Not -BeNullOrEmpty
        }

        It "Throws when ExpectAllowed and 8002 allow event has wrong SID" {
            $testExe = Join-Path $TestDrive "probe-allowed-wrong-sid.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"
            $markerPath = Join-Path $TestDrive "marker-allowed-wrong-sid.txt"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                return @(
                    [pscustomobject]@{
                        Id = 8002
                        Message = "probe-allowed-wrong-sid.exe was allowed to run"
                        UserId = [pscustomobject]@{ Value = 'S-1-5-21-other-sid' }
                    }
                )
            } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Allowed wrong SID probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Expectation ExpectAllowed `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -MarkerPath $markerPath `
                    -TimeoutSeconds 1
            } | Should -Throw "*Allowed execution was not observed*"
        }

        It "Throws when ExpectAllowed and process is observed from unrelated user (e.g. Admin)" {
            $testExe = Join-Path $TestDrive "firefox.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { return @() } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance {
                return @([pscustomobject]@{ ProcessId = 1234; Name = 'firefox.exe' })
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod {
                return [pscustomobject]@{ Sid = 'S-1-5-32-544' }
            } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Allowed admin process probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -ProcessName "firefox" `
                    -Expectation ExpectAllowed `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -TimeoutSeconds 1
            } | Should -Throw "*Allowed execution was not observed*"
        }

        It "Throws when ExpectDenied and 8004 block event has wrong SID" {
            $testExe = Join-Path $TestDrive "probe-denied-wrong-sid.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                return @(
                    [pscustomobject]@{
                        Id = 8004
                        Message = "probe-denied-wrong-sid.exe was prevented from running"
                        UserId = [pscustomobject]@{ Value = 'S-1-5-21-other-sid' }
                    }
                )
            } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Denied wrong SID probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Expectation ExpectDenied `
                    -StudentSid 'S-1-5-21-student-sid' `
                    -TimeoutSeconds 1
            } | Should -Throw "*AppLocker 8004 block event was not observed*"
        }

        It "Throws when ExpectAllowed but no evidence is observed" {
            $testExe = Join-Path $TestDrive "probe-allowed-no-evidence.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { return @() } -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe `
                    -ProbeName "Allowed no evidence probe" `
                    -UserName "student01" `
                    -Password "secret" `
                    -ExecutablePath $testExe `
                    -Expectation ExpectAllowed `
                    -TimeoutSeconds 1
            } | Should -Throw "*Allowed execution was not observed*"
        }

        It 'records exact Edge identity while distinguishing the SAM owner from the process token and restricted group attributes' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = [pscustomobject]@{
                ProcessId = 4242
                Name = 'msedge.exe'
                ExecutablePath = $testExe
            }

            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessOwnerSid { 'S-1-5-21-sam-owner' } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessTokenBoundaryEvidence {
                [pscustomobject]@{
                    status = 'ok'
                    tokenUserSid = 'S-1-5-21-token-owner'
                    restrictedGroupSid = 'S-1-5-21-openpath-restricted'
                    restrictedGroupPresent = $true
                    restrictedGroupAttributes = 4
                    restrictedGroupEnabled = $true
                    restrictedGroupDenyOnly = $false
                    restrictedGroupDisabled = $false
                }
            } -ModuleName BrowserBoundaryProbe

            $evidence = @(Get-OpenPathExactProcessBoundaryEvidence -ProcessName 'msedge' -StudentSid 'S-1-5-21-student-sid' -RestrictedGroupSid 'S-1-5-21-openpath-restricted' -ExpectedExecutablePath $testExe)

            $evidence.Count | Should -Be 1
            $evidence[0].name | Should -Be 'msedge.exe'
            $evidence[0].studentSid | Should -Be 'S-1-5-21-student-sid'
            $evidence[0].executablePath | Should -Be $testExe
            $evidence[0].samSid | Should -Be 'S-1-5-21-sam-owner'
            $evidence[0].tokenUserSid | Should -Be 'S-1-5-21-token-owner'
            $evidence[0].samTokenSidMatch | Should -BeFalse
            $evidence[0].restrictedGroupSid | Should -Be 'S-1-5-21-openpath-restricted'
            $evidence[0].restrictedGroupPresent | Should -BeTrue
            $evidence[0].restrictedGroupAttributes | Should -Be 4
            $evidence[0].restrictedGroupEnabled | Should -BeTrue
            $evidence[0].restrictedGroupDenyOnly | Should -BeFalse
            $evidence[0].restrictedGroupDisabled | Should -BeFalse
        }

        It 'captures the SAM group SID and membership before registering the task' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            Mock Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted'; SID = 'S-1-5-21-openpath-restricted' } } -ModuleName BrowserBoundaryProbe
            Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = 'S-1-5-21-student-sid' }) } -ModuleName BrowserBoundaryProbe
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { @() } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { @() } -ModuleName BrowserBoundaryProbe
            Mock Start-Sleep {} -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe -ProbeName 'SAM evidence Edge probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName 'msedge' -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1 -SuppressFailureDiagnostics
            } | Should -Throw

            $failureEvidence = Get-OpenPathLastBoundaryProbeFailureEvidence
            $failureEvidence.samGroupName | Should -Be 'OpenPath-Restricted'
            $failureEvidence.samGroupSid | Should -Be 'S-1-5-21-openpath-restricted'
            $failureEvidence.samGroupMemberPresent | Should -BeTrue
            $failureEvidence.samGroupMemberCount | Should -Be 1
            $failureEvidence.taskRegisteredAtUtc | Should -Not -BeNullOrEmpty
        }

        It 'correlates observed AppLocker XML fields without substituting expected path or SID' {
            $event = [pscustomobject]@{
                Id = 8004
                Xml = '<Event><System><Execution ProcessID="4242" /></System><EventData><Data Name="FilePath">C:\\Other\\msedge.exe</Data><Data Name="RuleId">rule-1</Data><Data Name="RuleName">wrong-path</Data><Data Name="UserSid">S-1-5-21-student-sid</Data></EventData></Event>'
                UserId = [pscustomobject]@{ Value = 'S-1-5-21-other-fallback' }
            }
            Add-Member -InputObject $event -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }

            $correlation = Get-OpenPathCorrelatedAppLockerEvent -Events @($event) -AllowedEventIds @(8004) -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -BinaryLeaf 'msedge.exe' -ExpectedExecutablePath 'C:\\Expected\\msedge.exe' -StudentSid 'S-1-5-21-student-sid' -ProcessIds @(4242)

            $correlation.matched | Should -BeFalse
            $correlation.candidates[0].observedPath | Should -Be 'C:\\Other\\msedge.exe'
            $correlation.candidates[0].observedUserSid | Should -Be 'S-1-5-21-student-sid'
            $correlation.candidates[0].observedProcessId | Should -Be 4242
            $correlation.candidates[0].observedRuleId | Should -Be 'rule-1'
            $correlation.candidates[0].observedRuleName | Should -Be 'wrong-path'
            $correlation.candidates[0].expected.executablePath | Should -Be 'C:\\Expected\\msedge.exe'
        }

        It 'correlates AppLocker RuleAndFileData leaves case-insensitively and prefers FullFilePath' {
            $event = [pscustomobject]@{
                Id = 8004
                Xml = @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event">
  <System><EventID>8004</EventID><Execution ProcessID="9999" /></System>
  <UserData>
    <RuleAndFileData>
      <rUlEiD>rule-edge</rUlEiD>
      <rUlEnAmE>Edge deny</rUlEnAmE>
      <TaRgEtUsEr>S-1-5-21-student-sid</TaRgEtUsEr>
      <TaRgEtPrOcEsSiD>5436</TaRgEtPrOcEsSiD>
      <TaRgEtLoGoNId>0xedge</TaRgEtLoGoNId>
      <FilePath>%PROGRAMFILES%\Microsoft Edge\Application\msedge.exe</FilePath>
      <FuLlFiLePaTh>C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe</FuLlFiLePaTh>
      <IgnoredLeaf>must-not-become-evidence</IgnoredLeaf>
    </RuleAndFileData>
  </UserData>
</Event>
'@
            }
            Add-Member -InputObject $event -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }

            $expectedPath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            $correlation = Get-OpenPathCorrelatedAppLockerEvent -Events @($event) -AllowedEventIds @(8004) -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -BinaryLeaf 'msedge.exe' -ExpectedExecutablePath $expectedPath -StudentSid 'S-1-5-21-student-sid' -ProcessIds @(5436)

            $correlation.matched | Should -BeTrue
            $correlation.event.observationSource | Should -Be 'event-xml'
            $correlation.event.observedPath | Should -Be $expectedPath
            $correlation.event.observedProcessId | Should -Be 5436
            $correlation.event.observedUserSid | Should -Be 'S-1-5-21-student-sid'
            $correlation.event.observedRuleId | Should -Be 'rule-edge'
            $correlation.event.observedRuleName | Should -Be 'Edge deny'
            $correlation.event.observedTargetLogonId | Should -Be '0xedge'
            ($correlation.event | ConvertTo-Json -Depth 8) | Should -Not -Match 'must-not-become-evidence'
        }

        It 'does not correlate an AppLocker event whose PID belongs to another process' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = [pscustomobject]@{ ProcessId = 4242; Name = 'msedge.exe'; ExecutablePath = $testExe }
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-21-student-sid' } } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessTokenBoundaryEvidence {
                [pscustomobject]@{
                    status = 'ok'
                    tokenUserSid = 'S-1-5-21-student-sid'
                    restrictedGroupSid = $null
                    restrictedGroupPresent = $null
                    restrictedGroupQueryStatus = 'not-requested'
                }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                [pscustomobject]@{
                    Id = 8004
                    ProcessId = 9999
                    Message = "msedge.exe was prevented from running"
                    UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' }
                }
            } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe
            Mock Start-Sleep {} -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe -ProbeName 'PID mismatch Edge probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName 'msedge' -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1 -SuppressFailureDiagnostics
            } | Should -Throw '*exact executable msedge.exe ran under the student SID and no correlated AppLocker block event was observed*'
            Should -Invoke Stop-Process -ModuleName BrowserBoundaryProbe -Times 1
        }

        It 'retains one correlated 8002 and 8020 event through a saturated bounded report' {
            $expectedPath = 'C:\msedge.exe'
            $studentSid = 'S-1-5-21-student-sid'
            $noise8002 = @(0..31 | ForEach-Object {
                    [pscustomobject]@{
                        Id = 8002
                        FilePath = "C:\noise\allow-$_.exe"
                        UserSid = 'S-1-5-21-other-sid'
                        ProcessId = 6000 + $_
                        PackageName = 'Other.Package'
                        RuleId = "noise-8002-$_"
                    }
                })
            $noise8020 = @(0..31 | ForEach-Object {
                    [pscustomobject]@{
                        Id = 8020
                        FilePath = "C:\noise\package-$_.exe"
                        UserSid = 'S-1-5-21-other-sid'
                        ProcessId = 7000 + $_
                        PackageName = 'Other.Package'
                        RuleId = "noise-8020-$_"
                    }
                })
            $exact8002 = [pscustomobject]@{
                Id = 8002
                FilePath = $expectedPath
                UserSid = $studentSid
                ProcessId = 4242
                PackageName = 'Microsoft.MicrosoftEdge.Stable'
                RuleId = 'exact-8002'
            }
            $exact8020 = [pscustomobject]@{
                Id = 8020
                FilePath = $expectedPath
                UserSid = $studentSid
                ProcessId = 4242
                PackageName = 'Microsoft.MicrosoftEdge.Stable'
                RuleId = 'exact-8020'
            }
            $reportPath = Join-Path $TestDrive 'saturated-browser-boundary-report.json'

            $transport = InModuleScope BrowserBoundaryProbe -Parameters @{
                Noise8002 = $noise8002
                Noise8020 = $noise8020
                Exact8002 = $exact8002
                Exact8020 = $exact8020
                ExpectedPath = $expectedPath
                StudentSid = $studentSid
            } {
                param($Noise8002, $Noise8020, $Exact8002, $Exact8020, $ExpectedPath, $StudentSid)

                $correlation8002 = Get-OpenPathCorrelatedAppLockerEvent `
                    -Events @($Noise8002 + $Exact8002) `
                    -AllowedEventIds @(8002) `
                    -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' `
                    -BinaryLeaf 'msedge.exe' `
                    -ExpectedExecutablePath $ExpectedPath `
                    -StudentSid $StudentSid `
                    -ProcessIds @(4242)
                $correlation8020 = Get-OpenPathCorrelatedAppLockerEvent `
                    -Events @($Noise8020 + $Exact8020) `
                    -AllowedEventIds @(8020) `
                    -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' `
                    -BinaryLeaf 'msedge.exe' `
                    -ExpectedExecutablePath $ExpectedPath `
                    -StudentSid $StudentSid `
                    -ProcessIds @(4242) `
                    -PackagedAppPattern 'MicrosoftEdge|Edge'

                $cachedUncorrelated = $correlation8002.candidates[-1] | Select-Object *
                $cachedUncorrelated.sidMatched = $false
                $existing = @(@($correlation8002.candidates | Select-Object -First 31) + @($cachedUncorrelated))
                $merged = Merge-OpenPathBoundedEvidence `
                    -Existing $existing `
                    -Incoming @($correlation8002.candidates) `
                    -Kind event
                $merged = Merge-OpenPathBoundedEvidence `
                    -Existing $merged `
                    -Incoming @($correlation8020.candidates) `
                    -Kind event

                $evidence = Set-OpenPathBoundaryProbeFailureEvidence `
                    -ProbeName 'Saturated event evidence probe' `
                    -ExecutablePath $ExpectedPath `
                    -StudentSid $StudentSid `
                    -FailureCode 'appLocker-allow-event-not-observed' `
                    -Events $merged `
                    -ExpectedEventIds @(8002, 8020) `
                    -AppLockerQueryStatuses @{ '8002' = 'QUERY_SUCCEEDED_MATCHES'; '8020' = 'QUERY_SUCCEEDED_MATCHES' } `
                    -AppLockerEventQueries @{
                        '8002' = [pscustomobject]@{ status = 'QUERY_SUCCEEDED_MATCHES' }
                        '8020' = [pscustomobject]@{ status = 'QUERY_SUCCEEDED_MATCHES' }
                    }
                [pscustomobject]@{
                    evidence = $evidence
                    merged = $merged
                    correlation8002 = $correlation8002
                    correlation8020 = $correlation8020
                }
            }

            $transport.correlation8002.matched | Should -BeTrue
            $transport.correlation8020.matched | Should -BeTrue
            $transport.correlation8002.candidates.Count | Should -Be 33
            $transport.correlation8020.candidates.Count | Should -Be 33
            $transport.merged.Count | Should -Be 32
            @($transport.merged | Where-Object { $_.id -eq 8002 -and $_.pidMatched -and $_.nameMatched -and $_.pathMatched -and $_.sidMatched -and $_.packageMatched }).Count | Should -Be 1
            @($transport.merged | Where-Object { $_.id -eq 8020 -and $_.pidMatched -and $_.nameMatched -and $_.pathMatched -and $_.sidMatched -and $_.packageMatched }).Count | Should -Be 1
            $transport.evidence.appLocker8002 | Should -BeTrue
            $transport.evidence.appLocker8020 | Should -BeTrue

            $report = [pscustomobject][ordered]@{
                results = @([pscustomobject][ordered]@{
                        name = 'Saturated event evidence probe'
                        status = 'fail'
                        evidence = $transport.evidence
                    })
            }
            Write-OpenPathBrowserBoundaryReport -Report $report -Path $reportPath
            $roundTrip = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $roundTrip.results[0].evidence.appLocker8002 | Should -BeTrue
            $roundTrip.results[0].evidence.appLocker8020 | Should -BeTrue
            @($roundTrip.results[0].evidence.events | Where-Object { $_.id -in @(8002, 8020) -and $_.sidMatched -and $_.pathMatched }).Count | Should -Be 2
        }

        It 'accepts the packaged-app 8020 allow event and keeps the evidence credential-free' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { @() } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                if ($FilterHashtable.LogName -eq 'Microsoft-Windows-AppLocker/Packaged app-Execution' -and $FilterHashtable.Id -eq 8020) {
                    return [pscustomobject]@{
                        Id = 8020
                        ProcessId = 4242
                        Message = 'Microsoft.MicrosoftEdge.Stable was allowed to run'
                        UserId = [pscustomobject]@{ Value = 'S-1-5-21-student-sid' }
                    }
                }
                return @()
            } -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe -ProbeName 'Allowed packaged Edge probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectAllowed -ProcessName 'msedge' -StudentSid 'S-1-5-21-student-sid' -PackagedAppPattern 'MicrosoftEdge|Edge' -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            $result.evidence.allowEventId | Should -Be 8020
            ($result | ConvertTo-Json -Depth 8) | Should -Not -Match 'secret|Password'
        }

        It 'preserves failed Edge evidence before throwing without serializing credentials' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $testProcess = [pscustomobject]@{ ProcessId = 4242; Name = 'msedge.exe'; ExecutablePath = $testExe }
            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-CimInstance { $testProcess } -ModuleName BrowserBoundaryProbe
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-21-student-sid' } } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessTokenBoundaryEvidence {
                [pscustomobject]@{
                    status = 'ok'
                    tokenUserSid = 'S-1-5-21-student-sid'
                    restrictedGroupSid = $null
                    restrictedGroupPresent = $null
                    restrictedGroupQueryStatus = 'not-requested'
                }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { @() } -ModuleName BrowserBoundaryProbe
            Mock Stop-Process {} -ModuleName BrowserBoundaryProbe
            Mock Start-Sleep {} -ModuleName BrowserBoundaryProbe

            {
                Invoke-StudentExecutableTaskProbe -ProbeName 'Canonical Edge deny' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -ProcessName 'msedge' -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1 -SuppressFailureDiagnostics
            } | Should -Throw

            $failureEvidence = Get-OpenPathLastBoundaryProbeFailureEvidence
            $failureEvidence.probeName | Should -Be 'Canonical Edge deny'
            $failureEvidence.executablePath | Should -Be $testExe
            $failureEvidence.processes[0].name | Should -Be 'msedge.exe'
            ($failureEvidence | ConvertTo-Json -Depth 10) | Should -Not -Match 'student01|secret|Password'
        }

        It 'uses ABI-aligned SID_AND_ATTRIBUTES parsing for x64 token groups' {
            $probeModule = Get-Content (Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "BrowserBoundaryProbe.psm1") -Raw

            $probeModule | Should -Not -Match '\$groupStride\s*=\s*\[IntPtr\]::Size\s*\+\s*4'
            Assert-ContentContainsAll -Content $probeModule -Needles @(
                'StructLayout(LayoutKind.Sequential)',
                'SID_AND_ATTRIBUTES',
                'Marshal.SizeOf'
            )
        }

        It 'keeps unavailable token group membership unknown instead of false' {
            $tokenEvidence = Get-OpenPathProcessTokenBoundaryEvidence -ProcessId 0 -RestrictedGroupSid 'S-1-5-21-openpath-restricted'

            $tokenEvidence.restrictedGroupPresent | Should -Be $null
            $tokenEvidence.restrictedGroupQueryStatus | Should -BeIn @('unavailable', 'not-observed')
        }

        It 'captures a Test-AppLockerPolicy decision as observed or explicitly unknown' {
            Mock Get-AppLockerPolicy { [pscustomobject]@{ RuleCollections = @([pscustomobject]@{ Type = 'Exe' }) } } -ModuleName BrowserBoundaryProbe
            Mock Test-AppLockerPolicy {
                [pscustomobject]@{ FilePath = 'C:\msedge.exe'; PolicyDecision = 'Denied' }
            } -ModuleName BrowserBoundaryProbe

            $decision = Get-OpenPathTestAppLockerPolicyDecision -ExecutablePath 'C:\msedge.exe' -StudentSid 'S-1-5-21-student-sid'

            $decision.status | Should -Be 'observed'
            $decision.decision | Should -Be 'Denied'
            $decision.userSid | Should -Be 'S-1-5-21-student-sid'
        }

        It 'keeps task identity and bounded TaskScheduler/Security logon evidence explicit' {
            $probeModule = Get-Content (Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "BrowserBoundaryProbe.psm1") -Raw

            Assert-ContentContainsAll -Content $probeModule -Needles @(
                'taskIdentity',
                'principal',
                'taskLogonType',
                'securityLogonType',
                'runLevel',
                'TaskScheduler/Operational',
                '129',
                '200',
                '201',
                "LogName = 'Security'",
                '4624',
                'logonId',
                'unknown'
            )
        }

        It 'does not conflate Task Scheduler logon enums with Security 4624 logon types' {
            $securityEvent = [pscustomobject]@{
                Id = 4624
                Xml = '<Event><EventData><Data Name="TargetUserSid">S-1-5-21-student-sid</Data><Data Name="TargetUserName">student01</Data><Data Name="LogonType">4</Data><Data Name="TargetLogonId">0x123</Data></EventData></Event>'
            }
            Add-Member -InputObject $securityEvent -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
            Mock Get-ScheduledTask {
                [pscustomobject]@{
                    Principal = [pscustomobject]@{ UserId = 'CONTOSO\student01'; LogonType = 'Password'; RunLevel = 'Limited' }
                }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                if ($FilterHashtable.LogName -eq 'Security') { return $securityEvent }
                return @()
            } -ModuleName BrowserBoundaryProbe

            $taskEvidence = Get-OpenPathTaskIdentityEvidence -TaskName 'OpenPathProbe-test' -StudentSid 'S-1-5-21-student-sid' -UserName 'student01'

            $taskEvidence.taskDefinitionPrincipal | Should -Be 'CONTOSO\student01'
            $taskEvidence.taskLogonType | Should -Be 'Password'
            $taskEvidence.expectedStudentSid | Should -Be 'S-1-5-21-student-sid'
            $taskEvidence.principal | Should -Be 'CONTOSO\student01'
            $taskEvidence.PSObject.Properties.Name | Should -Not -Contain 'logonType'
            $taskEvidence.securityLogons[0].securityLogonType | Should -Be '4'
            $taskEvidence.securityLogons[0].logonId | Should -Be '0x123'
        }

        It 'exposes the requested nested Edge failure contract without credentials' {
            $testExe = Join-Path $TestDrive 'msedge.exe'
            Set-Content -LiteralPath $testExe -Value 'dummy'
            $evidence = [pscustomobject][ordered]@{
                executableName = 'msedge.exe'
                executablePath = $testExe
                studentSid = 'S-1-5-21-student-sid'
                failureCode = 'test-failure'
                expectedEventIds = @(8002, 8004, 8020, 8022)
                samGroupName = 'OpenPath-Restricted'
                samGroupSid = 'S-1-5-21-openpath-restricted'
                samGroupMemberPresent = $true
                samGroupMemberCount = 1
                taskRegisteredAtUtc = '2026-09-10T00:00:00.0000000Z'
                processes = @([pscustomobject]@{
                        processId = 4242
                        name = 'msedge.exe'
                        executablePath = $testExe
                        samSid = 'S-1-5-21-sam-owner'
                        tokenUserSid = 'S-1-5-21-token-owner'
                        restrictedGroupSid = 'S-1-5-21-openpath-restricted'
                        restrictedGroupPresent = $true
                    })
                events = @()
                matchedEvent = $null
            }

            $contract = Get-OpenPathFlatEdgeBoundaryFailureContract -Evidence $evidence
            $contract.edge | Should -Not -BeNullOrEmpty
            @('expectedPath', 'observedExactProcess', 'observedPid', 'studentSid', 'restrictedGroupSid', 'restrictedGroupSamMember', 'restrictedGroupTokenMember', 'testAppLockerPolicyDecision', 'appLocker8002', 'appLocker8004', 'appLocker8020', 'appLocker8022') | ForEach-Object {
                $contract.edge.PSObject.Properties.Name | Should -Contain $_
            }
            ($contract | ConvertTo-Json -Depth 10) | Should -Not -Match 'secret|Password'
        }

        It 'uses exactly T0, T+5, T+15 and T+30 attempts without reapplying policy' {
            $script:diagnosticCalls = 0
            Mock Invoke-StudentExecutableTaskProbe {
                $script:diagnosticCalls++
                [pscustomobject]@{ status = 'pass'; evidence = [pscustomobject]@{ allowEventId = 8020 } }
            } -ModuleName BrowserBoundaryProbe
            Mock Start-Sleep {} -ModuleName BrowserBoundaryProbe

            $diagnostic = Invoke-OpenPathEdgeBoundaryDiagnostic -UserName 'student01' -Password 'secret' -ExecutablePath 'C:\msedge.exe' -StudentSid 'S-1-5-21-student-sid' -AttemptOffsetsSeconds @(0, 5, 15, 30)

            $script:diagnosticCalls | Should -Be 4
            @($diagnostic.attempts).Count | Should -Be 4
            @($diagnostic.attempts | ForEach-Object { $_.offsetSeconds }) | Should -Be @(0, 5, 15, 30)
            $diagnostic.diagnosticStartedAtUtc | Should -Not -BeNullOrEmpty
            @($diagnostic.attempts | Where-Object { $null -eq $_.elapsedSeconds }).Count | Should -Be 0
            @($diagnostic.attempts | ForEach-Object { $_.elapsedSeconds })[0] | Should -BeGreaterOrEqual 0
            $diagnostic.policyReapplied | Should -BeFalse
            ($diagnostic | ConvertTo-Json -Depth 10) | Should -Not -Match 'student01|secret|Password'
        }
    }

    Context "Assert-InstalledOpenPathBrowserBoundaryAppControl" {
        BeforeEach {
            $script:probeRoot = Join-Path $TestDrive "probe-root-$([guid]::NewGuid().ToString('N'))"
            $dataDir = Join-Path $script:probeRoot "data"
            $libDir = Join-Path $script:probeRoot "lib"
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $libDir "AppControl.psm1") -Value @"
function Test-OpenPathNonAdminAppControlActive { param(`$Mode, `$ApprovedBrowsers) return `$global:mockAppControlActive }
function Set-OpenPathNonAdminAppControl { param(`$OpenPathRoot, `$Mode, `$ApprovedBrowsers) `$global:mockSetAppControlCalled = `$true; return `$true }
Export-ModuleMember -Function Test-OpenPathNonAdminAppControlActive, Set-OpenPathNonAdminAppControl
"@
            $global:mockAppControlActive = $true
            $global:mockSetAppControlCalled = $false
        }

        AfterEach {
            Remove-Variable -Name mockAppControlActive -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name mockSetAppControlCalled -Scope Global -ErrorAction SilentlyContinue
            Get-Module AppControl | Remove-Module -Force -ErrorAction SilentlyContinue
        }

        AfterAll {
            Remove-Variable -Name mockAppControlActive -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name mockSetAppControlCalled -Scope Global -ErrorAction SilentlyContinue
            Get-Module AppControl | Remove-Module -Force -ErrorAction SilentlyContinue
            $realAppControl = Join-Path $PSScriptRoot ".." "lib" "AppControl.psm1"
            if (Test-Path $realAppControl) {
                Import-Module $realAppControl -Force -Global -ErrorAction SilentlyContinue
            }
        }

        It "Throws and never calls Set-OpenPathNonAdminAppControl when AppLocker boundary is inactive" {
            $global:mockAppControlActive = $false
            $config = [pscustomobject]@{
                installState = 'complete'
                appControlCommitState = 'committed'
                enableNonAdminAppControl = $true
                nonAdminAppControlMode = 'Enforced'
                approvedStudentBrowsers = @('Firefox')
            }
            $config | ConvertTo-Json | Set-Content (Join-Path $script:probeRoot "data\config.json")

            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'OpenPath-Watchdog' } } -ModuleName BrowserBoundaryProbe
            Mock Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted' } } -ModuleName BrowserBoundaryProbe
            Mock Get-Service { [pscustomobject]@{ Status = 'Running' } } -ModuleName BrowserBoundaryProbe

            {
                Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $script:probeRoot
            } | Should -Throw "*OpenPath AppControl boundary is inactive before browser-boundary probes; installer acceptance failed.*"

            $global:mockSetAppControlCalled | Should -BeFalse
        }

        It "Throws when OpenPath-Watchdog scheduled task is missing" {
            $config = [pscustomobject]@{
                installState = 'complete'
                appControlCommitState = 'committed'
                enableNonAdminAppControl = $true
            }
            $config | ConvertTo-Json | Set-Content (Join-Path $script:probeRoot "data\config.json")

            Mock Get-ScheduledTask { return $null } -ModuleName BrowserBoundaryProbe
            Mock Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted' } } -ModuleName BrowserBoundaryProbe
            Mock Get-Service { [pscustomobject]@{ Status = 'Running' } } -ModuleName BrowserBoundaryProbe

            {
                Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $script:probeRoot
            } | Should -Throw "*OpenPath-Watchdog scheduled task is missing*"
        }

        It "Throws when appControlCommitState is pending" {
            $config = [pscustomobject]@{
                installState = 'complete'
                appControlCommitState = 'pending'
                enableNonAdminAppControl = $true
            }
            $config | ConvertTo-Json | Set-Content (Join-Path $script:probeRoot "data\config.json")

            {
                Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $script:probeRoot
            } | Should -Throw "*appControlCommitState must be 'committed'*"
        }

        It "Throws when installState is installing" {
            $config = [pscustomobject]@{
                installState = 'installing'
                appControlCommitState = 'committed'
                enableNonAdminAppControl = $true
            }
            $config | ConvertTo-Json | Set-Content (Join-Path $script:probeRoot "data\config.json")

            {
                Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $script:probeRoot
            } | Should -Throw "*installState must be 'complete'*"
        }

        It "Passes when complete, committed, active, watchdog present and admin allow-all rule present" {
            $config = [pscustomobject]@{
                installState = 'complete'
                appControlCommitState = 'committed'
                enableNonAdminAppControl = $true
                nonAdminAppControlMode = 'Enforced'
                approvedStudentBrowsers = @('Firefox')
            }
            $config | ConvertTo-Json | Set-Content (Join-Path $script:probeRoot "data\config.json")

            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'OpenPath-Watchdog' } } -ModuleName BrowserBoundaryProbe
            Mock Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted' } } -ModuleName BrowserBoundaryProbe
            Mock Get-Service { [pscustomobject]@{ Status = 'Running' } } -ModuleName BrowserBoundaryProbe
            Mock Get-AppLockerPolicy {
                @"
<AppLockerPolicy Version="1">
    <RuleCollection Type="Exe" EnforcementMode="Enabled">
        <FilePathRule Id="$([guid]::NewGuid())" Name="Allow all for Admins" Action="Allow" UserOrGroupSid="S-1-5-32-544">
            <Conditions>
                <FilePathCondition Path="*" />
            </Conditions>
        </FilePathRule>
    </RuleCollection>
</AppLockerPolicy>
"@
            } -ModuleName BrowserBoundaryProbe

            {
                Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $script:probeRoot
            } | Should -Not -Throw
        }
    }

    Context "Report assertion and validation" {
        It "Throws when required probe is missing from report" {
            $report = [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ name = 'Probe A'; status = 'pass' }
                )
            }

            {
                Assert-RequiredStudentProbeStatuses `
                    -Report $report `
                    -ProbeNames @('Probe A', 'Required Missing Probe')
            } | Should -Throw "*Required student browser-boundary probe is missing: Required Missing Probe*"
        }

        It "Throws when required probe has fail status" {
            $report = [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ name = 'Probe A'; status = 'pass' },
                    [pscustomobject]@{ name = 'Probe B'; status = 'fail' }
                )
            }

            {
                Assert-RequiredStudentProbeStatuses `
                    -Report $report `
                    -ProbeNames @('Probe A', 'Probe B')
            } | Should -Throw "*Required student browser-boundary probe did not pass: Probe B status=fail*"
        }

        It "Returns statuses object when all required probes pass" {
            $report = [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ name = 'Probe A'; status = 'pass' },
                    [pscustomobject]@{ name = 'Probe B'; status = 'pass' }
                )
            }

            $statuses = Assert-RequiredStudentProbeStatuses `
                -Report $report `
                -ProbeNames @('Probe A', 'Probe B')

            $statuses.'Probe A' | Should -Be 'pass'
            $statuses.'Probe B' | Should -Be 'pass'
        }

        It "Invoke-ReportAssertNoFailures throws when report file does not exist" {
            $missingPath = Join-Path $TestDrive "missing-report.json"
            {
                Invoke-ReportAssertNoFailures -ReportPath $missingPath -Scope "Student"
            } | Should -Throw "*browser-boundary report was not produced*"
        }

        It "Invoke-ReportAssertNoFailures throws when report contains any failure" {
            $reportPath = Join-Path $TestDrive "failed-report.json"
            [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ name = 'Probe 1'; status = 'fail' }
                )
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8

            {
                Invoke-ReportAssertNoFailures -ReportPath $reportPath -Scope "Student"
            } | Should -Throw "*Student browser-boundary probes failed: 1: Probe 1*"
        }
    }

    Context "Process token observer" {
        BeforeEach {
            $script:observerRuntime = [pscustomobject]@{
                supported = $true
                edition = 'Core'
                version = '7.6.5'
                bitness = '64-bit'
                processId = 9876
            }
        }

        It 'records process-exited before observation with native stage evidence' {
            Mock Invoke-OpenPathNativeOpenProcess {
                [pscustomobject]@{ success = $false; handle = [IntPtr]::Zero; win32Code = 87 }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessExistence {
                [pscustomobject]@{ processExists = $false; processExistsStatus = 'observed' }
            } -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathProcessTokenBoundaryEvidence `
                -ProcessId 4242 `
                -RuntimeOverride $script:observerRuntime

            $observation.reason | Should -Be 'process-exited-before-observation'
            $observation.processId | Should -Be 4242
            $observation.processExists | Should -BeFalse
            $observation.processExistsStatus | Should -Be 'observed'
            $observation.observerArchitecture | Should -Be '64-bit'
            $observation.observerPid | Should -Be 9876
            $observation.observerEdition | Should -Be 'Core'
            $observation.observerVersion | Should -Be '7.6.5'
            $observation.nativeStages[0].stage | Should -Be 'OpenProcess'
            $observation.nativeStages[0].accessMask | Should -Be '0x00001000'
            $observation.nativeStages[0].win32Code | Should -Be 87
            $observation.nativeStages[0].win32Name | Should -Be 'ERROR_INVALID_PARAMETER'
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'handle|tokenHandle|processHandle|secret|Password'
        }

        It 'records access denied with unknown process existence and exact native stage evidence' {
            Mock Invoke-OpenPathNativeOpenProcess {
                [pscustomobject]@{ success = $false; handle = [IntPtr]::Zero; win32Code = 5 }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessExistence {
                [pscustomobject]@{ processExists = $true; processExistsStatus = 'observed' }
            } -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathProcessTokenBoundaryEvidence `
                -ProcessId 4343 `
                -RuntimeOverride $script:observerRuntime

            $observation.reason | Should -Be 'access-denied'
            $observation.processId | Should -Be 4343
            $observation.processExists | Should -BeTrue
            $observation.processExistsStatus | Should -Be 'observed'
            $observation.observerArchitecture | Should -Be '64-bit'
            $observation.observerPid | Should -Be 9876
            $observation.nativeStages[0].stage | Should -Be 'OpenProcess'
            $observation.nativeStages[0].accessMask | Should -Be '0x00001000'
            $observation.nativeStages[0].win32Code | Should -Be 5
            $observation.nativeStages[0].win32Name | Should -Be 'ERROR_ACCESS_DENIED'
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'handle|tokenHandle|processHandle|secret|Password'
        }

        It 'does not call an ambiguous invalid parameter an exited process when the PID is still present' {
            Mock Invoke-OpenPathNativeOpenProcess {
                [pscustomobject]@{ success = $false; handle = [IntPtr]::Zero; win32Code = 87 }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-OpenPathProcessExistence {
                [pscustomobject]@{ processExists = $true; processExistsStatus = 'observed' }
            } -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathProcessTokenBoundaryEvidence `
                -ProcessId 4646 `
                -RuntimeOverride $script:observerRuntime

            $observation.reason | Should -Be 'unexpected-native-error'
            $observation.processExists | Should -BeTrue
            $observation.processExistsStatus | Should -Be 'observed'
            $observation.errorCode | Should -Be 87
            $observation.nativeStages[0].win32Name | Should -Be 'ERROR_INVALID_PARAMETER'
        }

        It 'records an OpenProcessToken failure after observing the process' {
            Mock Invoke-OpenPathNativeOpenProcess {
                [pscustomobject]@{ success = $true; handle = [IntPtr]::new(42); win32Code = 0 }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativeOpenProcessToken {
                [pscustomobject]@{ success = $false; tokenHandle = [IntPtr]::Zero; win32Code = 87 }
            } -ModuleName BrowserBoundaryProbe
            Mock Close-OpenPathNativeHandle {} -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathProcessTokenBoundaryEvidence `
                -ProcessId 4444 `
                -RuntimeOverride $script:observerRuntime

            $observation.reason | Should -Be 'open-token-failed'
            $observation.processExists | Should -BeTrue
            $observation.failureStage | Should -Be 'OpenProcessToken'
            $observation.nativeStages[1].stage | Should -Be 'OpenProcessToken'
            $observation.nativeStages[1].accessMask | Should -Be '0x00000008'
            $observation.nativeStages[1].win32Code | Should -Be 87
            $observation.nativeStages[1].win32Name | Should -Be 'ERROR_INVALID_PARAMETER'
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'handle|tokenHandle|processHandle|secret|Password'
        }

        It 'records a GetTokenInformation failure after observing process and token stages' {
            Mock Invoke-OpenPathNativeOpenProcess {
                [pscustomobject]@{ success = $true; handle = [IntPtr]::new(52); win32Code = 0 }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativeOpenProcessToken {
                [pscustomobject]@{ success = $true; tokenHandle = [IntPtr]::new(53); win32Code = 0 }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativeGetTokenInformation {
                [pscustomobject]@{ success = $false; returnLength = 0; win32Code = 87 }
            } -ModuleName BrowserBoundaryProbe
            Mock Close-OpenPathNativeHandle {} -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathProcessTokenBoundaryEvidence `
                -ProcessId 4545 `
                -RuntimeOverride $script:observerRuntime

            $observation.reason | Should -Be 'token-information-failed'
            $observation.processExists | Should -BeTrue
            $observation.failureStage | Should -Be 'GetTokenInformation'
            $observation.nativeStages[2].stage | Should -Be 'GetTokenInformation'
            $observation.nativeStages[2].informationClass | Should -Be 'TokenUser'
            $observation.nativeStages[2].win32Code | Should -Be 87
            $observation.nativeStages[2].win32Name | Should -Be 'ERROR_INVALID_PARAMETER'
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'handle|tokenHandle|processHandle|secret|Password'
        }

        It 'uses the IntPtr SID conversion seam and preserves the TokenUser SID' {
            Mock Invoke-OpenPathNativeOpenProcess {
                [pscustomobject]@{ success = $true; handle = [IntPtr]::new(62); win32Code = 0 }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativeOpenProcessToken {
                [pscustomobject]@{ success = $true; tokenHandle = [IntPtr]::new(63); win32Code = 0 }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativeGetTokenInformation {
                param($TokenHandle, $InformationClass, $Buffer, $BufferLength, $ProcessId)
                if ($Buffer -eq [IntPtr]::Zero) {
                    [pscustomobject]@{ success = $false; returnLength = 16; win32Code = 122 }
                }
                else {
                    [Runtime.InteropServices.Marshal]::WriteIntPtr($Buffer, [IntPtr]::new(1))
                    [pscustomobject]@{ success = $true; returnLength = 16; win32Code = 0 }
                }
            } -ModuleName BrowserBoundaryProbe
            Mock ConvertTo-OpenPathSecurityIdentifierValue {
                param([IntPtr]$SidPointer)
                'S-1-5-18'
            } -ModuleName BrowserBoundaryProbe
            Mock Close-OpenPathNativeHandle {} -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathProcessTokenBoundaryEvidence `
                -ProcessId 4747 `
                -RuntimeOverride $script:observerRuntime

            $observation.status | Should -Be 'ok'
            $observation.tokenUserSid | Should -Be 'S-1-5-18'
            @($observation.nativeStages).Count | Should -Be 4
            $observation.nativeStages[2].informationClass | Should -Be 'TokenUser'
            $observation.nativeStages[3].informationClass | Should -Be 'TokenUser'
            $observation.exception | Should -Be $null
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'handle|tokenHandle|processHandle|secret|Password'
        }

        It 'preserves bounded metadata when TokenUser SID conversion throws' {
            Mock Invoke-OpenPathNativeOpenProcess {
                [pscustomobject]@{ success = $true; handle = [IntPtr]::new(72); win32Code = 0 }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativeOpenProcessToken {
                [pscustomobject]@{ success = $true; tokenHandle = [IntPtr]::new(73); win32Code = 0 }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativeGetTokenInformation {
                param($TokenHandle, $InformationClass, $Buffer, $BufferLength, $ProcessId)
                if ($Buffer -eq [IntPtr]::Zero) {
                    [pscustomobject]@{ success = $false; returnLength = 16; win32Code = 122 }
                }
                else {
                    [Runtime.InteropServices.Marshal]::WriteIntPtr($Buffer, [IntPtr]::new(1))
                    [pscustomobject]@{ success = $true; returnLength = 16; win32Code = 0 }
                }
            } -ModuleName BrowserBoundaryProbe
            Mock ConvertTo-OpenPathSecurityIdentifierValue {
                throw [System.InvalidOperationException]::new('token-constructor-password-secret')
            } -ModuleName BrowserBoundaryProbe
            Mock Close-OpenPathNativeHandle {} -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathProcessTokenBoundaryEvidence `
                -ProcessId 4848 `
                -RuntimeOverride $script:observerRuntime

            $observation.status | Should -Be 'unavailable'
            $observation.reason | Should -Be 'unexpected-native-error'
            $observation.failureStage | Should -Be 'unexpected'
            $observation.exception.type | Should -Match 'InvalidOperationException'
            $observation.exception.fullyQualifiedErrorId | Should -Not -BeNullOrEmpty
            $observation.exception.hResult | Should -Not -BeNullOrEmpty
            $observation.exception.safeReason | Should -Be 'token-observation-failed'
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'token-constructor-password-secret|handle|tokenHandle|processHandle|Password'
        }
    }

    Context "Test-AppLockerPolicy observer" {
        BeforeEach {
            $script:policyObserverRuntime = [pscustomobject]@{
                supported = $true
                edition = 'Core'
                version = '7.6.5'
                bitness = '64-bit'
                processId = 9877
            }
        }

        It 'records current policy runtime and a separate native PowerShell comparison' {
            Mock Get-AppLockerPolicy { [pscustomobject]@{ RuleCollections = @() } } -ModuleName BrowserBoundaryProbe
            Mock Test-AppLockerPolicy {
                [pscustomobject]@{ FilePath = 'C:\msedge.exe'; PolicyDecision = 'Denied' }
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativePowerShellPolicyComparison {
                [pscustomobject]@{
                    status = 'observed'
                    path = 'C:\msedge.exe'
                    userSid = 'S-1-5-21-policy-user'
                    runtime = [pscustomobject]@{ edition = 'Desktop'; version = '5.1.26100'; bitness = '64-bit'; processId = 7777 }
                    decision = 'Allowed'
                }
            } -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathTestAppLockerPolicyDecision `
                -ExecutablePath 'C:\msedge.exe' `
                -StudentSid 'S-1-5-21-policy-user' `
                -RuntimeOverride $script:policyObserverRuntime `
                -IncludeNativePowerShellComparison

            $observation.status | Should -Be 'observed'
            $observation.decision | Should -Be 'Denied'
            $observation.path | Should -Be 'C:\msedge.exe'
            $observation.userSid | Should -Be 'S-1-5-21-policy-user'
            $observation.runtime.edition | Should -Be 'Core'
            $observation.runtime.version | Should -Be '7.6.5'
            $observation.runtime.bitness | Should -Be '64-bit'
            $observation.runtime.processId | Should -Be 9877
            $observation.testAppLockerPolicy.available | Should -BeTrue
            $observation.testAppLockerPolicy.source | Should -Not -BeNullOrEmpty
            $observation.import.attempted | Should -BeFalse
            $observation.nativePowerShellComparison.status | Should -Be 'observed'
            $observation.nativePowerShellComparison.decision | Should -Be 'Allowed'
            $observation.nativePowerShellComparison.runtime.edition | Should -Be 'Desktop'

            $safeComparison = InModuleScope BrowserBoundaryProbe -Parameters @{ Comparison = $observation.nativePowerShellComparison } {
                Get-OpenPathSafePolicyComparisonEvidence -Comparison $Comparison
            }
            $safeComparison.decision | Should -Be 'Allowed'
        }

        It 'preserves an unknown or null native policy decision distinctly' {
            $unknown = InModuleScope BrowserBoundaryProbe {
                Get-OpenPathSafePolicyComparisonEvidence -Comparison ([pscustomobject][ordered]@{
                        status = 'observed'
                        path = 'C:\msedge.exe'
                        userSid = 'S-1-5-21-policy-user'
                        decision = 'unknown'
                    })
            }
            $nullDecision = InModuleScope BrowserBoundaryProbe {
                Get-OpenPathSafePolicyComparisonEvidence -Comparison ([pscustomobject][ordered]@{
                        status = 'unavailable'
                        path = 'C:\msedge.exe'
                        userSid = 'S-1-5-21-policy-user'
                        decision = $null
                    })
            }

            $unknown.PSObject.Properties['decision'] | Should -Not -BeNullOrEmpty
            $unknown.decision | Should -Be 'unknown'
            $nullDecision.PSObject.Properties['decision'] | Should -Not -BeNullOrEmpty
            $nullDecision.decision | Should -Be $null
        }

        It 'preserves policy import and exception metadata without raw exception text' {
            Mock Get-Command {
                param([string]$Name)
                if ($Name -eq 'Test-AppLockerPolicy') { return $null }
                if ($Name -eq 'Get-AppLockerPolicy') {
                    return [pscustomobject]@{ Name = $Name; Source = 'AppLocker'; CommandType = 'Cmdlet' }
                }
                Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathAppLockerModuleImport {
                throw [System.InvalidOperationException]::new('policy-secret-not-serializable')
            } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativePowerShellPolicyComparison {
                [pscustomobject]@{ status = 'unavailable'; path = 'C:\msedge.exe'; userSid = 'S-1-5-21-policy-user'; reason = 'test-fixture' }
            } -ModuleName BrowserBoundaryProbe

            $observation = Get-OpenPathTestAppLockerPolicyDecision `
                -ExecutablePath 'C:\msedge.exe' `
                -StudentSid 'S-1-5-21-policy-user' `
                -RuntimeOverride $script:policyObserverRuntime

            $observation.status | Should -Be 'unavailable'
            $observation.testAppLockerPolicy.available | Should -BeFalse
            $observation.import.attempted | Should -BeTrue
            $observation.import.result | Should -Be 'failed'
            $observation.exception.type | Should -Match 'InvalidOperationException'
            $observation.exception.fullyQualifiedErrorId | Should -Not -BeNullOrEmpty
            $observation.exception.hResult | Should -Not -BeNullOrEmpty
            $observation.exception.safeReason | Should -Be 'module-import-failed'
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'policy-secret-not-serializable|Password'
        }
    }

    Context "AppLocker event observer" {
        BeforeEach {
            $script:eventObserverRuntime = [pscustomobject]@{
                supported = $true
                edition = 'Core'
                version = '7.6.5'
                bitness = '64-bit'
                processId = 9880
            }
            $script:eventStartTime = [datetime]'2026-09-11T10:11:12Z'
        }

        It 'distinguishes a valid empty query from a failed query without raw exception text' {
            Mock Get-OpenPathAppLockerEventChannel {
                param([string]$LogName)
                [pscustomobject]@{ channel = $LogName; channelExists = $true; status = 'observed' }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { @() } -ModuleName BrowserBoundaryProbe

            $empty = Get-OpenPathAppLockerEventQuery `
                -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' `
                -EventId 8004 `
                -StartTime $script:eventStartTime `
                -RuntimeOverride $script:eventObserverRuntime `
                -IncludeNativePowerShellComparison:$false

            $empty.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            $empty.channel | Should -Be 'Microsoft-Windows-AppLocker/EXE and DLL'
            $empty.logName | Should -Be 'Microsoft-Windows-AppLocker/EXE and DLL'
            $empty.channelExists | Should -BeTrue
            $empty.queryAttempted | Should -BeTrue
            $empty.querySucceeded | Should -BeTrue
            $empty.eventCount | Should -Be 0
            @($empty.events).Count | Should -Be 0
            $empty.runtime.edition | Should -Be 'Core'
            $empty.runtime.version | Should -Be '7.6.5'
            $empty.runtime.bitness | Should -Be '64-bit'
            $empty.runtime.processId | Should -Be 9880

            Mock Get-WinEvent { throw [System.InvalidOperationException]::new('event-secret-not-serializable') } -ModuleName BrowserBoundaryProbe
            $failed = Get-OpenPathAppLockerEventQuery `
                -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' `
                -EventId 8004 `
                -StartTime $script:eventStartTime `
                -RuntimeOverride $script:eventObserverRuntime `
                -IncludeNativePowerShellComparison:$false

            $failed.status | Should -Be 'QUERY_FAILED'
            $failed.channelExists | Should -BeTrue
            $failed.queryAttempted | Should -BeTrue
            $failed.querySucceeded | Should -BeFalse
            $failed.eventCount | Should -Be 0
            $failed.exception.type | Should -Match 'InvalidOperationException'
            $failed.exception.fullyQualifiedErrorId | Should -Not -BeNullOrEmpty
            $failed.exception.hResult | Should -Not -BeNullOrEmpty
            $failed.exception.safeReason | Should -Be 'event-query-failed'
            ($failed | ConvertTo-Json -Depth 12) | Should -Not -Match 'event-secret-not-serializable|Password'
        }

        It 'treats NoMatchingEventsFound from a filtered query as a successful empty result' {
            Mock Get-OpenPathAppLockerEventChannel {
                param([string]$LogName)
                [pscustomobject]@{ channel = $LogName; channelExists = $true; status = 'observed' }
            } -ModuleName BrowserBoundaryProbe
            $noMatchError = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('no matching events'),
                'NoMatchingEventsFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $null
            )
            Mock Get-WinEvent { throw $noMatchError } -ModuleName BrowserBoundaryProbe

            $query = Get-OpenPathAppLockerEventQuery `
                -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' `
                -EventId 8004 `
                -StartTime $script:eventStartTime `
                -RuntimeOverride $script:eventObserverRuntime `
                -IncludeNativePowerShellComparison:$false

            $query.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            $query.queryAttempted | Should -BeTrue
            $query.querySucceeded | Should -BeTrue
            $query.eventCount | Should -Be 0
            $query.exception | Should -Be $null
            $query.reason | Should -Be $null
        }

        It 'uses the bounded no-match classifier for the native PowerShell script path' {
            $classification = InModuleScope BrowserBoundaryProbe {
                $noMatch = [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new('no matching events'),
                    'NoMatchingEventsFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $null
                )
                $failure = [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new('event provider failed'),
                    'EventProviderFailed',
                    [System.Management.Automation.ErrorCategory]::ReadError,
                    $null
                )
                [pscustomobject]@{
                    noMatch = Test-OpenPathNoMatchingEventsError -ErrorRecord $noMatch
                    failure = Test-OpenPathNoMatchingEventsError -ErrorRecord $failure
                }
            }

            $classification.noMatch | Should -BeTrue
            $classification.failure | Should -BeFalse
            $moduleContent = Get-Content (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1') -Raw
            $moduleContent | Should -Match '(?s)queryAttempted.*NoMatchingEventsFound'
        }

        It 'reports unsupported observer runtime without attempting channel discovery' {
            $unsupportedRuntime = [pscustomobject]@{
                supported = $false
                edition = 'Core'
                version = '7.6.5'
                bitness = '64-bit'
                processId = 9881
            }

            $query = Get-OpenPathAppLockerEventQuery `
                -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' `
                -EventId 8004 `
                -StartTime $script:eventStartTime `
                -RuntimeOverride $unsupportedRuntime `
                -IncludeNativePowerShellComparison:$false

            $query.status | Should -Be 'OBSERVER_RUNTIME_UNSUPPORTED'
            $query.channelExists | Should -Be $null
            $query.queryAttempted | Should -BeFalse
            $query.querySucceeded | Should -BeFalse
            $query.eventCount | Should -Be 0
        }

        It 'keeps native Windows PowerShell event comparison separate and exact' {
            Mock Get-OpenPathAppLockerEventChannel {
                param([string]$LogName)
                [pscustomobject]@{ channel = $LogName; channelExists = $true; status = 'observed' }
            } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent { throw [System.InvalidOperationException]::new('query-failed-secret') } -ModuleName BrowserBoundaryProbe
            Mock Invoke-OpenPathNativePowerShellEventQuery {
                param([string]$LogName, [int]$EventId, [datetime]$StartTime)
                [pscustomobject]@{
                    status = 'QUERY_SUCCEEDED_MATCHES'
                    channel = $LogName
                    logName = $LogName
                    eventId = $EventId
                    startTime = $StartTime
                    runtime = [pscustomobject]@{ edition = 'Desktop'; version = '5.1.26100'; bitness = '64-bit'; processId = 7780 }
                    eventCount = 1
                    events = @([pscustomobject]@{ Message = 'must-not-leak-password-secret' })
                }
            } -ModuleName BrowserBoundaryProbe

            $query = Get-OpenPathAppLockerEventQuery `
                -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' `
                -EventId 8004 `
                -StartTime $script:eventStartTime `
                -RuntimeOverride $script:eventObserverRuntime `
                -IncludeNativePowerShellComparison

            $query.status | Should -Be 'QUERY_FAILED'
            $query.nativePowerShellComparison.status | Should -Be 'QUERY_SUCCEEDED_MATCHES'
            $query.nativePowerShellComparison.channel | Should -Be 'Microsoft-Windows-AppLocker/EXE and DLL'
            $query.nativePowerShellComparison.eventId | Should -Be 8004
            $query.nativePowerShellComparison.runtime.edition | Should -Be 'Desktop'
            $query.nativePowerShellComparison.runtime.version | Should -Be '5.1.26100'
            $query.nativePowerShellComparison.PSObject.Properties['events'] | Should -Be $null
            Should -Invoke Invoke-OpenPathNativePowerShellEventQuery -ModuleName BrowserBoundaryProbe -Times 1 -ParameterFilter {
                $LogName -eq 'Microsoft-Windows-AppLocker/EXE and DLL' -and $EventId -eq 8004 -and $StartTime -eq $script:eventStartTime
            }
            ($query | ConvertTo-Json -Depth 12) | Should -Not -Match 'query-failed-secret|Password'
        }
    }

    Context "Observer evidence transport" {
        It 'preserves bounded token stages through the browser report JSON roundtrip' {
            $tokenObserver = InModuleScope BrowserBoundaryProbe {
                $stage = [pscustomobject][ordered]@{
                    stage = 'OpenProcess'
                    attempted = $true
                    succeeded = $true
                    processId = 5437
                    accessMask = '0x00001000'
                    informationClass = $null
                    win32Code = 0
                    win32Name = 'ERROR_SUCCESS'
                }
                $secondStage = $stage | Select-Object * | ForEach-Object {
                    $_.stage = 'OpenProcessToken'
                    $_.processId = 5437
                    $_.accessMask = '0x00000008'
                    $_
                }
                Get-OpenPathSafeTokenObserverEvidence -Observer ([pscustomobject][ordered]@{
                        status = 'ok'
                        nativeStages = @($stage, $secondStage)
                    })
            }
            $report = [pscustomobject][ordered]@{
                results = @([pscustomobject][ordered]@{
                        name = 'Approved Firefox executable is allowed to run as student'
                        evidence = [pscustomobject][ordered]@{
                            observedExactProcess = @([pscustomobject][ordered]@{ tokenObserver = $tokenObserver })
                        }
                    })
            }

            $reportPath = Join-Path $TestDrive 'browser-boundary-report.json'
            Write-OpenPathBrowserBoundaryReport -Report $report -Path $reportPath
            Test-Path -LiteralPath $reportPath | Should -BeTrue
            $roundTrip = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $nativeStages = $roundTrip.results[0].evidence.observedExactProcess[0].tokenObserver.nativeStages

            ($nativeStages -is [array]) | Should -BeTrue
            @($nativeStages).Count | Should -Be 2
            $nativeStages[0].stage | Should -Be 'OpenProcess'

            $runner = Get-Content (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-browser-boundary-ci.ps1') -Raw
            $runner | Should -Match 'Write-OpenPathBrowserBoundaryReport[\s\S]*\$reportPath'
        }

        It 'retains token, policy, and event observer evidence in the real nested and flat contracts' {
            $transport = InModuleScope BrowserBoundaryProbe {
                $tokenObserver = [pscustomobject][ordered]@{
                    status = 'unavailable'
                    reason = 'open-token-failed'
                    processId = 5436
                    processExists = $true
                    processExistsStatus = 'observed'
                    errorCode = 87
                    errorName = 'ERROR_INVALID_PARAMETER'
                    failureStage = 'OpenProcessToken'
                    observerArchitecture = '64-bit'
                    observerPid = 9882
                    exception = [pscustomobject][ordered]@{
                        type = 'System.InvalidOperationException'
                        fullyQualifiedErrorId = 'TokenObserverFailure'
                        hResult = -2146233079
                        safeReason = 'token-observation-failed'
                        Message = 'must-not-leak-token-exception-password-secret'
                    }
                    secret = 'must-not-leak-token-password-secret'
                    nativeStages = @([pscustomobject]@{ stage = 'OpenProcessToken'; processId = 5436; accessMask = '0x00000008'; win32Code = 87; win32Name = 'ERROR_INVALID_PARAMETER' })
                }
                $policyObserver = [pscustomobject][ordered]@{
                    status = 'observed'
                    decision = 'Denied'
                    path = 'C:\msedge.exe'
                    userSid = 'S-1-5-21-policy-user'
                    runtime = [pscustomobject]@{ edition = 'Core'; version = '7.6.5'; bitness = '64-bit'; processId = 9883 }
                    testAppLockerPolicy = [pscustomobject]@{ available = $true; source = 'AppLocker' }
                    import = [pscustomobject]@{ attempted = $false; result = 'not-required' }
                    nativePowerShellComparison = [pscustomobject]@{
                        status = 'observed'
                        decision = 'Allowed'
                        path = 'C:\msedge.exe'
                        userSid = 'S-1-5-21-policy-user'
                        runtime = [pscustomobject]@{ edition = 'Desktop'; version = '5.1.26100'; bitness = '64-bit'; processId = 7780 }
                    }
                    secret = 'must-not-leak-policy-password-secret'
                }
                $eventQuery = [pscustomobject][ordered]@{
                    status = 'QUERY_SUCCEEDED_NO_MATCHES'
                    channel = 'Microsoft-Windows-AppLocker/EXE and DLL'
                    logName = 'Microsoft-Windows-AppLocker/EXE and DLL'
                    eventId = 8004
                    channelExists = $true
                    queryAttempted = $true
                    querySucceeded = $true
                    eventCount = 0
                    events = @([pscustomobject]@{ Id = 8004; Message = 'must-not-leak-event-password-secret' })
                    exception = $null
                    reason = $null
                    runtime = [pscustomobject]@{ edition = 'Core'; version = '7.6.5'; bitness = '64-bit'; processId = 9880 }
                    secret = 'must-not-leak-query-password-secret'
                }
                $eventQueries = [ordered]@{}
                foreach ($eventId in @(8002, 8004, 8020, 8022)) {
                    $query = $eventQuery | Select-Object *
                    $query.eventId = $eventId
                    $query.status = if ($eventId -eq 8004) { 'QUERY_SUCCEEDED_NO_MATCHES' } else { 'QUERY_FAILED' }
                    $query.eventCount = 0
                    $query.events = @()
                    $query.exception = if ($eventId -in @(8002, 8020)) {
                        [pscustomobject]@{ type = 'System.InvalidOperationException'; fullyQualifiedErrorId = 'event-query-failed'; hResult = -1; safeReason = 'event-query-failed' }
                    }
                    else { $null }
                    $eventQueries[[string]$eventId] = $query
                }
                $process = [pscustomobject][ordered]@{
                    processId = 5436
                    name = 'msedge.exe'
                    executablePath = 'C:\msedge.exe'
                    studentSid = 'S-1-5-21-policy-user'
                    tokenObserver = $tokenObserver
                    restrictedGroupSid = 'S-1-5-21-restricted'
                    restrictedGroupPresent = $null
                    restrictedGroupQueryStatus = 'unavailable'
                }
                $evidence = Set-OpenPathBoundaryProbeFailureEvidence `
                    -ProbeName 'Canonical Edge deny' `
                    -ExecutablePath 'C:\msedge.exe' `
                    -StudentSid 'S-1-5-21-policy-user' `
                    -FailureCode 'appLocker-block-event-not-observed' `
                    -Processes @($process) `
                    -Events @() `
                    -ExpectedEventIds @(8004) `
                    -TestAppLockerPolicyDecision $policyObserver `
                    -AppLockerQueryStatuses @{ '8002' = 'QUERY_FAILED'; '8004' = 'QUERY_SUCCEEDED_NO_MATCHES'; '8020' = 'QUERY_FAILED'; '8022' = 'QUERY_SUCCEEDED_NO_MATCHES' } `
                    -AppLockerEventQueries $eventQueries
                $serialized = $evidence | ConvertTo-Json -Depth 20
                $serialized | Should -Not -Match 'must-not-leak-(token|policy|event|query)-password-secret'
                $evidence.appLockerEventQueries['8004'].PSObject.Properties['events'] | Should -Be $null
                $evidence.processes[0].tokenObserver.PSObject.Properties['secret'] | Should -Be $null
                $evidence.policyObserver.PSObject.Properties['secret'] | Should -Be $null
                $evidence.processes[0].tokenObserver.exception.safeReason | Should -Be 'token-observation-failed'
                $evidence.processes[0].tokenObserver.exception.PSObject.Properties['Message'] | Should -Be $null
                $flat = Get-OpenPathFlatEdgeBoundaryFailureContract -Evidence $evidence
                ($flat | ConvertTo-Json -Depth 20) | Should -Not -Match 'must-not-leak-(token|policy|event|query)-password-secret'
                [pscustomobject]@{ evidence = $evidence; flat = $flat }
            }

            $transport.evidence.processes[0].tokenObserver.failureStage | Should -Be 'OpenProcessToken'
            $transport.evidence.processes[0].tokenObserver.exception.safeReason | Should -Be 'token-observation-failed'
            $transport.evidence.testAppLockerPolicyDecision.runtime.edition | Should -Be 'Core'
            $transport.evidence.testAppLockerPolicyDecision.nativePowerShellComparison.decision | Should -Be 'Allowed'
            $transport.evidence.appLockerEventQueries.'8004'.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            @($transport.evidence.appLockerEventQueries.Keys | Sort-Object) | Should -Be @('8002', '8004', '8020', '8022')
            $transport.flat.edge.tokenObserver.failureStage | Should -Be 'OpenProcessToken'
            $transport.flat.edge.tokenObserver.exception.fullyQualifiedErrorId | Should -Be 'TokenObserverFailure'
            $transport.flat.edge.policyObserver.runtime.processId | Should -Be 9883
            $transport.flat.edge.policyObserver.nativePowerShellComparison.decision | Should -Be 'Allowed'
            $transport.flat.edge.eventQueries.'8004'.eventCount | Should -Be 0
            @($transport.flat.edge.eventQueries.Keys | Sort-Object) | Should -Be @('8002', '8004', '8020', '8022')
            ($transport | ConvertTo-Json -Depth 12) | Should -Not -Match 'secret|Password'
        }
    }

    Context "Direct Windows observer evidence" {
        It '[Windows direct] observes the current process token with native stage evidence' -Skip:($script:OpenPathWindowsDirect -ne $true) {
            $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $observation = Get-OpenPathProcessTokenBoundaryEvidence -ProcessId $PID

            $observation.processId | Should -Be $PID
            $observation.status | Should -Be 'ok'
            $observation.tokenUserSid | Should -Be $currentSid
            $observation.processExists | Should -BeTrue
            $observation.processExistsStatus | Should -Be 'observed'
            @($observation.nativeStages).Count | Should -BeGreaterThan 0
            @($observation.nativeStages | Where-Object { $_.stage -eq 'OpenProcess' -and $_.accessMask -eq '0x00001000' }).Count | Should -BeGreaterThan 0
            @($observation.nativeStages | Where-Object { $_.stage -eq 'OpenProcessToken' -and $_.accessMask -eq '0x00000008' }).Count | Should -BeGreaterThan 0
            @($observation.nativeStages | Where-Object { $_.stage -eq 'GetTokenInformation' -and $_.informationClass -eq 'TokenUser' -and $_.succeeded }).Count | Should -BeGreaterThan 0
            $observation.observerArchitecture | Should -Not -BeNullOrEmpty
            $observation.observerEdition | Should -Not -BeNullOrEmpty
            $observation.observerVersion | Should -Not -BeNullOrEmpty
            $observation.observerPid | Should -Be $PID
            ($observation | ConvertTo-Json -Depth 12) | Should -Not -Match 'handle|tokenHandle|processHandle|secret|Password'
        }

        It '[Windows direct] records policy evidence for a real System32 PE and a separate native comparison' -Skip:($script:OpenPathWindowsDirect -ne $true) {
            $systemPe = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\cmd.exe'
            $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Test-Path -LiteralPath $systemPe | Should -BeTrue
            $decision = Get-OpenPathTestAppLockerPolicyDecision -ExecutablePath $systemPe -StudentSid $currentSid

            $decision.path | Should -Be $systemPe
            $decision.exactPath | Should -Be $systemPe
            $decision.userSid | Should -Be $currentSid
            $decision.exactSid | Should -Be $currentSid
            $decision.runtime.edition | Should -Not -BeNullOrEmpty
            $decision.runtime.version | Should -Not -BeNullOrEmpty
            $decision.runtime.bitness | Should -Not -BeNullOrEmpty
            $decision.runtime.processId | Should -Be $PID
            $decision.status | Should -BeIn @('observed', 'unknown', 'unavailable')
            if ($decision.status -ne 'observed') {
                $decision.reason | Should -BeIn @('policy-command-unavailable', 'policy-evaluation-unavailable', 'windows-only')
            }
            $decision.nativePowerShellComparison | Should -Not -BeNull
            $decision.nativePowerShellComparison.status | Should -Not -BeNullOrEmpty
            if ($decision.nativePowerShellComparison.status -eq 'unavailable') {
                $decision.nativePowerShellComparison.reason | Should -BeIn @('policy-command-unavailable', 'native-powershell-missing', 'native-powershell-failed', 'windows-only')
            }
            ($decision | ConvertTo-Json -Depth 12) | Should -Not -Match 'secret|Password|Exception\.Message'
        }

        It '[Windows direct] queries recent AppLocker 8004 evidence with current and native runtime metadata' -Skip:($script:OpenPathWindowsDirect -ne $true) {
            $logName = 'Microsoft-Windows-AppLocker/EXE and DLL'
            $startTime = (Get-Date).AddMinutes(-1)
            $query = Get-OpenPathAppLockerEventQuery -LogName $logName -EventId 8004 -StartTime $startTime -IncludeNativePowerShellComparison

            $query.status | Should -BeIn @('QUERY_SUCCEEDED_NO_MATCHES', 'QUERY_FAILED', 'CHANNEL_UNAVAILABLE', 'OBSERVER_RUNTIME_UNSUPPORTED')
            $query.channel | Should -Be $logName
            $query.logName | Should -Be $logName
            $query.eventId | Should -Be 8004
            $query.startTime | Should -Not -BeNullOrEmpty
            $query.runtime.edition | Should -Not -BeNullOrEmpty
            $query.runtime.version | Should -Not -BeNullOrEmpty
            $query.runtime.bitness | Should -Not -BeNullOrEmpty
            $query.runtime.processId | Should -Be $PID
            $query.nativePowerShellComparison | Should -Not -BeNull
            $query.nativePowerShellComparison.status | Should -Not -BeNullOrEmpty
            if ($query.nativePowerShellComparison.runtime) {
                $query.nativePowerShellComparison.runtime.edition | Should -Not -BeNullOrEmpty
                $query.nativePowerShellComparison.runtime.version | Should -Not -BeNullOrEmpty
                $query.nativePowerShellComparison.runtime.bitness | Should -Not -BeNullOrEmpty
                $query.nativePowerShellComparison.runtime.processId | Should -BeGreaterThan 0
            }
            else {
                $query.nativePowerShellComparison.reason | Should -Not -BeNullOrEmpty
            }
            ($query | ConvertTo-Json -Depth 12) | Should -Not -Match 'secret|Password|Exception\.Message'
        }
    }
}
