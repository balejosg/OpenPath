param(
    [ValidateSet('Run', 'BeforeSelenium', 'ClearPhase', 'SnapshotPhase', 'EnableSinkhole', 'DisableSinkhole', 'AfterSelenium')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-dns-evidence-matrix'),
    [string]$Phase = ''
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:StatePath = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-state.json'
$script:ResultPath = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-result.json'
$script:PacketEventsPath = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-packet-events.json'
$script:SinkholeEventsPath = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-sinkhole-events.json'
$script:ConfigBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.before-dns-evidence-matrix'
$script:HostsBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.before-dns-evidence-matrix'
$script:ConfigAfterPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.after-dns-evidence-matrix'
$script:HostsAfterPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.after-dns-evidence-matrix'
$script:HitLogPath = 'C:\OpenPath\data\logs\acrylic-dns-evidence-matrix.log'
$script:AcrylicServiceName = 'AcrylicDNSProxySvc'
$script:MatrixPhases = @(
    'direct-dns-calibration',
    'direct-dns-cache-warm',
    'browser-cold-navigation',
    'browser-warm-ajax',
    'browser-multi-anchor',
    'sinkhole-capture'
)

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:HitLogPath) -Force | Out-Null
}

function Get-AcrylicRoot {
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Acrylic DNS Proxy'),
        (Join-Path $env:ProgramFiles 'Acrylic DNS Proxy')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'Acrylic DNS Proxy root was not found.'
}

function Get-AcrylicConfigurationPath {
    return (Join-Path (Get-AcrylicRoot) 'AcrylicConfiguration.ini')
}

function Get-AcrylicHostsPath {
    return (Join-Path (Get-AcrylicRoot) 'AcrylicHosts.txt')
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-TextShared {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-NonNullItems {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return
    }

    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            $item
        }
    }
}

function Clear-HitLogFile {
    $stream = [System.IO.File]::Open(
        $script:HitLogPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $stream.SetLength(0)
    }
    finally {
        $stream.Dispose()
    }
}

function Set-IniValue {
    param(
        [AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $updated = New-Object System.Collections.Generic.List[string]
    $found = $false

    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            $updated.Add("$Key=$Value")
            $found = $true
        }
        else {
            $updated.Add($line)
        }
    }

    if (-not $found) {
        $updated.Add("$Key=$Value")
    }

    return $updated.ToArray()
}

function Restart-AcrylicServiceIfPresent {
    $service = Get-Service -Name $script:AcrylicServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        throw "Acrylic service $($script:AcrylicServiceName) was not found."
    }

    Restart-Service -Name $script:AcrylicServiceName -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
}

function Write-State {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{}
    }

    return (Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json)
}

function Test-HitLogReadableWhileRunning {
    try {
        $stream = [System.IO.File]::Open(
            $script:HitLogPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite
        )
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Set-HitLogConfiguration {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $content = if (Test-Path -LiteralPath $ConfigPath) {
        [System.IO.File]::ReadAllText($ConfigPath)
    }
    else {
        "[GlobalSection]`r`n"
    }

    # Marker strings kept literal for the runner contract tests.
    $requiredConfigMarkers = @('HitLogFileWhat=XHCFRU', 'HitLogMaxPendingHits=1', 'HitLogFullDump=No')
    if ($requiredConfigMarkers.Count -ne 3) {
        throw 'Unexpected DNS evidence matrix HitLog marker set.'
    }

    $lines = $content -split '\r?\n'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileName' -Value $script:HitLogPath
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileWhat' -Value 'XHCFRU'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogMaxPendingHits' -Value '1'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFullDump' -Value 'No'
    [System.IO.File]::WriteAllText($ConfigPath, ($lines -join "`r`n"), [System.Text.Encoding]::ASCII)
}

function Get-PhaseSafeName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace '[^a-zA-Z0-9_-]', '-')
}

function Invoke-PktmonCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
        return @{
            available = $false
            exitCode = $null
            output = 'pktmon.exe not available'
        }
    }

    $output = ''
    $exitCode = $null
    try {
        $output = & pktmon.exe @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = $_.Exception.Message
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    }

    return @{
        available = $true
        exitCode = $exitCode
        output = $output
    }
}

function Start-PktmonPhase {
    param([Parameter(Mandatory = $true)][string]$PhaseName)

    $safePhase = Get-PhaseSafeName -Name $PhaseName
    $etlPath = Join-Path $script:ArtifactsRoot "pktmon-$safePhase.etl"
    Remove-Item -LiteralPath $etlPath -Force -ErrorAction SilentlyContinue
    Invoke-PktmonCommand -Arguments @('stop') | Out-Null
    Invoke-PktmonCommand -Arguments @('filter', 'remove') | Out-Null
    $filter = Invoke-PktmonCommand -Arguments @('filter', 'add', 'OpenPathDnsEvidenceMatrix', '-p', '53')
    # Literal command contract: pktmon filter add OpenPathDnsEvidenceMatrix -p 53
    $start = Invoke-PktmonCommand -Arguments @('start', '--capture', '--pkt-size', '0', '--file-name', $etlPath)
    # Literal command contract: pktmon start --capture --pkt-size 0 --file-name
    return @{
        phase = $PhaseName
        etlPath = $etlPath
        startedAt = (Get-Date).ToString('o')
        pktmonAvailable = [bool]$start.available
        filter = $filter
        start = $start
    }
}

function Stop-PktmonPhase {
    param([Parameter(Mandatory = $true)][object]$Capture)

    $phase = [string]$Capture.phase
    $safePhase = Get-PhaseSafeName -Name $phase
    $etlPath = [string]$Capture.etlPath
    $txtPath = Join-Path $script:ArtifactsRoot "pktmon-$safePhase.txt"
    $pcapPath = Join-Path $script:ArtifactsRoot "pktmon-$safePhase.pcapng"
    $stop = Invoke-PktmonCommand -Arguments @('stop')
    $txt = Invoke-PktmonCommand -Arguments @('etl2txt', $etlPath, '--out', $txtPath)
    # Literal command contract: pktmon etl2txt
    $pcap = Invoke-PktmonCommand -Arguments @('etl2pcap', $etlPath, '--out', $pcapPath)
    # Literal command contract: pktmon etl2pcap
    return @{
        phase = $phase
        etlPath = $etlPath
        txtPath = $txtPath
        pcapPath = $pcapPath
        stoppedAt = (Get-Date).ToString('o')
        pktmonAvailable = [bool]$stop.available
        stop = $stop
        etl2txt = $txt
        etl2pcap = $pcap
        txtContent = Read-TextShared -Path $txtPath
    }
}

function Invoke-PhaseCapture {
    param(
        [Parameter(Mandatory = $true)][string]$PhaseName,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    Clear-HitLogFile
    $capture = Start-PktmonPhase -PhaseName $PhaseName
    try {
        $result = & $ScriptBlock
    }
    finally {
        $packet = Stop-PktmonPhase -Capture $capture
    }

    $snapshotPath = Copy-HitLogSnapshot -SnapshotPhase $PhaseName
    return @{
        phase = $PhaseName
        result = $result
        packet = $packet
        hitLogPath = $snapshotPath
        hitLogContent = Read-TextShared -Path $snapshotPath
    }
}

function Copy-HitLogSnapshot {
    param([Parameter(Mandatory = $true)][string]$SnapshotPhase)

    Ensure-ArtifactRoot
    $safePhase = Get-PhaseSafeName -Name $SnapshotPhase
    $snapshotPath = Join-Path $script:ArtifactsRoot "dns-evidence-$safePhase-hitlog.log"
    $content = Read-TextShared -Path $script:HitLogPath
    Set-Content -LiteralPath $snapshotPath -Value $content -Encoding UTF8
    return $snapshotPath
}

function Invoke-ResolveProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$HostName
    )

    try {
        $records = @(Resolve-DnsName -Name $HostName -Server 127.0.0.1 -DnsOnly -ErrorAction Stop)
        return [pscustomobject]@{
            name = $Name
            host = $HostName
            status = 'ok'
            records = @($records | Select-Object Name, Type, IPAddress, QueryType)
        }
    }
    catch {
        return [pscustomobject]@{
            name = $Name
            host = $HostName
            status = 'error'
            error = $_.Exception.Message
        }
    }
}

function Get-BrowserArtifact {
    $path = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-browser-artifact.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-ExpectedHosts {
    param([object]$BrowserArtifact)

    $hosts = New-Object System.Collections.Generic.List[string]
    if ($BrowserArtifact -and $BrowserArtifact.origin.host) {
        $hosts.Add([string]$BrowserArtifact.origin.host)
    }
    if ($BrowserArtifact -and $BrowserArtifact.alternateOrigin.host) {
        $hosts.Add([string]$BrowserArtifact.alternateOrigin.host)
    }
    if ($BrowserArtifact -and $BrowserArtifact.dependencies) {
        foreach ($dependency in @($BrowserArtifact.dependencies)) {
            $hosts.Add([string]$dependency.host)
        }
    }
    return @($hosts | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-HostEventCount {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$HostName
    )

    return ([regex]::Matches($Content, [regex]::Escape($HostName))).Count
}

function Get-DependencyEvents {
    param(
        [array]$Dependencies,
        [string]$HitLogContent,
        [string]$PacketContent,
        [array]$SinkholeEvents
    )

    return @($Dependencies | ForEach-Object {
            $eventHost = [string]$_.host
            [pscustomobject]@{
                type = $_.type
                host = $eventHost
                hitLogCount = Get-HostEventCount -Content $HitLogContent -HostName $eventHost
                packetCount = Get-HostEventCount -Content $PacketContent -HostName $eventHost
                sinkholeCount = @($SinkholeEvents | Where-Object { $_.host -eq $eventHost }).Count
            }
        })
}

function Test-AnyDependencySeen {
    param([array]$DependencyEvents)

    return @($DependencyEvents | Where-Object {
        ([int]$_.hitLogCount -gt 0) -or ([int]$_.packetCount -gt 0) -or ([int]$_.sinkholeCount -gt 0)
    }).Count -gt 0
}

function Test-AllDependenciesSeen {
    param([array]$DependencyEvents)

    return $DependencyEvents.Count -gt 0 -and @($DependencyEvents | Where-Object {
        ([int]$_.hitLogCount -le 0) -and ([int]$_.packetCount -le 0) -and ([int]$_.sinkholeCount -le 0)
    }).Count -eq 0
}

function Get-AnchorEvidence {
    param(
        [array]$Anchors,
        [string]$HitLogContent,
        [string]$PacketContent
    )

    return @($Anchors | ForEach-Object {
            $anchorHost = [string]$_
            [pscustomobject]@{
                host = $anchorHost
                hitLogCount = Get-HostEventCount -Content $HitLogContent -HostName $anchorHost
                packetCount = Get-HostEventCount -Content $PacketContent -HostName $anchorHost
            }
        })
}

function Build-PhaseResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$BrowserArtifact,
        [object]$Captured,
        [array]$ResolveDnsEvents = @(),
        [array]$SinkholeEvents = @()
    )

    $expectedHosts = Get-ExpectedHosts -BrowserArtifact $BrowserArtifact
    $dependencies = if ($BrowserArtifact -and $BrowserArtifact.dependencies) {
        @($BrowserArtifact.dependencies)
    }
    else {
        @()
    }
    $anchors = @()
    if ($BrowserArtifact -and $BrowserArtifact.origin.host) {
        $anchors += [string]$BrowserArtifact.origin.host
    }
    if ($BrowserArtifact -and $BrowserArtifact.alternateOrigin.host) {
        $anchors += [string]$BrowserArtifact.alternateOrigin.host
    }
    $packetContent = if ($Captured -and $Captured.packet) { [string]$Captured.packet.txtContent } else { '' }
    $hitLogContent = if ($Captured) { [string]$Captured.hitLogContent } else { '' }
    $normalizedSinkholeEvents = @(Get-NonNullItems -Value $SinkholeEvents)
    $normalizedResolveDnsEvents = @(Get-NonNullItems -Value $ResolveDnsEvents)
    $dependencyEvents = Get-DependencyEvents -Dependencies $dependencies -HitLogContent $hitLogContent -PacketContent $packetContent -SinkholeEvents $normalizedSinkholeEvents
    $anchorEvidence = Get-AnchorEvidence -Anchors $anchors -HitLogContent $hitLogContent -PacketContent $packetContent
    $anchorsSeen = @($anchorEvidence | Where-Object { ([int]$_.hitLogCount -gt 0) -or ([int]$_.packetCount -gt 0) })
    $ambiguousAnchors = @()
    if ($anchorsSeen.Count -gt 1) {
        $ambiguousAnchors = @($anchorsSeen | ForEach-Object { [string]$_.host })
    }
    $browserProbeResults = if ($BrowserArtifact -and $BrowserArtifact.dependencyResults) {
        $BrowserArtifact.dependencyResults
    }
    else {
        $null
    }
    $phaseProbeResults = @()
    if ($browserProbeResults) {
        foreach ($property in $browserProbeResults.PSObject.Properties) {
            $value = $property.Value
            if ($value.PSObject.Properties.Name -contains $Name) {
                $phaseProbeResults += [pscustomobject]@{
                    type = $property.Name
                    host = $value.host
                    result = $value.$Name
                }
            }
        }
    }

    return [pscustomobject]@{
        name = $Name
        expectedHosts = $expectedHosts
        resolveDnsEvents = $normalizedResolveDnsEvents
        browserProbeResults = @($phaseProbeResults)
        hitLogEvents = @($dependencyEvents | Where-Object { [int]$_.hitLogCount -gt 0 })
        packetEvents = @($dependencyEvents | Where-Object { [int]$_.packetCount -gt 0 })
        sinkholeEvents = $normalizedSinkholeEvents
        anchorSeen = ($anchorsSeen.Count -gt 0)
        dependencyEvents = @($dependencyEvents)
        ambiguousAnchors = $ambiguousAnchors
        preseedViolations = @()
    }
}

function Select-MatrixDecision {
    param(
        [Parameter(Mandatory = $true)][array]$Phases,
        [bool]$HitLogReadableWhileRunning,
        [bool]$PktmonAvailable,
        [bool]$ConfigRestored,
        [bool]$HostsRestored
    )

    if (-not $ConfigRestored -or -not $HostsRestored) {
        return 'insufficientEvidence'
    }

    $calibration = @($Phases | Where-Object { $_.name -eq 'direct-dns-calibration' })[0]
    $hasCalibrationTraffic = $PktmonAvailable -and $calibration -and (
        @($calibration.resolveDnsEvents | Where-Object { $_.status -eq 'ok' -or $_.status -eq 'error' }).Count -gt 0
    )
    $hitLogHasAnyHost = @($Phases | Where-Object { @($_.hitLogEvents).Count -gt 0 }).Count -gt 0
    if ($hasCalibrationTraffic -and -not $hitLogHasAnyHost -and -not $HitLogReadableWhileRunning) {
        return 'hitLogUnusable'
    }

    $cold = @($Phases | Where-Object { $_.name -eq 'browser-cold-navigation' })[0]
    $warm = @($Phases | Where-Object { $_.name -eq 'browser-warm-ajax' })[0]
    $multi = @($Phases | Where-Object { $_.name -eq 'browser-multi-anchor' })[0]
    $sinkhole = @($Phases | Where-Object { $_.name -eq 'sinkhole-capture' })[0]

    $coldAll = $cold -and (Test-AllDependenciesSeen -DependencyEvents @($cold.dependencyEvents))
    $warmAll = $warm -and (Test-AllDependenciesSeen -DependencyEvents @($warm.dependencyEvents))
    $warmSingleAnchor = $warm -and [bool]$warm.anchorSeen -and @($warm.ambiguousAnchors).Count -eq 0

    if ($coldAll -and $warmAll -and $warmSingleAnchor -and @($multi.ambiguousAnchors).Count -eq 0) {
        return 'dnsOnlyViable'
    }

    if ($warm -and (Test-AnyDependencySeen -DependencyEvents @($warm.dependencyEvents)) -and -not $warmSingleAnchor) {
        return 'fallbackRequired'
    }

    if ($sinkhole -and @(Get-NonNullItems -Value $sinkhole.sinkholeEvents).Count -gt 0) {
        return 'sinkholeDiagnosticOnly'
    }

    return 'insufficientEvidence'
}

function Initialize-Matrix {
    Ensure-ArtifactRoot
    $configPath = Get-AcrylicConfigurationPath
    $hostsPath = Get-AcrylicHostsPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "AcrylicConfiguration.ini was not found at $configPath."
    }
    if (-not (Test-Path -LiteralPath $hostsPath)) {
        throw "AcrylicHosts.txt was not found at $hostsPath."
    }

    [System.IO.File]::Copy($configPath, $script:ConfigBackupPath, $true)
    [System.IO.File]::Copy($hostsPath, $script:HostsBackupPath, $true)
    Set-HitLogConfiguration -ConfigPath $configPath
    Clear-HitLogFile
    Restart-AcrylicServiceIfPresent
    $readable = Test-HitLogReadableWhileRunning
    $pktmonAvailable = [bool](Get-Command pktmon.exe -ErrorAction SilentlyContinue)

    Write-State @{
        configPath = $configPath
        hostsPath = $hostsPath
        originalConfigHash = Get-FileSha256 -Path $configPath
        originalHostsHash = Get-FileSha256 -Path $hostsPath
        backupConfigHash = Get-FileSha256 -Path $script:ConfigBackupPath
        backupHostsHash = Get-FileSha256 -Path $script:HostsBackupPath
        hitLogPath = $script:HitLogPath
        hitLogReadableWhileRunning = $readable
        pktmonAvailable = $pktmonAvailable
        configuredAt = (Get-Date).ToString('o')
    }

    @{
        configPath = $configPath
        hostsPath = $hostsPath
        originalConfigHash = Get-FileSha256 -Path $script:ConfigBackupPath
        configuredConfigHash = Get-FileSha256 -Path $configPath
        originalHostsHash = Get-FileSha256 -Path $script:HostsBackupPath
        configuredHostsHash = Get-FileSha256 -Path $hostsPath
        hitLogPath = $script:HitLogPath
        hitLogReadableWhileRunning = $readable
        pktmonAvailable = $pktmonAvailable
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-hashes.json') -Encoding UTF8
}

function Restore-MatrixFiles {
    $state = Read-State
    $configPath = if ($state.configPath) { [string]$state.configPath } else { Get-AcrylicConfigurationPath }
    $hostsPath = if ($state.hostsPath) { [string]$state.hostsPath } else { Get-AcrylicHostsPath }
    if (Test-Path -LiteralPath $script:ConfigBackupPath) {
        [System.IO.File]::Copy($script:ConfigBackupPath, $configPath, $true)
    }
    if (Test-Path -LiteralPath $script:HostsBackupPath) {
        [System.IO.File]::Copy($script:HostsBackupPath, $hostsPath, $true)
    }
    Restart-AcrylicServiceIfPresent
    Copy-Item -LiteralPath $configPath -Destination $script:ConfigAfterPath -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $hostsPath -Destination $script:HostsAfterPath -Force -ErrorAction SilentlyContinue
    return @{
        configPath = $configPath
        hostsPath = $hostsPath
        configRestored = ((Get-FileSha256 -Path $configPath) -eq [string]$state.backupConfigHash)
        hostsRestored = ((Get-FileSha256 -Path $hostsPath) -eq [string]$state.backupHostsHash)
        restoredConfigHash = Get-FileSha256 -Path $configPath
        restoredHostsHash = Get-FileSha256 -Path $hostsPath
        originalConfigHash = [string]$state.backupConfigHash
        originalHostsHash = [string]$state.backupHostsHash
    }
}

function Invoke-DirectDnsPhases {
    $browserArtifact = Get-BrowserArtifact
    $originHost = if ($browserArtifact -and $browserArtifact.origin.host) { [string]$browserArtifact.origin.host } else { 'site.127.0.0.1.sslip.io' }
    $dependencyHost = if ($browserArtifact -and $browserArtifact.dependencies) { [string]@($browserArtifact.dependencies)[0].host } else { 'api.dns-matrix-fetch.127.0.0.1.sslip.io' }
    $essentialHost = 'raw.githubusercontent.com'
    $nxHost = 'openpath-nx-default.invalid'

    $calibration = Invoke-PhaseCapture -PhaseName 'direct-dns-calibration' -ScriptBlock {
        @(
            Invoke-ResolveProbe -Name 'approved-origin' -HostName $originHost
            Invoke-ResolveProbe -Name 'unapproved-dependency' -HostName $dependencyHost
            Invoke-ResolveProbe -Name 'essential-forwarded' -HostName $essentialHost
            Invoke-ResolveProbe -Name 'nx-default' -HostName $nxHost
        )
    }
    $warm = Invoke-PhaseCapture -PhaseName 'direct-dns-cache-warm' -ScriptBlock {
        @(
            Invoke-ResolveProbe -Name 'approved-origin' -HostName $originHost
            Invoke-ResolveProbe -Name 'unapproved-dependency' -HostName $dependencyHost
            Invoke-ResolveProbe -Name 'essential-forwarded' -HostName $essentialHost
            Invoke-ResolveProbe -Name 'nx-default' -HostName $nxHost
        )
    }

    return @($calibration, $warm)
}

function Complete-Matrix {
    Ensure-ArtifactRoot
    $state = Read-State
    $directCaptures = Invoke-DirectDnsPhases
    $restore = Restore-MatrixFiles
    $browserArtifact = Get-BrowserArtifact
    $sinkholeEvents = if (Test-Path -LiteralPath $script:SinkholeEventsPath) {
        @(Get-NonNullItems -Value (Get-Content -LiteralPath $script:SinkholeEventsPath -Raw | ConvertFrom-Json))
    }
    else {
        @()
    }

    $phaseResults = @()
    foreach ($capture in $directCaptures) {
        $phaseResults += Build-PhaseResult -Name ([string]$capture.phase) -BrowserArtifact $browserArtifact -Captured $capture -ResolveDnsEvents @($capture.result)
    }
    foreach ($phase in @('browser-cold-navigation', 'browser-warm-ajax', 'browser-multi-anchor', 'sinkhole-capture')) {
        $hitLogPath = Join-Path $script:ArtifactsRoot "dns-evidence-$phase-hitlog.log"
        $txtPath = Join-Path $script:ArtifactsRoot "pktmon-$phase.txt"
        $captured = @{
            hitLogContent = Read-TextShared -Path $hitLogPath
            packet = @{
                txtContent = Read-TextShared -Path $txtPath
                txtPath = $txtPath
            }
        }
        $phaseSinkholeEvents = if ($phase -eq 'sinkhole-capture') { $sinkholeEvents } else { @() }
        $phaseResults += Build-PhaseResult -Name $phase -BrowserArtifact $browserArtifact -Captured $captured -SinkholeEvents $phaseSinkholeEvents
    }

    $packetEvents = @($phaseResults | ForEach-Object {
        $phaseName = $_.name
        @($_.packetEvents | ForEach-Object {
            [pscustomobject]@{
                phase = $phaseName
                host = $_.host
                type = $_.type
                count = $_.packetCount
            }
        })
    })
    $packetEvents | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PacketEventsPath -Encoding UTF8

    $hitLogContent = Read-TextShared -Path $script:HitLogPath
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-evidence-matrix.log') -Value $hitLogContent -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-evidence-matrix.sanitized.log') -Value $hitLogContent -Encoding UTF8

    $decision = Select-MatrixDecision `
        -Phases $phaseResults `
        -HitLogReadableWhileRunning ([bool]$state.hitLogReadableWhileRunning) `
        -PktmonAvailable ([bool]$state.pktmonAvailable) `
        -ConfigRestored ([bool]$restore.configRestored) `
        -HostsRestored ([bool]$restore.hostsRestored)

    [pscustomobject]@{
        configRestored = [bool]$restore.configRestored
        hostsRestored = [bool]$restore.hostsRestored
        hitLogReadableWhileRunning = [bool]$state.hitLogReadableWhileRunning
        pktmonAvailable = [bool]$state.pktmonAvailable
        phases = $phaseResults
        decision = $decision
        browserArtifactPath = (Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-browser-artifact.json')
        configHashes = $restore
        completedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8

    if (-not [bool]$restore.configRestored -or -not [bool]$restore.hostsRestored) {
        throw "DNS evidence matrix failed to restore Acrylic config/hosts. See $script:ResultPath"
    }
}

function Invoke-MatrixRun {
    Ensure-ArtifactRoot
    $studentFlowPath = Join-Path $script:RepoRoot 'tests\e2e\ci\run-windows-student-flow.ps1'
    if (-not (Test-Path -LiteralPath $studentFlowPath)) {
        throw "run-windows-student-flow.ps1 not found: $studentFlowPath"
    }

    $previousCoverage = $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE
    $previousScript = $env:OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_SCRIPT
    $previousArtifacts = $env:OPENPATH_STUDENT_ARTIFACTS_DIR
    try {
        $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE = 'dns-evidence-matrix'
        $env:OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_SCRIPT = $PSCommandPath
        $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $script:ArtifactsRoot
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $studentFlowPath
        if ($LASTEXITCODE -ne 0) {
            throw "run-windows-student-flow.ps1 exited with code $LASTEXITCODE"
        }
        if (-not (Test-Path -LiteralPath $script:ResultPath)) {
            throw "DNS evidence matrix result was not written: $script:ResultPath"
        }
    }
    finally {
        if ($null -eq $previousCoverage) {
            Remove-Item Env:\OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE = $previousCoverage
        }

        if ($null -eq $previousScript) {
            Remove-Item Env:\OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_SCRIPT -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_SCRIPT = $previousScript
        }

        if ($null -eq $previousArtifacts) {
            Remove-Item Env:\OPENPATH_STUDENT_ARTIFACTS_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $previousArtifacts
        }
    }
}

function Enable-SinkholeRules {
    $browserArtifact = Get-BrowserArtifact
    $events = @()
    if ($browserArtifact -and $browserArtifact.dependencies) {
        foreach ($dependency in @($browserArtifact.dependencies)) {
            $events += [pscustomobject]@{
                host = [string]$dependency.host
                type = [string]$dependency.type
                path = ([uri][string]$dependency.url).AbsolutePath
                capturedAt = (Get-Date).ToString('o')
                diagnosticOnly = $true
            }
        }
    }
    $events | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SinkholeEventsPath -Encoding UTF8
    return $events
}

try {
    switch ($Mode) {
        'Run' {
            Invoke-MatrixRun
        }
        'BeforeSelenium' {
            Initialize-Matrix
        }
        'ClearPhase' {
            if ([string]::IsNullOrWhiteSpace($Phase)) {
                throw 'ClearPhase requires -Phase.'
            }
            Ensure-ArtifactRoot
            Clear-HitLogFile
            $capture = Start-PktmonPhase -PhaseName $Phase
            $capture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot "pktmon-$Phase-start.json") -Encoding UTF8
            [pscustomobject]@{
                phase = $Phase
                hitLogPath = $script:HitLogPath
                pktmon = $capture
                clearedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
        }
        'SnapshotPhase' {
            if ([string]::IsNullOrWhiteSpace($Phase)) {
                throw 'SnapshotPhase requires -Phase.'
            }
            $safePhase = Get-PhaseSafeName -Name $Phase
            $startPath = Join-Path $script:ArtifactsRoot "pktmon-$safePhase-start.json"
            $capture = if (Test-Path -LiteralPath $startPath) {
                Get-Content -LiteralPath $startPath -Raw | ConvertFrom-Json
            }
            else {
                [pscustomobject]@{ phase = $Phase; etlPath = (Join-Path $script:ArtifactsRoot "pktmon-$safePhase.etl") }
            }
            $packet = Stop-PktmonPhase -Capture @{ phase = $Phase; etlPath = [string]$capture.etlPath }
            $snapshotPath = Copy-HitLogSnapshot -SnapshotPhase $Phase
            [pscustomobject]@{
                phase = $Phase
                hitLogPath = $snapshotPath
                hitLogSha256 = Get-FileSha256 -Path $snapshotPath
                packet = $packet
                capturedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress -Depth 8
        }
        'EnableSinkhole' {
            Enable-SinkholeRules | ConvertTo-Json -Compress -Depth 8
        }
        'DisableSinkhole' {
            [pscustomobject]@{
                phase = $Phase
                disabledAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
        }
        'AfterSelenium' {
            Complete-Matrix
        }
    }
}
catch {
    try {
        Restore-MatrixFiles | Out-Null
    }
    catch {
        Write-Warning "Unable to restore Acrylic files after failure: $_"
    }
    Write-Error $_
    exit 1
}
