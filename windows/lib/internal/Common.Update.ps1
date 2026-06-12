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
    $comparison = Compare-OpenPathVersion -CurrentVersion $currentVersion -TargetVersion $targetVersion
    if ($comparison -ge 0) {
        $message = "Agent already up to date (current=$currentVersion)"
        Write-SelfUpdateMessage -Message $message
        return [PSCustomObject]@{
            Success = $true
            Updated = $false
            CurrentVersion = $currentVersion
            TargetVersion = $targetVersion
            Message = $message
        }
    }

    $updateAvailableMessage = "Agent update available: $currentVersion -> $targetVersion"
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

    $mutex = $null
    $lockAcquired = $false
    $replacementBackups = @()

    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\OpenPathAgentUpdateLock')
        try {
            $lockAcquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
            Write-SelfUpdateMessage -Message 'Update lock was abandoned by previous process, continuing' -Level WARN
        }

        if (-not $lockAcquired) {
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

        $updateRoot = Join-Path $script:OpenPathRoot 'data\agent-update'
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

            $stagedPath = Join-Path $stagingRoot $relativePath
            $stagedDirectory = Split-Path $stagedPath -Parent
            if (-not (Test-Path $stagedDirectory)) {
                New-Item -ItemType Directory -Path $stagedDirectory -Force | Out-Null
            }

            $encodedPath = (($manifestPath -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
            $fileUrl = "$apiBaseUrl/api/agent/windows/files/$encodedPath"

            Invoke-WebRequest -Uri $fileUrl -Method Get -Headers $headers -OutFile $stagedPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop

            $expectedHash = if ($file.PSObject.Properties['sha256']) { [string]$file.sha256 } else { '' }
            if ($expectedHash) {
                $actualHash = (Get-FileHash -Path $stagedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
                    throw "Checksum mismatch for $manifestPath"
                }
            }

            $destinationPath = Join-Path $script:OpenPathRoot $relativePath
            $backupPath = Join-Path $backupRoot $relativePath
            $downloadedFiles += [PSCustomObject]@{
                RelativePath = $relativePath
                StagedPath = $stagedPath
                DestinationPath = $destinationPath
                BackupPath = $backupPath
            }
        }

        Save-OpenPathIntegrityBackup | Out-Null

        foreach ($download in $downloadedFiles) {
            $destinationDir = Split-Path $download.DestinationPath -Parent
            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }

            $backupDir = Split-Path $download.BackupPath -Parent
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }

            $hadExistingFile = Test-Path $download.DestinationPath
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
            if ($expectedHash) {
                $actualHash = (Get-FileHash -Path $download.DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
                    throw "Post-replacement checksum mismatch for $($download.RelativePath)"
                }
            }
        }

        if ($config.PSObject.Properties['version']) {
            $config.version = $targetVersion
        }
        else {
            $config | Add-Member -NotePropertyName version -NotePropertyValue $targetVersion
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
            Register-OpenPathTask -UpdateIntervalMinutes $updateInterval -WatchdogIntervalMinutes $watchdogInterval | Out-Null
        }
        if (Get-Command -Name 'Enable-OpenPathTask' -ErrorAction SilentlyContinue) {
            Enable-OpenPathTask | Out-Null
        }
        if (Get-Command -Name 'Register-OpenPathFirefoxNativeHost' -ErrorAction SilentlyContinue) {
            Register-OpenPathFirefoxNativeHost -Config $config | Out-Null
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

        New-OpenPathIntegrityBaseline | Out-Null

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
        $message = "Self-update failed: $_"
        Write-SelfUpdateMessage -Message $message -Level ERROR
        return [PSCustomObject]@{
            Success = $false
            Updated = $false
            Message = $message
        }
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # Ignore if mutex ownership changed unexpectedly
            }
        }
        if ($mutex) {
            $mutex.Dispose()
        }
    }
}
