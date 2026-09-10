# OpenPath Windows browser boundary probe and report validation unit tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1") -Force

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
                { Invoke-StudentExecutableTaskProbe -ProbeName 'No event probe' -UserName 'student01' -Password 'secret' -ExecutablePath $testExe -Expectation ExpectDenied -StudentSid 'S-1-5-21-student-sid' -TimeoutSeconds 1 } |
                    Should -Throw '*AppLocker 8004 block event was not observed*'
                Should -Invoke Write-Host -ModuleName BrowserBoundaryProbe -ParameterFilter {
                    $Object -match '^OPENPATH_BOUNDARY_PROBE_FAILURE state=Ready lastTaskResult=0xC0000022 lastRunObserved=true$'
                } -Times 1
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
            Mock Invoke-CimMethod { [pscustomobject]@{ Sid = 'S-1-5-21-sam-owner' } } -ModuleName BrowserBoundaryProbe
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
}
