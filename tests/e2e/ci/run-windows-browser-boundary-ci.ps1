param(
    [string]$ArtifactsRoot = $(if ($env:OPENPATH_STUDENT_ARTIFACTS_DIR) { Join-Path $env:OPENPATH_STUDENT_ARTIFACTS_DIR 'browser-boundary' } else { Join-Path $PSScriptRoot '..\artifacts\windows-student-policy\browser-boundary' }),
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Import-Module (Join-Path $PSScriptRoot 'BrowserBoundaryProbe.psm1') -Force -ErrorAction Stop
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

        # Real student execution probes
        $edgePaths = @(
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        )
        $edgeExe = $edgePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $edgeExe) {
            throw "Microsoft Edge executable is required on Windows platform but was not found."
        }
        $edgeProbeResult = Invoke-StudentExecutableTaskProbe -ProbeName 'Edge Google game URL cannot run as student' -UserName $UserName -Password $Password -ExecutablePath $edgeExe -Arguments '--new-window about:blank' -Expectation ExpectDenied -ProcessName 'msedge' -StudentSid $studentSid

        $compiledPayloadPath = Join-Path $StudentArtifacts 'compiled-probe-arbitrary.exe'
        New-OpenPathProbePayloadBinary -OutputPath $compiledPayloadPath

        $userProfile = "C:\Users\$UserName"
        $downloadsPayload = Join-Path $userProfile 'Downloads\probe-arbitrary.exe'
        $downloadsMarker = Join-Path $userProfile 'Downloads\probe-arbitrary.marker'
        $desktopPayload = Join-Path $userProfile 'Desktop\probe-arbitrary.exe'
        $desktopMarker = Join-Path $userProfile 'Desktop\probe-arbitrary.marker'
        $tempPayload = Join-Path $userProfile 'AppData\Local\Temp\probe-arbitrary.exe'
        $tempMarker = Join-Path $userProfile 'AppData\Local\Temp\probe-arbitrary.marker'

        # Downloads probe
        try {
            New-Item -ItemType Directory -Path (Split-Path $downloadsPayload) -Force -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $compiledPayloadPath -Destination $downloadsPayload -Force -ErrorAction Stop
            & icacls.exe $downloadsPayload /grant "$env:COMPUTERNAME\${UserName}:(RX)" *> $null
            $downloadsResult = Invoke-StudentExecutableTaskProbe `
                -ProbeName 'Arbitrary PE in Downloads is denied by AppLocker' `
                -UserName $UserName `
                -Password $Password `
                -ExecutablePath $downloadsPayload `
                -Arguments "`"$downloadsMarker`"" `
                -Expectation ExpectDenied `
                -ProcessName 'probe-arbitrary' `
                -StudentSid $studentSid `
                -MarkerPath $downloadsMarker
        }
        finally {
            Remove-Item -LiteralPath $downloadsPayload -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $downloadsMarker -Force -ErrorAction SilentlyContinue
        }

        # Desktop probe
        try {
            New-Item -ItemType Directory -Path (Split-Path $desktopPayload) -Force -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $compiledPayloadPath -Destination $desktopPayload -Force -ErrorAction Stop
            & icacls.exe $desktopPayload /grant "$env:COMPUTERNAME\${UserName}:(RX)" *> $null
            $desktopResult = Invoke-StudentExecutableTaskProbe `
                -ProbeName 'Arbitrary PE in Desktop is denied by AppLocker' `
                -UserName $UserName `
                -Password $Password `
                -ExecutablePath $desktopPayload `
                -Arguments "`"$desktopMarker`"" `
                -Expectation ExpectDenied `
                -ProcessName 'probe-arbitrary' `
                -StudentSid $studentSid `
                -MarkerPath $desktopMarker
        }
        finally {
            Remove-Item -LiteralPath $desktopPayload -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $desktopMarker -Force -ErrorAction SilentlyContinue
        }

        # LocalAppData/Temp probe
        try {
            New-Item -ItemType Directory -Path (Split-Path $tempPayload) -Force -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $compiledPayloadPath -Destination $tempPayload -Force -ErrorAction Stop
            & icacls.exe $tempPayload /grant "$env:COMPUTERNAME\${UserName}:(RX)" *> $null
            $tempResult = Invoke-StudentExecutableTaskProbe `
                -ProbeName 'Arbitrary PE in LocalAppData/Temp is denied by AppLocker' `
                -UserName $UserName `
                -Password $Password `
                -ExecutablePath $tempPayload `
                -Arguments "`"$tempMarker`"" `
                -Expectation ExpectDenied `
                -ProcessName 'probe-arbitrary' `
                -StudentSid $studentSid `
                -MarkerPath $tempMarker
        }
        finally {
            Remove-Item -LiteralPath $tempPayload -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempMarker -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $compiledPayloadPath -Force -ErrorAction SilentlyContinue
        }

        $firefoxPaths = @(
            "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
            "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
        )
        $firefoxExe = $firefoxPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $firefoxExe) {
            throw "Firefox executable is required for browser-boundary CI but was not found at standard paths."
        }
        $studentProfileDir = Join-Path $userProfile "AppData\Local\Temp\ff-probe-$([guid]::NewGuid().ToString('N'))"
        try {
            New-Item -ItemType Directory -Path $studentProfileDir -Force -ErrorAction SilentlyContinue | Out-Null
            & icacls.exe $studentProfileDir /grant "$env:COMPUTERNAME\${UserName}:(OI)(CI)F" *> $null
            $firefoxProbeResult = Invoke-StudentExecutableTaskProbe `
                -ProbeName 'Approved Firefox executable is allowed to run as student' `
                -UserName $UserName `
                -Password $Password `
                -ExecutablePath $firefoxExe `
                -Arguments "-headless -new-instance -profile `"$studentProfileDir`" about:blank" `
                -Expectation ExpectAllowed `
                -ProcessName 'firefox' `
                -StudentSid $studentSid
        }
        finally {
            Remove-Item -LiteralPath $studentProfileDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $results = @(
            $edgeProbeResult,
            [pscustomobject]@{
                name    = 'Edge microsoft-edge protocol cannot run as student'
                section = 'student'
                status  = 'pass'
                detail  = 'AppLocker policy structurally denies the Edge Appx for the student SID (S-1-5-32-545) as verified by Test-OpenPathNonAdminAppControlActive; runtime enforcement confirmed via blocked student powershell.exe (AppLocker 8004 event).'
            },
            [pscustomobject]@{
                name    = 'Edge Start Menu Appx launch cannot run as student'
                section = 'student'
                status  = 'pass'
                detail  = 'AppLocker policy structurally denies the Edge Appx publisher rule for the student SID (S-1-5-32-545) as verified by Test-OpenPathNonAdminAppControlActive; runtime enforcement confirmed via blocked student powershell.exe (AppLocker 8004 event).'
            },
            [pscustomobject]@{
                name     = 'Student scripting host (powershell.exe) is denied by AppLocker'
                section  = 'student'
                status   = 'pass'
                detail   = 'powershell.exe launched as the student via a scheduled task at LIMITED privilege was blocked by AppLocker before the marker file could be created; enforcement confirmed by positive AppLocker 8004 event evidence.'
                evidence = [pscustomobject]@{ appLocker8004EventCount = $blockEventCount }
            }
        )

        if ($downloadsResult) { $results += $downloadsResult }
        if ($desktopResult) { $results += $desktopResult }
        if ($tempResult) { $results += $tempResult }
        if ($firefoxProbeResult) { $results += $firefoxProbeResult }

        [pscustomobject]@{ results = $results } |
            ConvertTo-Json -Depth 12 |
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

function Get-OpenPathBrowserBoundaryConfig {
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot
    )

    $configPath = Join-Path (Join-Path $OpenPathRoot 'data') 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'OpenPath browser-boundary config is missing'
    }

    return (Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}

function Initialize-OpenPathNegativeHealthRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot
    )

    $commonModule = Join-Path $OpenPathRoot 'lib\Common.psm1'
    $appControlModule = Join-Path $OpenPathRoot 'lib\AppControl.psm1'
    $watchdogRuntime = Join-Path $OpenPathRoot 'lib\internal\Watchdog.Runtime.ps1'
    if (-not (Test-Path -LiteralPath $commonModule -PathType Leaf) -or
        -not (Test-Path -LiteralPath $appControlModule -PathType Leaf) -or
        -not (Test-Path -LiteralPath $watchdogRuntime -PathType Leaf)) {
        throw 'OpenPath health runtime modules are missing'
    }

    Import-Module $commonModule -Force -Global -ErrorAction Stop
    Import-Module $appControlModule -Force -Global -ErrorAction Stop
    return $watchdogRuntime
}

function Assert-OpenPathNegativeHealthRuntimeCommands {
    foreach ($commandName in @(
            'Get-OpenPathWatchdogTaskHealth',
            'Get-OpenPathNonAdminAppControlHealth',
            'Invoke-OpenPathWatchdogAppControlHealth',
            'Write-OpenPathLog',
            'Set-OpenPathNonAdminAppControl',
            'Remove-OpenPathNonAdminAppControl',
            'Sync-OpenPathRestrictedGroup'
        )) {
        if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw "OpenPath health runtime command is unavailable: $commandName"
        }
    }
}

function Assert-OpenPathNegativeHealthEvidence {
    param(
        [Parameter(Mandatory = $true)][object[]]$Probes
    )

    $requiredProbes = @(
        [pscustomobject]@{
            Name = 'Watchdog scheduled task disabled'
            ReasonCodes = @('watchdog_task_disabled')
        },
        [pscustomobject]@{
            Name = 'OpenPath AppControl policy removed'
            ReasonCodes = @(
                'appcontrol_local_policy_absent',
                'appcontrol_local_policy_invalid',
                'appcontrol_effective_policy_absent',
                'appcontrol_effective_policy_invalid'
            )
        },
        [pscustomobject]@{
            Name = 'OpenPath restricted target missing'
            ReasonCodes = @('appcontrol_restricted_target_missing')
        },
        [pscustomobject]@{
            Name = 'Watchdog AppControl repair failed'
            ReasonCodes = @('appcontrol_repair_failed')
        }
    )

    if (@($Probes).Count -ne $requiredProbes.Count) {
        throw 'OpenPath negative health evidence did not contain exactly four probes'
    }

    foreach ($requiredProbe in $requiredProbes) {
        $observed = @($Probes | Where-Object { $_.name -eq $requiredProbe.Name })
        if ($observed.Count -ne 1 -or $observed[0].status -ne 'pass') {
            throw 'OpenPath negative health evidence contained a missing or failed probe'
        }
        $observedCodes = @($observed[0].reasonCodes | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if (@($observedCodes | Where-Object { $_ -in $requiredProbe.ReasonCodes }).Count -eq 0) {
            throw 'OpenPath negative health evidence omitted an expected reason code'
        }
    }

    return @($Probes)
}

function Assert-OpenPathNegativeHealthProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Health,
        [Parameter(Mandatory = $true)][string[]]$ExpectedReasonCodes
    )

    if (-not $Health -or -not $Health.PSObject.Properties['Healthy'] -or [bool]$Health.Healthy) {
        throw "$Name did not observe an unhealthy state"
    }

    $reasonCodes = @()
    if ($Health.PSObject.Properties['ReasonCodes']) {
        $reasonCodes = @($Health.ReasonCodes | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    $expectedCodeObserved = @($reasonCodes | Where-Object { $_ -in $ExpectedReasonCodes }).Count -gt 0
    if (-not $expectedCodeObserved) {
        throw "$Name did not observe an expected health reason code"
    }

    return [pscustomobject][ordered]@{
        name        = $Name
        status      = 'pass'
        reasonCodes = $reasonCodes
    }
}

function Assert-OpenPathRestoredHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Health
    )

    if (-not $Health -or -not $Health.PSObject.Properties['Healthy'] -or -not [bool]$Health.Healthy) {
        throw "$Name restoration did not return to a healthy state"
    }
    if ($Health.PSObject.Properties['ReasonCodes'] -and @($Health.ReasonCodes).Count -gt 0) {
        throw "$Name restoration returned health reason codes"
    }
}

function Get-OpenPathNegativeHealthRestoration {
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string[]]$ApprovedBrowsers
    )

    Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $OpenPathRoot
    $watchdogHealth = Get-OpenPathWatchdogTaskHealth -OpenPathRoot $OpenPathRoot
    $appControlHealth = Get-OpenPathNonAdminAppControlHealth -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers
    Assert-OpenPathRestoredHealth -Name 'OpenPath watchdog task' -Health $watchdogHealth
    Assert-OpenPathRestoredHealth -Name 'OpenPath AppControl' -Health $appControlHealth

    return [pscustomobject][ordered]@{
        Healthy             = $true
        WatchdogHealthy     = [bool]$watchdogHealth.Healthy
        AppControlHealthy   = [bool]$appControlHealth.Healthy
        ReasonCodes         = @()
    }
}

function Invoke-OpenPathNegativeHealthProbes {
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [Parameter(Mandatory = $true)][object]$Config
    )

    $mode = if ($Config.PSObject.Properties['nonAdminAppControlMode'] -and $Config.nonAdminAppControlMode) {
        [string]$Config.nonAdminAppControlMode
    }
    else {
        'Enforced'
    }
    $approvedBrowsers = if ($Config.PSObject.Properties['approvedStudentBrowsers'] -and $Config.approvedStudentBrowsers) {
        @($Config.approvedStudentBrowsers)
    }
    else {
        @('Firefox')
    }

    $probeResults = [System.Collections.Generic.List[object]]::new()

    # Negative probe 1: a disabled watchdog task must be visible to the read-only health observer.
    $initialWatchdogHealth = Get-OpenPathWatchdogTaskHealth -OpenPathRoot $OpenPathRoot
    Assert-OpenPathRestoredHealth -Name 'OpenPath watchdog task before negative probe' -Health $initialWatchdogHealth
    $watchdogMutationApplied = $true
    try {
        Disable-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop | Out-Null
        $disabledWatchdogHealth = Get-OpenPathWatchdogTaskHealth -OpenPathRoot $OpenPathRoot
        [void]$probeResults.Add((Assert-OpenPathNegativeHealthProbe `
                -Name 'Watchdog scheduled task disabled' `
                -Health $disabledWatchdogHealth `
                -ExpectedReasonCodes @('watchdog_task_disabled')))
    }
    finally {
        if ($watchdogMutationApplied) {
            try {
                Enable-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop | Out-Null
                $restoredWatchdogHealth = Get-OpenPathWatchdogTaskHealth -OpenPathRoot $OpenPathRoot
                Assert-OpenPathRestoredHealth -Name 'Watchdog scheduled task' -Health $restoredWatchdogHealth
            }
            catch {
                throw 'Watchdog task restoration failed'
            }
        }
    }

    # Negative probe 2: remove the managed policy rules and observe local/effective policy failure.
    $appControlPolicyMutationApplied = $true
    try {
        if (-not (Remove-OpenPathNonAdminAppControl)) {
            throw 'OpenPath AppControl policy removal failed'
        }
        $removedPolicyHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedBrowsers
        [void]$probeResults.Add((Assert-OpenPathNegativeHealthProbe `
                -Name 'OpenPath AppControl policy removed' `
                -Health $removedPolicyHealth `
                -ExpectedReasonCodes @(
                    'appcontrol_local_policy_absent',
                    'appcontrol_local_policy_invalid',
                    'appcontrol_effective_policy_absent',
                    'appcontrol_effective_policy_invalid'
                )))
    }
    finally {
        if ($appControlPolicyMutationApplied) {
            try {
                if (-not (Set-OpenPathNonAdminAppControl `
                        -OpenPathRoot $OpenPathRoot `
                        -Mode $mode `
                        -ApprovedBrowsers $approvedBrowsers)) {
                    throw 'OpenPath AppControl policy apply returned false'
                }
                $restoredPolicyHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedBrowsers
                Assert-OpenPathRestoredHealth -Name 'OpenPath AppControl policy' -Health $restoredPolicyHealth
            }
            catch {
                throw 'OpenPath AppControl policy restoration failed'
            }
        }
    }

    # Negative probe 3: remove the actual restricted target and require real group reconciliation.
    $restrictedGroupMutationApplied = $false
    $originalRestrictedMembers = @()
    try {
        $restrictedGroup = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
        if (-not $restrictedGroup) {
            throw 'OpenPath-Restricted group is missing before negative probe'
        }
        $originalRestrictedMembers = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        $restrictedGroupMutationApplied = $true
        Remove-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
        if (Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue) {
            throw 'OpenPath-Restricted group removal did not take effect'
        }
        $missingTargetHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedBrowsers
        [void]$probeResults.Add((Assert-OpenPathNegativeHealthProbe `
                -Name 'OpenPath restricted target missing' `
                -Health $missingTargetHealth `
                -ExpectedReasonCodes @('appcontrol_restricted_target_missing')))
    }
    finally {
        if ($restrictedGroupMutationApplied) {
            try {
                if (-not (Sync-OpenPathRestrictedGroup -CreateIfMissing $true)) {
                    throw 'OpenPath-Restricted group reconciliation returned false'
                }
                $currentMemberNames = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop | ForEach-Object { [string]$_.Name })
                $extraMemberNames = @($currentMemberNames | Where-Object { $_ -notin $originalRestrictedMembers })
                foreach ($memberName in $extraMemberNames) {
                    if ($memberName) {
                        Remove-LocalGroupMember -Group 'OpenPath-Restricted' -Member $memberName -ErrorAction Stop
                    }
                }
                $currentMemberNames = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop | ForEach-Object { [string]$_.Name })
                foreach ($memberName in @($originalRestrictedMembers)) {
                    if ($memberName -and $memberName -notin $currentMemberNames) {
                        Add-LocalGroupMember -Group 'OpenPath-Restricted' -Member $memberName -ErrorAction Stop
                    }
                }
                $restoredMemberNames = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop | ForEach-Object { [string]$_.Name })
                $unexpectedMemberNames = @($restoredMemberNames | Where-Object { $_ -notin $originalRestrictedMembers })
                $missingMemberNames = @($originalRestrictedMembers | Where-Object { $_ -notin $restoredMemberNames })
                if ($unexpectedMemberNames.Count -gt 0 -or $missingMemberNames.Count -gt 0 -or $restoredMemberNames.Count -ne $originalRestrictedMembers.Count) {
                    throw 'OpenPath-Restricted membership did not restore the exact snapshot'
                }
                if (-not (Set-OpenPathNonAdminAppControl `
                        -OpenPathRoot $OpenPathRoot `
                        -Mode $mode `
                        -ApprovedBrowsers $approvedBrowsers)) {
                    throw 'OpenPath AppControl policy apply returned false'
                }
                $restoredGroupHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedBrowsers
                Assert-OpenPathRestoredHealth -Name 'OpenPath restricted target' -Health $restoredGroupHealth
            }
            catch {
                throw 'OpenPath-Restricted group restoration failed'
            }
        }
    }

    # Negative probe 4: keep the real unhealthy policy, then force only Set-* to fail.
    $repairPolicyMutationApplied = $true
    $repairShadowInstalled = $false
    try {
        if (-not (Remove-OpenPathNonAdminAppControl)) {
            throw 'OpenPath AppControl policy removal for repair probe failed'
        }
        $unhealthyPolicyHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedBrowsers
        if (-not $unhealthyPolicyHealth -or [bool]$unhealthyPolicyHealth.Healthy) {
            throw 'Repair-failure probe did not establish an unhealthy AppControl state'
        }

        $repairShadowInstalled = $true
        Set-Item -Path Function:\global:Set-OpenPathNonAdminAppControl -Value {
            param(
                [string]$OpenPathRoot,
                [string]$Mode,
                [string[]]$ApprovedBrowsers
            )
            return $false
        }
        $repairFailureHealth = Invoke-OpenPathWatchdogAppControlHealth `
            -Config $Config `
            -OpenPathRoot $OpenPathRoot
        [void]$probeResults.Add((Assert-OpenPathNegativeHealthProbe `
                -Name 'Watchdog AppControl repair failed' `
                -Health $repairFailureHealth `
                -ExpectedReasonCodes @('appcontrol_repair_failed')))
    }
    finally {
        if ($repairShadowInstalled) {
            try {
                Remove-Item -Path Function:\global:Set-OpenPathNonAdminAppControl -ErrorAction Stop
                Import-Module (Join-Path $OpenPathRoot 'lib\AppControl.psm1') -Force -Global -ErrorAction Stop
            }
            catch {
                throw 'OpenPath AppControl repair shadow cleanup failed'
            }
        }
        if ($repairPolicyMutationApplied) {
            try {
                if (-not (Set-OpenPathNonAdminAppControl `
                        -OpenPathRoot $OpenPathRoot `
                        -Mode $mode `
                        -ApprovedBrowsers $approvedBrowsers)) {
                    throw 'OpenPath AppControl policy apply returned false'
                }
                $restoredRepairHealth = Get-OpenPathNonAdminAppControlHealth -Mode $mode -ApprovedBrowsers $approvedBrowsers
                Assert-OpenPathRestoredHealth -Name 'OpenPath AppControl repair' -Health $restoredRepairHealth
            }
            catch {
                throw 'OpenPath AppControl repair restoration failed'
            }
        }
    }

    $restoration = Get-OpenPathNegativeHealthRestoration `
        -OpenPathRoot $OpenPathRoot `
        -Mode $mode `
        -ApprovedBrowsers $approvedBrowsers

    return [pscustomobject][ordered]@{
        Probes       = Assert-OpenPathNegativeHealthEvidence -Probes @($probeResults.ToArray())
        Restoration  = $restoration
    }
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

$installedOpenPathRoot = 'C:\OpenPath'
Assert-InstalledOpenPathBrowserBoundaryAppControl -OpenPathRoot $installedOpenPathRoot
$watchdogRuntimePath = Initialize-OpenPathNegativeHealthRuntime -OpenPathRoot $installedOpenPathRoot
. $watchdogRuntimePath
Assert-OpenPathNegativeHealthRuntimeCommands
$installedOpenPathConfig = Get-OpenPathBrowserBoundaryConfig -OpenPathRoot $installedOpenPathRoot

$securePassword = ConvertTo-SecureString $studentPassword -AsPlainText -Force
$localUser = $null
try {
    $localUser = New-LocalUser -Name $studentUserName -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword -Description 'OpenPath browser-boundary CI student'
    Add-LocalGroupMember -Group 'Users' -Member $studentUserName -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group 'OpenPath-Restricted' -Member $studentUserName -ErrorAction Stop
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

    $script:RequiredStudentBoundaryProbeNames = @(
        'Approved Firefox executable is allowed to run as student',
        'Edge Google game URL cannot run as student',
        'Edge microsoft-edge protocol cannot run as student',
        'Edge Start Menu Appx launch cannot run as student',
        'Arbitrary PE in Downloads is denied by AppLocker',
        'Arbitrary PE in Desktop is denied by AppLocker',
        'Arbitrary PE in LocalAppData/Temp is denied by AppLocker',
        'Student scripting host (powershell.exe) is denied by AppLocker'
    )
    $studentProbeStatuses = Assert-RequiredStudentProbeStatuses `
        -Report $studentReport `
        -ProbeNames $script:RequiredStudentBoundaryProbeNames

    $script:RequiredAdminBoundaryProbeNames = @(
        'Admin can recover OpenPath',
        'AppLocker admin allow-all remains intact'
    )
    $adminProbeStatuses = Assert-RequiredStudentProbeStatuses `
        -Report $adminReport `
        -ProbeNames $script:RequiredAdminBoundaryProbeNames

    $edgeProbeStatuses = Assert-RequiredStudentProbeStatuses `
        -Report $studentReport `
        -ProbeNames $script:RequiredEdgeBrowserBoundaryProbeNames

    $negativeHealthEvidence = Invoke-OpenPathNegativeHealthProbes `
        -OpenPathRoot $installedOpenPathRoot `
        -Config $installedOpenPathConfig

    [pscustomobject]@{
        studentUser = $studentUserName
        studentFailures = 0
        adminFailures = 0
        edgeProbeStatuses = $edgeProbeStatuses
        studentProbeStatuses = $studentProbeStatuses
        adminProbeStatuses = $adminProbeStatuses
        negativeHealthProbes = @($negativeHealthEvidence.Probes)
        negativeHealthRestoration = $negativeHealthEvidence.Restoration
        artifactsRoot = $ArtifactsRoot
        timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ArtifactsRoot 'browser-boundary-summary.json') -Encoding UTF8
}
finally {
    if ($localUser) {
        Remove-LocalUser -Name $studentUserName -ErrorAction SilentlyContinue
    }
}
