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
                return @'
{"schemaVersion":1,"runId":"12345","anchors":{"a1":{"host":"anchor1-ab12cd.192.168.1.150.sslip.io","roles":{"styles":"styles1-ab12cd.192.168.1.150.sslip.io","core":"core1-ab12cd.192.168.1.150.sslip.io","deferred":"deferred1-ab12cd.192.168.1.150.sslip.io","font":"font1-ab12cd.192.168.1.150.sslip.io","image":"image1-ab12cd.192.168.1.150.sslip.io","apiservice":"api1-ab12cd.192.168.1.150.sslip.io"}},"a2":{"host":"anchor2-ab12cd.192.168.1.150.sslip.io","roles":{}}},"controlDependencies":["styles1-ab12cd.192.168.1.150.sslip.io","core1-ab12cd.192.168.1.150.sslip.io","deferred1-ab12cd.192.168.1.150.sslip.io","font1-ab12cd.192.168.1.150.sslip.io","image1-ab12cd.192.168.1.150.sslip.io","api1-ab12cd.192.168.1.150.sslip.io"],"neverLearnable":"blocked9-ab12cd.192.168.1.150.sslip.io","unlisted":"unlisted8-ab12cd.192.168.1.150.sslip.io","whitelistHosts":["anchor1-ab12cd.192.168.1.150.sslip.io","anchor2-ab12cd.192.168.1.150.sslip.io"],"blockedSubdomains":["blocked9-ab12cd.192.168.1.150.sslip.io"]}
'@
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
                        if ($first -eq 'curl') {
                            if ($script:FirstVisitTestState.ReportJson) {
                                return ('{"runId":"12345","requests":9,"browserRequests":8,"lastReport":' + $script:FirstVisitTestState.ReportJson + '}')
                            }
                            return ($script:FirstVisitTestState.PlanJson)
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
                        $phaseMatch = [regex]::Match([string]$Script, "-Phase '([^']+)'")
                        $stepMatch = [regex]::Match([string]$Script, "-Step '([^']+)'")
                        if (-not $stepMatch.Success) { return 'ok' }
                        $phase = $phaseMatch.Groups[1].Value
                        $step = $stepMatch.Groups[1].Value
                        $script:FirstVisitTestState.Calls.Add("InvokeGuestPowerShell:$phase/$step")
                        $responses = @{
                            'prepare/install'   = '{"status":"passed","body":{"state":{"install":{"ready":true}},"session":""}}'
                            'prepare/configure' = '{"status":"passed","body":{"state":{"registered":true},"session":""}}'
                            'prepare/warmup'    = '{"status":"passed","body":{"state":{"extension":{"found":true,"active":true},"closeAfterWarmup":{"forced":false}},"session":""}}'
                            'observe/session'   = '{"status":"passed","body":{"state":{"session":"alumno","sessionLogonAt":"2026-10-01T20:00:00.0000000Z"},"session":"alumno"}}'
                            'observe/visit'     = '{"status":"passed","body":{"state":{"launchedAt":"2026-10-01T20:00:30.0000000Z","firefox":[{"pid":3,"created":"2026-10-01T20:00:30.0000000Z"}]},"session":""}}'
                            'observe/collect'   = '{"status":"passed","body":{"state":{"collect":{"diagnosticSample":["stage=extension-diagnostic note=reloaded"],"startupProfiles":["stage=startup-profile processToScriptMs=6341 pingMs=2210 firstEnqueueMs=120"]}},"session":""}}'
                            'observe/security'  = '{"status":"passed","body":{"state":{"overlay":{"unexpected":[],"missing":[]}},"session":""}}'
                            'cleanup/cleanup'   = '{"status":"passed","body":{"state":{"clean":{"rootGone":true}},"session":""}}'
                        }
                        $key = "$phase/$step"
                        if (-not $responses.ContainsKey($key)) { throw "first-visit-fake-missing-$key" }
                        return ($responses[$key] + "`n__HARNESS_EXIT__=0")
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
                    firstVisit       = [pscustomobject]@{ scenario = $Scenario; repetition = 1; labScenario = 'win11-education-existing-empty' }
                }
            }
        }

        BeforeEach {
            $script:OpenPathFirstVisitCaptureOffsets = @(0)
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
            @($state.Calls) | Should -Contain 'InvokeGuestPowerShell:prepare/warmup'
            $result.observation.state.plan.anchors.a1.host | Should -Be 'anchor1-ab12cd.192.168.1.150.sslip.io'
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
}
