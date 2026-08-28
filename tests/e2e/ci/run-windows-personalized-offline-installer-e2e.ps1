# Real Windows E2E for the personalized offline installer capability.
#
# This lane prepares a verified template cache, starts the real API against a
# real PostgreSQL instance, calls the real generate/download endpoint, persists
# only the verified executable, and delegates physical installation, trailer,
# payload, pending-enrollment, retry, runtime, and uninstall checks to the
# canonical EXE runner. Tokens, references, and generated URLs remain in
# process memory and are never written to evidence or logs by this script.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$TemplatePath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$TemplateCommit,

    [string]$TemplateVersion = '4.1.0',

    [string]$TemplateReleaseTag = '',

    [int]$ApiPort = 3204,

    [int]$ConnectivityPort = 18443,

    [string]$ArtifactsRoot = ''
)

$ErrorActionPreference = 'Stop'
$script:CurrentStage = 'preflight'
$script:ApiProcess = $null
$script:PostgresBinDir = $null
$script:PostgresDataDir = $null
$script:PostgresPort = $null
$script:PostgresStarted = $false
$script:RunRoot = $null
$script:TemplateRoot = $null
$script:TemplateSha256 = $null
$script:EvidencePath = $null
$script:DownloadedExecutablePath = $null
$script:PrimaryFailure = $false

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:NodeCommand = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $script:NodeCommand) {
    $script:NodeCommand = (Get-Command node -ErrorAction SilentlyContinue).Source
}
if (-not $script:NodeCommand) {
    throw 'node-runtime-missing'
}

if ([string]::IsNullOrWhiteSpace($TemplateReleaseTag)) {
    $TemplateReleaseTag = "scripts-v$TemplateVersion-$($TemplateCommit.Substring(0, 7))"
}

$script:TempRoot = [string]$env:RUNNER_TEMP
if ([string]::IsNullOrWhiteSpace($script:TempRoot)) {
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}
$script:TempRoot = [System.IO.Path]::GetFullPath($script:TempRoot)

if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) {
    $ArtifactsRoot = Join-Path -Path $script:TempRoot -ChildPath 'openpath-windows-personalized-offline-installer-e2e'
}

$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:EvidencePath = Join-Path $script:ArtifactsRoot 'windows-personalized-offline-installer-evidence.json'

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed"
    }
}

function Write-SafeEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Payload
    )

    [System.IO.Directory]::CreateDirectory($script:ArtifactsRoot) | Out-Null

    $json = ConvertTo-Json -InputObject $Payload -Depth 8
    [System.IO.File]::WriteAllText(
        $script:EvidencePath,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-SafeFailureCode {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = [string]$ErrorRecord.Exception.Message
    switch -Regex ($message) {
        'administrator-required' { return 'administrator-required' }
        'windows-only-lane' { return 'windows-only-lane' }
        'Access is denied|UnauthorizedAccess' { return 'access-denied' }
        'cannot find the path|does not exist' { return 'path-not-found' }
        'parameter cannot be found' { return 'command-parameter-error' }
        'timed out|timeout' { return 'timeout' }
        default { return 'lane-internal-error' }
    }
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0
    )
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Quote-Argument {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    return '"' + $Value.Replace('"', '""') + '"'
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $errorPath = "$OutputPath.err"
    $process = Start-Process -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $script:RepoRoot `
        -NoNewWindow `
        -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $errorPath `
        -PassThru

    if (-not $process.WaitForExit($TimeoutMs)) {
        try {
            $process.Kill($true)
        }
        catch {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        throw "$Context timed out"
    }

    $process.Refresh()
    if ($process.ExitCode -ne 0) {
        throw "$Context failed"
    }
}

function Get-PostgresBinDir {
    $command = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($command) {
        return Split-Path -Parent $command.Source
    }

    $candidate = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' `
        -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        Select-Object -Last 1
    if ($candidate) {
        return Split-Path -Parent $candidate.FullName
    }

    return $null
}

function Invoke-PostgresSql {
    param(
        [Parameter(Mandatory = $true)][string]$Sql
    )

    $sqlPath = Join-Path $script:RunRoot 'postgres.sql'
    $outputPath = Join-Path $script:ArtifactsRoot 'postgres-sql.log'
    [System.IO.File]::WriteAllText(
        $sqlPath,
        "$Sql`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    Invoke-ProcessWithTimeout `
        -FilePath (Join-Path $script:PostgresBinDir 'psql.exe') `
        -ArgumentList @(
            '-w',
            '-h',
            '127.0.0.1',
            '-p',
            [string]$script:PostgresPort,
            '-U',
            'postgres',
            '-d',
            'postgres',
            '-v',
            'ON_ERROR_STOP=1',
            '-f',
            $sqlPath
        ) `
        -TimeoutMs 30000 `
        -Context 'postgres SQL' `
        -OutputPath $outputPath
}

function Start-TestPostgres {
    Write-Step 'Starting isolated PostgreSQL for personalized installer E2E...'

    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        throw 'chocolatey-missing'
    }

    $script:PostgresBinDir = Get-PostgresBinDir
    if (-not $script:PostgresBinDir) {
        choco install postgresql16 --params '"/Password:openpath_test"' --no-progress -y | Out-Host
        Assert-LastExitCode 'postgresql installation'
        $script:PostgresBinDir = Get-PostgresBinDir
    }
    if (-not $script:PostgresBinDir) {
        throw 'postgres-binaries-missing'
    }

    $script:PostgresPort = Get-FreeTcpPort
    $script:PostgresDataDir = Join-Path $script:RunRoot 'postgres'
    $initdb = Join-Path $script:PostgresBinDir 'initdb.exe'
    $pgCtl = Join-Path $script:PostgresBinDir 'pg_ctl.exe'
    $pgIsReady = Join-Path $script:PostgresBinDir 'pg_isready.exe'
    $initLog = Join-Path $script:ArtifactsRoot 'postgres-initdb.log'
    $startLog = Join-Path $script:ArtifactsRoot 'postgres-start.log'
    $postgresLog = Join-Path $script:ArtifactsRoot 'postgres.log'

    Invoke-ProcessWithTimeout -FilePath $initdb `
        -ArgumentList @(
            '-D',
            $script:PostgresDataDir,
            '-U',
            'postgres',
            '-A',
            'trust',
            '-E',
            'UTF8'
        ) `
        -TimeoutMs 120000 `
        -Context 'postgres initdb' `
        -OutputPath $initLog

    Invoke-ProcessWithTimeout -FilePath $pgCtl `
        -ArgumentList @(
            'start',
            '-D',
            (Quote-Argument -Value $script:PostgresDataDir),
            '-l',
            (Quote-Argument -Value $postgresLog),
            '-o',
            (Quote-Argument -Value "-p $($script:PostgresPort)"),
            '-w'
        ) `
        -TimeoutMs 120000 `
        -Context 'postgres start' `
        -OutputPath $startLog
    $script:PostgresStarted = $true

    for ($attempt = 1; $attempt -le 30; $attempt += 1) {
        & $pgIsReady -h 127.0.0.1 -p $script:PostgresPort -U postgres -d postgres | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $roleSql = 'DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ''openpath'') THEN CREATE ROLE openpath LOGIN PASSWORD ''openpath_test''; ELSE ALTER ROLE openpath WITH LOGIN PASSWORD ''openpath_test''; END IF; END $$;'
            Invoke-PostgresSql -Sql $roleSql
            Invoke-PostgresSql -Sql 'DROP DATABASE IF EXISTS openpath_test WITH (FORCE);'
            Invoke-PostgresSql -Sql 'CREATE DATABASE openpath_test OWNER openpath;'
            return
        }
        Start-Sleep -Seconds 1
    }

    throw 'postgres-readiness-timeout'
}

function Invoke-ApiDatabaseSetup {
    Write-Step 'Initializing the API E2E database...'
    $saved = @{}
    foreach ($name in 'DATABASE_URL', 'DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD') {
        $saved[$name] = (Get-Item "Env:$name" -ErrorAction SilentlyContinue).Value
    }

    try {
        Remove-Item Env:DATABASE_URL -ErrorAction SilentlyContinue
        $env:DB_HOST = '127.0.0.1'
        $env:DB_PORT = [string]$script:PostgresPort
        $env:DB_NAME = 'openpath_test'
        $env:DB_USER = 'openpath'
        $env:DB_PASSWORD = 'openpath_test'
        Push-Location $script:RepoRoot
        try {
            npm run db:setup:e2e --workspace=@openpath/api *> $null
            Assert-LastExitCode 'API database setup'
        }
        finally {
            Pop-Location
        }
    }
    finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item "Env:$name" -Value $saved[$name]
            }
        }
    }
}

function Wait-ForApi {
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )

    for ($attempt = 1; $attempt -le 45; $attempt += 1) {
        if ($script:ApiProcess.HasExited) {
            throw 'api-exited-before-ready'
        }
        try {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 | Out-Null
            return
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }

    throw 'api-readiness-timeout'
}

function New-VerifiedTemplateCache {
    Write-Step 'Installing the verified template generation into an isolated cache...'
    $script:TemplateRoot = Join-Path $script:RunRoot 'templates'
    $commitDirectory = Join-Path (Join-Path $script:TemplateRoot $TemplateVersion) $TemplateCommit
    $generationDirectory = Join-Path (Join-Path $commitDirectory 'generations') "generation-$([guid]::NewGuid().ToString())"
    [System.IO.Directory]::CreateDirectory($generationDirectory) | Out-Null

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $TemplatePath).Hash.ToLowerInvariant()
    $sourceSidecarPath = "$TemplatePath.sha256"
    if (-not (Test-Path -LiteralPath $sourceSidecarPath -PathType Leaf)) {
        throw 'template-sidecar-missing'
    }
    $sidecarHash = ((Get-Content -LiteralPath $sourceSidecarPath -Raw).Trim() -split '\s+', 2)[0].ToLowerInvariant()
    if ($sidecarHash -ne $sourceHash) {
        throw 'template-sidecar-mismatch'
    }
    $script:TemplateSha256 = $sourceHash

    $fileName = 'OpenPath-Windows-Setup-Template.exe'
    $targetPath = Join-Path $generationDirectory $fileName
    Copy-Item -LiteralPath $TemplatePath -Destination $targetPath -Force
    [System.IO.File]::WriteAllText(
        "$targetPath.sha256",
        "$sourceHash  $fileName`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $provenance = [ordered]@{
        version    = $TemplateVersion
        commit     = $TemplateCommit
        releaseTag = $TemplateReleaseTag
        sha256     = $sourceHash
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText(
        "$targetPath.provenance.json",
        "$provenance`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    foreach ($path in @($targetPath, "$targetPath.sha256", "$targetPath.provenance.json")) {
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
    }

    $pointerTemp = Join-Path $commitDirectory ".current.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText(
        $pointerTemp,
        "$(Split-Path -Leaf $generationDirectory)`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $pointerTemp -Destination (Join-Path $commitDirectory '.current') -Force
}

function Start-Api {
    Write-Step "Starting the real API on port $ApiPort..."
    $apiLog = Join-Path $script:ArtifactsRoot 'api.log'
    $apiErrorLog = Join-Path $script:ArtifactsRoot 'api.err.log'
    $dataDir = Join-Path $script:RunRoot 'api-data'
    $artifactRoot = Join-Path $script:RunRoot 'artifacts'
    [System.IO.Directory]::CreateDirectory($dataDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($artifactRoot) | Out-Null

    $saved = @{}
    foreach ($name in @(
        'DATABASE_URL',
        'DB_HOST',
        'DB_PORT',
        'DB_NAME',
        'DB_USER',
        'DB_PASSWORD',
        'NODE_ENV',
        'JWT_SECRET',
        'SHARED_SECRET',
        'HOST',
        'PORT',
        'PUBLIC_URL',
        'DATA_DIR',
        'OPENPATH_FORCE_SERVER_START',
        'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR',
        'OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR',
        'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION',
        'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT',
        'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256',
        'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG',
        'OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_MAX_ATTEMPTS',
        'OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_TTL_MINUTES'
    )) {
        $saved[$name] = (Get-Item "Env:$name" -ErrorAction SilentlyContinue).Value
    }

    try {
        Remove-Item Env:DATABASE_URL -ErrorAction SilentlyContinue
        $env:NODE_ENV = 'test'
        $env:JWT_SECRET = 'openpath-personalized-e2e-jwt'
        $env:SHARED_SECRET = 'openpath-personalized-e2e-shared'
        $env:HOST = '127.0.0.1'
        $env:DB_HOST = '127.0.0.1'
        $env:DB_PORT = [string]$script:PostgresPort
        $env:DB_NAME = 'openpath_test'
        $env:DB_USER = 'openpath'
        $env:DB_PASSWORD = 'openpath_test'
        $env:PORT = [string]$ApiPort
        $env:PUBLIC_URL = "https://localhost:$ConnectivityPort"
        $env:DATA_DIR = $dataDir
        $env:OPENPATH_FORCE_SERVER_START = 'true'
        $env:OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR = $script:TemplateRoot
        $env:OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR = $artifactRoot
        $env:OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION = $TemplateVersion
        $env:OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT = $TemplateCommit
        $env:OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256 = $script:TemplateSha256
        $env:OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG = $TemplateReleaseTag
        $env:OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_MAX_ATTEMPTS = '3'
        $env:OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_TTL_MINUTES = '10'

        $script:ApiProcess = Start-Process -FilePath $script:NodeCommand `
            -ArgumentList @('--import', 'tsx', 'api/src/server.ts') `
            -WorkingDirectory $script:RepoRoot `
            -RedirectStandardOutput $apiLog `
            -RedirectStandardError $apiErrorLog `
            -PassThru
    }
    finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item "Env:$name" -Value $saved[$name]
            }
        }
    }

    Wait-ForApi -Url "http://127.0.0.1:$ApiPort/trpc/healthcheck.ready"
}

function Get-BackendScenario {
    Write-Step 'Creating a real teacher session and classroom through the API...'
    $errorPath = Join-Path $script:ArtifactsRoot 'backend-bootstrap.err.log'
    Push-Location $script:RepoRoot
    try {
        $output = & $script:NodeCommand --import tsx tests/e2e/student-flow/backend-harness.ts bootstrap `
            --api-url "http://127.0.0.1:$ApiPort" `
            --scenario-name 'Windows Personalized Offline Installer E2E' `
            --machine-hostname 'windows-personalized-offline-installer-e2e' `
            2> $errorPath
        Assert-LastExitCode 'backend scenario bootstrap'
    }
    finally {
        Pop-Location
    }

    $json = ($output -join [Environment]::NewLine).Trim()
    try {
        $scenario = $json | ConvertFrom-Json
    }
    catch {
        throw 'backend-bootstrap-invalid-json'
    }
    if (
        [string]::IsNullOrWhiteSpace([string]$scenario.classroom.id) -or
        [string]::IsNullOrWhiteSpace([string]$scenario.auth.teacher.accessToken)
    ) {
        throw 'backend-bootstrap-missing-session'
    }
    return $scenario
}

function Invoke-RealHttpCanary {
    param(
        [Parameter(Mandatory = $true)][object]$Scenario
    )

    Write-Step 'Generating and downloading the personalized executable through the real HTTP API...'
    $downloadPath = Join-Path $script:ArtifactsRoot 'OpenPath-personalized-download.exe'
    $script:DownloadedExecutablePath = $downloadPath
    $canaryErrorPath = Join-Path $script:ArtifactsRoot 'http-canary.err.log'
    $saved = @{}
    foreach ($name in 'OPENPATH_CANARY_BASE_URL', 'OPENPATH_CANARY_DOWNLOAD_BASE_URL', 'OPENPATH_CANARY_ACCESS_TOKEN', 'OPENPATH_CANARY_CLASSROOM_ID', 'OPENPATH_CANARY_OUTPUT_PATH') {
        $saved[$name] = (Get-Item "Env:$name" -ErrorAction SilentlyContinue).Value
    }

    try {
        $env:OPENPATH_CANARY_BASE_URL = "http://127.0.0.1:$ApiPort"
        $env:OPENPATH_CANARY_DOWNLOAD_BASE_URL = "http://127.0.0.1:$ApiPort"
        $env:OPENPATH_CANARY_ACCESS_TOKEN = [string]$Scenario.auth.teacher.accessToken
        $env:OPENPATH_CANARY_CLASSROOM_ID = [string]$Scenario.classroom.id
        $env:OPENPATH_CANARY_OUTPUT_PATH = $downloadPath

        Push-Location $script:RepoRoot
        try {
            $output = & $script:NodeCommand scripts/windows-offline-installer-canary.mjs 2> $canaryErrorPath
            Assert-LastExitCode 'HTTP offline installer canary'
        }
        finally {
            Pop-Location
        }
    }
    finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item "Env:$name" -Value $saved[$name]
            }
        }
    }

    try {
        $evidence = (($output -join [Environment]::NewLine).Trim() | ConvertFrom-Json)
    }
    catch {
        throw 'http-canary-invalid-json'
    }
    if (
        $evidence.status -ne 'ok' -or
        $evidence.downloadStatus -ne 200 -or
        $evidence.replayStatus -ne 410 -or
        $evidence.headersVerified -ne $true -or
        -not ($evidence.downloadBytes -gt 0) -or
        [string]$evidence.downloadSha256 -notmatch '^[0-9a-f]{64}$'
    ) {
        throw 'http-canary-contract-failed'
    }
    if (-not (Test-Path -LiteralPath $downloadPath -PathType Leaf)) {
        throw 'http-canary-download-missing'
    }
    $downloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
    $downloadSize = (Get-Item -LiteralPath $downloadPath).Length
    if ($downloadHash -ne [string]$evidence.downloadSha256 -or $downloadSize -ne [int64]$evidence.downloadBytes) {
        throw 'http-canary-file-identity-failed'
    }

    return [pscustomobject]@{
        downloadPath   = $downloadPath
        fileName       = [string]$evidence.fileName
        bytes          = [int64]$downloadSize
        sha256         = $downloadHash
        generateStatus = 200
        downloadStatus = [int]$evidence.downloadStatus
        replayStatus   = [int]$evidence.replayStatus
        headersVerified = [bool]$evidence.headersVerified
    }
}

function Invoke-PhysicalExeE2E {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$ClassroomId
    )

    Write-Step 'Executing the downloaded personalized EXE on the real Windows runner...'
    $evidencePath = Join-Path $script:ArtifactsRoot 'windows-offline-installer-exe-evidence.json'
    $shell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $shell) {
        $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    }
    if (-not $shell) {
        throw 'powershell-runtime-missing'
    }

    & $shell -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $script:RepoRoot 'tests\e2e\ci\run-windows-offline-installer-exe.ps1') `
        -ExecutablePath $ExecutablePath `
        -ExpectedClassroomId $ClassroomId `
        -ExpectedApiUrl "https://localhost:$ConnectivityPort" `
        -ConnectivityPort $ConnectivityPort `
        -EvidencePath $evidencePath
    if ($LASTEXITCODE -ne 0) {
        throw 'physical-exe-e2e-failed'
    }
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw 'physical-exe-evidence-missing'
    }

    try {
        $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    }
    catch {
        throw 'physical-exe-evidence-invalid'
    }
    if (
        $evidence.status -ne 'ok' -or
        $evidence.trailerValidated -ne $true -or
        $evidence.payloadManifestValidated -ne $true -or
        $evidence.pendingStateObserved -ne $true -or
        $evidence.retryOutcome -ne 'REGISTERED' -or
        $evidence.pendingStateCleared -ne $true
    ) {
        throw 'physical-exe-contract-failed'
    }
    return $evidence
}

function Stop-Api {
    if ($null -eq $script:ApiProcess) {
        return
    }
    try {
        if (-not $script:ApiProcess.HasExited) {
            $script:ApiProcess.Kill($true)
            if (-not $script:ApiProcess.WaitForExit(10000)) {
                Stop-Process -Id $script:ApiProcess.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Stop-Process -Id $script:ApiProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

function Stop-TestPostgres {
    if (-not $script:PostgresStarted -or -not $script:PostgresBinDir) {
        return
    }

    $pgCtl = Join-Path $script:PostgresBinDir 'pg_ctl.exe'
    try {
        Invoke-ProcessWithTimeout -FilePath $pgCtl `
            -ArgumentList @(
                'stop',
                '-D',
                (Quote-Argument -Value $script:PostgresDataDir),
                '-m',
                'fast',
                '-w'
            ) `
            -TimeoutMs 30000 `
            -Context 'postgres stop' `
            -OutputPath (Join-Path $script:ArtifactsRoot 'postgres-stop.log')
    }
    finally {
        $script:PostgresStarted = $false
    }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'windows-only-lane'
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'administrator-required'
    }

    $script:CurrentStage = 'prepare'
    [System.IO.Directory]::CreateDirectory($script:ArtifactsRoot) | Out-Null
    $script:RunRoot = Join-Path -Path $script:TempRoot -ChildPath "openpath-personalized-offline-installer-$([guid]::NewGuid().ToString('N'))"
    [System.IO.Directory]::CreateDirectory($script:RunRoot) | Out-Null

    $script:CurrentStage = 'template-cache'
    New-VerifiedTemplateCache
    $script:CurrentStage = 'postgres'
    Start-TestPostgres
    $script:CurrentStage = 'database-setup'
    Invoke-ApiDatabaseSetup
    $script:CurrentStage = 'api-start'
    Start-Api
    $script:CurrentStage = 'backend-bootstrap'
    $scenario = Get-BackendScenario
    $script:CurrentStage = 'http-generate-download-replay'
    $httpEvidence = Invoke-RealHttpCanary -Scenario $scenario
    $script:CurrentStage = 'physical-exe'
    $exeEvidence = Invoke-PhysicalExeE2E -ExecutablePath $httpEvidence.downloadPath -ClassroomId ([string]$scenario.classroom.id)

    $success = [ordered]@{
        status                  = 'ok'
        runner                  = if ($env:RUNNER_NAME) { $env:RUNNER_NAME } else { 'windows-runner' }
        generateStatus          = $httpEvidence.generateStatus
        downloadStatus          = $httpEvidence.downloadStatus
        downloadBytes           = $httpEvidence.bytes
        downloadSha256          = $httpEvidence.sha256
        downloadHeadersVerified = $httpEvidence.headersVerified
        replayStatus             = $httpEvidence.replayStatus
        trailerValidated         = [bool]$exeEvidence.trailerValidated
        payloadManifestValidated = [bool]$exeEvidence.payloadManifestValidated
        pendingStateObserved     = [bool]$exeEvidence.pendingStateObserved
        retryOutcome             = [string]$exeEvidence.retryOutcome
        pendingStateCleared      = [bool]$exeEvidence.pendingStateCleared
        uninstalled               = $true
    }
    Write-SafeEvidence -Payload $success
}
catch {
    $script:PrimaryFailure = $true
    $failureCode = Get-SafeFailureCode -ErrorRecord $_
    Write-Host "Personalized offline installer E2E failed at $($script:CurrentStage) ($failureCode)" -ForegroundColor Red
    Write-SafeEvidence -Payload ([ordered]@{
        status       = 'failed'
        code         = 'windows-personalized-offline-installer-e2e-failed'
        failureStage = $script:CurrentStage
        failureCode  = $failureCode
        runner       = if ($env:RUNNER_NAME) { $env:RUNNER_NAME } else { 'windows-runner' }
    })
}
finally {
    try {
        Stop-Api
    }
    catch {
        $script:PrimaryFailure = $true
    }
    try {
        Stop-TestPostgres
    }
    catch {
        $script:PrimaryFailure = $true
    }
    if ($script:RunRoot -and (Test-Path -LiteralPath $script:RunRoot)) {
        Remove-Item -LiteralPath $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:DownloadedExecutablePath -and (Test-Path -LiteralPath $script:DownloadedExecutablePath)) {
        Remove-Item -LiteralPath $script:DownloadedExecutablePath -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $script:ArtifactsRoot -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

if ($script:PrimaryFailure) {
    exit 1
}

Write-Host 'Windows personalized offline installer E2E completed successfully' -ForegroundColor Green
