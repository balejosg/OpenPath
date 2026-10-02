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
    [string]$FixtureBaselineJson = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
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

function Get-WarmupVerificationVerdict {
    # Pure verdict for the warm-up verification (Phase 3A.2 K1). The state
    # signal is only evaluated after Firefox closed; the live signals are gated
    # by what the build under test can emit.
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Live,
        [AllowNull()][object]$State,
        [bool]$XpiFetched = $false,
        [bool]$RequireHostStart = $false,
        [bool]$RequireBackgroundStart = $false,
        [bool]$RequireDiagnosticBatch = $false,
        [string]$ExpectedVersion = ''
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $XpiFetched) { $reasons.Add('xpi-not-fetched') }
    if ($RequireHostStart -and -not ($Live -and [bool]$Live.hostStarted)) { $reasons.Add('host-not-started') }
    if ($RequireBackgroundStart -and -not ($Live -and [bool]$Live.backgroundStart)) { $reasons.Add('background-start-missing') }
    if ($RequireDiagnosticBatch -and -not ($Live -and [bool]$Live.diagnosticBatchFirst)) { $reasons.Add('extension-diagnostic-batch-missing') }
    if ($State -and [bool]$State.found) {
        if (-not ([bool]$State.active -and -not [bool]$State.userDisabled -and -not [bool]$State.appDisabled)) {
            $reasons.Add('extension-registered-inactive')
        }
        elseif ($ExpectedVersion -and [string]$State.version -and ([string]$State.version -ne $ExpectedVersion)) {
            $reasons.Add("extension-version-mismatch:$([string]$State.version)-expected-$ExpectedVersion")
        }
    }
    elseif ($XpiFetched) { $reasons.Add('xpi-fetched-not-registered') }
    else { $reasons.Add('extension-not-registered') }
    $status = if ($reasons.Count -eq 0) { 'passed' } else { 'failed' }
    return [ordered]@{ status = $status; reasons = @($reasons) }
}

function Get-FirefoxProcesses {
    return @(Get-Process -Name 'firefox' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $created = ''
                try { $created = $_.StartTime.ToUniversalTime().ToString('o') } catch { }
                [ordered]@{ pid = $_.Id; created = $created }
            })
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
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Tag)
    $firefox = Get-FirefoxInstallPath
    if (-not $firefox) { throw 'firefox.exe not found' }
    Initialize-VisitRoot | Out-Null
    $root = $script:VisitRoot
    $cmdPath = Join-Path $root ("ff-$Tag.cmd")
    $body = @"
@echo off
echo launch %DATE% %TIME% user=%USERNAME% tag=$Tag >> "$root\logs\launch.log"
"$firefox" -new-window "$Url" >> "$root\logs\firefox-$Tag.log" 2>&1
echo exit %ERRORLEVEL% >> "$root\logs\launch.log"
"@
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

function Get-NativeHostDiagnostics {
    # Evidence for host-not-started, safe subset only (file/registry reads).
    # WMI, Get-WinEvent and Get-AppLockerPolicy hung the guest or broke JSON
    # serialization in Phase 3A.2 K0b/K0c, so they are deliberately absent.
    $out = [ordered]@{}
    $logPath = Get-NativeHostLogPath
    $out.nativeLog = [ordered]@{
        path   = $logPath
        exists = (Test-Path -LiteralPath $logPath)
        bytes  = if (Test-Path -LiteralPath $logPath) { (Get-Item -LiteralPath $logPath).Length } else { 0 }
        tail   = @(Get-LogTail -Path $logPath -Tail 6)
    }
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
    $out.manifestPath = $manifestPath
    $out.manifestExists = if ($manifestPath) { [bool](Test-Path -LiteralPath $manifestPath) } else { $false }
    $out.manifest = ''
    if ($out.manifestExists) {
        try { $out.manifest = (Get-Content -LiteralPath $manifestPath -Raw).Trim() } catch { }
    }
    $out.wrapperExists = $false
    $out.wrapperHead = @()
    if ($out.manifest) {
        try {
            $parsed = $out.manifest | ConvertFrom-Json
            if ($parsed.path) {
                $out.wrapperExists = [bool](Test-Path -LiteralPath ([string]$parsed.path))
                if ($out.wrapperExists) { $out.wrapperHead = @(Get-Content -LiteralPath ([string]$parsed.path) -TotalCount 4 -ErrorAction SilentlyContinue) }
            }
        }
        catch { }
    }
    $out.launchLogTail = @(Get-LogTail -Path (Join-Path $script:VisitRoot 'logs\launch.log') -Tail 12)
    $out.firefoxLogTail = @(Get-LogTail -Path (Join-Path $script:VisitRoot 'logs\firefox-warmup.log') -Tail 20)
    return $out
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

function Get-LogTail {
    param([string]$Path, [int]$Tail = 300, [string[]]$Patterns = @())
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    # Bounded read: a runaway native-host log must never turn a log read into a
    # whole-file scan inside the guest (Phase 3A.2 K0e).
    $lines = @(Get-Content -LiteralPath $Path -Tail 2000 -ErrorAction SilentlyContinue)
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
        $path = Get-OpenPathCapabilityStoragePath
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
        [string]$Tag = 'visit'
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
    $cmdPath = Write-CleanFirefoxCmd -Url $Url -Tag $Tag
    $target = '"C:\Windows\System32\cmd.exe" /c "' + $cmdPath + '"'
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target))
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -CommandLineBase64 $b64 2>&1 | Out-String).Trim()
    Start-Sleep -Seconds 12
    return [ordered]@{ mode = 'session-launcher-cmd'; out = $out; firefox = @(Get-FirefoxProcesses); tag = $Tag; cmd = $cmdPath }
}

function Get-LaunchDiagnostics {
    return [ordered]@{
        session = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        runKey = @((Invoke-Cmd 'reg.exe' @('query', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', '/v', 'OpenPathFirstVisit')).out | Select-Object -First 4)
        root = @(Get-ChildItem $script:VisitRoot -Recurse -ErrorAction SilentlyContinue | Select-Object -First 12 | ForEach-Object { $_.FullName + ' ' + $_.Length })
        launchOut = @($script:Body.launchOut)
        appLocker = @(Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 4 -ErrorAction SilentlyContinue | ForEach-Object { $_.TimeCreated.ToString('o') + ' ' + (($_.Message -split "`n")[0]) })
        codeIntegrity = @(Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 4 -ErrorAction SilentlyContinue | ForEach-Object { $_.TimeCreated.ToString('o') + ' ' + (($_.Message -split "`n")[0]) })
    }
}

function Complete-Step {
    param([string]$Status = 'passed')
    if ($script:Failures.Count -gt 0) { $Status = 'failed' }
    $payload = [ordered]@{
        status    = $Status
        step      = $Step
        phase     = $Phase
        scenario  = $ScenarioId
        failures  = @($script:Failures)
        endedAt   = [DateTime]::UtcNow.ToString('o')
        body      = [ordered]@{ state = $script:Body; session = [string]$script:Body.session }
    }
    $json = ''
    try { $json = $payload | ConvertTo-Json -Depth 12 -Compress }
    catch {
        Write-Output ('COMPLETE-STEP serialization-failed: ' + $_.Exception.Message)
        $payload = [ordered]@{
            status = $Status; step = $Step; phase = $Phase; scenario = $ScenarioId
            failures = @($script:Failures); endedAt = [DateTime]::UtcNow.ToString('o')
            body = [ordered]@{ state = [ordered]@{ note = 'body-unserializable' }; session = '' }
        }
        try { $json = $payload | ConvertTo-Json -Depth 6 -Compress }
        catch { $json = '{"status":"' + $Status + '","step":"' + $Step + '","failures":["body-unserializable"],"body":{"state":{}}}' }
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
        $script:Body.dnsBefore = @(
            Resolve-Probe -HostName ([string]$plan.anchors.a1.host)
            Resolve-Probe -HostName ([string]$plan.anchors.a1.roles.styles)
        )
        if (-not $script:Body.dnsBefore[0].resolves) { $script:Failures.Add('anchor-does-not-resolve-before-visit') }
        if ($script:Body.dnsBefore[1].resolves) { $script:Failures.Add('dependency-resolves-before-visit') }
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
        $script:Body.arm = [ordered]@{ mode = 'reboot'; cmd = $cmdPath; refresh = (Start-VisitRefresh -Mode 'reboot') }
        Complete-Step
    }
    'visit' {
        $plan = Get-FixturePlan
        $anchorHost = [string]$plan.anchors.a1.host
        $url = "http://$anchorHost/"
        $script:Body.anchor = 'a1'
        $script:Body.anchorUrl = $url
        if ($ScenarioId -eq 'first-visit-class-boot') {
            # Class boot: arm the wrapper for the next logon (the run key is what
            # starts the browser in this lab) and reboot; the host waits for the
            # new logon and measures the class-boot window.
            $cmdPath = Write-CleanFirefoxCmd -Url $url -Tag 'visit'
            Clear-VisitRunKey | Out-Null
            Set-VisitRunKey -CmdPath $cmdPath
            $script:Body.arm = [ordered]@{ mode = 'reboot'; cmd = $cmdPath; refresh = (Start-VisitRefresh -Mode 'reboot') }
        }
        else {
            $launch = Start-InSessionVisit -Url $url -Tag 'visit'
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
            $xpiFetchDelaySeconds = -1
            if ($xpiFetched -and $fixtureBefore -and [double]$fixtureBefore.serverNow -gt 0 -and [double]$clock.xpiLastFetchedAt -gt 0) {
                $xpiFetchDelaySeconds = [math]::Round([double]$clock.xpiLastFetchedAt - [double]$fixtureBefore.serverNow, 2)
            }
            # K0 observation (removed from the final harness): what the add-on
            # registry says while Firefox is still open.
            $script:Body.staleStateWhileOpen = Get-ProfileExtensionState
            if (-not $live.hostStarted) { $script:Body.hostDiagnostics = Get-NativeHostDiagnostics }
            Write-Output ('VERIFY-WARMUP stage=live hostStarted=' + [string]$live.hostStarted + ' xpiFetched=' + [string]$xpiFetched + ' fetchDelay=' + [string]$xpiFetchDelaySeconds)
            $script:Body.liveSignals = $live
            $script:Body.xpiFetch = [ordered]@{ fetched = $xpiFetched; delaySeconds = $xpiFetchDelaySeconds; baseCount = $xpiBaseCount; count = [int]$clock.xpiCount }
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
            $verdict = Get-WarmupVerificationVerdict -Live $live -State $state -XpiFetched $xpiFetched `
                -RequireHostStart:([bool]($Capabilities -match 'native-host-log')) `
                -RequireBackgroundStart:([bool]($Capabilities -match 'background-start')) `
                -RequireDiagnosticBatch:([bool]($Capabilities -match 'diagnostic-batch')) `
                -ExpectedVersion $expectedVersion
            $script:Body.warmupVerification = $verdict
            Write-Output ('VERIFY-WARMUP stage=verdict status=' + [string]$verdict.status + ' reasons=' + (@($verdict.reasons) -join ','))
            foreach ($reason in @($verdict.reasons)) { $script:Failures.Add($reason) }
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
            $logs += @(Get-Content -LiteralPath $file.FullName -Tail 12 -ErrorAction SilentlyContinue)
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
        $addonsLog = @()
        $addonsPath = Join-Path $script:VisitRoot 'moz\addons.log'
        if (Test-Path -LiteralPath $addonsPath) {
            $addonsLog = @(Get-Content -LiteralPath $addonsPath -Tail 80 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'addon|Addon|install|xpi|policy' } | Select-Object -First 30)
        }
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
        $profiles = @($nativeHost | Where-Object { $_ -match 'stage=startup-profile' })
        $openpath = Get-LogTail -Path "$OpenPathRoot\logs\openpath.log" -Tail 300
        $workerState = ''
        if (Test-Path -LiteralPath "$OpenPathRoot\data\runtime-dependency-worker-state.json") {
            $workerState = Get-Content -LiteralPath "$OpenPathRoot\data\runtime-dependency-worker-state.json" -Raw
        }
        $mozExtract = @()
        $mozFiles = @()
        foreach ($mozDir in @('C:\OpenPathLab\moz', (Join-Path $script:VisitRoot 'moz'))) {
            $mozFiles += @(Get-ChildItem -LiteralPath $mozDir -Filter '*.log*' -ErrorAction SilentlyContinue)
        }
        foreach ($mozFile in $mozFiles) {
            $mozExtract += @(Select-String -LiteralPath $mozFile.FullName -Pattern 'nsHostResolver|nsHttp' -ErrorAction SilentlyContinue |
                    Select-Object -First 400 | ForEach-Object { $_.Line })
        }
        $script:Body.collect = [ordered]@{
            diagnostics          = [ordered]@{
                lines                = $diagnostics.Count
                hostStarted          = $liveCollect.hostStarted
                backgroundStart      = $liveCollect.backgroundStart
                batchFirst           = $liveCollect.diagnosticBatchFirst
                transportTransitions = @($diagnostics | Where-Object { $_ -match 'kind":"transport' }).Count
                holdOutcomes         = @($diagnostics | Where-Object { $_ -match 'kind":"hold-outcome' }).Count
                reloadDecisions      = @($diagnostics | Where-Object { $_ -match 'kind":"reload-decision' }).Count
                reloadReasons        = $reloadReasons
                all                  = @($diagnostics | Select-Object -First 1000)
            }
            addonsLog            = @($addonsLog | Select-Object -First 30)
            mozExtract           = @($mozExtract | Select-Object -First 600)
            diagnosticLines      = $diagnostics.Count
            diagnosticSample     = @($diagnostics | Select-Object -First 40)
            startupProfiles      = @($profiles | Select-Object -Last 8)
            nativeHostTail       = @($nativeHost | Select-Object -Last 120)
            openpathTail         = @($openpath | Select-Object -Last 80)
            workerState          = $workerState
            overlayHosts         = @(Get-OverlayHosts)
            whitelistMirror      = @(Get-LogTail -Path "$OpenPathRoot\data\whitelist.txt" -Tail 40)
            firefoxProcesses     = @(Get-FirefoxProcesses)
        }
        $script:Body.session = $script:Body.session
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
