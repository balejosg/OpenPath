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

        It "Blocks all IPv6 DNS using valid /1 halves instead of the Windows-rejected ::/0 prefix" {
            # Regression: New-NetFirewallRule rejects '::/0' (prefix length 0) with "One or
            # more of the address prefixes is invalid", which aborted the entire firewall
            # apply mid-way on a real Windows endpoint. All-IPv6 must be the two /1 halves.
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableKnownDnsIpBlocking = $true
                    enableDohIpBlocking = $true
                    dohResolverIps = @('4.4.4.4')
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            $dns6Blocks = @(Get-CapturedFirewallRules) | Where-Object { $_.DisplayName -like '*Block-DefaultDeny-DNS6-*-53' }
            $dns6Blocks.Count | Should -Be 2
            foreach ($rule in $dns6Blocks) {
                $rule.RemoteAddress | Should -Match '::/1'
                $rule.RemoteAddress | Should -Match '8000::/1'
                $rule.RemoteAddress | Should -Not -Match '::/0'
            }
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
                # All-IPv6 is the two valid /1 halves, not the Windows-rejected '::/0' prefix.
                (@(Get-CapturedFirewallRules | Where-Object {
                            $_.DisplayName -eq "OpenPath-DNS-Block-DefaultDeny-DNS6-$protocol-53" -and
                            $_.RemoteAddress -match '::/1' -and $_.RemoteAddress -match '8000::/1' -and
                            $_.RemoteAddress -notmatch '::/0' -and $_.Action -eq 'Block'
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

    Context "Outbound egress floor (W-1(b), DefaultOutboundAction-Block model, default-OFF)" {
        It "Builds Allow-only rule shapes: system full egress, whitelist HTTP/HTTPS, loopback, and DHCP" {
            $rules = @(Get-OpenPathOutboundEgressFloorRules `
                    -AllowIps @('203.0.113.10', '203.0.113.20') `
                    -SystemServicePrograms @('C:\OpenPath\bin\OpenPathAgent.exe') `
                    -RulePrefix 'OpenPath-DNS')

            # System-program allow rule: FULL egress (any protocol/port/remote) so OS
            # update / time-sync / DNS-upstream survive the default block on any port.
            $systemAllow = @($rules | Where-Object {
                    $_.Action -eq 'Allow' -and $_.Program -eq 'C:\OpenPath\bin\OpenPathAgent.exe'
                })
            $systemAllow.Count | Should -Be 1
            $systemAllow[0].RemoteAddress | Should -Be 'Any'
            $systemAllow[0].Protocol | Should -Be 'Any'
            $systemAllow[0].RemotePort | Should -Be 'Any'
            $systemAllow[0].DisplayName | Should -BeLike 'OpenPath-DNS-Allow-EgressFloor-System-*'

            # Per-whitelist-IP allow rules over TCP 80 and 443 (HTTP redirects + HTTPS).
            foreach ($ip in @('203.0.113.10', '203.0.113.20')) {
                $allow = @($rules | Where-Object {
                        $_.Action -eq 'Allow' -and $_.RemoteAddress -eq $ip -and $_.Protocol -eq 'TCP'
                    })
                $allow.Count | Should -Be 1
                @($allow[0].RemotePort) | Should -Contain '80'
                @($allow[0].RemotePort) | Should -Contain '443'
            }

            # Loopback allow (IPv4 only) keeps the local Acrylic listener reachable.
            # No '::1' rule: New-NetFirewallRule rejects an IPv6 loopback RemoteAddress
            # (confirmed on the real Windows runner) and WFP exempts loopback anyway.
            (@($rules | Where-Object { $_.Action -eq 'Allow' -and $_.RemoteAddress -eq '127.0.0.1' })).Count | Should -Be 1
            (@($rules | Where-Object { $_.Action -eq 'Allow' -and $_.RemoteAddress -eq '::1' })).Count | Should -Be 0

            # DHCP allow (UDP 67/68) keeps the lease renewing under the default block.
            $dhcp = @($rules | Where-Object { $_.Action -eq 'Allow' -and $_.Protocol -eq 'UDP' -and $_.DisplayName -like '*EgressFloor-DHCP' })
            $dhcp.Count | Should -Be 1
            @($dhcp[0].RemotePort) | Should -Contain '67'
            @($dhcp[0].RemotePort) | Should -Contain '68'
        }

        It "Emits NO Block rules and no DefaultOutboundAction field (default-deny comes from the profile, not rules)" {
            $rules = @(Get-OpenPathOutboundEgressFloorRules -AllowIps @('203.0.113.10') -SystemServicePrograms @('C:\OpenPath\bin\agent.exe'))
            # The floor must create zero explicit Block rules (an explicit Block would WIN
            # over the program-scoped Allows on WFP and re-brick the system services).
            (@($rules | Where-Object { $_.Action -eq 'Block' })).Count | Should -Be 0
            foreach ($rule in $rules) {
                $rule.Action | Should -Be 'Allow'
                # The descriptor never carries a machine-wide DefaultOutboundAction field;
                # that profile-level flip is the apply path's job, not a rule shape.
                $rule.PSObject.Properties.Name | Should -Not -Contain 'DefaultOutboundAction'
            }
        }

        It "Set-OpenPathFirewall does not emit egress-floor rules or flip the outbound default by default" {
            Initialize-FirewallRuleCaptureMocks
            $script:profileOutboundActions = @()
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $script:profileOutboundActions += $DefaultOutboundAction } -ModuleName Firewall
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ enableKnownDnsIpBlocking = $true }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue

            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' })).Count | Should -Be 0
            # Default OFF: the outbound default is never flipped to Block.
            @($script:profileOutboundActions) | Should -Not -Contain 'Block'
        }

        It "Set-OpenPathFirewall emits egress-floor Allow rules and sets DefaultOutboundAction Block only when explicitly enabled" {
            Initialize-FirewallRuleCaptureMocks
            $script:profileOutboundActions = @()
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            if (-not (Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Get-NetFirewallProfile { }
            }
            Mock Get-NetFirewallProfile { param($Profile) [PSCustomObject]@{ DefaultOutboundAction = 'Allow' } } -ModuleName Firewall
            Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $script:profileOutboundActions += $DefaultOutboundAction } -ModuleName Firewall
            Mock Test-Path { $false } -ModuleName Firewall -ParameterFilter { $Path -like '*egress-floor-prev-outbound.json' }
            Mock Set-Content { } -ModuleName Firewall
            Mock New-Item { } -ModuleName Firewall
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
                        $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP' -and $_.Action -eq 'Allow'
                    })).Count | Should -Be 1
            # The default-deny is the profile flip, not an explicit Block rule.
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' -and $_.Action -eq 'Block' })).Count | Should -Be 0
            @($script:profileOutboundActions) | Should -Contain 'Block'
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
        It "Does NOT set DefaultOutboundAction Block when the resolved allow-IP set is empty, and restores Allow" {
            Initialize-FirewallRuleCaptureMocks
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            $outcome = InModuleScope Firewall {
                $captured = New-Object System.Collections.Generic.List[string]
                Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $captured.Add([string]$DefaultOutboundAction) } -ModuleName Firewall
                Mock Test-Path { $false } -ModuleName Firewall
                $count = Set-OpenPathEgressFloorRules -AllowIps @() -SystemServicePrograms @('C:\OpenPath\bin\agent.exe')
                [PSCustomObject]@{ Count = $count; Actions = @($captured) }
            }
            $outcome.Count | Should -Be 0
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' })).Count | Should -Be 0
            # Critical brick-guard: never Block with an empty allow set. The fail-open path
            # restores the default (fallback Allow, since no state file exists) -- never Block.
            @($outcome.Actions) | Should -Not -Contain 'Block'
            @($outcome.Actions) | Should -Contain 'Allow'
        }

        It "Sets DefaultOutboundAction Block and creates system/whitelist/loopback/DHCP Allows when an allow IP is present" {
            Initialize-FirewallRuleCaptureMocks
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            if (-not (Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Get-NetFirewallProfile { }
            }
            $outcome = InModuleScope Firewall {
                $captured = New-Object System.Collections.Generic.List[string]
                Mock Get-NetFirewallProfile { [PSCustomObject]@{ DefaultOutboundAction = 'Allow' } } -ModuleName Firewall
                Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $captured.Add([string]$DefaultOutboundAction) } -ModuleName Firewall
                Mock Test-Path { $false } -ModuleName Firewall
                Mock Set-Content { } -ModuleName Firewall
                Mock New-Item { } -ModuleName Firewall
                $count = Set-OpenPathEgressFloorRules -AllowIps @('203.0.113.10') -SystemServicePrograms @('C:\OpenPath\bin\agent.exe')
                [PSCustomObject]@{ Count = $count; Actions = @($captured) }
            }
            $outcome.Count | Should -BeGreaterThan 0
            @($outcome.Actions) | Should -Contain 'Block'
            # No explicit Block rule (the deny is the profile default).
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' -and $_.Action -eq 'Block' })).Count | Should -Be 0
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP' -and $_.Action -eq 'Allow'
                    })).Count | Should -Be 1
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor-System-*' })).Count | Should -Be 1
            (@(Get-CapturedFirewallRules | Where-Object { $_.RemoteAddress -eq '127.0.0.1' -and $_.DisplayName -like '*EgressFloor-Loopback*' })).Count | Should -Be 1
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor-DHCP' })).Count | Should -Be 1
        }

        It "Restores DefaultOutboundAction from persisted state and removes floor rules on Remove" {
            Initialize-FirewallRuleCaptureMocks
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
                function global:Get-NetFirewallRule { }
            }
            $restored = InModuleScope Firewall {
                $captured = New-Object System.Collections.Generic.List[string]
                # A persisted baseline recording that pre-floor outbound was NotConfigured.
                Mock Test-Path { $true } -ModuleName Firewall
                Mock Get-Content { '{ "Domain": "NotConfigured", "Private": "NotConfigured", "Public": "NotConfigured" }' } -ModuleName Firewall
                Mock Remove-Item { } -ModuleName Firewall
                Mock Get-NetFirewallRule { @() } -ModuleName Firewall
                Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $captured.Add([string]$DefaultOutboundAction) } -ModuleName Firewall
                Remove-OpenPathEgressFloorRules
                @($captured)
            }
            # Restored exactly from persisted state (NotConfigured), never left at Block.
            @($restored) | Should -Contain 'NotConfigured'
            @($restored) | Should -Not -Contain 'Block'
        }
    }

    Context "Egress floor refresh and drift (W-1(b))" {
        It "Update-OpenPathEgressFloor resolves live and applies a floor when no static IPs are supplied" {
            Initialize-FirewallRuleCaptureMocks
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            if (-not (Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Get-NetFirewallProfile { }
            }
            $count = InModuleScope Firewall {
                Mock Get-OpenPathEgressFloorAllowIps { @('203.0.113.10', '203.0.113.20') } -ModuleName Firewall
                Mock Get-NetFirewallProfile { param($Profile) [PSCustomObject]@{ DefaultOutboundAction = 'Allow' } } -ModuleName Firewall
                Mock Set-NetFirewallProfile { } -ModuleName Firewall
                Mock Test-Path { $false } -ModuleName Firewall -ParameterFilter { $Path -like '*egress-floor-prev-outbound.json' }
                Mock Set-Content { } -ModuleName Firewall
                Mock New-Item { } -ModuleName Firewall
                Update-OpenPathEgressFloor -StaticAllowIps @() -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            }
            $count | Should -BeGreaterThan 0
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-20-TCP'
                    })).Count | Should -Be 1
        }

        It "Update-OpenPathEgressFloor fails open (0 rules) when live resolution is empty" {
            Initialize-FirewallRuleCaptureMocks
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            $count = InModuleScope Firewall {
                Mock Get-OpenPathEgressFloorAllowIps { @() } -ModuleName Firewall
                Mock Set-NetFirewallProfile { } -ModuleName Firewall
                Mock Test-Path { $false } -ModuleName Firewall -ParameterFilter { $Path -like '*egress-floor-prev-outbound.json' }
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

        It "Test-OpenPathEgressFloorDrift does NOT report false drift when the installed rule stores the IP in netmask form" {
            # Windows reports a /32 RemoteAddress as x.x.x.x/255.255.255.255; the resolver
            # returns the bare literal. Both must normalize to the same canonical form so a
            # stable allow set is never flagged as drift every cycle.
            $drift = InModuleScope Firewall {
                if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
                    function script:Get-NetFirewallRule { }
                }
                # Define the stub unconditionally so its permissive (no-param) signature
                # shadows the real Windows Get-NetFirewallAddressFilter cmdlet too. Otherwise
                # on Windows Pester mocks the real cmdlet's strict CimInstance pipeline
                # metadata, the `$rule | Get-NetFirewallAddressFilter` call (a PSCustomObject)
                # fails to bind, the address filter comes back empty, and drift detection
                # falsely fires -- the test passed on Linux (cmdlet absent) but failed on Windows.
                function script:Get-NetFirewallAddressFilter { }
                Mock Get-NetFirewallRule { @([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP' }) } -ModuleName Firewall
                # Installed form is netmask, resolved form is bare -- must be treated equal.
                Mock Get-NetFirewallAddressFilter { [PSCustomObject]@{ RemoteAddress = @('203.0.113.10/255.255.255.255') } } -ModuleName Firewall
                Test-OpenPathEgressFloorDrift -StaticAllowIps @('203.0.113.10')
            }
            $drift.Drifted | Should -BeFalse
            $drift.Reason | Should -Be 'in-sync'
            @($drift.CurrentIps) | Should -Contain '203.0.113.10'
        }

        It "Test-OpenPathEgressFloorDrift reports drift when resolved IPs differ from installed allow rules (netmask-normalized)" {
            $drift = InModuleScope Firewall {
                if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
                    function script:Get-NetFirewallRule { }
                }
                # Define the stub unconditionally so its permissive (no-param) signature
                # shadows the real Windows Get-NetFirewallAddressFilter cmdlet too. Otherwise
                # on Windows Pester mocks the real cmdlet's strict CimInstance pipeline
                # metadata, the `$rule | Get-NetFirewallAddressFilter` call (a PSCustomObject)
                # fails to bind, the address filter comes back empty, and drift detection
                # falsely fires -- the test passed on Linux (cmdlet absent) but failed on Windows.
                function script:Get-NetFirewallAddressFilter { }
                Mock Get-NetFirewallRule { @([PSCustomObject]@{ DisplayName = 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP' }) } -ModuleName Firewall
                Mock Get-NetFirewallAddressFilter { [PSCustomObject]@{ RemoteAddress = @('203.0.113.10/255.255.255.255') } } -ModuleName Firewall
                Test-OpenPathEgressFloorDrift -StaticAllowIps @('203.0.113.10', '203.0.113.99')
            }
            $drift.Drifted | Should -BeTrue
            @($drift.ResolvedIps) | Should -Contain '203.0.113.99'
        }
    }

    Context "Egress floor live resolution in Set-OpenPathFirewall (W-1(b))" {
        It "Resolves the floor live when enabled with no static allow-IP set, and fails open (no Block default) on empty resolution" {
            Initialize-FirewallRuleCaptureMocks
            $script:profileOutboundActions = @()
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $script:profileOutboundActions += $DefaultOutboundAction } -ModuleName Firewall
            Mock Test-Path { $false } -ModuleName Firewall -ParameterFilter { $Path -like '*egress-floor-prev-outbound.json' }
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ outboundEgressFloorEnabled = $true }
            } -ModuleName Firewall
            Mock Get-OpenPathEgressFloorAllowIps { @() } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue
            # Fail-open: no EgressFloor rules emitted and the outbound default is never Block.
            (@(Get-CapturedFirewallRules | Where-Object { $_.DisplayName -like '*EgressFloor*' })).Count | Should -Be 0
            @($script:profileOutboundActions) | Should -Not -Contain 'Block'
        }

        It "Resolves the floor live when enabled with no static allow-IP set and applies Allows + Block default when resolution yields IPs" {
            Initialize-FirewallRuleCaptureMocks
            $script:profileOutboundActions = @()
            if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Set-NetFirewallProfile { }
            }
            if (-not (Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
                function global:Get-NetFirewallProfile { }
            }
            Mock Get-NetFirewallProfile { param($Profile) [PSCustomObject]@{ DefaultOutboundAction = 'Allow' } } -ModuleName Firewall
            Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $script:profileOutboundActions += $DefaultOutboundAction } -ModuleName Firewall
            Mock Test-Path { $false } -ModuleName Firewall -ParameterFilter { $Path -like '*egress-floor-prev-outbound.json' }
            Mock Set-Content { } -ModuleName Firewall
            Mock New-Item { } -ModuleName Firewall
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{ outboundEgressFloorEnabled = $true }
            } -ModuleName Firewall
            Mock Get-OpenPathEgressFloorAllowIps { @('203.0.113.10') } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            $result | Should -BeTrue
            (@(Get-CapturedFirewallRules | Where-Object {
                        $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-Whitelist-203-0-113-10-TCP' -and $_.Action -eq 'Allow'
                    })).Count | Should -Be 1
            @($script:profileOutboundActions) | Should -Contain 'Block'
        }
    }

    Context "Student egress floor rule set" {
        BeforeAll {
            $script:sfSid = 'S-1-5-21-1-2-3-1005'
            $script:sfFirefox = 'C:\Program Files\Mozilla Firefox\firefox.exe'
            $script:sfNativeHost = 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.exe'
        }

        It "emits exactly the fixed rules plus one student allow per program" {
            $rules = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms @($script:sfFirefox, $script:sfNativeHost))
            $rules.Count | Should -Be 10
            foreach ($suffix in @(
                    'Allow-EgressFloor-NonStudent',
                    'Allow-EgressFloor-NonStudentAppContainers',
                    'Allow-EgressFloor-Loopback',
                    'Block-EgressFloor-StudentAppContainers',
                    'Block-EgressFloor-ICMPv4-Internet',
                    'Block-EgressFloor-ICMPv6-Internet',
                    'Block-EgressFloor-SMB-Internet',
                    'Block-EgressFloor-WebClient-Internet')) {
                @($rules | Where-Object { $_.DisplayName -eq "OpenPath-DNS-$suffix" }).Count | Should -Be 1 -Because $suffix
            }
            @($rules | Where-Object { $_.DisplayName -like 'OpenPath-DNS-Allow-EgressFloor-Student-*' }).Count | Should -Be 2
            @($rules | Where-Object { $_.Direction -ne 'Outbound' }).Count | Should -Be 0
        }

        It "scopes the non-student allow with a deny ACE for the restricted group" {
            $rules = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms @($script:sfFirefox))
            $nonStudent = @($rules | Where-Object { $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-NonStudent' })[0]
            $nonStudent.LocalUser | Should -Be "D:(D;;CC;;;$($script:sfSid))(A;;CC;;;WD)"
            $nonStudent.Action | Should -Be 'Allow'
            $student = @($rules | Where-Object { $_.DisplayName -like '*-Allow-EgressFloor-Student-*' })[0]
            $student.LocalUser | Should -Be "D:(A;;CC;;;$($script:sfSid))"
            $student.Program | Should -Be $script:sfFirefox
        }

        It "includes ALL APPLICATION PACKAGES in AppContainer rules" {
            $rules = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms @($script:sfFirefox))
            $containerRules = @($rules | Where-Object { $_.Package -eq '*' })
            $containerRules.Count | Should -Be 2
            foreach ($rule in $containerRules) { $rule.LocalUser | Should -Match '\(A;;CC;;;AC\)' }
            @($containerRules | Where-Object { $_.Action -eq 'Block' })[0].LocalUser | Should -Be "D:(A;;CC;;;$($script:sfSid))(A;;CC;;;AC)"
            @($containerRules | Where-Object { $_.Action -eq 'Allow' })[0].LocalUser | Should -Be "D:(D;;CC;;;$($script:sfSid))(A;;CC;;;WD)(A;;CC;;;AC)"
        }

        It "blocks ICMP, SMB and WebClient towards the Internet" {
            $rules = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms @())
            $byName = @{}; foreach ($rule in $rules) { $byName[$rule.DisplayName] = $rule }
            $byName['OpenPath-DNS-Block-EgressFloor-ICMPv4-Internet'].Protocol | Should -Be 'ICMPv4'
            $byName['OpenPath-DNS-Block-EgressFloor-ICMPv6-Internet'].Protocol | Should -Be 'ICMPv6'
            $byName['OpenPath-DNS-Block-EgressFloor-SMB-Internet'].Protocol | Should -Be 'TCP'
            @($byName['OpenPath-DNS-Block-EgressFloor-SMB-Internet'].RemotePort) | Should -Be @('139', '445')
            $byName['OpenPath-DNS-Block-EgressFloor-WebClient-Internet'].Service | Should -Be 'WebClient'
            foreach ($name in @('ICMPv4', 'ICMPv6', 'SMB', 'WebClient')) {
                $byName["OpenPath-DNS-Block-EgressFloor-$name-Internet"].RemoteAddress | Should -Be 'Internet'
            }
            @($byName['OpenPath-DNS-Allow-EgressFloor-Loopback'].RemoteAddress) | Should -Be @('127.0.0.0/8', '::1')
        }

        It "never allows the kernel System program" {
            $rules = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms @($script:sfFirefox, 'System'))
            @($rules | Where-Object { $_.Program -eq 'System' }).Count | Should -Be 0
        }

        It "derives distinct stable ids for two programs with the same file name" {
            $programs = @('C:\Program Files\GIMP 2\bin\python.exe', 'C:\Program Files\Inkscape\bin\python.exe')
            $first = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms $programs | Where-Object { $_.DisplayName -like '*-Student-*' } | ForEach-Object DisplayName)
            $second = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms $programs | Where-Object { $_.DisplayName -like '*-Student-*' } | ForEach-Object DisplayName)
            $first.Count | Should -Be 2
            $first[0] | Should -Not -Be $first[1]
            ($first -join '|') | Should -Be ($second -join '|')
            $first[0] | Should -Match '^OpenPath-DNS-Allow-EgressFloor-Student-python-[0-9a-f]{8}$'
        }

        It "deduplicates programs case-insensitively and drops blanks" {
            $rules = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $script:sfSid -StudentPrograms @($script:sfFirefox, $script:sfFirefox.ToUpperInvariant(), '', '  '))
            @($rules | Where-Object { $_.DisplayName -like '*-Student-*' }).Count | Should -Be 1
        }

        It "throws on a RestrictedSid that is not an S-1- SID" {
            { Get-OpenPathStudentEgressFloorRules -RestrictedSid 'BU' -StudentPrograms @() } | Should -Throw
            { Get-OpenPathStudentEgressFloorRules -RestrictedSid '' -StudentPrograms @() } | Should -Throw
        }
    }

    Context "Student network programs" {
        BeforeAll {
            $script:snInventory = [pscustomobject]@{
                ExecutableIdentities = @(
                    [pscustomobject]@{ Family = 'Firefox'; ExecutablePath = 'C:\Program Files\Mozilla Firefox\firefox.exe'; IsApproved = $true },
                    [pscustomobject]@{ Family = 'Chrome'; ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'; IsApproved = $true },
                    [pscustomobject]@{ Family = 'Firefox'; ExecutablePath = 'C:\Users\s\AppData\Local\Firefox\firefox.exe'; IsApproved = $false }
                )
            }
            $script:snNativeHost = 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.exe'
            function script:New-SnCatalog([object[]]$Applications) { [pscustomobject]@{ schemaVersion = 1; applications = @($Applications) } }
        }

        It "returns approved browser paths and the native host" {
            $programs = @(Get-OpenPathStudentNetworkPrograms -ApprovedBrowsers @('Firefox') -BrowserInventory $script:snInventory -OpenPathRoot 'C:\OpenPath')
            $programs | Should -Contain 'C:\Program Files\Mozilla Firefox\firefox.exe'
            $programs | Should -Contain $script:snNativeHost
            $programs | Should -Not -Contain 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            $programs | Should -Not -Contain 'C:\Users\s\AppData\Local\Firefox\firefox.exe'
        }

        It "adds catalog Path entries marked network true" {
            $catalog = New-SnCatalog @(
                [pscustomobject]@{ id = 'net'; network = $true; identity = [pscustomobject]@{ type = 'Path'; path = '%PROGRAMFILES%\Vendor\app.exe' } },
                [pscustomobject]@{ id = 'offline'; identity = [pscustomobject]@{ type = 'Path'; path = 'C:\Program Files\Other\tool.exe' } }
            )
            $programs = @(Get-OpenPathStudentNetworkPrograms -ApprovedBrowsers @('Firefox') -BrowserInventory $script:snInventory -ApplicationCatalog $catalog -OpenPathRoot 'C:\OpenPath')
            $programs | Should -Contain 'C:\Program Files\Vendor\app.exe'
            $programs | Should -Not -Contain 'C:\Program Files\Other\tool.exe'
        }

        It "ignores network true on Publisher and Hash identities with a WARN" {
            $catalog = New-SnCatalog @(
                [pscustomobject]@{ id = 'pub'; network = $true; identity = [pscustomobject]@{ type = 'Publisher'; publisherName = 'O=VENDOR'; productName = 'App'; binaryName = 'app.exe' } },
                [pscustomobject]@{ id = 'hash'; network = $true; identity = [pscustomobject]@{ type = 'Hash'; sha256 = ('ab' * 32); fileName = 'h.exe' } }
            )
            $result = InModuleScope Firewall -Parameters @{ Catalog = $catalog; Inventory = $script:snInventory } {
                param($Catalog, $Inventory)
                $warnings = New-Object System.Collections.Generic.List[string]
                Mock Write-OpenPathLog { param($Message, $Level) if ($Level -eq 'WARN') { $warnings.Add([string]$Message) } }
                $programs = @(Get-OpenPathStudentNetworkPrograms -ApprovedBrowsers @('Firefox') -BrowserInventory $Inventory -ApplicationCatalog $Catalog -OpenPathRoot 'C:\OpenPath')
                [pscustomobject]@{ Programs = $programs; Warnings = @($warnings) }
            }
            @($result.Programs).Count | Should -Be 2
            @($result.Warnings | Where-Object { $_ -match 'pub' }).Count | Should -Be 1
            @($result.Warnings | Where-Object { $_ -match 'hash' }).Count | Should -Be 1
        }

        It "ignores network true on a path outside Program Files" {
            $catalog = New-SnCatalog @([pscustomobject]@{ id = 'userpath'; network = $true; identity = [pscustomobject]@{ type = 'Path'; path = 'C:\Users\x\a.exe' } })
            $programs = @(Get-OpenPathStudentNetworkPrograms -ApprovedBrowsers @('Firefox') -BrowserInventory $script:snInventory -ApplicationCatalog $catalog -OpenPathRoot 'C:\OpenPath')
            $programs | Should -Not -Contain 'C:\Users\x\a.exe'
        }

        It "still returns the native host when no approved browser is installed" {
            $programs = @(Get-OpenPathStudentNetworkPrograms -ApprovedBrowsers @('Firefox') -BrowserInventory ([pscustomobject]@{ ExecutableIdentities = @() }) -OpenPathRoot 'C:\OpenPath')
            $programs | Should -Be @($script:snNativeHost)
        }
    }

    Context "Student egress floor apply, fail-open and drift" {
        BeforeAll {
            foreach ($name in @('Set-NetFirewallProfile', 'Get-NetFirewallProfile', 'Get-NetFirewallRule', 'Get-NetFirewallSecurityFilter')) {
                if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
                    New-Item -Path "Function:\global:$name" -Value { param([Parameter(ValueFromPipeline = $true)]$InputObject, $Profile, $DefaultOutboundAction, $DisplayName, $ErrorAction) } -Force | Out-Null
                }
            }
            $script:sfaSid = 'S-1-5-21-1-2-3-1005'
            $script:sfaPrograms = @('C:\Program Files\Mozilla Firefox\firefox.exe')
        }

        It "fails open when the restricted group cannot be resolved" {
            $outcome = InModuleScope Firewall -Parameters @{ Programs = $script:sfaPrograms } {
                param($Programs)
                $events = New-Object System.Collections.Generic.List[string]
                Mock Write-OpenPathLog { }
                Mock Resolve-OpenPathEgressFloorRestrictedSid { throw 'OpenPath-Restricted group could not be resolved' }
                Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $events.Add("profile:$DefaultOutboundAction") }
                Mock Remove-OpenPathEgressFloorRules { param($RulePrefix, $RestoreDefaultOutbound) $events.Add("remove:$RestoreDefaultOutbound") }
                Mock New-OpenPathFirewallRule { $events.Add('create') }
                $count = Set-OpenPathStudentEgressFloor -StudentPrograms $Programs
                [pscustomobject]@{ Count = $count; Events = @($events) }
            }
            $outcome.Count | Should -Be 0
            @($outcome.Events) | Should -Not -Contain 'profile:Block'
            @($outcome.Events) | Should -Not -Contain 'create'
            @($outcome.Events) | Should -Contain 'remove:True'
        }

        It "saves the previous outbound default before creating rules and setting Block" {
            $outcome = InModuleScope Firewall -Parameters @{ Sid = $script:sfaSid; Programs = $script:sfaPrograms } {
                param($Sid, $Programs)
                $events = New-Object System.Collections.Generic.List[string]
                Mock Write-OpenPathLog { }
                Mock Resolve-OpenPathEgressFloorRestrictedSid { $Sid }
                Mock Save-OpenPathEgressFloorPreviousOutbound { $events.Add('save') }
                Mock Remove-OpenPathEgressFloorRules { param($RulePrefix, $RestoreDefaultOutbound) $events.Add("remove:$RestoreDefaultOutbound") }
                Mock New-OpenPathFirewallRule { $events.Add('create') }
                Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $events.Add("profile:$DefaultOutboundAction") }
                $count = Set-OpenPathStudentEgressFloor -StudentPrograms $Programs
                [pscustomobject]@{ Count = $count; Events = @($events) }
            }
            $outcome.Count | Should -Be 9
            $events = @($outcome.Events)
            $events[0] | Should -Be 'save'
            $events[1] | Should -Be 'remove:False'
            @($events | Where-Object { $_ -eq 'create' }).Count | Should -Be 9
            $events[-1] | Should -Be 'profile:Block'
        }

        It "passes LocalUser, Package and Service through to New-NetFirewallRule" {
            Initialize-FirewallRuleCaptureMocks
            InModuleScope Firewall -Parameters @{ Sid = $script:sfaSid; Programs = $script:sfaPrograms } {
                param($Sid, $Programs)
                Mock Resolve-OpenPathEgressFloorRestrictedSid { $Sid }
                Mock Save-OpenPathEgressFloorPreviousOutbound { }
                Mock Remove-OpenPathEgressFloorRules { }
                Mock Add-OpenPathFirewallManifestRule { }
                Mock Set-NetFirewallProfile { }
                Set-OpenPathStudentEgressFloor -StudentPrograms $Programs | Out-Null
            }
            $captured = @(Get-CapturedFirewallRules)
            @($captured | Where-Object { $_.DisplayName -eq 'OpenPath-DNS-Allow-EgressFloor-NonStudent' })[0].LocalUser | Should -Be "D:(D;;CC;;;$($script:sfaSid))(A;;CC;;;WD)"
            @($captured | Where-Object { $_.DisplayName -eq 'OpenPath-DNS-Block-EgressFloor-StudentAppContainers' })[0].Package | Should -Be '*'
            @($captured | Where-Object { $_.DisplayName -eq 'OpenPath-DNS-Block-EgressFloor-WebClient-Internet' })[0].Service | Should -Be 'WebClient'
        }

        It "tears down with restore when a rule creation throws" {
            $outcome = InModuleScope Firewall -Parameters @{ Sid = $script:sfaSid; Programs = $script:sfaPrograms } {
                param($Sid, $Programs)
                $events = New-Object System.Collections.Generic.List[string]
                Mock Write-OpenPathLog { }
                Mock Resolve-OpenPathEgressFloorRestrictedSid { $Sid }
                Mock Save-OpenPathEgressFloorPreviousOutbound { }
                Mock Remove-OpenPathEgressFloorRules { param($RulePrefix, $RestoreDefaultOutbound) $events.Add("remove:$RestoreDefaultOutbound") }
                Mock New-OpenPathFirewallRule { throw 'The parameter is incorrect.' }
                Mock Set-NetFirewallProfile { param($Profile, $DefaultOutboundAction) $events.Add("profile:$DefaultOutboundAction") }
                $count = Set-OpenPathStudentEgressFloor -StudentPrograms $Programs
                [pscustomobject]@{ Count = $count; Events = @($events) }
            }
            $outcome.Count | Should -Be 0
            @($outcome.Events) | Should -Not -Contain 'profile:Block'
            @($outcome.Events)[-1] | Should -Be 'remove:True'
        }

        It "does not overwrite an existing pre-floor state file on upgrade" {
            $written = InModuleScope Firewall -Parameters @{ Sid = $script:sfaSid; Programs = $script:sfaPrograms } {
                param($Sid, $Programs)
                $writes = New-Object System.Collections.Generic.List[string]
                Mock Write-OpenPathLog { }
                Mock Resolve-OpenPathEgressFloorRestrictedSid { $Sid }
                Mock Test-Path { $true }
                Mock Set-Content { param($Path) $writes.Add([string]$Path) }
                Mock Remove-OpenPathEgressFloorRules { }
                Mock New-OpenPathFirewallRule { }
                Mock Set-NetFirewallProfile { }
                Mock Get-NetFirewallProfile { [pscustomobject]@{ DefaultOutboundAction = 'Block' } }
                Set-OpenPathStudentEgressFloor -StudentPrograms $Programs | Out-Null
                @($writes)
            }
            @($written | Where-Object { $_ -like '*egress-floor-prev-outbound.json' }).Count | Should -Be 0
        }

        It "reports drift when a profile default is Allow" {
            $drift = InModuleScope Firewall -Parameters @{ Sid = $script:sfaSid; Programs = $script:sfaPrograms } {
                param($Sid, $Programs)
                $expected = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $Sid -StudentPrograms $Programs)
                Mock Resolve-OpenPathEgressFloorRestrictedSid { $Sid }
                Mock Get-NetFirewallProfile { [pscustomobject]@{ DefaultOutboundAction = 'Allow' } }
                Mock Get-NetFirewallRule { $expected | ForEach-Object { [pscustomobject]@{ DisplayName = $_.DisplayName } } }
                Mock Get-NetFirewallSecurityFilter { [pscustomobject]@{ LocalUser = "D:(D;;CC;;;$Sid)(A;;CC;;;WD)" } }
                Test-OpenPathStudentEgressFloorDrift -StudentPrograms $Programs
            }
            $drift.Drifted | Should -BeTrue
            $drift.Reason | Should -Be 'default-outbound-not-block'
        }

        It "reports drift when a student program rule is missing" {
            $drift = InModuleScope Firewall -Parameters @{ Sid = $script:sfaSid; Programs = $script:sfaPrograms } {
                param($Sid, $Programs)
                $expected = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $Sid -StudentPrograms $Programs)
                Mock Resolve-OpenPathEgressFloorRestrictedSid { $Sid }
                Mock Get-NetFirewallProfile { [pscustomobject]@{ DefaultOutboundAction = 'Block' } }
                Mock Get-NetFirewallRule { $expected | Where-Object { $_.DisplayName -notlike '*-Student-*' } | ForEach-Object { [pscustomobject]@{ DisplayName = $_.DisplayName } } }
                Mock Get-NetFirewallSecurityFilter { [pscustomobject]@{ LocalUser = "D:(D;;CC;;;$Sid)(A;;CC;;;WD)" } }
                Test-OpenPathStudentEgressFloorDrift -StudentPrograms $Programs
            }
            $drift.Drifted | Should -BeTrue
            $drift.Reason | Should -Be 'rule-set-mismatch'
        }

        It "reports no drift when the installed set equals the expected set" {
            $drift = InModuleScope Firewall -Parameters @{ Sid = $script:sfaSid; Programs = $script:sfaPrograms } {
                param($Sid, $Programs)
                $expected = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $Sid -StudentPrograms $Programs)
                Mock Resolve-OpenPathEgressFloorRestrictedSid { $Sid }
                Mock Get-NetFirewallProfile { [pscustomobject]@{ DefaultOutboundAction = 'Block' } }
                Mock Get-NetFirewallRule { $expected | ForEach-Object { [pscustomobject]@{ DisplayName = $_.DisplayName } } }
                Mock Get-NetFirewallSecurityFilter { [pscustomobject]@{ LocalUser = "D:(D;;CC;;;$Sid)(A;;CC;;;WD)" } }
                Test-OpenPathStudentEgressFloorDrift -StudentPrograms $Programs
            }
            $drift.Drifted | Should -BeFalse
        }

        It "reports no drift when the group is unresolvable and no floor is installed" {
            $drift = InModuleScope Firewall {
                Mock Resolve-OpenPathEgressFloorRestrictedSid { throw 'missing' }
                Mock Get-NetFirewallProfile { [pscustomobject]@{ DefaultOutboundAction = 'Allow' } }
                Mock Get-NetFirewallRule { @() }
                Test-OpenPathStudentEgressFloorDrift -StudentPrograms @()
            }
            $drift.Drifted | Should -BeFalse
            $drift.Reason | Should -Be 'restricted-group-unresolved'
        }
    }
}
