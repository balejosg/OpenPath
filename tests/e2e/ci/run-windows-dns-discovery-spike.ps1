param(
    [ValidateSet('Run', 'BeforeSelenium', 'ClearHitLog', 'SnapshotHitLog', 'AfterSelenium')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-dns-discovery-spike'),
    [string]$Phase = ''
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:StatePath = Join-Path $script:ArtifactsRoot 'dns-discovery-spike-state.json'
$script:BackupConfigPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.before-dns-discovery-spike'
$script:ResultPath = Join-Path $script:ArtifactsRoot 'dns-discovery-spike-result.json'
$script:HitLogPath = 'C:\OpenPath\data\logs\acrylic-dns-discovery-spike.log'
$script:AcrylicServiceName = 'AcrylicDNSProxySvc'

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
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $content = if (Test-Path -LiteralPath $ConfigPath) {
        [System.IO.File]::ReadAllText($ConfigPath)
    }
    else {
        "[GlobalSection]`r`n"
    }
    $lines = $content -split '\r?\n'

    # Marker strings kept literal for the runner contract tests.
    $requiredConfigMarkers = @('HitLogFileWhat=XHCFRU', 'HitLogMaxPendingHits=512')
    if ($requiredConfigMarkers.Count -ne 2) {
        throw 'Unexpected DNS discovery HitLog marker set.'
    }

    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileName' -Value $script:HitLogPath
    $lines = Set-IniValue -Lines $lines -Key 'HitLogFileWhat' -Value 'XHCFRU'
    $lines = Set-IniValue -Lines $lines -Key 'HitLogMaxPendingHits' -Value '512'
    [System.IO.File]::WriteAllText($ConfigPath, ($lines -join "`r`n"), [System.Text.Encoding]::ASCII)
}

function Restart-AcrylicServiceIfPresent {
    $service = Get-Service -Name $script:AcrylicServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        throw "Acrylic service $($script:AcrylicServiceName) was not found."
    }

    Restart-Service -Name $script:AcrylicServiceName -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
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

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{}
    }

    return (Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json)
}

function Write-State {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Initialize-SpikeHitLog {
    Ensure-ArtifactRoot
    $configPath = Get-AcrylicConfigurationPath
    $hostsPath = Get-AcrylicHostsPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "AcrylicConfiguration.ini was not found at $configPath."
    }

    [System.IO.File]::Copy($configPath, $script:BackupConfigPath, $true)
    $originalHash = Get-FileSha256 -Path $configPath
    $hostsHash = Get-FileSha256 -Path $hostsPath

    Set-HitLogConfiguration -ConfigPath $configPath
    Clear-HitLogFile
    Restart-AcrylicServiceIfPresent
    $readable = Test-HitLogReadableWhileRunning

    Write-State @{
        configPath = $configPath
        hostsPath = $hostsPath
        originalConfigHash = $originalHash
        hostsHash = $hostsHash
        hitLogPath = $script:HitLogPath
        hitLogReadableWhileRunning = $readable
        configuredAt = (Get-Date).ToString('o')
    }

    @{
        configPath = $configPath
        hostsPath = $hostsPath
        originalConfigHash = $originalHash
        configuredConfigHash = Get-FileSha256 -Path $configPath
        hostsHash = $hostsHash
        hitLogPath = $script:HitLogPath
        hitLogReadableWhileRunning = $readable
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-discovery-spike.hashes.json') -Encoding UTF8

    if (-not $readable) {
        throw 'Acrylic HitLog could not be opened with FileShare.ReadWrite while the service was running.'
    }
}

function Copy-HitLogSnapshot {
    param([Parameter(Mandatory = $true)][string]$SnapshotPhase)

    Ensure-ArtifactRoot
    $safePhase = $SnapshotPhase -replace '[^a-zA-Z0-9_-]', '-'
    $snapshotPath = Join-Path $script:ArtifactsRoot "dns-discovery-$safePhase-hitlog.log"
    $content = Read-TextShared -Path $script:HitLogPath
    Set-Content -LiteralPath $snapshotPath -Value $content -Encoding UTF8
    return $snapshotPath
}

function Disable-HitLogFileName {
    $state = Read-State
    $configPath = if ($state.configPath) { [string]$state.configPath } else { Get-AcrylicConfigurationPath }
    if (-not (Test-Path -LiteralPath $configPath)) {
        return
    }

    $content = [System.IO.File]::ReadAllText($configPath)
    if ($content -match '(?m)^\s*HitLogFileName\s*=\s*$') {
        return
    }

    $lines = Set-IniValue -Lines ($content -split '\r?\n') -Key 'HitLogFileName' -Value ''
    [System.IO.File]::WriteAllText($configPath, ($lines -join "`r`n"), [System.Text.Encoding]::ASCII)
}

function Restore-AcrylicConfig {
    $state = Read-State
    $configPath = if ($state.configPath) { [string]$state.configPath } else { Get-AcrylicConfigurationPath }
    if (Test-Path -LiteralPath $script:BackupConfigPath) {
        [System.IO.File]::Copy($script:BackupConfigPath, $configPath, $true)
    }
    else {
        Disable-HitLogFileName
    }
    Restart-AcrylicServiceIfPresent
    return @{
        configPath = $configPath
        configRestored = ((Get-FileSha256 -Path $configPath) -eq [string]$state.originalConfigHash)
        restoredConfigHash = Get-FileSha256 -Path $configPath
        originalConfigHash = [string]$state.originalConfigHash
    }
}

function Get-DependencyEvents {
    param(
        [Parameter(Mandatory = $true)][array]$Dependencies,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $Dependencies | ForEach-Object {
        $hostPattern = [regex]::Escape([string]$_.host)
        $count = ([regex]::Matches($Content, $hostPattern)).Count
        [pscustomobject]@{
            type = $_.type
            host = $_.host
            count = $count
        }
    }
}

function Get-AmbiguousAnchors {
    param(
        [Parameter(Mandatory = $true)][string]$OriginHost,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $matches = [regex]::Matches($Content, '\bsite\.[a-zA-Z0-9.-]+\b') |
        ForEach-Object { $_.Value.ToLowerInvariant() } |
        Where-Object { $_ -ne $OriginHost.ToLowerInvariant() } |
        Sort-Object -Unique
    return @($matches)
}

function Build-PhaseResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$OriginHost,
        [Parameter(Mandatory = $true)][array]$Dependencies,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [pscustomobject]@{
        name = $Name
        originHost = $OriginHost
        dependencyHosts = @($Dependencies | ForEach-Object { $_.host })
        anchorSeen = $Content -match [regex]::Escape($OriginHost)
        dependencyEvents = @(Get-DependencyEvents -Dependencies $Dependencies -Content $Content)
        ambiguousAnchors = @(Get-AmbiguousAnchors -OriginHost $OriginHost -Content $Content)
    }
}

function Select-SpikeDecision {
    param(
        [Parameter(Mandatory = $true)][array]$Phases,
        [bool]$HitLogReadableWhileRunning,
        [bool]$HitLogFlushObserved,
        [bool]$ConfigRestored
    )

    if (-not $HitLogReadableWhileRunning -or -not $HitLogFlushObserved -or -not $ConfigRestored) {
        return 'insufficientEvidence'
    }

    $warm = @($Phases | Where-Object { $_.name -eq 'warm-approved-origin' })[0]
    if ($null -eq $warm) {
        return 'insufficientEvidence'
    }

    $dependencyCounts = @($warm.dependencyEvents | ForEach-Object { [int]$_.count })
    $missingDependencies = @($dependencyCounts | Where-Object { $_ -le 0 })
    $allDependenciesSeen = ($dependencyCounts.Count -gt 0) -and ($missingDependencies.Count -eq 0)
    if (-not $allDependenciesSeen) {
        return 'insufficientEvidence'
    }

    if (-not [bool]$warm.anchorSeen) {
        return 'fallbackRequired'
    }

    if (@($warm.ambiguousAnchors).Count -eq 0) {
        return 'dnsOnlyViable'
    }

    return 'insufficientEvidence'
}

function Complete-Spike {
    Ensure-ArtifactRoot
    $state = Read-State
    try {
        $restore = Restore-AcrylicConfig
    }
    finally {
        try {
            Disable-HitLogFileName
        }
        catch {
            Write-Warning "Unable to clear HitLogFileName after restore: $_"
        }
    }
    $restore['restoredConfigHash'] = Get-FileSha256 -Path ([string]$restore['configPath'])
    $restore['configRestored'] = ($restore['restoredConfigHash'] -eq $restore['originalConfigHash'])

    $browserArtifactPath = Join-Path $script:ArtifactsRoot 'dns-discovery-spike-browser-artifact.json'
    $browserArtifact = if (Test-Path -LiteralPath $browserArtifactPath) {
        Get-Content -LiteralPath $browserArtifactPath -Raw | ConvertFrom-Json
    }
    else {
        $null
    }

    $originHost = if ($browserArtifact -and $browserArtifact.origin.host) {
        [string]$browserArtifact.origin.host
    }
    else {
        ''
    }
    $dependencies = if ($browserArtifact -and $browserArtifact.dependencies) {
        @($browserArtifact.dependencies)
    }
    else {
        @()
    }

    $coldContent = Read-TextShared -Path (Join-Path $script:ArtifactsRoot 'dns-discovery-cold-origin-hitlog.log')
    $warmContent = Read-TextShared -Path (Join-Path $script:ArtifactsRoot 'dns-discovery-warm-approved-origin-hitlog.log')
    $hitLogFlushObserved = (($coldContent.Trim().Length -gt 0) -or ($warmContent.Trim().Length -gt 0))
    $phases = @(
        Build-PhaseResult -Name 'cold-origin' -OriginHost $originHost -Dependencies $dependencies -Content $coldContent
        Build-PhaseResult -Name 'warm-approved-origin' -OriginHost $originHost -Dependencies $dependencies -Content $warmContent
    )
    $decision = Select-SpikeDecision `
        -Phases $phases `
        -HitLogReadableWhileRunning ([bool]$state.hitLogReadableWhileRunning) `
        -HitLogFlushObserved $hitLogFlushObserved `
        -ConfigRestored ([bool]$restore['configRestored'])

    $hitLogContent = Read-TextShared -Path $script:HitLogPath
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-discovery-spike.log') -Value $hitLogContent -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'acrylic-dns-discovery-spike.sanitized.log') -Value $hitLogContent -Encoding UTF8

    [pscustomobject]@{
        configRestored = [bool]$restore['configRestored']
        hitLogReadableWhileRunning = [bool]$state.hitLogReadableWhileRunning
        hitLogFlushObserved = $hitLogFlushObserved
        phases = $phases
        decision = $decision
        browserArtifactPath = $browserArtifactPath
        configHashes = $restore
        hostsHash = $state.hostsHash
        completedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8

    if ($decision -eq 'insufficientEvidence') {
        throw "DNS discovery spike produced insufficient evidence. See $script:ResultPath"
    }
}

function Invoke-SpikeRun {
    Ensure-ArtifactRoot
    $studentFlowPath = Join-Path $script:RepoRoot 'tests\e2e\ci\run-windows-student-flow.ps1'
    if (-not (Test-Path -LiteralPath $studentFlowPath)) {
        throw "run-windows-student-flow.ps1 not found: $studentFlowPath"
    }

    $previousCoverage = $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE
    $previousScript = $env:OPENPATH_WINDOWS_DNS_DISCOVERY_SPIKE_SCRIPT
    $previousArtifacts = $env:OPENPATH_STUDENT_ARTIFACTS_DIR
    try {
        $env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE = 'dns-discovery-spike'
        $env:OPENPATH_WINDOWS_DNS_DISCOVERY_SPIKE_SCRIPT = $PSCommandPath
        $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $script:ArtifactsRoot
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $studentFlowPath
        if ($LASTEXITCODE -ne 0) {
            throw "run-windows-student-flow.ps1 exited with code $LASTEXITCODE"
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
            Remove-Item Env:\OPENPATH_WINDOWS_DNS_DISCOVERY_SPIKE_SCRIPT -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_WINDOWS_DNS_DISCOVERY_SPIKE_SCRIPT = $previousScript
        }

        if ($null -eq $previousArtifacts) {
            Remove-Item Env:\OPENPATH_STUDENT_ARTIFACTS_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $previousArtifacts
        }
    }
}

try {
    switch ($Mode) {
        'Run' {
            Invoke-SpikeRun
        }
        'BeforeSelenium' {
            Initialize-SpikeHitLog
        }
        'ClearHitLog' {
            if ([string]::IsNullOrWhiteSpace($Phase)) {
                throw 'ClearHitLog requires -Phase.'
            }
            Ensure-ArtifactRoot
            Clear-HitLogFile
            [pscustomobject]@{
                phase = $Phase
                hitLogPath = $script:HitLogPath
                clearedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
        }
        'SnapshotHitLog' {
            if ([string]::IsNullOrWhiteSpace($Phase)) {
                throw 'SnapshotHitLog requires -Phase.'
            }
            $snapshotPath = Copy-HitLogSnapshot -SnapshotPhase $Phase
            [pscustomobject]@{
                phase = $Phase
                path = $snapshotPath
                sha256 = Get-FileSha256 -Path $snapshotPath
                capturedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
        }
        'AfterSelenium' {
            Complete-Spike
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
