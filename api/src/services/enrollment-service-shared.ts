import { quotePowerShellSingle } from '../lib/server-assets.js';

export type EnrollmentServiceError =
  | { code: 'UNAUTHORIZED'; message: string }
  | { code: 'FORBIDDEN'; message: string }
  | { code: 'NOT_FOUND'; message: string }
  | { code: 'BAD_REQUEST'; message: string }
  | { code: 'MISCONFIGURED'; message: string };

export type EnrollmentServiceResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: EnrollmentServiceError };

export interface EnrollmentTicketOutput {
  classroomId: string;
  classroomName: string;
  enrollmentToken: string;
}

export interface EnrollmentScriptOutput {
  script: string;
}

export interface EnrollmentTokenAccess {
  classroomId: string;
  classroomName: string;
}

export function hasEnrollmentRole(roles: readonly unknown[]): boolean {
  return roles.some((role): boolean => {
    if (typeof role !== 'object' || role === null) {
      return false;
    }

    const roleName = (role as { role?: unknown }).role;
    return roleName === 'admin' || roleName === 'teacher';
  });
}

export function buildWindowsEnrollmentScript(params: {
  classroomId: string;
  enrollmentToken: string;
  firefoxExtensionInstallUrl?: string;
  publicUrl: string;
}): string {
  const psApiUrl = quotePowerShellSingle(params.publicUrl);
  const psClassroomId = quotePowerShellSingle(params.classroomId);
  const psEnrollmentToken = quotePowerShellSingle(params.enrollmentToken);
  const psFirefoxExtensionInstallUrl = quotePowerShellSingle(
    params.firefoxExtensionInstallUrl?.trim() ?? ''
  );

  return `$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ApiUrl = ${psApiUrl}
$ClassroomId = ${psClassroomId}
$EnrollmentToken = ${psEnrollmentToken}
$FirefoxExtensionInstallUrl = ${psFirefoxExtensionInstallUrl}
$Headers = @{ Authorization = "Bearer $EnrollmentToken" }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator'
}

$TempRoot = Join-Path $env:TEMP ("openpath-bootstrap-" + [Guid]::NewGuid().ToString('N'))
$WindowsRoot = Join-Path $TempRoot 'windows'
$InstallTimingPath = 'C:\\OpenPath\\data\\logs\\install-timings.json'
$null = New-Item -ItemType Directory -Path (Join-Path $WindowsRoot 'lib') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $WindowsRoot 'scripts') -Force

$manifest = Invoke-RestMethod -Uri "$ApiUrl/api/agent/windows/bootstrap/manifest" -Headers $Headers -Method Get
if (-not $manifest.success -or -not $manifest.files) {
    throw 'Bootstrap manifest unavailable'
}

function Test-OpenPathBootstrapFilesPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [object[]]$ManifestFiles
    )

    foreach ($file in $ManifestFiles) {
        $relativePath = [string]$file.path
        if (-not $relativePath) {
            continue
        }

        if (-not (Test-Path (Join-Path $Root $relativePath))) {
            return $false
        }
    }

    return $true
}

if ($manifest.version) {
    $env:OPENPATH_VERSION = [string]$manifest.version
}

$bundleApplied = $false
if ($manifest.bundle) {
    $bundlePath = Join-Path $TempRoot 'windows-bootstrap.zip'
    $bundleUrl = [string]$manifest.bundle.path
    if (-not $bundleUrl) {
        $bundleUrl = '/api/agent/windows/bootstrap/bundle.zip'
    }
    if ($bundleUrl -notmatch '^https?://') {
        $bundleUrl = "$ApiUrl$bundleUrl"
    }

    Invoke-WebRequest -Uri $bundleUrl -Headers $Headers -OutFile $bundlePath -UseBasicParsing

    if ($manifest.bundle.sha256) {
        $expectedBundleHash = ([string]$manifest.bundle.sha256).ToLowerInvariant()
        $actualBundleHash = (Get-FileHash -Path $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualBundleHash -ne $expectedBundleHash) {
            throw 'Checksum mismatch for Windows bootstrap bundle'
        }
    }

    Expand-Archive -LiteralPath $bundlePath -DestinationPath $WindowsRoot -Force
    $bundleApplied = Test-OpenPathBootstrapFilesPresent -Root $WindowsRoot -ManifestFiles @($manifest.files)
}

if (-not $bundleApplied) {
    foreach ($file in $manifest.files) {
        $relativePath = [string]$file.path
        if (-not $relativePath) {
            continue
        }

        $destinationPath = Join-Path $WindowsRoot $relativePath
        $destinationDir = Split-Path $destinationPath -Parent
        if (-not (Test-Path $destinationDir)) {
            $null = New-Item -ItemType Directory -Path $destinationDir -Force
        }

        $encodedPath = (($relativePath -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $fileUrl = "$ApiUrl/api/agent/windows/bootstrap/files/$encodedPath"
        Invoke-WebRequest -Uri $fileUrl -Headers $Headers -OutFile $destinationPath -UseBasicParsing

        if ($file.sha256) {
            $expectedHash = ([string]$file.sha256).ToLowerInvariant()
            $actualHash = (Get-FileHash -Path $destinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash) {
                throw "Checksum mismatch for $relativePath"
            }
        }
    }
}

Push-Location $WindowsRoot
try {
    $InstallArgs = @(
        '-ApiUrl', $ApiUrl,
        '-ClassroomId', $ClassroomId,
        '-EnrollmentToken', $EnrollmentToken,
        '-Unattended',
        '-TimingOutputPath', $InstallTimingPath
    )

    if ($FirefoxExtensionInstallUrl) {
        $metadataPath = Join-Path $WindowsRoot 'browser-extension/firefox-release/metadata.json'
        if (-not (Test-Path $metadataPath)) {
            throw 'Firefox release metadata unavailable for explicit install_url'
        }

        $FirefoxExtensionId = [string]((Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json).extensionId)
        if (-not $FirefoxExtensionId) {
            throw 'Firefox release metadata does not include extensionId'
        }

        $InstallArgs += @(
            '-FirefoxExtensionId', $FirefoxExtensionId,
            '-FirefoxExtensionInstallUrl', $FirefoxExtensionInstallUrl
        )
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $WindowsRoot 'Install-OpenPath.ps1') @InstallArgs
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -ne 0) {
        throw "Install-OpenPath.ps1 exited with code $installExitCode"
    }
}
finally {
    Pop-Location
    Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
`;
}
