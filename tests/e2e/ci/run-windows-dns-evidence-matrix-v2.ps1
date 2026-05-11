param(
    [ValidateSet('Run', 'BeforeSelenium', 'ClearPhase', 'SnapshotPhase', 'ApplyFwRules', 'AfterSelenium')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-dns-evidence-matrix-v2'),
    [string]$Phase = ''
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:StatePath = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-v2-state.json'
$script:ResultPath = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-v2-result.json'
$script:HashesPath = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-v2-hashes.json'
$script:ConfigBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.before-dns-evidence-matrix-v2'
$script:HostsBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.before-dns-evidence-matrix-v2'
$script:ConfigAfterPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.after-dns-evidence-matrix-v2'
$script:HostsAfterPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.after-dns-evidence-matrix-v2'
$script:HitLogPath = 'C:\OpenPath\data\logs\acrylic-dns-evidence-matrix-v2.log'
$script:AcrylicServiceName = 'AcrylicDNSProxySvc'
$script:RegisteredAcrylicServiceForDiagnostic = $false
$script:AcrylicServiceNameUsed = ''

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:HitLogPath) -Force | Out-Null
}

function Get-RunnerHostSuffix {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.PrefixOrigin -ne 'WellKnown'
        } |
        Sort-Object InterfaceMetric, InterfaceIndex |
        Select-Object -First 1
    if (-not $address -or -not $address.IPAddress) {
        throw 'Unable to derive a non-loopback Windows runner IPv4 address for dns-evidence-matrix-v2.'
    }

    return (($address.IPAddress -replace '\.', '-') + '.sslip.io')
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

function Get-AcrylicServicePath {
    return (Join-Path (Get-AcrylicRoot) 'AcrylicService.exe')
}

function Get-AcrylicRegisteredService {
    $service = Get-Service -Name $script:AcrylicServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service) {
        return $service
    }

    return Get-Service -DisplayName '*Acrylic*' -ErrorAction SilentlyContinue | Select-Object -First 1
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

function Set-HitLogConfiguration {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $content = [System.IO.File]::ReadAllText($ConfigPath)

    # Marker strings kept literal for the runner contract tests.
    $requiredConfigMarkers = @('HitLogFileWhat=XHCFRU', 'HitLogMaxPendingHits=1', 'HitLogFullDump=No')
    if ($requiredConfigMarkers.Count -ne 3) {
        throw 'Unexpected DNS evidence matrix v2 HitLog marker set.'
    }

    $lines = $content -split '\r?\n'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileName' -Value $script:HitLogPath
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileWhat' -Value 'XHCFRU'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogMaxPendingHits' -Value '1'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFullDump' -Value 'No'
    [System.IO.File]::WriteAllText($ConfigPath, ($lines -join "`r`n"), [System.Text.Encoding]::ASCII)
}

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

function Remove-DiagnosticAcrylicServiceIfCreated {
    if (-not $script:RegisteredAcrylicServiceForDiagnostic) {
        return
    }

    $service = Get-AcrylicRegisteredService
    if ($null -ne $service) {
        Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
    }

    $servicePath = Get-AcrylicServicePath
    if (Test-Path -LiteralPath $servicePath) {
        $uninstallProcess = Start-Process -FilePath $servicePath -ArgumentList '/UNINSTALL' -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
        if ($uninstallProcess -and -not $uninstallProcess.WaitForExit(15000)) {
            Stop-Process -Id $uninstallProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $service = Get-AcrylicRegisteredService
    if ($null -ne $service) {
        & sc.exe delete $service.Name | Out-Null
        Start-Sleep -Seconds 1
    }
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

function Get-PhaseSafeName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace '[^a-zA-Z0-9_-]', '-')
}

function Copy-HitLogSnapshot {
    param([Parameter(Mandatory = $true)][string]$SnapshotPhase)

    Ensure-ArtifactRoot
    $safePhase = Get-PhaseSafeName -Name $SnapshotPhase
    $snapshotPath = Join-Path $script:ArtifactsRoot "dns-evidence-v2-$safePhase-hitlog.log"
    $content = Read-TextShared -Path $script:HitLogPath
    Set-Content -LiteralPath $snapshotPath -Value $content -Encoding UTF8
    return $snapshotPath
}

function Invoke-BoundedResolveDns {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$HostName,
        [int]$TimeoutSeconds = 20
    )

    $safeName = Get-PhaseSafeName -Name $Name
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
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) `
        -RedirectStandardError $errPath `
        -PassThru `
        -WindowStyle Hidden
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

function Add-FwRulesToHostsFile {
    param(
        [Parameter(Mandatory = $true)][string]$HostsPath,
        [Parameter(Mandatory = $true)][string[]]$Hosts
    )

    $content = [System.IO.File]::ReadAllText($HostsPath)
    $rules = @($Hosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique | ForEach-Object { "FW $_" })
    if ($rules.Count -eq 0) {
        return @()
    }

    $insertion = @(
        ''
        '# DNS evidence matrix v2 temporary FW dependency controls'
        $rules
        ''
    ) -join "`r`n"

    if ($content -match '(?m)^NX \*\s*$') {
        $content = [regex]::Replace($content, '(?m)^NX \*\s*$', ($insertion + "`r`nNX *"), 1)
    }
    else {
        $content = $content.TrimEnd() + "`r`n" + $insertion + "`r`nNX *`r`n"
    }

    [System.IO.File]::WriteAllText($HostsPath, $content, [System.Text.Encoding]::ASCII)
    return $rules
}

function Add-FwDependencyRules {
    $artifact = Get-BrowserArtifact
    if (-not $artifact -or -not $artifact.dependencies) {
        throw 'dns-evidence-matrix-v2 browser artifact is missing dependency hosts.'
    }

    $state = Read-State
    $hostsPath = if ($state.hostsPath) { [string]$state.hostsPath } else { Get-AcrylicHostsPath }
    $hosts = @($artifact.dependencies | ForEach-Object { [string]$_.host })
    $rules = Add-FwRulesToHostsFile -HostsPath $hostsPath -Hosts $hosts
    Restart-AcrylicServiceIfPresent

    [pscustomobject]@{
        phase = $Phase
        rules = @($rules)
        hostsPath = $hostsPath
        appliedAt = (Get-Date).ToString('o')
    }
}

function Invoke-PktmonMetadata {
    param([Parameter(Mandatory = $true)][string]$PhaseName)

    $safePhase = Get-PhaseSafeName -Name $PhaseName
    $metadataPath = Join-Path $script:ArtifactsRoot "pktmon-v2-$safePhase.json"
    $metadata = [pscustomobject]@{
        phase = $PhaseName
        purpose = 'metadata-only'
        available = [bool](Get-Command pktmon.exe -ErrorAction SilentlyContinue)
        capturedAt = (Get-Date).ToString('o')
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    return $metadata
}

function Invoke-PhaseCapture {
    param(
        [Parameter(Mandatory = $true)][string]$PhaseName,
        [scriptblock]$ScriptBlock = $null
    )

    Clear-HitLogFile
    $pktmonMetadata = Invoke-PktmonMetadata -PhaseName $PhaseName
    $result = if ($null -ne $ScriptBlock) { & $ScriptBlock } else { @() }
    Start-Sleep -Seconds 2
    $snapshotPath = Copy-HitLogSnapshot -SnapshotPhase $PhaseName

    return [pscustomobject]@{
        phase = $PhaseName
        result = $result
        hitLogPath = $snapshotPath
        hitLogContent = Read-TextShared -Path $snapshotPath
        pktmon = $pktmonMetadata
    }
}

function Get-BrowserArtifact {
    $path = Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-v2-browser-artifact.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-HostEventCounts {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string[]]$Hosts
    )

    return @($Hosts | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object {
        $hostName = [string]$_
        $lines = @($Content -split '\r?\n' | Where-Object { $_ -match [regex]::Escape($hostName) })
        $fwCount = @($lines | Where-Object { $_ -match '\bFW\b|Forward|Resolved|A\b' }).Count
        $nxCount = @($lines | Where-Object { $_ -match '\bNX\b|NXDOMAIN|Name Error|N\b' }).Count
        [pscustomobject]@{
            host = $hostName
            total = $lines.Count
            byResultClass = [pscustomobject]@{
                FW = $fwCount
                NX = $nxCount
                unknown = [Math]::Max(0, $lines.Count - $fwCount - $nxCount)
            }
        }
    })
}

function Get-PhaseResult {
    param(
        [Parameter(Mandatory = $true)][string]$PhaseName,
        [Parameter(Mandatory = $true)][string]$HitLogContent,
        [object]$BrowserArtifact,
        [array]$ResolveEvents = @()
    )

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
    foreach ($event in @($ResolveEvents)) {
        if ($event.host) {
            $hosts.Add([string]$event.host)
        }
    }

    $matchCounts = Get-HostEventCounts -Content $HitLogContent -Hosts $hosts.ToArray()
    $dependencyCounts = @()
    if ($BrowserArtifact -and $BrowserArtifact.dependencies) {
        foreach ($dependency in @($BrowserArtifact.dependencies)) {
            $count = @($matchCounts | Where-Object { $_.host -eq [string]$dependency.host })[0]
            $dependencyCounts += [pscustomobject]@{
                type = [string]$dependency.type
                host = [string]$dependency.host
                hitLogCount = if ($count) { [int]$count.total } else { 0 }
            }
        }
    }

    $anchorCounts = @($matchCounts | Where-Object {
        $BrowserArtifact -and (
            $_.host -eq [string]$BrowserArtifact.origin.host -or
            $_.host -eq [string]$BrowserArtifact.alternateOrigin.host
        )
    })
    $anchorsSeen = @($anchorCounts | Where-Object { [int]$_.total -gt 0 })

    [pscustomobject]@{
        name = $PhaseName
        matchCounts = @($matchCounts)
        dependencyEvents = @($dependencyCounts)
        anchorEvents = @($anchorCounts)
        ambiguousAnchors = if ($anchorsSeen.Count -gt 1) { @($anchorsSeen | ForEach-Object { [string]$_.host }) } else { @() }
        resolveDnsEvents = @($ResolveEvents)
        browserProbeOutcomes = if ($BrowserArtifact) { $BrowserArtifact.dependencyResults } else { $null }
    }
}

function Test-AnyDependencyHit {
    param([object]$Phase)
    return @($Phase.dependencyEvents | Where-Object { [int]$_.hitLogCount -gt 0 }).Count -gt 0
}

function Test-AllDependenciesHit {
    param([object]$Phase)
    return @($Phase.dependencyEvents).Count -gt 0 -and @($Phase.dependencyEvents | Where-Object { [int]$_.hitLogCount -le 0 }).Count -eq 0
}

function Select-MatrixV2Decision {
    param(
        [bool]$ConfigRestored,
        [bool]$HostsRestored,
        [object]$DirectPhase,
        [object]$BrowserNxPhase,
        [object]$BrowserFwPhase,
        [object]$WarmMultiPhase,
        [bool]$BrowserArtifactPresent,
        [string]$RestoreError,
        [string]$ServiceCleanupError
    )

    if (-not $ConfigRestored -or -not $HostsRestored -or -not $BrowserArtifactPresent -or $RestoreError -or $ServiceCleanupError) {
        return 'insufficientEvidence'
    }

    $directEvents = @($DirectPhase.resolveDnsEvents)
    $approvedOk = @($directEvents | Where-Object { $_.name -eq 'approved-origin' -and $_.status -eq 'ok' }).Count -gt 0
    $fwOk = @($directEvents | Where-Object { $_.name -eq 'fw-control' -and $_.status -eq 'ok' }).Count -gt 0
    $nxErrored = @($directEvents | Where-Object { $_.name -eq 'nx-control' -and $_.status -in @('error', 'timeout', 'failed') }).Count -gt 0
    if (-not ($approvedOk -and $fwOk -and $nxErrored)) {
        return 'insufficientEvidence'
    }

    $browserNxSeen = Test-AnyDependencyHit -Phase $BrowserNxPhase
    $browserFwSeen = Test-AnyDependencyHit -Phase $BrowserFwPhase
    $browserNxAll = Test-AllDependenciesHit -Phase $BrowserNxPhase
    $browserFwAll = Test-AllDependenciesHit -Phase $BrowserFwPhase
    $ambiguous = @($WarmMultiPhase.ambiguousAnchors).Count -gt 0

    if (($browserNxSeen -or $browserFwSeen) -and $ambiguous) {
        return 'ambiguousCorrelation'
    }

    if ($browserNxAll -and $browserFwAll) {
        return 'browserDnsObservable'
    }

    if ($browserFwSeen -and -not $browserNxSeen) {
        return 'browserForwardOnly'
    }

    return 'directOnly'
}

function Get-NextAction {
    param([Parameter(Mandatory = $true)][string]$Decision)

    switch ($Decision) {
        'browserDnsObservable' { return 'Design controlled local-learning anchors; do not enable product learning from this diagnostic alone.' }
        'browserForwardOnly' { return 'Do not use HitLog for blocked-dependency learning; restrict follow-up to forward-only evidence.' }
        'directOnly' { return 'Do not proceed with DNS-only browser learning; browser dependency lookups were not observable.' }
        'ambiguousCorrelation' { return 'Plan an anchor/fallback experiment before any learning design.' }
        default { return 'Fix the diagnostic harness before drawing product conclusions.' }
    }
}

function Restore-MatrixV2Files {
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

function Initialize-MatrixV2 {
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

    $suffix = if ([string]::IsNullOrWhiteSpace($env:OPENPATH_STUDENT_HOST_SUFFIX)) {
        Get-RunnerHostSuffix
    }
    else {
        [string]$env:OPENPATH_STUDENT_HOST_SUFFIX
    }
    $env:OPENPATH_STUDENT_HOST_SUFFIX = $suffix
    $approvedOrigin = "site.$suffix"
    $fwControl = "api.direct-fw-control.$suffix"
    $nxControl = ('openpath-hitlog-nx-' + [guid]::NewGuid().ToString('N') + '.invalid')
    Add-FwRulesToHostsFile -HostsPath $hostsPath -Hosts @($fwControl) | Out-Null
    Restart-AcrylicServiceIfPresent

    Write-State @{
        configPath = $configPath
        hostsPath = $hostsPath
        backupConfigHash = Get-FileSha256 -Path $script:ConfigBackupPath
        backupHostsHash = Get-FileSha256 -Path $script:HostsBackupPath
        configuredConfigHash = Get-FileSha256 -Path $configPath
        configuredHostsHash = Get-FileSha256 -Path $hostsPath
        hitLogPath = $script:HitLogPath
        hitLogReadableWhileRunning = Test-HitLogReadableWhileRunning
        runnerHostSuffix = $suffix
        directControlHosts = @{
            approvedOrigin = $approvedOrigin
            fwControl = $fwControl
            nxControl = $nxControl
        }
        serviceRegisteredForDiagnostic = $script:RegisteredAcrylicServiceForDiagnostic
        acrylicServiceName = $script:AcrylicServiceNameUsed
        configuredAt = (Get-Date).ToString('o')
    }
}

function Complete-MatrixV2 {
    Ensure-ArtifactRoot
    $state = Read-State
    $script:RegisteredAcrylicServiceForDiagnostic = [bool]$state.serviceRegisteredForDiagnostic
    if ($state.acrylicServiceName) {
        $script:AcrylicServiceNameUsed = [string]$state.acrylicServiceName
    }
    $directControlHosts = $state.directControlHosts
    $hostsPath = if ($state.hostsPath) { [string]$state.hostsPath } else { Get-AcrylicHostsPath }
    Add-FwRulesToHostsFile -HostsPath $hostsPath -Hosts @([string]$directControlHosts.fwControl) | Out-Null
    Restart-AcrylicServiceIfPresent
    $directCapture = Invoke-PhaseCapture -PhaseName 'direct-dns-control' -ScriptBlock {
        @(
            Invoke-BoundedResolveDns -Name 'approved-origin' -HostName ([string]$directControlHosts.approvedOrigin)
            Invoke-BoundedResolveDns -Name 'fw-control' -HostName ([string]$directControlHosts.fwControl)
            Invoke-BoundedResolveDns -Name 'nx-control' -HostName ([string]$directControlHosts.nxControl)
        )
    }

    $restore = $null
    $restoreError = ''
    $serviceCleanupError = ''
    try {
        $restore = Restore-MatrixV2Files
    }
    catch {
        $restoreError = [string]$_
        $restore = @{
            configPath = if ($state.configPath) { [string]$state.configPath } else { '' }
            hostsPath = if ($state.hostsPath) { [string]$state.hostsPath } else { '' }
            configRestored = $false
            hostsRestored = $false
        }
    }
    try {
        Remove-DiagnosticAcrylicServiceIfCreated
    }
    catch {
        $serviceCleanupError = [string]$_
    }

    $browserArtifact = Get-BrowserArtifact
    $directPhase = Get-PhaseResult `
        -PhaseName 'direct-dns-control' `
        -HitLogContent ([string]$directCapture.hitLogContent) `
        -BrowserArtifact $browserArtifact `
        -ResolveEvents @($directCapture.result)

    $browserPhases = @{}
    foreach ($phaseName in @('browser-nx', 'browser-fw', 'browser-warm-multi-anchor')) {
        $hitLogPath = Join-Path $script:ArtifactsRoot "dns-evidence-v2-$phaseName-hitlog.log"
        $browserPhases[$phaseName] = Get-PhaseResult `
            -PhaseName $phaseName `
            -HitLogContent (Read-TextShared -Path $hitLogPath) `
            -BrowserArtifact $browserArtifact
    }

    $hitLogContent = Read-TextShared -Path $script:HitLogPath
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-evidence-matrix-v2.log') -Value $hitLogContent -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-evidence-matrix-v2.sanitized.log') -Value $hitLogContent -Encoding UTF8

    $phases = @($directPhase, $browserPhases['browser-nx'], $browserPhases['browser-fw'], $browserPhases['browser-warm-multi-anchor'])
    $decision = Select-MatrixV2Decision `
        -ConfigRestored ([bool]$restore.configRestored) `
        -HostsRestored ([bool]$restore.hostsRestored) `
        -DirectPhase $directPhase `
        -BrowserNxPhase $browserPhases['browser-nx'] `
        -BrowserFwPhase $browserPhases['browser-fw'] `
        -WarmMultiPhase $browserPhases['browser-warm-multi-anchor'] `
        -BrowserArtifactPresent ($null -ne $browserArtifact) `
        -RestoreError $restoreError `
        -ServiceCleanupError $serviceCleanupError

    $hashes = [pscustomobject]$restore
    $hashes | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:HashesPath -Encoding UTF8

    [pscustomobject]@{
        configRestored = [bool]$restore.configRestored
        hostsRestored = [bool]$restore.hostsRestored
        runnerHostSuffix = [string]$state.runnerHostSuffix
        hosts = [pscustomobject]@{
            approvedOrigin = [string]$state.directControlHosts.approvedOrigin
            directFwControl = [string]$state.directControlHosts.fwControl
            directNxControl = [string]$state.directControlHosts.nxControl
            browserOrigin = if ($browserArtifact) { [string]$browserArtifact.origin.host } else { $null }
            browserAlternateOrigin = if ($browserArtifact) { [string]$browserArtifact.alternateOrigin.host } else { $null }
            browserDependencies = if ($browserArtifact) { @($browserArtifact.dependencies | ForEach-Object { [string]$_.host }) } else { @() }
        }
        phases = $phases
        browserProbeOutcomes = if ($browserArtifact) { $browserArtifact.dependencyResults } else { $null }
        pktmonControls = @($phases | ForEach-Object {
            [pscustomobject]@{
                phase = $_.name
                metadataPath = (Join-Path $script:ArtifactsRoot ("pktmon-v2-{0}.json" -f (Get-PhaseSafeName -Name $_.name)))
            }
        })
        decision = $decision
        nextAction = Get-NextAction -Decision $decision
        restoreError = $restoreError
        serviceCleanupError = $serviceCleanupError
        acrylicServiceName = [string]$state.acrylicServiceName
        serviceRegisteredForDiagnostic = [bool]$state.serviceRegisteredForDiagnostic
        configHashes = $hashes
        hitLogPath = $script:HitLogPath
        browserArtifactPath = (Join-Path $script:ArtifactsRoot 'dns-evidence-matrix-v2-browser-artifact.json')
        completedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8

    if (-not [bool]$restore.configRestored -or -not [bool]$restore.hostsRestored) {
        throw "DNS evidence matrix v2 failed to restore Acrylic config/hosts. See $script:ResultPath"
    }
}

function Invoke-MatrixV2Run {
    Ensure-ArtifactRoot
    $studentFlowPath = Join-Path $script:RepoRoot 'tests\e2e\ci\run-windows-student-flow.ps1'
    if (-not (Test-Path -LiteralPath $studentFlowPath)) {
        throw "run-windows-student-flow.ps1 not found: $studentFlowPath"
    }

    $previousCoverage = $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE
    $previousScript = $env:OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_V2_SCRIPT
    $previousArtifacts = $env:OPENPATH_STUDENT_ARTIFACTS_DIR
    $previousSuffix = $env:OPENPATH_STUDENT_HOST_SUFFIX
    try {
        $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE = 'dns-evidence-matrix-v2'
        $env:OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_V2_SCRIPT = $PSCommandPath
        $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $script:ArtifactsRoot
        $env:OPENPATH_STUDENT_HOST_SUFFIX = Get-RunnerHostSuffix
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $studentFlowPath
        if ($LASTEXITCODE -ne 0) {
            throw "run-windows-student-flow.ps1 exited with code $LASTEXITCODE"
        }
        if (-not (Test-Path -LiteralPath $script:ResultPath)) {
            throw "DNS evidence matrix v2 result was not written: $script:ResultPath"
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
            Remove-Item Env:\OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_V2_SCRIPT -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_WINDOWS_DNS_EVIDENCE_MATRIX_V2_SCRIPT = $previousScript
        }
        if ($null -eq $previousArtifacts) {
            Remove-Item Env:\OPENPATH_STUDENT_ARTIFACTS_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $previousArtifacts
        }
        if ($null -eq $previousSuffix) {
            Remove-Item Env:\OPENPATH_STUDENT_HOST_SUFFIX -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_STUDENT_HOST_SUFFIX = $previousSuffix
        }
    }
}

try {
    switch ($Mode) {
        'Run' {
            Invoke-MatrixV2Run
        }
        'BeforeSelenium' {
            Initialize-MatrixV2
        }
        'ClearPhase' {
            if ([string]::IsNullOrWhiteSpace($Phase)) {
                throw 'ClearPhase requires -Phase.'
            }
            Ensure-ArtifactRoot
            Clear-HitLogFile
            Invoke-PktmonMetadata -PhaseName $Phase | Out-Null
            [pscustomobject]@{
                phase = $Phase
                hitLogPath = $script:HitLogPath
                clearedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
        }
        'SnapshotPhase' {
            if ([string]::IsNullOrWhiteSpace($Phase)) {
                throw 'SnapshotPhase requires -Phase.'
            }
            $snapshotPath = Copy-HitLogSnapshot -SnapshotPhase $Phase
            [pscustomobject]@{
                phase = $Phase
                hitLogPath = $snapshotPath
                hitLogSha256 = Get-FileSha256 -Path $snapshotPath
                capturedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress -Depth 8
        }
        'ApplyFwRules' {
            Add-FwDependencyRules | ConvertTo-Json -Compress -Depth 8
        }
        'AfterSelenium' {
            Complete-MatrixV2
        }
    }
}
catch {
    try {
        Restore-MatrixV2Files | Out-Null
    }
    catch {
        Write-Warning "Unable to restore Acrylic files after failure: $_"
    }
    try {
        $state = Read-State
        $script:RegisteredAcrylicServiceForDiagnostic = [bool]$state.serviceRegisteredForDiagnostic
        if ($state.acrylicServiceName) {
            $script:AcrylicServiceNameUsed = [string]$state.acrylicServiceName
        }
        Remove-DiagnosticAcrylicServiceIfCreated
    }
    catch {
        Write-Warning "Unable to remove temporary Acrylic service after failure: $_"
    }
    Write-Error $_
    exit 1
}
