# OpenPath Windows Browser Boundary CI Probes & Verification Module

function Invoke-ReportAssertNoFailures {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "$Scope browser-boundary report was not produced: $ReportPath"
    }

    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    $failures = @($report.results | Where-Object { $_.status -eq 'fail' })
    if ($failures.Count -gt 0) {
        $names = ($failures | ForEach-Object { $_.name }) -join ', '
        throw "$Scope browser-boundary probes failed: $($failures.Count): $names"
    }

    return $report
}

function Assert-RequiredStudentProbeStatuses {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][string[]]$ProbeNames
    )

    $statuses = [ordered]@{}
    foreach ($probeName in $ProbeNames) {
        $probe = @($Report.results | Where-Object { $_.name -eq $probeName }) | Select-Object -First 1
        if (-not $probe) {
            throw "Required student browser-boundary probe is missing: $probeName"
        }
        $statuses[$probeName] = [string]$probe.status
        if ($probe.status -ne 'pass') {
            throw "Required student browser-boundary probe did not pass: $probeName status=$($probe.status)"
        }
    }

    return [pscustomobject]$statuses
}

function New-OpenPathProbePayloadBinary {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $cscPaths = @(
        "${env:WINDIR}\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "${env:WINDIR}\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $csc = $cscPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) {
        throw "C# compiler csc.exe was not found to build probe payload binary."
    }

    $srcPath = Join-Path ([System.IO.Path]::GetTempPath()) "probe-source-$([guid]::NewGuid().ToString('N')).cs"
    $code = @'
using System;
using System.IO;
using System.Threading;

class Program {
    static void Main(string[] args) {
        if (args.Length > 0 && !string.IsNullOrEmpty(args[0])) {
            try {
                File.WriteAllText(args[0], "executed");
            } catch {}
        }
        Thread.Sleep(30000);
    }
}
'@
    try {
        Set-Content -LiteralPath $srcPath -Value $code -Encoding UTF8
        & $csc /nologo /target:exe /out:$OutputPath $srcPath *> $null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
            throw "csc.exe compilation of probe payload failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Remove-Item -LiteralPath $srcPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenPathSchtasksCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # schtasks can emit a warning on stderr while returning success. Preserve
        # its native exit code instead of promoting that warning to a PowerShell
        # terminating error when the caller uses ErrorActionPreference=Stop.
        $ErrorActionPreference = 'Continue'
        & $Command *> $null
        return [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-OpenPathProbeProcessesForStudent {
    param([string]$ProcessName, [string]$StudentSid, [string]$ExpectedExecutablePath = '')
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return @() }
    if ([string]::IsNullOrWhiteSpace($StudentSid)) {
        return @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ ProcessId = $_.Id }
        })
    }
    $studentProcesses = @()
    try {
        $expectedLeaf = if ($ExpectedExecutablePath) { [System.IO.Path]::GetFileName($ExpectedExecutablePath) } else { "$ProcessName.exe" }
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name LIKE '$ProcessName%'" -ErrorAction SilentlyContinue)) {
            if ([string]$process.Name -ine $expectedLeaf) { continue }
            if ($ExpectedExecutablePath -and ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
                -not [string]::Equals([System.IO.Path]::GetFullPath([string]$process.ExecutablePath), [System.IO.Path]::GetFullPath($ExpectedExecutablePath), [System.StringComparison]::OrdinalIgnoreCase))) { continue }
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction SilentlyContinue
            if ($owner -and [string]$owner.Sid -eq $StudentSid) { $studentProcesses += $process }
        }
    }
    catch {}
    return @($studentProcesses)
}

function Invoke-StudentExecutableTaskProbe {
    param(
        [Parameter(Mandatory = $true)][string]$ProbeName,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [string]$Arguments = '',
        [ValidateSet('ExpectDenied', 'ExpectAllowed')][string]$Expectation = 'ExpectDenied',
        [string]$ProcessName = '',
        [string]$StudentSid = $null,
        [string]$MarkerPath = '',
        [string]$PackagedAppPattern = '',
        [int]$TimeoutSeconds = 20
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        throw "$ProbeName FAILED: Executable $ExecutablePath does not exist on host."
    }

    $probeTask = "OpenPathProbe-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $useScheduledTaskCmdlets = ($env:OPENPATH_TEST_FORCE_SCHEDULED_TASK_CMDLETS -eq '1') -or
        ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $env:OPENPATH_TEST_FORCE_SCHTASKS -ne '1')
    $quotedExecutablePath = '\"' + $ExecutablePath + '\"'
    $taskCommand = if ($Arguments) { "$quotedExecutablePath $Arguments" } else { $quotedExecutablePath }
    $taskTime = (Get-Date).AddMinutes(1).ToString('HH:mm')

    if ($useScheduledTaskCmdlets) {
        $taskAction = if ($Arguments) {
            New-ScheduledTaskAction -Execute $ExecutablePath -Argument $Arguments
        }
        else {
            New-ScheduledTaskAction -Execute $ExecutablePath
        }
        $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
        Register-ScheduledTask -TaskName $probeTask -Action $taskAction -Trigger $taskTrigger -User "$env:COMPUTERNAME\$UserName" -Password $Password -RunLevel Limited -Force | Out-Null
        $createExitCode = 0
    }
    else {
        $createExitCode = Invoke-OpenPathSchtasksCommand -Command {
            & schtasks.exe /Create /TN $probeTask /SC ONCE /ST $taskTime /TR $taskCommand /RU "$env:COMPUTERNAME\$UserName" /RP $Password /RL LIMITED /F
        }
    }
    if ($createExitCode -ne 0) {
        throw "$ProbeName FAILED: Task creation for $ExecutablePath failed under student credentials ($createExitCode); cannot verify AppLocker boundary."
    }

    $since = Get-Date
    try {
        if ($useScheduledTaskCmdlets) {
            Start-ScheduledTask -TaskName $probeTask
            $runExitCode = 0
        }
        else {
            $runExitCode = Invoke-OpenPathSchtasksCommand -Command { & schtasks.exe /Run /TN $probeTask }
        }
        if ($runExitCode -ne 0) {
            throw "$ProbeName FAILED: Task execution for $ExecutablePath failed ($runExitCode)."
        }

        $pollDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $binaryLeaf = [System.IO.Path]::GetFileName($ExecutablePath)

        if ($Expectation -eq 'ExpectDenied') {
            $eventFound = $false
            $blockEventId = 0
            $observedExactProcesses = @()
            while ((Get-Date) -lt $pollDeadline) {
                if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                    throw "$ProbeName FAILED: executable ran and created marker file $MarkerPath under student account!"
                }

                $studentProcesses = @(Get-OpenPathProbeProcessesForStudent -ProcessName $ProcessName -StudentSid $StudentSid -ExpectedExecutablePath $ExecutablePath)
                if ($studentProcesses.Count -gt 0) {
                    $observedExactProcesses += @($studentProcesses)
                }

                try {
                    $blockEvents = @(Get-WinEvent -FilterHashtable @{
                            LogName   = 'Microsoft-Windows-AppLocker/EXE and DLL'
                            Id        = 8004
                            StartTime = $since
                        } -ErrorAction SilentlyContinue | Where-Object {
                            $matchesBinary = ($_.Message -match [regex]::Escape($binaryLeaf))
                            $matchesUser = if ($StudentSid) {
                                ($_.UserId -and $_.UserId.Value -eq $StudentSid) -or ($_.Message -match [regex]::Escape($StudentSid))
                            } elseif ($UserName) {
                                ($_.Message -match [regex]::Escape($UserName)) -or ($_.UserId -and $_.UserId.Value -eq $UserName)
                            } else {
                                $true
                            }
                            $matchesBinary -and $matchesUser
                        })
                    if ($blockEvents.Count -gt 0) {
                        $eventFound = $true
                        $blockEventId = 8004
                        break
                    }
                }
                catch {}

                if (-not $eventFound -and -not [string]::IsNullOrWhiteSpace($PackagedAppPattern)) {
                    try {
                        $packagedBlockEvents = @(Get-WinEvent -FilterHashtable @{
                                LogName   = 'Microsoft-Windows-AppLocker/Packaged app-Execution'
                                Id        = 8022
                                StartTime = $since
                            } -ErrorAction SilentlyContinue | Where-Object {
                                $matchesPackage = $_.Message -match $PackagedAppPattern
                                $matchesUser = if ($StudentSid) {
                                    ($_.UserId -and $_.UserId.Value -eq $StudentSid) -or ($_.Message -match [regex]::Escape($StudentSid))
                                } else { $true }
                                $matchesPackage -and $matchesUser
                            })
                        if ($packagedBlockEvents.Count -gt 0) {
                            $eventFound = $true
                            $blockEventId = 8022
                            break
                        }
                    }
                    catch {}
                }

                Start-Sleep -Seconds 1
            }

            if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                throw "$ProbeName FAILED: executable ran and created marker file $MarkerPath under student account!"
            }

            $studentProcesses = @(Get-OpenPathProbeProcessesForStudent -ProcessName $ProcessName -StudentSid $StudentSid -ExpectedExecutablePath $ExecutablePath)
            if ($studentProcesses.Count -gt 0) {
                $observedExactProcesses += @($studentProcesses)
            }
            if ($observedExactProcesses.Count -gt 0) {
                foreach ($studentProcess in @($observedExactProcesses | Sort-Object ProcessId -Unique)) { Stop-Process -Id $studentProcess.ProcessId -Force -ErrorAction SilentlyContinue }
                if (-not $eventFound) {
                    Write-Host 'OPENPATH_BOUNDARY_PROBE_FAILURE reason=exact-student-process-observed-without-block-event'
                    throw "$ProbeName FAILED: exact executable $binaryLeaf ran under the student SID and no correlated AppLocker block event was observed."
                }
            }

            if (-not $eventFound) {
                if ($useScheduledTaskCmdlets) {
                    $taskState = 'unknown'
                    $lastTaskResult = 'unknown'
                    $lastRunObserved = 'unknown'
                    try {
                        $registeredTask = Get-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
                        if ($registeredTask) { $taskState = [string]$registeredTask.State }
                        $taskInfo = Get-ScheduledTaskInfo -TaskName $probeTask -ErrorAction SilentlyContinue
                        if ($taskInfo) {
                            $lastTaskResult = '0x{0:X8}' -f [uint32]$taskInfo.LastTaskResult
                            $lastRunObserved = ([datetime]$taskInfo.LastRunTime -gt [datetime]::MinValue).ToString().ToLowerInvariant()
                        }
                    }
                    catch {}
                    Write-Host "OPENPATH_BOUNDARY_PROBE_FAILURE state=$taskState lastTaskResult=$lastTaskResult lastRunObserved=$lastRunObserved"
                }
                $expectedEvent = if ($PackagedAppPattern) { '8004/8022 block event' } else { '8004 block event' }
                throw "$ProbeName FAILED: AppLocker $expectedEvent was not observed for $binaryLeaf within timeout ($TimeoutSeconds s)."
            }

            return [pscustomobject]@{
                name     = $ProbeName
                section  = 'student'
                status   = 'pass'
                detail   = "Real execution probe: $binaryLeaf denied for student account (AppLocker event $blockEventId confirmed)."
                evidence = [pscustomobject]@{ appLocker8004Observed = ($blockEventId -eq 8004); appLocker8022Observed = ($blockEventId -eq 8022); blockEventId = $blockEventId }
            }
        }
        else {
            $allowedFound = $false
            while ((Get-Date) -lt $pollDeadline) {
                if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                    $allowedFound = $true
                    break
                }

                if ($ProcessName) {
                    $studentProcs = @()
                    try {
                        $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE '$ProcessName%'" -ErrorAction SilentlyContinue)
                        foreach ($p in $procs) {
                            $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue
                            if ($owner -and $owner.Sid -and $StudentSid -and ($owner.Sid -eq $StudentSid)) {
                                $studentProcs += $p
                            }
                            elseif (-not $StudentSid) {
                                $studentProcs += $p
                            }
                        }
                    }
                    catch {}

                    if ($studentProcs.Count -gt 0) {
                        $allowedFound = $true
                        foreach ($sp in $studentProcs) {
                            Stop-Process -Id $sp.ProcessId -Force -ErrorAction SilentlyContinue
                        }
                        break
                    }
                }

                try {
                    $allowEvents = @(Get-WinEvent -FilterHashtable @{
                            LogName   = 'Microsoft-Windows-AppLocker/EXE and DLL'
                            Id        = 8002
                            StartTime = $since
                        } -ErrorAction SilentlyContinue | Where-Object {
                            $matchesBinary = ($_.Message -match [regex]::Escape($binaryLeaf))
                            $matchesUser = if ($StudentSid) {
                                ($_.UserId -and $_.UserId.Value -eq $StudentSid) -or ($_.Message -match [regex]::Escape($StudentSid))
                            } elseif ($UserName) {
                                ($_.Message -match [regex]::Escape($UserName)) -or ($_.UserId -and $_.UserId.Value -eq $UserName)
                            } else {
                                $true
                            }
                            $matchesBinary -and $matchesUser
                        })
                    if ($allowEvents.Count -gt 0) {
                        $allowedFound = $true
                        break
                    }
                }
                catch {}

                Start-Sleep -Seconds 1
            }

            if (-not $allowedFound) {
                throw "$ProbeName FAILED: Allowed execution was not observed for $binaryLeaf attributed to student within timeout ($TimeoutSeconds s)."
            }

            return [pscustomobject]@{
                name     = $ProbeName
                section  = 'student'
                status   = 'pass'
                detail   = "Real execution probe: $binaryLeaf allowed for student account."
                evidence = [pscustomobject]@{ allowedObserved = $true }
            }
        }
    }
    finally {
        if ($useScheduledTaskCmdlets) {
            $registeredProbe = Get-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
            if ($registeredProbe -and [string]$registeredProbe.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
                $stopDeadline = (Get-Date).AddSeconds(10)
                do {
                    Start-Sleep -Milliseconds 100
                    $registeredProbe = Get-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
                } while ($registeredProbe -and [string]$registeredProbe.State -eq 'Running' -and (Get-Date) -lt $stopDeadline)
            }
            Unregister-ScheduledTask -TaskName $probeTask -Confirm:$false -ErrorAction SilentlyContinue
        }
        else {
            Invoke-OpenPathSchtasksCommand -Command { & schtasks.exe /Delete /TN $probeTask /F } | Out-Null
        }
    }
}

function Assert-InstalledOpenPathBrowserBoundaryAppControl {
    <#
    .SYNOPSIS
        Verifies that OpenPath non-admin AppControl was installed and remains intact.
        This is an assert-only verification: it NEVER attempts to repair or mutates the boundary.
    #>
    param(
        [string]$OpenPathRoot = 'C:\OpenPath'
    )

    $configPath = Join-Path $OpenPathRoot 'data\config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenPath config is missing before browser-boundary probes: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if (-not $config.PSObject.Properties['installState'] -or $config.installState -ne 'complete') {
        throw "OpenPath installState must be 'complete' before browser-boundary probes, observed: '$($config.installState)'"
    }
    if (-not $config.PSObject.Properties['appControlCommitState'] -or $config.appControlCommitState -ne 'committed') {
        throw "OpenPath appControlCommitState must be 'committed' before browser-boundary probes, observed: '$($config.appControlCommitState)'"
    }
    if (-not $config.PSObject.Properties['enableNonAdminAppControl'] -or -not [bool]$config.enableNonAdminAppControl) {
        throw "OpenPath enableNonAdminAppControl must be true before browser-boundary probes."
    }

    if (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $watchdogTask = Get-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction SilentlyContinue
        if (-not $watchdogTask) {
            throw "OpenPath-Watchdog scheduled task is missing before browser-boundary probes."
        }
    }

    if (Get-Command -Name Get-LocalGroup -ErrorAction SilentlyContinue) {
        $restrictedGroup = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue
        if (-not $restrictedGroup) {
            throw "OpenPath-Restricted local group is missing before browser-boundary probes."
        }
    }

    if (Get-Command -Name Get-Service -ErrorAction SilentlyContinue) {
        $appIdSvc = Get-Service -Name 'AppIDSvc' -ErrorAction SilentlyContinue
        if (-not $appIdSvc -or $appIdSvc.Status -ne 'Running') {
            throw "AppIDSvc service must be Running before browser-boundary probes, observed status: '$($appIdSvc.Status)'"
        }
    }

    $appControlModule = Join-Path $OpenPathRoot 'lib\AppControl.psm1'
    if (-not (Test-Path -LiteralPath $appControlModule)) {
        throw "OpenPath AppControl module is missing: $appControlModule"
    }
    Import-Module $appControlModule -Force -Global -ErrorAction Stop

    $mode = if ($config.PSObject.Properties['nonAdminAppControlMode'] -and $config.nonAdminAppControlMode) { [string]$config.nonAdminAppControlMode } else { 'Enforced' }
    $approvedBrowsers = if ($config.PSObject.Properties['approvedStudentBrowsers'] -and $config.approvedStudentBrowsers) { @($config.approvedStudentBrowsers) } else { @('Firefox') }

    # Pure assert-only: DO NOT CALL Set-OpenPathNonAdminAppControl or repair!
    if (-not (Test-OpenPathNonAdminAppControlActive -Mode $mode -ApprovedBrowsers $approvedBrowsers)) {
        throw "OpenPath AppControl boundary is inactive before browser-boundary probes; installer acceptance failed."
    }

    if (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
        $policyXml = [xml](Get-AppLockerPolicy -Local -Xml -ErrorAction SilentlyContinue)
        if ($policyXml) {
            $adminAllowAllRules = @($policyXml.AppLockerPolicy.RuleCollection.FilePathRule | Where-Object {
                    $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-32-544' -and $_.Conditions.FilePathCondition.Path -eq '*'
                })
            if ($adminAllowAllRules.Count -eq 0) {
                throw 'OpenPath AppControl policy is active but the administrator allow-all rule is missing.'
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-ReportAssertNoFailures',
    'Assert-RequiredStudentProbeStatuses',
    'New-OpenPathProbePayloadBinary',
    'Invoke-StudentExecutableTaskProbe',
    'Assert-InstalledOpenPathBrowserBoundaryAppControl'
)
