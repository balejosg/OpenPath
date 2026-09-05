# OpenPath Windows browser boundary probe and report validation unit tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\tests\e2e\ci\BrowserBoundaryProbe.psm1") -Force

Describe "Windows Browser Boundary CI Probes" {
    BeforeAll {
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
        if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            function global:Get-ScheduledTask { param($TaskName) }
        }
    }

    Context "Invoke-StudentExecutableTaskProbe" {
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
