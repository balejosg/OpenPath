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

        It "Passes when ExpectAllowed and 8002 allow event is observed" {
            $testExe = Join-Path $TestDrive "probe-allowed-8002.exe"
            Set-Content -LiteralPath $testExe -Value "dummy"
            $markerPath = Join-Path $TestDrive "marker-allowed-absent.txt"

            Mock schtasks.exe { $global:LASTEXITCODE = 0 } -ModuleName BrowserBoundaryProbe
            Mock Get-WinEvent {
                return @(
                    [pscustomobject]@{
                        Id = 8002
                        Message = "probe-allowed-8002.exe was allowed to run"
                    }
                )
            } -ModuleName BrowserBoundaryProbe

            $result = Invoke-StudentExecutableTaskProbe `
                -ProbeName "Allowed 8002 probe" `
                -UserName "student01" `
                -Password "secret" `
                -ExecutablePath $testExe `
                -Expectation ExpectAllowed `
                -MarkerPath $markerPath `
                -TimeoutSeconds 1

            $result.status | Should -Be 'pass'
            $result.evidence.allowedObserved | Should -BeTrue
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
