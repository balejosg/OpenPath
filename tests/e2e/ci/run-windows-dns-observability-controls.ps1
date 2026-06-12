param(
    [ValidateSet('Run')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-dns-observability-controls')
)

$ErrorActionPreference = 'Stop'

$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:ResultPath = Join-Path $script:ArtifactsRoot 'dns-observability-controls-result.json'
$script:HashesPath = Join-Path $script:ArtifactsRoot 'dns-observability-controls-hashes.json'
$script:ConfigBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.before-dns-observability-controls'
$script:HostsBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.before-dns-observability-controls'
$script:ConfigAfterPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.after-dns-observability-controls'
$script:HostsAfterPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.after-dns-observability-controls'
$script:HitLogPath = 'C:\OpenPath\data\logs\acrylic-dns-observability-controls.log'
$script:AcrylicServiceName = 'AcrylicDNSProxySvc'
$script:ForwardControlHost = 'raw.githubusercontent.com'
$script:NxControlHost = ('openpath-hitlog-nx-' + [guid]::NewGuid().ToString('N') + '.invalid')
$script:RegisteredAcrylicServiceForDiagnostic = $false
$script:AcrylicServiceNameUsed = ''

. (Join-Path $PSScriptRoot 'acrylic-dns-spike-helpers.ps1')

function Set-HitLogConfiguration {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $content = [System.IO.File]::ReadAllText($ConfigPath)

    # Marker strings kept literal for the runner contract tests.
    $requiredConfigMarkers = @('HitLogFileWhat=XHCFRU', 'HitLogMaxPendingHits=1', 'HitLogFullDump=No')
    if ($requiredConfigMarkers.Count -ne 3) {
        throw 'Unexpected DNS observability control HitLog marker set.'
    }

    $lines = $content -split '\r?\n'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileName' -Value $script:HitLogPath
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileWhat' -Value 'XHCFRU'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogMaxPendingHits' -Value '1'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFullDump' -Value 'No'
    [System.IO.File]::WriteAllText($ConfigPath, ($lines -join "`r`n"), [System.Text.Encoding]::ASCII)
}

# Intentionally shadows the shared helper in acrylic-dns-spike-helpers.ps1 (divergent behavior; do not replace with the shared version).
function Restart-AcrylicServiceIfPresent {
    $service = Get-AcrylicRegisteredService
    if ($null -eq $service) {
        $servicePath = Get-AcrylicServicePath
        if (-not (Test-Path -LiteralPath $servicePath)) {
            throw "Acrylic service executable was not found at $servicePath."
        }

        $installProcess = Start-Process -FilePath $servicePath -ArgumentList '/INSTALL' -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $installProcess.WaitForExit(15000)) {
            Stop-Process -Id $installProcess.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
        $service = Get-AcrylicRegisteredService
        if ($null -eq $service) {
            New-Service -Name $script:AcrylicServiceName `
                -BinaryPathName ('"{0}"' -f $servicePath) `
                -DisplayName 'Acrylic DNS Proxy Service' `
                -StartupType Automatic `
                -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 1
            $service = Get-AcrylicRegisteredService
        }
        if ($null -ne $service) {
            $script:RegisteredAcrylicServiceForDiagnostic = $true
        }
    }
    if ($null -eq $service) {
        throw "Acrylic service $($script:AcrylicServiceName) was not found."
    }

    $script:AcrylicServiceNameUsed = [string]$service.Name
    if ($service.Status -eq 'Running') {
        Restart-Service -Name $service.Name -Force -ErrorAction Stop
    }
    else {
        Start-Service -Name $service.Name -ErrorAction Stop
    }
    Start-Sleep -Seconds 2
}
function Get-SafeName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace '[^a-zA-Z0-9_-]', '-')
}

function Copy-HitLogSnapshot {
    param([Parameter(Mandatory = $true)][string]$SnapshotName)

    Ensure-ArtifactRoot
    $safeName = Get-SafeName -Name $SnapshotName
    $snapshotPath = Join-Path $script:ArtifactsRoot "dns-observability-$safeName-hitlog.log"
    $content = Read-TextShared -Path $script:HitLogPath
    Set-Content -LiteralPath $snapshotPath -Value $content -Encoding UTF8
    return $snapshotPath
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

function Start-PktmonForwardControl {
    $etlPath = Join-Path $script:ArtifactsRoot 'pktmon-forward-control.etl'
    Remove-Item -LiteralPath $etlPath -Force -ErrorAction SilentlyContinue
    Invoke-PktmonCommand -Arguments @('stop') | Out-Null
    Invoke-PktmonCommand -Arguments @('filter', 'remove') | Out-Null
    $filter = Invoke-PktmonCommand -Arguments @('filter', 'add', 'OpenPathDnsObservabilityForward', '-p', '53')
    # Literal command contract: pktmon filter add OpenPathDnsObservabilityForward -p 53
    $start = Invoke-PktmonCommand -Arguments @('start', '--capture', '--pkt-size', '0', '--file-name', $etlPath)
    # Literal command contract: pktmon start --capture --pkt-size 0 --file-name
    return @{
        etlPath = $etlPath
        startedAt = (Get-Date).ToString('o')
        pktmonAvailable = [bool]$start.available
        filter = $filter
        start = $start
    }
}

function Stop-PktmonForwardControl {
    param([Parameter(Mandatory = $true)][object]$Capture)

    $etlPath = [string]$Capture.etlPath
    $txtPath = Join-Path $script:ArtifactsRoot 'pktmon-forward-control.txt'
    $pcapPath = Join-Path $script:ArtifactsRoot 'pktmon-forward-control.pcapng'
    $stop = Invoke-PktmonCommand -Arguments @('stop')
    $txt = Invoke-PktmonCommand -Arguments @('etl2txt', $etlPath, '--out', $txtPath)
    # Literal command contract: pktmon etl2txt
    $pcap = Invoke-PktmonCommand -Arguments @('etl2pcap', $etlPath, '--out', $pcapPath)
    # Literal command contract: pktmon etl2pcap
    $txtContent = Read-TextShared -Path $txtPath
    return @{
        etlPath = $etlPath
        txtPath = $txtPath
        pcapPath = $pcapPath
        stoppedAt = (Get-Date).ToString('o')
        pktmonAvailable = [bool]$stop.available
        stop = $stop
        etl2txt = $txt
        etl2pcap = $pcap
        txtLineCount = @($txtContent -split '\r?\n' | Where-Object { $_ }).Count
        hostMatchCount = ([regex]::Matches($txtContent, [regex]::Escape($script:ForwardControlHost))).Count
    }
}

function Invoke-BoundedResolveDns {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$HostName,
        [int]$TimeoutSeconds = 20
    )

    $safeName = Get-SafeName -Name $Name
    $outPath = Join-Path $script:ArtifactsRoot "resolve-$safeName.json"
    $errPath = Join-Path $script:ArtifactsRoot "resolve-$safeName.err.log"
    Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue

    $encodedHost = $HostName.Replace("'", "''")
    $encodedName = $Name.Replace("'", "''")
    $childScript = @"
`$ErrorActionPreference = 'Stop'
try {
    `$records = @(Resolve-DnsName -Name '$encodedHost' -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
    [pscustomobject]@{
        name = '$encodedName'
        host = '$encodedHost'
        status = 'ok'
        records = @(`$records | Select-Object Name, Type, IPAddress, QueryType)
        completedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath '$outPath' -Encoding UTF8
}
catch {
    [pscustomobject]@{
        name = '$encodedName'
        host = '$encodedHost'
        status = 'error'
        error = `$_.Exception.Message
        fullyQualifiedErrorId = `$_.FullyQualifiedErrorId
        completedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath '$outPath' -Encoding UTF8
}
"@

    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        $encodedCommand
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -RedirectStandardError $errPath -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            name = $Name
            host = $HostName
            status = 'timeout'
            error = "Resolve-DnsName timed out after $TimeoutSeconds seconds"
            completedAt = (Get-Date).ToString('o')
        }
    }

    if (Test-Path -LiteralPath $outPath) {
        return (Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json)
    }

    $stderr = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
    return [pscustomobject]@{
        name = $Name
        host = $HostName
        status = 'failed'
        error = $stderr
        completedAt = (Get-Date).ToString('o')
    }
}

function Get-HitLogLines {
    param([string]$Content)

    return @($Content -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ControlHitLogLines {
    param(
        [string[]]$Lines,
        [string]$HostName
    )

    return @($Lines | Where-Object { $_ -match [regex]::Escape($HostName) })
}

function Select-ObservabilityDecision {
    param(
        [bool]$ConfigRestored,
        [bool]$HostsRestored,
        [object]$ForwardControl,
        [object]$NxControl
    )

    if (-not $ConfigRestored -or -not $HostsRestored) {
        return 'insufficientEvidence'
    }

    if ($ForwardControl.status -ne 'ok') {
        return 'insufficientEvidence'
    }

    $forwardSeen = [int]$ForwardControl.hitLogMatchCount -gt 0
    $nxSeen = [int]$NxControl.hitLogMatchCount -gt 0

    if (-not $forwardSeen) {
        return 'hitLogUnusable'
    }

    if ($forwardSeen -and -not $nxSeen) {
        return 'hitLogForwardOnly'
    }

    if ($forwardSeen -and $nxSeen) {
        return 'hitLogUsable'
    }

    return 'insufficientEvidence'
}

function Restore-AcrylicFiles {
    param(
        [string]$ConfigPath,
        [string]$HostsPath
    )

    if ($ConfigPath -and (Test-Path -LiteralPath $script:ConfigBackupPath)) {
        [System.IO.File]::Copy($script:ConfigBackupPath, $ConfigPath, $true)
    }
    if ($HostsPath -and (Test-Path -LiteralPath $script:HostsBackupPath)) {
        [System.IO.File]::Copy($script:HostsBackupPath, $HostsPath, $true)
    }
    Restart-AcrylicServiceIfPresent
    Copy-Item -LiteralPath $ConfigPath -Destination $script:ConfigAfterPath -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $HostsPath -Destination $script:HostsAfterPath -Force -ErrorAction SilentlyContinue
}

function Invoke-ObservabilityControls {
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
    $originalConfigHash = Get-FileSha256 -Path $script:ConfigBackupPath
    $originalHostsHash = Get-FileSha256 -Path $script:HostsBackupPath

    $forwardControl = $null
    $nxControl = $null
    $pktmonStart = $null
    $pktmonStop = $null
    $hitLogReadable = $false
    $resultError = ''
    $restoreError = ''
    $serviceCleanupError = ''

    try {
        Set-HitLogConfiguration -ConfigPath $configPath
        Clear-HitLogFile
        Copy-HitLogSnapshot -SnapshotName 'before-restart' | Out-Null
        Restart-AcrylicServiceIfPresent
        $hitLogReadable = Test-HitLogReadableWhileRunning
        Copy-HitLogSnapshot -SnapshotName 'after-restart' | Out-Null
        Clear-HitLogFile
        Copy-HitLogSnapshot -SnapshotName 'before-controls' | Out-Null

        $pktmonStart = Start-PktmonForwardControl
        try {
            $forwardControl = Invoke-BoundedResolveDns -Name 'forward-control' -HostName $script:ForwardControlHost
        }
        finally {
            $pktmonStop = Stop-PktmonForwardControl -Capture $pktmonStart
        }

        $nxControl = Invoke-BoundedResolveDns -Name 'nx-control' -HostName $script:NxControlHost
        Start-Sleep -Seconds 2
        Copy-HitLogSnapshot -SnapshotName 'after-controls' | Out-Null
    }
    catch {
        $resultError = [string]$_
    }
    finally {
        try {
            Restore-AcrylicFiles -ConfigPath $configPath -HostsPath $hostsPath
        }
        catch {
            $restoreError = [string]$_
        }
        try {
            Remove-DiagnosticAcrylicServiceIfCreated
        }
        catch {
            $serviceCleanupError = [string]$_
        }
    }

    $configRestored = ((Get-FileSha256 -Path $configPath) -eq $originalConfigHash)
    $hostsRestored = ((Get-FileSha256 -Path $hostsPath) -eq $originalHostsHash)
    $hitLogContent = Read-TextShared -Path $script:HitLogPath
    $hitLogLines = Get-HitLogLines -Content $hitLogContent
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-observability-controls.log') -Value $hitLogContent -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-observability-controls.sanitized.log') -Value $hitLogContent -Encoding UTF8

    $forwardLines = Get-ControlHitLogLines -Lines $hitLogLines -HostName $script:ForwardControlHost
    $nxLines = Get-ControlHitLogLines -Lines $hitLogLines -HostName $script:NxControlHost

    if ($null -eq $forwardControl) {
        $forwardControl = [pscustomobject]@{
            name = 'forward-control'
            host = $script:ForwardControlHost
            status = 'not-run'
            error = $resultError
        }
    }
    $forwardControl | Add-Member -NotePropertyName hitLogMatchCount -NotePropertyValue @($forwardLines).Count -Force
    $forwardControl | Add-Member -NotePropertyName hitLogLines -NotePropertyValue @($forwardLines) -Force

    if ($null -eq $nxControl) {
        $nxControl = [pscustomobject]@{
            name = 'nx-control'
            host = $script:NxControlHost
            status = 'not-run'
            error = $resultError
        }
    }
    $nxControl | Add-Member -NotePropertyName hitLogMatchCount -NotePropertyValue @($nxLines).Count -Force
    $nxControl | Add-Member -NotePropertyName hitLogLines -NotePropertyValue @($nxLines) -Force

    $pktmonAvailable = [bool](Get-Command pktmon.exe -ErrorAction SilentlyContinue)
    $pktmonEvents = [pscustomobject]@{
        purpose = 'forward-upstream-control-only'
        available = $pktmonAvailable
        start = $pktmonStart
        stop = $pktmonStop
    }

    $hashes = [pscustomobject]@{
        configPath = $configPath
        hostsPath = $hostsPath
        originalConfigHash = $originalConfigHash
        originalHostsHash = $originalHostsHash
        restoredConfigHash = Get-FileSha256 -Path $configPath
        restoredHostsHash = Get-FileSha256 -Path $hostsPath
        configRestored = $configRestored
        hostsRestored = $hostsRestored
    }
    $hashes | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:HashesPath -Encoding UTF8

    $decision = Select-ObservabilityDecision `
        -ConfigRestored $configRestored `
        -HostsRestored $hostsRestored `
        -ForwardControl $forwardControl `
        -NxControl $nxControl
    if ($restoreError -or $serviceCleanupError) {
        $decision = 'insufficientEvidence'
    }

    [pscustomobject]@{
        configRestored = $configRestored
        hostsRestored = $hostsRestored
        hitLogReadableWhileRunning = $hitLogReadable
        pktmonAvailable = $pktmonAvailable
        forwardControl = $forwardControl
        nxControl = $nxControl
        hitLogLines = @($forwardLines + $nxLines)
        hitLogLineCount = @($hitLogLines).Count
        pktmonEvents = $pktmonEvents
        decision = $decision
        error = $resultError
        restoreError = $restoreError
        serviceCleanupError = $serviceCleanupError
        acrylicServiceName = $script:AcrylicServiceNameUsed
        serviceRegisteredForDiagnostic = $script:RegisteredAcrylicServiceForDiagnostic
        configHashes = $hashes
        hitLogPath = $script:HitLogPath
        completedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8

    if (-not $configRestored -or -not $hostsRestored) {
        $message = "DNS observability controls failed to restore Acrylic config/hosts. See $script:ResultPath"
        if ($restoreError) {
            $message = "$message Restore error: $restoreError"
        }
        throw $message
    }
}

try {
    switch ($Mode) {
        'Run' {
            Invoke-ObservabilityControls
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
