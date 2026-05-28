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
$script:DnsLimitedPath = Join-Path $script:ArtifactsRoot 'wedu-lab-dns-limited.json'
$script:BrowserBeforePath = Join-Path $script:ArtifactsRoot 'wedu-lab-browser-before.json'
$script:BrowserLimitedPath = Join-Path $script:ArtifactsRoot 'wedu-lab-browser-limited.json'
$script:BrowserAfterAuthPath = Join-Path $script:ArtifactsRoot 'wedu-lab-browser-post-auth.json'
$script:DnsPostAuthPath = Join-Path $script:ArtifactsRoot 'wedu-lab-dns-post-auth.json'
$script:PortalScreenshotPath = Join-Path $script:ArtifactsRoot 'wedu-lab-portal-limited-mode.png'
$script:NativeRecoveryPath = Join-Path $script:ArtifactsRoot 'wedu-lab-native-recovery.json'
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
$script:WeduLoginHost = 'wlogin.wedu-lab.test'
$script:WeduAssetHost = 'assets.wedu-lab.test'
$script:WeduCdnHost = 'cdn.wedu-lab.test'
$script:WeduAuthHost = 'auth.wedu-lab.test'
$script:WeduLimitedHosts = @($script:WeduHost, $script:WeduLoginHost, $script:WeduAssetHost, $script:WeduCdnHost, $script:WeduAuthHost)
$script:DetectionUrl = 'http://detectportal.firefox.com/success.txt'
$script:MsftConnectTestUrl = 'http://www.msftconnecttest.com/connecttest.txt'
$script:WeduCaptiveHostPattern = '10\.77\.0\.1|nce\.wedu\.comunidad\.madrid|WEDU lab captive portal'
$script:InstalledOpenPathRoot = 'C:\OpenPath'
$script:InstalledRecoveryScriptPath = Join-Path $script:InstalledOpenPathRoot 'scripts\Recover-CaptivePortal.ps1'

. (Join-Path $PSScriptRoot 'windows-direct-runtime-staging.ps1')

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

function Split-EnvList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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

    $nativeHostTimeoutMs = 180000
    if (-not [string]::IsNullOrWhiteSpace([string]$env:OPENPATH_WEDU_LAB_NATIVE_HOST_TIMEOUT_MS)) {
        $nativeHostTimeoutMs = [int]$env:OPENPATH_WEDU_LAB_NATIVE_HOST_TIMEOUT_MS
    }

    return [pscustomobject]@{
        gatewayUrl = $gatewayUrl.TrimEnd('/')
        expectedDns = $expectedDns
        expectedSubnet = $expectedSubnet
        token = $token
        negativeControls = @(Split-EnvList -Value ([string]$env:OPENPATH_WEDU_LAB_NEGATIVE_CONTROLS))
        postconditionAssertions = @(Split-EnvList -Value ([string]$env:OPENPATH_WEDU_LAB_POSTCONDITION_ASSERTIONS))
        nativeHostTimeoutMs = $nativeHostTimeoutMs
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

function Invoke-GatewayMissingTokenControl {
    param([Parameter(Mandatory = $true)][object]$Config)

    $uri = "$($Config.gatewayUrl)/lab/authenticated"
    $startedAt = Get-Date
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $statusCode = [int]$response.StatusCode
        return [pscustomobject]@{
            control = 'gateway-missing-token'
            uri = $uri
            statusCode = $statusCode
            startedAt = $startedAt.ToString('o')
            finishedAt = (Get-Date).ToString('o')
            success = -not ($statusCode -ge 200 -and $statusCode -lt 300)
        }
    }
    catch {
        $response = $_.Exception.Response
        $statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
        return [pscustomobject]@{
            control = 'gateway-missing-token'
            uri = $uri
            statusCode = $statusCode
            startedAt = $startedAt.ToString('o')
            finishedAt = (Get-Date).ToString('o')
            success = $true
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
        $location = [string]$response.Headers['Location']
        return [pscustomobject]@{
            url = $Url
            statusCode = [int]$response.StatusCode
            contentType = [string]$response.Headers['Content-Type']
            location = $location
            bodySample = ([string]$response.Content).Substring(0, [Math]::Min(500, ([string]$response.Content).Length))
            error = ''
        }
    }
    catch {
        $response = $_.Exception.Response
        $location = if ($response) { [string]$response.Headers['Location'] } else { '' }
        $bodySample = ''
        if ($response) {
            try {
                $stream = $response.GetResponseStream()
                if ($stream) {
                    $reader = [System.IO.StreamReader]::new($stream)
                    $body = $reader.ReadToEnd()
                    $bodySample = $body.Substring(0, [Math]::Min(500, $body.Length))
                }
            }
            catch {
                $bodySample = ''
            }
        }
        return [pscustomobject]@{
            url = $Url
            statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
            contentType = if ($response) { [string]$response.Headers['Content-Type'] } else { '' }
            location = $location
            bodySample = $bodySample
            error = [string]$_
        }
    }
}

function Get-HttpFailureKind {
    param([object]$Probe)

    $errorText = [string]$Probe.error
    if ($errorText -match 'timed out|timeout') {
        return 'external-timeout'
    }
    if ($errorText -match 'name could not be resolved|No such host|DNS|Resolve') {
        return 'dns-failure'
    }
    return 'unexpected-http-result'
}

function Test-CaptivePortalEvidence {
    param([object]$Probe)

    $body = [string]$Probe.bodySample
    $location = [string]$Probe.location
    return [bool]($body -match $script:WeduCaptiveHostPattern -or $location -match $script:WeduCaptiveHostPattern)
}

function Invoke-PreAuthExternalBlockedControl {
    $probe = Invoke-HttpProbe -Url $script:DetectionUrl
    $captiveEvidence = Test-CaptivePortalEvidence -Probe $probe
    $failureKind = if ($captiveEvidence) { 'none' } else { Get-HttpFailureKind -Probe $probe }

    return [pscustomobject]@{
        control = 'pre-auth-external-blocked'
        probe = $probe
        captiveEvidenceObserved = $captiveEvidence
        preAuthExternalNetworkFailure = [bool](-not $captiveEvidence -and $failureKind -in @('external-timeout', 'dns-failure'))
        failureKind = $failureKind
        success = $captiveEvidence
    }
}

function Invoke-WeduNegativeControls {
    param([Parameter(Mandatory = $true)][object]$Config)

    $results = foreach ($control in @($Config.negativeControls)) {
        switch ($control) {
            'gateway-missing-token' { Invoke-GatewayMissingTokenControl -Config $Config }
            'pre-auth-external-blocked' { Invoke-PreAuthExternalBlockedControl }
            default { throw "Unknown WEDU lab negative control: $control" }
        }
    }

    return [pscustomobject]@{
        requested = @($Config.negativeControls)
        results = @($results)
        success = [bool](@($results | Where-Object { -not $_.success }).Count -eq 0)
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

        $targetUrl = "http://$script:WeduHost/"
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
        $portalReadyResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/execute/sync" -Method Post -Body @{
            script = 'return window.__openPathWeduPortalReady === true;'
            args = @()
        }
        $loginSubmittedResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/execute/sync" -Method Post -Body @{
            script = @'
const form = document.querySelector('form');
const button = document.querySelector('button[type="submit"], input[type="submit"]');
if (!form || !button || button.disabled) {
  return false;
}
button.click();
return true;
'@
            args = @()
        }
        $postSubmitFinalUrl = $finalUrl
        $postSubmitNavigationCompleted = $false
        if ([bool]$loginSubmittedResult.value) {
            for ($attempt = 1; $attempt -le 20; $attempt++) {
                Start-Sleep -Milliseconds 250
                $postSubmitUrlResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/url"
                $postSubmitFinalUrl = if ($postSubmitUrlResult.value) { [string]$postSubmitUrlResult.value } else { '' }
                if ($postSubmitFinalUrl -and $postSubmitFinalUrl -ne $finalUrl) {
                    $postSubmitNavigationCompleted = $true
                    break
                }
            }
        }
        $finalLoginHost = ''
        try {
            $finalLoginHost = ([System.Uri]$finalUrl).Host
        }
        catch { }

        return [pscustomobject]@{
            gatewayUrl = $Config.gatewayUrl
            targetUrl = $targetUrl
            finalUrl = $finalUrl
            finalLoginHost = $finalLoginHost
            title = $title
            portalDetected = ($pageSource -match 'WEDU lab captive portal')
            portalReady = [bool]$portalReadyResult.value
            loginSubmitted = [bool]([bool]$loginSubmittedResult.value -and $postSubmitNavigationCompleted)
            postSubmitFinalUrl = $postSubmitFinalUrl
            postSubmitNavigationCompleted = $postSubmitNavigationCompleted
            expectedLoginHost = $script:WeduLoginHost
            expectedAssetsHost = $script:WeduAssetHost
            expectedCdnHost = $script:WeduCdnHost
            expectedAuthHost = $script:WeduAuthHost
            screenshotPath = 'wedu-lab-portal-limited-mode.png'
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

function Test-WeduLimitedModeDns {
    $results = foreach ($host in @($script:WeduLimitedHosts)) {
        $answers = @()
        $errorText = ''
        try {
            $answers = @(Resolve-DnsName -Name $host -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
        }
        catch {
            $errorText = [string]$_
        }
        [pscustomobject]@{
            host = $host
            resolvedThroughLocalDns = [bool]($answers.Count -gt 0)
            answers = @($answers | ForEach-Object { [string]$_.IPAddress } | Where-Object { $_ })
            error = $errorText
        }
    }

    $negativeHost = 'this-should-be-blocked-test-12345.com'
    $negativeBlocked = $false
    $negativeError = ''
    try {
        $negativeAnswers = @(Resolve-DnsName -Name $negativeHost -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction SilentlyContinue)
        $negativeBlocked = ($negativeAnswers.Count -eq 0)
    }
    catch {
        $negativeBlocked = $true
        $negativeError = [string]$_
    }

    return [pscustomobject]@{
        success = [bool]((@($results | Where-Object { -not $_.resolvedThroughLocalDns }).Count -eq 0) -and $negativeBlocked)
        server = '127.0.0.1'
        hosts = @($results)
        negativeControl = [pscustomobject]@{
            host = $negativeHost
            blocked = $negativeBlocked
            error = $negativeError
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Message,
        [int]$TimeoutMs = 180000
    )

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

    $nativeHostTimeoutMs = $TimeoutMs
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

function Invoke-WeduWebDriverPageProbe {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ExpectedBody
    )

    $startedAt = Get-Date
    $failureKind = 'none'
    $navigationError = ''
    try {
        Invoke-WebDriverJson -Uri "http://127.0.0.1:$Port/session/$SessionId/url" -Method Post -Body @{ url = $Url } | Out-Null
        Start-Sleep -Seconds 2
    }
    catch {
        $navigationError = [string]$_
        if ($navigationError -match 'timed out|timeout') {
            $failureKind = 'external-timeout'
        }
        elseif ($navigationError -match 'name could not be resolved|No such host|DNS|Resolve') {
            $failureKind = 'dns-failure'
        }
        else {
            $failureKind = 'unexpected-http-result'
        }
    }

    $finalUrl = ''
    $title = ''
    $source = ''
    try {
        $finalUrlResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$Port/session/$SessionId/url"
        $titleResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$Port/session/$SessionId/title"
        $sourceResult = Invoke-WebDriverJson -Uri "http://127.0.0.1:$Port/session/$SessionId/source"
        $finalUrl = if ($finalUrlResult.value) { [string]$finalUrlResult.value } else { '' }
        $title = if ($titleResult.value) { [string]$titleResult.value } else { '' }
        $source = if ($sourceResult.value) { [string]$sourceResult.value } else { '' }
    }
    catch {
        if (-not $navigationError) {
            $navigationError = [string]$_
            $failureKind = 'unexpected-http-result'
        }
    }

    $bodySample = $source.Substring(0, [Math]::Min(500, $source.Length))
    $portalMarkerAbsent = -not (($source -match $script:WeduCaptiveHostPattern) -or ($finalUrl -match $script:WeduCaptiveHostPattern))
    $expectedBodyPresent = $source -match [regex]::Escape($ExpectedBody)
    if (-not $portalMarkerAbsent) {
        $failureKind = 'portal-marker-still-present'
    }
    elseif ($failureKind -eq 'none' -and -not $expectedBodyPresent) {
        $failureKind = 'unexpected-http-result'
    }

    return [pscustomobject]@{
        targetUrl = $Url
        finalUrl = $finalUrl
        title = $title
        bodySample = $bodySample
        portalMarkerAbsent = $portalMarkerAbsent
        externalNavigationFunctional = [bool]($portalMarkerAbsent -and $expectedBodyPresent)
        failureKind = $failureKind
        startedAt = $startedAt.ToString('o')
        finishedAt = (Get-Date).ToString('o')
        error = $navigationError
    }
}

function Invoke-WeduPostAuthBrowserProbeWithRetry {
    $firefoxPath = Find-FirefoxPath
    $geckoDriverPath = Find-GeckoDriverPath
    if (-not $firefoxPath) {
        throw 'Firefox executable was not found; cannot verify WEDU lab post-auth browser navigation.'
    }
    if (-not $geckoDriverPath) {
        throw 'geckodriver.exe was not found; cannot verify WEDU lab post-auth browser navigation.'
    }

    $startedAt = Get-Date
    $attempts = @()
    $verified = $false
    $postAuthFailureKind = 'unexpected-http-result'
    $portalMarkerAbsent = $false
    $port = Get-FreeTcpPort
    $geckoOutPath = Join-Path $script:ArtifactsRoot 'wedu-lab-geckodriver-after-auth.out.log'
    $geckoErrPath = Join-Path $script:ArtifactsRoot 'wedu-lab-geckodriver-after-auth.err.log'
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
        for ($readyAttempt = 1; $readyAttempt -le 30; $readyAttempt++) {
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
            throw 'geckodriver did not become ready for WEDU lab post-auth browser probe.'
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
            throw 'geckodriver did not return a session id for WEDU lab post-auth browser probe.'
        }

        Invoke-WebDriverJson -Uri "http://127.0.0.1:$port/session/$sessionId/timeouts" -Method Post -Body @{
            implicit = 0
            pageLoad = 15000
            script = 5000
        } | Out-Null

        foreach ($attempt in 1..3) {
            $attemptStartedAt = Get-Date
            $detectPortal = Invoke-WeduWebDriverPageProbe -Port $port -SessionId $sessionId -Url $script:DetectionUrl -ExpectedBody 'success'
            $msftConnectTest = Invoke-WeduWebDriverPageProbe -Port $port -SessionId $sessionId -Url $script:MsftConnectTestUrl -ExpectedBody 'Microsoft Connect Test'
            $attemptResult = [pscustomobject]@{
                attempt = $attempt
                detectPortal = $detectPortal
                msftConnectTest = $msftConnectTest
                startedAt = $attemptStartedAt.ToString('o')
                finishedAt = (Get-Date).ToString('o')
            }
            $attempts += $attemptResult

            $portalMarkerAbsent = [bool]($detectPortal.portalMarkerAbsent -and $msftConnectTest.portalMarkerAbsent)
            $verified = [bool]($detectPortal.externalNavigationFunctional -and $msftConnectTest.externalNavigationFunctional)
            if ($verified) {
                $postAuthFailureKind = 'none'
                break
            }

            $postAuthFailureKind = if (-not $detectPortal.portalMarkerAbsent -or -not $msftConnectTest.portalMarkerAbsent) {
                'portal-marker-still-present'
            }
            elseif ($detectPortal.failureKind -eq 'dns-failure' -or $msftConnectTest.failureKind -eq 'dns-failure') {
                'dns-failure'
            }
            elseif ($detectPortal.failureKind -eq 'external-timeout' -or $msftConnectTest.failureKind -eq 'external-timeout') {
                'external-timeout'
            }
            else {
                'unexpected-http-result'
            }

            Start-Sleep -Seconds ([Math]::Min(5, $attempt * 2))
        }

        return [pscustomobject]@{
            postAuthBrowserNavigationVerified = $verified
            postAuthFailureKind = $postAuthFailureKind
            portalMarkerAbsent = $portalMarkerAbsent
            externalNavigationFunctional = $verified
            failureKind = $postAuthFailureKind
            attempts = @($attempts)
            startedAt = $startedAt.ToString('o')
            finishedAt = (Get-Date).ToString('o')
            geckoDriverOutPath = 'wedu-lab-geckodriver-after-auth.out.log'
            geckoDriverErrPath = 'wedu-lab-geckodriver-after-auth.err.log'
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

function Assert-WeduPostconditions {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$BrowserPayload,
        [Parameter(Mandatory = $true)][object]$OpenPathProtectionAfter
    )

    $results = foreach ($assertion in @($Config.postconditionAssertions)) {
        switch ($assertion) {
            'portal-detected' {
                [pscustomobject]@{ assertion = $assertion; success = [bool]$BrowserPayload.portalDetected }
            }
            'post-auth-protection-restored' {
                [pscustomobject]@{ assertion = $assertion; success = [bool]$OpenPathProtectionAfter.protectedModeRestored }
            }
            default { throw "Unknown WEDU lab postcondition assertion: $assertion" }
        }
    }

    return [pscustomobject]@{
        requested = @($Config.postconditionAssertions)
        results = @($results)
        success = [bool](@($results | Where-Object { -not $_.success }).Count -eq 0)
    }
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

    $negativeControls = Invoke-WeduNegativeControls -Config $config
    if (-not $negativeControls.success) {
        throw 'WEDU lab negative controls did not all pass.'
    }

    $successProbe = Invoke-HttpProbe -Url $script:DetectionUrl
    $portalProbe = Invoke-HttpProbe -Url "http://$script:WeduHost/"
    $browserBefore = Invoke-WeduBrowserProbe -Config $config
    $browserPortalDetected = [bool]$browserBefore.portalDetected
    $weduHostPortalDetected = [bool]($portalProbe.bodySample -match 'WEDU lab captive portal')
    $detectPortalInterceptionObserved = [bool]($successProbe.bodySample -match 'WEDU lab captive portal')
    $browserBeforePayload = [pscustomobject]@{
        detectionProbe = $successProbe
        portalProbe = $portalProbe
        browser = $browserBefore
        expectedPortalContent = 'WEDU lab captive portal'
        browserPortalDetected = $browserPortalDetected
        weduHostPortalDetected = $weduHostPortalDetected
        detectPortalInterceptionObserved = $detectPortalInterceptionObserved
        portalDetected = [bool]($browserPortalDetected -and $weduHostPortalDetected)
    }
    Save-Json -Value $browserBeforePayload -Path $script:BrowserBeforePath

    Stage-OpenPathDirectRunnerRuntime `
        -RepoRoot $script:RepoRoot `
        -InstalledOpenPathRoot $script:InstalledOpenPathRoot `
        -InstalledRecoveryScriptPath $script:InstalledRecoveryScriptPath `
        -MissingArtifactContext 'WEDU direct-runner checkout'
    $nativeRecovery = Invoke-NativeHostAction -Message @{
        action = 'recover-captive-portal-navigation'
        triggerHost = $script:WeduHost
        tabId = 1
        source = 'wedu-lab-captive'
    } -TimeoutMs $config.nativeHostTimeoutMs
    Save-Json -Value $nativeRecovery -Path $script:NativeRecoveryPath

    $dnsBefore = Get-WeduDnsSnapshot
    Save-Json -Value $dnsBefore -Path $script:DnsBeforePath
    $limitedDns = Test-WeduLimitedModeDns
    Save-Json -Value $limitedDns -Path $script:DnsLimitedPath

    $browserLimited = Invoke-WeduBrowserProbe -Config $config

    $activeMarkerMode = if ([bool]$nativeRecovery.activeMarkerMode) { [string]$nativeRecovery.activeMarkerMode } else { 'limited' }
    $bootstrapHosts = @($nativeRecovery.bootstrapHosts | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $observedRuntimeHosts = @($nativeRecovery.observedRuntimeHosts | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $pendingRuntimeHosts = @($nativeRecovery.pendingRuntimeHosts | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $effectiveExactHosts = @($nativeRecovery.effectiveExactHosts | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($effectiveExactHosts.Count -eq 0) {
        $effectiveExactHosts = @($bootstrapHosts + $observedRuntimeHosts | Select-Object -Unique)
    }
    $discoveryTruncated = [bool]$nativeRecovery.discoveryTruncated
    $fallbackMode = if ($nativeRecovery.fallbackMode) { [string]$nativeRecovery.fallbackMode } else { '' }
    $allEffectiveExactHostsInstalled = [bool](
        @($effectiveExactHosts).Count -gt 0 -and
        @($bootstrapHosts | Where-Object { $_ -notin $effectiveExactHosts }).Count -eq 0 -and
        @($observedRuntimeHosts | Where-Object { $_ -notin $effectiveExactHosts }).Count -eq 0
    )
    $limitedModeReady = [bool](
        $activeMarkerMode -eq 'limited' -and
        @($bootstrapHosts).Count -gt 0 -and
        -not $discoveryTruncated -and
        @($pendingRuntimeHosts).Count -eq 0 -and
        $allEffectiveExactHostsInstalled
    )
    $browserPayload = [pscustomobject]@{
        browserLimited = $browserLimited
        activeMarkerMode = $activeMarkerMode
        limitedModeReady = $limitedModeReady
        bootstrapHosts = @($bootstrapHosts)
        observedRuntimeHosts = @($observedRuntimeHosts)
        pendingRuntimeHosts = @($pendingRuntimeHosts)
        discoveryTruncated = $discoveryTruncated
        fallbackMode = $fallbackMode
        limitedDns = $limitedDns
    }
    Save-Json -Value $browserPayload -Path $script:BrowserLimitedPath

    $nativeReconcile = Invoke-NativeHostAction -Message @{
        action = 'recover-captive-portal-navigation'
        operation = 'reconcile'
        portalState = 'Authenticated'
        tabId = 1
        source = 'wedu-lab-authenticated'
    } -TimeoutMs $config.nativeHostTimeoutMs
    Save-Json -Value $nativeReconcile -Path $script:NativeReconcilePath

    $browserAfterAuth = Invoke-WeduPostAuthBrowserProbeWithRetry
    Save-Json -Value $browserAfterAuth -Path $script:BrowserAfterAuthPath
    $dnsPostAuth = Get-WeduDnsSnapshot
    Save-Json -Value $dnsPostAuth -Path $script:DnsPostAuthPath

    $networkAfter = Get-WeduNetworkSnapshot
    Save-Json -Value $networkAfter -Path $script:NetworkAfterPath

    $openPathProtectionAfter = Test-OpenPathProtectionAfter
    Save-Json -Value $openPathProtectionAfter -Path $script:OpenPathProtectionAfterPath
    $postconditionAssertions = Assert-WeduPostconditions -Config $config -BrowserPayload $browserBeforePayload -OpenPathProtectionAfter $openPathProtectionAfter
    if (-not $postconditionAssertions.success) {
        throw 'WEDU lab postcondition assertions did not all pass.'
    }
    $recoveryArtifacts = Copy-WeduRecoveryArtifacts

    $targetPlatformSymptomCleared = [bool]($browserAfterAuth.postAuthBrowserNavigationVerified)
    $success = [bool](
        $labNetwork.labNetworkVerified -and
        $nativeRecovery.success -and
        $activeMarkerMode -eq 'limited' -and
        $limitedModeReady -and
        $limitedDns.success -and
        $browserLimited.portalReady -and
        $browserLimited.finalLoginHost -eq $script:WeduLoginHost -and
        $browserLimited.loginSubmitted -and
        $nativeReconcile.success -and
        $nativeReconcile.state -eq 'Authenticated' -and
        $openPathProtectionAfter.protectedModeRestored -and
        $targetPlatformSymptomCleared
    )

    return [pscustomobject]@{
        schemaVersion = 2
        profile = 'captive-portal-wedu-lab'
        success = $success
        evidenceLevel = 'wedu-lab-direct-runner'
        targetPlatformSymptomCleared = [bool]$targetPlatformSymptomCleared
        labNetwork = $labNetwork
        limitedDns = $limitedDns
        gatewayReset = $gatewayReset
        negativeControls = $negativeControls
        dnsBeforePath = 'wedu-lab-dns-before.json'
        browserBeforePath = 'wedu-lab-browser-before.json'
        dnsLimitedPath = 'wedu-lab-dns-limited.json'
        browserLimitedPath = 'wedu-lab-browser-limited.json'
        browserAfterAuthPath = 'wedu-lab-browser-post-auth.json'
        dnsPostAuthPath = 'wedu-lab-dns-post-auth.json'
        portalScreenshotPath = 'wedu-lab-portal-limited-mode.png'
        nativeRecoveryPath = 'wedu-lab-native-recovery.json'
        nativeReconcilePath = 'wedu-lab-native-reconcile.json'
        networkAfterPath = 'wedu-lab-network-after.json'
        openPathProtectionAfterPath = 'wedu-lab-openpath-protection-after.json'
        nativeRecovery = $nativeRecovery
        nativeReconcile = $nativeReconcile
        browserBefore = $browserBeforePayload
        browserAfterAuth = $browserAfterAuth
        dnsPostAuth = $dnsPostAuth
        browserLimited = $browserPayload
        activeMarkerMode = $activeMarkerMode
        limitedModeReady = $limitedModeReady
        bootstrapHosts = @($bootstrapHosts)
        observedRuntimeHosts = @($observedRuntimeHosts)
        pendingRuntimeHosts = @($pendingRuntimeHosts)
        discoveryTruncated = $discoveryTruncated
        fallbackMode = $fallbackMode
        postAuthBrowserNavigationVerified = [bool]$browserAfterAuth.postAuthBrowserNavigationVerified
        postAuthFailureKind = [string]$browserAfterAuth.postAuthFailureKind
        openPathProtectionAfter = $openPathProtectionAfter
        postconditionAssertions = $postconditionAssertions
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
        schemaVersion = 2
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
