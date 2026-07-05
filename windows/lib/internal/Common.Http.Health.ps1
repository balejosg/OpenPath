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

function Get-OpenPathConfigPosture {
    <#
    .SYNOPSIS
        Builds the allowlisted effective flag-posture map for health reports.
    .DESCRIPTION
        Windows reports only the posture keys that exist on this platform.
        Values are canonical posture strings ('true'/'false'), matching the
        ConfigPosture schema in @openpath/shared.
    #>
    param(
        [PSCustomObject]$Config
    )

    $egressFloorEnabled = $false
    if ($Config -and $Config.PSObject.Properties['outboundEgressFloorEnabled']) {
        $egressFloorEnabled = [bool]$Config.outboundEgressFloorEnabled
    }

    $posture = @{}
    if ($egressFloorEnabled) {
        $posture['outboundEgressFloorEnabled'] = 'true'
    }
    else {
        $posture['outboundEgressFloorEnabled'] = 'false'
    }
    return $posture
}

function Get-OpenPathHealthReportFailStreakPath {
    return Join-Path $script:OpenPathRoot 'data\health-report-fail-streak.txt'
}

function Get-OpenPathHealthReportFailStreak {
    $path = Get-OpenPathHealthReportFailStreakPath
    if (-not (Test-Path $path)) {
        return 0
    }
    $raw = Get-Content $path -Raw -ErrorAction SilentlyContinue
    $value = 0
    if ([int]::TryParse(("$raw").Trim(), [ref]$value) -and $value -ge 0) {
        return $value
    }
    return 0
}

function Set-OpenPathHealthReportFailStreak {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Value
    )
    $path = Get-OpenPathHealthReportFailStreakPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -Path $path -Value ([string]$Value) -Encoding ASCII
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
    $failStreak = Get-OpenPathHealthReportFailStreak
    $reportBody = @{
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
        configPosture  = Get-OpenPathConfigPosture -Config $config
    }
    if ($failStreak -gt 0) {
        $reportBody['healthReportFailStreak'] = [int]$failStreak
    }
    $payload = @{ json = $reportBody } | ConvertTo-Json -Depth 8

    $healthUrl = "$($config.apiUrl.TrimEnd('/'))/trpc/healthReports.submit"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($authToken) {
        $headers['Authorization'] = "Bearer $authToken"
    }

    try {
        Invoke-RestMethod -Uri $healthUrl -Method Post -Headers $headers -Body $payload `
            -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Set-OpenPathHealthReportFailStreak -Value 0
        return $true
    }
    catch {
        $newStreak = (Get-OpenPathHealthReportFailStreak) + 1
        Set-OpenPathHealthReportFailStreak -Value $newStreak
        Write-OpenPathLog "Health report failed (non-critical, streak=$newStreak): $_" -Level WARN
        return $false
    }
}
