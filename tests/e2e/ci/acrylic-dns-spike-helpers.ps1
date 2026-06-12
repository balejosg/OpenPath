# Shared helpers for the Acrylic DNS spike/matrix runners. Dot-source after param(). Functions must stay generic; runner-specific variants stay in their runner.

function Get-AcrylicRoot {
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Acrylic DNS Proxy'),
        (Join-Path $env:ProgramFiles 'Acrylic DNS Proxy')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'Acrylic DNS Proxy root was not found.'
}

function Get-AcrylicServicePath {
    return (Join-Path (Get-AcrylicRoot) 'AcrylicService.exe')
}

function Get-AcrylicRegisteredService {
    $service = Get-Service -Name $script:AcrylicServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service) {
        return $service
    }

    return Get-Service -DisplayName '*Acrylic*' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-TextShared {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Clear-HitLogFile {
    $stream = [System.IO.File]::Open(
        $script:HitLogPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $stream.SetLength(0)
    }
    finally {
        $stream.Dispose()
    }
}

function Test-HitLogReadableWhileRunning {
    try {
        $stream = [System.IO.File]::Open(
            $script:HitLogPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite
        )
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{}
    }

    return (Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json)
}

function Remove-DiagnosticAcrylicServiceIfCreated {
    if (-not $script:RegisteredAcrylicServiceForDiagnostic) {
        return
    }

    $service = Get-AcrylicRegisteredService
    if ($null -ne $service) {
        Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
    }

    $servicePath = Get-AcrylicServicePath
    if (Test-Path -LiteralPath $servicePath) {
        $uninstallProcess = Start-Process -FilePath $servicePath -ArgumentList '/UNINSTALL' -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
        if ($uninstallProcess -and -not $uninstallProcess.WaitForExit(15000)) {
            Stop-Process -Id $uninstallProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $service = Get-AcrylicRegisteredService
    if ($null -ne $service) {
        & sc.exe delete $service.Name | Out-Null
        Start-Sleep -Seconds 1
    }
}

function Invoke-PktmonCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
        return @{
            available = $false
            exitCode = $null
            output = 'pktmon.exe not available'
        }
    }

    $output = ''
    $exitCode = $null
    try {
        $output = & pktmon.exe @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = $_.Exception.Message
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    }

    return @{
        available = $true
        exitCode = $exitCode
        output = $output
    }
}

function Get-AcrylicHostsPath {
    return (Join-Path (Get-AcrylicRoot) 'AcrylicHosts.txt')
}

function Get-AcrylicConfigurationPath {
    return (Join-Path (Get-AcrylicRoot) 'AcrylicConfiguration.ini')
}

function Set-IniValue {
    param(
        [AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $updated = New-Object System.Collections.Generic.List[string]
    $found = $false

    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            $updated.Add("$Key=$Value")
            $found = $true
        }
        else {
            $updated.Add($line)
        }
    }

    if (-not $found) {
        $updated.Add("$Key=$Value")
    }

    return $updated.ToArray()
}

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:HitLogPath) -Force | Out-Null
}

function Restart-AcrylicServiceIfPresent {
    $service = Get-Service -Name $script:AcrylicServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        throw "Acrylic service $($script:AcrylicServiceName) was not found."
    }

    Restart-Service -Name $script:AcrylicServiceName -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
}
