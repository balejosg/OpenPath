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
{"schemaVersion":1,"runId":"12345","anchor":"a1","anchorHost":"anchor1-ab12cd.192.168.1.150.sslip.io","navigationType":"navigate","loads":$Loads,"waves":{"cssApplied":true,"fontLoaded":true,"imageLoaded":true,"coreExecuted":true,"deferredExecuted":true,"apiPainted":true,"blockedCssFailed":true},"marks":{"start":1,"core":3000,"deferred":5000,"api":$ApiMark,"load":$ApiMark},"timings":{}}
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
    }

    Context 'Metrics extraction' {
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
        }
    }

    Context 'Template resolution (Phase 3A.3 L1)' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitTemplateSource.psm1') -Force
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
            $script:FirstVisitTemplateListing = '{"workflow_runs":[{"id":111,"database_id":null,"head_sha":"sha-111"},{"id":222,"database_id":null,"head_sha":"sha-222"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts111 = '{"artifacts":[{"name":"windows-personalized-exe"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts222 = '{"artifacts":[{"name":"windows-offline-template"}]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/release-scripts\.yml/runs\?branch=main&status=success') { return $script:FirstVisitTemplateListing }
                if ($url -match '/runs/111/artifacts') { return $script:FirstVisitTemplateArtifacts111 }
                if ($url -match '/runs/222/artifacts') { return $script:FirstVisitTemplateArtifacts222 }
                throw "unexpected-url:$url"
            }
            $resolved = Resolve-FirstVisitTemplateRun -Plan (Get-FirstVisitTemplateSourcePlan -EventName 'schedule') -Repository 'o/r' -ApiGet $api
            $resolved.runId | Should -Be '222'
            $resolved.templateSha | Should -Be 'sha-222'
            $resolved.candidates | Should -Be 2
        }

        It 'Resolves a dispatch by run id and by target SHA' {
            $script:FirstVisitTemplateRun = '{"id":777,"head_sha":"sha-777"}' | ConvertFrom-Json
            $script:FirstVisitTemplateListing = '{"workflow_runs":[{"id":777,"head_sha":"sha-777"}]}' | ConvertFrom-Json
            $script:FirstVisitTemplateArtifacts = '{"artifacts":[{"name":"windows-offline-template"}]}' | ConvertFrom-Json
            $api = {
                param($url)
                if ($url -match '/actions/runs/777$') { return $script:FirstVisitTemplateRun }
                if ($url -match 'head_sha=sha-777&status=success') { return $script:FirstVisitTemplateListing }
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

        It 'Fails with a clear INFRA code when no candidate keeps the artifact' {
            $script:FirstVisitTemplateListing = '{"workflow_runs":[{"id":9,"database_id":null}]}' | ConvertFrom-Json
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

        It 'Matches the historical templates against the real repository history' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
            # c28bf26e predates the sanitizer fix: its E1 events never reached
            # the log, so requiring background-start produced a false reason.
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
            $schedule.scenarios | Should -Be 'settled,hot,class-boot,control'
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
            $controller | Should -Match 'Read-OpenPathFirstVisitGuestText'
            $controller | Should -Match 'first-visit-precondition-failed'
            $controller | Should -Match 'Get-FirstVisitHostSignalsVerdict'
        }
    }
}
