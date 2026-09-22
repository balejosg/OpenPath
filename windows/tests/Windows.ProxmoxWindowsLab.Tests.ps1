Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\controllers\ProxmoxWindowsLab.psm1') -Force

Describe 'Proxmox Windows lab controller' {
    BeforeAll {
        function New-OpenPathLabTestState {
    return [pscustomobject]@{
        Calls             = [System.Collections.Generic.List[string]]::new()
        LockAvailable     = $true
        BootId            = 'boot-1'
        RebootBootId      = 'boot-2'
        GuestHashesByLeaf = @{}
        ScreendumpResult  = $true
        HarnessResponses  = @{}
        RebootSequence    = @()
    }
}

function New-OpenPathLabTestTransport {
    return @{
        EnsureLock            = { param($LockFile, $Owner, $TtlSeconds) $script:LabState.Calls.Add('EnsureLock'); $script:LabState.LockAvailable }
        ReleaseLock           = { param($LockFile, $Owner) $script:LabState.Calls.Add('ReleaseLock'); $true }
        GetVmStatus           = { param($Vmid) $script:LabState.Calls.Add("GetVmStatus:$Vmid"); 'stopped' }
        StopVm                = { param($Vmid) $script:LabState.Calls.Add("StopVm:$Vmid") }
        StartVm               = { param($Vmid) $script:LabState.Calls.Add("StartVm:$Vmid") }
        RollbackVm            = { param($Vmid, $Snapshot) $script:LabState.Calls.Add("RollbackVm:${Vmid}:${Snapshot}") }
        WaitGuestReady        = { param($Vmid, $TimeoutSeconds) $script:LabState.Calls.Add("WaitGuestReady:$Vmid"); $true }
        GetGuestOsInfo        = {
            param($Vmid)
            $script:LabState.Calls.Add('GetGuestOsInfo')
            [pscustomobject]@{ productType = 'client'; editionId = 'Professional'; productName = 'Windows 11 Pro'; build = '26100'; architecture = 'x64' }
        }
        GetGuestBootId        = { param($Vmid) $script:LabState.Calls.Add('GetGuestBootId'); $script:LabState.BootId }
        RequestGuestReboot    = { param($Vmid) $script:LabState.Calls.Add('RequestGuestReboot') }
        WaitGuestRebooted     = {
            param($Vmid, $PreviousBootId, $TimeoutSeconds)
            $script:LabState.Calls.Add('WaitGuestRebooted')
            if ($script:LabState.RebootSequence -and @($script:LabState.RebootSequence).Count -gt 0) {
                $next = @($script:LabState.RebootSequence)[0]
                $script:LabState.RebootSequence = @(@($script:LabState.RebootSequence) | Select-Object -Skip 1)
                $script:LabState.BootId = $next
                return $next
            }
            $script:LabState.BootId = $script:LabState.RebootBootId
            $script:LabState.BootId
        }
        PublishArtifact       = {
            param($StagingDir, $LocalPath)
            $leaf = Split-Path -Leaf $LocalPath
            $script:LabState.Calls.Add("PublishArtifact:$leaf")
            [pscustomobject]@{ url = 'http://192.0.2.10:18080/' + $leaf }
        }
        RemoveHostStaging     = { param($StagingDir) $script:LabState.Calls.Add('RemoveHostStaging') }
        DownloadGuestArtifact = {
            param($Vmid, $Url, $GuestPath)
            $script:LabState.Calls.Add('DownloadGuestArtifact')
            $leaf = Split-Path -Leaf $Url
            if ($script:LabState.GuestHashesByLeaf.ContainsKey($leaf)) {
                $script:LabState.GuestHashesByLeaf[$GuestPath] = $script:LabState.GuestHashesByLeaf[$leaf]
            }
        }
        GetGuestFileSha256    = { param($Vmid, $GuestPath) $script:LabState.Calls.Add('GetGuestFileSha256'); $script:LabState.GuestHashesByLeaf[$GuestPath] }
        RemoveGuestStaging    = { param($Vmid, $GuestPath) $script:LabState.Calls.Add('RemoveGuestStaging'); $true }
        CaptureScreendump     = { param($Vmid, $LocalPath) $script:LabState.Calls.Add('CaptureScreendump'); $script:LabState.ScreendumpResult }
        InvokeGuestPowerShell = {
            param($Vmid, $Script, $TimeoutSeconds)
            $phaseMatch = [regex]::Match([string]$Script, "-Phase '([^']+)'")
            $stepMatch = [regex]::Match([string]$Script, "-Step '([^']+)'")
            $phase = if ($phaseMatch.Success) { $phaseMatch.Groups[1].Value } else { 'unknown' }
            $step = if ($stepMatch.Success) { $stepMatch.Groups[1].Value } else { 'unknown' }
            $key = "$phase/$step"
            $script:LabState.Calls.Add("InvokeGuestPowerShell:$key")
            if (-not $script:LabState.HarnessResponses.ContainsKey($key)) {
                throw "desktop-lab-guest-step-failed-$key-test-response-missing"
            }
            $response = $script:LabState.HarnessResponses[$key]
            $json = if ($response -is [string]) { $response } else { $response | ConvertTo-Json -Depth 20 -Compress }
            return ($json + "`n__HARNESS_EXIT__=0")
        }
    }
}

function New-OpenPathLabTestConfig {
    param([string]$Mode = 'transport-dry-run')
    return [pscustomobject]@{
        schemaVersion   = 1
        mode            = $Mode
        sshHost         = 'lab-host'
        sshCommand      = 'ssh'
        scpCommand      = 'scp'
        hostAddress     = '192.0.2.10'
        lockFile        = '/run/openpath-desktop-survival.lock'
        hostStagingRoot = '/var/tmp/openpath-desktop-survival'
        timeoutSeconds  = 60
        scenarios       = @{
            'win11-pro-profileless-empty' = [pscustomobject]@{
                vmid                  = 107
                baselineSnapshot      = 'base-snap'
                expectedEditionId     = 'Professional'
                initialProfileExisted = $false
            }
        }
    }
}

function New-OpenPathLabTestArtifacts {
    param([string]$Root)
    $template = Join-Path $Root 'template.exe'
    $personalized = Join-Path $Root 'personalized.exe'
    Set-Content -LiteralPath $template -Value 'template-bytes' -Encoding ASCII
    Set-Content -LiteralPath $personalized -Value 'personalized-bytes' -Encoding ASCII
    return [pscustomobject]@{
        Template     = $template
        Personalized = $personalized
        TemplateSha  = (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant()
        PersonalizedSha = (Get-FileHash -LiteralPath $personalized -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-OpenPathLabAcceptanceConfig {
    $config = New-OpenPathLabTestConfig -Mode 'acceptance'
    $config | Add-Member -NotePropertyName studentUserName -NotePropertyValue 'alumno' -Force
    $config | Add-Member -NotePropertyName adminUserName -NotePropertyValue 'opadmin' -Force
    $config | Add-Member -NotePropertyName guestSecret -NotePropertyValue 'LabTest!Secret1' -Force
    $config.scenarios['win11-pro-profileless-empty'] | Add-Member -NotePropertyName imageIdentity -NotePropertyValue 'win11-pro-25h2-base' -Force
    return $config
}

function New-OpenPathLabTestPayload {
    param(
        [string]$ArtifactsRoot,
        [string]$TemplatePath,
        [string]$PersonalizedExePath,
        [string]$Phase = 'prepare',
        [hashtable]$Overrides = @{}
    )
    $payload = [ordered]@{
        schemaVersion          = 2
        suiteKind              = 'DesktopSurvival'
        policyConverterMode    = ''
        runId                  = 'run-test'
        runAttempt             = 1
        scenarioId             = 'win11-pro-profileless-empty'
        phase                  = $Phase
        sourceCommitSha        = ('a' * 40)
        correlationNonce       = ('b' * 32)
        outputPath             = Join-Path $ArtifactsRoot "$Phase-observation.json"
        artifactsRoot          = $ArtifactsRoot
        templatePath           = $TemplatePath
        templateSha256         = (Get-FileHash -LiteralPath $TemplatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        personalizedExePath    = $PersonalizedExePath
        personalizedExeSha256  = (Get-FileHash -LiteralPath $PersonalizedExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    foreach ($key in $Overrides.Keys) { $payload[$key] = $Overrides[$key] }
    return [pscustomobject]$payload
}

function Write-OpenPathLabTestConfigFile {
    param([string]$Path, [object]$Config)
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}
    }

    BeforeEach {
        $script:LabState = New-OpenPathLabTestState
        Remove-Item -LiteralPath (Join-Path $TestDrive 'controller-state.json') -Force -ErrorAction SilentlyContinue
    }

    It 'reads and validates a lab configuration file' {
        $configPath = Join-Path $TestDrive 'lab-config.json'
        Write-OpenPathLabTestConfigFile -Path $configPath -Config (New-OpenPathLabTestConfig)
        $config = Read-OpenPathProxmoxLabConfig -Path $configPath
        $config.mode | Should -Be 'transport-dry-run'
        $config.scenarios.PSObject.Properties['win11-pro-profileless-empty'].Value.vmid | Should -Be 107
        $transport = New-OpenPathProxmoxLabTransport -Config $config
        foreach ($key in @('EnsureLock', 'ReleaseLock', 'GetVmStatus', 'StopVm', 'StartVm', 'RollbackVm', 'WaitGuestReady', 'GetGuestOsInfo', 'GetGuestBootId', 'RequestGuestReboot', 'WaitGuestRebooted', 'PublishArtifact', 'RemoveHostStaging', 'DownloadGuestArtifact', 'GetGuestFileSha256', 'RemoveGuestStaging', 'CaptureScreendump', 'InvokeGuestPowerShell')) {
            $transport.ContainsKey($key) | Should -BeTrue
        }
    }

    It 'rejects unsafe lab configuration values' {
        $configPath = Join-Path $TestDrive 'lab-config-bad-ssh.json'
        $config = New-OpenPathLabTestConfig
        $config.sshHost = 'lab-host; rm -rf /'
        Write-OpenPathLabTestConfigFile -Path $configPath -Config $config
        { Read-OpenPathProxmoxLabConfig -Path $configPath } | Should -Throw '*desktop-lab-config-invalid*'

        $configPath = Join-Path $TestDrive 'lab-config-bad-vmid.json'
        $config = New-OpenPathLabTestConfig
        $config.scenarios['win11-pro-profileless-empty'].vmid = 7
        Write-OpenPathLabTestConfigFile -Path $configPath -Config $config
        { Read-OpenPathProxmoxLabConfig -Path $configPath } | Should -Throw '*desktop-lab-config-invalid*'
    }

    It 'prepare runs the transport sequence and records a dry-run observation' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = $artifacts.TemplateSha; 'personalized.exe' = $artifacts.PersonalizedSha }
        $transport = New-OpenPathLabTestTransport
        $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport
        $result.status | Should -Be 'passed'
        $result.observation.dryRun | Should -BeTrue
        $result.observation.acceptanceEligible | Should -BeFalse
        $result.observation.bootIdBefore | Should -Be 'boot-1'
        $result.observation.artifacts.guestTemplateSha256 | Should -Be $artifacts.TemplateSha
        $calls = $script:LabState.Calls
        [array]::IndexOf($calls.ToArray(), 'EnsureLock') -lt [array]::IndexOf($calls.ToArray(), 'RollbackVm:107:base-snap') | Should -BeTrue
        [array]::IndexOf($calls.ToArray(), 'RollbackVm:107:base-snap') -lt [array]::IndexOf($calls.ToArray(), 'StartVm:107') | Should -BeTrue
        $calls.Contains('PublishArtifact:template.exe') | Should -BeTrue
        $calls.Contains('PublishArtifact:personalized.exe') | Should -BeTrue
        $calls.Contains('ReleaseLock') | Should -BeTrue
        $statePath = Join-Path $TestDrive 'controller-state.json'
        (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -BeTrue
        (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).phase | Should -Be 'prepared'
    }

    It 'compares boot ids stored as ISO timestamps without culture drift' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = $artifacts.TemplateSha; 'personalized.exe' = $artifacts.PersonalizedSha }
        $script:LabState.BootId = '2026-09-20T15:26:50.5000000Z'
        $script:LabState.RebootBootId = '2026-09-20T16:00:00.0000000Z'
        $transport = New-OpenPathLabTestTransport
        Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport | Out-Null
        $observed = Invoke-OpenPathProxmoxControllerPhase -Payload (New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'observe') -Config (New-OpenPathLabTestConfig) -Transport $transport
        $observed.status | Should -Be 'passed'
        $observed.observation.bootIdBefore | Should -Be '2026-09-20T15:26:50.5000000Z'
        $result = Invoke-OpenPathProxmoxControllerPhase -Payload (New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'afterReboot') -Config (New-OpenPathLabTestConfig) -Transport $transport
        $result.status | Should -Be 'passed'
        ([datetime]$result.observation.bootIdBefore).ToUniversalTime().ToString('o') | Should -Be '2026-09-20T15:26:50.5000000Z'
        ([datetime]$result.observation.bootIdAfter).ToUniversalTime().ToString('o') | Should -Be '2026-09-20T16:00:00.0000000Z'
        $result.observation.bootIdChanged | Should -BeTrue
    }

    It 'leaves the snapshot chain untouched when baseline restore is disabled' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = $artifacts.TemplateSha; 'personalized.exe' = $artifacts.PersonalizedSha }
        $transport = New-OpenPathLabTestTransport
        $config = New-OpenPathLabTestConfig
        $config | Add-Member -NotePropertyName 'restoreBaseline' -NotePropertyValue $false
        $result = Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config $config -Transport $transport
        $result.status | Should -Be 'passed'
        $script:LabState.Calls.Contains('RollbackVm:107:base-snap') | Should -BeFalse
        $cleanupPayload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'cleanup'
        $cleanup = Invoke-OpenPathProxmoxControllerPhase -Payload $cleanupPayload -Config $config -Transport $transport
        $cleanup.status | Should -Be 'passed'
        $cleanup.observation.cleanup.rolledBack | Should -BeFalse
        $script:LabState.Calls.Contains('RollbackVm:107:base-snap') | Should -BeFalse
    }

    It 'prepare fails closed and releases the lock when the guest artifact hash differs' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = ('f' * 64); 'personalized.exe' = $artifacts.PersonalizedSha }
        $transport = New-OpenPathLabTestTransport
        { Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-guest-artifact-hash-mismatch*'
        $script:LabState.Calls.Contains('ReleaseLock') | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $TestDrive 'controller-state.json')) | Should -BeFalse
    }

    It 'prepare rejects a busy lab lock before touching the VM' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.LockAvailable = $false
        $transport = New-OpenPathLabTestTransport
        { Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-lock-busy*'
        $script:LabState.Calls.Contains('RollbackVm:107:base-snap') | Should -BeFalse
    }

    It 'prepare rejects artifact bytes that do not match the payload identity before mutating the VM' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Overrides @{ templateSha256 = ('0' * 64) }
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = $artifacts.TemplateSha; 'personalized.exe' = $artifacts.PersonalizedSha }
        $transport = New-OpenPathLabTestTransport
        { Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-artifact-hash-mismatch*'
        $script:LabState.Calls.Contains('StopVm:107') | Should -BeFalse
        $script:LabState.Calls.Contains('ReleaseLock') | Should -BeTrue
    }

    It 'prepare rejects a payload without artifact identity' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Overrides @{ templateSha256 = '' }
        $transport = New-OpenPathLabTestTransport
        { Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-artifact-identity-missing*'
    }

    It 'rejects an unmapped scenario and an unsupported lab mode' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Overrides @{ scenarioId = 'win11-unknown-scenario' }
        $transport = New-OpenPathLabTestTransport
        { Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-scenario-unmapped*'

        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        { Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig -Mode 'unsupported-mode') -Transport $transport } |
            Should -Throw '*desktop-lab-acceptance-not-implemented*'
    }

    It 'observe requires the prepared state and an unchanged boot id' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = $artifacts.TemplateSha; 'personalized.exe' = $artifacts.PersonalizedSha }
        $transport = New-OpenPathLabTestTransport
        $observePayload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'observe'
        { Invoke-OpenPathProxmoxControllerPhase -Payload $observePayload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-state-missing*'

        Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport | Out-Null
        $script:LabState.BootId = 'boot-drifted'
        { Invoke-OpenPathProxmoxControllerPhase -Payload $observePayload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-boot-id-drift*'

        $script:LabState.BootId = 'boot-1'
        $observed = Invoke-OpenPathProxmoxControllerPhase -Payload $observePayload -Config (New-OpenPathLabTestConfig) -Transport $transport
        $observed.observation.checks.guestReady | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $TestDrive 'controller-state.json') -Raw | ConvertFrom-Json).phase | Should -Be 'observed'
    }

    It 'afterReboot requires the observed state and a different boot id' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = $artifacts.TemplateSha; 'personalized.exe' = $artifacts.PersonalizedSha }
        $transport = New-OpenPathLabTestTransport
        $afterRebootPayload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'afterReboot'
        { Invoke-OpenPathProxmoxControllerPhase -Payload $afterRebootPayload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-state-missing*'

        Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport | Out-Null
        { Invoke-OpenPathProxmoxControllerPhase -Payload $afterRebootPayload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-state-not-observed*'

        Invoke-OpenPathProxmoxControllerPhase -Payload (New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'observe') -Config (New-OpenPathLabTestConfig) -Transport $transport | Out-Null
        $result = Invoke-OpenPathProxmoxControllerPhase -Payload $afterRebootPayload -Config (New-OpenPathLabTestConfig) -Transport $transport
        $result.observation.bootIdBefore | Should -Be 'boot-1'
        $result.observation.bootIdAfter | Should -Be 'boot-2'
        $result.observation.bootIdChanged | Should -BeTrue
        $script:LabState.Calls.Contains('CaptureScreendump') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $TestDrive 'controller-state.json') -Raw | ConvertFrom-Json).phase | Should -Be 'afterReboot'

        $stateFile = Join-Path $TestDrive 'controller-state.json'
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $state.phase = 'observed'
        $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding UTF8
        $script:LabState.BootId = 'boot-1'
        $script:LabState.RebootBootId = 'boot-1'
        { Invoke-OpenPathProxmoxControllerPhase -Payload $afterRebootPayload -Config (New-OpenPathLabTestConfig) -Transport $transport } |
            Should -Throw '*desktop-lab-boot-id-unchanged*'
    }

    It 'cleanup is idempotent, restores the baseline and removes the run state' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $script:LabState.GuestHashesByLeaf = @{ 'template.exe' = $artifacts.TemplateSha; 'personalized.exe' = $artifacts.PersonalizedSha }
        $transport = New-OpenPathLabTestTransport
        Invoke-OpenPathProxmoxControllerPhase -Payload $payload -Config (New-OpenPathLabTestConfig) -Transport $transport | Out-Null
        $cleanupPayload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'cleanup'
        $result = Invoke-OpenPathProxmoxControllerPhase -Payload $cleanupPayload -Config (New-OpenPathLabTestConfig) -Transport $transport
        $result.status | Should -Be 'passed'
        $script:LabState.Calls.Contains('RemoveHostStaging') | Should -BeTrue
        $script:LabState.Calls.Contains('RollbackVm:107:base-snap') | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $TestDrive 'controller-state.json')) | Should -BeFalse

        $second = Invoke-OpenPathProxmoxControllerPhase -Payload $cleanupPayload -Config (New-OpenPathLabTestConfig) -Transport $transport
        $second.status | Should -Be 'passed'
        $second.observation.cleanup.statePresent | Should -BeFalse
        $script:LabState.Calls.Contains('ReleaseLock') | Should -BeTrue
    }

    It 'acceptance mode runs the matrix step sequence and emits release-eligible evidence' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $harnessSource = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\desktop-survival\Invoke-OpenPathDesktopSurvivalGuest.ps1')).Path
        $harnessHash = (Get-FileHash -LiteralPath $harnessSource -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:LabState.GuestHashesByLeaf = @{
            'template.exe'                             = $artifacts.TemplateSha
            'personalized.exe'                         = $artifacts.PersonalizedSha
            'Invoke-OpenPathDesktopSurvivalGuest.ps1'  = $harnessHash
        }
        $script:LabState.RebootSequence = @('boot-2', 'boot-3', 'boot-4', 'boot-5', 'boot-6')
        $probes = @{
            probes                    = @{
                allowedBrowser   = @{ expected = 'allowed'; ran = $true }
                allowedSystemExe = @{ expected = 'allowed'; ran = $true }
                deniedBrowser    = @{ expected = 'denied'; ran = $false }
                deniedUserExe    = @{ expected = 'denied'; ran = $false }
                deniedScript     = @{ expected = 'denied'; ran = $false }
                deniedMsi        = @{ expected = 'denied'; ran = $false }
                packagedApp      = @{ expected = 'denied'; ran = $false }
            }
            fixtures                  = @{ exeAndDll = 'passed'; msiAndScript = 'passed'; packagedAppExecution = 'passed' }
            criticalUnexpectedDenials = @()
        }
        $script:LabState.HarnessResponses = @{
            'prepare/install'             = @{ status = 'passed'; failures = @(); body = @{ state = @{
                policyBeforeSha256      = ('c' * 64)
                policyAfterSha256       = ('d' * 64)
                initialProfileExisted   = $false
                catalogApplicationCount = 0
                installSummary          = @{ exitCode = 0; seconds = 12.5 }
                config                  = @{ appControlProfile = 'StrictApplicationAllowlist'; appControlCommitState = 'committed'; installState = 'complete' }
                groupMembers            = @('OP-LAB\alumno')
                tasks                   = @('OpenPath-Watchdog')
                uninstaller             = $true
            } } }
            'observe/admin-autologon'     = @{ status = 'passed'; failures = @(); body = @{ autologon = 'opadmin' } }
            'observe/admin-verify'        = @{ status = 'passed'; failures = @(); body = @{ session = 'OP-LAB\opadmin' } }
            'observe/student-autologon'   = @{ status = 'passed'; failures = @(); body = @{ autologon = 'alumno' } }
            'observe/student-verify'      = @{ status = 'passed'; failures = @(); body = @{ session = 'OP-LAB\alumno'; firstStudentInteractiveLogon = $true; studentLogons = @(@{ logonType = '2'; user = 'alumno' }) } }
            'observe/boundary'            = @{ status = 'passed'; failures = @(); body = $probes }
            'afterReboot/login-screen'    = @{ status = 'passed'; failures = @(); body = @{ autologon = 'cleared' } }
            'afterReboot/admin-autologon' = @{ status = 'passed'; failures = @(); body = @{ autologon = 'opadmin' } }
            'afterReboot/admin-verify'    = @{ status = 'passed'; failures = @(); body = @{ session = 'OP-LAB\opadmin' } }
            'afterReboot/student-autologon' = @{ status = 'passed'; failures = @(); body = @{ autologon = 'alumno' } }
            'afterReboot/student-verify'  = @{ status = 'passed'; failures = @(); body = @{ session = 'OP-LAB\alumno' } }
            'afterReboot/boundary'        = @{ status = 'passed'; failures = @(); body = $probes }
            'cleanup/uninstall'           = @{ status = 'passed'; failures = @(); body = @{ state = @{ uninstallFailed = $false; uninstallExitCode = 0 } } }
            'cleanup/verify-clean'        = @{ status = 'passed'; failures = @(); body = @{ clean = $true; policyEqualsBefore = $true } }
        }
        $transport = New-OpenPathLabTestTransport
        $config = New-OpenPathLabAcceptanceConfig
        $prepare = Invoke-OpenPathProxmoxControllerPhase -Payload (New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'prepare') -Config $config -Transport $transport
        $prepare.status | Should -Be 'passed'
        $prepare.synthetic | Should -BeFalse
        $prepare.observation.state.installSummary.exitCode | Should -Be 0
        $prepare.observation.guestState.policyAfterSha256 | Should -Be ('d' * 64)
        $observe = Invoke-OpenPathProxmoxControllerPhase -Payload (New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'observe') -Config $config -Transport $transport
        $observe.status | Should -Be 'passed'
        $observe.observation.firstStudentInteractiveLogon.session | Should -Be 'OP-LAB\alumno'
        $afterReboot = Invoke-OpenPathProxmoxControllerPhase -Payload (New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'afterReboot') -Config $config -Transport $transport
        $afterReboot.status | Should -Be 'passed'
        $cleanup = Invoke-OpenPathProxmoxControllerPhase -Payload (New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized -Phase 'cleanup') -Config $config -Transport $transport
        $cleanup.status | Should -Be 'passed'
        $cleanup.synthetic | Should -BeFalse
        $cleanup.scenario.sourceCommitSha | Should -Be ('a' * 40)
        $cleanup.scenario.appControlProfile | Should -Be 'StrictApplicationAllowlist'
        $cleanup.scenario.catalogApplicationCount | Should -Be 0
        $cleanup.scenario.bootIdBefore | Should -Not -Be $cleanup.scenario.bootIdAfter
        $cleanup.scenario.fixtures.exeAndDll | Should -Be 'passed'
        $cleanup.scenario.fixtures.msiAndScript | Should -Be 'passed'
        $cleanup.scenario.fixtures.packagedAppExecution | Should -Be 'passed'
        $cleanup.scenario.criticalUnexpectedDenials.Count | Should -Be 0
        foreach ($name in @('preRebootAdminDesktop', 'firstStudentInteractiveLogon', 'preRebootStudentBoundary', 'loginScreenAfterReboot', 'postRebootAdminDesktop', 'postRebootStudentDesktop', 'postRebootStudentBoundary', 'uninstallOrRollback', 'cleanup')) {
            $cleanup.scenario.observations.$name | Should -Be 'passed'
        }
        $calls = $script:LabState.Calls
        $calls.Contains('PublishArtifact:Invoke-OpenPathDesktopSurvivalGuest.ps1') | Should -BeTrue
        foreach ($key in @('prepare/install', 'observe/admin-verify', 'observe/student-verify', 'observe/boundary', 'afterReboot/login-screen', 'afterReboot/admin-verify', 'afterReboot/student-verify', 'afterReboot/boundary', 'cleanup/uninstall', 'cleanup/verify-clean')) {
            $calls.Contains("InvokeGuestPowerShell:$key") | Should -BeTrue
        }
        $calls.Contains('ReleaseLock') | Should -BeTrue
    }

    It 'CLI writes a correlated blocked observation and exits 2 when the lab config is missing' {
        $artifacts = New-OpenPathLabTestArtifacts -Root $TestDrive
        $payload = New-OpenPathLabTestPayload -ArtifactsRoot $TestDrive -TemplatePath $artifacts.Template -PersonalizedExePath $artifacts.Personalized
        $payloadPath = Join-Path $TestDrive 'cli-payload.json'
        $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $payloadPath -Encoding UTF8
        $missingConfig = Join-Path $TestDrive 'missing-lab-config.json'
        $cli = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\controllers\proxmox-disposable-windows-controller.ps1')).Path
        $outputPath = Join-Path $TestDrive 'prepare-observation.json'
        $env:OPENPATH_DESKTOP_LAB_CONFIG = $missingConfig
        try {
            & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File $cli -PayloadPath $payloadPath -OutputPath $outputPath -Mode Prepare -RunId run-test -RunAttempt 1 -ScenarioId win11-pro-profileless-empty -CorrelationNonce ('b' * 32) | Out-Null
            $LASTEXITCODE | Should -Be 2
        }
        finally {
            Remove-Item Env:OPENPATH_DESKTOP_LAB_CONFIG -ErrorAction SilentlyContinue
        }
        $blocked = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $blocked.status | Should -Be 'blocked'
        $blocked.correlationNonce | Should -Be ('b' * 32)
    }
}
