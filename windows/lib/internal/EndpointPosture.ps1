# Endpoint posture: reads what protection is live on this PC and reports
# contradictions with the classroom state. Leaf helper, dot-sourced by the
# watchdog script and the update runtime; it holds no module state.

function Test-OpenPathAdapterDnsPinnedToLocalResolver {
    # true when an active adapter still resolves through the local Acrylic proxy; the
    # firewall alone cannot prove a disabled classroom is open because a concurrent
    # protected-mode restore pins DNS before it rebuilds the rules
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name 'Get-DnsClientServerAddress' -ErrorAction SilentlyContinue)) {
        return $false
    }

    foreach ($adapter in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $address = Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
        $servers = @($address | ForEach-Object { @($_.ServerAddresses) } | Where-Object { $_ })
        if ($servers.Count -gt 0 -and [string]$servers[0] -eq '127.0.0.1') {
            return $true
        }
    }

    return $false
}

function Get-OpenPathOpenClassroomPostureFindings {
    <#
    .SYNOPSIS
        Names the contradictions between an open classroom and active protection.
    .DESCRIPTION
        Pure. A classroom whose whitelist is disabled is meant to be open, so
        firewall rules or a DNS pin to the local resolver still being in force
        means browsing fails with nothing showing why. Returns reason codes in a
        stable order, and an empty array when the classroom is enabled or captive
        portal mode is active (protection is expected to be partial then).
    .OUTPUTS
        string[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ClassroomDisabled,

        [Parameter(Mandatory = $true)]
        [bool]$PortalModeActive,

        [Parameter(Mandatory = $true)]
        [bool]$FirewallActive,

        [Parameter(Mandatory = $true)]
        [bool]$DnsPinned
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($ClassroomDisabled -and -not $PortalModeActive) {
        if ($FirewallActive) { [void]$findings.Add('open_classroom_firewall_active') }
        if ($DnsPinned) { [void]$findings.Add('open_classroom_dns_pinned') }
    }

    return $findings.ToArray()
}

function Get-OpenPathOpenClassroomPosture {
    <#
    .SYNOPSIS
        Reads live classroom and protection state and reports open-classroom findings.
    .DESCRIPTION
        Never throws. Classroom state that cannot be read counts as an enabled
        classroom (no findings); a failed firewall, DNS or portal probe counts as
        not active for that signal. Portal state is read without the expired-marker
        restore, so reading posture never changes the endpoint.
    .OUTPUTS
        PSCustomObject with ClassroomDisabled, PortalModeActive, FirewallActive,
        DnsPinned and Findings.
    #>
    [CmdletBinding()]
    param()

    $classroomDisabled = $false
    $portalModeActive = $false
    $firewallActive = $false
    $dnsPinned = $false

    try { $classroomDisabled = [bool](Test-OpenPathCaptivePortalClassroomDisabled) } catch { $classroomDisabled = $false }
    try { $portalModeActive = [bool](Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore) } catch { $portalModeActive = $false }
    try { $firewallActive = [bool](Test-FirewallActive) } catch { $firewallActive = $false }
    try { $dnsPinned = [bool](Test-OpenPathAdapterDnsPinnedToLocalResolver) } catch { $dnsPinned = $false }

    $findings = @(Get-OpenPathOpenClassroomPostureFindings `
            -ClassroomDisabled $classroomDisabled `
            -PortalModeActive $portalModeActive `
            -FirewallActive $firewallActive `
            -DnsPinned $dnsPinned)

    return [PSCustomObject]@{
        ClassroomDisabled = $classroomDisabled
        PortalModeActive  = $portalModeActive
        FirewallActive    = $firewallActive
        DnsPinned         = $dnsPinned
        Findings          = $findings
    }
}

function Merge-OpenPathReasonCodes {
    <#
    .SYNOPSIS
        Appends reason codes to an existing list, dropping blanks and duplicates.
    .OUTPUTS
        string[]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ReasonCodes = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$AdditionalReasonCodes = @()
    )

    $merged = [System.Collections.Generic.List[string]]::new()
    foreach ($code in @(@($ReasonCodes) + @($AdditionalReasonCodes))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$code) -and -not $merged.Contains([string]$code)) {
            [void]$merged.Add([string]$code)
        }
    }

    return $merged.ToArray()
}
