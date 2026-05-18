# OpenPath Captive Portal Module for Windows
# Detects captive portals and manages temporary fail-open mode.

# Import common functions
$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
$script:CaptivePortalStatePath = "$script:OpenPathRoot\data\captive-portal-active.json"
$script:CaptivePortalObservationPath = "$script:OpenPathRoot\data\captive-portal-observation.json"

function Test-OpenPathCaptivePortalModeActive {
    return (Test-Path $script:CaptivePortalStatePath)
}

function Get-OpenPathCaptivePortalMarker {
    if (-not (Test-Path $script:CaptivePortalStatePath)) {
        return $null
    }

    try {
        $raw = Get-Content $script:CaptivePortalStatePath -Raw -ErrorAction Stop
        if (-not $raw) {
            return $null
        }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Set-OpenPathCaptivePortalMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    try {
        $dir = Split-Path $script:CaptivePortalStatePath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $existing = Get-OpenPathCaptivePortalMarker
        $since = (Get-Date).ToString('o')
        if ($existing -and $existing.PSObject.Properties['since'] -and $existing.since) {
            $since = [string]$existing.since
        }

        $payload = @{
            active = $true
            state = [string]$State
            since = [string]$since
            updatedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 8

        $payload | Set-Content -Path $script:CaptivePortalStatePath -Encoding UTF8 -Force
        return $true
    }
    catch {
        return $false
    }
}

function Clear-OpenPathCaptivePortalMarker {
    try {
        Remove-Item -Path $script:CaptivePortalStatePath -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Get-OpenPathCaptivePortalObservation {
    if (-not (Test-Path $script:CaptivePortalObservationPath)) {
        return $null
    }

    try {
        $raw = Get-Content $script:CaptivePortalObservationPath -Raw -ErrorAction Stop
        if (-not $raw) {
            return $null
        }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Update-OpenPathCaptivePortalObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Authenticated', 'Portal', 'NoNetwork')]
        [string]$DetectedState,

        [int]$EnterPortalCount = 2,

        [int]$ExitAuthenticatedCount = 3
    )

    $now = Get-Date
    $existing = Get-OpenPathCaptivePortalObservation
    $portalCount = 0
    $authenticatedCount = 0
    $portalSince = $null

    if ($existing) {
        if ($existing.PSObject.Properties['portalCount']) { $portalCount = [int]$existing.portalCount }
        if ($existing.PSObject.Properties['authenticatedCount']) { $authenticatedCount = [int]$existing.authenticatedCount }
        if ($existing.PSObject.Properties['portalSince'] -and $existing.portalSince) {
            try { $portalSince = [datetime]::Parse([string]$existing.portalSince) } catch { $portalSince = $null }
        }
    }

    if (-not (Test-OpenPathCaptivePortalModeActive)) {
        $portalSince = $null
    }
    elseif (-not $portalSince) {
        $marker = Get-OpenPathCaptivePortalMarker
        if ($marker -and $marker.PSObject.Properties['since'] -and $marker.since) {
            try { $portalSince = [datetime]::Parse([string]$marker.since) } catch { $portalSince = $now }
        }
        else {
            $portalSince = $now
        }
    }

    if ($DetectedState -eq 'Portal') {
        $portalCount += 1
        $authenticatedCount = 0
    }
    elseif ($DetectedState -eq 'Authenticated') {
        $authenticatedCount += 1
        $portalCount = 0
    }

    $portalAgeSeconds = $null
    $minimumPortalElapsed = $true
    if ($portalSince) {
        $portalAgeSeconds = [Math]::Max(0, [int][Math]::Floor(($now - $portalSince).TotalSeconds))
    }

    $shouldEnterPortal = ($DetectedState -eq 'Portal' -and $portalCount -ge $EnterPortalCount -and -not (Test-OpenPathCaptivePortalModeActive))
    $shouldExitPortal = ($DetectedState -eq 'Authenticated' -and $authenticatedCount -ge $ExitAuthenticatedCount -and (Test-OpenPathCaptivePortalModeActive))

    try {
        $dir = Split-Path $script:CaptivePortalObservationPath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        [PSCustomObject]@{
            detectedState = $DetectedState
            portalCount = $portalCount
            authenticatedCount = $authenticatedCount
            portalSince = if ($portalSince) { $portalSince.ToString('o') } else { $null }
            portalAgeSeconds = $portalAgeSeconds
            minimumPortalElapsed = [bool]$minimumPortalElapsed
            shouldEnterPortal = [bool]$shouldEnterPortal
            shouldExitPortal = [bool]$shouldExitPortal
            updatedAt = $now.ToString('o')
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $script:CaptivePortalObservationPath -Encoding UTF8 -Force
    }
    catch {
        # Observation persistence is best-effort; callers still get the in-memory decision.
    }

    return [PSCustomObject]@{
        ShouldEnterPortal = [bool]$shouldEnterPortal
        ShouldExitPortal = [bool]$shouldExitPortal
        DetectedState = $DetectedState
        PortalCount = $portalCount
        AuthenticatedCount = $authenticatedCount
        PortalSince = if ($portalSince) { $portalSince.ToString('o') } else { $null }
        PortalAgeSeconds = $portalAgeSeconds
        MinimumPortalElapsed = [bool]$minimumPortalElapsed
    }
}

function Test-OpenPathPotentialCaptiveNetwork {
    <#
    .SYNOPSIS
        Detects local IPv4 network evidence before captive portal probes succeed.
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param()

    try {
        $activeAdapters = @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' }
        )
    }
    catch {
        $activeAdapters = @()
    }

    if ($activeAdapters.Count -le 0) {
        return $false
    }

    $activeInterfaceIndexes = @(
        $activeAdapters |
            ForEach-Object {
                if ($_.PSObject.Properties['ifIndex']) {
                    [int]$_.ifIndex
                }
                elseif ($_.PSObject.Properties['InterfaceIndex']) {
                    [int]$_.InterfaceIndex
                }
            } |
            Where-Object { $null -ne $_ }
    )

    if ($activeInterfaceIndexes.Count -le 0) {
        return $false
    }

    try {
        $defaultRoutes = @(
            Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object {
                    $activeInterfaceIndexes -contains [int]$_.InterfaceIndex -and
                    $_.NextHop -and
                    [string]$_.NextHop -ne '0.0.0.0' -and
                    -not ([string]$_.NextHop).StartsWith('127.')
                }
        )
        if ($defaultRoutes.Count -gt 0) {
            return $true
        }
    }
    catch {
        # Fall through to gateway evidence.
    }

    try {
        $ipConfigurations = @(
            Get-NetIPConfiguration -ErrorAction SilentlyContinue |
                Where-Object {
                    $activeInterfaceIndexes -contains [int]$_.InterfaceIndex -and
                    $_.IPv4DefaultGateway -and
                    $_.IPv4DefaultGateway.NextHop -and
                    [string]$_.IPv4DefaultGateway.NextHop -ne '0.0.0.0' -and
                    -not ([string]$_.IPv4DefaultGateway.NextHop).StartsWith('127.')
                }
        )
        return ($ipConfigurations.Count -gt 0)
    }
    catch {
        return $false
    }
}

function Test-OpenPathCaptivePortalState {
    <#
    .SYNOPSIS
        Detects captive portal state using multiple endpoints.
    .OUTPUTS
        String: Authenticated | Portal | NoNetwork
    #>
    [CmdletBinding()]
    param(
        [int]$TimeoutSec = 3
    )

    $checks = @(
        @{ Url = 'http://www.msftconnecttest.com/connecttest.txt'; ExpectedStatus = 200; ExpectedBody = 'Microsoft Connect Test' },
        @{ Url = 'http://detectportal.firefox.com/success.txt'; ExpectedStatus = 200; ExpectedBody = 'success' },
        @{ Url = 'http://clients3.google.com/generate_204'; ExpectedStatus = 204; ExpectedBody = '' }
    )

    $total = 0
    $success = 0
    $transportFail = 0

    foreach ($check in $checks) {
        $total += 1

        $statusCode = $null
        $content = ''

        try {
            $resp = Invoke-WebRequest -Uri $check.Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
            $statusCode = [int]$resp.StatusCode
            if ($resp.PSObject.Properties['Content'] -and $resp.Content) {
                $content = [string]$resp.Content
            }
        }
        catch {
            $ex = $_.Exception

            # Attempt to extract HTTP status code from the exception if present
            try {
                if ($ex -and $ex.Response -and $ex.Response.StatusCode) {
                    $statusCode = [int]$ex.Response.StatusCode
                }
            }
            catch {
                # Ignore
            }

            try {
                if (-not $statusCode -and $ex -and $ex.PSObject.Properties['StatusCode']) {
                    $statusCode = [int]$ex.StatusCode
                }
            }
            catch {
                # Ignore
            }

            if (-not $statusCode) {
                $transportFail += 1
            }
            continue
        }

        $content = $content.Trim()
        if ($statusCode -eq [int]$check.ExpectedStatus) {
            if ([string]$check.ExpectedBody -eq '' -or $content -eq [string]$check.ExpectedBody) {
                $success += 1
            }
        }
    }

    if ($total -le 0) {
        return 'NoNetwork'
    }
    if ($transportFail -ge $total) {
        if (Test-OpenPathPotentialCaptiveNetwork) {
            return 'Portal'
        }
        return 'NoNetwork'
    }

    $threshold = [Math]::Floor($total / 2) + 1
    if ($success -ge $threshold) {
        return 'Authenticated'
    }
    return 'Portal'
}

function Enable-OpenPathCaptivePortalMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$State = 'Portal'
    )

    if (-not $PSCmdlet.ShouldProcess('OpenPath', 'Enable captive portal mode')) {
        return $false
    }

    if (Test-OpenPathCaptivePortalModeActive) {
        Set-OpenPathCaptivePortalMarker -State $State | Out-Null
        return $true
    }

    Write-OpenPathLog 'Watchdog: Captive portal detected - entering portal mode (temporarily opening DNS + firewall)' -Level WARN

    Disable-OpenPathFirewall | Out-Null
    if (Get-Command -Name Restore-OpenPathCaptivePortalDNS -ErrorAction SilentlyContinue) {
        Restore-OpenPathCaptivePortalDNS | Out-Null
    }
    else {
        Restore-OriginalDNS
    }
    Set-OpenPathCaptivePortalMarker -State $State | Out-Null
    return $true
}

function Disable-OpenPathCaptivePortalMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$Config = $null
    )

    if (-not $PSCmdlet.ShouldProcess('OpenPath', 'Disable captive portal mode')) {
        return $false
    }

    if (-not (Test-OpenPathCaptivePortalModeActive)) {
        return $true
    }

    Write-OpenPathLog 'Watchdog: Captive portal resolved - restoring DNS protection' -Level WARN

    if (-not $Config) {
        try {
            $Config = Get-OpenPathConfig
        }
        catch {
            $Config = $null
        }
    }

    try {
        $restored = Restore-OpenPathProtectedMode -Config $Config
        if (-not $restored) {
            Write-OpenPathLog 'Watchdog: protected mode restore failed; keeping captive portal marker active' -Level WARN
            return $false
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: protected mode restore failed; keeping captive portal marker active: $_" -Level WARN
        return $false
    }

    $enforcementHealthy = $true
    $firewallExpected = $true
    if ($Config -and $Config.PSObject.Properties['enableFirewall']) {
        $firewallExpected = [bool]$Config.enableFirewall
    }

    try {
        if ((Get-Command -Name 'Test-DNSResolution' -ErrorAction SilentlyContinue) -and -not (Test-DNSResolution)) {
            $enforcementHealthy = $false
        }
        if ((Get-Command -Name 'Test-DNSSinkhole' -ErrorAction SilentlyContinue) -and -not (Test-DNSSinkhole -Domain 'this-should-be-blocked-test-12345.com')) {
            $enforcementHealthy = $false
        }
        if ($firewallExpected -and (Get-Command -Name 'Test-FirewallActive' -ErrorAction SilentlyContinue) -and -not (Test-FirewallActive)) {
            $enforcementHealthy = $false
        }
    }
    catch {
        Write-OpenPathLog "Watchdog: protected mode verification failed; keeping captive portal marker active: $_" -Level WARN
        return $false
    }

    if (-not $enforcementHealthy) {
        Write-OpenPathLog 'Watchdog: protected mode verification failed; keeping captive portal marker active' -Level WARN
        return $false
    }

    Clear-OpenPathCaptivePortalMarker | Out-Null
    return $true
}

Export-ModuleMember -Function @(
    'Test-OpenPathCaptivePortalModeActive',
    'Get-OpenPathCaptivePortalMarker',
    'Set-OpenPathCaptivePortalMarker',
    'Clear-OpenPathCaptivePortalMarker',
    'Get-OpenPathCaptivePortalObservation',
    'Update-OpenPathCaptivePortalObservation',
    'Test-OpenPathPotentialCaptiveNetwork',
    'Test-OpenPathCaptivePortalState',
    'Enable-OpenPathCaptivePortalMode',
    'Disable-OpenPathCaptivePortalMode'
)
