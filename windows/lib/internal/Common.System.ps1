function Test-AdminPrivileges {
    <#
    .SYNOPSIS
        Checks if script is running with administrator privileges
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-OpenPathLogRotation {
    <#
    .SYNOPSIS
        Rotates openpath.log when it exceeds the configured size threshold.
        Shifts existing numbered archives up and drops any beyond the keep count.
        Rotation failure is non-fatal: the caller falls back to appending.
    .PARAMETER LogPath
        Full path to the active log file (e.g. C:\OpenPath\data\logs\openpath.log).
    .PARAMETER MaxSizeBytes
        Rotate when the log file exceeds this size in bytes.
    .PARAMETER KeepFiles
        Number of rotated archives to retain (oldest are deleted).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [Parameter(Mandatory = $true)]
        [long]$MaxSizeBytes,

        [Parameter(Mandatory = $true)]
        [int]$KeepFiles
    )

    if (-not (Test-Path $LogPath)) {
        return
    }

    $fileInfo = Get-Item $LogPath -ErrorAction SilentlyContinue
    if (-not $fileInfo -or $fileInfo.Length -le $MaxSizeBytes) {
        return
    }

    # Shift archives: openpath.log.N -> openpath.log.N+1 (the move onto .KeepFiles overwrites the oldest)
    for ($i = $KeepFiles - 1; $i -ge 1; $i--) {
        $src = "$LogPath.$i"
        $dst = "$LogPath.$($i + 1)"
        if (Test-Path $src) {
            Move-Item $src $dst -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove the overflow archive if it slipped through
    $overflow = "$LogPath.$($KeepFiles + 1)"
    if (Test-Path $overflow) {
        Remove-Item $overflow -Force -ErrorAction SilentlyContinue
    }

    # Rotate active log to .1
    Move-Item $LogPath "$LogPath.1" -Force -ErrorAction SilentlyContinue
}

function Write-OpenPathLog {
    <#
    .SYNOPSIS
        Writes a log entry to the openpath log file
    .PARAMETER Message
        The message to log
    .PARAMETER Level
        Log level: INFO, WARN, ERROR
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Identify calling script for structured logging
    $callerInfo = Get-PSCallStack | Select-Object -Skip 1 -First 1
    $callerScript = if ($callerInfo -and $callerInfo.ScriptName) {
        Split-Path $callerInfo.ScriptName -Leaf
    }
    else {
        "unknown"
    }

    $logEntry = "$timestamp [$Level] [$callerScript] [PID:$PID] $Message"

    # Ensure log directory exists
    $logDir = Split-Path $script:LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Rotate log if it exceeds the configured size threshold (non-fatal)
    try {
        $config = $null
        if (Test-Path $script:ConfigPath) {
            $config = Get-Content $script:ConfigPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        $maxSizeMb = [int](Get-OpenPathConfigValue -Config $config -Name 'logMaxSizeMb' -DefaultValue 5)
        $keepFiles = [int](Get-OpenPathConfigValue -Config $config -Name 'logKeepFiles' -DefaultValue 3)
        if ($maxSizeMb -lt 1) { $maxSizeMb = 5 }
        if ($keepFiles -lt 1) { $keepFiles = 3 }
        Invoke-OpenPathLogRotation -LogPath $script:LogPath -MaxSizeBytes ($maxSizeMb * 1MB) -KeepFiles $keepFiles
    }
    catch {
        # Rotation failure must never break logging.
    }

    $logBytes = [System.Text.Encoding]::UTF8.GetBytes("$logEntry$([Environment]::NewLine)")
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open(
                $script:LogPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            $stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            $stream.Write($logBytes, 0, $logBytes.Length)
            break
        }
        catch {
            if ($attempt -eq 5) {
                Write-Warning "OpenPath log write failed after $attempt attempts: $_"
            }
            else {
                Start-Sleep -Milliseconds (50 * $attempt)
            }
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }

    if ($env:OPENPATH_QUIET_INSTALL -eq '1' -and $Level -ne "ERROR") {
        return
    }

    switch ($Level) {
        "ERROR" { Write-Error $logEntry -ErrorAction Continue }
        "WARN" { Write-Warning $logEntry }
        default { Write-Information $logEntry -InformationAction Continue }
    }
}

function Get-OpenPathFileAgeHours {
    <#
    .SYNOPSIS
        Returns file age in hours since last write time
    .PARAMETER Path
        Full file path
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return [double]::PositiveInfinity
    }

    try {
        $file = Get-Item $Path -ErrorAction Stop
        $age = (New-TimeSpan -Start $file.LastWriteTimeUtc -End (Get-Date).ToUniversalTime()).TotalHours
        return [Math]::Max([Math]::Round($age, 2), 0)
    }
    catch {
        return [double]::PositiveInfinity
    }
}
