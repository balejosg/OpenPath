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
            Start-Sleep -Seconds 2
        }

        throw "Timed out waiting for student browser-boundary task after $TimeoutSeconds seconds"
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

    $edgeProbe = @($studentReport.results | Where-Object { $_.name -eq 'Edge Google game URL cannot run as student' }) | Select-Object -First 1
    if (-not $edgeProbe -or $edgeProbe.status -ne 'pass') {
        $status = if ($edgeProbe) { [string]$edgeProbe.status } else { 'missing' }
        throw "Required Edge Google game URL student probe did not pass; status=$status"
    }

    [pscustomobject]@{
        studentUser = $studentUserName
        studentFailures = 0
        adminFailures = 0
        edgeGoogleGameProbe = $edgeProbe.status
        artifactsRoot = $ArtifactsRoot
        timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ArtifactsRoot 'browser-boundary-summary.json') -Encoding UTF8
}
finally {
    if ($localUser) {
        Remove-LocalUser -Name $studentUserName -ErrorAction SilentlyContinue
    }
}
