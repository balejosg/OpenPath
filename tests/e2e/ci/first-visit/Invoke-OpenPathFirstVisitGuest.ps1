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

function Get-FirefoxInstallPath {
    foreach ($candidate in @(
            (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return ''
}

function Invoke-SessionLaunch {
    # Runs the wrapper in the student's interactive desktop through a scheduled
    # task owned by the student (/IT). CreateProcessAsUser needs an exact console
    # token; the interactive task is what the Phase 2E controller proved works.
    param([Parameter(Mandatory = $true)][string]$CmdPath, [string]$Tag = 'visit')
    if (-not (Test-Path -LiteralPath $CmdPath)) { throw "launch wrapper missing at $CmdPath" }
    Invoke-Cmd 'schtasks.exe' @('/Delete', '/TN', 'OpenPathFirstVisitFirefox', '/F') | Out-Null
    $create = Invoke-Cmd 'schtasks.exe' @('/Create', '/TN', 'OpenPathFirstVisitFirefox', '/TR', "cmd.exe /c $CmdPath", '/SC', 'ONCE', '/ST', '00:00', '/RU', $StudentUserName, '/RP', $Secret, '/IT', '/F')
    $run = Invoke-Cmd 'schtasks.exe' @('/Run', '/TN', 'OpenPathFirstVisitFirefox')
    Start-Sleep -Seconds 8
    $query = Invoke-Cmd 'schtasks.exe' @('/Query', '/TN', 'OpenPathFirstVisitFirefox', '/V', '/FO', 'LIST')
    $log = @()
    foreach ($file in @(Get-ChildItem 'C:\OpenPathLab\logs' -Filter "firefox-$Tag.log*" -ErrorAction SilentlyContinue)) {
        $log += @(Get-Content -LiteralPath $file.FullName -Tail 15 -ErrorAction SilentlyContinue)
    }
    return [ordered]@{
        created  = $create.exit
        ran      = $run.exit
        taskOut  = @($create.out | Select-Object -First 3)
        query    = @(@($query.out) | Where-Object { $_ -match 'Result|Status|Run As|Task To Run' } | Select-Object -First 6)
        firefoxLog = @($log | Select-Object -First 20)
    }
}

function Invoke-Cmd {
    param([string]$File, [string[]]$Arguments)
    $out = & $File @Arguments 2>&1 | Out-String
    return [ordered]@{ exit = $LASTEXITCODE; out = @($out -split "`r?`n") }
}

function Close-FirefoxProcesses {
    param([int]$GracefulWaitSeconds = 20)
    $before = Get-FirefoxProcesses
    $gracefulExit = $null
    if ($before.Count -gt 0) {
        $gracefulExit = (Invoke-Cmd 'taskkill.exe' @('/IM', 'firefox.exe', '/T')).exit
    }
    $remaining = @(Get-FirefoxProcesses).Count
    for ($index = 0; $index -lt $GracefulWaitSeconds -and $remaining -gt 0; $index++) {
        Start-Sleep -Seconds 1
        $remaining = @(Get-FirefoxProcesses).Count
    }
    $forced = $false
    if ($remaining -gt 0) {
        Invoke-Cmd 'taskkill.exe' @('/IM', 'firefox.exe', '/T', '/F') | Out-Null
        Start-Sleep -Seconds 3
        $forced = $true
        $remaining = @(Get-FirefoxProcesses).Count
    }
    return [ordered]@{ before = $before; gracefulExit = $gracefulExit; forced = $forced; remaining = $remaining }
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

function Write-CleanFirefoxCmd {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Tag)
    $firefox = Get-FirefoxInstallPath
    if (-not $firefox) { throw 'firefox.exe not found' }
    New-Dir 'C:\OpenPathLab\logs'
    New-Dir 'C:\OpenPathLab\moz'
    $cmdPath = "C:\OpenPathLab\first-visit\ff-$Tag.cmd"
    $body = @"
@echo off
set MOZ_LOG=timestamp,rotate:300,nsHostResolver:5,nsHttp:4
set MOZ_LOG_FILE=C:\OpenPathLab\moz\$Tag.log
"$firefox" -new-window "$Url" >> C:\OpenPathLab\logs\firefox-$Tag.log 2>&1
"@
    [IO.File]::WriteAllText($cmdPath, $body, [Text.UTF8Encoding]::new($false))
    return $cmdPath
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
    $json = $payload | ConvertTo-Json -Depth 12 -Compress
    New-Dir (Split-Path -Parent $ResultPath)
    [IO.File]::WriteAllText($ResultPath, ($payload | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Write-Output $json
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
    'warmup' {
        $closed = Close-FirefoxProcesses
        $script:Body.closeBeforeWarmup = $closed
        $cmdPath = Write-CleanFirefoxCmd -Url 'about:blank' -Tag 'warmup'
        $launch = Invoke-SessionLaunch -CmdPath $cmdPath -Tag 'warmup'
        $script:Body.launch = $launch
        Start-Sleep -Seconds 15
        # The first launch creates the profile; console visibility is a lab-only
        # pref set so the background console lands in the Firefox stdout capture.
        Enable-BrowserConsoleVisibility
        $deadline = (Get-Date).AddSeconds(180)
        $extension = [ordered]@{ found = $false }
        while ((Get-Date) -lt $deadline) {
            $extension = Get-ExtensionState
            if ($extension.found -and $extension.active) { break }
            Start-Sleep -Seconds 5
        }
        $script:Body.extension = $extension
        if (-not $extension.found) { $script:Failures.Add('extension-not-installed-by-policy') }
        elseif (-not $extension.active) { $script:Failures.Add('extension-installed-but-inactive') }
        Start-Sleep -Seconds 10
        $closedAfter = Close-FirefoxProcesses
        $script:Body.closeAfterWarmup = $closedAfter
        Complete-Step
    }
    'visit' {
        $plan = Get-FixturePlan
        $waitSeconds = 20
        $existing = Get-FirefoxProcesses
        $launch = $null
        if ($ScenarioId -eq 'first-visit-hot') {
            if ($existing.Count -eq 0) {
                $cmdPath = Write-CleanFirefoxCmd -Url ("http://" + [string]$plan.anchors.a1.host + "/") -Tag 'hot-open'
                $launch = Invoke-SessionLaunch -CmdPath $cmdPath -Tag 'hot-open'
                $deadline = (Get-Date).AddSeconds(120)
                while ((Get-Date) -lt $deadline -and @(Get-FirefoxProcesses).Count -eq 0) { Start-Sleep -Seconds 3 }
                $script:Body.hotWaitSeconds = 300
                Start-Sleep -Seconds 300
            }
            # Same Firefox instance: a new window navigates to the second anchor
            # while the persistent native port stays on the same host process.
            $cmdPath = Write-CleanFirefoxCmd -Url ("http://" + [string]$plan.anchors.a2.host + "/") -Tag 'hot'
            $launch = Invoke-SessionLaunch -CmdPath $cmdPath -Tag 'hot'
            Start-Sleep -Seconds $waitSeconds
            $script:Body.anchor = 'a2'
            $script:Body.anchorUrl = "http://" + [string]$plan.anchors.a2.host + "/"
        }
        else {
            $cmdPath = Write-CleanFirefoxCmd -Url ("http://" + [string]$plan.anchors.a1.host + "/") -Tag 'visit'
            $launch = Invoke-SessionLaunch -CmdPath $cmdPath -Tag 'visit'
            $deadline = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $deadline -and @(Get-FirefoxProcesses).Count -eq 0) { Start-Sleep -Seconds 2 }
            Start-Sleep -Seconds $waitSeconds
            $script:Body.anchor = 'a1'
            $script:Body.anchorUrl = "http://" + [string]$plan.anchors.a1.host + "/"
        }
        $firefox = Get-FirefoxProcesses
        $script:Body.launch = $launch
        $script:Body.firefox = $firefox
        $script:Body.launchedAt = if ($firefox.Count -gt 0) { $firefox[0].created } else { '' }
        $script:Body.hostPids = @(Get-LogTail -Path (Get-NativeHostLogPath) -Tail 400 -Patterns @('initialization completed')) | ForEach-Object { if ($_ -match 'pid=(\d+)') { $Matches[1] } }
        if ($firefox.Count -eq 0) { $script:Failures.Add('firefox-did-not-start') }
        Complete-Step
    }
    'collect' {
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
        $mozFiles = @(Get-ChildItem 'C:\OpenPathLab\moz' -Filter '*.log*' -ErrorAction SilentlyContinue)
        foreach ($mozFile in $mozFiles) {
            $mozExtract += @(Select-String -LiteralPath $mozFile.FullName -Pattern 'nsHostResolver|nsHttp' -ErrorAction SilentlyContinue |
                    Select-Object -First 400 | ForEach-Object { $_.Line })
        }
        $script:Body.collect = [ordered]@{
            extension            = $profile
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
        # Blocked-screen navigation to an unlisted host in a new window; the host
        # side captures the console screendump while it is open.
        $cmdPath = Write-CleanFirefoxCmd -Url ("http://" + [string]$plan.unlisted + "/") -Tag 'blocked'
        $script:Body.blockedLaunch = Invoke-SessionLaunch -CmdPath $cmdPath -Tag 'blocked'
        Start-Sleep -Seconds 12
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
