$script:OpenPathAgentUpdateLockName = 'Global\OpenPathAgentUpdateLock'
# See the matching constant in scripts\Recover-OpenPathAgentUpdate.ps1: a
# repair timestamp more than a few seconds ahead means the wall clock was
# corrected backwards, so the repair wait is already satisfied.
$script:OpenPathAgentUpdateRepairClockSkewToleranceSeconds = 5

function Enter-OpenPathAgentUpdateLock {
    <#
    .SYNOPSIS
        Tries to take the machine-wide agent update lock
    .DESCRIPTION
        The self-update holds this lock while it replaces agent files and
        refreshes the integrity backup and baseline. The watchdog takes it
        around its integrity check so it never restores files from a backup
        that is about to be replaced.
    .PARAMETER TimeoutMilliseconds
        How long to wait for the lock; 0 returns immediately
    #>
    [CmdletBinding()]
    param(
        [int]$TimeoutMilliseconds = 0
    )

    $mutex = [System.Threading.Mutex]::new($false, $script:OpenPathAgentUpdateLockName)
    $acquired = $false
    $abandoned = $false
    try {
        $acquired = $mutex.WaitOne($TimeoutMilliseconds)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
        $abandoned = $true
    }

    if (-not $acquired) {
        $mutex.Dispose()
        $mutex = $null
    }

    return [PSCustomObject]@{
        Acquired = [bool]$acquired
        Abandoned = [bool]$abandoned
        Mutex = $mutex
    }
}

function Exit-OpenPathAgentUpdateLock {
    <#
    .SYNOPSIS
        Releases a lock taken with Enter-OpenPathAgentUpdateLock
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [PSCustomObject]$Lock
    )

    if (-not $Lock -or -not $Lock.Mutex) {
        return
    }

    if ($Lock.Acquired) {
        try {
            $Lock.Mutex.ReleaseMutex()
        }
        catch [System.ApplicationException] {
            # Ignore if mutex ownership changed unexpectedly
        }
    }
    $Lock.Mutex.Dispose()
}

function Get-OpenPathAgentUpdateRoot {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Join-Path $OpenPathRoot 'data') 'agent-update')
}

function Get-OpenPathAgentUpdateJournalPath {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'update-journal.json')
}

function Get-OpenPathAgentUpdateFailureRecordPath {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'failed-update.json')
}

function Get-OpenPathAgentUpdateTimeoutStatePath {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'timeout-state.json')
}

function Get-OpenPathAgentUpdateRecoveryReportPath {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'recovery-report.json')
}

function Get-OpenPathAgentUpdateSupersededJournalPath {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'superseded-update-journal.json')
}

function Get-OpenPathAgentUpdateRecoveryStatePath {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'recovery-state.json')
}

function Get-OpenPathAgentUpdateJournalIntentPath {
    param([Parameter(Mandatory = $true)][string]$BackupRoot)

    return (Join-Path $BackupRoot 'journal-intent.json')
}

function Get-OpenPathAgentUpdateCommittedMarkerPath {
    param([Parameter(Mandatory = $true)][string]$BackupRoot)

    return (Join-Path $BackupRoot 'committed.marker')
}

function Get-OpenPathAgentUpdateJournalRunId {
    param([AllowNull()][object]$Journal)

    if (-not $Journal) {
        return ''
    }

    if ($Journal.PSObject.Properties['runId'] -and -not [string]::IsNullOrWhiteSpace([string]$Journal.runId)) {
        return [string]$Journal.runId
    }

    $backupRoot = [string]$Journal.backupRoot
    if (-not [string]::IsNullOrWhiteSpace($backupRoot)) {
        return (Split-Path -Path $backupRoot.TrimEnd([char[]]@('\', '/')) -Leaf)
    }

    return ''
}

function Write-OpenPathAgentUpdateCommittedMarker {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [string]$TargetVersion = '',
        [string]$TargetBuild = ''
    )

    $marker = [PSCustomObject]@{
        schemaVersion = 1
        runId         = $RunId
        targetVersion = $TargetVersion
        targetBuild   = $TargetBuild
        committedAt   = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $markerPath = Get-OpenPathAgentUpdateCommittedMarkerPath -BackupRoot $BackupRoot
    Write-OpenPathAgentUpdateJsonFile -Path $markerPath -Object $marker
    return $markerPath
}

function Read-OpenPathAgentUpdateCommittedMarker {
    param(
        [Parameter(Mandatory = $true)][string]$MarkerPath,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        return $null
    }

    try {
        $marker = Get-Content -LiteralPath $MarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $schemaVersion = 0
        [void][int]::TryParse([string]$marker.schemaVersion, [ref]$schemaVersion)
        if ($schemaVersion -ne 1) {
            return $null
        }
        if ([string]::IsNullOrWhiteSpace($RunId) -or
            -not [string]::Equals([string]$marker.runId, $RunId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return $marker
    }
    catch {
        return $null
    }
}

function Test-OpenPathAgentUpdateCommitEvidence {
    param(
        [AllowNull()][object]$Journal,
        [string]$BackupRoot = ''
    )

    if ($Journal -and [string]$Journal.phase -eq 'committed') {
        return $true
    }

    $resolvedBackupRoot = if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot
    }
    elseif ($Journal) {
        [string]$Journal.backupRoot
    }
    else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($resolvedBackupRoot)) {
        return $false
    }

    $runId = if ($Journal) { Get-OpenPathAgentUpdateJournalRunId -Journal $Journal } else { Split-Path -Path $resolvedBackupRoot.TrimEnd([char[]]@('\', '/')) -Leaf }
    if ([string]::IsNullOrWhiteSpace($runId)) {
        return $false
    }

    $markerPath = Get-OpenPathAgentUpdateCommittedMarkerPath -BackupRoot $resolvedBackupRoot
    return ($null -ne (Read-OpenPathAgentUpdateCommittedMarker -MarkerPath $markerPath -RunId $runId))
}

function Read-OpenPathAgentUpdateRecoveryState {
    <#
    .SYNOPSIS
        Reads recovery-state.json, treating an unreadable file as blocked
    #>
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $statePath = Get-OpenPathAgentUpdateRecoveryStatePath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $schemaVersion = 0
        [void][int]::TryParse([string]$state.schemaVersion, [ref]$schemaVersion)
        if ($schemaVersion -ne 1 -or [string]$state.state -notin @('retrying', 'blocked')) {
            throw 'unsupported recovery state'
        }
        return $state
    }
    catch {
        return [PSCustomObject]@{
            schemaVersion  = 1
            state          = 'blocked'
            reasonCode     = 'self_update_recovery_state_unreadable'
            attempts       = 0
            firstSeenAt    = ''
            lastAttemptAt  = ''
            repairAttempts = 0
            lastRepairAt   = ''
            runId          = ''
            Unreadable     = $true
        }
    }
}

function Test-OpenPathAgentUpdateRecoveryBlocked {
    param([AllowNull()][object]$State)

    if (-not $State) {
        return $false
    }

    return ([bool]$State.PSObject.Properties['Unreadable'] -or [string]$State.state -eq 'blocked')
}

function Test-OpenPathAgentUpdateRepairAllowed {
    param(
        [AllowNull()][object]$State,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $attempts = 0
    if ($State -and $State.PSObject.Properties['repairAttempts']) {
        try { $attempts = [int]$State.repairAttempts } catch { $attempts = 0 }
    }

    $requiredMinutes = if ($attempts -ge 3) { 1440 } else { 10 }
    $lastRepairAt = [DateTimeOffset]::MinValue
    if ($State -and $State.PSObject.Properties['lastRepairAt'] -and $null -ne $State.lastRepairAt) {
        $value = $State.lastRepairAt
        if ($value -is [DateTimeOffset]) {
            $lastRepairAt = [DateTimeOffset]$value
        }
        elseif ($value -is [DateTime]) {
            $lastRepairAt = [DateTimeOffset]$value
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $parsed = [DateTimeOffset]::MinValue
            $ok = [DateTimeOffset]::TryParse(
                [string]$value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsed
            )
            if ($ok) {
                $lastRepairAt = $parsed
            }
        }
    }

    $waitedMinutes = [double]::PositiveInfinity
    if ($lastRepairAt -ne [DateTimeOffset]::MinValue) {
        $waitedMinutes = ($Now - $lastRepairAt).TotalMinutes
        if ($waitedMinutes -lt 0) {
            if ($waitedMinutes -lt -($script:OpenPathAgentUpdateRepairClockSkewToleranceSeconds / 60)) {
                # The last repair is ahead of this clock: the clock moved
                # backwards. Treat the wait as elapsed, like a missing or
                # unreadable timestamp.
                $waitedMinutes = [double]::PositiveInfinity
            }
            else {
                # Small timestamp rounding or clock slew starts the wait now.
                $waitedMinutes = 0
            }
        }
    }
    return [PSCustomObject]@{
        Allowed        = ($waitedMinutes -ge $requiredMinutes)
        Attempts       = $attempts
        RequiredMinutes = $requiredMinutes
        WaitedMinutes  = $waitedMinutes
    }
}

function Register-OpenPathAgentUpdateRepairAttempt {
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [AllowNull()][object]$State
    )

    $attempts = 0
    $firstSeenAt = ''
    $reasonCode = 'self_update_recovery_blocked'
    $runId = ''
    if ($State) {
        if ($State.PSObject.Properties['repairAttempts']) {
            try { $attempts = [int]$State.repairAttempts } catch { $attempts = 0 }
        }
        if ($State.PSObject.Properties['firstSeenAt']) {
            $firstSeenAt = [string]$State.firstSeenAt
        }
        if ($State.PSObject.Properties['reasonCode'] -and -not [string]::IsNullOrWhiteSpace([string]$State.reasonCode)) {
            $reasonCode = [string]$State.reasonCode
        }
        if ($State.PSObject.Properties['runId']) {
            $runId = [string]$State.runId
        }
    }

    $now = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    if ([string]::IsNullOrWhiteSpace($firstSeenAt)) {
        $firstSeenAt = $now
    }
    $record = [PSCustomObject]@{
        schemaVersion  = 1
        state          = 'blocked'
        reasonCode     = $reasonCode
        attempts       = 0
        firstSeenAt    = $firstSeenAt
        lastAttemptAt  = $now
        repairAttempts = ($attempts + 1)
        lastRepairAt   = $now
        runId          = $runId
    }
    if ($State -and $State.PSObject.Properties['attempts']) {
        try { $record.attempts = [int]$State.attempts } catch { }
    }
    Write-OpenPathAgentUpdateJsonFile `
        -Path (Get-OpenPathAgentUpdateRecoveryStatePath -OpenPathRoot $OpenPathRoot) `
        -Object $record
    return $record
}

function Remove-OpenPathAgentUpdateRecoveryState {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $statePath = Get-OpenPathAgentUpdateRecoveryStatePath -OpenPathRoot $OpenPathRoot
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
    }
}

function Copy-OpenPathAgentUpdateFileDurable {
    <#
    .SYNOPSIS
        Copies a file once, flushes it to disk and returns the SHA-256 of the bytes written
    .DESCRIPTION
        Reads the source and writes the destination in the same pass, feeding the
        incremental SHA-256 with exactly the bytes written. Flush($true) makes the
        data durable before the caller gives the destination a visible name. The
        destination is not replaced atomically by this helper; callers write to a
        temp sibling or a backup path they own.
    #>
    [CmdletBinding()]
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

function Get-OpenPathAgentUpdateFileHash {
    <#
    .SYNOPSIS
        Returns the lowercase SHA-256 of a file without the Get-FileHash wrapper
    .DESCRIPTION
        Get-FileHash converts a locked-file IOException into a
        WriteErrorException with HResult 0x80131501 and no inner exception, so
        the retry rule cannot see the real sharing violation. This helper opens
        the file directly, letting the IOException and its HResult surface.
    #>
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

function Test-OpenPathAgentUpdateSharingViolation {
    <#
    .SYNOPSIS
        Tests whether an error is a Windows sharing or lock violation
    .DESCRIPTION
        Only ERROR_SHARING_VIOLATION (0x80070020) and ERROR_LOCK_VIOLATION
        (0x80070021) are transient. The check uses HResult and never the
        localized message text. Method invocation wrappers are unwrapped
        because a .NET call from PowerShell surfaces the IOException as an
        inner exception.
    #>
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

function Get-OpenPathAgentUpdateExceptionDetail {
    <#
    .SYNOPSIS
        Returns the type, HResult and message of the exception that failed an operation
    #>
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

function Invoke-OpenPathAgentUpdateFileOperationWithRetry {
    <#
    .SYNOPSIS
        Runs one file operation, retrying only a transient sharing or lock violation
    .DESCRIPTION
        Four retries at one-second intervals cover the short holds an antivirus
        scanner, indexer or browser can put on an installed file. The worst case
        adds four seconds per locked file, well inside the three-minute P3
        bound. Every other error is rethrown on the first attempt so a damaged
        file or record is never hidden.
    #>
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
            if ($attempt -ge $MaxAttempts -or -not (Test-OpenPathAgentUpdateSharingViolation -ErrorRecord $errorRecord)) {
                throw
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function Invoke-OpenPathAgentUpdateFileReplace {
    param(
        [Parameter(Mandatory = $true)][string]$TempPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    if (Get-Command -Name 'Invoke-OpenPathAtomicFileReplace' -ErrorAction SilentlyContinue) {
        Invoke-OpenPathAtomicFileReplace `
            -TempPath $TempPath `
            -DestinationPath $DestinationPath `
            -BackupPath $BackupPath
    }
    else {
        [System.IO.File]::Replace($TempPath, $DestinationPath, $BackupPath, $true)
    }
}

function Move-OpenPathAgentUpdateFileDurable {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Invoke-OpenPathAgentUpdateFileOperationWithRetry -Operation {
        [System.IO.File]::Move($SourcePath, $DestinationPath)
    }
}

function Move-OpenPathAgentUpdateFileIntoPlace {
    <#
    .SYNOPSIS
        Atomically swaps an already flushed temp sibling into its destination
    .DESCRIPTION
        File.Replace is one metadata operation for an existing destination and
        File.Move is one for a new one. Both are used instead of Move-Item -Force,
        whose Windows PowerShell 5.1 implementation is not guaranteed to be a
        single rename. A transient sharing or lock violation is retried for a
        few seconds; any other failure is immediate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TempPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $backupPath = "$TempPath.bak"
    try {
        if ([System.IO.File]::Exists($DestinationPath)) {
            Invoke-OpenPathAgentUpdateFileOperationWithRetry -Operation {
                Invoke-OpenPathAgentUpdateFileReplace `
                    -TempPath $TempPath `
                    -DestinationPath $DestinationPath `
                    -BackupPath $backupPath
            }
        }
        else {
            Move-OpenPathAgentUpdateFileDurable -SourcePath $TempPath -DestinationPath $DestinationPath
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

function Remove-OpenPathAgentUpdateLeftovers {
    <#
    .SYNOPSIS
        Removes temp siblings and staging trees left by an earlier interrupted run
    .DESCRIPTION
        A run that is killed after writing a temp sibling can leave a file whose
        data is not part of any installed name. The next run removes those
        siblings and every staging tree before it downloads anything. A sweep
        failure is logged and never stops the update.
    #>
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $updateRoot = Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot
    try {
        foreach ($pattern in @('*.openpath-update-*.tmp', '*.openpath-update-*.bak', '*.openpath-update-recovery-*.tmp')) {
            $leftovers = @(Get-ChildItem -LiteralPath $OpenPathRoot -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue)
            foreach ($leftover in $leftovers) {
                Remove-Item -LiteralPath $leftover.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        if (Test-Path -LiteralPath $updateRoot) {
            foreach ($staging in @(Get-ChildItem -LiteralPath $updateRoot -Directory -Filter 'staging-*' -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $staging.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        try {
            Write-OpenPathLog "Self-update: could not sweep leftovers from an earlier run: $_" -Level WARN
        }
        catch {
            # A sweep failure must never stop the update.
        }
    }
}

function Write-OpenPathAgentUpdateJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Object
    )

    if (Get-Command -Name 'Write-OpenPathAtomicJsonFile' -ErrorAction SilentlyContinue) {
        Write-OpenPathAtomicJsonFile -Path $Path -Data $Object -Depth 10
        return
    }

    # The standalone unit tests dot-source this file without the rest of the
    # module. Keep the same durable contract instead of falling back to a plain
    # text write.
    $directory = Split-Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    $json = $Object | ConvertTo-Json -Depth 10
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($json)
    $fileStream = $null
    try {
        $fileStream = [System.IO.File]::Create($temporaryPath)
        $fileStream.Write($bytes, 0, $bytes.Length)
        $fileStream.Flush($true)
    }
    finally {
        if ($fileStream) {
            $fileStream.Dispose()
            $fileStream = $null
        }
    }
    try {
        if ([System.IO.File]::Exists($Path)) {
            Invoke-OpenPathAtomicFileReplace -TempPath $temporaryPath -DestinationPath $Path -BackupPath $backupPath
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

function Write-OpenPathAgentUpdateJournal {
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][object]$Journal
    )

    $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $OpenPathRoot
    Write-OpenPathAgentUpdateJsonFile -Path $journalPath -Object $Journal
    return $journalPath
}

function Update-OpenPathAgentUpdateJournalPhase {
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][object]$Journal,
        [Parameter(Mandatory = $true)][ValidateSet('replacing', 'validating', 'committed')][string]$Phase
    )

    $Journal.phase = $Phase
    $Journal.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    Write-OpenPathAgentUpdateJournal -OpenPathRoot $OpenPathRoot -Journal $Journal | Out-Null
}

function Remove-OpenPathAgentUpdateJournal {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $OpenPathRoot
    if (Test-Path -LiteralPath $journalPath) {
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
    }
}

function Save-OpenPathAgentUpdateSupersededJournal {
    <#
    .SYNOPSIS
        Keeps a stuck committed journal byte-for-byte before a replacement install
    .DESCRIPTION
        The stuck journal records that the installed tree passed the health gate
        but its finalization is still pending. A replacement install replaces the
        journal, so the stuck one is preserved under a fixed name. A complete
        rollback puts it back; a successful replacement removes it.
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$JournalPath
    )

    $supersededPath = Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $OpenPathRoot
    $temporaryPath = "$supersededPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-OpenPathAgentUpdateFileDurable -SourcePath $JournalPath -DestinationPath $temporaryPath | Out-Null
        if (Test-Path -LiteralPath $supersededPath -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $supersededPath, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $supersededPath)
        }
    }
    catch {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        throw "Could not preserve the committed update journal: $_"
    }
}

function Remove-OpenPathAgentUpdateSupersededJournal {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $supersededPath = Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $OpenPathRoot
    if (Test-Path -LiteralPath $supersededPath -PathType Leaf) {
        Remove-Item -LiteralPath $supersededPath -Force -ErrorAction Stop
    }
}

function Move-OpenPathAgentUpdateSupersededJournalToQuarantine {
    <#
    .SYNOPSIS
        Applies the recovery quarantine rule to an unusable superseded journal
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [string]$Detail = ''
    )

    $updateRoot = Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot
    $supersededPath = Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $supersededPath -PathType Leaf)) {
        return $false
    }

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
    $quarantinePath = Join-Path $updateRoot ("update-journal.quarantine-{0}-{1}.json" -f $timestamp, [guid]::NewGuid().ToString('N'))
    Move-OpenPathAgentUpdateFileDurable -SourcePath $supersededPath -DestinationPath $quarantinePath

    try {
        $quarantined = @(
            Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property LastWriteTimeUtc -Descending
        )
        if ($quarantined.Count -gt 3) {
            $quarantined | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Retention is housekeeping; the quarantine itself already succeeded.
    }

    try {
        $report = [PSCustomObject]@{
            schemaVersion = 1
            status        = 'DEGRADED'
            reasonCode    = $ReasonCode
            actions       = $ReasonCode
            version       = ''
            build         = ''
            message       = $Detail
            recordedAt    = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        Write-OpenPathAgentUpdateJsonFile -Path (Get-OpenPathAgentUpdateRecoveryReportPath -OpenPathRoot $OpenPathRoot) -Object $report
    }
    catch {
        try {
            Write-OpenPathLog "Self-update: could not write the superseded journal quarantine report: $_" -Level WARN
        }
        catch {
            # Reporting must never block the quarantine.
        }
    }

    return $true
}

function Restore-OpenPathAgentUpdateSupersededJournal {
    <#
    .SYNOPSIS
        Puts the superseded journal back in the journal place, or quarantines it
    .DESCRIPTION
        This rule must stay identical to the standalone recovery script: a usable
        superseded journal atomically replaces the rolled-back journal, and an
        unusable one is quarantined. A failed move keeps both files so no code
        path removes a journal while its replacement could not be put in place.
    #>
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $result = [PSCustomObject]@{
        Present     = $false
        Moved       = $false
        Quarantined = $false
        Error       = ''
    }

    $supersededPath = Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $supersededPath -PathType Leaf)) {
        return $result
    }
    $result.Present = $true

    $reasonCode = ''
    $detail = ''
    try {
        $supersededJournal = Get-Content -LiteralPath $supersededPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
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
        try {
            Move-OpenPathAgentUpdateSupersededJournalToQuarantine `
                -OpenPathRoot $OpenPathRoot `
                -ReasonCode $reasonCode `
                -Detail $detail | Out-Null
            $result.Quarantined = $true
        }
        catch {
            $result.Error = "Could not quarantine the unusable superseded update journal: $_"
        }
        return $result
    }

    $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $OpenPathRoot
    try {
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            [System.IO.File]::Replace($supersededPath, $journalPath, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($supersededPath, $journalPath)
        }
        $result.Moved = $true
    }
    catch {
        if ((Test-Path -LiteralPath $journalPath -PathType Leaf) -and -not (Test-Path -LiteralPath $supersededPath -PathType Leaf)) {
            $result.Moved = $true
        }
        else {
            $result.Error = "Could not put the superseded update journal back: $_"
        }
    }

    return $result
}

function Get-OpenPathAgentUpdateFailureRecord {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $recordPath = Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $recordPath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Save-OpenPathAgentUpdateFailureRecord {
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$Build = '',
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Message = ''
    )

    $record = [PSCustomObject]@{
        schemaVersion = 1
        version       = $Version
        build         = $Build
        stage         = $Stage
        message       = $Message
        failedAt      = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    Write-OpenPathAgentUpdateJsonFile -Path (Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $OpenPathRoot) -Object $record
}

function Clear-OpenPathAgentUpdateFailureRecord {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $recordPath = Get-OpenPathAgentUpdateFailureRecordPath -OpenPathRoot $OpenPathRoot
    if (Test-Path -LiteralPath $recordPath) {
        Remove-Item -LiteralPath $recordPath -Force -ErrorAction Stop
    }
}

function Get-OpenPathAgentUpdateTimeoutState {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $statePath = Get-OpenPathAgentUpdateTimeoutStatePath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Clear-OpenPathAgentUpdateTimeoutState {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $statePath = Get-OpenPathAgentUpdateTimeoutStatePath -OpenPathRoot $OpenPathRoot
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
    }
}

function Register-OpenPathAgentUpdateTimeout {
    <#
    .SYNOPSIS
        Counts consecutive gate or validation timeouts for one target build
    .DESCRIPTION
        A timeout does not prove the build is bad, so it must not by itself
        create the seven-day failed-build record. The count is persisted so the
        third consecutive timeout for the same target can apply the backoff.
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$Build = '',
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Message = ''
    )

    $now = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $previous = Get-OpenPathAgentUpdateTimeoutState -OpenPathRoot $OpenPathRoot
    $count = 1
    $firstAt = $now
    if ($previous -and (Test-OpenPathAgentUpdateFailureMatchesTarget -Record $previous -TargetVersion $Version -TargetBuild $Build)) {
        try {
            $count = [int]$previous.consecutiveTimeouts + 1
        }
        catch {
            $count = 1
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$previous.firstAt)) {
            $firstAt = [string]$previous.firstAt
        }
    }

    $state = [PSCustomObject]@{
        schemaVersion        = 1
        version              = $Version
        build                = $Build
        stage                = $Stage
        message              = $Message
        consecutiveTimeouts  = $count
        firstAt              = $firstAt
        lastAt               = $now
    }
    Write-OpenPathAgentUpdateJsonFile -Path (Get-OpenPathAgentUpdateTimeoutStatePath -OpenPathRoot $OpenPathRoot) -Object $state

    return [PSCustomObject]@{
        Count = $count
        State = $state
    }
}

function Test-OpenPathAgentUpdateFailureMatchesTarget {
    param(
        [AllowNull()][object]$Record,
        [string]$TargetVersion,
        [string]$TargetBuild
    )

    if (-not $Record) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetBuild)) {
        return [string]::Equals([string]$Record.build, $TargetBuild, [System.StringComparison]::OrdinalIgnoreCase)
    }

    return [string]::Equals([string]$Record.version, $TargetVersion, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-OpenPathAgentUpdateFailureBackoffActive {
    param(
        [AllowNull()][object]$Record,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    if (-not $Record -or [string]::IsNullOrWhiteSpace([string]$Record.failedAt)) {
        return $false
    }

    $failedAtValue = $Record.failedAt
    if ($failedAtValue -is [DateTime]) {
        $failedAtValue = $failedAtValue.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    elseif ($failedAtValue -is [DateTimeOffset]) {
        $failedAtValue = $failedAtValue.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    else {
        $failedAtValue = [string]$failedAtValue
    }

    $failedAt = [DateTimeOffset]::MinValue
    $parsed = [DateTimeOffset]::TryParse(
        [string]$failedAtValue,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$failedAt
    )
    if (-not $parsed) {
        return $false
    }

    $elapsed = $Now - $failedAt
    if ($elapsed.TotalSeconds -lt 0) {
        if ($elapsed.TotalSeconds -lt -$script:OpenPathAgentUpdateRepairClockSkewToleranceSeconds) {
            # The recorded failure is ahead of this clock: the clock moved
            # backwards. Treat the backoff as elapsed, like an unreadable
            # timestamp, instead of blocking until the clock catches up.
            return $false
        }
        # Ordinary timestamp rounding or a small NTP step starts the wait now.
        $elapsed = [TimeSpan]::Zero
    }

    return ($elapsed.TotalDays -lt 7)
}

function Test-OpenPathAgentUpdateTargetsMatch {
    <#
    .SYNOPSIS
        Compares two update targets, preferring the build when both sides have one
    #>
    param(
        [string]$VersionA = '',
        [string]$BuildA = '',
        [string]$VersionB = '',
        [string]$BuildB = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($BuildA) -and -not [string]::IsNullOrWhiteSpace($BuildB)) {
        return [string]::Equals($BuildA, $BuildB, [System.StringComparison]::OrdinalIgnoreCase)
    }

    return [string]::Equals($VersionA, $VersionB, [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-OpenPathAgentUpdateReasonCode {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Version,
        [string]$Build
    )

    $prefix = switch ($Stage) {
        'validation' { 'self_update_validation_failed' }
        'gate' { 'self_update_health_gate_failed' }
        default { 'self_update_failed' }
    }

    $candidate = ("{0}_{1}_{2}" -f $prefix, $Version, $Build)
    $candidate = ($candidate -replace '[^a-zA-Z0-9_]+', '_').ToLowerInvariant()
    while ($candidate.Contains('__')) {
        $candidate = $candidate.Replace('__', '_')
    }
    $candidate = $candidate.Trim('_')
    if ($candidate.Length -gt 64) {
        $candidate = $candidate.Substring(0, 64).TrimEnd('_')
    }
    if ($candidate -notmatch '^[a-z][a-z0-9_]{2,63}$') {
        $candidate = 'self_update_failed'
    }

    return $candidate
}

function Send-OpenPathAgentUpdateFailureReport {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Version,
        [string]$Build,
        [string]$CurrentVersion,
        [string]$Message
    )

    try {
        $reasonCode = ConvertTo-OpenPathAgentUpdateReasonCode -Stage $Stage -Version $Version -Build $Build
        $summary = "self-update $Stage failed for $Version build $Build : $Message"
        if ($summary.Length -gt 500) {
            $summary = $summary.Substring(0, 500)
        }
        Send-OpenPathHealthReport -Status 'DEGRADED' -Actions $summary -ReasonCodes @($reasonCode) -Version $CurrentVersion | Out-Null
    }
    catch {
        try {
            Write-OpenPathLog "Self-update: could not send failure health report: $_" -Level WARN
        }
        catch {
            # Reporting must never change the update outcome.
        }
    }
}

function Send-OpenPathAgentUpdateRecoveryReport {
    <#
    .SYNOPSIS
        Sends a recovery report left by the standalone interrupted-update script
    #>
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $reportPath = Get-OpenPathAgentUpdateRecoveryReportPath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $reportPath)) {
        return $false
    }

    try {
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([int]$report.schemaVersion -ne 1) {
            return $false
        }

        $reasonCode = [string]$report.reasonCode
        if ($reasonCode -notmatch '^[a-z][a-z0-9_]{2,63}$') {
            $reasonCode = 'self_update_recovery_failed'
        }

        $sent = Send-OpenPathHealthReport `
            -Status 'DEGRADED' `
            -Actions ([string]$report.actions) `
            -ReasonCodes @($reasonCode)
        if ($sent) {
            Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
        }
        return [bool]$sent
    }
    catch {
        try {
            Write-OpenPathLog "Self-update: could not send recovery health report: $_" -Level WARN
        }
        catch {
            # Reporting must never block the caller.
        }
        return $false
    }
}

function Resolve-OpenPathAgentUpdatePowerShellPath {
    $systemRoot = [string]$env:SystemRoot
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $candidate = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command) {
        return [string]$command.Source
    }

    return ''
}

function Test-OpenPathAgentUpdateStagedArtifacts {
    <#
    .SYNOPSIS
        Parses staged PowerShell and JSON files before any installed file changes
    .DESCRIPTION
        Runs the parse under the system Windows PowerShell when the caller is not
        already running it, so BOM-less file decoding matches the scheduled tasks.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [string]$PowerShellPath = '',
        [int]$TimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $PowerShellPath = Resolve-OpenPathAgentUpdatePowerShellPath
    }

    $useExternalProcess = (
        $PSVersionTable.PSEdition -ne 'Desktop' -and
        -not [string]::IsNullOrWhiteSpace($PowerShellPath) -and
        (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)
    )

    $validatorContent = @'
param([Parameter(Mandatory = $true)][string]$Root)
$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.ArrayList
$extensions = @('*.ps1', '*.psm1')
foreach ($pattern in $extensions) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $pattern -ErrorAction Stop)) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) {
            [void]$failures.Add(("{0}:{1}: {2}" -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Message))
        }
    }
}
foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' -ErrorAction Stop)) {
    try {
        $null = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [void]$failures.Add(("{0}: {1}" -f $file.FullName, $_.Exception.Message))
    }
}
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine($failure)
    }
    exit 1
}
exit 0
'@

    if ($useExternalProcess) {
        $validatorPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-update-validate-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        try {
            $encoding = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($validatorPath, $validatorContent, $encoding)
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = $PowerShellPath
            $windowStyleArgument = if ($env:OS -eq 'Windows_NT') { '-WindowStyle Hidden ' } else { '' }
            $processStartInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass $windowStyleArgument-File `"$validatorPath`" -Root `"$StagingRoot`""
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.CreateNoWindow = $true
            $processStartInfo.RedirectStandardOutput = $true
            $processStartInfo.RedirectStandardError = $true

            $process = [System.Diagnostics.Process]::Start($processStartInfo)
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try { $process.Kill() } catch { }
                return [PSCustomObject]@{
                    Healthy  = $false
                    TimedOut = $true
                    Message  = "Staged artifact validation timed out after $TimeoutSeconds seconds"
                }
            }

            $stderr = [string]$stderrTask.Result
            $exitCode = $process.ExitCode
            $process.Dispose()
            if ($exitCode -ne 0) {
                $firstLine = @($stderr -split "`r?`n" | Where-Object { $_ })[0]
                if ([string]::IsNullOrWhiteSpace($firstLine)) {
                    $firstLine = "validation process exited with code $exitCode"
                }
                return [PSCustomObject]@{
                    Healthy  = $false
                    TimedOut = $false
                    Message  = $firstLine
                }
            }

            return [PSCustomObject]@{
                Healthy  = $true
                TimedOut = $false
                Message  = ''
            }
        }
        catch {
            return [PSCustomObject]@{
                Healthy  = $false
                TimedOut = $false
                Message  = "Staged artifact validation could not run: $_"
            }
        }
        finally {
            Remove-Item -LiteralPath $validatorPath -Force -ErrorAction SilentlyContinue
        }
    }

    $failures = New-Object System.Collections.ArrayList
    foreach ($pattern in @('*.ps1', '*.psm1')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File -Filter $pattern -ErrorAction Stop)) {
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            foreach ($parseError in @($parseErrors)) {
                [void]$failures.Add(("{0}:{1}: {2}" -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Message))
            }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File -Filter '*.json' -ErrorAction Stop)) {
        try {
            $null = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            [void]$failures.Add(("{0}: {1}" -f $file.FullName, $_.Exception.Message))
        }
    }

    if ($failures.Count -gt 0) {
        return [PSCustomObject]@{
            Healthy  = $false
            TimedOut = $false
            Message  = [string]$failures[0]
        }
    }

    return [PSCustomObject]@{
        Healthy  = $true
        TimedOut = $false
        Message  = ''
    }
}

function Invoke-OpenPathAgentUpdateHealthGate {
    <#
    .SYNOPSIS
        Loads the replaced agent in a fresh Windows PowerShell process
    .DESCRIPTION
        Uses the installed health gate entry script, bounded by a timeout. Any
        non-zero exit, missing script or timeout fails the gate.
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [string]$PowerShellPath = '',
        [int]$TimeoutSeconds = 60
    )

    $gateScriptPath = Join-Path (Join-Path $OpenPathRoot 'scripts') 'Test-OpenPathAgentUpdateHealth.ps1'
    if (-not (Test-Path -LiteralPath $gateScriptPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Healthy  = $false
            TimedOut = $false
            ExitCode = -1
            Message  = "Health gate script is missing: $gateScriptPath"
        }
    }

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $PowerShellPath = Resolve-OpenPathAgentUpdatePowerShellPath
    }
    if ([string]::IsNullOrWhiteSpace($PowerShellPath) -or -not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Healthy  = $false
            TimedOut = $false
            ExitCode = -1
            Message  = 'Windows PowerShell is not available for the health gate'
        }
    }

    try {
        $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = $PowerShellPath
        $windowStyleArgument = if ($env:OS -eq 'Windows_NT') { '-WindowStyle Hidden ' } else { '' }
        $processStartInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass $windowStyleArgument-File `"$gateScriptPath`" -OpenPathRoot `"$OpenPathRoot`""
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true
        $processStartInfo.RedirectStandardOutput = $true
        $processStartInfo.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::Start($processStartInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            $process.Dispose()
            return [PSCustomObject]@{
                Healthy  = $false
                TimedOut = $true
                ExitCode = -1
                Message  = "Health gate timed out after $TimeoutSeconds seconds"
            }
        }

        $stdout = [string]$stdoutTask.Result
        $stderr = [string]$stderrTask.Result
        $exitCode = $process.ExitCode
        $process.Dispose()

        if ($exitCode -eq 0) {
            return [PSCustomObject]@{
                Healthy  = $true
                TimedOut = $false
                ExitCode = 0
                Message  = [string]$stdout
            }
        }

        $message = $stderr
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = $stdout
        }
        $firstLine = @($message -split "`r?`n" | Where-Object { $_ })[0]
        if ([string]::IsNullOrWhiteSpace($firstLine)) {
            $firstLine = "health gate exited with code $exitCode"
        }
        return [PSCustomObject]@{
            Healthy  = $false
            TimedOut = $false
            ExitCode = $exitCode
            Message  = $firstLine
        }
    }
    catch {
        return [PSCustomObject]@{
            Healthy  = $false
            TimedOut = $false
            ExitCode = -1
            Message  = "Health gate could not run: $_"
        }
    }
}

function New-OpenPathAgentUpdateBackupRoot {
    <#
    .SYNOPSIS
        Creates a new, empty backup directory owned by a single update run
    #>
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    $backupsRoot = Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'backups'
    if (-not (Test-Path -LiteralPath $backupsRoot)) {
        New-Item -ItemType Directory -Path $backupsRoot -Force | Out-Null
    }

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
    $runName = "run-$timestamp-$([guid]::NewGuid().ToString('N'))"
    $backupRoot = Join-Path $backupsRoot $runName
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    return $backupRoot
}

function Save-OpenPathAgentUpdateInstalledFileBackups {
    <#
    .SYNOPSIS
        Copies every installed file that will be replaced into this run's backup directory
    .DESCRIPTION
        Runs before the journal is written and before any installed file changes.
        A file whose installed hash already equals the target hash is classified
        unchanged and is neither backed up nor replaced. Every other existing
        file is copied with the durable single-pass copy, which also returns the
        hash of the bytes written; the backup is re-read once so the abort still
        proves what was persisted. Each entry gets the hash of the pre-update
        file so rollback can prove that a backup belongs to this run.
    #>
    param([Parameter(Mandatory = $true)][object[]]$Files)

    foreach ($file in $Files) {
        $hadExistingFile = Test-Path -LiteralPath $file.DestinationPath -PathType Leaf
        $file | Add-Member -NotePropertyName HadExistingFile -NotePropertyValue ([bool]$hadExistingFile) -Force

        if (-not $hadExistingFile) {
            $file | Add-Member -NotePropertyName PreviousSha256 -NotePropertyValue '' -Force
            $file | Add-Member -NotePropertyName Unchanged -NotePropertyValue $false -Force
            continue
        }

        $previousHash = (Get-FileHash -LiteralPath $file.DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ([string]::Equals($previousHash, [string]$file.ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $file | Add-Member -NotePropertyName PreviousSha256 -NotePropertyValue $previousHash -Force
            $file | Add-Member -NotePropertyName Unchanged -NotePropertyValue $true -Force
            continue
        }

        $backupDirectory = Split-Path $file.BackupPath -Parent
        if (-not (Test-Path -LiteralPath $backupDirectory)) {
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        }

        $copiedHash = Copy-OpenPathAgentUpdateFileDurable `
            -SourcePath $file.DestinationPath `
            -DestinationPath $file.BackupPath
        if (-not [string]::Equals($copiedHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Backup checksum mismatch for $($file.RelativePath)"
        }

        $backupHash = (Get-FileHash -LiteralPath $file.BackupPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if (-not [string]::Equals($backupHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Backup checksum mismatch for $($file.RelativePath)"
        }

        $file | Add-Member -NotePropertyName PreviousSha256 -NotePropertyValue $previousHash -Force
        $file | Add-Member -NotePropertyName Unchanged -NotePropertyValue $false -Force
    }
}

function Remove-OpenPathAgentUpdateBackupDirectories {
    <#
    .SYNOPSIS
        Removes old per-run and legacy per-version backup directories
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [string]$KeepPath = ''
    )

    $backupsRoot = Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'backups'
    if (-not (Test-Path -LiteralPath $backupsRoot)) {
        return
    }

    $resolvedKeepPath = ''
    if (-not [string]::IsNullOrWhiteSpace($KeepPath)) {
        try {
            $resolvedKeepPath = [System.IO.Path]::GetFullPath($KeepPath)
        }
        catch {
            $resolvedKeepPath = ''
        }
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $backupsRoot -Directory -ErrorAction SilentlyContinue)) {
        $resolvedDirectory = [System.IO.Path]::GetFullPath($directory.FullName)
        if ($resolvedKeepPath -and [string]::Equals($resolvedDirectory, $resolvedKeepPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            try {
                Write-OpenPathLog "Self-update: could not remove an old backup directory: $_" -Level WARN
            }
            catch {
                # Cleanup must never turn a healthy tree into a failed update.
            }
        }
    }
}

function Remove-OpenPathAgentUpdateRunBackupDirectory {
    <#
    .SYNOPSIS
        Removes a failed run's backup directory unless a journal still points to it
    .DESCRIPTION
        A run that failed before writing its journal, or that completed its
        rollback, leaves no updater state behind. A journal on disk that names
        the same backup root means the rollback is incomplete, so keep it.
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [string]$BackupRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        return
    }

    $backupsRoot = Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'backups'
    $allowedPrefix = [System.IO.Path]::GetFullPath($backupsRoot).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    try {
        $resolvedBackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
    }
    catch {
        return
    }

    if (-not $resolvedBackupRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $OpenPathRoot
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        try {
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $journalBackupRoot = [string]$journal.backupRoot
            if (-not [string]::IsNullOrWhiteSpace($journalBackupRoot)) {
                $resolvedJournalBackupRoot = [System.IO.Path]::GetFullPath($journalBackupRoot)
                if ([string]::Equals($resolvedJournalBackupRoot, $resolvedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return
                }
            }
        }
        catch {
            # An unreadable journal is not proof that this directory is unused.
            return
        }
    }

    if (Test-Path -LiteralPath $resolvedBackupRoot) {
        Remove-Item -LiteralPath $resolvedBackupRoot -Recurse -Force -ErrorAction Stop
    }
}

function Test-OpenPathAgentUpdateJournalTargetHashes {
    <#
    .SYNOPSIS
        Verifies that every file named by the journal is the target build
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][object]$Journal
    )

    $errors = New-Object System.Collections.ArrayList
    foreach ($entry in @($Journal.files)) {
        $relativePath = [string]$entry.relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.Contains('..') -or [System.IO.Path]::IsPathRooted($relativePath)) {
            [void]$errors.Add("Unsafe journal path: $relativePath")
            continue
        }

        $nativePath = ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar) -replace '\\', [System.IO.Path]::DirectorySeparatorChar
        $destinationPath = Join-Path $OpenPathRoot $nativePath
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            [void]$errors.Add("Missing file: $relativePath")
            continue
        }

        $expectedHash = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            [void]$errors.Add("Journal entry has no target hash: $relativePath")
            continue
        }

        try {
            $actualHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
        catch {
            [void]$errors.Add("Could not hash ${relativePath}: $_")
            continue
        }

        if (-not [string]::Equals($actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$errors.Add("Target hash mismatch: $relativePath")
        }
    }

    return [PSCustomObject]@{
        Complete = ($errors.Count -eq 0)
        Errors   = @($errors.ToArray())
    }
}

function Send-OpenPathAgentUpdateFinalizationFailureReport {
    param(
        [string]$Version,
        [string]$Build,
        [string]$Message
    )

    try {
        $summary = "self-update finalization failed for $Version build $Build : $Message"
        if ($summary.Length -gt 500) {
            $summary = $summary.Substring(0, 500)
        }
        Send-OpenPathHealthReport `
            -Status 'DEGRADED' `
            -Actions $summary `
            -ReasonCodes @('self_update_finalization_failed') `
            -Version $Version | Out-Null
    }
    catch {
        try {
            Write-OpenPathLog "Self-update: could not send finalization health report: $_" -Level WARN
        }
        catch {
            # Reporting must never change the update outcome.
        }
    }
}

function Complete-OpenPathAgentUpdateFinalization {
    <#
    .SYNOPSIS
        Finishes a committed update and is safe to run more than once
    .DESCRIPTION
        The health gate is the commit point. Everything after it is follow-up
        work: config, scheduled tasks, protected mode, the SSE listener, and
        the integrity backup and baseline. A failure here never rolls files
        back and leaves the committed journal for the next attempt.
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][object]$Journal,
        [object]$Config = $null
    )

    $targetVersion = [string]$Journal.targetVersion
    $targetBuild = [string]$Journal.targetBuild
    $step = 'journal'
    $failureCode = ''

    try {
        if ([string]$Journal.phase -ne 'committed') {
            $journalRunId = Get-OpenPathAgentUpdateJournalRunId -Journal $Journal
            $markerPath = Get-OpenPathAgentUpdateCommittedMarkerPath -BackupRoot ([string]$Journal.backupRoot)
            $marker = Read-OpenPathAgentUpdateCommittedMarker -MarkerPath $markerPath -RunId $journalRunId
            if (-not $marker) {
                throw "Journal phase is not committed: $($Journal.phase)"
            }
            $Journal.phase = 'committed'
            $Journal.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Write-OpenPathAgentUpdateJournal -OpenPathRoot $OpenPathRoot -Journal $Journal | Out-Null
        }

        # Verify the installed tree before anything else. A hash mismatch must
        # not touch the config, the tasks, protected mode or the integrity data,
        # because those steps restart the local DNS proxy.
        $step = 'integrity-verification'
        $targetCheck = Test-OpenPathAgentUpdateJournalTargetHashes -OpenPathRoot $OpenPathRoot -Journal $Journal

        # Every attempt refreshes updatedAt so the watchdog spaces retries, and
        # counts the attempt in the same journal write.
        $attempts = 0
        if ($Journal.PSObject.Properties['finalizationAttempts']) {
            try {
                $attempts = [int]$Journal.finalizationAttempts
            }
            catch {
                $attempts = 0
            }
        }
        $Journal | Add-Member -NotePropertyName finalizationAttempts -NotePropertyValue ($attempts + 1) -Force
        Update-OpenPathAgentUpdateJournalPhase -OpenPathRoot $OpenPathRoot -Journal $Journal -Phase 'committed'

        if (-not $targetCheck.Complete) {
            $failureCode = 'hash_mismatch'
            throw ("Installed files do not match the journal target hashes: " + (@($targetCheck.Errors) -join '; '))
        }

        $step = 'config'
        if (-not $Config) {
            $Config = Get-OpenPathConfig
        }

        $configChanged = $false
        if ([string]$Config.version -ne $targetVersion) {
            if ($Config.PSObject.Properties['version']) {
                $Config.version = $targetVersion
            }
            else {
                $Config | Add-Member -NotePropertyName version -NotePropertyValue $targetVersion
            }
            $configChanged = $true
        }

        if (-not [string]::IsNullOrWhiteSpace($targetBuild)) {
            $currentBuild = if ($Config.PSObject.Properties['agentBuild']) { [string]$Config.agentBuild } else { '' }
            if ($currentBuild -ne $targetBuild) {
                if ($Config.PSObject.Properties['agentBuild']) {
                    $Config.agentBuild = $targetBuild
                }
                else {
                    $Config | Add-Member -NotePropertyName agentBuild -NotePropertyValue $targetBuild
                }
                $configChanged = $true
            }
        }

        $hasUpdateTimestamp = (
            $Config.PSObject.Properties['lastAgentUpdateAt'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Config.lastAgentUpdateAt)
        )
        if ($configChanged -or -not $hasUpdateTimestamp) {
            $updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            if ($Config.PSObject.Properties['lastAgentUpdateAt']) {
                $Config.lastAgentUpdateAt = $updatedAt
            }
            else {
                $Config | Add-Member -NotePropertyName lastAgentUpdateAt -NotePropertyValue $updatedAt
            }
            $configChanged = $true
        }

        if ($configChanged) {
            Set-OpenPathConfig -Config $Config | Out-Null
        }

        $step = 'tasks'
        $updateInterval = 5
        if ($Config.PSObject.Properties['updateIntervalMinutes']) {
            try {
                $candidate = [int]$Config.updateIntervalMinutes
                if ($candidate -ge 1) {
                    $updateInterval = $candidate
                }
            }
            catch {
                # Keep default
            }
        }

        $watchdogInterval = 1
        if ($Config.PSObject.Properties['watchdogIntervalMinutes']) {
            try {
                $candidate = [int]$Config.watchdogIntervalMinutes
                if ($candidate -ge 1) {
                    $watchdogInterval = $candidate
                }
            }
            catch {
                # Keep default
            }
        }

        if (Get-Command -Name 'Register-OpenPathTask' -ErrorAction SilentlyContinue) {
            Register-OpenPathTask -OpenPathRoot $OpenPathRoot -UpdateIntervalMinutes $updateInterval -WatchdogIntervalMinutes $watchdogInterval | Out-Null
        }
        if (Get-Command -Name 'Enable-OpenPathTask' -ErrorAction SilentlyContinue) {
            Enable-OpenPathTask | Out-Null
        }
        if (Get-Command -Name 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure' -ErrorAction SilentlyContinue) {
            try { Invoke-OpenPathFirefoxNativeHostCompiledEnsure -Config $Config | Out-Null } catch { }
        }
        if (Get-Command -Name 'Register-OpenPathFirefoxNativeHost' -ErrorAction SilentlyContinue) {
            Register-OpenPathFirefoxNativeHost -Config $Config -PreserveExistingOnNotReady | Out-Null
        }
        # A classroom disabled on the server stays open across an agent update.
        $whitelistPath = Join-Path (Join-Path $OpenPathRoot 'data') 'whitelist.txt'
        $classroomDisabled = [bool](Get-OpenPathWhitelistSectionsFromFile -Path $whitelistPath).IsDisabled
        if (-not $classroomDisabled -and (Get-Command -Name 'Restore-OpenPathProtectedMode' -ErrorAction SilentlyContinue)) {
            Restore-OpenPathProtectedMode -Config $Config | Out-Null
        }
        elseif (Get-Command -Name 'Restart-AcrylicService' -ErrorAction SilentlyContinue) {
            Restart-AcrylicService | Out-Null
        }
        if (Get-Command -Name 'Start-OpenPathTask' -ErrorAction SilentlyContinue) {
            Start-OpenPathTask -TaskType SSE | Out-Null
        }

        # Refresh the integrity data only from a tree proven to be the target
        # build. Otherwise the watchdog would treat a mixed tree as trusted.
        $step = 'integrity'
        Save-OpenPathIntegrityBackup | Out-Null
        New-OpenPathIntegrityBaseline | Out-Null

        # The intent and marker have served their purpose only after the new
        # tree is verified and the integrity data describes it.
        $step = 'update-records-removal'
        $intentPath = Get-OpenPathAgentUpdateJournalIntentPath -BackupRoot ([string]$Journal.backupRoot)
        if (Test-Path -LiteralPath $intentPath -PathType Leaf) {
            Remove-Item -LiteralPath $intentPath -Force -ErrorAction Stop
        }
        $markerPath = Get-OpenPathAgentUpdateCommittedMarkerPath -BackupRoot ([string]$Journal.backupRoot)
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
        }

        $step = 'backup-cleanup'
        Remove-OpenPathAgentUpdateBackupDirectories -OpenPathRoot $OpenPathRoot -KeepPath ([string]$Journal.backupRoot)

        $step = 'superseded-journal-removal'
        Remove-OpenPathAgentUpdateSupersededJournal -OpenPathRoot $OpenPathRoot

        $step = 'journal-removal'
        Remove-OpenPathAgentUpdateJournal -OpenPathRoot $OpenPathRoot
        try {
            Clear-OpenPathAgentUpdateFailureRecord -OpenPathRoot $OpenPathRoot
        }
        catch {
            Write-OpenPathLog "Self-update: could not clear the failed-build record: $_" -Level WARN
        }
        $step = 'recovery-state-removal'
        Remove-OpenPathAgentUpdateRecoveryState -OpenPathRoot $OpenPathRoot

        return [PSCustomObject]@{
            Success = $true
            Message = ''
            FailureCode = ''
        }
    }
    catch {
        $message = "Finalization failed at ${step}: $_"
        try {
            Write-OpenPathLog "Self-update: $message" -Level ERROR
        }
        catch {
            # Logging must never change the finalization outcome.
        }
        Send-OpenPathAgentUpdateFinalizationFailureReport -Version $targetVersion -Build $targetBuild -Message $message
        if ([string]::IsNullOrWhiteSpace($failureCode)) {
            $failureCode = 'finalization_failed'
        }
        return [PSCustomObject]@{
            Success = $false
            Message = $message
            FailureCode = $failureCode
        }
    }
}

function Restore-OpenPathAgentUpdateJournalBackups {
    <#
    .SYNOPSIS
        Rolls back every file named by an update journal
    .DESCRIPTION
        One restore rule, shared with the standalone recovery script: leave a
        file whose current hash is the recorded pre-update hash; otherwise
        restore the backup only if the backup itself matches that hash. A file
        that did not exist before is removed. Rollback is complete only when
        every entry ends in a verified state.
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][object]$Journal
    )

    $complete = $true
    $changed = 0
    $errors = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList
    $updateRoot = Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot
    $allowedBackupRoot = [System.IO.Path]::GetFullPath((Join-Path $updateRoot 'backups'))
    $allowedBackupPrefix = $allowedBackupRoot.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $backupRoot = [string]$Journal.backupRoot
    $runId = Get-OpenPathAgentUpdateJournalRunId -Journal $Journal
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $runId = 'rollback'
    }

    if ([string]::IsNullOrWhiteSpace($backupRoot)) {
        return [PSCustomObject]@{ Complete = $false; Errors = @('Journal has no backup root'); Changed = 0; Failures = @() }
    }

    try {
        $resolvedBackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
    }
    catch {
        return [PSCustomObject]@{ Complete = $false; Errors = @("Backup root is not a valid path: $backupRoot"); Changed = 0; Failures = @() }
    }

    if (-not $resolvedBackupRoot.StartsWith($allowedBackupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ Complete = $false; Errors = @("Backup root is outside the update directory: $backupRoot"); Changed = 0; Failures = @() }
    }

    foreach ($entry in @($Journal.files)) {
        $relativePath = [string]$entry.relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.Contains('..') -or [System.IO.Path]::IsPathRooted($relativePath)) {
            [void]$errors.Add("Unsafe journal path: $relativePath")
            $complete = $false
            continue
        }

        $nativePath = ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar) -replace '\\', [System.IO.Path]::DirectorySeparatorChar
        $destinationPath = Join-Path $OpenPathRoot $nativePath
        $backupPath = Join-Path $resolvedBackupRoot $nativePath

        try {
            if ([bool]$entry.existedBefore) {
                $previousHash = [string]$entry.previousSha256
                if ($previousHash -notmatch '^[0-9a-fA-F]{64}$') {
                    [void]$errors.Add("Journal entry has no pre-update hash: $relativePath")
                    $complete = $false
                    continue
                }

                $destinationIsFile = Test-Path -LiteralPath $destinationPath -PathType Leaf
                if ($destinationIsFile) {
                    $currentHash = Invoke-OpenPathAgentUpdateFileOperationWithRetry -Operation {
                        Get-OpenPathAgentUpdateFileHash -Path $destinationPath
                    }
                    if ([string]::Equals($currentHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                }

                if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                    [void]$errors.Add("Missing file and backup: $relativePath")
                    $complete = $false
                    continue
                }

                $backupHash = Invoke-OpenPathAgentUpdateFileOperationWithRetry -Operation {
                    Get-OpenPathAgentUpdateFileHash -Path $backupPath
                }
                if (-not [string]::Equals($backupHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$errors.Add("Backup hash does not match the recorded pre-update hash: $relativePath")
                    $complete = $false
                    continue
                }

                $destinationDirectory = Split-Path $destinationPath -Parent
                if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                }
                $tempPath = "$destinationPath.openpath-update-$runId.tmp"
                try {
                    $copiedHash = Copy-OpenPathAgentUpdateFileDurable `
                        -SourcePath $backupPath `
                        -DestinationPath $tempPath
                    if (-not [string]::Equals($copiedHash, $previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                        [void]$errors.Add("Restored file does not match the recorded pre-update hash: $relativePath")
                        $complete = $false
                        continue
                    }
                    Move-OpenPathAgentUpdateFileIntoPlace -TempPath $tempPath -DestinationPath $destinationPath
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
                    Invoke-OpenPathAgentUpdateFileOperationWithRetry -Operation {
                        Remove-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
                    }
                    $changed += 1
                }
                if (Test-Path -LiteralPath $destinationPath) {
                    [void]$errors.Add("Could not remove new file: $relativePath")
                    $complete = $false
                }
            }
        }
        catch {
            $detail = Get-OpenPathAgentUpdateExceptionDetail -ErrorRecord $_
            $message = "Rollback failed for ${relativePath}: $($detail.ExceptionType) HResult=$($detail.HResult): $($detail.Message)"
            [void]$errors.Add($message)
            [void]$failures.Add([PSCustomObject]@{
                RelativePath  = $relativePath
                ExceptionType = $detail.ExceptionType
                HResult       = $detail.HResult
                Message       = $detail.Message
            })
            $complete = $false
        }

        $tempSibling = "$destinationPath.openpath-update-$runId.tmp"
        if (Test-Path -LiteralPath $tempSibling -PathType Leaf) {
            Remove-Item -LiteralPath $tempSibling -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath "$tempSibling.bak" -PathType Leaf) {
            Remove-Item -LiteralPath "$tempSibling.bak" -Force -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{
        Complete = $complete
        Errors   = @($errors.ToArray())
        Changed  = $changed
        Failures = @($failures.ToArray())
    }
}

function Invoke-OpenPathAgentSelfUpdate {
    <#
    .SYNOPSIS
        Performs silent software self-update against the current OpenPath server
    .PARAMETER CheckOnly
        Only check if update is available
    .PARAMETER Silent
        Suppress interactive output (logs are still written)
    #>
    [CmdletBinding()]
    param(
        [switch]$CheckOnly,
        [switch]$Silent
    )

    function Write-SelfUpdateMessage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,

            [ValidateSet('INFO', 'WARN', 'ERROR')]
            [string]$Level = 'INFO'
        )

        Write-OpenPathLog "Self-update: $Message" -Level $Level

        if ($Silent) {
            return
        }

        $color = switch ($Level) {
            'ERROR' { 'Red' }
            'WARN' { 'Yellow' }
            default { 'Cyan' }
        }

        Write-Host $Message -ForegroundColor $color
    }

    $config = $null
    try {
        $config = Get-OpenPathConfig
    }
    catch {
        $message = 'Configuration unavailable for self-update'
        Write-SelfUpdateMessage -Message $message -Level ERROR
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }

    # A committed journal means the new tree already passed the health gate.
    # Finish its follow-up work before a new update downloads anything. If that
    # finalization fails, the manifest still decides whether a new build can be
    # installed instead of returning at once.
    $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $script:OpenPathRoot
    $supersededJournalPath = Get-OpenPathAgentUpdateSupersededJournalPath -OpenPathRoot $script:OpenPathRoot
    if ((Test-Path -LiteralPath $supersededJournalPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        $restoredSuperseded = Restore-OpenPathAgentUpdateSupersededJournal -OpenPathRoot $script:OpenPathRoot
        if ($restoredSuperseded.Moved) {
            Write-SelfUpdateMessage -Message 'Restored the superseded update journal left by an interrupted replacement install'
        }
        elseif ($restoredSuperseded.Quarantined) {
            Write-SelfUpdateMessage -Message 'Quarantined an unusable superseded update journal' -Level WARN
        }
        else {
            $message = "Could not restore the superseded update journal: $($restoredSuperseded.Error)"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }
    }
    $pendingJournal = $null
    $pendingFinalizationFailure = $null
    $pendingJournalTargetVersion = ''
    $pendingJournalTargetBuild = ''
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        try {
            $pendingJournal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $pendingJournal = $null
        }
    }
    if ($pendingJournal -and [string]$pendingJournal.phase -eq 'committed') {
        $pendingJournalTargetVersion = [string]$pendingJournal.targetVersion
        $pendingJournalTargetBuild = [string]$pendingJournal.targetBuild
    }

    $pendingJournalHasCommitEvidence = $false
    if ($pendingJournal) {
        $pendingJournalHasCommitEvidence = Test-OpenPathAgentUpdateCommitEvidence -Journal $pendingJournal
        if ($pendingJournalHasCommitEvidence) {
            $pendingJournalTargetVersion = [string]$pendingJournal.targetVersion
            $pendingJournalTargetBuild = [string]$pendingJournal.targetBuild
        }
    }

    if ($pendingJournalHasCommitEvidence) {
        $pendingFinalizationLock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 120000
        if (-not $pendingFinalizationLock.Acquired) {
            $message = 'Another self-update process is already running'
            Write-SelfUpdateMessage -Message $message -Level WARN
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }

        try {
            if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
                $pendingJournal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ([string]$pendingJournal.phase -ne 'committed' -and
                    (Test-OpenPathAgentUpdateCommitEvidence -Journal $pendingJournal)) {
                    $pendingJournal.phase = 'committed'
                    $pendingJournal.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot -Journal $pendingJournal | Out-Null
                }
                if ([string]$pendingJournal.phase -eq 'committed') {
                    $pendingJournalTargetVersion = [string]$pendingJournal.targetVersion
                    $pendingJournalTargetBuild = [string]$pendingJournal.targetBuild
                    $pendingFinalization = Complete-OpenPathAgentUpdateFinalization `
                        -OpenPathRoot $script:OpenPathRoot `
                        -Journal $pendingJournal `
                        -Config $config
                    if (-not $pendingFinalization.Success) {
                        $pendingFinalizationFailure = $pendingFinalization
                        Write-SelfUpdateMessage `
                            -Message "Agent self-update finalization failed: $($pendingFinalization.Message); checking the published manifest before deciding whether to install it" `
                            -Level WARN
                    }
                    else {
                        Write-SelfUpdateMessage -Message 'Completed an interrupted agent update finalization'
                    }
                }
            }
        }
        catch {
            $pendingFinalizationFailure = [PSCustomObject]@{
                Success     = $false
                Message     = "Could not complete the committed agent update journal: $_"
                FailureCode = 'finalization_failed'
            }
            Write-SelfUpdateMessage -Message $pendingFinalizationFailure.Message -Level WARN
        }
        finally {
            Exit-OpenPathAgentUpdateLock -Lock $pendingFinalizationLock
        }
    }

    $apiUrl = if ($config.PSObject.Properties['apiUrl']) { [string]$config.apiUrl } else { '' }
    $whitelistUrl = if ($config.PSObject.Properties['whitelistUrl']) { [string]$config.whitelistUrl } else { '' }
    $recoveryState = Read-OpenPathAgentUpdateRecoveryState -OpenPathRoot $script:OpenPathRoot
    $repairRequired = Test-OpenPathAgentUpdateRecoveryBlocked -State $recoveryState
    if ($repairRequired) {
        $repairDecision = Test-OpenPathAgentUpdateRepairAllowed -State $recoveryState
        if (-not $repairDecision.Allowed) {
            $message = "Blocked agent update repair is waiting for its next bound ($($repairDecision.RequiredMinutes) minutes)"
            Write-SelfUpdateMessage -Message $message -Level WARN
            return [PSCustomObject]@{
                Success = $true
                Updated = $false
                Message = $message
            }
        }
    }

    $currentVersion = if ($config.PSObject.Properties['version'] -and $config.version) {
        [string]$config.version
    }
    else {
        '0.0.0'
    }

    if (-not $apiUrl -or -not $whitelistUrl) {
        if ($pendingFinalizationFailure) {
            $message = "Agent self-update finalization failed: $($pendingFinalizationFailure.Message)"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }
        $message = 'Classroom mode is not configured; self-update skipped'
        Write-SelfUpdateMessage -Message $message -Level WARN
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }

    $machineToken = Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl $whitelistUrl
    if (-not $machineToken) {
        if ($pendingFinalizationFailure) {
            $message = "Agent self-update finalization failed: $($pendingFinalizationFailure.Message)"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }
        $message = 'Could not extract machine token from whitelist URL'
        Write-SelfUpdateMessage -Message $message -Level ERROR
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }

    $apiBaseUrl = $apiUrl.TrimEnd('/')
    $headers = @{ Authorization = "Bearer $machineToken" }

    $manifest = $null
    try {
        $manifest = Invoke-RestMethod -Uri "$apiBaseUrl/api/agent/windows/manifest" -Method Get -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        if ($pendingFinalizationFailure) {
            Write-SelfUpdateMessage -Message "Manifest download failed while a committed update is stuck: $_" -Level WARN
            $message = "Agent self-update finalization failed: $($pendingFinalizationFailure.Message)"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }
        $message = "Manifest download failed: $_"
        Write-SelfUpdateMessage -Message $message -Level WARN
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }

    if (-not $manifest -or -not $manifest.version -or -not $manifest.files) {
        if ($pendingFinalizationFailure) {
            $message = "Agent self-update finalization failed: $($pendingFinalizationFailure.Message)"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }
        $message = 'Invalid manifest payload received from server'
        Write-SelfUpdateMessage -Message $message -Level ERROR
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }

    $targetVersion = [string]$manifest.version
    $currentBuild = if ($config.PSObject.Properties['agentBuild'] -and $config.agentBuild) { [string]$config.agentBuild } else { '' }
    $targetBuild = if ($manifest.PSObject.Properties['build'] -and $manifest.build) { [string]$manifest.build } else { '' }
    $updateNeeded = Test-OpenPathAgentUpdateNeeded -CurrentVersion $currentVersion -CurrentBuild $currentBuild `
        -TargetVersion $targetVersion -TargetBuild $targetBuild

    # A stuck finalization must not block a build that can fix the machine.
    # The journal's target decides whether the published build is different.
    $installPublishedBuild = $false
    if ($pendingFinalizationFailure) {
        $publishedBuildLabel = if ($targetBuild) { $targetBuild } else { '(none)' }
        $stuckBuildLabel = if ($pendingJournalTargetBuild) { $pendingJournalTargetBuild } else { '(none)' }
        if ([string]$pendingFinalizationFailure.FailureCode -eq 'hash_mismatch') {
            $installPublishedBuild = $true
            Write-SelfUpdateMessage -Message "Finalization failed at the target hash check; installing the published build $targetVersion build $publishedBuildLabel even if it matches the stuck target" -Level WARN
        }
        elseif (-not (Test-OpenPathAgentUpdateTargetsMatch `
                    -VersionA $targetVersion `
                    -BuildA $targetBuild `
                    -VersionB $pendingJournalTargetVersion `
                    -BuildB $pendingJournalTargetBuild)) {
            $installPublishedBuild = $true
            Write-SelfUpdateMessage -Message "Finalization failed for the stuck target $pendingJournalTargetVersion build $stuckBuildLabel; the server publishes $targetVersion build $publishedBuildLabel, so the published build is installed" -Level WARN
        }
        else {
            Write-SelfUpdateMessage -Message "Finalization failed for the stuck target $pendingJournalTargetVersion build $stuckBuildLabel; the server still publishes that target, so the committed journal is kept for the next bounded retry" -Level WARN
            $message = "Agent self-update finalization failed: $($pendingFinalizationFailure.Message)"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }
    }

    if ($repairRequired) {
        $installPublishedBuild = $true
        Write-SelfUpdateMessage -Message "Blocked recovery state; installing the published build $targetVersion build $targetBuild to repair the tree" -Level WARN
    }

    if (-not $updateNeeded -and -not $installPublishedBuild) {
        $message = "Agent already up to date (current=$currentVersion)"
        Write-SelfUpdateMessage -Message $message
        # Phase 5.2 D2: the periodic Update task also retries the compiled
        # native host refresh (source delivered by a previous update, earlier
        # compile failure, ...) under the one-hour failure backoff.
        if (Get-Command -Name 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure' -ErrorAction SilentlyContinue) {
            try { Invoke-OpenPathFirefoxNativeHostCompiledEnsure -Config $config | Out-Null } catch { }
        }
        return [PSCustomObject]@{
            Success = $true
            Updated = $false
            CurrentVersion = $currentVersion
            TargetVersion = $targetVersion
            Message = $message
        }
    }

    $updateAvailableMessage = if ((Compare-OpenPathVersion -CurrentVersion $currentVersion -TargetVersion $targetVersion) -eq 0) {
        "Agent update available: $currentVersion build $(if ($currentBuild) { $currentBuild } else { '(none)' }) -> $targetBuild"
    }
    else {
        "Agent update available: $currentVersion -> $targetVersion"
    }
    Write-SelfUpdateMessage -Message $updateAvailableMessage

    if ($CheckOnly) {
        return [PSCustomObject]@{
            Success = $true
            Updated = $false
            CurrentVersion = $currentVersion
            TargetVersion = $targetVersion
            Message = $updateAvailableMessage
        }
    }

    # A build that already failed validation or the health gate is not retried
    # in a loop. The server clears the record by publishing a different build;
    # after seven days the same build is attempted again in case the failure
    # was environmental.
    $failureRecord = Get-OpenPathAgentUpdateFailureRecord -OpenPathRoot $script:OpenPathRoot
    if (-not $repairRequired -and $failureRecord -and (Test-OpenPathAgentUpdateFailureMatchesTarget -Record $failureRecord -TargetVersion $targetVersion -TargetBuild $targetBuild)) {
        if (Test-OpenPathAgentUpdateFailureBackoffActive -Record $failureRecord) {
            $message = "Skipping previously failed agent update: $targetVersion build $targetBuild (failed at $($failureRecord.failedAt))"
            Write-SelfUpdateMessage -Message $message -Level WARN
            return [PSCustomObject]@{
                Success = $true
                Updated = $false
                CurrentVersion = $currentVersion
                TargetVersion = $targetVersion
                Message = $message
            }
        }
        try {
            Clear-OpenPathAgentUpdateFailureRecord -OpenPathRoot $script:OpenPathRoot
            Clear-OpenPathAgentUpdateTimeoutState -OpenPathRoot $script:OpenPathRoot
        }
        catch {
            Write-SelfUpdateMessage -Message "Could not clear the failed-build record: $_" -Level WARN
        }
    }
    elseif ($failureRecord) {
        try {
            Clear-OpenPathAgentUpdateFailureRecord -OpenPathRoot $script:OpenPathRoot
            Clear-OpenPathAgentUpdateTimeoutState -OpenPathRoot $script:OpenPathRoot
        }
        catch {
            Write-SelfUpdateMessage -Message "Could not clear the failed-build record: $_" -Level WARN
        }
    }

    $updateLock = $null
    $updateJournal = $null
    $runBackupRoot = $null
    $failureStage = $null
    $failureTimedOut = $false
    $updateCommitted = $false
    $replacementStarted = $false

    try {
        # Wait briefly: the watchdog holds this lock for the few seconds its
        # integrity check takes, and a concurrent self-update holds it longer.
        $updateLock = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 120000
        if ($updateLock.Abandoned) {
            Write-SelfUpdateMessage -Message 'Update lock was abandoned by previous process, continuing' -Level WARN
        }

        if (-not $updateLock.Acquired) {
            $message = 'Another self-update process is already running'
            Write-SelfUpdateMessage -Message $message -Level WARN
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }

        if ($repairRequired) {
            $repairState = Read-OpenPathAgentUpdateRecoveryState -OpenPathRoot $script:OpenPathRoot
            $repairDecision = Test-OpenPathAgentUpdateRepairAllowed -State $repairState
            if (-not $repairDecision.Allowed) {
                $message = "Blocked agent update repair is waiting for its next bound ($($repairDecision.RequiredMinutes) minutes)"
                Write-SelfUpdateMessage -Message $message -Level WARN
                return [PSCustomObject]@{
                    Success = $true
                    Updated = $false
                    Message = $message
                }
            }
            $recoveryState = Register-OpenPathAgentUpdateRepairAttempt -OpenPathRoot $script:OpenPathRoot -State $repairState
        }

        $manifestFiles = @($manifest.files)
        if ($manifestFiles.Count -eq 0) {
            throw 'Manifest did not include files to update'
        }

        # data\agent-update holds the update journal, per-run backups and the
        # staged download tree. The backup directory belongs to this run only.
        $updateRoot = Join-Path (Join-Path $script:OpenPathRoot 'data') 'agent-update'
        $stagingRoot = Join-Path $updateRoot ("staging-$targetVersion")
        $backupRoot = New-OpenPathAgentUpdateBackupRoot -OpenPathRoot $script:OpenPathRoot
        $runBackupRoot = $backupRoot
        $runId = Split-Path -Path $backupRoot -Leaf

        # A run killed before its first swap can leave flushed temp siblings and
        # a staging tree. None of them is a visible installed name; remove them
        # before this run downloads anything.
        Remove-OpenPathAgentUpdateLeftovers -OpenPathRoot $script:OpenPathRoot

        if (Test-Path $stagingRoot) {
            Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

        $downloadedFiles = @()
        foreach ($file in $manifestFiles) {
            $manifestPath = [string]$file.path
            if ([string]::IsNullOrWhiteSpace($manifestPath)) {
                throw 'Manifest included empty file path'
            }

            if ($manifestPath.Contains('..')) {
                throw "Rejected unsafe file path from manifest: $manifestPath"
            }

            $relativePath = $manifestPath -replace '/', '\'
            if ([System.IO.Path]::IsPathRooted($relativePath)) {
                throw "Rejected rooted file path from manifest: $manifestPath"
            }

            $declaredHash = if ($file.PSObject.Properties['sha256']) { [string]$file.sha256 } else { '' }
            if ([string]::IsNullOrWhiteSpace($declaredHash) -or $declaredHash -notmatch '^[0-9a-fA-F]{64}$') {
                throw "Manifest entry missing/invalid sha256 for $manifestPath"
            }

            $nativeRelativePath = ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar) -replace '\\', [System.IO.Path]::DirectorySeparatorChar
            $stagedPath = Join-Path $stagingRoot $nativeRelativePath
            $stagedDirectory = Split-Path $stagedPath -Parent
            if (-not (Test-Path $stagedDirectory)) {
                New-Item -ItemType Directory -Path $stagedDirectory -Force | Out-Null
            }

            $encodedPath = (($manifestPath -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
            $fileUrl = "$apiBaseUrl/api/agent/windows/files/$encodedPath"

            Invoke-WebRequest -Uri $fileUrl -Method Get -Headers $headers -OutFile $stagedPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop

            $expectedHash = if ($file.PSObject.Properties['sha256']) { [string]$file.sha256 } else { '' }
            $actualHash = (Get-FileHash -Path $stagedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
                throw "Checksum mismatch for $manifestPath"
            }

            $destinationPath = Join-Path $script:OpenPathRoot $nativeRelativePath
            $backupPath = Join-Path $backupRoot $nativeRelativePath
            $downloadedFiles += [PSCustomObject]@{
                RelativePath   = $relativePath
                StagedPath     = $stagedPath
                DestinationPath = $destinationPath
                BackupPath     = $backupPath
                ExpectedSha256 = $expectedHash.ToLowerInvariant()
            }
        }

        # Validate the staged tree before the first installed file changes. A
        # parse failure leaves the previous version running untouched.
        $stagedValidation = Test-OpenPathAgentUpdateStagedArtifacts -StagingRoot $stagingRoot
        if (-not $stagedValidation.Healthy) {
            $failureStage = 'validation'
            $failureTimedOut = [bool]$stagedValidation.TimedOut
            throw "Self-update staged artifact validation failed: $($stagedValidation.Message)"
        }

        # Back up every installed file this run will replace, and record the
        # pre-update hash, before the journal exists and before any file
        # changes. Rollback never reads a backup from another run.
        Save-OpenPathAgentUpdateInstalledFileBackups -Files $downloadedFiles
        Write-OpenPathAgentUpdateJsonFile -Path (Join-Path $backupRoot 'manifest.json') -Object $manifest

        # A committed journal on disk belongs to an earlier update that passed
        # the gate but could not finish. Keep it byte-for-byte before this run
        # replaces the journal, so a complete rollback restores the pending
        # finalization instead of losing it.
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            $journalBeforeReplacement = $null
            try {
                $journalBeforeReplacement = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $journalBeforeReplacement = $null
            }

            if ($journalBeforeReplacement) {
                $schemaVersionBeforeReplacement = 0
                [void][int]::TryParse([string]$journalBeforeReplacement.schemaVersion, [ref]$schemaVersionBeforeReplacement)
                if ($schemaVersionBeforeReplacement -eq 2 -and [string]$journalBeforeReplacement.phase -eq 'committed') {
                    Save-OpenPathAgentUpdateSupersededJournal `
                        -OpenPathRoot $script:OpenPathRoot `
                        -JournalPath $journalPath
                }
            }
        }

        $updateJournal = [PSCustomObject]@{
            schemaVersion   = 2
            phase           = 'replacing'
            runId           = $runId
            durable         = $true
            targetVersion   = $targetVersion
            targetBuild     = $targetBuild
            previousVersion = $currentVersion
            previousBuild   = $currentBuild
            backupRoot      = $backupRoot
            createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            files           = @(
                $downloadedFiles | ForEach-Object {
                    [PSCustomObject]@{
                        relativePath   = $_.RelativePath
                        existedBefore  = [bool]$_.HadExistingFile
                        previousSha256 = [string]$_.PreviousSha256
                        sha256         = [string]$_.ExpectedSha256
                        unchanged      = [bool]$_.Unchanged
                    }
                }
            )
        }
        # The intent is written and flushed first. If the journal itself is lost
        # or zero-filled by a power cut, recovery can still prove which files
        # this run was about to replace and roll them back.
        $intentPath = Get-OpenPathAgentUpdateJournalIntentPath -BackupRoot $backupRoot
        Write-OpenPathAgentUpdateJsonFile -Path $intentPath -Object $updateJournal
        Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot -Journal $updateJournal | Out-Null

        $replacementStarted = $true
        foreach ($download in $downloadedFiles) {
            if ([bool]$download.Unchanged) {
                continue
            }

            $destinationDir = Split-Path $download.DestinationPath -Parent
            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }

            $enforceSignature = ($env:OPENPATH_SELFUPDATE_REQUIRE_SIGNATURE -eq '1')
            if ($enforceSignature -and ($download.StagedPath -match '\.psm?1$')) {
                $sig = Get-AuthenticodeSignature -FilePath $download.StagedPath
                if ($sig.Status -ne 'Valid') {
                    throw "Self-update artifact failed Authenticode verification: $($download.RelativePath) ($($sig.Status))"
                }
            }

            $tempDestinationPath = "$($download.DestinationPath).openpath-update-$runId.tmp"
            $copiedHash = Copy-OpenPathAgentUpdateFileDurable `
                -SourcePath $download.StagedPath `
                -DestinationPath $tempDestinationPath
            if (-not [string]::Equals($copiedHash, [string]$download.ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $tempDestinationPath -Force -ErrorAction SilentlyContinue
                throw "Staged copy checksum mismatch for $($download.RelativePath)"
            }
            Move-OpenPathAgentUpdateFileIntoPlace `
                -TempPath $tempDestinationPath `
                -DestinationPath $download.DestinationPath
        }

        foreach ($download in $downloadedFiles) {
            $manifestEntry = @($manifestFiles | Where-Object { ([string]$_.path -replace '/', '\') -eq $download.RelativePath })[0]
            $expectedHash = if ($manifestEntry -and $manifestEntry.PSObject.Properties['sha256']) { [string]$manifestEntry.sha256 } else { '' }
            $actualHash = (Get-FileHash -Path $download.DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
                throw "Post-replacement checksum mismatch for $($download.RelativePath)"
            }
        }

        Update-OpenPathAgentUpdateJournalPhase -OpenPathRoot $script:OpenPathRoot -Journal $updateJournal -Phase 'validating'

        # The new code has not executed yet. Load it in a fresh Windows
        # PowerShell process exactly as the scheduled tasks do, and only commit
        # the version after that process proves the commands exist.
        $healthGate = Invoke-OpenPathAgentUpdateHealthGate -OpenPathRoot $script:OpenPathRoot
        if (-not $healthGate.Healthy) {
            $failureStage = 'gate'
            $failureTimedOut = [bool]$healthGate.TimedOut
            throw "Self-update health gate failed: $($healthGate.Message)"
        }

        # The new tree passed the gate. Any earlier timeout streak belonged to
        # an unproven build and must not make a later timeout block this one.
        try {
            Clear-OpenPathAgentUpdateTimeoutState -OpenPathRoot $script:OpenPathRoot
        }
        catch {
            Write-SelfUpdateMessage -Message "Could not clear the update timeout state: $_" -Level WARN
        }

        # The gate is the commit point. Persist the marker first; from here a
        # failure of the journal write is a finalization failure, not a rollback.
        $markerPath = Write-OpenPathAgentUpdateCommittedMarker `
            -BackupRoot $backupRoot `
            -RunId $runId `
            -TargetVersion $targetVersion `
            -TargetBuild $targetBuild
        $updateCommitted = $true
        Update-OpenPathAgentUpdateJournalPhase -OpenPathRoot $script:OpenPathRoot -Journal $updateJournal -Phase 'committed'

        $finalization = Complete-OpenPathAgentUpdateFinalization `
            -OpenPathRoot $script:OpenPathRoot `
            -Journal $updateJournal `
            -Config $config
        if (-not $finalization.Success) {
            $message = "Agent self-update finalization failed: $($finalization.Message)"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }

        $message = "Agent self-update applied successfully: $currentVersion -> $targetVersion"
        Write-SelfUpdateMessage -Message $message
        return [PSCustomObject]@{
            Success = $true
            Updated = $true
            CurrentVersion = $currentVersion
            TargetVersion = $targetVersion
            Message = $message
        }
    }
    catch {
        $failureMessage = [string]$_

        # Commit evidence is on disk, not only in this process: the marker is
        # written before the committed journal. If it exists for this run, the
        # tree passed the gate and must never be rolled back.
        if (-not $updateCommitted -and $runBackupRoot -and $runId) {
            $markerPath = Get-OpenPathAgentUpdateCommittedMarkerPath -BackupRoot $runBackupRoot
            $marker = Read-OpenPathAgentUpdateCommittedMarker -MarkerPath $markerPath -RunId $runId
            if ($marker) {
                $updateCommitted = $true
                if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
                    try {
                        $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                        if ([int]$journalOnDisk.schemaVersion -eq 2 -and [string]$journalOnDisk.phase -ne 'committed') {
                            $journalOnDisk.phase = 'committed'
                            $journalOnDisk.updatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                            Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot -Journal $journalOnDisk | Out-Null
                        }
                    }
                    catch {
                        Write-SelfUpdateMessage -Message "Could not promote the journal after finding the commit marker: $_" -Level WARN
                    }
                }
                Write-SelfUpdateMessage -Message 'Commit marker found; files are not rolled back' -Level WARN
            }
        }

        if ($updateCommitted) {
            # The tree passed the gate. A finalization failure keeps the
            # committed journal for the next attempt and never rolls back.
            Send-OpenPathAgentUpdateFinalizationFailureReport `
                -Version $targetVersion `
                -Build $targetBuild `
                -Message $failureMessage
            $message = "Agent self-update finalization failed: $failureMessage"
            Write-SelfUpdateMessage -Message $message -Level ERROR
            return [PSCustomObject]@{
                Success = $false
                Updated = $false
                Message = $message
            }
        }

        $journalRollbackComplete = $true
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            try {
                $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ([int]$journalOnDisk.schemaVersion -ne 2) {
                    $journalRollbackComplete = $false
                    Write-SelfUpdateMessage -Message "Cannot roll back a journal with unsupported schemaVersion $($journalOnDisk.schemaVersion)" -Level ERROR
                }
                elseif ([string]$journalOnDisk.phase -eq 'committed') {
                    $journalRollbackComplete = $false
                    Write-SelfUpdateMessage -Message 'Update is committed; files are not rolled back' -Level WARN
                }
                else {
                    $journalRollback = Restore-OpenPathAgentUpdateJournalBackups -OpenPathRoot $script:OpenPathRoot -Journal $journalOnDisk
                    $journalRollbackComplete = [bool]$journalRollback.Complete
                    foreach ($rollbackError in @($journalRollback.Errors)) {
                        if ($rollbackError) {
                            Write-SelfUpdateMessage -Message "Journal rollback: $rollbackError" -Level WARN
                        }
                    }
                }
            }
            catch {
                $journalRollbackComplete = $false
                Write-SelfUpdateMessage -Message "Could not read update journal for rollback: $_" -Level ERROR
            }
        }
        elseif ($replacementStarted) {
            $journalRollbackComplete = $false
            Write-SelfUpdateMessage -Message 'Update journal is missing; rollback cannot be verified' -Level ERROR
        }

        if ($journalRollbackComplete) {
            $supersededRestore = Restore-OpenPathAgentUpdateSupersededJournal -OpenPathRoot $script:OpenPathRoot
            if (-not $supersededRestore.Present) {
                if (Test-Path -LiteralPath $journalPath) {
                    Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
                }
            }
            elseif ($supersededRestore.Moved) {
                Write-SelfUpdateMessage -Message 'Put the superseded update journal back after the complete rollback'
            }
            elseif ($supersededRestore.Quarantined) {
                # The unusable superseded journal is quarantined; remove the
                # rolled-back journal as before.
                if (Test-Path -LiteralPath $journalPath) {
                    Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                Write-SelfUpdateMessage -Message "Kept the rolled-back journal because the superseded journal could not be restored: $($supersededRestore.Error)" -Level ERROR
            }
        }

        if ($failureStage -eq 'gate') {
            try {
                $restoredGate = Invoke-OpenPathAgentUpdateHealthGate -OpenPathRoot $script:OpenPathRoot
                if (-not $restoredGate.Healthy) {
                    Write-SelfUpdateMessage -Message "Restored agent tree failed the health gate: $($restoredGate.Message)" -Level ERROR
                }
            }
            catch {
                Write-SelfUpdateMessage -Message "Could not verify the restored agent tree: $_" -Level ERROR
            }
        }

        if ($failureStage) {
            $recordFailure = $true
            if ($failureTimedOut) {
                try {
                    $timeout = Register-OpenPathAgentUpdateTimeout `
                        -OpenPathRoot $script:OpenPathRoot `
                        -Version $targetVersion `
                        -Build $targetBuild `
                        -Stage $failureStage `
                        -Message $failureMessage
                    $recordFailure = ([int]$timeout.Count -ge 3)
                    if (-not $recordFailure) {
                        Write-SelfUpdateMessage -Message "Self-update $failureStage timeout $($timeout.Count) of 3; leaving the build eligible for the next retry" -Level WARN
                    }
                }
                catch {
                    # A timeout is not proof that the build is bad. If the
                    # streak cannot be persisted, keep retrying rather than
                    # turning this attempt into a seven-day block.
                    $recordFailure = $false
                    Write-SelfUpdateMessage -Message "Could not record the update timeout streak: $_" -Level WARN
                }
            }
            else {
                try {
                    Clear-OpenPathAgentUpdateTimeoutState -OpenPathRoot $script:OpenPathRoot
                }
                catch {
                    Write-SelfUpdateMessage -Message "Could not clear the update timeout state: $_" -Level WARN
                }
            }

            if ($recordFailure) {
                try {
                    Save-OpenPathAgentUpdateFailureRecord `
                        -OpenPathRoot $script:OpenPathRoot `
                        -Version $targetVersion `
                        -Build $targetBuild `
                        -Stage $failureStage `
                        -Message $failureMessage
                }
                catch {
                    Write-SelfUpdateMessage -Message "Could not record the failed build: $_" -Level WARN
                }
            }

            Send-OpenPathAgentUpdateFailureReport `
                -Stage $failureStage `
                -Version $targetVersion `
                -Build $targetBuild `
                -CurrentVersion $currentVersion `
                -Message $failureMessage
        }

        $message = "Self-update failed: $failureMessage"
        Write-SelfUpdateMessage -Message $message -Level ERROR
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }
    finally {
        if ($runBackupRoot -and -not $updateCommitted) {
            try {
                Remove-OpenPathAgentUpdateRunBackupDirectory -OpenPathRoot $script:OpenPathRoot -BackupRoot $runBackupRoot
            }
            catch {
                try {
                    Write-OpenPathLog "Self-update: could not remove the failed run backup directory: $_" -Level WARN
                }
                catch {
                    # Cleanup must never change the update outcome.
                }
            }
        }
        Exit-OpenPathAgentUpdateLock -Lock $updateLock
    }
}
