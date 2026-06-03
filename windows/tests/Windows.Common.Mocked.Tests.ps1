Describe "Common Module - Mocked Tests" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\Common.psm1" -Force
        InModuleScope Common {
            if (-not (Get-Command -Name 'Update-AcrylicHost' -ErrorAction SilentlyContinue)) {
                function script:Update-AcrylicHost {
                    return $true
                }
            }
            if (-not (Get-Command -Name 'Restart-AcrylicService' -ErrorAction SilentlyContinue)) {
                function script:Restart-AcrylicService {
                    return $true
                }
            }
            if (-not (Get-Command -Name 'Get-AcrylicPath' -ErrorAction SilentlyContinue)) {
                function script:Get-AcrylicPath {
                    return $null
                }
            }
            if (-not (Get-Command -Name 'Set-OpenPathFirewall' -ErrorAction SilentlyContinue)) {
                function script:Set-OpenPathFirewall {
                    return $true
                }
            }
            if (-not (Get-Command -Name 'Set-LocalDNS' -ErrorAction SilentlyContinue)) {
                function script:Set-LocalDNS {
                }
            }
            if (-not (Get-Command -Name 'Enable-OpenPathFirewall' -ErrorAction SilentlyContinue)) {
                function script:Enable-OpenPathFirewall {
                    return $true
                }
            }
            if (-not (Get-Command -Name 'Get-DnsClientServerAddress' -ErrorAction SilentlyContinue)) {
                function script:Get-DnsClientServerAddress {
                    param(
                        [int]$InterfaceIndex,
                        [string]$AddressFamily,
                        [object]$ErrorAction
                    )
                }
            }
            if (-not (Get-Command -Name 'Get-NetRoute' -ErrorAction SilentlyContinue)) {
                function script:Get-NetRoute {
                    param(
                        [string]$DestinationPrefix,
                        [int]$InterfaceIndex,
                        [object]$ErrorAction
                    )
                }
            }
            if (-not (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue)) {
                function script:Get-NetAdapter {
                    param([object]$ErrorAction)
                }
            }
            if (-not (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue)) {
                function script:Resolve-DnsName {
                    param(
                        [string]$Name,
                        [string]$Server,
                        [switch]$DnsOnly,
                        [object]$ErrorAction
                    )
                }
            }
        }
    }

    Context "Get-OpenPathFromUrl parsing" {
        It "Parses whitelist sections correctly" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content    = "domain1.com`ndomain2.com`ndomain3.com`n## BLOCKED-SUBDOMAINS`nbad.domain.com`n## BLOCKED-PATHS`n/blocked/path"
                    ETag       = $null
                }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.Whitelist.Count | Should -BeGreaterOrEqual 3
            $result.Whitelist[0] | Should -Be "domain1.com"
            $result.Whitelist | Should -Contain "domain2.com"
            $result.Whitelist | Should -Contain "domain3.com"
            $result.BlockedSubdomains | Should -HaveCount 1
            $result.BlockedSubdomains[0] | Should -Be "bad.domain.com"
            $result.BlockedPaths | Should -HaveCount 1
        }

        It "Detects #DESACTIVADO marker" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{ StatusCode = 200; Content = "#DESACTIVADO`ndomain1.com`ndomain2.com`ndomain3.com"; ETag = $null }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.IsDisabled | Should -BeTrue
        }

        It "Accepts disabled whitelist even without minimum domains" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{ StatusCode = 200; Content = "#DESACTIVADO"; ETag = $null }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.IsDisabled | Should -BeTrue
            $result.Whitelist | Should -HaveCount 0
        }

        It "Skips comment lines and empty lines" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content    = "# comment`n`ndomain1.com`ndomain2.com`ndomain3.com`n# another comment"
                    ETag       = $null
                }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.Whitelist.Count | Should -BeGreaterOrEqual 3
            $result.Whitelist | Should -Contain "domain1.com"
            $result.Whitelist | Should -Contain "domain2.com"
            $result.Whitelist | Should -Contain "domain3.com"
        }

        It "Accepts structured whitelist with a single valid domain" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content    = "## WHITELIST`nsingle-domain.example"
                    ETag       = $null
                }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.IsDisabled | Should -BeFalse
            $result.Whitelist.Count | Should -BeGreaterOrEqual 1
            $result.Whitelist | Should -Contain "single-domain.example"
        }

        It "Falls back to protected domains when whitelist has insufficient valid domains" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{ StatusCode = 200; Content = "not-a-domain"; ETag = $null }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.Whitelist.Count | Should -BeGreaterOrEqual 1
            $result.Whitelist | Should -Contain "github.com"
            $result.Whitelist | Should -Not -Contain "not-a-domain"
        }

        It "Handles empty response content by retaining protected domains" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{ StatusCode = 200; Content = ""; ETag = $null }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.Whitelist.Count | Should -BeGreaterOrEqual 1
            $result.Whitelist | Should -Contain "github.com"
        }

        It "Returns a detectable NotModified property when the whitelist ETag matches" {
            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{ StatusCode = 304; Content = ""; ETag = '"etag-123"' }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"
            $result.PSObject.Properties['NotModified'] | Should -Not -BeNullOrEmpty
            $result.NotModified | Should -BeTrue
            $result.Whitelist | Should -HaveCount 0
        }

        It "Protects always-allowed hosts from blocked sections and injects control-plane hosts into the effective whitelist" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    apiUrl = 'https://control.example'
                    whitelistUrl = 'https://downloads.example/w/token/whitelist.txt'
                }
            } -ModuleName Common

            Mock Invoke-OpenPathHttpGetText {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = @"
safe.example
## BLOCKED-SUBDOMAINS
control.example
aus5.mozilla.org
## BLOCKED-PATHS
downloads.example/blocked
download.mozilla.org/firefox/releases
"@
                    ETag = $null
                }
            } -ModuleName Common

            $result = Get-OpenPathFromUrl -Url "http://test.example.com/whitelist.txt"

            $result.Whitelist | Should -Contain 'safe.example'
            $result.Whitelist | Should -Contain 'control.example'
            $result.Whitelist | Should -Contain 'downloads.example'
            $result.BlockedSubdomains | Should -Not -Contain 'control.example'
            $result.BlockedSubdomains | Should -Not -Contain 'aus5.mozilla.org'
            $result.BlockedPaths | Should -Not -Contain 'downloads.example/blocked'
            $result.BlockedPaths | Should -Not -Contain 'download.mozilla.org/firefox/releases'
        }
    }

    Context "Get-PrimaryDNS with mocked network" {
        It "Returns DNS from adapter when available" {
            Mock Get-DnsClientServerAddress {
                @([PSCustomObject]@{ ServerAddresses = @("192.168.1.1") })
            } -ModuleName Common
            Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '142.250.184.14' }) } -ModuleName Common -ParameterFilter { $Server -eq '192.168.1.1' }

            $dns = Get-PrimaryDNS
            $dns | Should -Be "192.168.1.1"
        }

        It "Falls back to gateway when no DNS adapter found" {
            Mock Get-DnsClientServerAddress { @() } -ModuleName Common
            Mock Get-NetRoute {
                @([PSCustomObject]@{ NextHop = "10.0.0.1" })
            } -ModuleName Common
            Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '142.250.184.14' }) } -ModuleName Common -ParameterFilter { $Server -eq '10.0.0.1' }

            $dns = Get-PrimaryDNS
            $dns | Should -Be "10.0.0.1"
        }

        It "Falls back to a public resolver when adapter DNS cannot answer direct queries" {
            Mock Get-DnsClientServerAddress {
                @([PSCustomObject]@{ ServerAddresses = @("168.63.129.16") })
            } -ModuleName Common
            Mock Get-NetRoute { @() } -ModuleName Common
            Mock Resolve-DnsName { throw 'unreachable' } -ModuleName Common -ParameterFilter { $Server -eq '168.63.129.16' }
            Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '142.250.184.14' }) } -ModuleName Common -ParameterFilter { $Server -eq '8.8.8.8' }

            $dns = Get-PrimaryDNS
            $dns | Should -Be "8.8.8.8"
        }

        It "De-prioritizes platform-managed resolvers when a public fallback also works" {
            Mock Get-DnsClientServerAddress {
                @([PSCustomObject]@{ ServerAddresses = @("168.63.129.16") })
            } -ModuleName Common
            Mock Get-NetRoute { @() } -ModuleName Common
            Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '142.250.184.14' }) } -ModuleName Common -ParameterFilter { $Server -eq '168.63.129.16' }
            Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '142.250.184.14' }) } -ModuleName Common -ParameterFilter { $Server -eq '8.8.8.8' }

            $dns = Get-PrimaryDNS
            $dns | Should -Be "8.8.8.8"
        }

        It "Still uses a platform-managed resolver when fallbacks are unreachable" {
            Mock Get-DnsClientServerAddress {
                @([PSCustomObject]@{ ServerAddresses = @("168.63.129.16") })
            } -ModuleName Common
            Mock Get-NetRoute { @() } -ModuleName Common
            Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '142.250.184.14' }) } -ModuleName Common -ParameterFilter { $Server -eq '168.63.129.16' }
            Mock Resolve-DnsName { throw 'unreachable' } -ModuleName Common -ParameterFilter { $Server -eq '8.8.8.8' }
            Mock Resolve-DnsName { throw 'unreachable' } -ModuleName Common -ParameterFilter { $Server -eq '1.1.1.1' }
            Mock Resolve-DnsName { throw 'unreachable' } -ModuleName Common -ParameterFilter { $Server -eq '9.9.9.9' }
            Mock Resolve-DnsName { throw 'unreachable' } -ModuleName Common -ParameterFilter { $Server -eq '8.8.4.4' }

            $dns = Get-PrimaryDNS
            $dns | Should -Be "168.63.129.16"
        }

        It "Falls back to 8.8.8.8 as ultimate default" {
            Mock Get-DnsClientServerAddress { @() } -ModuleName Common
            Mock Get-NetRoute { @() } -ModuleName Common
            Mock Resolve-DnsName { throw 'unreachable' } -ModuleName Common

            $dns = Get-PrimaryDNS
            $dns | Should -Be "8.8.8.8"
        }
    }

    Context "Get-OpenPathCaptivePortalUpstreamDns with mocked network" {
        It "Prefers visible non-local adapter DNS after captive portal reset without public probes" {
            Mock Get-NetAdapter {
                @([PSCustomObject]@{ Status = 'Up'; ifIndex = 7 })
            } -ModuleName Common
            Mock Get-DnsClientServerAddress {
                @([PSCustomObject]@{ InterfaceIndex = 7; ServerAddresses = @('192.168.50.1') })
            } -ModuleName Common
            Mock Resolve-DnsName { throw 'public probe should not be required' } -ModuleName Common

            $dns = Get-OpenPathCaptivePortalUpstreamDns -AfterAdapterReset

            $dns.Address | Should -Be '192.168.50.1'
            $dns.Source | Should -Be 'active-adapter-dns'
            $dns.UsableForLimited | Should -BeTrue
            $dns.PreReset | Should -BeFalse
        }

        It "Falls back to gateway as unverified but usable for limited mode when no adapter DNS is visible" {
            Mock Get-NetAdapter {
                @([PSCustomObject]@{ Status = 'Up'; ifIndex = 7 })
            } -ModuleName Common
            Mock Get-DnsClientServerAddress { @() } -ModuleName Common
            Mock Get-NetRoute {
                @([PSCustomObject]@{ InterfaceIndex = 7; NextHop = '10.0.0.1' })
            } -ModuleName Common
            Mock Resolve-DnsName { throw 'gateway dns blocked by captive portal' } -ModuleName Common -ParameterFilter { $Server -eq '10.0.0.1' }

            $dns = Get-OpenPathCaptivePortalUpstreamDns -AfterAdapterReset

            $dns.Address | Should -Be '10.0.0.1'
            $dns.Source | Should -Be 'gateway'
            $dns.Verified | Should -BeFalse
            $dns.UsableForLimited | Should -BeTrue
        }

        It "Marks public fallback as diagnostic and not usable for limited mode" {
            Mock Get-NetAdapter { @() } -ModuleName Common
            Mock Get-DnsClientServerAddress { @() } -ModuleName Common
            Mock Get-NetRoute { @() } -ModuleName Common
            Mock Resolve-DnsName { throw 'unreachable' } -ModuleName Common

            $dns = Get-OpenPathCaptivePortalUpstreamDns -AfterAdapterReset

            $dns.Address | Should -Be '8.8.8.8'
            $dns.Source | Should -Be 'fallback'
            $dns.UsableForLimited | Should -BeFalse
        }
    }

    Context "Send-OpenPathHealthReport" {
        It "Posts health reports to the tRPC endpoint with expected payload fields" {
            $script:capturedUri = $null
            $script:capturedHeaders = $null
            $script:capturedBody = $null

            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    apiUrl = 'https://api.example.com'
                    whitelistUrl = 'https://api.example.com/w/token123/whitelist.txt'
                    version = '4.1.0'
                }
            } -ModuleName Common

            Mock Invoke-RestMethod {
                param(
                    [string]$Uri,
                    [string]$Method,
                    [hashtable]$Headers,
                    [string]$Body
                )

                $script:capturedUri = $Uri
                $script:capturedHeaders = $Headers
                $script:capturedBody = $Body

                return @{ result = @{ data = @{ json = @{ ok = $true } } } }
            } -ModuleName Common

            $result = Send-OpenPathHealthReport -Status 'DEGRADED' -DnsServiceRunning:$true -DnsResolving:$false -FailCount 2 -Actions 'watchdog_repair' -Version '4.1.0'
            $result | Should -BeTrue

            $script:capturedUri | Should -Be 'https://api.example.com/trpc/healthReports.submit'
            $script:capturedHeaders['Authorization'] | Should -Be 'Bearer token123'

            $payload = $script:capturedBody | ConvertFrom-Json
            $payload.json.status | Should -Be 'DEGRADED'
            $payload.json.hostname | Should -Not -BeNullOrEmpty
            $payload.json.dnsmasqRunning | Should -BeTrue
            $payload.json.dnsResolving | Should -BeFalse
            $payload.json.failCount | Should -Be 2
            $payload.json.actions | Should -Be 'watchdog_repair'
            $payload.json.version | Should -Be '4.1.0'
        }

        It "Returns false when apiUrl is missing in config" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    version = '4.1.0'
                }
            } -ModuleName Common

            Mock Invoke-RestMethod {
                throw 'Invoke-RestMethod should not be called when apiUrl is missing'
            } -ModuleName Common

            $result = Send-OpenPathHealthReport -Status 'HEALTHY'
            $result | Should -BeFalse
        }
    }

    Context "Restore-OpenPathLatestCheckpoint" {
        It "Restores checkpoint whitelist and reapplies DNS controls" {
            $tempDir = Join-Path $env:TEMP ("openpath-checkpoint-" + [Guid]::NewGuid().ToString())
            $checkpointDir = Join-Path $tempDir 'checkpoint-001'
            $checkpointWhitelistPath = Join-Path $checkpointDir 'whitelist.txt'
            $targetWhitelistPath = Join-Path $tempDir 'whitelist.txt'

            try {
                New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
                @('google.com', 'example.org') | Set-Content $checkpointWhitelistPath -Encoding UTF8

                Mock Get-OpenPathLatestCheckpoint {
                    [PSCustomObject]@{
                        Path = $checkpointDir
                        WhitelistPath = $checkpointWhitelistPath
                        Metadata = $null
                    }
                } -ModuleName Common

                Mock Update-AcrylicHost { $true } -ModuleName Common
                Mock Restart-AcrylicService { $true } -ModuleName Common
                Mock Get-AcrylicPath { 'C:\OpenPath\Acrylic DNS Proxy' } -ModuleName Common
                Mock Set-OpenPathFirewall { $true } -ModuleName Common
                Mock Set-LocalDNS { } -ModuleName Common
                Mock Enable-OpenPathFirewall { $true } -ModuleName Common

                $config = [PSCustomObject]@{
                    enableFirewall = $true
                    primaryDNS = '8.8.8.8'
                }

                $result = Restore-OpenPathLatestCheckpoint -Config $config -WhitelistPath $targetWhitelistPath

                $result.Success | Should -BeTrue
                $result.DomainCount | Should -Be 2
                $result.CheckpointPath | Should -Be $checkpointDir

                $restoredContent = Get-Content $targetWhitelistPath -Raw
                $restoredContent.Contains('google.com') | Should -BeTrue
                $restoredContent.Contains('example.org') | Should -BeTrue

                Should -Invoke Update-AcrylicHost -ModuleName Common -Times 1 -Exactly
                Should -Invoke Restart-AcrylicService -ModuleName Common -Times 1 -Exactly
                Should -Invoke Get-AcrylicPath -ModuleName Common -Times 1 -Exactly
                Should -Invoke Set-OpenPathFirewall -ModuleName Common -Times 1 -Exactly
                Should -Invoke Set-LocalDNS -ModuleName Common -Times 1 -Exactly
                Should -Invoke Enable-OpenPathFirewall -ModuleName Common -Times 0 -Exactly
            }
            finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Returns failure when checkpoint whitelist has no valid domains" {
            $tempDir = Join-Path $env:TEMP ("openpath-checkpoint-invalid-" + [Guid]::NewGuid().ToString())
            $checkpointDir = Join-Path $tempDir 'checkpoint-001'
            $checkpointWhitelistPath = Join-Path $checkpointDir 'whitelist.txt'
            $targetWhitelistPath = Join-Path $tempDir 'whitelist.txt'

            try {
                New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
                @('not-a-domain', '# comment') | Set-Content $checkpointWhitelistPath -Encoding UTF8

                Mock Get-OpenPathLatestCheckpoint {
                    [PSCustomObject]@{
                        Path = $checkpointDir
                        WhitelistPath = $checkpointWhitelistPath
                        Metadata = $null
                    }
                } -ModuleName Common

                $config = [PSCustomObject]@{
                    enableFirewall = $false
                    primaryDNS = '8.8.8.8'
                }

                $result = Restore-OpenPathLatestCheckpoint -Config $config -WhitelistPath $targetWhitelistPath

                $result.Success | Should -BeFalse
                $result.Error | Should -BeLike '*no valid domains*'
            }
            finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
