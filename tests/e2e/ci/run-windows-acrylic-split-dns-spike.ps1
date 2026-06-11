param(
    [ValidateSet('Run')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-acrylic-split-dns-spike')
)

$ErrorActionPreference = 'Stop'

# R1 spike for the permanent split-DNS redesign: prove on the REAL pinned Acrylic
# binary that a third upstream (TertiaryServer*) with a DomainNameAffinityMask
# DISJOINT from Primary/Secondary gives exclusive routing:
#   - a "portal" domain is forwarded ONLY to the tertiary server, and
#   - every other domain is forwarded ONLY to the primary/secondary servers.
# Exclusivity is proven behaviorally with alive vs guaranteed-dead (TEST-NET)
# upstreams: a query whose only mask-matching server is dead MUST fail, and a
# query whose only mask-matching server is alive MUST succeed. If masks leaked
# (global instead of per-server, or Tertiary* ignored) the expectations invert.

$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:ResultPath = Join-Path $script:ArtifactsRoot 'acrylic-split-dns-spike-result.json'
$script:HashesPath = Join-Path $script:ArtifactsRoot 'acrylic-split-dns-spike-hashes.json'
$script:IniBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.before-split-dns-spike'
$script:HostsBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.before-split-dns-spike'
$script:IniPhase1Path = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.split-dns-phase1'
$script:IniPhase2Path = Join-Path $script:ArtifactsRoot 'AcrylicConfiguration.ini.split-dns-phase2'
$script:AcrylicServiceName = 'AcrylicDNSProxySvc'
$script:WatchdogTaskName = 'OpenPath-Watchdog'

$script:SplitDomain = 'example.com'
$script:SplitSubDomain = 'www.example.com'
$script:ControlDomain = 'www.msftconnecttest.com'
$script:DeadServerA = '192.0.2.1'
$script:DeadServerB = '192.0.2.2'

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
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

function Get-AcrylicIniValue {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $match = [regex]::Match($Content, "(?m)^\s*$([regex]::Escape($Key))\s*=\s*(.*?)\s*$")
    if (-not $match.Success) {
        return ''
    }

    return ([string]$match.Groups[1].Value).Trim()
}

function Set-AcrylicIniValue {
    # Replace the key in place when present; otherwise insert it right after
    # PrimaryServerAddress so the new key stays inside the same INI section
    # (a key appended after the last section would be silently ignored).
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $pattern = "(?m)^\s*$([regex]::Escape($Key))\s*=.*$"
    if ([regex]::IsMatch($Content, $pattern)) {
        return ([regex]::new($pattern)).Replace($Content, "$Key=$Value", 1)
    }

    $anchor = [regex]::Match($Content, '(?m)^\s*PrimaryServerAddress\s*=.*$')
    if (-not $anchor.Success) {
        throw 'PrimaryServerAddress was not found in AcrylicConfiguration.ini; refusing to guess the section.'
    }

    $insertAt = $anchor.Index + $anchor.Length
    return $Content.Substring(0, $insertAt) + "`r`n$Key=$Value" + $Content.Substring($insertAt)
}

function Set-SpikeDnsTopology {
    param(
        [Parameter(Mandatory = $true)][string]$BaseIniContent,
        [Parameter(Mandatory = $true)][string]$AcrylicRoot,
        [Parameter(Mandatory = $true)][string]$PrimaryAddress,
        [Parameter(Mandatory = $true)][string]$PrimaryMask,
        [Parameter(Mandatory = $true)][string]$SecondaryAddress,
        [Parameter(Mandatory = $true)][string]$SecondaryMask,
        [Parameter(Mandatory = $true)][string]$TertiaryAddress,
        [Parameter(Mandatory = $true)][string]$TertiaryMask,
        [Parameter(Mandatory = $true)][string]$SnapshotPath
    )

    $content = $BaseIniContent
    foreach ($entry in @(
        @{ Key = 'PrimaryServerAddress'; Value = $PrimaryAddress },
        @{ Key = 'PrimaryServerDomainNameAffinityMask'; Value = $PrimaryMask },
        @{ Key = 'SecondaryServerAddress'; Value = $SecondaryAddress },
        @{ Key = 'SecondaryServerDomainNameAffinityMask'; Value = $SecondaryMask },
        @{ Key = 'TertiaryServerAddress'; Value = $TertiaryAddress },
        @{ Key = 'TertiaryServerPort'; Value = '53' },
        @{ Key = 'TertiaryServerProtocol'; Value = 'UDP' },
        @{ Key = 'TertiaryServerDomainNameAffinityMask'; Value = $TertiaryMask }
    )) {
        $content = Set-AcrylicIniValue -Content $content -Key $entry.Key -Value $entry.Value
    }

    $iniPath = Join-Path $AcrylicRoot 'AcrylicConfiguration.ini'
    $service = Get-AcrylicRegisteredService
    if ($null -eq $service) {
        throw "Acrylic service $($script:AcrylicServiceName) was not found."
    }

    Stop-Service -Name $service.Name -Force -ErrorAction Stop
    # Acrylic config must be ASCII/no-BOM (a BOM breaks every query), and the
    # persisted address cache must go or stale (incl. negative) answers from the
    # previous phase would survive the restart and fake the verdict.
    [System.IO.File]::WriteAllText($iniPath, $content, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($SnapshotPath, $content, [System.Text.Encoding]::ASCII)
    Remove-Item -LiteralPath (Join-Path $AcrylicRoot 'AcrylicCache.dat') -Force -ErrorAction SilentlyContinue
    Start-Service -Name $service.Name -ErrorAction Stop
    Start-Sleep -Seconds 2
}

function Resolve-ThroughAcrylic {
    param([Parameter(Mandatory = $true)][string]$Hostname)

    try {
        $records = @(Resolve-DnsName -Name $Hostname -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
        $ips = @(
            $records |
                Where-Object { $_.IPAddress } |
                ForEach-Object { [string]$_.IPAddress }
        )
        return @{
            domain = $Hostname
            success = ($ips.Count -gt 0)
            ips = $ips
            error = ''
        }
    }
    catch {
        return @{
            domain = $Hostname
            success = $false
            ips = @()
            error = [string]$_.Exception.Message
        }
    }
}

function Invoke-SpikePhaseProbes {
    return @{
        splitDomain = (Resolve-ThroughAcrylic -Hostname $script:SplitDomain)
        splitSubDomain = (Resolve-ThroughAcrylic -Hostname $script:SplitSubDomain)
        controlDomain = (Resolve-ThroughAcrylic -Hostname $script:ControlDomain)
    }
}

function Write-Result {
    param([Parameter(Mandatory = $true)][hashtable]$Result)

    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8
}

Ensure-ArtifactRoot
$acrylicRoot = Get-AcrylicRoot
$iniPath = Join-Path $acrylicRoot 'AcrylicConfiguration.ini'
$hostsPath = Join-Path $acrylicRoot 'AcrylicHosts.txt'
foreach ($requiredPath in @($iniPath, $hostsPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required Acrylic file was not found at $requiredPath."
    }
}

$originalIni = [System.IO.File]::ReadAllText($iniPath)
$originalHosts = [System.IO.File]::ReadAllText($hostsPath)
[System.IO.File]::WriteAllText($script:IniBackupPath, $originalIni, [System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllText($script:HostsBackupPath, $originalHosts, [System.Text.Encoding]::ASCII)

# Alive upstreams must already be allowed by OpenPath's anti-bypass firewall, so
# reuse the configured ones instead of inventing new addresses.
$aliveUpstreamA = Get-AcrylicIniValue -Content $originalIni -Key 'PrimaryServerAddress'
$aliveUpstreamB = Get-AcrylicIniValue -Content $originalIni -Key 'SecondaryServerAddress'
if (-not $aliveUpstreamA) { $aliveUpstreamA = '8.8.8.8' }
if (-not $aliveUpstreamB) { $aliveUpstreamB = $aliveUpstreamA }

$excludeSplitMask = "^$($script:SplitDomain);^*.$($script:SplitDomain);*"
$onlySplitMask = "$($script:SplitDomain);*.$($script:SplitDomain)"

$acrylicVersion = ''
try {
    $acrylicVersion = [string](Get-Item -LiteralPath (Join-Path $acrylicRoot 'AcrylicService.exe') -ErrorAction Stop).VersionInfo.FileVersion
}
catch { }

$watchdogTaskSuspended = $false
$phase1 = $null
$phase2 = $null
$postRestoreSanity = $null
$restoreError = ''

try {
    # Keep the OpenPath watchdog from repairing "protected mode" (rewriting the
    # hosts/config and restarting Acrylic) mid-spike. Re-enabled in finally.
    $watchdogTask = Get-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
    if ($watchdogTask) {
        Disable-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction Stop | Out-Null
        $watchdogTaskSuspended = $true
    }

    # Pure-forwarding hosts file: no FW/NX entries, so only the per-server
    # affinity masks decide where each query goes.
    [System.IO.File]::WriteAllText($hostsPath, "# split-dns spike: pure forwarding`r`n", [System.Text.Encoding]::ASCII)

    # Phase 1 -- the split domain's ONLY mask-matching server is DEAD while both
    # alive servers explicitly exclude it. If per-server masks are honored the
    # split domain cannot resolve although the alive upstreams know it.
    Set-SpikeDnsTopology `
        -BaseIniContent $originalIni `
        -AcrylicRoot $acrylicRoot `
        -PrimaryAddress $aliveUpstreamA -PrimaryMask $excludeSplitMask `
        -SecondaryAddress $aliveUpstreamB -SecondaryMask $excludeSplitMask `
        -TertiaryAddress $script:DeadServerA -TertiaryMask $onlySplitMask `
        -SnapshotPath $script:IniPhase1Path
    $phase1 = Invoke-SpikePhaseProbes

    # Phase 2 -- inverted: both primary/secondary are DEAD, the tertiary is the
    # alive server and matches ONLY the split domain. The split domain must now
    # resolve (tertiary really queried) and the control domain must NOT (its only
    # candidates are dead; if tertiary masks leaked it would resolve).
    Set-SpikeDnsTopology `
        -BaseIniContent $originalIni `
        -AcrylicRoot $acrylicRoot `
        -PrimaryAddress $script:DeadServerA -PrimaryMask $excludeSplitMask `
        -SecondaryAddress $script:DeadServerB -SecondaryMask $excludeSplitMask `
        -TertiaryAddress $aliveUpstreamA -TertiaryMask $onlySplitMask `
        -SnapshotPath $script:IniPhase2Path
    $phase2 = Invoke-SpikePhaseProbes

    $splitExcludedFromAliveUpstreams = (-not $phase1.splitDomain.success) -and (-not $phase1.splitSubDomain.success)
    $phase1ControlResolves = [bool]$phase1.controlDomain.success
    $tertiaryAnswersItsDomains = [bool]($phase2.splitDomain.success -and $phase2.splitSubDomain.success)
    $tertiaryIsolatedFromOtherDomains = (-not $phase2.controlDomain.success)

    $decision = if ($splitExcludedFromAliveUpstreams -and $phase1ControlResolves -and $tertiaryAnswersItsDomains -and $tertiaryIsolatedFromOtherDomains) {
        'tertiary-split-dns-viable'
    }
    elseif ($phase2.controlDomain.success) {
        'masks-leaked-to-tertiary'
    }
    elseif (-not $tertiaryAnswersItsDomains) {
        'tertiary-not-honored'
    }
    else {
        'inconclusive'
    }

    Write-Result @{
        decision = $decision
        acrylicVersion = $acrylicVersion
        aliveUpstreams = @($aliveUpstreamA, $aliveUpstreamB)
        deadUpstreams = @($script:DeadServerA, $script:DeadServerB)
        splitDomain = $script:SplitDomain
        controlDomain = $script:ControlDomain
        excludeSplitMask = $excludeSplitMask
        onlySplitMask = $onlySplitMask
        phase1 = $phase1
        phase2 = $phase2
        splitExcludedFromAliveUpstreams = $splitExcludedFromAliveUpstreams
        phase1ControlResolves = $phase1ControlResolves
        tertiaryAnswersItsDomains = $tertiaryAnswersItsDomains
        tertiaryIsolatedFromOtherDomains = $tertiaryIsolatedFromOtherDomains
        watchdogTaskSuspended = $watchdogTaskSuspended
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
}
catch {
    Write-Result @{
        decision = 'inconclusive'
        acrylicVersion = $acrylicVersion
        phase1 = $phase1
        phase2 = $phase2
        watchdogTaskSuspended = $watchdogTaskSuspended
        error = [string]$_
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
}
finally {
    try {
        $service = Get-AcrylicRegisteredService
        if ($null -ne $service) {
            Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
        }
        [System.IO.File]::WriteAllText($iniPath, $originalIni, [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText($hostsPath, $originalHosts, [System.Text.Encoding]::ASCII)
        Remove-Item -LiteralPath (Join-Path $acrylicRoot 'AcrylicCache.dat') -Force -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            Start-Service -Name $service.Name -ErrorAction Stop
        }
        Start-Sleep -Seconds 2
        $postRestoreSanity = Resolve-ThroughAcrylic -Hostname $script:ControlDomain
    }
    catch {
        $restoreError = [string]$_
    }

    try {
        if ($watchdogTaskSuspended) {
            Enable-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction Stop | Out-Null
        }
    }
    catch {
        $restoreError = ($restoreError + ' | watchdog re-enable failed: ' + [string]$_).Trim(' |')
    }

    @{
        originalIniSha256 = Get-FileSha256 -Path $script:IniBackupPath
        restoredIniSha256 = Get-FileSha256 -Path $iniPath
        originalHostsSha256 = Get-FileSha256 -Path $script:HostsBackupPath
        restoredHostsSha256 = Get-FileSha256 -Path $hostsPath
        postRestoreSanity = $postRestoreSanity
        restoreError = $restoreError
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:HashesPath -Encoding UTF8
}
