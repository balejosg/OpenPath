# OpenPath - WEDU captive portal diagnostics

[CmdletBinding()]
param(
    [string]$PortalHost = 'nce.wedu.comunidad.madrid',
    [string]$OutputDirectory = '',
    [switch]$Quick,
    [switch]$NoZip,
    [int]$TimeoutSeconds = 5,
    [int]$QuickTimeout = 1
)

$ErrorActionPreference = 'Stop'

function Write-OpenPathDiagnosticStep {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Invoke-OpenPathDiagnosticCapture {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$Name = 'capture'
    )

    try {
        return (& $Action)
    }
    catch {
        return [PSCustomObject]@{
            name = $Name
            ok = $false
            error = [string]$_.Exception.Message
        }
    }
}

function Get-OpenPathScheduledTaskInfoSnapshot {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [PSCustomObject]@{
            taskName = $TaskName
            found = $false
        }
    }

    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        taskName = $TaskName
        found = $true
        state = [string]$task.State
        lastRunTime = if ($taskInfo) { $taskInfo.LastRunTime } else { $null }
        lastTaskResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
        nextRunTime = if ($taskInfo) { $taskInfo.NextRunTime } else { $null }
    }
}

function Invoke-OpenPathDnsProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Server = '',
        [int]$Timeout = 5,
        [int]$QuickTimeout = 1
    )

    $effectiveTimeout = if ($Quick) { $QuickTimeout } else { $Timeout }
    $job = Start-Job -ScriptBlock {
        param([string]$ProbeName, [string]$ProbeServer)

        $resolveArgs = @{
            Name = $ProbeName
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($ProbeServer)) {
            $resolveArgs.Server = $ProbeServer
        }

        Resolve-DnsName @resolveArgs |
            Select-Object Name, Type, IPAddress, NameHost, QueryType, Section
    } -ArgumentList $Name, $Server

    try {
        if (Wait-Job -Job $job -Timeout $effectiveTimeout) {
            $records = @(Receive-Job -Job $job -ErrorAction Stop)
            return [PSCustomObject]@{
                name = $Name
                server = if ($Server) { $Server } else { 'default' }
                ok = $true
                records = @($records)
            }
        }

        Stop-Job -Job $job -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            name = $Name
            server = if ($Server) { $Server } else { 'default' }
            ok = $false
            timedOut = $true
            timeoutSeconds = $effectiveTimeout
        }
    }
    catch {
        return [PSCustomObject]@{
            name = $Name
            server = if ($Server) { $Server } else { 'default' }
            ok = $false
            error = [string]$_.Exception.Message
        }
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Copy-OpenPathDiagnosticFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $Source -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            source = $Source
            copied = $false
        }
    }

    $safeName = ($Source -replace '[:\\\/]+', '_').Trim('_')
    $destination = Join-Path $DestinationDirectory $safeName
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    return [PSCustomObject]@{
        source = $Source
        copied = $true
        destination = $destination
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path (Get-Location) "wedu-captive-portal-diagnostics-$stamp"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$snapshotDirectory = Join-Path $OutputDirectory 'snapshots'
New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null

Write-OpenPathDiagnosticStep -Message 'Capturing OpenPath state'
$recoveryTask = Get-OpenPathScheduledTaskInfoSnapshot -TaskName 'OpenPath-CaptivePortalRecovery'
$dnsHealthTask = Get-OpenPathScheduledTaskInfoSnapshot -TaskName 'OpenPath-DNSHealth'

$adapters = Invoke-OpenPathDiagnosticCapture -Name 'adapter-dns' -Action {
    Get-DnsClientServerAddress -AddressFamily IPv4 |
        Select-Object InterfaceAlias, InterfaceIndex, ServerAddresses
}

$snapshots = @(
    Copy-OpenPathDiagnosticFile -Source 'C:\OpenPath\data\config.json' -DestinationDirectory $snapshotDirectory
    Copy-OpenPathDiagnosticFile -Source 'C:\OpenPath\data\captive-portal-active.json' -DestinationDirectory $snapshotDirectory
    Copy-OpenPathDiagnosticFile -Source 'C:\OpenPath\data\captive-portal-observation.json' -DestinationDirectory $snapshotDirectory
    Copy-OpenPathDiagnosticFile -Source 'C:\OpenPath\data\logs\openpath.log' -DestinationDirectory $snapshotDirectory
    Copy-OpenPathDiagnosticFile -Source "${env:ProgramFiles(x86)}\Acrylic DNS Proxy\AcrylicConfiguration.ini" -DestinationDirectory $snapshotDirectory
    Copy-OpenPathDiagnosticFile -Source "${env:ProgramFiles(x86)}\Acrylic DNS Proxy\AcrylicHosts.txt" -DestinationDirectory $snapshotDirectory
)

Write-OpenPathDiagnosticStep -Message 'Capturing DNS probes'
$dnsProbes = @(
    Invoke-OpenPathDnsProbe -Name $PortalHost -Server '127.0.0.1' -Timeout $TimeoutSeconds -QuickTimeout $QuickTimeout
    Invoke-OpenPathDnsProbe -Name $PortalHost -Timeout $TimeoutSeconds -QuickTimeout $QuickTimeout
    Invoke-OpenPathDnsProbe -Name 'detectportal.firefox.com' -Server '127.0.0.1' -Timeout $TimeoutSeconds -QuickTimeout $QuickTimeout
    Invoke-OpenPathDnsProbe -Name 'www.msftconnecttest.com' -Server '127.0.0.1' -Timeout $TimeoutSeconds -QuickTimeout $QuickTimeout
)

$httpProbes = @()
if ($Quick) {
    $httpProbes = @(
        [PSCustomObject]@{
            skipped = $true
            reason = 'quick-mode'
        }
    )
}
else {
    Write-OpenPathDiagnosticStep -Message 'Capturing HTTP probes'
    $httpProbes = @(
        foreach ($url in @("http://$PortalHost/", 'http://detectportal.firefox.com/success.txt', 'http://www.msftconnecttest.com/connecttest.txt')) {
            Invoke-OpenPathDiagnosticCapture -Name $url -Action {
                $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSeconds -MaximumRedirection 0
                [PSCustomObject]@{
                    url = $url
                    statusCode = [int]$response.StatusCode
                    contentLength = if ($response.Content) { ([string]$response.Content).Length } else { 0 }
                }
            }
        }
    )
}

$result = [PSCustomObject]@{
    portalHost = $PortalHost
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    quick = [bool]$Quick
    recoveryTask = $recoveryTask
    dnsHealthTask = $dnsHealthTask
    adapters = $adapters
    dnsProbes = @($dnsProbes)
    httpProbes = @($httpProbes)
    snapshots = @($snapshots)
}

$jsonPath = Join-Path $OutputDirectory 'wedu-captive-portal-diagnostics.json'
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding UTF8 -Force

if (-not $NoZip) {
    $zipPath = "$OutputDirectory.zip"
    Compress-Archive -Path (Join-Path $OutputDirectory '*') -DestinationPath $zipPath -Force
    Write-Host "ZIP: $zipPath"
}

Write-Host "JSON: $jsonPath"
return $result
