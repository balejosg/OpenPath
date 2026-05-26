param(
    [ValidateSet('Run')]
    [string]$Mode = 'Run',
    [string]$ArtifactsRoot = $(Join-Path $PSScriptRoot '..\artifacts\windows-captive-portal-wedu-lab')
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$script:ResultPath = Join-Path $script:ArtifactsRoot 'direct-captive-portal-wedu-lab-result.json'
$script:CompletionPath = Join-Path $script:ArtifactsRoot 'direct-captive-portal-wedu-lab-completion.json'
$script:NetworkBeforePath = Join-Path $script:ArtifactsRoot 'wedu-lab-network-before.json'
$script:DnsBeforePath = Join-Path $script:ArtifactsRoot 'wedu-lab-dns-before.json'
$script:BrowserBeforePath = Join-Path $script:ArtifactsRoot 'wedu-lab-browser-before.json'
$script:PortalScreenshotPath = Join-Path $script:ArtifactsRoot 'wedu-lab-portal-before-login.png'
$script:NativeRecoveryPath = Join-Path $script:ArtifactsRoot 'wedu-lab-native-recovery.json'
$script:GatewayAuthenticatedPath = Join-Path $script:ArtifactsRoot 'wedu-lab-gateway-authenticated.json'
$script:NativeReconcilePath = Join-Path $script:ArtifactsRoot 'wedu-lab-native-reconcile.json'
$script:NetworkAfterPath = Join-Path $script:ArtifactsRoot 'wedu-lab-network-after.json'
$script:OpenPathProtectionAfterPath = Join-Path $script:ArtifactsRoot 'wedu-lab-openpath-protection-after.json'
$script:RecoveryResultRoot = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-result'
$script:RecoveryQueueRoot = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-queue'
$script:RecoveryProgressRoot = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-progress'
$script:RecoveryResultManifestPath = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-result-manifest.json'
$script:RecoveryQueueManifestPath = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-queue-manifest.json'
$script:RecoveryProgressManifestPath = Join-Path $script:ArtifactsRoot 'captive-portal-recovery-progress-manifest.json'
$script:WeduHost = 'nce.wedu.comunidad.madrid'
$script:DetectionUrl = 'http://detectportal.firefox.com/success.txt'

function Ensure-ArtifactRoot {
    New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:RecoveryResultRoot, $script:RecoveryQueueRoot, $script:RecoveryProgressRoot -Force | Out-Null
}

function Save-Json {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 12
    )

    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-WeduLabConfig {
    $token = [string]$env:OPENPATH_WEDU_LAB_GATEWAY_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'OPENPATH_WEDU_LAB_GATEWAY_TOKEN is required.'
    }

    $gatewayUrl = [string]$env:OPENPATH_WEDU_LAB_GATEWAY_URL
    if ([string]::IsNullOrWhiteSpace($gatewayUrl)) {
        $gatewayUrl = 'http://10.77.0.1'
    }

    $expectedDns = [string]$env:OPENPATH_WEDU_LAB_EXPECTED_DNS
    if ([string]::IsNullOrWhiteSpace($expectedDns)) {
        $expectedDns = '10.77.0.1'
    }

    $expectedSubnet = [string]$env:OPENPATH_WEDU_LAB_EXPECTED_SUBNET
    if ([string]::IsNullOrWhiteSpace($expectedSubnet)) {
        $expectedSubnet = '10.77.0.0/24'
    }

    return [pscustomobject]@{
        gatewayUrl = $gatewayUrl.TrimEnd('/')
        expectedDns = $expectedDns
        expectedSubnet = $expectedSubnet
        token = $token
    }
}

function ConvertTo-IPv4Number {
    param([Parameter(Mandatory = $true)][string]$Address)

    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    if ($bytes.Count -ne 4) {
        throw "Expected IPv4 address, got $Address"
    }

    return (([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3])
}

function Test-IPv4InSubnet {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Subnet
    )

    $parts = $Subnet.Split('/')
    if ($parts.Count -ne 2) {
        throw "Expected CIDR subnet, got $Subnet"
    }

    $prefix = [int]$parts[1]
    if ($prefix -lt 0 -or $prefix -gt 32) {
        throw "Invalid CIDR prefix in $Subnet"
    }

    $mask = [uint32]0
    for ($bit = 0; $bit -lt $prefix; $bit++) {
        $mask = $mask -bor ([uint32]1 -shl (31 - $bit))
    }

    return ((ConvertTo-IPv4Number -Address $Address) -band $mask) -eq ((ConvertTo-IPv4Number -Address $parts[0]) -band $mask)
}

function Get-WeduNetworkSnapshot {
    $adapters = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias } |
        Sort-Object InterfaceAlias |
        ForEach-Object {
            [pscustomobject]@{
                interfaceAlias = [string]$_.InterfaceAlias
                interfaceIndex = [int]$_.InterfaceIndex
                ipv4Addresses = @($_.IPv4Address | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
                ipv4DefaultGateway = @($_.IPv4DefaultGateway | Where-Object { $_.NextHop } | ForEach-Object { [string]$_.NextHop })
                dnsServers = @($_.DNSServer.ServerAddresses | Where-Object { $_ } | ForEach-Object { [string]$_ })
            }
        })

    return [pscustomobject]@{
        capturedAt = (Get-Date).ToString('o')
        adapters = $adapters
    }
}

function Assert-WeduLabNetwork {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedSubnet,
        [Parameter(Mandatory = $true)][string]$ExpectedDns
    )

    $addressesInSubnet = @()
    $dnsMatches = @()
    foreach ($adapter in @($Snapshot.adapters)) {
        foreach ($address in @($adapter.ipv4Addresses)) {
            if ($address -and (Test-IPv4InSubnet -Address $address -Subnet $ExpectedSubnet)) {
                $addressesInSubnet += $address
            }
        }
        foreach ($server in @($adapter.dnsServers)) {
            if ($server -eq $ExpectedDns) {
                $dnsMatches += $server
            }
        }
    }

    if ($addressesInSubnet.Count -eq 0) {
        throw "Fail-closed: this Windows VM is not on WEDU lab subnet $ExpectedSubnet."
    }
    if ($dnsMatches.Count -eq 0) {
        throw "Fail-closed: this Windows VM is not using WEDU lab DNS $ExpectedDns."
    }

    return [pscustomobject]@{
        labNetworkVerified = $true
        addressesInSubnet = @($addressesInSubnet)
        dnsMatches = @($dnsMatches)
        expectedSubnet = $ExpectedSubnet
        expectedDns = $ExpectedDns
    }
}

function Invoke-GatewayControl {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $uri = "$($Config.gatewayUrl)$Path"
    $headers = @{ 'X-Lab-Token' = [string]$Config.token }
    $startedAt = Get-Date
    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 20
        return [pscustomobject]@{
            operation = $Operation
            uri = $uri
            statusCode = [int]$response.StatusCode
            body = [string]$response.Content
            startedAt = $startedAt.ToString('o')
            finishedAt = (Get-Date).ToString('o')
            success = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300)
        }
    }
    catch {
        return [pscustomobject]@{
            operation = $Operation
            uri = $uri
            statusCode = 0
            body = ''
            startedAt = $startedAt.ToString('o')
            finishedAt = (Get-Date).ToString('o')
            success = $false
            error = [string]$_
        }
    }
}

function Get-WeduDnsSnapshot {
    $domains = @($script:WeduHost, 'detectportal.firefox.com', 'www.msftconnecttest.com', 'www.msftncsi.com')
    $queries = foreach ($domain in $domains) {
        try {
            $answers = @(Resolve-DnsName -Name $domain -Type A -ErrorAction Stop)
            [pscustomobject]@{
                domain = $domain
                success = $true
                addresses = @($answers | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
                error = ''
            }
        }
        catch {
            [pscustomobject]@{
                domain = $domain
                success = $false
                addresses = @()
                error = [string]$_
            }
        }
    }

    return [pscustomobject]@{
        capturedAt = (Get-Date).ToString('o')
        queries = @($queries)
    }
}

function Invoke-HttpProbe {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $response = Invoke-WebRequest -Uri $Url -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        return [pscustomobject]@{
            url = $Url
            statusCode = [int]$response.StatusCode
            contentType = [string]$response.Headers['Content-Type']
            bodySample = ([string]$response.Content).Substring(0, [Math]::Min(500, ([string]$response.Content).Length))
            error = ''
        }
    }
    catch {
        $response = $_.Exception.Response
        return [pscustomobject]@{
            url = $Url
            statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
            contentType = ''
            bodySample = ''
            error = [string]$_
        }
    }
}

function Find-FirefoxPath {
    return @(
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Find-GeckoDriverPath {
    $command = Get-Command geckodriver.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return @(
        (Join-Path $script:RepoRoot 'tools\geckodriver.exe'),
        (Join-Path $script:RepoRoot 'tests\e2e\bin\geckodriver.exe'),
        'C:\tools\geckodriver.exe'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
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

function Invoke-WebDriverJson {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet('Get', 'Post', 'Delete')]
        [string]$Method = 'Get',
        [AllowNull()][object]$Body = $null
    )

    $parameters = @{
        Uri = $Uri
        Method = $Method
        TimeoutSec = 20
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
    }

    return Invoke-RestMethod @parameters
}

function Invoke-WeduBrowserProbe {
    param([Parameter(Mandatory = $true)][object]$Config)

    $firefoxPath = Find-FirefoxPath
    $geckoDriverPath = Find-GeckoDriverPath
    if (-not $firefoxPath) {
        throw 'Firefox executable was not found; cannot capture WEDU lab portal evidence.'
    }
    if (-not $geckoDriverPath) {
        throw 'geckodriver.exe was not found; cannot capture WEDU lab portal evidence.'
    }

    $port = Get-FreeTcpPort
    $geckoOutPath = Join-Path $script:ArtifactsRoot 'wedu-lab-geckodriver.out.log'
    $geckoErrPath = Join-Path $script:ArtifactsRoot 'wedu-lab-geckodriver.err.log'
    $geckoProcess = Start-Process -FilePath $geckoDriverPath `
        -ArgumentList @('--host', '127.0.0.1', '--port', [string]$port) `
        -RedirectStandardOutput $geckoOutPath `
        -RedirectStandardError $geckoErrPath `
        -PassThru `
        -WindowStyle Hidden

    $sessionId = ''
    try {
        $statusUri = "http://127.0.0.1:$port/status"
        $ready = $false
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            try {
                Invoke-WebDriverJson -Uri $statusUri | Out-Null
                $ready = $true
                break
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $ready) {
            throw 'geckodriver did not become ready for WEDU lab portal capture.'
        }

        $session = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session" -Method Post -Body @{
            capabilities = @{
                alwaysMatch = @{
                    browserName = 'firefox'
                    pageLoadStrategy = 'eager'
                    'moz:firefoxOptions' = @{
                        binary = $firefoxPath
                        args = @('-headless')
                    }
                }
            }
        }
        $sessionId = if ($session.value -and $session.value.sessionId) { [string]$session.value.sessionId } else { [string]$session.sessionId }
        if (-not $sessionId) {
            throw 'geckodriver did not return a session id.'
        }

        Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/timeouts" -Method Post -Body @{
            implicit = 0
            pageLoad = 10000
            script = 5000
        } | Out-Null

        $targetUrl = "$($Config.gatewayUrl)/"
        Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/url" -Method Post -Body @{ url = $targetUrl } | Out-Null
        Start-Sleep -Seconds 2

        $finalUrlResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/url"
        $titleResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/title"
        $sourceResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/source"
        $screenshotResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/screenshot"

        $screenshotBytes = [System.Convert]::FromBase64String([string]$screenshotResult.value)
        [System.IO.File]::WriteAllBytes($script:PortalScreenshotPath, $screenshotBytes)

        $finalUrl = if ($finalUrlResult.value) { [string]$finalUrlResult.value } else { '' }
        $title = if ($titleResult.value) { [string]$titleResult.value } else { '' }
        $pageSource = if ($sourceResult.value) { [string]$sourceResult.value } else { '' }

        return [pscustomobject]@{
            gatewayUrl = $Config.gatewayUrl
            targetUrl = $targetUrl
            finalUrl = $finalUrl
            title = $title
            portalDetected = ($pageSource -match 'WEDU lab captive portal')
            screenshotPath = 'wedu-lab-portal-before-login.png'
            geckoDriverOutPath = 'wedu-lab-geckodriver.out.log'
            geckoDriverErrPath = 'wedu-lab-geckodriver.err.log'
        }
    }
    finally {
        if ($sessionId) {
            try {
                Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId" -Method Delete | Out-Null
            }
            catch { }
        }
        if ($geckoProcess -and -not $geckoProcess.HasExited) {
            Stop-Process -Id $geckoProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Find-NativeHostScriptPath {
    $candidatePaths = @(
        'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.ps1',
        (Join-Path $script:RepoRoot 'windows\scripts\OpenPath-NativeHost.ps1')
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return $candidatePath
        }
    }

    throw 'OpenPath native host script was not found.'
}

function Invoke-NativeHostAction {
    param([Parameter(Mandatory = $true)][hashtable]$Message)

    $nativeHostScriptPath = Find-NativeHostScriptPath
    $requestJson = $Message | ConvertTo-Json -Compress -Depth 6
    $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestJson)
    $lengthBytes = [System.BitConverter]::GetBytes([int]$requestBytes.Length)
    $inputPath = Join-Path $script:ArtifactsRoot 'wedu-lab-native-host-request.bin'
    $outputPath = Join-Path $script:ArtifactsRoot 'wedu-lab-native-host-response.bin'
    $errorPath = Join-Path $script:ArtifactsRoot 'wedu-lab-native-host-response.err.log'

    [System.IO.File]::WriteAllBytes($inputPath, [byte[]]($lengthBytes + $requestBytes))
    Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $nativeHostScriptPath) `
        -RedirectStandardInput $inputPath `
        -RedirectStandardOutput $outputPath `
        -RedirectStandardError $errorPath `
        -PassThru `
        -WindowStyle Hidden

    $nativeHostTimeoutMs = 90000
    if (-not $process.WaitForExit($nativeHostTimeoutMs)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'Native host WEDU lab action timed out.'
    }

    $stderr = if (Test-Path -LiteralPath $errorPath) { Get-Content -LiteralPath $errorPath -Raw } else { '' }
    $process.Refresh()
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    if ($exitCode -ne 0) {
        throw "Native host WEDU lab action exited with $($exitCode): $stderr"
    }

    $responseBytes = [System.IO.File]::ReadAllBytes($outputPath)
    if ($responseBytes.Length -lt 4) {
        throw 'Native host WEDU lab action did not return a framed response.'
    }

    $responseLength = [System.BitConverter]::ToInt32($responseBytes, 0)
    if ($responseLength -le 0 -or $responseBytes.Length -lt (4 + $responseLength)) {
        throw 'Native host WEDU lab action returned an invalid response frame.'
    }

    $responseJson = [System.Text.Encoding]::UTF8.GetString($responseBytes, 4, $responseLength)
    return ($responseJson | ConvertFrom-Json)
}

function Copy-RecoveryDirectoryArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ArtifactPrefix
    )

    $files = @()
    if (Test-Path -LiteralPath $SourceRoot) {
        foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name)) {
            if ($file.Name -notmatch '^[A-Za-z0-9_.-]+\.json$') {
                continue
            }
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $TargetRoot $file.Name) -Force
            $files += "$ArtifactPrefix\$($file.Name)"
        }
    }

    Save-Json -Value ([pscustomobject]@{
        files = $files
        sourceRoot = $SourceRoot
    }) -Path $ManifestPath

    return $files
}

function Copy-WeduRecoveryArtifacts {
    $resultFiles = Copy-RecoveryDirectoryArtifact `
        -SourceRoot 'C:\OpenPath\data\captive-portal-recovery-result' `
        -TargetRoot $script:RecoveryResultRoot `
        -ManifestPath $script:RecoveryResultManifestPath `
        -ArtifactPrefix 'captive-portal-recovery-result'
    $queueFiles = Copy-RecoveryDirectoryArtifact `
        -SourceRoot 'C:\OpenPath\data\captive-portal-recovery-queue' `
        -TargetRoot $script:RecoveryQueueRoot `
        -ManifestPath $script:RecoveryQueueManifestPath `
        -ArtifactPrefix 'captive-portal-recovery-queue'
    $progressFiles = Copy-RecoveryDirectoryArtifact `
        -SourceRoot 'C:\OpenPath\data\captive-portal-recovery-progress' `
        -TargetRoot $script:RecoveryProgressRoot `
        -ManifestPath $script:RecoveryProgressManifestPath `
        -ArtifactPrefix 'captive-portal-recovery-progress'

    return [pscustomobject]@{
        resultFiles = @($resultFiles)
        queueFiles = @($queueFiles)
        progressFiles = @($progressFiles)
    }
}

function Test-OpenPathProtectionAfter {
    $blockedDomain = 'this-should-be-blocked-test-12345.com'
    $allowedDomain = 'www.msftconnecttest.com'
    $blocked = $false
    $allowedFunctional = $false
    $blockedError = ''
    $allowedError = ''

    try {
        $blockedAnswers = @(Resolve-DnsName -Name $blockedDomain -Server 127.0.0.1 -DnsOnly -ErrorAction SilentlyContinue)
        $blocked = ($blockedAnswers.Count -eq 0)
    }
    catch {
        $blocked = $true
        $blockedError = [string]$_
    }

    try {
        $allowedAnswers = @(Resolve-DnsName -Name $allowedDomain -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
        $allowedFunctional = ($allowedAnswers.Count -gt 0)
    }
    catch {
        $allowedError = [string]$_
    }

    return [pscustomobject]@{
        blockedDomain = $blockedDomain
        blockedByOpenPath = $blocked
        blockedError = $blockedError
        allowedDomain = $allowedDomain
        allowedDomainFunctional = $allowedFunctional
        allowedError = $allowedError
        protectedModeRestored = ($blocked -and $allowedFunctional)
    }
}

function Invoke-WeduLabRun {
    Ensure-ArtifactRoot
    $config = Get-WeduLabConfig

    $networkBefore = Get-WeduNetworkSnapshot
    Save-Json -Value $networkBefore -Path $script:NetworkBeforePath
    $labNetwork = Assert-WeduLabNetwork -Snapshot $networkBefore -ExpectedSubnet $config.expectedSubnet -ExpectedDns $config.expectedDns

    $gatewayReset = Invoke-GatewayControl -Config $config -Operation 'gateway-reset' -Path '/lab/reset'
    if (-not $gatewayReset.success) {
        throw "Gateway reset failed: $($gatewayReset.error)"
    }

    $dnsBefore = Get-WeduDnsSnapshot
    Save-Json -Value $dnsBefore -Path $script:DnsBeforePath

    $successProbe = Invoke-HttpProbe -Url $script:DetectionUrl
    $portalProbe = Invoke-HttpProbe -Url "http://$script:WeduHost/"
    $browserBefore = Invoke-WeduBrowserProbe -Config $config
    $browserPayload = [pscustomobject]@{
        detectionProbe = $successProbe
        portalProbe = $portalProbe
        browser = $browserBefore
        expectedPortalContent = 'WEDU lab captive portal'
        portalDetected = [bool]($browserBefore.portalDetected -and ($successProbe.bodySample -match 'WEDU lab captive portal'))
    }
    Save-Json -Value $browserPayload -Path $script:BrowserBeforePath

    $nativeRecovery = Invoke-NativeHostAction -Message @{
        action = 'recover-captive-portal-navigation'
        triggerHost = $script:WeduHost
        tabId = 1
        source = 'wedu-lab-captive'
    }
    Save-Json -Value $nativeRecovery -Path $script:NativeRecoveryPath

    $gatewayAuthenticated = Invoke-GatewayControl -Config $config -Operation 'gateway-authenticated' -Path '/lab/authenticated'
    Save-Json -Value $gatewayAuthenticated -Path $script:GatewayAuthenticatedPath
    if (-not $gatewayAuthenticated.success) {
        throw "Gateway authenticated transition failed: $($gatewayAuthenticated.error)"
    }

    $nativeReconcile = Invoke-NativeHostAction -Message @{
        action = 'recover-captive-portal-navigation'
        operation = 'reconcile'
        portalState = 'Authenticated'
        tabId = 1
        source = 'wedu-lab-authenticated'
    }
    Save-Json -Value $nativeReconcile -Path $script:NativeReconcilePath

    $networkAfter = Get-WeduNetworkSnapshot
    Save-Json -Value $networkAfter -Path $script:NetworkAfterPath

    $openPathProtectionAfter = Test-OpenPathProtectionAfter
    Save-Json -Value $openPathProtectionAfter -Path $script:OpenPathProtectionAfterPath
    $recoveryArtifacts = Copy-WeduRecoveryArtifacts

    $success = [bool](
        $labNetwork.labNetworkVerified -and
        $browserPayload.portalDetected -and
        $nativeRecovery.success -and
        $gatewayAuthenticated.success -and
        $nativeReconcile.success -and
        $openPathProtectionAfter.protectedModeRestored
    )

    return [pscustomobject]@{
        profile = 'captive-portal-wedu-lab'
        success = $success
        evidenceLevel = 'wedu-lab-direct-runner'
        targetPlatformSymptomCleared = $false
        labNetwork = $labNetwork
        gatewayReset = $gatewayReset
        dnsBeforePath = 'wedu-lab-dns-before.json'
        browserBeforePath = 'wedu-lab-browser-before.json'
        portalScreenshotPath = 'wedu-lab-portal-before-login.png'
        nativeRecoveryPath = 'wedu-lab-native-recovery.json'
        gatewayAuthenticatedPath = 'wedu-lab-gateway-authenticated.json'
        nativeReconcilePath = 'wedu-lab-native-reconcile.json'
        networkAfterPath = 'wedu-lab-network-after.json'
        openPathProtectionAfterPath = 'wedu-lab-openpath-protection-after.json'
        nativeRecovery = $nativeRecovery
        gatewayAuthenticated = $gatewayAuthenticated
        nativeReconcile = $nativeReconcile
        openPathProtectionAfter = $openPathProtectionAfter
        recoveryArtifacts = $recoveryArtifacts
        timestamp = (Get-Date).ToString('o')
    }
}

try {
    $result = Invoke-WeduLabRun
    Save-Json -Value $result -Path $script:ResultPath
    if (-not $result.success) {
        throw 'WEDU lab direct-runner checks did not all pass.'
    }
}
catch {
    $errorPayload = [pscustomobject]@{
        profile = 'captive-portal-wedu-lab'
        success = $false
        evidenceLevel = 'wedu-lab-direct-runner'
        targetPlatformSymptomCleared = $false
        error = [string]$_
        timestamp = (Get-Date).ToString('o')
    }
    Save-Json -Value $errorPayload -Path $script:ResultPath
    throw
}
