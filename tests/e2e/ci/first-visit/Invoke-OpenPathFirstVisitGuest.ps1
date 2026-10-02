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
    [string]$PersonalizedExePath = ''
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
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = 'C:\Users\Public' }
    return (Join-Path (Join-Path $base 'OpenPath') 'native-host.log')
}

function Get-FirefoxProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='firefox.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object { [ordered]@{ pid = $_.ProcessId; created = ([datetime]$_.CreationDate).ToString('o') } })
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
set MOZ_LOG=timestamp,rotate:300,nsHostResolver:5,nsHttp:4
set MOZ_LOG_FILE=$root\moz\$Tag.log
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

function Get-ExtensionState {
    $profiles = @(Get-ChildItem 'C:\Users\*\AppData\Roaming\Mozilla\Firefox\Profiles' -Directory -ErrorAction SilentlyContinue)
    foreach ($profile in $profiles) {
        $extensions = Join-Path $profile.FullName 'extensions.json'
        if (-not (Test-Path -LiteralPath $extensions)) { continue }
        try {
            $json = Get-Content -LiteralPath $extensions -Raw | ConvertFrom-Json
            foreach ($addon in @($json.addons)) {
                if ([string]$addon.id -eq 'openpath-block-monitor@openpath') {
                    return [ordered]@{ found = $true; profile = $profile.Name; version = [string]$addon.version; active = [bool]$addon.active }
                }
            }
        }
        catch { }
    }
    return [ordered]@{ found = $false }
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
    if ($Patterns.Count -gt 0) {
        return @(Select-String -LiteralPath $Path -Pattern $Patterns | Select-Object -Last $Tail | ForEach-Object { $_.Line })
    }
    return @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction SilentlyContinue)
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
    $target = '"' + $firefox + '" -new-window "' + $Url + '"'
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target))
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -CommandLineBase64 $b64 2>&1 | Out-String).Trim()
    Start-Sleep -Seconds 12
    return [ordered]@{ mode = 'session-launcher'; out = $out; firefox = @(Get-FirefoxProcesses); tag = $Tag }
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

function Set-LabFirefoxPolicy {
    # Phase 2E proved the signed xpi installs from a file:// url in this lab. The
    # agent also writes (and reapplies) the managed ExtensionSettings in the
    # machine registry, and Firefox gives the registry precedence, so both
    # places are pointed at the staged xpi; the caller invokes this right before
    # a browser start so the agent cannot win the race.
    param([Parameter(Mandatory = $true)][string]$LabUrl)
    $policyPath = 'C:\Program Files\Mozilla Firefox\distribution\policies.json'
    $regPath = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
    $fileOk = $false
    $regOk = $false
    if (Test-Path -LiteralPath $policyPath) {
        try {
            $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
            $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
            if ($null -eq $entry) {
                $policy.policies.ExtensionSettings | Add-Member -NotePropertyName 'openpath-block-monitor@openpath' -NotePropertyValue ([pscustomobject]@{ installation_mode = 'force_installed' }) -Force
                $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
            }
            $entry | Add-Member -NotePropertyName install_url -NotePropertyValue $LabUrl -Force
            [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $readBack = [string]((Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json).policies.ExtensionSettings.'openpath-block-monitor@openpath'.install_url)
            $fileOk = ($readBack -eq $LabUrl)
        }
        catch { }
    }
    try {
        $settings = $null
        $current = @((Get-ItemProperty -Path $regPath -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings)
        if ($current.Count -gt 0) { $settings = ($current -join "`n") | ConvertFrom-Json }
        if ($null -eq $settings) { $settings = [pscustomobject]@{} }
        $entryValue = [pscustomobject]@{ installation_mode = 'force_installed'; install_url = $LabUrl }
        if ($settings.PSObject.Properties['openpath-block-monitor@openpath']) {
            $settings.PSObject.Properties['openpath-block-monitor@openpath'].Value = $entryValue
        }
        else {
            $settings | Add-Member -NotePropertyName 'openpath-block-monitor@openpath' -NotePropertyValue $entryValue -Force
        }
        $regValue = @($settings | ConvertTo-Json -Depth 10 -Compress)
        if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        New-ItemProperty -Path $regPath -Name 'ExtensionSettings' -Value $regValue -PropertyType MultiString -Force | Out-Null
        $regBack = @((Get-ItemProperty -Path $regPath -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings) -join "`n"
        $regOk = ($regBack -like ('*' + $LabUrl + '*'))
    }
    catch { }
    return [ordered]@{ fileOk = $fileOk; registryOk = $regOk; url = $LabUrl }
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
        # Lab-only: production points install_url at the managed API. The lab
        # fixture does not serve extension bytes, so the policy is pointed at the
        # locally staged signed XPI (the Phase 2E lab proved file:// installs).
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
            $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
            $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
            if ($null -eq $entry) {
                $policy.policies.ExtensionSettings | Add-Member -NotePropertyName 'openpath-block-monitor@openpath' -NotePropertyValue ([pscustomobject]@{ installation_mode = 'force_installed' }) -Force
                $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
            }
            $entry | Add-Member -NotePropertyName install_url -NotePropertyValue 'file:///C:/OpenPathLab/first-visit/openpath-firefox-extension.xpi' -Force
            [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $script:Body.xpiStaged = $labXpi
            $script:Body.policyInstallUrl = 'file:///C:/OpenPathLab/first-visit/openpath-firefox-extension.xpi'
        }
        else {
            $script:Failures.Add('firefox-release-xpi-missing')
        }
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
    'lab-policy' {
        # Phase 2E proved that Firefox installs the signed xpi from
        # distribution/policies.json with a file:// url in this lab. The agent
        # also writes the managed ExtensionSettings to the machine registry (and
        # reapplies it), and Firefox gives the registry precedence, so the lab
        # removes the registry entry and drives the install from the file. The
        # fixture additionally serves the xpi on the anchor and the managed API
        # path, so the install still works if the agent re-adds the registry
        # before the browser starts.
        $policyPath = 'C:\Program Files\Mozilla Firefox\distribution\policies.json'
        $labXpi = 'C:\OpenPathLab\first-visit\openpath-firefox-extension.xpi'
        $labUrl = 'file:///C:/OpenPathLab/first-visit/openpath-firefox-extension.xpi'

        $fixtureBase = Get-FixtureBase
        $upload = ''
        try {
            $uploadResp = Invoke-WebRequest -UseBasicParsing -Uri "$fixtureBase/xpi" -Method Post -InFile $labXpi -ContentType 'application/x-xpinstall' -TimeoutSec 120
            $upload = [string]$uploadResp.StatusCode
        }
        catch { $upload = 'upload-failed: ' + $_.Exception.Message }
        Write-Output ('LAB-POLICY xpi-upload=' + $upload)
        $script:Body.labPolicyUpload = $upload
        if ($upload -notmatch '^2') { $script:Failures.Add('lab-policy-xpi-upload-failed') }

        $regRemoved = $false
        try {
            Invoke-Cmd 'reg.exe' @('delete', 'HKLM\SOFTWARE\Policies\Mozilla\Firefox', '/v', 'ExtensionSettings', '/f') | Out-Null
            $regRemoved = ((Invoke-Cmd 'reg.exe' @('query', 'HKLM\SOFTWARE\Policies\Mozilla\Firefox', '/v', 'ExtensionSettings')).exit -ne 0)
        }
        catch { }
        Write-Output ('LAB-POLICY registry-removed=' + [string]$regRemoved)
        $script:Body.labPolicyRegistryRemoved = $regRemoved
        if (-not $regRemoved) { $script:Failures.Add('lab-policy-registry-not-removed') }

        $rewritten = $false
        if (Test-Path -LiteralPath $policyPath) {
            $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
            $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
            if ($null -eq $entry) {
                $policy.policies.ExtensionSettings | Add-Member -NotePropertyName 'openpath-block-monitor@openpath' -NotePropertyValue ([pscustomobject]@{ installation_mode = 'force_installed' }) -Force
                $entry = $policy.policies.ExtensionSettings.'openpath-block-monitor@openpath'
            }
            $entry | Add-Member -NotePropertyName install_url -NotePropertyValue $labUrl -Force
            [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $rewritten = $true
        }
        else { $script:Failures.Add('lab-policy-missing') }
        $readBack = ''
        try { $readBack = [string]((Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json).policies.ExtensionSettings.'openpath-block-monitor@openpath'.install_url) } catch { }
        Write-Output ('LAB-POLICY file rewritten=' + [string]$rewritten + ' install_url=' + $readBack)
        $script:Body.labPolicyRewritten = $rewritten
        $script:Body.labPolicyReadBack = $readBack
        if ($readBack -ne $labUrl) { $script:Failures.Add('lab-policy-not-applied') }

        # The launcher builds the student environment from the registry, so a
        # machine MOZ_LOG reaches the warm-up Firefox and records the addon
        # manager's install decision.
        $mozLog = 'timestamp,addons:5,sync:3,nsHttp:4'
        $mozLogFile = Join-Path $script:VisitRoot 'moz\addons.log'
        Invoke-Cmd 'reg.exe' @('add', 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', '/v', 'MOZ_LOG', '/t', 'REG_SZ', '/d', $mozLog, '/f') | Out-Null
        Invoke-Cmd 'reg.exe' @('add', 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', '/v', 'MOZ_LOG_FILE', '/t', 'REG_SZ', '/d', $mozLogFile, '/f') | Out-Null
        $script:Body.mozLogConfigured = $mozLog
        Complete-Step
    }
    'warmup' {
        $closed = Close-FirefoxProcesses
        $script:Body.closeBeforeWarmup = $closed
        # Reassert the file:// policy right before the browser starts: the agent
        # reapplies the managed registry policy on a timer and would otherwise
        # win the race.
        $script:Body.warmupPolicy = Set-LabFirefoxPolicy -LabUrl 'file:///C:/OpenPathLab/first-visit/openpath-firefox-extension.xpi'
        $launch = Start-InSessionVisit -Url 'about:blank' -Tag 'warmup'
        $script:Body.launchOut = $launch.out
        $script:Body.arm = [ordered]@{ mode = 'in-session'; firefox = @($launch.firefox) }
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
            $script:Body.visitPolicy = Set-LabFirefoxPolicy -LabUrl 'file:///C:/OpenPathLab/first-visit/openpath-firefox-extension.xpi'
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
    'check-extension' {
        # Warm-up verification: the policy must have installed and activated the
        # extension, the console prefs are applied for the visits and the warm-up
        # browser is closed cleanly (recording `forced`, the class-boot contract).
        try {
            Write-Output 'CHECK-EXT stage=start'
            Enable-BrowserConsoleVisibility
            Write-Output 'CHECK-EXT stage=console-prefs'
            # The policy install happens shortly after Firefox starts: poll instead
            # of reading the profile once.
            $extension = [ordered]@{ found = $false }
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline) {
                $extension = Get-ExtensionState
                if ($extension.found) { break }
                Start-Sleep -Seconds 5
            }
            Write-Output ('CHECK-EXT stage=poll-done found=' + [string]$extension.found)
            if (-not $extension.found) {
                # A policy install can be staged during the first start; one more
                # start with the browser closed completes it.
                Close-FirefoxProcesses | Out-Null
                $second = Start-InSessionVisit -Url 'about:blank' -Tag 'warmup2'
                Write-Output ('CHECK-EXT second-launch=' + [string]$second.out)
                $deadline2 = (Get-Date).AddSeconds(90)
                while ((Get-Date) -lt $deadline2) {
                    $extension = Get-ExtensionState
                    if ($extension.found) { break }
                    Start-Sleep -Seconds 5
                }
                Write-Output ('CHECK-EXT stage=second-poll-done found=' + [string]$extension.found)
            }
            $closed = Close-FirefoxProcesses
            Write-Output 'CHECK-EXT stage=closed'
            $script:Body.extension = $extension
            $script:Body.closeAfterWarmup = $closed
            if (-not $extension.found) {
                # Slim, literal-path diagnostics: every value is also traced so a
                # late crash still leaves the data in the raw output.
                $studentProfileRoot = "C:\Users\$StudentUserName\AppData\Roaming\Mozilla\Firefox\Profiles"
                $labXpi = 'C:\OpenPathLab\first-visit\openpath-firefox-extension.xpi'
                $profileDirs = @(Get-ChildItem -LiteralPath $studentProfileRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                $xpiBytes = if (Test-Path -LiteralPath $labXpi) { [long](Get-Item -LiteralPath $labXpi).Length } else { -1 }
                $firefoxOwners = @(Get-CimInstance Win32_Process -Filter "Name='firefox.exe'" -ErrorAction SilentlyContinue | ForEach-Object { try { [string]$_.GetOwner().User } catch { 'unknown' } })
                Write-Output ('CHECK-EXT diag profiles=[' + ($profileDirs -join ',') + '] xpiBytes=' + [string]$xpiBytes + ' owners=[' + ($firefoxOwners -join ',') + ']')
                foreach ($profileDir in $profileDirs) {
                    $extFile = "C:\Users\$StudentUserName\AppData\Roaming\Mozilla\Firefox\Profiles\$profileDir\extensions.json"
                    $ids = @()
                    if (Test-Path -LiteralPath $extFile) {
                        try { $ids = @((Get-Content -LiteralPath $extFile -Raw | ConvertFrom-Json).addons | ForEach-Object { [string]$_.id }) }
                        catch { $ids = @('parse-error') }
                    }
                    Write-Output ('CHECK-EXT diag profile=' + $profileDir + ' ids=[' + ($ids -join ',') + ']')
                }
                $aclLines = @((Invoke-Cmd 'icacls.exe' @($labXpi)).out | Select-Object -First 3)
                Write-Output ('CHECK-EXT diag acl=' + ($aclLines -join ' | '))
                $profileIds = [ordered]@{}
                foreach ($profileDir in $profileDirs) {
                    $extFile = "C:\Users\$StudentUserName\AppData\Roaming\Mozilla\Firefox\Profiles\$profileDir\extensions.json"
                    $ids = @()
                    if (Test-Path -LiteralPath $extFile) {
                        try { $ids = @((Get-Content -LiteralPath $extFile -Raw | ConvertFrom-Json).addons | ForEach-Object { [string]$_.id }) }
                        catch { $ids = @('parse-error') }
                    }
                    $profileIds[$profileDir] = $ids
                }
                $xpiSigned = $false
                $xpiId = ''
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                    $zip = [IO.Compression.ZipFile]::OpenRead($labXpi)
                    try {
                        $xpiSigned = @($zip.Entries | Where-Object { $_.FullName -like 'META-INF/*.rsa' }).Count -gt 0
                        $manifestEntry = @($zip.Entries | Where-Object { $_.FullName -eq 'manifest.json' })[0]
                        if ($manifestEntry) {
                            $reader = New-Object IO.StreamReader($manifestEntry.Open())
                            $manifestText = $reader.ReadToEnd()
                            $reader.Close()
                            $manifestJson = $manifestText | ConvertFrom-Json
                            $xpiId = [string]$manifestJson.browser_specific_settings.gecko.id
                            if (-not $xpiId) { $xpiId = [string]$manifestJson.applications.gecko.id }
                        }
                    }
                    finally { $zip.Dispose() }
                }
                catch { $xpiId = 'xpi-read-error' }
                $ffVersion = ''
                try { $ffVersion = [string](Get-Item -LiteralPath (Get-FirefoxInstallPath)).VersionInfo.ProductVersion } catch { }
                $guestClock = [DateTime]::UtcNow.ToString('o')
                Write-Output ('CHECK-EXT diag xpiSigned=' + [string]$xpiSigned + ' xpiId=' + $xpiId + ' firefoxVersion=' + $ffVersion)
                $profileDetail = [ordered]@{}
                foreach ($profileDir in $profileDirs) {
                    $profRoot = Join-Path $studentProfileRoot $profileDir
                    $extDir = Join-Path $profRoot 'extensions'
                    $extFiles = @()
                    if (Test-Path -LiteralPath $extDir) {
                        $extFiles = @(Get-ChildItem -LiteralPath $extDir -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + ':' + [string]$_.Length })
                    }
                    $jsonPath = Join-Path $profRoot 'extensions.json'
                    $jsonBytes = if (Test-Path -LiteralPath $jsonPath) { [long](Get-Item -LiteralPath $jsonPath).Length } else { -1 }
                    $profileDetail[$profileDir] = [ordered]@{ extFiles = $extFiles; extensionsJsonBytes = $jsonBytes }
                }
                $addonsLog = @()
                $addonsPath = Join-Path $script:VisitRoot 'moz\addons.log'
                if (Test-Path -LiteralPath $addonsPath) {
                    $addonsLog = @(Get-Content -LiteralPath $addonsPath -Tail 400 -ErrorAction SilentlyContinue |
                            Where-Object { $_ -match 'Addon|addon|xpi|install|Install|signatur|Signatur|policy|Policy|verify|Verify|blocked|rejected' } |
                            Select-Object -Last 40)
                }
                $extensionsJsonHead = ''
                foreach ($profileDir in $profileDirs) {
                    $jsonPath = Join-Path $studentProfileRoot "$profileDir\extensions.json"
                    if (Test-Path -LiteralPath $jsonPath) {
                        try { $extensionsJsonHead = (Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop).Substring(0, [math]::Min(1500, (Get-Item -LiteralPath $jsonPath).Length)) } catch { }
                        if ($extensionsJsonHead -match 'openpath') { break }
                    }
                }
                $script:Body.extensionDiagnostics = [ordered]@{
                    profiles      = $profileDirs
                    profileIds    = $profileIds
                    profileDetail = $profileDetail
                    addonsLog     = $addonsLog
                    extensionsJsonHead = $extensionsJsonHead
                    xpiBytes      = $xpiBytes
                    xpiSigned     = $xpiSigned
                    xpiId         = $xpiId
                    firefoxVersion = $ffVersion
                    guestClock    = $guestClock
                    firefoxOwners = $firefoxOwners
                }
                $script:Failures.Add('extension-not-installed-by-policy')
            }
            elseif (-not $extension.active) { $script:Failures.Add('extension-installed-but-inactive') }
        }
        catch {
            Write-Output ('CHECK-EXT stage=exception ' + $_.Exception.Message)
            $script:Failures.Add('check-extension-exception')
        }
        Complete-Step
    }
    'wait-firefox' {
        $firefox = @(Wait-FirefoxProcess -TimeoutSeconds 150)
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
        $profile = Get-ExtensionState
        $nativeHost = Get-LogTail -Path (Get-NativeHostLogPath) -Tail 600
        $diagnostics = @($nativeHost | Where-Object { $_ -match 'stage=extension-diagnostic' })
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
            extension            = $profile
            addonsLog            = @($addonsLog | Select-Object -First 30)
            mozExtract           = @($mozExtract | Select-Object -First 600)
            diagnosticLines      = $diagnostics.Count
            diagnosticSample     = @($diagnostics | Select-Object -First 12)
            startupProfiles      = @($profiles | Select-Object -Last 4)
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
