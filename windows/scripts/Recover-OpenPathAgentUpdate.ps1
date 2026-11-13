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
    Recovers the Windows agent from an interrupted self-update.
.DESCRIPTION
    Runs before every scheduled task and before the operator CLI loads the
    agent. It reads data\agent-update\update-journal.json using only built-in
    cmdlets, so a tree whose modules no longer load can still be repaired.
    Without a journal it exits immediately. A live updater holds the update
    lock; in that case this script leaves the update alone. A journal in the
    committed phase is deleted. Any other phase is rolled back from the
    per-update backups: files that existed before are restored and files that
    were new are removed. The journal is deleted only after every restored file
    matches its backup. A pending health report is left for the watchdog.
#>

[CmdletBinding()]
param(
    [string]$OpenPathRoot = ''
)

$ErrorActionPreference = 'Stop'
$script:UpdateRoot = ''
$script:JournalPath = ''
$script:ReportPath = ''
$script:LogPath = ''

function Resolve-OpenPathRecoveryRoot {
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

function Write-OpenPathRecoveryLog {
    param([string]$Message)

    try {
        $logDirectory = Join-Path (Join-Path $script:OpenPathRoot 'data') 'logs'
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        $timestamp = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Add-Content -LiteralPath $script:LogPath -Value ("[{0}] Self-update recovery: {1}" -f $timestamp, $Message) -Encoding UTF8
    }
    catch {
        # Logging must never block recovery.
    }
}

function ConvertTo-OpenPathRecoveryNativePath {
    param([string]$RelativePath)

    return (($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar) -replace '\\', [System.IO.Path]::DirectorySeparatorChar)
}

function Test-OpenPathRecoveryRelativePath {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $false
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        return $false
    }
    if ($RelativePath.Contains('..')) {
        return $false
    }

    return $true
}

function ConvertTo-OpenPathRecoveryReasonCode {
    param(
        [string]$Prefix,
        [string]$Version,
        [string]$Build
    )

    $candidate = ("{0}_{1}_{2}" -f $Prefix, $Version, $Build)
    $candidate = ($candidate -replace '[^a-zA-Z0-9_]+', '_').ToLowerInvariant()
    while ($candidate.Contains('__')) {
        $candidate = $candidate.Replace('__', '_')
    }
    $candidate = $candidate.Trim('_')
    if ($candidate.Length -gt 64) {
        $candidate = $candidate.Substring(0, 64).TrimEnd('_')
    }
    if ($candidate -notmatch '^[a-z][a-z0-9_]{2,63}$') {
        $candidate = 'self_update_recovery_failed'
    }

    return $candidate
}

function Write-OpenPathRecoveryReport {
    param(
        [string]$Status,
        [string]$ReasonCode,
        [string]$Actions,
        [string]$Version,
        [string]$Build,
        [string]$Message
    )

    try {
        $report = [PSCustomObject]@{
            schemaVersion = 1
            status        = $Status
            reasonCode    = $ReasonCode
            actions       = $Actions
            version       = $Version
            build         = $Build
            message       = $Message
            recordedAt    = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        $temporaryPath = "$($script:ReportPath).$([guid]::NewGuid().ToString('N')).tmp"
        $json = $report | ConvertTo-Json -Depth 5
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $script:ReportPath -Force
    }
    catch {
        Write-OpenPathRecoveryLog "Could not write recovery report: $_"
    }
}

function Restore-OpenPathRecoveryJournal {
    param([Parameter(Mandatory = $true)]$Journal)

    $backupRoot = [string]$Journal.backupRoot
    $allowedBackupRoot = [System.IO.Path]::GetFullPath((Join-Path $script:UpdateRoot 'backups'))
    $complete = $true

    if ([string]::IsNullOrWhiteSpace($backupRoot)) {
        Write-OpenPathRecoveryLog 'Journal has no backup root; cannot roll back'
        return $false
    }

    $resolvedBackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
    if (-not $resolvedBackupRoot.StartsWith($allowedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-OpenPathRecoveryLog "Journal backup root is outside the update backup directory: $backupRoot"
        return $false
    }

    foreach ($entry in @($Journal.files)) {
        $relativePath = [string]$entry.relativePath
        if (-not (Test-OpenPathRecoveryRelativePath -RelativePath $relativePath)) {
            Write-OpenPathRecoveryLog "Journal contains an unsafe relative path: $relativePath"
            $complete = $false
            continue
        }

        $nativePath = ConvertTo-OpenPathRecoveryNativePath -RelativePath $relativePath
        $destinationPath = Join-Path $script:OpenPathRoot $nativePath
        $backupPath = Join-Path $resolvedBackupRoot $nativePath
        $existedBefore = [bool]$entry.existedBefore

        try {
            if ($existedBefore) {
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    $destinationDirectory = Split-Path $destinationPath -Parent
                    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $backupPath -Destination $destinationPath -Force -ErrorAction Stop

                    $restoredHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($restoredHash -ne $backupHash) {
                        Write-OpenPathRecoveryLog "Restored file does not match its backup: $relativePath"
                        $complete = $false
                    }
                }
                elseif (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                    Write-OpenPathRecoveryLog "File was present before the update but is missing and has no backup: $relativePath"
                    $complete = $false
                }
            }
            else {
                if (Test-Path -LiteralPath $destinationPath) {
                    Remove-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
                }
                if (Test-Path -LiteralPath $destinationPath) {
                    Write-OpenPathRecoveryLog "Could not remove file added by the interrupted update: $relativePath"
                    $complete = $false
                }
            }
        }
        catch {
            Write-OpenPathRecoveryLog "Rollback failed for ${relativePath}: $_"
            $complete = $false
        }
    }

    return $complete
}

$script:OpenPathRoot = Resolve-OpenPathRecoveryRoot -ExplicitRoot $OpenPathRoot
$script:UpdateRoot = Join-Path (Join-Path $script:OpenPathRoot 'data') 'agent-update'
$script:JournalPath = Join-Path $script:UpdateRoot 'update-journal.json'
$script:ReportPath = Join-Path $script:UpdateRoot 'recovery-report.json'
$script:LogPath = Join-Path (Join-Path (Join-Path $script:OpenPathRoot 'data') 'logs') 'openpath.log'

if (-not (Test-Path -LiteralPath $script:JournalPath -PathType Leaf)) {
    return
}

$lock = $null
try {
    $lock = [System.Threading.Mutex]::new($false, 'Global\OpenPathAgentUpdateLock')
    $acquired = $false
    try {
        $acquired = $lock.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }

    if (-not $acquired) {
        return
    }

    $journal = $null
    try {
        $journal = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-OpenPathRecoveryLog "Ignoring unreadable journal: $_"
        return
    }

    $schemaVersion = 0
    [void][int]::TryParse([string]$journal.schemaVersion, [ref]$schemaVersion)
    if ($schemaVersion -ne 1) {
        Write-OpenPathRecoveryLog "Ignoring journal with unsupported schemaVersion '$($journal.schemaVersion)'"
        return
    }

    $phase = [string]$journal.phase
    if ($phase -eq 'committed') {
        Remove-Item -LiteralPath $script:JournalPath -Force -ErrorAction Stop
        return
    }

    $targetVersion = [string]$journal.targetVersion
    $targetBuild = [string]$journal.targetBuild
    $rollbackComplete = Restore-OpenPathRecoveryJournal -Journal $journal

    if ($rollbackComplete) {
        Remove-Item -LiteralPath $script:JournalPath -Force -ErrorAction Stop
        $reasonCode = ConvertTo-OpenPathRecoveryReasonCode -Prefix 'self_update_recovery_rolled_back' -Version $targetVersion -Build $targetBuild
        Write-OpenPathRecoveryReport `
            -Status 'DEGRADED' `
            -ReasonCode $reasonCode `
            -Actions 'self_update_recovery_rolled_back' `
            -Version $targetVersion `
            -Build $targetBuild `
            -Message ("Interrupted update to {0} build {1} was rolled back" -f $targetVersion, $targetBuild)
        Write-OpenPathRecoveryLog "Rolled back interrupted update to $targetVersion build $targetBuild"
        return
    }

    $failedReasonCode = ConvertTo-OpenPathRecoveryReasonCode -Prefix 'self_update_recovery_failed' -Version $targetVersion -Build $targetBuild
    Write-OpenPathRecoveryReport `
        -Status 'DEGRADED' `
        -ReasonCode $failedReasonCode `
        -Actions 'self_update_recovery_failed' `
        -Version $targetVersion `
        -Build $targetBuild `
        -Message 'Interrupted update rollback did not complete'
    Write-OpenPathRecoveryLog 'Interrupted update rollback did not complete; keeping the journal for the next attempt'
    throw 'OpenPath agent update recovery did not complete'
}
catch {
    Write-OpenPathRecoveryLog "Recovery failed: $_"
    throw 'OpenPath agent update recovery did not complete'
}
finally {
    if ($lock) {
        try {
            $lock.ReleaseMutex()
        }
        catch [System.ApplicationException] {
            # The mutex was not owned by this process.
        }
        $lock.Dispose()
    }
}
