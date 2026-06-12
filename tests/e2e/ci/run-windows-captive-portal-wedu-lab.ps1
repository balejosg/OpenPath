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
$script:BrowserAfterAuthPath = Join-Path $script:ArtifactsRoot 'wedu-lab-browser-post-auth.json'
$script:DnsPostAuthPath = Join-Path $script:ArtifactsRoot 'wedu-lab-dns-post-auth.json'
$script:PortalScreenshotPath = Join-Path $script:ArtifactsRoot 'wedu-lab-portal-limited-mode.png'
$script:NetworkAfterPath = Join-Path $script:ArtifactsRoot 'wedu-lab-network-after.json'
$script:PostAuthNetworkFidelityPath = Join-Path $script:ArtifactsRoot 'wedu-lab-post-auth-network-fidelity.json'
$script:SplitDnsProtectedPath = Join-Path $script:ArtifactsRoot 'wedu-lab-split-dns-protected.json'
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
# Captive-portal domains the runner DECLARES in config.json. The autonomous
# watchdog reads these (Get-OpenPathConfiguredCaptivePortalDomains) to decide it
# may enter LIMITED mode; the declared portal host must be the lab portal host.
$script:WeduConfiguredPortalDomains = @($script:WeduHost, $script:WeduLoginHost, $script:WeduAssetHost, $script:WeduCdnHost, $script:WeduAuthHost)
# Stale/public upstream the runner's Acrylic forwards to (NOT the dedicated
# network DNS 10.77.0.53). It must NOT resolve the portal host, so protected-mode
# resolution fails and the watchdog must recover the network resolver itself.
$script:WeduStalePrimaryDns = '8.8.8.8'
$script:WeduStaleSecondaryDns = '8.8.4.4'
# The lab network's dedicated DNS (DHCP-offered) -- the ONLY resolver that knows
# the internal portal host. Permanent split DNS must place this on Acrylic's
# third upstream while the stale public primary above stays first.
$script:WeduExpectedNetworkDns = [string]$(if ($env:OPENPATH_WEDU_LAB_NETWORK_DNS) { $env:OPENPATH_WEDU_LAB_NETWORK_DNS } else { '10.77.0.53' })
$script:WatchdogTaskName = 'OpenPath-Watchdog'
$script:CaptiveMarkerPath = 'C:\OpenPath\data\captive-portal-active.json'
$script:CaptiveObservationPath = 'C:\OpenPath\data\captive-portal-observation.json'
$script:DetectionUrl = 'http://detectportal.firefox.com/success.txt'
$script:MsftConnectTestUrl = 'http://www.msftconnecttest.com/connecttest.txt'
$script:WeduCaptiveHostPattern = '10\.77\.0\.1|nce\.wedu\.comunidad\.madrid|wlogin\.wedu-lab\.test|assets\.wedu-lab\.test|cdn\.wedu-lab\.test|auth\.wedu-lab\.test|WEDU lab captive portal'
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

function ConvertTo-WeduNativeStringArray {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = @($Value)
    $normalized = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        if ($null -eq $item) {
            continue
        }
        if ($item -is [hashtable] -and $item.Count -eq 0) {
            continue
        }
        if ($item -is [pscustomobject] -and @($item.PSObject.Properties).Count -eq 0) {
            continue
        }

        $text = ([string]$item).Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq '@{}') {
            continue
        }
        if (-not $normalized.Contains($text)) {
            $normalized.Add($text)
        }
    }

    return @($normalized)
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

function Get-WeduAcrylicIniValue {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    # Match only on the key's own line. \s would swallow the LF that the agent's
    # Set-AcrylicGlobalSetting writes after an empty value, so an empty
    # TertiaryServerAddress= would capture the next line ("TertiaryServerPort=53").
    $match = [regex]::Match($Content, "(?m)^[ \t]*$escapedKey[ \t]*=[ \t]*([^\r\n]*?)[ \t]*$")
    if (-not $match.Success) {
        return ''
    }

    return ([string]$match.Groups[1].Value).Trim()
}

function Get-WeduAcrylicDnsSnapshot {
    $configError = ''
    $candidateConfigPaths = [System.Collections.Generic.List[string]]::new()

    try {
        $openPathConfigPath = Join-Path $script:InstalledOpenPathRoot 'config.json'
        if (Test-Path -LiteralPath $openPathConfigPath) {
            $openPathConfig = Get-Content -LiteralPath $openPathConfigPath -Raw | ConvertFrom-Json
            if ($openPathConfig.PSObject.Properties['acrylicPath'] -and $openPathConfig.acrylicPath) {
                $candidateConfigPaths.Add((Join-Path ([string]$openPathConfig.acrylicPath) 'AcrylicConfiguration.ini'))
            }
        }
    }
    catch {
        $configError = [string]$_
    }

    $fallbackPaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Acrylic DNS Proxy\AcrylicConfiguration.ini'),
        (Join-Path $env:ProgramFiles 'Acrylic DNS Proxy\AcrylicConfiguration.ini')
    )
    foreach ($path in $fallbackPaths) {
        if ($path -and -not $candidateConfigPaths.Contains($path)) {
            $candidateConfigPaths.Add($path)
        }
    }

    $configPath = ''
    foreach ($path in @($candidateConfigPaths)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $configPath = $path
            break
        }
    }

    $primaryServerAddress = ''
    $secondaryServerAddress = ''
    if ($configPath) {
        try {
            $content = Get-Content -LiteralPath $configPath -Raw
            $primaryServerAddress = Get-WeduAcrylicIniValue -Content $content -Key 'PrimaryServerAddress'
            $secondaryServerAddress = Get-WeduAcrylicIniValue -Content $content -Key 'SecondaryServerAddress'
        }
        catch {
            $configError = [string]$_
        }
    }

    $serverAddresses = @($primaryServerAddress, $secondaryServerAddress) | Where-Object { $_ }
    return [pscustomobject]@{
        configPath = $configPath
        configRead = [bool]($configPath -and -not [string]::IsNullOrWhiteSpace($primaryServerAddress))
        primaryServerAddress = $primaryServerAddress
        secondaryServerAddress = $secondaryServerAddress
        serverAddresses = @($serverAddresses)
        error = $configError
    }
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
        acrylic = Get-WeduAcrylicDnsSnapshot
    }
}

function Assert-WeduLabNetwork {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedSubnet,
        [Parameter(Mandatory = $true)][string]$ExpectedDns
    )

    $addressesInSubnet = @()
    $adapterDnsMatches = @()
    $localResolverAdapters = @()
    foreach ($adapter in @($Snapshot.adapters)) {
        foreach ($address in @($adapter.ipv4Addresses)) {
            if ($address -and (Test-IPv4InSubnet -Address $address -Subnet $ExpectedSubnet)) {
                $addressesInSubnet += $address
            }
        }
        foreach ($server in @($adapter.dnsServers)) {
            if ($server -eq $ExpectedDns) {
                $adapterDnsMatches += $server
            }
            if ($server -eq '127.0.0.1') {
                $localResolverAdapters += [string]$adapter.interfaceAlias
            }
        }
    }

    $acrylic = if ($Snapshot.PSObject.Properties['acrylic']) { $Snapshot.acrylic } else { Get-WeduAcrylicDnsSnapshot }
    $acrylicDnsMatches = @()
    if ($localResolverAdapters.Count -gt 0) {
        foreach ($server in @($acrylic.serverAddresses)) {
            if ($server -eq $ExpectedDns) {
                $acrylicDnsMatches += $server
            }
        }
    }

    if ($addressesInSubnet.Count -eq 0) {
        throw "Fail-closed: this Windows VM is not on WEDU lab subnet $ExpectedSubnet."
    }
    if ($adapterDnsMatches.Count -eq 0 -and $acrylicDnsMatches.Count -eq 0) {
        throw "Fail-closed: this Windows VM is not using WEDU lab DNS $ExpectedDns."
    }

    return [pscustomobject]@{
        labNetworkVerified = $true
        addressesInSubnet = @($addressesInSubnet)
        dnsMatches = @($adapterDnsMatches + $acrylicDnsMatches)
        adapterDnsMatches = @($adapterDnsMatches)
        acrylicDnsMatches = @($acrylicDnsMatches)
        localResolverAdapters = @($localResolverAdapters)
        acrylic = $acrylic
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
    $network = Get-WeduNetworkSnapshot
    $queries = foreach ($domain in $domains) {
        try {
            $answers = @(Resolve-DnsName -Name $domain -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
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
        resolverServer = '127.0.0.1'
        adapters = @($network.adapters)
        acrylic = $network.acrylic
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
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [bool]$SubmitLogin = $true
    )

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
        $loginClicked = $false
        if ($SubmitLogin) {
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
            $loginClicked = [bool]$loginSubmittedResult.value
        }
        $postSubmitFinalUrl = $finalUrl
        $postSubmitNavigationCompleted = $false
        if ($loginClicked) {
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
            loginSubmitted = [bool]($loginClicked -and $postSubmitNavigationCompleted)
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
    $resolverServer = '127.0.0.1'
    $network = Get-WeduNetworkSnapshot
    $adaptersUsingLocalDns = @(
        @($network.adapters) |
            Where-Object { @($_.dnsServers) -contains $resolverServer } |
            ForEach-Object { [string]$_.interfaceAlias } |
            Where-Object { $_ }
    )
    $activeAdapters = @(
        @($network.adapters) |
            Where-Object { @($_.ipv4Addresses).Count -gt 0 -or @($_.ipv4DefaultGateway).Count -gt 0 }
    )
    $adapterLocalDnsRestored = ($activeAdapters.Count -gt 0 -and $adaptersUsingLocalDns.Count -eq $activeAdapters.Count)
    $acrylicPrimaryServerAddress = if ($network.acrylic) { [string]$network.acrylic.primaryServerAddress } else { '' }
    $acrylicSecondaryServerAddress = if ($network.acrylic) { [string]$network.acrylic.secondaryServerAddress } else { '' }
    $acrylicHostsPath = ''
    $acrylicHostsReadable = $false
    $acrylicHostsError = ''
    $acrylicNxWildcardPresent = $false
    $acrylicCaptivePortalSectionPresent = $false
    $blocked = $false
    $allowedFunctional = $false
    $blockedError = ''
    $allowedError = ''

    if ($network.acrylic -and $network.acrylic.configPath) {
        $acrylicHostsPath = Join-Path (Split-Path -Parent ([string]$network.acrylic.configPath)) 'AcrylicHosts.txt'
        if (Test-Path -LiteralPath $acrylicHostsPath) {
            try {
                $acrylicHostsContent = Get-Content -LiteralPath $acrylicHostsPath -Raw -ErrorAction Stop
                $acrylicHostsReadable = $true
                $acrylicNxWildcardPresent = [bool]($acrylicHostsContent -match '(?m)^NX \*$')
                $acrylicCaptivePortalSectionPresent = [bool]($acrylicHostsContent -match 'CAPTIVE PORTAL RECOVERY')
            }
            catch {
                $acrylicHostsError = [string]$_
            }
        }
    }

    try {
        $blockedAnswers = @(Resolve-DnsName -Name $blockedDomain -Server $resolverServer -DnsOnly -ErrorAction SilentlyContinue)
        $blocked = ($blockedAnswers.Count -eq 0)
    }
    catch {
        $blocked = $true
        $blockedError = [string]$_
    }

    try {
        $allowedAnswers = @(Resolve-DnsName -Name $allowedDomain -Server $resolverServer -DnsOnly -Type A -ErrorAction Stop)
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
        server = $resolverServer
        resolverServer = $resolverServer
        adapterLocalDnsRestored = $adapterLocalDnsRestored
        adaptersUsingLocalDns = @($adaptersUsingLocalDns)
        networkSnapshot = $network
        acrylicPrimaryServerAddress = $acrylicPrimaryServerAddress
        acrylicSecondaryServerAddress = $acrylicSecondaryServerAddress
        acrylicHostsPath = $acrylicHostsPath
        acrylicHostsReadable = $acrylicHostsReadable
        acrylicHostsError = $acrylicHostsError
        acrylicNxWildcardPresent = $acrylicNxWildcardPresent
        acrylicCaptivePortalSectionPresent = $acrylicCaptivePortalSectionPresent
        protectedModeRestored = ($blocked -and $allowedFunctional -and $adapterLocalDnsRestored -and $acrylicNxWildcardPresent -and -not $acrylicCaptivePortalSectionPresent)
    }
}

function Set-WeduConfigProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($Config.PSObject.Properties[$Name]) {
        $Config.$Name = $Value
    }
    else {
        $Config | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Ensure-WeduDirectRunnerConfig {
    # Declare the lab portal host as a captive-portal recovery domain and point
    # Acrylic at a stale/public upstream. The autonomous watchdog reads
    # captivePortalDomains to know it may enter LIMITED mode, and the stale
    # primaryDNS reproduces the production condition where the configured upstream
    # cannot resolve the portal host.
    $configPath = Join-Path (Join-Path $script:InstalledOpenPathRoot 'data') 'config.json'
    New-Item -ItemType Directory -Path (Split-Path $configPath -Parent) -Force | Out-Null

    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "WEDU runner config is invalid JSON at ${configPath}: $_"
        }
    }
    else {
        $config = [pscustomobject]@{}
    }

    Set-WeduConfigProperty -Config $config -Name 'primaryDNS' -Value $script:WeduStalePrimaryDns
    Set-WeduConfigProperty -Config $config -Name 'secondaryDNS' -Value $script:WeduStaleSecondaryDns
    Set-WeduConfigProperty -Config $config -Name 'captivePortalDomains' -Value @($script:WeduConfiguredPortalDomains)
    Set-WeduConfigProperty -Config $config -Name 'enableFirewall' -Value $true

    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
    return [pscustomobject]@{
        path = $configPath
        primaryDNS = [string]$config.primaryDNS
        captivePortalDomains = @($config.captivePortalDomains)
    }
}

function Test-WeduConfiguredUpstreamPortalResolution {
    # Probe the portal host against the configured (stale/public) Acrylic upstream.
    # In a production-faithful lab this must FAIL: the configured upstream does not
    # know the internal portal host, so the agent has to recover the network DNS.
    param([AllowNull()][string]$ConfiguredUpstream)

    if ([string]::IsNullOrWhiteSpace($ConfiguredUpstream)) {
        return [pscustomobject]@{ configuredUpstream = ''; resolves = $false; addresses = @(); error = 'no configured upstream' }
    }

    $resolves = $false
    $addresses = @()
    $errorText = ''
    try {
        $answers = @(Resolve-DnsName -Name $script:WeduHost -Server $ConfiguredUpstream -DnsOnly -Type A -ErrorAction Stop)
        $addresses = @($answers | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
        $resolves = [bool]($addresses.Count -gt 0)
    }
    catch {
        $errorText = [string]$_
    }

    return [pscustomobject]@{
        configuredUpstream = $ConfiguredUpstream
        resolves = $resolves
        addresses = @($addresses)
        error = $errorText
    }
}

function Invoke-WeduSplitDnsProtectedCheck {
    # Stage C2: the agent SUPPRESSES autonomous captive-portal-mode entry when
    # permanent split DNS is active. With the watchdog ENABLED and running normally
    # the captive-portal marker must NEVER appear across multiple watchdog cycles
    # (markerNeverPresent), while the portal host resolves in protected mode via
    # the third Acrylic upstream (the network DHCP DNS). The distinguishing split
    # signal: network DNS on TERTIARY, configured public resolver stays PRIMARY.
    param(
        # Drive the watchdog past the legacy entry threshold (two consecutive
        # 'Portal' detections) so the would-enter is actually suppressed -- the
        # marker is checked after EVERY cycle. Then keep cycling until split DNS
        # has settled (tertiary applied AND the portal resolves), because in the
        # lab several tasks contend over the Acrylic config and the drift refresh
        # may land a cycle or two in.
        [int]$MaxCycles = 6,
        [int]$DelaySeconds = 2
    )

    $runError = ''
    $applied = $false
    $primaryServerAddress = ''
    $tertiaryServerAddress = ''
    $portalAddresses = @()
    $portalResolveError = ''
    $resolvedAtLeastOnce = $false
    $blockedDomainStillBlocked = $false
    $blockedError = ''
    $markerNeverPresent = $true
    $updateTaskDisabled = $false

    try {
        # In the lab the OpenPath-Update task ALWAYS fails (no whitelist URL in the
        # runner config) and rewrites the Acrylic config mid-check, racing the
        # split-DNS drift refresh and blanking the third upstream. Disable it for
        # the duration; the OpenPath-Watchdog task stays ENABLED so we still prove
        # the watchdog suppresses portal-mode entry on its own.
        try { Disable-ScheduledTask -TaskName 'OpenPath-Update' -ErrorAction Stop | Out-Null; $updateTaskDisabled = $true }
        catch { $runError = "disable update: $_" }

        for ($cycle = 1; $cycle -le $MaxCycles; $cycle++) {
            try {
                # Start-ScheduledTask is async; a captive-network watchdog pass runs
                # the protected-mode repair probes first and can take 60-90s. Wait
                # for the task to actually START (running, or LastRunTime advanced)
                # and then to FINISH (up to ~120s) before reading state.
                $priorRun = Get-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue |
                    Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                $priorRunTime = if ($priorRun) { [datetime]$priorRun.LastRunTime } else { [datetime]::MinValue }
                Start-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction Stop
                $applied = $true
                $started = $false
                for ($wait = 1; $wait -le 280; $wait++) {
                    Start-Sleep -Milliseconds 500
                    $info = Get-ScheduledTask -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue |
                        Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                    if (-not $info) { continue }
                    # 267009 (0x41301) == task is currently running; LastTaskResult is
                    # an unsigned 32-bit code that overflows [int], hence the [long].
                    $running = ([long]$info.LastTaskResult -eq 267009)
                    $ranThisCycle = ([datetime]$info.LastRunTime -gt $priorRunTime)
                    if (-not $started) {
                        if ($running -or $ranThisCycle) { $started = $true }
                        continue
                    }
                    if (-not $running) { break }
                }
            }
            catch {
                $runError = ($runError + " | cycle ${cycle}: $_").Trim(' |')
            }

            # The C2 keystone: the marker must NEVER appear after a watchdog run
            # while split DNS is active -- not on this cycle, not on any cycle.
            if (Test-Path -LiteralPath $script:CaptiveMarkerPath) {
                $markerNeverPresent = $false
            }

            # Read the applied topology this cycle (the drift refresh may land late).
            $acrylic = Get-WeduAcrylicDnsSnapshot
            if ($acrylic.configPath) {
                try {
                    $iniContent = Get-Content -LiteralPath $acrylic.configPath -Raw -ErrorAction Stop
                    $primaryServerAddress = Get-WeduAcrylicIniValue -Content $iniContent -Key 'PrimaryServerAddress'
                    $tertiaryServerAddress = Get-WeduAcrylicIniValue -Content $iniContent -Key 'TertiaryServerAddress'
                }
                catch { }
            }

            try {
                $answers = @(Resolve-DnsName -Name $script:WeduHost -Server 127.0.0.1 -DnsOnly -Type A -ErrorAction Stop)
                $cycleAddresses = @($answers | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
                if ($cycleAddresses.Count -gt 0) {
                    $portalAddresses = $cycleAddresses
                    $resolvedAtLeastOnce = $true
                    $portalResolveError = ''
                }
            }
            catch {
                $portalResolveError = [string]$_
            }

            # Stop once split DNS has settled: tertiary is the network DNS AND the
            # portal resolves. (We have already crossed the entry threshold by now.)
            if ($tertiaryServerAddress -eq $script:WeduExpectedNetworkDns -and $resolvedAtLeastOnce) {
                break
            }
            if ($cycle -lt $MaxCycles) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }

        try {
            $blockedAnswers = @(Resolve-DnsName -Name 'this-should-be-blocked-test-12345.com' -Server 127.0.0.1 -DnsOnly -ErrorAction SilentlyContinue)
            $blockedDomainStillBlocked = ($blockedAnswers.Count -eq 0)
        }
        catch {
            $blockedDomainStillBlocked = $true
            $blockedError = [string]$_
        }
    }
    finally {
        if ($updateTaskDisabled) {
            try { Enable-ScheduledTask -TaskName 'OpenPath-Update' -ErrorAction Stop | Out-Null }
            catch { $runError = ($runError + " | re-enable update: $_").Trim(' |') }
        }
    }

    $acrylic = Get-WeduAcrylicDnsSnapshot
    if ($acrylic.configPath) {
        try {
            $iniContent = Get-Content -LiteralPath $acrylic.configPath -Raw -ErrorAction Stop
            $primaryServerAddress = Get-WeduAcrylicIniValue -Content $iniContent -Key 'PrimaryServerAddress'
            $tertiaryServerAddress = Get-WeduAcrylicIniValue -Content $iniContent -Key 'TertiaryServerAddress'
        }
        catch { }
    }

    # Diagnostic: if the SCHEDULED watchdog task did not apply split DNS (empty
    # tertiary), run the watchdog script DIRECTLY once and re-read the INI. If the
    # direct run applies it but the scheduled task did not, the drift refresh has a
    # scheduled-task-context problem; if neither applies it, the drift block itself
    # is broken. Purely diagnostic -- not part of the pass/fail decision.
    $directRunTertiary = ''
    if (-not $tertiaryServerAddress) {
        try {
            $watchdogScript = Join-Path $script:InstalledOpenPathRoot 'scripts\Test-DNSHealth.ps1'
            if (Test-Path -LiteralPath $watchdogScript) {
                $directOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdogScript 2>&1 | Out-String
                Set-Content -LiteralPath (Join-Path $script:ArtifactsRoot 'wedu-lab-watchdog-direct.txt') -Value ("exit=$LASTEXITCODE`n--- output ---`n$directOut") -Encoding UTF8 -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                if ($acrylic.configPath -and (Test-Path -LiteralPath $acrylic.configPath)) {
                    $iniAfter = Get-Content -LiteralPath $acrylic.configPath -Raw -ErrorAction SilentlyContinue
                    # Diagnostic only -- do NOT overwrite the scheduled-task result
                    # fields ($tertiaryServerAddress stays the scheduled task's value).
                    $directRunTertiary = Get-WeduAcrylicIniValue -Content $iniAfter -Key 'TertiaryServerAddress'
                }
            }
        }
        catch { }
    }

    $portalResolvesInProtectedMode = [bool]$resolvedAtLeastOnce
    # The split-DNS signal that distinguishes it from limited mode: the network
    # resolver is the THIRD upstream while the configured public resolver stays
    # PRIMARY. Limited mode would put the network resolver on Primary/Secondary.
    $splitTopologyActive = [bool](
        $tertiaryServerAddress -eq $script:WeduExpectedNetworkDns -and
        $primaryServerAddress -eq $script:WeduStalePrimaryDns
    )

    return [pscustomobject]@{
        portalHost = $script:WeduHost
        portalResolvesInProtectedMode = $portalResolvesInProtectedMode
        portalAddresses = @($portalAddresses)
        portalResolveError = $portalResolveError
        markerNeverPresent = $markerNeverPresent
        blockedDomainStillBlocked = $blockedDomainStillBlocked
        blockedError = $blockedError
        splitTopologyActive = $splitTopologyActive
        primaryServerAddress = $primaryServerAddress
        tertiaryServerAddress = $tertiaryServerAddress
        directRunTertiary = $directRunTertiary
        appliedViaProductPath = $applied
        watchdogRunError = $runError
    }
}

function Test-WeduPostAuthNetworkFidelity {
    # Production-faithful post-auth posture: once the user authenticates, the
    # network is OPEN (general egress works -- that is exactly why a stuck relaxed
    # mode shows up as fully unrestricted navigation in production), while the
    # portal host REMAINS resolvable only through the network's own DNS. Both must
    # hold or the exit phase would be proving the wrong thing (e.g. the portal host
    # suddenly becoming publicly resolvable would let the exit pass for the wrong
    # reason).
    $publicProbeDomain = 'www.msftconnecttest.com'
    $publicResolver = $script:WeduStalePrimaryDns

    $publicDnsResolves = $false
    $publicDnsError = ''
    try {
        $answers = @(Resolve-DnsName -Name $publicProbeDomain -Server $publicResolver -DnsOnly -Type A -ErrorAction Stop)
        $publicDnsResolves = (@($answers | Where-Object { $_.IPAddress }).Count -gt 0)
    }
    catch {
        $publicDnsError = [string]$_
    }

    # Fallback "network open" signal that does not depend on the local OpenPath
    # firewall allowing direct client DNS to the public resolver: the NCSI-style
    # probe must return its REAL content (no portal interception) post-auth.
    $detectionProbe = Invoke-HttpProbe -Url $script:DetectionUrl
    $externalHttpFunctional = [bool](
        $detectionProbe.statusCode -eq 200 -and
        -not (Test-CaptivePortalEvidence -Probe $detectionProbe)
    )
    $postAuthExternalNetworkOpen = [bool]($publicDnsResolves -or $externalHttpFunctional)

    $portalHostProbe = Test-WeduConfiguredUpstreamPortalResolution -ConfiguredUpstream $publicResolver
    $postAuthPortalHostStillNetworkOnly = [bool](
        $postAuthExternalNetworkOpen -and
        -not $portalHostProbe.resolves
    )

    return [pscustomobject]@{
        publicResolver = $publicResolver
        publicProbeDomain = $publicProbeDomain
        publicDnsResolves = $publicDnsResolves
        publicDnsError = $publicDnsError
        externalHttpFunctional = $externalHttpFunctional
        detectionProbe = $detectionProbe
        portalHostProbe = $portalHostProbe
        postAuthExternalNetworkOpen = $postAuthExternalNetworkOpen
        postAuthPortalHostStillNetworkOnly = $postAuthPortalHostStillNetworkOnly
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
    $passiveFinalUrl = if ($portalProbe.location) { [string]$portalProbe.location } else { "http://$script:WeduHost/" }
    $passiveFinalHost = ''
    try {
        $passiveFinalHost = ([System.Uri]$passiveFinalUrl).Host
    }
    catch { }
    $browserBefore = [pscustomobject]@{
        gatewayUrl = $config.gatewayUrl
        targetUrl = "http://$script:WeduHost/"
        finalUrl = $passiveFinalUrl
        finalLoginHost = $passiveFinalHost
        title = ''
        portalDetected = (Test-CaptivePortalEvidence -Probe $portalProbe)
        portalReady = $false
        loginSubmitted = $false
        postSubmitFinalUrl = $passiveFinalUrl
        postSubmitNavigationCompleted = $false
        expectedLoginHost = $script:WeduLoginHost
        expectedAssetsHost = $script:WeduAssetHost
        expectedCdnHost = $script:WeduCdnHost
        expectedAuthHost = $script:WeduAuthHost
        screenshotPath = ''
        geckoDriverOutPath = ''
        geckoDriverErrPath = ''
    }
    $browserPortalDetected = [bool]$browserBefore.portalDetected
    $weduHostPortalDetected = Test-CaptivePortalEvidence -Probe $portalProbe
    $detectPortalInterceptionObserved = Test-CaptivePortalEvidence -Probe $successProbe
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

    # Declare the portal host as a recovery domain and force a stale/public Acrylic
    # upstream so the watchdog has captivePortalDomains declared and a configured
    # upstream that cannot resolve the portal host.
    $runnerConfig = Ensure-WeduDirectRunnerConfig

    # Negative control: the configured (stale/public) upstream must NOT resolve the
    # portal host -- otherwise the lab is not reproducing the production condition.
    $networkForUpstream = Get-WeduNetworkSnapshot
    $configuredUpstream = ''
    if ($networkForUpstream.acrylic -and $networkForUpstream.acrylic.primaryServerAddress) {
        $configuredUpstream = [string]$networkForUpstream.acrylic.primaryServerAddress
    }
    if ([string]::IsNullOrWhiteSpace($configuredUpstream)) {
        $configuredUpstream = [string]$runnerConfig.primaryDNS
    }
    $configuredUpstreamProbe = Test-WeduConfiguredUpstreamPortalResolution -ConfiguredUpstream $configuredUpstream
    $configuredUpstreamResolvesPortalHost = [bool]$configuredUpstreamProbe.resolves
    Save-Json -Value $configuredUpstreamProbe -Path (Join-Path $script:ArtifactsRoot 'wedu-lab-configured-upstream-probe.json')

    # Stage C2 invariant: with split DNS active the watchdog SUPPRESSES autonomous
    # captive-portal-mode entry. Drive the real scheduled task N cycles and assert
    # the marker NEVER appears while the portal host resolves via the third upstream.
    $splitDnsProtected = Invoke-WeduSplitDnsProtectedCheck
    Save-Json -Value $splitDnsProtected -Path $script:SplitDnsProtectedPath
    # Capture the agent log so a failure here (e.g. the drift refresh not applying
    # the third upstream via the scheduled watchdog task) is diagnosable.
    Copy-Item -LiteralPath 'C:\OpenPath\data\logs\openpath.log' -Destination (Join-Path $script:ArtifactsRoot 'wedu-lab-openpath.log') -ErrorAction SilentlyContinue

    $dnsBefore = Get-WeduDnsSnapshot
    Save-Json -Value $dnsBefore -Path $script:DnsBeforePath

    # The browser login is the ONLY authentication act: the portal's /session
    # handler flips the gateway firewall to authenticated mode, exactly as a real
    # user sign-in does. The harness must NEVER flip the gateway through the
    # control endpoint. With split DNS active the portal resolves in protected mode
    # (no limited-mode entry), so the browser reaches it via Acrylic's third upstream.
    $browserLimited = Invoke-WeduBrowserProbe -Config $config

    # Diagnostic fields retained for the evidence contract (diagnostic-only,
    # not used in $success): split DNS replaces limited-mode host plumbing.
    $bootstrapHosts = @()
    $redirectHosts = @()
    $resourceHosts = @()
    $observedRuntimeHosts = @()
    $pendingRuntimeHosts = @()
    $discoveryTruncated = $false
    $fallbackMode = ''

    $postAuthNetworkFidelity = Test-WeduPostAuthNetworkFidelity
    Save-Json -Value $postAuthNetworkFidelity -Path $script:PostAuthNetworkFidelityPath
    $gatewayAuthenticated = [pscustomobject]@{
        via = 'browser-login'
        loginSubmitted = [bool]$browserLimited.loginSubmitted
        externalNetworkOpen = [bool]$postAuthNetworkFidelity.postAuthExternalNetworkOpen
        success = [bool]($browserLimited.loginSubmitted -and $postAuthNetworkFidelity.postAuthExternalNetworkOpen)
    }

    # Post-auth marker check: with split DNS suppression the marker must STILL never
    # have appeared -- not before auth, not after. Capture the live state.
    $postAuthMarkerNeverPresent = (-not (Test-Path -LiteralPath $script:CaptiveMarkerPath))

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
        (-not $configuredUpstreamResolvesPortalHost) -and
        $splitDnsProtected.portalResolvesInProtectedMode -and
        $splitDnsProtected.markerNeverPresent -and
        $splitDnsProtected.splitTopologyActive -and
        $splitDnsProtected.blockedDomainStillBlocked -and
        $browserLimited.portalReady -and
        $browserLimited.finalLoginHost -eq $script:WeduLoginHost -and
        $browserLimited.loginSubmitted -and
        $gatewayAuthenticated.success -and
        $postAuthNetworkFidelity.postAuthExternalNetworkOpen -and
        $postAuthNetworkFidelity.postAuthPortalHostStillNetworkOnly -and
        $postAuthMarkerNeverPresent -and
        $openPathProtectionAfter.protectedModeRestored -and
        $targetPlatformSymptomCleared
    )

    return [pscustomobject]@{
        schemaVersion = 2
        profile = 'captive-portal-wedu-lab'
        success = $success
        evidenceLevel = 'wedu-lab-direct-runner'
        targetPlatformSymptomCleared = [bool]$targetPlatformSymptomCleared
        configuredUpstreamResolvesPortalHost = [bool]$configuredUpstreamResolvesPortalHost
        configuredUpstreamProbe = $configuredUpstreamProbe
        gatewayAuthenticated = $gatewayAuthenticated
        postAuthMarkerNeverPresent = [bool]$postAuthMarkerNeverPresent
        postAuthExternalNetworkOpen = [bool]$postAuthNetworkFidelity.postAuthExternalNetworkOpen
        postAuthPortalHostStillNetworkOnly = [bool]$postAuthNetworkFidelity.postAuthPortalHostStillNetworkOnly
        postAuthNetworkFidelity = $postAuthNetworkFidelity
        splitDnsProtected = $splitDnsProtected
        splitDnsProtectedPath = 'wedu-lab-split-dns-protected.json'
        runnerConfig = $runnerConfig
        labNetwork = $labNetwork
        gatewayReset = $gatewayReset
        negativeControls = $negativeControls
        dnsBeforePath = 'wedu-lab-dns-before.json'
        browserBeforePath = 'wedu-lab-browser-before.json'
        browserAfterAuthPath = 'wedu-lab-browser-post-auth.json'
        dnsPostAuthPath = 'wedu-lab-dns-post-auth.json'
        portalScreenshotPath = 'wedu-lab-portal-limited-mode.png'
        networkAfterPath = 'wedu-lab-network-after.json'
        openPathProtectionAfterPath = 'wedu-lab-openpath-protection-after.json'
        browserBefore = $browserBeforePayload
        browserAfterAuth = $browserAfterAuth
        dnsPostAuth = $dnsPostAuth
        # Diagnostic-only fields retained for the evidence contract.
        bootstrapHosts = @($bootstrapHosts)
        redirectHosts = @($redirectHosts)
        resourceHosts = @($resourceHosts)
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
    # Start from a clean slate so a stale result from a previous run can never be
    # mistaken for this run's evidence.
    Remove-Item -LiteralPath $script:ResultPath -Force -ErrorAction SilentlyContinue
    $result = Invoke-WeduLabRun
    Save-Json -Value $result -Path $script:ResultPath
    if (-not $result.success) {
        throw 'WEDU lab direct-runner checks did not all pass.'
    }
}
catch {
    # Never clobber a rich result written above: its per-phase evidence is exactly
    # what a failed run needs for diagnosis. The bare error payload is only for
    # runs that died before Invoke-WeduLabRun could produce a result.
    if (-not (Test-Path -LiteralPath $script:ResultPath)) {
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
    }
    throw
}
