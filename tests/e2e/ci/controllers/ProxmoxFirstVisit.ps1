# Phase 3A first-visit lane: controller-side phases and metrics.
#
# Dot-sourced by ProxmoxWindowsLab.psm1 so it shares the module scope (internal
# helpers, transport contract and constants). The lane is site-agnostic: the
# fixture plan (anchors, dependency hosts, blocked host) is generated per run by
# tests/e2e/ci/first-visit/fixture_server.py and fetched at runtime.

$script:OpenPathFirstVisitCaptureOffsets = @(5, 10, 15, 20, 30, 60)

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
    # A stale instance from an interrupted run would keep the ports bound.
    & $Transport.InvokeHostCommand @('pkill', '-f', "first-visit-fixtures-$RunId") '' | Out-Null
    & $Transport.InvokeHostCommand @(
        'bash', '-lc',
        "setsid nohup env OPENPATH_FIRST_VISIT_TAG=first-visit-fixtures-$RunId python3 $staging/fixture_server.py --state-dir $staging/state --port 80 --run-id $RunId --ip $($settings.HostAddress) > $staging/fixture.log 2>&1 & sleep 1; " +
        "setsid nohup python3 $staging/dns_fixture.py --state-dir $staging/state --upstream $($settings.DnsUpstream) > $staging/dns.log 2>&1 & sleep 1; echo started"
    ) '' | Out-Null
    $planText = (& $Transport.InvokeHostCommand @('curl', '-s', '--max-time', '20', 'http://127.0.0.1/plan.json') '').Trim()
    if (-not $planText.StartsWith('{')) { throw 'first-visit-fixture-plan-unavailable' }
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
        & $Transport.InvokeHostCommand @('bash', '-lc', "pkill -f 'fixture_server.py --state-dir $staging' || true; pkill -f 'dns_fixture.py --state-dir $staging' || true; echo stopped") '' | Out-Null
    }
    catch {
        Write-Warning "first-visit fixture stop failed: $($_.Exception.Message)"
    }
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
        [int]$TimeoutSeconds = 900
    )
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
    $arguments += '| Out-String'
    $script = ($arguments -join ' ') + "`nWrite-Output ('__HARNESS_EXIT__=' + [string]`$LASTEXITCODE)"
    $output = & $Transport.InvokeGuestPowerShell $Vmid $script $TimeoutSeconds
    $exitMatch = [regex]::Match([string]$output, '__HARNESS_EXIT__=(-?\d+)')
    $exitCode = if ($exitMatch.Success) { [int]$exitMatch.Groups[1].Value } else { -999 }
    $jsonText = [string]$output
    $start = $jsonText.IndexOf('{')
    $end = $jsonText.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { throw "first-visit-guest-result-missing-$Phase-$Step" }
    try { $harness = $jsonText.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "first-visit-guest-result-invalid-$Phase-$Step" }
    if ([string]$harness.status -ne 'passed' -or $exitCode -ne 0) {
        $failures = @($harness.failures) -join ','
        throw "first-visit-guest-step-failed-$Phase-$Step-$failures"
    }
    return $harness
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
        [int]$MaxReloadsClassBoot = 1
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Report,
        [Parameter(Mandatory = $true)][string[]]$DiagnosticLines,
        [Parameter(Mandatory = $true)][string[]]$StartupProfiles,
        [Parameter(Mandatory = $true)][AllowNull()][object]$FixtureState,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Verdict
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
        fontLoaded     = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'fontLoaded')
        neverLearnableBlocked = [bool](Get-OpenPathLabField -InputObject $Verdict -Name 'neverLearnableBlocked')
        reloadReasons  = $reloadReasons
        diagnosticLines = $DiagnosticLines.Count
        holdOutcomes   = $holdOutcomes.Count
        hostProfile    = $hostProfile
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
    Start-OpenPathLabAcceptanceVm -Transport $Transport -Vmid $Vmid -Snapshot $Snapshot -TimeoutSeconds $TimeoutSeconds -RestoreBaseline $RestoreBaseline
    $bootId = [string](& $Transport.GetGuestBootId $Vmid)
    if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-guest-not-ready' }
    $setup = Invoke-OpenPathLabAcceptanceGuestSetup -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -TimeoutSeconds $TimeoutSeconds -HarnessSourcePath (Get-OpenPathFirstVisitHarnessSourcePath)
    # The session launcher is a small helper the guest harness needs next to it.
    $launcherText = Get-Content -LiteralPath (Get-OpenPathFirstVisitLauncherSourcePath) -Raw
    $launcherLiteral = ConvertTo-OpenPathLabPowerShellLiteral -Value $launcherText
    & $Transport.InvokeGuestPowerShell $Vmid @"
New-Item -ItemType Directory -Path 'C:\OpenPathLab\first-visit' -Force | Out-Null
[IO.File]::WriteAllText('C:\OpenPathLab\first-visit\student-session-launch.ps1', $launcherLiteral, [Text.UTF8Encoding]::new(`$false))
Write-Output 'launcher-staged'
"@ 120 | Out-Null
    $fixture = Start-OpenPathFirstVisitFixture -Config $Config -Transport $Transport -RunId ([string](Get-OpenPathLabField -InputObject $Payload -Name 'runId')) -ArtifactsRoot ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot'))
    Write-OpenPathFirstVisitGuestFixtureInfo -Transport $Transport -Vmid $Vmid -Settings $fixture.Settings -Plan $fixture.Plan
    $install = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'install' -HarnessGuestPath $setup.HarnessGuestPath -PersonalizedGuestPath $setup.PersonalizedGuestPath -TimeoutSeconds 1800
    $configure = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'configure' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 900
    $warmup = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'prepare' -Step 'warmup' -HarnessGuestPath $setup.HarnessGuestPath -TimeoutSeconds 900
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
        extension           = $warmup.body.state.extension
        warmupClose         = $warmup.body.state.closeAfterWarmup
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
    $harnessGuestPath = [string]$state.harnessGuestPath
    $captureDir = Join-Path ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')) 'captures'
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
    $visitDelaySeconds = -1
    $logonAt = ''
    if ($scenario -eq 'first-visit-class-boot') {
        # Class boot: warm-up already ran at prepare; reboot, log in by
        # autologon and open Firefox within the class-boot window.
        $autologon = [ordered]@{ enabled = $false }
        & $Transport.InvokeGuestPowerShell $Vmid @"
`$ErrorActionPreference = 'Continue'
`$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path `$key -Name 'AutoAdminLogon' -Value '1' -Type String
Set-ItemProperty -Path `$key -Name 'DefaultUserName' -Value '$($settings.StudentUserName)' -Type String
Set-ItemProperty -Path `$key -Name 'DefaultDomainName' -Value `$env:COMPUTERNAME -Type String
Set-ItemProperty -Path `$key -Name 'DefaultPassword' -Value '$($settings.GuestSecret)' -Type String
Write-Output 'autologon-on'
"@ 120 | Out-Null
        $previousBoot = [string]$state.bootIdLatest
        & $Transport.RequestGuestReboot $Vmid | Out-Null
        $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $previousBoot $TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'first-visit-reboot-timeout' }
        $session = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Phase 'observe' -Step 'session' -TimeoutSeconds 420
        $logonAt = [string]$session.body.state.sessionLogonAt
        $visit = Invoke-OpenPathFirstVisitVisit -Payload $Payload -Config $Config -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -HarnessGuestPath $harnessGuestPath -Scenario $scenario -CaptureDir $captureDir -TimeoutSeconds 900
        if ($logonAt) {
            $visitDelaySeconds = [int](([datetime]$visit.body.state.launchedAt) - ([datetime]$logonAt)).TotalSeconds
        }
    }
    else {
        $visit = Invoke-OpenPathFirstVisitVisit -Payload $Payload -Config $Config -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -HarnessGuestPath $harnessGuestPath -Scenario $scenario -CaptureDir $captureDir -TimeoutSeconds 900
    }
    # The verdict comes from the page self-report (never from MOZ_LOG).
    $fixtureUrl = [string]$state.fixtureUrl
    $report = $null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        $stateText = (& $Transport.InvokeHostCommand @('curl', '-s', '--max-time', '10', "$fixtureUrl/state.json") '').Trim()
        if ($stateText.StartsWith('{')) {
            $fixtureState = $stateText | ConvertFrom-Json
            if ($fixtureState.lastReport) { $report = $fixtureState.lastReport; break }
        }
        Start-Sleep -Seconds 5
    }
    $collect = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'collect' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 600
    $security = $null
    if ($scenario -in @('first-visit-settled', 'first-visit-control')) {
        $security = Send-OpenPathFirstVisitStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -Phase 'observe' -Step 'security' -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 600
        $blockedCapture = Join-Path $captureDir "console-$scenario-blocked.ppm"
        try { & $Transport.CaptureScreendump $Vmid $blockedCapture | Out-Null } catch { Write-Warning 'blocked screendump failed' }
    }
    $plan = $state.plan
    $verdict = Get-OpenPathFirstVisitReportVerdict -Report $report -Plan $plan -Scenario $scenario
    $metrics = Get-OpenPathFirstVisitMetrics -Plan $plan -Scenario $scenario -Report $report -DiagnosticLines @($collect.body.state.collect.diagnosticSample) -StartupProfiles @($collect.body.state.collect.startupProfiles) -FixtureState $null -Verdict $verdict
    $metricsPath = Join-Path ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')) 'metrics.json'
    [IO.File]::WriteAllText($metricsPath, ($metrics | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $evidenceDir = Join-Path ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')) 'guest-logs'
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    $studentUser = [string]$settings.StudentUserName
    Copy-OpenPathFirstVisitGuestFile -Transport $Transport -Vmid $Vmid -GuestPath "C:\Users\$studentUser\AppData\Local\OpenPath\native-host.log" -LocalPath (Join-Path $evidenceDir 'native-host.log') | Out-Null
    Copy-OpenPathFirstVisitGuestFile -Transport $Transport -Vmid $Vmid -GuestPath 'C:\OpenPath\logs\openpath.log' -LocalPath (Join-Path $evidenceDir 'openpath.log') | Out-Null
    $body = [ordered]@{
        state           = [ordered]@{
            scenario          = $scenario
            visitDelaySeconds = $visitDelaySeconds
            logonAt           = $logonAt
            visit             = $visit.body.state
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
