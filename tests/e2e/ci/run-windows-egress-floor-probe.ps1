# Windows egress floor lab acceptance probe.
#
# Runs as SYSTEM on a DISPOSABLE lab VM with OpenPath installed and
# outboundEgressFloorEnabled=true (Phase Enforce / AfterReboot), or after
# disable + uninstall (Phase AfterRemoval). It creates a temporary local
# administrator, scheduled tasks, and probe files under Program Files and
# ProgramData; roll the VM back afterwards.
#
# Passwords are used only to register scheduled tasks. They are never written to
# evidence: every captured output passes through Protect-OpenPathEgressProbeText.
[CmdletBinding()]
param(
    [ValidateSet('Enforce', 'AfterReboot', 'AfterRemoval')]
    [string]$Phase = 'Enforce',

    [string]$OpenPathRoot = 'C:\OpenPath',

    [string]$EvidencePath = '',

    [string]$StudentUserName = '',

    [string]$StudentPassword = '',

    # A public IP literal reachable from the lab network (no DNS involved).
    [string]$PublicProbeIp = '',

    # A whitelisted http(s) URL for the Firefox and DNS rows.
    [string]$WhitelistedUrl = '',

    # Evidence JSON from the Enforce phase; AfterRemoval compares against it.
    [string]$BaselineEvidencePath = '',

    # Lab prep: grant the student SeBatchLogonRight so scheduled-task probes can run.
    [switch]$GrantStudentBatchLogon,

    [switch]$RequireFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'EgressFloorProbe.psm1') -Force

$script:ProbeRoot = Join-Path $env:ProgramData 'OpenPathEgressProbe'
$script:ProbeOut = Join-Path $script:ProbeRoot 'out'
$script:ProbeBin = Join-Path $env:ProgramFiles 'OpenPathEgressProbe'
$script:Probes = [System.Collections.Generic.List[object]]::new()
$script:Secrets = [System.Collections.Generic.List[string]]::new()
$script:AdminUserName = 'opegressadmin'
$script:AdminPassword = ''

function Add-OpenPathEgressProbeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'unknown', 'skip', 'manual')][string]$Status,
        [string]$Detail = ''
    )
    $script:Probes.Add([pscustomobject]@{
            name   = $Name
            status = $Status
            detail = (Protect-OpenPathEgressProbeText -Text $Detail -Secrets $script:Secrets.ToArray())
        })
}

function Add-OpenPathEgressConnectivityResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Http', 'Ping')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidateSet('Blocked', 'Allowed')][string]$Expectation,
        [AllowEmptyString()][string]$Output
    )
    $observation = ConvertTo-OpenPathEgressProbeObservation -Kind $Kind -Output $Output
    $status = Get-OpenPathEgressProbeVerdict -Expectation $Expectation -Observation $observation
    Add-OpenPathEgressProbeResult -Name $Name -Status $status -Detail "expected=$Expectation observed=$observation output=$Output"
}

function Invoke-OpenPathEgressProbeAsUser {
    <# Runs a command line as a local user through a one-shot scheduled task; returns its output. #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [int]$TimeoutSeconds = 45
    )

    $outputPath = Join-Path $script:ProbeOut "$Name.txt"
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    $taskName = "OpenPathEgressProbe-$Name"
    $argument = New-OpenPathEgressProbeCmdArgument -CommandLine $CommandLine -OutputPath $outputPath
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\cmd.exe" -Argument $argument
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -User "$env:COMPUTERNAME\$UserName" -Password $Password -RunLevel Limited -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName
    }
    catch {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        return "TASK-ERROR: $($_.Exception.Message)"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $outputPath) -and ((Get-Content -LiteralPath $outputPath -Raw -ErrorAction SilentlyContinue) -match 'exit=')) { break }
        Start-Sleep -Seconds 1
    }
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $outputPath)) {
        $lastResult = if ($info) { '0x{0:X}' -f [int64]$info.LastTaskResult } else { 'n/a' }
        return "NO-OUTPUT lastResult=$lastResult"
    }
    return ((Get-Content -LiteralPath $outputPath) -join ' | ')
}

function Initialize-OpenPathEgressProbeFixtures {
    New-Item -ItemType Directory -Force -Path $script:ProbeOut, $script:ProbeBin | Out-Null
    # Students write probe output and Firefox profiles here (BUILTIN\Users modify).
    & icacls.exe $script:ProbeRoot /grant '*S-1-5-32-545:(OI)(CI)M' /T | Out-Null

    # AppContainer launcher with the internetClient capability, compiled into an
    # administrator-owned Program Files folder so AppLocker lets students run it.
    $launcherPath = Join-Path $script:ProbeBin 'OpenPathAcLaunch.exe'
    if (-not (Test-Path -LiteralPath $launcherPath)) {
        Add-Type -OutputAssembly $launcherPath -OutputType ConsoleApplication -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class OpenPathAcLaunch {
  [DllImport("userenv.dll", CharSet=CharSet.Unicode)] static extern int CreateAppContainerProfile(string n, string d, string desc, IntPtr caps, uint cnt, out IntPtr sid);
  [DllImport("userenv.dll", CharSet=CharSet.Unicode)] static extern int DeriveAppContainerSidFromAppContainerName(string n, out IntPtr sid);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern bool ConvertStringSidToSid(string s, out IntPtr sid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr attr, IntPtr val, IntPtr size, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
  [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
  [StructLayout(LayoutKind.Sequential)] struct SECURITY_CAPABILITIES { public IntPtr AppContainerSid; public IntPtr Capabilities; public uint CapabilityCount; public uint Reserved; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct STARTUPINFO { public int cb; public string r; public string d; public string t; public int x,y,xs,ys,xc,yc,fa,flags; public short sw, cb2; public IntPtr r2, hIn, hOut, hErr; }
  [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO si; public IntPtr attr; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hp, ht; public int pid, tid; }
  public static int Main(string[] args) {
    if (args.Length < 2) { Console.WriteLine("usage: OpenPathAcLaunch <exe> <command line>"); return 2; }
    string name = "openpath.egress.probe";
    IntPtr sid; if (CreateAppContainerProfile(name, name, name, IntPtr.Zero, 0, out sid) != 0) DeriveAppContainerSidFromAppContainerName(name, out sid);
    IntPtr capSid; ConvertStringSidToSid("S-1-15-3-1", out capSid);
    var cap = new SID_AND_ATTRIBUTES { Sid = capSid, Attributes = 4 };
    IntPtr capPtr = Marshal.AllocHGlobal(Marshal.SizeOf(cap)); Marshal.StructureToPtr(cap, capPtr, false);
    var sc = new SECURITY_CAPABILITIES { AppContainerSid = sid, Capabilities = capPtr, CapabilityCount = 1 };
    IntPtr scPtr = Marshal.AllocHGlobal(Marshal.SizeOf(sc)); Marshal.StructureToPtr(sc, scPtr, false);
    IntPtr size = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
    IntPtr list = Marshal.AllocHGlobal(size); InitializeProcThreadAttributeList(list, 1, 0, ref size);
    if (!UpdateProcThreadAttribute(list, 0, (IntPtr)0x20009, scPtr, (IntPtr)Marshal.SizeOf(sc), IntPtr.Zero, IntPtr.Zero)) { Console.WriteLine("ac-attr-fail " + Marshal.GetLastWin32Error()); return 3; }
    var si = new STARTUPINFOEX(); si.si.cb = Marshal.SizeOf(si); si.attr = list;
    si.si.flags = 0x100; si.si.hIn = GetStdHandle(-10); si.si.hOut = GetStdHandle(-11); si.si.hErr = GetStdHandle(-12);
    PROCESS_INFORMATION pi;
    string cmdline = string.Join(" ", args, 1, args.Length - 1);
    if (!CreateProcess(args[0], cmdline, IntPtr.Zero, IntPtr.Zero, true, 0x80000, IntPtr.Zero, null, ref si, out pi)) { Console.WriteLine("ac-create-fail " + Marshal.GetLastWin32Error()); return 4; }
    WaitForSingleObject(pi.hp, 30000); uint code; GetExitCodeProcess(pi.hp, out code);
    Console.WriteLine(" ac-exit=" + code); return 0;
  }
}
'@
    }

    # MSBuild inline task that opens a TCP connection (the classic LOLBin path).
    $projectPath = Join-Path $script:ProbeRoot 'egress-probe.proj'
    Set-Content -LiteralPath $projectPath -Encoding UTF8 -Value @"
<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <UsingTask TaskName="EgressProbe" TaskFactory="CodeTaskFactory" AssemblyFile="`$(MSBuildToolsPath)\Microsoft.Build.Tasks.v4.0.dll">
    <ParameterGroup><Address ParameterType="System.String" Required="true" /></ParameterGroup>
    <Task><Code Type="Fragment" Language="cs"><![CDATA[
      bool ok = false;
      try { using (var c = new System.Net.Sockets.TcpClient()) { ok = c.ConnectAsync(Address, 443).Wait(8000) && c.Connected; } } catch { ok = false; }
      Log.LogMessage(MessageImportance.High, ok ? "http=200" : "http=000");
    ]]></Code></Task>
  </UsingTask>
  <Target Name="Build"><EgressProbe Address="$PublicProbeIp" /></Target>
</Project>
"@
    # AppLocker denies the inbox curl.exe to students by path. A copy under the
    # administrator-owned probe folder runs, so only the egress floor can stop it:
    # the "unlisted program with a network stack" case the floor exists for.
    $studentCurl = Join-Path $script:ProbeBin 'probe-curl.exe'
    Copy-Item -LiteralPath "$env:WINDIR\System32\curl.exe" -Destination $studentCurl -Force
    return [pscustomobject]@{ Launcher = $launcherPath; Project = $projectPath; StudentCurl = $studentCurl }
}

function Grant-OpenPathEgressProbeBatchLogon {
    param([Parameter(Mandatory = $true)][string]$Sid)
    $export = Join-Path $script:ProbeRoot 'rights.inf'
    $import = Join-Path $script:ProbeRoot 'rights-new.inf'
    & secedit.exe /export /cfg $export /areas USER_RIGHTS | Out-Null
    $lines = Add-OpenPathEgressProbeBatchLogonSid -Lines @(Get-Content -LiteralPath $export) -Sid $Sid
    Set-Content -LiteralPath $import -Value $lines -Encoding Unicode
    & secedit.exe /configure /db (Join-Path $script:ProbeRoot 'rights.sdb') /cfg $import /areas USER_RIGHTS | Out-Null
}

function New-OpenPathEgressProbeAdmin {
    $password = 'Op!' + [guid]::NewGuid().ToString('N').Substring(0, 18) + 'aA9'
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    if (Get-LocalUser -Name $script:AdminUserName -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $script:AdminUserName -Password $secure
    }
    else {
        New-LocalUser -Name $script:AdminUserName -Password $secure -PasswordNeverExpires | Out-Null
    }
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $script:AdminUserName -ErrorAction SilentlyContinue
    $script:Secrets.Add($password)
    $script:AdminPassword = $password
}

function Remove-OpenPathEgressProbeAdmin {
    if (Get-LocalUser -Name $script:AdminUserName -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $script:AdminUserName -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathEgressProbeAuditSetting {
    # Only `auditpol /backup` carries the numeric Setting Value column.
    $path = Join-Path $env:TEMP ('openpath-egress-probe-audit-' + [guid]::NewGuid().ToString('N') + '.csv')
    try {
        & auditpol.exe /backup "/file:$path" 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        return ConvertFrom-OpenPathEgressProbeAuditCsv -Lines @(Get-Content -LiteralPath $path)
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathEgressProbeBlockedApps {
    param([Parameter(Mandatory = $true)][datetime]$Since)
    return @(Get-OpenPathEgressFloorBlockedConnections -Since $Since | ForEach-Object { [string]$_.Application })
}

function Import-OpenPathEgressProbeAgentModules {
    Import-Module (Join-Path $OpenPathRoot 'lib\Common.psm1') -Force -Global
    Import-Module (Join-Path $OpenPathRoot 'lib\Firewall.psm1') -Force -Global
}

function Add-OpenPathEgressFloorActiveResults {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore | ForEach-Object { "$($_.Name)=$($_.DefaultOutboundAction)" })
    $allBlock = @($profiles | Where-Object { $_ -notmatch '=Block$' }).Count -eq 0 -and $profiles.Count -gt 0
    Add-OpenPathEgressProbeResult -Name 'Floor active: every profile DefaultOutboundAction=Block' -Status $(if ($allBlock) { 'pass' } else { 'fail' }) -Detail ($profiles -join ' ')

    try {
        $config = Get-Content -LiteralPath (Join-Path $OpenPathRoot 'data\config.json') -Raw | ConvertFrom-Json
        $programs = @(Get-OpenPathEgressFloorStudentProgramsFromConfig -Config $config -OpenPathRoot $OpenPathRoot)
        $drift = Test-OpenPathStudentEgressFloorDrift -StudentPrograms $programs
        Add-OpenPathEgressProbeResult -Name 'Floor drift is false' -Status $(if (-not $drift.Drifted) { 'pass' } else { 'fail' }) -Detail "drifted=$($drift.Drifted) reason=$($drift.Reason)"
    }
    catch {
        Add-OpenPathEgressProbeResult -Name 'Floor drift is false' -Status 'unknown' -Detail $_.Exception.Message
    }
}

function Invoke-OpenPathEgressEnforcePhase {
    param([Parameter(Mandatory = $true)][object]$Evidence)

    if ([string]::IsNullOrWhiteSpace($StudentUserName) -or [string]::IsNullOrWhiteSpace($StudentPassword)) { throw 'egress-probe: -StudentUserName and -StudentPassword are required for Phase Enforce' }
    if ([string]::IsNullOrWhiteSpace($PublicProbeIp) -or [string]::IsNullOrWhiteSpace($WhitelistedUrl)) { throw 'egress-probe: -PublicProbeIp and -WhitelistedUrl are required for Phase Enforce' }

    $auditStatePath = Join-Path $OpenPathRoot 'data\egress-floor-audit-prev.json'
    if (Test-Path -LiteralPath $auditStatePath) {
        $Evidence.auditSettingBeforeFloor = [int]((Get-Content -LiteralPath $auditStatePath -Raw | ConvertFrom-Json).settingValue)
    }
    $outboundStatePath = Join-Path $OpenPathRoot 'data\egress-floor-prev-outbound.json'
    if (Test-Path -LiteralPath $outboundStatePath) {
        $Evidence.outboundBeforeFloor = Get-Content -LiteralPath $outboundStatePath -Raw | ConvertFrom-Json
    }

    $fixtures = Initialize-OpenPathEgressProbeFixtures
    if ($GrantStudentBatchLogon) {
        Grant-OpenPathEgressProbeBatchLogon -Sid ((Get-LocalUser -Name $StudentUserName).SID.Value)
    }
    New-OpenPathEgressProbeAdmin
    Add-OpenPathEgressFloorActiveResults

    $start = Get-Date
    $curl = "$env:WINDIR\System32\curl.exe"
    # Plain http: an IP-literal TLS handshake has no SNI and many CDNs reject it, which
    # would read as "unreachable" even when the connection is allowed.
    $curlArgs = "-s -o NUL -m 8 -w http=%{http_code} http://$PublicProbeIp/"

    # --- student: everything but approved programs is cut off ---
    Add-OpenPathEgressConnectivityResult -Name 'Student unlisted Program Files program (curl copy) to a public IP is blocked' -Kind Http -Expectation Blocked `
        -Output (Invoke-OpenPathEgressProbeAsUser -Name 'student-curl' -UserName $StudentUserName -Password $StudentPassword -CommandLine "`"$($fixtures.StudentCurl)`" $curlArgs")

    $python = Get-ChildItem -Path $env:ProgramFiles, ${env:ProgramFiles(x86)} -Filter 'python.exe' -Recurse -Depth 5 -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($python) {
        $code = "import socket;s=socket.socket();s.settimeout(8);print('http=200' if s.connect_ex(('$PublicProbeIp',443))==0 else 'http=000')"
        Add-OpenPathEgressConnectivityResult -Name 'Student Program Files python.exe is blocked' -Kind Http -Expectation Blocked `
            -Output (Invoke-OpenPathEgressProbeAsUser -Name 'student-python' -UserName $StudentUserName -Password $StudentPassword -CommandLine "`"$($python.FullName)`" -c `"$code`"")
    }
    else {
        Add-OpenPathEgressProbeResult -Name 'Student Program Files python.exe is blocked' -Status (Get-OpenPathEgressProbeMissingFixtureStatus -RequireFixtures:$RequireFixtures) -Detail 'no python.exe under Program Files'
    }

    $msbuild = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe"
    if (Test-Path -LiteralPath $msbuild) {
        Add-OpenPathEgressConnectivityResult -Name 'Student MSBuild inline task is blocked' -Kind Http -Expectation Blocked `
            -Output (Invoke-OpenPathEgressProbeAsUser -Name 'student-msbuild' -UserName $StudentUserName -Password $StudentPassword -CommandLine "`"$msbuild`" /nologo /v:m `"$($fixtures.Project)`"" -TimeoutSeconds 90)
    }
    else {
        Add-OpenPathEgressProbeResult -Name 'Student MSBuild inline task is blocked' -Status (Get-OpenPathEgressProbeMissingFixtureStatus -RequireFixtures:$RequireFixtures) -Detail 'MSBuild.exe not found'
    }

    Add-OpenPathEgressConnectivityResult -Name 'Student AppContainer curl (internetClient) is blocked' -Kind Http -Expectation Blocked `
        -Output (Invoke-OpenPathEgressProbeAsUser -Name 'student-appcontainer' -UserName $StudentUserName -Password $StudentPassword -CommandLine "`"$($fixtures.Launcher)`" `"$($fixtures.StudentCurl)`" curl.exe $curlArgs")

    Add-OpenPathEgressConnectivityResult -Name 'Student ping to the Internet fails' -Kind Ping -Expectation Blocked `
        -Output (Invoke-OpenPathEgressProbeAsUser -Name 'student-ping' -UserName $StudentUserName -Password $StudentPassword -CommandLine "ping -n 2 -w 2000 $PublicProbeIp")

    # --- student Firefox: approved browser keeps working ---
    $firefox = Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'
    if (Test-Path -LiteralPath $firefox) {
        $ffStart = Get-Date
        $png = Join-Path $script:ProbeOut 'firefox-whitelisted.png'
        $profileDir = Join-Path $script:ProbeOut 'ff-profile'
        $output = Invoke-OpenPathEgressProbeAsUser -Name 'student-firefox' -UserName $StudentUserName -Password $StudentPassword -TimeoutSeconds 120 `
            -CommandLine "`"$firefox`" -headless -no-remote -profile `"$profileDir`" --screenshot `"$png`" $WhitelistedUrl"
        $ffBlocked = @(Get-OpenPathEgressProbeBlockedApps -Since $ffStart | Where-Object { $_ -match 'firefox\.exe$' })
        $status = if ($ffBlocked.Count -gt 0) { 'fail' } elseif (Test-Path -LiteralPath $png) { 'pass' } else { 'unknown' }
        Add-OpenPathEgressProbeResult -Name 'Student Firefox loads a whitelisted site' -Status $status -Detail "firefox 5157=$($ffBlocked.Count) screenshot=$(Test-Path -LiteralPath $png) output=$output"
    }
    else {
        Add-OpenPathEgressProbeResult -Name 'Student Firefox loads a whitelisted site' -Status 'fail' -Detail "approved browser missing: $firefox"
    }
    Add-OpenPathEgressProbeResult -Name "Student Firefox shows the blocked screen for http://$PublicProbeIp/" -Status 'manual' -Detail 'Check interactively in a student session (extension 2.1.0+).'
    Add-OpenPathEgressProbeResult -Name 'Student native host runtime-dependency round trip reaches the API' -Status 'manual' -Detail 'Check interactively: visit a page with a new runtime dependency and confirm it is learned.'

    # --- administrator: unaffected, including AppContainer (Store-app) egress ---
    Add-OpenPathEgressConnectivityResult -Name 'Admin curl to a public IP works' -Kind Http -Expectation Allowed `
        -Output (Invoke-OpenPathEgressProbeAsUser -Name 'admin-curl' -UserName $script:AdminUserName -Password $script:AdminPassword -CommandLine "$curl $curlArgs")
    Add-OpenPathEgressConnectivityResult -Name 'Admin AppContainer curl (Store-app path) works' -Kind Http -Expectation Allowed `
        -Output (Invoke-OpenPathEgressProbeAsUser -Name 'admin-appcontainer' -UserName $script:AdminUserName -Password $script:AdminPassword -CommandLine "`"$($fixtures.Launcher)`" $curl curl.exe $curlArgs")

    # --- SYSTEM: Windows Update, time, DNS ---
    $wuStart = Get-Date
    & "$env:WINDIR\System32\UsoClient.exe" StartScan 2>&1 | Out-Null
    Start-Sleep -Seconds 90
    $wuBlocked = @(Get-OpenPathEgressProbeBlockedApps -Since $wuStart | Where-Object { $_ -match '(mousocoreworker|svchost|usoclient)\.exe$' })
    Add-OpenPathEgressProbeResult -Name 'SYSTEM Windows Update scan has no blocked connections' -Status $(if ($wuBlocked.Count -eq 0) { 'pass' } else { 'fail' }) -Detail "blocked=$($wuBlocked -join ',')"

    Start-Service -Name W32Time -ErrorAction SilentlyContinue
    $w32 = (& "$env:WINDIR\System32\w32tm.exe" /resync 2>&1) -join ' '
    Add-OpenPathEgressProbeResult -Name 'SYSTEM w32tm /resync succeeds' -Status $(if ($LASTEXITCODE -eq 0) { 'pass' } else { 'fail' }) -Detail "exit=$LASTEXITCODE $w32"

    $whitelistedHost = ([uri]$WhitelistedUrl).Host
    try {
        $addresses = @(Resolve-DnsName -Name $whitelistedHost -Type A -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] } | ForEach-Object { $_.IPAddress })
        Add-OpenPathEgressProbeResult -Name 'SYSTEM DNS resolves a whitelisted host through Acrylic' -Status $(if ($addresses.Count -gt 0) { 'pass' } else { 'fail' }) -Detail ($addresses -join ',')
    }
    catch {
        Add-OpenPathEgressProbeResult -Name 'SYSTEM DNS resolves a whitelisted host through Acrylic' -Status 'fail' -Detail $_.Exception.Message
    }

    # --- the operator report names the blocked student programs ---
    $report = (& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $OpenPathRoot 'OpenPath.ps1') egress-report 1 2>&1) -join ' | '
    Add-OpenPathEgressProbeResult -Name 'egress-report lists the blocked student curl copy' -Status $(if ($report -match 'probe-curl\.exe') { 'pass' } else { 'fail' }) -Detail $report
    $Evidence.blockedSinceStart = @(Get-OpenPathEgressFloorBlockedConnections -Since $start)
}

function Invoke-OpenPathEgressAfterRemovalPhase {
    param([Parameter(Mandatory = $true)][object]$Evidence)

    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore | ForEach-Object { "$($_.Name)=$($_.DefaultOutboundAction)" })
    $allAllow = @($profiles | Where-Object { $_ -notmatch '=(Allow|NotConfigured)$' }).Count -eq 0 -and $profiles.Count -gt 0
    Add-OpenPathEgressProbeResult -Name 'After removal: every profile DefaultOutboundAction=Allow' -Status $(if ($allAllow) { 'pass' } else { 'fail' }) -Detail ($profiles -join ' ')

    $rules = @(Get-NetFirewallRule -DisplayName '*EgressFloor*' -ErrorAction SilentlyContinue)
    Add-OpenPathEgressProbeResult -Name 'After removal: no EgressFloor rules remain' -Status $(if ($rules.Count -eq 0) { 'pass' } else { 'fail' }) -Detail "count=$($rules.Count)"

    $current = Get-OpenPathEgressProbeAuditSetting
    $Evidence.currentAuditSetting = $current
    if ($BaselineEvidencePath -and (Test-Path -LiteralPath $BaselineEvidencePath)) {
        $baseline = Get-Content -LiteralPath $BaselineEvidencePath -Raw | ConvertFrom-Json
        $before = $baseline.auditSettingBeforeFloor
        $status = if ($null -eq $before -or $null -eq $current) { 'unknown' } elseif ([int]$before -eq [int]$current) { 'pass' } else { 'fail' }
        Add-OpenPathEgressProbeResult -Name 'After removal: Filtering Platform Connection audit is back to its pre-floor value' -Status $status -Detail "before=$before current=$current"
    }
    else {
        Add-OpenPathEgressProbeResult -Name 'After removal: Filtering Platform Connection audit is back to its pre-floor value' -Status 'unknown' -Detail 'no -BaselineEvidencePath from the Enforce phase'
    }
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $env:ProgramData "OpenPathEgressProbe\evidence-$($Phase.ToLowerInvariant())-$((Get-Date).ToString('yyyyMMddTHHmmss')).json"
}
if ($StudentPassword) { $script:Secrets.Add($StudentPassword) }

$evidence = [ordered]@{
    schema                  = 'openpath-egress-floor-probe/v1'
    phase                   = $Phase
    computer                = $env:COMPUTERNAME
    startedAt               = (Get-Date).ToUniversalTime().ToString('o')
    student                 = $StudentUserName
    publicProbeIp           = $PublicProbeIp
    whitelistedUrl          = $WhitelistedUrl
    auditSettingBeforeFloor = $null
    outboundBeforeFloor     = $null
    currentAuditSetting     = $null
    blockedSinceStart       = @()
    probes                  = @()
    status                  = 'fail'
    error                   = $null
}

try {
    if ($Phase -ne 'AfterRemoval') { Import-OpenPathEgressProbeAgentModules }
    switch ($Phase) {
        'Enforce' { Invoke-OpenPathEgressEnforcePhase -Evidence $evidence }
        'AfterReboot' { Add-OpenPathEgressFloorActiveResults }
        'AfterRemoval' { Invoke-OpenPathEgressAfterRemovalPhase -Evidence $evidence }
    }
}
catch {
    $evidence.error = Protect-OpenPathEgressProbeText -Text "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" -Secrets $script:Secrets.ToArray()
}
finally {
    Remove-OpenPathEgressProbeAdmin
    $evidence.probes = @($script:Probes)
    $evidence.status = if ($evidence.error) { 'fail' } else { Get-OpenPathEgressProbeOverallStatus -Probes $evidence.probes }
    $evidence.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    $parent = Split-Path -Parent $EvidencePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $json = Protect-OpenPathEgressProbeText -Text ($evidence | ConvertTo-Json -Depth 8) -Secrets $script:Secrets.ToArray()
    [IO.File]::WriteAllText($EvidencePath, $json, [Text.UTF8Encoding]::new($false))
    foreach ($probe in $script:Probes) { Write-Output ('[{0}] {1}' -f $probe.status.ToUpperInvariant(), $probe.name) }
    Write-Output "status=$($evidence.status) evidence=$EvidencePath"
}

if ($evidence.status -eq 'fail') { exit 1 }
exit 0
