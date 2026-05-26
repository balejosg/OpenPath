function Invoke-OpenPathDnsResolveName {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string]$Server = "127.0.0.1",
        [switch]$QuickTimeout
    )

    $resolveParams = @{
        Name = $Domain
        Server = $Server
        DnsOnly = $true
        ErrorAction = 'Stop'
    }
    $resolveCommand = Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue
    if ($QuickTimeout -and $resolveCommand -and $resolveCommand.Parameters.ContainsKey('QuickTimeout')) {
        $resolveParams['QuickTimeout'] = $true
    }

    return (Resolve-DnsName @resolveParams)
}

function Invoke-OpenPathDnsResolveNameWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string]$Server = "127.0.0.1",
        [int]$AttemptTimeoutSeconds = 0
    )

    if ($AttemptTimeoutSeconds -le 0 -or -not (Get-Command -Name Start-Job -ErrorAction SilentlyContinue)) {
        return (Invoke-OpenPathDnsResolveName -Domain $Domain -Server $Server -QuickTimeout:($AttemptTimeoutSeconds -gt 0))
    }

    $job = Start-Job -ScriptBlock {
        param(
            [string]$Domain,
            [string]$Server
        )

        $resolveParams = @{
            Name = $Domain
            Server = $Server
            DnsOnly = $true
            ErrorAction = 'Stop'
        }
        $resolveCommand = Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue
        if ($resolveCommand -and $resolveCommand.Parameters.ContainsKey('QuickTimeout')) {
            $resolveParams['QuickTimeout'] = $true
        }

        Resolve-DnsName @resolveParams
    } -ArgumentList $Domain, $Server

    try {
        $completed = Wait-Job -Job $job -Timeout $AttemptTimeoutSeconds
        if (-not $completed) {
            throw "DNS resolution attempt timed out after $AttemptTimeoutSeconds seconds for $Domain via $Server"
        }

        return (Receive-Job -Job $job -ErrorAction Stop)
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-OpenPathDnsWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string]$Server = "127.0.0.1",
        [int]$MaxAttempts = 12,
        [int]$DelayMilliseconds = 1000,
        [int]$AttemptTimeoutSeconds = 0
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $result = Invoke-OpenPathDnsResolveNameWithTimeout -Domain $Domain -Server $Server -AttemptTimeoutSeconds $AttemptTimeoutSeconds
            if ($result) { return $result }
        }
        catch { $lastError = $_ }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds $DelayMilliseconds }
    }

    if ($lastError) {
        Write-OpenPathLog "DNS resolution failed for $Domain via $Server after $MaxAttempts attempts: $lastError" -Level WARN
    }
    return $null
}

function Test-DNSResolution {
    param(
        [string]$Domain = "",
        [int]$MaxAttempts = 12,
        [int]$DelayMilliseconds = 1000,
        [int]$AttemptTimeoutSeconds = 0
    )

    $probeDomain = ([string]$Domain).Trim()
    if (-not $probeDomain) {
        $probeDomain = @((Get-OpenPathDnsProbeDomains) | Select-Object -First 1)[0]
    }
    if (-not $probeDomain) {
        Write-OpenPathLog "DNS resolution probe skipped because no allowed probe domains are available" -Level WARN
        return $false
    }

    $result = Resolve-OpenPathDnsWithRetry -Domain $probeDomain -MaxAttempts $MaxAttempts -DelayMilliseconds $DelayMilliseconds -AttemptTimeoutSeconds $AttemptTimeoutSeconds
    return ($null -ne $result)
}

function Test-DNSSinkhole {
    param([string]$Domain = "should-not-exist-test.com")
    try {
        $result = Resolve-DnsName -Name $Domain -Server 127.0.0.1 -DnsOnly -ErrorAction SilentlyContinue
        return ($null -eq $result)
    }
    catch {
        return $true
    }
}
