function Test-AdminPrivileges {
    <#
    .SYNOPSIS
        Checks if script is running with administrator privileges
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

    # Rotate log if it exceeds 5 MB
    $script:MaxLogSizeBytes = 5MB
    if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath -ErrorAction SilentlyContinue).Length -gt $script:MaxLogSizeBytes) {
        $archivePath = $script:LogPath -replace '\.log$', ".$(Get-Date -Format 'yyyyMMddHHmmss').log"
        Move-Item $script:LogPath $archivePath -Force -ErrorAction SilentlyContinue
        Get-ChildItem (Split-Path $script:LogPath) -Filter "openpath.*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
            Remove-Item -Force -ErrorAction SilentlyContinue
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
