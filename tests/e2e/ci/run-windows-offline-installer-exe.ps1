# Windows evidence lane for the personalized NSIS executable.
#
# This is intentionally separate from the read-only trailer helper: it launches
# the generated .exe, lets the NSIS runtime extract and validate its payload,
# invokes the existing offline Install-OpenPath.ps1 path, observes pending
# enrollment, and then exercises the existing retry path against a local HTTPS
# enrollment fixture. The runner must be ephemeral or reset after this lane.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ExecutablePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedClassroomId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://localhost:\d+$')]
    [string]$ExpectedApiUrl,

    [string]$OpenPathRoot = '',

    [int]$ConnectivityPort = 18443,

    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'

function Get-AvailablePowerShell {
    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command pwsh -ErrorAction SilentlyContinue
    }
    if (-not $command) {
        throw 'powershell-runtime-missing'
    }
    return $command.Source
}

function Write-SafeEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Payload,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Assert-EqualValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    if ($Actual.TrimEnd('/') -ne $Expected.TrimEnd('/')) {
        throw $Code
    }
}

function Start-EnrollmentFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [string]$ClassroomId,

        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    return Start-Job -ScriptBlock {
        param(
            [string]$ListenerPrefix,
            [string]$ExpectedClassroom,
            [int]$ListenerPort
        )

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($ListenerPrefix)
        $listener.Start()
        try {
            while ($true) {
                $context = $listener.GetContext()
                try {
                    $path = $context.Request.Url.AbsolutePath
                    if ($context.Request.HttpMethod -ne 'POST' -or $path -ne '/api/machines/register') {
                        $context.Response.StatusCode = 404
                        $context.Response.Close()
                        continue
                    }

                    $body = @{
                        success = $true
                        machineHostname = 'openpath-exe-e2e-machine'
                        reportedHostname = 'openpath-exe-e2e-machine'
                        whitelistUrl = "https://localhost:$ListenerPort/w/e2e-machine-token/whitelist.txt"
                        classroomName = 'Windows EXE E2E'
                        classroomId = $ExpectedClassroom
                    } | ConvertTo-Json -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'application/json'
                    $context.Response.ContentLength64 = $bytes.Length
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.Close()
                }
                catch {
                    $context.Response.Abort()
                }
            }
        }
        finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $ClassroomId, $Port
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'windows-only-lane'
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'administrator-required'
}

$shell = Get-AvailablePowerShell
$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$expectedApiUri = [System.Uri]$ExpectedApiUrl
if ($expectedApiUri.Port -ne $ConnectivityPort) {
    throw 'ExpectedApiUrl port must match ConnectivityPort'
}
$previousOpenPathRoot = $env:OPENPATH_WINDOWS_ROOT
if (-not $OpenPathRoot) {
    $OpenPathRoot = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-exe-e2e-$([guid]::NewGuid().ToString('N'))"
}
if (Test-Path -LiteralPath $OpenPathRoot) {
    throw 'OpenPathRoot must be a new isolated directory'
}

$evidencePathWasSupplied = [bool]$EvidencePath
if (-not $EvidencePath) {
    $EvidencePath = Join-Path ([System.IO.Path]::GetTempPath()) 'openpath-windows-offline-installer-exe-evidence.json'
}

$stubJob = $null
$certificate = $null
$certificateFile = $null
$sslBindingAdded = $false
$urlAclAdded = $false
$sslAppId = '{4c9e7d9c-2d7c-4e4e-bb3e-2f5f0b7e7c42}'
$urlAcl = "https://localhost:$ConnectivityPort/"
$trailerConfigFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-exe-trailer-$([guid]::NewGuid().ToString('N')).json"
$result = $null

try {
    $env:OPENPATH_WINDOWS_ROOT = $OpenPathRoot
    $installProcess = Start-Process -FilePath $resolvedExecutable -ArgumentList @('/S') -Wait -PassThru
    $installExitCode = [int]$installProcess.ExitCode
    if ($installExitCode -ne 60) {
        throw 'offline-install-did-not-reach-pending-state'
    }

    $pendingStatePath = Join-Path $OpenPathRoot 'data\pending-enrollment.json.dpapi'
    $installedConfigPath = Join-Path $OpenPathRoot 'data\config.json'
    if (-not (Test-Path -LiteralPath $pendingStatePath -PathType Leaf)) {
        throw 'pending-enrollment-state-missing'
    }
    if (-not (Test-Path -LiteralPath $installedConfigPath -PathType Leaf)) {
        throw 'installed-config-missing'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $OpenPathRoot 'lib\install\Installer.Offline.ps1') -PathType Leaf)) {
        throw 'offline-runtime-missing'
    }

    $installedConfig = Get-Content -LiteralPath $installedConfigPath -Raw | ConvertFrom-Json
    Assert-EqualValue -Actual ([string]$installedConfig.classroomId) -Expected $ExpectedClassroomId -Code 'installed-classroom-mismatch'
    Assert-EqualValue -Actual ([string]$installedConfig.apiUrl) -Expected $ExpectedApiUrl -Code 'installed-api-url-mismatch'

    $reader = Join-Path $PSScriptRoot '..\..\..\windows\offline-installer\scripts\Read-Trailer.ps1'
    if (-not (Test-Path -LiteralPath $reader -PathType Leaf)) {
        throw 'offline-trailer-reader-missing'
    }
    & $shell -NoProfile -ExecutionPolicy Bypass -File $reader -ExecutablePath $resolvedExecutable -OutputConfigPath $trailerConfigFile *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $trailerConfigFile -PathType Leaf)) {
        throw 'trailer-validation-failed'
    }
    $trailerConfig = Get-Content -LiteralPath $trailerConfigFile -Raw | ConvertFrom-Json
    Assert-EqualValue -Actual ([string]$trailerConfig.classroomId) -Expected $ExpectedClassroomId -Code 'trailer-classroom-mismatch'
    Assert-EqualValue -Actual ([string]$trailerConfig.apiUrl) -Expected $ExpectedApiUrl -Code 'trailer-api-url-mismatch'

    $certificate = New-SelfSignedCertificate -DnsName 'localhost' -CertStoreLocation 'Cert:\LocalMachine\My'
    $certificateFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-exe-e2e-$([guid]::NewGuid().ToString('N')).cer"
    Export-Certificate -Cert $certificate -FilePath $certificateFile -Type CERT | Out-Null
    Import-Certificate -FilePath $certificateFile -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
    & netsh http add sslcert "ipport=0.0.0.0:$ConnectivityPort" "certhash=$($certificate.Thumbprint)" "appid=$sslAppId" "certstorename=MY" *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'local-https-binding-failed'
    }
    $sslBindingAdded = $true

    & netsh http add urlacl "url=$urlAcl" 'user=Everyone' *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'local-https-urlacl-failed'
    }
    $urlAclAdded = $true

    $stubJob = Start-EnrollmentFixture -Prefix $urlAcl -ClassroomId $ExpectedClassroomId -Port $ConnectivityPort
    Start-Sleep -Seconds 2
    if ($stubJob.State -eq 'Failed') {
        Receive-Job -Job $stubJob -ErrorAction SilentlyContinue | Out-Null
        throw 'local-enrollment-fixture-failed'
    }

    . (Join-Path $OpenPathRoot 'lib\install\Installer.Offline.ps1')
    $retry = Invoke-OpenPathPendingEnrollmentRetry -OpenPathRoot $OpenPathRoot
    if ([string]$retry.Outcome -ne 'REGISTERED') {
        throw 'pending-enrollment-retry-did-not-complete'
    }
    if (Test-Path -LiteralPath $pendingStatePath -PathType Leaf) {
        throw 'pending-enrollment-state-not-cleared'
    }

    $completedConfig = Get-Content -LiteralPath $installedConfigPath -Raw | ConvertFrom-Json
    Assert-EqualValue -Actual ([string]$completedConfig.classroomId) -Expected $ExpectedClassroomId -Code 'completed-classroom-mismatch'
    if ([string]::IsNullOrWhiteSpace([string]$completedConfig.whitelistUrl)) {
        throw 'completed-whitelist-url-missing'
    }

    $result = [ordered]@{
        status = 'ok'
        installerExitCode = $installExitCode
        trailerValidated = $true
        payloadManifestValidated = $true
        pendingStateObserved = $true
        retryOutcome = [string]$retry.Outcome
        pendingStateCleared = $true
    }
    Write-SafeEvidence -Payload $result -Path $EvidencePath
    $result | ConvertTo-Json -Compress
    exit 0
}
catch {
    $failure = [ordered]@{
        status = 'failed'
        code = 'windows-offline-installer-exe-e2e-failed'
    }
    Write-SafeEvidence -Payload $failure -Path $EvidencePath
    $failure | ConvertTo-Json -Compress
    exit 1
}
finally {
    if ($stubJob) {
        Stop-Job -Job $stubJob -ErrorAction SilentlyContinue
        Remove-Job -Job $stubJob -Force -ErrorAction SilentlyContinue
    }
    if ($sslBindingAdded) {
        & netsh http delete sslcert "ipport=0.0.0.0:$ConnectivityPort" *> $null
    }
    if ($urlAclAdded) {
        & netsh http delete urlacl "url=$urlAcl" *> $null
    }
    if ($certificate) {
        Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }
    if ($certificateFile -and (Test-Path -LiteralPath $certificateFile)) {
        Remove-Item -LiteralPath $certificateFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $trailerConfigFile) {
        Remove-Item -LiteralPath $trailerConfigFile -Force -ErrorAction SilentlyContinue
    }
    $uninstaller = Join-Path $OpenPathRoot 'Uninstall-OpenPath.ps1'
    if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
        & $shell -NoProfile -ExecutionPolicy Bypass -File $uninstaller *> $null
    }
    if (Test-Path -LiteralPath $OpenPathRoot) {
        Remove-Item -LiteralPath $OpenPathRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previousOpenPathRoot) {
        Remove-Item Env:OPENPATH_WINDOWS_ROOT -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENPATH_WINDOWS_ROOT = $previousOpenPathRoot
    }
    if (-not $evidencePathWasSupplied -and (Test-Path -LiteralPath $EvidencePath)) {
        Remove-Item -LiteralPath $EvidencePath -Force -ErrorAction SilentlyContinue
    }
}
