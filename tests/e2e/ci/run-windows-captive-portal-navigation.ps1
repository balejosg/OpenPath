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
$script:DnsDuringPath = Join-Path $script:ArtifactsRoot 'captive-portal-dns-during.json'
$script:DnsAfterPath = Join-Path $script:ArtifactsRoot 'captive-portal-dns-after.json'
$script:FirefoxNavigationResultPath = Join-Path $script:ArtifactsRoot 'captive-portal-firefox-navigation-result.json'
$script:CaptivePortalObservationPath = Join-Path $script:ArtifactsRoot 'captive-portal-observation.json'
$script:RecoveryArtifactRoot = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-result'
$script:RecoveryManifestPath = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-result-manifest.json'
$script:RecoveryQueueArtifactRoot = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-queue'
$script:RecoveryQueueManifestPath = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-queue-manifest.json'
$script:RecoveryProgressArtifactRoot = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-progress'
$script:RecoveryProgressManifestPath = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-progress-manifest.json'
$script:TaskStatePath = Join-Path $script:ArtifactsRoot 'captive-portal-task-state.json'
$script:ConfigSnapshotPath = Join-Path $script:ArtifactsRoot 'captive-portal-config-snapshot.json'
$script:AcrylicHostsSnapshotPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.captive-portal-snapshot'
$script:AcrylicConfigurationSnapshotPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.captive-portal-snapshot'
$script:MarkerBeforeAuthPath = Join-Path $script:ArtifactsRoot 'captive-portal-marker-before-auth.json'
$script:MarkerAfterAuthPath = Join-Path $script:ArtifactsRoot 'captive-portal-marker-after-auth.json'
$script:FixtureStatePath = 'C:\OpenPath\data\captive-portal-recovery-fixture-state.json'
$script:InstalledOpenPathRoot = 'C:\OpenPath'
$script:InstalledRecoveryScriptPath = 'C:\OpenPath\scripts\Recover-CaptivePortal.ps1'
$script:RecoveryScriptBackupPath = Join-Path $script:ArtifactsRoot 'Recover-CaptivePortal.ps1.product-backup'
$script:FixtureHost = 'nce.127.0.0.1.sslip.io'
$script:FixtureUrl = "http://$script:FixtureHost/"

. (Join-Path $PSScriptRoot 'windows-direct-runtime-staging.ps1')

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:RecoveryArtifactRoot, $script:RecoveryQueueArtifactRoot, $script:RecoveryProgressArtifactRoot -Force | Out-Null
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

function Ensure-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($InputObject.PSObject.Properties[$Name]) {
        if ($null -eq $InputObject.$Name -or ([string]$InputObject.$Name).Trim() -eq '') {
            $InputObject.$Name = $Value
        }
    }
    else {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-RedactedConfigSnapshot {
    param([Parameter(Mandatory = $true)][object]$Config)

    $snapshot = [ordered]@{}
    foreach ($property in @($Config.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($name -match '(?i)(token|secret|password|credential|key)' -or $name -eq 'whitelistUrl') {
            $snapshot[$name] = '<redacted>'
            continue
        }
        $snapshot[$name] = $property.Value
    }
    return [pscustomobject]$snapshot
}

function Ensure-OpenPathDirectRunnerConfig {
    $configPath = Join-Path (Join-Path $script:InstalledOpenPathRoot 'data') 'config.json'
    $configDir = Split-Path $configPath -Parent
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null

    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "OpenPath direct runner config is invalid JSON at ${configPath}: $_"
        }
    }
    else {
        $config = [pscustomobject]@{}
    }

    Ensure-ObjectProperty -InputObject $config -Name 'version' -Value 'direct-runner-captive-portal-navigation'
    Ensure-ObjectProperty -InputObject $config -Name 'apiUrl' -Value ''
    Ensure-ObjectProperty -InputObject $config -Name 'whitelistUrl' -Value ''
    Ensure-ObjectProperty -InputObject $config -Name 'classroomId' -Value 'direct-runner'
    Ensure-ObjectProperty -InputObject $config -Name 'machineName' -Value $env:COMPUTERNAME
    Ensure-ObjectProperty -InputObject $config -Name 'primaryDNS' -Value '8.8.8.8'
    Ensure-ObjectProperty -InputObject $config -Name 'secondaryDNS' -Value '8.8.4.4'
    Ensure-ObjectProperty -InputObject $config -Name 'enableFirewall' -Value $true
    Ensure-ObjectProperty -InputObject $config -Name 'approvedStudentBrowsers' -Value @('Firefox')
    Ensure-ObjectProperty -InputObject $config -Name 'captivePortalDomains' -Value @($script:FixtureHost)

    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
    Save-Json -Value (Get-RedactedConfigSnapshot -Config $config) -Path $script:ConfigSnapshotPath
    return $config
}

function Copy-CaptivePortalEnvironmentSnapshots {
    $files = @()
    $errors = @()

    try {
        $configPath = Join-Path (Join-Path $script:InstalledOpenPathRoot 'data') 'config.json'
        if (Test-Path -LiteralPath $configPath) {
            $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            Save-Json -Value (Get-RedactedConfigSnapshot -Config $config) -Path $script:ConfigSnapshotPath
            $files += 'captive-portal-config-snapshot.json'
        }
    }
    catch {
        $errors += "config: $_"
    }

    try {
        $acrylicPath = $null
        if (Get-Command -Name 'Get-AcrylicPath' -ErrorAction SilentlyContinue) {
            $acrylicPath = Get-AcrylicPath
        }
        if (-not $acrylicPath) {
            $acrylicPath = 'C:\Program Files (x86)\Acrylic DNS Proxy'
        }

        $hostsPath = Join-Path $acrylicPath 'AcrylicHosts.txt'
        if (Test-Path -LiteralPath $hostsPath) {
            Copy-Item -LiteralPath $hostsPath -Destination $script:AcrylicHostsSnapshotPath -Force
            $files += 'AcrylicHosts.txt.captive-portal-snapshot'
        }

        $configurationPath = Join-Path $acrylicPath 'AcrylicConfiguration.ini'
        if (Test-Path -LiteralPath $configurationPath) {
            Copy-Item -LiteralPath $configurationPath -Destination $script:AcrylicConfigurationSnapshotPath -Force
            $files += 'AcrylicConfiguration.ini.captive-portal-snapshot'
        }
    }
    catch {
        $errors += "acrylic: $_"
    }

    return [pscustomobject]@{
        files = @($files)
        errors = @($errors)
    }
}

function Convert-ToScheduledTaskResultCode {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [long]$Value
    }
    catch {
        return $null
    }
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

    $nativeHostTimeoutMs = 150000
    if (-not $process.WaitForExit($nativeHostTimeoutMs)) {
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
    param([AllowNull()][object[]]$NativeResponses)

    $files = @()
    $requestIds = @(
        @($NativeResponses) |
            Where-Object { $_ -and $_.PSObject.Properties['requestId'] } |
            ForEach-Object { [string]$_.requestId } |
            Where-Object { $_ -and $_ -match '^[A-Za-z0-9_.-]+$' } |
            Select-Object -Unique
    )

    foreach ($requestId in $requestIds) {
        $sourcePath = Join-Path 'C:\OpenPath\data\captive-portal-recovery-result' "$requestId.json"
        $targetPath = Join-Path $script:RecoveryArtifactRoot "$requestId.json"
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            $files += "captive-portal-recovery-result\$requestId.json"
        }
    }

    Save-Json -Value ([pscustomobject]@{
        files = $files
        requestIds = @($requestIds)
        sourceRoot = 'C:\OpenPath\data\captive-portal-recovery-result'
    }) -Path $script:RecoveryManifestPath

    return $files
}

function Copy-RecoveryDirectoryArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ArtifactPrefix
    )

    $files = @()
    if (Test-Path -LiteralPath $SourceRoot) {
        New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name)) {
            if ($file.Name -notmatch '^[A-Za-z0-9_.-]+\.json$') {
                continue
            }
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $TargetRoot $file.Name) -Force
            $files += "$ArtifactPrefix\$($file.Name)"
        }
    }

    Save-Json -Value ([pscustomobject]@{
        files = $files
        sourceRoot = $SourceRoot
    }) -Path $ManifestPath

    return $files
}

function Save-CaptivePortalTaskStateArtifact {
    $taskName = 'OpenPath-CaptivePortalRecovery'
    $payload = [ordered]@{
        taskName = $taskName
        taskPresent = $false
        taskState = ''
        taskLastResult = $null
        taskLastResultHex = ''
        capturedAt = (Get-Date).ToString('o')
        error = ''
    }

    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue } else { $null }
        $payload.taskPresent = ($null -ne $task)
        if ($task -and $task.PSObject.Properties['State']) {
            $payload.taskState = [string]$task.State
        }
        if ($taskInfo -and $taskInfo.PSObject.Properties['LastTaskResult']) {
            $lastResult = Convert-ToScheduledTaskResultCode $taskInfo.LastTaskResult
            $payload.taskLastResult = $lastResult
            if ($null -ne $lastResult) {
                $payload.taskLastResultHex = ('0x{0:X8}' -f ([uint32]([long]$lastResult -band 0xffffffff)))
            }
        }
    }
    catch {
        $payload.error = [string]$_
    }

    Save-Json -Value ([pscustomobject]$payload) -Path $script:TaskStatePath
    return 'captive-portal-task-state.json'
}

function Copy-RecoveryDiagnosticArtifacts {
    $queueFiles = Copy-RecoveryDirectoryArtifact `
        -SourceRoot 'C:\OpenPath\data\captive-portal-recovery-queue' `
        -TargetRoot $script:RecoveryQueueArtifactRoot `
        -ManifestPath $script:RecoveryQueueManifestPath `
        -ArtifactPrefix 'captive-portal-recovery-queue'
    $resultFiles = Copy-RecoveryDirectoryArtifact `
        -SourceRoot 'C:\OpenPath\data\captive-portal-recovery-result' `
        -TargetRoot $script:RecoveryArtifactRoot `
        -ManifestPath $script:RecoveryManifestPath `
        -ArtifactPrefix 'captive-portal-recovery-result'
    $progressFiles = Copy-RecoveryDirectoryArtifact `
        -SourceRoot 'C:\OpenPath\data\captive-portal-recovery-progress' `
        -TargetRoot $script:RecoveryProgressArtifactRoot `
        -ManifestPath $script:RecoveryProgressManifestPath `
        -ArtifactPrefix 'captive-portal-recovery-progress'
    $taskState = Save-CaptivePortalTaskStateArtifact

    return [pscustomobject]@{
        queueFiles = @($queueFiles)
        resultFiles = @($resultFiles)
        progressFiles = @($progressFiles)
        queueManifestPath = 'captive-portal-recovery-queue-manifest.json'
        resultManifestPath = 'captive-portal-recovery-result-manifest.json'
        progressManifestPath = 'captive-portal-recovery-progress-manifest.json'
        taskStatePath = $taskState
    }
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
            $expiresAtUtc = ([DateTimeOffset]::Parse([string]$fixture.expiresAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).UtcDateTime
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

function Set-LocalOnlyCaptivePortalRecoveryFixtureState {
    param(
        [ValidateSet('Portal', 'Authenticated', 'NoNetwork')]
        [string]$State
    )

    $payload = if (Test-Path -LiteralPath $script:FixtureStatePath) {
        Get-Content -LiteralPath $script:FixtureStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    else {
        [pscustomobject]@{
            purpose = 'direct-runner-captive-portal-navigation'
            fixtureDoesNotProveRealWeduCaptiveDns = $true
        }
    }

    $payload.state = $State
    $payload.expiresAtUtc = ([DateTime]::UtcNow.AddMinutes(5)).ToString('o')
    Save-Json -Value $payload -Path $script:FixtureStatePath
}

function Clear-LocalOnlyCaptivePortalRecoveryMarker {
    $markerPath = Join-Path (Join-Path $script:InstalledOpenPathRoot 'data') 'captive-portal-active.json'
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
}

function Copy-CaptivePortalObservationArtifact {
    $sourcePath = 'C:\OpenPath\data\captive-portal-observation.json'
    if (Test-Path -LiteralPath $sourcePath) {
        Copy-Item -LiteralPath $sourcePath -Destination $script:CaptivePortalObservationPath -Force
        return 'captive-portal-observation.json'
    }

    return ''
}

function Get-PortalMarkerSnapshot {
    $activeMarkerPath = 'C:\OpenPath\data\captive-portal-active.json'
    if (-not (Test-Path -LiteralPath $activeMarkerPath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $activeMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return [pscustomobject]@{ readError = [string]$_ }
    }
}

function Save-PortalMarkerSnapshot {
    param(
        [AllowNull()][object]$Marker,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $payload = if ($Marker) { $Marker } else { [pscustomobject]@{ active = $false } }
    Save-Json -Value $payload -Path $Path
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

    $taskLastResult = if ($taskInfo) { Convert-ToScheduledTaskResultCode $taskInfo.LastTaskResult } else { $null }

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
        noFailedTask = ($null -ne $taskLastResult) -and ($taskLastResult -eq 0)
        taskLastResult = $taskLastResult
        noPrematureExit = Test-Path -LiteralPath $activeMarkerPath
    }
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Find-GeckoDriverPath {
    $command = Get-Command geckodriver.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidatePaths = @(
        "$env:ChocolateyInstall\bin\geckodriver.exe",
        'C:\ProgramData\chocolatey\bin\geckodriver.exe',
        (Join-Path $script:RepoRoot 'tests\selenium\node_modules\.bin\geckodriver.cmd')
    )
    foreach ($candidatePath in $candidatePaths) {
        if ($candidatePath -and (Test-Path -LiteralPath $candidatePath)) {
            return $candidatePath
        }
    }

    return ''
}

function Invoke-WebDriverJson {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet('Get', 'Post', 'Delete')]
        [string]$Method = 'Get',
        [AllowNull()][object]$Body = $null
    )

    $params = @{
        Uri = $Uri
        Method = $Method
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
    }

    return (Invoke-RestMethod @params)
}

function Test-FirefoxNavigationBlockedByOpenPath {
    param(
        [string]$FinalUrl = '',
        [string]$Title = '',
        [string]$PageSource = ''
    )

    if ($FinalUrl -match '(?i)/blocked/blocked\.html|about:neterror\?e=blockedByPolicy') {
        return $true
    }
    if ($FinalUrl -match '(?i)^moz-extension://') {
        return $true
    }
    if ($Title -match '(?i)OpenPath.*blocked|blocked.*OpenPath') {
        return $true
    }
    if ($PageSource -match '(?i)OpenPath[\s\S]{0,160}(blocked|request access)|blocked[\s\S]{0,160}OpenPath') {
        return $true
    }

    return $false
}

function Invoke-FirefoxNavigationInspection {
    param(
        [Parameter(Mandatory = $true)][string]$FirefoxPath,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $geckoDriverPath = Find-GeckoDriverPath
    if (-not $geckoDriverPath) {
        throw 'geckodriver.exe was not found; cannot inspect Firefox final URL.'
    }

    $port = Get-FreeTcpPort
    $geckoOutPath = Join-Path $script:ArtifactsRoot 'captive-portal-geckodriver.out.log'
    $geckoErrPath = Join-Path $script:ArtifactsRoot 'captive-portal-geckodriver.err.log'
    $geckoArgs = @('--host', '127.0.0.1', '--port', [string]$port)
    $geckoProcess = Start-Process -FilePath $geckoDriverPath `
        -ArgumentList $geckoArgs `
        -RedirectStandardOutput $geckoOutPath `
        -RedirectStandardError $geckoErrPath `
        -PassThru `
        -WindowStyle Hidden

    $sessionId = ''
    try {
        $statusUri = "http://127.0.0.1:$port/status"
        $ready = $false
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            try {
                Invoke-WebDriverJson -Uri $statusUri | Out-Null
                $ready = $true
                break
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $ready) {
            throw 'geckodriver did not become ready for Firefox navigation inspection.'
        }

        $session = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session" -Method Post -Body @{
            capabilities = @{
                alwaysMatch = @{
                    browserName = 'firefox'
                    pageLoadStrategy = 'eager'
                    'moz:firefoxOptions' = @{
                        binary = $FirefoxPath
                        args = @('-headless')
                    }
                }
            }
        }
        $sessionId = if ($session.value -and $session.value.sessionId) { [string]$session.value.sessionId } else { [string]$session.sessionId }
        if (-not $sessionId) {
            throw 'geckodriver did not return a session id.'
        }

        Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/timeouts" -Method Post -Body @{
            implicit = 0
            pageLoad = 10000
            script = 5000
        } | Out-Null

        $navigationError = ''
        try {
            Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/url" -Method Post -Body @{ url = $Url } | Out-Null
        }
        catch {
            $navigationError = [string]$_
        }

        Start-Sleep -Seconds 2
        $finalUrlResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/url"
        $titleResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/title"
        $sourceResult = $null
        try {
            $sourceResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/source"
        }
        catch {
            $sourceResult = [pscustomobject]@{ value = '' }
        }

        $finalUrl = if ($finalUrlResult -and $finalUrlResult.PSObject.Properties['value']) { [string]$finalUrlResult.value } else { '' }
        $title = if ($titleResult -and $titleResult.PSObject.Properties['value']) { [string]$titleResult.value } else { '' }
        $pageSource = if ($sourceResult -and $sourceResult.PSObject.Properties['value']) { [string]$sourceResult.value } else { '' }
        $blocked = Test-FirefoxNavigationBlockedByOpenPath -FinalUrl $finalUrl -Title $title -PageSource $pageSource

        return [pscustomobject]@{
            browserObservationLevel = 'webdriver-final-url'
            geckoDriverPath = $geckoDriverPath
            inspectedFinalUrl = (-not [string]::IsNullOrWhiteSpace($finalUrl))
            finalUrl = $finalUrl
            title = $title
            navigationError = $navigationError
            blockedByOpenPath = $blocked
            didNotLandOnBlockedPage = (-not $blocked -and -not [string]::IsNullOrWhiteSpace($finalUrl))
            geckoDriverOutPath = 'captive-portal-geckodriver.out.log'
            geckoDriverErrPath = 'captive-portal-geckodriver.err.log'
        }
    }
    finally {
        if ($sessionId) {
            try {
                Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId" -Method Delete | Out-Null
            }
            catch { }
        }
        if ($geckoProcess -and -not $geckoProcess.HasExited) {
            Stop-Process -Id $geckoProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-FirefoxRetryObservation {
    param([AllowNull()][object]$NativeResponse)

    $retryAttempted = $false
    $errorText = ''
    $inspection = $null
    try {
        $firefoxPath = @(
            "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
            "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

        if ($firefoxPath) {
            $retryAttempted = $true
            $inspection = Invoke-FirefoxNavigationInspection -FirefoxPath $firefoxPath -Url $script:FixtureUrl
        }
        else {
            $errorText = 'Firefox executable was not found; browser navigation could not be inspected.'
        }
    }
    catch {
        $errorText = [string]$_
    }

    if (-not $inspection) {
        $inspection = [pscustomobject]@{
            browserObservationLevel = 'webdriver-final-url'
            inspectedFinalUrl = $false
            finalUrl = ''
            title = ''
            navigationError = ''
            blockedByOpenPath = $null
            didNotLandOnBlockedPage = $false
            geckoDriverOutPath = 'captive-portal-geckodriver.out.log'
            geckoDriverErrPath = 'captive-portal-geckodriver.err.log'
        }
    }

    $navigationResult = [pscustomobject]@{
        fixtureUrl = $script:FixtureUrl
        retryAttempted = $retryAttempted
        browserObservationLevel = [string]$inspection.browserObservationLevel
        inspectedFinalUrl = [bool]$inspection.inspectedFinalUrl
        finalUrl = [string]$inspection.finalUrl
        title = [string]$inspection.title
        navigationError = [string]$inspection.navigationError
        blockedByOpenPath = $inspection.blockedByOpenPath
        didNotLandOnBlockedPage = [bool]$inspection.didNotLandOnBlockedPage
        nativeRecoverySuccess = if ($NativeResponse -and $NativeResponse.PSObject.Properties['success']) { [bool]$NativeResponse.success } else { $false }
        nativeRequestId = if ($NativeResponse -and $NativeResponse.PSObject.Properties['requestId']) { [string]$NativeResponse.requestId } else { '' }
        geckoDriverOutPath = if ($inspection.PSObject.Properties['geckoDriverOutPath']) { [string]$inspection.geckoDriverOutPath } else { '' }
        geckoDriverErrPath = if ($inspection.PSObject.Properties['geckoDriverErrPath']) { [string]$inspection.geckoDriverErrPath } else { '' }
        error = $errorText
    }
    Save-Json -Value $navigationResult -Path $script:FirefoxNavigationResultPath
    return $navigationResult
}

function Test-BlockedDomainStillBlocked {
    $domain = 'this-should-be-blocked-test-12345.com'
    try {
        $result = Resolve-DnsName -Name $domain -Server 127.0.0.1 -DnsOnly -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            domain = $domain
            blocked = ($null -eq $result)
        }
    }
    catch {
        return [pscustomobject]@{
            domain = $domain
            blocked = $true
            error = [string]$_
        }
    }
}

function Test-AllowedDomainFunctional {
    $domain = 'www.msftconnecttest.com'
    try {
        $answers = @(Resolve-DnsName -Name $domain -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
        return [pscustomobject]@{
            domain = $domain
            functional = ($answers.Count -gt 0)
            addresses = @($answers | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
            error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            domain = $domain
            functional = $false
            addresses = @()
            error = [string]$_
        }
    }
}

function Invoke-CaptivePortalNavigationRun {
    Ensure-ArtifactRoot
    $directRunnerConfig = Ensure-OpenPathDirectRunnerConfig

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
    $nativeReconcileResponse = $null
    $firefoxNavigation = $null
    $environmentSnapshots = $null
    if (-not $protectedBlock.blocked) {
        throw "Protected mode did not block fixture host $script:FixtureHost through 127.0.0.1."
    }

    try {
        Stage-OpenPathDirectRunnerRuntime `
            -RepoRoot $script:RepoRoot `
            -InstalledOpenPathRoot $script:InstalledOpenPathRoot `
            -InstalledRecoveryScriptPath $script:InstalledRecoveryScriptPath
        $environmentSnapshots = Copy-CaptivePortalEnvironmentSnapshots
        Install-LocalOnlyCaptivePortalRecoveryFixture
        Clear-LocalOnlyCaptivePortalRecoveryMarker
        $nativeResponse = Invoke-NativeHostAction -Message @{
            action = 'recover-captive-portal-navigation'
            triggerHost = $script:FixtureHost
            tabId = 1
        }
        $dnsDuring = Get-DnsAddressSnapshot
        Save-Json -Value $dnsDuring -Path $script:DnsDuringPath
        $markerBeforeAuth = Get-PortalMarkerSnapshot
        Save-PortalMarkerSnapshot -Marker $markerBeforeAuth -Path $script:MarkerBeforeAuthPath
        $firefoxNavigation = Invoke-FirefoxRetryObservation -NativeResponse $nativeResponse
        Set-LocalOnlyCaptivePortalRecoveryFixtureState -State Authenticated
        $nativeReconcileResponse = Invoke-NativeHostAction -Message @{
            action = 'recover-captive-portal-navigation'
            operation = 'reconcile'
            portalState = 'Authenticated'
            tabId = 1
        }
    }
    finally {
        Restore-LocalOnlyCaptivePortalRecoveryFixture
    }

    $dnsAfter = Get-DnsAddressSnapshot
    Save-Json -Value $dnsAfter -Path $script:DnsAfterPath
    $markerAfterAuth = Get-PortalMarkerSnapshot
    Save-PortalMarkerSnapshot -Marker $markerAfterAuth -Path $script:MarkerAfterAuthPath
    $dnsRecoveredFromAcrylicOnly = Test-DnsSnapshotHasNonAcrylicServer -Snapshot $dnsAfter
    Copy-RecoveryResultArtifact -NativeResponses @($nativeResponse, $nativeReconcileResponse) | Out-Null
    $recoveryDiagnostics = Copy-RecoveryDiagnosticArtifacts
    $environmentSnapshots = Copy-CaptivePortalEnvironmentSnapshots
    $recoveryFiles = @($recoveryDiagnostics.resultFiles)
    $observationArtifact = Copy-CaptivePortalObservationArtifact
    $concurrency = Get-PortalConcurrencyObservation
    $portalActivePath = 'C:\OpenPath\data\captive-portal-active.json'
    $portalModeActive = Test-Path -LiteralPath $portalActivePath
    $nativeStateIsPortal = ([string]$nativeResponse.state -eq 'Portal')
    $nativeRecoveryVerified = [bool](
        $protectedBlock.blocked -and
        $nativeResponse.success -and
        $nativeStateIsPortal -and
        $nativeResponse.portalModeActive -and
        $nativeResponse.recoveryHostsApplied
    )
    $blockedDomainStillBlocked = Test-BlockedDomainStillBlocked
    $allowedDomainFunctional = Test-AllowedDomainFunctional
    $limitedPostAuthUnproven = [bool]($markerAfterAuth -and $markerAfterAuth.PSObject.Properties['mode'] -and [string]$markerAfterAuth.mode -eq 'limited')
    $portalExitRoute = if ($limitedPostAuthUnproven) {
        'limited-post-auth-unproven'
    }
    elseif ($nativeReconcileResponse -and $nativeReconcileResponse.PSObject.Properties['portalExitRoute']) {
        [string]$nativeReconcileResponse.portalExitRoute
    }
    else {
        ''
    }
    $postAuthProtectedModeRestored = [bool](
        $nativeReconcileResponse.success -and
        $nativeReconcileResponse.protectedModeRestored -and
        $nativeReconcileResponse.localDnsLoopbackRestored -and
        $nativeReconcileResponse.acrylicNormalRestored -and
        $nativeReconcileResponse.dnsResolutionHealthy -and
        $nativeReconcileResponse.sinkholeHealthy -and
        ((-not $nativeReconcileResponse.firewallExpectedActive) -or $nativeReconcileResponse.firewallHealthy) -and
        $nativeReconcileResponse.markerCleared -and
        $blockedDomainStillBlocked.blocked -and
        $allowedDomainFunctional.functional -and
        (-not $limitedPostAuthUnproven)
    )
    $browserNavigationVerified = [bool](
        $firefoxNavigation.inspectedFinalUrl -and
        $firefoxNavigation.didNotLandOnBlockedPage -and
        $firefoxNavigation.nativeRecoverySuccess
    )
    $targetPlatformSymptomCleared = [bool]($browserNavigationVerified -and $postAuthProtectedModeRestored)

    $result = [pscustomobject]@{
        profile = 'captive-portal-navigation'
        success = $targetPlatformSymptomCleared
        evidenceLevel = 'post-auth-recovery-direct-runner'
        nativeRecoveryVerified = $nativeRecoveryVerified
        browserNavigationVerified = $browserNavigationVerified
        targetPlatformSymptomCleared = $targetPlatformSymptomCleared
        fixture = $fixtureSummary
        protectedModeBlock = $protectedBlock
        nativeAction = $nativeResponse
        nativeReconcileAction = $nativeReconcileResponse
        portalModeActive = $portalModeActive
        portalActivePath = $portalActivePath
        nativeStateIsPortal = $nativeStateIsPortal
        dnsRecoveredFromAcrylicOnly = $dnsRecoveredFromAcrylicOnly
        portalExitRoute = $portalExitRoute
        markerBeforeAuth = if ($markerBeforeAuth) { $markerBeforeAuth } else { [pscustomobject]@{ active = $false } }
        markerAfterAuth = if ($markerAfterAuth) { $markerAfterAuth } else { [pscustomobject]@{ active = $false } }
        blockedDomainStillBlocked = $blockedDomainStillBlocked
        allowedDomainFunctional = $allowedDomainFunctional
        localDnsLoopbackRestored = if ($nativeReconcileResponse) { [bool]$nativeReconcileResponse.localDnsLoopbackRestored } else { $false }
        acrylicNormalRestored = if ($nativeReconcileResponse) { [bool]$nativeReconcileResponse.acrylicNormalRestored } else { $false }
        dnsResolutionHealthy = if ($nativeReconcileResponse) { [bool]$nativeReconcileResponse.dnsResolutionHealthy } else { $false }
        sinkholeHealthy = if ($nativeReconcileResponse) { [bool]$nativeReconcileResponse.sinkholeHealthy } else { $false }
        firewallExpectedActive = if ($nativeReconcileResponse) { [bool]$nativeReconcileResponse.firewallExpectedActive } else { $false }
        firewallHealthy = if ($nativeReconcileResponse) { [bool]$nativeReconcileResponse.firewallHealthy } else { $false }
        markerCleared = if ($nativeReconcileResponse) { [bool]$nativeReconcileResponse.markerCleared } else { $false }
        postAuthProtectedModeRestored = $postAuthProtectedModeRestored
        limitedPostAuthUnproven = $limitedPostAuthUnproven
        recoveryArtifacts = $recoveryFiles
        recoveryDiagnostics = $recoveryDiagnostics
        environmentSnapshots = $environmentSnapshots
        captivePortalObservationPath = $observationArtifact
        dnsBeforePath = 'captive-portal-dns-before.json'
        dnsDuringPath = 'captive-portal-dns-during.json'
        dnsAfterPath = 'captive-portal-dns-after.json'
        firefoxNavigationResultPath = 'captive-portal-firefox-navigation-result.json'
        firefoxNavigation = $firefoxNavigation
        concurrency = $concurrency
        writtenAt = (Get-Date).ToString('o')
    }

    Save-Json -Value $result -Path $script:ResultPath
    if (-not $result.success) {
        throw "Captive portal navigation fixture failed before target-platform symptom clearance. See $script:ResultPath"
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
        $recoveryDiagnostics = Copy-RecoveryDiagnosticArtifacts
        $environmentSnapshots = Copy-CaptivePortalEnvironmentSnapshots
        if (-not (Test-Path -LiteralPath $script:ResultPath)) {
            Save-Json -Value ([pscustomobject]@{
                profile = 'captive-portal-navigation'
                success = $false
                decision = 'insufficientEvidence'
                fixtureDoesNotProveRealWeduCaptiveDns = $true
                error = [string]$_
                recoveryDiagnostics = $recoveryDiagnostics
                environmentSnapshots = $environmentSnapshots
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
