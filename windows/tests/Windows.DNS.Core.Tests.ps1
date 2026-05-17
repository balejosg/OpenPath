Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

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

        if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) {
            function global:Get-NetAdapter { }
        }
        if (-not (Get-Command -Name Set-DnsClientServerAddress -ErrorAction SilentlyContinue)) {
            function global:Set-DnsClientServerAddress { }
        }
        if (-not (Get-Command -Name Clear-DnsClientCache -ErrorAction SilentlyContinue)) {
            function global:Clear-DnsClientCache { }
        }
        if (-not (Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue)) {
            function global:Resolve-DnsName {
                param(
                    [string]$Name,
                    [string]$Server,
                    [switch]$DnsOnly,
                    [object]$ErrorAction
                )
            }
        }
        if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) {
            function global:Get-Service { }
        }
        if (-not (Get-Command -Name Restart-Service -ErrorAction SilentlyContinue)) {
            function global:Restart-Service { }
        }
        if (-not (Get-Command -Name Start-Service -ErrorAction SilentlyContinue)) {
            function global:Start-Service { }
        }

        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\DNS.psm1" -Force -Global -ErrorAction Stop
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

    Context "Original DNS snapshot" {
        It "Snapshots adapter identity and IPv4 DNS before local DNS mutation" {
            $servicePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Service.ps1"
            $content = Get-Content $servicePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Save-OpenPathOriginalDnsSnapshot',
                "return 'C:\OpenPath\data\original-dns.json'",
                'InterfaceGuid = [string]$adapter.InterfaceGuid',
                'InterfaceAlias = [string]$adapter.Name',
                'InterfaceIndex = [int]$adapter.ifIndex',
                'ServerAddresses = @($dns.ServerAddresses | ForEach-Object { [string]$_ })',
                'Save-OpenPathOriginalDnsSnapshot | Out-Null'
            )
        }

        It "Restores DNS by InterfaceGuid with index and alias fallback and resets empty server lists" {
            $servicePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Service.ps1"
            $content = Get-Content $servicePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Restore-OriginalDNS',
                '$snapshotPath = Get-OpenPathOriginalDnsSnapshotPath',
                'if (Test-Path $snapshotPath)',
                '$snapshot = @(Get-Content $snapshotPath -Raw | ConvertFrom-Json)',
                '[string]$_.InterfaceGuid -eq [string]$entry.InterfaceGuid',
                '$_.ifIndex -eq [int]$entry.InterfaceIndex',
                '$_.Name -eq [string]$entry.InterfaceAlias',
                'Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $servers',
                'Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses'
            )
        }

        It "Resets captive portal DNS from active adapters without reading stale snapshots" {
            $servicePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Service.ps1"
            $content = Get-Content $servicePath -Raw
            $portalRestoreBody = [regex]::Match($content, '(?s)function Restore-OpenPathCaptivePortalDNS \{.*?\r?\n\}\r?\n\r?\nfunction Get-AcrylicService').Value

            Assert-ContentContainsAll -Content $portalRestoreBody -Needles @(
                'function Restore-OpenPathCaptivePortalDNS',
                '$adapters = Get-NetAdapter | Where-Object { $_.Status -eq ''Up'' }',
                'Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop',
                'Clear-DnsClientCache'
            )
            $portalRestoreBody | Should -Not -Match 'Get-OpenPathOriginalDnsSnapshotPath'
            $portalRestoreBody | Should -Not -Match 'original-dns\.json'
            $portalRestoreBody | Should -Not -Match 'Get-Content'
            $portalRestoreBody | Should -Not -Match 'ServerAddresses \$servers'
        }

        It "Keeps Restore-OriginalDNS snapshot rollback behavior for OpenPath cleanup" {
            $servicePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Service.ps1"
            $content = Get-Content $servicePath -Raw
            $restoreOriginalBody = [regex]::Match($content, '(?s)function Restore-OriginalDNS \{.*?\r?\n\}\r?\n\r?\nfunction Restore-OpenPathCaptivePortalDNS').Value

            Assert-ContentContainsAll -Content $restoreOriginalBody -Needles @(
                '$snapshot = @(Get-Content $snapshotPath -Raw | ConvertFrom-Json)',
                'Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $servers',
                'Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses',
                'Clear-DnsClientCache'
            )
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

        It "Exposes runtime dependency policy, queue, and overlay as split internal modules" {
            $internalPath = Join-Path $PSScriptRoot ".." "lib" "internal"
            $policyPath = Join-Path $internalPath "RuntimeDependency.Policy.ps1"
            $queuePath = Join-Path $internalPath "RuntimeDependency.Queue.ps1"
            $overlayPath = Join-Path $internalPath "RuntimeDependency.Overlay.ps1"
            $dnsModulePath = Join-Path $PSScriptRoot ".." "lib" "DNS.psm1"
            $dnsModuleContent = Get-Content $dnsModulePath -Raw

            Test-Path $policyPath | Should -BeTrue
            Test-Path $queuePath | Should -BeTrue
            Test-Path $overlayPath | Should -BeTrue
            $dnsModuleContent | Should -Match "RuntimeDependency\.Policy\.ps1"
            $dnsModuleContent | Should -Match "RuntimeDependency\.Queue\.ps1"
            $dnsModuleContent | Should -Match "RuntimeDependency\.Overlay\.ps1"
            ([regex]::Matches($dnsModuleContent, "RuntimeDependency\.Policy\.ps1")).Count | Should -Be 1
            ([regex]::Matches($dnsModuleContent, "RuntimeDependency\.Queue\.ps1")).Count | Should -Be 1
            ([regex]::Matches($dnsModuleContent, "RuntimeDependency\.Overlay\.ps1")).Count | Should -Be 1

            $policyContent = Get-Content $policyPath -Raw
            $policyContent | Should -Match 'function Test-OpenPathRuntimeDependencyCandidate'
            $policyContent | Should -Match 'Sensitive fields are not accepted'
            $policyContent | Should -Match 'Protected hosts are not accepted as runtime dependencies'
            $policyContent | Should -Match 'Blocked hosts are not accepted as runtime dependencies'
        }

        It "Validates runtime dependency policy without accepting URLs, headers, bodies, or tokens" {
            InModuleScope DNS {
                $state = [PSCustomObject]@{
                    apiUrl = 'https://api.openpath.example'
                    whitelistUrl = 'https://api.openpath.example/w/token/whitelist.txt'
                }
                $valid = Test-OpenPathRuntimeDependencyCandidate `
                    -Message ([PSCustomObject]@{
                        anchorHost = 'www.reddit.com'
                        dependencyHost = 'www.redditstatic.com'
                        requestType = 'script'
                    }) `
                    -WhitelistedDomains @('reddit.com') `
                    -BlockedSubdomains @() `
                    -State $state
                $valid.Valid | Should -BeTrue
                $valid.AnchorHost | Should -Be 'www.reddit.com'
                $valid.DependencyHost | Should -Be 'www.redditstatic.com'
                $valid.RequestType | Should -Be 'script'

                $sensitive = Test-OpenPathRuntimeDependencyCandidate `
                    -Message ([PSCustomObject]@{
                        anchorHost = 'www.reddit.com'
                        dependencyHost = 'www.redditstatic.com'
                        requestType = 'script'
                        url = 'https://www.redditstatic.com/app.js?token=secret'
                        headers = @{ Authorization = 'Bearer secret' }
                        body = 'secret'
                        token = 'secret'
                    }) `
                    -WhitelistedDomains @('reddit.com') `
                    -BlockedSubdomains @() `
                    -State $state
                $sensitive.Valid | Should -BeFalse
                $sensitive.Result.error | Should -Be 'Sensitive fields are not accepted'

                $protected = Test-OpenPathRuntimeDependencyCandidate `
                    -Message ([PSCustomObject]@{
                        anchorHost = 'www.reddit.com'
                        dependencyHost = 'download.windowsupdate.com'
                        requestType = 'script'
                    }) `
                    -WhitelistedDomains @('reddit.com') `
                    -BlockedSubdomains @() `
                    -State $state
                $protected.Valid | Should -BeFalse
                $protected.Result.error | Should -Be 'Protected hosts are not accepted as runtime dependencies'

                $blocked = Test-OpenPathRuntimeDependencyCandidate `
                    -Message ([PSCustomObject]@{
                        anchorHost = 'www.reddit.com'
                        dependencyHost = 'ads.redditstatic.com'
                        requestType = 'script'
                    }) `
                    -WhitelistedDomains @('reddit.com') `
                    -BlockedSubdomains @('ads.redditstatic.com') `
                    -State $state
                $blocked.Valid | Should -BeFalse
                $blocked.Result.error | Should -Be 'Blocked hosts are not accepted as runtime dependencies'
            }
        }

        It "Writes runtime dependency queue requests with only sanitized host fields and batch-compatible shape" {
            InModuleScope DNS {
                $queuePath = Join-Path $TestDrive "runtime-dependency-queue"
                $first = Write-OpenPathRuntimeDependencyQueueRequest `
                    -AnchorHost 'WWW.Reddit.Com.' `
                    -DependencyHost 'WWW.RedditStatic.Com.' `
                    -RequestType 'Script' `
                    -QueuePath $queuePath
                $second = Write-OpenPathRuntimeDependencyQueueRequest `
                    -AnchorHost 'www.reddit.com' `
                    -DependencyHost 'www.redditstatic.com' `
                    -RequestType 'script' `
                    -QueuePath $queuePath

                $second | Should -Be $first
                $files = @(Get-ChildItem -Path $queuePath -Filter '*.json' -File)
                $files.Count | Should -Be 1
                $request = Get-Content $files[0].FullName -Raw | ConvertFrom-Json

                $request.anchorHost | Should -Be 'www.reddit.com'
                $request.dependencyHost | Should -Be 'www.redditstatic.com'
                $request.requestType | Should -Be 'script'
                $request.PSObject.Properties.Name | Should -Contain 'anchorHost'
                $request.PSObject.Properties.Name | Should -Contain 'dependencyHost'
                $request.PSObject.Properties.Name | Should -Contain 'requestType'
                $request.PSObject.Properties.Name | Should -Not -Contain 'url'
                $request.PSObject.Properties.Name | Should -Not -Contain 'headers'
                $request.PSObject.Properties.Name | Should -Not -Contain 'body'
                $request.PSObject.Properties.Name | Should -Not -Contain 'token'
            }
        }

        It "Dedupe, prunes expired runtime dependency overlay entries, and enforces capacity" {
            InModuleScope DNS {
                $overlayPath = Join-Path $TestDrive "runtime-dependency-overlay.json"
                $now = [DateTimeOffset]::UtcNow
                $entries = @(
                    [PSCustomObject]@{
                        dependencyHost = 'old.example'
                        anchorHost = 'www.reddit.com'
                        requestTypes = @('image')
                        firstSeen = $now.AddDays(-3).ToString('o')
                        lastSeen = $now.AddDays(-3).ToString('o')
                        expiresAt = $now.AddDays(-1).ToString('o')
                        source = 'firefox-webrequest-local'
                    },
                    [PSCustomObject]@{
                        dependencyHost = 'cdn-one.example'
                        anchorHost = 'www.reddit.com'
                        requestTypes = @('script')
                        firstSeen = $now.AddMinutes(-10).ToString('o')
                        lastSeen = $now.AddMinutes(-10).ToString('o')
                        expiresAt = $now.AddDays(1).ToString('o')
                        source = 'firefox-webrequest-local'
                    }
                )
                Write-OpenPathRuntimeDependencyOverlay -Entries $entries -Path $overlayPath

                $updated = Update-OpenPathRuntimeDependencyOverlay `
                    -Entries (Read-OpenPathRuntimeDependencyOverlay -Path $overlayPath) `
                    -Requests @(
                        [PSCustomObject]@{ anchorHost = 'www.reddit.com'; dependencyHost = 'cdn-one.example'; requestType = 'image' },
                        [PSCustomObject]@{ anchorHost = 'www.reddit.com'; dependencyHost = 'cdn-two.example'; requestType = 'script' },
                        [PSCustomObject]@{ anchorHost = 'www.reddit.com'; dependencyHost = 'cdn-three.example'; requestType = 'script' }
                    ) `
                    -WhitelistedDomains @('reddit.com') `
                    -BlockedSubdomains @() `
                    -Capacity 2 `
                    -TtlDays 7

                $updated.Entries.Count | Should -Be 2
                $updated.Entries.dependencyHost | Should -Not -Contain 'old.example'
                $updated.Entries.dependencyHost | Should -Contain 'cdn-one.example'
                $cdnOne = @($updated.Entries | Where-Object { $_.dependencyHost -eq 'cdn-one.example' })[0]
                @($cdnOne.requestTypes) | Should -Contain 'script'
                @($cdnOne.requestTypes) | Should -Contain 'image'
            }
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

        It "Renders Microsoft system domains as essential FW rules before the default block" {
            InModuleScope DNS {
                $definition = New-AcrylicHostsDefinition `
                    -WhitelistedDomains @('example.com') `
                    -DnsSettings ([PSCustomObject]@{
                        PrimaryDNS = '1.1.1.1'
                        SecondaryDNS = '1.0.0.1'
                        MaxDomains = 10
                    })

                $content = ConvertTo-AcrylicHostsContent -Definition $definition
                $defaultBlockRuleIndex = $content.IndexOf('NX *')

                foreach ($domain in @(
                        'windowsupdate.com',
                        'delivery.mp.microsoft.com',
                        'definitionupdates.microsoft.com',
                        'edge.microsoft.com',
                        'login.microsoftonline.com',
                        'azureedge.net',
                        'blob.core.windows.net'
                    )) {
                    $content | Should -Match "(?m)^FW $([regex]::Escape($domain))$"
                    $content | Should -Match "(?m)^FW >$([regex]::Escape($domain))$"
                    $content.IndexOf("FW $domain") | Should -BeLessThan $defaultBlockRuleIndex
                    $definition.DomainAffinityMask | Should -Match "$([regex]::Escape($domain));\*\.$([regex]::Escape($domain))"
                }

                $content | Should -Not -Match '\*\.windowsupdate\.com'
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

        It "Processes queued reddit runtime dependencies into exact FW rules before the default block" {
            $previousOverlayPath = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
            $previousQueuePath = $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-runtime-queue-" + [Guid]::NewGuid().ToString("N"))
            $overlayPath = Join-Path $tempRoot "runtime-dependency-overlay.json"
            $queuePath = Join-Path $tempRoot "runtime-dependency-queue"

            try {
                New-Item -ItemType Directory -Path $queuePath -Force | Out-Null
                $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = $overlayPath
                $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH = $queuePath

                @{
                    version = 1
                    queuedAt = (Get-Date).ToUniversalTime().ToString('o')
                    anchorHost = 'www.reddit.com'
                    dependencyHost = 'www.redditstatic.com'
                    requestType = 'xmlhttprequest'
                    source = 'firefox-webrequest-local'
                } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $queuePath "request.json") -Encoding UTF8 -Force
                @{
                    version = 1
                    queuedAt = (Get-Date).ToUniversalTime().ToString('o')
                    anchorHost = 'www.reddit.com'
                    dependencyHost = 'emoji.redditmedia.com'
                    requestType = 'image'
                    source = 'firefox-webrequest-local'
                } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $queuePath "request-image.json") -Encoding UTF8 -Force

                InModuleScope DNS {
                    $queueResult = Invoke-OpenPathRuntimeDependencyQueue `
                        -WhitelistedDomains @('reddit.com') `
                        -BlockedSubdomains @()

                    $queueResult.Changed | Should -BeTrue
                    $queueResult.Processed | Should -Be 2

                    $domains = Get-OpenPathRuntimeDependencyDomains `
                        -WhitelistedDomains @('reddit.com') `
                        -BlockedSubdomains @() `
                        -Prune

                    $domains | Should -Contain 'www.redditstatic.com'
                    $domains | Should -Contain 'emoji.redditmedia.com'

                    $definition = New-AcrylicHostsDefinition `
                        -WhitelistedDomains @('reddit.com') `
                        -BlockedSubdomains @() `
                        -RuntimeDependencyDomains $domains `
                        -DnsSettings ([PSCustomObject]@{
                            PrimaryDNS = '1.1.1.1'
                            SecondaryDNS = '1.0.0.1'
                            MaxDomains = 10
                        })
                    $content = ConvertTo-AcrylicHostsContent -Definition $definition

                    $content | Should -Match '(?m)^FW www\.redditstatic\.com$'
                    $content | Should -Match '(?m)^FW emoji\.redditmedia\.com$'
                    $content | Should -Not -Match '(?m)^FW >www\.redditstatic\.com$'
                    $content | Should -Not -Match '(?m)^FW >emoji\.redditmedia\.com$'
                    $dependencyRuleIndex = $content.IndexOf('FW www.redditstatic.com')
                    $defaultBlockRuleIndex = $content.IndexOf('NX *')
                    $dependencyRuleIndex | Should -BeGreaterThan -1
                    $defaultBlockRuleIndex | Should -BeGreaterThan $dependencyRuleIndex
                }
            }
            finally {
                if ($null -eq $previousOverlayPath) {
                    Remove-Item Env:\OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH -ErrorAction SilentlyContinue
                }
                else {
                    $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = $previousOverlayPath
                }
                if ($null -eq $previousQueuePath) {
                    Remove-Item Env:\OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH -ErrorAction SilentlyContinue
                }
                else {
                    $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH = $previousQueuePath
                }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
            $modelPath = Join-Path $PSScriptRoot ".." "lib" "internal" "AcrylicHostsModel.ps1"
            $rendererPath = Join-Path $PSScriptRoot ".." "lib" "internal" "AcrylicHostsRenderer.ps1"
            $moduleContent = Get-Content $modulePath -Raw
            $configContent = Get-Content $configPath -Raw
            $modelContent = Get-Content $modelPath -Raw
            $rendererContent = Get-Content $rendererPath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                "AcrylicHostsModel.ps1",
                "AcrylicHostsRenderer.ps1",
                "DNS.Acrylic.Install.ps1",
                "DNS.Acrylic.Config.ps1",
                "DNS.Acrylic.Service.ps1",
                "DNS.Diagnostics.ps1"
            )

            Assert-ContentContainsAll -Content $modelContent -Needles @(
                "'NX *'",
                'function Get-AcrylicForwardRules',
                'function New-AcrylicHostsDefinition'
            )
            Assert-ContentContainsAll -Content $rendererContent -Needles @(
                'function ConvertTo-AcrylicHostsContent'
            )
            Assert-ContentContainsAll -Content $configContent -Needles @(
                'function Get-OpenPathDnsSettings',
                '$definition = New-AcrylicHostsDefinition',
                '$content = ConvertTo-AcrylicHostsContent -Definition $definition'
            )
            foreach ($movedFunction in @(
                    'Resolve-SslipIpv4Address',
                    'Get-AcrylicForwardRules',
                    'New-AcrylicHostsDefinition',
                    'ConvertTo-AcrylicHostsContent',
                    'Set-AcrylicGlobalSetting',
                    'Set-AcrylicAllowedAddress',
                    'Get-OpenPathRuntimeDependencyOverlayPath',
                    'Read-OpenPathRuntimeDependencyOverlay',
                    'Write-OpenPathRuntimeDependencyOverlay',
                    'Invoke-OpenPathRuntimeDependencyQueue',
                    'Normalize-OpenPathRuntimeDependencyHost'
                )) {
                $configContent | Should -Not -Match "function\s+$movedFunction\b"
            }

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
            Mock Write-AcrylicConfigFile {
                param(
                    [string]$Path,
                    [string]$Content
                )

                if ($Path -like '*AcrylicConfiguration.ini') {
                    $script:capturedAcrylicConfig = $Content
                    $script:capturedAcrylicConfigEncoding = 'ASCII'
                }
            } -ModuleName DNS

            $result = Set-AcrylicConfiguration -WhitelistedDomains @('example.com', 'test.com')

            $result | Should -BeTrue
            $script:capturedAcrylicConfig | Should -Not -BeNullOrEmpty
            Assert-ContentContainsAll -Content $script:capturedAcrylicConfig -Needles @(
                '[GlobalSection]',
                'PrimaryServerDomainNameAffinityMask=raw.githubusercontent.com;*.raw.githubusercontent.com',
                'SecondaryServerDomainNameAffinityMask=raw.githubusercontent.com;*.raw.githubusercontent.com',
                'windowsupdate.com;*.windowsupdate.com',
                'delivery.mp.microsoft.com;*.delivery.mp.microsoft.com',
                'login.microsoftonline.com;*.login.microsoftonline.com',
                'azureedge.net;*.azureedge.net',
                'blob.core.windows.net;*.blob.core.windows.net',
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
            Mock Write-AcrylicConfigFile {
                param(
                    [string]$Path,
                    [string]$Content
                )

                if ($Path -like '*AcrylicConfiguration.ini') {
                    $script:capturedAcrylicConfig = $Content
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
            Mock Write-AcrylicConfigFile {
                param(
                    [string]$Path,
                    [string]$Content
                )

                if ($Path -like '*AcrylicConfiguration.ini') {
                    $script:capturedAcrylicConfig = $Content
                }
            } -ModuleName DNS
            Mock Write-AcrylicHostsFile {
                param(
                    [string]$Path,
                    [string]$Content
                )
                if ($Path -like '*AcrylicHosts.txt') {
                    $script:capturedHostsContent = $Content
                    $script:capturedHostsEncoding = 'ASCII'
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
                Mock Get-AcrylicEssentialDomainGroups {
                    @(
                        [PSCustomObject]@{ Comment = '# Control plane and bootstrap/download'; Domains = @('control.example', 'downloads.example', 'raw.githubusercontent.com') },
                        [PSCustomObject]@{ Comment = '# NTP'; Domains = @('time.windows.com') }
                    )
                }

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
            $reconcilerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointStateReconciler.ps1"
            $content = Get-Content $scriptPath -Raw

            . $reconcilerPath
            $plan = New-OpenPathEndpointStateRepairPlan `
                -PolicyState ([PSCustomObject]@{ ProtectedModeEligible = $true }) `
                -Mode 'ApplyWhitelist' `
                -EnableBrowserPolicies:$true

            $plan.Actions | Should -Be @(
                'RestoreProtectedMode',
                'SetAllBrowserPolicy',
                'RestoreProtectedModeNoRestart'
            )
            $content | Should -Match '(?s)Handle-OpenPathWhitelistApply.*?-BlockedPaths \$Whitelist\.BlockedPaths.*?Get-OpenPathRuntimeHealth'
        }
    }
}
