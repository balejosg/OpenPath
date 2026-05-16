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
        $enableKnownDnsIpBlocking = $true
        $enableDohIpBlocking = $true
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
        }
        catch {
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
