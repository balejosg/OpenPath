Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Firewall Module" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\Firewall.psm1" -Force -ErrorAction SilentlyContinue
    }

    Context "Test-FirewallActive" {
        It "Returns a boolean value" -Skip:(-not (Test-FunctionExists 'Test-FirewallActive')) {
            $result = Test-FirewallActive
            $result | Should -BeOfType [bool]
        }
    }

    Context "Get-FirewallStatus" {
        It "Returns a hashtable with expected keys" -Skip:(-not (Test-FunctionExists 'Get-FirewallStatus')) {
            $status = Get-FirewallStatus
            $status | Should -Not -BeNullOrEmpty
            $status.TotalRules | Should -Not -BeNullOrEmpty
            $status.AllowRules | Should -Not -BeNullOrEmpty
            $status.BlockRules | Should -Not -BeNullOrEmpty
        }
    }

    Context "Firewall cleanup manifest" {
        It "Creates OpenPath grouped rules and removes by manifest, group, and DNS prefix" {
            $policyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Policy.ps1"
            $statePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.State.ps1"
            $policyContent = Get-Content $policyPath -Raw
            $stateContent = Get-Content $statePath -Raw

            Assert-ContentContainsAll -Content $policyContent -Needles @(
                'New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Allow-Loopback-UDP"',
                'New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoT"'
            )
            Assert-ContentContainsAll -Content $stateContent -Needles @(
                "return 'C:\OpenPath\data\firewall-rules.json'",
                "Group = 'OpenPath'",
                'Add-OpenPathFirewallManifestRule -Name $DisplayName',
                "Get-NetFirewallRule -Group 'OpenPath'",
                'Get-NetFirewallRule -DisplayName "$script:RulePrefix-*"'
            )
        }
    }

    Context "DoH egress blocking" {
        It "Matches shared DoH resolver contract fixture" {
            $expectedResolvers = @(Get-ContractFixtureLines -FileName 'doh-resolvers.txt' | Sort-Object -Unique)
            $actualResolvers = @((Get-DefaultDohResolverIps) | Sort-Object -Unique)

            $diff = Compare-Object -ReferenceObject $expectedResolvers -DifferenceObject $actualResolvers
            $diff | Should -BeNullOrEmpty
        }

        It "Exposes a default DoH resolver catalog" {
            $resolvers = Get-DefaultDohResolverIps

            $resolvers | Should -Not -BeNullOrEmpty
            @($resolvers).Count | Should -BeGreaterThan 0
            @($resolvers) | Should -Contain '8.8.8.8'
            @($resolvers) | Should -Contain '1.1.1.1'
            @($resolvers) | Should -Contain '2001:4860:4860::8888'
            @($resolvers) | Should -Contain '2606:4700:4700::1111'
            @($resolvers) | Should -Contain '2620:fe::fe'

            foreach ($resolver in @($resolvers)) {
                { [void][System.Net.IPAddress]::Parse($resolver) } | Should -Not -Throw
            }
        }

        BeforeEach {
            Initialize-FirewallRuleCaptureMocks
        }

        It "Creates TCP and UDP 443 DoH block rules from configured resolver list" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableDohIpBlocking = $true
                    dohResolverIps = @('4.4.4.4', '5.5.5.5')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '4.4.4.4' -and $_.RemotePort -eq '443' -and $_.Protocol -eq 'TCP'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '4.4.4.4' -and $_.RemotePort -eq '443' -and $_.Protocol -eq 'UDP'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '5.5.5.5' -and $_.RemotePort -eq '443' -and $_.Protocol -eq 'TCP'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '5.5.5.5' -and $_.RemotePort -eq '443' -and $_.Protocol -eq 'UDP'
                }).Count | Should -Be 1
        }

        It "Creates equivalent DNS and DoH blocks for configured IPv6 resolver addresses" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dohResolverIps = @('2001:4860:4860::8888', '2606:4700:4700::1111')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            foreach ($resolverIp in @('2001:4860:4860::8888', '2606:4700:4700::1111')) {
                foreach ($protocol in @('TCP', 'UDP')) {
                    (@(Get-CapturedFirewallRules) | Where-Object {
                            $_.RemoteAddress -eq $resolverIp -and $_.RemotePort -eq '443' -and $_.Protocol -eq $protocol
                        }).Count | Should -Be 1

                    (@(Get-CapturedFirewallRules) | Where-Object {
                            $_.RemoteAddress -eq $resolverIp -and $_.RemotePort -eq '53' -and $_.Protocol -eq $protocol
                        }).Count | Should -Be 1
                }
            }
        }

        It "Creates program-scoped resolver blocks for upstream DNS and skips invalid DoH resolver entries" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dohResolverIps = @('8.8.8.8', 'invalid-ip', '6.6.6.6')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '443' -and $_.Program
                }).Count | Should -BeGreaterThan 0
            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '53' -and $_.Program
                }).Count | Should -BeGreaterThan 0
            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '443' -and -not $_.Program
                }).Count | Should -Be 0
            (@(Get-CapturedFirewallRules) | Where-Object { $_.RemoteAddress -eq 'invalid-ip' -and $_.RemotePort -eq '443' }).Count | Should -Be 0

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '6.6.6.6' -and $_.RemotePort -eq '443' -and $_.Protocol -eq 'TCP'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '6.6.6.6' -and $_.RemotePort -eq '443' -and $_.Protocol -eq 'UDP'
                }).Count | Should -Be 1
        }

        It "Blocks the proven Cloudflare DoH bypass class while leaving Acrylic upstream DNS allowed" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dohResolverIps = @('1.1.1.1', '1.0.0.1', '8.8.8.8')
                }
            } -ModuleName Firewall

            Set-FirewallAcrylicServicePresent -Present $true
            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            # Regression probe references only:
            # curl.exe --doh-url https://1.1.1.1/dns-query https://blocked.example.com
            # curl.exe --resolve "cloudflare-dns.com:443:1.1.1.1" https://cloudflare-dns.com/dns-query
            foreach ($cloudflareResolver in @('1.1.1.1', '1.0.0.1')) {
                foreach ($protocol in @('TCP', 'UDP')) {
                    (@(Get-CapturedFirewallRules) | Where-Object {
                            $_.RemoteAddress -eq $cloudflareResolver -and $_.RemotePort -eq '443' -and $_.Protocol -eq $protocol -and $_.Action -eq 'Block'
                        }).Count | Should -Be 1

                    (@(Get-CapturedFirewallRules) | Where-Object {
                            $_.RemoteAddress -eq $cloudflareResolver -and $_.RemotePort -eq '53' -and $_.Protocol -eq $protocol -and $_.Action -eq 'Block'
                        }).Count | Should -Be 1
                }
            }

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -eq 'OpenPath-DNS-Allow-Upstream-UDP' -and $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '53' -and $_.Program -like '*AcrylicService.exe'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -eq 'OpenPath-DNS-Allow-Upstream-TCP' -and $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '53' -and $_.Program -like '*AcrylicService.exe'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '53' -and $_.Action -eq 'Block' -and $_.Program -notlike '*AcrylicService.exe'
                }).Count | Should -BeGreaterThan 0
        }

        It "Does not create DoH 443 rules when DoH IP blocking is disabled" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $false
                    dohResolverIps = @('4.4.4.4', '5.5.5.5')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules) | Where-Object { $_.DisplayName -like '*Block-DoH*' -and $_.RemotePort -eq '443' }).Count | Should -Be 0
        }

        It "Creates targeted DNS/53 bypass blocks instead of a global port 53 block" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dohResolverIps = @('4.4.4.4', '5.5.5.5')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '4.4.4.4' -and $_.RemotePort -eq '53' -and $_.Protocol -eq 'TCP'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemoteAddress -eq '4.4.4.4' -and $_.RemotePort -eq '53' -and $_.Protocol -eq 'UDP'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object { $_.DisplayName -eq 'OpenPath-DNS-Block-DNS-UDP' }).Count | Should -Be 0
            (@(Get-CapturedFirewallRules) | Where-Object { $_.DisplayName -eq 'OpenPath-DNS-Block-DNS-TCP' }).Count | Should -Be 0
        }

        It "Keeps QUIC blocking resolver-specific without adding a global UDP 443 block by default" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dohResolverIps = @('1.1.1.1', '8.8.8.8')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            $resolverUdp443Blocks = @(Get-CapturedFirewallRules) | Where-Object {
                $_.RemotePort -eq '443' -and $_.Protocol -eq 'UDP' -and $_.Action -eq 'Block' -and $_.RemoteAddress
            }
            $resolverUdp443Blocks.Count | Should -BeGreaterThan 0

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.RemotePort -eq '443' -and $_.Protocol -eq 'UDP' -and $_.Action -eq 'Block' -and -not $_.RemoteAddress
                }).Count | Should -Be 0
        }

        It "Creates TCP and UDP allow rules for Acrylic upstream DNS" {
            Initialize-FirewallRuleCaptureMocks
            Set-FirewallAcrylicServicePresent -Present $true
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dohResolverIps = @('4.4.4.4')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -eq 'OpenPath-DNS-Allow-Upstream-UDP' -and $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '53'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -eq 'OpenPath-DNS-Allow-Upstream-TCP' -and $_.RemoteAddress -eq '8.8.8.8' -and $_.RemotePort -eq '53'
                }).Count | Should -Be 1
        }
    }

    Context "VPN and Tor egress blocking" {
        It "Matches shared VPN/Tor contract fixtures" {
            $expectedVpnRules = @(Get-ContractFixtureLines -FileName 'vpn-block-rules.txt' | Sort-Object -Unique)
            $actualVpnRules = @(
                (Get-DefaultVpnBlockRules | ForEach-Object {
                    "$(($_.Protocol).ToString().ToLowerInvariant()):$($_.Port):$($_.Name)"
                }) | Sort-Object -Unique
            )

            $vpnDiff = Compare-Object -ReferenceObject $expectedVpnRules -DifferenceObject $actualVpnRules
            $vpnDiff | Should -BeNullOrEmpty

            $expectedTorPorts = @(Get-ContractFixtureLines -FileName 'tor-block-ports.txt' | Sort-Object -Unique)
            $actualTorPorts = @((Get-DefaultTorBlockPorts | ForEach-Object { [string]$_ }) | Sort-Object -Unique)

            $torDiff = Compare-Object -ReferenceObject $expectedTorPorts -DifferenceObject $actualTorPorts
            $torDiff | Should -BeNullOrEmpty
        }

        It "Exposes default VPN and Tor block catalogs" {
            $vpnRules = @((Get-DefaultVpnBlockRules))
            $torPorts = @((Get-DefaultTorBlockPorts))

            $vpnRules.Count | Should -BeGreaterThan 0
            $torPorts.Count | Should -BeGreaterThan 0

            ($vpnRules | Where-Object { $_.Protocol -eq 'UDP' -and $_.Port -eq 1194 }).Count | Should -Be 1
            ($vpnRules | Where-Object { $_.Protocol -eq 'TCP' -and $_.Port -eq 1723 }).Count | Should -Be 1
            @($torPorts) | Should -Contain 9001
            @($torPorts) | Should -Contain 9030
        }

        BeforeEach {
            Initialize-FirewallRuleCaptureMocks
        }

        It "Applies custom VPN and Tor block configuration" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableDohIpBlocking = $false
                    vpnBlockRules = @(
                        [PSCustomObject]@{ Protocol = 'TCP'; Port = 9443; Name = 'TestVPN-TCP' },
                        [PSCustomObject]@{ Protocol = 'UDP'; Port = 5555; Name = 'TestVPN-UDP' }
                    )
                    torBlockPorts = @(10001, 10002)
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-VPN*' -and $_.Protocol -eq 'TCP' -and $_.RemotePort -eq '9443'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-VPN*' -and $_.Protocol -eq 'UDP' -and $_.RemotePort -eq '5555'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-Tor-10001' -and $_.Protocol -eq 'TCP' -and $_.RemotePort -eq '10001'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-Tor-10002' -and $_.Protocol -eq 'TCP' -and $_.RemotePort -eq '10002'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object { $_.DisplayName -like '*Block-Tor-9001' }).Count | Should -Be 0
        }

        It "Skips invalid VPN/Tor custom entries and keeps valid ones" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableDohIpBlocking = $false
                    vpnBlockRules = @('udp:6000:GoodRule', 'bad-entry', 'tcp:notaport:BadRule', 'icmp:1200:InvalidProto')
                    torBlockPorts = @('9050', 'bad', 70000)
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-VPN*' -and $_.Protocol -eq 'UDP' -and $_.RemotePort -eq '6000'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-VPN*' -and $_.RemotePort -eq '1200'
                }).Count | Should -Be 0

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-Tor-9050' -and $_.Protocol -eq 'TCP' -and $_.RemotePort -eq '9050'
                }).Count | Should -Be 1

            (@(Get-CapturedFirewallRules) | Where-Object {
                    $_.DisplayName -like '*Block-Tor-70000'
                }).Count | Should -Be 0
        }
    }
}
