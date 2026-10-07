# In-guest harness for the Phase 3A first-visit lane.
#
# Driven by the Proxmox controller through the QEMU guest agent as SYSTEM. Each
# step prints one JSON result object with `status` (passed/failed) and a
# step-specific payload; the controller writes it as the phase observation.
#
# The harness is site-agnostic: the anchors, dependency hosts and blocked host
# all come from the fixture server plan fetched at runtime (no site-specific
# lists anywhere).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Step,
    [string]$Phase = '',
    [string]$ScenarioId = '',
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$StudentUserName = 'alumno',
    [string]$AdminUserName = 'opadmin',
    [string]$Secret = '',
    [string]$StatePath = '',
    [string]$TemplatePath = '',
    [string]$PersonalizedExePath = '',
    # Phase 3A.2 K1: the live signals the build under test can emit
    # (native-host-log, background-start, diagnostic-batch). The controller
    # derives them from the template source SHA; the warm-up verification only
    # fails on a missing signal when the build actually supports it.
    [string]$Capabilities = '',
    # The controller passes the fixture clock captured just before the warm-up
    # launch (guest steps are separate processes, so step-local state does not
    # survive).
    [string]$FixtureBaselineJson = '',
    # Phase 6.1 C: ISO-8601 UTC scene start (prepare began). Every CodeIntegrity
    # XML query is bounded to the scene from this mark.
    [string]$SceneStartedAt = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# Phase 3A.3: the controller stages these modules next to the harness. The
# verdict and result-serialization contracts live there so the lane tests can
# execute them without a VM. Import-Module (not dot-sourcing): the modules end
# with Export-ModuleMember, which only defines commands in module scope.
$script:WarmupModuleLoaded = $false
$script:ResultModuleLoaded = $false
$script:ModuleLoadError = ''
$warmupModulePath = Join-Path $PSScriptRoot 'FirstVisitWarmup.psm1'
if (Test-Path -LiteralPath $warmupModulePath) {
    try { Import-Module -Name $warmupModulePath -Force -ErrorAction Stop; $script:WarmupModuleLoaded = $true }
    catch { $script:ModuleLoadError = "warmup: $($_.Exception.Message)" }
}
$resultModulePath = Join-Path $PSScriptRoot 'FirstVisitResult.psm1'
if (Test-Path -LiteralPath $resultModulePath) {
    try { Import-Module -Name $resultModulePath -Force -ErrorAction Stop; $script:ResultModuleLoaded = $true }
    catch { $script:ModuleLoadError = (($script:ModuleLoadError + " result: $($_.Exception.Message)").Trim()) }
}
# Phase 6 A/C: the Acrylic INI parser and the real-site canary metrics live in
# tested modules staged next to the harness.
$script:DnsTopologyModuleLoaded = $false
$script:CanaryModuleLoaded = $false
$dnsModulePath = Join-Path $PSScriptRoot 'FirstVisitDnsTopology.psm1'
if (Test-Path -LiteralPath $dnsModulePath) {
    try { Import-Module -Name $dnsModulePath -Force -ErrorAction Stop; $script:DnsTopologyModuleLoaded = $true }
    catch { $script:ModuleLoadError = (($script:ModuleLoadError + " dns: $($_.Exception.Message)").Trim()) }
}
$canaryModulePath = Join-Path $PSScriptRoot 'FirstVisitSiteCanary.psm1'
if (Test-Path -LiteralPath $canaryModulePath) {
    try { Import-Module -Name $canaryModulePath -Force -ErrorAction Stop; $script:CanaryModuleLoaded = $true }
    catch { $script:ModuleLoadError = (($script:ModuleLoadError + " canary: $($_.Exception.Message)").Trim()) }
}
# Phase 6.1 A: the launch-wrapper body builder (one directive per line).
$script:LaunchModuleLoaded = $false
$launchModulePath = Join-Path $PSScriptRoot 'FirstVisitLaunch.psm1'
if (Test-Path -LiteralPath $launchModulePath) {
    try { Import-Module -Name $launchModulePath -Force -ErrorAction Stop; $script:LaunchModuleLoaded = $true }
    catch { $script:ModuleLoadError = (($script:ModuleLoadError + " launch: $($_.Exception.Message)").Trim()) }
}
$OpenPathRoot = 'C:\OpenPath'
$LabRoot = 'C:\OpenPathLab'
$script:VisitRoot = 'C:\OpenPath\lab\first-visit'
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Body = [ordered]@{}

function New-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-FixtureBase {
    $infoFile = 'C:\OpenPathLab\first-visit\fixture.json'
    if (Test-Path -LiteralPath $infoFile) {
        try {
            $info = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
            if ($info.fixtureUrl) { return ([string]$info.fixtureUrl).TrimEnd('/') }
        }
        catch { }
    }
    try {
        $config = Get-Content -LiteralPath "$OpenPathRoot\data\config.json" -Raw -ErrorAction Stop | ConvertFrom-Json
        $base = [string]$config.apiUrl
        if ($base) { return $base.TrimEnd('/') }
    }
    catch { }
    return ''
}

function Get-FixturePlan {
    $base = Get-FixtureBase
    if (-not $base) { throw 'fixture apiUrl missing from the OpenPath config' }
    return (Invoke-WebRequest -UseBasicParsing -Uri "$base/plan.json" -TimeoutSec 30 -ErrorAction Stop | Select-Object -ExpandProperty Content | ConvertFrom-Json)
}

function Get-NativeHostLogPath {
    param([string]$UserName = '')
    # The harness runs as SYSTEM, so %LOCALAPPDATA% is the system profile: the
    # native host runs in the student's session and logs to the student profile.
    if (-not $UserName) { $UserName = $StudentUserName }
    $base = "C:\Users\$UserName\AppData\Local"
    return (Join-Path (Join-Path $base 'OpenPath') 'native-host.log')
}

function Get-FixtureClock {
    # Reads the fixture state on the fixture's own clock, so warm-up deltas
    # (xpi fetch vs launch mark) never mix the guest clock with the host clock.
    param([string]$FixtureBase = '')
    if (-not $FixtureBase) { $FixtureBase = Get-FixtureBase }
    try {
        $state = (Invoke-WebRequest -UseBasicParsing -Uri "$($FixtureBase.TrimEnd('/'))/state.json" -TimeoutSec 15 -ErrorAction Stop).Content | ConvertFrom-Json
        $xpi = $state.xpi
        return [ordered]@{
            serverNow       = [double]$state.serverNow
            xpiCount        = [int]$xpi.count
            xpiLastFetchedAt = [double]$xpi.lastFetchedAt
            xpiLastPath     = [string]$xpi.lastPath
        }
    }
    catch {
        return [ordered]@{ serverNow = 0.0; xpiCount = -1; xpiLastFetchedAt = 0.0; xpiLastPath = ''; error = $_.Exception.Message }
    }
}

function Get-XpiManifestVersion {
    param([Parameter(Mandatory = $true)][string]$XpiPath)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [IO.Compression.ZipFile]::OpenRead($XpiPath)
        try {
            $entry = $zip.GetEntry('manifest.json')
            if (-not $entry) { return '' }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            return [string]$manifest.version
        }
        finally { $zip.Dispose() }
    }
    catch { return '' }
}

function Get-WarmupLiveSignals {
    # Pure parser for the student's native-host.log tail (Phase 3A.2 K1).
    param([AllowNull()][string[]]$Lines = @())
    $hostLines = @($Lines | Where-Object { $_ -match 'initialization completed' })
    $pids = @($hostLines | ForEach-Object { if ($_ -match 'pid=(\d+)') { [string]$Matches[1] } } | Select-Object -Unique)
    $diagnostics = @($Lines | Where-Object { $_ -match 'stage=extension-diagnostic ' })
    $background = @($diagnostics | Where-Object { $_ -match '"kind":"background-start"' })
    $batch = @($Lines | Where-Object { $_ -match 'stage=extension-diagnostic-batch first=true' })
    return [ordered]@{
        hostStarted          = ($hostLines.Count -gt 0)
        hostPids             = $pids
        diagnosticLines      = $diagnostics.Count
        backgroundStart      = ($background.Count -gt 0)
        diagnosticBatchFirst = ($batch.Count -gt 0)
    }
}

function Get-ExtensionEntryFromJson {
    # Pure parser for extensions.json. Never used while Firefox is running:
    # Firefox only flushes the add-on registry on shutdown, so a read against a
    # live browser is a false negative (Phase 3A.2 correction 1).
    param([AllowNull()][string]$JsonText)
    if (-not $JsonText) { return [ordered]@{ parsed = $false; found = $false } }
    try { $json = $JsonText | ConvertFrom-Json -ErrorAction Stop }
    catch { return [ordered]@{ parsed = $false; found = $false } }
    foreach ($addon in @($json.addons)) {
        if ([string]$addon.id -eq 'openpath-block-monitor@openpath') {
            $telemetry = ''
            try { $telemetry = ($addon.installTelemetryInfo | ConvertTo-Json -Compress -Depth 4) } catch { }
            return [ordered]@{
                parsed               = $true
                found                = $true
                id                   = [string]$addon.id
                version              = [string]$addon.version
                active               = [bool]$addon.active
                userDisabled         = [bool]$addon.userDisabled
                appDisabled          = [bool]$addon.appDisabled
                location             = [string]$addon.location
                signedState          = [int]$addon.signedState
                installTelemetryInfo = $telemetry
            }
        }
    }
    return [ordered]@{ parsed = $true; found = $false; addonCount = @($json.addons).Count }
}

function Get-BoundedMozMatches {
    # Phase 5.2 C2: the original Select-String read every *.log* under the
    # shared lab dir and the visit root in full; on a run with accumulated
    # MOZ_LOG files the collect step spent tens of minutes there. This scans
    # only the newest files, only their tail, with a line cap and a hard time
    # budget, so the block can never consume the scene.
    param(
        [string[]]$Directories = @(),
        [string]$Pattern = 'nsHostResolver|nsHttp',
        [int]$MaxFiles = 4,
        [int]$MaxBytesPerFile = 4194304,
        [int]$MaxMatches = 200,
        [int]$BudgetSeconds = 20,
        # Phase 6.1 A: Firefox writes the rotated MOZ_LOG files with the real
        # names generated from MOZ_LOG_FILE; the canary scans its dedicated moz
        # directories without a name filter and records which files it saw.
        [string]$FileFilter = '*.log*'
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($directory in $Directories) {
        if (-not $directory) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter $FileFilter -ErrorAction SilentlyContinue)) {
            $files.Add($file) | Out-Null
        }
    }
    $ordered = @($files | Sort-Object LastWriteTime -Descending)
    $matches = New-Object System.Collections.Generic.List[string]
    $scanned = 0
    $truncated = $false
    foreach ($file in $ordered) {
        if ($matches.Count -ge $MaxMatches -or $stopwatch.Elapsed.TotalSeconds -gt $BudgetSeconds) { $truncated = $true; break }
        if ($scanned -ge $MaxFiles) { $truncated = $true; break }
        $scanned += 1
        foreach ($line in @(Get-FileTailSafe -Path $file.FullName -Lines 4000 -MaxBytes $MaxBytesPerFile)) {
            if ($line -match $Pattern) {
                $matches.Add([string]$line) | Out-Null
                if ($matches.Count -ge $MaxMatches) { break }
            }
        }
    }
    return [ordered]@{
        lines     = @($matches)
        files     = $scanned
        totalFiles = $ordered.Count
        truncated = $truncated
        elapsedMs = [int]$stopwatch.ElapsedMilliseconds
        fileNames = @($ordered | Select-Object -First 12 | ForEach-Object { $_.Name })
    }
}

function Get-FirefoxProcesses {
    return @(Get-Process -Name 'firefox' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $created = ''
                try { $created = $_.StartTime.ToUniversalTime().ToString('o') } catch { }
                [ordered]@{ pid = $_.Id; created = $created }
            })
}

function Get-PreExistingFirefox {
    # Phase 6.1 B: who is already open when the visit launches (pid, creation,
    # parent process and command line via Win32_Process). Recorded for every
    # scenario; the harness closes them for every non-hot scenario so the visit
    # browser is the one the wrapper starts.
    $rows = @()
    try {
        foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='firefox.exe'" -ErrorAction SilentlyContinue)) {
            $created = ''
            try { $created = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o') } catch { $created = [string]$process.CreationDate }
            $parentName = ''
            try {
                $parent = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$([int]$process.ParentProcessId)" -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($parent.Count -gt 0) { $parentName = [string]$parent[0].Name }
            }
            catch { }
            $rows += [ordered]@{
                pid         = [int]$process.ProcessId
                created     = $created
                parentPid   = [int]$process.ParentProcessId
                parentName  = $parentName
                commandLine = ([string]$process.CommandLine)
            }
        }
    }
    catch { }
    return @($rows)
}

function Invoke-Cmd {
    # Small native-command wrapper: returns the exit code and the output lines.
    param([Parameter(Mandatory = $true)][string]$File, [string[]]$Arguments = @())
    try {
        $out = & $File @Arguments 2>&1 | Out-String
        return [ordered]@{ exit = $LASTEXITCODE; out = @($out -split "`r?`n" | Where-Object { $_ -ne '' }) }
    }
    catch {
        return [ordered]@{ exit = -1; out = @($_.Exception.Message) }
    }
}

function Invoke-SacControlRun {
    # Phase 6.1 C: run one control exe as SYSTEM with a hard timeout. A code
    # integrity policy blocks CreateProcess (Win32 error 1260 and friends) —
    # that failure to start is the control signal, not the exit code.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutMs = 10000,
        [int]$ExpectedExitCode = 7
    )
    $started = [DateTime]::UtcNow
    $info = [ordered]@{
        path             = $Path
        started          = $false
        timedOut         = $false
        exitCode         = $null
        expectedExitCode = $ExpectedExitCode
        nativeError      = $null
        error            = ''
        elapsedMs        = -1
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Path
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $info.started = $true
        if (-not $process.WaitForExit($TimeoutMs)) {
            $info.timedOut = $true
            try { $process.Kill() } catch { }
        }
        else {
            try { $info.exitCode = [int]$process.ExitCode } catch { }
        }
    }
    catch {
        $exception = $_.Exception
        if (-not ($exception -is [System.ComponentModel.Win32Exception]) -and ($exception.InnerException -is [System.ComponentModel.Win32Exception])) {
            $exception = $exception.InnerException
        }
        if ($exception -is [System.ComponentModel.Win32Exception]) { $info.nativeError = [int]$exception.NativeErrorCode }
        $info.error = [string]$exception.Message
    }
    $info.elapsedMs = [int](([DateTime]::UtcNow) - $started).TotalMilliseconds
    return $info
}

function Get-CodeIntegrityXmlEvents {
    # Phase 6.1 C: XML keeps FileName, PolicyId and the correlation ids; the
    # text format loses them. Bounded to MaxEvents and ~1 MB per call, oldest
    # first from the scene start.
    param(
        [string]$SinceIso = '',
        [int]$MaxEvents = 200,
        [int]$MaxBytes = 1048576
    )
    $query = '*'
    if ($SinceIso) { $query = "*[System[TimeCreated[@SystemTime>='$SinceIso']]]" }
    $result = Invoke-Cmd 'wevtutil.exe' @('qe', 'Microsoft-Windows-CodeIntegrity/Operational', "/q:$query", "/c:$MaxEvents", '/rd:false', '/f:xml')
    $text = (@($result.out) -join "`r`n")
    $truncated = $false
    if ($text.Length -gt $MaxBytes) {
        $text = $text.Substring(0, $MaxBytes)
        $truncated = $true
    }
    return [ordered]@{
        exit      = $result.exit
        xml       = $text
        truncated = $truncated
        events    = ([regex]::Matches($text, '(?s)<Event\s')).Count
    }
}

function Close-FirefoxProcesses {
    # Graceful close first, then forced; records whether force was needed so the
    # class-boot contract can assert a clean close.
    $before = @(Get-FirefoxProcesses)
    if ($before.Count -eq 0) { return [ordered]@{ present = $false; forced = $false; remaining = 0 } }
    $gracefulExit = (Invoke-Cmd 'taskkill.exe' @('/IM', 'firefox.exe')).exit
    Start-Sleep -Seconds 8
    $remaining = @(Get-FirefoxProcesses)
    $forced = $false
    if ($remaining.Count -gt 0) {
        $forced = $true
        Invoke-Cmd 'taskkill.exe' @('/IM', 'firefox.exe', '/F') | Out-Null
        Start-Sleep -Seconds 5
        $remaining = @(Get-FirefoxProcesses)
    }
    return [ordered]@{ present = $true; gracefulExit = $gracefulExit; forced = $forced; remaining = $remaining.Count }
}

function Get-FirefoxInstallPath {
    foreach ($candidate in @(
            (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return ''
}

function Initialize-VisitRoot {
    # Approved, student-writable root (the Phase 2E controller arms its probe
    # suite from a Users-granted root because the AppControl boundary blocks
    # PowerShell/cmd from user-writable paths).
    $root = $script:VisitRoot
    New-Dir $root
    New-Dir (Join-Path $root 'logs')
    New-Dir (Join-Path $root 'moz')
    Invoke-Cmd 'icacls.exe' @($root, '/grant', '*S-1-5-32-545:(OI)(CI)M') | Out-Null
    return $root
}

function Set-VisitRunKey {
    param([Parameter(Mandatory = $true)][string]$CmdPath)
    Invoke-Cmd 'reg.exe' @('add', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', '/v', 'OpenPathFirstVisit', '/t', 'REG_SZ', '/d', "cmd.exe /c $CmdPath", '/f') | Out-Null
}

function Clear-VisitRunKey {
    Invoke-Cmd 'reg.exe' @('delete', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', '/v', 'OpenPathFirstVisit', '/f') | Out-Null
}

function Get-ConsoleSessionId {
    # The explorer process gives the interactive session id without parsing any
    # localized quser/qwinsta text.
    try {
        $explorer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1)
        if ($explorer.Count -gt 0) { return [string]$explorer[0].SessionId }
    }
    catch { }
    $quser = (Invoke-Cmd 'quser.exe' @()).out
    foreach ($line in @($quser)) {
        if ($line -match [regex]::Escape($StudentUserName)) {
            foreach ($part in @($line.Trim() -split '\s+')) {
                if ($part -match '^\d+$') { return $part }
            }
        }
    }
    $winsta = (Invoke-Cmd 'qwinsta.exe' @()).out
    foreach ($line in @($winsta)) {
        if ($line -match '^\s*console\s+(\d+)') { return $Matches[1] }
    }
    return ''
}

function Get-SessionDiagnostics {
    $quser = @((Invoke-Cmd 'quser.exe' @()).out | Select-Object -First 6)
    $winsta = @((Invoke-Cmd 'qwinsta.exe' @()).out | Select-Object -First 6)
    return [ordered]@{ quser = $quser; qwinsta = $winsta }
}

function Start-VisitRefresh {
    # logon-cycle keeps the persistent host process (and the overlay) warm; the
    # class-boot scenario reboots instead and the host side drives that.
    param([ValidateSet('logoff', 'reboot', 'none')][string]$Mode = 'logoff')
    if ($Mode -eq 'none') { return 'no-refresh' }
    if ($Mode -eq 'reboot') {
        Invoke-Cmd 'shutdown.exe' @('/r', '/t', '2', '/f') | Out-Null
        return 'reboot-requested'
    }
    $sessionId = Get-ConsoleSessionId
    if (-not $sessionId) {
        $script:Body.sessionDiagnostics = Get-SessionDiagnostics
        return 'no-console-session'
    }
    Invoke-Cmd 'logoff.exe' @($sessionId) | Out-Null
    return "logoff-$sessionId"
}

function Write-CleanFirefoxCmd {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Tag,
        # Phase 6 C: MOZ_LOG nsHostResolver capture is enabled ONLY for the
        # real-site canary. Firefox rotates with `rotate:16` (four .0-.3 files);
        # the collect reads the newest files within its own budget.
        [bool]$MozLog = $false
    )
    $firefox = Get-FirefoxInstallPath
    if (-not $firefox) { throw 'firefox.exe not found' }
    Initialize-VisitRoot | Out-Null
    $root = $script:VisitRoot
    $cmdPath = Join-Path $root ("ff-$Tag.cmd")
    if ($script:LaunchModuleLoaded) {
        $body = ConvertTo-OpenPathFirstVisitFirefoxCmdBody -FirefoxPath $firefox -Url $Url -Tag $Tag -Root $root -MozLog $MozLog
    }
    else {
        # Minimal correct fallback: never glue a `set` directive to the launch
        # line (Phase 6.1 A regression guard).
        $lines = @('@echo off', "echo launch %DATE% %TIME% user=%USERNAME% tag=$Tag >> ""$root\logs\launch.log""")
        if ($MozLog) {
            $lines += 'set MOZ_LOG=timestamp,rotate:16,nsHostResolver:5'
            $lines += "set MOZ_LOG_FILE=$root\moz\hostresolver.log"
        }
        $lines += """$firefox"" -new-window ""$Url"" >> ""$root\logs\firefox-$Tag.log"" 2>&1"
        $lines += "echo exit %ERRORLEVEL% >> ""$root\logs\launch.log"""
        $body = (($lines -join "`r`n") + "`r`n")
    }
    [IO.File]::WriteAllText($cmdPath, $body, [Text.UTF8Encoding]::new($false))
    return $cmdPath
}

function Wait-FirefoxProcess {
    param([int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $firefox = Get-FirefoxProcesses
        if ($firefox.Count -gt 0) { return $firefox }
        Start-Sleep -Seconds 3
    }
    return @()
}

function Get-ProfileExtensionState {
    # State signal for the warm-up verification: only call this after Firefox
    # closed (Firefox flushes extensions.json on shutdown).
    $studentProfileRoot = "C:\Users\$StudentUserName\AppData\Roaming\Mozilla\Firefox\Profiles"
    $fallback = [ordered]@{ parsed = $false; found = $false }
    foreach ($profile in @(Get-ChildItem -LiteralPath $studentProfileRoot -Directory -ErrorAction SilentlyContinue)) {
        $extensions = Join-Path $profile.FullName 'extensions.json'
        if (-not (Test-Path -LiteralPath $extensions)) { continue }
        $entry = Get-ExtensionEntryFromJson -JsonText (Get-Content -LiteralPath $extensions -Raw -ErrorAction SilentlyContinue)
        if ($entry.found) {
            $entry['profile'] = $profile.Name
            $entry['extensionsJsonBytes'] = (Get-Item -LiteralPath $extensions).Length
            return $entry
        }
        if (-not $fallback.parsed -and $entry.parsed) {
            $fallback = $entry
            $fallback['profile'] = $profile.Name
            $fallback['extensionsJsonBytes'] = (Get-Item -LiteralPath $extensions).Length
        }
    }
    return $fallback
}

function Enable-BrowserConsoleVisibility {
    # Lab-only: make the background console observable in the Firefox stdout
    # capture (never applied to a product profile by the lane itself).
    $profiles = @(Get-ChildItem 'C:\Users\*\AppData\Roaming\Mozilla\Firefox\Profiles' -Directory -ErrorAction SilentlyContinue)
    foreach ($profile in $profiles) {
        $userJs = Join-Path $profile.FullName 'user.js'
        $lines = @(
            'user_pref("devtools.console.stdout.chrome", true);',
            'user_pref("browser.dom.window.dump.enabled", true);',
            'user_pref("devtools.console.stdout.content", true);'
        )
        Add-Content -LiteralPath $userJs -Value $lines -Encoding ASCII
    }
}

function Get-FileTailSafe {
    # Tail for files another process may have open for append (the cmd wrapper's
    # stdout redirection blocks a plain Get-Content in this lab, Phase 3A.2
    # K0e/red-b). Requests ReadWrite sharing: if the writer denies reads the
    # open fails fast instead of hanging the harness.
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Lines = 12, [int]$MaxBytes = 2097152)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -gt $MaxBytes) { $stream.Seek($stream.Length - $MaxBytes, [IO.SeekOrigin]::Begin) | Out-Null }
            $reader = New-Object IO.StreamReader($stream)
            $content = $reader.ReadToEnd()
            return @($content -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -Last $Lines)
        }
        finally { $stream.Dispose() }
    }
    catch { return @() }
}

function Get-LogTail {
    param([string]$Path, [int]$Tail = 300, [string[]]$Patterns = @())
    # Bounded, share-friendly read: a runaway or append-locked log must never
    # stall the harness inside the guest (Phase 3A.2 K0e/red-b).
    $lines = @(Get-FileTailSafe -Path $Path -Lines 2000)
    if ($Patterns.Count -gt 0) {
        $matched = @()
        foreach ($line in $lines) {
            foreach ($pattern in $Patterns) {
                if ($line -match $pattern) { $matched += $line; break }
            }
        }
        return @($matched | Select-Object -Last $Tail)
    }
    return @($lines | Select-Object -Last $Tail)
}

function Get-FileTextSafe {
    # Whole-file read with ReadWrite sharing: the resident worker keeps its
    # state file open while writing. Returns '' on any failure and never
    # produces the ETS-wrapped strings `Get-Content -Raw` returns (Phase 5.3
    # B1: that wrapper is what the PS 5.1 serializer walked in the collect).
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 262144)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -gt $MaxBytes) { $stream.Seek($stream.Length - $MaxBytes, [IO.SeekOrigin]::Begin) | Out-Null }
            $reader = New-Object IO.StreamReader($stream)
            return $reader.ReadToEnd()
        }
        finally { $stream.Dispose() }
    }
    catch { return '' }
}

function Resolve-Probe {
    param([string]$HostName)
    try {
        $answers = @(Resolve-DnsName -Name $HostName -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' })
        if ($answers.Count -eq 0) { return [ordered]@{ host = $HostName; resolves = $false; ips = @() } }
        return [ordered]@{ host = $HostName; resolves = $true; ips = @($answers | ForEach-Object { $_.IPAddress }) }
    }
    catch {
        return [ordered]@{ host = $HostName; resolves = $false; ips = @() }
    }
}

function Get-OverlayHosts {
    try {
        Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -Global -ErrorAction SilentlyContinue
        # Phase 5.3: Get-OpenPathCapabilityStoragePath without -Name fails
        # ValidateSet and returned an empty list; the data dir is the root.
        $path = Get-OpenPathCapabilityStorageRoot
        $overlayFile = Join-Path $path 'runtime-dependency-overlay.json'
        if (-not (Test-Path -LiteralPath $overlayFile)) { return @() }
        $overlay = Get-Content -LiteralPath $overlayFile -Raw | ConvertFrom-Json
        $hosts = @()
        foreach ($entry in @($overlay.entries)) {
            if ($entry.host) { $hosts += [string]$entry.host }
            elseif ($entry.dependencyHost) { $hosts += [string]$entry.dependencyHost }
        }
        return @($hosts | Sort-Object -Unique)
    }
    catch {
        return @()
    }
}

function Start-InSessionVisit {
    # Launches the managed browser on the student's desktop through the
    # CreateProcessAsUser helper with firefox.exe as the target (the AppControl
    # boundary blocks cmd/powershell from user paths; the managed browser is
    # allowed). The command line travels base64-encoded so quoting can never
    # break it.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Tag = 'visit',
        [bool]$MozLog = $false
    )
    $firefox = Get-FirefoxInstallPath
    if (-not $firefox) { throw 'firefox.exe not found' }
    Initialize-VisitRoot | Out-Null
    $launcher = Join-Path $script:VisitRoot 'student-session-launch.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) {
        $legacy = 'C:\OpenPathLab\first-visit\student-session-launch.ps1'
        if (Test-Path -LiteralPath $legacy) { Copy-Item -LiteralPath $legacy -Destination $launcher -Force }
    }
    if (-not (Test-Path -LiteralPath $launcher)) { throw "session launcher missing at $launcher" }
    # Phase 2E proved this launch shape on the same image: a cmd wrapper (stdout
    # captured, launch/exit markers) started through the session launcher.
    $cmdPath = Write-CleanFirefoxCmd -Url $Url -Tag $Tag -MozLog:$MozLog
    $target = '"C:\Windows\System32\cmd.exe" /c "' + $cmdPath + '"'
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target))
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -CommandLineBase64 $b64 2>&1 | Out-String).Trim()
    Start-Sleep -Seconds 12
    return [ordered]@{ mode = 'session-launcher-cmd'; out = $out; firefox = @(Get-FirefoxProcesses); tag = $Tag; cmd = $cmdPath }
}

function Get-LaunchDiagnostics {
    # Safe subset only: WMI, event-log queries and the AppLocker policy cmdlet
    # hung or broke serialization in the guest during Phase 3A.2. AppLocker
    # events are collected by the separate host-events step (short timeout).
    $session = @((Invoke-Cmd 'quser.exe' @()).out | Select-Object -First 4)
    return [ordered]@{
        session  = @($session)
        runKey   = @((Invoke-Cmd 'reg.exe' @('query', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', '/v', 'OpenPathFirstVisit')).out | Select-Object -First 4)
        root     = @(Get-ChildItem $script:VisitRoot -Recurse -ErrorAction SilentlyContinue | Select-Object -First 12 | ForEach-Object { $_.FullName + ' ' + $_.Length })
        launchOut = @($script:Body.launchOut)
        nativeLog = @(Get-LogTail -Path (Get-NativeHostLogPath) -Tail 6)
    }
}

function Get-StepResultPayload {
    param([string]$Status = 'passed')
    return [ordered]@{
        status    = $Status
        step      = $Step
        phase     = $Phase
        scenario  = $ScenarioId
        failures  = @($script:Failures)
        endedAt   = [DateTime]::UtcNow.ToString('o')
        body      = [ordered]@{ state = $script:Body; session = [string]$script:Body.session }
    }
}

function Save-PartialResult {
    # Written before close/diagnostic operations that could hang or be killed:
    # the controller can always recover the milestone the step reached.
    try {
        $payload = Get-StepResultPayload
        $payload.status = 'partial'
        $payload.savedAt = [DateTime]::UtcNow.ToString('o')
        $json = ''
        if ($script:ResultModuleLoaded) { $json = ConvertTo-FirstVisitResultJson -Payload $payload -PartsDirectory "$ResultPath.parts" }
        if (-not $json) { try { $json = $payload | ConvertTo-Json -Depth 12 -Compress } catch { $json = '' } }
        if ($json) {
            New-Dir (Split-Path -Parent $ResultPath)
            [IO.File]::WriteAllText("$ResultPath.partial.json", $json, [Text.UTF8Encoding]::new($false))
        }
    }
    catch { }
}

function Complete-Step {
    param([string]$Status = 'passed')
    if ($script:Failures.Count -gt 0) { $Status = 'failed' }
    $payload = Get-StepResultPayload -Status $Status
    $json = ''
    if ($script:ResultModuleLoaded) {
        try { $json = ConvertTo-FirstVisitResultJson -Payload $payload -PartsDirectory "$ResultPath.parts" } catch { $json = '' }
    }
    if (-not $json) {
        try { $json = $payload | ConvertTo-Json -Depth 12 -Compress } catch { $json = '' }
    }
    if (-not $json) {
        $json = '{"status":"' + $Status + '","step":"' + $Step + '","failures":["result-serialization-failed"],"body":{"state":{}}}'
    }
    New-Dir (Split-Path -Parent $ResultPath)
    try { [IO.File]::WriteAllText($ResultPath, $json, [Text.UTF8Encoding]::new($false)) } catch { }
    # Markers keep the result unambiguous even when earlier traces contain braces.
    Write-Output '<<<GUEST_RESULT>>>'
    Write-Output $json
    Write-Output '<<<END_GUEST_RESULT>>>'
    if ($Status -eq 'failed') { exit 1 }
    exit 0
}

New-Dir 'C:\OpenPathLab\logs'
New-Dir 'C:\OpenPathLab\first-visit'

try {
switch ($Step) {
    'install' {
        if (-not (Test-Path -LiteralPath $PersonalizedExePath)) { $script:Failures.Add('personalized-exe-missing') }
        else {
            $process = Start-Process -FilePath $PersonalizedExePath -ArgumentList '/S' -PassThru -Wait -WindowStyle Hidden
            $script:Body.installerExit = $process.ExitCode
            # A production-like offline install applies policies and tasks after
            # the silent installer returns; wait for the essential surfaces.
            $deadline = (Get-Date).AddSeconds(900)
            $ready = $false
            $firefoxDeadline = (Get-Date).AddSeconds(900)
            while ((Get-Date) -lt $deadline) {
                $hasScript = Test-Path -LiteralPath "$OpenPathRoot\OpenPath.ps1"
                $hasUninstall = Test-Path -LiteralPath "$OpenPathRoot\Uninstall-OpenPath.ps1"
                $service = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
                if ($hasScript -and $hasUninstall -and $service) { $ready = $true }
                if ($ready -and (Get-FirefoxInstallPath)) { break }
                Start-Sleep -Seconds 10
            }
            # The Firefox managed policy is applied by the agent update flow
            # (configure), so only the install surfaces are required here.
            $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OpenPath-*' } | ForEach-Object { $_.TaskName })
            $script:Body.install = [ordered]@{
                ready            = $ready
                uninstaller      = (Test-Path -LiteralPath "$OpenPathRoot\Uninstall-OpenPath.ps1")
                acrylicService   = [string](Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue).Status
                tasks            = @($tasks)
                firefoxInstalled = [bool](Get-FirefoxInstallPath)
            }
            if (-not $ready) { $script:Failures.Add('install-not-ready') }
            if (-not (Get-FirefoxInstallPath)) { $script:Failures.Add('firefox-missing') }
        }
        Complete-Step
    }
    'configure' {
        $fixture = Get-FixtureBase
        $dnsIp = ''
        $infoFile = 'C:\OpenPathLab\first-visit\fixture.json'
        if (Test-Path -LiteralPath $infoFile) {
            try { $dnsIp = [string](Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json).dnsIp } catch { }
        }
        if (-not $fixture) { $script:Failures.Add('fixture-url-missing'); Complete-Step }
        if (-not $dnsIp) { $script:Failures.Add('fixture-dns-missing'); Complete-Step }
        $configPath = "$OpenPathRoot\data\config.json"
        if (-not (Test-Path -LiteralPath $configPath)) { $script:Failures.Add('config-missing-after-install'); Complete-Step }
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.whitelistUrl = "$fixture/w/firstvisit/whitelist.txt"
        $config.apiUrl = "$fixture/"
        $config | Add-Member -NotePropertyName classroom -NotePropertyValue 'firstvisit' -Force
        $config | Add-Member -NotePropertyName classroomId -NotePropertyValue 'firstvisit' -Force
        $config | Add-Member -NotePropertyName primaryDNS -NotePropertyValue $dnsIp -Force
        $config | Add-Member -NotePropertyName secondaryDNS -NotePropertyValue $dnsIp -Force
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $script:Body.config = [ordered]@{ whitelistUrl = $config.whitelistUrl; apiUrl = $config.apiUrl; primaryDNS = [string]$config.primaryDNS }
        Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -Global -ErrorAction SilentlyContinue
        Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -Global -ErrorAction SilentlyContinue
        $registered = $false
        try {
            $live = Get-OpenPathConfig
            $registered = [bool](Register-OpenPathFirefoxNativeHost -Config $live -ClearWhitelist)
        }
        catch { $script:Failures.Add("native-host-registration: $($_.Exception.Message)") }
        $script:Body.registered = $registered
        $update = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\OpenPath\scripts\Update-OpenPath.ps1') -RedirectStandardOutput 'C:\OpenPathLab\logs\update.out.log' -RedirectStandardError 'C:\OpenPathLab\logs\update.err.log' -PassThru -Wait -WindowStyle Hidden
        $script:Body.updateExit = $update.ExitCode
        $policyPath = 'C:\Program Files\Mozilla Firefox\distribution\policies.json'
        $managed = $false
        $policyDeadline = (Get-Date).AddSeconds(300)
        while ((Get-Date) -lt $policyDeadline) {
            if (Test-Path -LiteralPath $policyPath) {
                try {
                    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
                    $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
                    $managed = ($entry.installation_mode -eq 'force_installed')
                }
                catch { }
            }
            if ($managed) { break }
            Start-Sleep -Seconds 10
        }
        $script:Body.firefoxPolicyForce = $managed
        if (-not $managed) { $script:Failures.Add('firefox-policy-not-force-installed') }
        # Lab-only staging for the fixture: copy the exact XPI the template
        # installer placed in the guest so the fixture can serve it on the
        # managed API path. The harness never rewrites the browser policy: the
        # registry entry, policies.json and distribution/ stay exactly as the
        # product wrote them (Phase 3A.2 K1).
        $xpi = @(Get-ChildItem -Path "$OpenPathRoot\browser-extension" -Recurse -Filter '*openpath*.xpi' -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First 1)
        if ($xpi.Count -gt 0) {
            $labXpi = 'C:\OpenPathLab\first-visit\openpath-firefox-extension.xpi'
            Copy-Item -LiteralPath $xpi[0].FullName -Destination $labXpi -Force
            $xpiHash = (Get-FileHash -LiteralPath $labXpi -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Output ('CONFIGURE xpi-source=' + $xpi[0].FullName + ' bytes=' + [string]$xpi[0].Length + ' sha256=' + $xpiHash)
            Invoke-Cmd 'icacls.exe' @($labXpi, '/grant', '*S-1-5-32-545:R') | Out-Null
            Invoke-Cmd 'icacls.exe' @('C:\OpenPathLab\first-visit', '/grant', '*S-1-5-32-545:(OI)(CI)RX') | Out-Null
            $script:Body.xpiSha256 = $xpiHash
            $script:Body.xpiStaged = $labXpi
        }
        else {
            $script:Failures.Add('firefox-release-xpi-missing')
        }
        # Read-only record of the policy the product wrote: Firefox gives the
        # machine registry precedence over policies.json, and both are the
        # agent's business, never the harness'.
        $policySnapshot = [ordered]@{ installationMode = ''; fileInstallUrl = ''; registryInstallUrl = '' }
        try {
            $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
            $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
            $policySnapshot.installationMode = [string]$entry.installation_mode
            $policySnapshot.fileInstallUrl = [string]$entry.install_url
        }
        catch { }
        try {
            $current = @((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings)
            if ($current.Count -gt 0) {
                $settings = ($current -join "`n") | ConvertFrom-Json
                $entry = $settings.'openpath-block-monitor@openpath'
                if ($entry) { $policySnapshot.registryInstallUrl = [string]$entry.install_url }
            }
        }
        catch { }
        $script:Body.firefoxPolicy = $policySnapshot
        Start-Sleep -Seconds 20
        $plan = Get-FixturePlan
        $script:Body.plan = [ordered]@{
            anchors            = @($plan.anchors.PSObject.Properties | ForEach-Object { $_.Value.host })
            neverLearnable     = [string]$plan.neverLearnable
            unlisted           = [string]$plan.unlisted
            controlDeps        = @($plan.controlDependencies)
            whitelistHosts     = @($plan.whitelistHosts)
        }
        # Direct probe of the DNS fixture (never through Acrylic): if the
        # fixture itself is down the run is INFRA, not a product failure.
        $fixtureDnsOk = $false
        try {
            $probe = @(Resolve-DnsName -Name 'probe.127.0.0.1.sslip.io' -Server $dnsIp -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' })
            $fixtureDnsOk = [bool](@($probe | Where-Object { $_.IPAddress -eq '127.0.0.1' }).Count -gt 0)
        }
        catch { $fixtureDnsOk = $false }
        $script:Body.fixtureDnsOk = $fixtureDnsOk
        if (-not $fixtureDnsOk) { $script:Failures.Add('first-visit-dns-fixture-unavailable') }
        $siteMode = [bool]$plan.siteMode
        $script:Body.siteMode = $siteMode
        $dnsBeforeList = @(Resolve-Probe -HostName ([string]$plan.anchors.a1.host))
        if (-not $siteMode) { $dnsBeforeList += Resolve-Probe -HostName ([string]$plan.anchors.a1.roles.styles) }
        $script:Body.dnsBefore = $dnsBeforeList
        # Phase 5.3 (floor): the floor pre-whitelists every dependency host, so
        # the environment control REQUIRES the dependency to resolve before the
        # visit. The measurement scenarios keep the inverse precondition (a
        # dependency only resolves after the product learns it).
        if ($siteMode) {
            # Phase 6 C: the canary anchor is a real site; the only resolvability
            # precondition is the anchor itself (real DNS through the product).
            if (-not $dnsBeforeList[0].resolves) { $script:Failures.Add('site-anchor-does-not-resolve') }
        }
        elseif ($plan.floorMode) {
            if (-not $script:Body.dnsBefore[0].resolves) { $script:Failures.Add('floor-anchor-does-not-resolve-before-visit') }
            if (-not $script:Body.dnsBefore[1].resolves) { $script:Failures.Add('floor-dependency-does-not-resolve-before-visit') }
        }
        else {
            if (-not $script:Body.dnsBefore[0].resolves) { $script:Failures.Add('anchor-does-not-resolve-before-visit') }
            if ($script:Body.dnsBefore[1].resolves) { $script:Failures.Add('dependency-resolves-before-visit') }
        }
        Complete-Step
    }
    'session' {
        $sessionUser = ''
        $logonAt = ''
        try {
            $explorer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($explorer.Count -gt 0) {
                $owner = Invoke-CimMethod -InputObject $explorer[0] -MethodName GetOwner -ErrorAction SilentlyContinue
                if ($owner -and $owner.User) { $sessionUser = [string]$owner.User }
                $logonAt = ([datetime]$explorer[0].CreationDate).ToString('o')
            }
        }
        catch { }
        $script:Body.session = $sessionUser
        $script:Body.sessionLogonAt = $logonAt
        $script:Body.interactive = ($sessionUser -ieq $StudentUserName)
        if (-not $script:Body.interactive) { $script:Failures.Add('student-session-not-interactive') }
        Complete-Step
    }
    'stage-xpi' {
        # Lab staging only: upload the exact signed XPI the template installer
        # left in the guest to the fixture, which serves it on the managed API
        # path the production agent policy points Firefox at. The harness never
        # touches the browser policy (no registry delete, no policies.json
        # rewrite, no distribution/extensions copy) — Phase 3A.2 K1.
        $labXpi = 'C:\OpenPathLab\first-visit\openpath-firefox-extension.xpi'
        if (-not (Test-Path -LiteralPath $labXpi)) {
            $script:Failures.Add('template-xpi-missing')
            Complete-Step
        }
        $xpiSha = (Get-FileHash -LiteralPath $labXpi -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:Body.xpi = [ordered]@{
            path    = $labXpi
            bytes   = (Get-Item -LiteralPath $labXpi).Length
            sha256  = $xpiSha
            version = Get-XpiManifestVersion -XpiPath $labXpi
        }
        $fixtureBase = Get-FixtureBase
        $upload = ''
        try {
            $uploadResp = Invoke-WebRequest -UseBasicParsing -Uri "$fixtureBase/xpi" -Method Post -InFile $labXpi -ContentType 'application/x-xpinstall' -TimeoutSec 120
            $upload = [string]$uploadResp.StatusCode
        }
        catch { $upload = 'upload-failed: ' + $_.Exception.Message }
        Write-Output ('STAGE-XPI sha256=' + $xpiSha + ' version=' + [string]$script:Body.xpi.version + ' upload=' + $upload)
        $script:Body.xpiUpload = $upload
        if ($upload -notmatch '^2') { $script:Failures.Add('xpi-upload-failed') }
        Complete-Step
    }
    'warmup' {
        $closed = Close-FirefoxProcesses
        $script:Body.closeBeforeWarmup = $closed
        # The policy is the agent's; the fixture already serves the managed API
        # path. Record the fixture clock before the launch window so the later
        # xpi-fetch check uses one clock (the fixture's).
        $script:Body.fixtureBeforeLaunch = Get-FixtureClock
        # Phase 2E proved this launch shape on this image: the browser starts at
        # logon from the cmd wrapper (Run key) and the extension's native host
        # starts with it. The direct in-session launch does not (Phase 3A.2
        # K0b/K0c/K0d), so the warm-up arms the same logon path the class-boot
        # visit uses.
        $cmdPath = Write-CleanFirefoxCmd -Url 'about:blank' -Tag 'warmup'
        Clear-VisitRunKey | Out-Null
        Set-VisitRunKey -CmdPath $cmdPath
        $script:Body.armedAt = [DateTime]::UtcNow.ToString('o')
        $script:Body.arm = [ordered]@{ mode = 'reboot'; cmd = $cmdPath; refresh = (Start-VisitRefresh -Mode 'reboot') }
        Complete-Step
    }
    'visit' {
        $plan = Get-FixturePlan
        $siteMode = [bool]$plan.siteMode
        $anchorHost = [string]$plan.anchors.a1.host
        # Phase 6 C: the canary navigates the real site URL; every other
        # scenario keeps the fixture anchor.
        if ($siteMode -and [string]$plan.siteUrl) { $url = [string]$plan.siteUrl } else { $url = "http://$anchorHost/" }
        $script:Body.anchor = 'a1'
        $script:Body.anchorUrl = $url
        $script:Body.siteMode = $siteMode
        # Phase 6.1 B: record any Firefox already open at visit launch (pid,
        # creation, parent, command line) and close it for every non-hot
        # scenario, so the measured browser is the one this visit starts.
        $preExisting = @(Get-PreExistingFirefox)
        $script:Body.preExistingFirefox = $preExisting
        $closePreExisting = ($ScenarioId -notlike '*hot*')
        if ($closePreExisting -and $preExisting.Count -gt 0) {
            $script:Body.preExistingClose = Close-FirefoxProcesses
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                if (@(Get-FirefoxProcesses).Count -eq 0) { break }
                Start-Sleep -Seconds 2
            }
            $remaining = @(Get-FirefoxProcesses)
            $script:Body.preExistingRemaining = $remaining
            if ($remaining.Count -gt 0) { $script:Failures.Add("pre-existing-firefox-remains:$($remaining.Count)") | Out-Null }
        }
        if ($ScenarioId -like '*class-boot*') {
            # Class boot: arm the wrapper for the next logon (the run key is what
            # starts the browser in this lab) and reboot; the host waits for the
            # new logon and measures the class-boot window.
            $cmdPath = Write-CleanFirefoxCmd -Url $url -Tag 'visit' -MozLog:$siteMode
            Clear-VisitRunKey | Out-Null
            Set-VisitRunKey -CmdPath $cmdPath
            $script:Body.arm = [ordered]@{ mode = 'reboot'; cmd = $cmdPath; refresh = (Start-VisitRefresh -Mode 'reboot') }
        }
        else {
            $launch = Start-InSessionVisit -Url $url -Tag 'visit' -MozLog:$siteMode
            $script:Body.launchOut = $launch.out
            $script:Body.arm = [ordered]@{ mode = 'in-session'; firefox = @($launch.firefox) }
        }
        Complete-Step
    }
    'second-window' {
        # Hot scenario: the same Firefox instance and host process get a second
        # window on anchor 2 after the hot window.
        $plan = Get-FixturePlan
        $url = "http://" + [string]$plan.anchors.a2.host + "/"
        $launch = Start-InSessionVisit -Url $url -Tag 'hot-second'
        $script:Body.anchor = 'a2'
        $script:Body.anchorUrl = $url
        $script:Body.launchOut = $launch.out
        $script:Body.secondLaunch = $launch
        Complete-Step
    }
    'verify-warmup' {
        # Warm-up verification (Phase 3A.2 K1): the managed policy must have
        # installed and activated the extension before any measured visit.
        #   live  (Firefox open): the extension launches the per-user native
        #         host; supported builds also emit background-start and the
        #         diagnostic batch line.
        #   state (after an orderly close): the add-on entry in extensions.json.
        # extensions.json is never read while Firefox runs: Firefox only flushes
        # the add-on registry on shutdown, so a live read is a false negative
        # (Phase 3A.2 correction 1).
        try {
            Write-Output 'VERIFY-WARMUP stage=start'
            $fixtureBase = Get-FixtureBase
            $fixtureBefore = $null
            if ($FixtureBaselineJson) {
                try { $fixtureBefore = $FixtureBaselineJson | ConvertFrom-Json } catch { $fixtureBefore = $null }
            }
            if (-not $fixtureBefore) { $fixtureBefore = $script:Body.fixtureBeforeLaunch }
            $xpiBaseCount = if ($fixtureBefore) { [int]$fixtureBefore.xpiCount } else { -1 }
            $nativeLog = Get-NativeHostLogPath
            $live = $null
            $xpiFetched = $false
            $clock = $null
            $deadline = (Get-Date).AddSeconds(60)
            while ($true) {
                $live = Get-WarmupLiveSignals -Lines @(Get-LogTail -Path $nativeLog -Tail 600)
                $clock = Get-FixtureClock -FixtureBase $fixtureBase
                if ($xpiBaseCount -ge 0 -and [int]$clock.xpiCount -gt $xpiBaseCount) { $xpiFetched = $true }
                if ($live.hostStarted -and ($xpiFetched -or $xpiBaseCount -lt 0)) { break }
                if ((Get-Date) -ge $deadline) { break }
                Start-Sleep -Seconds 5
            }
            # Named reference: seconds from the warm-up arm mark (fixture clock,
            # captured before the logon cycle) to the managed XPI fetch (same
            # fixture clock). Comparing the fetch against "Firefox was seen"
            # produced negative deltas in Phase 3A.2 red-b r1.
            $xpiFetchAfterArmSeconds = -1
            if ($xpiFetched -and $fixtureBefore -and [double]$fixtureBefore.serverNow -gt 0 -and [double]$clock.xpiLastFetchedAt -gt 0) {
                $xpiFetchAfterArmSeconds = [math]::Round([double]$clock.xpiLastFetchedAt - [double]$fixtureBefore.serverNow, 2)
            }
            Write-Output ('VERIFY-WARMUP stage=live hostStarted=' + [string]$live.hostStarted + ' xpiFetched=' + [string]$xpiFetched + ' fetchAfterArm=' + [string]$xpiFetchAfterArmSeconds)
            $script:Body.liveSignals = $live
            $script:Body.xpiFetch = [ordered]@{ fetched = $xpiFetched; afterArmSeconds = $xpiFetchAfterArmSeconds; baseCount = $xpiBaseCount; count = [int]$clock.xpiCount }
            # The close/state read may be interrupted; the milestone so far is
            # already on disk (Phase 3A.3 L3).
            Save-PartialResult
            # Orderly close before the state signal: taskkill /T first, forced
            # /F only when needed (recorded so the contract can assert it).
            $before = @(Get-FirefoxProcesses)
            $gracefulExit = -1
            $forced = $false
            $remaining = @()
            if ($before.Count -gt 0) {
                $gracefulExit = (Invoke-Cmd 'taskkill.exe' @('/IM', 'firefox.exe', '/T')).exit
                Start-Sleep -Seconds 10
                $remaining = @(Get-FirefoxProcesses)
                if ($remaining.Count -gt 0) {
                    $forced = $true
                    Invoke-Cmd 'taskkill.exe' @('/IM', 'firefox.exe', '/F') | Out-Null
                    Start-Sleep -Seconds 5
                    $remaining = @(Get-FirefoxProcesses)
                }
            }
            $script:Body.closeAfterWarmup = [ordered]@{ present = ($before.Count -gt 0); gracefulExit = $gracefulExit; forced = $forced; remaining = $remaining.Count }
            Start-Sleep -Seconds 3
            $state = Get-ProfileExtensionState
            $script:Body.extension = $state
            $expectedVersion = ''
            if ($script:Body.xpi) { $expectedVersion = [string]$script:Body.xpi.version }
            # Preconditions are the lane's (INFRA when failed, decided by the
            # controller). Host signals are product evidence only: the visit
            # always runs and the self-report gives the verdict.
            if ($script:WarmupModuleLoaded) {
                $preconditions = Get-FirstVisitPreconditionVerdict -XpiFetched $xpiFetched -ExtensionState $state -ExpectedVersion $expectedVersion
                $hostVerdict = Get-FirstVisitHostSignalsVerdict -Live $live -Events $null -Capabilities $Capabilities -StudentUserName $StudentUserName
                $script:Body.hostSignals = $hostVerdict.signals
            }
            else {
                $preconditions = [ordered]@{ status = 'failed'; reasons = @('warmup-module-missing') }
                $script:Body.moduleLoadError = $script:ModuleLoadError
                $script:Failures.Add('warmup-module-missing')
            }
            $script:Body.preconditions = $preconditions
            $script:Body.warmupVerification = [ordered]@{
                status       = [string]$preconditions.status
                reasons      = @($preconditions.reasons)
                hostMeasured = [bool]$script:Body.hostSignals
            }
            Write-Output ('VERIFY-WARMUP stage=verdict preconditions=' + [string]$preconditions.status + ' reasons=' + (@($preconditions.reasons) -join ',') + ' hostStarted=' + [string]$live.hostStarted)
            # Lab-only console prefs so the visit browser's console lands in the
            # captured stdout (never policy).
            Enable-BrowserConsoleVisibility
        }
        catch {
            Write-Output ('VERIFY-WARMUP stage=exception ' + $_.Exception.Message)
            $script:Failures.Add('verify-warmup-exception')
        }
        Complete-Step
    }
    'wait-firefox' {
        $firefox = @(Wait-FirefoxProcess -TimeoutSeconds 150)
        if ($firefox.Count -gt 0) { $script:Body.firefoxSeenFixtureClock = (Get-FixtureClock).serverNow }
        $logs = @()
        foreach ($file in @(Get-ChildItem (Join-Path $script:VisitRoot 'logs') -Filter 'firefox-*.log*' -ErrorAction SilentlyContinue)) {
            $logs += @(Get-FileTailSafe -Path $file.FullName -Lines 12)
        }
        if ($firefox.Count -eq 0) { $script:Body.launchDiagnostics = Get-LaunchDiagnostics }
        $script:Body.firefox = $firefox
        $script:Body.launchedAt = if ($firefox.Count -gt 0) { $firefox[0].created } else { '' }
        $script:Body.firefoxLog = @($logs | Select-Object -First 16)
        $script:Body.hostPids = @(Get-LogTail -Path (Get-NativeHostLogPath) -Tail 400 -Patterns @('initialization completed')) | ForEach-Object { if ($_ -match 'pid=(\d+)') { $Matches[1] } }
        if ($firefox.Count -eq 0) { $script:Failures.Add('firefox-did-not-start') }
        Complete-Step
    }
    'security' {
        $plan = Get-FixturePlan
        # Phase 6 C: the real-site canary has no fixture blocked-host probe;
        # the controller never calls this step for site, and if it ever does,
        # fixture-only expectations must not run against a real page.
        if ($plan.siteMode) {
            $script:Body.securitySkipped = 'site-canary'
            Complete-Step
        }
        $overlayHosts = @(Get-OverlayHosts)
        $script:Body.overlayHosts = $overlayHosts
        $expected = @($plan.controlDependencies | Where-Object { $_ -ne $plan.neverLearnable })
        $unexpectedOverlay = @($overlayHosts | Where-Object { $expected -notcontains $_ })
        $missing = @($expected | Where-Object { $overlayHosts -notcontains $_ })
        $script:Body.overlay = [ordered]@{ unexpected = $unexpectedOverlay; missing = $missing }
        if ($unexpectedOverlay.Count -gt 0) { $script:Failures.Add('overlay-has-unexpected-hosts') }
        if ($overlayHosts -contains [string]$plan.neverLearnable) { $script:Failures.Add('never-learnable-host-in-overlay') }
        $never = Resolve-Probe -HostName ([string]$plan.neverLearnable)
        $unlisted = Resolve-Probe -HostName ([string]$plan.unlisted)
        $script:Body.securityDns = [ordered]@{ neverLearnable = $never; unlisted = $unlisted }
        if ($never.resolves) { $script:Failures.Add('never-learnable-host-resolves') }
        if ($unlisted.resolves) { $script:Failures.Add('unlisted-host-resolves') }
        $whitelistMirror = ''
        try { $whitelistMirror = (Get-Content -LiteralPath "$OpenPathRoot\data\whitelist.txt" -Raw) } catch { }
        $script:Body.whitelistSha256 = if ($whitelistMirror) { (Get-FileHash -LiteralPath "$OpenPathRoot\data\whitelist.txt" -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
        # Blocked-screen navigation in the student's desktop (same session).
        $launch = Start-InSessionVisit -Url ("http://" + [string]$plan.unlisted + "/") -Tag 'blocked'
        $script:Body.blockedLaunch = $launch
        Start-Sleep -Seconds 12
        Complete-Step
    }
    'collect' {
        # Phase 5.2 C2: per-block timings travel in the result so the workflow
        # evidence shows exactly where the step spends its time, and the step
        # stays inside its controller budget (<=120 s).
        $collectWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $timings = [ordered]@{}
        $lap = {
            param([string]$Name)
            $timings[$Name] = [int]$collectWatch.ElapsedMilliseconds
            $collectWatch.Restart()
            # Phase 5.2: persist after every block so an interrupted collect
            # names the block it was in (the Phase-5.2 acceptance runs only had
            # the initial partial and could not explain the hang).
            Save-PartialResult
        }
        $script:Body.collect = [ordered]@{ timings = $timings }
        Save-PartialResult
        $addonsLog = @()
        $addonsPath = Join-Path $script:VisitRoot 'moz\addons.log'
        if (Test-Path -LiteralPath $addonsPath) {
            # Share-safe tail: Get-Content -Tail can wait on a log the browser
            # still holds open (the Phase 5.2 collect hang).
            $addonsLog = @(Get-FileTailSafe -Path $addonsPath -Lines 200 | Where-Object { $_ -match 'addon|Addon|install|xpi|policy' } | Select-Object -First 30)
        }
        & $lap 'addonsMs'
        # No extensions.json read here: the authoritative warm-up state signal
        # already ran after an orderly close. Reading it with Firefox open is a
        # false negative (Phase 3A.2 K1).
        $nativeHost = Get-LogTail -Path (Get-NativeHostLogPath) -Tail 1500
        $diagnostics = @($nativeHost | Where-Object { $_ -match 'stage=extension-diagnostic ' })
        $liveCollect = Get-WarmupLiveSignals -Lines $nativeHost
        $reloadReasons = @()
        foreach ($line in @($diagnostics | Where-Object { $_ -match 'kind":"reload-decision' })) {
            $match = [regex]::Match($line, '"reason":"([^"]+)"')
            if ($match.Success) { $reloadReasons += $match.Groups[1].Value }
        }
        & $lap 'nativeHostMs'
        $profiles = @($nativeHost | Where-Object { $_ -match 'stage=startup-profile' })
        & $lap 'profilesMs'
        # Phase 5.2: optional blocks are skipped once the step has spent its
        # budget (the mandatory diagnostics/log reads above already ran).
        $collectBudgetSeconds = 100
        $skippedBlocks = New-Object System.Collections.Generic.List[string]
        $budgetExceeded = { $collectWatch.Elapsed.TotalSeconds -gt $collectBudgetSeconds }
        $openpath = @()
        if (& $budgetExceeded) { $skippedBlocks.Add('openpath') | Out-Null } else { $openpath = Get-LogTail -Path "$OpenPathRoot\data\logs\openpath.log" -Tail 300; & $lap 'openpathMs' }
        $workerState = ''
        if (& $budgetExceeded) { $skippedBlocks.Add('workerState') | Out-Null }
        elseif (Test-Path -LiteralPath "$OpenPathRoot\data\runtime-dependency-worker-state.json") {
            # Phase 5.3 B1: share-safe read without ETS properties.
            $workerState = Get-FileTextSafe -Path "$OpenPathRoot\data\runtime-dependency-worker-state.json"
        }
        & $lap 'workerStateMs'
        # Phase 6 C: the site canary extracts ONLY the learned overlay hosts
        # from the bounded MOZ_LOG scan (and every other scenario keeps the
        # generic nsHostResolver|nsHttp filter).
        $collectPlan = $null
        try { $collectPlan = Get-FixturePlan } catch { }
        $collectSiteMode = [bool]($collectPlan -and $collectPlan.siteMode)
        $earlyOverlayHosts = @()
        if ($collectSiteMode) { $earlyOverlayHosts = @(Get-OverlayHosts) }
        $mozPattern = 'nsHostResolver|nsHttp'
        if ($collectSiteMode -and $earlyOverlayHosts.Count -gt 0) {
            $mozPattern = (@($earlyOverlayHosts) | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
        }
        # Phase 6.1 A: the canary scans its dedicated moz directories without a
        # name filter (Firefox rotates the MOZ_LOG_FILE base into real names) and
        # records the file names it actually saw.
        $mozFilter = if ($collectSiteMode) { '*' } else { '*.log*' }
        $moz = [ordered]@{ lines = @(); files = 0; totalFiles = 0; truncated = $true; fileNames = @() }
        if (& $budgetExceeded) { $skippedBlocks.Add('moz') | Out-Null }
        else { $moz = Get-BoundedMozMatches -Directories @('C:\OpenPathLab\moz', (Join-Path $script:VisitRoot 'moz')) -Pattern $mozPattern -FileFilter $mozFilter; $mozExtract = @($moz.lines) }
        $mozExtract = @($moz.lines)
        & $lap 'mozScanMs'
        $timings.mozFiles = $moz.files
        $timings.mozFilesTotal = $moz.totalFiles
        $timings.mozTruncated = $moz.truncated
        $timings.mozFileNames = @($moz.fileNames)
        $mozDirListing = @()
        foreach ($mozDir in @('C:\OpenPathLab\moz', (Join-Path $script:VisitRoot 'moz'))) {
            try {
                foreach ($entry in @(Get-ChildItem -LiteralPath $mozDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12)) {
                    $mozDirListing += [ordered]@{ dir = $mozDir; name = $entry.Name; bytes = [long]$entry.Length; lastWrite = $entry.LastWriteTimeUtc.ToString('o') }
                }
            }
            catch { }
        }
        $overlayHosts = @()
        if (& $budgetExceeded) { $skippedBlocks.Add('overlayHosts') | Out-Null }
        elseif ($collectSiteMode -and $earlyOverlayHosts.Count -gt 0) { $overlayHosts = $earlyOverlayHosts; & $lap 'overlayHostsMs' }
        else { $overlayHosts = @(Get-OverlayHosts); & $lap 'overlayHostsMs' }
        $whitelistMirror = @()
        if (& $budgetExceeded) { $skippedBlocks.Add('whitelistMirror') | Out-Null } else { $whitelistMirror = @(Get-LogTail -Path "$OpenPathRoot\data\whitelist.txt" -Tail 40); & $lap 'whitelistMs' }
        $firefoxProcesses = @()
        if (& $budgetExceeded) { $skippedBlocks.Add('firefoxProcesses') | Out-Null } else { $firefoxProcesses = @(Get-FirefoxProcesses); & $lap 'processesMs' }
        $timings.skippedBlocks = @($skippedBlocks.ToArray())
        $truncateLine = {
            param([AllowNull()][string]$Line, [int]$Max = 600)
            if ($null -eq $Line) { return '' }
            if ($Line.Length -gt $Max) { return $Line.Substring(0, $Max) + '...' }
            return $Line
        }
        $script:Body.collect.diagnostics = [ordered]@{
            lines                = $diagnostics.Count
            hostStarted          = $liveCollect.hostStarted
            backgroundStart      = $liveCollect.backgroundStart
            batchFirst           = $liveCollect.diagnosticBatchFirst
            transportTransitions = @($diagnostics | Where-Object { $_ -match 'kind":"transport' }).Count
            holdOutcomes         = @($diagnostics | Where-Object { $_ -match 'kind":"hold-outcome' }).Count
            reloadDecisions      = @($diagnostics | Where-Object { $_ -match 'kind":"reload-decision' }).Count
            reloadReasons        = $reloadReasons
            # Phase 5.2: the payload is bounded so the PS 5.1 serializer can
            # never wedge on a big diagnostic set (the acceptance runs spent
            # >500 s serializing an unbounded collect body).
            all                  = @($diagnostics | Select-Object -First 120 | ForEach-Object { & $truncateLine $_ 600 })
        }
        $script:Body.collect.addonsLog = @($addonsLog | Select-Object -First 30 | ForEach-Object { & $truncateLine $_ 300 })
        $script:Body.collect.mozExtract = @($mozExtract | Select-Object -First 200 | ForEach-Object { & $truncateLine $_ 300 })
        # Phase 6 C: the canary needs every hold outcome (the `all` cap would
        # cut a busy real page) plus the navigation/reload decisions, and it
        # records which MOZ filter and hosts were tracked.
        $script:Body.collect.holds = @($diagnostics | Where-Object { $_ -match 'kind":"hold"' }).Count
        $script:Body.collect.canaryDiagnostics = @($diagnostics | Where-Object { $_ -match 'kind":"(hold|hold-outcome|navigation|reload-decision)"' } | Select-Object -First 500 | ForEach-Object { & $truncateLine $_ 500 })
        $script:Body.collect.mozPattern = $mozPattern
        $script:Body.collect.mozHostsTracked = @($earlyOverlayHosts | Select-Object -First 100)
        $script:Body.collect.mozFileNames = @($moz.fileNames | Select-Object -First 12)
        $script:Body.collect.mozDirListing = @($mozDirListing | Select-Object -First 24)
        $script:Body.collect.diagnosticLines = $diagnostics.Count
        $script:Body.collect.diagnosticSample = @($diagnostics | Select-Object -First 20 | ForEach-Object { & $truncateLine $_ 600 })
        $script:Body.collect.startupProfiles = @($profiles | Select-Object -Last 8 | ForEach-Object { & $truncateLine $_ 600 })
        $script:Body.collect.nativeHostTail = @($nativeHost | Select-Object -Last 40 | ForEach-Object { & $truncateLine $_ 600 })
        $script:Body.collect.openpathTail = @($openpath | Select-Object -Last 60 | ForEach-Object { & $truncateLine $_ 600 })
        if ($workerState -and $workerState.Length -gt 16384) { $workerState = $workerState.Substring(0, 16384) + '...truncated' }
        $script:Body.collect.workerState = $workerState
        $script:Body.collect.overlayHosts = @($overlayHosts | Select-Object -First 100)
        $script:Body.collect.whitelistMirror = @($whitelistMirror | Select-Object -First 40 | ForEach-Object { & $truncateLine $_ 160 })
        $script:Body.collect.firefoxProcesses = @($firefoxProcesses | Select-Object -First 20)
        # Phase 5.3 B1: name the key if a single value ever wedges the PS 5.1
        # serializer again. Every probe saves a partial naming the key in
        # progress, and the probe is bounded so the step still completes.
        $serializeKeyMs = [ordered]@{}
        $keyProbeWatch = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($key in @('diagnostics', 'canaryDiagnostics', 'addonsLog', 'mozExtract', 'diagnosticSample', 'startupProfiles', 'nativeHostTail', 'openpathTail', 'workerState', 'overlayHosts', 'whitelistMirror', 'firefoxProcesses')) {
            if (-not $script:Body.collect.Contains($key)) { continue }
            if ($keyProbeWatch.Elapsed.TotalSeconds -gt 30) { $serializeKeyMs['budgetExceeded'] = $true; break }
            $script:Body.collect.timings.serializeKeyCurrent = $key
            Save-PartialResult
            $keyWatch = [System.Diagnostics.Stopwatch]::StartNew()
            try { $null = ($script:Body.collect[$key] | ConvertTo-Json -Depth 12 -Compress) } catch { }
            $keyWatch.Stop()
            $serializeKeyMs[$key] = [int]$keyWatch.ElapsedMilliseconds
        }
        $serializeKeyMs['probeMs'] = [int]$keyProbeWatch.ElapsedMilliseconds
        $script:Body.collect.timings.serializeKeyMs = $serializeKeyMs
        # Time one reduced serialization of the payload; the real serialization
        # in Complete-Step then runs with the measured value included.
        $pending = Get-StepResultPayload
        $serializeWatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($script:ResultModuleLoaded) {
            try { $null = ConvertTo-FirstVisitResultJson -Payload $pending -MaxInlineBytes 0 } catch { }
        }
        $serializeWatch.Stop()
        & $lap 'serializationMs'
        $timings.serializationMs = [int]$serializeWatch.ElapsedMilliseconds
        $timings.totalMs = [int](($timings.Values | Where-Object { $_ -is [int] -or $_ -is [long] -or $_ -is [double] } | Measure-Object -Sum).Sum)
        $script:Body.session = $script:Body.session
        Complete-Step
    }
    'host-probe' {
        # Phase 5.2 E2: the student probe runs inside every scene and produces
        # the B6 evidence from the workflow itself: the compiled .exe launched
        # as the restricted student, the still-denied powershell.exe (new 8004)
        # and the student's native-host log line. Older templates without the
        # exe record compiledHostPresent=false plus the deny evidence instead.
        # Phase 5.3 B6: the step is failed when the probe result or the deny
        # evidence is missing; it never reports passed without them.
        Save-PartialResult
        $probeScript = Join-Path $PSScriptRoot 'Test-OpenPathNativeHostAsStudent.ps1'
        $probeWork = 'C:\OpenPathLab\phase5\b6'
        $probeResult = $null
        $probeError = ''
        $probeOutput = ''
        if (-not (Test-Path -LiteralPath $probeScript)) {
            $probeError = 'student-host-probe-script-missing'
        }
        else {
            try {
                $launcherPath = 'C:\OpenPathLab\first-visit\student-session-launch.ps1'
                $probeOutput = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -HostExe 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.exe' -StudentUserName $StudentUserName -LauncherPath $launcherPath -WorkDir $probeWork 2>&1 | Out-String).Trim()
                $probeResultPath = Join-Path $probeWork 'b6-result.json'
                if (Test-Path -LiteralPath $probeResultPath) {
                    $probeResult = Get-Content -LiteralPath $probeResultPath -Raw | ConvertFrom-Json
                }
                if (-not $probeResult) { $probeError = 'student-host-probe-result-missing' }
            }
            catch {
                $probeError = [string]$_.Exception.Message
            }
        }
        $script:Body.hostProbe = [ordered]@{
            scriptFound = (Test-Path -LiteralPath $probeScript)
            error       = $probeError
            result      = $probeResult
            raw         = if ($probeError) { $probeOutput.Substring(0, [Math]::Min(2000, $probeOutput.Length)) } else { '' }
        }
        if (-not $probeResult) {
            $script:Failures.Add('student-host-probe-result-missing') | Out-Null
        }
        else {
            if ($probeResult.error) { $script:Failures.Add('student-host-probe-error') | Out-Null }
            if ($probeResult.events8004Measured -ne $true) { $script:Failures.Add('student-host-probe-8004-unmeasured') | Out-Null }
            elseif ($probeResult.deniedPowershell -ne $true) { $script:Failures.Add('student-host-probe-powershell-not-denied') | Out-Null }
        }
        Complete-Step
    }
    'host-signals' {
        # Product evidence after the warm-up logon: what the native host did.
        # File/registry/native-command reads only; the controller runs this with
        # a short timeout and never lets its failure abort the run.
        Save-PartialResult
        # Phase 5.3 B5: DNS topology evidence. Where does the guest resolve the
        # fixture names through, and which upstreams does Acrylic use? The
        # controller correlates the fresh-probe name with the host dns.jsonl.
        $dnsTopology = [ordered]@{}
        try {
            $dnsTopology.adapters = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ interface = [string]$_.InterfaceAlias; servers = @($_.ServerAddresses) } })
        }
        catch { }
        try {
            $acrylicIni = ''
            foreach ($candidate in @(
                    (Join-Path ${env:ProgramFiles(x86)} 'Acrylic DNS Proxy\AcrylicConfiguration.ini'),
                    (Join-Path $env:ProgramFiles 'Acrylic DNS Proxy\AcrylicConfiguration.ini')
                )) {
                if ($candidate -and (Test-Path -LiteralPath $candidate)) { $acrylicIni = $candidate; break }
            }
            if (-not $acrylicIni) {
                try {
                    $cfg = Get-Content -LiteralPath "$OpenPathRoot\data\config.json" -Raw | ConvertFrom-Json
                    $configured = [string]$cfg.acrylicPath
                    if ($configured -and (Test-Path -LiteralPath (Join-Path $configured 'AcrylicConfiguration.ini'))) { $acrylicIni = Join-Path $configured 'AcrylicConfiguration.ini' }
                }
                catch { }
            }
            if ($acrylicIni) {
                $dnsTopology.acrylicIniPath = $acrylicIni
                # Phase 6 A: the parse lives in the tested FirstVisitDnsTopology
                # module; the value is captured before any other -match, so the
                # literal upstreams and masks reach the evidence.
                if ($script:DnsTopologyModuleLoaded) {
                    $dnsTopology.acrylic = ConvertFrom-OpenPathAcrylicIniText -Text (Get-FileTextSafe -Path $acrylicIni -MaxBytes 262144)
                }
                else {
                    $dnsTopology.acrylic = [ordered]@{}
                    $dnsTopology.acrylicError = 'dns-topology-module-missing'
                }
                $acrylicHostsPath = Join-Path (Split-Path $acrylicIni -Parent) 'AcrylicHosts.txt'
                if (Test-Path -LiteralPath $acrylicHostsPath) {
                    $acrylicHostsText = Get-FileTextSafe -Path $acrylicHostsPath -MaxBytes 262144
                    # Non-secret preview only: the whitelist hosts are lab fixtures.
                    $dnsTopology.acrylicHostsPreview = @($acrylicHostsText -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 20)
                    $dnsTopology.anchorStaticHostLines = @()  # filled after the plan is read
                    $dnsTopology.acrylicHostsAllLines = @($acrylicHostsText -split "`r?`n" | Where-Object { $_ -ne '' })
                }
            }
        }
        catch { }
        try {
            $dnsIp = ''
            $infoFile = 'C:\OpenPathLab\first-visit\fixture.json'
            if (Test-Path -LiteralPath $infoFile) { try { $dnsIp = [string](Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json).dnsIp } catch { } }
            $planForDns = Get-FixturePlan
            $anchorHost = [string]$planForDns.anchors.a1.host
            $dnsTopology.anchorProbe = [ordered]@{ host = $anchorHost; result = (Resolve-Probe -HostName $anchorHost) }
            # Phase 5.3 P5: the anchor resolves through the static AcrylicHosts
            # entry (embedded IPv4); search the WHOLE hosts file (and the OS
            # hosts file) instead of a short preview.
            if ($dnsTopology.Contains('acrylicHostsAllLines')) {
                $dnsTopology.anchorStaticHostLine = @($dnsTopology.acrylicHostsAllLines | Where-Object { $_ -match [regex]::Escape($anchorHost) } | Select-Object -First 3)
            }
            $osHostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            if (Test-Path -LiteralPath $osHostsPath) {
                $osHostsText = Get-FileTextSafe -Path $osHostsPath -MaxBytes 131072
                $dnsTopology.osHostsAnchorLine = @($osHostsText -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($anchorHost) } | Select-Object -First 3)
            }
            if ($dnsIp) {
                $correlateHost = 'correlate-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.' + $dnsIp + '.sslip.io'
                $dnsTopology.correlateHost = $correlateHost
                # Direct query to the fixture (the only path that must appear in
                # dns.jsonl); the system-resolver result is recorded separately
                # and is expected to stay unresolved (not in the affinity mask).
                $direct = [ordered]@{ resolves = $false; ips = @() }
                try {
                    $answers = @(Resolve-DnsName -Name $correlateHost -Server $dnsIp -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' })
                    if ($answers.Count -gt 0) { $direct.resolves = $true; $direct.ips = @($answers | ForEach-Object { $_.IPAddress }) }
                }
                catch { $direct.error = [string]$_ }
                $dnsTopology.correlateDirect = $direct
                $dnsTopology.correlateSystem = Resolve-Probe -HostName $correlateHost
            }
        }
        catch { $dnsTopology.correlateError = [string]$_ }
        $script:Body.dnsTopology = $dnsTopology
        $nativeLog = Get-NativeHostLogPath
        $lines = @(Get-LogTail -Path $nativeLog -Tail 1200)
        $live = Get-WarmupLiveSignals -Lines $lines
        $initLine = @($lines | Where-Object { $_ -match 'initialization completed' } | Select-Object -First 1)
        $appControl = [ordered]@{}
        try {
            $cfg = Get-Content -LiteralPath "$OpenPathRoot\data\config.json" -Raw -ErrorAction Stop | ConvertFrom-Json
            $appControl = [ordered]@{
                enableNonAdminAppControl = $cfg.enableNonAdminAppControl
                nonAdminAppControlMode   = $cfg.nonAdminAppControlMode
                appControlProfile        = $cfg.appControlProfile
                appControlCommitState    = $cfg.appControlCommitState
            }
        }
        catch { $appControl = [ordered]@{ error = $_.Exception.Message } }
        $group = @((Invoke-Cmd 'net.exe' @('localgroup', 'OpenPath-Restricted')).out | Select-Object -First 30)
        $manifestPath = ''
        foreach ($hive in @('HKLM:', 'HKCU:')) {
            try {
                $key = "$hive\SOFTWARE\Mozilla\NativeMessagingHosts\whitelist_native_host"
                if (Test-Path $key) {
                    $value = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
                    if ($value) { $manifestPath = [string]$value; break }
                }
            }
            catch { }
        }
        $wrapperPath = ''
        if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) {
            try { $wrapperPath = [string](Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).path } catch { }
        }
        $script:Body.hostSignals = [ordered]@{
            at                   = [DateTime]::UtcNow.ToString('o')
            hostStarted          = $live.hostStarted
            hostPids             = $live.hostPids
            firstInitLine        = [string]($initLine | Select-Object -First 1)
            diagnosticLines      = $live.diagnosticLines
            backgroundStart      = $live.backgroundStart
            diagnosticBatchFirst = $live.diagnosticBatchFirst
            nativeLogPath        = $nativeLog
            nativeLogExists      = (Test-Path -LiteralPath $nativeLog)
            nativeLogBytes       = if (Test-Path -LiteralPath $nativeLog) { (Get-Item -LiteralPath $nativeLog).Length } else { 0 }
            appControl           = $appControl
            restrictedGroup      = $group
            manifestPath         = $manifestPath
            wrapperPath          = $wrapperPath
        }
        Complete-Step
    }
    'host-events' {
        # AppLocker + CodeIntegrity events, deliberately a separate short call:
        # this is the only evidence available for builds without the per-user
        # native host log, and Phase 6 needs the SAC / Code Integrity signals.
        Save-PartialResult
        $languageMode = [string]$ExecutionContext.SessionState.LanguageMode
        $ciQuery = '*[System[(EventID=3033 or EventID=3034 or EventID=3076 or EventID=3077 or EventID=3089)]]'
        if ($languageMode -ne 'FullLanguage') {
            # Phase 6 B: under ConstrainedLanguage the harness can still run
            # native commands and write cmdlets; collect the minimum (state,
            # events with wevtutil, openpath.log with type) and document it.
            $minimal = @{}
            $minimal.status = 'passed'
            $minimal.step = $Step
            $minimal.phase = $Phase
            $minimal.scenario = $ScenarioId
            $minimal.languageMode = $languageMode
            $minimal.constrainedLanguage = $true
            $ci = Invoke-Cmd 'wevtutil.exe' @('qe', 'Microsoft-Windows-CodeIntegrity/Operational', "/q:$ciQuery", '/c:40', '/rd:true', '/f:text')
            $minimal.codeIntegrityExit = $ci.exit
            $minimal.codeIntegrityLineCount = @($ci.out).Count
            $minimal.codeIntegrityLines = @($ci.out | Select-Object -First 200)
            $openpathConstrained = Invoke-Cmd 'cmd.exe' @('/c', 'type C:\OpenPath\data\logs\openpath.log 2>nul')
            $minimal.openpathLineCount = @($openpathConstrained.out).Count
            $minimal.openpathTail = @($openpathConstrained.out | Select-Object -Last 30)
            $minimalJson = $minimal | ConvertTo-Json -Depth 6 -Compress
            Set-Content -LiteralPath $ResultPath -Value $minimalJson -Encoding UTF8 -ErrorAction SilentlyContinue
            Write-Output '<<<GUEST_RESULT>>>'
            Write-Output $minimalJson
            Write-Output '<<<END_GUEST_RESULT>>>'
            exit 0
        }
        $events = [ordered]@{ at = [DateTime]::UtcNow.ToString('o'); languageMode = $languageMode }
        foreach ($pair in @(
                @{ Key = 'events8004'; Log = 'Microsoft-Windows-AppLocker/EXE and DLL'; Id = 8004 },
                @{ Key = 'events8007'; Log = 'Microsoft-Windows-AppLocker/MSI and Script'; Id = 8007 }
            )) {
            $result = Invoke-Cmd 'wevtutil.exe' @('qe', $pair.Log, "/q:*[System[(EventID=$($pair.Id))]]", '/c:40', '/rd:true', '/f:text')
            $list = New-Object System.Collections.Generic.List[string]
            foreach ($line in @($result.out)) {
                $list.Add([string]$line) | Out-Null
                if ($list.Count -ge 400) { break }
            }
            $events[$pair.Key] = @($list)
            $events["exit$($pair.Id)"] = $result.exit
        }
        # Phase 6.1 C: Code Integrity XML from the scene start (all ids; keeps
        # file, policy and correlation ids). Bounded to 200 events / ~512 KB.
        $ciXml = Get-CodeIntegrityXmlEvents -SinceIso $SceneStartedAt -MaxEvents 200 -MaxBytes 524288
        $events.codeIntegrityXml = $ciXml
        $events.codeIntegrityExit = $ciXml.exit
        $events.sceneStartedAt = $SceneStartedAt
        # Phase 6 B: constrained-language errors in the agent log (bounded).
        $events.openpathLanguageErrors = @(Get-LogTail -Path "$OpenPathRoot\data\logs\openpath.log" -Tail 400 -Patterns @('ConstrainedLanguage', 'constrained language', 'language mode') | Select-Object -Last 20)
        # Phase 6 B: agent state after the boot (Acrylic service, DNS for the
        # anchor, watchdog/worker tasks).
        $agentState = [ordered]@{}
        try { $agentState.acrylicService = [string](Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue).Status } catch { $agentState.acrylicService = 'query-failed' }
        try { $agentState.tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OpenPath-*' } | ForEach-Object { [ordered]@{ name = $_.TaskName; state = [string]$_.State } }) } catch { }
        try {
            $planForState = Get-FixturePlan
            $anchorHostForState = [string]$planForState.anchors.a1.host
            if ($anchorHostForState) { $agentState.anchorDns = Resolve-Probe -HostName $anchorHostForState }
        }
        catch { }
        $events.agentState = $agentState
        $script:Body.hostEvents = $events
        Complete-Step
    }
    'sac-defender-enable' {
        # Phase 6.1 C extra attempt: clear the Defender-disabling policy values
        # and make sure the service is running, so Smart App Control can
        # evaluate signatures at all.
        Save-PartialResult
        $result = [ordered]@{
            policyBefore  = @()
            removed       = @()
            policyAfter   = @()
            serviceBefore = ''
            serviceAfter  = ''
            startError    = ''
            at            = [DateTime]::UtcNow.ToString('o')
        }
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
        try {
            if (Test-Path $policyPath) {
                $props = Get-ItemProperty -Path $policyPath -ErrorAction Stop
                $entries = @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
                $result.policyBefore = @($entries | ForEach-Object { [ordered]@{ name = $_.Name; value = [string]$_.Value } })
                foreach ($name in @('DisableAntiSpyware', 'DisableAntiVirus', 'DisableRoutinelyTakingAction', 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableScriptScanning')) {
                    if (@($entries | ForEach-Object { $_.Name }) -contains $name) {
                        Remove-ItemProperty -Path $policyPath -Name $name -ErrorAction SilentlyContinue
                        $result.removed += $name
                    }
                }
            }
        }
        catch { }
        try { $result.serviceBefore = [string](Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue).Status } catch { }
        try { Set-Service -Name 'WinDefend' -StartupType Automatic -ErrorAction SilentlyContinue } catch { }
        try { Start-Service -Name 'WinDefend' -ErrorAction Stop } catch { $result.startError = [string]$_.Exception.Message }
        try { $result.serviceAfter = [string](Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue).Status } catch { }
        try {
            $propsAfter = Get-ItemProperty -Path $policyPath -ErrorAction SilentlyContinue
            if ($propsAfter) {
                $result.policyAfter = @($propsAfter.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { [ordered]@{ name = $_.Name; value = [string]$_.Value } })
            }
        }
        catch { }
        $script:Body.sacDefenderEnable = $result
        Complete-Step
    }
    'sac-control' {
        # Phase 6.1 C: positive control for Smart App Control. Compile a trivial
        # console exe with the .NET Framework csc.exe, keep a MOTW (ZoneId=3)
        # and a plain copy, run both as SYSTEM and collect the CodeIntegrity XML
        # events that name them. No binary ever enters the repository; the
        # directory is removed afterwards.
        Save-PartialResult
        $languageMode = [string]$ExecutionContext.SessionState.LanguageMode
        $control = [ordered]@{
            ran           = $false
            languageMode  = $languageMode
            dir           = 'C:\Windows\Temp\openpath-sac-control'
            csc           = ''
            compileExit   = -1
            compileOutput = @()
            plain         = $null
            motw          = $null
            codeIntegrity = $null
            cleaned       = $false
            error         = ''
        }
        if ($languageMode -ne 'FullLanguage') {
            $control.error = "constrained-language:$languageMode"
            $script:Body.sacControl = $control
            Complete-Step
        }
        try {
            $control.ran = $true
            $dir = $control.dir
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $source = Join-Path $dir 'control.cs'
            [IO.File]::WriteAllText($source, 'public static class OpenPathSacControl { public static void Main() { System.Environment.ExitCode = 7; } }', [Text.UTF8Encoding]::new($false))
            $candidates = @(
                (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
                (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
            )
            $csc = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
            if ($csc.Count -eq 0) { throw 'csc-not-found' }
            $control.csc = [string]$csc[0]
            $compile = Invoke-Cmd ([string]$csc[0]) @('/nologo', '/target:exe', ("/out:" + (Join-Path $dir 'control.exe')), $source)
            $control.compileExit = $compile.exit
            $control.compileOutput = @($compile.out | Select-Object -First 10)
            $compiled = Join-Path $dir 'control.exe'
            if ($compile.exit -ne 0 -or -not (Test-Path -LiteralPath $compiled)) { throw "compile-failed:$($compile.exit)" }
            $plainPath = Join-Path $dir 'control-plain.exe'
            $motwPath = Join-Path $dir 'control-motw.exe'
            Copy-Item -LiteralPath $compiled -Destination $plainPath -Force
            Copy-Item -LiteralPath $compiled -Destination $motwPath -Force
            $zone = "[ZoneTransfer]`r`nZoneId=3`r`nReferrerUrl=https://example.invalid/`r`nHostUrl=https://example.invalid/control.exe"
            Set-Content -LiteralPath $motwPath -Stream 'Zone.Identifier' -Value $zone -Encoding ASCII
            $control.plain = Invoke-SacControlRun -Path $plainPath
            $control.motw = Invoke-SacControlRun -Path $motwPath
            $control.codeIntegrity = Get-CodeIntegrityXmlEvents -SinceIso $SceneStartedAt -MaxEvents 60 -MaxBytes 262144
        }
        catch { $control.error = [string]$_.Exception.Message }
        finally {
            try { Remove-Item -LiteralPath $control.dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            $control.cleaned = -not (Test-Path -LiteralPath $control.dir)
        }
        $script:Body.sacControl = $control
        Complete-Step
    }
    'sac-apply' {
        # Phase 6 B: simulate "an installed machine to which Windows turns SAC
        # On". Runs right after the warm-up with SAC=2; the class-boot reboot
        # then applies it. Records the previous value and the CiTool result.
        Save-PartialResult
        $languageMode = [string]$ExecutionContext.SessionState.LanguageMode
        if ($languageMode -ne 'FullLanguage') {
            $script:Failures.Add("sac-apply-requires-full-language:$languageMode")
            Complete-Step
        }
        $policyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
        $previous = -1
        try {
            $current = Get-ItemProperty -LiteralPath $policyPath -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
            if ($current -and $null -ne $current.VerifiedAndReputablePolicyState) { $previous = [int]$current.VerifiedAndReputablePolicyState }
        }
        catch { }
        try {
            if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
            Set-ItemProperty -LiteralPath $policyPath -Name 'VerifiedAndReputablePolicyState' -Value 1 -Type DWord
        }
        catch {
            $script:Failures.Add("sac-apply-registry-failed: $($_.Exception.Message)")
            Complete-Step
        }
        $ciTool = Join-Path $env:SystemRoot 'System32\CiTool.exe'
        $ci = [ordered]@{ path = $ciTool; exists = (Test-Path -LiteralPath $ciTool); exit = -1; out = @() }
        if ($ci.exists) {
            $result = Invoke-Cmd $ciTool @('-r')
            $ci.exit = $result.exit
            $ci.out = @($result.out | Select-Object -First 20)
        }
        $applied = -1
        try {
            $now = Get-ItemProperty -LiteralPath $policyPath -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop
            if ($now -and $null -ne $now.VerifiedAndReputablePolicyState) { $applied = [int]$now.VerifiedAndReputablePolicyState }
        }
        catch { }
        $script:Body.sacApply = [ordered]@{
            previousValue = $previous
            appliedValue  = $applied
            ciTool        = $ci
            at            = [DateTime]::UtcNow.ToString('o')
        }
        Complete-Step
    }
    'sac-state' {
        # Phase 6 B: state after the class-boot reboot applied SAC. Works under
        # ConstrainedLanguage too (minimal path with cmdlets and native
        # commands only) because the policy can put PowerShell in CLM.
        Save-PartialResult
        $languageMode = [string]$ExecutionContext.SessionState.LanguageMode
        $policyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
        $ciQuery = '*[System[(EventID=3033 or EventID=3034 or EventID=3076 or EventID=3077 or EventID=3089)]]'
        $registryValue = -1
        $mpState = 'unknown'
        try {
            $current = Get-ItemProperty -LiteralPath $policyPath -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
            if ($current -and $null -ne $current.VerifiedAndReputablePolicyState) { $registryValue = [int]$current.VerifiedAndReputablePolicyState }
        }
        catch { }
        try {
            if (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue) {
                $mpState = [string](Get-MpComputerStatus -ErrorAction Stop).SmartAppControlState
            }
        }
        catch { $mpState = 'query-failed' }
        if ($languageMode -ne 'FullLanguage') {
            $minimal = @{}
            $minimal.status = 'passed'
            $minimal.step = $Step
            $minimal.phase = $Phase
            $minimal.scenario = $ScenarioId
            $minimal.languageMode = $languageMode
            $minimal.constrainedLanguage = $true
            $minimalDeviceGuard = @{ umciEnforcementStatus = $null; ciEnforcementStatus = $null; error = 'constrained-language' }
            try {
                $dgMinimal = @(Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop | Select-Object -First 1)
                if ($dgMinimal.Count -gt 0) {
                    $minimalDeviceGuard.umciEnforcementStatus = $dgMinimal[0].UsermodeCodeIntegrityPolicyEnforcementStatus
                    $minimalDeviceGuard.ciEnforcementStatus = $dgMinimal[0].CodeIntegrityPolicyEnforcementStatus
                    $minimalDeviceGuard.error = ''
                }
            }
            catch { }
            $minimal.sacState = @{ registryValue = $registryValue; smartAppControlState = $mpState; languageMode = $languageMode; deviceGuard = $minimalDeviceGuard; constrainedLanguage = $true }
            $ci = Invoke-Cmd 'wevtutil.exe' @('qe', 'Microsoft-Windows-CodeIntegrity/Operational', "/q:$ciQuery", '/c:40', '/rd:true', '/f:text')
            $minimal.codeIntegrityExit = $ci.exit
            $minimal.codeIntegrityLines = @($ci.out | Select-Object -First 200)
            $openpathConstrained = Invoke-Cmd 'cmd.exe' @('/c', 'type C:\OpenPath\data\logs\openpath.log 2>nul')
            $minimal.openpathLineCount = @($openpathConstrained.out).Count
            $minimal.openpathTail = @($openpathConstrained.out | Select-Object -Last 30)
            $minimalJson = $minimal | ConvertTo-Json -Depth 6 -Compress
            Set-Content -LiteralPath $ResultPath -Value $minimalJson -Encoding UTF8 -ErrorAction SilentlyContinue
            Write-Output '<<<GUEST_RESULT>>>'
            Write-Output $minimalJson
            Write-Output '<<<END_GUEST_RESULT>>>'
            exit 0
        }
        $deviceGuard = [ordered]@{ umciEnforcementStatus = $null; ciEnforcementStatus = $null; securityServicesRunning = @(); error = '' }
        try {
            $dg = @(Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop | Select-Object -First 1)
            if ($dg.Count -gt 0) {
                if ($null -ne $dg[0].UsermodeCodeIntegrityPolicyEnforcementStatus) { $deviceGuard.umciEnforcementStatus = [int]$dg[0].UsermodeCodeIntegrityPolicyEnforcementStatus }
                if ($null -ne $dg[0].CodeIntegrityPolicyEnforcementStatus) { $deviceGuard.ciEnforcementStatus = [int]$dg[0].CodeIntegrityPolicyEnforcementStatus }
                $deviceGuard.securityServicesRunning = @($dg[0].SecurityServicesRunning)
            }
            else { $deviceGuard.error = 'no-instance' }
        }
        catch { $deviceGuard.error = [string]$_.Exception.Message }
        $ciToolPath = Join-Path $env:SystemRoot 'System32\CiTool.exe'
        $ciTool = [ordered]@{ path = $ciToolPath; exists = (Test-Path -LiteralPath $ciToolPath); exit = -1; mode = 'none'; raw = @(); json = '' }
        if ($ciTool.exists) {
            $rawResult = Invoke-Cmd $ciToolPath @('-lp')
            $ciTool.exit = $rawResult.exit
            $ciTool.mode = 'text'
            $ciTool.raw = @($rawResult.out | Select-Object -First 60)
            $jsonResult = Invoke-Cmd $ciToolPath @('-lp', '--json')
            $jsonText = (@($jsonResult.out) -join "`n").Trim()
            if ($jsonResult.exit -eq 0 -and $jsonText -match '^\s*[\{\[]') {
                $ciTool.mode = 'json'
                if ($jsonText.Length -gt 40000) { $jsonText = $jsonText.Substring(0, 40000) }
                $ciTool.json = $jsonText
            }
        }
        $defender = [ordered]@{ status = $null; policy = @(); disabledByPolicy = @(); error = '' }
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $defender.status = [ordered]@{
                amServiceEnabled          = [bool]$mp.AMServiceEnabled
                antivirusEnabled          = [bool]$mp.AntivirusEnabled
                realTimeProtectionEnabled = [bool]$mp.RealTimeProtectionEnabled
                isTamperProtected         = [bool]$mp.IsTamperProtected
                smartAppControlState      = [string]$mp.SmartAppControlState
                amServiceVersion          = [string]$mp.AMServiceVersion
            }
        }
        catch { $defender.error = [string]$_.Exception.Message }
        try {
            $defenderPolicy = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -ErrorAction SilentlyContinue
            if ($defenderPolicy) {
                $entries = @($defenderPolicy.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
                $defender.policy = @($entries | ForEach-Object { [ordered]@{ name = $_.Name; value = [string]$_.Value } })
                foreach ($name in @('DisableAntiSpyware', 'DisableAntiVirus', 'DisableRoutinelyTakingAction', 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableScriptScanning')) {
                    $entry = @($entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
                    if ($entry.Count -gt 0 -and ([string]$entry[0].Value) -notin @('0', '')) { $defender.disabledByPolicy += $name }
                }
            }
        }
        catch { }
        $ciXml = Get-CodeIntegrityXmlEvents -SinceIso $SceneStartedAt -MaxEvents 200 -MaxBytes 524288
        $agentState = [ordered]@{}
        try { $agentState.acrylicService = [string](Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue).Status } catch { $agentState.acrylicService = 'query-failed' }
        try { $agentState.tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OpenPath-*' } | ForEach-Object { [ordered]@{ name = $_.TaskName; state = [string]$_.State } }) } catch { }
        try {
            $planForState = Get-FixturePlan
            $anchorHostForState = [string]$planForState.anchors.a1.host
            if ($anchorHostForState) { $agentState.anchorDns = Resolve-Probe -HostName $anchorHostForState }
        }
        catch { }
        try { $agentState.openpathErrors = @(Get-LogTail -Path "$OpenPathRoot\data\logs\openpath.log" -Tail 400 -Patterns @('ERROR', 'WARN') | Select-Object -Last 25) } catch { }
        $script:Body.sacState = [ordered]@{
            registryValue         = $registryValue
            smartAppControlState  = $mpState
            languageMode          = $languageMode
            deviceGuard           = $deviceGuard
            ciTool                = $ciTool
            defender              = $defender
            codeIntegrityXml      = $ciXml
            codeIntegrityExit     = $ciXml.exit
            agentState            = $agentState
            sceneStartedAt        = $SceneStartedAt
            at                    = [DateTime]::UtcNow.ToString('o')
        }
        Complete-Step
    }
    'cleanup' {
        if (Test-Path -LiteralPath "$OpenPathRoot\Uninstall-OpenPath.ps1") {
            $uninstall = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\OpenPath\Uninstall-OpenPath.ps1') -RedirectStandardOutput 'C:\OpenPathLab\logs\uninstall.out.log' -RedirectStandardError 'C:\OpenPathLab\logs\uninstall.err.log' -PassThru -Wait -WindowStyle Hidden
            $script:Body.uninstallExit = $uninstall.ExitCode
        }
        Start-Sleep -Seconds 15
        $script:Body.clean = [ordered]@{
            rootGone       = -not (Test-Path -LiteralPath $OpenPathRoot)
            uninstallGone  = -not (Test-Path -LiteralPath "$OpenPathRoot\Uninstall-OpenPath.ps1")
            tasks          = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OpenPath-*' } | ForEach-Object { $_.TaskName })
            service        = [string](Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue).Status
            firefox        = @(Get-FirefoxProcesses).Count
        }
        Complete-Step
    }
    default {
        $script:Failures.Add("unknown-step: $Step")
        Complete-Step
    }
}
}
catch {
    $script:Failures.Add("harness-exception: $($_.Exception.Message)")
    $script:Body.harnessException = $_.Exception.ToString()
    Complete-Step
}
