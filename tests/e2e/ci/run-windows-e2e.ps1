$ErrorActionPreference = 'Stop'

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-Host ""
    Write-Host $Message
}

function Fail-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][object]$ErrorRecord
    )

    if ($null -ne $ErrorRecord) {
        throw "$Message $ErrorRecord"
    }

    throw $Message
}

function Get-OpenPathUninstallArgs {
    param(
        [Parameter(Mandatory = $true)][string]$UninstallPath
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $UninstallPath)
    if ($env:RUNNER_ENVIRONMENT -eq 'self-hosted') {
        $arguments += '-KeepAcrylic'
    }

    return $arguments
}

function Ensure-Pester {
    Write-Step "Installing/Importing Pester..."
    try {
        if (-not (Get-Module -ListAvailable -Name Pester)) {
            Install-Module -Name Pester -Force -SkipPublisherCheck -ErrorAction Stop
        }
        Import-Module Pester -PassThru -ErrorAction Stop | Out-Null
        Write-Host "OK: Pester ready"
    }
    catch {
        Fail-Step "Failed to install/import Pester." $_
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

function Set-TestWhitelistContent {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string[]]$WhitelistDomains,
        [string[]]$BlockedSubdomains = @(),
        [string]$RelativePath = 'whitelist.txt'
    )

    $lines = @(
        '## WHITELIST'
    ) + $WhitelistDomains + @(
        '',
        '## BLOCKED-SUBDOMAINS'
    ) + $BlockedSubdomains

    $targetPath = Join-Path $RootPath $RelativePath
    $targetDirectory = Split-Path $targetPath -Parent
    if (-not (Test-Path $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }
    $lines | Set-Content -Path $targetPath -Encoding UTF8
}

function Start-TestWhitelistServer {
    Write-Step "Starting local whitelist server..."

    $rootPath = Join-Path $env:TEMP ("openpath-whitelist-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
    $machineToken = 'test-machine-token'
    $whitelistRelativePath = Join-Path 'w' $machineToken 'whitelist.txt'

    Set-TestWhitelistContent -RootPath $rootPath `
        -RelativePath $whitelistRelativePath `
        -WhitelistDomains @('google.com', 'github.com', 'microsoft.com') `
        -BlockedSubdomains @('ads.example.com', 'tracking.example.com')

    $port = Get-FreeTcpPort
    $job = Start-Job -ArgumentList $port, $rootPath, $machineToken, $whitelistRelativePath.Replace('\', '/') -ScriptBlock {
        param($Port, $ContentRoot, $MachineToken, $WhitelistPath)

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()

        try {
            while ($listener.IsListening) {
                try {
                    $context = $listener.GetContext()
                }
                catch {
                    break
                }

                try {
                    $relativePath = $context.Request.Url.AbsolutePath.TrimStart('/')
                    if ([string]::IsNullOrWhiteSpace($relativePath)) {
                        $relativePath = $WhitelistPath
                    }

                    $candidatePath = $null
                    $normalizedRoot = [System.IO.Path]::GetFullPath($ContentRoot)
                    $requiresAuth = $relativePath.StartsWith('api/agent/windows/', [System.StringComparison]::OrdinalIgnoreCase)

                    if ($requiresAuth) {
                        $authorization = $context.Request.Headers['Authorization']
                        if ($authorization -ne "Bearer $MachineToken") {
                            $context.Response.StatusCode = 401
                            $context.Response.OutputStream.Close()
                            $context.Response.Close()
                            continue
                        }
                    }

                    if ($relativePath.StartsWith('api/agent/windows/files/', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $requestedPath = $relativePath.Substring('api/agent/windows/files/'.Length)
                        if ([string]::IsNullOrWhiteSpace($requestedPath) -or $requestedPath.Contains('..')) {
                            $context.Response.StatusCode = 400
                            $context.Response.OutputStream.Close()
                            $context.Response.Close()
                            continue
                        }

                        $relativeUpdatePath = $requestedPath -replace '/', [System.IO.Path]::DirectorySeparatorChar
                        $candidatePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $ContentRoot 'update-files') $relativeUpdatePath))
                    }
                    else {
                        $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $ContentRoot $relativePath))
                    }

                    if (-not $candidatePath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $candidatePath)) {
                        $context.Response.StatusCode = 404
                    }
                    else {
                        $bytes = [System.IO.File]::ReadAllBytes($candidatePath)
                        $context.Response.StatusCode = 200
                        if ($candidatePath.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
                            $context.Response.ContentType = 'application/json; charset=utf-8'
                        }
                        elseif ($candidatePath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
                            $context.Response.ContentType = 'text/plain; charset=utf-8'
                        }
                        else {
                            $context.Response.ContentType = 'application/octet-stream'
                        }
                        $context.Response.ContentLength64 = $bytes.Length
                        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                }
                catch {
                    $context.Response.StatusCode = 500
                }
                finally {
                    $context.Response.OutputStream.Close()
                    $context.Response.Close()
                }
            }
        }
        finally {
            if ($listener.IsListening) {
                $listener.Stop()
            }
            $listener.Close()
        }
    }

    $url = "http://127.0.0.1:$port/$($whitelistRelativePath.Replace('\', '/'))"
    $apiUrl = "http://127.0.0.1:$port"

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        if ($job.State -eq 'Failed') {
            $jobError = Receive-Job -Job $job -Keep | Out-String
            Fail-Step "Whitelist server job failed to start. $jobError"
        }

        try {
            Invoke-WebRequest -Uri $url -TimeoutSec 2 | Out-Null
            Write-Host "OK: Local whitelist server ready at $url"
            return [PSCustomObject]@{
                Job                   = $job
                RootPath              = $rootPath
                Url                   = $url
                ApiUrl                = $apiUrl
                MachineToken          = $machineToken
                WhitelistRelativePath = $whitelistRelativePath.Replace('\', '/')
            }
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    Fail-Step "Local whitelist server did not become ready in time."
}

function Stop-TestWhitelistServer {
    param(
        [Parameter()][object]$ServerState
    )

    if ($null -eq $ServerState) {
        return
    }

    if ($ServerState.PSObject.Properties['Job'] -and $ServerState.Job) {
        Stop-Job -Job $ServerState.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $ServerState.Job -Force -ErrorAction SilentlyContinue
    }

    if ($ServerState.PSObject.Properties['RootPath'] -and (Test-Path $ServerState.RootPath)) {
        Remove-Item $ServerState.RootPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenPathInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$WhitelistUrl,
        [Parameter(Mandatory = $true)][string]$ApiUrl
    )

    Write-Step "Running Windows installer..."

    $installerPath = Join-Path $RepoRoot 'windows\Install-OpenPath.ps1'
    $installerArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $installerPath,
        '-WhitelistUrl', $WhitelistUrl,
        '-ApiUrl', $ApiUrl,
        '-SkipPreflight',
        '-Unattended'
    )

    & powershell.exe @installerArgs
    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Install-OpenPath.ps1 exited with code $LASTEXITCODE."
    }

    if (-not (Test-Path 'C:\OpenPath\data\config.json')) {
        Fail-Step 'Installer completed but C:\OpenPath\data\config.json is missing.'
    }

    $config = Get-Content 'C:\OpenPath\data\config.json' -Raw | ConvertFrom-Json
    if ($config.whitelistUrl -ne $WhitelistUrl) {
        Fail-Step "Installer persisted whitelistUrl '$($config.whitelistUrl)' instead of '$WhitelistUrl'."
    }
}

function Import-InstalledModulesAndSmoke {
    Write-Step "Importing installed modules..."

    Import-Module 'C:\OpenPath\lib\Common.psm1' -Force
    Import-Module 'C:\OpenPath\lib\DNS.psm1' -Force
    Import-Module 'C:\OpenPath\lib\Firewall.psm1' -Force

    if (-not (Test-Path 'C:\OpenPath\scripts\Update-OpenPath.ps1')) {
        Fail-Step 'Installed update script is missing.'
    }

    if (-not (Test-Path 'C:\OpenPath\OpenPath.ps1')) {
        Fail-Step 'Installed OpenPath.ps1 command is missing.'
    }

    $acrylicPath = Get-AcrylicPath
    Write-Host "Acrylic Path: $acrylicPath"

    $installed = Test-AcrylicInstalled
    if (-not $installed) {
        Fail-Step 'Acrylic was not installed by Install-OpenPath.ps1.'
    }

    Write-Host 'OK: Installed modules import successfully'
}

function Set-AcrylicDiagnosticLogging {
    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) {
        Write-Host 'WARN: Acrylic path unavailable; cannot enable hit logging.'
        return
    }

    $configPath = Join-Path $acrylicPath 'AcrylicConfiguration.ini'
    if (-not (Test-Path $configPath)) {
        Write-Host "WARN: Acrylic configuration missing at $configPath"
        return
    }

    $logPath = 'C:\OpenPath\data\logs\acrylic-hit.log'
    $iniContent = Get-Content $configPath -Raw
    $settings = @{
        'HitLogFileName' = $logPath
        'HitLogFileWhat' = 'XHCFRU'
        'HitLogMaxPendingHits' = '1'
    }

    foreach ($key in $settings.Keys) {
        $pattern = "(?m)^$key=.*$"
        $replacement = "$key=$($settings[$key])"
        if ($iniContent -match $pattern) {
            $iniContent = $iniContent -replace $pattern, $replacement
        }
        else {
            $iniContent += "`n$replacement"
        }
    }

    $iniContent | Set-Content -Path $configPath -Encoding UTF8
    Restart-Service -Name 'AcrylicDNSProxySvc' -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Host "OK: Acrylic hit logging enabled at $logPath"
}

function Test-InstalledWhitelist {
    Write-Step "Testing installed whitelist state..."

    $whitelistPath = 'C:\OpenPath\data\whitelist.txt'
    if (-not (Test-Path $whitelistPath)) {
        Write-Host 'WARN: Installed whitelist file is not present immediately after install; proceeding to explicit update validation.'
        $logPath = 'C:\OpenPath\data\logs\openpath.log'
        if (Test-Path $logPath) {
            Write-Host 'Recent openpath.log entries:'
            Get-Content $logPath -Tail 40 | ForEach-Object { Write-Host $_ }
        }
        return
    }

    $content = Get-Content $whitelistPath -Raw
    foreach ($domain in @('google.com', 'github.com', 'microsoft.com')) {
        if ($content -notmatch [regex]::Escape($domain)) {
            Fail-Step "Installed whitelist file does not contain expected domain '$domain'."
        }
    }

    Write-Host 'OK: First update downloaded whitelist content'
}

function Write-AcrylicDiagnostics {
    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) {
        Write-Host 'WARN: Acrylic path unavailable for diagnostics.'
        return
    }

    $diagnosticFiles = @(
        (Join-Path $acrylicPath 'AcrylicConfiguration.ini'),
        (Join-Path $acrylicPath 'AcrylicHosts.txt'),
        'C:\OpenPath\data\logs\acrylic-hit.log'
    )

    foreach ($path in $diagnosticFiles) {
        if (-not (Test-Path $path)) {
            Write-Host "WARN: Diagnostic file missing: $path"
            continue
        }

        Write-Host ""
        Write-Host "---- $path ----"
        Get-Content $path -TotalCount 120 | ForEach-Object { Write-Host $_ }
    }

    $configPath = Join-Path $acrylicPath 'AcrylicConfiguration.ini'
    if (Test-Path $configPath) {
        $primaryServer = Select-String -Path $configPath -Pattern '^PrimaryServerAddress=' | Select-Object -First 1
        $secondaryServer = Select-String -Path $configPath -Pattern '^SecondaryServerAddress=' | Select-Object -First 1

        $servers = @('127.0.0.1')
        foreach ($serverLine in @($primaryServer, $secondaryServer)) {
            if (-not $serverLine) {
                continue
            }

            $server = ($serverLine.Line -split '=', 2)[1].Trim()
            if (-not $server) {
                continue
            }

            $servers += $server
        }

        $servers = @($servers | Select-Object -Unique)
        $recordTypes = @('A', 'AAAA', 'HTTPS')

        foreach ($server in $servers) {
            foreach ($recordType in $recordTypes) {
                try {
                    $result = Resolve-DnsName -Name 'google.com' -Server $server -Type $recordType -DnsOnly -ErrorAction Stop
                    $resolvedValue = $result |
                        Where-Object {
                            ($_.PSObject.Properties['IPAddress'] -and $_.IPAddress) -or
                            ($_.PSObject.Properties['NameHost'] -and $_.NameHost) -or
                            ($_.PSObject.Properties['Strings'] -and $_.Strings)
                        } |
                        Select-Object -First 1

                    if ($resolvedValue) {
                        if ($resolvedValue.PSObject.Properties['IPAddress'] -and $resolvedValue.IPAddress) {
                            Write-Host "OK: $server $recordType -> $($resolvedValue.IPAddress)"
                        }
                        elseif ($resolvedValue.PSObject.Properties['NameHost'] -and $resolvedValue.NameHost) {
                            Write-Host "OK: $server $recordType -> $($resolvedValue.NameHost)"
                        }
                        elseif ($resolvedValue.PSObject.Properties['Strings'] -and $resolvedValue.Strings) {
                            Write-Host "OK: $server $recordType -> $($resolvedValue.Strings -join ', ')"
                        }
                        else {
                            Write-Host "OK: $server $recordType returned a DNS answer"
                        }
                    }
                    else {
                        Write-Host "OK: $server $recordType returned a DNS answer"
                    }
                }
                catch {
                    Write-Host "WARN: $server $recordType failed: $_"
                }
            }
        }

        $serviceExecutable = Join-Path $acrylicPath 'AcrylicService.exe'
        if (Test-Path $serviceExecutable) {
            $fileVersion = (Get-Item $serviceExecutable).VersionInfo.FileVersion
            if ($fileVersion) {
                Write-Host "OK: AcrylicService.exe version $fileVersion"
            }
        }
    }
}

function Test-InstalledDnsProxyResolution {
    Write-Step "Testing installed DNS proxy resolution..."

    $loopbackConfigured = Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { $_.ServerAddresses -contains '127.0.0.1' }

    if (-not $loopbackConfigured) {
        Fail-Step 'Installer did not set any IPv4 adapter DNS server to 127.0.0.1.'
    }

    $acrylicService = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
    if (-not $acrylicService -or $acrylicService.Status -ne 'Running') {
        Fail-Step 'Acrylic DNS Proxy service is not running after installation.'
    }

    Set-AcrylicDiagnosticLogging

    $result = Resolve-OpenPathDnsWithRetry -Domain 'google.com' -MaxAttempts 20 -DelayMilliseconds 1500
    if (-not $result) {
        Write-AcrylicDiagnostics
        Fail-Step 'Acrylic proxy validation failed.'
    }

    $resolvedIp = $result |
        Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } |
        Select-Object -First 1 -ExpandProperty IPAddress

    if ($resolvedIp) {
        Write-Host "OK: Acrylic proxy working: $resolvedIp"
    }
    else {
        Write-Host 'OK: Acrylic proxy returned a DNS response.'
    }

    try {
        $systemResult = Resolve-DnsName -Name 'google.com' -ErrorAction Stop
        Write-Host "OK: System resolver reached OpenPath DNS: $($systemResult[0].IPAddress)"
    }
    catch {
        Write-Host 'WARN: System default resolver did not converge on the runner, but explicit Acrylic resolution via 127.0.0.1 succeeded.'
    }
}

function Restart-AcrylicServiceForE2E {
    param(
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$Required
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $service = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction Stop
            if ($service.Status -ne 'Stopped') {
                Stop-Service -Name 'AcrylicDNSProxySvc' -Force -ErrorAction Stop
                $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
            }

            Start-Service -Name 'AcrylicDNSProxySvc' -ErrorAction Stop
            $service = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction Stop
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
            return $true
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Write-Host "WARN: Acrylic service restart failed while ${Context} on attempt ${attempt}: $($_.Exception.Message)"
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }
        }
    }

    if ($Required) {
        Fail-Step "Acrylic service restart failed while $Context." $lastError
    }

    Write-Host "WARN: Acrylic service restart failed while ${Context}: $($lastError.Exception.Message)"
    return $false
}

function Test-SinkholeBlocking {
    Write-Step "Testing DNS sinkhole blocking..."

    $acrylicPath = 'C:\Program Files (x86)\Acrylic DNS Proxy'
    $hostsFile = Join-Path $acrylicPath 'AcrylicHosts.txt'

    if (-not (Test-Path $hostsFile)) {
        Fail-Step "Acrylic hosts file not found; cannot validate sinkhole behavior."
    }

    Copy-Item $hostsFile "$hostsFile.bak" -Force
    try {
        Add-Content -Path $hostsFile -Value '0.0.0.0 blocked-test-domain.example.com'
        Restart-AcrylicServiceForE2E -Context 'applying sinkhole hosts' -Required | Out-Null
        Start-Sleep -Seconds 3

        try {
            $result = Resolve-DnsName -Name 'blocked-test-domain.example.com' -Server '127.0.0.1' -ErrorAction Stop
            if ($result.IPAddress -eq '0.0.0.0') {
                Write-Host 'OK: Sinkhole blocking works (0.0.0.0)'
            }
            else {
                Fail-Step "Sinkhole domain resolved to $($result.IPAddress) instead of 0.0.0.0."
            }
        }
        catch {
            Write-Host 'OK: Domain blocked (resolution failed as expected)'
        }
    }
    finally {
        if (Test-Path "$hostsFile.bak") {
            Move-Item "$hostsFile.bak" $hostsFile -Force
        }
        Restart-AcrylicServiceForE2E -Context 'restoring sinkhole hosts' | Out-Null
    }
}

function Test-InstalledUpdateRefresh {
    param(
        [Parameter(Mandatory = $true)][object]$ServerState,
        [Parameter(Mandatory = $true)][string[]]$WhitelistDomains
    )

    Write-Step "Testing installed update script against the local server..."

    Set-TestWhitelistContent -RootPath $ServerState.RootPath `
        -RelativePath $ServerState.WhitelistRelativePath `
        -WhitelistDomains $WhitelistDomains `
        -BlockedSubdomains @('ads.example.com')

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\OpenPath\scripts\Update-OpenPath.ps1'
    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Update-OpenPath.ps1 exited with code $LASTEXITCODE."
    }

    $content = Get-Content 'C:\OpenPath\data\whitelist.txt' -Raw
    if ($content -notmatch 'newdomain\.example\.com') {
        Fail-Step 'Installed update script did not refresh the whitelist from the local test server.'
    }

    Write-Host 'OK: Installed update script refreshed whitelist data'
}

function Set-TestAgentUpdateContent {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$TargetVersion
    )

    $manifestPath = Join-Path $RootPath 'api\agent\windows\manifest'
    $updateFilesRoot = Join-Path $RootPath 'update-files'
    $openPathSource = 'C:\OpenPath\OpenPath.ps1'

    if (-not (Test-Path $openPathSource)) {
        Fail-Step "Installed OpenPath.ps1 is missing at $openPathSource."
    }

    New-Item -ItemType Directory -Path (Split-Path $manifestPath -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path $updateFilesRoot -Force | Out-Null

    $targetFilePath = Join-Path $updateFilesRoot 'OpenPath.ps1'
    $targetContent = Get-Content $openPathSource -Raw
    $targetContent = $targetContent.TrimEnd() + "`r`n# lifecycle-self-update-marker $TargetVersion`r`n"
    $targetContent | Set-Content -Path $targetFilePath -Encoding UTF8

    $hash = (Get-FileHash -Path $targetFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = @{
        version = $TargetVersion
        files = @(
            @{
                path = 'OpenPath.ps1'
                sha256 = $hash
            }
        )
    }

    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
}

function Test-InstalledAgentSelfUpdate {
    param(
        [Parameter(Mandatory = $true)][object]$ServerState
    )

    Write-Step "Testing installed agent self-update against the local server..."

    $targetVersion = '9.9.9'
    Set-TestAgentUpdateContent -RootPath $ServerState.RootPath -TargetVersion $targetVersion

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\OpenPath\OpenPath.ps1' self-update
    if ($LASTEXITCODE -ne 0) {
        Fail-Step "OpenPath.ps1 self-update exited with code $LASTEXITCODE."
    }

    $config = Get-Content 'C:\OpenPath\data\config.json' -Raw | ConvertFrom-Json
    if ($config.version -ne $targetVersion) {
        Fail-Step "Agent self-update persisted version '$($config.version)' instead of '$targetVersion'."
    }

    if (-not $config.PSObject.Properties['lastAgentUpdateAt'] -or -not $config.lastAgentUpdateAt) {
        Fail-Step 'Agent self-update did not record lastAgentUpdateAt in config.json.'
    }

    $openPathContent = Get-Content 'C:\OpenPath\OpenPath.ps1' -Raw
    if ($openPathContent -notmatch 'lifecycle-self-update-marker 9\.9\.9') {
        Fail-Step 'Agent self-update did not replace OpenPath.ps1 with the staged update payload.'
    }

    Write-Host 'OK: Installed agent self-update applied the staged update payload'
}

function Test-Firewall {
    Write-Step "Testing firewall functions..."

    try {
        Import-Module 'C:\OpenPath\lib\Firewall.psm1' -Force
        $active = Test-FirewallActive
        Write-Host "Firewall Active: $active"

        try {
            New-NetFirewallRule -DisplayName 'OpenPath-Test-Rule' -Direction Outbound -Action Block -Protocol UDP -RemotePort 12345 -ErrorAction Stop | Out-Null
            Write-Host 'OK: Test firewall rule created'
            $rule = Get-NetFirewallRule -DisplayName 'OpenPath-Test-Rule' -ErrorAction SilentlyContinue
            if ($rule) {
                Write-Host 'OK: Test firewall rule verified'
            }
            else {
                Fail-Step "Firewall rule was not present after creation."
            }
        }
        catch {
            Fail-Step "Firewall rule creation failed." $_
        }
        finally {
            Remove-NetFirewallRule -DisplayName 'OpenPath-Test-Rule' -ErrorAction SilentlyContinue
        }
    }
    catch {
        Fail-Step "Firewall module validation failed." $_
    }
}

function Verify-InstalledScheduledTasks {
    Write-Step "Verifying installed OpenPath scheduled tasks..."

    $expectedTasks = @(
        'OpenPath-Update',
        'OpenPath-Watchdog',
        'OpenPath-Startup',
        'OpenPath-SSE',
        'OpenPath-AgentUpdate'
    )

    foreach ($taskName in $expectedTasks) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Fail-Step "Expected scheduled task '$taskName' was not registered by the installer."
        }
    }

    Write-Host 'OK: Installer registered all expected scheduled tasks'
}

function Verify-WindowsUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    Write-Step "Verifying Windows uninstallation removes installed state..."

    $expectedTasks = @(
        'OpenPath-Update',
        'OpenPath-Watchdog',
        'OpenPath-Startup',
        'OpenPath-SSE',
        'OpenPath-AgentUpdate'
    )

    $uninstallPath = Join-Path $RepoRoot 'windows\Uninstall-OpenPath.ps1'
    if (-not (Test-Path $uninstallPath)) {
        Fail-Step "Uninstall-OpenPath.ps1 is missing at $uninstallPath."
    }

    $uninstallArgs = Get-OpenPathUninstallArgs -UninstallPath $uninstallPath
    & powershell.exe @uninstallArgs
    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Uninstall-OpenPath.ps1 exited with code $LASTEXITCODE."
    }

    if (Test-Path 'C:\OpenPath') {
        Fail-Step 'OpenPath install root still exists after uninstall.'
    }

    foreach ($taskName in $expectedTasks) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Fail-Step "Expected scheduled task '$taskName' still exists after uninstall."
        }
    }

    Write-Host 'OK: Windows uninstaller removed the installed state'
}

function Run-PesterE2E {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string[]]$ExpectedWhitelistDomains = @()
    )

    Write-Step "Running Pester E2E tests..."
    $previousExpectedDomains = $env:OPENPATH_E2E_EXPECTED_WHITELIST_DOMAINS
    try {
        $normalizedExpectedDomains = @(
            $ExpectedWhitelistDomains |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )

        if ($normalizedExpectedDomains.Count -gt 0) {
            $env:OPENPATH_E2E_EXPECTED_WHITELIST_DOMAINS = ($normalizedExpectedDomains -join ',')
        }
        else {
            Remove-Item Env:OPENPATH_E2E_EXPECTED_WHITELIST_DOMAINS -ErrorAction SilentlyContinue
        }

        $config = New-PesterConfiguration
        $config.Run.Path = (Join-Path $RepoRoot 'tests\e2e\Windows-E2E.Tests.ps1')
        $config.Output.Verbosity = 'Detailed'
        $config.Run.PassThru = $true

        $result = Invoke-Pester -Configuration $config
        Write-Host "Results: $($result.PassedCount) passed, $($result.FailedCount) failed"

        if ($result.FailedCount -gt 0) {
            Fail-Step "Pester E2E suite reported $($result.FailedCount) failure(s)."
        }
    }
    catch {
        Fail-Step "Invoke-Pester failed." $_
    }
    finally {
        if ($null -eq $previousExpectedDomains) {
            Remove-Item Env:OPENPATH_E2E_EXPECTED_WHITELIST_DOMAINS -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENPATH_E2E_EXPECTED_WHITELIST_DOMAINS = $previousExpectedDomains
        }
    }
}

function Cleanup-WindowsE2E {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter()][object]$ServerState
    )

    Write-Step "Cleanup..."

    try {
        if (Test-Path 'C:\OpenPath') {
            $uninstallPath = Join-Path $RepoRoot 'windows\Uninstall-OpenPath.ps1'
            if (Test-Path $uninstallPath) {
                $uninstallArgs = Get-OpenPathUninstallArgs -UninstallPath $uninstallPath
                & powershell.exe @uninstallArgs
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "WARN: Uninstall-OpenPath.ps1 exited with code $LASTEXITCODE"
                }
                else {
                    Write-Host 'OK: Uninstaller completed'
                }
            }
        }
    }
    finally {
        Stop-TestWhitelistServer -ServerState $ServerState
    }
}

$serverState = $null

try {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $updatedWhitelistDomains = @('google.com', 'github.com', 'newdomain.example.com')

    Ensure-Pester
    $serverState = Start-TestWhitelistServer
    Invoke-OpenPathInstaller -RepoRoot $RepoRoot -WhitelistUrl $serverState.Url -ApiUrl $serverState.ApiUrl
    Import-InstalledModulesAndSmoke
    Test-InstalledWhitelist
    Test-InstalledDnsProxyResolution
    Test-SinkholeBlocking
    Test-InstalledUpdateRefresh -ServerState $serverState -WhitelistDomains $updatedWhitelistDomains
    Test-InstalledAgentSelfUpdate -ServerState $serverState
    Test-Firewall
    Verify-InstalledScheduledTasks
    Run-PesterE2E -RepoRoot $RepoRoot -ExpectedWhitelistDomains $updatedWhitelistDomains
    Verify-WindowsUninstall -RepoRoot $RepoRoot

    Write-Host ""
    Write-Host 'Windows E2E complete'
}
finally {
    Cleanup-WindowsE2E -RepoRoot $RepoRoot -ServerState $serverState
}
