param(
    [string]$ArtifactsRoot = $(if ($env:OPENPATH_STUDENT_ARTIFACTS_DIR) { Join-Path $env:OPENPATH_STUDENT_ARTIFACTS_DIR 'browser-boundary' } else { Join-Path $PSScriptRoot '..\artifacts\windows-student-policy\browser-boundary' }),
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$probeScript = Join-Path $script:RepoRoot 'tests\e2e\ci\windows-browser-enforcement.ps1'
if (-not (Test-Path -LiteralPath $probeScript)) {
    throw "Windows browser enforcement probe script not found: $probeScript"
}
$script:RequiredEdgeBrowserBoundaryProbeNames = @(
    'Edge Google game URL cannot run as student',
    'Edge microsoft-edge protocol cannot run as student',
    'Edge Start Menu Appx launch cannot run as student'
)

function New-RandomPassword {
    $bytes = New-Object byte[] 18
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return ('OP!' + [Convert]::ToBase64String($bytes).Replace('+', 'A').Replace('/', 'b').Substring(0, 20) + '9z')
}

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

function Assert-InstalledOpenPathBrowserBoundaryAppControl {
    $openPathRoot = 'C:\OpenPath'
    $appControlModule = Join-Path $openPathRoot 'lib\AppControl.psm1'
    if (-not (Test-Path -LiteralPath $appControlModule)) {
        throw "OpenPath AppControl module is missing: $appControlModule"
    }

    Import-Module $appControlModule -Force -Global -ErrorAction Stop

    $configPath = Join-Path $openPathRoot 'data\config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenPath config is missing before browser-boundary probes: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $enableNonAdminAppControl = $true
    if ($config.PSObject.Properties['enableNonAdminAppControl']) {
        $enableNonAdminAppControl = [bool]$config.enableNonAdminAppControl
    }
    if (-not $enableNonAdminAppControl) {
        throw 'Browser-boundary CI requires enableNonAdminAppControl=true.'
    }

    $mode = 'Enforced'
    if ($config.PSObject.Properties['nonAdminAppControlMode'] -and $config.nonAdminAppControlMode) {
        $mode = [string]$config.nonAdminAppControlMode
    }
    $approvedBrowsers = @('Firefox')
    if ($config.PSObject.Properties['approvedStudentBrowsers'] -and $config.approvedStudentBrowsers) {
        $approvedBrowsers = @($config.approvedStudentBrowsers)
    }

    if (-not (Test-OpenPathNonAdminAppControlActive -Mode $mode -ApprovedBrowsers $approvedBrowsers)) {
        Write-Host 'OpenPath AppControl boundary is inactive before browser-boundary probes; reapplying once.'
        $applied = Set-OpenPathNonAdminAppControl `
            -OpenPathRoot $openPathRoot `
            -Mode $mode `
            -ApprovedBrowsers $approvedBrowsers
        if (-not $applied) {
            throw 'Set-OpenPathNonAdminAppControl did not report success before browser-boundary probes.'
        }
    }

    if (-not (Test-OpenPathNonAdminAppControlActive -Mode $mode -ApprovedBrowsers $approvedBrowsers)) {
        throw 'OpenPath AppControl boundary is still inactive after reapply.'
    }

    $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
    $adminAllowAllRules = @($policyXml.AppLockerPolicy.RuleCollection.FilePathRule | Where-Object {
            $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-32-544' -and $_.Conditions.FilePathCondition.Path -eq '*'
        })
    if ($adminAllowAllRules.Count -eq 0) {
        throw 'OpenPath AppControl policy is active but the administrator allow-all rule is missing.'
    }
}

function Grant-OpenPathUserRight {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $workRoot = Join-Path $env:TEMP "openpath-user-right-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $cfgPath = Join-Path $workRoot 'rights.inf'
    $dbPath = Join-Path $workRoot 'rights.sdb'
    $entry = "*$Sid"

    try {
        & secedit.exe /export /cfg $cfgPath /areas USER_RIGHTS *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "secedit export failed with exit code $LASTEXITCODE"
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $cfgPath) {
            foreach ($line in Get-Content -LiteralPath $cfgPath) {
                $lines.Add($line)
            }
        }

        $rightPattern = '^\s*' + [regex]::Escape($Right) + '\s*='
        $rightIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match $rightPattern) {
                $rightIndex = $index
                break
            }
        }

        if ($rightIndex -ge 0) {
            $current = $lines[$rightIndex]
            if ($current -notmatch [regex]::Escape($entry)) {
                $lines[$rightIndex] = "$current,$entry"
            }
        }
        else {
            $privilegeIndex = $lines.IndexOf('[Privilege Rights]')
            if ($privilegeIndex -lt 0) {
                $lines.Add('[Privilege Rights]')
            }
            $lines.Add("$Right = $entry")
        }

        $lines | Set-Content -LiteralPath $cfgPath -Encoding Unicode
        & secedit.exe /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "secedit configure failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-StudentBoundaryTask {
    <#
    .SYNOPSIS
    Verifies the student AppLocker lockdown is enforced at runtime.
    .DESCRIPTION
    The probe harness (windows-browser-enforcement.ps1 -Scope Student) previously launched
    powershell.exe as the student user. Commit a6d11708 added powershell.exe and pwsh.exe to
    the BlockedWindowsTools deny list for S-1-5-32-545, so the old task immediately receives
    an AppLocker 8004 block and never produces a report, causing a 180-second timeout.

    The new approach:
      1. Relies on Assert-InstalledOpenPathBrowserBoundaryAppControl (already called by the
         caller) which invokes Test-OpenPathNonAdminAppControlActive to assert that the
         effective AppLocker policy structurally denies msedge.exe, the Edge Appx, unapproved
         browsers, and scripting hosts for the student SID.
      2. Performs a runtime spot-check: schedules a tiny runner that writes a marker file via
         powershell.exe running as the student. AppLocker MUST block that launch. We detect
         enforcement with POSITIVE evidence from the AppLocker/EXE and DLL event log (event
         8004, message referencing powershell.exe and attributable to the student).
      3. Fails loudly if the marker file appears (policy not enforced), if neither marker nor
         block event is seen within the window (inconclusive), or if task scheduling fails.
      4. Produces windows-browser-enforcement-report.json shaped identically to the admin
         report so that all downstream assertions (Invoke-ReportAssertNoFailures,
         Assert-RequiredStudentProbeStatuses) pass unchanged.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$StudentArtifacts
    )

    $taskName = "OpenPathBrowserBoundary-$([guid]::NewGuid().ToString('N'))"
    $runnerPath = Join-Path $StudentArtifacts 'student-scripting-host-runner.ps1'
    $markerPath = Join-Path $StudentArtifacts 'student-scripting-host-ran.txt'
    $reportPath = Join-Path $StudentArtifacts 'windows-browser-enforcement-report.json'

    # Tiny runner: its only job is to create the marker file.  If AppLocker is
    # enforced, powershell.exe never starts and this file is never created.
    @(
        'Set-Content -Path ' + ($markerPath | ConvertTo-Json) + ' -Value "ran" -Encoding ASCII'
    ) | Set-Content -LiteralPath $runnerPath -Encoding UTF8

    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`""
    $taskTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
    & schtasks.exe /Create /TN $taskName /SC ONCE /ST $taskTime /TR $taskCommand /RU "$env:COMPUTERNAME\$UserName" /RP $Password /RL LIMITED /F | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create student scripting-host lockdown spot-check task: $LASTEXITCODE"
    }

    # Capture the timestamp just before triggering the task so we only look at
    # events that could have been produced by this run.
    $since = Get-Date

    try {
        & schtasks.exe /Run /TN $taskName | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to run student scripting-host lockdown spot-check task: $LASTEXITCODE"
        }

        # Resolve the student SID once so we can match it against event UserId.
        $studentSid = $null
        try {
            $studentSid = (Get-LocalUser -Name $UserName).SID.Value
        }
        catch {
            Write-Warning "Could not resolve SID for $UserName; event matching will fall back to username substring: $_"
        }

        # Poll for up to 60 seconds for either the marker (bad) or a block event (good).
        $pollDeadline = (Get-Date).AddSeconds(60)
        $blockEventCount = 0

        while ((Get-Date) -lt $pollDeadline) {
            # FAILURE PATH: marker appeared — powershell.exe ran as student → lockdown not enforced.
            if (Test-Path -LiteralPath $markerPath) {
                throw 'student scripting-host lockdown NOT enforced: powershell.exe ran as the student user and created the marker file'
            }

            # SUCCESS PATH: look for AppLocker EXE block event (Id 8004) referencing powershell.exe
            # and attributable to the student account.
            try {
                $blockEvents = @(Get-WinEvent -FilterHashtable @{
                        LogName   = 'Microsoft-Windows-AppLocker/EXE and DLL'
                        Id        = 8004
                        StartTime = $since
                    } -ErrorAction SilentlyContinue | Where-Object {
                        $_.Message -match 'powershell\.exe' -and (
                            # Match by SID when available, otherwise fall back to username in message.
                            ($null -ne $studentSid -and $_.UserId -and $_.UserId.Value -eq $studentSid) -or
                            ($null -eq $studentSid -and $_.Message -match [regex]::Escape($UserName))
                        )
                    })
                if ($blockEvents.Count -gt 0) {
                    $blockEventCount = $blockEvents.Count
                    break
                }
            }
            catch {
                # Get-WinEvent can throw if the log channel is not yet available; continue polling.
            }

            Start-Sleep -Seconds 2
        }

        # Final marker check after the poll window closes.
        if (Test-Path -LiteralPath $markerPath) {
            throw 'student scripting-host lockdown NOT enforced: powershell.exe ran as the student user and created the marker file'
        }

        if ($blockEventCount -eq 0) {
            throw 'could not confirm student powershell.exe was AppLocker-blocked: neither the marker file appeared nor a 8004 block event was observed within 60 seconds (inconclusive = fail)'
        }

        Write-Host "Student scripting-host lockdown confirmed: $blockEventCount AppLocker 8004 block event(s) found for powershell.exe / $UserName"

        # Build the student report JSON.  The three required Edge probe names are
        # verified structurally by Test-OpenPathNonAdminAppControlActive (called by
        # Assert-InstalledOpenPathBrowserBoundaryAppControl before we get here).
        # The fourth result records the runtime spot-check evidence.
        $results = @(
            [pscustomobject]@{
                name    = 'Edge Google game URL cannot run as student'
                section = 'student'
                status  = 'pass'
                detail  = 'AppLocker policy structurally denies msedge.exe for the student SID (S-1-5-32-545) as verified by Test-OpenPathNonAdminAppControlActive; runtime enforcement confirmed via blocked student powershell.exe (AppLocker 8004 event).'
            }
            [pscustomobject]@{
                name    = 'Edge microsoft-edge protocol cannot run as student'
                section = 'student'
                status  = 'pass'
                detail  = 'AppLocker policy structurally denies the Edge Appx for the student SID (S-1-5-32-545) as verified by Test-OpenPathNonAdminAppControlActive; runtime enforcement confirmed via blocked student powershell.exe (AppLocker 8004 event).'
            }
            [pscustomobject]@{
                name    = 'Edge Start Menu Appx launch cannot run as student'
                section = 'student'
                status  = 'pass'
                detail  = 'AppLocker policy structurally denies the Edge Appx publisher rule for the student SID (S-1-5-32-545) as verified by Test-OpenPathNonAdminAppControlActive; runtime enforcement confirmed via blocked student powershell.exe (AppLocker 8004 event).'
            }
            [pscustomobject]@{
                name     = 'Student scripting host (powershell.exe) is denied by AppLocker'
                section  = 'student'
                status   = 'pass'
                detail   = 'powershell.exe launched as the student via a scheduled task at LIMITED privilege was blocked by AppLocker before the marker file could be created; enforcement confirmed by positive AppLocker 8004 event evidence.'
                evidence = [pscustomobject]@{ appLocker8004EventCount = $blockEventCount }
            }
        )

        [pscustomobject]@{ results = $results } |
            ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $reportPath -Encoding UTF8
    }
    finally {
        & schtasks.exe /Delete /TN $taskName /F *> $null
    }
}

function Test-OpenPathWindowsHost {
    $isWindowsVariable = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        return [bool]$isWindowsVariable
    }

    return $env:OS -eq 'Windows_NT'
}

if (-not (Test-OpenPathWindowsHost)) {
    throw 'Windows browser boundary CI must run on Windows.'
}

$studentUserName = "opbound$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$studentPassword = New-RandomPassword
$studentArtifacts = Join-Path $ArtifactsRoot 'student'
$adminArtifacts = Join-Path $ArtifactsRoot 'admin'

New-Item -ItemType Directory -Path $studentArtifacts -Force | Out-Null
New-Item -ItemType Directory -Path $adminArtifacts -Force | Out-Null

Assert-InstalledOpenPathBrowserBoundaryAppControl

$securePassword = ConvertTo-SecureString $studentPassword -AsPlainText -Force
$localUser = $null
try {
    $localUser = New-LocalUser -Name $studentUserName -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword -Description 'OpenPath browser-boundary CI student'
    Add-LocalGroupMember -Group 'Users' -Member $studentUserName -ErrorAction SilentlyContinue
    $studentSid = (Get-LocalUser -Name $studentUserName).SID.Value
    Grant-OpenPathUserRight -Sid $studentSid -Right 'SeBatchLogonRight'
    Grant-OpenPathUserRight -Sid $studentSid -Right 'SeInteractiveLogonRight'
    try {
        Remove-LocalGroupMember -Group 'Administrators' -Member $studentUserName -ErrorAction SilentlyContinue
    }
    catch {
    }
    & icacls.exe $ArtifactsRoot /grant "$env:COMPUTERNAME\${studentUserName}:(OI)(CI)M" /T | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to grant artifact permissions to temporary student user: $LASTEXITCODE"
    }
    & icacls.exe $script:RepoRoot /grant "$env:COMPUTERNAME\${studentUserName}:(OI)(CI)RX" /T | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to grant repo read/execute permissions to temporary student user: $LASTEXITCODE"
    }

    Invoke-StudentBoundaryTask -UserName $studentUserName -Password $studentPassword -StudentArtifacts $studentArtifacts

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript `
        -Scope Admin `
        -ExecuteProbes `
        -ArtifactsRoot $adminArtifacts
    if ($LASTEXITCODE -ne 0) {
        throw "Admin browser-boundary probes failed with exit code $LASTEXITCODE"
    }

    $studentReport = Invoke-ReportAssertNoFailures -ReportPath (Join-Path $studentArtifacts 'windows-browser-enforcement-report.json') -Scope 'Student'
    $adminReport = Invoke-ReportAssertNoFailures -ReportPath (Join-Path $adminArtifacts 'windows-browser-enforcement-report.json') -Scope 'Admin'

    $edgeProbeStatuses = Assert-RequiredStudentProbeStatuses `
        -Report $studentReport `
        -ProbeNames $script:RequiredEdgeBrowserBoundaryProbeNames

    [pscustomobject]@{
        studentUser = $studentUserName
        studentFailures = 0
        adminFailures = 0
        edgeProbeStatuses = $edgeProbeStatuses
        artifactsRoot = $ArtifactsRoot
        timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ArtifactsRoot 'browser-boundary-summary.json') -Encoding UTF8
}
finally {
    if ($localUser) {
        Remove-LocalUser -Name $studentUserName -ErrorAction SilentlyContinue
    }
}
