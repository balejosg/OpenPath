function Set-AcrylicGlobalSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value
    )

    $escapedKey = [regex]::Escape($Key)
    $pattern = "(?m)^$escapedKey=.*$"
    $replacement = "$Key=$Value"
    if ($Content -match $pattern) { return ($Content -replace $pattern, $replacement) }

    $nextSection = [regex]::Match($Content, '(?m)^\[(?!GlobalSection\])[^]]+\]\s*$')
    if ($nextSection.Success) { return $Content.Insert($nextSection.Index, "$replacement`n") }

    return ($Content.TrimEnd() + "`n$replacement`n")
}

function Set-AcrylicAllowedAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Content -notmatch '(?m)^\[AllowedAddressesSection\]\s*$') {
        $Content = $Content.TrimEnd() + "`n`n[AllowedAddressesSection]`n"
    }

    $escapedKey = [regex]::Escape($Key)
    $pattern = "(?m)^$escapedKey=.*$"
    $replacement = "$Key=$Value"
    if ($Content -match $pattern) { return ($Content -replace $pattern, $replacement) }

    $allowedSection = [regex]::Match($Content, '(?m)^\[AllowedAddressesSection\]\s*$')
    if ($allowedSection.Success) { return $Content.Insert($allowedSection.Index + $allowedSection.Length, "`n$replacement") }

    return ($Content.TrimEnd() + "`n`n[AllowedAddressesSection]`n$replacement`n")
}

function Write-AcrylicPolicyLockFallbackWarning {
    param([string]$Reason = '')

    $message = 'Acrylic policy global mutex unavailable; using fallback file lock'
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $message = "$message ($Reason)"
    }

    if (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue) {
        Write-OpenPathLog $message -Level WARN
        return
    }

    Write-Warning $message
}

function Invoke-AcrylicPolicyStateFallbackLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [int]$TimeoutMilliseconds = 15000,
        [string]$Reason = ''
    )

    Write-AcrylicPolicyLockFallbackWarning -Reason $Reason

    $lockDirectories = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $lockDirectories += (Join-Path $env:ProgramData 'OpenPath')
    }
    $lockDirectories += (Join-Path ([IO.Path]::GetTempPath()) 'OpenPath')

    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    $lastError = $null

    foreach ($lockDirectory in @($lockDirectories | Select-Object -Unique)) {
        try {
            if (-not (Test-Path -LiteralPath $lockDirectory -ErrorAction SilentlyContinue)) {
                New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
            }

            $lockPath = Join-Path $lockDirectory 'OpenPathPolicyStateLock.fallback.lock'
            $stream = $null
            while (-not $stream) {
                try {
                    $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                }
                catch [System.IO.IOException] {
                    $lastError = $_
                    if ((Get-Date) -ge $deadline) {
                        throw "Timed out waiting for Acrylic fallback policy lock at $lockPath"
                    }
                    Start-Sleep -Milliseconds 100
                }
            }

            try {
                $stream.SetLength(0)
                $lockBytes = [Text.Encoding]::ASCII.GetBytes("pid=$PID utc=$((Get-Date).ToUniversalTime().ToString('o'))`n")
                $stream.Write($lockBytes, 0, $lockBytes.Length)
                $stream.Flush()

                return (& $Action)
            }
            finally {
                if ($stream) { $stream.Dispose() }
            }
        }
        catch {
            $lastError = $_
            continue
        }
    }

    if ($lastError) {
        throw $lastError
    }

    throw 'Acrylic fallback policy lock unavailable'
}

function Invoke-AcrylicPolicyStateLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [string]$MutexName = 'Global\OpenPathPolicyStateLock',
        [int]$TimeoutMilliseconds = 15000
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $lockAcquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if (-not $lockAcquired) {
            throw "Timed out waiting for $MutexName"
        }

        return (& $Action)
    }
    catch {
        $exception = $_.Exception
        $innerException = $exception.InnerException
        $isUnauthorizedAccessException = (
            $exception -is [System.UnauthorizedAccessException] -or
            $innerException -is [System.UnauthorizedAccessException] -or
            [string]$exception.Message -match '(?i)(access.*denied|acceso denegado|UnauthorizedAccessException)'
        )

        if ($isUnauthorizedAccessException) {
            return (Invoke-AcrylicPolicyStateFallbackLocked -Action $Action -TimeoutMilliseconds $TimeoutMilliseconds -Reason ([string]$exception.Message))
        }

        throw
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try { $mutex.ReleaseMutex() }
            catch [System.ApplicationException] { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Write-AcrylicTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw "Refusing to write blank $Description to $Path"
    }

    $directory = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
    }
    if (-not (Test-Path -LiteralPath $directory -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $leaf = Split-Path -Path $Path -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'Acrylic.tmp'
    }
    $tempPath = Join-Path $directory (".$leaf.$([guid]::NewGuid().ToString('N')).tmp")

    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.Encoding]::ASCII)
        $writtenFile = Get-Item -LiteralPath $tempPath -Force -ErrorAction Stop
        if ($writtenFile.Length -le 0) {
            throw "Refusing to replace $Description with a zero-byte temporary file at $tempPath"
        }

        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-AcrylicConfigFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    Write-AcrylicTextFile -Path $Path -Content $Content -Description 'AcrylicConfiguration.ini'
}

function Write-AcrylicHostsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    Write-AcrylicTextFile -Path $Path -Content $Content -Description 'AcrylicHosts.txt'
}
