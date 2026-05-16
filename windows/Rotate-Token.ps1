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

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Rotates the machine's download token for whitelist access
.DESCRIPTION
    Requests a new download token from the central API and updates
    the local configuration with the new tokenized whitelist URL.
    Requires classroom mode to be configured during installation.
.PARAMETER Secret
    Legacy shared secret fallback for API authentication. Modern classroom
    installs rotate tokens using the machine token derived from whitelistUrl.
.EXAMPLE
    .\Rotate-Token.ps1
    .\Rotate-Token.ps1 -Secret "your-shared-secret"
#>

param(
    [string]$Secret = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot
$ConfigPath = "$OpenPathRoot\data\config.json"
$CommonModulePath = "$OpenPathRoot\lib\Common.psm1"
$BrowserModulePath = "$OpenPathRoot\lib\Browser.psm1"
$RotateCompatPath = "$OpenPathRoot\lib\internal\RotateToken.Compat.ps1"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  OpenPath - Token Rotation" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ConfigPath)) {
    Write-Host "ERROR: Configuration file not found" -ForegroundColor Red
    Write-Host "  Expected: $ConfigPath" -ForegroundColor Yellow
    Write-Host "  Run Install-OpenPath.ps1 first" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $CommonModulePath)) {
    Write-Host "ERROR: Common module not found" -ForegroundColor Red
    Write-Host "  Expected: $CommonModulePath" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $BrowserModulePath)) {
    Write-Host "ERROR: Browser module not found" -ForegroundColor Red
    Write-Host "  Expected: $BrowserModulePath" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $RotateCompatPath)) {
    Write-Host "ERROR: Rotation compatibility helper not found" -ForegroundColor Red
    Write-Host "  Expected: $RotateCompatPath" -ForegroundColor Yellow
    exit 1
}

Import-Module $CommonModulePath -Force
Import-Module $BrowserModulePath -Force
. $RotateCompatPath

$config = Get-OpenPathConfig

if (-not $config.apiUrl -or -not $config.classroom) {
    Write-Host "ERROR: Classroom mode not configured" -ForegroundColor Red
    Write-Host "  Only machines registered in a classroom can rotate their token" -ForegroundColor Yellow
    Write-Host "  Reinstall with -Classroom and -ApiUrl parameters" -ForegroundColor Yellow
    exit 1
}

$hostname = Get-OpenPathMachineName
$apiUrl = $config.apiUrl
$rotationAuth = Resolve-OpenPathRotationAuth -Config $config -SecretOverride $Secret
$authToken = $rotationAuth.Token

Write-Host "Rotating download token..." -ForegroundColor Yellow
Write-Host "  Hostname: $hostname"
Write-Host "  API: $apiUrl"
Write-Host ""

if (-not $authToken) {
    Write-Host "ERROR: No authentication token available" -ForegroundColor Red
    Write-Host "  Expected whitelistUrl with a machine token in config, or -Secret for legacy fallback" -ForegroundColor Yellow
    exit 1
}

Write-Host "  Authentication: $($rotationAuth.Source)"

try {
    $headers = @{
        "Authorization" = "Bearer $authToken"
        "Content-Type" = "application/json"
    }
    
    $response = Invoke-RestMethod -Uri "$apiUrl/api/machines/$hostname/rotate-download-token" `
        -Method Post -Headers $headers -ErrorAction Stop
    
    if ($response.success) {
        if ($response.whitelistUrl) {
            Set-OpenPathConfigValue -Config $config -Name 'whitelistUrl' -Value ([string]$response.whitelistUrl)
            Set-OpenPathConfig -Config $config | Out-Null

            try {
                Sync-OpenPathFirefoxNativeHostState -Config $config -ClearWhitelist | Out-Null
            }
            catch {
                throw "Failed to sync Firefox native host state after token rotation: $_"
            }
            
            Write-Host "Token rotated successfully" -ForegroundColor Green
            Write-Host "  New whitelist URL saved to config" -ForegroundColor Green
        }
        else {
            Write-Host "ERROR: Rotation successful but no new URL received" -ForegroundColor Red
            exit 1
        }
    }
    else {
        Write-Host "ERROR: Token rotation failed" -ForegroundColor Red
        Write-Host "  Response: $($response | ConvertTo-Json -Compress)" -ForegroundColor Yellow
        exit 1
    }
}
catch {
    Write-Host "ERROR: Failed to rotate token" -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Token rotation complete" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
