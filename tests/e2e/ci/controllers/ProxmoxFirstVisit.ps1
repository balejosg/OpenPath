# Phase 3A first-visit lane: controller-side phases and metrics.
#
# Dot-sourced by ProxmoxWindowsLab.psm1 so it shares the module scope (internal
# helpers, transport contract and constants). The lane is site-agnostic: the
# fixture plan (anchors, dependency hosts, blocked host) is generated per run by
# tests/e2e/ci/first-visit/fixture_server.py and fetched at runtime.

# Phase 3A.3: verdict and result contracts shared with the guest harness.
Import-Module (Join-Path $PSScriptRoot '..\first-visit\FirstVisitResult.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\first-visit\FirstVisitWarmup.psm1') -Force

$script:OpenPathFirstVisitCaptureOffsets = @(5, 10, 15, 20, 30, 60)
$script:OpenPathFirstVisitRefreshSettleSeconds = 30
$script:OpenPathFirstVisitObserveSettleSeconds = 15
$script:OpenPathFirstVisitHotWindowSeconds = 300
$script:OpenPathFirstVisitHotSecondSettleSeconds = 20
# Phase 5 A2: per-phase step trace (step, elapsed, source, status). Append-only
# and persisted after every step so a killed controller can still be measured.
$script:OpenPathFirstVisitStepTrace = $null

function Get-OpenPathFirstVisitHarnessSourcePath {
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'first-visit\Invoke-OpenPathFirstVisitGuest.ps1')
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
    return [pscustomobject]@{
        Scenario    = $scenario
        FixtureUrl  = "http://$hostAddress"
        DnsIp       = $hostAddress
        DnsUpstream = $upstream
        HostAddress = $hostAddress
    }
}

function Start-OpenPathFirstVisitFixture {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot
    )
    $stagingRoot = [string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot')
    if ([string]::IsNullOrWhiteSpace($stagingRoot)) { $stagingRoot = '/var/tmp/openpath-first-visit' }
    $staging = "$stagingRoot/$RunId".Replace('//', '/')
    $settings = Get-OpenPathFirstVisitSettings -Payload ([pscustomobject]@{ firstVisit = [pscustomobject]@{ scenario = 'first-visit-settled' } }) -Config $Config
    $localFixtures = Get-OpenPathFirstVisitFixturesRoot

    & $Transport.InvokeHostCommand @('mkdir', '-p', "$staging/state") '' | Out-Null
    foreach ($name in @('fixture_server.py', 'dns_fixture.py')) {
        & $Transport.CopyFileToHost (Join-Path $localFixtures $name) "$staging/$name" | Out-Null
    }
    # A stale instance from an interrupted run keeps the ports bound and the
    # next start fails with EADDRINUSE; clear every fixture instance first.
    # The bracket form keeps pkill from matching its own ssh command line.
    & $Transport.InvokeHostCommand @('bash', '-lc', "pkill -f 'fixture[_]server.py --state-dir' || true; pkill -f 'dns[_]fixture.py --state-dir' || true; sleep 2; echo cleared") '' | Out-Null
    $startCommand = "setsid nohup python3 $staging/dns_fixture.py --state-dir $staging/state --upstream $($settings.DnsUpstream) > $staging/dns.log 2>&1 < /dev/null & sleep 1; " +
    "setsid nohup python3 $staging/fixture_server.py --state-dir $staging/state --port 80 --run-id $RunId --ip $($settings.HostAddress) > $staging/fixture.log 2>&1 < /dev/null & sleep 2; echo started"
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
    $null = $script:OpenPathFirstVisitStepTrace.Add($Entry)
    if ([string]::IsNullOrWhiteSpace($ArtifactsRoot) -or [string]::IsNullOrWhiteSpace($Phase)) { return }
    try {
        $path = Join-Path $ArtifactsRoot "$Phase-step-trace.json"
        [IO.File]::WriteAllText($path, (@($script:OpenPathFirstVisitStepTrace) | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    }
    catch { }
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
        status         = ''
        failures       = @()
    }
    $artifactsRoot = ''
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
    $arguments += '| Out-String'
    $script = ($arguments -join ' ') + "`nWrite-Output ('__HARNESS_EXIT__=' + [string]`$LASTEXITCODE)"
    $attemptTimeout = [math]::Min($TimeoutSeconds, 600)
    $maxAttempts = if ($AllowRetry) { 2 } else { 1 }
    $output = ''
    $fileText = ''
    $exitCode = -999
    $exitKnown = $false
    $artifactsRoot = [string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try { $output = & $Transport.InvokeGuestPowerShell $Vmid $script $attemptTimeout }
        catch { $output = '' }
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
        if ($attempt -ge $maxAttempts) { break }
        Update-OpenPathLabActiveHeartbeat
        Start-Sleep -Seconds 15
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
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [int]$MaxBytes = 2000000
    )
    $script = @"
if (Test-Path -LiteralPath '$GuestPath') {
    `$bytes = [IO.File]::ReadAllBytes('$GuestPath')
    if (`$bytes.Length -gt $MaxBytes) { `$bytes = `$bytes[(`$bytes.Length - $MaxBytes)..(`$bytes.Length - 1)] }
    [Convert]::ToBase64String(`$bytes)
} else { 'MISSING' }
"@
    $output = (& $Transport.InvokeGuestPowerShell $Vmid $script 300 | Out-String).Trim()
    $lines = @($output -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^(VERBOSE|WARNING|DEBUG)' })
    $base64 = $lines[-1]
    if ($base64 -eq 'MISSING' -or -not $base64) { return $false }
    try {
        [IO.File]::WriteAllBytes($LocalPath, [Convert]::FromBase64String($base64))
        return $true
    }
    catch {
        return $false
    }
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
    }
    if ($null -eq $Report -or -not $Report.waves) {
        $result.reasons += 'self-report-missing'
        return [pscustomobject]$result
    }
    $isClassBoot = ($Scenario -eq 'first-visit-class-boot')
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
    $result.status = if ($result.reasons | Where-Object { $_ -like '*incomplete*' -or $_ -in @('too-many-reloads', 'self-report-missing', 'never-learnable-host-not-blocked') }) { 'failed' } else { 'passed' }
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
        [AllowNull()][object]$PrepareState = $null
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
        verdict        = if ($Verdict) { [string]$Verdict.status } else { 'failed' }
        reasons        = if ($Verdict) { @($Verdict.reasons) } else { @('no-verdict') }
        waves          = if ($Verdict) { $Verdict.waves } else { $null }
        waveTimesMs    = if ($Verdict) { $Verdict.timesMs } else { $null }
        reloads        = if ($Verdict) { $Verdict.reloads } else { -1 }
        repairReloads  = if ($Verdict) { $Verdict.reloads } else { -1 }
        fontLoaded     = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'fontLoaded')
        neverLearnableBlocked = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'neverLearnableBlocked')
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
        }
        fixture        = if ($FixtureState) { [ordered]@{ requests = [int]$FixtureState.requests } } else { $null }
    }
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
    foreach ($moduleName in @('FirstVisitWarmup.psm1', 'FirstVisitResult.psm1')) {
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
    $fixture = Start-OpenPathFirstVisitFixture -Config $Config -Transport $Transport -RunId ([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId')) -ArtifactsRoot ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot'))
    Write-OpenPathFirstVisitGuestFixtureInfo -Transport $Transport -Vmid $Vmid -Settings $fixture.Settings -Plan $fixture.Plan
    $install = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'install' -HarnessGuestPath $setup.HarnessGuestPath -PersonalizedGuestPath $setup.PersonalizedGuestPath -TimeoutSeconds 1800
    $configure = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'configure' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 900
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
    try {
        $hostEventsStep = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'host-events' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 300 -AllowRetry -AllowFailed
        $hostEventsBody = $hostEventsStep.body.state.hostEvents
    }
    catch { $hostEvidenceError = (($hostEvidenceError + ' ' + [string]$_.Exception.Message).Trim()) }
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
    $state = [ordered]@{
        phase               = 'prepared'
        scenarioId          = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
        bootIdBefore        = $bootId
        bootIdLatest        = $bootId
        harnessGuestPath    = $setup.HarnessGuestPath
        personalizedGuestPath = $setup.PersonalizedGuestPath
        guestSecret         = $settings.GuestSecret
        fixtureUrl          = $firstVisit.FixtureUrl
        dnsIp               = $firstVisit.DnsIp
        plan                = $fixture.Plan
        install             = $install.body.state.install
        configured          = [bool]$configure.body.state.registered
        passwordReset       = ($passwordReset -match 'done')
        sessionUser         = $sessionUser
        capabilities        = $capabilities
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
    $firstVisit = Get-OpenPathLabField -InputObject $Payload -Name 'firstVisit'
    $scenario = if ($firstVisit) { [string](Get-OpenPathLabField -InputObject $firstVisit -Name 'scenario') } else { 'first-visit-settled' }
    if (-not $scenario) { $scenario = 'first-visit-settled' }
    if ([string](Get-OpenPathLabField -InputObject $Config -Name 'mode') -ne 'acceptance') {
        throw 'first-visit-requires-acceptance-lab-config'
    }
    $harnessGuestPath = [string]$state.harnessGuestPath
    $artifactsRoot = [string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')
    $captureDir = Join-Path $artifactsRoot 'captures'
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
    $evidenceDir = Join-Path $artifactsRoot 'guest-logs'
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null

    # 1) Arm the visit (wrapper + Run key) and refresh the session: logoff for
    #    settled/hot/control (the persistent host process stays warm), reboot for
    #    class-boot (Firefox starts within the class-boot window at logon).
    $arm = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'visit' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300
    $refreshMode = [string](Get-OpenPathLabField -InputObject $arm.body.state.arm -Name 'mode')
    $logonAt = ''
    if ($scenario -eq 'first-visit-class-boot') {
        # The visit step armed the run-key wrapper and requested the reboot; wait
        # for the new boot, the real logon and the browser it starts.
        $bootBefore = [string]$state.bootIdLatest
        $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $bootBefore $TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-reboot-timeout' }
        $session = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Phase 'observe' -Step 'session' -TimeoutSeconds 420
        $logonAt = [string]$session.body.state.sessionLogonAt
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

    # 3) The verdict comes from the page self-report (never from MOZ_LOG); the
    #    repair-reload count is computed from the report sequence.
    $fixtureUrl = [string]$state.fixtureUrl
    $staging = "$([string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot'))/$([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId'))".Replace('//', '/')
    $report = $null
    $fixtureState = $null
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $stateTextForObserve = (& $Transport.InvokeHostCommand @('curl', '-s', '--max-time', '10', "$fixtureUrl/state.json") '').Trim()
        if ($stateTextForObserve.StartsWith('{')) {
            $fixtureState = $stateTextForObserve | ConvertFrom-Json
            if ($fixtureState.lastReport) { $report = $fixtureState.lastReport; break }
        }
        Start-Sleep -Seconds 5
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
    if ($browserRequests -le 0) {
        throw 'first-visit-fixture-served-no-requests'
    }
    $collect = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'collect' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 600 -AllowRetry
    # Strict mode: never dereference a property chain directly. The serializer
    # may drop the collect subtree (naming the failing keys) and the scene must
    # still produce metrics instead of aborting the phase.
    $collectState = Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject (Get-OpenPathLabField -InputObject $collect -Name 'body') -Name 'state') -Name 'collect'
    $mozExtract = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'mozExtract'))
    if ($mozExtract.Count -gt 0) {
        [IO.File]::WriteAllLines((Join-Path $evidenceDir 'moz-extract.txt'), $mozExtract, [Text.UTF8Encoding]::new($false))
    }
    $security = $null
    if ($scenario -in @('first-visit-settled', 'first-visit-control')) {
        $security = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'security' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 600 -AllowRetry
        Start-Sleep -Seconds 20
        $blockedCapture = Join-Path $captureDir "console-$scenario-blocked.ppm"
        try { & $Transport.CaptureScreendump $Vmid $blockedCapture | Out-Null } catch { Write-Warning 'blocked screendump failed' }
    }
    $plan = $state.plan
    $verdict = Get-OpenPathFirstVisitReportVerdict -Report $report -Plan $plan -Scenario $scenario -RepairReloads $repairReloads
    $workerStateJson = [string](Get-OpenPathLabField -InputObject $collectState -Name 'workerState')
    if ($workerStateJson -and -not $workerStateJson.StartsWith('{')) { $workerStateJson = '' }
    $metricsFixture = if ($fixtureState) {
        [pscustomobject]@{ requests = [int](Get-OpenPathLabField -InputObject $fixtureState -Name 'requests'); browserRequests = $browserRequests; workerStateJson = $workerStateJson }
    }
    else { [pscustomobject]@{ requests = 0; browserRequests = 0; workerStateJson = $workerStateJson } }
    $collectDiagnostics = Get-OpenPathLabField -InputObject $collectState -Name 'diagnostics'
    $diagnosticLines = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectDiagnostics -Name 'all'))
    $startupProfiles = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'startupProfiles'))
    $openpathTail = @(Get-OpenPathFirstVisitStringArray -Value (Get-OpenPathLabField -InputObject $collectState -Name 'openpathTail'))
    $metrics = Get-OpenPathFirstVisitMetrics -Plan $plan -Scenario $scenario -Report $report -DiagnosticLines $diagnosticLines -StartupProfiles $startupProfiles -FixtureState $metricsFixture -Verdict $verdict -LogLines $openpathTail -Diagnostics $collectDiagnostics -PrepareState $state
    $metricsPath = Join-Path $artifactsRoot 'metrics.json'
    [IO.File]::WriteAllText($metricsPath, ($metrics | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $studentUser = [string]$settings.StudentUserName
    Copy-OpenPathFirstVisitGuestFile -Transport $Transport -Vmid $Vmid -GuestPath "C:\Users\$studentUser\AppData\Local\OpenPath\native-host.log" -LocalPath (Join-Path $evidenceDir 'native-host.log') | Out-Null
    Copy-OpenPathFirstVisitGuestFile -Transport $Transport -Vmid $Vmid -GuestPath 'C:\OpenPath\logs\openpath.log' -LocalPath (Join-Path $evidenceDir 'openpath.log') | Out-Null
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
            metrics           = $metrics
            security          = if ($security) { $security.body.state } else { $null }
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
