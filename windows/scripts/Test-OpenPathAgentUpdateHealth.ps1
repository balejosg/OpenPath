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

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Loads the installed Windows agent and verifies its commands are available.
.DESCRIPTION
    Self-update runs this script in a fresh Windows PowerShell process after the
    staged files are in place and before it commits the new version. It imports
    the same module set as the scheduled tasks and the operator CLI, then checks
    a fixed list of commands. It performs no network, firewall, DNS, registry or
    task changes. Exit code 0 means the tree loads; any other code fails the
    update and triggers a rollback.
#>

[CmdletBinding()]
param(
    [string]$OpenPathRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Resolve-OpenPathHealthGateRoot {
    param([string]$ExplicitRoot)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        return $ExplicitRoot.TrimEnd('\').TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENPATH_WINDOWS_ROOT)) {
        return ([string]$env:OPENPATH_WINDOWS_ROOT).TrimEnd('\').TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENPATH_ROOT)) {
        return ([string]$env:OPENPATH_ROOT).TrimEnd('\').TrimEnd('/')
    }

    return (Split-Path $PSScriptRoot -Parent)
}

$root = Resolve-OpenPathHealthGateRoot -ExplicitRoot $OpenPathRoot
$requiredCommands = @(
    'Write-OpenPathLog',
    'Get-OpenPathConfig',
    'Get-OpenPathRuntimeHealth',
    'Send-OpenPathHealthReport',
    'Invoke-OpenPathAgentSelfUpdate',
    'Get-OpenPathCriticalFiles',
    'Test-OpenPathIntegrity',
    'Restore-OpenPathIntegrity',
    'Get-AcrylicPath',
    'Test-DNSResolution',
    'Set-LocalDNS',
    'Restart-AcrylicService',
    'Get-OpenPathBridgeFilterCatalog',
    'Get-OpenPathTaskStatus',
    'Get-OpenPathBrowserDoctorReport',
    'Test-OpenPathCaptivePortalModeActive',
    'Test-OpenPathNonAdminAppControlActive',
    'Set-OpenPathFirewall',
    'Test-FirewallActive',
    'Invoke-OpenPathUpdateCycle',
    'Invoke-OpenPathWatchdogChecks',
    'Get-OpenPathOpenClassroomPosture',
    'Merge-OpenPathReasonCodes',
    'Invoke-OpenPathOpenClassroomPostureRepair',
    'Test-OpenPathAdapterDnsPinnedToLocalResolver'
)

try {
    if (-not (Test-Path -LiteralPath (Join-Path $root 'lib/Common.psm1') -PathType Leaf)) {
        throw "Agent root does not contain lib/Common.psm1: $root"
    }

    $moduleOrder = @(
        'DNS',
        'Network',
        'Services',
        'Browser',
        'CaptivePortal',
        'AppControl',
        'Firewall',
        'Common',
        'Update.Runtime'
    )
    foreach ($moduleName in $moduleOrder) {
        $modulePath = Join-Path $root ("lib/{0}.psm1" -f $moduleName)
        Import-Module $modulePath -Force -Global -ErrorAction Stop
    }

    $watchdogRuntimePath = Join-Path $root 'lib/internal/Watchdog.Runtime.ps1'
    if (-not (Test-Path -LiteralPath $watchdogRuntimePath -PathType Leaf)) {
        throw "Agent root does not contain lib/internal/Watchdog.Runtime.ps1: $root"
    }
    . $watchdogRuntimePath

    $missingCommands = @(
        $requiredCommands | Where-Object {
            -not (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }
    )
    if ($missingCommands.Count -gt 0) {
        throw "Agent tree is missing required commands: $($missingCommands -join ', ')"
    }

    Write-Output 'healthy'
    exit 0
}
catch {
    [Console]::Error.WriteLine("OpenPath agent update health gate failed: $_")
    exit 1
}
