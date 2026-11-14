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
    Without a journal, a preserved journal or an unfinished run intent it exits
    immediately. A live updater holds the update lock; in that case this script
    leaves the update alone.

    A valid journal is authoritative. A committed journal, or a journal with a
    committed.marker for the same run, is left for the updater because
    finalization needs the modules. Any other valid phase is rolled back from
    this run's backups: files already at the recorded pre-update hash are left
    alone, other files are restored only when the backup matches that hash, and
    files that were new are removed. Every restore is a flushed temp sibling
    followed by a rename, so a second power cut cannot zero an installed file.

    When the journal is missing or unusable, the newest valid
    backups\run-*\journal-intent.json is used instead. With a marker it is
    promoted to a committed journal; without one it is rolled back, and a run
    that had not replaced anything is cleaned up without a DEGRADED report.
    When nothing local is valid the script quarantines the unusable bytes,
    writes a blocked recovery-state.json and does not let the watchdog integrity
    restore resume. The updater repairs a blocked tree by converging on the
    published manifest. A pending health report is left for the watchdog.

    A blocked state returns without hashing anything. A retrying state returns
    for ten minutes after its last attempt. Three incomplete rollbacks also set
    blocked. A swap or restore retries only a Windows sharing or lock violation
    for a few seconds; a definitive failure logs the relative path, exception
    type and HResult and records them in recovery-state.json.
#>

[CmdletBinding()]
param(
    [string]$OpenPathRoot = ''
)

$ErrorActionPreference = 'Stop'
$script:UpdateRoot = ''
$script:JournalPath = ''
$script:SupersededJournalPath = ''
$script:RecoveryStatePath = ''
$script:ReportPath = ''
$script:LogPath = ''
$script:BackupsRoot = ''

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
        $line = "[{0}] Self-update recovery: {1}{2}" -f $timestamp, $Message, [Environment]::NewLine
        $encoding = [System.Text.UTF8Encoding]::new($false)
        $bytes = $encoding.GetBytes($line)
        $stream = [System.IO.File]::Open(
            $script:LogPath,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
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

function Write-OpenPathRecoveryJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Object
    )

    $directory = Split-Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 10
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($json)
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    $stream = $null
    try {
        $stream = [System.IO.File]::Create($temporaryPath)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($stream) {
            $stream.Dispose()
            $stream = $null
        }
    }
    try {
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            try { [System.IO.File]::Delete($temporaryPath) } catch {}
        }
        if ([System.IO.File]::Exists($backupPath)) {
            try { [System.IO.File]::Delete($backupPath) } catch {}
        }
    }
}

function Copy-OpenPathRecoveryFileDurable {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [int]$BufferSize = 1048576
    )

    if ($BufferSize -lt 1) {
        $BufferSize = 1048576
    }

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if ($destinationDirectory -and -not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [System.IO.File]::OpenRead($SourcePath)
        $outputStream = [System.IO.File]::Create($DestinationPath)
        $buffer = New-Object byte[] $BufferSize
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            $outputStream.Write($buffer, 0, $read)
        }
        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        $outputStream.Flush($true)
        $hashBytes = $sha.Hash
    }
    finally {
        if ($outputStream) {
            $outputStream.Dispose()
            $outputStream = $null
        }
        if ($inputStream) {
            $inputStream.Dispose()
            $inputStream = $null
        }
        $sha.Dispose()
    }

    return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-OpenPathRecoveryFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $buffer = New-Object byte[] 1048576
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        $hashBytes = $sha.Hash
    }
    finally {
        if ($stream) {
            $stream.Dispose()
            $stream = $null
        }
        $sha.Dispose()
    }

    return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-OpenPathRecoverySharingViolation {
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($exception) {
        if ($exception -is [System.IO.IOException]) {
            $hresult = [long]$exception.HResult -band 0xFFFFFFFFL
            if ($hresult -eq 0x80070020L -or $hresult -eq 0x80070021L) {
                return $true
            }
        }
        $exception = $exception.InnerException
    }

    return $false
}

function Get-OpenPathRecoveryExceptionDetail {
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($exception -and $exception.InnerException -and
        ($exception -is [System.Management.Automation.MethodInvocationException] -or
         $exception -is [System.Reflection.TargetInvocationException])) {
        $exception = $exception.InnerException
    }

    if (-not $exception) {
        return [PSCustomObject]@{
            ExceptionType = ''
            HResult       = '0x00000000'
            Message       = [string]$ErrorRecord
        }
    }

    $hresult = [long]$exception.HResult -band 0xFFFFFFFFL
    return [PSCustomObject]@{
        ExceptionType = $exception.GetType().FullName
        HResult       = ('0x{0:X8}' -f $hresult)
        Message       = [string]$exception.Message
    }
}

function Invoke-OpenPathRecoveryFileOperationWithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [int]$MaxAttempts = 5,
        [int]$DelayMilliseconds = 1000
    )

    if ($MaxAttempts -lt 1) {
        $MaxAttempts = 1
    }
    if ($DelayMilliseconds -lt 0) {
        $DelayMilliseconds = 0
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Operation)
        }
        catch {
            $errorRecord = $_
            if ($attempt -ge $MaxAttempts -or -not (Test-OpenPathRecoverySharingViolation -ErrorRecord $errorRecord)) {
                throw
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function Invoke-OpenPathRecoveryFileReplace {
    param(
        [Parameter(Mandatory = $true)][string]$TempPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    [System.IO.File]::Replace($TempPath, $DestinationPath, $BackupPath, $true)
}

function Move-OpenPathRecoveryFileDurable {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Invoke-OpenPathRecoveryFileOperationWithRetry -Operation {
        [System.IO.File]::Move($SourcePath, $DestinationPath)
    }
}

function Move-OpenPathRecoveryFileIntoPlace {
    param(
        [Parameter(Mandatory = $true)][string]$TempPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $backupPath = "$TempPath.bak"
    try {
        if ([System.IO.File]::Exists($DestinationPath)) {
            Invoke-OpenPathRecoveryFileOperationWithRetry -Operation {
                Invoke-OpenPathRecoveryFileReplace `
                    -TempPath $TempPath `
                    -DestinationPath $DestinationPath `
                    -BackupPath $backupPath
            }
        }
        else {
            Move-OpenPathRecoveryFileDurable -SourcePath $TempPath -DestinationPath $DestinationPath
        }
    }
    finally {
        if ([System.IO.File]::Exists($TempPath)) {
            try { [System.IO.File]::Delete($TempPath) } catch {}
        }
        if ([System.IO.File]::Exists($backupPath)) {
            try { [System.IO.File]::Delete($backupPath) } catch {}
        }
    }
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
        Write-OpenPathRecoveryJsonFile -Path $script:ReportPath -Object $report
    }
    catch {
        Write-OpenPathRecoveryLog "Could not write recovery report: $_"
    }
}

function ConvertTo-OpenPathRecoveryDateTimeOffset {
    param([object]$Value)

    if ($Value -is [DateTimeOffset]) {
        return [DateTimeOffset]$Value
    }
    if ($Value -is [DateTime]) {
        return [DateTimeOffset]$Value
    }

    $parsed = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
    if ($ok) {
        return $parsed
    }

    return [DateTimeOffset]::MinValue
}

function Get-OpenPathRecoveryRunId {
    param([AllowNull()][object]$Record)

    if (-not $Record) {
        return ''
    }
    if ($Record.PSObject.Properties['runId'] -and -not [string]::IsNullOrWhiteSpace([string]$Record.runId)) {
        return [string]$Record.runId
    }
    $backupRoot = [string]$Record.backupRoot
    if (-not [string]::IsNullOrWhiteSpace($backupRoot)) {
        return (Split-Path -Path $backupRoot.TrimEnd([char[]]@('\', '/')) -Leaf)
    }

    return ''
}

function Test-OpenPathRecoveryJournalRecord {
    param([AllowNull()][object]$Record)

    $result = [PSCustomObject]@{
        Valid      = $false
        ReasonCode = 'self_update_recovery_journal_unreadable'
        Detail     = 'The update journal could not be parsed'
    }

    if (-not $Record) {
        return $result
    }

    $schemaVersion = 0
    [void][int]::TryParse([string]$Record.schemaVersion, [ref]$schemaVersion)
    if ($schemaVersion -ne 2) {
        $result.ReasonCode = 'self_update_recovery_journal_schema_unsupported'
        $result.Detail = ("The update journal has unsupported schemaVersion '{0}'" -f $Record.schemaVersion)
        return $result
    }

    $phase = [string]$Record.phase
    if ($phase -notin @('replacing', 'validating', 'committed')) {
        $result.ReasonCode = 'self_update_recovery_journal_unreadable'
        $result.Detail = ("The update journal has an unknown phase '{0}'" -f $phase)
        return $result
    }

    $backupRoot = [string]$Record.backupRoot
    if ([string]::IsNullOrWhiteSpace($backupRoot)) {
        $result.Detail = 'The update journal has no backup root'
        return $result
    }

    $allowedBackupRoot = [System.IO.Path]::GetFullPath($script:BackupsRoot)
    $allowedBackupPrefix = $allowedBackupRoot.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    try {
        $resolvedBackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
    }
    catch {
        $result.Detail = "The update journal backup root is not a valid path: $backupRoot"
        return $result
    }
    if (-not $resolvedBackupRoot.StartsWith($allowedBackupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.Detail = "The update journal backup root is outside the update backup directory: $backupRoot"
        return $result
    }

    $entries = @($Record.files)
    foreach ($entry in $entries) {
        if (-not $entry) {
            $result.Detail = 'The update journal has an empty file entry'
            return $result
        }
        $relativePath = [string]$entry.relativePath
        if (-not (Test-OpenPathRecoveryRelativePath -RelativePath $relativePath)) {
            $result.Detail = "The update journal contains an unsafe relative path: $relativePath"
            return $result
        }
        if (-not $entry.PSObject.Properties['existedBefore'] -or $entry.existedBefore -isnot [bool]) {
            $result.Detail = "The update journal entry has no boolean existedBefore: $relativePath"
            return $result
        }
        if ([string]$entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            $result.Detail = "The update journal entry has no valid target hash: $relativePath"
            return $result
        }
        if ([bool]$entry.existedBefore) {
            if ([string]$entry.previousSha256 -notmatch '^[0-9a-fA-F]{64}$') {
                $result.Detail = "The update journal entry has no valid pre-update hash: $relativePath"
                return $result
            }
        }
    }

    $result.Valid = $true
    $result.ReasonCode = ''
    $result.Detail = ''
    return $result
}

function Read-OpenPathRecoveryJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-OpenPathRecoveryState {
    if (-not (Test-Path -LiteralPath $script:RecoveryStatePath -PathType Leaf)) {
        return [PSCustomObject]@{ Present = $false; Unreadable = $false; State = $null }
    }

    $state = Read-OpenPathRecoveryJsonFile -Path $script:RecoveryStatePath
    if (-not $state) {
        return [PSCustomObject]@{ Present = $true; Unreadable = $true; State = $null }
    }

    $schemaVersion = 0
    [void][int]::TryParse([string]$state.schemaVersion, [ref]$schemaVersion)
    if ($schemaVersion -ne 1 -or [string]$state.state -notin @('retrying', 'blocked')) {
        return [PSCustomObject]@{ Present = $true; Unreadable = $true; State = $null }
    }

    return [PSCustomObject]@{ Present = $true; Unreadable = $false; State = $state }
}

function Write-OpenPathRecoveryState {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [int]$Attempts = 1,
        [string]$FirstSeenAt = '',
        [string]$RunId = '',
        [int]$RepairAttempts = 0,
        [string]$LastRepairAt = '',
        [string]$FailedPath = '',
        [string]$FailedExceptionType = '',
        [string]$FailedHResult = '',
        [string]$FailedMessage = ''
    )

    $now = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    if ([string]::IsNullOrWhiteSpace($FirstSeenAt)) {
        $FirstSeenAt = $now
    }
    $stateRecord = [PSCustomObject]@{
        schemaVersion       = 1
        state               = $State
        reasonCode          = $ReasonCode
        attempts            = [int]$Attempts
        firstSeenAt         = $FirstSeenAt
        lastAttemptAt       = $now
        repairAttempts      = [int]$RepairAttempts
        lastRepairAt        = $LastRepairAt
        runId               = $RunId
        lastFailedPath          = $FailedPath
        lastFailedExceptionType = $FailedExceptionType
        lastFailedHResult       = $FailedHResult
        lastFailedMessage       = $FailedMessage
    }
    Write-OpenPathRecoveryJsonFile -Path $script:RecoveryStatePath -Object $stateRecord
    return $stateRecord
}

function Remove-OpenPathRecoveryState {
    if (Test-Path -LiteralPath $script:RecoveryStatePath -PathType Leaf) {
        Remove-Item -LiteralPath $script:RecoveryStatePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathRecoveryRunIntents {
    if (-not (Test-Path -LiteralPath $script:BackupsRoot)) {
        return @()
    }

    $intents = New-Object System.Collections.ArrayList
    foreach ($directory in @(Get-ChildItem -LiteralPath $script:BackupsRoot -Directory -Filter 'run-*' -ErrorAction SilentlyContinue)) {
        $intentPath = Join-Path $directory.FullName 'journal-intent.json'
        $record = Read-OpenPathRecoveryJsonFile -Path $intentPath
        $validation = Test-OpenPathRecoveryJournalRecord -Record $record
        if (-not $validation.Valid) {
            continue
        }
        $runId = Get-OpenPathRecoveryRunId -Record $record
        if ([string]::IsNullOrWhiteSpace($runId)) {
            $runId = $directory.Name
        }
        [void]$intents.Add([PSCustomObject]@{
            Record     = $record
            RunId      = $runId
            BackupRoot = $directory.FullName
            IntentPath = $intentPath
            CreatedAt  = ConvertTo-OpenPathRecoveryDateTimeOffset -Value $record.createdAt
        })
    }

    return @($intents.ToArray())
}

function Test-OpenPathRecoveryMarker {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        return $false
    }
    $markerPath = Join-Path $BackupRoot 'committed.marker'
    $marker = Read-OpenPathRecoveryJsonFile -Path $markerPath
    if (-not $marker) {
        return $false
    }
    $schemaVersion = 0
    [void][int]::TryParse([string]$marker.schemaVersion, [ref]$schemaVersion)
    if ($schemaVersion -ne 1) {
        return $false
    }

    return [string]::Equals([string]$marker.runId, $RunId, [System.StringComparison]::OrdinalIgnoreCase)
}

function Restore-OpenPathRecoveryJournal {
    # This rule must stay identical to Restore-OpenPathAgentUpdateJournalBackups
    # in Common.Update.ps1. The script cannot import that module, so the two
    # implementations are pinned together by the parity tests.
    param([Parameter(Mandatory = $true)]$Journal)

    $backupRoot = [string]$Journal.backupRoot
    $allowedBackupRoot = [System.IO.Path]::GetFullPath($script:BackupsRoot)
    $allowedBackupPrefix = $allowedBackupRoot.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $complete = $true
    $changed = 0
    $failures = @()

    if ([string]::IsNullOrWhiteSpace($backupRoot)) {
        Write-OpenPathRecoveryLog 'Journal has no backup root; cannot roll back'
        return [PSCustomObject]@{ Complete = $false; Errors = @('Journal has no backup root'); Changed = 0; Failures = @() }
    }

    try {
        $resolvedBackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
    }
    catch {
        Write-OpenPathRecoveryLog "Journal backup root is not a valid path: $backupRoot"
        return [PSCustomObject]@{ Complete = $false; Errors = @('Invalid backup root'); Changed = 0; Failures = @() }
    }

    if (-not $resolvedBackupRoot.StartsWith($allowedBackupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-OpenPathRecoveryLog "Journal backup root is outside the update backup directory: $backupRoot"
        return [PSCustomObject]@{ Complete = $false; Errors = @('Backup root outside update directory'); Changed = 0; Failures = @() }
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
                $previousHash = [string]$entry.previousSha256
                if ($previousHash -notmatch '^[0-9a-fA-F]{64}$') {
                    Write-OpenPathRecoveryLog "Journal entry has no pre-update hash: $relativePath"
                    $complete = $false
                    continue
                }

                $destinationIsFile = Test-Path -LiteralPath $destinationPath -PathType Leaf
                if ($destinationIsFile) {
                    $currentHash = Invoke-OpenPathRecoveryFileOperationWithRetry -Operation {
                        Get-OpenPathRecoveryFileHash -Path $destinationPath
                    }
                    if ([string]::Equals($currentHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                }

                if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                    Write-OpenPathRecoveryLog "File was present before the update but is missing and has no backup: $relativePath"
                    $complete = $false
                    continue
                }

                $backupHash = Invoke-OpenPathRecoveryFileOperationWithRetry -Operation {
                    Get-OpenPathRecoveryFileHash -Path $backupPath
                }
                if (-not [string]::Equals($backupHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-OpenPathRecoveryLog "Backup hash does not match the recorded pre-update hash: $relativePath"
                    $complete = $false
                    continue
                }

                $destinationDirectory = Split-Path $destinationPath -Parent
                if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                }
                $tempPath = "$destinationPath.openpath-update-recovery-$([guid]::NewGuid().ToString('N')).tmp"
                try {
                    $copiedHash = Copy-OpenPathRecoveryFileDurable -SourcePath $backupPath -DestinationPath $tempPath
                    if (-not [string]::Equals($copiedHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-OpenPathRecoveryLog "Restored file does not match the recorded pre-update hash: $relativePath"
                        $complete = $false
                        continue
                    }
                    Move-OpenPathRecoveryFileIntoPlace -TempPath $tempPath -DestinationPath $destinationPath
                    $changed += 1
                }
                finally {
                    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                if (Test-Path -LiteralPath $destinationPath) {
                    Invoke-OpenPathRecoveryFileOperationWithRetry -Operation {
                        Remove-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
                    }
                    $changed += 1
                }
                if (Test-Path -LiteralPath $destinationPath) {
                    Write-OpenPathRecoveryLog "Could not remove file added by the interrupted update: $relativePath"
                    $complete = $false
                }
            }
        }
        catch {
            $detail = Get-OpenPathRecoveryExceptionDetail -ErrorRecord $_
            Write-OpenPathRecoveryLog "Rollback failed for ${relativePath}: $($detail.ExceptionType) HResult=$($detail.HResult): $($detail.Message)"
            $failures += [PSCustomObject]@{
                RelativePath  = $relativePath
                ExceptionType = $detail.ExceptionType
                HResult       = $detail.HResult
                Message       = $detail.Message
            }
            $complete = $false
        }
    }

    return [PSCustomObject]@{ Complete = $complete; Errors = @(); Changed = $changed; Failures = @($failures) }
}

function Move-OpenPathRecoveryFileToQuarantine {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return $false
    }

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
    $quarantineName = "update-journal.quarantine-$timestamp-$([guid]::NewGuid().ToString('N')).json"
    $quarantinePath = Join-Path $script:UpdateRoot $quarantineName

    try {
        Move-OpenPathRecoveryFileDurable -SourcePath $SourcePath -DestinationPath $quarantinePath
    }
    catch {
        Write-OpenPathRecoveryLog "Could not quarantine the unusable update journal: $_"
        return $false
    }

    try {
        $quarantined = @(
            Get-ChildItem -LiteralPath $script:UpdateRoot -Filter 'update-journal.quarantine-*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property LastWriteTimeUtc -Descending
        )
        if ($quarantined.Count -gt 3) {
            $quarantined | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Retention is housekeeping; the quarantine itself already succeeded.
    }

    Write-OpenPathRecoveryLog "Quarantined an unusable update journal as $quarantineName"
    return $true
}

function Move-OpenPathRecoveryJournalToQuarantine {
    param(
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [string]$Version = '',
        [string]$Build = '',
        [string]$Detail = '',
        [string]$SourcePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $SourcePath = $script:JournalPath
    }

    if (-not (Move-OpenPathRecoveryFileToQuarantine -SourcePath $SourcePath)) {
        return
    }

    Write-OpenPathRecoveryReport `
        -Status 'DEGRADED' `
        -ReasonCode $ReasonCode `
        -Actions $ReasonCode `
        -Version $Version `
        -Build $Build `
        -Message $Detail
}

function Restore-OpenPathRecoverySupersededJournal {
    # This rule must stay identical to Restore-OpenPathAgentUpdateSupersededJournal
    # in Common.Update.ps1. The script cannot import that module, so the two
    # implementations are pinned together by the parity tests.
    if (-not (Test-Path -LiteralPath $script:SupersededJournalPath -PathType Leaf)) {
        return 'missing'
    }

    $reasonCode = ''
    $detail = ''
    try {
        $supersededJournal = Get-Content -LiteralPath $script:SupersededJournalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $schemaVersion = 0
        [void][int]::TryParse([string]$supersededJournal.schemaVersion, [ref]$schemaVersion)
        if ($schemaVersion -ne 2) {
            $reasonCode = 'self_update_recovery_journal_schema_unsupported'
            $detail = ("The superseded update journal has unsupported schemaVersion '{0}'" -f $supersededJournal.schemaVersion)
        }
    }
    catch {
        $reasonCode = 'self_update_recovery_journal_unreadable'
        $detail = "The superseded update journal could not be parsed: $_"
    }

    if ($reasonCode) {
        Move-OpenPathRecoveryJournalToQuarantine `
            -ReasonCode $reasonCode `
            -Detail $detail `
            -SourcePath $script:SupersededJournalPath
        if (Test-Path -LiteralPath $script:SupersededJournalPath -PathType Leaf) {
            Write-OpenPathRecoveryLog 'Could not quarantine the unusable superseded update journal'
            return 'failed'
        }
        return 'quarantined'
    }

    try {
        if (Test-Path -LiteralPath $script:JournalPath -PathType Leaf) {
            [System.IO.File]::Replace($script:SupersededJournalPath, $script:JournalPath, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($script:SupersededJournalPath, $script:JournalPath)
        }
        return 'moved'
    }
    catch {
        if ((Test-Path -LiteralPath $script:JournalPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $script:SupersededJournalPath -PathType Leaf)) {
            return 'moved'
        }
        Write-OpenPathRecoveryLog "Could not put the superseded update journal back: $_"
        return 'failed'
    }
}

function Remove-OpenPathRecoveryTempSiblings {
    <#
    .SYNOPSIS
        Removes every update temp sibling under the installed tree
    .DESCRIPTION
        A killed updater can leave a flushed but uninstalled temp sibling next
        to a file that the rollback then finds already at its pre-update hash.
        The per-entry cleanup only knows the current run id, so a completed
        recovery sweeps every matching sibling. No installed name uses these
        patterns and the update lock is held here.
    #>
    foreach ($pattern in @('*.openpath-update-*.tmp', '*.openpath-update-*.bak')) {
        foreach ($leftover in @(Get-ChildItem -LiteralPath $script:OpenPathRoot -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $leftover.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Complete-OpenPathRecoveryRun {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [bool]$Changed = $false,
        [bool]$ReportRollback = $true
    )

    $targetVersion = [string]$Record.targetVersion
    $targetBuild = [string]$Record.targetBuild
    $runBackupRoot = [string]$Record.backupRoot
    $runId = Get-OpenPathRecoveryRunId -Record $Record
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        foreach ($entry in @($Record.files)) {
            $relativePath = [string]$entry.relativePath
            if (-not (Test-OpenPathRecoveryRelativePath -RelativePath $relativePath)) {
                continue
            }
            $nativePath = ConvertTo-OpenPathRecoveryNativePath -RelativePath $relativePath
            $destinationPath = Join-Path $script:OpenPathRoot $nativePath
            $tempSibling = "$destinationPath.openpath-update-$runId.tmp"
            if (Test-Path -LiteralPath $tempSibling -PathType Leaf) {
                Remove-Item -LiteralPath $tempSibling -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath "$tempSibling.bak" -PathType Leaf) {
                Remove-Item -LiteralPath "$tempSibling.bak" -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Remove-OpenPathRecoveryTempSiblings

    $supersededRestore = Restore-OpenPathRecoverySupersededJournal
    if ($supersededRestore -eq 'failed') {
        $failedReasonCode = ConvertTo-OpenPathRecoveryReasonCode -Prefix 'self_update_recovery_failed' -Version $targetVersion -Build $targetBuild
        Write-OpenPathRecoveryReport `
            -Status 'DEGRADED' `
            -ReasonCode $failedReasonCode `
            -Actions 'self_update_recovery_failed' `
            -Version $targetVersion `
            -Build $targetBuild `
            -Message 'Interrupted update rollback completed but the superseded update journal could not be restored'
        Write-OpenPathRecoveryLog 'Interrupted update rollback completed but the superseded update journal could not be restored; keeping both journals'
        throw 'OpenPath agent update recovery did not complete'
    }

    if ($supersededRestore -eq 'quarantined') {
        Remove-Item -LiteralPath $script:JournalPath -Force -ErrorAction SilentlyContinue
    }
    elseif ($supersededRestore -eq 'missing') {
        Remove-Item -LiteralPath $script:JournalPath -Force -ErrorAction SilentlyContinue
    }
    # A moved superseded journal now occupies the journal place and must not
    # be removed: it records the earlier update's pending finalization.

    if (-not [string]::IsNullOrWhiteSpace($runBackupRoot)) {
        $intentPath = Join-Path $runBackupRoot 'journal-intent.json'
        if (Test-Path -LiteralPath $intentPath -PathType Leaf) {
            Remove-Item -LiteralPath $intentPath -Force -ErrorAction SilentlyContinue
        }
        $markerPath = Join-Path $runBackupRoot 'committed.marker'
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        }
        try {
            $resolvedRunRoot = [System.IO.Path]::GetFullPath($runBackupRoot)
            $allowedRoot = [System.IO.Path]::GetFullPath($script:BackupsRoot).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
            if ($resolvedRunRoot.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $resolvedRunRoot)) {
                Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-OpenPathRecoveryLog "Could not remove the recovered run directory: $_"
        }
    }

    Remove-OpenPathRecoveryState

    if ($ReportRollback -or $Changed) {
        $reasonCode = ConvertTo-OpenPathRecoveryReasonCode -Prefix 'self_update_recovery_rolled_back' -Version $targetVersion -Build $targetBuild
        Write-OpenPathRecoveryReport `
            -Status 'DEGRADED' `
            -ReasonCode $reasonCode `
            -Actions 'self_update_recovery_rolled_back' `
            -Version $targetVersion `
            -Build $targetBuild `
            -Message ("Interrupted update to {0} build {1} was rolled back" -f $targetVersion, $targetBuild)
    }

    Write-OpenPathRecoveryLog "Rolled back interrupted update to $targetVersion build $targetBuild"
}

function Register-OpenPathRecoveryFailure {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [string]$Detail = '',
        [AllowNull()][object]$Failure = $null
    )

    $existing = Get-OpenPathRecoveryState
    $attempts = 0
    $firstSeenAt = ''
    $repairAttempts = 0
    $lastRepairAt = ''
    $failedPath = ''
    $failedExceptionType = ''
    $failedHResult = ''
    $failedMessage = ''
    if ($existing.Present -and -not $existing.Unreadable -and $existing.State) {
        try { $attempts = [int]$existing.State.attempts } catch { $attempts = 0 }
        $firstSeenAt = [string]$existing.State.firstSeenAt
        try { $repairAttempts = [int]$existing.State.repairAttempts } catch { $repairAttempts = 0 }
        $lastRepairAt = [string]$existing.State.lastRepairAt
        if ($existing.State.PSObject.Properties['lastFailedPath']) {
            $failedPath = [string]$existing.State.lastFailedPath
        }
        if ($existing.State.PSObject.Properties['lastFailedExceptionType']) {
            $failedExceptionType = [string]$existing.State.lastFailedExceptionType
        }
        if ($existing.State.PSObject.Properties['lastFailedHResult']) {
            $failedHResult = [string]$existing.State.lastFailedHResult
        }
        if ($existing.State.PSObject.Properties['lastFailedMessage']) {
            $failedMessage = [string]$existing.State.lastFailedMessage
        }
    }
    if ($Failure) {
        $failedPath = [string]$Failure.RelativePath
        $failedExceptionType = [string]$Failure.ExceptionType
        $failedHResult = [string]$Failure.HResult
        $failedMessage = [string]$Failure.Message
    }
    $attempts += 1
    $state = if ($attempts -ge 3) { 'blocked' } else { 'retrying' }

    $targetVersion = [string]$Record.targetVersion
    $targetBuild = [string]$Record.targetBuild
    Write-OpenPathRecoveryState `
        -State $state `
        -ReasonCode $ReasonCode `
        -Attempts $attempts `
        -FirstSeenAt $firstSeenAt `
        -RunId (Get-OpenPathRecoveryRunId -Record $Record) `
        -RepairAttempts $repairAttempts `
        -LastRepairAt $lastRepairAt `
        -FailedPath $failedPath `
        -FailedExceptionType $failedExceptionType `
        -FailedHResult $failedHResult `
        -FailedMessage $failedMessage | Out-Null

    if ($state -eq 'blocked') {
        Write-OpenPathRecoveryReport `
            -Status 'DEGRADED' `
            -ReasonCode 'self_update_recovery_blocked' `
            -Actions 'self_update_recovery_blocked' `
            -Version $targetVersion `
            -Build $targetBuild `
            -Message ("Recovery reached its attempt bound: {0} {1}" -f $ReasonCode, $Detail)
    }
    else {
        $failedReasonCode = ConvertTo-OpenPathRecoveryReasonCode -Prefix 'self_update_recovery_failed' -Version $targetVersion -Build $targetBuild
        Write-OpenPathRecoveryReport `
            -Status 'DEGRADED' `
            -ReasonCode $failedReasonCode `
            -Actions 'self_update_recovery_failed' `
            -Version $targetVersion `
            -Build $targetBuild `
            -Message ("Recovery attempt {0} did not complete: {1}" -f $attempts, $ReasonCode)
    }
}

$script:OpenPathRoot = Resolve-OpenPathRecoveryRoot -ExplicitRoot $OpenPathRoot
$script:UpdateRoot = Join-Path (Join-Path $script:OpenPathRoot 'data') 'agent-update'
$script:BackupsRoot = Join-Path $script:UpdateRoot 'backups'
$script:JournalPath = Join-Path $script:UpdateRoot 'update-journal.json'
$script:SupersededJournalPath = Join-Path $script:UpdateRoot 'superseded-update-journal.json'
$script:RecoveryStatePath = Join-Path $script:UpdateRoot 'recovery-state.json'
$script:ReportPath = Join-Path $script:UpdateRoot 'recovery-report.json'
$script:LogPath = Join-Path (Join-Path (Join-Path $script:OpenPathRoot 'data') 'logs') 'openpath.log'

$hasIntent = $false
if (Test-Path -LiteralPath $script:BackupsRoot) {
    $hasIntent = $null -ne (Get-ChildItem -LiteralPath $script:BackupsRoot -Directory -Filter 'run-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'journal-intent.json') -PathType Leaf } |
        Select-Object -First 1)
}

if (-not (Test-Path -LiteralPath $script:JournalPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $script:SupersededJournalPath -PathType Leaf) -and
    -not $hasIntent -and
    -not (Test-Path -LiteralPath $script:RecoveryStatePath -PathType Leaf)) {
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

    $stateInfo = Get-OpenPathRecoveryState
    if ($stateInfo.Unreadable) {
        Write-OpenPathRecoveryLog 'Recovery state is unreadable; treating the tree as blocked and skipping hashing'
        return
    }
    if ($stateInfo.Present) {
        if ([string]$stateInfo.State.state -eq 'blocked') {
            Write-OpenPathRecoveryLog 'Recovery state is blocked; skipping hashing until the updater repairs the tree'
            return
        }
        $lastAttemptAt = ConvertTo-OpenPathRecoveryDateTimeOffset -Value $stateInfo.State.lastAttemptAt
        if ($lastAttemptAt -ne [DateTimeOffset]::MinValue -and
            ([DateTimeOffset]::UtcNow - $lastAttemptAt).TotalMinutes -lt 10) {
            Write-OpenPathRecoveryLog 'Recovery is retrying and its ten-minute backoff is still active'
            return
        }
    }

    if (-not (Test-Path -LiteralPath $script:JournalPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $script:SupersededJournalPath -PathType Leaf) {
            $supersededRestore = Restore-OpenPathRecoverySupersededJournal
            if ($supersededRestore -eq 'moved') {
                Write-OpenPathRecoveryLog 'Moved the superseded update journal into place'
            }
            elseif ($supersededRestore -eq 'quarantined') {
                return
            }
            else {
                Write-OpenPathRecoveryLog 'The superseded update journal is present but could not be put back'
                return
            }
        }
    }

    $journal = $null
    $journalValidation = Test-OpenPathRecoveryJournalRecord -Record $null
    if (Test-Path -LiteralPath $script:JournalPath -PathType Leaf) {
        try {
            $journal = Get-Content -LiteralPath $script:JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $journalValidation = Test-OpenPathRecoveryJournalRecord -Record $journal
        }
        catch {
            $journalValidation.Detail = "The update journal could not be parsed: $_"
        }
    }

    $supersededRunId = ''
    if (Test-Path -LiteralPath $script:SupersededJournalPath -PathType Leaf) {
        $supersededRecord = Read-OpenPathRecoveryJsonFile -Path $script:SupersededJournalPath
        if ($supersededRecord) {
            $supersededRunId = Get-OpenPathRecoveryRunId -Record $supersededRecord
        }
    }

    if ($journalValidation.Valid) {
        # Tier 1: a valid journal is authoritative.
        $runId = Get-OpenPathRecoveryRunId -Record $journal
        $hasMarker = Test-OpenPathRecoveryMarker -BackupRoot ([string]$journal.backupRoot) -RunId $runId
        if ([string]$journal.phase -eq 'committed' -or $hasMarker) {
            if ([string]$journal.phase -ne 'committed') {
                $journal.phase = 'committed'
                $journal.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                Write-OpenPathRecoveryJsonFile -Path $script:JournalPath -Object $journal
                Write-OpenPathRecoveryLog "Promoted the update journal to committed from the commit marker for run $runId"
            }
            else {
                Write-OpenPathRecoveryLog "Left the committed update journal in place for run $runId"
            }
            return
        }

        $rollback = Restore-OpenPathRecoveryJournal -Journal $journal
        if ($rollback.Complete) {
            Complete-OpenPathRecoveryRun -Record $journal -Changed ([bool]$rollback.Changed) -ReportRollback $true
            return
        }

        $primaryFailure = @($rollback.Failures)[0]
        Register-OpenPathRecoveryFailure -Record $journal -ReasonCode 'self_update_recovery_failed' -Failure $primaryFailure
        $failureText = if ($primaryFailure) {
            " for $($primaryFailure.RelativePath): $($primaryFailure.ExceptionType) HResult=$($primaryFailure.HResult)"
        }
        else {
            ''
        }
        Write-OpenPathRecoveryLog "Interrupted update rollback did not complete${failureText}; keeping the journal for the next attempt"
        throw 'OpenPath agent update recovery did not complete'
    }

    # Tier 2: use the newest valid intent when the journal cannot be used.
    $intents = @(Get-OpenPathRecoveryRunIntents |
        Where-Object { [string]::IsNullOrWhiteSpace($supersededRunId) -or -not [string]::Equals($_.RunId, $supersededRunId, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object -Property CreatedAt -Descending)
    $intent = if ($intents.Count -gt 0) { $intents[0] } else { $null }

    if ($intent) {
        if (Test-Path -LiteralPath $script:JournalPath -PathType Leaf) {
            if (-not (Move-OpenPathRecoveryFileToQuarantine -SourcePath $script:JournalPath)) {
                Write-OpenPathRecoveryLog 'Could not quarantine the unusable journal before using the run intent'
                return
            }
        }

        if (Test-OpenPathRecoveryMarker -BackupRoot $intent.BackupRoot -RunId $intent.RunId) {
            $intentRecord = $intent.Record
            $intentRecord.phase = 'committed'
            $intentRecord.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Write-OpenPathRecoveryJsonFile -Path $script:JournalPath -Object $intentRecord
            Write-OpenPathRecoveryLog "Promoted the run intent to a committed journal from the commit marker for run $($intent.RunId)"
            return
        }

        $rollback = Restore-OpenPathRecoveryJournal -Journal $intent.Record
        if ($rollback.Complete) {
            $changed = [bool]$rollback.Changed
            Complete-OpenPathRecoveryRun -Record $intent.Record -Changed $changed -ReportRollback $changed
            if (-not $changed) {
                Write-OpenPathRecoveryLog "Removed the orphan run $($intent.RunId) without a rollback report"
            }
            return
        }

        $primaryFailure = @($rollback.Failures)[0]
        Register-OpenPathRecoveryFailure -Record $intent.Record -ReasonCode 'self_update_recovery_failed' -Failure $primaryFailure
        $failureText = if ($primaryFailure) {
            " for $($primaryFailure.RelativePath): $($primaryFailure.ExceptionType) HResult=$($primaryFailure.HResult)"
        }
        else {
            ''
        }
        Write-OpenPathRecoveryLog "Interrupted update rollback from run $($intent.RunId) did not complete${failureText}; keeping the journal and intent"
        throw 'OpenPath agent update recovery did not complete'
    }

    # Tier 3: nothing local is valid. Stop the integrity restore and let the
    # updater converge on the published manifest.
    if (Test-Path -LiteralPath $script:JournalPath -PathType Leaf) {
        if (-not (Move-OpenPathRecoveryFileToQuarantine -SourcePath $script:JournalPath)) {
            Write-OpenPathRecoveryLog 'Could not quarantine the unusable journal; leaving it in place'
            return
        }
    }

    $reasonCode = $journalValidation.ReasonCode
    if ([string]::IsNullOrWhiteSpace($reasonCode)) {
        $reasonCode = 'self_update_recovery_blocked'
    }
    $detail = $journalValidation.Detail
    Write-OpenPathRecoveryState `
        -State 'blocked' `
        -ReasonCode $reasonCode `
        -Attempts 1 `
        -RunId (Get-OpenPathRecoveryRunId -Record $journal) | Out-Null
    Write-OpenPathRecoveryReport `
        -Status 'DEGRADED' `
        -ReasonCode $reasonCode `
        -Actions 'self_update_recovery_blocked' `
        -Version ([string]$journal.targetVersion) `
        -Build ([string]$journal.targetBuild) `
        -Message $detail
    Write-OpenPathRecoveryLog "Blocked interrupted update recovery: $reasonCode $detail"
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
