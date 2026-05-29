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
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$StudentArtifacts
    )

    $taskName = "OpenPathBrowserBoundary-$([guid]::NewGuid().ToString('N'))"
    $runnerPath = Join-Path $StudentArtifacts 'run-student-browser-boundary.ps1'
    $exitCodePath = Join-Path $StudentArtifacts 'student-exit-code.txt'
    $reportPath = Join-Path $StudentArtifacts 'windows-browser-enforcement-report.json'
    $stdoutPath = Join-Path $StudentArtifacts 'student-task.out.log'
    $stderrPath = Join-Path $StudentArtifacts 'student-task.err.log'

    @(
        '$ErrorActionPreference = ''Stop'''
        '$repoRoot = ' + ($script:RepoRoot | ConvertTo-Json)
        '$probeScript = Join-Path $repoRoot ''tests\e2e\ci\windows-browser-enforcement.ps1'''
        '$artifactsRoot = ' + ($StudentArtifacts | ConvertTo-Json)
        '$exitCodePath = ' + ($exitCodePath | ConvertTo-Json)
        '$stdoutPath = ' + ($stdoutPath | ConvertTo-Json)
        '$stderrPath = ' + ($stderrPath | ConvertTo-Json)
        'Set-Location $repoRoot'
        '$process = Start-Process -FilePath powershell.exe -ArgumentList @(''-NoProfile'', ''-ExecutionPolicy'', ''Bypass'', ''-File'', $probeScript, ''-Scope'', ''Student'', ''-ExecuteProbes'', ''-PrepareProbeFiles'', ''-ArtifactsRoot'', $artifactsRoot) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden'
        '$process.WaitForExit() | Out-Null'
        'Set-Content -Path $exitCodePath -Value ([string]$process.ExitCode) -Encoding ASCII'
        'exit $process.ExitCode'
    ) | Set-Content -LiteralPath $runnerPath -Encoding UTF8

    $taskTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`""
    & schtasks.exe /Create /TN $taskName /SC ONCE /ST $taskTime /TR $taskCommand /RU "$env:COMPUTERNAME\$UserName" /RP $Password /RL LIMITED /F | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create student browser-boundary scheduled task: $LASTEXITCODE"
    }

    try {
        & schtasks.exe /Run /TN $taskName | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to run student browser-boundary scheduled task: $LASTEXITCODE"
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $exitCodePath) {
                $exitCode = [int]((Get-Content -LiteralPath $exitCodePath -Raw).Trim())
                if ($exitCode -ne 0) {
                    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
                    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
                    throw "Student browser-boundary probes failed with exit code $exitCode`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
                }
                return
            }
            if (Test-Path -LiteralPath $reportPath) {
                try {
                    Invoke-ReportAssertNoFailures -ReportPath $reportPath -Scope 'Student' | Out-Null
                    return
                }
                catch {
                    throw
                }
            }
            Start-Sleep -Seconds 2
        }

        throw "Timed out waiting for student browser-boundary task after $TimeoutSeconds seconds; neither $exitCodePath nor $reportPath was produced"
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
