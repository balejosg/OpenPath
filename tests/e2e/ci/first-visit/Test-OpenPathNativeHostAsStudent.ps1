# Phase 5 B6: run the compiled native host as the restricted student on an
# installed classroom image and collect the literal acceptance evidence.
#
# Executed by the lab transport as SYSTEM through the first-visit harness
# machinery. It:
#   1. writes a framed request file (ping + read actions),
#   2. launches cmd.exe as the student (active console session) with the
#      compiled host and file redirection,
#   3. parses the framed responses,
#   4. proves powershell.exe is still denied for the same student by diffing
#      AppLocker 8004 events,
#   5. records the student's native-host.log initialization line.
#
# Result: C:\OpenPathLab\phase5\b6-result.json (stdout JSON is also printed).
[CmdletBinding()]
param(
    [string]$HostExe = 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.exe',
    [string]$StudentUserName = 'alumno',
    [string]$LauncherPath = 'C:\OpenPathLab\first-visit\student-session-launch.ps1',
    [string]$WorkDir = 'C:\OpenPathLab\phase5'
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$result = [ordered]@{
    schemaVersion = 1
    startedAt     = [DateTime]::UtcNow.ToString('o')
    hostExe       = $HostExe
    hostExists    = (Test-Path -LiteralPath $HostExe -PathType Leaf)
    compiledHostPresent = (Test-Path -LiteralPath $HostExe -PathType Leaf)
    manifestHealthy = $false
    manifestTargetsCompiledHost = $false
    manifestPath  = ''
    launchPath    = ''
    responses     = @()
    pingResponded = $false
    readsResponded = $false
    portalProtocolResponded = $false
    smartAppControl = $null
    hostLogInit   = @()
    hostLogBytes  = 0
    deniedPowershell = $false
    events8004Before = 0
    events8004After = 0
    error         = ''
    skipReason    = ''
}

function Read-NativeHost8004Count {
    $query = @'
$events = wevtutil.exe qe 'Microsoft-Windows-AppLocker/EXE and DLL' "/q:*[System[(EventID=8004)]]" /c:200 /rd:true /f:text 2>$null
$count = 0
foreach ($line in @($events)) { if ($line -match 'WINDOWSPOWERSHELL|POWERSHELL\.EXE') { $count++ } }
$count
'@
    $count = & powershell.exe -NoProfile -Command $query 2>$null | Select-Object -Last 1
    return [int]$count
}

try {
    # Smart App Control state is part of the acceptance evidence: enforcement
    # can block an unsigned locally compiled host.
    try {
        $result.smartAppControl = [int](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop).VerifiedAndReputablePolicyState
    }
    catch { $result.smartAppControl = $null }

    if (-not $result.hostExists) {
        # An older template ships no compiled host; the evidence is still
        # collected (compiledHostPresent=false and the PowerShell deny probe),
        # never a hard probe failure.
        $result.skipReason = 'compiled-host-missing'
    }
    else {
        $manifestPath = Join-Path (Split-Path $HostExe -Parent) 'OpenPath-NativeHost.manifest.json'
        if (Test-Path -LiteralPath $manifestPath) {
            $result.manifestPath = $manifestPath
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $result.manifestHealthy = ([string]$manifest.healthStatus -eq 'healthy')
        }
        $messagingManifest = Join-Path (Split-Path $HostExe -Parent) 'whitelist_native_host.json'
        if (Test-Path -LiteralPath $messagingManifest) {
            $result.launchPath = [string](Get-Content -LiteralPath $messagingManifest -Raw | ConvertFrom-Json).path
            $result.manifestTargetsCompiledHost = [bool]($result.launchPath -and ((Split-Path -Leaf $result.launchPath) -ieq 'OpenPath-NativeHost.exe'))
        }

        # 1) Framed requests.
        $requests = @(
            (@{ action = 'ping'; id = 'b6-1' } | ConvertTo-Json -Compress),
            (@{ action = 'get-hostname' } | ConvertTo-Json -Compress),
            (@{ action = 'get-machine-token' } | ConvertTo-Json -Compress),
            (@{ action = 'get-blocked-paths' } | ConvertTo-Json -Compress),
            (@{ action = 'get-allowed-paths' } | ConvertTo-Json -Compress),
            (@{ action = 'get-blocked-subdomains' } | ConvertTo-Json -Compress),
            (@{ action = 'check'; domains = @('example.com') } | ConvertTo-Json -Compress),
            # Portal recovery protocol check: no trigger host must answer the
            # structured InvalidHost response (never a crash).
            (@{ action = 'recover-captive-portal-navigation'; operation = 'open' } | ConvertTo-Json -Compress)
        )
        $requestPath = Join-Path $WorkDir 'b6-requests.bin'
        $stream = [IO.File]::Open($requestPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        try {
            foreach ($json in $requests) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($json)
                $stream.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
                $stream.Write($bytes, 0, $bytes.Length)
            }
        }
        finally { $stream.Dispose() }

        # 2) Launch as the student through the session launcher (cmd handles the
        #    redirection; AppLocker still allows cmd.exe under %WINDIR%).
        $responsePath = Join-Path $WorkDir 'b6-responses.bin'
        $errorPath = Join-Path $WorkDir 'b6-student-err.txt'
        Remove-Item -LiteralPath $responsePath, $errorPath -Force -ErrorAction SilentlyContinue
        $commandLine = '"C:\Windows\System32\cmd.exe" /c ""' + $HostExe + '" < "' + $requestPath + '" > "' + $responsePath + '" 2> "' + $errorPath + '""'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($commandLine))
        $launch = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LauncherPath -CommandLineBase64 $encoded 2>&1 | Out-String
        $result.launchOutput = $launch.Trim()

        # 3) Poll and parse the framed responses (30 s: the compiled host answers
        #    in milliseconds; a longer wait only burns the observe budget).
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $responsePath -PathType Leaf)) { Start-Sleep -Seconds 2 }
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($responsePath)
            $offset = 0
            while ($offset + 4 -le $bytes.Length) {
                $length = [BitConverter]::ToInt32($bytes, $offset)
                $offset += 4
                if ($length -le 0 -or $offset + $length -gt $bytes.Length) { break }
                $json = [Text.Encoding]::UTF8.GetString($bytes, $offset, $length)
                $offset += $length
                try { $result.responses += ($json | ConvertFrom-Json) } catch { $result.responses += @{ parseError = $json } }
            }
        }
        if (Test-Path -LiteralPath $errorPath) { $result.studentStderr = (Get-Content -LiteralPath $errorPath -Raw) }
        $result.pingResponded = [bool](@($result.responses | Where-Object { $_.action -eq 'ping' -and $_.success -eq $true }).Count -gt 0)
        $result.readsResponded = [bool](@($result.responses | Where-Object { $_.action -in @('get-hostname', 'get-machine-token', 'get-blocked-paths', 'get-allowed-paths', 'get-blocked-subdomains') -and $_.success -eq $true }).Count -ge 5)
        $result.portalProtocolResponded = [bool](@($result.responses | Where-Object { $_.action -eq 'recover-captive-portal-navigation' }).Count -gt 0)
    }

    # 4) powershell.exe must still be denied for the student (new 8004 events).
    $before = Read-NativeHost8004Count
    $psCommandLine = '"C:\Windows\System32\cmd.exe" /c "powershell.exe -NoProfile -Command exit 0"'
    $psEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($psCommandLine))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LauncherPath -CommandLineBase64 $psEncoded 2>&1 | Out-Null
    Start-Sleep -Seconds 10
    $after = Read-NativeHost8004Count
    $result.events8004Before = $before
    $result.events8004After = $after
    $result.deniedPowershell = ($after -gt $before)

    # 5) Student host log.
    $logPath = "C:\Users\$StudentUserName\AppData\Local\OpenPath\native-host.log"
    if (Test-Path -LiteralPath $logPath) {
        $result.hostLogBytes = (Get-Item -LiteralPath $logPath).Length
        $result.hostLogInit = @(Get-Content -LiteralPath $logPath -Tail 400 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'initialization completed' } | Select-Object -Last 3)
    }
}
catch {
    $result.error = [string]$_
}
$result.endedAt = [DateTime]::UtcNow.ToString('o')
$jsonText = ($result | ConvertTo-Json -Depth 10)
[IO.File]::WriteAllText((Join-Path $WorkDir 'b6-result.json'), $jsonText, [Text.UTF8Encoding]::new($false))
Write-Output $jsonText
