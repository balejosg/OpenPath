# Phase 3A first-visit lane: controller-side phases and metrics.
#
# Dot-sourced by ProxmoxWindowsLab.psm1 so it shares the module scope (internal
# helpers, transport contract and constants). The lane is site-agnostic: the
# fixture plan (anchors, dependency hosts, blocked host) is generated per run by
# tests/e2e/ci/first-visit/fixture_server.py and fetched at runtime.

# Phase 3A.3: verdict and result contracts shared with the guest harness.
Import-Module (Join-Path $PSScriptRoot '..\first-visit\FirstVisitResult.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\first-visit\FirstVisitWarmup.psm1') -Force
# Phase 6 C: real-site canary metrics/verdict (pure, tested).
Import-Module (Join-Path $PSScriptRoot '..\first-visit\FirstVisitSiteCanary.psm1') -Force
# Phase 7 L1: update-contention analysis (pure, tested).
Import-Module (Join-Path $PSScriptRoot '..\first-visit\FirstVisitUpdateContention.psm1') -Force
# Phase 7 P1: stall-gap classification (pure, tested).
Import-Module (Join-Path $PSScriptRoot '..\first-visit\FirstVisitStall.psm1') -Force

$script:OpenPathFirstVisitCaptureOffsets = @(5, 10, 15, 20, 30, 60)
$script:OpenPathFirstVisitRefreshSettleSeconds = 30
$script:OpenPathFirstVisitObserveSettleSeconds = 15
$script:OpenPathFirstVisitHotWindowSeconds = 300
$script:OpenPathFirstVisitHotSecondSettleSeconds = 20
# Phase 6: the post-security settle and the inter-attempt retry are test
# knobs; the lane tests zero them so the suite never spends minutes sleeping.
$script:OpenPathFirstVisitSecuritySettleSeconds = 20
$script:OpenPathFirstVisitStepRetryDelaySeconds = 15
# Phase 5.2 C1: extra seconds the report wait keeps polling for the page's
# final blocked-path probe (0 in the contract tests), and the wait cap.
$script:OpenPathFirstVisitReportGraceSeconds = 15
$script:OpenPathFirstVisitReportWaitSeconds = 120
# Phase 5 A2: per-phase step trace (step, elapsed, source, status). Append-only
# and persisted after every step so a killed controller can still be measured.
$script:OpenPathFirstVisitStepTrace = $null

function ConvertTo-OpenPathFirstVisitSceneStartedIso {
    <#
    .SYNOPSIS
    Normalizes the persisted scene start into invariant ISO-8601 UTC.
    .DESCRIPTION
    Phase 7 L3: ConvertFrom-Json turns the ISO string back into a [datetime];
    formatting that with [string] uses the host locale (10/07/2026 13:14:47)
    and no XPath SystemTime comparison can match it. This helper keeps the
    value invariant whatever shape it arrives in.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value = $null)

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Get-OpenPathFirstVisitHarnessSourcePath {    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'first-visit\Invoke-OpenPathFirstVisitGuest.ps1')
}

function Get-OpenPathFirstVisitLauncherSourcePath {
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'first-visit\student-session-launch.ps1')
}

function Get-OpenPathFirstVisitFixturesRoot {
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'first-visit')
}

function Get-OpenPathFirstVisitSettings {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config
    )
    $firstVisit = Get-OpenPathLabField -InputObject $Payload -Name 'firstVisit'
    $scenario = if ($firstVisit) { [string](Get-OpenPathLabField -InputObject $firstVisit -Name 'scenario') } else { '' }
    if ([string]::IsNullOrWhiteSpace($scenario)) { $scenario = 'first-visit-settled' }
    $hostAddress = [string](Get-OpenPathLabField -InputObject $Config -Name 'hostAddress')
    if ([string]::IsNullOrWhiteSpace($hostAddress)) { throw 'first-visit-host-address-missing' }
    $upstream = if ($env:OPENPATH_FIRST_VISIT_DNS_UPSTREAM) { [string]$env:OPENPATH_FIRST_VISIT_DNS_UPSTREAM } else { '192.168.1.133' }
    # Phase 6 B: smart_app_control = unchanged (default) | on.
    # Phase 7 L2: on-before-install applies SAC before the product install.
    $smartAppControl = if ($firstVisit) { [string](Get-OpenPathLabField -InputObject $firstVisit -Name 'smartAppControl') } else { '' }
    if ([string]::IsNullOrWhiteSpace($smartAppControl)) { $smartAppControl = 'unchanged' }
    $smartAppControl = $smartAppControl.Trim().ToLowerInvariant()
    if ($smartAppControl -notin @('unchanged', 'on', 'on-before-install')) { throw "first-visit-smart-app-control-invalid:$smartAppControl" }
    if ($smartAppControl -in @('on', 'on-before-install') -and $scenario -notlike '*class-boot*') {
        throw 'first-visit-smart-app-control-requires-class-boot'
    }
    # Phase 6 C: real-site canary inputs (only the site scenario uses them).
    $siteUrl = if ($firstVisit) { [string](Get-OpenPathLabField -InputObject $firstVisit -Name 'siteUrl') } else { '' }
    $siteWhitelist = if ($firstVisit) { [string](Get-OpenPathLabField -InputObject $firstVisit -Name 'siteWhitelist') } else { '' }
    $siteDomains = @($siteWhitelist -split ',' | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    # Phase 6 C: `site` is the settled-like canary; `site-class-boot` runs the
    # same real-site plan through the class-boot refresh (reboot + logon).
    $siteMode = ($scenario -in @('first-visit-site', 'first-visit-site-class-boot'))
    # Phase 7 L1: `update-contention` runs the settled-like visit with the
    # product update started right before the browser launch.
    $updateContention = ($scenario -eq 'first-visit-update-contention')
    if ($siteMode -and [string]::IsNullOrWhiteSpace($siteUrl)) { throw 'first-visit-site-url-required' }
    if ($siteMode) {
        # The URL and the domains travel through a bash command on the Proxmox
        # host: allow only URL-safe characters, never quotes/spaces/backticks.
        if ($siteUrl.Trim() -notmatch '^https?://[A-Za-z0-9][A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]*$') {
            throw 'first-visit-site-url-invalid'
        }
        foreach ($domain in $siteDomains) {
            if ($domain -notmatch '^[a-z0-9][a-z0-9.-]*[a-z0-9]$') { throw "first-visit-site-domain-invalid:$domain" }
        }
        if ($siteDomains.Count -eq 0) { throw 'first-visit-site-whitelist-required' }
    }
    return [pscustomobject]@{
        Scenario        = $scenario
        FixtureUrl      = "http://$hostAddress"
        DnsIp           = $hostAddress
        DnsUpstream     = $upstream
        HostAddress     = $hostAddress
        SmartAppControl = $smartAppControl
        SiteMode        = $siteMode
        SiteUrl         = $siteUrl.Trim()
        SiteDomains     = $siteDomains
        UpdateContention = $updateContention
    }
}

function Start-OpenPathFirstVisitFixture {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
        [string]$Scenario = 'first-visit-settled',
        [string]$SiteUrl = '',
        [string[]]$SiteDomains = @()
    )
    $stagingRoot = [string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot')
    if ([string]::IsNullOrWhiteSpace($stagingRoot)) { $stagingRoot = '/var/tmp/openpath-first-visit' }
    $staging = "$stagingRoot/$RunId".Replace('//', '/')
    # Phase 5.3 B4: the scenario selects the served whitelist (floor
    # pre-whitelists every dependency host). `control` is the historical alias.
    # Phase 6 C: the site canary serves only the requested real domains.
    $fixtureScenario = if ($Scenario -eq 'first-visit-control') { 'floor' } elseif ($Scenario -eq 'first-visit-floor') { 'floor' } elseif ($Scenario -in @('first-visit-site', 'first-visit-site-class-boot')) { 'site' } else { 'settled' }
    $settings = Get-OpenPathFirstVisitSettings -Payload ([pscustomobject]@{ firstVisit = [pscustomobject]@{ scenario = $Scenario; siteUrl = $SiteUrl; siteWhitelist = ($SiteDomains -join ',') } }) -Config $Config
    $localFixtures = Get-OpenPathFirstVisitFixturesRoot

    & $Transport.InvokeHostCommand @('mkdir', '-p', "$staging/state") '' | Out-Null
    foreach ($name in @('fixture_server.py', 'dns_fixture.py')) {
        & $Transport.CopyFileToHost (Join-Path $localFixtures $name) "$staging/$name" | Out-Null
    }
    # A stale instance from an interrupted run keeps the ports bound and the
    # next start fails with EADDRINUSE; clear every fixture instance first.
    # The bracket form keeps pkill from matching its own ssh command line.
    & $Transport.InvokeHostCommand @('bash', '-lc', "pkill -f 'fixture[_]server.py --state-dir' || true; pkill -f 'dns[_]fixture.py --state-dir' || true; sleep 2; echo cleared") '' | Out-Null
    $siteArgs = ''
    if ($fixtureScenario -eq 'site') {
        $siteArgs = "--site-url '$($settings.SiteUrl)' --site-domains '$($settings.SiteDomains -join ',')' "
    }
    $startCommand = "setsid nohup python3 $staging/dns_fixture.py --state-dir $staging/state --upstream $($settings.DnsUpstream) > $staging/dns.log 2>&1 < /dev/null & sleep 1; " +
    "setsid nohup python3 $staging/fixture_server.py --state-dir $staging/state --port 80 --run-id $RunId --ip $($settings.HostAddress) --scenario $fixtureScenario $siteArgs> $staging/fixture.log 2>&1 < /dev/null & sleep 2; echo started"
    $startOutput = (& $Transport.InvokeHostCommand @('bash', '-lc', $startCommand) '').Trim()
    $planText = ''
    $httpDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $httpDeadline -and -not $planText.StartsWith('{')) {
        $planText = (& $Transport.InvokeHostCommand @('curl', '-s', '--max-time', '10', 'http://127.0.0.1/plan.json') '').Trim()
        if (-not $planText.StartsWith('{')) { Start-Sleep -Seconds 5 }
    }
    if (-not $planText.StartsWith('{')) {
        $diag = (& $Transport.InvokeHostCommand @('bash', '-lc', "tail -3 $staging/fixture.log 2>/dev/null; echo ---; tail -3 $staging/dns.log 2>/dev/null; echo ---; ps aux | grep -cE 'fixture[_]server|dns[_]fixture'") '').Trim()
        throw "first-visit-fixture-plan-unavailable start=[$startOutput] diag=$(($diag -replace '\s+', ' '))"
    }
    # The DNS fixture must answer directly on the lab host before any guest uses it.
    $dnsProbe = @'
import socket
q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + b"".join(
    bytes([len(part)]) + part.encode() for part in "probe.127.0.0.1.sslip.io".split(".")
) + b"\x00\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
s.sendto(q, ("127.0.0.1", 53))
d, _ = s.recvfrom(512)
print("DNS-OK" if d[-4:] == bytes([127, 0, 0, 1]) else "DNS-BAD")
'@
    $dnsOk = $false
    $dnsDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $dnsDeadline -and -not $dnsOk) {
        $dnsResult = (& $Transport.InvokeHostCommand @('python3', '-c', $dnsProbe) '').Trim()
        $dnsOk = $dnsResult -match 'DNS-OK'
        if (-not $dnsOk) { Start-Sleep -Seconds 5 }
    }
    if (-not $dnsOk) {
        $log = (& $Transport.InvokeHostCommand @('bash', '-lc', "tail -5 $staging/dns.log 2>/dev/null || true") '').Trim()
        throw "first-visit-dns-fixture-unavailable log=$log"
    }
    $plan = $planText | ConvertFrom-Json
    New-Item -ItemType Directory -Path (Join-Path $ArtifactsRoot 'fixture') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $ArtifactsRoot 'fixture') 'plan.json'), $planText, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Staging = $staging; Plan = $plan; Settings = $settings }
}

function Stop-OpenPathFirstVisitFixture {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot
    )
    try {
        $stagingRoot = [string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot')
        if ([string]::IsNullOrWhiteSpace($stagingRoot)) { $stagingRoot = '/var/tmp/openpath-first-visit' }
        $staging = "$stagingRoot/$RunId".Replace('//', '/')
        foreach ($file in @('requests.jsonl', 'reports.jsonl', 'last_report.json', 'dns.jsonl', 'fixture.log')) {
            $text = (& $Transport.InvokeHostCommand @('bash', '-lc', "test -f $staging/state/$file && cat $staging/state/$file || true") '').Trim()
            if ($text) {
                $target = Join-Path (Join-Path $ArtifactsRoot 'fixture') $file
                [IO.File]::WriteAllText($target, $text, [Text.UTF8Encoding]::new($false))
            }
        }
        & $Transport.InvokeHostCommand @('bash', '-lc', "pkill -f 'fixture[_]server.py --state-dir $staging' || true; pkill -f 'dns[_]fixture.py --state-dir $staging' || true; echo stopped") '' | Out-Null
    }
    catch {
        Write-Warning "first-visit fixture stop failed: $($_.Exception.Message)"
    }
}

function Get-OpenPathFirstVisitCapabilityArgument {
    <#
    .SYNOPSIS
    Comma-joined live-signal capability list for the guest harness.
    #>
    [CmdletBinding()]
    param(
        [bool]$NativeHostLog = $false,
        [bool]$BackgroundStart = $false,
        [bool]$DiagnosticBatch = $false
    )
    $keys = @()
    if ($NativeHostLog) { $keys += 'native-host-log' }
    if ($BackgroundStart) { $keys += 'background-start' }
    if ($DiagnosticBatch) { $keys += 'diagnostic-batch' }
    return ($keys -join ',')
}

function Get-OpenPathFirstVisitBuildCapabilities {
    <#
    .SYNOPSIS
    Live signals the template build can emit (Phase 3A.2 K1).
    .DESCRIPTION
    The warm-up verdict only fails on a missing live signal when the build
    actually supports it. The thresholds are historical facts of this lane; an
    unknown SHA (or missing git) fails open and only the state signal applies.
    #>
    [CmdletBinding()]
    param(
        [string]$SourceSha = '',
        # Test seam: the contract tests inject a deterministic ancestry probe.
        [scriptblock]$IsAncestor = $null
    )
    if ([string]::IsNullOrWhiteSpace($SourceSha)) {
        return [pscustomobject]@{ nativeHostLog = $false; backgroundStart = $false; diagnosticBatch = $false; CapabilityArgument = '' }
    }
    $nativeHostLog = $false
    $backgroundStart = $false
    $diagnosticBatch = $false
    try {
        $thresholds = [ordered]@{
            nativeHostLog   = '196664c4'
            # Both E1 signals require the diagnostics sanitizer ([int]$ts ->
            # [long], 7fe4d310): before it, extension diagnostics never reached
            # the log, so requiring them produced false 'background-start-missing'
            # reasons on c28bf26e-style templates (Phase 3A.3 correction 5).
            backgroundStart = '7fe4d310'
            diagnosticBatch = '7fe4d310'
        }
        $probe = $IsAncestor
        if (-not $probe) {
            $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
            $repoRootResolved = $repoRoot
            $probe = {
                param($Base, $Head)
                & git -C $repoRootResolved merge-base --is-ancestor $Base $Head 2>$null | Out-Null
                return ($LASTEXITCODE -eq 0)
            }.GetNewClosure()
        }
        foreach ($name in @($thresholds.Keys)) {
            $ancestor = $false
            try { $ancestor = [bool](& $probe $thresholds[$name] $SourceSha) } catch { $ancestor = $false }
            if ($ancestor) {
                switch ($name) {
                    'nativeHostLog' { $nativeHostLog = $true }
                    'backgroundStart' { $backgroundStart = $true }
                    'diagnosticBatch' { $diagnosticBatch = $true }
                }
            }
        }
    }
    catch { }
    return [pscustomobject]@{
        nativeHostLog      = $nativeHostLog
        backgroundStart    = $backgroundStart
        diagnosticBatch    = $diagnosticBatch
        CapabilityArgument = Get-OpenPathFirstVisitCapabilityArgument -NativeHostLog $nativeHostLog -BackgroundStart $backgroundStart -DiagnosticBatch $diagnosticBatch
    }
}

function Read-OpenPathFirstVisitGuestText {
    # Best-effort text read of one guest file; never throws. Used to recover a
    # result the stdout pipeline lost.
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [int]$TimeoutSeconds = 120
    )
    $literal = ConvertTo-OpenPathLabPowerShellLiteral -Value $GuestPath
    $script = "if (Test-Path -LiteralPath $literal) { [IO.File]::ReadAllText($literal) } else { Write-Output 'MISSING' }"
    try {
        $text = (& $Transport.InvokeGuestPowerShell $Vmid $script $TimeoutSeconds | Out-String)
    }
    catch { return '' }
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $trimmed = $text.Trim()
    if ($trimmed -eq 'MISSING') { return '' }
    return $trimmed
}

function Resolve-OpenPathFirstVisitResultParts {
    <#
    .SYNOPSIS
    Replaces firstVisitPart descriptors in a guest result with their content.
    .DESCRIPTION
    Phase 5 A2: values too large for the inline result JSON travel as part files
    next to it. This reads each referenced part from the guest, archives it in
    the run artifacts and assigns it back into the parsed result so consumers
    see the original value. Best-effort: a missing part leaves the descriptor
    and the caller's guards treat it as absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Harness,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot
    )
    $body = Get-OpenPathLabField -InputObject $Harness -Name 'body'
    $partMap = Get-OpenPathLabField -InputObject $body -Name 'resultParts'
    if (-not $partMap) { return }
    $guestPartsDir = $Paths.GuestDir.TrimEnd('\') + "\result-$Phase-$Step.json.parts"
    foreach ($entry in @($partMap.PSObject.Properties)) {
        $flatKey = [string]$entry.Name
        $partName = [string]$entry.Value
        if ([string]::IsNullOrWhiteSpace($flatKey) -or [string]::IsNullOrWhiteSpace($partName)) { continue }
        $segments = @($flatKey -split '\.')
        if ($segments.Count -lt 3 -or $segments[0] -ne 'body' -or $segments[1] -ne 'state') { continue }
        $text = Read-OpenPathFirstVisitGuestText -Transport $Transport -Vmid $Vmid -GuestPath ($guestPartsDir + '\' + $partName) -TimeoutSeconds 120
        if (-not $text) { continue }
        try { $value = $text | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        try { [IO.File]::WriteAllText((Join-Path $ArtifactsRoot "guest-$Phase-$Step.part-$partName"), $text, [Text.UTF8Encoding]::new($false)) } catch { }
        $node = Get-OpenPathLabField -InputObject $Harness -Name 'body'
        $node = Get-OpenPathLabField -InputObject $node -Name 'state'
        for ($index = 2; $index -lt ($segments.Count - 1); $index++) {
            if ($null -eq $node) { break }
            $node = Get-OpenPathLabField -InputObject $node -Name $segments[$index]
        }
        if ($null -eq $node) { continue }
        $leaf = [string]$segments[-1]
        try {
            if ($node -is [System.Collections.IDictionary]) { $node[$leaf] = $value }
            elseif ($node.PSObject.Properties[$leaf]) { $node.$leaf = $value }
        }
        catch {
            Write-Warning "first-visit part merge failed for $flatKey : $($_.Exception.Message)"
        }
    }
}

function Get-OpenPathFirstVisitStringArray {
    <#
    .SYNOPSIS
    Returns only the string elements of a collect value.
    .DESCRIPTION
    The guest serializer may deliver a missing array as an empty string or as a
    part descriptor object; binding either into [string[]] without filtering
    aborted the whole phase. Never throws.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value = $null)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { if ($Value) { return @($Value) } return @() }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value | Where-Object { $_ -is [string] -and $_ }) }
    return @()
}

function Add-OpenPathFirstVisitStepTrace {
    <#
    .SYNOPSIS
    Records one guest step timing entry and persists the trace next to the run
    artifacts so a killed controller still explains where the time went.
    .DESCRIPTION
    Phase 5.2 C3: the entry is written with status=running BEFORE the step is
    invoked and updated in place when it ends. A phase timeout can therefore
    name the step that was in progress, not only the last one that finished.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [AllowNull()][string]$ArtifactsRoot = '',
        [AllowNull()][string]$Phase = ''
    )
    if (-not $script:OpenPathFirstVisitStepTrace) {
        $script:OpenPathFirstVisitStepTrace = New-Object System.Collections.ArrayList
    }
    $existing = $null
    foreach ($candidate in @($script:OpenPathFirstVisitStepTrace)) {
        if ([string]$candidate['phase'] -eq [string]$Entry['phase'] -and
            [string]$candidate['step'] -eq [string]$Entry['step'] -and
            [string]$candidate['startedAt'] -eq [string]$Entry['startedAt']) {
            $existing = $candidate
            break
        }
    }
    if ($existing) {
        foreach ($key in @($Entry.Keys)) { $existing[[string]$key] = $Entry[$key] }
    }
    else {
        $null = $script:OpenPathFirstVisitStepTrace.Add($Entry)
    }
    if ([string]::IsNullOrWhiteSpace($ArtifactsRoot) -or [string]::IsNullOrWhiteSpace($Phase)) { return }
    try {
        $path = Join-Path $ArtifactsRoot "$Phase-step-trace.json"
        [IO.File]::WriteAllText($path, (@($script:OpenPathFirstVisitStepTrace) | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    }
    catch { }
}

function Get-OpenPathFirstVisitHarnessProcessCount {
    <#
    .SYNOPSIS
        Counts guest powershell.exe processes still running the first-visit
        harness by command line. -1 when the query itself failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid
    )
    $script = "try { @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { `$_.Name -eq 'powershell.exe' -and `$_.CommandLine -like '*Invoke-OpenPathFirstVisitGuest*' }).Count } catch { -1 }"
    try {
        if ($Transport.Contains('InvokeGuestPowerShellOnce')) {
            $output = & $Transport.InvokeGuestPowerShellOnce $Vmid $script 30
        }
        else {
            $output = & $Transport.InvokeGuestPowerShell $Vmid $script 30
        }
        $text = ([string]$output).Trim()
        if ($text -match '(-?\d+)\s*$') { return [int]$Matches[1] }
    }
    catch { }
    return -1
}

function Send-OpenPathFirstVisitStep {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$HarnessGuestPath,
        [string]$PersonalizedGuestPath = '',
        [string]$Capabilities = '',
        [string]$FixtureBaselineJson = '',
        [int]$TimeoutSeconds = 900,
        # Read-only steps may be re-run once after a transport error; steps with
        # side effects (install, warm-up, visit) never are.
        [switch]$AllowRetry,
        # Best-effort steps (host signals/events) return a failed harness instead
        # of throwing, so partial evidence still reaches the caller.
        [switch]$AllowFailed
    )
    $stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stepEntry = [ordered]@{
        phase          = $Phase
        step           = $Step
        startedAt      = [DateTime]::UtcNow.ToString('o')
        endedAt        = ''
        elapsedMs      = -1
        timeoutSeconds = $TimeoutSeconds
        attempts       = 0
        resultSource   = ''
        status         = 'running'
        failures       = @()
    }
    $artifactsRoot = [string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')
    # Phase 5.2 C3: persist the running entry before invoking the step so a
    # killed controller (phase timeout) still names the step in progress.
    Add-OpenPathFirstVisitStepTrace -Entry $stepEntry -ArtifactsRoot $artifactsRoot -Phase $Phase
    try {
        Update-OpenPathLabActiveHeartbeat
        $resultPath = $Paths.GuestDir.TrimEnd('\') + "\result-$Phase-$Step.json"
    $statePath = $Paths.GuestDir.TrimEnd('\') + '\guest-state.json'
    $arguments = @(
        '& powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $HarnessGuestPath),
        '-Phase ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Phase),
        '-Step ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Step),
        '-ScenarioId ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value ([string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId'))),
        '-ResultPath ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $resultPath),
        '-StudentUserName ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Settings.StudentUserName),
        '-AdminUserName ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Settings.AdminUserName),
        '-Secret ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Settings.GuestSecret),
        '-StatePath ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $statePath)
    )
    if ($PersonalizedGuestPath) { $arguments += '-PersonalizedExePath ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $PersonalizedGuestPath) }
    if ($Capabilities) { $arguments += '-Capabilities ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Capabilities) }
    if ($FixtureBaselineJson) { $arguments += '-FixtureBaselineJson ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $FixtureBaselineJson) }
    # Phase 6.1 C: every step of the scene shares the prepare start mark so the
    # CodeIntegrity XML queries are bounded to the scene.
    $sceneStartedAtArgument = [string](Get-OpenPathLabField -InputObject $Settings -Name 'SceneStartedAt')
    if ($sceneStartedAtArgument) { $arguments += '-SceneStartedAt ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $sceneStartedAtArgument) }
    $arguments += '| Out-String'
    $script = ($arguments -join ' ') + "`nWrite-Output ('__HARNESS_EXIT__=' + [string]`$LASTEXITCODE)"
    $attemptTimeout = [math]::Min($TimeoutSeconds, 600)
    $maxAttempts = if ($AllowRetry) { 2 } else { 1 }
    $output = ''
    $fileText = ''
    $exitCode = -999
    $exitKnown = $false
    $timedOut = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Transport.Contains('InvokeGuestPowerShellOnce')) {
                $output = & $Transport.InvokeGuestPowerShellOnce $Vmid $script $attemptTimeout
            }
            else {
                $output = & $Transport.InvokeGuestPowerShell $Vmid $script $attemptTimeout
            }
        }
        catch {
            # Phase 5.3 B2: a timeout leaves a live guest process; the transport
            # killed its tree and this step is over, never relaunched.
            $invokeError = [string]$_.Exception.Message
            if ($invokeError -like '*guest-query-timeout*') {
                $timedOut = $true
                $pidMatch = [regex]::Match($invokeError, 'pid=([0-9]+)')
                $killMatch = [regex]::Match($invokeError, 'kill=([A-Za-z-]+)')
                if ($pidMatch.Success) { $stepEntry.killedPid = [int]$pidMatch.Groups[1].Value }
                $stepEntry.killReason = 'step-timeout'
                $stepEntry.killResult = if ($killMatch.Success) { [string]$killMatch.Groups[1].Value } else { 'unknown' }
            }
            $output = ''
        }
        $exitMatch = [regex]::Match([string]$output, '__HARNESS_EXIT__=(-?\d+)')
        if ($exitMatch.Success) {
            $exitCode = [int]$exitMatch.Groups[1].Value
            $exitKnown = $true
        }
        if (Get-FirstVisitResultFromOutput -Output ([string]$output)) { break }
        # Phase 3A.3 L3: the harness writes the result file before printing it.
        # A written result means the step ran, so it must never be re-executed
        # (a doubled install or a re-polled wait-firefox was the 3A.2 failure).
        $fileText = Read-OpenPathFirstVisitGuestText -Transport $Transport -Vmid $Vmid -GuestPath $resultPath -TimeoutSeconds 120
        if (-not $fileText) {
            $fileText = Read-OpenPathFirstVisitGuestText -Transport $Transport -Vmid $Vmid -GuestPath ($resultPath + '.partial.json') -TimeoutSeconds 120
        }
        if ($fileText) { break }
        # A killed attempt is terminal even for read-only steps: the result file
        # lookup above covers the evidence and a relaunch would double the step.
        if ($timedOut -or $attempt -ge $maxAttempts) { break }
        Update-OpenPathLabActiveHeartbeat
        if ($script:OpenPathFirstVisitStepRetryDelaySeconds -gt 0) { Start-Sleep -Seconds $script:OpenPathFirstVisitStepRetryDelaySeconds }
    }
    $resolved = Resolve-FirstVisitGuestResult -Output ([string]$output) -FileText $fileText
    if (-not $resolved.json) {
        # Archive the raw guest output so a missing result still explains itself.
        try {
            $rawPath = Join-Path $artifactsRoot "guest-$Phase-$Step.raw.txt"
            [IO.File]::WriteAllText($rawPath, ([string]$output).Substring(0, [math]::Min(6000, ([string]$output).Length)), [Text.UTF8Encoding]::new($false))
        }
        catch { }
        throw "first-visit-guest-result-missing-$Phase-$Step"
    }
    try { $harness = $resolved.json | ConvertFrom-Json -ErrorAction Stop }
    catch {
        try {
            $rawPath = Join-Path $artifactsRoot "guest-$Phase-$Step.raw.txt"
            [IO.File]::WriteAllText($rawPath, ([string]$output).Substring(0, [math]::Min(6000, ([string]$output).Length)), [Text.UTF8Encoding]::new($false))
        }
        catch { }
        throw "first-visit-guest-result-invalid-$Phase-$Step"
    }
    # Phase 5 A2: restore values that traveled as part files and archive them.
    try {
        Resolve-OpenPathFirstVisitResultParts -Harness $harness -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase $Phase -Step $Step -ArtifactsRoot $artifactsRoot
    }
    catch { Write-Warning "first-visit result part resolution failed: $($_.Exception.Message)" }
    $resultArchive = Join-Path $artifactsRoot "guest-$Phase-$Step.json"
    try { [IO.File]::WriteAllText($resultArchive, $resolved.json, [Text.UTF8Encoding]::new($false)) } catch { }
    try { [IO.File]::WriteAllText((Join-Path $artifactsRoot "guest-$Phase-$Step.result-source.txt"), ([string]$resolved.source + " stdoutValid=$($resolved.stdoutValid) fileValid=$($resolved.fileValid)"), [Text.UTF8Encoding]::new($false)) } catch { }
    if ($resolved.source -eq 'result-file' -and [string]$harness.status -eq 'partial') {
        # A partial write means the step was interrupted at a milestone: the
        # evidence is useful, the step is not a pass.
        $harness.status = 'failed'
        $harness.failures = @($harness.failures) + @('step-interrupted')
    }
    # When the result came from the file, the exit marker may be missing or
    # belong to a killed stdout: the file is the harness' own write and wins.
    $exitMismatch = ($resolved.source -ne 'result-file') -and $exitKnown -and $exitCode -ne 0
    $stepEntry.attempts = [int]$attempt
    $stepEntry.resultSource = [string]$resolved.source
    if ([string]$harness.status -ne 'passed' -or $exitMismatch) {
        $stepEntry.status = [string]$harness.status
        $stepEntry.failures = @($harness.failures)
        if ($AllowFailed) { return $harness }
        $failures = @($harness.failures) -join ','
        $bodyJson = ($harness.body | ConvertTo-Json -Depth 6 -Compress)
        throw "first-visit-guest-step-failed-$Phase-$Step-$failures body=$bodyJson"
    }
    $stepEntry.status = [string]$harness.status
    return $harness
    }
    catch {
        # keep the step trace on any control-flow error so a failed phase (or a
        # killed controller, via the on-disk trace) names the step and the time.
        $stepEntry.status = 'error'
        $stepEntry.failures = @([string]$_.Exception.Message)
        throw
    }
    finally {
        $stepStopwatch.Stop()
        $stepEntry.endedAt = [DateTime]::UtcNow.ToString('o')
        $stepEntry.elapsedMs = $stepStopwatch.ElapsedMilliseconds
        # Phase 5.3 B2: record that no harness process from previous steps is
        # still alive in the guest (command-line count).
        try {
            $stepEntry.harnessProcessesAfter = [int](Get-OpenPathFirstVisitHarnessProcessCount -Transport $Transport -Vmid $Vmid)
        }
        catch { $stepEntry.harnessProcessesAfter = -1 }
        Add-OpenPathFirstVisitStepTrace -Entry $stepEntry -ArtifactsRoot $artifactsRoot -Phase $Phase
    }
}

function Write-OpenPathFirstVisitGuestFixtureInfo {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][object]$Plan
    )
    $payload = [ordered]@{ fixtureUrl = $Settings.FixtureUrl; dnsIp = $Settings.DnsIp; plan = $Plan } | ConvertTo-Json -Depth 8 -Compress
    $literal = ConvertTo-OpenPathLabPowerShellLiteral -Value $payload
    $script = @"
New-Item -ItemType Directory -Path 'C:\OpenPathLab\first-visit' -Force | Out-Null
[IO.File]::WriteAllText('C:\OpenPathLab\first-visit\fixture.json', $literal, [Text.UTF8Encoding]::new(`$false))
Copy-Item 'C:\OpenPathLab\first-visit\student-session-launch.ps1' -Destination 'C:\OpenPathLab\first-visit\student-session-launch.ps1' -Force -ErrorAction SilentlyContinue
Write-Output 'fixture-info-written'
"@
    & $Transport.InvokeGuestPowerShell $Vmid $script 120 | Out-Null
}

function Copy-OpenPathFirstVisitGuestFile {
    <#
    .SYNOPSIS
        Copies a bounded tail of a guest file to the evidence directory.
    .DESCRIPTION
    Phase 5.3 B8: `C:\OpenPath\logs\openpath.log` does not exist (the agent log
    is `data\logs\openpath.log`), so the copy silently failed and no worker
    trace reached the artifacts. The guest reads the last $MaxBytes with shared
    access, the result names the path/bytes/error, and the caller records it.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [int]$MaxBytes = 262144,
        [string]$Reason = ''
    )
    $literal = ConvertTo-OpenPathLabPowerShellLiteral -Value $GuestPath
    $script = @"
`$path = $literal
`$result = [ordered]@{ path = `$path; exists = `$false; bytes = 0; base64 = ''; error = '' }
if (Test-Path -LiteralPath `$path -PathType Leaf) {
    `$result.exists = `$true
    try {
        `$stream = [IO.File]::Open(`$path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            `$length = `$stream.Length
            if (`$length -gt $MaxBytes) { `$stream.Seek(`$length - $MaxBytes, [IO.SeekOrigin]::Begin) | Out-Null }
            `$reader = New-Object IO.StreamReader(`$stream)
            `$text = `$reader.ReadToEnd()
            `$result.bytes = `$text.Length
            `$result.base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(`$text))
        }
        finally { `$stream.Dispose() }
    }
    catch { `$result.error = [string]`$_.Exception.Message }
}
`$result | ConvertTo-Json -Compress
"@
    $output = (& $Transport.InvokeGuestPowerShell $Vmid $script 300 | Out-String).Trim()
    $jsonLine = @($output -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    $result = $null
    if ($jsonLine) {
        try { $result = [string]$jsonLine | ConvertFrom-Json } catch { $result = $null }
    }
    if ($result -and $result.base64) {
        try {
            [IO.File]::WriteAllBytes($LocalPath, [Convert]::FromBase64String([string]$result.base64))
            return [pscustomobject][ordered]@{ ok = $true; reason = $Reason; path = $GuestPath; bytes = [int]$result.bytes; error = '' }
        }
        catch {
            return [pscustomobject][ordered]@{ ok = $false; reason = $Reason; path = $GuestPath; bytes = 0; error = "local-write-failed: $($_.Exception.Message)" }
        }
    }
    $errorText = if ($result -and $result.error) { [string]$result.error } elseif ($result -and -not $result.exists) { 'guest-path-missing' } else { 'guest-copy-unparsable' }
    return [pscustomobject][ordered]@{ ok = $false; reason = $Reason; path = $GuestPath; bytes = 0; error = $errorText }
}

function Get-OpenPathFirstVisitReportVerdict {
    <#
    .SYNOPSIS
    Pure verdict for one first-visit run, from the page self-report.
    .DESCRIPTION
    wave1/2/3 are complete when every criterion flag is true and the last
    reported mark for the wave is within the threshold. Reloads come from the
    in-page session counter. A missing report is never a pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Report,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [int]$SettledWaveThresholdMs = 15000,
        [int]$ClassBootWaveThresholdMs = 30000,
        [int]$MaxReloadsSettled = 0,
        [int]$MaxReloadsClassBoot = 1,
        [int]$RepairReloads = -1
    )
    $result = [ordered]@{
        scenario = $Scenario
        status   = 'failed'
        reasons  = @()
        waves    = [ordered]@{ wave1 = $false; wave2 = $false; wave3 = $false }
        reloads  = -1
        timesMs  = [ordered]@{}
        fontLoaded = $false
        neverLearnableBlocked = $false
        visitDelaySeconds = -1
        # Phase 5.2 E3: generic product signal that only the host-driven path
        # rules can satisfy (DNS cannot block paths; a dead host fails open).
        blockedPathEnforced = $false
        blockedPathFinal    = $false
        blockedPathEvidence = $false
    }
    if ($null -eq $Report -or -not $Report.waves) {
        $result.reasons += 'self-report-missing'
        return [pscustomobject]$result
    }
    $isClassBoot = ($Scenario -like '*class-boot*')
    $threshold = if ($isClassBoot) { $ClassBootWaveThresholdMs } else { $SettledWaveThresholdMs }
    $maxReloads = if ($isClassBoot) { $MaxReloadsClassBoot } else { $MaxReloadsSettled }
    $waves = $Report.waves
    $marks = $Report.marks
    $criteria = @{
        wave1 = @('cssApplied', 'coreExecuted', 'imageLoaded')
        wave2 = @('deferredExecuted')
        wave3 = @('apiPainted')
    }
    $marksByWave = @{ wave1 = 'core'; wave2 = 'deferred'; wave3 = 'api' }
    foreach ($wave in @('wave1', 'wave2', 'wave3')) {
        $ok = $true
        foreach ($flag in $criteria[$wave]) {
            if (-not [bool](Get-OpenPathLabField -InputObject $waves -Name $flag)) { $ok = $false }
        }
        $mark = [double](Get-OpenPathLabField -InputObject $marks -Name $marksByWave[$wave])
        if ($ok -and ($mark -le 0 -or $mark -gt $threshold)) { $ok = $false }
        $result.waves[$wave] = $ok
        $result.timesMs[$wave] = [int]$mark
        if (-not $ok) { $result.reasons += "$wave-incomplete-or-over-threshold" }
    }
    $result.reloads = [int](Get-OpenPathLabField -InputObject $Report -Name 'loads') - 1
    if ($result.reloads -lt 0) { $result.reloads = 0 }
    if ($RepairReloads -ge 0) { $result.reloads = $RepairReloads }
    if ($result.reloads -gt $maxReloads) { $result.reasons += 'too-many-reloads' }
    $result.fontLoaded = [bool](Get-OpenPathLabField -InputObject $waves -Name 'fontLoaded')
    $result.neverLearnableBlocked = [bool](Get-OpenPathLabField -InputObject $waves -Name 'blockedCssFailed')
    if (-not $result.neverLearnableBlocked) { $result.reasons += 'never-learnable-host-not-blocked' }
    # Phase 5.2 E3: only a report that explicitly settled the blocked-path probe
    # can carry the generic path signal; the waves stay the page self-report.
    $result.blockedPathFinal = [bool](Get-OpenPathLabField -InputObject $Report -Name 'blockedPathFinal')
    $result.blockedPathEnforced = [bool](Get-OpenPathLabField -InputObject $Report -Name 'blockedPathEnforced')
    if ($result.blockedPathFinal) {
        $result.blockedPathEvidence = $true
        if (-not $result.blockedPathEnforced) { $result.reasons += 'blocked-path-not-enforced' }
    }
    $result.status = if ($result.reasons | Where-Object { $_ -like '*incomplete*' -or $_ -in @('too-many-reloads', 'self-report-missing', 'never-learnable-host-not-blocked', 'blocked-path-not-enforced') }) { 'failed' } else { 'passed' }
    return [pscustomobject]$result
}

function Get-OpenPathFirstVisitMetrics {
    <#
    .SYNOPSIS
    Builds the per-run metrics JSON from the collected evidence.
    .DESCRIPTION
    Every timing segment stays on a single clock: page waves come from the
    in-page self-report (performance.now), warm-up fetch deltas from the fixture
    clock, and host-side segments from the native host's own startup-profile
    lines. Phase 3A.2 K5 baseline source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Report,
        # A host-blocked first visit produces no E1 diagnostics at all: the
        # empty array must bind instead of failing (Phase 3A.3).
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$DiagnosticLines,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$StartupProfiles,
        [Parameter(Mandatory = $true)][AllowNull()][object]$FixtureState,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Verdict,
        [string[]]$LogLines = @(),
        [AllowNull()][object]$Diagnostics = $null,
        [AllowNull()][object]$PrepareState = $null,
        # Phase 5.2 C1/C2: the scene keeps its verdict when the collect failed;
        # the failure and the guest block timings travel as evidence.
        [bool]$EvidenceIncomplete = $false,
        [string]$CollectError = '',
        [AllowNull()][object]$CollectTimings = $null,
        # Phase 5.2 E2: student host probe evidence (per scene).
        [AllowNull()][object]$HostProbe = $null,
        [string]$HostProbeError = '',
        # Phase 6: real-site canary metrics/verdict, SAC state and the post-boot
        # CodeIntegrity evidence (Phase 6.1 adds the control and visit probes).
        [AllowNull()][object]$Canary = $null,
        [AllowNull()][object]$SacState = $null,
        [AllowNull()][object]$SacControl = $null,
        [AllowNull()][object]$PostHostEvents = $null,
        [AllowNull()][object]$PostHostVerdict = $null,
        [AllowNull()][object]$VisitDiagnostics = $null,
        # Phase 7 P1: stall classification (sampler + host pressure + log gaps).
        [AllowNull()][object]$Stall = $null,
        # Phase 7 L2: smart_app_control=on-before-install evidence.
        [AllowNull()][object]$OnBeforeInstall = $null
    )
    $hostProfile = @()
    foreach ($line in $StartupProfiles) {
        $entry = [ordered]@{ raw = $line }
        foreach ($key in @('processToScriptMs', 'pingMs', 'firstEnqueueMs', 'firstEnqueueAtMs')) {
            $match = [regex]::Match($line, "$key=(-?\d+)")
            if ($match.Success) { $entry[$key] = [int]$match.Groups[1].Value }
        }
        $hostProfile += $entry
    }
    $decisions = @($DiagnosticLines | Where-Object { $_ -match 'kind":"reload-decision' })
    $reloadReasons = @()
    foreach ($line in $decisions) {
        $match = [regex]::Match($line, '"reason":"([^"]+)"')
        if ($match.Success) { $reloadReasons += $match.Groups[1].Value }
    }
    $holdOutcomes = @($DiagnosticLines | Where-Object { $_ -match 'kind":"hold-outcome' })
    $workerApplyMs = -1
    $overlayStamps = 0
    $acrylicLines = 0
    if ($LogLines) {
        $overlayStamps = @($LogLines | Where-Object { $_ -match 'stamped' }).Count
        $acrylicLines = @($LogLines | Where-Object { $_ -match '(?i)acrylic' }).Count
    }
    if ($FixtureState -and (Get-OpenPathLabField -InputObject $FixtureState -Name 'workerStateJson')) {
        try {
            $worker = [string](Get-OpenPathLabField -InputObject $FixtureState -Name 'workerStateJson') | ConvertFrom-Json
            $workerApplyMs = [int](Get-OpenPathLabField -InputObject $worker -Name 'lastApplyMs')
        }
        catch { }
    }
    $xpiFetchAfterArmSeconds = -1
    $verificationStatus = ''
    $hostStarted = $false
    $productReasons = @()
    $hostSignalsMetrics = $null
    $appControlEvidence = @()
    if ($PrepareState) {
        $xpiFetch = Get-OpenPathLabField -InputObject $PrepareState -Name 'xpiFetch'
        if ($xpiFetch) {
            $afterArm = Get-OpenPathLabField -InputObject $xpiFetch -Name 'afterArmSeconds'
            if ($null -ne $afterArm) { $xpiFetchAfterArmSeconds = [double]$afterArm }
        }
        $verification = Get-OpenPathLabField -InputObject $PrepareState -Name 'verification'
        if ($verification) { $verificationStatus = [string](Get-OpenPathLabField -InputObject $verification -Name 'status') }
        $liveSignals = Get-OpenPathLabField -InputObject $PrepareState -Name 'liveSignals'
        if ($liveSignals) { $hostStarted = [bool](Get-OpenPathLabField -InputObject $liveSignals -Name 'hostStarted') }
        $hostEvidence = Get-OpenPathLabField -InputObject $PrepareState -Name 'hostEvidence'
        if ($hostEvidence) {
            $productReasons = @(Get-OpenPathLabField -InputObject $hostEvidence -Name 'productReasons')
            $hostSignalsMetrics = Get-OpenPathLabField -InputObject $hostEvidence -Name 'signals'
            $appControlEvidence = @(Get-OpenPathLabField -InputObject $hostEvidence -Name 'verdict' | ForEach-Object { $_.appControlEvidence } | Where-Object { $_ })
        }
    }
    # Phase 6 B: a post-boot block (SAC/CodeIntegrity) is a product reason too.
    if ($PostHostVerdict) {
        $productReasons = @($productReasons + @(Get-OpenPathLabField -InputObject $PostHostVerdict -Name 'productReasons') | Select-Object -Unique)
    }
    $diagnosticKinds = [ordered]@{
        lines           = @($DiagnosticLines).Count
        transport       = @($DiagnosticLines | Where-Object { $_ -match 'kind":"transport' }).Count
        hold            = @($DiagnosticLines | Where-Object { $_ -match 'kind":"hold"' }).Count
        holdOutcome     = $holdOutcomes.Count
        reloadDecision  = $decisions.Count
        reloadReasons   = $reloadReasons
        backgroundStart = @($DiagnosticLines | Where-Object { $_ -match '"kind":"background-start"' }).Count
    }
    if ($Diagnostics) {
        $lines = Get-OpenPathLabField -InputObject $Diagnostics -Name 'lines'
        if ($null -ne $lines) { $diagnosticKinds.lines = [int]$lines }
        $backgroundStart = Get-OpenPathLabField -InputObject $Diagnostics -Name 'backgroundStart'
        if ($null -ne $backgroundStart) { $diagnosticKinds.backgroundStart = [bool]$backgroundStart }
        $diagnosticKinds.batchFirst = [bool](Get-OpenPathLabField -InputObject $Diagnostics -Name 'batchFirst')
        $diagnosticKinds.hostStarted = [bool](Get-OpenPathLabField -InputObject $Diagnostics -Name 'hostStarted')
    }
    return [ordered]@{
        schemaVersion  = 1
        scenario       = $Scenario
        anchor         = if ($Report) { [string]$Report.anchor } else { '' }
        plan           = [ordered]@{
            anchors          = @($Plan.anchors.PSObject.Properties | ForEach-Object { $_.Value.host })
            controlDeps      = @($Plan.controlDependencies)
            neverLearnable   = [string]$Plan.neverLearnable
        }
        verdict        = if ($Verdict) { [string]$Verdict.status } elseif ($Canary) { [string](Get-OpenPathLabField -InputObject $Canary -Name 'status') } else { 'failed' }
        # Phase 7 L3: canary scenes have no page self-report; their reasons are
        # the canary verdict reasons instead of the legacy `no-verdict` marker.
        reasons        = if ($Verdict) { @($Verdict.reasons) } elseif ($Canary) { @(Get-OpenPathLabField -InputObject $Canary -Name 'reasons') } else { @('no-verdict') }
        waves          = if ($Verdict) { $Verdict.waves } else { $null }
        waveTimesMs    = if ($Verdict) { $Verdict.timesMs } else { $null }
        reloads        = if ($Verdict) { $Verdict.reloads } else { -1 }
        repairReloads  = if ($Verdict) { $Verdict.reloads } else { -1 }
        fontLoaded     = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'fontLoaded')
        neverLearnableBlocked = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'neverLearnableBlocked')
        blockedPathEnforced = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'blockedPathEnforced')
        blockedPathFinal = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'blockedPathFinal')
        evidenceIncomplete = $EvidenceIncomplete
        collectError = $CollectError
        collectTimings = $CollectTimings
        studentHostProbe = $HostProbe
        studentHostProbeError = $HostProbeError
        reloadReasons  = $reloadReasons
        diagnosticLines = @($DiagnosticLines).Count
        holdOutcomes   = $holdOutcomes.Count
        diagnostics    = $diagnosticKinds
        hostProfile    = $hostProfile
        workerApplyMs  = $workerApplyMs
        overlayStamps  = $overlayStamps
        acrylicLines   = $acrylicLines
        warmup         = [ordered]@{
            xpiFetchAfterArmSeconds = $xpiFetchAfterArmSeconds
            verificationStatus   = $verificationStatus
            hostStarted          = $hostStarted
            productReasons       = @($productReasons)
            hostSignals          = $hostSignalsMetrics
            appControlEvidence   = @($appControlEvidence | Select-Object -First 5)
            blockedBySmartAppControl = [bool](Get-OpenPathLabField -InputObject $PostHostVerdict -Name 'blockedBySmartAppControl')
        }
        fixture        = if ($FixtureState) { [ordered]@{ requests = [int]$FixtureState.requests } } else { $null }
        # Phase 6 evidence: the real-site canary, the SAC state after the boot
        # and the post-boot CodeIntegrity collection.
        canary         = $Canary
        sacState       = $SacState
        sacControl     = $SacControl
        postHostEvents = $PostHostEvents
        visitDiagnostics = $VisitDiagnostics
        # Phase 7 P1: every >2 s gap, classified with the sampler and host data.
        stall          = $Stall
        # Phase 7 L2: policy applied before install + compile/recompile evidence.
        sacOnBeforeInstall = $OnBeforeInstall
    }
}

function Invoke-OpenPathFirstVisitSacAssessment {
    <#
    .SYNOPSIS
    Phase 6.1 C: one Smart App Control assessment round (state + control).
    .DESCRIPTION
    Runs sac-state and sac-control as independent best-effort steps so partial
    evidence still reaches the caller; the decision is made by
    Get-OpenPathFirstVisitSacDecision (UMCI enforced AND the MOTW control
    blocked).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$HarnessGuestPath,
        [Parameter(Mandatory = $true)][string]$CycleLabel,
        [string]$Phase = 'observe',
        [int]$TimeoutSeconds = 600
    )
    $result = [ordered]@{ label = $CycleLabel; state = $null; control = $null; stateError = ''; controlError = '' }
    try {
        $stateStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $Settings -Phase $Phase -Step 'sac-state' -HarnessGuestPath $HarnessGuestPath -TimeoutSeconds 300 -AllowFailed
        $result.state = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $stateStep -Name 'body') -Name 'state') -Name 'sacState'
    }
    catch { $result.stateError = [string]$_.Exception.Message }
    try {
        $controlStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $Settings -Phase $Phase -Step 'sac-control' -HarnessGuestPath $HarnessGuestPath -TimeoutSeconds $TimeoutSeconds -AllowRetry -AllowFailed
        $result.control = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $controlStep -Name 'body') -Name 'state') -Name 'sacControl'
    }
    catch { $result.controlError = [string]$_.Exception.Message }
    return $result
}

function Invoke-OpenPathFirstVisitPrepare {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$RestoreBaseline
    )
    $settings = Get-OpenPathLabAcceptanceSettings -Config $Config
    $firstVisit = Get-OpenPathFirstVisitSettings -Payload $Payload -Config $Config
    # Phase 6.1 C: the scene starts when prepare begins; every step carries the
    # mark so the CodeIntegrity XML queries share one window.
    $sceneStartedAt = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $settings | Add-Member -NotePropertyName 'SceneStartedAt' -NotePropertyValue $sceneStartedAt -Force
    # Phase 5.3 B4: `control` is the historical alias of the floor scenario.
    $scenarioNormalized = if ($firstVisit.Scenario -eq 'first-visit-control') { 'first-visit-floor' } else { $firstVisit.Scenario }
    # Phase 5.2 C3: each phase owns its step trace.
    $script:OpenPathFirstVisitStepTrace = $null
    # A transport dry-run lab cannot produce a first-visit verdict; report
    # BLOCKED instead of a green run with no evidence.
    if ([string](Get-OpenPathLabField -InputObject $Config -Name 'mode') -ne 'acceptance') {
        throw 'first-visit-requires-acceptance-lab-config'
    }
    Start-OpenPathLabAcceptanceVm -Transport $Transport -Vmid $Vmid -Snapshot $Snapshot -TimeoutSeconds $TimeoutSeconds -RestoreBaseline $RestoreBaseline
    $bootId = [string](& $Transport.GetGuestBootId $Vmid)
    if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-guest-not-ready' }
    $setup = Invoke-OpenPathLabAcceptanceGuestSetup -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -TimeoutSeconds $TimeoutSeconds -HarnessSourcePath (Get-OpenPathFirstVisitHarnessSourcePath)
    # The session launcher is small enough for one guest command. The two
    # shared modules are staged through the artifact transport, next to the
    # harness the harness dot-sources them from: embedding both module texts in
    # a single encoded command exceeded the QGA command size and made every
    # prepare fail with desktop-lab-guest-query-failed (Phase 3A.3).
    $launcherText = Get-Content -LiteralPath (Get-OpenPathFirstVisitLauncherSourcePath) -Raw
    $launcherLiteral = ConvertTo-OpenPathLabPowerShellLiteral -Value $launcherText
    & $Transport.InvokeGuestPowerShell $Vmid @"
New-Item -ItemType Directory -Path 'C:\OpenPathLab\first-visit' -Force | Out-Null
[IO.File]::WriteAllText('C:\OpenPathLab\first-visit\student-session-launch.ps1', $launcherLiteral, [Text.UTF8Encoding]::new(`$false))
Write-Output 'launcher-staged'
"@ 120 | Out-Null
    foreach ($moduleName in @('FirstVisitWarmup.psm1', 'FirstVisitResult.psm1', 'FirstVisitDnsTopology.psm1', 'FirstVisitSiteCanary.psm1', 'FirstVisitLaunch.psm1', 'FirstVisitStall.psm1', 'Test-OpenPathNativeHostAsStudent.ps1')) {
        $localModule = Join-Path (Get-OpenPathFirstVisitFixturesRoot) $moduleName
        if (-not (Test-Path -LiteralPath $localModule -PathType Leaf)) { throw "first-visit-helper-missing-$moduleName" }
        $published = & $Transport.PublishArtifact $Paths.StagingDir $localModule
        $url = [string](Get-OpenPathLabField -InputObject $published -Name 'url')
        if ([string]::IsNullOrWhiteSpace($url)) { throw "first-visit-helper-publish-failed-$moduleName" }
        $guestModulePath = $Paths.GuestDir.TrimEnd('\') + '\' + $moduleName
        & $Transport.DownloadGuestArtifact $Vmid $url $guestModulePath | Out-Null
        $guestHash = [string](& $Transport.GetGuestFileSha256 $Vmid $guestModulePath)
        $localHash = (Get-FileHash -LiteralPath $localModule -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($guestHash -and ($guestHash.ToLowerInvariant() -ne $localHash)) { throw "first-visit-helper-hash-mismatch-$moduleName" }
    }
    try { & $Transport.RemoveHostStaging $Paths.StagingDir | Out-Null } catch { }
    $fixture = Start-OpenPathFirstVisitFixture -Config $Config -Transport $Transport -RunId ([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId')) -ArtifactsRoot ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')) -Scenario $scenarioNormalized -SiteUrl $firstVisit.SiteUrl -SiteDomains $firstVisit.SiteDomains
    Write-OpenPathFirstVisitGuestFixtureInfo -Transport $Transport -Vmid $Vmid -Settings $fixture.Settings -Plan $fixture.Plan
    # Phase 7 L2: smart_app_control=on-before-install applies and enforces SAC
    # BEFORE the product install, proven with the positive control. Everything
    # after this point (install, compile, visit, recompile) runs with SAC
    # already active from the start.
    $sacPreInstall = $null
    $sacPreInstallDecision = $null
    $sacPreInstallApply = $null
    if ($firstVisit.SmartAppControl -eq 'on-before-install') {
        $sacApplyStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare-sac' -Step 'sac-apply' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 300
        $sacPreInstallApply = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $sacApplyStep -Name 'body') -Name 'state') -Name 'sacApply'
        & $Transport.RequestGuestReboot $Vmid | Out-Null
        $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $bootId $TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-sac-reboot-timeout' }
        $sacPreInstall = Invoke-OpenPathFirstVisitSacAssessment -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath -CycleLabel 'preinstall' -Phase 'prepare-sac'
        $sacPreInstallDecision = Get-OpenPathFirstVisitSacDecision -SacState $sacPreInstall.state -SacControl $sacPreInstall.control
        if (-not $sacPreInstallDecision.applied) {
            throw "sac-not-enforced-before-install: umci=$($sacPreInstallDecision.umciEnforcementStatus) motwBlocked=$($sacPreInstallDecision.motwBlocked) plainRan=$($sacPreInstallDecision.plainRan)"
        }
        Write-Host ("first-visit SAC pre-install applied: umci=$($sacPreInstallDecision.umciEnforcementStatus) motwBlocked=$($sacPreInstallDecision.motwBlocked) plainRan=$($sacPreInstallDecision.plainRan)")
    }
    $install = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'install' -HarnessGuestPath $setup.HarnessGuestPath -PersonalizedGuestPath $setup.PersonalizedGuestPath -TimeoutSeconds 1800
    $configure = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'configure' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 900
    # Phase 7 L2: with SAC already enforced, capture the compiled native host
    # state and run the product's own compile/ensure entrypoint.
    $hostCompile = $null
    if ($firstVisit.SmartAppControl -eq 'on-before-install') {
        $hostCompileStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'host-compile-state' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 600 -AllowFailed
        $hostCompile = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $hostCompileStep -Name 'body') -Name 'state') -Name 'hostCompile'
    }
    # Production-like requirement: the student is logged in interactively before
    # any browser runs (the session launcher needs an active console session, and
    # W/W2/B all assume a real student desktop). The guest secret must match the
    # account before the autologon can succeed.
    $passwordReset = (& $Transport.InvokeGuestPowerShell $Vmid "net user $($settings.StudentUserName) '$($settings.GuestSecret)' /y; Write-Output done" 120 | Out-String).Trim()
    $autologonScript = @"
`$ErrorActionPreference = 'Continue'
`$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path `$key -Name 'AutoAdminLogon' -Value '1' -Type String
Set-ItemProperty -Path `$key -Name 'DefaultUserName' -Value '$($settings.StudentUserName)' -Type String
Set-ItemProperty -Path `$key -Name 'DefaultDomainName' -Value `$env:COMPUTERNAME -Type String
Set-ItemProperty -Path `$key -Name 'DefaultPassword' -Value '$($settings.GuestSecret)' -Type String
Remove-ItemProperty -Path `$key -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path `$key -Name 'AutoLogonSID' -ErrorAction SilentlyContinue
Write-Output 'autologon-on'
"@
    & $Transport.InvokeGuestPowerShell $Vmid $autologonScript 120 | Out-Null
    & $Transport.RequestGuestReboot $Vmid | Out-Null
    $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $bootId $TimeoutSeconds)
    if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-reboot-timeout' }
    $session = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath -Phase 'prepare' -Step 'session' -TimeoutSeconds 420
    $sessionUser = [string](Get-OpenPathLabField -InputObject $session.body.state -Name 'session')
    $sourceSha = [string](Get-OpenPathLabField -InputObject $Payload -Name 'sourceCommitSha')
    $capabilities = Get-OpenPathFirstVisitBuildCapabilities -SourceSha $sourceSha
    # Stage the installed template xpi on the fixture (lab-only) and let the
    # warm-up run on the agent's own managed policy, no harness rewrite.
    $stage = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'stage-xpi' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 300
    $warmup = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'warmup' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 900
    # The warm-up arms about:blank through the logon path (Run key + wrapper);
    # wait for the new boot, the logon and the browser, then verify the
    # policy-installed extension and close it cleanly before any visit.
    $warmupArm = Get-OpenPathLabField -InputObject $warmup.body.state -Name 'arm'
    $warmupRebooted = $false
    if ($warmupArm -and ([string](Get-OpenPathLabField -InputObject $warmupArm -Name 'mode') -eq 'reboot')) {
        $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $bootId $TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-warmup-reboot-timeout' }
        $warmupRebooted = $true
    }
    Start-Sleep -Seconds $script:OpenPathFirstVisitRefreshSettleSeconds
    $warmSession = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath -Phase 'prepare' -Step 'session' -TimeoutSeconds 420
    $warmFirefox = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'wait-firefox' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 400 -AllowRetry
    # One fixture clock for the fetch check (count from before the logon) and
    # for the delay (from the moment the browser was first seen).
    $warmupFixtureJson = ''
    try {
        $warmupBaseline = Get-OpenPathLabField -InputObject $warmup.body.state -Name 'fixtureBeforeLaunch'
        $baseline = [ordered]@{
            xpiCount  = [int](Get-OpenPathLabField -InputObject $warmupBaseline -Name 'xpiCount')
            # Same fixture clock as the fetch timestamp; this is the warm-up arm
            # mark, not the later "Firefox was seen" probe (which produced
            # negative deltas in Phase 3A.2 red-b r1).
            serverNow = [double](Get-OpenPathLabField -InputObject $warmupBaseline -Name 'serverNow')
        }
        $warmupFixtureJson = ($baseline | ConvertTo-Json -Compress)
    }
    catch { }
    $warmVerify = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'verify-warmup' -HarnessGuestPath $setup.HarnessGuestPath -Capabilities ([string]$capabilities.CapabilityArgument) -FixtureBaselineJson $warmupFixtureJson -TimeoutSeconds 900 -AllowRetry

    # Lane preconditions (fixture served + signed extension installed and
    # active) are INFRA when they fail: without them the visit measures
    # nothing. The native host start is product behaviour and never blocks the
    # visit (Phase 3A.3 L2).
    $preconditions = Get-OpenPathLabField -InputObject $warmVerify.body.state -Name 'preconditions'
    if ($preconditions -and ([string](Get-OpenPathLabField -InputObject $preconditions -Name 'status') -ne 'passed')) {
        $preconditionReasons = @(Get-OpenPathLabField -InputObject $preconditions -Name 'reasons')
        throw "first-visit-precondition-failed-$(($preconditionReasons) -join '-')"
    }
    # Host signals and AppLocker events: separate short calls (event and policy
    # queries hung the guest when they ran inside verify-warmup in 3A.2).
    $hostSignalsBody = $null
    $hostEventsBody = $null
    $hostEvidenceError = ''
    try {
        $hostSignalsStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'host-signals' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 240 -AllowRetry -AllowFailed
        $hostSignalsBody = $hostSignalsStep.body.state.hostSignals
    }
    catch { $hostEvidenceError = [string]$_.Exception.Message }
    # Phase 5.3 B5: persist the DNS topology evidence (guest view + host
    # dns.jsonl correlation for the fresh probe name).
    $dnsTopology = $null
    try {
        $hostSignalsState = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $hostSignalsStep -Name 'body') -Name 'state'
        $dnsTopology = Get-OpenPathLabField -InputObject $hostSignalsState -Name 'dnsTopology'
    }
    catch { }
    try {
        $dnsEvidence = [ordered]@{ schemaVersion = 1; guest = $dnsTopology; host = [ordered]@{ staging = ''; stats = '' } }
        $stagingRootForDns = [string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot')
        if ([string]::IsNullOrWhiteSpace($stagingRootForDns)) { $stagingRootForDns = '/var/tmp/openpath-first-visit' }
        $stagingForDns = "$stagingRootForDns/$([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId'))".Replace('//', '/')
        $dnsEvidence.host.staging = $stagingForDns
        $correlateHost = [string](Get-OpenPathLabField -InputObject $dnsTopology -Name 'correlateHost')
        $statsCommand = "f='$stagingForDns/state/dns.jsonl'; if [ -f `"`$f`" ]; then echo total=`$(wc -l < `"`$f`"); echo sslip-answer=`$(grep -c sslip-answer `"`$f`"); echo correlate=`$(grep -c '$correlateHost' `"`$f`"); grep sslip-answer `"`$f`" | head -3; else echo total=0; echo sslip-answer=0; echo correlate=0; fi"
        $dnsEvidence.host.stats = ([string](& $Transport.InvokeHostCommand @('bash', '-lc', $statsCommand) '')).Trim()
        [IO.File]::WriteAllText((Join-Path ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')) 'dns-topology.json'), ($dnsEvidence | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }
    catch { Write-Warning "dns topology evidence failed: $($_.Exception.Message)" }
    try {
        $hostEventsStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'host-events' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 300 -AllowRetry -AllowFailed
        $hostEventsBody = $hostEventsStep.body.state.hostEvents
    }
    catch { $hostEvidenceError = (($hostEvidenceError + ' ' + [string]$_.Exception.Message).Trim()) }
    # Phase 6.1 C: the positive SAC control runs in EVERY scene as the SAC=2
    # baseline (ControlOptions: compile csc exe, MOTW + plain copies, run as
    # SYSTEM, collect the CodeIntegrity XML naming them, delete them).
    $sacControlBaseline = $null
    $sacControlBaselineError = ''
    try {
        $sacControlBaselineStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'sac-control' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 600 -AllowRetry -AllowFailed
        $sacControlBaseline = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $sacControlBaselineStep -Name 'body') -Name 'state') -Name 'sacControl'
    }
    catch { $sacControlBaselineError = [string]$_.Exception.Message }
    # Phase 6.1 B/C: smart_app_control=on simulates an installed machine to
    # which Windows turns SAC On. The policy is applied and enforced with its
    # own reboot HERE (so the measured class-boot visit stays clean), and SAC
    # only counts as applied with the positive control (UMCI enforced AND the
    # MOTW copy blocked). One extra attempt re-enables Defender when the image
    # disables it by policy; after that the scene is INFRA sac-not-enforced.
    $sacApply = $sacPreInstallApply
    $sacApplySecond = $null
    $sacState = if ($sacPreInstall) { $sacPreInstall.state } else { $null }
    $sacControlPost = if ($sacPreInstall) { $sacPreInstall.control } else { $null }
    $sacDecision = $sacPreInstallDecision
    $sacCycles = @()
    if ($sacPreInstall) { $sacCycles = @($sacPreInstall) }
    if ($firstVisit.SmartAppControl -eq 'on') {
        $sacApplyStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'sac-apply' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 300
        $sacApply = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $sacApplyStep -Name 'body') -Name 'state') -Name 'sacApply'
        # Phase 6.1 fix: request the reboot that applies the policy; the cycle
        # only ever WAITS for it (run 37583684814 hung until the phase timeout).
        & $Transport.RequestGuestReboot $Vmid | Out-Null
        $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $bootId $TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-sac-reboot-timeout' }
        $sacSession = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath -Phase 'prepare' -Step 'session' -TimeoutSeconds 420
        $cycleOne = Invoke-OpenPathFirstVisitSacAssessment -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath -CycleLabel 'cycle1' -Phase 'prepare-sac'
        $sacCycles += $cycleOne
        $sacDecision = Get-OpenPathFirstVisitSacDecision -SacState $cycleOne.state -SacControl $cycleOne.control
        if (-not $sacDecision.applied) {
            $defenderDisabled = @(Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $cycleOne.state -Name 'defender') -Name 'disabledByPolicy')
            if ($defenderDisabled.Count -gt 0) {
                Write-Host ("first-visit SAC extra attempt: defender disabled by policy=" + ($defenderDisabled -join ','))
                $defenderStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'sac-defender-enable' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 300 -AllowFailed
                $sacApplyStepSecond = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'sac-apply' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 300
                $sacApplySecond = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $sacApplyStepSecond -Name 'body') -Name 'state') -Name 'sacApply'
                & $Transport.RequestGuestReboot $Vmid | Out-Null
                $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $bootId $TimeoutSeconds)
                if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-sac-reboot-timeout' }
                $sacSession = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath -Phase 'prepare' -Step 'session' -TimeoutSeconds 420
                $cycleTwo = Invoke-OpenPathFirstVisitSacAssessment -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath -CycleLabel 'cycle2' -Phase 'prepare-sac'
                $sacCycles += $cycleTwo
                $sacDecision = Get-OpenPathFirstVisitSacDecision -SacState $cycleTwo.state -SacControl $cycleTwo.control
            }
        }
        if (-not $sacDecision.applied) {
            $detail = "sac-not-enforced: umci=$($sacDecision.umciEnforcementStatus) motwBlocked=$($sacDecision.motwBlocked) plainRan=$($sacDecision.plainRan)"
            $lastCycle = $sacCycles[-1]
            if ($lastCycle.stateError) { $detail = "$detail stateError=$($lastCycle.stateError)" }
            if ($lastCycle.controlError) { $detail = "$detail controlError=$($lastCycle.controlError)" }
            throw $detail
        }
        $sacState = $sacCycles[-1].state
        $sacControlPost = $sacCycles[-1].control
        Write-Host ("first-visit SAC applied: umci=$($sacDecision.umciEnforcementStatus) motwBlocked=$($sacDecision.motwBlocked) plainRan=$($sacDecision.plainRan) cycles=$($sacCycles.Count)")
    }
    $liveForVerdict = $hostSignalsBody
    if (-not $liveForVerdict) {
        # Fall back to the live signals the verify step already collected: the
        # host verdict must still be reported when the separate call failed.
        $liveForVerdict = Get-OpenPathLabField -InputObject $warmVerify.body.state -Name 'hostSignals'
    }
    $hostVerdict = Get-FirstVisitHostSignalsVerdict -Live $liveForVerdict -Events $hostEventsBody -Capabilities ([string]$capabilities.CapabilityArgument) -StudentUserName $settings.StudentUserName -WindowStart ([string](Get-OpenPathLabField -InputObject $warmup.body.state -Name 'armedAt'))
    Write-Host ('first-visit host verdict: reasons=' + (@($hostVerdict.productReasons) -join ',') + ' hostStarted=' + [string]$hostVerdict.signals.hostStarted + ' appControlBlocked=' + [string]$hostVerdict.blockedByAppControl)
    # The fixture must serve exactly the template's AMO-signed xpi on the
    # managed API path; record every sha and fail loudly on a mismatch.
    $xpiServedSha = ''
    try {
        $xpiServedSha = (& $Transport.InvokeHostCommand @('bash', '-lc', "curl -s --max-time 30 '$(($firstVisit.FixtureUrl).TrimEnd('/'))/api/extensions/firefox/openpath.xpi' | sha256sum | cut -d' ' -f1") '').Trim()
    }
    catch { }
    $firstVisitPayload = Get-OpenPathLabField -InputObject $Payload -Name 'firstVisit'
    $templateXpiSha = ''
    if ($firstVisitPayload) { $templateXpiSha = [string](Get-OpenPathLabField -InputObject $firstVisitPayload -Name 'templateXpiSha256') }
    $installedXpiSha = [string](Get-OpenPathLabField -InputObject $stage.body.state.xpi -Name 'sha256')
    if ($templateXpiSha -and $installedXpiSha -and ($installedXpiSha -ne $templateXpiSha)) {
        throw "first-visit-xpi-installed-sha-mismatch installed=$installedXpiSha template=$templateXpiSha"
    }
    if ($templateXpiSha -and $xpiServedSha -and ($xpiServedSha -ne $templateXpiSha)) {
        throw "first-visit-xpi-served-sha-mismatch served=$xpiServedSha template=$templateXpiSha"
    }
    # Phase 5.3 B7: never persist the guest secret. Its SHA-256 keeps the state
    # correlatable without leaking the credential into the public artifact.
    $guestSecretHash = ''
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $guestSecretHash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$settings.GuestSecret)) | ForEach-Object { $_.ToString('x2') })
        }
        finally { $sha.Dispose() }
    }
    catch { $guestSecretHash = '' }
    $state = [ordered]@{
        phase               = 'prepared'
        scenarioId          = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
        bootIdBefore        = $bootId
        bootIdLatest        = $bootId
        harnessGuestPath    = $setup.HarnessGuestPath
        personalizedGuestPath = $setup.PersonalizedGuestPath
        guestSecret         = '<redacted>'
        guestSecretSha256   = $guestSecretHash
        fixtureUrl          = $firstVisit.FixtureUrl
        dnsIp               = $firstVisit.DnsIp
        plan                = $fixture.Plan
        dnsTopology         = $dnsTopology
        install             = $install.body.state.install
        configured          = [bool]$configure.body.state.registered
        passwordReset       = ($passwordReset -match 'done')
        sessionUser         = $sessionUser
        capabilities        = $capabilities
        sceneStartedAt      = $sceneStartedAt
        smartAppControl     = [string]$firstVisit.SmartAppControl
        sacApply            = $sacApply
        sacApplySecond      = $sacApplySecond
        sacControlBaseline  = $sacControlBaseline
        sacControlBaselineError = $sacControlBaselineError
        sacState            = $sacState
        sacControlPost      = $sacControlPost
        sacDecision         = $sacDecision
        sacCycles           = @($sacCycles)
        # Phase 7 L2: on-before-install evidence (policy applied before the
        # install, the compiled host with SAC active and its build/ensure log).
        sacPreInstall       = $sacPreInstall
        sacPreInstallDecision = $sacPreInstallDecision
        hostCompile         = $hostCompile
        siteMode            = [bool]$firstVisit.SiteMode
        siteUrl             = [string]$firstVisit.SiteUrl
        siteDomains         = @($firstVisit.SiteDomains)
        xpi                 = $stage.body.state.xpi
        xpiUpload           = [string]$stage.body.state.xpiUpload
        xpiServedSha256     = $xpiServedSha
        xpiTemplateSha256   = $templateXpiSha
        firefoxPolicy       = $configure.body.state.firefoxPolicy
        warmupFixture       = $warmup.body.state.fixtureBeforeLaunch
        warmupRebooted      = $warmupRebooted
        warmupSession       = [bool](Get-OpenPathLabField -InputObject $warmSession.body.state -Name 'session')
        warmupFirefox       = @(Get-OpenPathLabField -InputObject $warmFirefox.body.state -Name 'firefox')
        verification        = Get-OpenPathLabField -InputObject $warmVerify.body.state -Name 'warmupVerification'
        preconditions       = $preconditions
        liveSignals         = Get-OpenPathLabField -InputObject $warmVerify.body.state -Name 'liveSignals'
        xpiFetch            = Get-OpenPathLabField -InputObject $warmVerify.body.state -Name 'xpiFetch'
        extension           = Get-OpenPathLabField -InputObject $warmVerify.body.state -Name 'extension'
        warmupClose         = Get-OpenPathLabField -InputObject $warmVerify.body.state -Name 'closeAfterWarmup'
        hostEvidence        = [ordered]@{
            verdict      = $hostVerdict
            productReasons = @($hostVerdict.productReasons)
            signals      = $hostVerdict.signals
            rawSignals   = $hostSignalsBody
            events       = $hostEventsBody
            error        = $hostEvidenceError
        }
        productReasons      = @($hostVerdict.productReasons)
    }
    Write-OpenPathLabAcceptanceState -Path $StatePath -Value $state
    $body = [ordered]@{ state = $state }
    return New-OpenPathLabAcceptanceObservation -Payload $Payload -Phase 'prepare' -Body $body
}

function Invoke-OpenPathFirstVisitVisit {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$HarnessGuestPath,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][string]$CaptureDir,
        [int]$TimeoutSeconds = 900
    )
    $visit = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $Settings -Phase $Phase -Step 'visit' -HarnessGuestPath $HarnessGuestPath -TimeoutSeconds $TimeoutSeconds
    $startedAt = Get-Date
    $offsets = @($script:OpenPathFirstVisitCaptureOffsets)
    foreach ($offset in $offsets) {
        $remaining = ($startedAt.AddSeconds($offset) - (Get-Date)).TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Seconds ([int][math]::Ceiling($remaining)) }
        $capture = Join-Path $CaptureDir ("console-$Scenario-t{0:d3}.ppm" -f $offset)
        try { & $Transport.CaptureScreendump $Vmid $capture | Out-Null } catch { Write-Warning "screendump t$offset failed: $($_.Exception.Message)" }
    }
    return $visit
}

function Start-OpenPathFirstVisitSamplers {
    <#
    .SYNOPSIS
    Starts the guest stall sampler and the Proxmox host pressure sampler.
    .DESCRIPTION
    Phase 7 P1: both run from just before the visit until after the collect so
    every >2 s worker/native gap can be classified with data.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$HarnessGuestPath,
        [Parameter(Mandatory = $true)][string]$Staging
    )
    $result = [ordered]@{ guestSampler = $null; pressureStarted = $false; pressureOut = ''; error = '' }
    try {
        $step = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $Settings -Phase 'observe' -Step 'stall-sampler-start' -HarnessGuestPath $HarnessGuestPath -TimeoutSeconds 240
        $result.guestSampler = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $step -Name 'body') -Name 'state') -Name 'stallSamplerStart'
    }
    catch {
        $result.error = (($result.error + " guest-sampler: $([string]$_.Exception.Message)").Trim())
    }
    try {
        $localScript = Join-Path (Get-OpenPathFirstVisitFixturesRoot) 'pressure-sampler.sh'
        if (Test-Path -LiteralPath $localScript) {
            & $Transport.CopyFileToHost $localScript "$Staging/pressure-sampler.sh" | Out-Null
            $pressureOut = "$Staging/state/pressure-scene.jsonl"
            # 2400 s is the upper bound of a scene; the stop still ends it early.
            $startCommand = "setsid nohup bash $Staging/pressure-sampler.sh '$pressureOut' $Vmid 2400 > /dev/null 2>&1 < /dev/null & sleep 1; echo pressure-started"
            $out = ([string](& $Transport.InvokeHostCommand @('bash', '-lc', $startCommand) '')).Trim()
            $result.pressureStarted = ($out -match 'pressure-started')
            $result.pressureOut = $pressureOut
        }
        else {
            $result.error = (($result.error + ' pressure-sampler-missing').Trim())
        }
    }
    catch {
        $result.error = (($result.error + " pressure: $([string]$_.Exception.Message)").Trim())
    }
    return [PSCustomObject]$result
}

function Stop-OpenPathFirstVisitSamplers {
    <#
    .SYNOPSIS
    Stops both samplers and returns the guest classification plus host pressure.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$HarnessGuestPath,
        [Parameter(Mandatory = $true)][string]$Staging
    )
    $result = [ordered]@{ guestSampler = $null; pressure = @(); pressureError = ''; error = '' }
    try {
        $step = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $Settings -Phase 'observe' -Step 'stall-sampler-stop' -HarnessGuestPath $HarnessGuestPath -TimeoutSeconds 300 -AllowFailed
        $result.guestSampler = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $step -Name 'body') -Name 'state') -Name 'stallSampler'
    }
    catch {
        $result.error = (($result.error + " guest-sampler-stop: $([string]$_.Exception.Message)").Trim())
    }
    try {
        $fetchCommand = "pkill -f 'pressure-sampler[.]sh' > /dev/null 2>&1 || true; sleep 1; tail -n 2400 '$Staging/state/pressure-scene.jsonl' 2>/dev/null || true"
        $pressureText = ([string](& $Transport.InvokeHostCommand @('bash', '-lc', $fetchCommand) '')).Trim()
        $samples = New-Object System.Collections.Generic.List[object]
        foreach ($line in @($pressureText -split "`n")) {
            if (-not $line.Trim().StartsWith('{')) { continue }
            try { $samples.Add(($line | ConvertFrom-Json)) | Out-Null } catch { }
        }
        $result.pressure = @($samples.ToArray())
    }
    catch {
        $result.pressureError = [string]$_.Exception.Message
    }
    return [PSCustomObject]$result
}

function Invoke-OpenPathFirstVisitObserve {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $settings = Get-OpenPathLabAcceptanceSettings -Config $Config
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    # Phase 6.1 C: continue the scene clock started in prepare.
    # Phase 7 L3: ConvertFrom-Json turns the ISO string into a [datetime], and
    # [string] would then format it with the host locale (10/07/2026 13:14:47),
    # which no XPath SystemTime comparison can match. Normalize back to
    # invariant ISO-8601 UTC before it reaches the guest.
    $sceneStartedAt = ConvertTo-OpenPathFirstVisitSceneStartedIso -Value (Get-OpenPathLabField -InputObject $state -Name 'sceneStartedAt')
    if (-not $sceneStartedAt) {
        $sceneStartedAt = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $settings | Add-Member -NotePropertyName 'SceneStartedAt' -NotePropertyValue $sceneStartedAt -Force
    $firstVisit = Get-OpenPathLabField -InputObject $Payload -Name 'firstVisit'
    # Phase 5.2 C3: each phase owns its step trace.
    $script:OpenPathFirstVisitStepTrace = $null
    $scenario = if ($firstVisit) { [string](Get-OpenPathLabField -InputObject $firstVisit -Name 'scenario') } else { 'first-visit-settled' }
    if (-not $scenario) { $scenario = 'first-visit-settled' }
    if ($scenario -eq 'first-visit-control') { $scenario = 'first-visit-floor' }
    # Phase 6 C: the real-site canary has no page self-report (the real site is
    # not instrumented); its verdict comes from the collected diagnostics.
    # Phase 6.1 fix: the class-boot canary variant must take the same path.
    $siteMode = ($scenario -in @('first-visit-site', 'first-visit-site-class-boot'))
    # Phase 6 B: SAC state is read only for smart_app_control=on scenes.
    $sacStateInfo = $null
    $sacControlInfo = $null
    $sacPostDecision = $null
    $sacStepError = ''
    if ([string](Get-OpenPathLabField -InputObject $Config -Name 'mode') -ne 'acceptance') {
        throw 'first-visit-requires-acceptance-lab-config'
    }
    $harnessGuestPath = [string]$state.harnessGuestPath
    $artifactsRoot = [string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')
    $captureDir = Join-Path $artifactsRoot 'captures'
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
    $evidenceDir = Join-Path $artifactsRoot 'guest-logs'
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null

    # Phase 7 P1: the sampler window covers the visit and the dependency
    # fan-out (guest stall sampler + Proxmox host pressure). Started before the
    # update-contention trigger/arm so the very first contention is sampled.
    $observeStaging = "$([string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot'))/$([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId'))".Replace('//', '/')
    $samplers = Start-OpenPathFirstVisitSamplers -Payload $Payload -Config $Config -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Staging $observeStaging
    if ($samplers.error) { Write-Warning "first-visit samplers: $($samplers.error)" }

    # Phase 7 L1: the update-contention scenario starts the product update
    # right BEFORE the browser launch, so the dependency fast path has to
    # contend with a real update cycle while the page fans out.
    $updateTrigger = $null
    if ($scenario -eq 'first-visit-update-contention') {
        $triggerStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'update-trigger' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300
        $updateTrigger = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $triggerStep -Name 'body') -Name 'state') -Name 'updateTrigger'
        Write-Host "first-visit update-contention trigger: mode=$([string](Get-OpenPathLabField -InputObject $updateTrigger -Name 'mode')) exit=$([string](Get-OpenPathLabField -InputObject $updateTrigger -Name 'exit'))"
    }
    # 1) Arm the visit (wrapper + Run key) and refresh the session: logoff for
    #    settled/hot/control (the persistent host process stays warm), reboot for
    #    class-boot (Firefox starts within the class-boot window at logon).
    $arm = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'visit' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300
    $refreshMode = [string](Get-OpenPathLabField -InputObject $arm.body.state.arm -Name 'mode')
    # Phase 6.1 B: who was already open at visit launch (and whether it was
    # closed) travels with the scene evidence.
    $armState = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $arm -Name 'body') -Name 'state'
    $visitDiagnostics = [ordered]@{
        preExistingFirefox   = Get-OpenPathLabField -InputObject $armState -Name 'preExistingFirefox'
        preExistingClose     = Get-OpenPathLabField -InputObject $armState -Name 'preExistingClose'
        preExistingRemaining = Get-OpenPathLabField -InputObject $armState -Name 'preExistingRemaining'
    }
    $logonAt = ''
    if ($scenario -like '*class-boot*') {
        # The visit step armed the run-key wrapper and requested the reboot; wait
        # for the new boot, the real logon and the browser it starts.
        $bootBefore = [string]$state.bootIdLatest
        $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $bootBefore $TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-reboot-timeout' }
        $session = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Phase 'observe' -Step 'session' -TimeoutSeconds 420
        $logonAt = [string]$session.body.state.sessionLogonAt
        # Phase 6.1 C: after the class-boot reboot, re-read the state and re-run
        # the positive control. SAC only counts as applied with UMCI enforced
        # AND the MOTW control blocked; anything else is INFRA sac-not-enforced
        # and the scene stops here (the enforcement cycle itself ran in prepare).
        $sacStateInfo = $null
        $sacStepError = ''
        $sacControlInfo = $null
        $sacPostDecision = $null
        if ([string]$state.smartAppControl -in @('on', 'on-before-install')) {
            $sacPostCycle = Invoke-OpenPathFirstVisitSacAssessment -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -CycleLabel 'postboot' -Phase 'observe'
            $sacStateInfo = $sacPostCycle.state
            $sacControlInfo = $sacPostCycle.control
            $sacStepError = (($sacPostCycle.stateError + ' ' + $sacPostCycle.controlError).Trim())
            $sacPostDecision = Get-OpenPathFirstVisitSacDecision -SacState $sacStateInfo -SacControl $sacControlInfo
            if (-not $sacPostDecision.applied) {
                $notEnforcedDetail = "sac-not-enforced: umci=$($sacPostDecision.umciEnforcementStatus) motwBlocked=$($sacPostDecision.motwBlocked) plainRan=$($sacPostDecision.plainRan)"
                if ($sacStepError) { $notEnforcedDetail = "$notEnforcedDetail error=$sacStepError" }
                throw $notEnforcedDetail
            }
            Write-Host ("first-visit SAC state: umci=$($sacPostDecision.umciEnforcementStatus) motwBlocked=$($sacPostDecision.motwBlocked) plainRan=$($sacPostDecision.plainRan) languageMode=$([string](Get-OpenPathLabField -InputObject $sacStateInfo -Name 'languageMode'))")
        }
    }
    else {
        # The visit step launched the browser on the student's desktop directly.
        Start-Sleep -Seconds $script:OpenPathFirstVisitObserveSettleSeconds
    }
    $wait = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'wait-firefox' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 400 -AllowRetry
    $launchedAt = [string]$wait.body.state.launchedAt
    if ($scenario -eq 'first-visit-hot') {
        # Hot window: the same instance gets a second window on anchor 2 and the
        # final self-report is the anchor-2 document.
        Start-Sleep -Seconds $script:OpenPathFirstVisitHotWindowSeconds
        $second = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'second-window' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300
        Start-Sleep -Seconds $script:OpenPathFirstVisitHotSecondSettleSeconds
    }
    $visitDelaySeconds = -1
    if ($logonAt -and $launchedAt) {
        try { $visitDelaySeconds = [int](([datetime]$launchedAt) - ([datetime]$logonAt)).TotalSeconds } catch { }
    }

    # 2) Console screendumps at the fixed offsets.
    $startedAt = Get-Date
    foreach ($offset in @($script:OpenPathFirstVisitCaptureOffsets)) {
        $remaining = ($startedAt.AddSeconds($offset) - (Get-Date)).TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Seconds ([int][math]::Ceiling($remaining)) }
        $capture = Join-Path $captureDir ("console-$scenario-t{0:d3}.ppm" -f $offset)
        try { & $Transport.CaptureScreendump $Vmid $capture | Out-Null } catch { Write-Warning "screendump t$offset failed: $($_.Exception.Message)" }
    }

    # 3) Phase 5.2 C1: the verdict is computed and persisted from the page
    #    self-report (plus the prepare product signals) BEFORE the heavy collect.
    #    A slow or failed collect can no longer turn a measured PRODUCT failure
    #    into INFRA: it only marks the evidence incomplete.
    $fixtureUrl = [string]$state.fixtureUrl
    $staging = "$([string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot'))/$([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId'))".Replace('//', '/')
    $report = $null
    $fixtureState = $null
    if (-not $siteMode) {
        $deadline = (Get-Date).AddSeconds($script:OpenPathFirstVisitReportWaitSeconds)
        $firstReportAt = $null
        while ($true) {
            $stateTextForObserve = (& $Transport.InvokeHostCommand @('curl', '-s', '--max-time', '10', "$fixtureUrl/state.json") '').Trim()
            if ($stateTextForObserve.StartsWith('{')) {
                $fixtureState = $stateTextForObserve | ConvertFrom-Json
                $lastReport = Get-OpenPathLabField -InputObject $fixtureState -Name 'lastReport'
                if ($lastReport) {
                    $report = $lastReport
                    if (-not $firstReportAt) { $firstReportAt = Get-Date }
                    # The blocked-path probe (Phase 5.2 E3) settles a few seconds
                    # after load; prefer the report that carries its final value,
                    # bounded by the grace so a legacy page can never stall here.
                    if ([bool](Get-OpenPathLabField -InputObject $report -Name 'blockedPathFinal')) { break }
                    if ($script:OpenPathFirstVisitReportGraceSeconds -le 0) { break }
                    if (((Get-Date) - $firstReportAt).TotalSeconds -ge $script:OpenPathFirstVisitReportGraceSeconds) { break }
                }
            }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 5
        }
    }
    else {
        # Canary: the real site is not instrumented; still snapshot the fixture
        # state for the request counters.
        $stateTextForObserve = (& $Transport.InvokeHostCommand @('curl', '-s', '--max-time', '10', "$fixtureUrl/state.json") '').Trim()
        if ($stateTextForObserve.StartsWith('{')) { $fixtureState = $stateTextForObserve | ConvertFrom-Json }
    }
    $repairReloads = -1
    $reportsText = (& $Transport.InvokeHostCommand @('bash', '-lc', "test -f $staging/state/reports.jsonl && cat $staging/state/reports.jsonl || true") '').Trim()
    if ($reportsText) {
        $seen = @{}
        $reloadCount = 0
        foreach ($line in @($reportsText -split "`n")) {
            if (-not $line.Trim().StartsWith('{')) { continue }
            try { $entry = $line | ConvertFrom-Json } catch { continue }
            $origin = [string](Get-OpenPathLabField -InputObject $entry -Name 'timeOrigin')
            if (-not $origin -or $seen.ContainsKey($origin)) { continue }
            $seen[$origin] = $true
            if ([string](Get-OpenPathLabField -InputObject $entry -Name 'navigationType') -eq 'reload') { $reloadCount += 1 }
        }
        $repairReloads = $reloadCount
    }
    $browserRequests = if ($fixtureState) { [int](Get-OpenPathLabField -InputObject $fixtureState -Name 'browserRequests') } else { 0 }
    $plan = $state.plan
    $verdict = $null
    $verdictDocument = $null
    $verdictPath = Join-Path $artifactsRoot 'observe-verdict.json'
    if (-not $siteMode) {
        $verdict = Get-OpenPathFirstVisitReportVerdict -Report $report -Plan $plan -Scenario $scenario -RepairReloads $repairReloads
        $prepareHostEvidence = Get-OpenPathLabField -InputObject $state -Name 'hostEvidence'
        $prepareProductReasons = @(Get-OpenPathLabField -InputObject $prepareHostEvidence -Name 'productReasons')
        $prepareHostSignals = Get-OpenPathLabField -InputObject $prepareHostEvidence -Name 'signals'
        $prepareHostVerdict = Get-OpenPathLabField -InputObject $prepareHostEvidence -Name 'verdict'
        $prepareLiveSignals = Get-OpenPathLabField -InputObject $state -Name 'liveSignals'
        $verdictDocument = [ordered]@{
            schemaVersion       = 1
            scenario            = $scenario
            source              = 'self-report+prepare'
            verdict             = $verdict
            reportPresent       = ($null -ne $report)
            browserRequests     = $browserRequests
            fixtureRequests     = if ($fixtureState) { [int](Get-OpenPathLabField -InputObject $fixtureState -Name 'requests') } else { 0 }
            repairReloads       = $repairReloads
            productReasons      = @($prepareProductReasons)
            hostStarted         = [bool](Get-OpenPathLabField -InputObject $prepareLiveSignals -Name 'hostStarted')
            hostSignals         = $prepareHostSignals
            blockedByAppControl = [bool](Get-OpenPathLabField -InputObject $prepareHostVerdict -Name 'blockedByAppControl')
            blockedPathEnforced = Get-OpenPathLabField -InputObject $report -Name 'blockedPathEnforced'
            blockedPathFinal    = [bool](Get-OpenPathLabField -InputObject $report -Name 'blockedPathFinal')
            evidenceIncomplete  = $false
            collectError        = ''
            writtenAt           = [DateTime]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText($verdictPath, ($verdictDocument | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    }
    # Phase 5.2: copy the guest logs right after the verdict, before the heavy
    # collect/probe. A later failure then still explains the visit from the
    # visit-time native-host.log (extension diagnostics, E1 decisions).
    # Phase 5.3 B8: the agent log lives at data\logs\openpath.log; every copy
    # result is recorded so a silent failure can never hide again.
    $studentUserEarly = [string]$settings.StudentUserName
    $copyEvidencePath = Join-Path $evidenceDir 'copies.json'
    $copyEvidence = New-Object System.Collections.ArrayList
    foreach ($copy in @(
            @{ Path = "C:\Users\$studentUserEarly\AppData\Local\OpenPath\native-host.log"; Name = 'native-host.log'; Reason = 'after-verdict' },
            @{ Path = 'C:\OpenPath\data\logs\openpath.log'; Name = 'openpath.log'; Reason = 'after-verdict' }
        )) {
        $copyResult = Copy-OpenPathFirstVisitGuestFile -Transport $Transport -Vmid $Vmid -GuestPath $copy.Path -LocalPath (Join-Path $evidenceDir $copy.Name) -Reason $copy.Reason
        $null = $copyEvidence.Add($copyResult)
        if (-not $copyResult.ok) { Write-Warning "guest log copy failed [$($copy.Reason)/$($copy.Name)]: $($copyResult.error)" }
    }
    try { [IO.File]::WriteAllText($copyEvidencePath, (@($copyEvidence) | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false)) } catch { }

    # 4) Collect: bounded (<=120 s controller budget) and best-effort. Its
    #    failure is recorded literally and never changes the persisted verdict.
    $collect = $null
    $collectError = ''
    try {
        $collect = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'collect' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 120 -AllowRetry
    }
    catch {
        $collectError = [string]$_.Exception.Message
        if ($collectError.Length -gt 600) { $collectError = $collectError.Substring(0, 600) + '...' }
        Write-Warning "first-visit collect failed (verdict preserved): $collectError"
    }
    # Strict mode: never dereference a property chain directly. The serializer
    # may drop the collect subtree (naming the failing keys) and the scene must
    # still produce metrics instead of aborting the phase.
    $collectState = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $collect -Name 'body') -Name 'state') -Name 'collect'
    $mozExtract = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'mozExtract'))
    if ($mozExtract.Count -gt 0) {
        [IO.File]::WriteAllLines((Join-Path $evidenceDir 'moz-extract.txt'), $mozExtract, [Text.UTF8Encoding]::new($false))
    }
    # Phase 7 P1: close the sampler window right after the collect (the worker
    # log tail is already captured) and keep the evidence for the analysis.
    $samplerEvidence = Stop-OpenPathFirstVisitSamplers -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Staging $observeStaging
    if ($samplerEvidence.error) { Write-Warning "first-visit sampler stop: $($samplerEvidence.error)" }
    $security = $null
    $securityError = ''
    # Phase 5.2 E2: the student host probe is scene evidence, not a gate: its
    # result travels in metrics and never changes the persisted verdict.
    $hostProbe = $null
    $hostProbeError = ''
    try {
        $hostProbe = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'host-probe' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 240 -AllowRetry
    }
    catch {
        $hostProbeError = [string]$_.Exception.Message
        if ($hostProbeError.Length -gt 400) { $hostProbeError = $hostProbeError.Substring(0, 400) + '...' }
        Write-Warning "first-visit student host probe failed: $hostProbeError"
    }
    $hostProbeState = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $hostProbe -Name 'body') -Name 'state'
    $hostProbeResult = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $hostProbeState -Name 'hostProbe') -Name 'result'
    if (-not $hostProbeError) {
        $hostProbeError = [string](Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $hostProbeState -Name 'hostProbe') -Name 'error')
    }
    # Phase 7 L2: with SAC still enforced, force a host recompilation through the
    # product's own ensure (delete the compiled exe + build manifest) and repeat
    # the student probe. This is the auto-update path when the .cs changes.
    $hostRecompile = $null
    if ([string]$state.smartAppControl -eq 'on-before-install') {
        try {
            $recompileStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'host-recompile' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 600 -AllowFailed
            $hostRecompile = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $recompileStep -Name 'body') -Name 'state') -Name 'hostRecompile'
        }
        catch { Write-Warning "first-visit host recompile step failed: $($_.Exception.Message)" }
    }
    # Phase 6 B: post-boot CodeIntegrity / language-mode / agent-state evidence
    # for every scenario (also with SAC=2), bounded and best-effort.
    $postEvents = $null
    $postEventsError = ''
    try {
        $postEventsStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'host-events' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300 -AllowRetry -AllowFailed
        $postEvents = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $postEventsStep -Name 'body') -Name 'state') -Name 'hostEvents'
    }
    catch {
        $postEventsError = [string]$_.Exception.Message
        if ($postEventsError.Length -gt 400) { $postEventsError = $postEventsError.Substring(0, 400) + '...' }
        Write-Warning "first-visit post-boot host events failed: $postEventsError"
    }
    # Phase 6 B: the SAC-blocked signal needs the post-boot CodeIntegrity
    # evidence; the merged product reasons feed the verdict document.
    $postHostVerdict = $null
    if ($postEvents) {
        $postLive = [pscustomobject]@{ hostStarted = (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $state -Name 'liveSignals') -Name 'hostStarted') }
        $postHostVerdict = Get-FirstVisitHostSignalsVerdict -Live $postLive -Events $postEvents -CodeIntegrityEvents $postEvents -Capabilities ([string]$state.capabilities.CapabilityArgument) -StudentUserName $settings.StudentUserName -SmartAppControlState ([string](Get-OpenPathLabField -InputObject $sacStateInfo -Name 'smartAppControlState'))
    }
    if ($scenario -in @('first-visit-settled', 'first-visit-floor') -and -not $siteMode) {
        try {
            $security = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'security' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300 -AllowRetry
        }
        catch {
            $securityError = [string]$_.Exception.Message
            if ($securityError.Length -gt 400) { $securityError = $securityError.Substring(0, 400) + '...' }
            Write-Warning "first-visit security step failed: $securityError"
        }
        if ($script:OpenPathFirstVisitSecuritySettleSeconds -gt 0) { Start-Sleep -Seconds $script:OpenPathFirstVisitSecuritySettleSeconds }
        $blockedCapture = Join-Path $captureDir "console-$scenario-blocked.ppm"
        try { & $Transport.CaptureScreendump $Vmid $blockedCapture | Out-Null } catch { Write-Warning 'blocked screendump failed' }
    }
    $workerStateJson = [string](Get-OpenPathLabField -InputObject $collectState -Name 'workerState')
    if ($workerStateJson -and -not $workerStateJson.StartsWith('{')) { $workerStateJson = '' }
    $metricsFixture = if ($fixtureState) {
        [pscustomobject]@{ requests = [int](Get-OpenPathLabField -InputObject $fixtureState -Name 'requests'); browserRequests = $browserRequests; workerStateJson = $workerStateJson }
    }
    else { [pscustomobject]@{ requests = 0; browserRequests = 0; workerStateJson = $workerStateJson } }
    $collectDiagnostics = Get-OpenPathLabField -InputObject $collectState -Name 'diagnostics'
    $collectTimings = Get-OpenPathLabField -InputObject $collectState -Name 'timings'
    $diagnosticLines = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectDiagnostics -Name 'all'))
    $startupProfiles = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'startupProfiles'))
    $openpathTail = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'openpathTail'))
    # Phase 6 C: the real-site canary verdict is computed from the collected
    # evidence (extension holds/outcomes, bounded MOZ_LOG nsHostResolver lines
    # for the learned hosts and the worker stamp lines). It never fails the run:
    # only INFRA does. The verdict document is written here (there is no page
    # self-report to persist before the collect).
    $canary = $null
    $canaryMetrics = $null
    if ($siteMode -or $scenario -eq 'first-visit-update-contention') {
        $canaryDiagnostics = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'canaryDiagnostics'))
        $canaryOverlayHosts = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'overlayHosts'))
        # Phase 6.1 B: the canary verifies real navigation: the site host must
        # appear in an extension navigation diagnostic, otherwise the scene is
        # INFRA site-not-navigated (checked by the outcome classifier).
        $siteHost = ''
        if ($siteMode) {
            try {
                $siteHost = [string](Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $plan -Name 'anchors') -Name 'a1') -Name 'host')
            }
            catch { }
        }
        $canaryMetrics = Get-OpenPathFirstVisitCanaryMetrics -DiagnosticLines $canaryDiagnostics -OpenPathLines $openpathTail -SiteHost $siteHost
        if ($siteMode) {
            $canaryMoz = Select-OpenPathFirstVisitMozHostLines -MozLines $mozExtract -Hosts $canaryOverlayHosts -ReadyTimes (Get-OpenPathLabField -InputObject $canaryMetrics -Name 'readyTimes')
        }
        else {
            # Phase 7 L1: the update-contention scene has no real-site MOZ
            # extract; its negative-lookup evidence comes from the held hosts'
            # own diagnostics only.
            $canaryMoz = [ordered]@{ linesByHost = [ordered]@{}; negativesAfterReady = @(); negativeCount = 0 }
        }
        $canaryVerdict = Get-OpenPathFirstVisitCanaryVerdict -Metrics $canaryMetrics -MozResult $canaryMoz
        $canary = [ordered]@{
            status              = [string]$canaryVerdict.status
            reasons             = @($canaryVerdict.reasons)
            metrics             = $canaryMetrics
            negativeCount       = [int](Get-OpenPathLabField -InputObject $canaryMoz -Name 'negativeCount')
            negativesAfterReady = @(Get-OpenPathLabField -InputObject $canaryMoz -Name 'negativesAfterReady')
            linesByHost         = Get-OpenPathLabField -InputObject $canaryMoz -Name 'linesByHost'
            hostCount           = $canaryOverlayHosts.Count
            diagnostics         = $canaryDiagnostics.Count
            mozLines            = $mozExtract.Count
            siteHost            = $siteHost
            siteNavigated       = [bool](Get-OpenPathLabField -InputObject $canaryMetrics -Name 'siteNavigated')
            siteNavigationTs    = [long](Get-OpenPathLabField -InputObject $canaryMetrics -Name 'siteNavigationTs')
            navigationEvents    = @(Get-OpenPathLabField -InputObject $canaryMetrics -Name 'navigationEvents')
        }
        if ($scenario -eq 'first-visit-update-contention') {
            # Phase 7 L1: the acceptance analysis (update in course at the first
            # retention, enqueue->ready p95 <= 3 s, zero cancelled-budget).
            $contentionAnalysis = Get-OpenPathFirstVisitUpdateContention -OpenPathLines $openpathTail -DiagnosticLines $canaryDiagnostics -CanaryMetrics $canaryMetrics
            $canary['contention'] = $contentionAnalysis
            $canary['updateTrigger'] = $updateTrigger
        }
        $prepareHostEvidenceForCanary = Get-OpenPathLabField -InputObject $state -Name 'hostEvidence'
        if ($siteMode) {
            $verdictDocument = [ordered]@{
                schemaVersion       = 1
                scenario            = $scenario
                source              = 'canary'
                canary              = $true
                canaryStatus        = [string]$canaryVerdict.status
                canaryReasons       = @($canaryVerdict.reasons)
                canaryMetrics       = $canaryMetrics
                negativesAfterReady = @(Get-OpenPathLabField -InputObject $canaryMoz -Name 'negativesAfterReady')
                siteHost            = $siteHost
                siteNavigated       = [bool](Get-OpenPathLabField -InputObject $canaryMetrics -Name 'siteNavigated')
                siteNavigationTs    = [long](Get-OpenPathLabField -InputObject $canaryMetrics -Name 'siteNavigationTs')
                siteNavigationEvents = @(Get-OpenPathLabField -InputObject $canaryMetrics -Name 'navigationEvents')
                reportPresent       = $false
                verdict             = [ordered]@{
                    status  = if ([string]$canaryVerdict.status -eq 'CANARY-PASS') { 'canary-pass' } else { 'canary-red' }
                    reasons = @($canaryVerdict.reasons)
                    waves   = [ordered]@{}
                }
                productReasons      = @(Get-OpenPathLabField -InputObject $prepareHostEvidenceForCanary -Name 'productReasons')
                hostStarted         = [bool](Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $state -Name 'liveSignals') -Name 'hostStarted')
                evidenceIncomplete  = [bool]$collectError
                collectError        = $collectError
                writtenAt           = [DateTime]::UtcNow.ToString('o')
            }
            [IO.File]::WriteAllText($verdictPath, ($verdictDocument | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false))
        }
        elseif ($verdictDocument) {
            # Phase 7 L1: the update-contention scene keeps its page self-report
            # verdict and adds the canary/contention evidence to the same file.
            $verdictDocument.canaryMetrics = $canaryMetrics
            $verdictDocument.canaryStatus = [string]$canaryVerdict.status
            $verdictDocument.canaryReasons = @($canaryVerdict.reasons)
            $verdictDocument.contention = $canary['contention']
            $verdictDocument.updateTrigger = $updateTrigger
            [IO.File]::WriteAllText($verdictPath, ($verdictDocument | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false))
        }
    }
    # Phase 7 P1: classify every >2 s worker gap with the sampler timeline and
    # the host pressure; a whole-VM stall overlapping a not-ready retention is
    # INFRA vm-stall, never a product/canary result.
    $stall = $null
    $infraVmStall = $false
    if ($samplerEvidence) {
        $guestStall = $samplerEvidence.guestSampler
        $workerGaps = @(Get-OpenPathFirstVisitWorkerGaps -OpenPathLines $openpathTail)
        $stall = Get-OpenPathFirstVisitStallClassification `
            -LogGaps $workerGaps `
            -SamplerGaps @(Get-OpenPathLabField -InputObject $guestStall -Name 'samplerGaps') `
            -SaturationWindows @(Get-OpenPathLabField -InputObject $guestStall -Name 'saturationWindows') `
            -HostPressure @($samplerEvidence.pressure)
        if ($null -ne $canaryMetrics) {
            $notReady = @()
            foreach ($entry in @(Get-OpenPathLabField -InputObject $canaryMetrics -Name 'holdOutcomes')) {
                if ([string](Get-OpenPathLabField -InputObject $entry -Name 'outcome') -ne 'ready') { $notReady += $entry }
            }
            foreach ($gap in @($stall.gaps)) {
                if ([string]$gap.classification -ne 'vm-stall') { continue }
                foreach ($entry in $notReady) {
                    $ts = [long](Get-OpenPathLabField -InputObject $entry -Name 'ts')
                    if ($ts -ge [long]$gap.startMs -and $ts -le [long]$gap.endMs) { $infraVmStall = $true }
                }
            }
        }
        $stall['infraVmStall'] = $infraVmStall
        try {
            $stallSamplesPath = Join-Path $artifactsRoot 'stall-samples.json'
            $stallRecord = [ordered]@{
                classification = $stall
                guest = [ordered]@{
                    sampleCount       = [int](Get-OpenPathLabField -InputObject $guestStall -Name 'sampleCount')
                    maxSystemCpu      = Get-OpenPathLabField -InputObject $guestStall -Name 'maxSystemCpu'
                    samplerGaps       = @(Get-OpenPathLabField -InputObject $guestStall -Name 'samplerGaps')
                    saturationWindows = @(Get-OpenPathLabField -InputObject $guestStall -Name 'saturationWindows')
                    decimated         = @(Get-OpenPathLabField -InputObject $guestStall -Name 'decimated')
                }
                hostPressure = @($samplerEvidence.pressure)
                samplerError = $samplerEvidence.error
            }
            [IO.File]::WriteAllText($stallSamplesPath, ($stallRecord | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        }
        catch { Write-Warning "stall samples record failed: $($_.Exception.Message)" }
        if ($stall.gaps.Count -gt 0) {
            $gapSummary = @($stall.gaps | ForEach-Object { "$($_.classification):$($_.gapMs)ms" }) -join ' '
            Write-Host "first-visit stall classification: $($stall.classification) gaps=[$gapSummary] vmStall=$($stall.vmStall) infraVmStall=$infraVmStall"
        }
    }
    if ($verdictDocument -and $infraVmStall) {
        $verdictDocument.infraVmStall = $true
        [IO.File]::WriteAllText($verdictPath, ($verdictDocument | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false))
    }
    # Phase 6 B: merge the post-boot host verdict into the persisted document
    # (a SAC/CodeIntegrity block is a product reason even when the visit ran).
    if ($postHostVerdict -and @($postHostVerdict.productReasons).Count -gt 0) {
        $mergedReasons = @($verdictDocument.productReasons) + @($postHostVerdict.productReasons)
        $verdictDocument.productReasons = @($mergedReasons | Select-Object -Unique)
        $verdictDocument.blockedBySmartAppControl = [bool]$postHostVerdict.blockedBySmartAppControl
        [IO.File]::WriteAllText($verdictPath, ($verdictDocument | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false))
    }
    # Phase 7 L2: consolidated on-before-install evidence.
    $sacOnBeforeInstall = $null
    if ([string]$state.smartAppControl -eq 'on-before-install') {
        $sacOnBeforeInstall = [ordered]@{
            preInstallApply    = $state.sacApply
            preInstallDecision = $state.sacPreInstallDecision
            preInstallCycle    = $state.sacPreInstall
            hostCompile        = $state.hostCompile
            hostRecompile      = $hostRecompile
            probe              = $hostProbeResult
        }
    }
    $metrics = Get-OpenPathFirstVisitMetrics -Plan $plan -Scenario $scenario -Report $report -DiagnosticLines $diagnosticLines -StartupProfiles $startupProfiles -FixtureState $metricsFixture -Verdict $verdict -LogLines $openpathTail -Diagnostics $collectDiagnostics -PrepareState $state -EvidenceIncomplete ([bool]$collectError) -CollectError $collectError -CollectTimings $collectTimings -HostProbe $hostProbeResult -HostProbeError $hostProbeError -Canary $canary -SacState $sacStateInfo -SacControl $sacControlInfo -PostHostEvents $postEvents -PostHostVerdict $postHostVerdict -VisitDiagnostics $visitDiagnostics -Stall $stall -OnBeforeInstall $sacOnBeforeInstall
    if ($collectError) {
        # Same file, added fields only: the verdict written before the collect
        # is never replaced, the incompleteness is.
        $verdictDocument.evidenceIncomplete = $true
        $verdictDocument.collectError = $collectError
        [IO.File]::WriteAllText($verdictPath, ($verdictDocument | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    }
    $metricsPath = Join-Path $artifactsRoot 'metrics.json'
    [IO.File]::WriteAllText($metricsPath, ($metrics | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $studentUser = [string]$settings.StudentUserName
    foreach ($copy in @(
            @{ Path = "C:\Users\$studentUser\AppData\Local\OpenPath\native-host.log"; Name = 'native-host.log'; Reason = 'final' },
            @{ Path = 'C:\OpenPath\data\logs\openpath.log'; Name = 'openpath.log'; Reason = 'final' }
        )) {
        $copyResult = Copy-OpenPathFirstVisitGuestFile -Transport $Transport -Vmid $Vmid -GuestPath $copy.Path -LocalPath (Join-Path $evidenceDir $copy.Name) -Reason $copy.Reason
        $null = $copyEvidence.Add($copyResult)
        if (-not $copyResult.ok) { Write-Warning "guest log copy failed [$($copy.Reason)/$($copy.Name)]: $($copyResult.error)" }
    }
    try { [IO.File]::WriteAllText($copyEvidencePath, (@($copyEvidence) | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false)) } catch { }
    $body = [ordered]@{
        state = [ordered]@{
            scenario          = $scenario
            refreshMode       = $refreshMode
            visitDelaySeconds = $visitDelaySeconds
            logonAt           = $logonAt
            launchedAt        = $launchedAt
            repairReloads     = $repairReloads
            firefox           = @(Get-OpenPathLabField -InputObject $wait.body.state -Name 'firefox')
            firefoxLog        = @(Get-OpenPathLabField -InputObject $wait.body.state -Name 'firefoxLog')
            report            = $report
            verdict           = $verdict
            verdictDocument   = $verdictDocument
            metrics           = $metrics
            evidenceIncomplete = [bool]$collectError
            collectError      = $collectError
            postHostEvents    = $postEvents
            postHostEventsError = $postEventsError
            postHostVerdict   = $postHostVerdict
            sacState          = $sacStateInfo
            sacControl        = $sacControlInfo
            sacStepError      = $sacStepError
            postHostDecision  = if ($sacPostDecision) { $sacPostDecision } else { $null }
            visitDiagnostics  = $visitDiagnostics
            canary            = $canary
            security          = if ($security) { $security.body.state } else { $null }
            securityError     = $securityError
        }
    }
    return New-OpenPathLabAcceptanceObservation -Payload $Payload -Phase 'observe' -Body $body
}

function Invoke-OpenPathFirstVisitCleanup {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$RestoreBaseline
    )
    $body = [ordered]@{ state = [ordered]@{ uninstall = $null; fixtureStopped = $false } }
    # Phase 5.2 C3: each phase owns its step trace.
    $script:OpenPathFirstVisitStepTrace = $null
    try {
        $settings = Get-OpenPathLabAcceptanceSettings -Config $Config
        $state = $null
        if (Test-Path -LiteralPath $StatePath) { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
        if ($state -and $state.harnessGuestPath) {
            $uninstall = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'cleanup' -Step 'cleanup' -HarnessGuestPath ([string]$state.harnessGuestPath) -TimeoutSeconds 900
            $body.state.uninstall = $uninstall.body.state.clean
        }
    }
    catch {
        $body.state.uninstallError = [string]$_.Exception.Message
    }
    finally {
        Stop-OpenPathFirstVisitFixture -Config $Config -Transport $Transport -RunId ([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId')) -ArtifactsRoot ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot'))
        $body.state.fixtureStopped = $true
        $restore = $true
        $restoreValue = Get-OpenPathLabField -InputObject $Config -Name 'restoreBaseline'
        if ($null -ne $restoreValue) { $restore = [bool]$restoreValue }
        if ($restore) {
            try { & $Transport.StopVm $Vmid | Out-Null } catch { }
            try { & $Transport.RollbackVm $Vmid $Snapshot | Out-Null } catch { }
        }
        else {
            try { & $Transport.StopVm $Vmid | Out-Null } catch { }
        }
    }
    return New-OpenPathLabAcceptanceObservation -Payload $Payload -Phase 'cleanup' -Body $body
}
