# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# PSScriptAnalyzer suppressions:
# - Write-Host is intentional for interactive uninstaller
# - BOM not required for UTF-8 (files are already UTF-8 without BOM)
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstalls the OpenPath DNS system for Windows
.DESCRIPTION
    Removes firewall rules, scheduled tasks, browser policies, 
    and restores original DNS settings.
.PARAMETER KeepAcrylic
    Keep Acrylic DNS Proxy installed
.PARAMETER KeepLogs
    Keep log files
#>

param(
    [switch]$KeepAcrylic,
    [switch]$KeepLogs
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

function Convert-ToRegistryProviderPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    if ($RegistryPath -match '^HKLM\\') {
        return "Registry::HKEY_LOCAL_MACHINE\\$($RegistryPath.Substring(5))"
    }

    throw "Unsupported registry hive path: $RegistryPath"
}

function Remove-RegistryKeyIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    $providerPath = Convert-ToRegistryProviderPath -RegistryPath $RegistryPath
    if (Test-Path $providerPath) {
        Remove-Item -Path $providerPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-OpenPathScheduledTask {
    $tasks = Get-ScheduledTask -TaskName "OpenPath-*" -ErrorAction SilentlyContinue

    foreach ($task in $tasks) {
        Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Stop-OpenPathRootedProcess {
    $processIds = @()

    $processIds += Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Id -ne $PID -and
            $_.Path -and
            $_.Path.StartsWith($OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -ExpandProperty Id

    $processIds += Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like "*$OpenPathRoot*"
        } |
        Select-Object -ExpandProperty ProcessId

    $processIds |
        Where-Object { $_ } |
        Select-Object -Unique |
        ForEach-Object {
            Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        }
}

function Remove-OpenPathFallbackAppLockerRules {
    if (-not (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { return }

    $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
    $removed = $false
    foreach ($collection in @($policyXml.AppLockerPolicy.RuleCollection)) {
        foreach ($rule in @($collection.ChildNodes)) {
            if ($null -ne $rule -and
                $rule -is [System.Xml.XmlElement] -and
                $rule.GetAttribute('Name') -like 'OpenPath non-admin app control*') {
                [void]$collection.RemoveChild($rule)
                $removed = $true
            }
        }
    }
    if (-not $removed) { return }

    $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-uninstall-applocker-$([guid]::NewGuid()).xml"
    try {
        $policyXml.Save($policyPath)
        Set-AppLockerPolicy -XMLPolicy $policyPath -ErrorAction Stop
    }
    finally {
        Remove-Item $policyPath -Force -ErrorAction SilentlyContinue
    }
}

function Restore-OpenPathOriginalDns {
    $snapshotPath = Join-Path $OpenPathRoot 'data\original-dns.json'
    if ((Test-Path $snapshotPath) -and (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) {
        try {
            $snapshot = @(Get-Content $snapshotPath -Raw | ConvertFrom-Json)
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
            foreach ($entry in $snapshot) {
                $adapter = @($adapters | Where-Object { [string]$_.InterfaceGuid -eq [string]$entry.InterfaceGuid } | Select-Object -First 1)
                if (-not $adapter -and $entry.InterfaceIndex -ne $null) {
                    $adapter = @($adapters | Where-Object { $_.ifIndex -eq [int]$entry.InterfaceIndex } | Select-Object -First 1)
                }
                if (-not $adapter -and $entry.InterfaceAlias) {
                    $adapter = @($adapters | Where-Object { $_.Name -eq [string]$entry.InterfaceAlias } | Select-Object -First 1)
                }
                if (-not $adapter) { continue }

                $servers = @($entry.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($servers.Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $servers -ErrorAction SilentlyContinue
                }
                else {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                }
            }
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            return
        }
        catch {
            Write-Host "  Snapshot DNS restore failed: $_" -ForegroundColor Yellow
        }
    }

    Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Remove-OpenPathFirewallRules {
    $manifestPath = Join-Path $OpenPathRoot 'data\firewall-rules.json'
    if (Test-Path $manifestPath) {
        @(Get-Content $manifestPath -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ }) |
            Where-Object { $_ } |
            ForEach-Object {
                Get-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue |
                    Remove-NetFirewallRule -ErrorAction SilentlyContinue
            }
    }

    Get-NetFirewallRule -Group 'OpenPath' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName "OpenPath-DNS-*" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

function Remove-OpenPathInstallRoot {
    param(
        [switch]$KeepLogs
    )

    if (-not (Test-Path $OpenPathRoot)) {
        return
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            if ($KeepLogs) {
                Get-ChildItem $OpenPathRoot -Exclude "data" -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction Stop

                $dataPath = Join-Path $OpenPathRoot "data"
                if (Test-Path $dataPath) {
                    Get-ChildItem $dataPath -Exclude "logs" -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction Stop
                }

                return
            }

            Remove-Item $OpenPathRoot -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path $OpenPathRoot)) {
                return
            }
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }
        }

        Stop-OpenPathRootedProcess
        Start-Sleep -Milliseconds (300 * $attempt)
    }

    if (Test-Path $OpenPathRoot) {
        throw "OpenPath install root still exists after cleanup: $OpenPathRoot"
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  OpenPath DNS for Windows - Uninstaller" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Import modules if available
if (Test-Path "$OpenPathRoot\lib\Common.psm1") {
    Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\DNS.psm1") {
    Import-Module "$OpenPathRoot\lib\DNS.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Firewall.psm1") {
    Import-Module "$OpenPathRoot\lib\Firewall.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\AppControl.psm1") {
    Import-Module "$OpenPathRoot\lib\AppControl.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Browser.psm1") {
    Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Services.psm1") {
    Import-Module "$OpenPathRoot\lib\Services.psm1" -Force -ErrorAction SilentlyContinue
}

# Step 1: Remove scheduled tasks
Write-Host "[1/6] Removing scheduled tasks..." -ForegroundColor Yellow
Stop-OpenPathScheduledTask
Write-Host "  Scheduled tasks removed" -ForegroundColor Green

# Step 2: Restore DNS
Write-Host "[2/6] Restoring DNS configuration..." -ForegroundColor Yellow
Restore-OpenPathOriginalDns
Write-Host "  DNS restored" -ForegroundColor Green

# Step 3: Remove firewall rules
Write-Host "[3/6] Removing firewall rules..." -ForegroundColor Yellow
Remove-OpenPathFirewallRules
Write-Host "  Firewall rules removed" -ForegroundColor Green

if (Get-Command -Name Remove-OpenPathNonAdminAppControl -ErrorAction SilentlyContinue) {
    Remove-OpenPathNonAdminAppControl | Out-Null
}
else {
    Remove-OpenPathFallbackAppLockerRules
}

# Step 4: Remove browser policies
Write-Host "[4/6] Removing browser policies..." -ForegroundColor Yellow

# Firefox
$firefoxPolicies = @(
    "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json"
)
foreach ($path in $firefoxPolicies) {
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

$firefoxNativeHostRegistryPaths = @(
    'HKLM\SOFTWARE\Mozilla\NativeMessagingHosts\whitelist_native_host',
    'HKLM\SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host'
)
foreach ($registryPath in $firefoxNativeHostRegistryPaths) {
    Remove-RegistryKeyIfPresent -RegistryPath $registryPath
}

$firefoxNativeHostArtifacts = @(
    "$OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.cmd",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.State.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Protocol.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Actions.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\whitelist_native_host.json",
    "$OpenPathRoot\browser-extension\firefox\native\native-state.json",
    "$OpenPathRoot\browser-extension\firefox\native\whitelist.txt"
)
foreach ($artifactPath in $firefoxNativeHostArtifacts) {
    if (Test-Path $artifactPath) {
        Remove-Item $artifactPath -Force -ErrorAction SilentlyContinue
    }
}

# Chrome/Edge registry
$regPaths = @(
    "HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist",
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist",
    "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist",
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
)
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "  Browser policies removed" -ForegroundColor Green

# Step 5: Stop and optionally remove Acrylic
Write-Host "[5/6] Stopping Acrylic DNS..." -ForegroundColor Yellow
$acrylicService = Get-Service -DisplayName "*Acrylic*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($acrylicService) {
    Stop-Service -Name $acrylicService.Name -Force -ErrorAction SilentlyContinue
    
    if (-not $KeepAcrylic) {
        # Uninstall Acrylic service
        $acrylicPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
        if (Test-Path "$acrylicPath\AcrylicService.exe") {
            & "$acrylicPath\AcrylicService.exe" /UNINSTALL 2>$null
        }
        $remainingAcrylicService = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
        if ($remainingAcrylicService) {
            & sc.exe delete AcrylicDNSProxySvc 2>$null | Out-Null
        }
        Write-Host "  Acrylic stopped and uninstalled" -ForegroundColor Green
    }
    else {
        Write-Host "  Acrylic stopped (kept installed)" -ForegroundColor Green
    }
}
else {
    Write-Host "  Acrylic not found" -ForegroundColor Yellow
}

# Step 6: Remove whitelist files
Write-Host "[6/6] Removing files..." -ForegroundColor Yellow
if (Test-Path $OpenPathRoot) {
    Stop-OpenPathRootedProcess

    if ($KeepLogs) {
        Remove-OpenPathInstallRoot -KeepLogs
        Write-Host "  Files removed (logs preserved)" -ForegroundColor Green
    }
    else {
        Remove-OpenPathInstallRoot
        Write-Host "  Files removed" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  UNINSTALL COMPLETED" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "The system has been restored to its original state."
Write-Host "A restart may be required to apply all changes."
Write-Host ""
