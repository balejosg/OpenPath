[CmdletBinding()]
param(
    [ValidateSet('Disabled', 'Enabled')][string]$Mode = 'Disabled',
    [string]$ExecutablePath = '',
    [string]$ProbePayloadPath = '',
    [string]$ExpectedExecutableSha256 = '',
    [string]$ExpectedProbePayloadSha256 = '',
    [string]$ChildEvidencePath = '',
    [string]$EvidencePath = '',
    [string]$TargetUserName = 'op-e2e-converter'
)

$ErrorActionPreference = 'Stop'

function Get-OpenPathContrastPolicySnapshot {
    $now = Get-Date
    Get-OpenPathEnforcementObserverSnapshot -Phase before-launch -WindowStart $now -WindowEnd $now
}

function Get-OpenPathContrastHostContext {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $bootTime = [datetime]$operatingSystem.LastBootUpTime
    [pscustomobject][ordered]@{
        hostedRunner = $env:GITHUB_ACTIONS -eq 'true'
        runnerEnvironment = $env:RUNNER_ENVIRONMENT
        imageOS = $env:ImageOS
        imageVersion = $env:ImageVersion
        bootTimeUtc = $bootTime.ToUniversalTime().ToString('o')
    }
}

function Write-OpenPathContrastEvidence {
    param([object]$Payload,[string]$Path)
    Write-OpenPathOfflineInstallerEvidence -Payload $Payload -Path $Path
}

function Get-OpenPathContrastSnapshotSafe {
    param([Parameter(Mandatory=$true)][string]$Context)
    try { return Get-OpenPathDisposablePolicyConverterObservation -Context $Context }
    catch {
        return [pscustomobject][ordered]@{ status='unavailable'; context=$Context; reason='policy-converter-observer-failed'; capturedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); runtime=$null; task=$null; taskInfo=$null; service=$null; process=$null }
    }
}

function Start-OpenPathContrastProcess {
    param([string]$FilePath,[object[]]$ArgumentList,[string]$StandardOutputPath,[string]$StandardErrorPath)
    Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -RedirectStandardOutput $StandardOutputPath -RedirectStandardError $StandardErrorPath -Wait -PassThru
}

function Invoke-OpenPathEncodedContrastChild {
    param([string]$HarnessPath,[string]$ExecutablePath,[string]$ProbePayloadPath,[string]$ChildEvidencePath,[string]$TargetUserName)
    $shell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)
    if (-not $shell) { $shell = Get-Command pwsh -ErrorAction Stop }
    $privateRoot = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-policy-converter-private-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
    $stdoutPath = Join-Path $privateRoot 'child.stdout.log'
    $stderrPath = Join-Path $privateRoot 'child.stderr.log'
    $environmentNames = @('OPENPATH_CONTRAST_HARNESS','OPENPATH_CONTRAST_EXECUTABLE','OPENPATH_CONTRAST_PROBE','OPENPATH_CONTRAST_CHILD_EVIDENCE','OPENPATH_CONTRAST_TARGET_USER')
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:OPENPATH_CONTRAST_HARNESS = $HarnessPath
        $env:OPENPATH_CONTRAST_EXECUTABLE = $ExecutablePath
        $env:OPENPATH_CONTRAST_PROBE = $ProbePayloadPath
        $env:OPENPATH_CONTRAST_CHILD_EVIDENCE = $ChildEvidencePath
        $env:OPENPATH_CONTRAST_TARGET_USER = $TargetUserName
        $command = "& `$env:OPENPATH_CONTRAST_HARNESS -ExecutablePath `$env:OPENPATH_CONTRAST_EXECUTABLE -ExpectedClassroomId 'release-e2e-classroom' -ExpectedApiUrl 'https://localhost:18443' -EvidencePath `$env:OPENPATH_CONTRAST_CHILD_EVIDENCE -ProbePayloadPath `$env:OPENPATH_CONTRAST_PROBE -TargetUserName `$env:OPENPATH_CONTRAST_TARGET_USER; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
        $process = Start-OpenPathContrastProcess -FilePath $shell.Source -ArgumentList $arguments -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        return [pscustomobject][ordered]@{ exitCode=[int]$process.ExitCode; evidenceAvailable=(Test-Path -LiteralPath $ChildEvidencePath -PathType Leaf); privateOutputRoot=$privateRoot }
    }
    finally {
        foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
    }
}

function Invoke-OpenPathContrastChild {
    param([string]$ExecutablePath,[string]$ProbePayloadPath,[string]$ChildEvidencePath,[string]$TargetUserName)
    Invoke-OpenPathEncodedContrastChild -HarnessPath (Join-Path $PSScriptRoot 'run-windows-offline-installer-exe.ps1') @PSBoundParameters
}

function Invoke-OpenPathPolicyConverterContrast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Disabled','Enabled')][string]$Mode,
        [Parameter(Mandatory=$true)][string]$ExecutablePath,
        [Parameter(Mandatory=$true)][string]$ProbePayloadPath,
        [Parameter(Mandatory=$true)][string]$ExpectedExecutableSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedProbePayloadSha256,
        [Parameter(Mandatory=$true)][string]$ChildEvidencePath,
        [Parameter(Mandatory=$true)][string]$EvidencePath,
        [string]$TargetUserName = 'op-e2e-converter'
    )
    $startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $actualExecutableSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash
    $actualProbePayloadSha256 = (Get-FileHash -LiteralPath $ProbePayloadPath -Algorithm SHA256).Hash
    $hostContext = Get-OpenPathContrastHostContext
    $policyBefore = $null
    $before = $null
    $after = $null
    $afterChild = $null
    $afterRestoration = $null
    $child = $null
    $interventionAttempted = $false
    $restorationAttempted = $false
    $restorationSucceeded = $null
    $status = 'observed'
    $code = $null
    try {
        if (-not $hostContext.hostedRunner -or $hostContext.runnerEnvironment -ne 'github-hosted') {
            $status='baseline-not-comparable'; $code='github-hosted-runner-required'
        }
        elseif ($actualExecutableSha256 -ne $ExpectedExecutableSha256 -or $actualProbePayloadSha256 -ne $ExpectedProbePayloadSha256) {
            $status='baseline-not-comparable'; $code='contrast-input-hash-mismatch'
        }
        else {
            # Capture policy first because the observer itself can initialize AppLocker providers.
            $policyBefore = Get-OpenPathContrastPolicySnapshot
            $before = Get-OpenPathContrastSnapshotSafe -Context 'contrast-before-intervention'
            $cold = $before.status -eq 'observed' -and $before.task.queryStatus -eq 'observed' -and $before.task.exists -eq $true -and $null -ne $before.task.enabled -and $before.task.enabled -eq $false -and $before.service.queryStatus -eq 'observed' -and $before.service.state -eq 'Stopped' -and $null -ne $before.service.processId -and [int]$before.service.processId -eq 0
            if (-not $cold) { $status='baseline-not-comparable'; $code='cold-baseline-not-observed' }
            else {
                if ($Mode -eq 'Enabled') {
                    $interventionAttempted = $true
                    try { Enable-ScheduledTask -TaskName 'PolicyConverter' -TaskPath '\Microsoft\Windows\AppID\' -ErrorAction Stop | Out-Null }
                    catch { $status='intervention-failed'; $code='policy-converter-enable-failed' }
                }
                if ($status -eq 'observed') {
                    $after = Get-OpenPathContrastSnapshotSafe -Context 'contrast-after-intervention'
                    $expectedEnabled = $Mode -eq 'Enabled'
                    if ($after.task.queryStatus -ne 'observed' -or $null -eq $after.task.enabled -or $after.task.enabled -ne $expectedEnabled) { $status='intervention-failed'; $code='policy-converter-state-not-observed' }
                    else {
                        try { $child = Invoke-OpenPathContrastChild -ExecutablePath $ExecutablePath -ProbePayloadPath $ProbePayloadPath -ChildEvidencePath $ChildEvidencePath -TargetUserName $TargetUserName }
                        catch { $status='child-evidence-unavailable'; $code='child-launch-failed' }
                        if ($child -and -not $child.evidenceAvailable) { $status='child-evidence-unavailable'; $code='child-evidence-missing' }
                    }
                }
            }
        }
    }
    finally {
        if ($before) { $afterChild = Get-OpenPathContrastSnapshotSafe -Context 'contrast-after-child' }
        if ($Mode -eq 'Enabled' -and $interventionAttempted) {
            $restorationAttempted = $true
            try { Disable-ScheduledTask -TaskName 'PolicyConverter' -TaskPath '\Microsoft\Windows\AppID\' -ErrorAction Stop | Out-Null; $restorationSucceeded=$true }
            catch { $restorationSucceeded=$false }
        }
        if ($before) { $afterRestoration = Get-OpenPathContrastSnapshotSafe -Context 'contrast-after-restoration' }
        if ($restorationAttempted -and ($afterRestoration.status -ne 'observed' -or $afterRestoration.task.queryStatus -ne 'observed' -or $null -eq $afterRestoration.task.enabled -or $afterRestoration.task.enabled -ne $false)) { $restorationSucceeded=$false }
        $result = [pscustomobject][ordered]@{
            schemaVersion=1; status=$status; code=$code; mode=$Mode; startedAtUtc=$startedAtUtc; endedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
            hostedRunner=$hostContext.hostedRunner; runnerEnvironment=$hostContext.runnerEnvironment; imageOS=$hostContext.imageOS; imageVersion=$hostContext.imageVersion; bootTimeUtc=$hostContext.bootTimeUtc
            inputs=[pscustomobject][ordered]@{ executableSha256=$actualExecutableSha256; expectedExecutableSha256=$ExpectedExecutableSha256; probePayloadSha256=$actualProbePayloadSha256; expectedProbePayloadSha256=$ExpectedProbePayloadSha256; targetUserName=$TargetUserName }
            policyBeforeIntervention=$policyBefore; snapshots=[pscustomobject][ordered]@{ beforeIntervention=$before; afterIntervention=$after; afterChild=$afterChild; afterRestoration=$afterRestoration }
            intervention=[pscustomobject][ordered]@{ attempted=$interventionAttempted; action=if($Mode -eq 'Enabled'){'enable'}else{'none'} }
            childExitCode=if($child){$child.exitCode}else{$null}; childEvidenceAvailable=if($child){$child.evidenceAvailable}else{$false}
            restoration=[pscustomobject][ordered]@{ attempted=$restorationAttempted; succeeded=$restorationSucceeded; initialEnabled=if($before){$before.task.enabled}else{$null} }
        }
        Write-OpenPathContrastEvidence -Payload $result -Path $EvidencePath
    }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    Import-Module (Join-Path $PSScriptRoot 'BrowserBoundaryProbe.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'DisposableWindowsTarget.psm1') -Force -ErrorAction Stop
    $result = Invoke-OpenPathPolicyConverterContrast @PSBoundParameters
    $result | Select-Object status,code,mode,childExitCode,childEvidenceAvailable | ConvertTo-Json -Compress
}
