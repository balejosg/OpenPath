function Test-OpenPathFirewallIpAddress {
    param(
        [AllowNull()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }

    $parsedAddress = $null
    return [System.Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsedAddress)
}

function ConvertTo-OpenPathIPv4UInt32 {
    # converts a dotted IPv4 string to its [int64] numeric value (0..4294967295);
    # returns $null for blank, non-IPv4, or unparseable input.
    param(
        [AllowNull()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsed)) { return $null }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }

    $bytes = $parsed.GetAddressBytes()
    return ([int64]$bytes[0] -shl 24) -bor ([int64]$bytes[1] -shl 16) -bor ([int64]$bytes[2] -shl 8) -bor [int64]$bytes[3]
}

function ConvertFrom-OpenPathIPv4UInt32 {
    # converts an [int64] numeric IPv4 value (0..4294967295) back to dotted notation.
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Value
    )

    $b0 = ($Value -shr 24) -band 0xFF
    $b1 = ($Value -shr 16) -band 0xFF
    $b2 = ($Value -shr 8) -band 0xFF
    $b3 = $Value -band 0xFF
    return "$b0.$b1.$b2.$b3"
}

function Get-OpenPathDnsEgressBlockRanges {
    <#
    .SYNOPSIS
        Returns the minimal set of IPv4 "start-end" ranges that cover the whole IPv4
        space EXCEPT loopback (127.0.0.0/8) and the supplied allow IPs.
    .DESCRIPTION
        Used to express a default-deny outbound DNS policy on a single port without
        also blocking the local Acrylic proxy or its configured upstreams. Windows
        Firewall evaluates Block over Allow, so a blanket "block all :53" would also
        kill Acrylic's upstream queries; instead we block everything except the
        loopback range and the explicit allow IPs (each a /32). IPv6 and non-IPv4
        entries in -AllowIps are ignored (IPv6 DNS is blocked wholesale elsewhere).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$AllowIps = @()
    )

    $min = [int64]0
    $max = [int64]4294967295

    $excluded = New-Object 'System.Collections.Generic.List[object]'
    # Loopback 127.0.0.0 - 127.255.255.255
    $excluded.Add([PSCustomObject]@{ Start = [int64]2130706432; End = [int64]2147483647 })

    foreach ($ip in @($AllowIps)) {
        $value = ConvertTo-OpenPathIPv4UInt32 -Address ([string]$ip)
        if ($null -ne $value) {
            $excluded.Add([PSCustomObject]@{ Start = [int64]$value; End = [int64]$value })
        }
    }

    $sorted = @($excluded | Sort-Object -Property Start)
    $merged = New-Object 'System.Collections.Generic.List[object]'
    foreach ($interval in $sorted) {
        if ($merged.Count -gt 0 -and $interval.Start -le ($merged[$merged.Count - 1].End + 1)) {
            if ($interval.End -gt $merged[$merged.Count - 1].End) {
                $merged[$merged.Count - 1].End = $interval.End
            }
        }
        else {
            $merged.Add([PSCustomObject]@{ Start = [int64]$interval.Start; End = [int64]$interval.End })
        }
    }

    $ranges = @()
    $cursor = $min
    foreach ($interval in $merged) {
        if ($interval.Start -gt $cursor) {
            $ranges += ('{0}-{1}' -f (ConvertFrom-OpenPathIPv4UInt32 -Value $cursor), (ConvertFrom-OpenPathIPv4UInt32 -Value ($interval.Start - 1)))
        }
        if (($interval.End + 1) -gt $cursor) {
            $cursor = $interval.End + 1
        }
    }
    if ($cursor -le $max) {
        $ranges += ('{0}-{1}' -f (ConvertFrom-OpenPathIPv4UInt32 -Value $cursor), (ConvertFrom-OpenPathIPv4UInt32 -Value $max))
    }

    return @($ranges)
}

function Get-OpenPathEgressFloorSystemServicePrograms {
    <#
    .SYNOPSIS
        W-1(b): returns the absolute program paths that MUST keep outbound HTTPS (443)
        regardless of the resolved whitelist-IP allow-list, so the transport egress
        floor never bricks the device's update / time-sync / agent control plane.
    .DESCRIPTION
        The egress floor's IPv4 default-deny block over 443 would otherwise sever any
        process whose destination IP is not in the (DNS-resolved) whitelist set. Several
        OS and OpenPath subsystems connect to endpoints that are NOT in the classroom
        whitelist and/or whose IPs we cannot resolve through Acrylic in advance:

          * Windows Update / delivery optimization (svchost-hosted wuauserv, BITS, DoSvc).
            These run inside generic svchost.exe instances, so the only stable program
            path is svchost.exe itself. We allow it conservatively -- a service-host
            allow is broad, but losing OS security updates on a locked-down fleet is the
            worse failure, and DNS-name enforcement still constrains *browser* egress.
          * Time sync (w32tm.exe + the svchost-hosted W32Time service). A device whose
            clock drifts fails TLS to its own control plane; never risk it.
          * The OpenPath agent itself: it runs as scheduled tasks under powershell.exe /
            pwsh.exe and must reach the API control plane, the whitelist URL, and the
            self-update artifact host -- whose CDN IPs rotate and may not be in the
            classroom whitelist file.
          * Acrylic (AcrylicService.exe): its upstream is DNS/53, but allow it on 443 as
            well so any future DoH-to-trusted-upstream or update path is not collateral.

        This is deliberately CONSERVATIVE: we over-allow a known, signed system binary by
        absolute path rather than risk bricking a managed device. Allowing a service host
        (svchost.exe) on 443 is a known residual-surface trade-off and is documented as
        such; it is NOT a substitute for the name-based enforcement that still governs the
        managed browsers. Callers may extend this list via -ExtraPrograms (e.g. the config
        outboundEgressFloorSystemPrograms key) when a site ships an additional agent.

        Paths that do not exist on disk are still emitted: Windows Firewall program-scoped
        Allow rules with a non-existent path are simply never matched, so an over-broad
        list cannot itself open a hole, while a path that appears after first apply (e.g.
        pwsh 7 installed later) is already covered.
    .PARAMETER OpenPathRoot
        OpenPath install root used to locate the agent's own scripts/CLI. Defaults to the
        module-resolved root.
    .PARAMETER AcrylicPath
        Directory containing AcrylicService.exe.
    .PARAMETER ExtraPrograms
        Additional absolute program paths to merge in (operator/config supplied).
    .OUTPUTS
        string[] -- de-duplicated absolute program paths.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$OpenPathRoot,
        [AllowNull()]
        [string]$AcrylicPath,
        [AllowNull()]
        [string[]]$ExtraPrograms = @()
    )

    $windowsRoot = if ($env:SystemRoot) { [string]$env:SystemRoot } elseif ($env:WINDIR) { [string]$env:WINDIR } else { 'C:\Windows' }
    $programFiles = if ($env:ProgramFiles) { [string]$env:ProgramFiles } else { 'C:\Program Files' }
    $programFilesX86 = if (${env:ProgramFiles(x86)}) { [string]${env:ProgramFiles(x86)} } else { 'C:\Program Files (x86)' }

    $resolvedRoot = $OpenPathRoot
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
        if (Get-Command -Name 'Resolve-OpenPathWindowsRoot' -ErrorAction SilentlyContinue) {
            $resolvedRoot = Resolve-OpenPathWindowsRoot
        }
        elseif ($script:OpenPathRoot) {
            $resolvedRoot = [string]$script:OpenPathRoot
        }
        else {
            $resolvedRoot = 'C:\OpenPath'
        }
    }
    $resolvedRoot = ([string]$resolvedRoot).TrimEnd('\')

    $programs = New-Object 'System.Collections.Generic.List[string]'

    # --- OS update / delivery / time sync (run inside generic svchost.exe) ---
    # svchost hosts wuauserv (Windows Update), BITS, DoSvc (delivery optimization),
    # and W32Time. There is no per-service exe, so svchost.exe is the stable handle.
    $programs.Add("$windowsRoot\System32\svchost.exe")
    $programs.Add("$windowsRoot\System32\w32tm.exe")
    # Update-orchestrator / TrustedInstaller side of servicing.
    $programs.Add("$windowsRoot\System32\UsoClient.exe")
    $programs.Add("$windowsRoot\System32\MoUsoCoreWorker.exe")
    $programs.Add("$windowsRoot\servicing\TrustedInstaller.exe")
    # BITS transfer host occasionally runs as a standalone helper.
    $programs.Add("$windowsRoot\System32\svchost.exe")

    # --- The OpenPath agent itself (its tasks run under Windows PowerShell / pwsh 7) ---
    $programs.Add("$windowsRoot\System32\WindowsPowerShell\v1.0\powershell.exe")
    $programs.Add("$windowsRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe")
    $programs.Add("$programFiles\PowerShell\7\pwsh.exe")
    $programs.Add("$programFilesX86\PowerShell\7\pwsh.exe")

    # --- Acrylic (DNS/53 normally, but never make it collateral on 443) ---
    if (-not [string]::IsNullOrWhiteSpace($AcrylicPath)) {
        $programs.Add(("$([string]$AcrylicPath)".TrimEnd('\') + '\AcrylicService.exe'))
    }
    else {
        $programs.Add("$programFilesX86\Acrylic DNS Proxy\AcrylicService.exe")
        $programs.Add("$programFiles\Acrylic DNS Proxy\AcrylicService.exe")
    }

    foreach ($extra in @($ExtraPrograms)) {
        $trimmed = ([string]$extra).Trim()
        if ($trimmed) { $programs.Add($trimmed) }
    }

    return @($programs | Where-Object { $_ } | Select-Object -Unique)
}

function Get-OpenPathEgressFloorAllowIps {
    <#
    .SYNOPSIS
        W-1(b): resolves the active whitelist domains (plus the always-allowed system
        domains) through the local Acrylic proxy (127.0.0.1) into the set of A/AAAA IP
        literals the outbound 443 floor must permit. PULL-based equivalent of the Linux
        dnsmasq->ipset feed (Acrylic has no ipset to read from).
    .DESCRIPTION
        Reads the persisted whitelist file, takes every valid whitelist domain AND the
        OpenPath always-allowed domains (control plane, MS/Firefox update, NTP, captive
        portal probes), and resolves each through the local Acrylic listener -- the same
        resolver path enforcement uses -- collecting their A (and AAAA) records. The
        result is what the floor's per-IP Allow rules are built from.

        CRITICAL FAIL-OPEN CONTRACT: this function only ADDS IPs. If resolution yields
        zero IPs (Acrylic down, all lookups timing out, empty whitelist), it returns an
        empty array and the caller MUST treat that as "do not build the floor" rather
        than "block everything". An empty allow-set with a default-deny block would brick
        all HTTPS; never let that happen. The apply path (Set-OpenPathFirewall /
        Update-OpenPathEgressFloor) enforces this guard.

        Both A and AAAA are collected, but note the floor only builds IPv4 per-IP Allow
        rules today (IPv6 443 is blocked wholesale by Get-OpenPathOutboundEgressFloorRules);
        AAAA results are returned for completeness/diagnostics and ignored by the IPv4
        range math. IPv6 whitelist reachability over the floor is a documented follow-up.
    .PARAMETER WhitelistPath
        Path to the persisted whitelist file. Defaults to <root>\data\whitelist.txt.
    .PARAMETER Server
        DNS server to resolve through. Defaults to the local Acrylic proxy 127.0.0.1.
    .PARAMETER IncludeAlwaysAllowed
        When set (default), also resolves the OpenPath always-allowed system domains so
        update/control-plane hosts whose names (not just programs) we trust stay reachable.
    .PARAMETER MaxAttempts
        Per-domain resolve attempts (passed through to Resolve-OpenPathDnsWithRetry).
    .OUTPUTS
        string[] -- de-duplicated, validated IP literals (may be empty == fail-open signal).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$WhitelistPath,
        [string]$Server = '127.0.0.1',
        [switch]$IncludeAlwaysAllowed = $true,
        [int]$MaxAttempts = 2
    )

    $resolvedRoot = if ($script:OpenPathRoot) { [string]$script:OpenPathRoot } elseif (Get-Command -Name 'Resolve-OpenPathWindowsRoot' -ErrorAction SilentlyContinue) { Resolve-OpenPathWindowsRoot } else { 'C:\OpenPath' }
    if ([string]::IsNullOrWhiteSpace($WhitelistPath)) {
        $WhitelistPath = Join-Path ($resolvedRoot.TrimEnd('\')) 'data\whitelist.txt'
    }

    $domains = New-Object 'System.Collections.Generic.List[string]'

    if (Get-Command -Name 'Get-ValidWhitelistDomainsFromFile' -ErrorAction SilentlyContinue) {
        try {
            foreach ($domain in @(Get-ValidWhitelistDomainsFromFile -Path $WhitelistPath)) {
                $trimmed = ([string]$domain).Trim()
                if ($trimmed) { $domains.Add($trimmed) }
            }
        }
        catch {
            Write-OpenPathLog "Egress floor: failed reading whitelist domains from '$WhitelistPath': $_" -Level WARN
        }
    }

    if ($IncludeAlwaysAllowed -and (Get-Command -Name 'Get-OpenPathAlwaysAllowedDomains' -ErrorAction SilentlyContinue)) {
        try {
            foreach ($domain in @(Get-OpenPathAlwaysAllowedDomains)) {
                $trimmed = ([string]$domain).Trim()
                if ($trimmed) { $domains.Add($trimmed) }
            }
        }
        catch {
            Write-OpenPathLog "Egress floor: failed reading always-allowed domains: $_" -Level WARN
        }
    }

    $uniqueDomains = @($domains | Where-Object { $_ } | Sort-Object -Unique)
    if ($uniqueDomains.Count -eq 0) {
        Write-OpenPathLog 'Egress floor: no whitelist/always-allowed domains to resolve; returning empty allow-IP set (fail-open)' -Level WARN
        return @()
    }

    $ipSet = New-Object 'System.Collections.Generic.List[string]'
    $resolvedCount = 0
    foreach ($domain in $uniqueDomains) {
        $records = $null
        try {
            if (Get-Command -Name 'Resolve-OpenPathDnsWithRetry' -ErrorAction SilentlyContinue) {
                $records = Resolve-OpenPathDnsWithRetry -Domain $domain -Server $Server -MaxAttempts $MaxAttempts -DelayMilliseconds 250 -AttemptTimeoutSeconds 3
            }
            elseif (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue) {
                $records = Resolve-DnsName -Name $domain -Server $Server -DnsOnly -ErrorAction Stop
            }
        }
        catch {
            $records = $null
        }

        if (-not $records) { continue }
        $resolvedCount++
        foreach ($record in @($records)) {
            $ip = $null
            if ($record.PSObject.Properties['IPAddress'] -and $record.IPAddress) {
                $ip = [string]$record.IPAddress
            }
            elseif ($record.PSObject.Properties['IP4Address'] -and $record.IP4Address) {
                $ip = [string]$record.IP4Address
            }
            if ($ip -and (Test-OpenPathFirewallIpAddress -Address $ip)) {
                $ipSet.Add($ip.Trim())
            }
        }
    }

    $uniqueIps = @($ipSet | Where-Object { $_ } | Sort-Object -Unique)
    Write-OpenPathLog "Egress floor: resolved $($uniqueDomains.Count) domain(s) -> $($uniqueIps.Count) allow IP(s) ($resolvedCount domain(s) answered)"
    return @($uniqueIps)
}

function Get-OpenPathOutboundEgressFloorRules {
    <#
    .SYNOPSIS
        W-1(b) SCAFFOLD (default-OFF): builds the rule shapes for a transport-level
        outbound egress floor that denies arbitrary outbound 443 traffic except to a
        supplied allow-list of resolved whitelist IPs and the system service set.
    .DESCRIPTION
        OpenPath enforcement is name-based (Acrylic + DNS firewall). With no transport
        floor, any process that can open a socket (powershell, ftp, an Appx with its own
        resolver, etc.) can connect to an arbitrary IP literal and spoof the Host header
        to bypass the whitelist. The Linux agent already has a name-aware egress floor;
        this is the Windows twin.

        This helper is PURE: it returns rule descriptor objects (it does NOT call
        New-NetFirewallRule), so the rule SHAPE is unit-testable here without a live
        Windows firewall or a working dynamic IP-sync feed.

        It deliberately does NOT set a machine-wide DefaultOutboundAction Block. Instead
        it expresses default-deny as explicit Block rules over the IPv4 ranges NOT in the
        allow-list (reusing Get-OpenPathDnsEgressBlockRanges range math) plus a wholesale
        IPv6 :443 block, scoped to remote port 443. System service programs in
        -SystemServicePrograms are emitted as higher-priority Allow rules so OS/agent
        update, API, and time-sync paths keep working.

        ENABLING THIS BY DEFAULT REQUIRES WEDU-LAB VALIDATION: the allow-IP set must be
        kept in lock-step with the live Acrylic-resolved whitelist IPs, and the system
        service allow-list must be proven complete, or the device loses its ability to
        reach whitelisted sites and its own update/API/time-sync. Until that validation
        exists, callers gate this behind the default-$false OutboundEgressFloorEnabled flag.
    .PARAMETER AllowIps
        IPv4 literals (each a /32) that outbound 443 is permitted to reach -- the
        Acrylic-resolved whitelist IP set. IPv6 and non-IPv4 entries are ignored.
    .PARAMETER SystemServicePrograms
        Absolute program paths (e.g. the OpenPath agent, Windows Update, w32tm) that
        must always be allowed outbound 443 regardless of the IP allow-list.
    .PARAMETER RulePrefix
        Display-name prefix for emitted rules; defaults to the module rule prefix.
    .OUTPUTS
        PSCustomObject[] -- rule descriptors with fields:
        DisplayName, Direction, Protocol, RemoteAddress, RemotePort, Action, Profile,
        Program (Allow rules only), Description.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$AllowIps = @(),
        [AllowNull()]
        [string[]]$SystemServicePrograms = @(),
        [string]$RulePrefix = $script:RulePrefix
    )

    $rules = @()

    # Higher-priority allow rules for trusted system/agent programs so update, API,
    # and time-sync egress is never collateral-damaged by the floor.
    foreach ($program in @($SystemServicePrograms | Where-Object { $_ })) {
        $programId = ([System.IO.Path]::GetFileNameWithoutExtension([string]$program)) -replace '[^0-9A-Za-z]', '-'
        $rules += [PSCustomObject]@{
            DisplayName   = "$RulePrefix-Allow-EgressFloor-System-$programId-TCP443"
            Direction     = 'Outbound'
            Protocol      = 'TCP'
            RemoteAddress = 'Any'
            RemotePort    = 443
            Action        = 'Allow'
            Profile       = 'Any'
            Program       = [string]$program
            Description   = "Outbound egress floor: allow system/agent program $program to reach HTTPS for update/API/time-sync"
        }
    }

    # Allow rules for each resolved whitelist IP (the name-aware allow-list).
    $normalizedAllowIps = @(
        $AllowIps |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { (ConvertTo-OpenPathIPv4UInt32 -Address $_) -ne $null } |
            Sort-Object -Unique
    )
    foreach ($allowIp in $normalizedAllowIps) {
        $allowId = $allowIp -replace '[^0-9A-Za-z]', '-'
        $rules += [PSCustomObject]@{
            DisplayName   = "$RulePrefix-Allow-EgressFloor-Whitelist-$allowId-TCP443"
            Direction     = 'Outbound'
            Protocol      = 'TCP'
            RemoteAddress = $allowIp
            RemotePort    = 443
            Action        = 'Allow'
            Profile       = 'Any'
            Description   = "Outbound egress floor: allow HTTPS to resolved whitelist IP $allowIp"
        }
    }

    # Default-deny everything else on 443 (IPv4), expressed as Block over the ranges
    # NOT in the allow-list. No machine-wide DefaultOutboundAction Block is set.
    $blockRanges = @(Get-OpenPathDnsEgressBlockRanges -AllowIps $normalizedAllowIps)
    if ($blockRanges.Count -gt 0) {
        $rules += [PSCustomObject]@{
            DisplayName   = "$RulePrefix-Block-EgressFloor-DefaultDeny-TCP443"
            Direction     = 'Outbound'
            Protocol      = 'TCP'
            RemoteAddress = $blockRanges
            RemotePort    = 443
            Action        = 'Block'
            Profile       = 'Any'
            Description   = 'Outbound egress floor: default-deny HTTPS except resolved whitelist IPs and system services'
        }
    }

    # IPv6 has no name-aware allow-list path here, so block 443 wholesale.
    $rules += [PSCustomObject]@{
        DisplayName   = "$RulePrefix-Block-EgressFloor-DefaultDeny6-TCP443"
        Direction     = 'Outbound'
        Protocol      = 'TCP'
        RemoteAddress = '::/0'
        RemotePort    = 443
        Action        = 'Block'
        Profile       = 'Any'
        Description   = 'Outbound egress floor: default-deny IPv6 HTTPS'
    }

    return @($rules)
}

function Remove-OpenPathEgressFloorRules {
    <#
    .SYNOPSIS
        W-1(b): removes only the egress-floor firewall rules (idempotent re-apply
        support) so a refresh replaces stale per-IP Allow rules without disturbing the
        rest of the OpenPath rule set.
    .DESCRIPTION
        Every floor rule carries the "$RulePrefix-*-EgressFloor-*" display-name shape, so
        we can target exactly those rules. Mirrors the broader Remove-OpenPathFirewall
        lifecycle but scoped to the floor, which lets the watchdog refresh the allow-IP
        set on its own cadence (CDN IP rotation) without a full firewall rebuild.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$RulePrefix = $script:RulePrefix
    )

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Remove OpenPath egress-floor rules')) {
        return
    }

    if (-not (Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue)) {
        return
    }

    Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -DisplayName "$RulePrefix-*-EgressFloor-*" -ErrorAction SilentlyContinue)
}

function Set-OpenPathEgressFloorRules {
    <#
    .SYNOPSIS
        W-1(b): builds and applies the outbound 443 egress-floor rules from a resolved
        allow-IP set and the system-service program list, with a strict FAIL-OPEN guard.
    .DESCRIPTION
        This is the single apply path shared by Set-OpenPathFirewall and the watchdog
        refresh (Update-OpenPathEgressFloor). It:

          1. FAIL-OPEN GUARD: if the resolved allow-IP set is empty, it does NOT create
             any block rule (and removes any stale floor rules), leaving the device on
             its current DNS-name-based behavior. An empty allow-set plus a default-deny
             443 block would brick all HTTPS, including the agent's own control plane;
             we never do that. This is the core anti-brick invariant.
          2. Removes stale floor rules first (idempotent re-apply).
          3. Emits the descriptor rules from Get-OpenPathOutboundEgressFloorRules and
             realizes each via New-OpenPathFirewallRule (same helper as DoH/DNS blocks).

        Never sets a machine-wide DefaultOutboundAction Block.
    .OUTPUTS
        int -- the number of floor rules created (0 == fail-open / no-op).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string[]]$AllowIps = @(),
        [AllowNull()]
        [string[]]$SystemServicePrograms = @(),
        [string]$RulePrefix = $script:RulePrefix
    )

    $normalizedAllowIps = @(
        $AllowIps |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { (ConvertTo-OpenPathIPv4UInt32 -Address $_) -ne $null } |
            Sort-Object -Unique
    )

    # FAIL-OPEN: zero resolvable IPv4 allow IPs means we cannot safely express a
    # default-deny without bricking. Tear down any stale floor and stop.
    if ($normalizedAllowIps.Count -eq 0) {
        Write-OpenPathLog 'Outbound egress floor: resolved allow-IP set is empty; skipping floor (fail-open to DNS-name enforcement) and clearing any stale floor rules' -Level WARN
        if ($PSCmdlet.ShouldProcess('Windows Firewall', 'Clear stale egress-floor rules (fail-open)')) {
            Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix
        }
        return 0
    }

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Apply OpenPath outbound egress-floor rules')) {
        return 0
    }

    # Idempotent re-apply: clear the previous floor before laying down the new set.
    Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix

    $egressFloorRules = @(Get-OpenPathOutboundEgressFloorRules `
            -AllowIps $normalizedAllowIps `
            -SystemServicePrograms $SystemServicePrograms `
            -RulePrefix $RulePrefix)

    foreach ($egressRule in $egressFloorRules) {
        $egressRuleParameters = @{
            DisplayName   = $egressRule.DisplayName
            Direction     = $egressRule.Direction
            Protocol      = $egressRule.Protocol
            RemoteAddress = $egressRule.RemoteAddress
            RemotePort    = $egressRule.RemotePort
            Action        = $egressRule.Action
            Profile       = $egressRule.Profile
            Description   = $egressRule.Description
        }
        if ($egressRule.PSObject.Properties['Program'] -and $egressRule.Program) {
            $egressRuleParameters['Program'] = $egressRule.Program
        }
        New-OpenPathFirewallRule @egressRuleParameters | Out-Null
    }

    Write-OpenPathLog "Outbound egress floor active ($($egressFloorRules.Count) rules; $($normalizedAllowIps.Count) allow IPs)" -Level WARN
    return $egressFloorRules.Count
}

function Update-OpenPathEgressFloor {
    <#
    .SYNOPSIS
        W-1(b): re-resolves the whitelist + always-allowed domains through Acrylic and
        re-applies the outbound 443 egress floor. The refresh entrypoint for CDN IP
        rotation and whitelist changes; safe to call repeatedly (idempotent).
    .DESCRIPTION
        CDN IPs rotate, so a static allow-set goes stale and would start blocking
        legitimately-whitelisted sites. This re-runs the live resolver
        (Get-OpenPathEgressFloorAllowIps) and re-applies the floor via the shared
        fail-open apply path (Set-OpenPathEgressFloorRules). Called by:
          * Set-OpenPathFirewall, when the floor is enabled and no static allow-IP set
            is configured.
          * The watchdog (per-minute) when Test-OpenPathEgressFloorDrift reports drift.
          * The whitelist-apply path on a whitelist change.

        Honors an explicit static allow-IP set when one is supplied (operator override);
        otherwise resolves live. Always fail-open on an empty resolution.
    .PARAMETER StaticAllowIps
        Operator/config supplied allow IPs that bypass live resolution when non-empty.
    .PARAMETER SystemServicePrograms
        Extra operator/config supplied system-service program paths (merged with the
        built-in conservative list).
    .PARAMETER AcrylicPath
        Acrylic install directory, used to locate AcrylicService.exe for the allow-list.
    .PARAMETER WhitelistPath
        Override path to the persisted whitelist file (defaults to <root>\data\whitelist.txt).
    .OUTPUTS
        int -- number of floor rules applied (0 == fail-open / no-op).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string[]]$StaticAllowIps = @(),
        [AllowNull()]
        [string[]]$SystemServicePrograms = @(),
        [AllowNull()]
        [string]$AcrylicPath,
        [AllowNull()]
        [string]$WhitelistPath
    )

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Refresh OpenPath outbound egress floor')) {
        return 0
    }

    $allowIps = @($StaticAllowIps | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($allowIps.Count -eq 0) {
        $allowIps = @(Get-OpenPathEgressFloorAllowIps -WhitelistPath $WhitelistPath)
    }

    $programs = @(Get-OpenPathEgressFloorSystemServicePrograms -AcrylicPath $AcrylicPath -ExtraPrograms $SystemServicePrograms)

    return (Set-OpenPathEgressFloorRules -AllowIps $allowIps -SystemServicePrograms $programs)
}

function Test-OpenPathEgressFloorDrift {
    <#
    .SYNOPSIS
        W-1(b): reports whether the currently-installed egress-floor per-IP Allow rules
        differ from the freshly-resolved whitelist IP set (CDN rotation detector for the
        watchdog).
    .DESCRIPTION
        Compares the set of IPs in the installed "$RulePrefix-Allow-EgressFloor-Whitelist-*"
        rules against a fresh resolution. Returns Drifted=$true when they differ, so the
        watchdog can call Update-OpenPathEgressFloor only when needed (avoiding a firewall
        rewrite every minute). FAIL-CLOSED on the *detector*, fail-open on the *apply*:
        if fresh resolution is empty we report no drift (the apply path would no-op
        anyway), so we never trigger a churn that tears down a working floor.
    .OUTPUTS
        PSCustomObject -- Drifted (bool), CurrentIps (string[]), ResolvedIps (string[]), Reason (string).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$StaticAllowIps = @(),
        [AllowNull()]
        [string]$WhitelistPath,
        [string]$RulePrefix = $script:RulePrefix
    )

    $resolvedIps = @($StaticAllowIps | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($resolvedIps.Count -eq 0) {
        $resolvedIps = @(Get-OpenPathEgressFloorAllowIps -WhitelistPath $WhitelistPath)
    }
    $resolvedIps = @($resolvedIps | Where-Object { (ConvertTo-OpenPathIPv4UInt32 -Address $_) -ne $null } | Sort-Object -Unique)

    if ($resolvedIps.Count -eq 0) {
        # Fresh resolution is empty -> the apply path would fail-open / no-op. Never
        # report drift here, or the watchdog would tear down a still-valid floor.
        return [PSCustomObject]@{ Drifted = $false; CurrentIps = @(); ResolvedIps = @(); Reason = 'empty-resolution-fail-open' }
    }

    $currentIps = @()
    try {
        $installed = @(Get-NetFirewallRule -DisplayName "$RulePrefix-Allow-EgressFloor-Whitelist-*" -ErrorAction SilentlyContinue)
        foreach ($rule in $installed) {
            $addressFilter = $null
            if (Get-Command -Name 'Get-NetFirewallAddressFilter' -ErrorAction SilentlyContinue) {
                $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            }
            foreach ($remote in @($addressFilter.RemoteAddress)) {
                $candidate = ([string]$remote).Trim()
                if ($candidate -and (ConvertTo-OpenPathIPv4UInt32 -Address $candidate) -ne $null) {
                    $currentIps += $candidate
                }
            }
        }
    }
    catch {
        $currentIps = @()
    }
    $currentIps = @($currentIps | Sort-Object -Unique)

    $drifted = @(Compare-Object -ReferenceObject $currentIps -DifferenceObject $resolvedIps).Count -gt 0
    $reason = if ($drifted) { "allow-IP set changed (installed=$($currentIps.Count), resolved=$($resolvedIps.Count))" } else { 'in-sync' }

    return [PSCustomObject]@{
        Drifted     = $drifted
        CurrentIps  = $currentIps
        ResolvedIps = $resolvedIps
        Reason      = $reason
    }
}

function Add-OpenPathCaptivePortalUpstreamFirewallAllow {
    <#
    .SYNOPSIS
        Allows Acrylic to reach the captive-portal upstream DNS (the network's DHCP
        resolver) through the anti-bypass firewall.
    .DESCRIPTION
        OpenPath's outbound DNS firewall only permits Acrylic to talk to the
        configured primary/secondary upstream. When a captive portal requires
        forwarding the admin-declared portal domains to the network's own resolver,
        Acrylic's queries to that resolver are otherwise dropped, so the portal never
        resolves. This adds an additive allow rule (port 53, scoped to Acrylic) for
        the portal upstream. Rules use the OpenPath-DNS prefix, so the firewall
        rebuild on protected-mode restore removes them automatically -- the allow is
        only in effect during the captive-portal window. The adapter stays on
        127.0.0.1 and the Acrylic NX * default-block is untouched (no fail-open).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [string]$AcrylicPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
    )

    if (-not (Test-OpenPathFirewallIpAddress -Address $Address)) {
        Write-OpenPathLog "Captive portal upstream firewall allow skipped: invalid address '$Address'" -Level WARN
        return $false
    }
    if (-not (Test-AdminPrivileges)) {
        Write-OpenPathLog 'Administrator privileges required for captive portal upstream firewall allow' -Level WARN
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', "Allow Acrylic to reach captive portal upstream $Address")) {
        return $false
    }

    $acrylicExe = "$AcrylicPath\AcrylicService.exe"
    foreach ($protocol in @('UDP', 'TCP')) {
        $name = "$script:RulePrefix-Allow-PortalUpstream-$protocol"
        Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)

        $ruleParameters = @{
            DisplayName   = $name
            Direction     = 'Outbound'
            Protocol      = $protocol
            RemoteAddress = $Address
            RemotePort    = 53
            Action        = 'Allow'
            Profile       = 'Any'
            Description   = "Allow Acrylic to reach captive portal upstream $Address over $protocol"
        }
        if (Test-Path $acrylicExe) { $ruleParameters['Program'] = $acrylicExe }
        New-OpenPathFirewallRule @ruleParameters | Out-Null
    }
    Write-OpenPathLog "Captive portal upstream firewall allow set for $Address"
    return $true
}

function Set-OpenPathFirewall {
    <#
    .SYNOPSIS
        Configures Windows Firewall to block external DNS and VPNs
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$UpstreamDNS = '8.8.8.8',
        [string]$AcrylicPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
    )

    if (-not (Test-AdminPrivileges)) {
        Write-OpenPathLog 'Administrator privileges required for firewall configuration' -Level ERROR
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Configure OpenPath firewall rules')) {
        return $false
    }

    Write-OpenPathLog 'Configuring Windows Firewall...'
    Remove-OpenPathFirewall

    try {
        $secondaryDns = '8.8.4.4'
        $declaredPortalDomains = @()
        $enableKnownDnsIpBlocking = $true
        $enableDohIpBlocking = $true
        $dnsEgressDefaultDeny = $true
        $blockInboundDns = $true
        # W-1(b): transport-level outbound 443 egress floor. DEFAULT OFF. Enabling
        # by default requires WEDU-lab validation of dynamic whitelist-IP sync and a
        # proven-complete system-service allow-list; see Get-OpenPathOutboundEgressFloorRules.
        $outboundEgressFloorEnabled = $false
        $outboundEgressFloorAllowIps = @()
        $outboundEgressFloorSystemPrograms = @()
        $dohResolvers = Get-DefaultDohResolverIps
        $resolverBypassClients = Get-DefaultResolverBypassClientPrograms
        $vpnPorts = Get-DefaultVpnBlockRules
        $torPorts = Get-DefaultTorBlockPorts

        try {
            $config = Get-OpenPathConfig
            if ($config.PSObject.Properties['enableKnownDnsIpBlocking']) {
                $enableKnownDnsIpBlocking = [bool]$config.enableKnownDnsIpBlocking
            }
            if ($config.PSObject.Properties['enableDohIpBlocking']) {
                $enableDohIpBlocking = [bool]$config.enableDohIpBlocking
            }
            if ($config.PSObject.Properties['dnsEgressDefaultDeny']) {
                $dnsEgressDefaultDeny = [bool]$config.dnsEgressDefaultDeny
            }
            if ($config.PSObject.Properties['blockInboundDns']) {
                $blockInboundDns = [bool]$config.blockInboundDns
            }
            if ($config.PSObject.Properties['outboundEgressFloorEnabled']) {
                $outboundEgressFloorEnabled = [bool]$config.outboundEgressFloorEnabled
            }
            if ($config.PSObject.Properties['outboundEgressFloorAllowIps'] -and $config.outboundEgressFloorAllowIps) {
                $outboundEgressFloorAllowIps = @($config.outboundEgressFloorAllowIps | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
            }
            if ($config.PSObject.Properties['outboundEgressFloorSystemPrograms'] -and $config.outboundEgressFloorSystemPrograms) {
                $outboundEgressFloorSystemPrograms = @($config.outboundEgressFloorSystemPrograms | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
            }
            if ($config.PSObject.Properties['dohResolverIps'] -and $config.dohResolverIps) {
                $configuredResolvers = @($config.dohResolverIps | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
                if ($configuredResolvers.Count -gt 0) {
                    $dohResolvers = $configuredResolvers
                }
            }
            if ($config.PSObject.Properties['vpnBlockRules'] -and $config.vpnBlockRules) {
                $configuredVpnRules = @()
                foreach ($rule in @($config.vpnBlockRules)) {
                    try {
                        $protocol = ''
                        $port = 0
                        $name = ''

                        if ($rule -is [string]) {
                            $parts = @($rule -split ':', 3)
                            if ($parts.Count -lt 2) { continue }
                            $protocol = [string]$parts[0]
                            $port = [int]$parts[1]
                            if ($parts.Count -ge 3) { $name = [string]$parts[2] }
                        }
                        else {
                            $protocol = if ($rule.PSObject.Properties['Protocol']) { [string]$rule.Protocol } else { '' }
                            $port = if ($rule.PSObject.Properties['Port']) { [int]$rule.Port } else { 0 }
                            $name = if ($rule.PSObject.Properties['Name']) { [string]$rule.Name } else { '' }
                        }

                        $protocolUpper = $protocol.Trim().ToUpperInvariant()
                        if ($protocolUpper -notin @('TCP', 'UDP')) { continue }
                        if ($port -lt 1 -or $port -gt 65535) { continue }
                        if (-not $name) { $name = "VPN-$protocolUpper-$port" }

                        $configuredVpnRules += [PSCustomObject]@{
                            Protocol = $protocolUpper
                            Port     = $port
                            Name     = $name
                        }
                    }
                    catch {
                        continue
                    }
                }

                if ($configuredVpnRules.Count -gt 0) {
                    $vpnPorts = $configuredVpnRules
                }
            }

            if ($config.PSObject.Properties['torBlockPorts'] -and $config.torBlockPorts) {
                $configuredTorPorts = @()
                foreach ($torPort in @($config.torBlockPorts)) {
                    try {
                        $candidatePort = [int]$torPort
                        if ($candidatePort -ge 1 -and $candidatePort -le 65535) {
                            $configuredTorPorts += $candidatePort
                        }
                    }
                    catch {
                        continue
                    }
                }

                if ($configuredTorPorts.Count -gt 0) {
                    $torPorts = @($configuredTorPorts | Sort-Object -Unique)
                }
            }

            if ($config.PSObject.Properties['captivePortalDomains'] -and $config.captivePortalDomains) {
                $declaredPortalDomains = @($config.captivePortalDomains | Where-Object { $_ })
            }
        }
        catch {
        }

        # Permanent split DNS: Acrylic must be able to reach the network's DHCP
        # resolvers for the declared captive-portal domains in normal protected
        # mode, not only during the legacy limited-mode window.
        $portalUpstreams = @()
        if ($declaredPortalDomains.Count -gt 0 -and (Get-Command -Name 'Get-OpenPathSplitDnsPortalUpstreams' -ErrorAction SilentlyContinue)) {
            try {
                $portalUpstreams = @(Get-OpenPathSplitDnsPortalUpstreams -ExcludeAddresses @($UpstreamDNS, $secondaryDns))
            }
            catch {
                $portalUpstreams = @()
            }
        }

        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Allow-Loopback-UDP" `
            -Direction Outbound -Protocol UDP -RemoteAddress 127.0.0.1 -RemotePort 53 `
            -Action Allow -Profile Any -Description 'Allow DNS to local Acrylic DNS Proxy' | Out-Null

        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Allow-Loopback-TCP" `
            -Direction Outbound -Protocol TCP -RemoteAddress 127.0.0.1 -RemotePort 53 `
            -Action Allow -Profile Any -Description 'Allow DNS to local Acrylic DNS Proxy (TCP)' | Out-Null

        $acrylicExe = "$AcrylicPath\AcrylicService.exe"
        if (Test-Path $acrylicExe) {
            $allowTargets = @(
                [PSCustomObject]@{ Name = 'Upstream'; Address = $UpstreamDNS },
                [PSCustomObject]@{ Name = 'Secondary'; Address = $secondaryDns }
            )
            $portalUpstreamIndex = 0
            foreach ($portalUpstream in @($portalUpstreams)) {
                $portalUpstreamIndex++
                $allowTargets += [PSCustomObject]@{ Name = "PortalUpstream$portalUpstreamIndex"; Address = [string]$portalUpstream }
            }

            foreach ($target in $allowTargets) {
                if (-not (Test-OpenPathFirewallIpAddress -Address $target.Address)) { continue }

                foreach ($protocol in @('UDP', 'TCP')) {
                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Allow-$($target.Name)-$protocol" `
                        -Direction Outbound -Protocol $protocol -RemoteAddress $target.Address -RemotePort 53 `
                        -Action Allow -Program $acrylicExe -Profile Any `
                        -Description "Allow Acrylic to reach $($target.Name.ToLowerInvariant()) DNS over $protocol" | Out-Null
                }
            }
        }

        if ($enableKnownDnsIpBlocking) {
            $dns53RuleCount = 0
            foreach ($resolverIp in ($dohResolvers | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ } | Sort-Object -Unique)) {
                if (-not (Test-OpenPathFirewallIpAddress -Address $resolverIp)) {
                    Write-OpenPathLog "Skipping invalid DNS resolver IP: $resolverIp" -Level WARN
                    continue
                }

                $resolverId = $resolverIp -replace '[^0-9A-Za-z]', '-'
                if ($resolverIp -in @($UpstreamDNS, $secondaryDns)) {
                    foreach ($clientProgram in @($resolverBypassClients)) {
                        foreach ($protocol in @('TCP', 'UDP')) {
                            $clientId = ([System.IO.Path]::GetFileNameWithoutExtension($clientProgram)) -replace '[^0-9A-Za-z]', '-'
                            New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Known-DNS-$resolverId-$clientId-$protocol-53" `
                                -Direction Outbound -Protocol $protocol -RemoteAddress $resolverIp -RemotePort 53 `
                                -Action Block -Program $clientProgram -Profile Any `
                                -Description "Block direct DNS bypass from $clientProgram to resolver $resolverIp over $protocol/53" | Out-Null
                            $dns53RuleCount++
                        }
                    }
                }
                else {
                    foreach ($protocol in @('TCP', 'UDP')) {
                        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Known-DNS-$resolverId-$protocol-53" `
                            -Direction Outbound -Protocol $protocol -RemoteAddress $resolverIp -RemotePort 53 `
                            -Action Block -Profile Any `
                            -Description "Block direct DNS bypass to resolver $resolverIp over $protocol/53" | Out-Null
                        $dns53RuleCount++
                    }
                }
            }

            Write-OpenPathLog "Added $dns53RuleCount direct DNS bypass block rules"
        }
        else {
            Write-OpenPathLog 'Known DNS IP blocking disabled by configuration' -Level WARN
        }

        if ($dnsEgressDefaultDeny) {
            $egressAllowIps = @('127.0.0.1', $UpstreamDNS, $secondaryDns)
            foreach ($portalUpstream in @($portalUpstreams)) { $egressAllowIps += [string]$portalUpstream }
            $egressAllowIps = @($egressAllowIps | Where-Object { Test-OpenPathFirewallIpAddress -Address $_ } | Sort-Object -Unique)
            $egressBlockRanges = @(Get-OpenPathDnsEgressBlockRanges -AllowIps $egressAllowIps)

            if ($egressBlockRanges.Count -gt 0) {
                foreach ($protocol in @('UDP', 'TCP')) {
                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DefaultDeny-DNS-$protocol-53" `
                        -Direction Outbound -Protocol $protocol -RemoteAddress $egressBlockRanges -RemotePort 53 `
                        -Action Block -Profile Any `
                        -Description "Default-deny outbound DNS over $protocol/53 except local Acrylic and configured upstreams" | Out-Null
                }
            }

            # IPv6 DNS has no local Acrylic listener (IPv6 binding disabled), so block it wholesale.
            foreach ($protocol in @('UDP', 'TCP')) {
                New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DefaultDeny-DNS6-$protocol-53" `
                    -Direction Outbound -Protocol $protocol -RemoteAddress '::/0' -RemotePort 53 `
                    -Action Block -Profile Any `
                    -Description "Default-deny outbound IPv6 DNS over $protocol/53" | Out-Null
            }

            Write-OpenPathLog "Default-deny DNS egress active ($($egressBlockRanges.Count) IPv4 block ranges)"
        }
        else {
            Write-OpenPathLog 'Default-deny DNS egress disabled by configuration' -Level WARN
        }

        if ($blockInboundDns) {
            foreach ($protocol in @('UDP', 'TCP')) {
                New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Inbound-DNS-$protocol-53" `
                    -Direction Inbound -Protocol $protocol -LocalPort 53 -Action Block -Profile Any `
                    -Description "Block inbound DNS over $protocol/53 so the host never answers LAN or guest-VM queries" | Out-Null
            }
        }

        if ($outboundEgressFloorEnabled) {
            # W-1(b): transport floor. DEFAULT OFF (outboundEgressFloorEnabled = $false
            # above). This branch is only reached when an operator has explicitly opted in.
            #
            # !!! VALIDATED NON-FUNCTIONAL ON A REAL WINDOWS RUNNER (2026-06-14) -- DO NOT
            # ENABLE AS-IS. This approach builds explicit Block rules over the non-allow
            # IPv4 ranges plus program-scoped Allow rules for the system services. A live
            # test on the self-hosted runner (VM103) proved that on Windows Filtering
            # Platform an explicit Block rule WINS over a program-scoped Allow (block
            # precedence is the documented WFP order). So the system-service Allow rules do
            # NOT override the range Block: svchost/w32tm/the agent would be blocked from
            # reaching any non-whitelisted 443 IP, killing OS update, time-sync, and the
            # control plane -- i.e. enabling this would brick the device. A working default
            # -deny on Windows needs Set-NetFirewallProfile -DefaultOutboundAction Block
            # (per profile) plus Allow exceptions (which override the DEFAULT block rather
            # than competing explicit Block rules), with a proven-complete allow set --
            # exactly the machine-wide default-block the original scaffold avoided. Until
            # the floor is reworked that way and re-validated, the IP-literal P0 mitigation
            # is the AppLocker tool-blocks + Appx denies (active by default), not this floor.
            # The drift detector also over-triggers: Windows stores a /32 RemoteAddress in
            # netmask form (x.x.x.x/255.255.255.255), not the bare literal it compares.
            #
            # (Original notes:) Enabling REQUIRES real-Windows validation of (a) live
            # whitelist-IP resolution staying in lock-step with the CDN-rotated allow set,
            # and (b) the system-service allow-list being proven complete.
            #
            # Allow-IP source: prefer an explicit operator/config static list when one is
            # supplied; otherwise resolve the live whitelist + always-allowed domains
            # through the local Acrylic proxy. The shared apply path
            # (Set-OpenPathEgressFloorRules) FAILS OPEN: if the resolved set is empty it
            # builds NO default-deny block and leaves DNS-name enforcement in place,
            # rather than bricking all HTTPS.
            $egressFloorRuleCount = Update-OpenPathEgressFloor `
                -StaticAllowIps $outboundEgressFloorAllowIps `
                -SystemServicePrograms $outboundEgressFloorSystemPrograms `
                -AcrylicPath $AcrylicPath
            Write-OpenPathLog "Outbound egress floor configured ($egressFloorRuleCount rules applied; 0 == fail-open)" -Level WARN
        }
        else {
            Write-OpenPathLog 'Outbound egress floor disabled by configuration (default; requires WEDU-lab validation to enable)'
        }

        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoT" `
            -Direction Outbound -Protocol TCP -RemotePort 853 -Action Block -Profile Any `
            -Description 'Block DNS-over-TLS to prevent bypass' | Out-Null

        if ($enableDohIpBlocking) {
            $dohRuleCount = 0
            foreach ($resolverIp in ($dohResolvers | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ } | Sort-Object -Unique)) {
                if (-not (Test-OpenPathFirewallIpAddress -Address $resolverIp)) {
                    Write-OpenPathLog "Skipping invalid DoH resolver IP: $resolverIp" -Level WARN
                    continue
                }

                $resolverId = $resolverIp -replace '[^0-9A-Za-z]', '-'

                if ($resolverIp -in @($UpstreamDNS, $secondaryDns)) {
                    foreach ($clientProgram in @($resolverBypassClients)) {
                        $clientId = ([System.IO.Path]::GetFileNameWithoutExtension($clientProgram)) -replace '[^0-9A-Za-z]', '-'
                        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoH-$resolverId-$clientId-TCP443" `
                            -Direction Outbound -Protocol TCP -RemoteAddress $resolverIp -RemotePort 443 `
                            -Action Block -Program $clientProgram -Profile Any -Description "Block DoH resolver $resolverIp from $clientProgram over TCP/443" | Out-Null

                        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoH-$resolverId-$clientId-UDP443" `
                            -Direction Outbound -Protocol UDP -RemoteAddress $resolverIp -RemotePort 443 `
                            -Action Block -Program $clientProgram -Profile Any -Description "Block DoH resolver $resolverIp from $clientProgram over UDP/443" | Out-Null

                        $dohRuleCount += 2
                    }
                }
                else {
                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoH-$resolverId-TCP443" `
                        -Direction Outbound -Protocol TCP -RemoteAddress $resolverIp -RemotePort 443 `
                        -Action Block -Profile Any -Description "Block DoH resolver $resolverIp over TCP/443" | Out-Null

                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoH-$resolverId-UDP443" `
                        -Direction Outbound -Protocol UDP -RemoteAddress $resolverIp -RemotePort 443 `
                        -Action Block -Profile Any -Description "Block DoH resolver $resolverIp over UDP/443" | Out-Null

                    $dohRuleCount += 2
                }
            }

            Write-OpenPathLog "Added $dohRuleCount DoH egress block rules"
        }
        else {
            Write-OpenPathLog 'DoH IP blocking disabled by configuration' -Level WARN
        }

        foreach ($vpn in @($vpnPorts)) {
            $vpnProtocol = ([string]$vpn.Protocol).Trim().ToUpperInvariant()
            $vpnPort = [int]$vpn.Port
            $vpnName = [string]$vpn.Name

            if ($vpnProtocol -notin @('TCP', 'UDP')) {
                Write-OpenPathLog "Skipping invalid VPN protocol in rule: $vpnProtocol" -Level WARN
                continue
            }
            if ($vpnPort -lt 1 -or $vpnPort -gt 65535) {
                Write-OpenPathLog "Skipping invalid VPN port in rule: $vpnPort" -Level WARN
                continue
            }
            if (-not $vpnName) { $vpnName = "VPN-$vpnProtocol-$vpnPort" }

            New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-VPN-$vpnName" `
                -Direction Outbound -Protocol $vpnProtocol -RemotePort $vpnPort -Action Block `
                -Profile Any -Description "Block $vpnName VPN traffic" | Out-Null
        }

        foreach ($port in @($torPorts)) {
            New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Tor-$port" `
                -Direction Outbound -Protocol TCP -RemotePort $port -Action Block -Profile Any `
                -Description "Block Tor traffic on port $port" | Out-Null
        }

        Write-OpenPathLog 'Windows Firewall configured successfully'
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to configure firewall: $_" -Level ERROR
        return $false
    }
}
