<##
.SYNOPSIS
    In-guest desktop-survival harness for one Proxmox scenario step.
.DESCRIPTION
    Runs inside the disposable Windows guest through the QEMU guest agent and
    performs the real acceptance work of the desktop-survival matrix: baseline
    verification, personalized installer execution, strict AppControl commit
    verification, interactive session management, restricted-student boundary
    probes, rollback and cleanup verification.

    The controller owns hypervisor actions (snapshot, reboot, screendump) and
    calls this harness once per step. Every step writes a JSON result to
    -ResultPath and prints it to stdout. The harness never claims acceptance by
    itself: it reports what it observed and fails closed on unexpected results.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('prepare', 'observe', 'afterReboot', 'cleanup')][string]$Phase,
    [Parameter(Mandatory = $true)][ValidateSet(
        'install',
        'admin-autologon', 'admin-verify',
        'student-autologon', 'student-verify',
        'login-screen',
        'boundary-arm', 'boundary-collect',
        'uninstall',
        'verify-clean'
    )][string]$Step,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ScenarioId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$TemplatePath = '',
    [string]$PersonalizedExePath = '',
    [string]$StudentUserName = 'alumno',
    [string]$AdminUserName = 'opadmin',
    [string]$Secret = '',
    [string]$StatePath = 'C:\ProgramData\openpath-desktop-survival\state.json',
    [string]$ProbeRoot = 'C:\Users\Public\OpenPathProbes'
)

$ErrorActionPreference = 'Stop'
$script:Failures = New-Object System.Collections.Generic.List[string]

function Add-OpenPathLabFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Failures.Add($Message) | Out-Null
}

function Get-TargetUserSid {
    param([Parameter(Mandatory = $true)][string]$UserName)
    $account = New-Object System.Security.Principal.NTAccount($UserName)
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Get-AppLockerXmlText {
    try { return [string](Get-AppLockerPolicy -Local -Xml -ErrorAction Stop) }
    catch { return '' }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Invoke-OpenPathNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ output = [string]$output; exitCode = [int]$LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $previous }
}

function Read-OpenPathLabState {
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $parsed = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $table = @{}
            foreach ($property in @($parsed.PSObject.Properties)) { $table[$property.Name] = $property.Value }
            return $table
        }
        catch { return $null }
    }
    return $null
}

function Write-OpenPathLabState {
    param([Parameter(Mandatory = $true)][object]$Value)
    $parent = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$StatePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 24), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $StatePath -Force
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Test-PolicyHasOpenPathRules {
    $xml = Get-AppLockerXmlText
    return [bool]($xml -match 'OpenPath non-admin app control')
}

function Get-OpenPathStateSummary {
    $summary = [ordered]@{
        rootExists   = Test-Path -LiteralPath 'C:\OpenPath'
        configExists = $false
        config       = $null
        uninstaller  = Test-Path -LiteralPath 'C:\OpenPath\Uninstall-OpenPath.ps1'
        groupExists  = [bool](Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue)
        groupMembers = @()
        tasks        = @()
        policySha256 = ''
        policyHasOpenPathRules = $false
    }
    try {
        if (Test-Path -LiteralPath 'C:\OpenPath\data\config.json') {
            $summary.configExists = $true
            $summary.config = Get-Content -LiteralPath 'C:\OpenPath\data\config.json' -Raw | ConvertFrom-Json
        }
    }
    catch { Add-OpenPathLabFailure "config-unreadable: $($_.Exception.Message)" }
    $summary.catalogApplicationCount = 0
    if ($summary.config) {
        foreach ($candidate in @('applications', 'catalog', 'applicationCatalog')) {
            $value = $null
            if ($summary.config.PSObject.Properties[$candidate]) { $value = $summary.config.$candidate }
            if ($null -eq $value -or $value -is [string]) { continue }
            if ($value -is [System.Collections.IEnumerable]) { $summary.catalogApplicationCount = @($value).Count }
            elseif ($value.PSObject.Properties['applications']) { $summary.catalogApplicationCount = @($value.applications).Count }
            break
        }
    }
    try {
        $summary.groupMembers = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop |
            ForEach-Object { [string]$_.Name } | Sort-Object)
    }
    catch {}
    $summary.tasks = @(Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue |
        ForEach-Object { [string]$_.TaskName } | Sort-Object)
    $summary.policySha256 = Get-Sha256Hex -Text (Get-AppLockerXmlText)
    $summary.policyHasOpenPathRules = Test-PolicyHasOpenPathRules
    return $summary
}

function Set-OpenPathAutologon {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '1'
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultUserName' -Value $UserName
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -Value $Password
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonSID' -ErrorAction SilentlyContinue
    return 'autologon-set'
}

function Clear-OpenPathAutologon {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '0'
    Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonSID' -ErrorAction SilentlyContinue
    return 'autologon-cleared'
}

function Get-InteractiveSession {
    param([Parameter(Mandatory = $true)][string]$UserName)
    try {
        $consoleUser = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -ExpandProperty UserName)
        if ($consoleUser -and $consoleUser -match "\\$([regex]::Escape($UserName))$") { return $consoleUser }
    }
    catch {}
    foreach ($explorer in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        try {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            if ([string]$owner.User -eq $UserName) { return "$($owner.Domain)\$($owner.User)" }
        }
        catch {}
    }
    return ''
}

function Get-StudentLogonEvents {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][datetime]$AfterUtc
    )
    $events = @()
    try { $raw = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = $AfterUtc } -ErrorAction Stop }
    catch { return @() }
    foreach ($entry in $raw) {
        try {
            [xml]$xml = $entry.ToXml()
            $data = @{}
            foreach ($node in $xml.Event.EventData.Data) { $data[[string]$node.Name] = [string]$node.'#text' }
            if ([string]$data['TargetUserSid'] -ne $Sid) { continue }
            if ([string]$data['LogonType'] -notin @('2', '10', '11')) { continue }
            $events += [ordered]@{
                timeUtc   = $entry.TimeCreated.ToUniversalTime().ToString('o')
                logonType = [string]$data['LogonType']
                user      = [string]$data['TargetUserName']
            }
        }
        catch {}
    }
    return @($events)
}

function Ensure-OpenPathProbeDirectory {
    if (-not (Test-Path -LiteralPath $ProbeRoot)) {
        New-Item -ItemType Directory -Path $ProbeRoot -Force | Out-Null
    }
    Invoke-OpenPathNative -FilePath 'icacls.exe' -Arguments @($ProbeRoot, '/grant', '*S-1-5-32-545:(OI)(CI)M') | Out-Null
}

# Runs a probe process with the restricted student's own token. The interactive
# Task Scheduler path is unavailable for lab accounts (no batch logon right) and
# WMI refuses alternate credentials for local connections, so the harness uses
# LogonUser + CreateProcessWithTokenW from the SYSTEM context. AppLocker
# evaluates the child exactly as it would a student-launched process.
$script:OpenPathStudentProcessType = $null

function Initialize-OpenPathStudentProcess {
    if ($null -ne $script:OpenPathStudentProcessType) { return }
    $source = @'
using System;
using System.Runtime.InteropServices;

public static class OpenPathStudentProcess
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int logonType, int logonProvider, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessWithTokenW(IntPtr token, int logonFlags, string appName, string commandLine, int creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out int exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static int Run(string user, string password, string commandLine, int timeoutMilliseconds, out string error)
    {
        error = null;
        IntPtr token;
        if (!LogonUser(user, ".", password, 2, 0, out token))
        {
            error = "logon-failed:" + Marshal.GetLastWin32Error();
            return -1;
        }
        try
        {
            var startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(startupInfo);
            PROCESS_INFORMATION processInformation;
            if (!CreateProcessWithTokenW(token, 1, null, commandLine, 0x08000000, IntPtr.Zero, null, ref startupInfo, out processInformation))
            {
                error = "create-failed:" + Marshal.GetLastWin32Error();
                return -1;
            }
            try
            {
                uint wait = WaitForSingleObject(processInformation.hProcess, (uint)timeoutMilliseconds);
                if (wait == 0x102)
                {
                    error = "timeout";
                    return -2;
                }
                int exitCode;
                GetExitCodeProcess(processInformation.hProcess, out exitCode);
                return exitCode;
            }
            finally
            {
                CloseHandle(processInformation.hProcess);
                CloseHandle(processInformation.hThread);
            }
        }
        finally
        {
            CloseHandle(token);
        }
    }
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
    $script:OpenPathStudentProcessType = [OpenPathStudentProcess]
}

function Invoke-OpenPathStudentTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [int]$WaitSeconds = 45
    )
    Initialize-OpenPathStudentProcess
    $errorText = ''
    $exitCode = [OpenPathStudentProcess]::Run($StudentUserName, $Secret, $CommandLine, ($WaitSeconds * 1000), [ref]$errorText)
    return [ordered]@{
        status    = if ($null -ne $errorText -and $errorText -ne '') { [string]$errorText } else { 'finished' }
        lastResult = [string]$exitCode
        mode      = 'student-token'
    }
}

function New-OpenPathProbeLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [int]$GraceSeconds = 6
    )
    $escapedPath = $FilePath.Replace("'", "''")
    $escapedArgs = $Arguments.Replace("'", "''")
    $body = @"
`$ErrorActionPreference = 'Continue'
`$result = [ordered]@{ name = '$Name'; startedAt = (Get-Date).ToUniversalTime().ToString('o') }
try {
    `$p = Start-Process -FilePath '$escapedPath' -ArgumentList '$escapedArgs' -PassThru -ErrorAction Stop
    Start-Sleep -Seconds $GraceSeconds
    `$live = Get-Process -Id `$p.Id -ErrorAction SilentlyContinue
    `$result.started = `$true
    `$result.stillRunning = [bool]`$live
    if (`$live) {
        `$result.loadedModules = @(`$live.Modules | ForEach-Object { `$_.ModuleName } | Where-Object { `$_ -match 'mozglue|nss3|xul' } | Select-Object -First 5)
        Stop-Process -Id `$p.Id -Force -ErrorAction SilentlyContinue
    }
}
catch {
    `$result.started = `$false
    `$result.error = `$_.Exception.Message
    `$result.nativeError = `$_.Exception.NativeErrorCode
}
`$result | ConvertTo-Json -Compress | Set-Content -LiteralPath '$ProbeRoot/$Name.result.json' -Encoding UTF8
"@
    $launcher = Join-Path $ProbeRoot "$Name.ps1"
    [IO.File]::WriteAllText($launcher, $body, [Text.UTF8Encoding]::new($false))
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher"
}

function Get-ProbeDecision {
    param([Parameter(Mandatory = $true)][string]$Name)
    $resultFile = Join-Path $ProbeRoot "$Name.result.json"
    if (-not (Test-Path -LiteralPath $resultFile)) { return [ordered]@{ observed = 'no-result'; started = $null } }
    try { return [ordered]@{ observed = (Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json); started = [bool](Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json).started } }
    catch { return [ordered]@{ observed = 'unparsable'; started = $null } }
}

function New-OpenPathProbeSuiteCmd {
    # Runs as the restricted student at logon through the HKLM Run value.
    # Strict app control denies PowerShell script hosts to restricted users, so
    # the runner is a batch command script executed by cmd.exe (permitted by the
    # restricted Exe rules) and staged under the approved runtime root; scripts
    # are likewise only approved from that root.
    param(
        [Parameter(Mandatory = $true)][string]$SuitePath,
        [Parameter(Mandatory = $true)][string]$StudentUserName
    )
    $body = @'
@echo off
setlocal enableextensions
set "ROOT=C:\Users\Public\OpenPathProbes"
echo launch user=%USERNAME% at %DATE% %TIME% >> "%ROOT%\probe-suite.launch.log"
if /I not "%USERNAME%"=="__STUDENT__" (
  > "%ROOT%\probe-suite.skipped-%USERNAME%.txt" echo skipped-as=%USERNAME%
  exit /b 0
)
> "%ROOT%\probe-suite.started" echo started=%USERNAME%

call :ProbeExe allowed-browser "C:\Program Files\Mozilla Firefox\firefox.exe" "-foreground" firefox.exe "" 10
call :ProbeExe allowed-system-exe "%SystemRoot%\System32\charmap.exe" "" charmap.exe "" 4
call :ProbeExe denied-browser "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" "about:blank" msedge.exe "" 4
call :ProbeExe denied-user-exe "%ROOT%\fixture-user-exe.exe" "" fixture-user-exe.exe "" 4
call :ProbeExe packaged-app "%SystemRoot%\System32\calc.exe" "" CalculatorApp.exe Calculator.exe 6

del /q "%ROOT%\script-marker.txt" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\fixture-script.ps1" >"%ROOT%\script-probe.out" 2>&1
set "SCRIPT_EXIT=%ERRORLEVEL%"
set "SCRIPT_MARKER=0"
if exist "%ROOT%\script-marker.txt" set "SCRIPT_MARKER=1"
(
  echo name=denied-script
  echo exit=%SCRIPT_EXIT%
  echo marker=%SCRIPT_MARKER%
) > "%ROOT%\result-denied-script.txt"

set "MSI_EXIT=0"
set "MSI_INSTALLED=0"
set "MSI_POLICY=0"
if not exist "%ROOT%\fixture-package.msi" goto :MsiDone
del /q "%ROOT%\msi.log" >nul 2>&1
msiexec.exe /i "%ROOT%\fixture-package.msi" /qn /norestart /l*v "%ROOT%\msi.log" >nul 2>&1
rem Capture the exit code on its own statement: inside a parenthesized block
rem %ERRORLEVEL% expands when the block is parsed, before msiexec runs.
set "MSI_EXIT=%ERRORLEVEL%"
if "%MSI_EXIT%"=="1625" set "MSI_POLICY=1"
if not exist "%ROOT%\msi.log" goto :MsiDone
findstr /I /C:"1625" "%ROOT%\msi.log" >nul 2>&1 && set "MSI_POLICY=1"
findstr /I /C:"forbidden by system policy" "%ROOT%\msi.log" >nul 2>&1 && set "MSI_POLICY=1"
findstr /I /C:"Installation success or error status: 0" "%ROOT%\msi.log" >nul 2>&1 && set "MSI_INSTALLED=1"
:MsiDone
(
  echo name=denied-msi
  echo exit=%MSI_EXIT%
  echo installed=%MSI_INSTALLED%
  echo policyBlocked=%MSI_POLICY%
) > "%ROOT%\result-denied-msi.txt"

echo done > "%ROOT%\probe-suite.done"
exit /b 0

:ProbeExe
rem %1=name %2=path %3=args %4=primary-image %5=fallback-image %6=grace-seconds
set "P_NAME=%~1"
set "P_PATH=%~2"
set "P_ARGS=%~3"
set "P_IMAGE=%~4"
set "P_FALLBACK=%~5"
set "P_GRACE=%~6"
set "P_STARTED=0"
if not exist "%P_PATH%" goto :ProbeExeResult
start "" /b "%P_PATH%" %P_ARGS% >nul 2>&1
call :ProbeSleep %P_GRACE%
tasklist /FI "IMAGENAME eq %P_IMAGE%" /NH 2>nul | find /I "%P_IMAGE%" >nul && set "P_STARTED=1"
if "%P_STARTED%"=="0" if not "%P_FALLBACK%"=="" (
  tasklist /FI "IMAGENAME eq %P_FALLBACK%" /NH 2>nul | find /I "%P_FALLBACK%" >nul && set "P_STARTED=1"
)
if "%P_STARTED%"=="1" taskkill /IM "%P_IMAGE%" /F >nul 2>&1
:ProbeExeResult
(
  echo name=%P_NAME%
  echo started=%P_STARTED%
) > "%ROOT%\result-%P_NAME%.txt"
exit /b 0

:ProbeSleep
set /a "P_N=%~1-1"
if %P_N% LEQ 0 exit /b 0
ping -n %P_N% 127.0.0.1 >nul
exit /b 0
'@
    $body = $body.Replace('__STUDENT__', $StudentUserName)
    [IO.File]::WriteAllText($SuitePath, $body, [Text.Encoding]::ASCII)
}

function Get-OpenPathProbeResult {
    param([Parameter(Mandatory = $true)][string]$Name)
    $resultFile = Join-Path $ProbeRoot "result-$Name.txt"
    if (-not (Test-Path -LiteralPath $resultFile)) { return $null }
    $detail = [ordered]@{}
    foreach ($line in @(Get-Content -LiteralPath $resultFile -ErrorAction SilentlyContinue)) {
        if ([string]$line -match '^([A-Za-z][A-Za-z0-9_]*)=(.*)$') {
            $detail[$Matches[1]] = ([string]$Matches[2]).Trim()
        }
    }
    if ($detail.Count -eq 0) { return $null }
    return [pscustomobject]$detail
}

function Invoke-OpenPathBoundaryArm {
    param([Parameter(Mandatory = $true)][string]$SuitePath)
    Ensure-OpenPathProbeDirectory
    # host-side fixtures reused by the student suite
    Copy-Item -LiteralPath 'C:\Windows\System32\charmap.exe' -Destination (Join-Path $ProbeRoot 'fixture-user-exe.exe') -Force -ErrorAction SilentlyContinue
    $msiSource = Get-ChildItem -Path 'D:\', 'E:\', 'F:\' -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($msiSource) { Copy-Item -LiteralPath $msiSource.FullName -Destination (Join-Path $ProbeRoot 'fixture-package.msi') -Force -ErrorAction SilentlyContinue }
    else { Add-OpenPathLabFailure 'msi-fixture-source-missing' }
    $marker = Join-Path $ProbeRoot 'script-marker.txt'
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'fixture-script.ps1'), "'ran' | Set-Content -LiteralPath '$marker'", [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath (Join-Path $ProbeRoot 'probe-suite.done') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ProbeRoot 'probe-suite.started') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ProbeRoot 'probe-suite.launch.log') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ProbeRoot 'script-probe.out') -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ProbeRoot -Filter 'result-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ProbeRoot -Filter 'probe-suite.skipped-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    # Strict app control only approves scripts from the OpenPath runtime root
    # (AppControl.psm1 sets the Script allow path to "$OpenPathRoot\*"), so the
    # suite must live there. A user-writable script path -- including the
    # all-users Startup folder -- is denied to restricted users by design.
    $labRoot = Split-Path -Parent $SuitePath
    New-Item -ItemType Directory -Path $labRoot -Force | Out-Null
    New-OpenPathProbeSuiteCmd -SuitePath $SuitePath -StudentUserName $StudentUserName
    Invoke-OpenPathNative -FilePath 'icacls.exe' -Arguments @($labRoot, '/grant', '*S-1-5-32-545:(RX)') | Out-Null
    Invoke-OpenPathNative -FilePath 'icacls.exe' -Arguments @($SuitePath, '/grant', '*S-1-5-32-545:(RX)') | Out-Null
    # Trigger the suite at the student's logon through a Run value: a registry
    # value is not a script, and the process it starts is an approved executable
    # running an approved script path.
    $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $runKey -Name 'OpenPathProbeSuite' -Value ("cmd.exe /c `"$SuitePath`"")
    return [ordered]@{ armed = $true; suite = $SuitePath; runValue = 'OpenPathProbeSuite' }
}

function Invoke-OpenPathBoundaryCollect {
    param([int]$TimeoutSeconds = 360)
    $armState = Read-OpenPathLabState
    $windowStartUtc = $null
    if ($null -ne $armState -and $armState.Contains('probeWindowStartUtc')) {
        try { $windowStartUtc = ([datetime]$armState['probeWindowStartUtc']).ToUniversalTime() } catch { $windowStartUtc = $null }
    }
    $done = Join-Path $ProbeRoot 'probe-suite.done'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $done)) { Start-Sleep -Seconds 5 }
    $suiteCompleted = Test-Path -LiteralPath $done
    if (-not $suiteCompleted) { Add-OpenPathLabFailure 'probe-suite-timeout' }
    try { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'OpenPathProbeSuite' -ErrorAction SilentlyContinue } catch { }
    # Remove any launcher left behind by earlier harness revisions.
    $startupLauncher = Join-Path (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp') 'zz_openpath_probe_suite.cmd'
    Remove-Item -LiteralPath $startupLauncher -Force -ErrorAction SilentlyContinue
    $userStartupLauncher = Join-Path $env:SystemDrive "Users\$StudentUserName\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\zz_openpath_probe_suite.cmd"
    Remove-Item -LiteralPath $userStartupLauncher -Force -ErrorAction SilentlyContinue

    $probes = [ordered]@{}
    function Add-Observation {
        param([string]$Key, [string]$Expected, [string]$Fixture, $Detail)
        $ran = $null
        if ($null -ne $Detail) {
            $normalized = @{}
            foreach ($property in $Detail.PSObject.Properties) {
                $raw = [string]$property.Value
                $normalized[$property.Name] = if ($raw -eq '1' -or $raw -ieq 'true') { $true }
                    elseif ($raw -eq '0' -or $raw -ieq 'false') { $false }
                    else { $property.Value }
            }
            if ($normalized.ContainsKey('started')) { $ran = [bool]$normalized['started'] }
            elseif ($normalized.ContainsKey('marker')) { $ran = [bool]$normalized['marker'] }
            elseif ($normalized.ContainsKey('markerPresent')) { $ran = [bool]$normalized['markerPresent'] }
            elseif ($normalized.ContainsKey('installed')) { $ran = [bool]$normalized['installed'] }
            $Detail = [pscustomobject]$normalized
        }
        $probes[$Key] = [ordered]@{ expected = $Expected; fixture = $Fixture; ran = $ran; observed = $Detail }
    }
    Add-Observation -Key 'allowedBrowser' -Expected 'allowed' -Fixture 'exeAndDll' -Detail (Get-OpenPathProbeResult -Name 'allowed-browser')
    Add-Observation -Key 'allowedSystemExe' -Expected 'allowed' -Fixture 'exeAndDll' -Detail (Get-OpenPathProbeResult -Name 'allowed-system-exe')
    Add-Observation -Key 'deniedBrowser' -Expected 'denied' -Fixture '' -Detail (Get-OpenPathProbeResult -Name 'denied-browser')
    Add-Observation -Key 'deniedUserExe' -Expected 'denied' -Fixture '' -Detail (Get-OpenPathProbeResult -Name 'denied-user-exe')
    Add-Observation -Key 'deniedScript' -Expected 'denied' -Fixture 'msiAndScript' -Detail (Get-OpenPathProbeResult -Name 'denied-script')
    Add-Observation -Key 'deniedMsi' -Expected 'denied' -Fixture 'msiAndScript' -Detail (Get-OpenPathProbeResult -Name 'denied-msi')
    Add-Observation -Key 'packagedApp' -Expected 'denied' -Fixture 'packagedAppExecution' -Detail (Get-OpenPathProbeResult -Name 'packaged-app')

    $fixtures = [ordered]@{
        exeAndDll            = if ($probes.allowedBrowser.ran -eq $true -and $probes.allowedSystemExe.ran -eq $true) { 'passed' } else { 'failed' }
        msiAndScript         = if ($probes.deniedScript.ran -eq $false -and $probes.deniedMsi.ran -eq $false -and $probes.deniedMsi.observed.policyBlocked -eq $true) { 'passed' } else { 'failed' }
        packagedAppExecution = if ($probes.packagedApp.ran -eq $false) { 'passed' } else { 'failed' }
    }
    $criticalDenials = @()
    foreach ($entry in $probes.GetEnumerator()) {
        if ($entry.Value.expected -eq 'allowed' -and $entry.Value.ran -ne $true) { $criticalDenials += [string]$entry.Key }
        if ($entry.Value.expected -eq 'denied' -and ($entry.Value.ran -eq $true -or $null -eq $entry.Value.ran)) { $criticalDenials += [string]$entry.Key }
    }
    # AppLocker events for the probe window make each allow/deny observation
    # traceable to the enforcement decision that produced it.
    $applockerEvents = @()
    foreach ($logName in @('Microsoft-Windows-AppLocker/EXE and DLL', 'Microsoft-Windows-AppLocker/MSI and Script')) {
        try {
            $filter = @{ LogName = $logName }
            if ($null -ne $windowStartUtc) { $filter['StartTime'] = $windowStartUtc }
            Get-WinEvent -FilterHashtable $filter -MaxEvents 300 -ErrorAction Stop |
                Where-Object { [string]$_.Message -match 'OpenPathProbes|probe-suite|FIXTURE-' } |
                ForEach-Object {
                    $applockerEvents += [ordered]@{
                        log      = $logName
                        id       = [int]$_.Id
                        level    = [string]$_.LevelDisplayName
                        timeUtc  = $_.TimeCreated.ToUniversalTime().ToString('o')
                        message  = ([string]$_.Message -replace "`r?`n", ' ').Trim()
                    }
                }
        }
        catch { }
    }

    return [ordered]@{
        suiteCompleted            = $suiteCompleted
        probes                    = $probes
        fixtures                  = $fixtures
        criticalUnexpectedDenials = @($criticalDenials)
        applockerEvents           = @($applockerEvents)
    }
}

function Invoke-OpenPathLabStep {
    switch ("$Phase/$Step") {
        'prepare/install' {
            $state = [ordered]@{
                scenarioId              = $ScenarioId
                startedAtUtc            = [DateTime]::UtcNow.ToString('o')
                policyBeforeSha256      = Get-Sha256Hex -Text (Get-AppLockerXmlText)
                policyBeforeHasOpenPath = Test-PolicyHasOpenPathRules
                initialProfileExisted   = Test-Path -LiteralPath "C:\Users\$StudentUserName"
                catalogApplicationCount = 0
            }
            if (Test-Path -LiteralPath 'C:\OpenPath') { Add-OpenPathLabFailure 'baseline-not-clean-openpath-present' }
            if (Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue) { Add-OpenPathLabFailure 'baseline-not-clean-restricted-group-present' }
            if (-not (Test-Path -LiteralPath $PersonalizedExePath)) { Add-OpenPathLabFailure 'personalized-exe-missing' }
            if (-not (Test-Path -LiteralPath $TemplatePath)) { Add-OpenPathLabFailure 'template-exe-missing' }

            if ($Secret) {
                foreach ($user in @($StudentUserName, $AdminUserName)) {
                    $reset = Invoke-OpenPathNative -FilePath 'net.exe' -Arguments @('user', $user, $Secret)
                    if ($reset.exitCode -ne 0) { Add-OpenPathLabFailure "account-reset-failed-$user" }
                }
            }

            if ($script:Failures.Count -eq 0) {
                $stopwatch = [Diagnostics.Stopwatch]::StartNew()
                $process = Start-Process -FilePath $PersonalizedExePath -ArgumentList '/S' -Wait -PassThru
                $stopwatch.Stop()
                $state.installExitCode = $process.ExitCode
                $state.installSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            }
            $summary = Get-OpenPathStateSummary
            $state.policyAfterSha256 = $summary.policySha256
            $state.config = $summary.config
            $state.groupMembers = $summary.groupMembers
            $state.tasks = $summary.tasks
            $state.uninstaller = $summary.uninstaller
            $state.catalogApplicationCount = $summary.catalogApplicationCount
            $installExit = -1
            $installSecondsValue = 0.0
            if ($state.Contains('installExitCode')) { $installExit = [int]$state.installExitCode }
            if ($state.Contains('installSeconds')) { $installSecondsValue = [double]$state.installSeconds }
            $state.installSummary = [ordered]@{ exitCode = $installExit; seconds = $installSecondsValue }
            $state.summary = $summary
            if (-not $summary.configExists) { Add-OpenPathLabFailure 'install-config-missing' }
            elseif ([string]$summary.config.appControlProfile -ne 'StrictApplicationAllowlist') { Add-OpenPathLabFailure 'install-profile-not-strict' }
            elseif ([string]$summary.config.appControlCommitState -ne 'committed') { Add-OpenPathLabFailure 'install-appcontrol-not-committed' }
            if (-not $summary.uninstaller) { Add-OpenPathLabFailure 'install-uninstaller-missing' }
            if (-not $summary.groupExists) { Add-OpenPathLabFailure 'install-restricted-group-missing' }
            Write-OpenPathLabState -Value $state
            return [ordered]@{ state = $state }
        }
        'observe/admin-autologon' {
            Set-OpenPathAutologon -UserName $AdminUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $AdminUserName }
        }
        'observe/admin-verify' {
            return [ordered]@{ session = Get-InteractiveSession -UserName $AdminUserName }
        }
        'observe/student-autologon' {
            Set-OpenPathAutologon -UserName $StudentUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $StudentUserName }
        }
        'observe/student-verify' {
            $state = Read-OpenPathLabState
            $logons = Get-StudentLogonEvents -Sid (Get-TargetUserSid -UserName $StudentUserName) -AfterUtc ([datetime]$state.startedAtUtc)
            return [ordered]@{
                session                      = Get-InteractiveSession -UserName $StudentUserName
                studentLogons                = @($logons)
                firstStudentInteractiveLogon = [bool](@($logons).Count -gt 0)
            }
        }
        'observe/boundary-arm' {
            $suitePath = 'C:\OpenPath\lab\probe-suite.cmd'
            $arm = Invoke-OpenPathBoundaryArm -SuitePath $suitePath
            $state = Read-OpenPathLabState
            $state.probeWindowStartUtc = (Get-Date).ToUniversalTime().ToString('o')
            Write-OpenPathLabState -Value $state
            return $arm
        }
        'observe/boundary-collect' {
            $probe = Invoke-OpenPathBoundaryCollect
            $state = Read-OpenPathLabState
            $state.preRebootProbes = $probe
            Write-OpenPathLabState -Value $state
            return $probe
        }
        'afterReboot/login-screen' {
            Clear-OpenPathAutologon | Out-Null
            return [ordered]@{ autologon = 'cleared' }
        }
        'afterReboot/admin-autologon' {
            Set-OpenPathAutologon -UserName $AdminUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $AdminUserName }
        }
        'afterReboot/admin-verify' {
            return [ordered]@{ session = Get-InteractiveSession -UserName $AdminUserName }
        }
        'afterReboot/student-autologon' {
            Set-OpenPathAutologon -UserName $StudentUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $StudentUserName }
        }
        'afterReboot/student-verify' {
            return [ordered]@{ session = Get-InteractiveSession -UserName $StudentUserName }
        }
        'afterReboot/boundary-arm' {
            $suitePath = 'C:\OpenPath\lab\probe-suite.cmd'
            $arm = Invoke-OpenPathBoundaryArm -SuitePath $suitePath
            $state = Read-OpenPathLabState
            $state.probeWindowStartUtc = (Get-Date).ToUniversalTime().ToString('o')
            Write-OpenPathLabState -Value $state
            return $arm
        }
        'afterReboot/boundary-collect' {
            $probe = Invoke-OpenPathBoundaryCollect
            $state = Read-OpenPathLabState
            $state.postRebootProbes = $probe
            Write-OpenPathLabState -Value $state
            return $probe
        }
        'cleanup/uninstall' {
            $state = Read-OpenPathLabState
            Clear-OpenPathAutologon | Out-Null
            $state.uninstallFailed = $false
            if (Test-Path -LiteralPath 'C:\OpenPath\Uninstall-OpenPath.ps1') {
                $stopwatch = [Diagnostics.Stopwatch]::StartNew()
                $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\OpenPath\Uninstall-OpenPath.ps1'
                ) -Wait -PassThru
                $stopwatch.Stop()
                $state.uninstallExitCode = $process.ExitCode
                $state.uninstallSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
                if ($process.ExitCode -ne 0) { $state.uninstallFailed = $true; Add-OpenPathLabFailure 'uninstall-nonzero-exit' }
            }
            else { $state.uninstallFailed = $true; Add-OpenPathLabFailure 'uninstall-script-missing' }
            $summary = Get-OpenPathStateSummary
            $state.summary = $summary
            $state.policyAfterUninstallSha256 = $summary.policySha256
            if ($summary.rootExists) { Add-OpenPathLabFailure 'rollback-root-remains' }
            if ($summary.groupExists) { Add-OpenPathLabFailure 'rollback-group-remains' }
            if (@($summary.tasks).Count -gt 0) { Add-OpenPathLabFailure 'rollback-tasks-remain' }
            if ($summary.policyHasOpenPathRules) { Add-OpenPathLabFailure 'rollback-openpath-rules-remain' }
            Write-OpenPathLabState -Value $state
            return [ordered]@{ state = $state }
        }
        'cleanup/verify-clean' {
            $state = Read-OpenPathLabState
            $summary = Get-OpenPathStateSummary
            $clean = (-not $summary.rootExists) -and (-not $summary.groupExists) -and (@($summary.tasks).Count -eq 0) -and (-not $summary.policyHasOpenPathRules)
            if (-not $clean) { Add-OpenPathLabFailure 'cleanup-not-clean' }
            return [ordered]@{
                clean                    = $clean
                summary                  = $summary
                policyEqualsBefore       = ($summary.policySha256 -eq $state.policyBeforeSha256)
                policyHasOpenPathRules   = $summary.policyHasOpenPathRules
            }
        }
        default { throw "desktop-survival-step-invalid: $Phase/$Step" }
    }
}

$result = [ordered]@{
    schemaVersion = 2
    scenarioId    = $ScenarioId
    phase         = $Phase
    step          = $Step
    status        = 'passed'
    failures      = @()
    body          = $null
}
try { $result.body = Invoke-OpenPathLabStep }
catch { $result.status = 'failed'; Add-OpenPathLabFailure "step-error: $($_.Exception.Message)" }
$result.failures = @($script:Failures)
if ($script:Failures.Count -gt 0) { $result.status = 'failed' }
$json = $result | ConvertTo-Json -Depth 24
[IO.File]::WriteAllText($ResultPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output $json
if ($result.status -ne 'passed') { exit 1 }
exit 0
