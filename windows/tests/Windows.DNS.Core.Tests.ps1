Describe "DNS Module" {
    BeforeAll {
        function Assert-IsAsciiEncoding {
            param([object]$Encoding)

            $Encoding | Should -Not -BeNullOrEmpty
            if ($Encoding -is [System.Text.Encoding]) {
                $Encoding.WebName | Should -Be 'us-ascii'
                return
            }

            ([string]$Encoding) | Should -Match 'ASCII'
        }

        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\DNS.psm1" -Force -ErrorAction SilentlyContinue
    }

    Context "Test-AcrylicInstalled" {
        It "Returns a boolean value" -Skip:(-not (Test-FunctionExists 'Test-AcrylicInstalled')) {
            $result = Test-AcrylicInstalled
            $result | Should -BeOfType [bool]
        }
    }

    Context "Get-AcrylicPath" {
        It "Returns null or valid path" -Skip:(-not (Test-FunctionExists 'Get-AcrylicPath')) {
            $path = Get-AcrylicPath
            if ($path) {
                Test-Path $path | Should -BeTrue
            } else {
                $path | Should -BeNullOrEmpty
            }
        }
    }

    Context "Test-DNSResolution" {
        It "Uses the first allowed probe domain when no explicit domain is provided" {
            Mock Get-OpenPathDnsProbeDomains { @('safe.example', 'fallback.example') } -ModuleName DNS
            Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '203.0.113.10' }) } -ModuleName DNS -ParameterFilter { $Name -eq 'safe.example' -and $Server -eq '127.0.0.1' }
            Mock Start-Sleep { } -ModuleName DNS

            InModuleScope DNS {
                (Test-DNSResolution -MaxAttempts 1) | Should -BeTrue
                Assert-MockCalled Resolve-DnsName -ModuleName DNS -Times 1 -Exactly -ParameterFilter { $Name -eq 'safe.example' -and $Server -eq '127.0.0.1' }
            }
        }
    }

    Context "Get-OpenPathDnsSettings" {
        It "Returns safe defaults when OpenPath config is unavailable" {
            Mock Get-OpenPathConfig { throw 'config unavailable' } -ModuleName DNS

            InModuleScope DNS {
                $settings = Get-OpenPathDnsSettings

                $settings.PrimaryDNS | Should -Be '8.8.8.8'
                $settings.SecondaryDNS | Should -Be '8.8.4.4'
                $settings.MaxDomains | Should -Be 500
            }
        }

        It "Honors DNS-related overrides from OpenPath config" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    primaryDNS = '1.1.1.1'
                    secondaryDNS = '1.0.0.1'
                    maxDomains = 42
                }
            } -ModuleName DNS

            InModuleScope DNS {
                $settings = Get-OpenPathDnsSettings

                $settings.PrimaryDNS | Should -Be '1.1.1.1'
                $settings.SecondaryDNS | Should -Be '1.0.0.1'
                $settings.MaxDomains | Should -Be 42
            }
        }
    }

    Context "Update-AcrylicHost" {
        BeforeEach {
            Mock Get-OpenPathProtectedDomains { @('raw.githubusercontent.com') } -ModuleName DNS
        }

        It "Generates valid hosts content" -Skip:(-not ((Test-FunctionExists 'Test-AcrylicInstalled') -and (Test-FunctionExists 'Update-AcrylicHost') -and (Test-AcrylicInstalled))) {
            $result = Update-AcrylicHost -WhitelistedDomains @("example.com", "test.com") -BlockedSubdomains @()
            $result | Should -BeTrue
        }

        It "Builds Acrylic hosts content from a generated definition in official FW/sinkhole order" {
            InModuleScope DNS {
                $definition = New-AcrylicHostsDefinition `
                    -WhitelistedDomains @('example.com', 'test.com') `
                    -BlockedSubdomains @('ads.other-example.com') `
                    -DnsSettings ([PSCustomObject]@{
                        PrimaryDNS = '1.1.1.1'
                        SecondaryDNS = '1.0.0.1'
                        MaxDomains = 10
                    })

                $content = ConvertTo-AcrylicHostsContent -Definition $definition

                $expectedNeedles = @(
                    '# ESSENTIAL DOMAINS (always allowed)',
                    'FW raw.githubusercontent.com',
                    'FW >raw.githubusercontent.com',
                    '# BLOCKED SUBDOMAINS (1)',
                    'NX >ads.other-example.com',
                    '# WHITELISTED DOMAINS (2)',
                    'FW example.com',
                    'FW >example.com',
                    'FW test.com',
                    'FW >test.com',
                    '# DEFAULT BLOCK (NXDOMAIN for everything else)',
                    '# This MUST come last after FW rules.',
                    '# Upstream DNS: 1.1.1.1',
                    'NX *'
                )

                foreach ($needle in $expectedNeedles) {
                    $content.Contains($needle) | Should -BeTrue -Because "Expected generated hosts content to include '$needle'"
                }

                $content | Should -Not -Match 'FORWARD >'
                $content | Should -Not -Match 'NX >\*'

                $whitelistSectionIndex = $content.IndexOf('# WHITELISTED DOMAINS')
                $defaultBlockRuleIndex = $content.IndexOf('NX *')
                $whitelistSectionIndex | Should -BeGreaterThan -1
                $defaultBlockRuleIndex | Should -BeGreaterThan $whitelistSectionIndex

                @($definition.EffectiveWhitelistedDomains).Count | Should -Be 2
                $definition.WasTruncated | Should -BeFalse
            }
        }

        It "Keeps blocked descendants ahead of a whitelisted parent wildcard" {
            InModuleScope DNS {
                $definition = New-AcrylicHostsDefinition `
                    -WhitelistedDomains @('example.com') `
                    -BlockedSubdomains @('ads.example.com') `
                    -DnsSettings ([PSCustomObject]@{
                        PrimaryDNS = '1.1.1.1'
                        SecondaryDNS = '1.0.0.1'
                        MaxDomains = 10
                    })

                $content = ConvertTo-AcrylicHostsContent -Definition $definition
                $lines = @($content -split "`n")
                $regexForwardRules = @(
                    $lines | Where-Object {
                        $_.StartsWith('FW /^') -and
                        $_.Contains('ads\.example\.com') -and
                        $_.Contains('example\.com$')
                    }
                )
                $regexRule = $regexForwardRules[0]
                $regexPattern = $regexRule.Substring(4).TrimStart('/').Replace('\\', '\')

                $content.Contains('FW example.com') | Should -BeTrue
                $content.Contains('NX >ads.example.com') | Should -BeTrue
                $content.Contains('FW >example.com') | Should -BeFalse
                $regexRule | Should -Not -Match '\\\\\.'
                $regexForwardRules.Count | Should -Be 1
                'www.example.com' | Should -Match $regexPattern
                'ads.example.com' | Should -Not -Match $regexPattern
                'cdn.ads.example.com' | Should -Not -Match $regexPattern
            }
        }

        It "Renders runtime dependency overlay entries as exact hosts before the default block" {
            InModuleScope DNS {
                $definition = New-AcrylicHostsDefinition `
                    -WhitelistedDomains @('allowed.example') `
                    -BlockedSubdomains @('blocked.cdn.example') `
                    -RuntimeDependencyDomains @('cdn.example', 'blocked.cdn.example') `
                    -DnsSettings ([PSCustomObject]@{
                        PrimaryDNS = '1.1.1.1'
                        SecondaryDNS = '1.0.0.1'
                        MaxDomains = 10
                    })

                $content = ConvertTo-AcrylicHostsContent -Definition $definition

                $content | Should -Match '# LOCAL RUNTIME DEPENDENCIES \(1\)'
                $content | Should -Match '(?m)^FW cdn\.example$'
                $content | Should -Not -Match 'FW >cdn\.example'
                $content | Should -Not -Match '(?m)^FW blocked\.cdn\.example$'

                $overlayRuleIndex = $content.IndexOf('FW cdn.example')
                $defaultBlockRuleIndex = $content.IndexOf('NX *')
                $overlayRuleIndex | Should -BeGreaterThan -1
                $defaultBlockRuleIndex | Should -BeGreaterThan $overlayRuleIndex
                $definition.DomainAffinityMask | Should -Match 'cdn\.example'
            }
        }

        It "Keeps runtime dependency overlays for anchors covered by a whitelisted parent domain" {
            $previousOverlayPath = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
            $overlayPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-runtime-overlay-" + [Guid]::NewGuid().ToString("N") + ".json")

            try {
                $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = $overlayPath
                @{
                    version = 1
                    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    entries = @(
                        @{
                            dependencyHost = 'www.redditstatic.com'
                            anchorHost = 'www.reddit.com'
                            requestTypes = @('script')
                            firstSeen = (Get-Date).ToUniversalTime().ToString('o')
                            lastSeen = (Get-Date).ToUniversalTime().ToString('o')
                            expiresAt = (Get-Date).ToUniversalTime().AddDays(1).ToString('o')
                            source = 'firefox-webrequest-local'
                        }
                    )
                } | ConvertTo-Json -Depth 8 | Set-Content $overlayPath -Encoding UTF8 -Force

                InModuleScope DNS {
                    $domains = Get-OpenPathRuntimeDependencyDomains `
                        -WhitelistedDomains @('reddit.com') `
                        -BlockedSubdomains @() `
                        -Prune

                    $domains | Should -Contain 'www.redditstatic.com'
                }
            }
            finally {
                if ($null -eq $previousOverlayPath) {
                    Remove-Item Env:\OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH -ErrorAction SilentlyContinue
                }
                else {
                    $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = $previousOverlayPath
                }
                Remove-Item $overlayPath -Force -ErrorAction SilentlyContinue
            }
        }

        It "Resolves sslip.io fixture domains locally without relying on upstream DNS" {
            InModuleScope DNS {
                $definition = New-AcrylicHostsDefinition `
                    -WhitelistedDomains @('portal.127.0.0.1.sslip.io', 'site.10.20.30.40.sslip.io') `
                    -DnsSettings ([PSCustomObject]@{
                        PrimaryDNS = '1.1.1.1'
                        SecondaryDNS = '1.0.0.1'
                        MaxDomains = 10
                    })

                $content = ConvertTo-AcrylicHostsContent -Definition $definition

                $content | Should -Match '127\.0\.0\.1 portal\.127\.0\.0\.1\.sslip\.io'
                $content | Should -Match '127\.0\.0\.1 >portal\.127\.0\.0\.1\.sslip\.io'
                $content | Should -Match '10\.20\.30\.40 site\.10\.20\.30\.40\.sslip\.io'
                $content | Should -Not -Match 'FW portal\.127\.0\.0\.1\.sslip\.io'
            }
        }

        It "Keeps Acrylic hosts modeling and rendering split into helpers" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "DNS.psm1"
            $configPath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Config.ps1"
            $moduleContent = Get-Content $modulePath -Raw
            $configContent = Get-Content $configPath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                "DNS.Acrylic.Install.ps1",
                "DNS.Acrylic.Config.ps1",
                "DNS.Acrylic.Service.ps1",
                "DNS.Diagnostics.ps1"
            )

            Assert-ContentContainsAll -Content $configContent -Needles @(
                'function Get-OpenPathDnsSettings',
                "'NX *'",
                'function Get-AcrylicForwardRules',
                'function New-AcrylicHostsDefinition',
                'function ConvertTo-AcrylicHostsContent',
                '$definition = New-AcrylicHostsDefinition',
                '$content = ConvertTo-AcrylicHostsContent -Definition $definition',
                '"FW $normalizedDomain"',
                '"FW >$normalizedDomain"'
            )

            $configContent | Should -Not -Match '\$content = @"'
        }

        It "Retries Acrylic DNS resolution before reporting failure" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Diagnostics.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Resolve-OpenPathDnsWithRetry',
                '[int]$MaxAttempts = 12',
                'Start-Sleep -Milliseconds $DelayMilliseconds',
                'Resolve-OpenPathDnsWithRetry',
                'Write-OpenPathLog "DNS resolution failed'
            )
        }

        It "Configures Acrylic to ignore upstream negative responses while keeping hosts policy enabled" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Config.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '"IgnoreNegativeResponsesFromPrimaryServer" = "No"',
                '"IgnoreNegativeResponsesFromSecondaryServer" = "No"',
                '"AddressCacheDisabled" = "No"',
                '"AddressCacheNegativeTime" = "0"'
            )
            $content | Should -Not -Match '"AddressCacheDisabled"\s*=\s*"Yes"'
        }

        It "Limits Acrylic upstream affinity masks to essential and whitelisted domains" {
            $script:capturedAcrylicConfig = $null
            $script:capturedAcrylicConfigEncoding = $null

            Mock Get-AcrylicPath { 'C:\Program Files (x86)\Acrylic DNS Proxy' } -ModuleName DNS
            Mock Get-OpenPathDnsSettings {
                [PSCustomObject]@{
                    PrimaryDNS = '1.1.1.1'
                    SecondaryDNS = '1.0.0.1'
                    MaxDomains = 10
                }
            } -ModuleName DNS
            Mock Test-Path { $false } -ModuleName DNS -ParameterFilter { $Path -like '*AcrylicConfiguration.ini' }
            Mock Set-Content {
                param(
                    [string]$Path,
                    [string]$Value,
                    [string]$Encoding,
                    [switch]$Force
                )

                if ($Path -like '*AcrylicConfiguration.ini') {
                    $script:capturedAcrylicConfig = $Value
                    $script:capturedAcrylicConfigEncoding = $Encoding
                }
            } -ModuleName DNS

            $result = Set-AcrylicConfiguration -WhitelistedDomains @('example.com', 'test.com')

            $result | Should -BeTrue
            $script:capturedAcrylicConfig | Should -Not -BeNullOrEmpty
            Assert-ContentContainsAll -Content $script:capturedAcrylicConfig -Needles @(
                '[GlobalSection]',
                'PrimaryServerDomainNameAffinityMask=raw.githubusercontent.com;*.raw.githubusercontent.com',
                'SecondaryServerDomainNameAffinityMask=raw.githubusercontent.com;*.raw.githubusercontent.com',
                'example.com;*.example.com',
                'test.com;*.test.com',
                'PrimaryServerPort=53',
                'PrimaryServerProtocol=UDP',
                'SecondaryServerPort=53',
                'SecondaryServerProtocol=UDP',
                'LocalIPv4BindingAddress=0.0.0.0',
                'LocalIPv6BindingAddress=',
                '[AllowedAddressesSection]',
                'IP1=127.*',
                'IP2=::1',
                'IgnoreNegativeResponsesFromPrimaryServer=No',
                'IgnoreNegativeResponsesFromSecondaryServer=No',
                'AddressCacheDisabled=No'
            )
            Assert-IsAsciiEncoding $script:capturedAcrylicConfigEncoding
            $script:capturedAcrylicConfig | Should -Not -Match 'PrimaryServerDomainNameAffinityMask=.*blocked\.127\.0\.0\.1\.sslip\.io'
            $script:capturedAcrylicConfig | Should -Not -Match 'SecondaryServerDomainNameAffinityMask=.*blocked\.127\.0\.0\.1\.sslip\.io'
        }

        It "Allows install-time Acrylic configuration before any classroom whitelist exists" {
            $script:capturedAcrylicConfig = $null

            Mock Get-AcrylicPath { 'C:\Program Files (x86)\Acrylic DNS Proxy' } -ModuleName DNS
            Mock Get-OpenPathDnsSettings {
                [PSCustomObject]@{
                    PrimaryDNS = '1.1.1.1'
                    SecondaryDNS = '1.0.0.1'
                    MaxDomains = 10
                }
            } -ModuleName DNS
            Mock Test-Path { $false } -ModuleName DNS -ParameterFilter { $Path -like '*AcrylicConfiguration.ini' }
            Mock Set-Content {
                param(
                    [string]$Path,
                    [string]$Value,
                    [string]$Encoding,
                    [switch]$Force
                )

                if ($Path -like '*AcrylicConfiguration.ini') {
                    $script:capturedAcrylicConfig = $Value
                }
            } -ModuleName DNS

            $result = Set-AcrylicConfiguration

            $result | Should -BeTrue
            $script:capturedAcrylicConfig | Should -Not -BeNullOrEmpty
            Assert-ContentContainsAll -Content $script:capturedAcrylicConfig -Needles @(
                '[GlobalSection]',
                'PrimaryServerDomainNameAffinityMask=raw.githubusercontent.com;*.raw.githubusercontent.com',
                'PrimaryServerPort=53',
                'PrimaryServerProtocol=UDP',
                'LocalIPv4BindingAddress=0.0.0.0',
                '[AllowedAddressesSection]',
                'IP1=127.*',
                'IP2=::1',
                'IgnoreNegativeResponsesFromPrimaryServer=No',
                'AddressCacheDisabled=No'
            )
            $script:capturedAcrylicConfig | Should -Not -Match 'example\.com;'
            $script:capturedAcrylicConfig | Should -Match 'PrimaryServerDomainNameAffinityMask=.*raw\.githubusercontent\.com'
        }

        It "Allows updating Acrylic hosts before any classroom whitelist exists" {
            $script:capturedAcrylicConfig = $null
            $script:capturedHostsContent = $null
            $script:capturedHostsEncoding = $null

            Mock Get-AcrylicPath { 'C:\Program Files (x86)\Acrylic DNS Proxy' } -ModuleName DNS
            Mock Get-OpenPathDnsSettings {
                [PSCustomObject]@{
                    PrimaryDNS = '1.1.1.1'
                    SecondaryDNS = '1.0.0.1'
                    MaxDomains = 10
                }
            } -ModuleName DNS
            Mock Test-Path { $false } -ModuleName DNS
            Mock Set-Content {
                param(
                    [string]$Path,
                    [string]$Value,
                    [string]$Encoding,
                    [switch]$Force
                )

                if ($Path -like '*AcrylicConfiguration.ini') {
                    $script:capturedAcrylicConfig = $Value
                }

                if ($Path -like '*AcrylicHosts.txt') {
                    $script:capturedHostsContent = $Value
                    $script:capturedHostsEncoding = $Encoding
                }
            } -ModuleName DNS

            $result = Update-AcrylicHost -WhitelistedDomains @() -BlockedSubdomains @()

            $result | Should -BeTrue
            $script:capturedHostsContent | Should -Not -BeNullOrEmpty
            $script:capturedHostsContent | Should -Match '# WHITELISTED DOMAINS \(0\)'
            $script:capturedHostsContent | Should -Match 'NX \*'
            $script:capturedHostsContent | Should -Not -Match 'FW example\.com'
            Assert-IsAsciiEncoding $script:capturedHostsEncoding
            $script:capturedAcrylicConfig | Should -Not -BeNullOrEmpty
            Assert-ContentContainsAll -Content $script:capturedAcrylicConfig -Needles @(
                'PrimaryServerDomainNameAffinityMask=raw.githubusercontent.com;*.raw.githubusercontent.com',
                'IgnoreNegativeResponsesFromPrimaryServer=No',
                'AddressCacheDisabled=No'
            )
        }

        It "Always includes configured control-plane domains in the essential Acrylic allowlist" {
            InModuleScope DNS {
                Mock Get-OpenPathProtectedDomains { @('control.example', 'downloads.example', 'raw.githubusercontent.com') }

                $definition = New-AcrylicHostsDefinition `
                    -WhitelistedDomains @('safe.example') `
                    -DnsSettings ([PSCustomObject]@{
                        PrimaryDNS = '1.1.1.1'
                        SecondaryDNS = '1.0.0.1'
                        MaxDomains = 10
                    })

                $content = ConvertTo-AcrylicHostsContent -Definition $definition

                $content | Should -Match 'FW control\.example'
                $content | Should -Match 'FW downloads\.example'
                $definition.DomainAffinityMask | Should -Match 'control\.example;\*\.control\.example'
                $definition.DomainAffinityMask | Should -Match 'downloads\.example;\*\.downloads\.example'
            }
        }

        It "Purges AcrylicCache.dat before restarting the service" {
            $script:removedAcrylicPaths = @()

            Mock Get-AcrylicPath { 'C:\Program Files (x86)\Acrylic DNS Proxy' } -ModuleName DNS
            Mock Test-Path {
                param([string]$Path)

                return ($Path -like '*AcrylicCache.dat')
            } -ModuleName DNS
            Mock Remove-Item {
                param(
                    [string]$Path,
                    [switch]$Force,
                    [object]$ErrorAction
                )

                $script:removedAcrylicPaths += $Path
            } -ModuleName DNS
            Mock Get-Service {
                [PSCustomObject]@{
                    Name = 'AcrylicDNSProxySvc'
                    Status = 'Running'
                }
            } -ModuleName DNS
            Mock Restart-Service { } -ModuleName DNS
            Mock Start-Sleep { } -ModuleName DNS

            $result = Restart-AcrylicService

            $result | Should -BeTrue
            $script:removedAcrylicPaths | Should -Contain 'C:\Program Files (x86)\Acrylic DNS Proxy\AcrylicCache.dat'
        }
    }

    Context "Protected mode restore" {
        It "Reasserts local DNS after browser policy work during whitelist apply" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $content = Get-Content $scriptPath -Raw

            $policyIndex = $content.IndexOf('Set-AllBrowserPolicy -BlockedPaths $Whitelist.BlockedPaths -Config $Config')
            $restoreIndex = $content.IndexOf('Restore-OpenPathProtectedMode -Config $Config -SkipAcrylicRestart')
            $healthIndex = $content.IndexOf('$runtimeHealth = Get-OpenPathRuntimeHealth', $restoreIndex)

            $policyIndex | Should -BeGreaterThan -1
            $restoreIndex | Should -BeGreaterThan $policyIndex
            $healthIndex | Should -BeGreaterThan $restoreIndex
        }
    }
}
