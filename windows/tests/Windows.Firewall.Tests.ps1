Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Firewall Module" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\Firewall.psm1" -Force -ErrorAction SilentlyContinue
    }

    Context "Test-FirewallActive" {
        It "Returns a boolean value" -Skip:(-not $IsWindows) {
            $result = Test-FirewallActive
            $result | Should -BeOfType [bool]
        }
    }

    Context "Get-FirewallStatus" {
        It "Returns a hashtable with expected keys" -Skip:(-not $IsWindows) {
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
                'function Remove-OpenPathFirewallRuleObjects',
                "Get-NetFirewallRule -Group 'OpenPath'",
                'Get-NetFirewallRule -DisplayName "$script:RulePrefix-*"'
            )
        }

        It "Writes firewall manifests atomically as JSON arrays and normalizes legacy joined names" {
            $manifestPath = Join-Path $TestDrive 'firewall-rules.json'
            Set-Content -Path $manifestPath -Value '["OpenPath-DNS-Allow-Loopback-TCP OpenPath-DNS-Allow-Loopback-UDP"]' -Encoding UTF8

            Mock Get-OpenPathFirewallManifestPath { $manifestPath } -ModuleName Firewall
            Mock Write-OpenPathLog { } -ModuleName Firewall

            InModuleScope Firewall {
                Add-OpenPathFirewallManifestRule -Name 'OpenPath-DNS-Allow-Upstream-UDP'
            }

            $raw = Get-Content $manifestPath -Raw
            $raw.TrimStart() | Should -Match '^\['
            $parsed = @($raw | ConvertFrom-Json)

            $parsed.Count | Should -Be 3
            $parsed | Should -Contain 'OpenPath-DNS-Allow-Loopback-TCP'
            $parsed | Should -Contain 'OpenPath-DNS-Allow-Loopback-UDP'
            $parsed | Should -Contain 'OpenPath-DNS-Allow-Upstream-UDP'
            Get-ChildItem -Path $TestDrive -Filter '*.tmp' | Should -BeNullOrEmpty
        }

        It "Ignores corrupt firewall manifests and still removes grouped and DNS-prefixed rules" {
            $manifestPath = Join-Path $TestDrive 'firewall-rules.json'
            Set-Content -Path $manifestPath -Value '[ "OpenPath-DNS-Allow-Loopback-TCP", ' -Encoding UTF8
            $script:requestedFirewallRules = @()
            $script:removedFirewallRules = @()

            if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
                function global:Get-NetFirewallRule { }
            }

            Mock Get-OpenPathFirewallManifestPath { $manifestPath } -ModuleName Firewall
            Mock Write-OpenPathLog { } -ModuleName Firewall
            Mock Get-NetFirewallRule {
                param(
                    [string]$DisplayName,
                    [string]$Group
                )

                if ($DisplayName) {
                    $script:requestedFirewallRules += $DisplayName
                    if ($DisplayName -eq 'OpenPath-DNS-*') {
                        return [PSCustomObject]@{ DisplayName = 'OpenPath-DNS-fallback-rule' }
                    }
                    return [PSCustomObject]@{ DisplayName = $DisplayName }
                }

                if ($Group -eq 'OpenPath') {
                    $script:requestedFirewallRules += 'group:OpenPath'
                    return [PSCustomObject]@{ DisplayName = 'OpenPath-group-rule' }
                }
            } -ModuleName Firewall
            Mock Remove-OpenPathFirewallRuleObjects {
                param([object[]]$Rules)

                $script:removedFirewallRules += @(
                    foreach ($rule in @($Rules)) {
                        if ($null -ne $rule -and $rule.PSObject.Properties['DisplayName']) {
                            $rule.DisplayName
                        }
                    }
                )
            } -ModuleName Firewall

            try {
                $result = InModuleScope Firewall { Remove-OpenPathFirewall }

                $result | Should -BeTrue
                $script:requestedFirewallRules | Should -Contain 'group:OpenPath'
                $script:requestedFirewallRules | Should -Contain 'OpenPath-DNS-*'
                $script:removedFirewallRules | Should -Contain 'OpenPath-group-rule'
                $script:removedFirewallRules | Should -Contain 'OpenPath-DNS-fallback-rule'
                Should -Invoke -CommandName Remove-OpenPathFirewallRuleObjects -ModuleName Firewall -Times 2 -Exactly
                Test-Path $manifestPath | Should -BeFalse
            }
            finally {
                Remove-Variable -Name requestedFirewallRules -Scope Script -ErrorAction SilentlyContinue
                Remove-Variable -Name removedFirewallRules -Scope Script -ErrorAction SilentlyContinue
                Microsoft.PowerShell.Management\Remove-Item Function:\Get-NetFirewallRule -ErrorAction SilentlyContinue
            }
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

    Context "Split DNS portal upstream firewall allow" {
        It "Extends the Acrylic allow targets with split-DNS portal upstreams" {
            $policyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Policy.ps1"
            $content = Get-Content $policyPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'PortalUpstream$portalUpstreamIndex',
                'Get-OpenPathSplitDnsPortalUpstreams'
            )
        }
    }

    Context "Captive portal upstream firewall allow" {
        BeforeEach {
            Initialize-FirewallRuleCaptureMocks
            if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
                function global:Get-NetFirewallRule { }
            }
            Mock Get-NetFirewallRule { @() } -ModuleName Firewall
        }

        It "Adds additive UDP+TCP/53 allow rules for the portal upstream, scoped to Acrylic and prefixed for cleanup" {
            Set-FirewallAcrylicServicePresent -Present $true

            $result = Add-OpenPathCaptivePortalUpstreamFirewallAllow -Address '172.23.136.5' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            $rules = @(Get-CapturedFirewallRules | Where-Object {
                    $_.RemoteAddress -eq '172.23.136.5' -and $_.RemotePort -eq '53' -and $_.Action -eq 'Allow'
                })
            (@($rules | Where-Object { $_.Protocol -eq 'UDP' })).Count | Should -Be 1
            (@($rules | Where-Object { $_.Protocol -eq 'TCP' })).Count | Should -Be 1
            # OpenPath-DNS prefix => removed by the firewall rebuild on protected-mode restore
            (@($rules | Where-Object { $_.DisplayName -like 'OpenPath-DNS-Allow-PortalUpstream-*' })).Count | Should -Be 2
            # scoped to the Acrylic program (not a blanket DNS allow)
            (@($rules | Where-Object { $_.Program -like '*AcrylicService.exe' })).Count | Should -Be 2
        }

        It "Refuses an invalid upstream address and creates no rules" {
            $result = Add-OpenPathCaptivePortalUpstreamFirewallAllow -Address 'not-an-ip'
            $result | Should -BeFalse
            @(Get-CapturedFirewallRules).Count | Should -Be 0
        }
    }

    Context "Default-deny DNS egress" {
        BeforeEach {
            Initialize-FirewallRuleCaptureMocks
        }

        It "Blocks outbound DNS to everything except loopback and configured upstreams" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dnsEgressDefaultDeny = $true
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            foreach ($protocol in @('UDP', 'TCP')) {
                $blocks = @(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq "OpenPath-DNS-Block-DefaultDeny-DNS-$protocol-53" -and
                        $_.RemotePort -eq '53' -and $_.Direction -eq 'Outbound' -and $_.Action -eq 'Block'
                    })
                $blocks.Count | Should -Be 1
                # Wide block that still carves out loopback and the configured upstreams.
                $blocks[0].RemoteAddress | Should -Match '128\.0\.0\.0-255\.255\.255\.255'
                $blocks[0].RemoteAddress | Should -Not -Match '127\.0\.0\.0'
                $blocks[0].RemoteAddress | Should -Not -Match '8\.8\.8\.8'
                $blocks[0].RemoteAddress | Should -Not -Match '8\.8\.4\.4'
            }
        }

        It "Blocks IPv6 DNS wholesale since there is no local IPv6 Acrylic listener" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ dnsEgressDefaultDeny = $true }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            foreach ($protocol in @('UDP', 'TCP')) {
                (@(Get-CapturedFirewallRules | Where-Object {
                            $_.DisplayName -eq "OpenPath-DNS-Block-DefaultDeny-DNS6-$protocol-53" -and
                            $_.RemoteAddress -eq '::/0' -and $_.Action -eq 'Block'
                        })).Count | Should -Be 1
            }
        }

        It "Does not create default-deny rules when disabled by configuration" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ dnsEgressDefaultDeny = $false }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*DefaultDeny*' })).Count | Should -Be 0
        }
    }

    Context "Inbound DNS blocking" {
        BeforeEach {
            Initialize-FirewallRuleCaptureMocks
        }

        It "Blocks inbound DNS on local port 53 so the host never answers LAN or guest queries" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ blockInboundDns = $true }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            foreach ($protocol in @('UDP', 'TCP')) {
                (@(Get-CapturedFirewallRules | Where-Object {
                            $_.DisplayName -eq "OpenPath-DNS-Block-Inbound-DNS-$protocol-53" -and
                            $_.Direction -eq 'Inbound' -and $_.LocalPort -eq '53' -and $_.Action -eq 'Block'
                        })).Count | Should -Be 1
            }
        }

        It "Does not create inbound DNS blocks when disabled by configuration" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ blockInboundDns = $false }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*Block-Inbound-DNS*' })).Count | Should -Be 0
        }
    }

    Context "Get-OpenPathDnsEgressBlockRanges" {
        It "Returns the full non-loopback IPv4 space when no allow IPs are supplied" {
            $ranges = @(Get-OpenPathDnsEgressBlockRanges -AllowIps @())
            $ranges.Count | Should -Be 2
            $ranges | Should -Contain '0.0.0.0-126.255.255.255'
            $ranges | Should -Contain '128.0.0.0-255.255.255.255'
        }

        It "Carves out loopback and each supplied allow IP" {
            $ranges = @(Get-OpenPathDnsEgressBlockRanges -AllowIps @('8.8.8.8', '8.8.4.4'))
            $ranges.Count | Should -Be 4
            $ranges | Should -Contain '0.0.0.0-8.8.4.3'
            $ranges | Should -Contain '8.8.4.5-8.8.8.7'
            $ranges | Should -Contain '8.8.8.9-126.255.255.255'
            $ranges | Should -Contain '128.0.0.0-255.255.255.255'
        }

        It "Ignores IPv6 and unparseable allow entries" {
            $ranges = @(Get-OpenPathDnsEgressBlockRanges -AllowIps @('::1', 'not-an-ip', '9.9.9.9'))
            $ranges | Should -Contain '0.0.0.0-9.9.9.8'
            $ranges | Should -Contain '9.9.9.10-126.255.255.255'
            $ranges | Should -Contain '128.0.0.0-255.255.255.255'
        }

        It "Merges duplicate and adjacent allow IPs without emitting empty ranges" {
            $ranges = @(Get-OpenPathDnsEgressBlockRanges -AllowIps @('1.1.1.1', '1.1.1.1', '1.1.1.2'))
            $ranges | Should -Contain '0.0.0.0-1.1.1.0'
            $ranges | Should -Contain '1.1.1.3-126.255.255.255'
            foreach ($range in $ranges) { $range | Should -Match '^\d+\.\d+\.\d+\.\d+-\d+\.\d+\.\d+\.\d+$' }
        }
    }

    Context "Outbound egress floor (W-1(b), default-OFF scaffold)" {
        It "Builds default-deny outbound 443 rule shapes that allow only whitelist IPs and system programs" {
            $rules = @(Get-OpenPathOutboundEgressFloorRules `
                    -AllowIps @('203.0.113.10', '203.0.113.20') `
                    -SystemServicePrograms @('C:\OpenPath\bin\OpenPathAgent.exe') `
                    -RulePrefix 'OpenPath-DNS')

            # System-program allow rule (Any remote, 443) so update/API/time-sync survives.
            $systemAllow = @($rules | Where-Object {
                    $_.Action -eq 'Allow' -and $_.Program -eq 'C:\OpenPath\bin\OpenPathAgent.exe' -and $_.RemotePort -eq 443
                })
            $systemAllow.Count | Should -Be 1
            $systemAllow[0].RemoteAddress | Should -Be 'Any'

            # Per-whitelist-IP allow rules.
            foreach ($ip in @('203.0.113.10', '203.0.113.20')) {
                $allow = @($rules | Where-Object {
                        $_.Action -eq 'Allow' -and $_.RemoteAddress -eq $ip -and $_.RemotePort -eq 443
                    })
                $allow.Count | Should -Be 1
            }

            # IPv4 default-deny block that carves out loopback and the allow IPs.
            $ipv4Block = @($rules | Where-Object {
                    $_.Action -eq 'Block' -and $_.Protocol -eq 'TCP' -and $_.RemotePort -eq 443 -and $_.RemoteAddress -ne '::/0'
                })
            $ipv4Block.Count | Should -Be 1
            # Loopback and both allow IPs are carved out of the blocked space.
            $ipv4Block[0].RemoteAddress | Should -Contain '0.0.0.0-126.255.255.255'
            $ipv4Block[0].RemoteAddress | Should -Contain '128.0.0.0-203.0.113.9'
            $ipv4Block[0].RemoteAddress | Should -Contain '203.0.113.21-255.255.255.255'
            ($ipv4Block[0].RemoteAddress -join ' ') | Should -Not -Match '127\.0\.0\.0-'
            ($ipv4Block[0].RemoteAddress -join ' ') | Should -Not -Match '-203\.0\.113\.10$'

            # Wholesale IPv6 443 block.
            $ipv6Block = @($rules | Where-Object { $_.Action -eq 'Block' -and $_.RemoteAddress -eq '::/0' -and $_.RemotePort -eq 443 })
            $ipv6Block.Count | Should -Be 1
        }

        It "Never expresses the floor as a machine-wide DefaultOutboundAction block" {
            $rules = @(Get-OpenPathOutboundEgressFloorRules -AllowIps @('203.0.113.10'))
            foreach ($rule in $rules) {
                $rule.PSObject.Properties.Name | Should -Not -Contain 'DefaultOutboundAction'
                # Every block rule is scoped to remote port 443, never a blanket all-port deny.
                if ($rule.Action -eq 'Block') {
                    $rule.RemotePort | Should -Be 443
                }
            }
        }

        It "Set-OpenPathFirewall does not emit egress-floor rules by default" {
            Initialize-FirewallRuleCaptureMocks
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ enableKnownDnsIpBlocking = $true }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' })).Count | Should -Be 0
        }

        It "Set-OpenPathFirewall emits egress-floor rules only when explicitly enabled" {
            Initialize-FirewallRuleCaptureMocks
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    outboundEgressFloorEnabled = $true
                    outboundEgressFloorAllowIps = @('203.0.113.10')
                    outboundEgressFloorSystemPrograms = @('C:\OpenPath\bin\OpenPathAgent.exe')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP443' -and $_.Action -eq 'Allow'
                    })).Count | Should -Be 1
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Block-EgressFloor-DefaultDeny-TCP443' -and $_.Action -eq 'Block'
                    })).Count | Should -Be 1
        }
    }

    Context "Egress floor system-service allow-list (W-1(b))" {
        It "Includes svchost, w32tm, both PowerShell hosts, and Acrylic so OS/agent egress survives" {
            $programs = InModuleScope Firewall {
                Get-OpenPathEgressFloorSystemServicePrograms -OpenPathRoot 'C:\OpenPath' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            }

            # svchost.exe hosts wuauserv / BITS / DoSvc / W32Time -- must be present.
            ($programs | Where-Object { $_ -like '*\System32\svchost.exe' }).Count | Should -BeGreaterThan 0
            ($programs | Where-Object { $_ -like '*\System32\w32tm.exe' }).Count | Should -BeGreaterThan 0
            ($programs | Where-Object { $_ -like '*\WindowsPowerShell\v1.0\powershell.exe' }).Count | Should -BeGreaterThan 0
            ($programs | Where-Object { $_ -like '*\PowerShell\7\pwsh.exe' }).Count | Should -BeGreaterThan 0
            ($programs | Where-Object { $_ -like '*Acrylic DNS Proxy\AcrylicService.exe' }).Count | Should -Be 1
        }

        It "De-duplicates and merges operator-supplied extra programs" {
            $programs = InModuleScope Firewall {
                Get-OpenPathEgressFloorSystemServicePrograms -OpenPathRoot 'C:\OpenPath' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy' -ExtraPrograms @('C:\Site\agent.exe', 'C:\Site\agent.exe')
            }
            ($programs | Where-Object { $_ -eq 'C:\Site\agent.exe' }).Count | Should -Be 1
            # No duplicate svchost entries despite being added twice in the builder.
            ($programs | Where-Object { $_ -like '*\System32\svchost.exe' }).Count | Should -Be 1
        }
    }

    Context "Egress floor live resolver (W-1(b))" {
        It "Resolves whitelist + always-allowed domains through Acrylic and returns deduped valid IPv4 literals" {
            $resolved = InModuleScope Firewall {
                Mock Write-OpenPathLog { } -ModuleName Firewall
                Mock Get-ValidWhitelistDomainsFromFile { @('example.edu') } -ModuleName Firewall
                Mock Get-OpenPathAlwaysAllowedDomains { @('api.example.org') } -ModuleName Firewall
                if (-not (Get-Command -Name Resolve-OpenPathDnsWithRetry -ErrorAction SilentlyContinue)) {
                    function script:Resolve-OpenPathDnsWithRetry { }
                }
                Mock Resolve-OpenPathDnsWithRetry {
                    param($Domain)
                    if ($Domain -eq 'example.edu') {
                        return @(
                            [PSCustomObject]@{ IPAddress = '203.0.113.5' },
                            [PSCustomObject]@{ IPAddress = '203.0.113.6' },
                            [PSCustomObject]@{ IPAddress = '203.0.113.5' }
                        )
                    }
                    return @([PSCustomObject]@{ IPAddress = '198.51.100.9' })
                } -ModuleName Firewall

                Get-OpenPathEgressFloorAllowIps -WhitelistPath 'C:\OpenPath\data\whitelist.txt'
            }

            @($resolved) | Should -Contain '203.0.113.5'
            @($resolved) | Should -Contain '203.0.113.6'
            @($resolved) | Should -Contain '198.51.100.9'
            (@($resolved) | Where-Object { $_ -eq '203.0.113.5' }).Count | Should -Be 1
        }

        It "Returns an empty set (fail-open signal) when no domains resolve" {
            $resolved = InModuleScope Firewall {
                Mock Write-OpenPathLog { } -ModuleName Firewall
                Mock Get-ValidWhitelistDomainsFromFile { @('example.edu') } -ModuleName Firewall
                Mock Get-OpenPathAlwaysAllowedDomains { @() } -ModuleName Firewall
                if (-not (Get-Command -Name Resolve-OpenPathDnsWithRetry -ErrorAction SilentlyContinue)) {
                    function script:Resolve-OpenPathDnsWithRetry { }
                }
                Mock Resolve-OpenPathDnsWithRetry { $null } -ModuleName Firewall

                Get-OpenPathEgressFloorAllowIps -WhitelistPath 'C:\OpenPath\data\whitelist.txt'
            }
            @($resolved).Count | Should -Be 0
        }
    }

    Context "Egress floor apply fail-open guard (W-1(b))" {
        It "Builds NO default-deny block rule when the resolved allow-IP set is empty" {
            Initialize-FirewallRuleCaptureMocks
            $count = InModuleScope Firewall {
                Set-OpenPathEgressFloorRules -AllowIps @() -SystemServicePrograms @('C:\OpenPath\bin\agent.exe')
            }
            $count | Should -Be 0
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' })).Count | Should -Be 0
        }

        It "Builds the floor when at least one valid allow IP is present" {
            Initialize-FirewallRuleCaptureMocks
            $count = InModuleScope Firewall {
                Set-OpenPathEgressFloorRules -AllowIps @('203.0.113.10') -SystemServicePrograms @('C:\OpenPath\bin\agent.exe')
            }
            $count | Should -BeGreaterThan 0
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Block-EgressFloor-DefaultDeny-TCP443' -and $_.Action -eq 'Block'
                    })).Count | Should -Be 1
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP443' -and $_.Action -eq 'Allow'
                    })).Count | Should -Be 1
        }
    }

    Context "Egress floor refresh and drift (W-1(b))" {
        It "Update-OpenPathEgressFloor resolves live and applies a floor when no static IPs are supplied" {
            Initialize-FirewallRuleCaptureMocks
            $count = InModuleScope Firewall {
                Mock Get-OpenPathEgressFloorAllowIps { @('203.0.113.10', '203.0.113.20') } -ModuleName Firewall
                Update-OpenPathEgressFloor -StaticAllowIps @() -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            }
            $count | Should -BeGreaterThan 0
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-20-TCP443'
                    })).Count | Should -Be 1
        }

        It "Update-OpenPathEgressFloor fails open (0 rules) when live resolution is empty" {
            Initialize-FirewallRuleCaptureMocks
            $count = InModuleScope Firewall {
                Mock Get-OpenPathEgressFloorAllowIps { @() } -ModuleName Firewall
                Update-OpenPathEgressFloor -StaticAllowIps @() -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            }
            $count | Should -Be 0
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' })).Count | Should -Be 0
        }

        It "Test-OpenPathEgressFloorDrift reports no drift when resolution is empty (never tears down a working floor)" {
            $drift = InModuleScope Firewall {
                Mock Get-OpenPathEgressFloorAllowIps { @() } -ModuleName Firewall
                Test-OpenPathEgressFloorDrift -StaticAllowIps @()
            }
            $drift.Drifted | Should -BeFalse
            $drift.Reason | Should -Be 'empty-resolution-fail-open'
        }

        It "Test-OpenPathEgressFloorDrift reports drift when resolved IPs differ from installed allow rules" {
            $drift = InModuleScope Firewall {
                if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
                    function script:Get-NetFirewallRule { }
                }
                if (-not (Get-Command -Name Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue)) {
                    function script:Get-NetFirewallAddressFilter { }
                }
                Mock Get-NetFirewallRule { @([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP443' }) } -ModuleName Firewall
                Mock Get-NetFirewallAddressFilter { [PSCustomObject]@{ RemoteAddress = @('203.0.113.10') } } -ModuleName Firewall
                Test-OpenPathEgressFloorDrift -StaticAllowIps @('203.0.113.10', '203.0.113.99')
            }
            $drift.Drifted | Should -BeTrue
            @($drift.ResolvedIps) | Should -Contain '203.0.113.99'
        }
    }

    Context "Egress floor live resolution in Set-OpenPathFirewall (W-1(b))" {
        It "Resolves the floor live when enabled with no static allow-IP set, and fails open on empty resolution" {
            Initialize-FirewallRuleCaptureMocks
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ outboundEgressFloorEnabled = $true }
            } -ModuleName Firewall
            Mock Get-OpenPathEgressFloorAllowIps { @() } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue
            # Fail-open: no EgressFloor block rules emitted on empty resolution.
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*Block*' -or $_.DisplayName -like '*Block-EgressFloor*' })).Count | Should -Be 0
        }

        It "Resolves the floor live when enabled with no static allow-IP set and applies rules when resolution yields IPs" {
            Initialize-FirewallRuleCaptureMocks
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ outboundEgressFloorEnabled = $true }
            } -ModuleName Firewall
            Mock Get-OpenPathEgressFloorAllowIps { @('203.0.113.10') } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Block-EgressFloor-DefaultDeny-TCP443' -and $_.Action -eq 'Block'
                    })).Count | Should -Be 1
        }
    }
}
