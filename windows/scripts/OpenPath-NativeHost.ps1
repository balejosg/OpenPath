# OpenPath Native Messaging Host for Windows
# Runs under the logged-in Firefox user context and reads only the
# browser-readable mirror staged beneath C:\OpenPath\browser-extension\firefox\native.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

$script:NativeRoot = Split-Path -Parent $PSCommandPath

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
$script:LogPath = Join-Path $script:NativeRoot 'native-host.log'
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
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logDir = Split-Path $script:LogPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $logBytes = [System.Text.Encoding]::UTF8.GetBytes("[$timestamp] $Message$([Environment]::NewLine)")
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

Write-NativeHostLog 'Native host started'

while ($true) {
    try {
        $message = Read-NativeMessage
        if ($null -eq $message) {
            break
        }

        $response = Handle-Message -Message $message
        Write-NativeMessage -Message $response
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
