$script:OpenPathAgentUpdateLockName = 'Global\OpenPathAgentUpdateLock'

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

function Get-OpenPathAgentUpdateRecoveryReportPath {
    param([string]$OpenPathRoot = $script:OpenPathRoot)

    return (Join-Path (Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot) 'recovery-report.json')
}

function Write-OpenPathAgentUpdateJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Object
    )

    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Object | ConvertTo-Json -Depth 10
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($temporaryPath, $json, $encoding)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
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

    return (($Now - $failedAt).TotalDays -lt 7)
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
                    Healthy = $false
                    Message = "Staged artifact validation timed out after $TimeoutSeconds seconds"
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
                    Healthy = $false
                    Message = $firstLine
                }
            }

            return [PSCustomObject]@{
                Healthy = $true
                Message = ''
            }
        }
        catch {
            return [PSCustomObject]@{
                Healthy = $false
                Message = "Staged artifact validation could not run: $_"
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
            Healthy = $false
            Message = [string]$failures[0]
        }
    }

    return [PSCustomObject]@{
        Healthy = $true
        Message = ''
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

function Restore-OpenPathAgentUpdateJournalBackups {
    <#
    .SYNOPSIS
        Rolls back every file named by an update journal
    #>
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,
        [Parameter(Mandatory = $true)][object]$Journal
    )

    $complete = $true
    $errors = New-Object System.Collections.ArrayList
    $updateRoot = Get-OpenPathAgentUpdateRoot -OpenPathRoot $OpenPathRoot
    $allowedBackupRoot = [System.IO.Path]::GetFullPath((Join-Path $updateRoot 'backups'))
    $backupRoot = [string]$Journal.backupRoot

    if ([string]::IsNullOrWhiteSpace($backupRoot)) {
        return [PSCustomObject]@{ Complete = $false; Errors = @('Journal has no backup root') }
    }

    $resolvedBackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
    if (-not $resolvedBackupRoot.StartsWith($allowedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ Complete = $false; Errors = @("Backup root is outside the update directory: $backupRoot") }
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
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    $destinationDirectory = Split-Path $destinationPath -Parent
                    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $backupPath -Destination $destinationPath -Force -ErrorAction Stop
                    $restoredHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($restoredHash -ne $backupHash) {
                        [void]$errors.Add("Restored file does not match backup: $relativePath")
                        $complete = $false
                    }
                }
                elseif (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                    [void]$errors.Add("Missing file and backup: $relativePath")
                    $complete = $false
                }
            }
            else {
                if (Test-Path -LiteralPath $destinationPath) {
                    Remove-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
                }
                if (Test-Path -LiteralPath $destinationPath) {
                    [void]$errors.Add("Could not remove new file: $relativePath")
                    $complete = $false
                }
            }
        }
        catch {
            [void]$errors.Add("Rollback failed for ${relativePath}: $_")
            $complete = $false
        }
    }

    return [PSCustomObject]@{
        Complete = $complete
        Errors   = @($errors.ToArray())
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

    $apiUrl = if ($config.PSObject.Properties['apiUrl']) { [string]$config.apiUrl } else { '' }
    $whitelistUrl = if ($config.PSObject.Properties['whitelistUrl']) { [string]$config.whitelistUrl } else { '' }
    $currentVersion = if ($config.PSObject.Properties['version'] -and $config.version) {
        [string]$config.version
    }
    else {
        '0.0.0'
    }

    if (-not $apiUrl -or -not $whitelistUrl) {
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
        $message = "Manifest download failed: $_"
        Write-SelfUpdateMessage -Message $message -Level WARN
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }

    if (-not $manifest -or -not $manifest.version -or -not $manifest.files) {
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
    if (-not $updateNeeded) {
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
    if ($failureRecord -and (Test-OpenPathAgentUpdateFailureMatchesTarget -Record $failureRecord -TargetVersion $targetVersion -TargetBuild $targetBuild)) {
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
        }
        catch {
            Write-SelfUpdateMessage -Message "Could not clear the failed-build record: $_" -Level WARN
        }
    }
    elseif ($failureRecord) {
        try {
            Clear-OpenPathAgentUpdateFailureRecord -OpenPathRoot $script:OpenPathRoot
        }
        catch {
            Write-SelfUpdateMessage -Message "Could not clear the failed-build record: $_" -Level WARN
        }
    }

    $updateLock = $null
    $replacementBackups = @()
    $updateJournal = $null
    $failureStage = $null
    $updateCommitted = $false
    $journalPath = Get-OpenPathAgentUpdateJournalPath -OpenPathRoot $script:OpenPathRoot

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

        $manifestFiles = @($manifest.files)
        if ($manifestFiles.Count -eq 0) {
            throw 'Manifest did not include files to update'
        }

        # data\agent-update holds the update journal, per-version backups and
        # the staged download tree.
        $updateRoot = Join-Path (Join-Path $script:OpenPathRoot 'data') 'agent-update'
        $stagingRoot = Join-Path $updateRoot ("staging-$targetVersion")
        $backupRoot = Join-Path (Join-Path $updateRoot 'backups') $currentVersion

        if (Test-Path $stagingRoot) {
            Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $backupRoot 'manifest.json') -Encoding UTF8 -Force

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
            throw "Self-update staged artifact validation failed: $($stagedValidation.Message)"
        }

        foreach ($download in $downloadedFiles) {
            $download | Add-Member -NotePropertyName HadExistingFile -NotePropertyValue ([bool](Test-Path -LiteralPath $download.DestinationPath)) -Force
        }

        $updateJournal = [PSCustomObject]@{
            schemaVersion   = 1
            phase           = 'replacing'
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
                        relativePath  = $_.RelativePath
                        existedBefore = [bool]$_.HadExistingFile
                        sha256        = [string]$_.ExpectedSha256
                    }
                }
            )
        }
        Write-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot -Journal $updateJournal | Out-Null

        foreach ($download in $downloadedFiles) {
            $destinationDir = Split-Path $download.DestinationPath -Parent
            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }

            $backupDir = Split-Path $download.BackupPath -Parent
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }

            $enforceSignature = ($env:OPENPATH_SELFUPDATE_REQUIRE_SIGNATURE -eq '1')
            if ($enforceSignature -and ($download.StagedPath -match '\.psm?1$')) {
                $sig = Get-AuthenticodeSignature -FilePath $download.StagedPath
                if ($sig.Status -ne 'Valid') {
                    throw "Self-update artifact failed Authenticode verification: $($download.RelativePath) ($($sig.Status))"
                }
            }

            $hadExistingFile = [bool]$download.HadExistingFile
            if ($hadExistingFile) {
                Copy-Item -Path $download.DestinationPath -Destination $download.BackupPath -Force -ErrorAction Stop
            }

            $tempDestinationPath = "$($download.DestinationPath).openpath-update-$([guid]::NewGuid()).tmp"
            Copy-Item -Path $download.StagedPath -Destination $tempDestinationPath -Force -ErrorAction Stop
            Move-Item -Path $tempDestinationPath -Destination $download.DestinationPath -Force -ErrorAction Stop

            $replacementBackups += [PSCustomObject]@{
                DestinationPath = $download.DestinationPath
                BackupPath = $download.BackupPath
                HadExistingFile = [bool]$hadExistingFile
            }
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
            throw "Self-update health gate failed: $($healthGate.Message)"
        }

        if ($config.PSObject.Properties['version']) {
            $config.version = $targetVersion
        }
        else {
            $config | Add-Member -NotePropertyName version -NotePropertyValue $targetVersion
        }

        if ($targetBuild) {
            if ($config.PSObject.Properties['agentBuild']) {
                $config.agentBuild = $targetBuild
            }
            else {
                $config | Add-Member -NotePropertyName agentBuild -NotePropertyValue $targetBuild
            }
        }

        $updatedAt = Get-Date -Format 'o'
        if ($config.PSObject.Properties['lastAgentUpdateAt']) {
            $config.lastAgentUpdateAt = $updatedAt
        }
        else {
            $config | Add-Member -NotePropertyName lastAgentUpdateAt -NotePropertyValue $updatedAt
        }

        Set-OpenPathConfig -Config $config | Out-Null

        $updateInterval = 5
        if ($config.PSObject.Properties['updateIntervalMinutes']) {
            try {
                $candidate = [int]$config.updateIntervalMinutes
                if ($candidate -ge 1) {
                    $updateInterval = $candidate
                }
            }
            catch {
                # Keep default
            }
        }

        $watchdogInterval = 1
        if ($config.PSObject.Properties['watchdogIntervalMinutes']) {
            try {
                $candidate = [int]$config.watchdogIntervalMinutes
                if ($candidate -ge 1) {
                    $watchdogInterval = $candidate
                }
            }
            catch {
                # Keep default
            }
        }

        if (Get-Command -Name 'Register-OpenPathTask' -ErrorAction SilentlyContinue) {
            Register-OpenPathTask -OpenPathRoot $script:OpenPathRoot -UpdateIntervalMinutes $updateInterval -WatchdogIntervalMinutes $watchdogInterval | Out-Null
        }
        if (Get-Command -Name 'Enable-OpenPathTask' -ErrorAction SilentlyContinue) {
            Enable-OpenPathTask | Out-Null
        }
        if (Get-Command -Name 'Invoke-OpenPathFirefoxNativeHostCompiledEnsure' -ErrorAction SilentlyContinue) {
            # Phase 5.2 D2: compile/refresh before the registration decides which
            # launch path the Firefox manifest should carry.
            try { Invoke-OpenPathFirefoxNativeHostCompiledEnsure -Config $config | Out-Null } catch { }
        }
        if (Get-Command -Name 'Register-OpenPathFirefoxNativeHost' -ErrorAction SilentlyContinue) {
            Register-OpenPathFirefoxNativeHost -Config $config -PreserveExistingOnNotReady | Out-Null
        }
        if (Get-Command -Name 'Restore-OpenPathProtectedMode' -ErrorAction SilentlyContinue) {
            Restore-OpenPathProtectedMode -Config $config | Out-Null
        }
        elseif (Get-Command -Name 'Restart-AcrylicService' -ErrorAction SilentlyContinue) {
            Restart-AcrylicService | Out-Null
        }
        if (Get-Command -Name 'Start-OpenPathTask' -ErrorAction SilentlyContinue) {
            Start-OpenPathTask -TaskType SSE | Out-Null
        }

        # Refresh the integrity backup and baseline only now, still under the
        # update lock: a backup taken before the replacement holds the old
        # files, and the watchdog would restore them over the new version.
        Save-OpenPathIntegrityBackup | Out-Null
        New-OpenPathIntegrityBaseline | Out-Null

        Update-OpenPathAgentUpdateJournalPhase -OpenPathRoot $script:OpenPathRoot -Journal $updateJournal -Phase 'committed'
        $updateCommitted = $true
        try {
            Remove-OpenPathAgentUpdateJournal -OpenPathRoot $script:OpenPathRoot
            Clear-OpenPathAgentUpdateFailureRecord -OpenPathRoot $script:OpenPathRoot
        }
        catch {
            Write-SelfUpdateMessage -Message "Update committed but cleanup failed: $_" -Level WARN
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
        $journalRollbackComplete = $true

        if (-not $updateCommitted -and (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            try {
                $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ([string]$journalOnDisk.phase -eq 'committed') {
                    Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
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

        if (-not $updateCommitted) {
            foreach ($replacement in @($replacementBackups | Sort-Object { $_.DestinationPath.Length } -Descending)) {
                try {
                    if ($replacement.HadExistingFile -and (Test-Path $replacement.BackupPath)) {
                        Copy-Item -Path $replacement.BackupPath -Destination $replacement.DestinationPath -Force -ErrorAction Stop
                    }
                    elseif (-not $replacement.HadExistingFile -and (Test-Path $replacement.DestinationPath)) {
                        Remove-Item -Path $replacement.DestinationPath -Force -ErrorAction Stop
                    }
                }
                catch {
                    Write-SelfUpdateMessage -Message "Rollback failed for $($replacement.DestinationPath): $_" -Level ERROR
                }
            }
        }

        if (-not $updateCommitted -and $journalRollbackComplete -and (Test-Path -LiteralPath $journalPath)) {
            Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
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
        Exit-OpenPathAgentUpdateLock -Lock $updateLock
    }
}
