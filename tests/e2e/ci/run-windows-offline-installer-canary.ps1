# Read-only Windows evidence for a generated OpenPath offline installer.
# This validates the trailer and file identity. It never installs by default.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ExecutablePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedClassroomId,

    [string]$ExpectedApiUrl = '',

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedSha256 = '',

    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$reader = Join-Path $repoRoot 'windows\offline-installer\scripts\Read-Trailer.ps1'
$installer = Join-Path $repoRoot 'windows\Install-OpenPath.ps1'
$configFile = $null

try {
    if (-not (Test-Path -LiteralPath $reader -PathType Leaf)) {
        throw 'offline-trailer-reader-missing'
    }
    if ($Install -and -not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw 'windows-installer-missing'
    }

    $shellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $shellCommand) {
        $shellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    }
    if (-not $shellCommand) {
        throw 'powershell-runtime-missing'
    }

    $configFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-offline-config-$([guid]::NewGuid().ToString('N')).json"
    $readerArguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $reader,
        '-ExecutablePath',
        (Resolve-Path -LiteralPath $ExecutablePath).Path,
        '-OutputConfigPath',
        $configFile
    )
    & $shellCommand.Source @readerArguments *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw 'trailer-validation-failed'
    }

    $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    if ([string]$config.classroomId -ne $ExpectedClassroomId) {
        throw 'classroom-id-mismatch'
    }

    if ($ExpectedApiUrl) {
        $actualApiUrl = ([string]$config.apiUrl).TrimEnd('/')
        if ($actualApiUrl -ne $ExpectedApiUrl.TrimEnd('/')) {
            throw 'api-url-mismatch'
        }
    }

    $file = Get-Item -LiteralPath $ExecutablePath
    $actualSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ExpectedSha256 -and $actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw 'executable-checksum-mismatch'
    }

    if ($Install) {
        Push-Location $repoRoot
        try {
            $installArguments = @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $installer,
                '-OfflineConfigPath',
                $configFile,
                '-Unattended'
            )
            & $shellCommand.Source @installArguments *> $null
            if ($LASTEXITCODE -ne 0) {
                throw 'windows-install-failed'
            }
        }
        finally {
            Pop-Location
        }
    }

    [pscustomobject]@{
        status = 'ok'
        classroomId = [string]$config.classroomId
        bytes = [int64]$file.Length
        sha256 = $actualSha256
        installed = [bool]$Install
    } | ConvertTo-Json -Compress
    exit 0
}
catch {
    [pscustomobject]@{
        status = 'failed'
        code = 'windows-offline-installer-evidence-failed'
    } | ConvertTo-Json -Compress
    exit 1
}
finally {
    if ($configFile -and (Test-Path -LiteralPath $configFile)) {
        Remove-Item -LiteralPath $configFile -Force -ErrorAction SilentlyContinue
    }
}
