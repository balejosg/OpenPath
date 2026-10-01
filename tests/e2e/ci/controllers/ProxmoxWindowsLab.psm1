<##
.SYNOPSIS
    Proxmox-backed disposable Windows lab transport for desktop-survival qualification.
.DESCRIPTION
    Phase 1 (transport dry-run) of the external disposable-Windows controller
    contract. The orchestrator is transport-injectable so unit tests never touch
    a hypervisor, while the real transport drives Proxmox over SSH, QEMU Guest
    Agent, HTTP staging for exact artifacts and the QEMU monitor for console
    screendumps. Acceptance qualification stays blocked until the real
    Pro/Education matrix and interactive probes exist; this module never emits
    acceptance-eligible metadata.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OpenPathLabBlockedErrorCodes = @(
    'desktop-lab-config-missing',
    'desktop-lab-config-invalid',
    'desktop-lab-scenario-unmapped',
    'desktop-lab-acceptance-not-implemented',
    'desktop-lab-transport-invalid',
    'desktop-lab-transport-unavailable',
    'first-visit-requires-acceptance-lab-config',
    'first-visit-fixture-plan-unavailable',
    'first-visit-dns-fixture-unavailable',
    'first-visit-fixture-served-no-requests'
)

$script:OpenPathLabRequiredTransportKeys = @(
    'EnsureLock', 'UpdateLockHeartbeat', 'ReleaseLock', 'InvokeHostCommand', 'CopyFileToHost', 'GetVmStatus', 'StopVm', 'StartVm', 'RollbackVm',
    'WaitGuestReady', 'GetGuestOsInfo', 'GetGuestBootId', 'RequestGuestReboot',
    'WaitGuestRebooted', 'PublishArtifact', 'RemoveHostStaging', 'DownloadGuestArtifact',
    'GetGuestFileSha256', 'RemoveGuestStaging', 'CaptureScreendump', 'InvokeGuestPowerShell'
)

# Phase 3A first-visit lane (shares this module scope).
. (Join-Path $PSScriptRoot 'ProxmoxFirstVisit.ps1')

function Test-OpenPathLabBlockedErrorCode {
    param([Parameter(Mandatory = $true)][string]$Code)
    return $script:OpenPathLabBlockedErrorCodes -contains $Code
}

function Get-OpenPathLabField {
    param([Parameter(Mandatory = $true)][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-OpenPathLabRequiredField {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Code
    )
    $value = Get-OpenPathLabField -InputObject $InputObject -Name $Name
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { throw $Code }
    return [string]$value
}

function Assert-OpenPathLabSafeSegment {
    param([string]$Value, [string]$Code = 'desktop-lab-config-invalid')
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw $Code }
}

function Assert-OpenPathLabAbsolutePosixPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^/[A-Za-z0-9._/-]+$') { throw 'desktop-lab-config-invalid' }
    if ($Value -match '(^|/)\.\.(/|$)') { throw 'desktop-lab-config-invalid' }
}

function Assert-OpenPathLabHostName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$') { throw 'desktop-lab-config-invalid' }
}

function Read-OpenPathProxmoxLabConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'desktop-lab-config-missing' }
    try { $config = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'desktop-lab-config-invalid' }
    if ([int](Get-OpenPathLabField -InputObject $config -Name 'schemaVersion') -ne 1) { throw 'desktop-lab-config-invalid' }
    $mode = [string](Get-OpenPathLabRequiredField -InputObject $config -Name 'mode' -Code 'desktop-lab-config-invalid')
    if ($mode -notin @('transport-dry-run', 'acceptance')) { throw 'desktop-lab-config-invalid' }
    Assert-OpenPathLabHostName -Value ([string](Get-OpenPathLabRequiredField -InputObject $config -Name 'sshHost' -Code 'desktop-lab-config-invalid'))
    Assert-OpenPathLabHostName -Value ([string](Get-OpenPathLabRequiredField -InputObject $config -Name 'hostAddress' -Code 'desktop-lab-config-invalid'))
    foreach ($name in @('sshCommand', 'scpCommand')) {
        $value = [string](Get-OpenPathLabRequiredField -InputObject $config -Name $name -Code 'desktop-lab-config-invalid')
        if ($value -notmatch '^[A-Za-z0-9._/-]+$') { throw 'desktop-lab-config-invalid' }
    }
    Assert-OpenPathLabAbsolutePosixPath -Value ([string](Get-OpenPathLabRequiredField -InputObject $config -Name 'lockFile' -Code 'desktop-lab-config-invalid'))
    Assert-OpenPathLabAbsolutePosixPath -Value ([string](Get-OpenPathLabRequiredField -InputObject $config -Name 'hostStagingRoot' -Code 'desktop-lab-config-invalid'))
    $timeoutValue = Get-OpenPathLabField -InputObject $config -Name 'timeoutSeconds'
    if ($null -ne $timeoutValue) {
        $timeout = 0
        if (-not [int]::TryParse([string]$timeoutValue, [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 86400) { throw 'desktop-lab-config-invalid' }
    }
    $httpPortValue = Get-OpenPathLabField -InputObject $config -Name 'httpPort'
    if ($null -ne $httpPortValue) {
        $httpPort = 0
        if (-not [int]::TryParse([string]$httpPortValue, [ref]$httpPort) -or $httpPort -lt 1024 -or $httpPort -gt 65535) { throw 'desktop-lab-config-invalid' }
    }
    $restoreBaselineValue = Get-OpenPathLabField -InputObject $config -Name 'restoreBaseline'
    if ($null -ne $restoreBaselineValue -and $restoreBaselineValue -isnot [bool]) { throw 'desktop-lab-config-invalid' }
    $scenarios = Get-OpenPathLabField -InputObject $config -Name 'scenarios'
    if ($null -eq $scenarios) { throw 'desktop-lab-config-invalid' }
    $scenarioProperties = @($scenarios.PSObject.Properties)
    if ($scenarioProperties.Count -lt 1) { throw 'desktop-lab-config-invalid' }
    foreach ($scenarioProperty in $scenarioProperties) {
        Assert-OpenPathLabSafeSegment -Value ([string]$scenarioProperty.Name)
        $scenario = $scenarioProperty.Value
        $vmid = 0
        if (-not [int]::TryParse([string](Get-OpenPathLabField -InputObject $scenario -Name 'vmid'), [ref]$vmid) -or $vmid -lt 100 -or $vmid -gt 999999) { throw 'desktop-lab-config-invalid' }
        Assert-OpenPathLabSafeSegment -Value ([string](Get-OpenPathLabRequiredField -InputObject $scenario -Name 'baselineSnapshot' -Code 'desktop-lab-config-invalid'))
        Assert-OpenPathLabSafeSegment -Value ([string](Get-OpenPathLabRequiredField -InputObject $scenario -Name 'expectedEditionId' -Code 'desktop-lab-config-invalid'))
        $initialProfile = Get-OpenPathLabField -InputObject $scenario -Name 'initialProfileExisted'
        if ($null -eq $initialProfile) { throw 'desktop-lab-config-invalid' }
    }
    return $config
}

function Get-OpenPathLabScenario {
    param([Parameter(Mandatory = $true)][object]$Config, [Parameter(Mandatory = $true)][string]$ScenarioId)
    $scenarios = Get-OpenPathLabField -InputObject $Config -Name 'scenarios'
    if ($null -eq $scenarios) { throw 'desktop-lab-config-invalid' }
    $scenario = Get-OpenPathLabField -InputObject $scenarios -Name $ScenarioId
    if ($null -eq $scenario) { throw 'desktop-lab-scenario-unmapped' }
    return $scenario
}

function Get-OpenPathLabPaths {
    param([Parameter(Mandatory = $true)][object]$Payload, [Parameter(Mandatory = $true)][object]$Config)
    $runId = Get-OpenPathLabRequiredField -InputObject $Payload -Name 'runId' -Code 'desktop-lab-payload-invalid'
    $runAttempt = [int](Get-OpenPathLabField -InputObject $Payload -Name 'runAttempt')
    $scenarioId = Get-OpenPathLabRequiredField -InputObject $Payload -Name 'scenarioId' -Code 'desktop-lab-payload-invalid'
    $segment = "$runId-$runAttempt-$scenarioId"
    return [pscustomobject]@{
        Segment    = $segment
        StagingDir = ([string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot')).TrimEnd('/') + '/' + $segment
        GuestDir   = 'C:\Windows\Temp\openpath-desktop-survival\' + $segment
    }
}

function Get-OpenPathLabArtifactSpecs {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][string]$GuestDir
    )
    $specs = @()
    foreach ($pair in @(
            @{ PathKey = 'templatePath'; HashKey = 'templateSha256'; GuestName = 'template.exe' },
            @{ PathKey = 'personalizedExePath'; HashKey = 'personalizedExeSha256'; GuestName = 'personalized.exe' }
        )) {
        $path = [string](Get-OpenPathLabField -InputObject $Payload -Name $pair.PathKey)
        $hash = [string](Get-OpenPathLabField -InputObject $Payload -Name $pair.HashKey)
        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($hash) -or $hash -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'desktop-lab-artifact-identity-missing'
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'desktop-lab-artifact-missing' }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actual, $hash.ToLowerInvariant(), [System.StringComparison]::Ordinal)) {
            throw 'desktop-lab-artifact-hash-mismatch'
        }
        $specs += [pscustomobject]@{
            Path      = $path
            Sha256    = $actual
            GuestPath = $GuestDir.TrimEnd('\') + '\' + $pair.GuestName
        }
    }
    return $specs
}

function Read-OpenPathLabState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw 'desktop-lab-state-invalid' }
    if ($null -eq $state) { throw 'desktop-lab-state-invalid' }
    return $state
}

function Write-OpenPathLabState {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function ConvertTo-OpenPathLabBootIdString {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime().ToString('o') }
    return [string]$Value
}

function Assert-OpenPathLabStateIdentity {
    param([Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][object]$Payload)
    foreach ($name in @('runId', 'scenarioId')) {
        if ([string](Get-OpenPathLabField -InputObject $State -Name $name) -ne [string](Get-OpenPathLabField -InputObject $Payload -Name $name)) {
            throw 'desktop-lab-state-artifact-mismatch'
        }
    }
    if ([int](Get-OpenPathLabField -InputObject $State -Name 'runAttempt') -ne [int](Get-OpenPathLabField -InputObject $Payload -Name 'runAttempt')) {
        throw 'desktop-lab-state-artifact-mismatch'
    }
    $artifacts = Get-OpenPathLabField -InputObject $State -Name 'artifacts'
    if ($null -eq $artifacts) { throw 'desktop-lab-state-artifact-mismatch' }
    foreach ($pair in @(
            @{ StateKey = 'templateSha256'; PayloadKey = 'templateSha256' },
            @{ StateKey = 'personalizedExeSha256'; PayloadKey = 'personalizedExeSha256' }
        )) {
        $stateHash = [string](Get-OpenPathLabField -InputObject $artifacts -Name $pair.StateKey)
        $payloadHash = [string](Get-OpenPathLabField -InputObject $Payload -Name $pair.PayloadKey)
        if (-not [string]::Equals($stateHash, $payloadHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'desktop-lab-state-artifact-mismatch'
        }
    }
}

function New-OpenPathLabObservation {
    param([Parameter(Mandatory = $true)][object]$Payload, [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Body)
    return [pscustomobject][ordered]@{
        schemaVersion    = 2
        status           = 'passed'
        runId            = [string](Get-OpenPathLabField -InputObject $Payload -Name 'runId')
        runAttempt       = [int](Get-OpenPathLabField -InputObject $Payload -Name 'runAttempt')
        scenarioId       = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
        phase            = [string](Get-OpenPathLabField -InputObject $Payload -Name 'phase')
        correlationNonce = [string](Get-OpenPathLabField -InputObject $Payload -Name 'correlationNonce')
        observation      = [pscustomobject]$Body
    }
}

function New-OpenPathLabDryRunBody {
    param([Parameter(Mandatory = $true)][string]$Phase)
    return [ordered]@{
        schemaVersion      = 1
        dryRun             = $true
        acceptanceEligible = $false
        qualificationNote  = 'Transport dry-run only. Not release evidence; the Pro/Education desktop-survival matrix remains blocked.'
        phase              = $Phase
    }
}

function Invoke-OpenPathLabPreparePhase {
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
    $specs = @(Get-OpenPathLabArtifactSpecs -Payload $Payload -GuestDir $Paths.GuestDir)
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) { throw 'desktop-lab-state-present' }
    $status = [string](& $Transport.GetVmStatus $Vmid)
    if ($status -eq 'running') { & $Transport.StopVm $Vmid | Out-Null }
    if ($RestoreBaseline) { & $Transport.RollbackVm $Vmid $Snapshot | Out-Null }
    & $Transport.StartVm $Vmid | Out-Null
    if (-not (& $Transport.WaitGuestReady $Vmid $TimeoutSeconds)) {
        throw 'desktop-lab-guest-not-ready'
    }
    $os = & $Transport.GetGuestOsInfo $Vmid
    $bootId = [string](& $Transport.GetGuestBootId $Vmid)
    if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'desktop-lab-guest-not-ready' }
    $guestHashes = [ordered]@{}
    try {
        foreach ($spec in $specs) {
            $published = & $Transport.PublishArtifact $Paths.StagingDir $spec.Path
            $url = [string](Get-OpenPathLabField -InputObject $published -Name 'url')
            if ([string]::IsNullOrWhiteSpace($url)) { throw 'desktop-lab-artifact-publish-failed' }
            & $Transport.DownloadGuestArtifact $Vmid $url $spec.GuestPath | Out-Null
            $guestHash = [string](& $Transport.GetGuestFileSha256 $Vmid $spec.GuestPath)
            if (-not [string]::Equals($guestHash, $spec.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'desktop-lab-guest-artifact-hash-mismatch'
            }
            $guestHashes[(Split-Path -Leaf $spec.GuestPath)] = $guestHash.ToLowerInvariant()
        }
    }
    finally {
        try { & $Transport.RemoveHostStaging $Paths.StagingDir | Out-Null } catch {}
    }
    $state = [ordered]@{
        schemaVersion      = 1
        runId              = [string](Get-OpenPathLabField -InputObject $Payload -Name 'runId')
        runAttempt         = [int](Get-OpenPathLabField -InputObject $Payload -Name 'runAttempt')
        scenarioId         = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
        vmid               = $Vmid
        baselineSnapshot   = $Snapshot
        phase              = 'prepared'
        bootIdBefore       = $bootId
        os                 = $os
        guestDir           = $Paths.GuestDir
        artifacts          = [ordered]@{
            templateSha256        = [string](Get-OpenPathLabField -InputObject $Payload -Name 'templateSha256')
            personalizedExeSha256 = [string](Get-OpenPathLabField -InputObject $Payload -Name 'personalizedExeSha256')
            guestHashes           = $guestHashes
        }
        updatedAtUtc       = [DateTime]::UtcNow.ToString('o')
    }
    Write-OpenPathLabState -Path $StatePath -Value $state
    $body = New-OpenPathLabDryRunBody -Phase 'prepare'
    $body.scenarioId = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
    $body.vm = [ordered]@{ vmid = $Vmid; baselineSnapshot = $Snapshot }
    $body.os = $os
    $body.bootIdBefore = $bootId
    $body.artifacts = [ordered]@{
        templateSha256        = [string](Get-OpenPathLabField -InputObject $Payload -Name 'templateSha256')
        personalizedExeSha256 = [string](Get-OpenPathLabField -InputObject $Payload -Name 'personalizedExeSha256')
        guestTemplateSha256   = [string](Get-OpenPathLabField -InputObject $guestHashes -Name 'template.exe')
        guestPersonalizedExeSha256 = [string](Get-OpenPathLabField -InputObject $guestHashes -Name 'personalized.exe')
    }
    $body.checks = [ordered]@{ guestReady = $true; artifactsVerified = $true }
    return New-OpenPathLabObservation -Payload $Payload -Body $body
}

function Invoke-OpenPathLabObservePhase {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $specs = @(Get-OpenPathLabArtifactSpecs -Payload $Payload -GuestDir (Get-OpenPathLabPaths -Payload $Payload -Config $Config).GuestDir)
    $state = Read-OpenPathLabState -Path $StatePath
    if ($null -eq $state) { throw 'desktop-lab-state-missing' }
    if ([string](Get-OpenPathLabField -InputObject $state -Name 'phase') -ne 'prepared') { throw 'desktop-lab-state-not-prepared' }
    Assert-OpenPathLabStateIdentity -State $state -Payload $Payload
    if (-not (& $Transport.WaitGuestReady ([int](Get-OpenPathLabField -InputObject $state -Name 'vmid')) $TimeoutSeconds)) {
        throw 'desktop-lab-guest-not-ready'
    }
    $bootId = [string](& $Transport.GetGuestBootId ([int](Get-OpenPathLabField -InputObject $state -Name 'vmid')))
    if ($bootId -ne (ConvertTo-OpenPathLabBootIdString -Value (Get-OpenPathLabField -InputObject $state -Name 'bootIdBefore'))) { throw 'desktop-lab-boot-id-drift' }
    foreach ($spec in $specs) {
        $guestHash = [string](& $Transport.GetGuestFileSha256 ([int](Get-OpenPathLabField -InputObject $state -Name 'vmid')) $spec.GuestPath)
        if (-not [string]::Equals($guestHash, $spec.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'desktop-lab-guest-artifact-hash-mismatch'
        }
    }
    $state.phase = 'observed'
    $state.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-OpenPathLabState -Path $StatePath -Value $state
    $body = New-OpenPathLabDryRunBody -Phase 'observe'
    $body.bootIdBefore = ConvertTo-OpenPathLabBootIdString -Value (Get-OpenPathLabField -InputObject $state -Name 'bootIdBefore')
    $body.checks = [ordered]@{ guestReady = $true; artifactsVerified = $true; bootIdUnchanged = $true }
    return New-OpenPathLabObservation -Payload $Payload -Body $body
}

function Invoke-OpenPathLabAfterRebootPhase {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $specs = @(Get-OpenPathLabArtifactSpecs -Payload $Payload -GuestDir $Paths.GuestDir)
    $state = Read-OpenPathLabState -Path $StatePath
    if ($null -eq $state) { throw 'desktop-lab-state-missing' }
    if ([string](Get-OpenPathLabField -InputObject $state -Name 'phase') -ne 'observed') { throw 'desktop-lab-state-not-observed' }
    Assert-OpenPathLabStateIdentity -State $state -Payload $Payload
    $vmid = [int](Get-OpenPathLabField -InputObject $state -Name 'vmid')
    $bootIdBefore = ConvertTo-OpenPathLabBootIdString -Value (Get-OpenPathLabField -InputObject $state -Name 'bootIdBefore')
    & $Transport.RequestGuestReboot $vmid | Out-Null
    $bootIdAfter = [string](& $Transport.WaitGuestRebooted $vmid $bootIdBefore $TimeoutSeconds)
    if ([string]::IsNullOrWhiteSpace($bootIdAfter)) { throw 'desktop-lab-guest-not-ready' }
    if ($bootIdAfter -eq $bootIdBefore) { throw 'desktop-lab-boot-id-unchanged' }
    $screendumpCaptured = [bool](& $Transport.CaptureScreendump $vmid (Join-Path ([string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')) 'console-after-reboot.ppm'))
    foreach ($spec in $specs) {
        $guestHash = [string](& $Transport.GetGuestFileSha256 $vmid $spec.GuestPath)
        if (-not [string]::Equals($guestHash, $spec.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'desktop-lab-guest-artifact-hash-mismatch'
        }
    }
    $state.phase = 'afterReboot'
    Add-Member -InputObject $state -NotePropertyName 'bootIdAfter' -NotePropertyValue $bootIdAfter -Force
    $state.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-OpenPathLabState -Path $StatePath -Value $state
    $body = New-OpenPathLabDryRunBody -Phase 'afterReboot'
    $body.bootIdBefore = $bootIdBefore
    $body.bootIdAfter = $bootIdAfter
    $body.bootIdChanged = $true
    $body.checks = [ordered]@{ guestReady = $true; artifactsVerified = $true; screendumpCaptured = $screendumpCaptured }
    return New-OpenPathLabObservation -Payload $Payload -Body $body
}

function Invoke-OpenPathLabCleanupPhase {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][bool]$RestoreBaseline
    )
    $state = Read-OpenPathLabState -Path $StatePath
    $statePresent = $null -ne $state
    $hostStagingRemoved = $true
    try { & $Transport.RemoveHostStaging $Paths.StagingDir | Out-Null } catch { $hostStagingRemoved = $false }
    $guestStagingRemoved = $null
    $rolledBack = $false
    if ($statePresent) {
        $guestStagingRemoved = $true
        try { & $Transport.RemoveGuestStaging $Vmid ([string](Get-OpenPathLabField -InputObject $state -Name 'guestDir')) | Out-Null } catch { $guestStagingRemoved = $false }
        & $Transport.StopVm $Vmid | Out-Null
        if ($RestoreBaseline) {
            & $Transport.RollbackVm $Vmid $Snapshot | Out-Null
            $rolledBack = $true
        }
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    }
    $body = New-OpenPathLabDryRunBody -Phase 'cleanup'
    $body.cleanup = [ordered]@{
        statePresent        = $statePresent
        hostStagingRemoved  = $hostStagingRemoved
        guestStagingRemoved = $guestStagingRemoved
        rolledBack          = $rolledBack
    }
    return New-OpenPathLabObservation -Payload $Payload -Body $body
}

#region Acceptance mode

function ConvertTo-OpenPathLabPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-OpenPathLabAcceptanceHarnessSourcePath {
    $ciRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $ciRoot 'desktop-survival\Invoke-OpenPathDesktopSurvivalGuest.ps1')
}

function Get-OpenPathLabAcceptanceSettings {
    param([Parameter(Mandatory = $true)][object]$Config)
    $student = [string](Get-OpenPathLabField -InputObject $Config -Name 'studentUserName')
    if ([string]::IsNullOrWhiteSpace($student)) { $student = 'alumno' }
    $admin = [string](Get-OpenPathLabField -InputObject $Config -Name 'adminUserName')
    if ([string]::IsNullOrWhiteSpace($admin)) { $admin = 'opadmin' }
    $secret = [string](Get-OpenPathLabField -InputObject $Config -Name 'guestSecret')
    if ([string]::IsNullOrWhiteSpace($secret)) {
        $secret = 'OpDsk' + [guid]::NewGuid().ToString('N').Substring(0, 14) + '!aA1'
    }
    foreach ($user in @($student, $admin)) {
        if ($user -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'desktop-lab-config-invalid' }
    }
    return [pscustomobject]@{ StudentUserName = $student; AdminUserName = $admin; GuestSecret = $secret }
}

function Read-OpenPathLabAcceptanceState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'desktop-lab-acceptance-state-missing' }
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'desktop-lab-acceptance-state-invalid' }
}

function Write-OpenPathLabAcceptanceState {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function ConvertTo-OpenPathLabAcceptanceStateTable {
    param([Parameter(Mandatory = $true)][object]$State)
    $table = [ordered]@{}
    foreach ($property in @($State.PSObject.Properties)) { $table[$property.Name] = $property.Value }
    return $table
}

function New-OpenPathLabAcceptanceObservation {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][object]$Body,
        [object]$Scenario = $null
    )
    $observation = [ordered]@{
        schemaVersion    = 2
        status           = 'passed'
        synthetic        = $false
        runId            = [string](Get-OpenPathLabField -InputObject $Payload -Name 'runId')
        runAttempt       = [int](Get-OpenPathLabField -InputObject $Payload -Name 'runAttempt')
        sourceCommitSha  = [string](Get-OpenPathLabField -InputObject $Payload -Name 'sourceCommitSha')
        scenarioId       = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
        phase            = $Phase
        correlationNonce = [string](Get-OpenPathLabField -InputObject $Payload -Name 'correlationNonce')
        observation      = $Body
    }
    if ($null -ne $Scenario) { $observation.scenario = $Scenario }
    return [pscustomobject]$observation
}

function Send-OpenPathLabAcceptanceStep {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$HarnessGuestPath,
        [string]$TemplateGuestPath = '',
        [string]$PersonalizedGuestPath = '',
        [int]$TimeoutSeconds = 900
    )
    $resultPath = $Paths.GuestDir.TrimEnd('\') + "\result-$Phase-$Step.json"
    $statePath = $Paths.GuestDir.TrimEnd('\') + '\guest-state.json'
    $identity = ConvertTo-OpenPathLabPowerShellLiteral -Value ([string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId'))
    $arguments = @(
        '& powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $HarnessGuestPath),
        '-Phase ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Phase),
        '-Step ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Step),
        '-ScenarioId ' + $identity,
        '-ResultPath ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $resultPath),
        '-StudentUserName ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Settings.StudentUserName),
        '-AdminUserName ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Settings.AdminUserName),
        '-Secret ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $Settings.GuestSecret),
        '-StatePath ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $statePath)
    )
    if ($TemplateGuestPath) { $arguments += '-TemplatePath ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $TemplateGuestPath) }
    if ($PersonalizedGuestPath) { $arguments += '-PersonalizedExePath ' + (ConvertTo-OpenPathLabPowerShellLiteral -Value $PersonalizedGuestPath) }
    $arguments += '| Out-String'
    $script = ($arguments -join ' ') + "`nWrite-Output ('__HARNESS_EXIT__=' + [string]`$LASTEXITCODE)"
    $output = & $Transport.InvokeGuestPowerShell $Vmid $script $TimeoutSeconds
    $exitMatch = [regex]::Match([string]$output, '__HARNESS_EXIT__=(-?\d+)')
    $exitCode = if ($exitMatch.Success) { [int]$exitMatch.Groups[1].Value } else { -999 }
    $jsonText = [string]$output
    $start = $jsonText.IndexOf('{')
    $end = $jsonText.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { throw "desktop-lab-guest-result-missing-$Phase-$Step" }
    try { $harness = $jsonText.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "desktop-lab-guest-result-invalid-$Phase-$Step" }
    if ([string]$harness.status -ne 'passed' -or $exitCode -ne 0) {
        $failures = @($harness.failures) -join ','
        throw "desktop-lab-guest-step-failed-$Phase-$Step-$failures"
    }
    return $harness
}

function Get-OpenPathLabAcceptanceCapture {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $artifactsRoot = [string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')
    $target = Join-Path (Join-Path $artifactsRoot 'screens') "$Name.ppm"
    $captured = [bool](& $Transport.CaptureScreendump $Vmid $target)
    return [ordered]@{ name = $Name; captured = $captured; path = "screens/$Name.ppm" }
}

function Get-OpenPathLabAcceptanceTimeoutDiagnostics {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Step
    )
    $name = "session-timeout-$Phase-$Step"
    $artifactsRoot = [string](Get-OpenPathLabField -InputObject $Payload -Name 'artifactsRoot')
    $capture = Get-OpenPathLabAcceptanceCapture -Payload $Payload -Transport $Transport -Vmid $Vmid -Name $name
    $diagnosticScript = @'
$ErrorActionPreference = 'Continue'
$result = [ordered]@{}
try { $result.quser = (quser.exe 2>&1 | Out-String).Trim() } catch {}
try {
    $explorers = @()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        $owner = ''
        try {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            $owner = "$($o.Domain)\$($o.User)"
        }
        catch {}
        $explorers += [ordered]@{ pid = $p.ProcessId; owner = $owner }
    }
    $result.explorers = $explorers
}
catch {}
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $result.memory = [ordered]@{
        freePhysicalKB = [int64]$os.FreePhysicalMemory
        totalVisibleKB = [int64]$os.TotalVisibleMemorySize
        freeVirtualKB  = [int64]$os.FreeVirtualMemory
        totalVirtualKB = [int64]$os.TotalVirtualMemorySize
    }
}
catch {}
$lockerRows = @()
foreach ($logName in @('Microsoft-Windows-AppLocker/EXE and DLL', 'Microsoft-Windows-AppLocker/MSI and Script', 'Microsoft-Windows-AppLocker/Packaged app-Execution', 'Microsoft-Windows-AppLocker/Packaged app-Deployment')) {
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = (Get-Date).AddMinutes(-30) } -MaxEvents 40 -ErrorAction Stop
        foreach ($e in $events) {
            if ([string]$e.LevelDisplayName -eq 'Information') { continue }
            $lockerRows += [ordered]@{
                log     = $logName
                id      = $e.Id
                level   = [string]$e.LevelDisplayName
                timeUtc = $e.TimeCreated.ToUniversalTime().ToString('o')
                message = (([string]$e.Message -replace "`r?`n", ' ').Trim())
            }
        }
    }
    catch {}
}
$result.appLocker = @($lockerRows | Select-Object -First 40)
try { $result.watchdogTail = @(Get-Content -LiteralPath 'C:\OpenPath\data\logs\openpath.log' -Tail 40 -ErrorAction SilentlyContinue) } catch {}
$result | ConvertTo-Json -Depth 6
'@
    $diagnostics = [ordered]@{
        captured = [bool]$capture.captured
        screen   = $capture.path
        guest    = $null
        file     = ''
    }
    try {
        # One bounded attempt: diagnostics must not multiply the timeout.
        $raw = & $Transport.InvokeGuestPowerShell $Vmid $diagnosticScript 90 1
        $diagnostics.guest = ConvertFrom-OpenPathLabJsonText -Text ([string]$raw)
    }
    catch {
        $diagnostics.guestError = Format-OpenPathLabGuestErrorDetail -Text ([string]$_.Exception.Message)
    }
    $target = Join-Path $artifactsRoot "$name.diagnostics.json"
    try {
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllText($target, ($diagnostics | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $diagnostics.file = "$name.diagnostics.json"
    }
    catch { $diagnostics.fileError = $_.Exception.Message }
    return [pscustomobject]$diagnostics
}

function Wait-OpenPathLabAcceptanceSession {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$HarnessGuestPath,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Step,
        [int]$TimeoutSeconds = 420
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastAttemptError = $null
    while ((Get-Date) -lt $deadline) {
        Update-OpenPathLabActiveHeartbeat
        try {
            $harness = Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths `
                -Phase $Phase -Step $Step -Settings $Settings -HarnessGuestPath $HarnessGuestPath -TimeoutSeconds 300
        }
        catch {
            $lastAttemptError = $_
            Start-Sleep -Seconds 10
            continue
        }
        $session = [string](Get-OpenPathLabField -InputObject $harness.body -Name 'session')
        if (-not [string]::IsNullOrWhiteSpace($session)) { return $harness }
        Start-Sleep -Seconds 10
    }
    # A session timeout used to leave no useful evidence: the per-attempt errors
    # were swallowed and the guest state was discarded with the next rollback.
    # Capture the console, one bounded diagnostic query and the last attempt
    # error so the artifact explains the failure instead of only naming it.
    $diagnostics = $null
    try {
        $diagnostics = Get-OpenPathLabAcceptanceTimeoutDiagnostics -Payload $Payload -Transport $Transport -Vmid $Vmid -Phase $Phase -Step $Step
    }
    catch {}
    $lastAttemptDetail = if ($null -ne $lastAttemptError) { Format-OpenPathLabGuestErrorDetail -Text ([string]$lastAttemptError.Exception.Message) } else { 'no-attempt-error' }
    $diagnosticsDetail = if ($null -ne $diagnostics) { " diagnostics=$($diagnostics.file) screen=$($diagnostics.screen)" } else { '' }
    throw "desktop-lab-session-timeout-$Phase-$Step lastAttempt=$lastAttemptDetail$diagnosticsDetail"
}

function Invoke-OpenPathLabAcceptanceGuestSetup {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$HarnessSourcePath = ''
    )
    $specs = @(Get-OpenPathLabArtifactSpecs -Payload $Payload -GuestDir $Paths.GuestDir)
    $guestHashes = [ordered]@{}
    $harnessGuestPath = $Paths.GuestDir.TrimEnd('\') + '\guest-harness.ps1'
    try {
        foreach ($spec in $specs) {
            $published = & $Transport.PublishArtifact $Paths.StagingDir $spec.Path
            $url = [string](Get-OpenPathLabField -InputObject $published -Name 'url')
            if ([string]::IsNullOrWhiteSpace($url)) { throw 'desktop-lab-artifact-publish-failed' }
            & $Transport.DownloadGuestArtifact $Vmid $url $spec.GuestPath | Out-Null
            $guestHash = [string](& $Transport.GetGuestFileSha256 $Vmid $spec.GuestPath)
            if (-not [string]::Equals($guestHash, $spec.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'desktop-lab-guest-artifact-hash-mismatch'
            }
            $guestHashes[(Split-Path -Leaf $spec.GuestPath)] = $guestHash.ToLowerInvariant()
        }
        $harnessSource = if ($PSBoundParameters.ContainsKey('HarnessSourcePath') -and $HarnessSourcePath) { $HarnessSourcePath } else { Get-OpenPathLabAcceptanceHarnessSourcePath }
        if (-not (Test-Path -LiteralPath $harnessSource -PathType Leaf)) { throw 'desktop-lab-harness-source-missing' }
        $harnessHash = (Get-FileHash -LiteralPath $harnessSource -Algorithm SHA256).Hash.ToLowerInvariant()
        $published = & $Transport.PublishArtifact $Paths.StagingDir $harnessSource
        $url = [string](Get-OpenPathLabField -InputObject $published -Name 'url')
        if ([string]::IsNullOrWhiteSpace($url)) { throw 'desktop-lab-artifact-publish-failed' }
        & $Transport.DownloadGuestArtifact $Vmid $url $harnessGuestPath | Out-Null
        $guestHash = [string](& $Transport.GetGuestFileSha256 $Vmid $harnessGuestPath)
        if (-not [string]::Equals($guestHash, $harnessHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'desktop-lab-guest-harness-hash-mismatch'
        }
    }
    finally {
        try { & $Transport.RemoveHostStaging $Paths.StagingDir | Out-Null } catch {}
    }
    return [pscustomobject]@{
        TemplateGuestPath       = $specs[0].GuestPath
        PersonalizedGuestPath   = $specs[1].GuestPath
        HarnessGuestPath        = $harnessGuestPath
        GuestHashes             = $guestHashes
    }
}

function Start-OpenPathLabAcceptanceVm {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$Snapshot,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$RestoreBaseline
    )
    $status = [string](& $Transport.GetVmStatus $Vmid)
    if ($status -eq 'running') { & $Transport.StopVm $Vmid | Out-Null }
    if ($RestoreBaseline) { & $Transport.RollbackVm $Vmid $Snapshot | Out-Null }
    & $Transport.StartVm $Vmid | Out-Null
    if (-not (& $Transport.WaitGuestReady $Vmid $TimeoutSeconds)) { throw 'desktop-lab-guest-not-ready' }
}

function Start-OpenPathLabAcceptanceReboot {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$PreviousBootId,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    & $Transport.RequestGuestReboot $Vmid | Out-Null
    $bootId = [string](& $Transport.WaitGuestRebooted $Vmid $PreviousBootId $TimeoutSeconds)
    if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'desktop-lab-guest-not-ready' }
    if ($bootId -eq $PreviousBootId) { throw 'desktop-lab-boot-id-unchanged' }
    # A freshly installed agent can restart the guest on its own shortly after
    # the requested reboot. Wait until the boot id stays stable for a short
    # window so the following session wait does not race a second restart.
    $stableDeadline = (Get-Date).AddSeconds(90)
    $stableSince = Get-Date
    while ((Get-Date) -lt $stableDeadline) {
        Start-Sleep -Seconds 5
        $currentBootId = [string](& $Transport.GetGuestBootId $Vmid)
        if ([string]::IsNullOrWhiteSpace($currentBootId)) { $stableSince = Get-Date; continue }
        if ($currentBootId -ne $bootId) { $bootId = $currentBootId; $stableSince = Get-Date; continue }
        if (((Get-Date) - $stableSince).TotalSeconds -ge 10) { break }
    }
    return $bootId
}

function Invoke-OpenPathLabAcceptancePrepare {
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
    $scenario = Get-OpenPathLabScenario -Config $Config -ScenarioId ([string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId'))
    Start-OpenPathLabAcceptanceVm -Transport $Transport -Vmid $Vmid -Snapshot $Snapshot -TimeoutSeconds $TimeoutSeconds -RestoreBaseline $RestoreBaseline
    $os = & $Transport.GetGuestOsInfo $Vmid
    $expectedEdition = [string](Get-OpenPathLabField -InputObject $scenario -Name 'expectedEditionId')
    $edition = [string](Get-OpenPathLabField -InputObject $os -Name 'editionId')
    if ($expectedEdition -and $edition -ne $expectedEdition) { throw 'desktop-lab-edition-mismatch' }
    $bootId = [string](& $Transport.GetGuestBootId $Vmid)
    if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'desktop-lab-guest-not-ready' }
    $setup = Invoke-OpenPathLabAcceptanceGuestSetup -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -TimeoutSeconds $TimeoutSeconds
    $harness = Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths `
        -Phase 'prepare' -Step 'install' -Settings $settings -HarnessGuestPath $setup.HarnessGuestPath `
        -TemplateGuestPath $setup.TemplateGuestPath -PersonalizedGuestPath $setup.PersonalizedGuestPath -TimeoutSeconds 1800
    $body = $harness.body
    $state = [ordered]@{
        phase                     = 'prepared'
        scenarioId                = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
        os                        = $os
        bootIdBefore              = $bootId
        bootIdLatest              = $bootId
        policyBeforeSha256        = [string](Get-OpenPathLabField -InputObject $body.state -Name 'policyBeforeSha256')
        policyAfterSha256         = [string](Get-OpenPathLabField -InputObject $body.state -Name 'policyAfterSha256')
        initialProfileExisted     = [bool](Get-OpenPathLabField -InputObject $body.state -Name 'initialProfileExisted')
        catalogApplicationCount   = [int](Get-OpenPathLabField -InputObject $body.state -Name 'catalogApplicationCount')
        install                   = Get-OpenPathLabField -InputObject $body.state -Name 'installSummary'
        config                    = Get-OpenPathLabField -InputObject $body.state -Name 'config'
        groupMembers              = Get-OpenPathLabField -InputObject $body.state -Name 'groupMembers'
        tasks                     = Get-OpenPathLabField -InputObject $body.state -Name 'tasks'
        uninstaller               = [bool](Get-OpenPathLabField -InputObject $body.state -Name 'uninstaller')
        harnessGuestPath          = $setup.HarnessGuestPath
        templateGuestPath         = $setup.TemplateGuestPath
        personalizedGuestPath     = $setup.PersonalizedGuestPath
        guestSecret               = $settings.GuestSecret
    }
    Write-OpenPathLabAcceptanceState -Path $StatePath -Value $state
    $body | Add-Member -NotePropertyName guestState -NotePropertyValue $state -Force
    return New-OpenPathLabAcceptanceObservation -Payload $Payload -Phase 'prepare' -Body $body
}

function Invoke-OpenPathLabAcceptanceObserve {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $state = ConvertTo-OpenPathLabAcceptanceStateTable -State (Read-OpenPathLabAcceptanceState -Path $StatePath)
    $settings = Get-OpenPathLabAcceptanceSettings -Config $Config
    $persistedSecret = [string](Get-OpenPathLabField -InputObject $state -Name 'guestSecret')
    if (-not [string]::IsNullOrWhiteSpace($persistedSecret)) { $settings.GuestSecret = $persistedSecret }
    $harnessGuestPath = [string](Get-OpenPathLabField -InputObject $state -Name 'harnessGuestPath')
    $body = [ordered]@{ screendumps = @() }

    Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'observe' -Step 'admin-autologon' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 120 | Out-Null
    $state.bootIdLatest = Start-OpenPathLabAcceptanceReboot -Transport $Transport -Vmid $Vmid -PreviousBootId ([string](Get-OpenPathLabField -InputObject $state -Name 'bootIdLatest')) -TimeoutSeconds $TimeoutSeconds
    $adminVerify = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Phase 'observe' -Step 'admin-verify'
    $body.preRebootAdminDesktop = [ordered]@{ session = [string](Get-OpenPathLabField -InputObject $adminVerify.body -Name 'session') }
    $state.preRebootAdminSessionVerified = $true
    $body.screendumps = @(Get-OpenPathLabAcceptanceCapture -Payload $Payload -Transport $Transport -Vmid $Vmid -Name 'pre-reboot-admin-desktop')

    Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'observe' -Step 'boundary-arm' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300 | Out-Null
    Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'observe' -Step 'student-autologon' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 120 | Out-Null
    $state.bootIdLatest = Start-OpenPathLabAcceptanceReboot -Transport $Transport -Vmid $Vmid -PreviousBootId ([string](Get-OpenPathLabField -InputObject $state -Name 'bootIdLatest')) -TimeoutSeconds $TimeoutSeconds
    $studentVerify = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Phase 'observe' -Step 'student-verify'
    $firstLogon = [bool](Get-OpenPathLabField -InputObject $studentVerify.body -Name 'firstStudentInteractiveLogon')
    if (-not $firstLogon) { throw 'desktop-lab-first-student-logon-missing' }
    $state.firstStudentLogonVerified = $true
    $body.firstStudentInteractiveLogon = [ordered]@{
        session     = [string](Get-OpenPathLabField -InputObject $studentVerify.body -Name 'session')
        studentLogons = Get-OpenPathLabField -InputObject $studentVerify.body -Name 'studentLogons'
    }
    $body.screendumps = @($body.screendumps) + @(Get-OpenPathLabAcceptanceCapture -Payload $Payload -Transport $Transport -Vmid $Vmid -Name 'first-student-logon')

    $boundary = Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'observe' -Step 'boundary-collect' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 900
    $state.preRebootProbes = $boundary.body
    if (@($boundary.body.criticalUnexpectedDenials).Count -gt 0) { throw 'desktop-lab-pre-reboot-boundary-unexpected' }
    $body.preRebootStudentBoundary = $boundary.body
    $state.bootIdAfterObserve = [string](Get-OpenPathLabField -InputObject $state -Name 'bootIdLatest')
    Write-OpenPathLabAcceptanceState -Path $StatePath -Value $state
    return New-OpenPathLabAcceptanceObservation -Payload $Payload -Phase 'observe' -Body $body
}

function Invoke-OpenPathLabAcceptanceAfterReboot {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $state = ConvertTo-OpenPathLabAcceptanceStateTable -State (Read-OpenPathLabAcceptanceState -Path $StatePath)
    $settings = Get-OpenPathLabAcceptanceSettings -Config $Config
    $persistedSecret = [string](Get-OpenPathLabField -InputObject $state -Name 'guestSecret')
    if (-not [string]::IsNullOrWhiteSpace($persistedSecret)) { $settings.GuestSecret = $persistedSecret }
    $harnessGuestPath = [string](Get-OpenPathLabField -InputObject $state -Name 'harnessGuestPath')
    $body = [ordered]@{ screendumps = @() }

    Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'afterReboot' -Step 'login-screen' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 120 | Out-Null
    $state.bootIdAfter = Start-OpenPathLabAcceptanceReboot -Transport $Transport -Vmid $Vmid -PreviousBootId ([string](Get-OpenPathLabField -InputObject $state -Name 'bootIdLatest')) -TimeoutSeconds $TimeoutSeconds
    Start-Sleep -Seconds 20
    $loginScreen = Get-OpenPathLabAcceptanceCapture -Payload $Payload -Transport $Transport -Vmid $Vmid -Name 'login-screen-after-reboot'
    if (-not $loginScreen.captured) { throw 'desktop-lab-login-screen-capture-failed' }
    $body.loginScreenAfterReboot = $loginScreen
    $state.loginScreenCaptured = $true
    $body.screendumps = @($body.screendumps) + @($loginScreen)

    Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'afterReboot' -Step 'admin-autologon' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 120 | Out-Null
    $state.bootIdLatest = Start-OpenPathLabAcceptanceReboot -Transport $Transport -Vmid $Vmid -PreviousBootId ([string](Get-OpenPathLabField -InputObject $state -Name 'bootIdAfter')) -TimeoutSeconds $TimeoutSeconds
    $adminVerify = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Phase 'afterReboot' -Step 'admin-verify'
    $body.postRebootAdminDesktop = [ordered]@{ session = [string](Get-OpenPathLabField -InputObject $adminVerify.body -Name 'session') }
    $state.postRebootAdminSessionVerified = $true
    $body.screendumps = @($body.screendumps) + @(Get-OpenPathLabAcceptanceCapture -Payload $Payload -Transport $Transport -Vmid $Vmid -Name 'post-reboot-admin-desktop')

    Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'afterReboot' -Step 'boundary-arm' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 300 | Out-Null
    Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'afterReboot' -Step 'student-autologon' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 120 | Out-Null
    $state.bootIdLatest = Start-OpenPathLabAcceptanceReboot -Transport $Transport -Vmid $Vmid -PreviousBootId ([string](Get-OpenPathLabField -InputObject $state -Name 'bootIdLatest')) -TimeoutSeconds $TimeoutSeconds
    $studentVerify = Wait-OpenPathLabAcceptanceSession -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Settings $settings -HarnessGuestPath $harnessGuestPath -Phase 'afterReboot' -Step 'student-verify'
    $body.postRebootStudentDesktop = [ordered]@{ session = [string](Get-OpenPathLabField -InputObject $studentVerify.body -Name 'session') }
    $state.postRebootStudentSessionVerified = $true
    $body.screendumps = @($body.screendumps) + @(Get-OpenPathLabAcceptanceCapture -Payload $Payload -Transport $Transport -Vmid $Vmid -Name 'post-reboot-student-desktop')

    $boundary = Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'afterReboot' -Step 'boundary-collect' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 900
    $state.postRebootProbes = $boundary.body
    if (@($boundary.body.criticalUnexpectedDenials).Count -gt 0) { throw 'desktop-lab-post-reboot-boundary-unexpected' }
    $body.postRebootStudentBoundary = $boundary.body
    Write-OpenPathLabAcceptanceState -Path $StatePath -Value $state
    return New-OpenPathLabAcceptanceObservation -Payload $Payload -Phase 'afterReboot' -Body $body
}

function Invoke-OpenPathLabAcceptanceCleanup {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][bool]$RestoreBaseline
    )
    $state = ConvertTo-OpenPathLabAcceptanceStateTable -State (Read-OpenPathLabAcceptanceState -Path $StatePath)
    $settings = Get-OpenPathLabAcceptanceSettings -Config $Config
    $persistedSecret = [string](Get-OpenPathLabField -InputObject $state -Name 'guestSecret')
    if (-not [string]::IsNullOrWhiteSpace($persistedSecret)) { $settings.GuestSecret = $persistedSecret }
    $scenario = Get-OpenPathLabScenario -Config $Config -ScenarioId ([string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId'))
    $harnessGuestPath = [string](Get-OpenPathLabField -InputObject $state -Name 'harnessGuestPath')

    try {
        $uninstall = Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'cleanup' -Step 'uninstall' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 1800
        $verify = Send-OpenPathLabAcceptanceStep -Payload $Payload -Transport $Transport -Vmid $Vmid -Paths $Paths -Phase 'cleanup' -Step 'verify-clean' -Settings $settings -HarnessGuestPath $harnessGuestPath -TimeoutSeconds 600
        $clean = [bool](Get-OpenPathLabField -InputObject $verify.body -Name 'clean')
        if (-not $clean) { throw 'desktop-lab-cleanup-not-clean' }
    }
    finally {
        # A dead or timing-out guest must not leave its VM running while the
        # next scenario waits for the lab lock.
        if ($RestoreBaseline) {
            try { & $Transport.StopVm $Vmid | Out-Null } catch {}
            try { & $Transport.RollbackVm $Vmid $Snapshot | Out-Null } catch {}
        }
        try { & $Transport.RemoveGuestStaging $Vmid $Paths.GuestDir | Out-Null } catch {}
    }

    $preProbes = Get-OpenPathLabField -InputObject $state -Name 'preRebootProbes'
    $postProbes = Get-OpenPathLabField -InputObject $state -Name 'postRebootProbes'
    $preFixtures = Get-OpenPathLabField -InputObject $preProbes -Name 'fixtures'
    $postFixtures = Get-OpenPathLabField -InputObject $postProbes -Name 'fixtures'
    $fixtures = [ordered]@{}
    foreach ($name in @('exeAndDll', 'msiAndScript', 'packagedAppExecution')) {
        $pre = [string](Get-OpenPathLabField -InputObject $preFixtures -Name $name)
        $post = [string](Get-OpenPathLabField -InputObject $postFixtures -Name $name)
        $fixtures[$name] = if ($pre -eq 'passed' -and $post -eq 'passed') { 'passed' } else { 'failed' }
    }
    $imageIdentity = [string](Get-OpenPathLabField -InputObject $scenario -Name 'imageIdentity')
    if ([string]::IsNullOrWhiteSpace($imageIdentity)) { $imageIdentity = $Snapshot }
    $os = Get-OpenPathLabField -InputObject $state -Name 'os'
    $scenarioObject = [ordered]@{}
    foreach ($property in @($os.PSObject.Properties)) { $scenarioObject[$property.Name] = $property.Value }
    $observations = [ordered]@{
        preRebootAdminDesktop        = if ([bool](Get-OpenPathLabField -InputObject $state -Name 'preRebootAdminSessionVerified')) { 'passed' } else { 'failed' }
        firstStudentInteractiveLogon = if ([bool](Get-OpenPathLabField -InputObject $state -Name 'firstStudentLogonVerified')) { 'passed' } else { 'failed' }
        preRebootStudentBoundary     = if (@($preProbes.criticalUnexpectedDenials).Count -eq 0) { 'passed' } else { 'failed' }
        loginScreenAfterReboot       = if ([bool](Get-OpenPathLabField -InputObject $state -Name 'loginScreenCaptured')) { 'passed' } else { 'failed' }
        postRebootAdminDesktop       = if ([bool](Get-OpenPathLabField -InputObject $state -Name 'postRebootAdminSessionVerified')) { 'passed' } else { 'failed' }
        postRebootStudentDesktop     = if ([bool](Get-OpenPathLabField -InputObject $state -Name 'postRebootStudentSessionVerified')) { 'passed' } else { 'failed' }
        postRebootStudentBoundary    = if (@($postProbes.criticalUnexpectedDenials).Count -eq 0) { 'passed' } else { 'failed' }
        uninstallOrRollback          = if ([bool](Get-OpenPathLabField -InputObject $uninstall.body.state -Name 'uninstallFailed')) { 'failed' } else { 'passed' }
        cleanup                      = if ($clean) { 'passed' } else { 'failed' }
    }
    if (@($observations.Values | Where-Object { $_ -ne 'passed' }).Count -gt 0) { throw 'desktop-lab-observations-failed' }
    if (@($fixtures.Values | Where-Object { $_ -ne 'passed' }).Count -gt 0) { throw 'desktop-lab-fixtures-failed' }
    $scenarioMetadata = [ordered]@{
        scenarioId                = [string](Get-OpenPathLabField -InputObject $Payload -Name 'scenarioId')
        sourceCommitSha           = [string](Get-OpenPathLabField -InputObject $Payload -Name 'sourceCommitSha')
        templateSha256            = [string](Get-OpenPathLabField -InputObject $Payload -Name 'templateSha256')
        personalizedExeSha256     = [string](Get-OpenPathLabField -InputObject $Payload -Name 'personalizedExeSha256')
        policyBeforeSha256        = [string](Get-OpenPathLabField -InputObject $state -Name 'policyBeforeSha256')
        policyAfterSha256         = [string](Get-OpenPathLabField -InputObject $state -Name 'policyAfterSha256')
        os                        = $scenarioObject
        imageIdentity             = $imageIdentity
        snapshotIdentity          = $Snapshot
        appControlProfile         = 'ManagedBrowserCompatibility'
        catalogApplicationCount   = [int](Get-OpenPathLabField -InputObject $state -Name 'catalogApplicationCount')
        initialProfileExisted     = [bool](Get-OpenPathLabField -InputObject $state -Name 'initialProfileExisted')
        bootIdBefore              = [string](Get-OpenPathLabField -InputObject $state -Name 'bootIdBefore')
        bootIdAfter               = [string](Get-OpenPathLabField -InputObject $state -Name 'bootIdAfter')
        synthetic                 = $false
        observations              = $observations
        criticalUnexpectedDenials = @()
        fixtures                  = $fixtures
    }
    if ($scenarioMetadata.bootIdBefore -eq $scenarioMetadata.bootIdAfter) { throw 'desktop-lab-boot-id-unchanged' }
    $body = [ordered]@{
        uninstall        = Get-OpenPathLabField -InputObject $uninstall.body -Name 'state'
        verify           = $verify.body
        snapshot         = $Snapshot
        guestStagingRemoved = $true
        baselineRestored = $RestoreBaseline
    }
    return New-OpenPathLabAcceptanceObservation -Payload $Payload -Phase 'cleanup' -Body $body -Scenario $scenarioMetadata
}

#endregion

function Invoke-OpenPathProxmoxControllerPhase {
    <#
    .SYNOPSIS
        Runs one transport dry-run phase of the disposable Windows controller.
    .DESCRIPTION
        Validates payload, lab configuration and the injected transport contract,
        serializes lab access with a remote lock and dispatches the phase. It is
        acceptance-incapable by construction: qualification metadata is marked
        dry-run and never release eligible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport
    )
    if ([int](Get-OpenPathLabField -InputObject $Payload -Name 'schemaVersion') -ne 2) { throw 'desktop-lab-payload-invalid' }
    $phase = [string](Get-OpenPathLabRequiredField -InputObject $Payload -Name 'phase' -Code 'desktop-lab-payload-invalid')
    if ($phase -notin @('prepare', 'observe', 'afterReboot', 'cleanup')) { throw 'desktop-lab-payload-invalid' }
    $scenarioId = [string](Get-OpenPathLabRequiredField -InputObject $Payload -Name 'scenarioId' -Code 'desktop-lab-payload-invalid')
    $runId = [string](Get-OpenPathLabRequiredField -InputObject $Payload -Name 'runId' -Code 'desktop-lab-payload-invalid')
    $runAttempt = [int](Get-OpenPathLabField -InputObject $Payload -Name 'runAttempt')
    $correlationNonce = [string](Get-OpenPathLabRequiredField -InputObject $Payload -Name 'correlationNonce' -Code 'desktop-lab-payload-invalid')
    if ($correlationNonce -notmatch '^[0-9a-fA-F]{32}$') { throw 'desktop-lab-payload-invalid' }
    $artifactsRoot = [string](Get-OpenPathLabRequiredField -InputObject $Payload -Name 'artifactsRoot' -Code 'desktop-lab-payload-invalid')
    if ([string](Get-OpenPathLabField -InputObject $Config -Name 'mode') -notin @('transport-dry-run', 'acceptance')) { throw 'desktop-lab-acceptance-not-implemented' }
    foreach ($key in $script:OpenPathLabRequiredTransportKeys) {
        if (-not $Transport.Contains($key)) { throw 'desktop-lab-transport-invalid' }
    }
    # Phase 3A: a suite may map its own scenario ids onto one lab inventory
    # entry (vmid + baseline snapshot) without touching the operator config.
    $labScenarioId = $scenarioId
    $firstVisitPayload = Get-OpenPathLabField -InputObject $Payload -Name 'firstVisit'
    if ($firstVisitPayload) {
        $mapped = [string](Get-OpenPathLabField -InputObject $firstVisitPayload -Name 'labScenario')
        if (-not [string]::IsNullOrWhiteSpace($mapped)) { $labScenarioId = $mapped }
    }
    $scenario = Get-OpenPathLabScenario -Config $Config -ScenarioId $labScenarioId
    $vmid = [int](Get-OpenPathLabField -InputObject $scenario -Name 'vmid')
    $snapshot = [string](Get-OpenPathLabField -InputObject $scenario -Name 'baselineSnapshot')
    $paths = Get-OpenPathLabPaths -Payload $Payload -Config $Config
    $statePath = Join-Path $artifactsRoot 'controller-state.json'
    $lockOwner = "$runId/$runAttempt/$scenarioId"
    $lockFile = [string](Get-OpenPathLabField -InputObject $Config -Name 'lockFile')
    $timeoutSeconds = [int](Get-OpenPathLabField -InputObject $Config -Name 'timeoutSeconds')
    if ($timeoutSeconds -le 0) { $timeoutSeconds = 1800 }
    $restoreBaseline = $true
    $restoreBaselineValue = Get-OpenPathLabField -InputObject $Config -Name 'restoreBaseline'
    if ($null -ne $restoreBaselineValue) { $restoreBaseline = [bool]$restoreBaselineValue }
    $lockWaitSeconds = 900
    $lockWaitValue = Get-OpenPathLabField -InputObject $Config -Name 'lockWaitSeconds'
    if ($null -ne $lockWaitValue) { $lockWaitSeconds = [int]$lockWaitValue }
    if (-not (& $Transport.EnsureLock $lockFile $lockOwner $timeoutSeconds $lockWaitSeconds)) { throw 'desktop-lab-lock-busy' }
    $script:OpenPathLabActiveLock = @{ File = $lockFile; Owner = $lockOwner; Transport = $Transport }
    try {
        $mode = [string](Get-OpenPathLabField -InputObject $Config -Name 'mode')
        if ($mode -eq 'acceptance') {
            $acceptanceStatePath = Join-Path $artifactsRoot 'acceptance-state.json'
            $suiteKind = [string](Get-OpenPathLabField -InputObject $Payload -Name 'suiteKind')
            if ($suiteKind -eq 'FirstVisit') {
                switch ($phase) {
                    'prepare' { return Invoke-OpenPathFirstVisitPrepare -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Snapshot $snapshot -Paths $paths -StatePath $acceptanceStatePath -TimeoutSeconds $timeoutSeconds -RestoreBaseline $restoreBaseline }
                    'observe' { return Invoke-OpenPathFirstVisitObserve -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Paths $paths -StatePath $acceptanceStatePath -TimeoutSeconds $timeoutSeconds }
                    'cleanup' { return Invoke-OpenPathFirstVisitCleanup -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Snapshot $snapshot -Paths $paths -StatePath $acceptanceStatePath -TimeoutSeconds $timeoutSeconds -RestoreBaseline $restoreBaseline }
                    default { throw 'first-visit-phase-invalid' }
                }
            }
            switch ($phase) {
                'prepare' { return Invoke-OpenPathLabAcceptancePrepare -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Snapshot $snapshot -Paths $paths -StatePath $acceptanceStatePath -TimeoutSeconds $timeoutSeconds -RestoreBaseline $restoreBaseline }
                'observe' { return Invoke-OpenPathLabAcceptanceObserve -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Paths $paths -StatePath $acceptanceStatePath -TimeoutSeconds $timeoutSeconds }
                'afterReboot' { return Invoke-OpenPathLabAcceptanceAfterReboot -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Paths $paths -StatePath $acceptanceStatePath -TimeoutSeconds $timeoutSeconds }
                'cleanup' { return Invoke-OpenPathLabAcceptanceCleanup -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Snapshot $snapshot -Paths $paths -StatePath $acceptanceStatePath -RestoreBaseline $restoreBaseline }
                default { throw 'desktop-lab-payload-invalid' }
            }
        }
        switch ($phase) {
            'prepare' { return Invoke-OpenPathLabPreparePhase -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Snapshot $snapshot -Paths $paths -StatePath $statePath -TimeoutSeconds $timeoutSeconds -RestoreBaseline $restoreBaseline }
            'observe' { return Invoke-OpenPathLabObservePhase -Payload $Payload -Config $Config -Transport $Transport -StatePath $statePath -TimeoutSeconds $timeoutSeconds }
            'afterReboot' { return Invoke-OpenPathLabAfterRebootPhase -Payload $Payload -Config $Config -Transport $Transport -Paths $paths -StatePath $statePath -TimeoutSeconds $timeoutSeconds }
            'cleanup' { return Invoke-OpenPathLabCleanupPhase -Payload $Payload -Config $Config -Transport $Transport -Vmid $vmid -Snapshot $snapshot -Paths $paths -StatePath $statePath -RestoreBaseline $restoreBaseline }
            default { throw 'desktop-lab-payload-invalid' }
        }
    }
    finally {
        $script:OpenPathLabActiveLock = $null
        try { & $Transport.ReleaseLock $lockFile $lockOwner | Out-Null } catch {}
    }
}

function Update-OpenPathLabActiveHeartbeat {
    # Best-effort heartbeat refresh while a phase runs; never fails a phase.
    if (-not $script:OpenPathLabActiveLock) { return }
    try {
        & $script:OpenPathLabActiveLock.Transport.UpdateLockHeartbeat $script:OpenPathLabActiveLock.File $script:OpenPathLabActiveLock.Owner | Out-Null
    }
    catch { }
}

function ConvertTo-OpenPathLabShellArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-OpenPathLabSsh {
    param(
        [Parameter(Mandatory = $true)][string]$SshCommand,
        [Parameter(Mandatory = $true)][string]$SshHost,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$InputText = ''
    )
    $remote = ($ArgumentList | ForEach-Object { ConvertTo-OpenPathLabShellArgument -Value ([string]$_) }) -join ' '
    $sshArguments = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', $SshHost, $remote)
    if ([string]::IsNullOrEmpty($InputText)) {
        return (& $SshCommand @sshArguments 2>&1 | Out-String)
    }
    return ($InputText | & $SshCommand @sshArguments 2>&1 | Out-String)
}

function ConvertFrom-OpenPathLabJsonText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { throw 'desktop-lab-guest-query-failed' }
    try { return ($Text.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'desktop-lab-guest-query-failed' }
}

function Format-OpenPathLabGuestErrorDetail {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 300
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $detail = [string]$Text
    $detail = $detail -replace '/w/[^/\s?#]+/whitelist\.txt', '/w/[redacted]/whitelist.txt'
    $detail = $detail -replace '(?i)(token=)[^&\s]+', '$1[redacted]'
    $detail = ($detail -replace '[\r\n\t]+', ' ').Trim()
    if ($detail.Length -gt $MaxLength) { $detail = $detail.Substring(0, $MaxLength) + '...' }
    return $detail
}

function Invoke-OpenPathLabQgaScript {
    param(
        [Parameter(Mandatory = $true)][string]$SshCommand,
        [Parameter(Mandatory = $true)][string]$SshHost,
        [Parameter(Mandatory = $true)][int]$Vmid,
        [Parameter(Mandatory = $true)][string]$PowerShell,
        [int]$TimeoutSeconds = 120,
        [int]$Attempts = 4
    )
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($PowerShell))
    $arguments = @('qm', 'guest', 'exec', [string]$Vmid, '--timeout', [string]$TimeoutSeconds, '--', 'powershell.exe', '-NoProfile', '-EncodedCommand', $encoded)
    # The guest agent is briefly unavailable while a requested reboot is still
    # settling. Retry transient query failures instead of failing the phase.
    $lastError = $null
    for ($attempt = 1; $attempt -le [Math]::Max(1, $Attempts); $attempt++) {
        try {
            $raw = Invoke-OpenPathLabSsh -SshCommand $SshCommand -SshHost $SshHost -ArgumentList $arguments
            $result = ConvertFrom-OpenPathLabJsonText -Text $raw
            $exitCode = Get-OpenPathLabField -InputObject $result -Name 'exitcode'
            $guestError = Format-OpenPathLabGuestErrorDetail -Text ([string](Get-OpenPathLabField -InputObject $result -Name 'err-data'))
            if ($null -ne $exitCode -and [int]$exitCode -ne 0) {
                throw "desktop-lab-guest-query-failed exitcode=$([int]$exitCode) err=$guestError"
            }
            $output = Get-OpenPathLabField -InputObject $result -Name 'out-data'
            if ($null -eq $output) {
                throw "desktop-lab-guest-query-failed exitcode=missing-output err=$guestError"
            }
            return [string]$output
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds (3 * $attempt) }
        }
    }
    throw $lastError
}

function Get-OpenPathLabGuestOsInfo {
    param([string]$SshCommand, [string]$SshHost, [int]$Vmid)
    $script = @'
$cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
[ordered]@{ productType = 'client'; editionId = [string]$cv.EditionID; productName = [string]$cv.ProductName; version = [string]$cv.DisplayVersion; build = "$($cv.CurrentBuild).$($cv.UBR)"; architecture = [string]$env:PROCESSOR_ARCHITECTURE } | ConvertTo-Json -Compress
'@
    # The guest agent can restart while Windows finishes booting; this query is
    # cheap and idempotent, so allow a full boot window of retries.
    $output = Invoke-OpenPathLabQgaScript -SshCommand $SshCommand -SshHost $SshHost -Vmid $Vmid -PowerShell $script -Attempts 15
    return (ConvertFrom-OpenPathLabJsonText -Text $output)
}

function Get-OpenPathLabGuestBootId {
    param([string]$SshCommand, [string]$SshHost, [int]$Vmid)
    $script = "([datetime](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToUniversalTime().ToString('o')"
    $output = Invoke-OpenPathLabQgaScript -SshCommand $SshCommand -SshHost $SshHost -Vmid $Vmid -PowerShell $script -Attempts 15
    $bootId = ($output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($bootId)) { throw 'desktop-lab-guest-query-failed' }
    return $bootId
}

function Invoke-OpenPathProxmoxLabLockRelease {
    <#
    .SYNOPSIS
        Releases the desktop-survival lab lock when the given workflow run owns it.
    .DESCRIPTION
        A cancelled workflow run can leave the remote lock directory behind and
        block every later scenario until the TTL expires.  Probe each configured
        scenario owner for this run and release only the lock entries that
        belong to it; another run's lock is left untouched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$RunAttempt
    )
    $lockFile = [string](Get-OpenPathLabField -InputObject $Config -Name 'lockFile')
    $scenarios = Get-OpenPathLabField -InputObject $Config -Name 'scenarios'
    $released = @()
    foreach ($property in @($scenarios.PSObject.Properties)) {
        $owner = "$RunId/$RunAttempt/$([string]$property.Name)"
        try {
            if (& $Transport.ReleaseLock $lockFile $owner) { $released += [string]$property.Name }
        }
        catch {}
    }
    return @($released)
}

function Invoke-OpenPathProxmoxLabStaleLockReclaim {
    <#
    .SYNOPSIS
        Reclaims the desktop-survival lab lock from a finished workflow run.
    .DESCRIPTION
        A lock left behind by a dead run blocks every later scenario until the
        TTL expires.  Read the current lock owner and reclaim it only when all
        of these hold: the owner has the canonical
        <runId>/<runAttempt>/<scenario> shape, the owning run is not active,
        and the compare-and-delete release confirms ownership.  A lock owned by
        the same run at an earlier attempt belongs to a cancelled or failed
        attempt and counts as finished, so a re-run reclaims its own leftover
        lock; the current attempt stays active.  Manual or local lab sessions
        (a non-canonical owner) are never reclaimed, and an unknown run state
        fails closed as active.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Transport,
        [Parameter(Mandatory = $true)][scriptblock]$IsRunActive,
        [Parameter(Mandatory = $true)][string]$CurrentRunId,
        [Parameter(Mandatory = $true)][int]$CurrentRunAttempt
    )
    if (-not $Transport.Contains('ReadLockOwner')) { return 'unsupported' }
    $lockFile = [string](Get-OpenPathLabField -InputObject $Config -Name 'lockFile')
    $owner = ''
    try { $owner = ([string](& $Transport.ReadLockOwner $lockFile)).Trim() }
    catch { return 'release-failed' }
    if ([string]::IsNullOrWhiteSpace($owner)) { return 'free' }
    if ($owner -notmatch '^(\d+)/(\d+)/[A-Za-z0-9._-]+$') { return 'foreign-owner' }
    $runId = [string]$Matches[1]
    $ownerAttempt = [int]$Matches[2]
    if ($runId -eq $CurrentRunId) {
        if ($ownerAttempt -ge $CurrentRunAttempt) { return 'active-owner' }
    }
    else {
        $active = $true
        try { $active = [bool](& $IsRunActive $runId) }
        catch { $active = $true }
        if ($active) { return 'active-owner' }
    }
    try {
        if (& $Transport.ReleaseLock $lockFile $owner) { return "reclaimed:$owner" }
    }
    catch { return 'release-failed' }
    return 'release-failed'
}

function New-OpenPathProxmoxLabTransport {
    <#
    .SYNOPSIS
        Builds the real Proxmox transport for a validated lab configuration.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Config)
    $lab = @{
        SshCommand      = [string](Get-OpenPathLabField -InputObject $Config -Name 'sshCommand')
        ScpCommand      = [string](Get-OpenPathLabField -InputObject $Config -Name 'scpCommand')
        SshHost         = [string](Get-OpenPathLabField -InputObject $Config -Name 'sshHost')
        HostAddress     = [string](Get-OpenPathLabField -InputObject $Config -Name 'hostAddress')
        HostStagingRoot = [string](Get-OpenPathLabField -InputObject $Config -Name 'hostStagingRoot')
        HttpPort        = [int](Get-OpenPathLabField -InputObject $Config -Name 'httpPort')
        Scratch         = @{ HttpServerPid = $null }
    }
    if ($lab.HttpPort -le 0) { $lab.HttpPort = 18080 }
    # GetNewClosure() re-binds each transport scriptblock to a fresh dynamic
    # module, which does not see this module's internal functions. These
    # helpers keep module session-state affinity, so closures can call them.
    $h = @{
        Ssh = { param($SshCommand, $SshHost, $ArgumentList, $InputText) Invoke-OpenPathLabSsh -SshCommand $SshCommand -SshHost $SshHost -ArgumentList $ArgumentList -InputText $InputText }
        Scp = { param($ScpCommand, $SshHost, $LocalPath, $RemotePath) & $ScpCommand '-o' 'BatchMode=yes' '-q' $LocalPath "$SshHost`:$RemotePath" 2>&1 | Out-String }
        Qga = { param($SshCommand, $SshHost, $Vmid, $PowerShell, $TimeoutSeconds = 120, $Attempts = 4) Invoke-OpenPathLabQgaScript -SshCommand $SshCommand -SshHost $SshHost -Vmid $Vmid -PowerShell $PowerShell -TimeoutSeconds $TimeoutSeconds -Attempts $Attempts }
        GuestOsInfo = { param($SshCommand, $SshHost, $Vmid) Get-OpenPathLabGuestOsInfo -SshCommand $SshCommand -SshHost $SshHost -Vmid $Vmid }
        GuestBootId = { param($SshCommand, $SshHost, $Vmid) Get-OpenPathLabGuestBootId -SshCommand $SshCommand -SshHost $SshHost -Vmid $Vmid }
    }
    $transport = @{}
    $transport.InvokeHostCommand = {
        param($ArgumentList, $InputText = '')
        return (& $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList $ArgumentList -InputText $InputText)
    }.GetNewClosure()
    $transport.CopyFileToHost = {
        param($LocalPath, $RemotePath)
        return (& $h.Scp $lab.ScpCommand $lab.SshHost $LocalPath $RemotePath)
    }.GetNewClosure()
    # Single lock implementation, shared with the bats test and the manual
    # utility: tests/e2e/ci/controllers/proxmox-lab-lock.sh (Phase 3A G3).
    $lockScriptPath = Join-Path $PSScriptRoot 'proxmox-lab-lock.sh'
    $transport.EnsureLock = {
        param($LockFile, $Owner, $TtlSeconds, $WaitSeconds = 900)
        $script = if (Test-Path -LiteralPath $lockScriptPath) { Get-Content -LiteralPath $lockScriptPath -Raw } else { '' }
        if (-not $script) { throw 'desktop-lab-lock-script-missing' }
        $output = & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('bash', '-s', '--', 'acquire', $LockFile, $Owner, [string]$TtlSeconds, [string]$WaitSeconds) -InputText $script
        return $output.Trim() -eq 'acquired'
    }.GetNewClosure()
    $transport.UpdateLockHeartbeat = {
        param($LockFile, $Owner)
        $script = if (Test-Path -LiteralPath $lockScriptPath) { Get-Content -LiteralPath $lockScriptPath -Raw } else { '' }
        if (-not $script) { return $false }
        $output = & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('bash', '-s', '--', 'renew', $LockFile, $Owner) -InputText $script
        return $output.Trim() -eq 'renewed'
    }.GetNewClosure()
    $transport.ReleaseLock = {
        param($LockFile, $Owner)
        $script = @'
set -u
lock_dir="$1"
owner="$2"
if [ -f "$lock_dir/owner" ] && [ "$(cat "$lock_dir/owner")" = "$owner" ]; then
  rm -rf "$lock_dir"
  echo released
else
  echo not-owner
fi
'@
        $output = & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('bash', '-s', '--', $LockFile, $Owner) -InputText $script
        return $output.Trim() -eq 'released'
    }.GetNewClosure()
    $transport.ReadLockOwner = {
        param($LockFile)
        $script = @'
set -u
lock_dir="$1"
if [ -f "$lock_dir/owner" ]; then cat "$lock_dir/owner"; fi
'@
        $output = & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('bash', '-s', '--', $LockFile) -InputText $script
        return $output.Trim()
    }.GetNewClosure()
    $transport.GetVmStatus = {
        param($Vmid)
        $output = & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('qm', 'status', [string]$Vmid)
        if ($output -match 'status:\s*(\S+)') { return $Matches[1] }
        return 'unknown'
    }.GetNewClosure()
    $transport.StopVm = {
        param($Vmid)
        & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('qm', 'stop', [string]$Vmid, '--timeout', '60') | Out-Null
    }.GetNewClosure()
    $transport.StartVm = {
        param($Vmid)
        & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('qm', 'start', [string]$Vmid) | Out-Null
    }.GetNewClosure()
    $transport.RollbackVm = {
        param($Vmid, $Snapshot)
        & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('qm', 'rollback', [string]$Vmid, [string]$Snapshot) | Out-Null
    }.GetNewClosure()
    $transport.WaitGuestReady = {
        param($Vmid, $TimeoutSeconds)
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            try {
                $output = & $h.Qga $lab.SshCommand $lab.SshHost -Vmid ([int]$Vmid) -PowerShell "Write-Output 'ready'" -TimeoutSeconds 30
                if ($output -match 'ready') { return $true }
            }
            catch {}
            Start-Sleep -Seconds 3
        }
        return $false
    }.GetNewClosure()
    $transport.GetGuestOsInfo = {
        param($Vmid)
        & $h.GuestOsInfo -SshCommand $lab.SshCommand -SshHost $lab.SshHost -Vmid ([int]$Vmid)
    }.GetNewClosure()
    $transport.GetGuestBootId = {
        param($Vmid)
        & $h.GuestBootId -SshCommand $lab.SshCommand -SshHost $lab.SshHost -Vmid ([int]$Vmid)
    }.GetNewClosure()
    $transport.RequestGuestReboot = {
        param($Vmid)
        try {
            $trueScript = "& shutdown.exe /r /t 2 /f | Out-Null"
            & $h.Qga $lab.SshCommand $lab.SshHost -Vmid ([int]$Vmid) -PowerShell $trueScript -TimeoutSeconds 30 | Out-Null
        }
        catch {}
    }.GetNewClosure()
    $transport.WaitGuestRebooted = {
        param($Vmid, $PreviousBootId, $TimeoutSeconds)
        Start-Sleep -Seconds 5
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            try {
                $bootId = & $h.GuestBootId -SshCommand $lab.SshCommand -SshHost $lab.SshHost -Vmid ([int]$Vmid)
                if ($bootId -ne $PreviousBootId) { return $bootId }
            }
            catch {}
            Start-Sleep -Seconds 3
        }
        throw 'desktop-lab-reboot-timeout'
    }.GetNewClosure()
    $transport.PublishArtifact = {
        param($StagingDir, $LocalPath)
        $leaf = Split-Path -Leaf $LocalPath
        & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('mkdir', '-p', [string]$StagingDir) | Out-Null
        $target = "$($lab.SshHost):$StagingDir/$leaf"
        & $lab.ScpCommand -q $LocalPath $target 2>&1 | Out-String | Out-Null
        if (-not $lab.Scratch.HttpServerPid) {
            $serverScript = @'
set -u
staging="$1"
port="$2"
address="$3"
nohup python3 -m http.server "$port" --bind "$address" --directory "$staging" >/dev/null 2>&1 &
echo $!
'@
            $pidOutput = & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('bash', '-s', '--', [string]$StagingDir, [string]$lab.HttpPort, [string]$lab.HostAddress) -InputText $serverScript
            $pidText = ($pidOutput.Trim() -split "`n" | Select-Object -Last 1).Trim()
            $pidValue = 0
            if ([int]::TryParse($pidText, [ref]$pidValue)) { $lab.Scratch.HttpServerPid = $pidValue }
        }
        return [pscustomobject]@{ url = "http://$($lab.HostAddress):$($lab.HttpPort)/$leaf" }
    }.GetNewClosure()
    $transport.RemoveHostStaging = {
        param($StagingDir)
        if ($lab.Scratch.HttpServerPid) {
            try { & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('kill', [string]$lab.Scratch.HttpServerPid) | Out-Null } catch {}
            $lab.Scratch.HttpServerPid = $null
        }
        & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('rm', '-rf', [string]$StagingDir) | Out-Null
    }.GetNewClosure()
    $transport.DownloadGuestArtifact = {
        param($Vmid, $Url, $GuestPath)
        $script = @'
$url = '<URL>'
$guestPath = '<GUESTPATH>'
$parent = Split-Path -Parent $guestPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $guestPath -ErrorAction Stop
Write-Output 'downloaded'
'@
        $script = $script.Replace('<URL>', ([string]$Url).Replace("'", "''")).Replace('<GUESTPATH>', ([string]$GuestPath).Replace("'", "''"))
        $output = & $h.Qga $lab.SshCommand $lab.SshHost -Vmid ([int]$Vmid) -PowerShell $script -TimeoutSeconds 600
        if ($output -notmatch 'downloaded') { throw 'desktop-lab-guest-download-failed' }
    }.GetNewClosure()
    $transport.GetGuestFileSha256 = {
        param($Vmid, $GuestPath)
        $script = "(Get-FileHash -LiteralPath '" + ([string]$GuestPath).Replace("'", "''") + "' -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()"
        $output = & $h.Qga $lab.SshCommand $lab.SshHost -Vmid ([int]$Vmid) -PowerShell $script
        $match = [regex]::Match($output, '[0-9a-fA-F]{64}')
        if (-not $match.Success) { throw 'desktop-lab-guest-query-failed' }
        return $match.Value.ToLowerInvariant()
    }.GetNewClosure()
    $transport.RemoveGuestStaging = {
        param($Vmid, $GuestPath)
        $script = "Remove-Item -LiteralPath '" + ([string]$GuestPath).Replace("'", "''") + "' -Recurse -Force -ErrorAction SilentlyContinue; Write-Output 'removed'"
        $output = & $h.Qga $lab.SshCommand $lab.SshHost -Vmid ([int]$Vmid) -PowerShell $script -TimeoutSeconds 300
        return $output -match 'removed'
    }.GetNewClosure()
    $transport.CaptureScreendump = {
        param($Vmid, $LocalPath)
        $hostDirectory = $lab.HostStagingRoot
        $hostDump = "$hostDirectory/console-vm$Vmid.ppm"
        try {
            $monitorScript = @'
set -u
dump="$1"
vmid="$2"
printf 'screendump %s\n' "$dump" | qm monitor "$vmid" >/dev/null 2>&1
test -s "$dump"
'@
            & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('mkdir', '-p', $hostDirectory) | Out-Null
            & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('bash', '-s', '--', $hostDump, [string]$Vmid) -InputText $monitorScript | Out-Null
            $parent = Split-Path -Parent $LocalPath
            if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            & $lab.ScpCommand -q "$($lab.SshHost):$hostDump" $LocalPath 2>&1 | Out-String | Out-Null
            if (Test-Path -LiteralPath $LocalPath -PathType Leaf) {
                try { & $h.Ssh $lab.SshCommand $lab.SshHost -ArgumentList @('rm', '-f', $hostDump) | Out-Null } catch {}
                return $true
            }
            return $false
        }
        catch { return $false }
    }.GetNewClosure()
    $transport.InvokeGuestPowerShell = {
        param($Vmid, $Script, $TimeoutSeconds, $Attempts = 4)
        $text = & $h.Qga $lab.SshCommand $lab.SshHost -Vmid ([int]$Vmid) -PowerShell ([string]$Script) -TimeoutSeconds ([int]$TimeoutSeconds) -Attempts ([int]$Attempts)
        return [string]$text
    }.GetNewClosure()
    return $transport
}

Export-ModuleMember -Function Read-OpenPathProxmoxLabConfig, Invoke-OpenPathProxmoxControllerPhase, New-OpenPathProxmoxLabTransport, Test-OpenPathLabBlockedErrorCode, Invoke-OpenPathProxmoxLabLockRelease, Invoke-OpenPathProxmoxLabStaleLockReclaim, Get-OpenPathFirstVisitReportVerdict, Get-OpenPathFirstVisitMetrics, Get-OpenPathFirstVisitHarnessSourcePath, Get-OpenPathFirstVisitSettings
