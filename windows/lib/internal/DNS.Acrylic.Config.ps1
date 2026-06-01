function Get-OpenPathDnsSettings {
    [CmdletBinding()]
    param()

    $settings = [ordered]@{
        PrimaryDNS = "8.8.8.8"
        SecondaryDNS = "8.8.4.4"
        MaxDomains = 500
    }

    try {
        $config = Get-OpenPathConfig
        if ($config.PSObject.Properties['primaryDNS'] -and $config.primaryDNS) { $settings.PrimaryDNS = [string]$config.primaryDNS }
        if ($config.PSObject.Properties['secondaryDNS'] -and $config.secondaryDNS) { $settings.SecondaryDNS = [string]$config.secondaryDNS }
        if ($config.PSObject.Properties['maxDomains'] -and ($config.maxDomains -as [int]) -gt 0) { $settings.MaxDomains = [int]$config.maxDomains }
    }
    catch {
        Write-Debug "OpenPath DNS settings unavailable, using defaults: $_"
    }

    return [PSCustomObject]$settings
}

function Invoke-OpenPathPolicyStateLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [string]$MutexName = 'Global\OpenPathPolicyStateLock',
        [int]$TimeoutMilliseconds = 15000
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $lockAcquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if (-not $lockAcquired) {
            throw "Timed out waiting for $MutexName"
        }

        return (& $Action)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try { $mutex.ReleaseMutex() }
            catch [System.ApplicationException] { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Update-AcrylicHost {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$WhitelistedDomains,
        [string[]]$BlockedSubdomains = @()
    )

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) {
        Write-OpenPathLog "Acrylic not found" -Level ERROR
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("AcrylicHosts.txt", "Update whitelist configuration")) { return $false }

    return [bool](Invoke-OpenPathPolicyStateLocked -Action {
        $hostsPath = "$acrylicPath\AcrylicHosts.txt"
        $dnsSettings = Get-OpenPathDnsSettings
        $captivePortalDomains = @()
        try {
            $openPathConfig = Get-OpenPathConfig
            if ($openPathConfig.PSObject.Properties['captivePortalDomains']) {
                $captivePortalDomains = @($openPathConfig.captivePortalDomains)
            }
        }
        catch {
            Write-Debug "OpenPath captive portal domains unavailable, using none: $_"
        }
        $runtimeDependencyDomains = Get-OpenPathRuntimeDependencyDomains -WhitelistedDomains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains -Prune
        $definition = New-AcrylicHostsDefinition -WhitelistedDomains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains -RuntimeDependencyDomains $runtimeDependencyDomains -CaptivePortalDomains $captivePortalDomains -DnsSettings $dnsSettings
        if ($definition.WasTruncated) {
            Write-OpenPathLog "Truncating whitelist from $($definition.OriginalWhitelistedDomainCount) to $($dnsSettings.MaxDomains) domains" -Level WARN
        }
        Write-OpenPathLog "Generating AcrylicHosts.txt with $(@($definition.EffectiveWhitelistedDomains).Count) domains..."
        $content = ConvertTo-AcrylicHostsContent -Definition $definition
        Write-AcrylicHostsFile -Path $hostsPath -Content $content

        $configurationUpdated = Set-AcrylicConfiguration -WhitelistedDomains $definition.EffectiveWhitelistedDomains -BlockedSubdomains $definition.BlockedSubdomains -RuntimeDependencyDomains $definition.RuntimeDependencyDomains -CaptivePortalDomains $definition.CaptivePortalDomains
        if (-not $configurationUpdated) {
            Write-OpenPathLog "Failed to update AcrylicConfiguration.ini" -Level ERROR
            return $false
        }
        Write-OpenPathLog "AcrylicHosts.txt updated"
        return $true
    })
}

function Set-AcrylicConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowEmptyCollection()][string[]]$WhitelistedDomains = @(),
        [AllowEmptyCollection()][string[]]$BlockedSubdomains = @(),
        [AllowEmptyCollection()][string[]]$RuntimeDependencyDomains = @(),
        [AllowEmptyCollection()][string[]]$CaptivePortalDomains = @()
    )

    $acrylicPath = Get-AcrylicPath
    if (-not $acrylicPath) { return $false }
    if (-not $PSCmdlet.ShouldProcess("AcrylicConfiguration.ini", "Configure Acrylic settings")) { return $false }

    $configPath = "$acrylicPath\AcrylicConfiguration.ini"
    $dnsSettings = Get-OpenPathDnsSettings
    Write-OpenPathLog "Configuring Acrylic..."

    $essentialForwardDomains = @(
        foreach ($group in @(Get-AcrylicEssentialDomainGroups)) {
            @($group.Domains)
        }
    )
    $affinityMaskEntries = @(
        Get-AcrylicAffinityMaskEntries -Domains $essentialForwardDomains
        Get-AcrylicAffinityMaskEntries -Domains $WhitelistedDomains -BlockedSubdomains $BlockedSubdomains
        Get-AcrylicExactAffinityMaskEntries -Domains (Get-AcrylicAllowedRuntimeDependencyDomains -Domains $RuntimeDependencyDomains -BlockedSubdomains $BlockedSubdomains)
        Get-AcrylicExactAffinityMaskEntries -Domains $CaptivePortalDomains
    ) | Select-Object -Unique
    $domainAffinityMask = ($affinityMaskEntries -join ';')

    $iniContent = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { "" }
    if ($iniContent -notmatch '(?m)^\[GlobalSection\]\s*$') {
        $iniContent = "[GlobalSection]`n$iniContent"
    }
    $settings = [ordered]@{
        "PrimaryServerAddress" = $dnsSettings.PrimaryDNS
        "PrimaryServerPort" = "53"
        "PrimaryServerProtocol" = "UDP"
        "PrimaryServerQueryTypeAffinityMask" = ""
        "SecondaryServerAddress" = $dnsSettings.SecondaryDNS
        "SecondaryServerPort" = "53"
        "SecondaryServerProtocol" = "UDP"
        "SecondaryServerQueryTypeAffinityMask" = ""
        "LocalIPv4BindingAddress" = "0.0.0.0"
        "LocalIPv4BindingPort" = "53"
        "LocalIPv6BindingAddress" = ""
        "LocalIPv6BindingPort" = "53"
        "LocalIPv6BindingEnabledOnWindowsVersionsPriorToWindowsVistaOrWindowsServer2008" = "No"
        "GeneratedResponseTimeToLive" = "300"
        "PrimaryServerDomainNameAffinityMask" = $domainAffinityMask
        "SecondaryServerDomainNameAffinityMask" = $domainAffinityMask
        "IgnoreFailureResponsesFromPrimaryServer" = "No"
        "IgnoreNegativeResponsesFromPrimaryServer" = "No"
        "IgnoreFailureResponsesFromSecondaryServer" = "No"
        "IgnoreNegativeResponsesFromSecondaryServer" = "No"
        "SinkholeIPv6Lookups" = "No"
        "ForwardPrivateReverseLookups" = "No"
        "AddressCacheFailureTime" = "0"
        "AddressCacheDisabled" = "No"
        "AddressCacheInMemoryOnly" = "Yes"
        "AddressCacheNegativeTime" = "0"
        "AddressCacheScavengingTime" = "5760"
        "AddressCacheSilentUpdateTime" = "1440"
        "AddressCachePeriodicPruningTime" = "360"
        "AddressCacheDomainNameAffinityMask" = "^dns.msftncsi.com;^ipv6.msftncsi.com;^www.msftncsi.com;*"
        "AddressCacheQueryTypeAffinityMask" = "A;AAAA;CNAME;MX;NS;PTR;SOA;SRV;TXT"
        "CacheSize" = "65536"
        "HitLogFileName" = ""
        "HitLogFileWhat" = "XHCF"
        "HitLogFullDump" = "No"
        "HitLogMaxPendingHits" = "512"
        "ErrorLogFileName" = ""
    }

    foreach ($key in $settings.Keys) {
        $iniContent = Set-AcrylicGlobalSetting -Content $iniContent -Key $key -Value $settings[$key]
    }

    if ($iniContent -notmatch '(?m)^\[AllowedAddressesSection\]\s*$') {
        $iniContent = $iniContent.TrimEnd() + "`n`n[AllowedAddressesSection]`n"
    }
    $iniContent = Set-AcrylicAllowedAddress -Content $iniContent -Key 'IP1' -Value '127.*'
    $iniContent = Set-AcrylicAllowedAddress -Content $iniContent -Key 'IP2' -Value '::1'

    Write-AcrylicConfigFile -Path $configPath -Content $iniContent
    Write-OpenPathLog "Acrylic configuration updated"
    return $true
}
