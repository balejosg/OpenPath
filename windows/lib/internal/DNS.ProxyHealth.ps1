function New-OpenPathDnsProxyState {
    <#
    .SYNOPSIS
    Builds the immutable proxy-state fact consumed by the watchdog and repair paths.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [string]$ServiceStatus = '',
        [object]$ListenerPid = $null,
        [string]$ListenerProcessName = '',
        [bool]$AcrylicInstalled = $false
    )

    return [PSCustomObject]@{
        State = $State
        ServiceStatus = $ServiceStatus
        ListenerPid = $ListenerPid
        ListenerProcessName = $ListenerProcessName
        AcrylicInstalled = $AcrylicInstalled
    }
}

function Get-OpenPathDnsProxyState {
    <#
    .SYNOPSIS
    Reports whether the local Acrylic DNS proxy is actually serving 127.0.0.1:53.
    .DESCRIPTION
    Distinguishes a missing installation, a stopped/unregistered service, a port owned by
    another process, and a healthy listener. Returns State = unknown when the platform
    cmdlets are unavailable or fail, so callers never take repair action on incomplete
    evidence. The owning process of a conflicting listener is reported, never terminated.
    #>
    [CmdletBinding()]
    param()

    try {
        $acrylicInstalled = [bool](Test-AcrylicInstalled)
    }
    catch {
        Write-OpenPathLog "DNS proxy state check failed to inspect the Acrylic installation: $_" -Level WARN
        return New-OpenPathDnsProxyState -State 'unknown'
    }

    if (-not $acrylicInstalled) {
        return New-OpenPathDnsProxyState -State 'missing' -AcrylicInstalled $false
    }

    $acrylicPath = $null
    try {
        $acrylicPath = Get-AcrylicPath
    }
    catch {
        Write-OpenPathLog "DNS proxy state check failed to resolve the Acrylic path: $_" -Level WARN
        return New-OpenPathDnsProxyState -State 'unknown' -AcrylicInstalled $true
    }

    if (-not $acrylicPath -or -not (Test-Path (Join-Path $acrylicPath 'AcrylicService.exe'))) {
        return New-OpenPathDnsProxyState -State 'missing' -AcrylicInstalled $true
    }

    $service = $null
    try {
        $service = Get-AcrylicService
    }
    catch {
        Write-OpenPathLog "DNS proxy state check failed to inspect the Acrylic service: $_" -Level WARN
        return New-OpenPathDnsProxyState -State 'unknown' -AcrylicInstalled $true
    }

    $serviceStatus = if ($service -and $service.PSObject.Properties['Status']) { [string]$service.Status } else { 'NotFound' }

    if (-not (Get-Command -Name Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
        return New-OpenPathDnsProxyState -State 'unknown' -ServiceStatus $serviceStatus -AcrylicInstalled $true
    }

    $listener = $null
    try {
        $listener = @(Get-NetUDPEndpoint -LocalAddress '127.0.0.1' -LocalPort 53 -ErrorAction Stop | Select-Object -First 1)[0]
    }
    catch {
        Write-OpenPathLog "DNS proxy state check failed to inspect the UDP listener: $_" -Level WARN
        return New-OpenPathDnsProxyState -State 'unknown' -ServiceStatus $serviceStatus -AcrylicInstalled $true
    }

    if ($null -eq $listener) {
        return New-OpenPathDnsProxyState -State 'service-down' -ServiceStatus $serviceStatus -AcrylicInstalled $true
    }

    $listenerPid = [int]$listener.OwningProcess
    $listenerProcessName = ''
    try {
        $listenerProcess = Get-Process -Id $listenerPid -ErrorAction Stop
        if (-not $listenerProcess) {
            return New-OpenPathDnsProxyState -State 'unknown' -ServiceStatus $serviceStatus -ListenerPid $listenerPid -AcrylicInstalled $true
        }
        $listenerProcessName = ([string]$listenerProcess.ProcessName) -replace '\.exe$', ''
    }
    catch {
        Write-OpenPathLog "DNS proxy state check failed to inspect listener PID $listenerPid`: $_" -Level WARN
        return New-OpenPathDnsProxyState -State 'unknown' -ServiceStatus $serviceStatus -ListenerPid $listenerPid -AcrylicInstalled $true
    }

    if ($listenerProcessName -ne 'AcrylicService') {
        Write-OpenPathLog "DNS proxy port conflict: 127.0.0.1:53 UDP is owned by $listenerProcessName (PID $listenerPid), not AcrylicService" -Level WARN
        return New-OpenPathDnsProxyState `
            -State 'port-conflict' `
            -ServiceStatus $serviceStatus `
            -ListenerPid $listenerPid `
            -ListenerProcessName $listenerProcessName `
            -AcrylicInstalled $true
    }

    if ($serviceStatus -ne 'Running') {
        return New-OpenPathDnsProxyState `
            -State 'service-down' `
            -ServiceStatus $serviceStatus `
            -ListenerPid $listenerPid `
            -ListenerProcessName $listenerProcessName `
            -AcrylicInstalled $true
    }

    return New-OpenPathDnsProxyState `
        -State 'listening' `
        -ServiceStatus $serviceStatus `
        -ListenerPid $listenerPid `
        -ListenerProcessName $listenerProcessName `
        -AcrylicInstalled $true
}

function Read-OpenPathAcrylicRepairState {
    <#
    .SYNOPSIS
    Reads the Acrylic repair/cache-seed throttle state, returning safe defaults when absent or malformed.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    $state = [PSCustomObject]@{
        lastReinstallAttemptAt = ''
        lastReinstallResult = ''
        lastCacheSeedAttemptAt = ''
    }

    $path = Get-OpenPathAcrylicRepairStatePath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path $path)) {
        return $state
    }

    try {
        $stored = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($propertyName in @('lastReinstallAttemptAt', 'lastReinstallResult', 'lastCacheSeedAttemptAt')) {
            if ($stored.PSObject.Properties[$propertyName]) {
                $state.$propertyName = [string]$stored.$propertyName
            }
        }
    }
    catch {
        Write-OpenPathLog "Could not read Acrylic repair state: $_" -Level WARN
    }

    return $state
}

function Write-OpenPathAcrylicRepairState {
    <#
    .SYNOPSIS
    Persists the Acrylic repair/cache-seed throttle state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$OpenPathRoot = ''
    )

    $path = Get-OpenPathAcrylicRepairStatePath -OpenPathRoot $OpenPathRoot
    Write-OpenPathAtomicJsonFile -Path $path -Data $State -Depth 5
}

function Test-OpenPathAcrylicRepairWindowElapsed {
    <#
    .SYNOPSIS
    Returns true when the recorded timestamp is absent, malformed, or older than the window.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Timestamp,
        [Parameter(Mandatory = $true)][int]$Minutes
    )

    if ([string]::IsNullOrWhiteSpace([string]$Timestamp)) {
        return $true
    }

    $parsed = [DateTimeOffset]::MinValue
    try {
        if ([DateTimeOffset]::TryParse(
                [string]$Timestamp,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsed)) {
            return ((([DateTimeOffset]::UtcNow) - $parsed).TotalMinutes -ge $Minutes)
        }
    }
    catch {
        return $true
    }

    return $true
}

function Invoke-OpenPathAcrylicArtifactCacheSeed {
    <#
    .SYNOPSIS
    Downloads and verifies the pinned Acrylic ZIP during a healthy cycle, at most once per day.
    .DESCRIPTION
    The repair path must not depend on network access when DNS is already broken. This
    seed runs only while Acrylic is listening and local resolution is healthy, so a machine
    installed before the cache existed acquires the artifact before it is needed.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ProxyState,
        [AllowNull()][object]$LocalResolutionHealthy,
        [string]$OpenPathRoot = ''
    )

    if ($null -eq $ProxyState -or [string]$ProxyState.State -ne 'listening') {
        return $false
    }
    if ($null -eq $LocalResolutionHealthy -or -not [bool]$LocalResolutionHealthy) {
        return $false
    }

    $cachePath = Get-OpenPathAcrylicCachePath -OpenPathRoot $OpenPathRoot
    if (Test-Path $cachePath) {
        return $true
    }

    $state = Read-OpenPathAcrylicRepairState -OpenPathRoot $OpenPathRoot
    if (-not (Test-OpenPathAcrylicRepairWindowElapsed -Timestamp $state.lastCacheSeedAttemptAt -Minutes 1440)) {
        return $false
    }

    $state.lastCacheSeedAttemptAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-OpenPathAcrylicRepairState -State $state -OpenPathRoot $OpenPathRoot

    $spec = Get-OpenPathAcrylicArtifactSpec
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-acrylic-seed-" + [Guid]::NewGuid().ToString('N') + '.zip')
    try {
        foreach ($url in @($spec.PortableZipUrls)) {
            try {
                if (Test-Path $tempPath) {
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                }
                Invoke-AcrylicPortableDownload -Url $url -DestinationPath $tempPath
                Assert-AcrylicDownloadHash -Path $tempPath -ExpectedSha256 $spec.PortableZipSha256 -ArtifactName 'Acrylic-Portable.zip'
                if (-not (Test-AcrylicPortableArchive -Path $tempPath)) {
                    throw 'Downloaded Acrylic archive was not a valid portable release'
                }
                Save-OpenPathAcrylicArtifactToCache `
                    -SourcePath $tempPath `
                    -ExpectedSha256 $spec.PortableZipSha256 `
                    -OpenPathRoot $OpenPathRoot | Out-Null
                Write-OpenPathLog 'Seeded the verified Acrylic repair cache'
                return $true
            }
            catch {
                Write-OpenPathLog "Acrylic cache seed failed from ${url}: $_" -Level WARN
            }
        }
    }
    finally {
        if (Test-Path $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $false
}

function Invoke-OpenPathDnsProxyRepair {
    <#
    .SYNOPSIS
    Executes the bounded repair for a classified local DNS proxy failure.
    .DESCRIPTION
    dns_proxy_down restarts/re-registers the service. dns_proxy_missing reinstalls from the
    verified local cache only, with a 30-minute throttle, then restores the Acrylic host
    content and firewall. Port conflicts and upstream failures are reported by the caller
    and never repaired by killing another process or changing upstreams.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('dns_proxy_down', 'dns_proxy_missing', 'dns_port_conflict', 'dns_upstream_unreachable')]
        [string]$FailureClass,

        [AllowNull()]
        [object]$Config,

        [string]$OpenPathRoot = ''
    )

    $result = [PSCustomObject]@{
        Attempted = $false
        Repaired = $false
        ReasonCode = $null
        Detail = ''
    }

    switch ($FailureClass) {
        'dns_proxy_down' {
            $result.Attempted = $true
            $started = [bool](Ensure-AcrylicService -Start)
            $autoStart = [bool](Set-AcrylicServiceAutoStart)
            $result.Repaired = [bool]($started -and $autoStart)
            if (-not $started) {
                $result.Detail = 'Acrylic service did not start'
            }
            elseif (-not $autoStart) {
                $result.Detail = 'Acrylic service auto-start could not be set'
            }
            return $result
        }
        'dns_proxy_missing' {
            $cachePath = Get-OpenPathAcrylicCachePath -OpenPathRoot $OpenPathRoot
            if (-not (Test-Path $cachePath)) {
                $result.ReasonCode = 'dns_proxy_reinstall_unavailable'
                $result.Detail = 'No verified Acrylic cache is available'
                return $result
            }

            $state = Read-OpenPathAcrylicRepairState -OpenPathRoot $OpenPathRoot
            if (-not (Test-OpenPathAcrylicRepairWindowElapsed -Timestamp $state.lastReinstallAttemptAt -Minutes 30)) {
                $result.Detail = 'Reinstall throttle window has not elapsed'
                return $result
            }

            $state.lastReinstallAttemptAt = [DateTimeOffset]::UtcNow.ToString('o')
            $state.lastReinstallResult = 'attempted'
            Write-OpenPathAcrylicRepairState -State $state -OpenPathRoot $OpenPathRoot

            $result.Attempted = $true
            try {
                $spec = Get-OpenPathAcrylicArtifactSpec
                Assert-AcrylicDownloadHash -Path $cachePath -ExpectedSha256 $spec.PortableZipSha256 -ArtifactName 'Acrylic-Portable.zip'
                if (-not (Test-AcrylicPortableArchive -Path $cachePath)) {
                    throw 'Cached Acrylic archive is not a valid portable release'
                }

                $installed = Install-OpenPathAcrylicFromVerifiedArchive -AcrylicZipPath $cachePath
                if (-not $installed) {
                    throw 'Local Acrylic install did not complete'
                }

                $dataRoot = Get-OpenPathAcrylicDataRoot -OpenPathRoot $OpenPathRoot
                $whitelistPath = [System.IO.Path]::Combine($dataRoot, 'whitelist.txt')
                $sections = Get-OpenPathWhitelistSectionsFromFile -Path $whitelistPath
                Update-AcrylicHost `
                    -WhitelistedDomains @($sections.Whitelist) `
                    -BlockedSubdomains @($sections.BlockedSubdomains) | Out-Null
                Restart-AcrylicService | Out-Null

                $upstream = '8.8.8.8'
                if ($Config -and $Config.PSObject.Properties['primaryDNS'] -and $Config.primaryDNS) {
                    $upstream = [string]$Config.primaryDNS
                }
                if (Get-Command -Name Set-OpenPathFirewall -ErrorAction SilentlyContinue) {
                    $acrylicPath = Get-AcrylicPath
                    $firewallApplied = [bool](Set-OpenPathFirewall -UpstreamDNS $upstream -AcrylicPath $acrylicPath)
                    if (-not $firewallApplied) {
                        throw 'Firewall reapply failed after the Acrylic reinstall'
                    }
                }
                else {
                    Write-OpenPathLog 'Set-OpenPathFirewall is unavailable; the reinstall could not reapply the DNS firewall' -Level WARN
                }

                $result.Repaired = $true
                $result.ReasonCode = 'dns_proxy_reinstalled'
                $state.lastReinstallResult = 'success'
            }
            catch {
                $result.ReasonCode = 'dns_proxy_reinstall_unavailable'
                $result.Detail = [string]$_.Exception.Message
                $state.lastReinstallResult = 'failed'
                Write-OpenPathLog "Acrylic reinstall from the local cache failed: $_" -Level WARN
            }

            Write-OpenPathAcrylicRepairState -State $state -OpenPathRoot $OpenPathRoot
            return $result
        }
        default {
            return $result
        }
    }
}

function Get-OpenPathDnsFailureClass {
    <#
    .SYNOPSIS
    Maps a proxy-state fact and local resolution result to one DNS failure reason code.
    .DESCRIPTION
    Pure decision function. Returns $null when the proxy is healthy or the evidence is
    unknown. A listening proxy that cannot resolve a protected domain through itself is
    classified as dns_upstream_unreachable, not dns_proxy_down.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ProxyState,

        [AllowNull()]
        [object]$LocalResolutionHealthy = $null
    )

    if ($null -eq $ProxyState -or -not $ProxyState.PSObject.Properties['State']) {
        return $null
    }

    switch ([string]$ProxyState.State) {
        'missing' { return 'dns_proxy_missing' }
        'service-down' { return 'dns_proxy_down' }
        'port-conflict' { return 'dns_port_conflict' }
        'listening' {
            if ($null -ne $LocalResolutionHealthy -and -not [bool]$LocalResolutionHealthy) {
                return 'dns_upstream_unreachable'
            }
            return $null
        }
        default { return $null }
    }
}
