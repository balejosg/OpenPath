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
        W-1(b): returns the absolute program paths that MUST keep full outbound egress
        (any protocol, any remote, any port) regardless of the resolved whitelist-IP
        allow-list, so the DefaultOutboundAction-Block egress floor never bricks the
        device's update / time-sync / agent control plane.
    .DESCRIPTION
        Under the DefaultOutboundAction-Block model the profile default denies every
        outbound connection that no Allow rule matches. These programs reach update,
        time-sync, control-plane, and DNS-upstream endpoints on a range of ports (not
        only 443: Windows Update can use 80, w32tm uses NTP/123, Acrylic uses DNS/53),
        so they each get a program-scoped Allow with no protocol/port/remote
        restriction. A program-scoped Allow overrides the profile default block (the
        parent validated allow_overrides_default_block=true on the real runner); it
        only loses to a competing explicit Block rule, and this floor creates none.
        Several OS and OpenPath subsystems connect to endpoints that are NOT in the
        classroom whitelist and/or whose IPs we cannot resolve through Acrylic in
        advance:

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
          * Acrylic (AcrylicService.exe): its upstream is DNS/53; full egress also covers
            any future DoH-to-trusted-upstream or update path so it is never collateral.

        This is deliberately CONSERVATIVE: we over-allow a known, signed system binary by
        absolute path rather than risk bricking a managed device. Allowing a service host
        (svchost.exe) full egress is a known residual-surface trade-off and is documented
        as such; it is NOT a substitute for the name-based enforcement that still governs
        the managed browsers (those run under firefox.exe/chrome.exe, which are NOT on this
        list, so the profile default still denies their off-whitelist egress). Callers may
        extend this list via -ExtraPrograms (e.g. the config
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
        W-1(b): builds the ALLOW rule shapes for the DefaultOutboundAction-Block egress
        floor -- system-service full egress, whitelist-IP HTTP/HTTPS, loopback, and DHCP.
    .DESCRIPTION
        OpenPath enforcement is name-based (Acrylic + DNS firewall). With no transport
        floor, any process that can open a socket (powershell, ftp, an Appx with its own
        resolver, etc.) can connect to an arbitrary IP literal and spoof the Host header
        to bypass the whitelist. The Linux agent already has a name-aware egress floor;
        this is the Windows twin.

        DESIGN (validated on the real runner 2026-06-14): default-deny is expressed by
        Set-NetFirewallProfile -DefaultOutboundAction Block (set by the apply path
        Set-OpenPathEgressFloorRules), NOT by explicit Block rules. On Windows Filtering
        Platform an explicit Block rule WINS over a program-scoped Allow, so the previous
        "Block over non-allow ranges + program Allow" scaffold bricked svchost/w32tm/the
        agent. By contrast a program- or address-scoped Allow rule OVERRIDES the profile
        DEFAULT block (allow_overrides_default_block=true) -- it only loses to a competing
        explicit Block rule, and this floor emits NONE. So this helper returns ONLY Allow
        descriptors; the caller turns the default to Block and these Allows carve the
        permitted egress out of it.

        This helper is PURE: it returns rule descriptor objects (it does NOT call
        New-NetFirewallRule and does NOT call Set-NetFirewallProfile), so the rule SHAPE
        is unit-testable here without a live Windows firewall.

        Allow descriptors emitted:
          a. System-service programs (-SystemServicePrograms): full outbound egress (any
             protocol, any remote, any port) so OS update/time-sync/control-plane and the
             DNS-upstream (AcrylicService.exe) and NTP (w32tm.exe) paths survive on
             whatever ports they need -- not just 443.
          b. Whitelist-resolved IPs (-AllowIps): Allow outbound TCP to RemotePort 80,443
             (HTTP redirects + HTTPS) for each resolved /32.
          c. Loopback: Allow outbound to 127.0.0.1 and ::1 so the local Acrylic listener
             and other loopback IPC keep working.
          d. DHCP: Allow outbound UDP RemotePort 67,68 so the lease keeps renewing.

        ENABLING THIS BY DEFAULT REQUIRES WEDU-LAB VALIDATION: the allow-IP set must be
        kept in lock-step with the live Acrylic-resolved whitelist IPs, and the system
        service allow-list must be proven complete, or the device loses its ability to
        reach whitelisted sites and its own update/API/time-sync. Until that validation
        exists, callers gate this behind the default-$false OutboundEgressFloorEnabled flag.
    .PARAMETER AllowIps
        IPv4 literals (each a /32) that outbound HTTP/HTTPS is permitted to reach -- the
        Acrylic-resolved whitelist IP set. IPv6 and non-IPv4 entries are ignored.
    .PARAMETER SystemServicePrograms
        Absolute program paths (e.g. the OpenPath agent, Windows Update, w32tm, Acrylic)
        that must always be allowed full outbound egress regardless of the IP allow-list.
    .PARAMETER RulePrefix
        Display-name prefix for emitted rules; defaults to the module rule prefix.
    .OUTPUTS
        PSCustomObject[] -- Allow-only rule descriptors with fields:
        DisplayName, Direction, Protocol, RemoteAddress, RemotePort, Action, Profile,
        Program (system-service rules only), Description.
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

    # (a) Trusted system/agent programs: FULL outbound egress (any protocol / port /
    # remote) so update, API, time-sync, and DNS-upstream egress survive the default
    # block on whatever ports they use. These Allows override the profile DEFAULT block.
    foreach ($program in @($SystemServicePrograms | Where-Object { $_ })) {
        $programId = ([System.IO.Path]::GetFileNameWithoutExtension([string]$program)) -replace '[^0-9A-Za-z]', '-'
        $rules += [PSCustomObject]@{
            DisplayName   = "$RulePrefix-Allow-EgressFloor-System-$programId"
            Direction     = 'Outbound'
            Protocol      = 'Any'
            RemoteAddress = 'Any'
            RemotePort    = 'Any'
            Action        = 'Allow'
            Profile       = 'Any'
            Program       = [string]$program
            Description   = "Outbound egress floor: allow system/agent program $program full egress for update/API/time-sync/DNS"
        }
    }

    # (b) Allow HTTP/HTTPS to each resolved whitelist IP (the name-aware allow-list).
    $normalizedAllowIps = @(
        $AllowIps |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { (ConvertTo-OpenPathIPv4UInt32 -Address $_) -ne $null } |
            Sort-Object -Unique
    )
    foreach ($allowIp in $normalizedAllowIps) {
        $allowId = $allowIp -replace '[^0-9A-Za-z]', '-'
        $rules += [PSCustomObject]@{
            DisplayName   = "$RulePrefix-Allow-EgressFloor-Whitelist-$allowId-TCP"
            Direction     = 'Outbound'
            Protocol      = 'TCP'
            RemoteAddress = $allowIp
            RemotePort    = @('80', '443')
            Action        = 'Allow'
            Profile       = 'Any'
            Description   = "Outbound egress floor: allow HTTP/HTTPS to resolved whitelist IP $allowIp"
        }
    }

    # (c) Loopback: keep the local Acrylic listener and loopback IPC reachable.
    # Only IPv4 127.0.0.1 is expressed as a rule: New-NetFirewallRule REJECTS '::1' as
    # a RemoteAddress ("loopback IPv6 address" error -- confirmed on the real Windows
    # runner), and WFP exempts loopback (127.0.0.0/8 and ::1) from filtering anyway, so
    # an explicit IPv6 loopback rule is both invalid and unnecessary.
    $rules += [PSCustomObject]@{
        DisplayName   = "$RulePrefix-Allow-EgressFloor-Loopback4"
        Direction     = 'Outbound'
        Protocol      = 'Any'
        RemoteAddress = '127.0.0.1'
        RemotePort    = 'Any'
        Action        = 'Allow'
        Profile       = 'Any'
        Description   = 'Outbound egress floor: allow IPv4 loopback (local Acrylic and IPC)'
    }

    # (d) DHCP: keep the lease renewing (client 68 -> server 67) under the default block.
    $rules += [PSCustomObject]@{
        DisplayName   = "$RulePrefix-Allow-EgressFloor-DHCP"
        Direction     = 'Outbound'
        Protocol      = 'UDP'
        RemoteAddress = 'Any'
        RemotePort    = @('67', '68')
        Action        = 'Allow'
        Profile       = 'Any'
        Description   = 'Outbound egress floor: allow DHCP (UDP 67/68) so the lease keeps renewing'
    }

    return @($rules)
}

function Get-OpenPathEgressFloorProfileNames {
    <#
    .SYNOPSIS
        W-1(b): the firewall profiles the egress floor governs. Outbound only --
        inbound (management/RDP/guest-agent) is never touched.
    #>
    [CmdletBinding()]
    param()
    return @('Domain', 'Private', 'Public')
}

function Get-OpenPathEgressFloorPreviousOutboundStatePath {
    <#
    .SYNOPSIS
        W-1(b): path of the JSON state file that records each profile's
        DefaultOutboundAction BEFORE the floor flipped it to Block, so disable/remove
        can restore the machine to exactly its pre-floor outbound default.
    .DESCRIPTION
        Lives next to the other OpenPath data-dir state files (<root>\data). The root is
        resolved the same way the rest of this module resolves it.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$OpenPathRoot
    )

    $resolvedRoot = $OpenPathRoot
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
        if ($script:OpenPathRoot) {
            $resolvedRoot = [string]$script:OpenPathRoot
        }
        elseif (Get-Command -Name 'Resolve-OpenPathWindowsRoot' -ErrorAction SilentlyContinue) {
            $resolvedRoot = Resolve-OpenPathWindowsRoot
        }
        else {
            $resolvedRoot = 'C:\OpenPath'
        }
    }
    $resolvedRoot = ([string]$resolvedRoot).TrimEnd('\')
    return "$resolvedRoot\data\egress-floor-prev-outbound.json"
}

function ConvertTo-OpenPathEgressFloorCanonicalIp {
    <#
    .SYNOPSIS
        W-1(b): normalizes a firewall RemoteAddress / resolved IP literal to its bare
        canonical form so drift comparison does not churn on netmask notation.
    .DESCRIPTION
        Windows stores a /32 RemoteAddress in NETMASK form (x.x.x.x/255.255.255.255) and
        a /24 as x.x.x.x/255.255.255.0, NOT the bare literal we resolve. To compare the
        installed allow rules against a fresh resolution we strip a trailing host mask
        (/255.255.255.255 or /32) and return the bare dotted IPv4. Any other suffix
        (a real subnet such as /24 or /255.255.255.0) is preserved verbatim, and a
        non-IPv4 value is returned trimmed and unchanged. Returns $null for blank input.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }
    $candidate = ([string]$Address).Trim()

    # Strip only a host (/32) mask in either notation; leave real subnets intact.
    if ($candidate -match '^(.+?)/(?:255\.255\.255\.255|32)$') {
        $candidate = $Matches[1].Trim()
    }

    if ((ConvertTo-OpenPathIPv4UInt32 -Address $candidate) -ne $null) {
        return $candidate
    }
    return $candidate
}

function Save-OpenPathEgressFloorPreviousOutbound {
    <#
    .SYNOPSIS
        W-1(b): captures and PERSISTS each profile's current DefaultOutboundAction before
        the floor flips it to Block, so the original can be restored exactly on disable.
    .DESCRIPTION
        Reads Get-NetFirewallProfile for Domain/Private/Public and writes a JSON map of
        profile -> DefaultOutboundAction to the state file. Idempotent: if the state file
        already exists (a prior apply captured the genuine pre-floor default) it is NOT
        overwritten, so a re-apply or refresh that runs while the default is already Block
        cannot poison the saved baseline with "Block". Best-effort: a read/write failure
        is logged and swallowed (the apply still proceeds; restore then falls back to Allow).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-OpenPathEgressFloorPreviousOutboundStatePath
    }

    if (-not $PSCmdlet.ShouldProcess($StatePath, 'Persist pre-floor DefaultOutboundAction')) {
        return
    }

    try {
        if (Test-Path $StatePath) {
            # A genuine pre-floor baseline is already recorded; do not clobber it.
            return
        }
    }
    catch {
    }

    if (-not (Get-Command -Name 'Get-NetFirewallProfile' -ErrorAction SilentlyContinue)) {
        return
    }

    $previous = [ordered]@{}
    foreach ($profileName in @(Get-OpenPathEgressFloorProfileNames)) {
        $action = 'Allow'
        try {
            $profileObject = Get-NetFirewallProfile -Profile $profileName -ErrorAction Stop
            if ($null -ne $profileObject -and $profileObject.PSObject.Properties['DefaultOutboundAction'] -and $profileObject.DefaultOutboundAction) {
                $action = [string]$profileObject.DefaultOutboundAction
            }
        }
        catch {
            $action = 'Allow'
        }
        $previous[$profileName] = $action
    }

    try {
        $directory = Split-Path $StatePath -Parent
        if ($directory -match '^([A-Za-z]):[\\/]' -and -not (Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue)) {
            return
        }
        if ($directory -and -not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $json = ConvertTo-Json -InputObject $previous -Depth 3
        Set-Content -Path $StatePath -Value $json -Encoding UTF8 -Force
        Write-OpenPathLog "Egress floor: saved pre-floor DefaultOutboundAction state to $StatePath"
    }
    catch {
        Write-OpenPathLog "Egress floor: failed to persist pre-floor DefaultOutboundAction state: $_" -Level WARN
    }
}

function Restore-OpenPathEgressFloorPreviousOutbound {
    <#
    .SYNOPSIS
        W-1(b): restores each profile's DefaultOutboundAction from the persisted pre-floor
        state (fallback Allow when no state is recorded) and deletes the state file.
    .DESCRIPTION
        The mirror of Save-OpenPathEgressFloorPreviousOutbound. Used on disable/remove and
        on the fail-open path. NEVER restores to Block: if the recorded value is missing,
        unreadable, or anything other than a recognized non-Block action, the profile is
        restored to Allow so an empty allow-set can never leave egress bricked. After a
        successful restore the state file is removed so the next apply re-captures a fresh
        genuine baseline.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-OpenPathEgressFloorPreviousOutboundStatePath
    }

    if (-not $PSCmdlet.ShouldProcess($StatePath, 'Restore pre-floor DefaultOutboundAction')) {
        return
    }

    $previous = @{}
    try {
        if (Test-Path $StatePath) {
            # Read line-wise and re-join rather than -Raw: equivalent for a small JSON file
            # and avoids a Pester mock-binding quirk around the -Raw parameter set in tests.
            $stateText = (Get-Content $StatePath -ErrorAction Stop) -join "`n"
            $parsed = $stateText | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed) {
                foreach ($property in $parsed.PSObject.Properties) {
                    $previous[$property.Name] = [string]$property.Value
                }
            }
        }
    }
    catch {
        Write-OpenPathLog "Egress floor: pre-floor DefaultOutboundAction state unreadable; restoring profiles to Allow. $_" -Level WARN
        $previous = @{}
    }

    if (Get-Command -Name 'Set-NetFirewallProfile' -ErrorAction SilentlyContinue) {
        foreach ($profileName in @(Get-OpenPathEgressFloorProfileNames)) {
            $action = 'Allow'
            if ($previous.ContainsKey($profileName) -and $previous[$profileName]) {
                $candidate = [string]$previous[$profileName]
                # Brick-guard: never restore to Block. Only a recognized non-Block action
                # (Allow / NotConfigured) is honored; anything else falls back to Allow.
                if ($candidate -in @('Allow', 'NotConfigured')) {
                    $action = $candidate
                }
            }
            try {
                Set-NetFirewallProfile -Profile $profileName -DefaultOutboundAction $action -ErrorAction Stop
            }
            catch {
                Write-OpenPathLog "Egress floor: failed restoring DefaultOutboundAction=$action on profile ${profileName}: $_" -Level WARN
            }
        }
        Write-OpenPathLog 'Egress floor: restored DefaultOutboundAction from pre-floor state (fallback Allow)'
    }

    try {
        if (Test-Path $StatePath) {
            Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Remove-OpenPathEgressFloorRules {
    <#
    .SYNOPSIS
        W-1(b): the disable/teardown path for the egress floor -- restores each profile's
        DefaultOutboundAction from the persisted pre-floor state (fallback Allow) and
        removes the "$RulePrefix-*-EgressFloor-*" Allow rules.
    .DESCRIPTION
        Under the DefaultOutboundAction-Block model, removing the Allow rules WITHOUT
        first restoring the default would brick every outbound connection (the default is
        still Block, and nothing carves egress out of it). So the full teardown
        FIRST restores the default outbound action via
        Restore-OpenPathEgressFloorPreviousOutbound (which also deletes the state file),
        THEN removes the floor Allow rules. Every floor rule carries the
        "$RulePrefix-*-EgressFloor-*" display-name shape, so we target exactly those.

        -RestoreDefaultOutbound (default $true) restores the profile default. The
        idempotent rule-swap inside Set-OpenPathEgressFloorRules (which is about to set
        the default to Block and re-create the Allow rules) calls this with
        -RestoreDefaultOutbound:$false so it does NOT churn the profile default or delete
        the still-valid pre-floor baseline mid-apply.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$RulePrefix = $script:RulePrefix,
        [bool]$RestoreDefaultOutbound = $true
    )

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Remove OpenPath egress-floor rules')) {
        return
    }

    if ($RestoreDefaultOutbound) {
        Restore-OpenPathEgressFloorPreviousOutbound
    }

    if (-not (Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue)) {
        return
    }

    Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -DisplayName "$RulePrefix-*-EgressFloor-*" -ErrorAction SilentlyContinue)
}

function Set-OpenPathEgressFloorRules {
    <#
    .SYNOPSIS
        W-1(b): applies the DefaultOutboundAction-Block egress floor from a resolved
        allow-IP set and the system-service program list, with a strict FAIL-OPEN guard.
    .DESCRIPTION
        This is the single apply path shared by Set-OpenPathFirewall and the watchdog
        refresh (Update-OpenPathEgressFloor). It implements the working
        DefaultOutboundAction-Block model (validated on the real runner): the profile
        default denies all outbound, and Allow rules carve the permitted egress out of it
        (a program/address-scoped Allow OVERRIDES the default block; it only loses to a
        competing explicit Block rule, of which this floor emits none).

          1. FAIL-OPEN GUARD (the core anti-brick invariant): if the resolved allow-IP
             set is empty (Acrylic down / empty whitelist) it does NOT set
             DefaultOutboundAction Block. Instead it RESTORES the default to the persisted
             pre-floor value (fallback Allow) and removes all floor rules, leaving the
             device on its DNS-name-based behavior. Setting the default to Block with an
             EMPTY allow set would brick every outbound connection, including the agent's
             own control plane; we never do that.
          2. APPLY (allow set non-empty):
             a. Persist the current per-profile DefaultOutboundAction (so disable restores
                it exactly) via Save-OpenPathEgressFloorPreviousOutbound -- idempotent, it
                will not overwrite a genuine pre-floor baseline on re-apply.
             b. Swap the floor Allow rules (idempotent): remove the stale
                "$RulePrefix-*-EgressFloor-*" rules WITHOUT touching the profile default,
                then re-create the fresh Allow set from Get-OpenPathOutboundEgressFloorRules.
             c. Set-NetFirewallProfile -Profile Domain,Private,Public
                -DefaultOutboundAction Block. (Inbound default is intentionally left
                alone so management/RDP/guest-agent keep working.)

        This is the ONLY place that flips DefaultOutboundAction to Block, and it is
        unreachable when $normalizedAllowIps.Count -eq 0 (the guard returns first).
    .OUTPUTS
        int -- the number of floor Allow rules created (0 == fail-open / no-op).
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

    # FAIL-OPEN: zero resolvable IPv4 allow IPs means we must NOT set the default to
    # Block (that would brick all egress). Restore the persisted pre-floor default
    # (fallback Allow) and tear down any stale floor rules, then stop.
    if ($normalizedAllowIps.Count -eq 0) {
        Write-OpenPathLog 'Outbound egress floor: resolved allow-IP set is empty; NOT setting DefaultOutboundAction Block (fail-open). Restoring pre-floor outbound default and clearing stale floor rules' -Level WARN
        if ($PSCmdlet.ShouldProcess('Windows Firewall', 'Restore pre-floor outbound default and clear stale egress-floor rules (fail-open)')) {
            Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix -RestoreDefaultOutbound $true
        }
        return 0
    }

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Apply OpenPath DefaultOutboundAction-Block egress floor')) {
        return 0
    }

    # (a) Capture the genuine pre-floor DefaultOutboundAction once, before we flip it.
    Save-OpenPathEgressFloorPreviousOutbound

    # (b) Idempotent Allow-rule swap: clear the previous floor rules WITHOUT restoring the
    # default (we are about to set it to Block) and WITHOUT deleting the saved baseline.
    Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix -RestoreDefaultOutbound $false

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

    # (c) Flip the profile default to Block. This is the ONLY place we do so, and the
    # empty-allow-set guard above has already returned, so we never reach here with an
    # empty allow set.
    if (Get-Command -Name 'Set-NetFirewallProfile' -ErrorAction SilentlyContinue) {
        $egressFloorProfiles = @(Get-OpenPathEgressFloorProfileNames)
        try {
            Set-NetFirewallProfile -Profile $egressFloorProfiles -DefaultOutboundAction Block -ErrorAction Stop
            Write-OpenPathLog "Outbound egress floor: DefaultOutboundAction set to Block on $($egressFloorProfiles -join ',')" -Level WARN
        }
        catch {
            Write-OpenPathLog "Outbound egress floor: failed to set DefaultOutboundAction Block ($_); restoring pre-floor default and tearing down floor to avoid a partial/bricking state" -Level ERROR
            Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix -RestoreDefaultOutbound $true
            return 0
        }
    }

    Write-OpenPathLog "Outbound egress floor active ($($egressFloorRules.Count) allow rules; $($normalizedAllowIps.Count) allow IPs; default outbound = Block)" -Level WARN
    return $egressFloorRules.Count
}

function Update-OpenPathEgressFloor {
    <#
    .SYNOPSIS
        W-1(b): re-resolves the whitelist + always-allowed domains through Acrylic and
        re-applies the DefaultOutboundAction-Block egress floor. The refresh entrypoint
        for CDN IP rotation and whitelist changes; safe to call repeatedly (idempotent).
    .DESCRIPTION
        CDN IPs rotate, so a static allow-set goes stale and would start blocking
        legitimately-whitelisted sites. This re-runs the live resolver
        (Get-OpenPathEgressFloorAllowIps) and re-applies the floor via the shared
        fail-open apply path (Set-OpenPathEgressFloorRules), which updates only the
        whitelist-IP Allow rules while keeping DefaultOutboundAction Block and the
        system/loopback/DHCP Allow rules. Called by:
          * Set-OpenPathFirewall, when the floor is enabled and no static allow-IP set
            is configured.
          * The watchdog (per-minute) when Test-OpenPathEgressFloorDrift reports drift.
          * The whitelist-apply path on a whitelist change.

        Honors an explicit static allow-IP set when one is supplied (operator override);
        otherwise resolves live. Always fail-open on an empty resolution: if a refresh
        resolves to empty, the apply path restores the pre-floor default (does NOT keep
        Block) and removes the floor rather than bricking egress.
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

        NORMALIZATION: Windows stores a /32 RemoteAddress in NETMASK form
        (x.x.x.x/255.255.255.255), NOT the bare literal we resolve, so a naive string
        compare would report drift on EVERY cycle and churn the floor. Both the installed
        RemoteAddress values and the freshly-resolved IPs are normalized to the same bare
        canonical form via ConvertTo-OpenPathEgressFloorCanonicalIp (which strips a
        trailing /255.255.255.255 or /32 host mask) before the set diff.
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
    # Normalize the resolved set to the same bare canonical form as the installed rules
    # (strip any host mask) so the diff compares like-for-like and does not churn.
    $resolvedIps = @(
        $resolvedIps |
            ForEach-Object { ConvertTo-OpenPathEgressFloorCanonicalIp -Address $_ } |
            Where-Object { $_ -and (ConvertTo-OpenPathIPv4UInt32 -Address $_) -ne $null } |
            Sort-Object -Unique
    )

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
                # Windows reports a /32 as x.x.x.x/255.255.255.255; normalize to bare IPv4.
                $candidate = ConvertTo-OpenPathEgressFloorCanonicalIp -Address ([string]$remote)
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
        # W-1(b): transport-level outbound egress floor (DefaultOutboundAction-Block
        # model). DEFAULT OFF. Enabling by default requires the parent's real-runner
        # (WEDU-lab) validation of dynamic whitelist-IP sync and a proven-complete
        # system-service allow-list; see Get-OpenPathOutboundEgressFloorRules.
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

            # IPv6 DNS has no local Acrylic listener (IPv6 binding disabled), so block it
            # wholesale. New-NetFirewallRule REJECTS the '::/0' all-IPv6 prefix with "One
            # or more of the address prefixes is invalid" (prefix length 0 is not allowed
            # -- confirmed on the real Windows box), which previously aborted the entire
            # firewall configuration mid-apply. Express all-IPv6 as the two valid /1
            # halves (the standard /0 workaround). A wildcard "Any" would also match IPv4
            # and override the upstream-DNS carve-out above, so this must stay IPv6-scoped.
            foreach ($protocol in @('UDP', 'TCP')) {
                New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DefaultDeny-DNS6-$protocol-53" `
                    -Direction Outbound -Protocol $protocol -RemoteAddress @('::/1', '8000::/1') -RemotePort 53 `
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
            # DESIGN (DefaultOutboundAction-Block model, validated on the real runner
            # 2026-06-14): default-deny is expressed by
            # Set-NetFirewallProfile -Profile Domain,Private,Public
            # -DefaultOutboundAction Block, with program/address-scoped ALLOW rules that
            # carve the permitted egress back out. The parent validated on the self-hosted
            # runner that a program-scoped Allow OVERRIDES the profile DEFAULT block
            # (allow_overrides_default_block=true); an Allow only loses to a *competing
            # explicit Block rule*, and this floor creates NONE. This replaces the earlier
            # scaffold that expressed default-deny as explicit Block rules over the
            # non-allow IPv4 ranges -- that was VALIDATED NON-FUNCTIONAL because on Windows
            # Filtering Platform an explicit Block WINS over a program-scoped Allow, so the
            # system-service Allows were overridden and svchost/w32tm/the agent got blocked
            # (OS update / time-sync / control plane down == bricked device).
            #
            # Allows created (all override the default block): system-service programs get
            # FULL egress (any protocol/port/remote) for update/time-sync/control-plane/DNS;
            # each resolved whitelist IP gets TCP 80/443; IPv4 loopback (127.0.0.1) and DHCP
            # (UDP 67/68) are allowed (IPv6 ::1 is WFP-exempt and rejected as a rule, so it
            # is not created). Inbound is intentionally untouched (DefaultInboundAction is
            # NOT set), so management/RDP/guest-agent keep working.
            #
            # The end-to-end rule MODEL was validated on the real runner (VM103,
            # 2026-06-14): a non-system program reached a whitelisted IP, was blocked from a
            # non-whitelisted IP (P0 closed), and a system program still reached any IP
            # (no brick); runner restored clean. What ENABLING BY DEFAULT still requires is
            # fleet-level validation that the system-service allow-list is complete for real
            # managed devices (MDM/Defender/OEM agents) and that live whitelist-IP
            # resolution stays in lock-step with CDN rotation -- a canary rollout, not one
            # runner. The default stays $false until that is done.
            #
            # Allow-IP source: prefer an explicit operator/config static list when one is
            # supplied; otherwise resolve the live whitelist + always-allowed domains
            # through the local Acrylic proxy. The shared apply path
            # (Set-OpenPathEgressFloorRules) FAILS OPEN: if the resolved set is empty it
            # does NOT set DefaultOutboundAction Block -- it restores the persisted
            # pre-floor outbound default (fallback Allow) and removes the floor, leaving
            # DNS-name enforcement in place rather than bricking all egress.
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
