param(
    [switch]$RunBrowserEnforcementProbes
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ArtifactsRoot = if ($env:OPENPATH_STUDENT_ARTIFACTS_DIR) {
    [System.IO.Path]::GetFullPath($env:OPENPATH_STUDENT_ARTIFACTS_DIR)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'tests\e2e\artifacts\windows-student-policy'))
}

$script:ApiPort = if ($env:OPENPATH_STUDENT_API_PORT) { [int]$env:OPENPATH_STUDENT_API_PORT } else { 3201 }
$script:FixturePort = if ($env:OPENPATH_STUDENT_FIXTURE_PORT) { [int]$env:OPENPATH_STUDENT_FIXTURE_PORT } else { 18082 }
$script:MachineName = if ($env:OPENPATH_STUDENT_MACHINE_NAME) { [string]$env:OPENPATH_STUDENT_MACHINE_NAME } else { 'windows-student-e2e' }

$script:ApiProcess = $null
$script:FixtureProcess = $null
$script:DatabaseMode = $null
$script:PostgresServiceName = $null
$script:PostgresBinDir = $null
$script:PostgresDataDir = $null
$script:PostgresLogPath = $null
$script:PostgresPort = 5432
$script:FirefoxBinaryPath = $null
$script:FirefoxUnsignedAddonSupportState = $null
$script:PrimaryFailure = $null
$script:RunSucceeded = $false
$script:Timings = @()

function Resolve-WindowsStudentSseGroup {
    param(
        [ValidateSet('full', 'request-lifecycle', 'ajax-auto-allow', 'path-blocking', 'exemptions')][string]$ScenarioGroup = 'full'
    )

    return $ScenarioGroup
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

function Write-DiagnosticNote {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    $diagnosticTracePath = Join-Path $script:ArtifactsRoot 'windows-student-policy-trace.log'
    $timestamp = (Get-Date).ToString('o')
    Add-Content -Path $diagnosticTracePath -Value "$timestamp $Message"
}

function Write-TimingEvidence {
    if (-not (Test-Path $script:ArtifactsRoot)) {
        New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    }

    $timingsPath = Join-Path $script:ArtifactsRoot 'windows-student-policy-timings.json'
    ConvertTo-Json -InputObject @($script:Timings) -Depth 4 | Set-Content -Path $timingsPath -Encoding UTF8
}

function Invoke-TimedStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $startedAt = Get-Date
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'success'
    $errorMessage = $null

    Write-Host "::group::$Name"
    try {
        & $ScriptBlock
    }
    catch {
        $status = 'failure'
        $errorMessage = $_.Exception.Message
        throw
    }
    finally {
        $timer.Stop()
        $endedAt = Get-Date
        $script:Timings += [pscustomobject]@{
            name            = $Name
            status          = $status
            startedAt       = $startedAt.ToString('o')
            endedAt         = $endedAt.ToString('o')
            durationMs      = [math]::Round($timer.Elapsed.TotalMilliseconds, 0)
            durationSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 3)
            error           = $errorMessage
        }
        Write-TimingEvidence
        Write-Host "::notice title=Windows Student Policy Timing::$Name $status in $([math]::Round($timer.Elapsed.TotalSeconds, 3))s"
        Write-Host '::endgroup::'
    }
}

function Publish-GitHubTimingSummary {
    if (-not $env:GITHUB_STEP_SUMMARY -or $script:Timings.Count -eq 0) {
        return
    }

    $lines = @(
        ''
        '## Windows Student Policy Timing'
        ''
        '| Phase | Status | Seconds |'
        '| --- | --- | ---: |'
    )

    foreach ($timing in $script:Timings) {
        $lines += "| $($timing.name) | $($timing.status) | $($timing.durationSeconds) |"
    }

    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join [Environment]::NewLine)
}

function Get-OpenPathUninstallArgs {
    $uninstallPath = Join-Path $script:RepoRoot 'windows\Uninstall-OpenPath.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uninstallPath)
    if ($env:RUNNER_ENVIRONMENT -eq 'self-hosted') {
        $arguments += '-KeepAcrylic'
    }

    return $arguments
}

function Publish-GitHubStepSummary {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('failure', 'success')][string]$Mode
    )

    try {
        if ($env:GITHUB_STEP_SUMMARY) {
            $nodeCommand = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
            if (-not $nodeCommand) {
                Write-DiagnosticNote 'Skipping diagnostic GITHUB_STEP_SUMMARY publish because node.exe was not found on PATH.'
            }
            else {
                $summary = & $nodeCommand --import tsx tests/e2e/student-flow/windows-student-summary.ts `
                    --artifacts-dir $script:ArtifactsRoot `
                    --mode $Mode

                if ($LASTEXITCODE -ne 0) {
                    Write-DiagnosticNote "Failed to build GitHub step summary (exit $LASTEXITCODE)."
                }
                else {
                    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $summary
                }
            }
        }

        Publish-GitHubTimingSummary
    }
    catch {
        Write-DiagnosticNote "Skipping GITHUB_STEP_SUMMARY publish: $_"
    }
}

function Publish-GitHubFailureAnnotations {
    try {
        $nodeCommand = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
        if (-not $nodeCommand) {
            Write-DiagnosticNote 'Skipping GitHub failure annotations because node.exe was not found on PATH.'
            return
        }

        $annotations = & $nodeCommand --import tsx -e "import { buildWindowsStudentAnnotations } from './tests/e2e/student-flow/windows-student-summary.ts'; const annotations = buildWindowsStudentAnnotations({ artifactsDir: process.argv[1], mode: 'failure' }); process.stdout.write(annotations.join('\n'));" $script:ArtifactsRoot
        if ($LASTEXITCODE -ne 0) {
            Write-DiagnosticNote "Failed to build GitHub failure annotations (exit $LASTEXITCODE)."
            return
        }

        if ($annotations) {
            $annotations | Out-Host
        }
    }
    catch {
        Write-DiagnosticNote "Skipping GitHub failure annotations: $_"
    }
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed with exit code $LASTEXITCODE"
    }
}

function Write-Utf8NoBomLfFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $content = ($Lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Quote-Argument {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    '"' + $Value.Replace('"', '""') + '"'
}

function Get-FirefoxCandidateRoots {
    @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LOCALAPPDATA
    ) | Where-Object { $_ }
}

function Get-FirefoxBinaryPath {
    param(
        [switch]$AllowRelease
    )

    if ($script:FirefoxBinaryPath) {
        return $script:FirefoxBinaryPath
    }

    if ($env:OPENPATH_FIREFOX_BINARY) {
        $overridePath = [System.IO.Path]::GetFullPath($env:OPENPATH_FIREFOX_BINARY)
        if ((Test-Path $overridePath -PathType Leaf) -and ([System.IO.Path]::GetFileName($overridePath) -ieq 'firefox.exe')) {
            $script:FirefoxBinaryPath = $overridePath
            return $overridePath
        }

        throw "OPENPATH_FIREFOX_BINARY must point to firefox.exe: $overridePath"
    }

    $candidateRoots = Get-FirefoxCandidateRoots

    $candidateRelativePaths = @(
        'Firefox Nightly\firefox.exe',
        'Firefox Developer Edition\firefox.exe',
        'Programs\Firefox Nightly\firefox.exe',
        'Programs\Firefox Developer Edition\firefox.exe'
    )

    if ($AllowRelease) {
        $candidateRelativePaths += @(
            'Mozilla Firefox\firefox.exe',
            'Programs\Mozilla Firefox\firefox.exe'
        )
    }

    foreach ($root in $candidateRoots) {
        foreach ($relativePath in $candidateRelativePaths) {
            $candidate = Join-Path $root $relativePath
            if (Test-Path $candidate) {
                if (-not $AllowRelease) {
                    $script:FirefoxBinaryPath = $candidate
                }
                return $candidate
            }
        }
    }

    return $null
}

function Backup-FirefoxConfigFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (Test-Path $Path) {
        return [pscustomobject]@{
            Path = $Path
            Existed = $true
            Content = [System.IO.File]::ReadAllBytes($Path)
        }
    }

    return [pscustomobject]@{
        Path = $Path
        Existed = $false
        Content = $null
    }
}

function Restore-FirefoxConfigFile {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Snapshot
    )

    if ($Snapshot.Existed) {
        $parent = Split-Path $Snapshot.Path -Parent
        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        [System.IO.File]::WriteAllBytes($Snapshot.Path, $Snapshot.Content)
        return
    }

    if (Test-Path $Snapshot.Path) {
        Remove-Item $Snapshot.Path -Force
    }
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$WorkingDirectory = $script:RepoRoot
    )

    $errorPath = "$OutputPath.err"

    $process = Start-Process -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $WorkingDirectory `
        -NoNewWindow `
        -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $errorPath `
        -PassThru

    if (-not $process.WaitForExit($TimeoutMs)) {
        try {
            $process.Kill($true)
        }
        catch {
            # Best effort.
        }

        $stdout = if (Test-Path $OutputPath) { Get-Content $OutputPath -Raw } else { '' }
        $stderr = if (Test-Path $errorPath) { Get-Content $errorPath -Raw } else { '' }
        throw "$Context timed out after $TimeoutMs ms. STDOUT:`n$stdout`nSTDERR:`n$stderr"
    }

    if (Test-Path $OutputPath) {
        Get-Content $OutputPath -Raw | Out-Host
    }

    if (Test-Path $errorPath) {
        $stderrContent = Get-Content $errorPath -Raw
        if ($stderrContent) {
            $stderrContent | Out-Host
        }
    }

    if ($process.ExitCode -ne 0) {
        throw "$Context failed with exit code $($process.ExitCode)"
    }
}

function Invoke-WebProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 3
    )

    Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
}

function Wait-ForHttp {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Headers = @{},
        [int]$Attempts = 40,
        [object]$Process = $null,
        [string]$ProcessName = 'background process',
        [string]$LogPath = ''
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
        if ($null -ne $Process) {
            if ($Process.HasExited) {
                $logOutput = if ($LogPath -and (Test-Path $LogPath)) { Get-Content $LogPath -Raw } else { '' }
                throw "$ProcessName exited before becoming ready. ExitCode=$($Process.ExitCode). Log:`n$logOutput"
            }
        }

        try {
            Invoke-WebProbe -Url $Url -Headers $Headers -TimeoutSec 3
            return
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }

    throw "Timed out waiting for HTTP endpoint: $Url"
}

function Ensure-ArtifactsDirectory {
    if (-not (Test-Path $script:ArtifactsRoot)) {
        New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    }
}

function Ensure-SeleniumDependencies {
    Write-Step 'Ensuring Selenium package dependencies...'
    Push-Location (Join-Path $script:RepoRoot 'tests\selenium')
    try {
        npm ci --prefer-offline --no-audit --fund=false | Out-Host
        Assert-LastExitCode 'npm ci (tests/selenium)'
    }
    finally {
        Pop-Location
    }
}

function Build-RequiredWorkspaces {
    Write-Step 'Building shared and Firefox extension workspaces...'
    Push-Location $script:RepoRoot
    try {
        npm run build --workspace=@openpath/shared | Out-Host
        Assert-LastExitCode 'npm run build --workspace=@openpath/shared'
        npm run build:cached --workspace=@openpath/firefox-extension | Out-Host
        Assert-LastExitCode 'npm run build:cached --workspace=@openpath/firefox-extension'
    }
    finally {
        Pop-Location
    }
}

function Start-TestPostgresDocker {
    Write-Step 'Starting PostgreSQL via Docker Compose...'
    docker compose -f "$script:RepoRoot\docker-compose.test.yml" up -d | Out-Host
    Assert-LastExitCode 'docker compose up -d'

    for ($attempt = 1; $attempt -le 30; $attempt += 1) {
        try {
            docker exec openpath-test-db pg_isready -U openpath -d openpath_test | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $script:DatabaseMode = 'docker'
                return
            }
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }

    throw 'Docker-based PostgreSQL did not become ready in time.'
}

function Get-PostgresBinDir {
    $command = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($command) {
        return Split-Path -Parent $command.Source
    }

    $candidate = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
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

    if (-not $script:PostgresBinDir) {
        throw 'PostgreSQL bin directory is not configured.'
    }

    $psql = Join-Path $script:PostgresBinDir 'psql.exe'
    $outputPath = Join-Path $script:ArtifactsRoot 'psql-last.log'
    $sqlPath = Join-Path $script:ArtifactsRoot 'psql-last.sql'

    [System.IO.File]::WriteAllText($sqlPath, "$Sql`n", [System.Text.UTF8Encoding]::new($false))

    Invoke-ProcessWithTimeout -FilePath $psql `
        -ArgumentList @('-w', '-h', '127.0.0.1', '-p', [string]$script:PostgresPort, '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-f', $sqlPath) `
        -TimeoutMs 30000 `
        -Context 'psql' `
        -OutputPath $outputPath
}

function Start-TestPostgresProcess {
    Write-Step 'Starting PostgreSQL via local process...'

    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        throw 'Chocolatey is required to install PostgreSQL on the Windows runner.'
    }

    $script:PostgresBinDir = Get-PostgresBinDir
    if (-not $script:PostgresBinDir) {
        choco install postgresql16 --params '"/Password:openpath_test"' --no-progress -y | Out-Host
        Assert-LastExitCode 'choco install postgresql16'
        $script:PostgresBinDir = Get-PostgresBinDir
    }

    if (-not $script:PostgresBinDir) {
        throw 'Could not locate PostgreSQL binaries after installation.'
    }

    $tempRoot = if ($env:RUNNER_TEMP) {
        $env:RUNNER_TEMP
    }
    else {
        [System.IO.Path]::GetTempPath()
    }

    $script:PostgresDataDir = Join-Path $tempRoot ("openpath-postgres-" + [System.Guid]::NewGuid().ToString('N'))
    $script:PostgresLogPath = Join-Path $script:ArtifactsRoot 'postgres.log'

    $initdb = Join-Path $script:PostgresBinDir 'initdb.exe'
    $pgCtl = Join-Path $script:PostgresBinDir 'pg_ctl.exe'
    $pgIsReady = Join-Path $script:PostgresBinDir 'pg_isready.exe'

    Invoke-ProcessWithTimeout -FilePath $initdb `
        -ArgumentList @('-D', $script:PostgresDataDir, '-U', 'postgres', '-A', 'trust', '-E', 'UTF8') `
        -TimeoutMs 120000 `
        -Context 'initdb' `
        -OutputPath (Join-Path $script:ArtifactsRoot 'postgres-initdb.log')

    Invoke-ProcessWithTimeout -FilePath $pgCtl `
        -ArgumentList @(
            'start',
            '-D',
            (Quote-Argument -Value $script:PostgresDataDir),
            '-l',
            (Quote-Argument -Value $script:PostgresLogPath),
            '-o',
            (Quote-Argument -Value "-p $($script:PostgresPort)"),
            '-w'
        ) `
        -TimeoutMs 120000 `
        -Context 'pg_ctl start' `
        -OutputPath (Join-Path $script:ArtifactsRoot 'postgres-start.log')

    Write-Step 'Verifying PostgreSQL readiness and bootstrap SQL...'
    for ($attempt = 1; $attempt -le 30; $attempt += 1) {
        try {
            & $pgIsReady -h 127.0.0.1 -p $script:PostgresPort -U postgres -d postgres | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "PostgreSQL ready on attempt $attempt" -ForegroundColor DarkGray
                Invoke-PostgresSql -Sql "DO `$`$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openpath') THEN CREATE ROLE openpath LOGIN PASSWORD 'openpath_test'; ELSE ALTER ROLE openpath WITH LOGIN PASSWORD 'openpath_test'; END IF; END `$`$;"
                Invoke-PostgresSql -Sql "DROP DATABASE IF EXISTS openpath_test WITH (FORCE);"
                Invoke-PostgresSql -Sql "CREATE DATABASE openpath_test OWNER openpath;"
                $script:DatabaseMode = 'local'
                return
            }
        }
        catch {
            Write-Host "PostgreSQL not ready yet (attempt $attempt): $_" -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
    }

    throw 'Local PostgreSQL process did not become ready in time.'
}

function Ensure-TestPostgres {
    try {
        if (Get-Command docker.exe -ErrorAction SilentlyContinue) {
            docker info | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Start-TestPostgresDocker
                return
            }
        }
    }
    catch {
        Write-Host 'WARN: Docker PostgreSQL bootstrap unavailable; falling back to local PostgreSQL.' -ForegroundColor Yellow
    }

    Start-TestPostgresProcess
}

function Initialize-TestDatabase {
    Write-Step 'Running API E2E database setup...'
    Push-Location $script:RepoRoot
    try {
        $env:DB_HOST = '127.0.0.1'
        $env:DB_PORT = '5433'
        $env:DB_NAME = 'openpath_test'
        $env:DB_USER = 'openpath'
        $env:DB_PASSWORD = 'openpath_test'

        if ($script:DatabaseMode -eq 'local') {
            $env:DB_PORT = [string]$script:PostgresPort
        }

        npm run db:setup:e2e --workspace=@openpath/api | Out-Host
        Assert-LastExitCode 'npm run db:setup:e2e --workspace=@openpath/api'
    }
    finally {
        Pop-Location
    }
}

function Start-ApiServer {
    Write-Step "Starting API on port $($script:ApiPort)..."
    $apiLog = Join-Path $script:ArtifactsRoot 'api.log'
    $apiErrLog = Join-Path $script:ArtifactsRoot 'api.err.log'
    $dataDir = Join-Path $script:ArtifactsRoot 'api-data'
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

    $nodeCommand = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not $nodeCommand) {
        throw 'node.exe was not found on PATH.'
    }

    $originalEnv = @{}
    foreach ($name in 'NODE_ENV','JWT_SECRET','SHARED_SECRET','DB_HOST','DB_PORT','DB_NAME','DB_USER','DB_PASSWORD','PORT','PUBLIC_URL','DATA_DIR','OPENPATH_FORCE_SERVER_START') {
        $originalEnv[$name] = (Get-Item "Env:$name" -ErrorAction SilentlyContinue).Value
    }

    try {
        $env:NODE_ENV = 'test'
        $env:JWT_SECRET = 'openpath-student-policy-secret'
        $env:SHARED_SECRET = 'openpath-student-policy-shared'
        $env:DB_HOST = '127.0.0.1'
        $env:DB_PORT = if ($script:DatabaseMode -eq 'local') { [string]$script:PostgresPort } else { '5433' }
        $env:DB_NAME = 'openpath_test'
        $env:DB_USER = 'openpath'
        $env:DB_PASSWORD = 'openpath_test'
        $env:PORT = [string]$script:ApiPort
        $env:PUBLIC_URL = "http://127.0.0.1:$($script:ApiPort)"
        $env:DATA_DIR = $dataDir
        $env:OPENPATH_FORCE_SERVER_START = 'true'

        $script:ApiProcess = Start-Process -FilePath $nodeCommand `
            -ArgumentList @('--import', 'tsx', 'api/src/server.ts') `
            -WorkingDirectory $script:RepoRoot `
            -NoNewWindow `
            -RedirectStandardOutput $apiLog `
            -RedirectStandardError $apiErrLog `
            -PassThru
    }
    finally {
        foreach ($name in $originalEnv.Keys) {
            if ($null -eq $originalEnv[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item "Env:$name" -Value $originalEnv[$name]
            }
        }
    }

    Wait-ForHttp -Url "http://127.0.0.1:$($script:ApiPort)/trpc/healthcheck.ready" -Process $script:ApiProcess -ProcessName 'API server process' -LogPath $apiLog
}

function Start-FixtureServer {
    Write-Step "Starting fixture server on port $($script:FixturePort)..."
    $fixtureLog = Join-Path $script:ArtifactsRoot 'fixture-server.log'
    $fixtureErrLog = Join-Path $script:ArtifactsRoot 'fixture-server.err.log'
    $nodeCommand = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not $nodeCommand) {
        throw 'node.exe was not found on PATH.'
    }

    $script:FixtureProcess = Start-Process -FilePath $nodeCommand `
        -ArgumentList @('--import', 'tsx', 'tests/e2e/student-flow/fixture-server.ts', '--host', '0.0.0.0', '--port', [string]$script:FixturePort) `
        -WorkingDirectory $script:RepoRoot `
        -NoNewWindow `
        -RedirectStandardOutput $fixtureLog `
        -RedirectStandardError $fixtureErrLog `
        -PassThru

    Wait-ForHttp -Url "http://127.0.0.1:$($script:FixturePort)/ok" -Headers @{ Host = "portal.127.0.0.1.sslip.io:$($script:FixturePort)" } -Process $script:FixtureProcess -ProcessName 'fixture server process' -LogPath $fixtureLog
}

function Invoke-BackendHarnessBootstrap {
    param(
        [string]$ScenarioName = 'Windows Student Policy'
    )

    Write-Step 'Bootstrapping student-policy scenario...'
    $scenarioPath = Join-Path $script:ArtifactsRoot 'student-scenario.json'
    Push-Location $script:RepoRoot
    try {
        $scenarioJson = node --import tsx tests/e2e/student-flow/backend-harness.ts bootstrap `
            --api-url "http://127.0.0.1:$($script:ApiPort)" `
            --scenario-name $ScenarioName `
            --machine-hostname $script:MachineName
        Assert-LastExitCode 'backend harness bootstrap'

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($scenarioPath, ($scenarioJson -join [Environment]::NewLine), $utf8NoBom)
    }
    finally {
        Pop-Location
    }

    return Get-Content $scenarioPath -Raw | ConvertFrom-Json
}

function New-FirefoxExtensionArchive {
    Write-Step 'Packaging Firefox extension XPI for Selenium...'
    $packagePath = Join-Path $script:ArtifactsRoot 'openpath-firefox-extension.xpi'
    if (Test-Path $packagePath) {
        Remove-Item $packagePath -Force
    }

    $bashCommand = (Get-Command bash.exe -ErrorAction SilentlyContinue).Source
    if (-not $bashCommand) {
        throw 'bash.exe is required to package the Firefox extension XPI on the Windows runner.'
    }

    $extensionDir = Join-Path $script:RepoRoot 'firefox-extension'
    $manifest = Get-Content (Join-Path $extensionDir 'manifest.json') -Raw | ConvertFrom-Json
    $expectedName = "monitor-bloqueos-red-$($manifest.version).xpi"
    $builtXpiPath = Join-Path $extensionDir $expectedName
    if (Test-Path $builtXpiPath) {
        Remove-Item $builtXpiPath -Force
    }

    & $bashCommand (Join-Path $extensionDir 'build-xpi.sh') | Out-Host
    Assert-LastExitCode 'firefox-extension/build-xpi.sh'

    if (-not (Test-Path $builtXpiPath)) {
        throw "Firefox extension packaging did not produce $builtXpiPath"
    }

    $xpiHash = (Get-FileHash -Algorithm SHA256 -Path $builtXpiPath).Hash.ToLowerInvariant()
    $hashEvidencePath = Join-Path $script:ArtifactsRoot 'firefox-xpi-sha256.txt'
    Set-Content -Path $hashEvidencePath -Value "$xpiHash  $builtXpiPath" -Encoding UTF8
    Write-DiagnosticNote "Firefox XPI hash sha256=$xpiHash path=$builtXpiPath"

    Copy-Item $builtXpiPath -Destination $packagePath -Force
    return $packagePath
}

function Enable-FirefoxUnsignedAddonSupport {
    Write-Step 'Configuring Firefox for unsigned Selenium addons...'

    $firefoxBinaryPath = Get-FirefoxBinaryPath
    if (-not $firefoxBinaryPath) {
        throw 'Firefox executable not found in the expected install locations.'
    }
    $firefoxDir = Split-Path -Parent $firefoxBinaryPath

    $defaultsPrefDir = Join-Path $firefoxDir 'defaults\pref'
    $autoconfigPath = Join-Path $defaultsPrefDir 'autoconfig.js'
    $mozillaCfgPath = Join-Path $firefoxDir 'mozilla.cfg'

    $script:FirefoxUnsignedAddonSupportState = [pscustomobject]@{
        Autoconfig = Backup-FirefoxConfigFile -Path $autoconfigPath
        MozillaCfg = Backup-FirefoxConfigFile -Path $mozillaCfgPath
    }

    Write-Utf8NoBomLfFile -Path $autoconfigPath -Lines @(
        '// OpenPath Selenium Firefox autoconfig',
        'pref("general.config.filename", "mozilla.cfg");',
        'pref("general.config.obscure_value", 0);'
    )

    Write-Utf8NoBomLfFile -Path $mozillaCfgPath -Lines @(
        '// OpenPath Selenium Firefox configuration',
        'lockPref("xpinstall.signatures.required", false);',
        'lockPref("extensions.langpacks.signatures.required", false);',
        'lockPref("extensions.blocklist.enabled", false);'
    )
}

function Restore-FirefoxUnsignedAddonSupport {
    if ($null -eq $script:FirefoxUnsignedAddonSupportState) {
        return
    }

    $restoreError = $null

    try {
        Restore-FirefoxConfigFile -Snapshot $script:FirefoxUnsignedAddonSupportState.Autoconfig
    }
    catch {
        $restoreError = $_
    }

    try {
        Restore-FirefoxConfigFile -Snapshot $script:FirefoxUnsignedAddonSupportState.MozillaCfg
    }
    catch {
        if ($null -eq $restoreError) {
            $restoreError = $_
        }
    }

    $script:FirefoxUnsignedAddonSupportState = $null

    if ($null -ne $restoreError) {
        throw $restoreError
    }
}

function Ensure-FirefoxAndGeckodriver {
    Write-Step 'Ensuring Firefox and geckodriver are available...'

    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        throw 'Chocolatey is required to install Firefox and geckodriver on the Windows runner.'
    }

    if (-not (Get-FirefoxBinaryPath)) {
        choco install firefox-nightly --pre --no-progress -y | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-DiagnosticNote "Firefox Nightly install failed with exit $LASTEXITCODE."
        }
        elseif (-not (Get-FirefoxBinaryPath)) {
            Write-DiagnosticNote 'Firefox Nightly install completed without a usable Nightly binary.'
        }
    }

    if (-not (Get-FirefoxBinaryPath)) {
        Write-DiagnosticNote 'Trying Firefox Developer Edition because Nightly is unavailable.'
        choco install firefox-dev --pre --no-progress -y | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-DiagnosticNote "Firefox Developer Edition install failed with exit $LASTEXITCODE."
        }
        elseif (-not (Get-FirefoxBinaryPath)) {
            Write-DiagnosticNote 'Firefox Developer Edition install completed without a usable Developer Edition binary.'
        }
    }

    if (-not (Get-FirefoxBinaryPath)) {
        $releasePath = Get-FirefoxBinaryPath -AllowRelease
        if ($releasePath) {
            throw "Only Firefox Release was found at $releasePath; the student-policy Selenium suite requires Nightly or Developer Edition so unsigned test extensions can load."
        }
    }

    if (-not (Get-FirefoxBinaryPath)) {
        throw 'Firefox Nightly or Developer Edition executable not found after Chocolatey provisioning.'
    }

    if (-not (Get-Command geckodriver.exe -ErrorAction SilentlyContinue)) {
        choco install geckodriver --no-progress -y | Out-Host
        Assert-LastExitCode 'choco install geckodriver'
    }
}

function Get-EnrollmentTicket {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Scenario
    )

    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:ApiPort)/api/enroll/$($Scenario.classroom.id)/ticket" `
        -Headers @{ Authorization = "Bearer $($Scenario.auth.teacher.accessToken)" } `
        -Method Post

    return [string]$response.enrollmentToken
}

function Get-AcrylicRootCandidates {
    $roots = @()
    if (${env:ProgramFiles(x86)}) {
        $roots += Join-Path ${env:ProgramFiles(x86)} 'Acrylic DNS Proxy'
    }
    if ($env:ProgramFiles) {
        $roots += Join-Path $env:ProgramFiles 'Acrylic DNS Proxy'
    }

    return $roots | Select-Object -Unique
}

function Get-AcrylicConfigurationPath {
    foreach ($acrylicRoot in Get-AcrylicRootCandidates) {
        $candidatePath = Join-Path $acrylicRoot 'AcrylicConfiguration.ini'
        if (Test-Path $candidatePath) {
            return $candidatePath
        }
    }

    return $null
}

function Get-AcrylicHostsPath {
    foreach ($acrylicRoot in Get-AcrylicRootCandidates) {
        $candidatePath = Join-Path $acrylicRoot 'AcrylicHosts.txt'
        if (Test-Path $candidatePath) {
            return $candidatePath
        }
    }

    return $null
}

function Assert-InstalledAcrylicRuntime {
    Write-Step 'Verifying installed Windows Acrylic runtime...'

    $runtimePath = 'C:\OpenPath\lib\internal\DNS.Acrylic.Config.ps1'
    if (-not (Test-Path $runtimePath)) {
        throw "Installed Acrylic runtime missing at $runtimePath"
    }

    $runtimeContent = Get-Content $runtimePath -Raw
    $runtimeHash = (Get-FileHash -Algorithm SHA256 -Path $runtimePath).Hash
    $requiredRuntimeMarkers = @(
        'Set-AcrylicGlobalSetting',
        '"PrimaryServerPort" = "53"',
        '"PrimaryServerProtocol" = "UDP"',
        '"SecondaryServerPort" = "53"',
        '"SecondaryServerProtocol" = "UDP"',
        '"AddressCacheDisabled" = "No"',
        '[AllowedAddressesSection]'
    )
    $missingRuntimeMarkers = @($requiredRuntimeMarkers | Where-Object { -not $runtimeContent.Contains($_) })
    if ($missingRuntimeMarkers.Count -gt 0) {
        throw "Installed Acrylic runtime is stale or incomplete at $runtimePath (sha256=$runtimeHash); missing markers: $($missingRuntimeMarkers -join ', ')"
    }

    $configPath = Get-AcrylicConfigurationPath
    if (-not $configPath) {
        throw 'AcrylicConfiguration.ini was not found after Windows client install/update.'
    }

    $configContent = Get-Content $configPath -Raw
    $configHash = (Get-FileHash -Algorithm SHA256 -Path $configPath).Hash
    $requiredConfigMarkers = @(
        '[GlobalSection]',
        'PrimaryServerPort=53',
        'PrimaryServerProtocol=UDP',
        'SecondaryServerPort=53',
        'SecondaryServerProtocol=UDP',
        'LocalIPv4BindingAddress=0.0.0.0',
        'LocalIPv4BindingPort=53',
        'PrimaryServerDomainNameAffinityMask=raw.githubusercontent.com',
        'SecondaryServerDomainNameAffinityMask=raw.githubusercontent.com',
        'AddressCacheDisabled=No',
        'IP1=127.*',
        'IP2=::1',
        '[AllowedAddressesSection]'
    )
    $missingConfigMarkers = @($requiredConfigMarkers | Where-Object { -not $configContent.Contains($_) })
    if ($missingConfigMarkers.Count -gt 0) {
        throw "AcrylicConfiguration.ini is missing required Windows student-policy defaults at $configPath (sha256=$configHash); missing markers: $($missingConfigMarkers -join ', ')"
    }

    $hostsPath = Get-AcrylicHostsPath
    if (-not $hostsPath) {
        throw 'AcrylicHosts.txt was not found after Windows client install/update.'
    }

    $hostsContent = Get-Content $hostsPath -Raw
    $hostsHash = (Get-FileHash -Algorithm SHA256 -Path $hostsPath).Hash
    $requiredHostsMarkers = @(
        'FW raw.githubusercontent.com',
        'FW github.com',
        'NX *'
    )
    $missingHostsMarkers = @($requiredHostsMarkers | Where-Object { -not $hostsContent.Contains($_) })
    if ($missingHostsMarkers.Count -gt 0) {
        throw "AcrylicHosts.txt is missing required Windows student-policy rules at $hostsPath (sha256=$hostsHash); missing markers: $($missingHostsMarkers -join ', ')"
    }

    Write-DiagnosticNote "Installed Acrylic runtime hash sha256=$runtimeHash path=$runtimePath"
    Write-DiagnosticNote "AcrylicConfiguration.ini hash sha256=$configHash path=$configPath"
    Write-DiagnosticNote "AcrylicHosts.txt hash sha256=$hostsHash path=$hostsPath"
}

function Assert-WindowsDnsPolicyReady {
    Write-Step 'Verifying Windows DNS policy readiness...'

    $udpListeners = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue)
    $tcpListeners = @(Get-NetTCPConnection -LocalPort 53 -ErrorAction SilentlyContinue)
    if ($udpListeners.Count -eq 0 -and $tcpListeners.Count -eq 0) {
        throw 'Acrylic DNS service is not listening on local port 53 after install/enroll/update.'
    }

    $dnsErrors = @()
    foreach ($probeHost in @(
            'raw.githubusercontent.com',
            'github.com'
        )) {
        try {
            $result = Resolve-DnsName -Name $probeHost -Server 127.0.0.1 -DnsOnly -ErrorAction Stop
            if (-not $result) {
                $dnsErrors += "$probeHost returned no records"
            }
        }
        catch {
            $dnsErrors += "$probeHost failed: $($_.Exception.Message)"
        }
    }

    $blockedProbeHost = 'blocked.127.0.0.1.sslip.io'
    $blockedFixtureIp = '127.0.0.1'
    try {
        $blockedAddresses = @(
            Resolve-DnsName -Name $blockedProbeHost -Server 127.0.0.1 -DnsOnly -ErrorAction Stop |
                Where-Object { $_.IPAddress } |
                ForEach-Object { [string]$_.IPAddress }
        )
        if ($blockedAddresses -contains $blockedFixtureIp) {
            $dnsErrors += "$blockedProbeHost resolved to $blockedFixtureIp through Acrylic, expected default deny"
        }
    }
    catch {
        Write-DiagnosticNote "$blockedProbeHost returned DNS error through Acrylic, treating as blocked: $($_.Exception.Message)"
    }

    if ($dnsErrors.Count -gt 0) {
        throw "Acrylic DNS policy readiness failed before Selenium: $($dnsErrors -join '; ')"
    }

    Write-DiagnosticNote 'Windows DNS policy readiness verified through local Acrylic.'
}

function Wait-WindowsDnsPolicyReady {
    $maxAttempts = 12
    if ($env:OPENPATH_WINDOWS_DNS_READINESS_ATTEMPTS) {
        $parsedAttempts = 0
        if (
            [int]::TryParse($env:OPENPATH_WINDOWS_DNS_READINESS_ATTEMPTS, [ref]$parsedAttempts) -and
            $parsedAttempts -gt 0
        ) {
            $maxAttempts = $parsedAttempts
        }
    }

    $delaySeconds = 5
    if ($env:OPENPATH_WINDOWS_DNS_READINESS_DELAY_SECONDS) {
        $parsedDelay = 0
        if (
            [int]::TryParse($env:OPENPATH_WINDOWS_DNS_READINESS_DELAY_SECONDS, [ref]$parsedDelay) -and
            $parsedDelay -gt 0
        ) {
            $delaySeconds = $parsedDelay
        }
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-DiagnosticNote "Windows DNS policy readiness attempt $attempt/$maxAttempts"
            Assert-WindowsDnsPolicyReady
            return
        }
        catch {
            $lastError = $_
            Write-DiagnosticNote "Windows DNS policy readiness attempt $attempt/$maxAttempts failed: $($_.Exception.Message)"
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds $delaySeconds
            }
        }
    }

    Invoke-DebugDump
    throw "Windows DNS policy readiness did not converge after $maxAttempts attempts: $($lastError.Exception.Message)"
}

function Install-AndEnrollClient {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Scenario,
        [bool]$InstallClient = $true
    )

    if ($InstallClient) {
        Write-Step 'Installing and enrolling the Windows OpenPath client...'

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot 'windows\Install-OpenPath.ps1') `
            -WhitelistUrl $Scenario.machine.whitelistUrl `
            -ApiUrl "http://127.0.0.1:$($script:ApiPort)" `
            -Unattended

        if ($LASTEXITCODE -ne 0) {
            throw "Install-OpenPath.ps1 failed with exit code $LASTEXITCODE"
        }
    }
    else {
        Write-Step 'Reconfiguring existing Windows OpenPath client...'
    }

    $enrollmentToken = Get-EnrollmentTicket -Scenario $Scenario
    Write-DiagnosticNote "Enrollment ticket acquired for classroom $($Scenario.classroom.id); installClient=$InstallClient"

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot 'windows\scripts\Enroll-Machine.ps1') `
        -ApiUrl "http://127.0.0.1:$($script:ApiPort)" `
        -ClassroomId $Scenario.classroom.id `
        -EnrollmentToken $enrollmentToken `
        -MachineName $script:MachineName `
        -Unattended

    if ($LASTEXITCODE -ne 0) {
        throw "Enroll-Machine.ps1 failed with exit code $LASTEXITCODE"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\OpenPath\scripts\Update-OpenPath.ps1'
    if ($LASTEXITCODE -ne 0) {
        throw "Update-OpenPath.ps1 failed with exit code $LASTEXITCODE"
    }

    Assert-InstalledAcrylicRuntime
    Wait-WindowsDnsPolicyReady

    $scenarioPath = Join-Path $script:ArtifactsRoot 'student-scenario.json'
    if (-not (Test-Path $scenarioPath)) {
        throw "student-scenario.json missing at $scenarioPath"
    }

    $config = Get-Content 'C:\OpenPath\data\config.json' -Raw | ConvertFrom-Json
    $configWhitelistUrl = [string]$config.whitelistUrl
    if (-not $configWhitelistUrl) {
        throw 'Installed client config is missing whitelistUrl'
    }

    Write-DiagnosticNote "Installed client config whitelistUrl: $configWhitelistUrl"
    Write-DiagnosticNote "Scenario file before reconciliation: $(Get-Content $scenarioPath -Raw)"

    $nodeCommand = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not $nodeCommand) {
        throw 'node.exe was not found on PATH.'
    }

    $reconcileLogPath = Join-Path $script:ArtifactsRoot 'reconcile-student-scenario.log'
    $reconcileErrPath = Join-Path $script:ArtifactsRoot 'reconcile-student-scenario.err.log'
    & $nodeCommand --import tsx tests/e2e/student-flow/reconcile-student-scenario.ts `
        --scenario-file $scenarioPath `
        --whitelist-url $configWhitelistUrl `
        1>> $reconcileLogPath 2>> $reconcileErrPath
    Assert-LastExitCode 'student scenario reconciliation'

    Write-DiagnosticNote "Scenario file after reconciliation: $(Get-Content $scenarioPath -Raw)"
}

function Invoke-SeleniumStudentSuite {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioPath,
        [Parameter(Mandatory = $true)][string]$ExtensionArchivePath,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][ValidateSet('full', 'fallback-propagation')][string]$CoverageProfile,
        [ValidateSet('full', 'request-lifecycle', 'ajax-auto-allow', 'path-blocking', 'exemptions')][string]$ScenarioGroup = 'full'
    )

    Push-Location (Join-Path $script:RepoRoot 'tests\selenium')
    try {
        $originalFirefoxBinary = $env:OPENPATH_FIREFOX_BINARY
        $originalCoverageProfile = $env:OPENPATH_STUDENT_COVERAGE_PROFILE
        $originalScenarioGroup = $env:OPENPATH_STUDENT_SCENARIO_GROUP
        $originalDiagnosticsDir = $env:OPENPATH_STUDENT_DIAGNOSTICS_DIR
        $env:OPENPATH_STUDENT_SCENARIO_FILE = $ScenarioPath
        $env:OPENPATH_FIXTURE_PORT = [string]$script:FixturePort
        $env:OPENPATH_EXTENSION_PATH = $ExtensionArchivePath
        $env:OPENPATH_STUDENT_DIAGNOSTICS_DIR = $script:ArtifactsRoot
        $env:OPENPATH_WHITELIST_PATH = 'C:\OpenPath\data\whitelist.txt'
        $env:OPENPATH_FORCE_UPDATE_COMMAND = 'powershell -NoLogo -File "C:\OpenPath\scripts\Update-OpenPath.ps1"'
        $env:OPENPATH_DISABLE_SSE_COMMAND = 'powershell -NoLogo -Command "Disable-ScheduledTask -TaskName ''OpenPath-SSE'' -ErrorAction SilentlyContinue; Stop-ScheduledTask -TaskName ''OpenPath-SSE'' -ErrorAction SilentlyContinue"'
        $env:OPENPATH_ENABLE_SSE_COMMAND = 'powershell -NoLogo -Command "Enable-ScheduledTask -TaskName ''OpenPath-SSE'' -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskName ''OpenPath-SSE'' -ErrorAction SilentlyContinue"'
        $env:CI = 'true'
        $env:OPENPATH_STUDENT_MODE = $Mode
        $env:OPENPATH_STUDENT_COVERAGE_PROFILE = $CoverageProfile
        if ($ScenarioGroup -ne 'full') {
            $env:OPENPATH_STUDENT_SCENARIO_GROUP = $ScenarioGroup
        }
        else {
            Remove-Item Env:\OPENPATH_STUDENT_SCENARIO_GROUP -ErrorAction SilentlyContinue
        }
        $env:OPENPATH_FIREFOX_BINARY = Get-FirefoxBinaryPath
        if (-not $env:OPENPATH_FIREFOX_BINARY) {
            throw 'Firefox executable not found before Selenium startup.'
        }

        Write-DiagnosticNote "Starting Selenium student-policy suite mode=$Mode coverageProfile=$CoverageProfile scenarioGroup=$ScenarioGroup scenarioPath=$ScenarioPath extensionPath=$ExtensionArchivePath"
        Write-DiagnosticNote "Scenario payload at Selenium handoff: $(Get-Content $ScenarioPath -Raw)"

        $npmCommand = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
        if (-not $npmCommand) {
            throw 'npm.cmd was not found on PATH.'
        }

        $logPath = Join-Path $script:ArtifactsRoot ("windows-student-policy-$Mode.log")
        $errorPath = Join-Path $script:ArtifactsRoot ("windows-student-policy-$Mode.err.log")
        $process = Start-Process -FilePath $npmCommand `
            -ArgumentList @('run', 'test:student-policy:ci') `
            -WorkingDirectory (Get-Location).Path `
            -NoNewWindow `
            -RedirectStandardOutput $logPath `
            -RedirectStandardError $errorPath `
            -PassThru

        if (-not $process.WaitForExit(1200000)) {
            try {
                $process.Kill($true)
            }
            catch {
                # Best effort.
            }

            $tail = if (Test-Path $logPath) { Get-Content $logPath -Raw } else { '' }
            $errorTail = if (Test-Path $errorPath) { Get-Content $errorPath -Raw } else { '' }
            throw "Windows student-policy Selenium ($Mode) timed out after 20 minutes. STDOUT:`n$tail`nSTDERR:`n$errorTail"
        }

        if (Test-Path $logPath) {
            Get-Content $logPath -Raw | Out-Host
        }

        if (Test-Path $errorPath) {
            $stderrContent = Get-Content $errorPath -Raw
            if ($stderrContent) {
                $stderrContent | Out-Host
            }
        }

        if ($process.ExitCode -ne 0) {
            throw "npm run test:student-policy:ci ($Mode) failed with exit code $($process.ExitCode)"
        }
    }
    finally {
        Remove-Item Env:\OPENPATH_STUDENT_SCENARIO_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENPATH_FIXTURE_PORT -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENPATH_EXTENSION_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENPATH_WHITELIST_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENPATH_FORCE_UPDATE_COMMAND -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENPATH_DISABLE_SSE_COMMAND -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENPATH_ENABLE_SSE_COMMAND -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENPATH_STUDENT_MODE -ErrorAction SilentlyContinue
        if ($null -ne $originalCoverageProfile) {
            $env:OPENPATH_STUDENT_COVERAGE_PROFILE = $originalCoverageProfile
        }
        else {
            Remove-Item Env:\OPENPATH_STUDENT_COVERAGE_PROFILE -ErrorAction SilentlyContinue
        }
        if ($null -ne $originalScenarioGroup) {
            $env:OPENPATH_STUDENT_SCENARIO_GROUP = $originalScenarioGroup
        }
        else {
            Remove-Item Env:\OPENPATH_STUDENT_SCENARIO_GROUP -ErrorAction SilentlyContinue
        }
        if ($null -ne $originalFirefoxBinary) {
            $env:OPENPATH_FIREFOX_BINARY = $originalFirefoxBinary
        }
        else {
            Remove-Item Env:\OPENPATH_FIREFOX_BINARY -ErrorAction SilentlyContinue
        }
        if ($null -ne $originalDiagnosticsDir) {
            $env:OPENPATH_STUDENT_DIAGNOSTICS_DIR = $originalDiagnosticsDir
        }
        else {
            Remove-Item Env:\OPENPATH_STUDENT_DIAGNOSTICS_DIR -ErrorAction SilentlyContinue
        }
        Pop-Location
    }
}

function Write-WindowsDiagnostics {
    Write-Step 'Collecting Windows student-policy diagnostics...'

    $diagnosticPath = Join-Path $script:ArtifactsRoot 'windows-diagnostics.txt'
    $whitelistPath = 'C:\OpenPath\data\whitelist.txt'
    $logPath = 'C:\OpenPath\data\logs\openpath.log'
    $acrylicArtifactDir = Join-Path $script:ArtifactsRoot 'acrylic'
    $runtimeArtifactDir = Join-Path $script:ArtifactsRoot 'installed-runtime'
    $acrylicFiles = @(
        'AcrylicConfiguration.ini',
        'AcrylicHosts.txt',
        'AcrylicCache.dat',
        'AcrylicDebug.txt'
    )
    $acrylicRoots = Get-AcrylicRootCandidates
    $installedRuntimeFiles = @(
        'C:\OpenPath\lib\DNS.psm1',
        'C:\OpenPath\lib\internal\DNS.Acrylic.Config.ps1'
    )

    New-Item -ItemType Directory -Path $acrylicArtifactDir -Force | Out-Null
    foreach ($acrylicRoot in $acrylicRoots) {
        foreach ($fileName in $acrylicFiles) {
            $candidatePath = Join-Path $acrylicRoot $fileName
            if (Test-Path $candidatePath) {
                $destinationPath = Join-Path $acrylicArtifactDir $fileName
                Copy-Item $candidatePath -Destination $destinationPath -Force
            }
        }
    }

    New-Item -ItemType Directory -Path $runtimeArtifactDir -Force | Out-Null
    foreach ($runtimeFile in $installedRuntimeFiles) {
        if (Test-Path $runtimeFile) {
            Copy-Item $runtimeFile -Destination (Join-Path $runtimeArtifactDir (Split-Path $runtimeFile -Leaf)) -Force
        }
    }

    $runtimeEvidenceOutput = foreach ($runtimeFile in $installedRuntimeFiles) {
        "=== Installed Runtime $runtimeFile ==="
        if (Test-Path $runtimeFile) {
            Get-FileHash -Algorithm SHA256 -Path $runtimeFile | Format-List | Out-String
            if ($runtimeFile -like '*DNS.Acrylic.Config.ps1') {
                $runtimeContent = Get-Content $runtimeFile -Raw
                foreach ($marker in @('Set-AcrylicGlobalSetting', 'PrimaryServerPort', 'AllowedAddressesSection')) {
                    "$marker=$($runtimeContent.Contains($marker))"
                }
            }
        }
        else {
            'MISSING'
        }
    }

    $acrylicFileEvidenceOutput = foreach ($acrylicRoot in $acrylicRoots) {
        foreach ($fileName in $acrylicFiles) {
            $candidatePath = Join-Path $acrylicRoot $fileName
            "=== Acrylic File $candidatePath ==="
            if (Test-Path $candidatePath) {
                Get-FileHash -Algorithm SHA256 -Path $candidatePath | Format-List | Out-String
            }
            else {
                'MISSING'
            }
        }
    }

    $acrylicServiceProcessOutput = try {
        $serviceProcess = Get-CimInstance -ClassName Win32_Service -Filter "Name='AcrylicDNSProxySvc'" -ErrorAction Stop
        @(
            ($serviceProcess | Select-Object Name, State, Status, ProcessId, PathName, StartName, ExitCode | Format-List | Out-String)
            $(if ($serviceProcess.ProcessId -and $serviceProcess.ProcessId -gt 0) {
                    Get-Process -Id $serviceProcess.ProcessId -ErrorAction SilentlyContinue | Format-List Id, ProcessName, Path, StartTime, Responding | Out-String
                }
                else {
                    'Acrylic service has no active process id.'
                })
        )
    }
    catch {
        "ERROR: $($_.Exception.Message)"
    }

    $acrylicEventLogOutput = try {
        $since = (Get-Date).AddHours(-2)
        @(
            '--- Application events mentioning Acrylic ---'
            (Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction Stop |
                Where-Object { $_.ProviderName -like '*Acrylic*' -or $_.Message -like '*Acrylic*' } |
                Select-Object -First 30 TimeCreated, ProviderName, Id, LevelDisplayName, Message |
                Format-List | Out-String)
            '--- Service Control Manager events mentioning Acrylic ---'
            (Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = $since } -ErrorAction Stop |
                Where-Object { $_.Message -like '*Acrylic*' } |
                Select-Object -First 30 TimeCreated, ProviderName, Id, LevelDisplayName, Message |
                Format-List | Out-String)
        )
    }
    catch {
        "ERROR: $($_.Exception.Message)"
    }

    $dnsProbeOutput = foreach ($probeHost in @(
            'google.com',
            'portal.127.0.0.1.sslip.io',
            'api.site.127.0.0.1.sslip.io',
            'blocked.127.0.0.1.sslip.io'
        )) {
        "=== Resolve-DnsName $probeHost via 127.0.0.1 ==="
        try {
            Resolve-DnsName -Name $probeHost -Server 127.0.0.1 -DnsOnly -ErrorAction Stop | Out-String
        }
        catch {
            "ERROR: $($_.Exception.Message)"
        }
    }

    @(
        '=== Scheduled Tasks ==='
        (Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue | Format-List | Out-String)
        '=== Acrylic Service ==='
        (Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue | Format-List | Out-String)
        '=== DNS Port 53 Listeners ==='
        (Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String)
        (Get-NetTCPConnection -LocalPort 53 -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String)
        '=== OpenPath Firewall DNS Rules ==='
        (Get-NetFirewallRule -DisplayName 'OpenPath-DNS-*' -ErrorAction SilentlyContinue | Format-Table DisplayName, Enabled, Direction, Action -AutoSize | Out-String)
        '=== OpenPath Config ==='
        $(if (Test-Path 'C:\OpenPath\data\config.json') { Get-Content 'C:\OpenPath\data\config.json' -Raw } else { 'Config file missing' })
        '=== Student Scenario ==='
        $(if (Test-Path (Join-Path $script:ArtifactsRoot 'student-scenario.json')) { Get-Content (Join-Path $script:ArtifactsRoot 'student-scenario.json') -Raw } else { 'Student scenario missing' })
        '=== Installed Runtime Evidence ==='
        ($runtimeEvidenceOutput | Out-String)
        '=== Acrylic File Evidence ==='
        ($acrylicFileEvidenceOutput | Out-String)
        '=== Acrylic Service Process Evidence ==='
        ($acrylicServiceProcessOutput | Out-String)
        '=== Acrylic Event Log Evidence ==='
        ($acrylicEventLogOutput | Out-String)
        '=== DNS Probes ==='
        ($dnsProbeOutput | Out-String)
        '=== Whitelist ==='
        $(if (Test-Path $whitelistPath) { Get-Content $whitelistPath -Raw } else { 'Whitelist file missing' })
        '=== OpenPath Log Tail ==='
        $(if (Test-Path $logPath) { Get-Content $logPath -Tail 200 | Out-String } else { 'OpenPath log missing' })
    ) | Set-Content -Path $diagnosticPath -Encoding UTF8
}

function Stop-BackgroundJobs {
    foreach ($process in @($script:ApiProcess, $script:FixtureProcess)) {
        if ($null -ne $process -and -not $process.HasExited) {
            try {
                $process.Kill($true)
            }
            catch {
                # Best effort.
            }
        }
    }
}

function Cleanup-TestPostgres {
    if ($script:DatabaseMode -eq 'docker') {
        docker compose -f "$script:RepoRoot\docker-compose.test.yml" down | Out-Null
    }

    if ($script:DatabaseMode -eq 'local' -and $script:PostgresBinDir -and $script:PostgresDataDir) {
        $pgCtl = Join-Path $script:PostgresBinDir 'pg_ctl.exe'
        if (Test-Path $pgCtl) {
            & $pgCtl stop -D $script:PostgresDataDir -m fast | Out-Null
        }

        if (Test-Path $script:PostgresDataDir) {
            Remove-Item $script:PostgresDataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-DebugDump {
    Write-WindowsDiagnostics
    foreach ($logPath in @(
        (Join-Path $script:ArtifactsRoot 'api.log'),
        (Join-Path $script:ArtifactsRoot 'api.err.log'),
        (Join-Path $script:ArtifactsRoot 'fixture-server.log'),
        (Join-Path $script:ArtifactsRoot 'fixture-server.err.log'),
        (Join-Path $script:ArtifactsRoot 'windows-student-policy-trace.log'),
        (Join-Path $script:ArtifactsRoot 'reconcile-student-scenario.log'),
        (Join-Path $script:ArtifactsRoot 'reconcile-student-scenario.err.log')
    )) {
        if (Test-Path $logPath) {
            Write-Host "===== $(Split-Path $logPath -Leaf) ====="
            Get-Content $logPath -Raw | Write-Host
        }
    }
}

function Invoke-WindowsBrowserEnforcementProbes {
    $probeScript = Join-Path $script:RepoRoot 'tests\e2e\ci\windows-browser-enforcement.ps1'
    if (-not (Test-Path $probeScript)) {
        throw "Windows browser enforcement probe script not found: $probeScript"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript `
        -Scope Student `
        -ExecuteProbes `
        -PrepareProbeFiles `
        -ArtifactsRoot $script:ArtifactsRoot

    if ($LASTEXITCODE -ne 0) {
        throw "windows-browser-enforcement.ps1 failed with exit code $LASTEXITCODE"
    }
}

try {
    Ensure-ArtifactsDirectory
    Invoke-TimedStep -Name 'Build workspaces' -ScriptBlock { Build-RequiredWorkspaces }
    Invoke-TimedStep -Name 'Install Selenium dependencies' -ScriptBlock { Ensure-SeleniumDependencies }
    Invoke-TimedStep -Name 'Ensure test PostgreSQL' -ScriptBlock { Ensure-TestPostgres }
    Invoke-TimedStep -Name 'Initialize test database' -ScriptBlock { Initialize-TestDatabase }
    Invoke-TimedStep -Name 'Start API server' -ScriptBlock { Start-ApiServer }
    Invoke-TimedStep -Name 'Start fixture server' -ScriptBlock { Start-FixtureServer }
    $scenario = Invoke-TimedStep -Name 'Bootstrap scenario (sse)' -ScriptBlock { Invoke-BackendHarnessBootstrap -ScenarioName 'Windows Student Policy SSE' }
    $scenarioPath = Join-Path $script:ArtifactsRoot 'student-scenario.json'
    $extensionArchivePath = Invoke-TimedStep -Name 'Package Firefox extension' -ScriptBlock { New-FirefoxExtensionArchive }
    Invoke-TimedStep -Name 'Ensure Firefox and geckodriver' -ScriptBlock { Ensure-FirefoxAndGeckodriver }
    Invoke-TimedStep -Name 'Enable Firefox unsigned addon support' -ScriptBlock { Enable-FirefoxUnsignedAddonSupport }
    Invoke-TimedStep -Name 'Install and enroll client (sse)' -ScriptBlock { Install-AndEnrollClient -Scenario $scenario -InstallClient $true }
    $windowsStudentSseGroup = if ([string]::IsNullOrWhiteSpace($env:OPENPATH_WINDOWS_STUDENT_SSE_GROUP)) {
        Resolve-WindowsStudentSseGroup
    }
    else {
        Resolve-WindowsStudentSseGroup -ScenarioGroup $env:OPENPATH_WINDOWS_STUDENT_SSE_GROUP
    }
    Invoke-TimedStep -Name "Run Selenium student suite (sse, $windowsStudentSseGroup)" -ScriptBlock { Invoke-SeleniumStudentSuite -ScenarioPath $scenarioPath -ExtensionArchivePath $extensionArchivePath -Mode 'sse' -CoverageProfile 'full' -ScenarioGroup $windowsStudentSseGroup }
    if ($RunBrowserEnforcementProbes -or $env:OPENPATH_WINDOWS_BROWSER_ENFORCEMENT_PROBES -eq '1') {
        Invoke-TimedStep -Name 'Run Windows browser enforcement probes' -ScriptBlock { Invoke-WindowsBrowserEnforcementProbes }
    }
    $scenario = Invoke-TimedStep -Name 'Bootstrap scenario (fallback)' -ScriptBlock { Invoke-BackendHarnessBootstrap -ScenarioName 'Windows Student Policy Fallback' }
    Invoke-TimedStep -Name 'Install and enroll client (fallback)' -ScriptBlock { Install-AndEnrollClient -Scenario $scenario -InstallClient $false }
    Invoke-TimedStep -Name 'Run Selenium student suite (fallback, fallback-propagation)' -ScriptBlock { Invoke-SeleniumStudentSuite -ScenarioPath $scenarioPath -ExtensionArchivePath $extensionArchivePath -Mode 'fallback' -CoverageProfile 'fallback-propagation' }
    Invoke-TimedStep -Name 'Collect Windows diagnostics' -ScriptBlock { Write-WindowsDiagnostics }
    $script:RunSucceeded = $true
}
catch {
    $script:PrimaryFailure = $_
    Write-Host "Windows student-policy runner failed: $_" -ForegroundColor Red
    Invoke-DebugDump
    Publish-GitHubFailureAnnotations
    Publish-GitHubStepSummary -Mode 'failure'
    throw
}
finally {
    $cleanupError = $null

    try {
        Invoke-TimedStep -Name 'Uninstall OpenPath client' -ScriptBlock {
            $uninstallArgs = Get-OpenPathUninstallArgs
            & powershell.exe @uninstallArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Uninstall-OpenPath.ps1 failed with exit code $LASTEXITCODE"
            }
        }
    }
    catch {
        $cleanupError = $_
    }

    try {
        Invoke-TimedStep -Name 'Restore Firefox unsigned addon support' -ScriptBlock { Restore-FirefoxUnsignedAddonSupport }
    }
    catch {
        if ($null -eq $cleanupError) {
            $cleanupError = $_
        }
    }

    try {
        Invoke-TimedStep -Name 'Stop background jobs' -ScriptBlock { Stop-BackgroundJobs }
    }
    catch {
        if ($null -eq $cleanupError) {
            $cleanupError = $_
        }
    }

    try {
        Invoke-TimedStep -Name 'Cleanup test PostgreSQL' -ScriptBlock { Cleanup-TestPostgres }
    }
    catch {
        if ($null -eq $cleanupError) {
            $cleanupError = $_
        }
    }

    if (($null -ne $cleanupError) -and ($null -eq $script:PrimaryFailure)) {
        throw $cleanupError
    }

    if (($null -ne $cleanupError) -and ($null -ne $script:PrimaryFailure)) {
        Write-Host "Cleanup failed after primary error: $cleanupError" -ForegroundColor Yellow
    }

    if (($script:RunSucceeded) -and ($null -eq $cleanupError) -and ($null -eq $script:PrimaryFailure)) {
        Publish-GitHubStepSummary -Mode 'success'
        Write-Host 'Windows student-policy runner completed successfully' -ForegroundColor Green
    }
}
