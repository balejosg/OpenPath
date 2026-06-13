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
