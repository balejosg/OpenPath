# OpenPath Native Messaging Host for Windows
# Runs under the logged-in Firefox user context and reads only the
# browser-readable mirror staged beneath C:\OpenPath\browser-extension\firefox\native.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

$script:NativeRoot = Split-Path -Parent $PSCommandPath
$script:NativeHostStartStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:NativeHostProcessStart = $null
try {
    $script:NativeHostProcessStart = (Get-Process -Id $PID -ErrorAction Stop).StartTime
}
catch {
    $script:NativeHostProcessStart = $null
}

function Resolve-OpenPathNativeHostLogPath {
    # resolves the per-user writable log path; the staged native directory is
    # read-only for the browser user, so logging there silently failed before.
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = $env:TEMP
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        return (Join-Path $script:NativeRoot 'native-host.log')
    }
    return (Join-Path (Join-Path $base 'OpenPath') 'native-host.log')
}

function Resolve-OpenPathNativeHostRoot {
    $stagedStateHelperPath = Join-Path $script:NativeRoot 'NativeHost.State.ps1'
    if (Test-Path $stagedStateHelperPath -ErrorAction SilentlyContinue) {
        return [System.IO.Path]::GetFullPath((Join-Path $script:NativeRoot '..\..\..'))
    }

    $candidateRoots = @(
        (Join-Path $PSScriptRoot '..'),
        (Join-Path $PSScriptRoot '..\..\..')
    )

    foreach ($candidateRoot in $candidateRoots) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($candidateRoot)
        $stateHelperPath = Join-Path $resolvedRoot 'lib\internal\NativeHost.State.ps1'
        if (Test-Path $stateHelperPath -ErrorAction SilentlyContinue) {
            return $resolvedRoot
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
}

function Resolve-OpenPathNativeHostSupportPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $candidatePaths = @(
        (Join-Path $script:NativeRoot $FileName),
        (Join-Path $script:OpenPathRoot "lib\internal\$FileName")
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path $candidatePath -ErrorAction SilentlyContinue) {
            return $candidatePath
        }
    }

    throw "OpenPath native host support file not found: $FileName"
}

$script:OpenPathRoot = Resolve-OpenPathNativeHostRoot
$script:StatePath = Join-Path $script:NativeRoot 'native-state.json'
$script:WhitelistPath = Join-Path $script:NativeRoot 'whitelist.txt'
$script:LogPath = Resolve-OpenPathNativeHostLogPath
$script:LogMaxBytes = 262144
$script:UpdateTaskName = 'OpenPath-Update'
$script:RuntimeDependencyTaskName = 'OpenPath-RuntimeDependencyApply'
$script:MaxDomains = 50
$script:MaxMessageBytes = 1MB

$null = . (Resolve-OpenPathNativeHostSupportPath -FileName 'NativeHost.State.ps1')
$null = . (Resolve-OpenPathNativeHostSupportPath -FileName 'NativeHost.Protocol.ps1')
$null = . (Resolve-OpenPathNativeHostSupportPath -FileName 'NativeHost.Actions.ps1')

function Write-NativeHostLog {
    param(
        [string]$Message
    )

    try {
        # Never persist credentials: strip token query parameters and tokenized
        # whitelist paths before the line reaches disk.
        $safeMessage = [regex]::Replace([string]$Message, '(?i)(token=)[^&\s]+', '${1}<redacted>')
        $safeMessage = [regex]::Replace($safeMessage, '(?i)/w/[A-Za-z0-9._-]{8,}', '/w/<redacted>')

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $scriptElapsedMs = if ($script:NativeHostStartStopwatch) { $script:NativeHostStartStopwatch.ElapsedMilliseconds } else { 0 }
        $processElapsedMs = 0
        if ($script:NativeHostProcessStart) {
            try { $processElapsedMs = [int]([DateTime]::UtcNow - $script:NativeHostProcessStart.ToUniversalTime()).TotalMilliseconds } catch { $processElapsedMs = 0 }
        }
        $line = "[$timestamp] [+${scriptElapsedMs}ms script] [proc=${processElapsedMs}ms] $safeMessage$([Environment]::NewLine)"
        $logBytes = [System.Text.Encoding]::UTF8.GetBytes($line)

        $logDir = Split-Path $script:LogPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Size cap with a single rotation so the per-user log cannot grow without bound.
        try {
            $logInfo = New-Object System.IO.FileInfo($script:LogPath)
            if ($logInfo.Exists -and $logInfo.Length -ge $script:LogMaxBytes) {
                [System.IO.File]::Move($script:LogPath, "$($script:LogPath).1", $true)
            }
        }
        catch {
            # Rotation is best-effort; logging must continue regardless.
        }

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
                if ($attempt -lt 5) {
                    Start-Sleep -Milliseconds (50 * $attempt)
                }
            }
            finally {
                if ($null -ne $stream) {
                    $stream.Dispose()
                }
            }
        }
    }
    catch {
        # Logging must never break protocol handling.
    }
}

$script:NativeHostMessageCount = 0
Write-NativeHostLog "Native host initialization completed pid=$PID log=$script:LogPath"

while ($true) {
    try {
        $message = Read-NativeMessage
        if ($null -eq $message) {
            break
        }

        $script:NativeHostMessageCount = 1 + [int]$script:NativeHostMessageCount
        $messageAction = ''
        try { $messageAction = [string]$message.action } catch { }
        $messageStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $chattyAction = Test-NativeHostChattyAction -Action $messageAction
        if (-not $chattyAction) {
            Write-NativeHostStageLog -Stage 'message-received' -Fields @{ index = $script:NativeHostMessageCount; action = $messageAction }
        }

        $response = Handle-Message -Message $message
        Write-NativeMessage -Message $response
        $messageStopwatch.Stop()
        if ($chattyAction) {
            Write-NativeHostChattyActionLog -Action $messageAction
        }
        else {
            Write-NativeHostStageLog -Stage 'response-sent' -Fields @{ index = $script:NativeHostMessageCount; action = $messageAction; totalMs = [int]$messageStopwatch.ElapsedMilliseconds }
        }
    }
    catch {
        Write-NativeHostLog "Fatal protocol error: $_"
        try {
            Write-NativeMessage -Message @{
                success = $false
                error = [string]$_
            }
        }
        catch {
            break
        }
    }
}

Write-NativeHostLog "Native host process exiting pid=$PID"
