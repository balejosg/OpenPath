function Test-InternetConnection {
    <#
    .SYNOPSIS
        Tests if there is an active internet connection
    #>
    $testServer = '8.8.8.8'
    try {
        $result = Test-NetConnection -ComputerName $testServer -Port 53 -WarningAction SilentlyContinue
        return $result.TcpTestSucceeded
    }
    catch {
        return $false
    }
}

function Send-OpenPathHealthReport {
    <#
    .SYNOPSIS
        Sends machine health status to central API via tRPC
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [bool]$DnsServiceRunning = $false,

        [bool]$DnsResolving = $false,

        [int]$FailCount = 0,

        [string]$Actions = '',

        [string]$Version = 'unknown'
    )

    $config = $null
    try {
        $config = Get-OpenPathConfig
    }
    catch {
        return $false
    }

    if (-not ($config.PSObject.Properties['apiUrl']) -or -not $config.apiUrl) {
        return $false
    }

    $versionToSend = $Version
    if ($versionToSend -eq 'unknown' -and $config.PSObject.Properties['version'] -and $config.version) {
        $versionToSend = [string]$config.version
    }

    $authToken = ''
    if ($config.PSObject.Properties['whitelistUrl'] -and $config.whitelistUrl) {
        $authToken = Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl ([string]$config.whitelistUrl)
    }

    if (-not $authToken -and $config.PSObject.Properties['healthApiSecret'] -and $config.healthApiSecret) {
        $authToken = [string]$config.healthApiSecret
    }
    elseif (-not $authToken -and $env:OPENPATH_HEALTH_API_SECRET) {
        $authToken = [string]$env:OPENPATH_HEALTH_API_SECRET
    }

    # Canonical field names (v1.3+): agentVersion and platform are added alongside
    # the legacy version field so old API versions also accept the payload.
    # dnsState mirrors dnsResolving for the canonical schema.
    $payload = @{
        json = @{
            hostname       = Get-OpenPathMachineName
            status         = $Status
            dnsmasqRunning = [bool]$DnsServiceRunning
            dnsResolving   = [bool]$DnsResolving
            dnsState       = [bool]$DnsResolving
            failCount      = [int]$FailCount
            actions        = [string]$Actions
            version        = [string]$versionToSend
            agentVersion   = [string]$versionToSend
            platform       = 'windows'
        }
    } | ConvertTo-Json -Depth 8

    $healthUrl = "$($config.apiUrl.TrimEnd('/'))/trpc/healthReports.submit"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($authToken) {
        $headers['Authorization'] = "Bearer $authToken"
    }

    try {
        Invoke-RestMethod -Uri $healthUrl -Method Post -Headers $headers -Body $payload `
            -TimeoutSec 10 -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-OpenPathLog "Health report failed (non-critical): $_" -Level WARN
        return $false
    }
}
