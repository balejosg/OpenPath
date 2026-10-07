# Phase 3A first-visit lane tests: fixture-host learnability, self-report
# verdict and metrics extraction. No hypervisor or network access required.

Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\controllers\ProxmoxWindowsLab.psm1') -Force

Describe 'First-visit lane' {
    Context 'Fixture hosts under RuntimeDependency.Policy' {
        BeforeAll {
            $policyPath = Join-Path $PSScriptRoot '..' 'lib' 'internal' 'RuntimeDependency.Policy.ps1'
            $anchor = 'anchor1-ab12cd.192.168.1.150.sslip.io'
            $dependency = 'styles1-ab12cd.192.168.1.150.sslip.io'
            $blocked = 'blocked9-ab12cd.192.168.1.150.sslip.io'
            function Invoke-PolicyProbe {
                param([string]$Anchor, [string]$Dependency, [string[]]$Whitelist = @(), [string[]]$Blocked = @())
                $script = @"
`$ErrorActionPreference='Stop'
. '$policyPath'
`$result = Test-OpenPathRuntimeDependencyCandidate -Message ([pscustomobject]@{ anchorHost = '$Anchor'; dependencyHost = '$Dependency'; requestType = 'stylesheet' }) -WhitelistedDomains @($((($Whitelist | ForEach-Object { "'" + $_ + "'" }) -join ','))) -BlockedSubdomains @($((($Blocked | ForEach-Object { "'" + $_ + "'" }) -join ','))) -SkipOverlayCheck
Write-Output ('VALID=' + [string]`$result.Valid)
"@
                $output = & pwsh -NoProfile -Command $script | Select-Object -Last 1
                return $output -eq 'VALID=True'
            }
        }

        It 'Accepts a fixture dependency host when the anchor is whitelisted' {
            Invoke-PolicyProbe -Anchor $anchor -Dependency $dependency -Whitelist @($anchor) | Should -BeTrue
        }

        It 'Rejects the dependency when the anchor is not whitelisted' {
            Invoke-PolicyProbe -Anchor $anchor -Dependency $dependency -Whitelist @() | Should -BeFalse
        }

        It 'Rejects the never-learnable host through the blocked-subdomains section' {
            Invoke-PolicyProbe -Anchor $anchor -Dependency $blocked -Whitelist @($anchor) -Blocked @($blocked) | Should -BeFalse
        }

        It 'Skips a dependency that is already whitelisted instead of learning it again' {
            $script = @"
`$ErrorActionPreference='Stop'
. '$policyPath'
`$result = Test-OpenPathRuntimeDependencyCandidate -Message ([pscustomobject]@{ anchorHost = '$anchor'; dependencyHost = 'www.example.org'; requestType = 'stylesheet' }) -WhitelistedDomains @('$anchor','example.org') -BlockedSubdomains @() -SkipOverlayCheck
Write-Output ('SKIPPED=' + [string]`$result.Result.skipped)
"@
            (& pwsh -NoProfile -Command $script | Select-Object -Last 1) | Should -Be 'SKIPPED=True'
        }
    }

    Context 'Self-report verdict' {
        BeforeAll {
            function New-FirstVisitPlanFixture {
                return [pscustomobject]@{
                    anchors = [pscustomobject]@{
                        a1 = [pscustomobject]@{ host = 'anchor1-x.192.168.1.150.sslip.io'; roles = [pscustomobject]@{} }
                        a2 = [pscustomobject]@{ host = 'anchor2-x.192.168.1.150.sslip.io'; roles = [pscustomobject]@{} }
                    }
                    controlDependencies = @('styles1-x.192.168.1.150.sslip.io')
                    neverLearnable     = 'blocked9-x.192.168.1.150.sslip.io'
                }
            }
            function New-FirstVisitReportFixture {
                param(
                    [int]$Core = 3000,
                    [int]$Deferred = 5000,
                    [int]$Api = 7000,
                    [int]$Loads = 1,
                    [bool]$ApiPainted = $true,
                    [bool]$BlockedCssFailed = $true
                )
                return [pscustomobject]@{
                    anchor = 'a1'
                    loads  = $Loads
                    waves  = [pscustomobject]@{
                        cssApplied = $true; coreExecuted = $true; imageLoaded = $true
                        deferredExecuted = $true; apiPainted = $ApiPainted
                        fontLoaded = $true; blockedCssFailed = $BlockedCssFailed
                    }
                    marks  = [pscustomobject]@{ core = $Core; deferred = $Deferred; api = $Api }
                }
            }
        }

        It 'Passes a settled visit with all three waves inside 15 s and no reloads' {
            $plan = New-FirstVisitPlanFixture
            $verdict = Get-OpenPathFirstVisitReportVerdict -Report (New-FirstVisitReportFixture) -Plan $plan -Scenario 'first-visit-settled'
            $verdict.status | Should -Be 'passed'
            $verdict.reloads | Should -Be 0
            $verdict.fontLoaded | Should -BeTrue
            $verdict.neverLearnableBlocked | Should -BeTrue
        }

        It 'Fails a settled visit that reloaded (W/W2 allow zero reloads)' {
            $plan = New-FirstVisitPlanFixture
            $verdict = Get-OpenPathFirstVisitReportVerdict -Report (New-FirstVisitReportFixture -Loads 2) -Plan $plan -Scenario 'first-visit-settled'
            $verdict.status | Should -Be 'failed'
            $verdict.reasons | Should -Contain 'too-many-reloads'
        }

        It 'Passes a class-boot visit inside 30 s with at most one reload' {
            $plan = New-FirstVisitPlanFixture
            $report = New-FirstVisitReportFixture -Core 20000 -Deferred 24000 -Api 28000 -Loads 2
            $verdict = Get-OpenPathFirstVisitReportVerdict -Report $report -Plan $plan -Scenario 'first-visit-class-boot'
            $verdict.status | Should -Be 'passed'
            $verdict.reloads | Should -Be 1
        }

        It 'Fails a class-boot visit when a wave is incomplete or over 30 s' {
            $plan = New-FirstVisitPlanFixture
            $incomplete = Get-OpenPathFirstVisitReportVerdict -Report (New-FirstVisitReportFixture -ApiPainted $false) -Plan $plan -Scenario 'first-visit-class-boot'
            $incomplete.status | Should -Be 'failed'
            $overThreshold = Get-OpenPathFirstVisitReportVerdict -Report (New-FirstVisitReportFixture -Core 20000 -Deferred 24000 -Api 31000) -Plan $plan -Scenario 'first-visit-class-boot'
            $overThreshold.status | Should -Be 'failed'
            $overThreshold.reasons | Should -Contain 'wave3-incomplete-or-over-threshold'
        }

        It 'Never passes without a self-report' {
            $plan = New-FirstVisitPlanFixture
            $verdict = Get-OpenPathFirstVisitReportVerdict -Report $null -Plan $plan -Scenario 'first-visit-settled'
            $verdict.status | Should -Be 'failed'
            $verdict.reasons | Should -Contain 'self-report-missing'
        }

        It 'Fails when the never-learnable host was not blocked by the client' {
            $plan = New-FirstVisitPlanFixture
            $verdict = Get-OpenPathFirstVisitReportVerdict -Report (New-FirstVisitReportFixture -BlockedCssFailed $false) -Plan $plan -Scenario 'first-visit-settled'
            $verdict.status | Should -Be 'failed'
            $verdict.reasons | Should -Contain 'never-learnable-host-not-blocked'
        }
    }

    Context 'Controller dispatch (fake transport)' {
        BeforeAll {
            function New-FirstVisitFakePlan {
                # Built as an object so no key/value JSON literal with an
                # API-shaped key ever lands in the repository text (gitleaks).
                $roles = [ordered]@{
                    styles   = 'styles1-ab12cd.192.168.1.150.sslip.io'
                    core     = 'core1-ab12cd.192.168.1.150.sslip.io'
                    deferred = 'deferred1-ab12cd.192.168.1.150.sslip.io'
                    font     = 'font1-ab12cd.192.168.1.150.sslip.io'
                    image    = 'image1-ab12cd.192.168.1.150.sslip.io'
                    fetchsvc = 'api1-ab12cd.192.168.1.150.sslip.io'
                }
                $plan = [ordered]@{
                    schemaVersion    = 1
                    runId            = '12345'
                    anchors          = [ordered]@{
                        a1 = [ordered]@{ host = 'anchor1-ab12cd.192.168.1.150.sslip.io'; roles = $roles }
                        a2 = [ordered]@{ host = 'anchor2-ab12cd.192.168.1.150.sslip.io'; roles = [ordered]@{} }
                    }
                    controlDependencies = @($roles.Values)
                    neverLearnable   = 'blocked9-ab12cd.192.168.1.150.sslip.io'
                    unlisted         = 'unlisted8-ab12cd.192.168.1.150.sslip.io'
                    whitelistHosts   = @('anchor1-ab12cd.192.168.1.150.sslip.io', 'anchor2-ab12cd.192.168.1.150.sslip.io')
                    blockedSubdomains = @('blocked9-ab12cd.192.168.1.150.sslip.io')
                }
                return ($plan | ConvertTo-Json -Depth 8 -Compress)
            }
            function New-FirstVisitReportJson {
                param([int]$Loads = 1, [int]$ApiMark = 7000)
                return @"
{"schemaVersion":1,"runId":"12345","anchor":"a1","anchorHost":"anchor1-ab12cd.192.168.1.150.sslip.io","navigationType":"navigate","loads":$Loads,"waves":{"cssApplied":true,"fontLoaded":true,"imageLoaded":true,"coreExecuted":true,"deferredExecuted":true,"apiPainted":true,"blockedCssFailed":true},"blockedPathEnforced":true,"blockedPathFinal":true,"marks":{"start":1,"core":3000,"deferred":5000,"api":$ApiMark,"load":$ApiMark},"timings":{}}
"@
            }
            function New-FirstVisitTestState {
                param([string]$PlanJson, [string]$ReportJson = '', [int]$ApiMark = 7000)
                $state = [pscustomobject]@{
                    Calls            = [System.Collections.Generic.List[string]]::new()
                    PlanJson         = $PlanJson
                    ReportJson       = $ReportJson
                    ApiMark          = $ApiMark
                    LocalByLeaf      = @{}
                    GuestByLeaf      = @{}
                    GuestFiles       = @{}
                    EmptyBlockSteps  = @()
                    ResponseOverrides = @{}
                    Dumps            = 0
                }
                return $state
            }
            function New-FirstVisitTestTransport {
                param([Parameter(Mandatory = $true)][object]$State)
                $script:FirstVisitTestState = $State
                return @{
                    EnsureLock = { param($LockFile, $Owner, $TtlSeconds, $WaitSeconds = 900) $script:FirstVisitTestState.Calls.Add('EnsureLock'); $true }
                    UpdateLockHeartbeat = { param($LockFile, $Owner) $script:FirstVisitTestState.Calls.Add('UpdateLockHeartbeat'); $true }
                    ReleaseLock = { param($LockFile, $Owner) $script:FirstVisitTestState.Calls.Add('ReleaseLock'); $true }
                    InvokeHostCommand = {
                        param($ArgumentList, $InputText)
                        $first = [string](@($ArgumentList)[0])
                        $script:FirstVisitTestState.Calls.Add("InvokeHostCommand:$first")
                        if ($first -eq 'python3') {
                            # The DNS fixture probe must answer like the lab resolver.
                            return 'DNS-OK'
                        }
                        if ($first -eq 'curl') {
                            if ($script:FirstVisitTestState.ReportJson) {
                                return ('{"runId":"12345","requests":9,"browserRequests":8,"lastReport":' + $script:FirstVisitTestState.ReportJson + '}')
                            }
                            return ($script:FirstVisitTestState.PlanJson)
                        }
                        if ($first -eq 'bash') {
                            $joined = (@($ArgumentList) -join ' ')
                            if ($joined -match 'sha256sum') { return 'fake-template-xpi-sha' }
                            return 'ok'
                        }
                        return 'ok'
                    }
                    CopyFileToHost = { param($LocalPath, $RemotePath) $script:FirstVisitTestState.Calls.Add('CopyFileToHost:' + (Split-Path -Leaf $LocalPath)); $true }
                    GetVmStatus = { param($Vmid) 'stopped' }
                    StopVm = { param($Vmid) $script:FirstVisitTestState.Calls.Add('StopVm') }
                    StartVm = { param($Vmid) $script:FirstVisitTestState.Calls.Add('StartVm') }
                    RollbackVm = { param($Vmid, $Snapshot) $script:FirstVisitTestState.Calls.Add('RollbackVm') }
                    WaitGuestReady = { param($Vmid, $TimeoutSeconds) $true }
                    GetGuestOsInfo = { param($Vmid) [pscustomobject]@{ productType = 'client'; editionId = 'Education'; productName = 'Windows 11 Education'; build = '26100'; architecture = 'x64' } }
                    GetGuestBootId = { param($Vmid) 'boot-1' }
                    RequestGuestReboot = { param($Vmid) $script:FirstVisitTestState.Calls.Add('RequestGuestReboot') }
                    WaitGuestRebooted = { param($Vmid, $PreviousBootId, $TimeoutSeconds) $script:FirstVisitTestState.Calls.Add('WaitGuestRebooted'); 'boot-2' }
                    PublishArtifact = {
                        param($StagingDir, $LocalPath)
                        $leaf = Split-Path -Leaf $LocalPath
                        $script:FirstVisitTestState.LocalByLeaf[$leaf] = $LocalPath
                        [pscustomobject]@{ url = 'http://192.0.2.10:18080/' + $leaf }
                    }
                    RemoveHostStaging = { param($StagingDir) }
                    DownloadGuestArtifact = {
                        param($Vmid, $Url, $GuestPath)
                        $leaf = [IO.Path]::GetFileName($Url)
                        $script:FirstVisitTestState.GuestByLeaf[$leaf] = $GuestPath
                    }
                    GetGuestFileSha256 = {
                        param($Vmid, $GuestPath)
                        foreach ($leaf in $script:FirstVisitTestState.GuestByLeaf.Keys) {
                            if ($script:FirstVisitTestState.GuestByLeaf[$leaf] -eq $GuestPath -and $script:FirstVisitTestState.LocalByLeaf.ContainsKey($leaf)) {
                                return (Get-FileHash -LiteralPath $script:FirstVisitTestState.LocalByLeaf[$leaf] -Algorithm SHA256).Hash.ToLowerInvariant()
                            }
                        }
                        return ''
                    }
                    RemoveGuestStaging = { param($Vmid, $GuestPath) $true }
                    CaptureScreendump = { param($Vmid, $LocalPath) $script:FirstVisitTestState.Dumps += 1; $true }
                    InvokeGuestPowerShell = {
                        param($Vmid, $Script, $TimeoutSeconds)
                        $fileMatch = [regex]::Match([string]$Script, "ReadAllText\('([^']+)'\)")
                        if ($fileMatch.Success) {
                            $path = $fileMatch.Groups[1].Value
                            $script:FirstVisitTestState.Calls.Add("ReadGuestFile:$path")
                            if ($script:FirstVisitTestState.GuestFiles.ContainsKey($path)) { return [string]$script:FirstVisitTestState.GuestFiles[$path] }
                            return 'MISSING'
                        }
                        $phaseMatch = [regex]::Match([string]$Script, "-Phase '([^']+)'")
                        $stepMatch = [regex]::Match([string]$Script, "-Step '([^']+)'")
                        if (-not $stepMatch.Success) { return 'ok' }
                        $phase = $phaseMatch.Groups[1].Value
                        $step = $stepMatch.Groups[1].Value
                        $script:FirstVisitTestState.Calls.Add("InvokeGuestPowerShell:$phase/$step")
                        $responses = @{
                            'prepare/install'   = '{"status":"passed","body":{"state":{"install":{"ready":true}},"session":""}}'
                            'prepare/configure' = '{"status":"passed","body":{"state":{"registered":true,"firefoxPolicy":{"installationMode":"force_installed","fileInstallUrl":"http://192.168.1.150/api/extensions/firefox/openpath.xpi","registryInstallUrl":"http://192.168.1.150/api/extensions/firefox/openpath.xpi"}},"session":""}}'
                            'prepare/stage-xpi' = '{"status":"passed","body":{"state":{"xpi":{"sha256":"fake-template-xpi-sha","version":"1.2.3","bytes":254161},"xpiUpload":"200"},"session":""}}'
                            'prepare/warmup'    = '{"status":"passed","body":{"state":{"fixtureBeforeLaunch":{"serverNow":1000.0,"xpiCount":1},"closeBeforeWarmup":{"forced":false}},"session":""}}'
                            'prepare/session'   = '{"status":"passed","body":{"state":{"session":"alumno","sessionLogonAt":"2026-10-01T19:59:00.0000000Z"},"session":"alumno"}}'
                            'prepare/wait-firefox' = '{"status":"passed","body":{"state":{"firefox":[{"pid":2,"created":"2026-10-01T19:59:20.0000000Z"}]},"session":""}}'
                            'prepare/verify-warmup' = '{"status":"passed","body":{"state":{"warmupVerification":{"status":"passed","reasons":[]},"preconditions":{"status":"passed","reasons":[]},"hostSignals":{"hostStarted":true,"hostPids":["42"],"firstInitLine":"Native host initialization completed pid=42","diagnosticLines":3,"backgroundStart":true,"diagnosticBatchFirst":true},"liveSignals":{"hostStarted":true,"hostPids":["42"],"backgroundStart":true,"diagnosticBatchFirst":true,"diagnosticLines":3},"xpiFetch":{"fetched":true,"afterArmSeconds":1.9,"baseCount":1,"count":2},"extension":{"found":true,"active":true,"userDisabled":false,"appDisabled":false,"version":"1.2.3"},"closeAfterWarmup":{"forced":true}},"session":""}}'
                            'prepare/host-signals' = '{"status":"passed","body":{"state":{"hostSignals":{"hostStarted":true,"hostPids":["42"],"firstInitLine":"Native host initialization completed pid=42","appControl":{"enableNonAdminAppControl":true,"nonAdminAppControlMode":"Enforced","appControlProfile":"ClassroomStandard"},"restrictedGroup":["alumno"],"manifestPath":"C:\\OpenPath\\native\\whitelist_native_host.json","wrapperPath":"C:\\OpenPath\\native\\OpenPath-NativeHost.cmd"}},"session":""}}'
                            'prepare/host-events' = '{"status":"passed","body":{"state":{"hostEvents":{"events8004":[],"events8007":[]}},"session":""}}'
                            'observe/session'   = '{"status":"passed","body":{"state":{"session":"alumno","sessionLogonAt":"2026-10-01T20:00:00.0000000Z"},"session":"alumno"}}'
                            'observe/visit'     = '{"status":"passed","body":{"state":{"arm":{"mode":"in-session"},"anchor":"a1"},"session":""}}'
                            'observe/wait-firefox' = '{"status":"passed","body":{"state":{"launchedAt":"2026-10-01T20:00:30.0000000Z","firefox":[{"pid":3,"created":"2026-10-01T20:00:30.0000000Z"}],"firefoxLog":[]},"session":""}}'
                            'observe/collect'   = '{"status":"passed","body":{"state":{"collect":{"diagnostics":{"lines":3,"hostStarted":true,"backgroundStart":true,"batchFirst":true,"reloadReasons":["reloaded"],"all":["stage=extension-diagnostic {\"kind\":\"reload-decision\",\"reason\":\"reloaded\"}","stage=extension-diagnostic {\"kind\":\"background-start\"}","stage=extension-diagnostic {\"kind\":\"hold-outcome\",\"outcome\":\"released-budget\"}"]},"startupProfiles":["stage=startup-profile processToScriptMs=6341 pingMs=2210 firstEnqueueMs=120"]}},"session":""}}'
                            'observe/host-probe' = '{"status":"passed","body":{"state":{"hostProbe":{"scriptFound":true,"error":"","result":{"hostExists":true,"compiledHostPresent":true,"manifestHealthy":true,"manifestTargetsCompiledHost":true,"pingResponded":true,"readsResponded":true,"portalProtocolResponded":true,"deniedPowershell":true,"responses":[{"action":"ping","success":true}]}}},"session":""}}'
                            'observe/security'  = '{"status":"passed","body":{"state":{"overlay":{"unexpected":[],"missing":[]}},"session":""}}'
                            'cleanup/cleanup'   = '{"status":"passed","body":{"state":{"clean":{"rootGone":true}},"session":""}}'
                        }
                        $key = "$phase/$step"
                        if (-not $responses.ContainsKey($key)) { throw "first-visit-fake-missing-$key" }
                        if ($script:FirstVisitTestState.ResponseOverrides.ContainsKey($key)) {
                            return ("<<<GUEST_RESULT>>>`n" + $script:FirstVisitTestState.ResponseOverrides[$key] + "`n<<<END_GUEST_RESULT>>>`n__HARNESS_EXIT__=0")
                        }
                        if ($script:FirstVisitTestState.EmptyBlockSteps -contains $key) {
                            # Phase 3A.2 red-b r1: markers present, body empty.
                            return "<<<GUEST_RESULT>>>`n`n<<<END_GUEST_RESULT>>>`n__HARNESS_EXIT__=1"
                        }
                        return ("<<<GUEST_RESULT>>>`n" + $responses[$key] + "`n<<<END_GUEST_RESULT>>>`n__HARNESS_EXIT__=0")
                    }
                }
            }
            function New-FirstVisitTestConfig {
                return [pscustomobject]@{
                    schemaVersion   = 1
                    mode            = 'acceptance'
                    sshHost         = 'lab-host'
                    sshCommand      = 'ssh'
                    scpCommand      = 'scp'
                    hostAddress     = '192.168.1.150'
                    lockFile        = '/run/openpath-desktop-survival.lock'
                    hostStagingRoot = '/var/tmp/openpath-first-visit'
                    timeoutSeconds  = 600
                    scenarios       = @{
                        'win11-education-existing-empty' = [pscustomobject]@{
                            vmid                  = 111
                            baselineSnapshot      = 'surf-snap'
                            expectedEditionId     = 'Education'
                            initialProfileExisted = $true
                        }
                    }
                }
            }
            function New-FirstVisitTestPayload {
                param(
                    [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
                    [Parameter(Mandatory = $true)][string]$TemplatePath,
                    [Parameter(Mandatory = $true)][string]$PersonalizedExePath,
                    [string]$Phase = 'prepare',
                    [string]$Scenario = 'first-visit-settled'
                )
                return [pscustomobject]@{
                    schemaVersion    = 2
                    suiteKind        = 'FirstVisit'
                    runId            = '12345'
                    runAttempt       = 1
                    scenarioId       = "$Scenario-r1"
                    phase            = $Phase
                    sourceCommitSha  = 'abc123'
                    correlationNonce = '0123456789abcdef0123456789abcdef'
                    outputPath       = Join-Path $ArtifactsRoot 'observation.json'
                    artifactsRoot    = $ArtifactsRoot
                    templatePath     = $TemplatePath
                    templateSha256   = (Get-FileHash -LiteralPath $TemplatePath -Algorithm SHA256).Hash.ToLowerInvariant()
                    personalizedExePath = $PersonalizedExePath
                    personalizedExeSha256 = (Get-FileHash -LiteralPath $PersonalizedExePath -Algorithm SHA256).Hash.ToLowerInvariant()
                    firstVisit       = [pscustomobject]@{ scenario = $Scenario; repetition = 1; labScenario = 'win11-education-existing-empty'; templateXpiSha256 = 'fake-template-xpi-sha' }
                }
            }
        }

        BeforeEach {
            # The capture offsets live in the module scope; inject a single
            # immediate capture so the dispatch tests never sleep for screendumps.
            & (Get-Module ProxmoxWindowsLab) {
                $script:OpenPathFirstVisitCaptureOffsets = @(0)
                $script:OpenPathFirstVisitRefreshSettleSeconds = 0
                $script:OpenPathFirstVisitObserveSettleSeconds = 0
                $script:OpenPathFirstVisitHotWindowSeconds = 0
                $script:OpenPathFirstVisitHotSecondSettleSeconds = 0
                $script:OpenPathFirstVisitReportGraceSeconds = 0
                $script:OpenPathFirstVisitReportWaitSeconds = 0
                # Phase 6: the post-security settle and the inter-attempt retry
                # are knobs; the dispatch tests zero them (each was spending
                # 20 s + 15 s per observe test and the Windows shard hit its
                # per-file timeout).
                $script:OpenPathFirstVisitSecuritySettleSeconds = 0
                $script:OpenPathFirstVisitStepRetryDelaySeconds = 0
            }
            $script:FirstVisitArtifacts = Join-Path $TestDrive ('first-visit-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:FirstVisitArtifacts -Force | Out-Null
            $script:FirstVisitTemplate = Join-Path $script:FirstVisitArtifacts 'template.exe'
            $script:FirstVisitPersonalized = Join-Path $script:FirstVisitArtifacts 'personalized.exe'
            Set-Content -LiteralPath $script:FirstVisitTemplate -Value 'template-bytes' -Encoding ASCII
            Set-Content -LiteralPath $script:FirstVisitPersonalized -Value 'personalized-bytes' -Encoding ASCII
        }

        It 'Dispatches a FirstVisit prepare phase: fixture, staged harness, install, configure and warmup' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            $result.phase | Should -Be 'prepare'
            $result.scenarioId | Should -Be 'first-visit-settled-r1'
            @($state.Calls) | Should -Contain 'CopyFileToHost:fixture_server.py'
            @($state.Calls) | Should -Contain 'CopyFileToHost:dns_fixture.py'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:prepare/install'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:prepare/configure'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:prepare/stage-xpi'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:prepare/warmup'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:prepare/verify-warmup'
            $result.observation.state.verification.status | Should -Be 'passed'
            $result.observation.state.xpi.sha256 | Should -Be 'fake-template-xpi-sha'
            $result.observation.state.xpiServedSha256 | Should -Be 'fake-template-xpi-sha'
            $result.observation.state.plan.anchors.a1.host | Should -Be 'anchor1-ab12cd.192.168.1.150.sslip.io'
        }

        It 'Recovers the prepare result from the guest file when stdout loses the block' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $state.EmptyBlockSteps = @('prepare/verify-warmup')
            $state.GuestFiles['C:\Windows\Temp\openpath-desktop-survival\12345-1-first-visit-settled-r1\result-prepare-verify-warmup.json'] =
                '{"status":"passed","step":"verify-warmup","failures":[],"body":{"state":{"preconditions":{"status":"passed","reasons":[]},"hostSignals":{"hostStarted":false},"warmupVerification":{"status":"passed","reasons":[]}},"session":""}}'
            $transport = New-FirstVisitTestTransport -State $state
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            @($state.Calls | Where-Object { $_ -like 'ReadGuestFile:*result-prepare-verify-warmup.json' }).Count | Should -BeGreaterThan 0
            (Get-Content -LiteralPath (Join-Path $script:FirstVisitArtifacts 'guest-prepare-verify-warmup.result-source.txt') -Raw) | Should -Match 'result-file'
        }

        It 'Stops the prepare as INFRA when a lane precondition fails' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $state.ResponseOverrides['prepare/verify-warmup'] = '{"status":"passed","body":{"state":{"preconditions":{"status":"failed","reasons":["xpi-not-fetched"]},"hostSignals":{"hostStarted":false},"warmupVerification":{"status":"failed","reasons":["xpi-not-fetched"]}},"session":""}}'
            $transport = New-FirstVisitTestTransport -State $state
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            { Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport } |
                Should -Throw '*first-visit-precondition-failed-xpi-not-fetched*'
        }

        It 'Dispatches a settled observe phase and writes a passing metrics verdict' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            $result.observation.state.verdict.status | Should -Be 'passed'
            $result.observation.state.verdict.reloads | Should -Be 0
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:observe/visit'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:observe/collect'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:observe/security'
            $state.Dumps | Should -BeGreaterThan 0
            $metricsPath = Join-Path $script:FirstVisitArtifacts 'metrics.json'
            (Test-Path -LiteralPath $metricsPath) | Should -BeTrue
            (Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json).verdict | Should -Be 'passed'
        }

        It 'Dispatches a class-boot observe phase: reboot, session, visit within the window' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Scenario 'first-visit-class-boot'
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson -Loads 2
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe' -Scenario 'first-visit-class-boot'
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            $result.observation.state.verdict.status | Should -Be 'passed'
            $result.observation.state.visitDelaySeconds | Should -Be 30
            @($state.Calls) | Should -Contain 'RequestGuestReboot'
            @($state.Calls) | Should -Contain 'WaitGuestRebooted'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:observe/session'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:observe/visit'
        }

        It 'Restores collect values that traveled as part files' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson
            # The collect result references one oversized key as a part file.
            $state.ResponseOverrides['observe/collect'] = '{"status":"passed","body":{"state":{"collect":{"diagnostics":{"lines":1,"all":{"firstVisitPart":"body_state_collect_diagnostics_all.json","count":1}},"startupProfiles":[]}},"resultParts":{"body.state.collect.diagnostics.all":"body_state_collect_diagnostics_all.json"},"session":""}}'
            $partPath = 'C:\Windows\Temp\openpath-desktop-survival\12345-1-first-visit-settled-r1\result-observe-collect.json.parts\body_state_collect_diagnostics_all.json'
            $state.GuestFiles[$partPath] = '["stage=extension-diagnostic {\"kind\":\"reload-decision\",\"reason\":\"reloaded\"}"]'
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            @($state.Calls | Where-Object { $_ -like "ReadGuestFile:*$partPath" }).Count | Should -BeGreaterThan 0
            # The part was merged back before the metrics consumed it.
            $result.observation.state.metrics.diagnosticLines | Should -Be 1
            $result.observation.state.metrics.reloadReasons | Should -Contain 'reloaded'
            (Test-Path -LiteralPath (Join-Path $script:FirstVisitArtifacts 'guest-observe-collect.part-body_state_collect_diagnostics_all.json')) | Should -BeTrue
        }

        It 'Computes metrics when the serializer dropped the collect subtree' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson
            # The serializer dropped the collect subtree (naming it) but the step
            # itself passed: the scene must still produce metrics, not throw.
            $state.ResponseOverrides['observe/collect'] = '{"status":"passed","body":{"state":{"session":""},"bodySerializationFailures":["body.state.collect"]}}'
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            $result.observation.state.metrics.diagnosticLines | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $script:FirstVisitArtifacts 'metrics.json')) | Should -BeTrue
        }

        It 'Keeps the verdict when the collect step fails and marks the evidence incomplete' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson
            $state.ResponseOverrides['observe/collect'] = '{"status":"failed","failures":["collect-timeout"],"body":{"state":{}}}'
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            # The verdict was written before the collect and survives it.
            $result.observation.state.verdict.status | Should -Be 'passed'
            $result.observation.state.evidenceIncomplete | Should -BeTrue
            $result.observation.state.metrics.evidenceIncomplete | Should -BeTrue
            $result.observation.state.metrics.collectError | Should -Match 'collect-timeout'
            $verdictPath = Join-Path $script:FirstVisitArtifacts 'observe-verdict.json'
            (Test-Path -LiteralPath $verdictPath) | Should -BeTrue
            $verdictFile = Get-Content -LiteralPath $verdictPath -Raw | ConvertFrom-Json
            $verdictFile.reportPresent | Should -BeTrue
            $verdictFile.evidenceIncomplete | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $script:FirstVisitArtifacts 'metrics.json')) | Should -BeTrue
        }

        It 'Persists a self-report-missing verdict instead of aborting the scene' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            # No ReportJson: the fixture never saw the page report.
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            $result.observation.state.verdict.status | Should -Be 'failed'
            $verdictFile = Get-Content -LiteralPath (Join-Path $script:FirstVisitArtifacts 'observe-verdict.json') -Raw | ConvertFrom-Json
            $verdictFile.reportPresent | Should -BeFalse
        }

        It 'Carries the prepare AppControl product reason into the verdict file' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $state.ResponseOverrides['prepare/host-signals'] = '{"status":"passed","body":{"state":{"hostSignals":{"hostStarted":false,"hostPids":[],"firstInitLine":"","diagnosticLines":0,"backgroundStart":false,"diagnosticBatchFirst":false}},"session":""}}'
            $state.ResponseOverrides['prepare/host-events'] = '{"status":"passed","body":{"state":{"hostEvents":{"events8004":["Event[0]: denied C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe for alumno"],"events8007":[]}},"session":""}}'
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $verdictFile = Get-Content -LiteralPath (Join-Path $script:FirstVisitArtifacts 'observe-verdict.json') -Raw | ConvertFrom-Json
            @($verdictFile.productReasons) | Should -Contain 'native-host-blocked-by-appcontrol'
            $verdictFile.blockedByAppControl | Should -BeTrue
        }

        It 'Carries the student host probe evidence into the metrics (Phase 5.2 E2)' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport
            $result.status | Should -Be 'passed'
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:observe/host-probe'
            $probe = $result.observation.state.metrics.studentHostProbe
            $probe.compiledHostPresent | Should -BeTrue
            $probe.pingResponded | Should -BeTrue
            $probe.manifestTargetsCompiledHost | Should -BeTrue
            $probe.deniedPowershell | Should -BeTrue
        }

        It 'Writes a per-step trace with timings for every guest step' {
            $state = New-FirstVisitTestState -PlanJson (New-FirstVisitFakePlan)
            $transport = New-FirstVisitTestTransport -State $state
            $preparePayload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized
            Invoke-OpenPathProxmoxControllerPhase -Payload $preparePayload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            $state.ReportJson = New-FirstVisitReportJson
            $payload = New-FirstVisitTestPayload -ArtifactsRoot $script:FirstVisitArtifacts -TemplatePath $script:FirstVisitTemplate -PersonalizedExePath $script:FirstVisitPersonalized -Phase 'observe'
            Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-FirstVisitTestConfig) -Transport $transport | Out-Null
            foreach ($phase in @('prepare', 'observe')) {
                $stepName = if ($phase -eq 'prepare') { 'verify-warmup' } else { 'collect' }
                $tracePath = Join-Path $script:FirstVisitArtifacts "$phase-step-trace.json"
                (Test-Path -LiteralPath $tracePath) | Should -BeTrue -Because $phase
                $trace = @(Get-Content -LiteralPath $tracePath -Raw | ConvertFrom-Json)
                $entries = @($trace | Where-Object { $_.phase -eq $phase -and $_.step -eq $stepName })
                $entries.Count | Should -BeGreaterThan 0 -Because $phase
                $entry = $entries[-1]
                $entry.elapsedMs | Should -BeGreaterThan -1
                $entry.status | Should -Be 'passed'
                $entry.startedAt | Should -Not -BeNullOrEmpty
                # The running entry is updated in place, never duplicated.
                $entries.Count | Should -Be 1
            }
        }
    }

    Context 'Metrics extraction' {
        It 'Accepts an empty diagnostics and startup-profile set (host-blocked visit)' {
            # A blocked native host emits no E1 lines; the metrics call must not
            # fail binding an empty array (Phase 3A.3 observe failure).
            $plan = [pscustomobject]@{
                anchors = [pscustomobject]@{ a1 = [pscustomobject]@{ host = 'anchor1-x'; roles = [pscustomobject]@{} } }
                controlDependencies = @('styles1-x')
                neverLearnable = 'blocked9-x'
            }
            $report = [pscustomobject]@{ anchor = 'a1'; loads = 1; waves = [pscustomobject]@{ cssApplied = $false }; marks = [pscustomobject]@{} }
            $verdict = [pscustomobject]@{ status = 'failed'; reasons = @('wave1-incomplete-or-over-threshold'); waves = $null; timesMs = $null; reloads = 0 }
            $metrics = Get-OpenPathFirstVisitMetrics -Plan $plan -Scenario 'first-visit-settled' -Report $report `
                -DiagnosticLines @() -StartupProfiles @() -FixtureState $null -Verdict $verdict
            $metrics.verdict | Should -Be 'failed'
            $metrics.diagnosticLines | Should -Be 0
        }

        It 'Extracts reload reasons and host startup numbers from the E1 lines' {
            $plan = [pscustomobject]@{
                anchors = [pscustomobject]@{ a1 = [pscustomobject]@{ host = 'anchor1-x'; roles = [pscustomobject]@{} } }
                controlDependencies = @('styles1-x')
                neverLearnable = 'blocked9-x'
            }
            $report = [pscustomobject]@{ anchor = 'a1'; loads = 2; waves = [pscustomobject]@{}; marks = [pscustomobject]@{} }
            $verdict = [pscustomobject]@{ status = 'passed'; reasons = @(); waves = $null; timesMs = $null; reloads = 1 }
            $metrics = Get-OpenPathFirstVisitMetrics -Plan $plan -Scenario 'first-visit-class-boot' -Report $report `
                -DiagnosticLines @(
                    'stage=extension-diagnostic {"kind":"reload-decision","reason":"reloaded"}',
                    'stage=extension-diagnostic {"kind":"reload-decision","reason":"navigation-mismatch"}',
                    'stage=extension-diagnostic {"kind":"hold-outcome","outcome":"released-budget"}'
                ) `
                -StartupProfiles @('stage=startup-profile processToScriptMs=6341 pingMs=9210 firstEnqueueMs=448') `
                -FixtureState $null -Verdict $verdict
            $metrics.reloadReasons | Should -Contain 'reloaded'
            $metrics.reloadReasons | Should -Contain 'navigation-mismatch'
            $metrics.holdOutcomes | Should -Be 1
            $metrics.diagnosticLines | Should -Be 3
            $metrics.hostProfile[0].pingMs | Should -Be 9210
            $metrics.hostProfile[0].processToScriptMs | Should -Be 6341
        }
    }

    Context 'Warm-up preconditions and product host signals (Phase 3A.3 L2)' {
        BeforeAll {
            $script:FirstVisitHarnessPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\Invoke-OpenPathFirstVisitGuest.ps1'
            $script:FirstVisitModulesRoot = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit'
            Import-Module (Join-Path $script:FirstVisitModulesRoot 'FirstVisitWarmup.psm1') -Force
            Import-Module (Join-Path $script:FirstVisitModulesRoot 'FirstVisitResult.psm1') -Force
            Import-Module (Join-Path $script:FirstVisitModulesRoot 'FirstVisitTemplateSource.psm1') -Force
            # The lane tests never touch a real install (Phase 3A.3): the
            # modules under test are pure and this root stays a temporary.
            $script:FirstVisitTempRoot = Join-Path ([IO.Path]::GetTempPath()) ('openpath-first-visit-tests-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:FirstVisitTempRoot -Force | Out-Null
            $env:OPENPATH_WINDOWS_ROOT = $script:FirstVisitTempRoot
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:FirstVisitHarnessPath, [ref]$tokens, [ref]$parseErrors)
            foreach ($name in @('Get-WarmupLiveSignals', 'Get-ExtensionEntryFromJson')) {
                $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
                if (-not $definition) { throw "first-visit-harness-function-missing: $name" }
                . ([scriptblock]::Create($definition.Extent.Text))
            }
        }
        AfterAll {
            Remove-Item Env:\OPENPATH_WINDOWS_ROOT -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:FirstVisitTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Reads the live host start, background-start and diagnostic batch from native-host.log lines' {
            $lines = @(
                'stage=extension-diagnostic {"kind":"background-start"}',
                'Native host initialization completed pid=4242 log=C:\Users\alumno\AppData\Local\OpenPath\native-host.log',
                'stage=extension-diagnostic-batch first=true received=50 written=50 dropped=0 pid=4242'
            )
            $live = Get-WarmupLiveSignals -Lines $lines
            $live.hostStarted | Should -BeTrue
            $live.hostPids | Should -Contain '4242'
            $live.backgroundStart | Should -BeTrue
            $live.diagnosticBatchFirst | Should -BeTrue
        }

        It 'Treats a stale extensions.json without the add-on as not-registered and finds an active entry after close' {
            $stale = Get-ExtensionEntryFromJson -JsonText '{"schemaVersion":35,"addons":[{"id":"default-theme@mozilla.org","active":true}]}'
            $stale.parsed | Should -BeTrue
            $stale.found | Should -BeFalse
            $active = Get-ExtensionEntryFromJson -JsonText '{"addons":[{"id":"openpath-block-monitor@openpath","version":"2.0.1","active":true,"userDisabled":false,"appDisabled":false,"location":4,"signedState":2}]}'
            $active.found | Should -BeTrue
            $active.active | Should -BeTrue
            $active.version | Should -Be '2.0.1'
            (Get-ExtensionEntryFromJson -JsonText 'not json').parsed | Should -BeFalse
        }

        It 'Fails the lane preconditions with explicit reasons (INFRA), never the host start' {
            $stale = Get-ExtensionEntryFromJson -JsonText '{"schemaVersion":35,"addons":[{"id":"default-theme@mozilla.org","active":true}]}'
            $pre = Get-FirstVisitPreconditionVerdict -XpiFetched $false -ExtensionState $stale
            $pre.status | Should -Be 'failed'
            $pre.reasons | Should -Contain 'xpi-not-fetched'

            $pre = Get-FirstVisitPreconditionVerdict -XpiFetched $true -ExtensionState $stale
            $pre.reasons | Should -Contain 'xpi-fetched-not-registered'

            $inactive = Get-ExtensionEntryFromJson -JsonText '{"addons":[{"id":"openpath-block-monitor@openpath","version":"2.0.1","active":false,"userDisabled":true,"appDisabled":false}]}'
            $pre = Get-FirstVisitPreconditionVerdict -XpiFetched $true -ExtensionState $inactive
            $pre.reasons | Should -Contain 'extension-registered-inactive'

            $mismatch = Get-ExtensionEntryFromJson -JsonText '{"addons":[{"id":"openpath-block-monitor@openpath","version":"1.0.0","active":true,"userDisabled":false,"appDisabled":false}]}'
            $pre = Get-FirstVisitPreconditionVerdict -XpiFetched $true -ExtensionState $mismatch -ExpectedVersion '2.0.1'
            ($pre.reasons -join ',') | Should -Match 'extension-version-mismatch:1\.0\.0-expected-2\.0\.1'

            $good = Get-ExtensionEntryFromJson -JsonText '{"addons":[{"id":"openpath-block-monitor@openpath","version":"2.0.1","active":true,"userDisabled":false,"appDisabled":false}]}'
            (Get-FirstVisitPreconditionVerdict -XpiFetched $true -ExtensionState $good -ExpectedVersion '2.0.1').status | Should -Be 'passed'
        }

        It 'Reports the native host start as a product reason without aborting the visit' {
            $live = Get-WarmupLiveSignals -Lines @()
            $hostVerdict = Get-FirstVisitHostSignalsVerdict -Live $live -Events $null -Capabilities 'native-host-log,background-start,diagnostic-batch'
            $hostVerdict.status | Should -Be 'failed'
            $hostVerdict.productReasons | Should -Contain 'native-host-not-started'
            $hostVerdict.blockedByAppControl | Should -BeFalse
            $hostVerdict.signals.hostStarted | Should -BeFalse
            $hostVerdict.signals.backgroundStartCapable | Should -BeTrue
        }

        It 'Names the AppLocker deny when the student launcher interpreter was blocked' {
            $events = [ordered]@{
                events8004 = @(
                    'Event[0]:',
                    '  Date: 2026-10-03T07:30:00.1234567Z',
                    '  Description:',
                    '  %WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe was prevented from running by policy. Target user: alumno',
                    'Event[1]:',
                    '  Date: 2026-10-03T07:30:01.1234567Z',
                    '  Description:',
                    '  %WINDIR%\System32\notepad.exe was prevented from running by policy. Target user: alumno'
                )
            }
            $hostVerdict = Get-FirstVisitHostSignalsVerdict -Live (Get-WarmupLiveSignals -Lines @()) -Events $events -Capabilities 'native-host-log' -StudentUserName 'alumno' -WindowStart '2026-10-03T07:20:00Z'
            $hostVerdict.status | Should -Be 'failed'
            $hostVerdict.productReasons | Should -Contain 'native-host-blocked-by-appcontrol'
            $hostVerdict.productReasons | Should -Not -Contain 'native-host-not-started'
            $hostVerdict.blockedByAppControl | Should -BeTrue
            $hostVerdict.appControlEvidence[0].student | Should -BeTrue
        }

        It 'Ignores unrelated and pre-window 8004 events' {
            $events = [ordered]@{
                events8004 = @(
                    '  Date: 2026-10-02T06:00:00Z',
                    '  powershell.exe was prevented from running by policy (yesterday)',
                    '  Date: 2026-10-03T07:30:00Z',
                    '  cmd.exe was prevented from running by policy'
                )
            }
            $hostVerdict = Get-FirstVisitHostSignalsVerdict -Live (Get-WarmupLiveSignals -Lines @()) -Events $events -Capabilities 'native-host-log' -WindowStart '2026-10-03T07:20:00Z'
            $hostVerdict.productReasons | Should -Contain 'native-host-not-started'
            $hostVerdict.blockedByAppControl | Should -BeFalse
        }

        It 'Does not claim a reason when the build cannot emit the host log' {
            $hostVerdict = Get-FirstVisitHostSignalsVerdict -Live (Get-WarmupLiveSignals -Lines @()) -Events $null -Capabilities ''
            @($hostVerdict.productReasons).Count | Should -Be 0
            $hostVerdict.status | Should -Be 'passed'
        }

        It 'Keeps the guest harness free of any browser-policy rewrite' {
            $text = Get-Content -LiteralPath $script:FirstVisitHarnessPath -Raw
            $text | Should -Not -Match 'Set-LabFirefoxPolicy'
            $text | Should -Not -Match 'Install-DistributedExtension'
            $text | Should -Not -Match 'reg\.exe.*ExtensionSettings'
            $text | Should -Not -Match 'distribution\\extensions'
            $text | Should -Not -Match 'file:///'
            $text | Should -Not -Match 'WriteAllText\(\$policyPath'
        }

        It 'Keeps the risky policy and event reads in separate bounded steps' {
            $text = Get-Content -LiteralPath $script:FirstVisitHarnessPath -Raw
            $text | Should -Not -Match 'Get-NativeHostDiagnostics'
            $text | Should -Not -Match 'Get-AppLockerPolicy'
            $text | Should -Match 'host-signals'
            $text | Should -Match 'host-events'
            $text | Should -Match "wevtutil\.exe"
            $text | Should -Match 'Save-PartialResult'
            $text | Should -Match 'FirstVisitResult\.psm1'
        }
    }

    Context 'Guest result contract (Phase 3A.3 L3)' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitResult.psm1') -Force
        }

        It 'Recovers the red-b r1 body (empty stdout block) from the guest result file' {
            # Body equivalent to Phase 3A.2 red-b r1, including hostDiagnostics:
            # the markers were present but the JSON between them was empty.
            $body = [ordered]@{
                status   = 'failed'
                step     = 'verify-warmup'
                phase    = 'prepare'
                scenario = 'first-visit-class-boot-r1'
                failures = @('host-not-started', 'background-start-missing')
                body     = [ordered]@{
                    state = [ordered]@{
                        liveSignals = [ordered]@{ hostStarted = $false; hostPids = @(); backgroundStart = $false; diagnosticBatchFirst = $false }
                        xpiFetch = [ordered]@{ fetched = $true; delaySeconds = -14.31 }
                        hostDiagnostics = [ordered]@{
                            nativeLog = [ordered]@{ path = 'C:\Users\alumno\AppData\Local\OpenPath\native-host.log'; exists = $false; bytes = 0; tail = @() }
                            manifestPath = 'C:\OpenPath\browser-extension\firefox\native\whitelist_native_host.json'
                            manifestExists = $true
                            manifest = '{"name":"whitelist_native_host","path":"C:\\OpenPath\\browser-extension\\firefox\\native\\OpenPath-NativeHost.cmd"}'
                            wrapperExists = $true
                            wrapperHead = @('@echo off', 'setlocal')
                        }
                    }
                    session = ''
                }
            }
            $fileJson = $body | ConvertTo-Json -Depth 12 -Compress
            $emptyStdout = "<<<GUEST_RESULT>>>`r`n`r`n<<<END_GUEST_RESULT>>>`r`n__HARNESS_EXIT__=1"
            $resolved = Resolve-FirstVisitGuestResult -Output $emptyStdout -FileText $fileJson
            $resolved.source | Should -Be 'result-file'
            $resolved.stdoutValid | Should -BeFalse
            $resolved.fileValid | Should -BeTrue
            $parsed = $resolved.json | ConvertFrom-Json
            $parsed.status | Should -Be 'failed'
            $parsed.body.state.hostDiagnostics.manifestExists | Should -BeTrue
        }

        It 'Prefers the stdout block when it parses and reports missing only when both channels fail' {
            $stdout = "<<<GUEST_RESULT>>>{`"status`":`"passed`",`"body`":{`"state`":{}}}<<<END_GUEST_RESULT>>>`n__HARNESS_EXIT__=0"
            $resolved = Resolve-FirstVisitGuestResult -Output $stdout -FileText 'not json'
            $resolved.source | Should -Be 'stdout'
            (Resolve-FirstVisitGuestResult -Output 'nothing' -FileText '').error | Should -Be 'first-visit-guest-result-missing'
        }

        It 'Serializes key-by-key and names the failing key instead of losing the result' {
            $probe = { param($value) return -not ($value -is [string] -and $value -eq 'UNSERIALIZABLE') }
            $payload = [ordered]@{
                status   = 'passed'
                step     = 'verify-warmup'
                failures = @()
                body     = [ordered]@{
                    state = [ordered]@{
                        good = 'kept'
                        bad  = 'UNSERIALIZABLE'
                        hostDiagnostics = [ordered]@{ manifestPath = 'C:\x\whitelist_native_host.json' }
                    }
                    session = 'alumno'
                }
            }
            $json = ConvertTo-FirstVisitResultJson -Payload $payload -SerializableProbe $probe
            $parsed = $json | ConvertFrom-Json
            $parsed.status | Should -Be 'passed'
            $parsed.body.state.good | Should -Be 'kept'
            $parsed.body.state.hostDiagnostics.manifestPath | Should -Be 'C:\x\whitelist_native_host.json'
            ($parsed.body.bodySerializationFailures -join ',') | Should -Match 'body\.state\.bad'
            # Phase 5 A2: the failing key also carries the serializer error text.
            $parsed.body.serializationDiagnostics.'body.state.bad' | Should -Be 'custom-probe-rejected'
        }

        It 'Splits oversized values into part files so a large collect still arrives' {
            $partsDir = Join-Path ([System.IO.Path]::GetTempPath()) ('first-visit-parts-' + [guid]::NewGuid().ToString('N'))
            try {
                $payload = [ordered]@{
                    status   = 'passed'
                    step     = 'collect'
                    failures = @()
                    body     = [ordered]@{
                        state = [ordered]@{
                            collect = [ordered]@{
                                diagnostics = [ordered]@{ lines = 10; all = @(1..10 | ForEach-Object { "line-$_ " + ('x' * 20) }) }
                                workerState = '{"heartbeatEpochMs":1}'
                            }
                        }
                        session = ''
                    }
                }
                # Tiny cap forces the split; the default probe stays real.
                $json = ConvertTo-FirstVisitResultJson -Payload $payload -MaxInlineBytes 32 -PartsDirectory $partsDir
                $parsed = $json | ConvertFrom-Json
                # The big dictionary is split by its own keys: only diagnostics.all
                # exceeds the cap, the other keys stay inline.
                $parsed.body.state.collect.PSObject.Properties['firstVisitPart'] | Should -BeNullOrEmpty
                $parsed.body.state.collect.diagnostics.lines | Should -Be 10
                $parsed.body.state.collect.workerState | Should -Be '{"heartbeatEpochMs":1}'
                $parsed.body.state.collect.diagnostics.all.firstVisitPart | Should -Be 'body.state.collect.diagnostics.all.json'
                $parsed.body.resultParts.PSObject.Properties['body.state.collect.diagnostics.all'].Value | Should -Be 'body.state.collect.diagnostics.all.json'
                (Test-Path -LiteralPath (Join-Path $partsDir 'body.state.collect.diagnostics.all.json')) | Should -BeTrue
                $partValue = Get-Content -LiteralPath (Join-Path $partsDir 'body.state.collect.diagnostics.all.json') -Raw | ConvertFrom-Json
                $partValue.Count | Should -Be 10
                # The inline result stays small: no unbounded value travels whole.
                $json.Length | Should -BeLessThan 2048
            }
            finally {
                Remove-Item -LiteralPath $partsDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Reports the serializer error text through the serialization diagnostics' {
            # Get-FirstVisitSerializationError returns '' for values that
            # serialize (the real engine error text is captured when a value
            # throws; pwsh and PS 5.1 differ on what throws).
            (Get-FirstVisitSerializationError -Value 'plain') | Should -Be ''
            (Get-FirstVisitSerializationError -Value @('a', 'b')) | Should -Be ''
            # The reducer path records the diagnostic with the custom probe; a
            # scalar value is named directly (dictionaries are split by keys).
            $probe = { param($value) return $false }
            $payload = [ordered]@{ status = 'failed'; step = 'collect'; failures = @(); body = [ordered]@{ state = [ordered]@{ collect = 'BAD' }; session = '' } }
            $parsed = (ConvertTo-FirstVisitResultJson -Payload $payload -SerializableProbe $probe) | ConvertFrom-Json
            $parsed.body.serializationDiagnostics.'body.state.collect' | Should -Be 'custom-probe-rejected'
            ($parsed.body.bodySerializationFailures -join ',') | Should -Match 'body\.state\.collect'
        }

        It 'Keeps null and empty collection values instead of listing them as failures' {
            # Phase 5.2: PowerShell collapses a returned $null or empty array to
            # no output; the reducer must not confuse that with a rejected value.
            $probe = { param($value) return -not ($value -is [string] -and $value -eq 'UNSERIALIZABLE') }
            $payload = [ordered]@{
                status   = 'passed'
                step     = 'collect'
                failures = @()
                body     = [ordered]@{
                    state = [ordered]@{
                        collect = [ordered]@{ diagnostics = [ordered]@{ all = @() }; mozExtract = @() }
                        session = $null
                    }
                    session = ''
                }
            }
            $parsed = (ConvertTo-FirstVisitResultJson -Payload $payload -SerializableProbe $probe) | ConvertFrom-Json
            $parsed.PSObject.Properties['failures'] | Should -Not -BeNullOrEmpty
            @($parsed.failures).Count | Should -Be 0
            $parsed.body.state.PSObject.Properties['session'] | Should -Not -BeNullOrEmpty
            $parsed.body.state.PSObject.Properties['collect'] | Should -Not -BeNullOrEmpty
            @($parsed.body.bodySerializationFailures).Count | Should -Be 0
        }

        It 'Bounds huge strings and arrays before serializing (Phase 5.2)' {
            $big = 'x' * 20000
            $many = @(1..5000 | ForEach-Object { "item-$_" })
            $limited = Limit-FirstVisitResultValue -Value ([ordered]@{ big = $big; many = $many; keep = 'ok' }) -MaxStringChars 100 -MaxItems 10
            $limited.big.Length | Should -BeLessOrEqual 113
            $limited.big | Should -Match 'truncated'
            @($limited.many).Count | Should -Be 10
            $limited.keep | Should -Be 'ok'
            # The serialized payload stays small (the PS 5.1 serializer wedged
            # for >500 s on the unbounded collect body in the acceptance runs).
            $json = ConvertTo-FirstVisitResultJson -Payload ([ordered]@{ status = 'passed'; step = 'collect'; failures = @(); body = [ordered]@{ state = [ordered]@{ big = $big; many = $many } } }) -MaxInlineBytes 0
            $json.Length | Should -BeLessThan 40000
        }

        It 'Drops the Get-Content ETS wrapper from strings (Phase 5.3 B1)' {
            # Get-Content -Raw returns a string wrapped with PSPath/PSDrive/
            # PSProvider note properties; the PS 5.1 serializer walked that
            # wrapper in the collect wedge. The limiter must return a plain
            # string and keep the size cap.
            $wrapped = 'payload'
            $wrapped | Add-Member -MemberType NoteProperty -Name 'PSPath' -Value 'Microsoft.PowerShell.Core\FileSystem::C:\x' -Force
            $wrapped | Add-Member -MemberType NoteProperty -Name 'PSDrive' -Value 'C' -Force
            $limited = Limit-FirstVisitResultValue -Value ([ordered]@{ state = $wrapped }) -MaxStringChars 4
            ($limited.state -is [string]) | Should -BeTrue
            $limited.state | Should -Be 'payl...truncated'
            $limited.state.PSObject.Properties['PSPath'] | Should -BeNull
            # A parsed JSON object (pscustomobject) is evidence, not poison:
            # it must survive as a property bag.
            $probe = '{"compiledHostPresent":false,"deniedPowershell":true}' | ConvertFrom-Json
            $limitedProbe = Limit-FirstVisitResultValue -Value ([ordered]@{ result = $probe })
            $limitedProbe.result.compiledHostPresent | Should -BeFalse
            $limitedProbe.result.deniedPowershell | Should -BeTrue
        }

        It 'Serializes a Get-Content -Raw payload as a plain string under PowerShell 5.1 (Phase 5.3 B1)' {
            $wrapped = Get-Content -LiteralPath $PSCommandPath -Raw
            # 1) Fixed path: the limiter + serializer stay bounded and the value
            #    arrives as a plain JSON string.
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $json = ConvertTo-FirstVisitResultJson -Payload ([ordered]@{
                    status = 'passed'; step = 'collect'; failures = @()
                    body   = [ordered]@{ state = [ordered]@{ collect = [ordered]@{ workerState = $wrapped } } }
                }) -MaxInlineBytes 0
            $watch.Stop()
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 2
            $json | Should -Not -Match 'PSPath|PSDrive|PSProvider'
            $parsed = $json | ConvertFrom-Json
            ($parsed.body.state.collect.workerState -is [string]) | Should -BeTrue
            # 2) Measurement under Windows PowerShell 5.1 (the shell the guest
            #    harness runs): Get-Content -Raw vs [IO.File]::ReadAllText.
            #    A pathological result is reported, never allowed to hang the
            #    suite: the child is killed after 45 s.
            $windowsPowerShell = ''
            if ($env:WINDIR) {
                $candidate = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (Test-Path -LiteralPath $candidate) { $windowsPowerShell = $candidate }
            }
            if (-not $windowsPowerShell) {
                Write-Host 'B1 measurement skipped: Windows PowerShell 5.1 not available in this environment.'
                return
            }
            $driver = @"
`$file = Join-Path `$env:TEMP ('phase53-b1-' + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText(`$file, (('line ' * 200) + "``n") * 200)
`$wrapped = Get-Content -LiteralPath `$file -Raw
`$w1 = [System.Diagnostics.Stopwatch]::StartNew()
try { `$json1 = [ordered]@{ s = `$wrapped } | ConvertTo-Json -Depth 12 -Compress } catch { `$json1 = '' }
`$w1.Stop()
`$plain = [IO.File]::ReadAllText(`$file)
`$w2 = [System.Diagnostics.Stopwatch]::StartNew()
try { `$json2 = [ordered]@{ s = `$plain } | ConvertTo-Json -Depth 12 -Compress } catch { `$json2 = '' }
`$w2.Stop()
`$shape = if (`$json1 -match 'PSPath|PSDrive|PSProvider') { 'ets-object' } else { 'plain-string' }
[ordered]@{ getContentMs = [int]`$w1.ElapsedMilliseconds; readAllTextMs = [int]`$w2.ElapsedMilliseconds; shape = `$shape; length = `$wrapped.Length } | ConvertTo-Json -Compress
"@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($driver))
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $windowsPowerShell
            $startInfo.Arguments = '-NoProfile -EncodedCommand ' + $encoded
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = [System.Diagnostics.Process]::Start($startInfo)
            $completed = $process.WaitForExit(45000)
            if (-not $completed) {
                try { $process.Kill($true) } catch { }
                Write-Host 'B1 measurement: the Get-Content stack did not complete within 45 s under PowerShell 5.1 (pathological case recorded).'
            }
            else {
                $measurement = $process.StandardOutput.ReadToEnd().Trim()
                Write-Host "B1 measurement (PowerShell 5.1): $measurement"
            }
            $process.Dispose()
        }

        It 'Splits an unserializable dictionary so healthy children still arrive' {
            $probe = {
                param($value)
                if ($value -is [System.Collections.IDictionary] -and @($value.Keys) -contains 'bad') { return $false }
                if ($value -is [string] -and $value -eq 'POISON') { return $false }
                return $true
            }
            $payload = [ordered]@{
                status   = 'passed'
                step     = 'collect'
                failures = @()
                body     = [ordered]@{
                    state = [ordered]@{
                        collect = [ordered]@{ good = 'kept'; bad = 'POISON' }
                    }
                    session = ''
                }
            }
            $json = ConvertTo-FirstVisitResultJson -Payload $payload -SerializableProbe $probe
            $parsed = $json | ConvertFrom-Json
            # The dictionary itself was rejected; its healthy child survived and
            # only the poison child was named.
            $parsed.body.state.collect.good | Should -Be 'kept'
            $parsed.body.state.collect.PSObject.Properties['bad'] | Should -BeNullOrEmpty
            ($parsed.body.bodySerializationFailures -join ',') | Should -Match 'body\.state\.collect\.bad'
            $parsed.body.serializationDiagnostics.'body.state.collect.bad' | Should -Be 'custom-probe-rejected'
        }
    }

    Context 'Template resolution (Phase 3A.3 L1)' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitTemplateSource.psm1') -Force
            # Phase 5.3 P5: the resolver contrasts the listing with main HEAD
            # (GET commits/main, then runs?head_sha=<sha>).
            $script:FirstVisitTemplateHead = '{"sha":"sha-head"}' | ConvertFrom-Json
            $script:FirstVisitTemplateHeadRuns = '{"workflow_runs":[{"id":999,"head_sha":"sha-head","head_branch":"main","event":"push","status":"completed","conclusion":"failure"}]}' | ConvertFrom-Json
        }

        It 'Uses the completing run id directly on a workflow_run trigger (no lookup)' {
            $plan = Get-FirstVisitTemplateSourcePlan -EventName 'workflow_run' -WorkflowRunId '555' -WorkflowRunHeadSha 'sha-555'
            $plan.mode | Should -Be 'workflow-run'
            $script:FirstVisitTemplateApiCalls = 0
            $api = { param($url) $script:FirstVisitTemplateApiCalls += 1; throw 'no-lookup-expected' }
            $resolved = Resolve-FirstVisitTemplateRun -Plan $plan -Repository 'o/r' -ApiGet $api
            $resolved.runId | Should -Be '555'
            $resolved.templateSha | Should -Be 'sha-555'
            $script:FirstVisitTemplateApiCalls | Should -Be 0
        }

        It 'Reads id (not database_id) and skips candidates without the template artifact' {
            # Phase 5.3 P3: completed listing + client-side conclusion filter.
            $script:FirstVisitTemplateListing = '{"workflow_runs":[
                {"id":111,"database_id":null,"head_sha":"sha-111","head_branch":"main","event":"push","conclusion":"failure"},
                {"id":112,"database_id":null,"head_sha":"sha-112","head_branch":"main","event":"push","conclusion":"success"},
                {"id":222,"database_id":null,"head_sha":"sha-222","head_branch":"main","event":"push","conclusion":"success"}
            ]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts112 = '{"artifacts":[{"name":"windows-personalized-exe"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts222 = '{"artifacts":[{"name":"windows-offline-template"}]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/release-scripts\.yml/runs\?per_page=50') { return $script:FirstVisitTemplateListing }
                if ($url -match '/runs/112/artifacts') { return $script:FirstVisitTemplateArtifacts112 }
                if ($url -match '/runs/222/artifacts') { return $script:FirstVisitTemplateArtifacts222 }
                throw "unexpected-url:$url"
            }
            $resolved = Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'schedule') -Repository 'o/r' -ApiGet $api
            $resolved.runId | Should -Be '222'
            $resolved.templateSha | Should -Be 'sha-222'
            $resolved.candidates | Should -Be 2
            # 112 is a newer success without the artifact: the resolved run is
            # one successful run behind the newest.
            $resolved.lag | Should -Be 1
            $resolved.newestSuccessRunId | Should -Be '112'
        }

        It 'Resolves a dispatch by run id and by target SHA' {
            $script:FirstVisitTemplateRun = '{"id":777,"head_sha":"sha-777"}' | ConvertFrom-Json
            $script:FirstVisitTemplateListing = '{"workflow_runs":[{"id":777,"head_sha":"sha-777","head_branch":"main","event":"push","conclusion":"success"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts = '{"artifacts":[{"name":"windows-offline-template"}]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/actions/runs/777$') { return $script:FirstVisitTemplateRun }
                if ($url -match 'head_sha=sha-777&per_page=50') { return $script:FirstVisitTemplateListing }
                if ($url -match '/runs/777/artifacts') { return $script:FirstVisitTemplateArtifacts }
                throw "unexpected-url:$url"
            }
            $byId = Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'workflow_dispatch' -InputRunId '777') -Repository 'o/r' -ApiGet $api
            $byId.runId | Should -Be '777'
            $byId.templateSha | Should -Be 'sha-777'
            $bySha = Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'workflow_dispatch' -InputSha 'sha-777') -Repository 'o/r' -ApiGet $api
            $bySha.runId | Should -Be '777'
            (Get-FirstVisitTemplateSourcePlan -EventName 'workflow_dispatch').mode | Should -Be 'latest'
        }

        It 'Marks a stale listing as stale when main HEAD has a newer successful REL (Phase 5.3 P5)' {
            # Recorded 2026-10-06 06:18 staleness: the unfiltered listing does
            # not contain the newest main REL; resolving the old one silently
            # would measure an outdated product.
            $script:FirstVisitTemplateListing = '{"workflow_runs":[{"id":90,"head_sha":"sha-old","head_branch":"main","event":"push","status":"completed","conclusion":"success"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateHead = '{"sha":"sha-new"}' | ConvertFrom-Json
            $script:FirstVisitTemplateHeadRuns = '{"workflow_runs":[{"id":100,"head_sha":"sha-new","head_branch":"main","event":"push","status":"completed","conclusion":"success"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts = '{"artifacts":[{"name":"windows-offline-template"}]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/commits/main$') { return $script:FirstVisitTemplateHead }
                if ($url -match 'head_sha=sha-new') { return $script:FirstVisitTemplateHeadRuns }
                if ($url -match '/release-scripts\.yml/runs\?per_page=50') { return $script:FirstVisitTemplateListing }
                if ($url -match '/runs/90/artifacts') { return $script:FirstVisitTemplateArtifacts }
                throw "unexpected-url:$url"
            }
            $resolved = Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'schedule') -Repository 'o/r' -ApiGet $api
            $resolved.runId | Should -Be '90'
            $resolved.stale | Should -BeTrue -Because 'the workflow turns this into INFRA, never a silent old template'
            $resolved.headSha | Should -Be 'sha-new'
            $resolved.headRelRunId | Should -Be '100'
            $resolved.headRelStatus | Should -Be 'completed'
        }

        It 'Uses the last successful main REL while the HEAD REL is still running (Phase 5.3 P5)' {
            $script:FirstVisitTemplateListing = '{"workflow_runs":[{"id":90,"head_sha":"sha-old","head_branch":"main","event":"push","status":"completed","conclusion":"success"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateHead = '{"sha":"sha-new"}' | ConvertFrom-Json
            $script:FirstVisitTemplateHeadRuns = '{"workflow_runs":[{"id":100,"head_sha":"sha-new","head_branch":"main","event":"push","status":"in_progress","conclusion":null}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts = '{"artifacts":[{"name":"windows-offline-template"}]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/commits/main$') { return $script:FirstVisitTemplateHead }
                if ($url -match 'head_sha=sha-new') { return $script:FirstVisitTemplateHeadRuns }
                if ($url -match '/release-scripts\.yml/runs\?per_page=50') { return $script:FirstVisitTemplateListing }
                if ($url -match '/runs/90/artifacts') { return $script:FirstVisitTemplateArtifacts }
                throw "unexpected-url:$url"
            }
            $resolved = Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'schedule') -Repository 'o/r' -ApiGet $api
            $resolved.runId | Should -Be '90'
            $resolved.stale | Should -BeFalse
            $resolved.headRelStatus | Should -Be 'in_progress'
            $resolved.headRelRunId | Should -Be '100'
        }

        It 'Ignores non-main, non-push and unsuccessful runs in the unfiltered listing (Phase 5.3 P5)' {
            $script:FirstVisitTemplateListing = '{"workflow_runs":[
                {"id":1,"head_sha":"s1","head_branch":"feature","event":"push","status":"completed","conclusion":"success"},
                {"id":2,"head_sha":"s2","head_branch":"main","event":"schedule","status":"completed","conclusion":"success"},
                {"id":3,"head_sha":"s3","head_branch":"main","event":"push","status":"completed","conclusion":"failure"},
                {"id":4,"head_sha":"s4","head_branch":"main","event":"push","status":"completed","conclusion":"success"}
            ]}' | ConvertFrom-Json
            $script:FirstVisitTemplateHead = '{"sha":"s4"}' | ConvertFrom-Json
            $script:FirstVisitTemplateHeadRuns = '{"workflow_runs":[{"id":4,"head_sha":"s4","head_branch":"main","event":"push","status":"completed","conclusion":"success"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts = '{"artifacts":[{"name":"windows-offline-template"}]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/commits/main$') { return $script:FirstVisitTemplateHead }
                if ($url -match 'head_sha=s4') { return $script:FirstVisitTemplateHeadRuns }
                if ($url -match '/release-scripts\.yml/runs\?per_page=50') { return $script:FirstVisitTemplateListing }
                if ($url -match '/runs/4/artifacts') { return $script:FirstVisitTemplateArtifacts }
                throw "unexpected-url:$url"
            }
            $resolved = Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'schedule') -Repository 'o/r' -ApiGet $api
            $resolved.runId | Should -Be '4'
            $resolved.candidates | Should -Be 1
            $resolved.stale | Should -BeFalse
        }

        It 'Fails with a clear INFRA code when no candidate keeps the artifact' {
            $script:FirstVisitTemplateListing = '{"workflow_runs":[{"id":9,"database_id":null,"head_sha":"sha-9","head_branch":"main","event":"push","conclusion":"success"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts = '{"artifacts":[]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/runs\?') { return $script:FirstVisitTemplateListing }
                return $script:FirstVisitTemplateArtifacts
            }
            { Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'schedule') -Repository 'o/r' -ApiGet $api } |
                Should -Throw '*first-visit-template-not-found*'
        }
    }

    Context 'Template capability gating (Phase 3A.3 L2)' {
        It 'Maps supported live signals to the harness capability argument' {
            Get-OpenPathFirstVisitCapabilityArgument -NativeHostLog $true -BackgroundStart $true -DiagnosticBatch $false | Should -Be 'native-host-log,background-start'
            Get-OpenPathFirstVisitCapabilityArgument -NativeHostLog $false -BackgroundStart $false -DiagnosticBatch $false | Should -Be ''
        }

        It 'Fails open for an unknown source SHA' {
            $capabilities = Get-OpenPathFirstVisitBuildCapabilities -SourceSha '0000000000000000000000000000000000000000' -IsAncestor { param($base, $head) return $false }
            $capabilities.CapabilityArgument | Should -Be ''
        }

        It 'Requires the diagnostics sanitizer for both E1 signals (deterministic probe)' {
            $withFix = { param($base, $head) return ($head -eq 'sha-new' -and $base -in @('196664c4', '7fe4d310')) }
            $beforeFix = { param($base, $head) return ($head -eq 'sha-old' -and $base -eq '196664c4') }
            (Get-OpenPathFirstVisitBuildCapabilities -SourceSha 'sha-new' -IsAncestor $withFix).CapabilityArgument | Should -Be 'native-host-log,background-start,diagnostic-batch'
            (Get-OpenPathFirstVisitBuildCapabilities -SourceSha 'sha-old' -IsAncestor $beforeFix).CapabilityArgument | Should -Be 'native-host-log'
        }

        It 'Matches the historical templates against the real repository history' {
            # c28bf26e predates the sanitizer fix: its E1 events never reached
            # the log, so requiring background-start produced a false reason.
            # The CI checkout is shallow, so the ancestry only proves anything
            # when the full history is present (the lane itself checks out with
            # fetch-depth 0).
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'git is unavailable'
                return
            }
            $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
            $shallow = & git -C $repoRoot rev-parse --is-shallow-repository 2>$null | Select-Object -First 1
            if ("$shallow".Trim() -eq 'true') {
                Set-ItResult -Skipped -Because 'the checkout is shallow'
                return
            }
            (Get-OpenPathFirstVisitBuildCapabilities -SourceSha 'c28bf26e').CapabilityArgument | Should -Be 'native-host-log'
            (Get-OpenPathFirstVisitBuildCapabilities -SourceSha '2342794d').CapabilityArgument | Should -Be ''
            $latest = Get-OpenPathFirstVisitBuildCapabilities -SourceSha '36f3a00c'
            $latest.nativeHostLog | Should -BeTrue
            $latest.backgroundStart | Should -BeTrue
            $latest.diagnosticBatch | Should -BeTrue
        }
    }

    Context 'Lane trigger planning (Phase 3A.2 K2)' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitLanePlan.psm1') -Force
        }

        It 'Detects first-visit-relevant changed paths' {
            Test-OpenPathFirstVisitRelevantPath -Paths @('docs/readme.md') | Should -BeFalse
            Test-OpenPathFirstVisitRelevantPath -Paths @('windows/lib/Browser.FirefoxPolicy.psm1') | Should -BeTrue
            Test-OpenPathFirstVisitRelevantPath -Paths @('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1') | Should -BeTrue
            Test-OpenPathFirstVisitRelevantPath -Paths @('docs/a.md', 'firefox-extension/src/background.ts') | Should -BeTrue
            Test-OpenPathFirstVisitRelevantPath -Paths @() | Should -BeFalse
        }

        It 'Plans scenarios per trigger' {
            $schedule = Get-OpenPathFirstVisitScenarioPlan -EventName 'schedule'
            $schedule.scenarios | Should -Be 'settled,hot,class-boot,floor'
            $schedule.repetitions | Should -Be 2
            $afterRel = Get-OpenPathFirstVisitScenarioPlan -EventName 'workflow_run'
            $afterRel.scenarios | Should -Be 'settled,class-boot'
            $afterRel.repetitions | Should -Be 1
            $dispatch = Get-OpenPathFirstVisitScenarioPlan -EventName 'workflow_dispatch'
            $dispatch.scenarios | Should -Be 'settled,class-boot'
            $dispatch.repetitions | Should -Be 1
            $requested = Get-OpenPathFirstVisitScenarioPlan -EventName 'workflow_dispatch' -RequestedScenarios 'class-boot' -RequestedRepetitions '5'
            $requested.scenarios | Should -Be 'class-boot'
            $requested.repetitions | Should -Be 5
        }

        It 'Uses the whole push range and fails open without a comparable base' {
            $ancestor = { param($base, $head) return ($base -eq 'base-1') }
            $docsDiff = { param($base, $head) return @('docs/readme.md') }
            $laneDiff = { param($base, $head) return @('windows/scripts/OpenPath-NativeHost.ps1') }
            $candidates = @([pscustomobject]@{ sha = 'old-1' }, [pscustomobject]@{ sha = 'base-1' })

            $decision = Get-OpenPathFirstVisitScopeDecision -EventName 'workflow_run' -HeadSha 'head-1' -Candidates $candidates -IsAncestor $ancestor -DiffFiles $docsDiff
            $decision.run | Should -BeFalse
            $decision.base | Should -Be 'base-1'

            (Get-OpenPathFirstVisitScopeDecision -EventName 'workflow_run' -HeadSha 'head-1' -Candidates $candidates -IsAncestor $ancestor -DiffFiles $laneDiff).run | Should -BeTrue

            $noBase = Get-OpenPathFirstVisitScopeDecision -EventName 'workflow_run' -HeadSha 'head-1' -Candidates @() -IsAncestor $ancestor -DiffFiles $docsDiff
            $noBase.run | Should -BeTrue
            $noBase.reason | Should -Be 'no-comparable-base-fail-open'

            $emptyDiff = Get-OpenPathFirstVisitScopeDecision -EventName 'workflow_run' -HeadSha 'head-1' -Candidates $candidates -IsAncestor $ancestor -DiffFiles { param($b, $h) return @() }
            $emptyDiff.run | Should -BeTrue
            $emptyDiff.reason | Should -Be 'empty-diff-fail-open'

            (Get-OpenPathFirstVisitScopeDecision -EventName 'workflow_dispatch' -HeadSha '' -Candidates @()).run | Should -BeTrue

            # The nightly must run unconditionally, never diff-scoped.
            $schedule = Get-OpenPathFirstVisitScopeDecision -EventName 'schedule' -HeadSha '' -Candidates @() -IsAncestor $ancestor -DiffFiles $docsDiff
            $schedule.run | Should -BeTrue
            $schedule.reason | Should -Be 'non-workflow-run'
        }

        It 'Keeps every PowerShell workflow run block parseable' {
            $workflowPath = Join-Path $PSScriptRoot '..\..\.github\workflows\windows-first-visit-lab.yml'
            $lines = Get-Content -LiteralPath $workflowPath
            $blocks = @()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '^\s+run:\s*\|\s*$') { continue }
                $indent = $lines[$i].Length - $lines[$i].TrimStart().Length
                $start = $i + 1
                $end = $start
                while ($end -lt $lines.Count -and ($lines[$end].Trim() -eq '' -or ($lines[$end].Length - $lines[$end].TrimStart().Length) -gt $indent)) { $end++ }
                $block = ($lines[$start..($end - 1)] -join "`n")
                if ($block -match 'Invoke-RestMethod|Import-Module|\$env:') { $blocks += $block }
                $i = $end
            }
            $blocks.Count | Should -BeGreaterThan 0
            foreach ($block in $blocks) {
                # GitHub expressions are replaced before PowerShell sees the text.
                $sanitized = [regex]::Replace($block, '\$\{\{[^}]*\}\}', 'placeholder')
                $tokens = $null
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseInput($sanitized, [ref]$tokens, [ref]$errors)
                @($errors).Count | Should -Be 0 -Because (@($errors | ForEach-Object { $_.Message }) -join '; ')
            }
        }

        It 'Keeps the lane workflow free of the gh CLI and wired to the range resolver' {
            $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\.github\workflows\windows-first-visit-lab.yml') -Raw
            $workflow | Should -Not -Match 'gh run '
            $workflow | Should -Not -Match 'gh workflow'
            $workflow | Should -Match 'Resolve-FirstVisitScope\.ps1'
            $workflow | Should -Match 'FirstVisitLanePlan\.psm1'
            $workflow | Should -Match 'archive_download_url'
            $workflow | Should -Match 'steps\.plan\.outputs\.scenarios'
            $workflow | Should -Match 'steps\.template\.outputs\.template_sha'
        }

        It 'Resolves the template through the tested module and never reads database_id' {
            $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\.github\workflows\windows-first-visit-lab.yml') -Raw
            $workflow | Should -Match 'FirstVisitTemplateSource\.psm1'
            $workflow | Should -Match 'Get-FirstVisitTemplateSourcePlan'
            $workflow | Should -Match 'Resolve-FirstVisitTemplateRun'
            $workflow | Should -Not -Match 'database_id'
            # No lane run may cancel another: the concurrency group is per run.
            $workflow | Should -Match 'group: windows-first-visit-lab-\$\{\{ github\.run_id \}\}'
        }

        It 'Stages the shared result and verdict modules next to the guest harness' {
            $controller = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\controllers\ProxmoxFirstVisit.ps1') -Raw
            $controller | Should -Match 'FirstVisitWarmup\.psm1'
            $controller | Should -Match 'FirstVisitResult\.psm1'
            # The modules are staged through the artifact transport next to the
            # harness; a single encoded command with both module texts exceeded
            # the QGA command size and failed every prepare (Phase 3A.3).
            $controller | Should -Match 'DownloadGuestArtifact \$Vmid \$url \$guestModulePath'
            $controller | Should -Match '\$Paths\.GuestDir\.TrimEnd'
            $controller | Should -Not -Match 'warmupModuleLiteral'
            $controller | Should -Not -Match 'resultModuleLiteral'
            $controller | Should -Match 'Read-OpenPathFirstVisitGuestText'
            $controller | Should -Match 'first-visit-precondition-failed'
            $controller | Should -Match 'Get-FirstVisitHostSignalsVerdict'
        }
    }

    Context 'Aggregator honesty (Phase 5 A2)' {
        It 'Classifies an observe failure as INFRA with the literal controller error' {
            $root = Join-Path $TestDrive ('aggregate-' + [guid]::NewGuid().ToString('N'))
            $scenarioDir = Join-Path (Join-Path (Join-Path $root '12345') '1') 'first-visit-settled-r1'
            New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'prepare.json'), '{"status":"passed","error":""}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'observe.json'), '{"status":"failed","reasonCode":"CONTROLLER_PHASE_FAILED","error":"controller-exit-1: CONTROLLER_PHASE_FAILED: first-visit-guest-step-failed-observe-collect-result-serialization-failed"}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'cleanup.json'), '{"status":"passed","error":""}')
            $summaryJson = Join-Path $root 'summary.json'
            $hostExe = (Get-Process -Id $PID).Path
            $aggregate = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\aggregate-windows-first-visit.ps1'
            $hostArguments = @('-NoProfile')
            if ([IO.Path]::GetFileName($hostExe) -ieq 'powershell.exe') { $hostArguments += @('-ExecutionPolicy', 'Bypass') }
            & $hostExe @hostArguments -File $aggregate -RunId '12345' -RunAttempt 1 -EvidenceRoot $root -SummaryJsonPath $summaryJson | Out-Null
            $LASTEXITCODE | Should -Be 1
            $summary = Get-Content -LiteralPath $summaryJson -Raw | ConvertFrom-Json
            $row = $summary.scenarios[0]
            $row.category | Should -Be 'INFRA'
            $row.error | Should -Match 'first-visit-guest-step-failed-observe-collect-result-serialization-failed'
            $row.observeStatus | Should -Be 'failed'
            ($row.reasons -join ',') | Should -Match 'observe-failed'
        }

        It 'Never leaves a scene without a verdict or a literal cause' {
            $root = Join-Path $TestDrive ('aggregate-' + [guid]::NewGuid().ToString('N'))
            $scenarioDir = Join-Path (Join-Path (Join-Path $root '12345') '1') 'first-visit-hot-r1'
            New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'prepare.json'), '{"status":"passed","error":""}')
            $summaryJson = Join-Path $root 'summary.json'
            $hostExe = (Get-Process -Id $PID).Path
            $aggregate = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\aggregate-windows-first-visit.ps1'
            $hostArguments = @('-NoProfile')
            if ([IO.Path]::GetFileName($hostExe) -ieq 'powershell.exe') { $hostArguments += @('-ExecutionPolicy', 'Bypass') }
            & $hostExe @hostArguments -File $aggregate -RunId '12345' -RunAttempt 1 -EvidenceRoot $root -SummaryJsonPath $summaryJson | Out-Null
            $LASTEXITCODE | Should -Be 1
            $row = (Get-Content -LiteralPath $summaryJson -Raw | ConvertFrom-Json).scenarios[0]
            $row.category | Should -Be 'INFRA'
            $row.category | Should -Not -Be 'UNKNOWN'
            $row.error | Should -Not -Be ''
        }

        It 'Classifies a measured passing verdict as PASS (control)' {
            $root = Join-Path $TestDrive ('aggregate-' + [guid]::NewGuid().ToString('N'))
            $scenarioDir = Join-Path (Join-Path (Join-Path $root '12345') '1') 'first-visit-control-r1'
            New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'prepare.json'), '{"status":"passed","error":""}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'observe.json'), '{"status":"passed","error":""}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'cleanup.json'), '{"status":"passed","error":""}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'metrics.json'), '{"verdict":"passed","reasons":[],"reloads":0,"waveTimesMs":{"wave1":1000},"warmup":{"productReasons":[]}}')
            $summaryJson = Join-Path $root 'summary.json'
            $hostExe = (Get-Process -Id $PID).Path
            $aggregate = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\aggregate-windows-first-visit.ps1'
            $hostArguments = @('-NoProfile')
            if ([IO.Path]::GetFileName($hostExe) -ieq 'powershell.exe') { $hostArguments += @('-ExecutionPolicy', 'Bypass') }
            & $hostExe @hostArguments -File $aggregate -RunId '12345' -RunAttempt 1 -EvidenceRoot $root -SummaryJsonPath $summaryJson | Out-Null
            $LASTEXITCODE | Should -Be 0
            $row = (Get-Content -LiteralPath $summaryJson -Raw | ConvertFrom-Json).scenarios[0]
            $row.category | Should -Be 'PASS'
            $row.verdict | Should -Be 'passed'
        }
    }

    Context 'Acrylic INI parsing (Phase 6 A)' -Tag 'Phase6' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitDnsTopology.psm1') -Force
            $iniSample = @'
; Acrylic sample with sections, upstreams and masks
[GlobalSection]
PrimaryServerAddress=192.0.2.10
SecondaryServerAddress=192.0.2.11
TertiaryServerAddress=192.0.2.12
QuaternaryServerAddress=
DenaryServerAddress=192.0.2.19
AddressCacheDomainNameAffinityMask=example.com,example.org
AddressCacheQueryTypeAffinityMask=1,28
; PrimaryServerAddress=9.9.9.9
UseWindowsHostsFile=True
[AdditionalSection]
PrimaryServerAddress=198.51.100.7
'@
        }

        It 'Keeps the literal GlobalSection upstream values and affinity masks' {
            $parsed = ConvertFrom-OpenPathAcrylicIniText -Text $iniSample
            $parsed['GlobalSection.PrimaryServerAddress'] | Should -Be '192.0.2.10'
            $parsed['GlobalSection.SecondaryServerAddress'] | Should -Be '192.0.2.11'
            $parsed['GlobalSection.TertiaryServerAddress'] | Should -Be '192.0.2.12'
            $parsed['GlobalSection.AddressCacheDomainNameAffinityMask'] | Should -Be 'example.com,example.org'
            $parsed['GlobalSection.AddressCacheQueryTypeAffinityMask'] | Should -Be '1,28'
            $parsed['AdditionalSection.PrimaryServerAddress'] | Should -Be '198.51.100.7'
        }

        It 'Ignores commented keys and keeps empty values empty' {
            $parsed = ConvertFrom-OpenPathAcrylicIniText -Text $iniSample
            $parsed['GlobalSection.PrimaryServerAddress'] | Should -Not -Be '9.9.9.9'
            $parsed.Contains('GlobalSection.PrimaryServerAddress') | Should -BeTrue
            $parsed['GlobalSection.QuaternaryServerAddress'] | Should -Be ''
        }

        It 'Parses a CRLF file and returns an empty map for empty text' {
            $crlf = ($iniSample -replace "`n", "`r`n")
            $parsed = ConvertFrom-OpenPathAcrylicIniText -Text $crlf
            $parsed['GlobalSection.PrimaryServerAddress'] | Should -Be '192.0.2.10'
            (ConvertFrom-OpenPathAcrylicIniText -Text '').Keys.Count | Should -Be 0
        }
    }

    Context 'Real-site canary metrics (Phase 6 C)' -Tag 'Phase6' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitSiteCanary.psm1') -Force
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitWarmup.psm1') -Force
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitOutcome.psm1') -Force
            function ConvertTo-DiagLine {
                param([hashtable]$Event)
                return '2026-10-06 12:00:00 [INFO] [NativeHost] [PID:1] stage=extension-diagnostic ' + (($Event | ConvertTo-Json -Compress))
            }
            $script:canaryLines = @(
                (ConvertTo-DiagLine @{ ts = 1000; kind = 'navigation'; source = 'onBeforeNavigate'; host = 'www.example.invalid' }),
                (ConvertTo-DiagLine @{ ts = 1200; kind = 'hold'; dependencyHost = 'cdn1.example.invalid'; tabId = 5; type = 'script' }),
                (ConvertTo-DiagLine @{ ts = 2000; kind = 'hold-outcome'; dependencyHost = 'cdn1.example.invalid'; outcome = 'ready'; ms = 800; tabId = 5 }),
                (ConvertTo-DiagLine @{ ts = 2500; kind = 'hold'; dependencyHost = 'cdn2.example.invalid'; tabId = -1; type = 'image' }),
                (ConvertTo-DiagLine @{ ts = 7700; kind = 'hold-outcome'; dependencyHost = 'cdn2.example.invalid'; outcome = 'cancelled-budget'; ms = 5200; tabId = -1 }),
                (ConvertTo-DiagLine @{ ts = 8000; kind = 'reload-decision'; reason = 'ready-adopted-document'; tabId = 5 }),
                'not a diagnostic line'
            )
        }

        It 'Aggregates hold outcomes, ready times, reloads and service-worker holds' {
            $metrics = Get-OpenPathFirstVisitCanaryMetrics -DiagnosticLines $script:canaryLines
            $metrics.holds | Should -Be 2
            $metrics.outcomeCounts.ready | Should -Be 1
            $metrics.outcomeCounts.'cancelled-budget' | Should -Be 1
            $metrics.readyP50Ms | Should -Be 800
            $metrics.readyMaxMs | Should -Be 800
            $metrics.lastReadyFromNavigationMs | Should -Be 1000
            $metrics.reloads | Should -Be 1
            ($metrics.reloadReasons -join ',') | Should -Be 'ready-adopted-document'
            $metrics.serviceWorkerHolds | Should -Be 1
        }

        It 'Fails the canary when any hold is not ready, a negative follow-up appears or reloads exceed one' {
            $metrics = Get-OpenPathFirstVisitCanaryMetrics -DiagnosticLines $script:canaryLines
            $verdict = Get-OpenPathFirstVisitCanaryVerdict -Metrics $metrics -MozResult ([pscustomobject]@{ negativeCount = 0 })
            $verdict.status | Should -Be 'CANARY-RED'
            ($verdict.reasons -join ',') | Should -Match 'holds-not-ready:1'

            $okLines = @(
                (ConvertTo-DiagLine @{ ts = 1200; kind = 'hold'; dependencyHost = 'cdn1.example.invalid'; tabId = 5 }),
                (ConvertTo-DiagLine @{ ts = 2000; kind = 'hold-outcome'; dependencyHost = 'cdn1.example.invalid'; outcome = 'ready'; ms = 800; tabId = 5 })
            )
            $okMetrics = Get-OpenPathFirstVisitCanaryMetrics -DiagnosticLines $okLines
            (Get-OpenPathFirstVisitCanaryVerdict -Metrics $okMetrics -MozResult ([pscustomobject]@{ negativeCount = 0 })).status | Should -Be 'CANARY-PASS'
            (Get-OpenPathFirstVisitCanaryVerdict -Metrics $okMetrics -MozResult ([pscustomobject]@{ negativeCount = 2 })).status | Should -Be 'CANARY-RED'
            $manyReloads = Get-OpenPathFirstVisitCanaryMetrics -DiagnosticLines ($okLines + (ConvertTo-DiagLine @{ ts = 3000; kind = 'reload-decision'; reason = 'a' }) + (ConvertTo-DiagLine @{ ts = 4000; kind = 'reload-decision'; reason = 'b' }))
            (Get-OpenPathFirstVisitCanaryVerdict -Metrics $manyReloads -MozResult ([pscustomobject]@{ negativeCount = 0 })).status | Should -Be 'CANARY-RED'
        }

        It 'Only counts MOZ negatives for learned hosts after their ready time' {
            $readyTs = [long]([datetimeoffset]::ParseExact('2026-10-06 12:00:10.000000', 'yyyy-MM-dd HH:mm:ss.ffffff', [System.Globalization.CultureInfo]::InvariantCulture)).ToUnixTimeMilliseconds()
            $beforeTs = $readyTs - 5000
            $afterTs = $readyTs + 5000
            $format = { param([long]$Ts) ([datetimeoffset]::FromUnixTimeMilliseconds($Ts)).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss.ffffff') }
            $mozLines = @(
                ((& $format $beforeTs) + ' UTC - [1:1]: D/nsHostResolver DNS lookup for cdn1.example.invalid'),
                ((& $format $afterTs) + ' UTC - [1:1]: D/nsHostResolver DNS lookup for cdn1.example.invalid'),
                ((& $format $afterTs) + ' UTC - [1:1]: E/nsHostResolver failed for cdn1.example.invalid NS_ERROR_UNKNOWN_HOST'),
                ((& $format $afterTs) + ' UTC - [1:1]: D/nsHostResolver something for unrelated.example')
            )
            $result = Select-OpenPathFirstVisitMozHostLines -MozLines $mozLines -Hosts @('cdn1.example.invalid') -ReadyTimes ([pscustomobject]@{ 'cdn1.example.invalid' = $readyTs })
            $result.negativeCount | Should -Be 1
            @($result.linesByHost['cdn1.example.invalid']).Count | Should -Be 3
        }

        It 'Measures worker stamp to ready gaps over two seconds' {
            $stampText = '2026-10-06 12:00:00 [INFO] [Update.Runtime.psm1] [PID:9] Runtime dependency fast apply overlay generation stamped: appliedGeneration=3'
            $stampEpoch = [long]([datetimeoffset]::ParseExact('2026-10-06 12:00:00', 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)).ToUnixTimeMilliseconds()
            $readyEvents = @(
                [pscustomobject]@{ dependencyHost = 'slow.example'; ts = $stampEpoch + 3200 },
                [pscustomobject]@{ dependencyHost = 'fast.example'; ts = $stampEpoch + 500 }
            )
            $gaps = @(Get-OpenPathFirstVisitStampGaps -OpenPathLines @($stampText) -ReadyEvents $readyEvents)
            $gaps.Count | Should -Be 1
            $gaps[0].host | Should -Be 'slow.example'
            $gaps[0].gapMs | Should -Be 3200
        }

        It 'Names a Smart App Control block from the CodeIntegrity events' {
            $codeIntegrity = [ordered]@{
                codeIntegrity = @(
                    'Event[0]:',
                    '  Date: 2026-10-06T12:30:00.1234567Z',
                    '  Event ID: 3033',
                    '  Description:',
                    '  Code Integrity determined that a process (C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.exe) attempted to load a file that did not meet the Microsoft signing level requirements.',
                    'Event[1]:',
                    '  Date: 2026-10-06T12:30:01.1234567Z',
                    '  Event ID: 3077',
                    '  Description:',
                    '  Code Integrity would have blocked notepad.exe (audit).'
                )
            }
            $hostVerdict = Get-FirstVisitHostSignalsVerdict -Live ([pscustomobject]@{ hostStarted = $false }) -Events $null -Capabilities 'native-host-log' -CodeIntegrityEvents $codeIntegrity -SmartAppControlState 'On'
            $hostVerdict.status | Should -Be 'failed'
            $hostVerdict.productReasons | Should -Contain 'native-host-blocked-by-smart-app-control'
            $hostVerdict.blockedBySmartAppControl | Should -BeTrue
            $hostVerdict.signals.smartAppControlState | Should -Be 'On'
            $hostVerdict.smartAppControlEvidence[0].eventId | Should -Be 3033
            # Audit-only events for unrelated binaries never produce the signal.
            $auditOnly = [ordered]@{ codeIntegrity = @('Event[0]:', '  Event ID: 3077', '  notepad.exe (audit)') }
            (Get-FirstVisitHostSignalsVerdict -Live ([pscustomobject]@{ hostStarted = $false }) -Events $null -Capabilities 'native-host-log' -CodeIntegrityEvents $auditOnly).blockedBySmartAppControl | Should -BeFalse
        }

        It 'Validates the site and smart_app_control dispatch inputs before touching the lab' {
            $config = [pscustomobject]@{ hostAddress = '192.168.1.150' }
            function New-FirstVisitPayload {
                param([hashtable]$FirstVisit)
                return [pscustomobject]@{ firstVisit = [pscustomobject]$FirstVisit }
            }
            $site = Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-site'; siteUrl = 'https://example.invalid/'; siteWhitelist = 'example.invalid' }) -Config $config
            $site.SiteMode | Should -BeTrue
            $site.SiteUrl | Should -Be 'https://example.invalid/'
            $site.SiteDomains | Should -Contain 'example.invalid'
            $siteClassBoot = Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-site-class-boot'; siteUrl = 'https://example.invalid/'; siteWhitelist = 'example.invalid' }) -Config $config
            $siteClassBoot.SiteMode | Should -BeTrue
            { Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-site' }) -Config $config } | Should -Throw '*first-visit-site-url-required*'
            { Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-site'; siteUrl = 'https://example.invalid/a b' }) -Config $config } | Should -Throw '*first-visit-site-url-invalid*'
            { Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-site'; siteUrl = 'https://example.invalid/'; siteWhitelist = 'bad_domain!' }) -Config $config } | Should -Throw '*first-visit-site-domain-invalid*'
            $sac = Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-class-boot'; smartAppControl = 'on' }) -Config $config
            $sac.SmartAppControl | Should -Be 'on'
            { Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-settled'; smartAppControl = 'on' }) -Config $config } | Should -Throw '*requires-class-boot*'
            { Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-class-boot'; smartAppControl = 'maybe' }) -Config $config } | Should -Throw '*smart-app-control-invalid*'
            # `site-class-boot` is a class-boot flow, so the SAC simulation is allowed there.
            { Get-OpenPathFirstVisitSettings -Payload (New-FirstVisitPayload @{ scenario = 'first-visit-site-class-boot'; siteUrl = 'https://example.invalid/'; siteWhitelist = 'example.invalid'; smartAppControl = 'on' }) -Config $config } | Should -Not -Throw
        }

        It 'Classifies a canary scene as CANARY-PASS/CANARY-RED and only INFRA fails the run' {
            $root = Join-Path $TestDrive ('aggregate-' + [guid]::NewGuid().ToString('N'))
            $scenarioDir = Join-Path (Join-Path (Join-Path $root '12345') '1') 'first-visit-site-r1'
            New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'prepare.json'), '{"status":"passed","error":""}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'observe.json'), '{"status":"passed","error":""}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'cleanup.json'), '{"status":"passed","error":""}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'observe-verdict.json'), '{"schemaVersion":1,"scenario":"first-visit-site","source":"canary","canary":true,"canaryStatus":"CANARY-RED","canaryReasons":["holds-not-ready:1"],"reportPresent":false,"verdict":{"status":"canary-red","reasons":["holds-not-ready:1"]},"productReasons":[],"evidenceIncomplete":false}')
            [IO.File]::WriteAllText((Join-Path $scenarioDir 'metrics.json'), '{"scenario":"first-visit-site","verdict":"canary-red","reasons":["holds-not-ready:1"],"reloads":0,"warmup":{"productReasons":[]},"canary":{"status":"CANARY-RED","metrics":{"holds":2,"readyP50Ms":800,"readyMaxMs":900,"reloads":1},"negativeCount":0}}')
            $summaryJson = Join-Path $root 'summary.json'
            $hostExe = (Get-Process -Id $PID).Path
            $aggregate = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\aggregate-windows-first-visit.ps1'
            $hostArguments = @('-NoProfile')
            if ([IO.Path]::GetFileName($hostExe) -ieq 'powershell.exe') { $hostArguments += @('-ExecutionPolicy', 'Bypass') }
            & $hostExe @hostArguments -File $aggregate -RunId '12345' -RunAttempt 1 -EvidenceRoot $root -SummaryJsonPath $summaryJson | Out-Null
            $LASTEXITCODE | Should -Be 0
            $row = (Get-Content -LiteralPath $summaryJson -Raw | ConvertFrom-Json).scenarios[0]
            $row.category | Should -Be 'CANARY-RED'
            $row.canaryStatus | Should -Be 'CANARY-RED'
            # An incomplete canary is INFRA and does fail the run. The pure
            # classifier is exercised directly so the test never needs a second
            # aggregate host process (the Windows shard's per-file timeout).
            $infraOutcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile ([pscustomobject]@{
                    scenario = 'first-visit-site'; source = 'canary'; canary = $true; canaryStatus = 'CANARY-PASS'
                    reportPresent = $false; productReasons = @(); evidenceIncomplete = $true; collectError = 'collect-timeout'
                    verdict = [pscustomobject]@{ status = 'canary-pass'; reasons = @() }
                }) -Metrics $null -Scenario 'first-visit-site'
            $infraOutcome.category | Should -Be 'INFRA'
            $infraOutcome.error | Should -Be 'collect-timeout'
        }
    }

    Context 'Visit launch wrapper (Phase 6.1 A)' -Tag 'Phase61' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitLaunch.psm1') -Force
            $firefoxPath = 'C:\Program Files\Mozilla Firefox\firefox.exe'
            $url = 'https://example.invalid/'
            $root = 'C:\OpenPath\lab\first-visit'
            $script:launchBody = ConvertTo-OpenPathFirstVisitFirefoxCmdBody -FirefoxPath $firefoxPath -Url $url -Tag 'visit' -Root $root -MozLog $true
            $script:launchLines = @($script:launchBody -split "`r?`n")
        }

        It 'Keeps every set directive on its own line and exactly one quoted launch line with -new-window and the URL' {
            $launchLines = @($script:launchLines | Where-Object { $_ -match '^\s*"' })
            $launchLines.Count | Should -Be 1
            $launchLines[0].Contains('"' + $firefoxPath + '"') | Should -BeTrue
            $launchLines[0].Contains('-new-window') | Should -BeTrue
            $launchLines[0].Contains('"' + $url + '"') | Should -BeTrue
            $launchLines[0] | Should -Match 'firefox-visit\.log'
            $script:launchLines | Should -Contain '@echo off'
            # The old here-string glued the last set directive to the launch
            # line: no set line may ever carry firefox.exe.
            foreach ($line in $script:launchLines) {
                if ($line -match '^\s*set\s') { $line | Should -Not -Match 'firefox\.exe' }
            }
        }

        It 'Uses Firefox MOZ_LOG rotation and no unknown environment variable' {
            $moz = @($script:launchLines | Where-Object { $_ -match '^\s*set\s+MOZ_LOG' })
            $moz.Count | Should -Be 2
            ($moz -join "`n") | Should -Match 'timestamp,rotate:16,nsHostResolver:5'
            ($moz -join "`n").Contains("$root\moz\hostresolver.log") | Should -BeTrue
            @($script:launchLines | Where-Object { $_ -match 'MOZ_LOG_FILE_MAX_SIZE' }).Count | Should -Be 0
        }

        It 'Omits every MOZ_LOG directive when the canary logging is off' {
            $plain = ConvertTo-OpenPathFirstVisitFirefoxCmdBody -FirefoxPath 'C:\PF\firefox.exe' -Url 'http://example.invalid/' -Tag 'warmup' -Root 'C:\root' -MozLog $false
            $plain | Should -Not -Match 'MOZ_LOG'
            @($plain -split "`r?`n" | Where-Object { $_ -match '^\s*"' }).Count | Should -Be 1
        }
    }

    Context 'SAC positive control and canary navigation (Phase 6.1 B/C)' -Tag 'Phase61' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitWarmup.psm1') -Force
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitSiteCanary.psm1') -Force
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitOutcome.psm1') -Force
            function ConvertTo-DiagLine61 {
                param([hashtable]$Event)
                return '2026-10-07 08:00:00 [INFO] [NativeHost] [PID:1] stage=extension-diagnostic ' + (($Event | ConvertTo-Json -Compress))
            }
        }

        It 'Only counts SAC as applied with UMCI enforced AND the MOTW control blocked' {
            $state = [pscustomobject]@{ deviceGuard = [pscustomobject]@{ umciEnforcementStatus = 2 } }
            $blockedMotw = [pscustomobject]@{
                plain = [pscustomobject]@{ started = $true; exitCode = 7 }
                motw  = [pscustomobject]@{ started = $false; error = 'blocked by policy'; nativeError = 1260 }
            }
            (Get-OpenPathFirstVisitSacDecision -SacState $state -SacControl $blockedMotw).applied | Should -BeTrue
            # The registry saying On is not enough: the MOTW control must be blocked.
            $ranMotw = [pscustomobject]@{
                plain = [pscustomobject]@{ started = $true; exitCode = 7 }
                motw  = [pscustomobject]@{ started = $true; exitCode = 7 }
            }
            (Get-OpenPathFirstVisitSacDecision -SacState $state -SacControl $ranMotw).applied | Should -BeFalse
            # A blocked MOTW without UMCI enforcement is not enough either.
            $auditState = [pscustomobject]@{ deviceGuard = [pscustomobject]@{ umciEnforcementStatus = 1 } }
            (Get-OpenPathFirstVisitSacDecision -SacState $auditState -SacControl $blockedMotw).applied | Should -BeFalse
            # No control at all can never pass.
            (Get-OpenPathFirstVisitSacDecision -SacState $state -SacControl $null).applied | Should -BeFalse
        }

        It 'Reads the Smart App Control block from the CodeIntegrity XML with file and policy' {
            $xml = @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><EventID>3033</EventID><TimeCreated SystemTime="2026-10-07T08:00:00.1234567Z"/></System><EventData><Data Name="PolicyId">{11111111-2222-3333-4444-555555555555}</Data><Data Name="FileName">\Device\HarddiskVolume3\Program Files\OpenPath\OpenPath-NativeHost.exe</Data></EventData></Event>
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><EventID>3077</EventID><TimeCreated SystemTime="2026-10-07T08:00:01.1234567Z"/></System><EventData><Data Name="FileName">notepad.exe</Data></EventData></Event>
'@
            $events = [ordered]@{ codeIntegrityXml = [ordered]@{ xml = $xml } }
            $evidence = @(Select-FirstVisitSmartAppControlEvidence -Events $events)
            $evidence.Count | Should -Be 1
            $evidence[0].eventId | Should -Be 3033
            $evidence[0].blocking | Should -BeTrue
            $evidence[0].policy | Should -Be '{11111111-2222-3333-4444-555555555555}'
            $verdict = Get-FirstVisitHostSignalsVerdict -Live ([pscustomobject]@{ hostStarted = $false }) -Events $null -Capabilities 'native-host-log' -CodeIntegrityEvents $events
            $verdict.productReasons | Should -Contain 'native-host-blocked-by-smart-app-control'
            # Audit-only events (3076/3077) never raise the product signal.
            $auditOnly = [ordered]@{ codeIntegrityXml = [ordered]@{ xml = '<Event><System><EventID>3077</EventID><TimeCreated SystemTime="2026-10-07T08:00:02Z"/></System><EventData><Data Name="FileName">OpenPath-NativeHost.exe</Data></EventData></Event>' } }
            (Get-FirstVisitHostSignalsVerdict -Live ([pscustomobject]@{ hostStarted = $false }) -Events $null -Capabilities 'native-host-log' -CodeIntegrityEvents $auditOnly).blockedBySmartAppControl | Should -BeFalse
        }

        It 'Requires the site host to be navigated or the scene is INFRA site-not-navigated' {
            $lines = @(
                (ConvertTo-DiagLine61 @{ ts = 1000; kind = 'navigation'; source = 'onCommitted'; host = 'www.example.invalid' }),
                (ConvertTo-DiagLine61 @{ ts = 1200; kind = 'hold'; dependencyHost = 'cdn.example.invalid'; tabId = 5 })
            )
            $metrics = Get-OpenPathFirstVisitCanaryMetrics -DiagnosticLines $lines -SiteHost 'www.example.invalid'
            $metrics.siteNavigated | Should -BeTrue
            $metrics.siteNavigationTs | Should -Be 1000
            (Get-OpenPathFirstVisitCanaryMetrics -DiagnosticLines $lines -SiteHost 'other.example.invalid').siteNavigated | Should -BeFalse
            $outcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile ([pscustomobject]@{
                    scenario = 'first-visit-site'; source = 'canary'; canary = $true; canaryStatus = 'CANARY-RED'
                    siteNavigated = $false; reportPresent = $false; productReasons = @()
                    verdict = [pscustomobject]@{ status = 'canary-red'; reasons = @('no-holds-observed') }
                }) -Metrics $null -Scenario 'first-visit-site'
            $outcome.category | Should -Be 'INFRA'
            $outcome.error | Should -Be 'site-not-navigated'
            # A navigated canary keeps its CANARY status as the category.
            $navigatedOutcome = Get-OpenPathFirstVisitSceneOutcome -VerdictFile ([pscustomobject]@{
                    scenario = 'first-visit-site'; source = 'canary'; canary = $true; canaryStatus = 'CANARY-PASS'
                    siteNavigated = $true; reportPresent = $false; productReasons = @()
                    verdict = [pscustomobject]@{ status = 'canary-pass'; reasons = @() }
                }) -Metrics $null -Scenario 'first-visit-site'
            $navigatedOutcome.category | Should -Be 'CANARY-PASS'
        }
    }
}
