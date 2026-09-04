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
        [int]$TimeoutSeconds = 20
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        throw "$ProbeName FAILED: Executable $ExecutablePath does not exist on host."
    }

    $probeTask = "OpenPathProbe-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $taskCommand = if ($Arguments) { "`"$ExecutablePath`" $Arguments" } else { "`"$ExecutablePath`"" }
    $taskTime = (Get-Date).AddMinutes(1).ToString('HH:mm')

    & schtasks.exe /Create /TN $probeTask /SC ONCE /ST $taskTime /TR $taskCommand /RU "$env:COMPUTERNAME\$UserName" /RP $Password /RL LIMITED /F *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "$ProbeName FAILED: Task creation for $ExecutablePath failed under student credentials ($LASTEXITCODE); cannot verify AppLocker boundary."
    }

    $since = Get-Date
    try {
        & schtasks.exe /Run /TN $probeTask *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "$ProbeName FAILED: Task execution for $ExecutablePath failed ($LASTEXITCODE)."
        }

        $pollDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $binaryLeaf = [System.IO.Path]::GetFileName($ExecutablePath)

        if ($Expectation -eq 'ExpectDenied') {
            $eventFound = $false
            while ((Get-Date) -lt $pollDeadline) {
                if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                    throw "$ProbeName FAILED: executable ran and created marker file $MarkerPath under student account!"
                }

                if ($ProcessName -and (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
                    Stop-Process -Name $ProcessName -Force -ErrorAction SilentlyContinue
                    throw "$ProbeName FAILED: process $ProcessName is running under student account!"
                }

                try {
                    $blockEvents = @(Get-WinEvent -FilterHashtable @{
                            LogName   = 'Microsoft-Windows-AppLocker/EXE and DLL'
                            Id        = 8004
                            StartTime = $since
                        } -ErrorAction SilentlyContinue | Where-Object {
                            $_.Message -match [regex]::Escape($binaryLeaf) -and (
                                ($null -ne $StudentSid -and $_.UserId -and $_.UserId.Value -eq $StudentSid) -or
                                ($null -eq $StudentSid -and $_.Message -match [regex]::Escape($UserName))
                            )
                        })
                    if ($blockEvents.Count -gt 0) {
                        $eventFound = $true
                        break
                    }
                }
                catch {}

                Start-Sleep -Seconds 1
            }

            if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                throw "$ProbeName FAILED: executable ran and created marker file $MarkerPath under student account!"
            }

            if ($ProcessName -and (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
                Stop-Process -Name $ProcessName -Force -ErrorAction SilentlyContinue
                throw "$ProbeName FAILED: process $ProcessName is running under student account!"
            }

            if (-not $eventFound) {
                throw "$ProbeName FAILED: AppLocker 8004 block event was not observed for $binaryLeaf within timeout ($TimeoutSeconds s)."
            }

            return [pscustomobject]@{
                name     = $ProbeName
                section  = 'student'
                status   = 'pass'
                detail   = "Real execution probe: $binaryLeaf denied for student account (AppLocker event 8004 confirmed)."
                evidence = [pscustomobject]@{ appLocker8004Observed = $true }
            }
        }
        else {
            $allowedFound = $false
            while ((Get-Date) -lt $pollDeadline) {
                if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                    $allowedFound = $true
                    break
                }

                if ($ProcessName -and (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
                    $allowedFound = $true
                    Stop-Process -Name $ProcessName -Force -ErrorAction SilentlyContinue
                    break
                }

                try {
                    $allowEvents = @(Get-WinEvent -FilterHashtable @{
                            LogName   = 'Microsoft-Windows-AppLocker/EXE and DLL'
                            Id        = 8002
                            StartTime = $since
                        } -ErrorAction SilentlyContinue | Where-Object {
                            $_.Message -match [regex]::Escape($binaryLeaf)
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
                throw "$ProbeName FAILED: Allowed execution was not observed for $binaryLeaf within timeout ($TimeoutSeconds s)."
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
        & schtasks.exe /Delete /TN $probeTask /F *> $null
    }
}

Export-ModuleMember -Function @(
    'Invoke-ReportAssertNoFailures',
    'Assert-RequiredStudentProbeStatuses',
    'New-OpenPathProbePayloadBinary',
    'Invoke-StudentExecutableTaskProbe'
)
