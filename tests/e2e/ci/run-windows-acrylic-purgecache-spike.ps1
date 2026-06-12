param(
    [ValidateSet('Run')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-acrylic-purgecache-spike')
)

$ErrorActionPreference = 'Stop'

$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:ResultPath = Join-Path $script:ArtifactsRoot 'acrylic-purgecache-spike-result.json'
$script:HashesPath = Join-Path $script:ArtifactsRoot 'acrylic-purgecache-spike-hashes.json'
$script:HostsBackupPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.before-purgecache-spike'
$script:HostsAfterPath = Join-Path $script:ArtifactsRoot 'AcrylicHosts.txt.after-purgecache-spike'
$script:AcrylicServiceName = 'AcrylicDNSProxySvc'

. (Join-Path $PSScriptRoot 'acrylic-dns-spike-helpers.ps1')

# Intentionally shadows the shared helper in acrylic-dns-spike-helpers.ps1 (divergent behavior; do not replace with the shared version).
function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
}

function Get-AcrylicControllerPath {
    return (Join-Path (Get-AcrylicRoot) 'AcrylicController.exe')
}
# Intentionally shadows the shared helper in acrylic-dns-spike-helpers.ps1 (divergent behavior; do not replace with the shared version).
function Restart-AcrylicServiceIfPresent {
    $service = Get-AcrylicRegisteredService
    if ($null -eq $service) {
        throw "Acrylic service $($script:AcrylicServiceName) was not found."
    }

    if ($service.Status -eq 'Running') {
        Restart-Service -Name $service.Name -Force -ErrorAction Stop
    }
    else {
        Start-Service -Name $service.Name -ErrorAction Stop
    }
    Start-Sleep -Seconds 2
}

function Invoke-AcrylicPurgeCache {
    $controllerPath = Get-AcrylicControllerPath
    if (-not (Test-Path -LiteralPath $controllerPath)) {
        throw "AcrylicController.exe was not found at $controllerPath."
    }

    $stdoutPath = Join-Path $script:ArtifactsRoot 'acrylic-controller-purgecache.out.log'
    $stderrPath = Join-Path $script:ArtifactsRoot 'acrylic-controller-purgecache.err.log'
    $process = Start-Process `
        -FilePath $controllerPath `
        -ArgumentList @('PurgeCache') `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru
    if (-not $process.WaitForExit(15000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'AcrylicController.exe PurgeCache timed out.'
    }

    $process.Refresh()
    return [int]$process.ExitCode
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
            success = $true
            ips = $ips
            error = ''
        }
    }
    catch {
        return @{
            success = $false
            ips = @()
            error = [string]$_.Exception.Message
        }
    }
}

function Write-Result {
    param([Parameter(Mandatory = $true)][hashtable]$Result)

    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8
}

Ensure-ArtifactRoot
$hostsPath = Get-AcrylicHostsPath
if (-not (Test-Path -LiteralPath $hostsPath)) {
    throw "AcrylicHosts.txt was not found at $hostsPath."
}

$originalHosts = [System.IO.File]::ReadAllText($hostsPath)
[System.IO.File]::WriteAllText($script:HostsBackupPath, $originalHosts, [System.Text.Encoding]::ASCII)
$probeHost = ('openpath-purgecache-' + [guid]::NewGuid().ToString('N') + '.test')
$baseline = $null
$afterPurge = $null
$restoreError = ''
$purgeExitCode = $null

try {
    Restart-AcrylicServiceIfPresent
    $baseline = Resolve-ThroughAcrylic -Hostname $probeHost

    $updatedHosts = $originalHosts.TrimEnd() + "`r`n127.0.0.1 $probeHost`r`n"
    [System.IO.File]::WriteAllText($hostsPath, $updatedHosts, [System.Text.Encoding]::ASCII)
    $purgeExitCode = Invoke-AcrylicPurgeCache
    Start-Sleep -Seconds 2
    $afterPurge = Resolve-ThroughAcrylic -Hostname $probeHost

    $reloadObserved = (
        $afterPurge.success -eq $true -and
        @($afterPurge.ips) -contains '127.0.0.1'
    )
    $decision = if ($reloadObserved) { 'purgeCacheReloadsHosts' } else { 'restartRequired' }

    Copy-Item -LiteralPath $hostsPath -Destination $script:HostsAfterPath -Force
    Write-Result @{
        decision = $decision
        probeHost = $probeHost
        purgeCacheExitCode = $purgeExitCode
        baseline = $baseline
        afterPurgeCache = $afterPurge
        officialAcrylicHostsContract = 'Acrylic Hosts documentation says AcrylicHosts.txt changes require service restart.'
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
}
catch {
    Write-Result @{
        decision = 'inconclusive'
        probeHost = $probeHost
        purgeCacheExitCode = $purgeExitCode
        baseline = $baseline
        afterPurgeCache = $afterPurge
        error = [string]$_
        officialAcrylicHostsContract = 'Acrylic Hosts documentation says AcrylicHosts.txt changes require service restart.'
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
}
finally {
    try {
        [System.IO.File]::WriteAllText($hostsPath, $originalHosts, [System.Text.Encoding]::ASCII)
        Restart-AcrylicServiceIfPresent
    }
    catch {
        $restoreError = [string]$_
    }

    @{
        originalHostsSha256 = Get-FileSha256 -Path $script:HostsBackupPath
        restoredHostsSha256 = Get-FileSha256 -Path $hostsPath
        afterHostsSha256 = Get-FileSha256 -Path $script:HostsAfterPath
        restoreError = $restoreError
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:HashesPath -Encoding UTF8
}
