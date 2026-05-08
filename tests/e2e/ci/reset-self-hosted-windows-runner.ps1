Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Write-Host 'Resetting persistent self-hosted Windows runner state...'

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.Name -in @('node.exe', 'esbuild.exe', 'postgres.exe', 'pg_ctl.exe', 'npm.cmd', 'npm.exe', 'powershell.exe', 'pwsh.exe') -and
        (
            $_.CommandLine -like '*openpath-direct-overlay-*' -or
            $_.CommandLine -like '*openpath-direct-node-v*' -or
            $_.CommandLine -like '*run-windows-student-flow.ps1*' -or
            $_.CommandLine -like '*run-windows-browser-boundary-ci.ps1*' -or
            $_.CommandLine -like '*windows-browser-enforcement.ps1*' -or
            $_.CommandLine -like '*C:\OpenPath\scripts\Update-OpenPath.ps1*' -or
            $_.CommandLine -like '*C:\OpenPath\scripts\Start-SSEListener.ps1*' -or
            $_.CommandLine -like '*openpath-postgres*'
        )
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

$openPathTaskNames = @(
    'OpenPath-AgentUpdate',
    'OpenPath-SSE',
    'OpenPath-Startup',
    'OpenPath-Update',
    'OpenPath-Watchdog'
)

foreach ($taskName in $openPathTaskNames) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object {
        $_.TaskName -like 'OpenPath-*' -or
        $_.TaskName -like 'Whitelist-*' -or
        $_.TaskPath -like '*OpenPath*' -or
        $_.TaskPath -like '*Whitelist*'
    } |
    ForEach-Object {
        Stop-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }

Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Path -and $_.Path.StartsWith('C:\OpenPath', [System.StringComparison]::OrdinalIgnoreCase)) -or
        $_.ProcessName -like 'OpenPath*' -or
        $_.ProcessName -like 'Acrylic*'
    } |
    Stop-Process -Force -ErrorAction SilentlyContinue

$acrylicServiceName = 'AcrylicDNSProxySvc'
Stop-Service -Name $acrylicServiceName -Force -ErrorAction SilentlyContinue

$pathsToRemove = @(
    'C:\OpenPath'
)

foreach ($path in $pathsToRemove) {
    if ($path -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    if (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
        $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
        $changed = $false
        foreach ($collection in @($policyXml.AppLockerPolicy.RuleCollection)) {
            foreach ($rule in @($collection.ChildNodes)) {
                if ($rule.Name -like 'OpenPath non-admin app control*') {
                    [void]$collection.RemoveChild($rule)
                    $changed = $true
                }
            }
        }

        if ($changed -and (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) {
            $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-runner-reset-applocker-$([guid]::NewGuid()).xml"
            $policyXml.Save($policyPath)
            Set-AppLockerPolicy -XMLPolicy $policyPath
            Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Warning "Unable to remove OpenPath AppLocker rules during runner reset: $_"
}

$currentRepoRoot = $null
try {
    $currentRepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
}
catch {
    $currentRepoRoot = $null
}

Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'openpath-direct-overlay-*' -ErrorAction SilentlyContinue |
    Where-Object { -not $currentRepoRoot -or $_.FullName -ne $currentRepoRoot } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$firefoxDistributionPaths = @(
    "${env:ProgramFiles}\Mozilla Firefox\distribution",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution"
)

foreach ($distributionPath in $firefoxDistributionPaths) {
    if (-not $distributionPath) {
        continue
    }

    $firefoxRoot = Split-Path -Parent $distributionPath
    if (-not (Test-Path -LiteralPath $firefoxRoot)) {
        continue
    }

    New-Item -Path $distributionPath -ItemType Directory -Force | Out-Null
    Remove-Item -LiteralPath (Join-Path $distributionPath 'policies.json') -Force -ErrorAction SilentlyContinue
    & icacls $distributionPath /grant 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T | Out-Null
}

$dnsServers = @('1.1.1.1', '8.8.8.8')
$activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' }

foreach ($adapter in $activeAdapters) {
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dnsServers -ErrorAction SilentlyContinue
}

if (-not $activeAdapters) {
    Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses @('1.1.1.1', '8.8.8.8') -ErrorAction SilentlyContinue
}

Clear-DnsClientCache -ErrorAction SilentlyContinue

Write-Host 'Self-hosted Windows runner reset complete.'
