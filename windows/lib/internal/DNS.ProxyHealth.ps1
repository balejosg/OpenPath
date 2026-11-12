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
