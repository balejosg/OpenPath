param(
    [ValidateSet('Run')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-captive-portal-navigation')
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:ResultPath = Join-Path $script:ArtifactsRoot 'captive-portal-navigation-result.json'
$script:DnsBeforePath = Join-Path $script:ArtifactsRoot 'captive-portal-dns-before.json'
$script:DnsAfterPath = Join-Path $script:ArtifactsRoot 'captive-portal-dns-after.json'
$script:FirefoxNavigationResultPath = Join-Path $script:ArtifactsRoot 'captive-portal-firefox-navigation-result.json'
$script:CaptivePortalObservationPath = Join-Path $script:ArtifactsRoot 'captive-portal-observation.json'
$script:RecoveryArtifactRoot = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-result'
$script:RecoveryManifestPath = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-result-manifest.json'
$script:FixtureStatePath = 'C:\OpenPath\data\captive-portal-recovery-fixture-state.json'
$script:InstalledOpenPathRoot = 'C:\OpenPath'
$script:InstalledRecoveryScriptPath = 'C:\OpenPath\scripts\Recover-CaptivePortal.ps1'
$script:RecoveryScriptBackupPath = Join-Path $script:ArtifactsRoot 'Recover-CaptivePortal.ps1.product-backup'
$script:FixtureHost = 'nce.127.0.0.1.sslip.io'
$script:FixtureUrl = "http://$script:FixtureHost/"

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:RecoveryArtifactRoot -Force | Out-Null
}

function Get-DnsAddressSnapshot {
    $adapters = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -and $_.ServerAddresses } |
        Sort-Object InterfaceAlias |
        ForEach-Object {
            [pscustomobject]@{
                interfaceAlias = [string]$_.InterfaceAlias
                interfaceIndex = [int]$_.InterfaceIndex
                serverAddresses = @($_.ServerAddresses | ForEach-Object { [string]$_ })
            }
        })

    return [pscustomobject]@{
        capturedAt = (Get-Date).ToString('o')
        adapters = $adapters
    }
}

function Test-DnsSnapshotHasNonAcrylicServer {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $servers = @(
        $Snapshot.adapters |
            ForEach-Object { @($_.serverAddresses) } |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ }
    )

    return @($servers | Where-Object { $_ -ne '127.0.0.1' -and $_ -ne '::1' }).Count -gt 0
}

function Save-Json {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 12
    )

    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-ProtectedModeBlocksFixtureHost {
    $result = [pscustomobject]@{
        host = $script:FixtureHost
        server = '127.0.0.1'
        blocked = $false
        addresses = @()
        error = ''
    }

    try {
        $answers = @(Resolve-DnsName -Name $script:FixtureHost -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
        $result.addresses = @($answers | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
        $result.blocked = $false
    }
    catch {
        $result.blocked = $true
        $result.error = [string]$_
    }

    return $result
}

function Find-NativeHostScriptPath {
    $candidatePaths = @(
        'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.ps1',
        (Join-Path $script:RepoRoot 'windows\scripts\OpenPath-NativeHost.ps1')
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return $candidatePath
        }
    }

    throw 'OpenPath native host script was not found.'
}

function Invoke-NativeHostAction {
    param([Parameter(Mandatory = $true)][hashtable]$Message)

    $nativeHostScriptPath = Find-NativeHostScriptPath
    $requestJson = $Message | ConvertTo-Json -Compress -Depth 6
    $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestJson)
    $lengthBytes = [System.BitConverter]::GetBytes([int]$requestBytes.Length)
    $inputPath = Join-Path $script:ArtifactsRoot 'native-host-request.bin'
    $outputPath = Join-Path $script:ArtifactsRoot 'native-host-response.bin'
    $errorPath = Join-Path $script:ArtifactsRoot 'native-host-response.err.log'

    [System.IO.File]::WriteAllBytes($inputPath, [byte[]]($lengthBytes + $requestBytes))
    Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $nativeHostScriptPath) `
        -RedirectStandardInput $inputPath `
        -RedirectStandardOutput $outputPath `
        -RedirectStandardError $errorPath `
        -PassThru `
        -WindowStyle Hidden

    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'Native host recovery action timed out.'
    }

    $stderr = if (Test-Path -LiteralPath $errorPath) { Get-Content -LiteralPath $errorPath -Raw } else { '' }
    $process.Refresh()
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    if ($exitCode -ne 0) {
        throw "Native host recovery action exited with $($exitCode): $stderr"
    }

    $responseBytes = [System.IO.File]::ReadAllBytes($outputPath)
    if ($responseBytes.Length -lt 4) {
        throw 'Native host recovery action did not return a framed response.'
    }

    $responseLength = [System.BitConverter]::ToInt32($responseBytes, 0)
    if ($responseLength -le 0 -or $responseBytes.Length -lt (4 + $responseLength)) {
        throw 'Native host recovery action returned an invalid response frame.'
    }

    $responseJson = [System.Text.Encoding]::UTF8.GetString($responseBytes, 4, $responseLength)
    return ($responseJson | ConvertFrom-Json)
}

function Copy-RecoveryResultArtifact {
    param([AllowNull()][object]$NativeResponse)

    $files = @()
    $requestId = if ($NativeResponse -and $NativeResponse.PSObject.Properties['requestId']) {
        [string]$NativeResponse.requestId
    }
    else {
        ''
    }

    if ($requestId -and $requestId -match '^[A-Za-z0-9_.-]+$') {
        $sourcePath = Join-Path 'C:\OpenPath\data\captive-portal-recovery-result' "$requestId.json"
        $targetPath = Join-Path $script:RecoveryArtifactRoot "$requestId.json"
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            $files += "captive-portal-recovery-result\$requestId.json"
        }
    }

    Save-Json -Value ([pscustomobject]@{
        files = $files
        requestId = $requestId
        sourceRoot = 'C:\OpenPath\data\captive-portal-recovery-result'
    }) -Path $script:RecoveryManifestPath

    return $files
}

function Copy-OpenPathDirectRunnerNativeArtifact {
    param([Parameter(Mandatory = $true)][string]$ArtifactName)

    $candidateRoots = @(
        (Join-Path $script:RepoRoot 'windows\scripts'),
        (Join-Path $script:RepoRoot 'windows\lib'),
        (Join-Path $script:RepoRoot 'windows\lib\internal')
    )
    $sourcePath = $candidateRoots |
        ForEach-Object { Join-Path $_ $ArtifactName } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $sourcePath) {
        throw "Native host artifact was not found in direct-runner overlay: $ArtifactName"
    }

    $nativeRoot = Join-Path $script:InstalledOpenPathRoot 'browser-extension\firefox\native'
    New-Item -ItemType Directory -Path $nativeRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $nativeRoot $ArtifactName) -Force
}

function Stage-OpenPathRuntimeForDirectRunner {
    $installedLibRoot = Join-Path $script:InstalledOpenPathRoot 'lib'
    $installedScriptRoot = Join-Path $script:InstalledOpenPathRoot 'scripts'
    New-Item -ItemType Directory -Path $installedLibRoot, $installedScriptRoot -Force | Out-Null

    Copy-Item -Path (Join-Path $script:RepoRoot 'windows\lib\*') -Destination $installedLibRoot -Recurse -Force
    Copy-Item `
        -LiteralPath (Join-Path $script:RepoRoot 'windows\scripts\Recover-CaptivePortal.ps1') `
        -Destination $script:InstalledRecoveryScriptPath `
        -Force

    foreach ($artifactName in @(
            'OpenPath-NativeHost.ps1',
            'OpenPath-NativeHost.cmd',
            'CapabilityStorage.ps1',
            'RequestSetup.State.psm1',
            'Common.Redaction.ps1',
            'RuntimeDependency.Policy.ps1',
            'RuntimeDependency.Queue.ps1',
            'RuntimeDependency.Overlay.ps1',
            'TaskRunner.ps1',
            'NativeHost.State.ps1',
            'NativeHost.Protocol.ps1',
            'NativeHost.Actions.ps1'
        )) {
        Copy-OpenPathDirectRunnerNativeArtifact -ArtifactName $artifactName
    }

    Import-Module (Join-Path $script:RepoRoot 'windows\lib\Services.psm1') -Force
    Register-OpenPathTask | Out-Null
}

function Install-LocalOnlyCaptivePortalRecoveryFixture {
    if (-not (Test-Path -LiteralPath $script:InstalledRecoveryScriptPath)) {
        throw "Installed recovery script was not found: $script:InstalledRecoveryScriptPath"
    }

    Copy-Item -LiteralPath $script:InstalledRecoveryScriptPath -Destination $script:RecoveryScriptBackupPath -Force
    $content = Get-Content -LiteralPath $script:InstalledRecoveryScriptPath -Raw
    if ($content -match 'direct-runner-captive-portal-navigation') {
        throw 'Installed recovery script already contains the direct-runner fixture bypass.'
    }

    $needle = 'return (Test-OpenPathCaptivePortalState -TimeoutSec 3)'
    if (-not $content.Contains($needle)) {
        throw 'Installed recovery script does not contain the real captive portal state probe.'
    }

    $fixtureProbe = @'
$fixturePath = Join-Path (Join-Path $OpenPathRoot 'data') 'captive-portal-recovery-fixture-state.json'
if (Test-Path $fixturePath -ErrorAction SilentlyContinue) {
    $fixture = Get-Content $fixturePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$fixture.purpose -eq 'direct-runner-captive-portal-navigation') {
        if ($fixture.PSObject.Properties['expiresAtUtc'] -and $fixture.expiresAtUtc) {
            $expiresAtUtc = ([DateTimeOffset]::Parse([string]$fixture.expiresAtUtc)).UtcDateTime
            if ($expiresAtUtc -lt [DateTime]::UtcNow) {
                return (Test-OpenPathCaptivePortalState -TimeoutSec 3)
            }
        }
        $state = [string]$fixture.state
        if ($state -in @('Portal', 'Authenticated', 'NoNetwork')) {
            Write-OpenPathLog "Captive portal recovery: using direct-runner local-only fixture state $state" -Level WARN
            return $state
        }
    }
}

    return (Test-OpenPathCaptivePortalState -TimeoutSec 3)
'@

    $patched = $content.Replace($needle, $fixtureProbe)
    Set-Content -LiteralPath $script:InstalledRecoveryScriptPath -Value $patched -Encoding ASCII

    $fixtureRoot = Split-Path $script:FixtureStatePath -Parent
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Save-Json -Value ([pscustomobject]@{
        purpose = 'direct-runner-captive-portal-navigation'
        state = 'Portal'
        expiresAtUtc = ([DateTime]::UtcNow.AddMinutes(5)).ToString('o')
        fixtureDoesNotProveRealWeduCaptiveDns = $true
    }) -Path $script:FixtureStatePath
}

function Restore-LocalOnlyCaptivePortalRecoveryFixture {
    Remove-Item -LiteralPath $script:FixtureStatePath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:RecoveryScriptBackupPath) {
        Copy-Item -LiteralPath $script:RecoveryScriptBackupPath -Destination $script:InstalledRecoveryScriptPath -Force
    }
}

function Copy-CaptivePortalObservationArtifact {
    $sourcePath = 'C:\OpenPath\data\captive-portal-observation.json'
    if (Test-Path -LiteralPath $sourcePath) {
        Copy-Item -LiteralPath $sourcePath -Destination $script:CaptivePortalObservationPath -Force
        return 'captive-portal-observation.json'
    }

    return ''
}

function Get-PortalConcurrencyObservation {
    $activeMarkerPath = 'C:\OpenPath\data\captive-portal-active.json'
    $activeMarkers = @($activeMarkerPath | Where-Object { Test-Path -LiteralPath $_ })
    $activeMarker = $null
    if (Test-Path -LiteralPath $activeMarkerPath) {
        try {
            $activeMarker = Get-Content -LiteralPath $activeMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $activeMarker = [pscustomobject]@{ readError = [string]$_ }
        }
    }
    $task = Get-ScheduledTask -TaskName 'OpenPath-CaptivePortalRecovery' -ErrorAction SilentlyContinue
    $taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName 'OpenPath-CaptivePortalRecovery' -ErrorAction SilentlyContinue } else { $null }
    $latestResult = Get-ChildItem -LiteralPath 'C:\OpenPath\data\captive-portal-recovery-result' -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $latestPayload = $null
    if ($latestResult) {
        try {
            $latestPayload = Get-Content -LiteralPath $latestResult.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $latestPayload = [pscustomobject]@{ readError = [string]$_ }
        }
    }
    $hostsPath = 'C:\Program Files (x86)\Acrylic DNS Proxy\AcrylicHosts.txt'
    $hostsSnapshot = ''
    if (Test-Path -LiteralPath $hostsPath) {
        $hostsSnapshot = (Get-Content -LiteralPath $hostsPath -Raw -ErrorAction SilentlyContinue) `
            -replace '(?m)^(\s*\d{1,3}(?:\.\d{1,3}){3}\s+).+$', '$1<redacted-host>'
    }

    return [pscustomobject]@{
        watchdogRecoveryConcurrencyHook = 'Portal watchdog+recovery concurrency observation'
        expectedOneActivePortalMarker = ($activeMarkers.Count -eq 1)
        activePortalMarkerCount = $activeMarkers.Count
        activePortalMarkerPath = $activeMarkerPath
        marker = [pscustomobject]@{
            mode = if ($activeMarker -and $activeMarker.PSObject.Properties['mode']) { [string]$activeMarker.mode } else { '' }
            allowedHosts = if ($activeMarker -and $activeMarker.PSObject.Properties['allowedHosts']) { @($activeMarker.allowedHosts) } else { @() }
            upstreamDns = [pscustomobject]@{
                source = if ($activeMarker -and $activeMarker.PSObject.Properties['upstreamDnsSource']) { [string]$activeMarker.upstreamDnsSource } else { '' }
                usableForLimited = if ($activeMarker -and $activeMarker.PSObject.Properties['upstreamUsableForLimited']) { [bool]$activeMarker.upstreamUsableForLimited } else { $null }
            }
        }
        recentSuccessSource = if ($latestPayload -and $latestPayload.PSObject.Properties['recentSuccessSource']) { [string]$latestPayload.recentSuccessSource } else { '' }
        exactHostEnableAttempted = if ($latestPayload -and $latestPayload.PSObject.Properties['triggerHost']) { -not [string]::IsNullOrWhiteSpace([string]$latestPayload.triggerHost) } else { $null }
        dnsResetAt = if ($activeMarker -and $activeMarker.PSObject.Properties['dnsResetAt']) { [string]$activeMarker.dnsResetAt } else { '' }
        upstreamCapturedAt = if ($activeMarker -and $activeMarker.PSObject.Properties['upstreamCapturedAt']) { [string]$activeMarker.upstreamCapturedAt } else { '' }
        passthroughEgress = if ($activeMarker -and $activeMarker.PSObject.Properties['passthroughEgress']) { $activeMarker.passthroughEgress } else { $null }
        acrylicHostsSnapshotRedacted = $hostsSnapshot
        noFailedTask = if ($taskInfo) { [int]$taskInfo.LastTaskResult -eq 0 } else { $false }
        taskLastResult = if ($taskInfo) { [int]$taskInfo.LastTaskResult } else { $null }
        noPrematureExit = Test-Path -LiteralPath $activeMarkerPath
    }
}

function Invoke-FirefoxRetryObservation {
    param([AllowNull()][object]$NativeResponse)

    $retryAttempted = $false
    $errorText = ''
    try {
        $firefoxPath = @(
            "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
            "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

        if ($firefoxPath) {
            $retryAttempted = $true
            $process = Start-Process -FilePath $firefoxPath -ArgumentList @('-headless', '-url', $script:FixtureUrl) -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 5
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        else {
            $errorText = 'Firefox executable was not found; native recovery evidence is still recorded.'
        }
    }
    catch {
        $errorText = [string]$_
    }

    $navigationResult = [pscustomobject]@{
        fixtureUrl = $script:FixtureUrl
        retryAttempted = $retryAttempted
        browserObservationLevel = 'headless-process-launch-only'
        blockedByOpenPath = $null
        didNotLandOnBlockedPage = $null
        note = 'This runner does not inspect Firefox final URL. Firefox retry suppression is covered by extension tests; target-platform evidence must inspect the real browser.'
        nativeRecoverySuccess = if ($NativeResponse -and $NativeResponse.PSObject.Properties['success']) { [bool]$NativeResponse.success } else { $false }
        nativeRequestId = if ($NativeResponse -and $NativeResponse.PSObject.Properties['requestId']) { [string]$NativeResponse.requestId } else { '' }
        error = $errorText
    }
    Save-Json -Value $navigationResult -Path $script:FirefoxNavigationResultPath
    return $navigationResult
}

function Invoke-CaptivePortalNavigationRun {
    Ensure-ArtifactRoot

    $fixtureSummary = [pscustomobject]@{
        fixtureHost = $script:FixtureHost
        fixtureUrl = $script:FixtureUrl
        fixtureDoesNotProveRealWeduCaptiveDns = $true
        summary = 'This fixture validates the captive portal recovery+retry channel only. It does not prove real WEDU captive DNS behavior for nce.wedu.comunidad.madrid.'
    }

    $dnsBefore = Get-DnsAddressSnapshot
    Save-Json -Value $dnsBefore -Path $script:DnsBeforePath

    $protectedBlock = Test-ProtectedModeBlocksFixtureHost
    $nativeResponse = $null
    if (-not $protectedBlock.blocked) {
        throw "Protected mode did not block fixture host $script:FixtureHost through 127.0.0.1."
    }

    try {
        Stage-OpenPathRuntimeForDirectRunner
        Install-LocalOnlyCaptivePortalRecoveryFixture
        $nativeResponse = Invoke-NativeHostAction -Message @{
            action = 'recover-captive-portal-navigation'
            triggerHost = $script:FixtureHost
            tabId = 1
        }
    }
    finally {
        Restore-LocalOnlyCaptivePortalRecoveryFixture
    }

    $dnsAfter = Get-DnsAddressSnapshot
    Save-Json -Value $dnsAfter -Path $script:DnsAfterPath
    $dnsRecoveredFromAcrylicOnly = Test-DnsSnapshotHasNonAcrylicServer -Snapshot $dnsAfter
    $recoveryFiles = Copy-RecoveryResultArtifact -NativeResponse $nativeResponse
    $observationArtifact = Copy-CaptivePortalObservationArtifact
    $firefoxNavigation = Invoke-FirefoxRetryObservation -NativeResponse $nativeResponse
    $concurrency = Get-PortalConcurrencyObservation
    $portalActivePath = 'C:\OpenPath\data\captive-portal-active.json'
    $portalModeActive = Test-Path -LiteralPath $portalActivePath
    $nativeStateIsPortal = ([string]$nativeResponse.state -eq 'Portal')
    $nativeRecoveryVerified = [bool]($protectedBlock.blocked -and $portalModeActive -and $nativeResponse.success -and $nativeStateIsPortal)

    $result = [pscustomobject]@{
        profile = 'captive-portal-navigation'
        success = $nativeRecoveryVerified
        evidenceLevel = 'native-recovery-direct-runner'
        nativeRecoveryVerified = $nativeRecoveryVerified
        browserNavigationVerified = $false
        targetPlatformSymptomCleared = $false
        fixture = $fixtureSummary
        protectedModeBlock = $protectedBlock
        nativeAction = $nativeResponse
        portalModeActive = $portalModeActive
        portalActivePath = $portalActivePath
        nativeStateIsPortal = $nativeStateIsPortal
        dnsRecoveredFromAcrylicOnly = $dnsRecoveredFromAcrylicOnly
        recoveryArtifacts = $recoveryFiles
        captivePortalObservationPath = $observationArtifact
        dnsBeforePath = 'captive-portal-dns-before.json'
        dnsAfterPath = 'captive-portal-dns-after.json'
        firefoxNavigationResultPath = 'captive-portal-firefox-navigation-result.json'
        firefoxNavigation = $firefoxNavigation
        concurrency = $concurrency
        writtenAt = (Get-Date).ToString('o')
    }

    Save-Json -Value $result -Path $script:ResultPath
    if (-not $result.success) {
        throw "Captive portal navigation fixture failed. See $script:ResultPath"
    }
}

try {
    switch ($Mode) {
        'Run' {
            Invoke-CaptivePortalNavigationRun
        }
    }
}
catch {
    try {
        Ensure-ArtifactRoot
        if (-not (Test-Path -LiteralPath $script:ResultPath)) {
            Save-Json -Value ([pscustomobject]@{
                profile = 'captive-portal-navigation'
                success = $false
                decision = 'insufficientEvidence'
                fixtureDoesNotProveRealWeduCaptiveDns = $true
                error = [string]$_
                writtenAt = (Get-Date).ToString('o')
            }) -Path $script:ResultPath
        }
    }
    catch {
        Write-Warning "Unable to write captive portal navigation failure artifact: $_"
    }
    Write-Error $_
    exit 1
}
