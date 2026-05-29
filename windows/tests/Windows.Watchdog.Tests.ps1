Describe "Watchdog Script" {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    }

    Context "Module import resilience" {
        It "Uses the shared standalone bootstrap helper" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force',
                'Initialize-OpenPathScriptSession `',
                '-OpenPathRoot $OpenPathRoot',
                '-DependentModules @(''DNS'', ''Firewall'', ''Browser'', ''CaptivePortal'', ''AppControl'')',
                '-RequiredCommands @(',
                '-ScriptName ''Test-DNSHealth.ps1''',
                '''Sync-OpenPathFirefoxManagedExtensionPolicy''',
                '''Get-OpenPathWhitelistSectionsFromFile''',
                '''Restore-OpenPathCaptivePortalDNS'''
            )
        }
    }

    Context "Firefox managed extension refresh" {
        It "Refreshes only the Firefox managed extension policy without reading local blocked paths" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Sync-OpenPathFirefoxManagedExtensionPolicy',
                'Watchdog: refreshed Firefox managed extension policy'
            )
            $content | Should -Not -Match 'Set-FirefoxPolicy -BlockedPaths'
        }
    }

    Context "SSE listener monitoring" {
        It "Checks and restarts SSE listener task" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'OpenPath-SSE',
                'Start-ScheduledTask -TaskName "OpenPath-SSE"'
            )
        }
    }

    Context "AppControl repair" {
        It "Reapplies AppControl with approved student browsers from config" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$approvedStudentBrowsers = @(''Firefox'')',
                '$Config.PSObject.Properties[''approvedStudentBrowsers'']',
                '$approvedStudentBrowsers = @($Config.approvedStudentBrowsers)',
                'Test-OpenPathNonAdminAppControlActive `',
                '-Mode $mode `',
                '-ApprovedBrowsers $approvedStudentBrowsers',
                'Set-OpenPathNonAdminAppControl -OpenPathRoot $OpenPathRoot -Mode $mode -ApprovedBrowsers $approvedStudentBrowsers'
            )
        }
    }

    Context "Captive portal detection" {
        It "Defines admin-only captive portal recovery script with bounded queue processing" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '#Requires -RunAsAdministrator',
                'Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force',
                "-DependentModules @('DNS', 'Firewall', 'CaptivePortal')",
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryQueue',
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryResult',
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryProgress',
                'Get-OpenPathCaptivePortalRecoveryRequests',
                'Invoke-OpenPathCaptivePortalAuthenticatedRestore',
                'Invoke-OpenPathCaptivePortalRecoveryRequest',
                'Write-OpenPathCaptivePortalRecoveryProgress',
                '$MaxRequestAgeSeconds = 60',
                '$RecentSuccessSeconds = 30',
                'createdAtUtc',
                '''request-read''',
                '''state-probe''',
                '''enable''',
                '''disable''',
                '''write-result''',
                '''error''',
                'Test-OpenPathCaptivePortalState -TimeoutSec 3',
                'Update-OpenPathCaptivePortalObservation -DetectedState Portal',
                'Enable-OpenPathCaptivePortalMode -State Portal -PortalRecoveryDomains',
                'Disable-OpenPathCaptivePortalMode',
                '$operation',
                '''open''',
                '''reconcile''',
                '''Authenticated''',
                'portalModeActive',
                'ConvertTo-Json -Depth 6'
            )

            $content | Should -Not -Match 'captive-portal-recovery-fixture-state\.json'
            $content | Should -Not -Match 'direct-runner-captive-portal-navigation'
            $content | Should -Not -Match 'Get-OpenPathCaptivePortalRecoveryFixtureState'
        }

        It "Orders recovery observation before enabling portal mode and never uses stale DNS rollback" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.IndexOf('Update-OpenPathCaptivePortalObservation -DetectedState Portal') |
                Should -BeLessThan $content.IndexOf('Enable-OpenPathCaptivePortalMode -State Portal')
            $content | Should -Not -Match 'Restore-OriginalDNS'
        }

        It "Detects captive portals and opens only exact recovery hosts without dropping protection" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $scriptContent = Get-Content $scriptPath -Raw
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                '-DependentModules @(',
                '''DNS''',
                '''Firewall''',
                '''Browser''',
                '''CaptivePortal''',
                'Test-OpenPathCaptivePortalState',
                'Enable-OpenPathCaptivePortalMode'
            )

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'msftconnecttest.com',
                'detectportal.firefox.com',
                'clients3.google.com',
                'captive-portal-active.json',
                'Captive portal detected',
                '-Mode limited',
                'allowedHosts',
                'expiresAt',
                'upstreamDns',
                'Get-PrimaryDNS',
                'New-AcrylicHostsDefinition',
                'Get-AcrylicExactForwardRule',
                'Test-FirewallActive',
                'Test-DNSResolution',
                'Test-DNSSinkhole'
            )

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalMode')
            $disableStart = $moduleContent.IndexOf('function Disable-OpenPathCaptivePortalMode')
            $enableBody = $moduleContent.Substring($enableStart, $disableStart - $enableStart)
            $enableBody | Should -Not -Match 'Disable-OpenPathFirewall'
            $enableBody | Should -Not -Match 'Restore-OpenPathCaptivePortalDNS'
            $enableBody | Should -Not -Match 'Restore-OriginalDNS'
        }

        It "Enters bounded passthrough instead of staying protected when watchdog has no exact host" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalMode')
            $disableStart = $moduleContent.IndexOf('function Disable-OpenPathCaptivePortalMode')
            $enableBody = $moduleContent.Substring($enableStart, $disableStart - $enableStart)

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'Enable-OpenPathCaptivePortalPassthroughMode',
                '-Mode passthrough',
                'Restore-OpenPathCaptivePortalDNS',
                'Test-OpenPathCaptivePortalPassthroughEgressUsable',
                'adapter DNS reset did not complete',
                'reset DNS did not expose DNS/HTTP/HTTPS egress',
                'upstreamUsableForLimited'
            )
            $enableBody | Should -Not -Match 'no exact recovery host was supplied; staying protected'
            $enableBody | Should -Not -Match '(?s)if \(\$allowedHosts\.Count -le 0\).*?return \$false'
        }

        It "Promotes an active passthrough marker with a new exact host into limited Acrylic recovery" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalMode')
            $disableStart = $moduleContent.IndexOf('function Disable-OpenPathCaptivePortalMode')
            $enableBody = $moduleContent.Substring($enableStart, $disableStart - $enableStart)

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                '$marker.mode -eq ''passthrough''',
                'New-OpenPathLimitedCaptivePortalHostsDefinition',
                'Set-Content -Path $hostsPath',
                'Set-OpenPathCaptivePortalMarker -State $State -Mode limited',
                'CAPTIVE PORTAL RECOVERY'
            )
            $enableBody | Should -Not -Match '(?s)if \(Test-OpenPathCaptivePortalModeActive\).*?Set-OpenPathCaptivePortalMarker.*?return \$true'
        }

        It "Renders exact temporary portal hosts before the default NX block and clears them on exit" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'CAPTIVE PORTAL RECOVERY',
                '$PortalRecoveryDomains',
                '$portalRecoveryLines',
                '$sections += New-AcrylicHostsSection -Title ''CAPTIVE PORTAL RECOVERY',
                'Restore-OpenPathCaptivePortalAcrylicHostState',
                'Update-AcrylicHost -WhitelistedDomains $whitelistDomains -BlockedSubdomains $blockedSubdomains',
                'Clear-OpenPathCaptivePortalMarker'
            )

            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $definitionEnd = $moduleContent.IndexOf('function Test-OpenPathLimitedCaptivePortalProtection')
            $definitionBody = $moduleContent.Substring($definitionStart, $definitionEnd - $definitionStart)
            $definitionBody.IndexOf('$sections += New-AcrylicHostsSection -Title ''CAPTIVE PORTAL RECOVERY') |
                Should -BeLessThan $definitionBody.IndexOf('$sections += $section')
            $definitionBody | Should -Match '(?s)foreach \(\$domain in @\(\$PortalRecoveryDomains\)\).*?Get-AcrylicExactForwardRule'
        }

        It "Discovers bounded exact captive portal hosts and rejects unsafe host candidates" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'function Get-OpenPathCaptivePortalDynamicHosts',
                'function Get-OpenPathCaptivePortalBootstrapSeedUrls',
                'function Invoke-OpenPathCaptivePortalBootstrapProbe',
                'Get-OpenPathCaptivePortalAllowedHosts -Hosts',
                'Normalize-OpenPathCaptivePortalDynamicHost',
                'Extract-OpenPathCaptivePortalHostsFromText',
                'Reject-OpenPathCaptivePortalDynamicHost',
                'AllowAutoRedirect = $false',
                '$request.UserAgent = ''OpenPath captive portal recovery''',
                'discoveryTruncated',
                'bootstrapHosts',
                'observedRuntimeHosts',
                'pendingRuntimeHosts',
                'fallbackMode',
                'limitedModeReady',
                'RuntimeDependencyOverlay',
                'Read-OpenPathRuntimeDependencyOverlay',
                'Test-OpenPathProtectedRuntimeDependencyHost'
            )

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                '.local',
                'single-label',
                'ip-address',
                'protected-host',
                'parent-wildcard',
                'invalid-host'
            )

            $moduleContent | Should -Not -Match 'cookies?'
            $moduleContent | Should -Not -Match 'authorization'
        }

        It "Behaviorally returns only exact safe dynamic hosts" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            Import-Module $modulePath -Force

            $result = Get-OpenPathCaptivePortalDynamicHosts -SeedUrls @(
                'https://Login.Wedu.Example/start',
                '<script src="https://cdn.wedu.example/app.js"></script>',
                '<form action="https://auth.wedu.example/login"></form>',
                'fetch("https://api.wedu.example/session")',
                'https://*.wedu.example/path',
                'https://10.77.0.1/login',
                'https://printer.local/setup',
                'https://intranet/',
                'https://detectportal.firefox.com/success.txt'
            )

            @($result.bootstrapHosts) | Should -Contain 'login.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'cdn.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'auth.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'api.wedu.example'
            @($result.resourceHosts) | Should -Contain 'cdn.wedu.example'
            @($result.resourceHosts) | Should -Contain 'auth.wedu.example'
            @($result.resourceHosts) | Should -Contain 'api.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain '*.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain '10.77.0.1'
            @($result.bootstrapHosts) | Should -Not -Contain 'printer.local'
            @($result.bootstrapHosts) | Should -Not -Contain 'intranet'
            @($result.bootstrapHosts) | Should -Not -Contain 'detectportal.firefox.com'
            $result.discoveryTruncated | Should -BeFalse
        }

        It "Behaviorally separates bootstrap, redirect, and resource hosts without leaking URLs" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            Import-Module $modulePath -Force

            $result = Get-OpenPathCaptivePortalBootstrapHosts -SeedUrls @(
                'http://bootstrap.wedu.example/start?token=secret',
                'https://redirect.wedu.example/login?cookie=session',
                '<script src="https://static.wedu.example/app.js?auth=secret"></script>',
                '<form action="https://form.wedu.example/login" method="post"></form>',
                'https://10.77.0.1/login',
                'https://printer.local/setup',
                'https://intranet/',
                'https://detectportal.firefox.com/success.txt'
            )

            @($result.bootstrapHosts) | Should -Contain 'bootstrap.wedu.example'
            @($result.redirectHosts) | Should -Contain 'redirect.wedu.example'
            @($result.resourceHosts) | Should -Contain 'static.wedu.example'
            @($result.resourceHosts) | Should -Contain 'form.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'redirect.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'static.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'form.wedu.example'
            @($result.redirectHosts) | Should -Not -Contain 'static.wedu.example'
            @($result.redirectHosts) | Should -Not -Contain 'form.wedu.example'
            @($result.resourceHosts) | Should -Not -Contain 'bootstrap.wedu.example'
            @($result.resourceHosts) | Should -Not -Contain 'redirect.wedu.example'
            @($result.bootstrapHosts + $result.redirectHosts + $result.resourceHosts) | Should -Not -Contain '10.77.0.1'
            @($result.bootstrapHosts + $result.redirectHosts + $result.resourceHosts) | Should -Not -Contain 'printer.local'
            @($result.bootstrapHosts + $result.redirectHosts + $result.resourceHosts) | Should -Not -Contain 'intranet'
            @($result.bootstrapHosts + $result.redirectHosts + $result.resourceHosts) | Should -Not -Contain 'detectportal.firefox.com'
            (($result | ConvertTo-Json -Depth 8) -match 'secret|cookie|/login|/start|/app.js') | Should -BeFalse
            $result.truncated | Should -BeFalse
            @($result.errors).Count | Should -BeGreaterThan 0
        }

        It "Classifies fetched redirect-chain hosts by source bucket" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $module = Import-Module $modulePath -Force -PassThru
            $requestFactory = {
                param([System.Uri]$Uri)

                $headers = [System.Net.WebHeaderCollection]::new()
                $body = ''
                if ($Uri.Host -eq 'bootstrap.wedu.example') {
                    $headers['Location'] = 'http://redirect.wedu.example/login?ticket=secret'
                }
                elseif ($Uri.Host -eq 'redirect.wedu.example') {
                    $body = '<script src="https://assets.wedu.example/app.js?token=secret"></script>'
                }

                $response = [PSCustomObject]@{
                    Headers = $headers
                    Stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body))
                }
                $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { return $this.Stream }
                $response | Add-Member -MemberType ScriptMethod -Name Close -Value {
                    if ($this.Stream) { $this.Stream.Dispose() }
                }
                return $response
            }

            $result = & $module {
                param([scriptblock]$RequestFactory)
                Invoke-OpenPathCaptivePortalBootstrapProbe `
                    -SeedUrl 'http://bootstrap.wedu.example/start?seed=secret' `
                    -MaxRedirects 2 `
                    -RequestFactory $RequestFactory
            } $requestFactory

            @($result.bootstrapHosts) | Should -Contain 'bootstrap.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'redirect.wedu.example'
            @($result.bootstrapHosts) | Should -Not -Contain 'assets.wedu.example'
            @($result.redirectHosts) | Should -Contain 'redirect.wedu.example'
            @($result.redirectHosts) | Should -Not -Contain 'assets.wedu.example'
            @($result.resourceHosts) | Should -Contain 'assets.wedu.example'
            (($result | ConvertTo-Json -Depth 8) -match 'secret|/login|/app.js') | Should -BeFalse
        }

        It "Does not promote already-rendered secondary seed probes into bootstrap hosts" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $module = Import-Module $modulePath -Force -PassThru
            $requestFactory = {
                param([System.Uri]$Uri)

                $headers = [System.Net.WebHeaderCollection]::new()
                $body = '<link rel="stylesheet" href="http://assets.wedu-lab.test/portal.css"><script src="http://cdn.wedu-lab.test/portal.js"></script><a href="http://auth.wedu-lab.test/token">Auth</a>'
                if ($Uri.Host -eq 'nce.wedu.comunidad.madrid') {
                    $headers['Location'] = 'http://wlogin.wedu-lab.test/login?continue=http%3A%2F%2Fnce.wedu.comunidad.madrid%2F'
                    $body = ''
                }

                $response = [PSCustomObject]@{
                    Headers = $headers
                    Stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body))
                }
                $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { return $this.Stream }
                $response | Add-Member -MemberType ScriptMethod -Name Close -Value {
                    if ($this.Stream) { $this.Stream.Dispose() }
                }
                return $response
            }

            $result = & $module {
                param([scriptblock]$RequestFactory)
                Get-OpenPathCaptivePortalBootstrapHosts `
                    -SeedUrls @(
                        'http://nce.wedu.comunidad.madrid/',
                        'http://assets.wedu-lab.test/',
                        'http://cdn.wedu-lab.test/',
                        'http://wlogin.wedu-lab.test/',
                        'http://auth.wedu-lab.test/'
                    ) `
                    -FetchSeedUrls `
                    -MaxHttpRedirects 2 `
                    -RequestFactory $RequestFactory
            } $requestFactory

            @($result.bootstrapHosts) | Should -Contain 'nce.wedu.comunidad.madrid'
            @($result.bootstrapHosts) | Should -Not -Contain 'assets.wedu-lab.test'
            @($result.bootstrapHosts) | Should -Not -Contain 'cdn.wedu-lab.test'
            @($result.bootstrapHosts) | Should -Not -Contain 'wlogin.wedu-lab.test'
            @($result.bootstrapHosts) | Should -Not -Contain 'auth.wedu-lab.test'
            @($result.redirectHosts) | Should -Contain 'wlogin.wedu-lab.test'
            @($result.resourceHosts) | Should -Contain 'assets.wedu-lab.test'
            @($result.resourceHosts) | Should -Contain 'cdn.wedu-lab.test'
            @($result.resourceHosts) | Should -Contain 'auth.wedu-lab.test'
        }

        It "Keeps fetched redirect and resource bootstrap hosts in distinct result fields" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $probeStart = $moduleContent.IndexOf('function Invoke-OpenPathCaptivePortalBootstrapProbe')
            $runtimeStart = $moduleContent.IndexOf('function Get-OpenPathCaptivePortalRuntimeOverlayHosts')
            $probeBody = $moduleContent.Substring($probeStart, $runtimeStart - $probeStart)
            $helperStart = $moduleContent.IndexOf('function Get-OpenPathCaptivePortalBootstrapHosts')
            $seedStart = $moduleContent.IndexOf('function Get-OpenPathCaptivePortalBootstrapSeedUrls')
            $helperBody = $moduleContent.Substring($helperStart, $seedStart - $helperStart)

            Assert-ContentContainsAll -Content $probeBody -Needles @(
                '$redirectHosts = [System.Collections.Generic.List[string]]::new()',
                '$resourceHosts = [System.Collections.Generic.List[string]]::new()',
                '$isBootstrapRequest = ($attempt -eq 0)',
                '$redirectHosts.Add($redirectHost)',
                '$resourceHosts.Add($textHost)',
                'redirectHosts = @($redirectHosts)',
                'resourceHosts = @($resourceHosts)'
            )
            Assert-ContentContainsAll -Content $helperBody -Needles @(
                '$probe.redirectHosts',
                '$probe.resourceHosts',
                '-Kind ''resource'''
            )
        }

        It "Includes bootstrap and runtime overlay hosts in limited Acrylic rendering before NX block" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $enableBody -Needles @(
                'Get-OpenPathCaptivePortalDynamicHosts',
                'Get-OpenPathCaptivePortalBootstrapSeedUrls',
                '$dynamicHosts.bootstrapHosts',
                '$dynamicHosts.redirectHosts',
                '$dynamicHosts.resourceHosts',
                '$dynamicHosts.observedRuntimeHosts',
                '$dynamicHosts.pendingRuntimeHosts',
                '$dynamicHosts.discoveryTruncated',
                '-FetchSeedUrls',
                'Set-OpenPathCaptivePortalMarker -State $State -Mode limited',
                '-BootstrapHosts',
                '-RedirectHosts',
                '-ResourceHosts',
                '-ObservedRuntimeHosts',
                '-PendingRuntimeHosts',
                '-DiscoveryTruncated',
                '-FallbackMode'
            )

            $enableBody.IndexOf('$dynamicHosts.bootstrapHosts') |
                Should -BeLessThan $enableBody.IndexOf('New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody.IndexOf('$dynamicHosts.observedRuntimeHosts') |
                Should -BeLessThan $enableBody.IndexOf('New-OpenPathLimitedCaptivePortalHostsDefinition')
        }

        It "Performs a bounded second limited-mode render after initial Acrylic bootstrap discovery" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $enableBody -Needles @(
                '$script:CaptivePortalBootstrapMaxIterations',
                'for ($bootstrapIteration = 0',
                'Get-OpenPathCaptivePortalBootstrapHosts',
                '$bootstrapDiscovery.redirectHosts',
                '$bootstrapDiscovery.resourceHosts',
                '$bootstrapDiscovery.truncated',
                '$limitedModeReady = (',
                '-LimitedModeReady $limitedModeReady'
            )

            $enableBody | Should -Match '(?s)for \(\$bootstrapIteration = 0.*?New-OpenPathLimitedCaptivePortalHostsDefinition.*?Restart-AcrylicService.*?Get-OpenPathCaptivePortalBootstrapHosts'
        }

        It "Does not mark limited mode ready when final bootstrap discovery was not rendered" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $enableBody -Needles @(
                '$renderedHosts = @($mergedHosts)',
                '$pendingDiscoveredHostsAfterRender',
                '$hostName -notin $renderedHosts',
                '$allowedMarkerHosts = @($renderedHosts)',
                '@($pendingDiscoveredHostsAfterRender).Count -eq 0'
            )
        }

        It "Bounds limited portal Acrylic restart and DNS protection verification inside native host budget" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                '$script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds',
                '$script:CaptivePortalLimitedModeDnsMaxAttempts',
                '$script:CaptivePortalLimitedModeDnsDelayMilliseconds',
                '$script:CaptivePortalLimitedModeDnsAttemptTimeoutSeconds',
                'Restart-AcrylicService -TimeoutSeconds $script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds -SkipBatchFallback',
                'Test-OpenPathLimitedCaptivePortalProtection -PortalRecoveryDomains $renderedHosts -DnsMaxAttempts $script:CaptivePortalLimitedModeDnsMaxAttempts -DnsDelayMilliseconds $script:CaptivePortalLimitedModeDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $script:CaptivePortalLimitedModeDnsAttemptTimeoutSeconds'
            )

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            $enableBody.IndexOf('Restart-AcrylicService -TimeoutSeconds $script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds -SkipBatchFallback') |
                Should -BeLessThan $enableBody.IndexOf('Test-OpenPathLimitedCaptivePortalProtection -PortalRecoveryDomains $renderedHosts')
            $enableBody | Should -Match '(?s)if \(-not \(\[bool\]\$restartSucceeded\)\).*?Restore-OpenPathLimitedCaptivePortalAttempt.*?return \$false'
        }

        It "Treats transport failures as captive portal when local IPv4 network evidence exists" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'function Test-OpenPathPotentialCaptiveNetwork',
                'Get-NetAdapter -ErrorAction SilentlyContinue',
                'Get-NetRoute -DestinationPrefix ''0.0.0.0/0'' -ErrorAction SilentlyContinue',
                '$transportFail -ge $total',
                'Test-OpenPathPotentialCaptiveNetwork',
                'return ''Portal'''
            )
        }

        It "Restores DNS protection after captive portal is resolved" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $scriptContent = Get-Content $scriptPath -Raw
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                'Disable-OpenPathCaptivePortalMode',
                'Test-OpenPathCaptivePortalModeActive'
            )

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'Captive portal resolved',
                'restoring DNS protection',
                'Restore-OpenPathProtectedMode -Config $Config',
                'keeping captive portal marker active',
                'Test-DNSResolution',
                'Test-DNSSinkhole -Domain ''this-should-be-blocked-test-12345.com''',
                '$firewallExpected = [bool]$Config.enableFirewall',
                'Test-FirewallActive',
                'Clear-OpenPathCaptivePortalMarker'
            )

            $moduleContent | Should -Not -Match 'Disable-OpenPathCaptivePortalMode[\\s\\S]*Restore-OpenPathProtectedMode -Config \\$Config -SkipAcrylicRestart'
        }

        It "Does not treat a missing marker as restored while Acrylic remains in portal recovery mode" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $disableStart = $moduleContent.IndexOf('function Disable-OpenPathCaptivePortalMode')
            $exportStart = $moduleContent.IndexOf('Export-ModuleMember')
            $disableBody = $moduleContent.Substring($disableStart, $exportStart - $disableStart)

            $disableBody | Should -Not -Match '(?s)if \(-not \(Test-Path \$script:CaptivePortalStatePath\)\)\s*\{\s*return \$true\s*\}'
            Assert-ContentContainsAll -Content $disableBody -Needles @(
                '$markerPresentAtStart = Test-Path $script:CaptivePortalStatePath',
                'no captive portal marker exists but protected mode is still not restored',
                'Get-OpenPathCaptivePortalProtectedModeExitEvidence',
                'Restore-OpenPathCaptivePortalAcrylicHostState',
                'Restore-OpenPathProtectedMode -Config $Config'
            )
        }

        It "Verifies limited portal recovery with exact temporary hosts instead of a generic DNS probe" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $protectionStart = $moduleContent.IndexOf('function Test-OpenPathLimitedCaptivePortalProtection')
            $restoreStart = $moduleContent.IndexOf('function Restore-OpenPathCaptivePortalAcrylicHostState')
            $protectionBody = $moduleContent.Substring($protectionStart, $restoreStart - $protectionStart)

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'function Test-OpenPathLimitedCaptivePortalRecoveryHost',
                'Test-OpenPathLimitedCaptivePortalRecoveryHost -Domain $recoveryHost',
                'Test-OpenPathLimitedCaptivePortalProtection -PortalRecoveryDomains $renderedHosts',
                'Get-AcrylicExactForwardRule -Domain $Domain',
                '$match.Index -lt $defaultBlockIndex'
            )
            Assert-ContentContainsAll -Content $protectionBody -Needles @(
                '[string[]]$PortalRecoveryDomains = @()',
                'Get-OpenPathCaptivePortalAllowedHosts -Hosts $PortalRecoveryDomains',
                '$recoveryHost',
                'NX \*'
            )
            Assert-ContentContainsAll -Content $protectionBody -Needles @(
                'Get-OpenPathCaptivePortalAllowedHosts -Hosts $PortalRecoveryDomains',
                'Test-OpenPathLimitedCaptivePortalRecoveryHost -Domain $recoveryHost'
            )
            $protectionBody | Should -Not -Match 'Test-DNSResolution'
            $protectionBody | Should -Not -Match 'Test-DNSSinkhole'
            $protectionBody | Should -Not -Match 'Test-FirewallActive'
            $protectionBody.Contains("if ((Get-Command -Name 'Test-FirewallActive' -ErrorAction SilentlyContinue) -and -not (Test-FirewallActive))") |
                Should -BeFalse
        }

        It "Bounds post-auth reconcile protected-mode evidence inside native host budget" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $scriptContent = Get-Content $scriptPath -Raw
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                '$RecoveryDnsMaxAttempts',
                '$RecoveryDnsDelayMilliseconds',
                '$RecoveryDnsAttemptTimeoutSeconds',
                'Disable-OpenPathCaptivePortalMode -DnsMaxAttempts $RecoveryDnsMaxAttempts -DnsDelayMilliseconds $RecoveryDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $RecoveryDnsAttemptTimeoutSeconds',
                'Get-OpenPathCaptivePortalProtectedModeExitEvidence -DnsMaxAttempts $RecoveryDnsMaxAttempts -DnsDelayMilliseconds $RecoveryDnsDelayMilliseconds -DnsAttemptTimeoutSeconds $RecoveryDnsAttemptTimeoutSeconds'
            )

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'function Get-OpenPathCaptivePortalProtectedModeExitEvidence',
                '[int]$DnsAttemptTimeoutSeconds = 0',
                'Test-DNSResolution -MaxAttempts $DnsMaxAttempts -DelayMilliseconds $DnsDelayMilliseconds -AttemptTimeoutSeconds $DnsAttemptTimeoutSeconds',
                'Test-DNSSinkhole -Domain ''this-should-be-blocked-test-12345.com'' -AttemptTimeoutSeconds $DnsAttemptTimeoutSeconds',
                'function Disable-OpenPathCaptivePortalMode',
                '[int]$DnsMaxAttempts = 12',
                '[int]$DnsDelayMilliseconds = 1000',
                '[int]$DnsAttemptTimeoutSeconds = 0'
            )
        }

        It "Writes post-auth reconcile success only when protected mode is fully restored" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Invoke-OpenPathCaptivePortalAuthenticatedRestore',
                '$protectedModeRestored = ([bool]$disabled -and [bool]$postAuthEvidence.protectedModeRestored)',
                'success = $protectedModeRestored',
                'portalExitRoute = if ($protectedModeRestored) { "$Operation-authenticated" } else { "$Operation-authenticated-restore-failed" }',
                'protectedModeRestored = [bool]$postAuthEvidence.protectedModeRestored',
                'Invoke-OpenPathCaptivePortalAuthenticatedRestore -RequestId $requestId -Operation $operation -ResultPath $ResultPath -ProgressPath $ProgressPath',
                'Invoke-OpenPathCaptivePortalAuthenticatedRestore -RequestId $requestId -Operation $operation -ResultPath $ResultPath -ProgressPath $ProgressPath -TriggerHost $triggerHost'
            )
            $content | Should -Not -Match 'success = \$disabled\s+operation = \$operation'
        }

        It "Closes any active captive portal marker immediately on authenticated detection and preserves the marker when restore fails" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $helperContent = Get-Content $helperPath -Raw
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                '$markerMode',
                '$markerMode -ne ''''',
                '$captiveState -eq ''Authenticated''',
                'Disable-OpenPathCaptivePortalMode -Config $Config',
                'failed to close authenticated captive portal mode; marker preserved'
            )

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'keeping captive portal marker active',
                'protectedModeRestored',
                'markerCleared'
            )
        }

        It "Runs passthrough emergency checks even when protected mode checks are otherwise skipped" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Invoke-OpenPathCaptivePortalPassthroughEmergencyChecks',
                'Get-OpenPathCaptivePortalMarker',
                'Get-OpenPathActiveIpv4AdaptersMissingLocalDns',
                '$shouldRunProtectedModeChecks = [bool]$policyState.ProtectedModeEligible',
                'Disable-OpenPathCaptivePortalMode -Config $Config'
            )
        }

        It "Treats passthrough expiry as an emergency close and verifies full protected-mode restoration before clearing state" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'passthrough deadline expired',
                'failed to close expired captive portal passthrough marker',
                'Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue',
                '127.0.0.1',
                'CAPTIVE PORTAL RECOVERY',
                'acrylicNormalRestored',
                'localDnsLoopbackRestored',
                'markerCleared',
                'firewallExpectedActive',
                'firewallHealthy',
                'protectedModeRestored'
            )
            $content | Should -Not -Match 'Disable-OpenPathCaptivePortalMode[\s\S]*Restore-OriginalDNS'
        }

        It "Uses hysteresis before entering or exiting captive portal mode" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $helperContent = Get-Content $helperPath -Raw
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'captive-portal-observation.json',
                'Update-OpenPathCaptivePortalObservation',
                '[int]$EnterPortalCount = 2',
                '[int]$ExitAuthenticatedCount = 1',
                '$DetectedState -eq ''Portal''',
                '$DetectedState -eq ''Authenticated''',
                'portalAgeSeconds',
                'minimumPortalElapsed',
                'shouldExitPortal',
                'PortalAgeSeconds',
                'AuthenticatedCount'
            )

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'Update-OpenPathCaptivePortalObservation -DetectedState $captiveState',
                '$portalObservation.ShouldEnterPortal',
                '$portalObservation.ShouldExitPortal',
                'PortalSince = $portalObservation.PortalSince',
                'PortalAgeSeconds = $portalObservation.PortalAgeSeconds',
                'AuthenticatedCount = $portalObservation.AuthenticatedCount',
                'MinimumPortalElapsed = $portalObservation.MinimumPortalElapsed',
                'ShouldExitPortal = $portalObservation.ShouldExitPortal'
            )

            $helperContent | Should -Not -Match "if \\(\\$captiveState -eq 'Portal'\\)"
            $helperContent | Should -Not -Match "\\$captiveState -eq 'NoNetwork'.*Enable-OpenPathCaptivePortalMode"
            $moduleContent | Should -Not -Match 'MinimumPortalSeconds\\s*=\\s*180'
            $moduleContent | Should -Not -Match 'authenticatedCount\\s+-ge\\s+\\$ExitAuthenticatedCount\\s+-and\\s+\\$minimumPortalElapsed'
        }

        It "Caps limited mode marker TTL to the bounded post-auth backstop" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                '$limitedModeTtlSeconds = [Math]::Min([Math]::Max(1, $TtlSeconds), 120)',
                '-TtlSeconds $limitedModeTtlSeconds'
            )
        }
    }

    Context "Integrity checks" {
        It "Verifies baseline integrity and handles tampering" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Test-OpenPathIntegrity',
                'Restore-OpenPathIntegrity',
                'TAMPERED'
            )
        }

        It "Protects runtime and native update helpers in the integrity baseline" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Integrity.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$script:OpenPathRoot\lib\Update.Runtime.psm1',
                '$script:OpenPathRoot\lib\internal\CapabilityStorage.ps1',
                '$script:OpenPathRoot\lib\internal\NativeHost.Actions.ps1',
                '$script:OpenPathRoot\lib\internal\EndpointStateReconciler.ps1',
                '$script:OpenPathRoot\lib\internal\Watchdog.Runtime.ps1'
            )
        }
    }

    Context "Watchdog health states" {
        It "Uses the shared endpoint reconciler for protected DNS and firewall repair ordering" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $stateHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointPolicyState.ps1"
            $reconcilerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointStateReconciler.ps1"
            $helperContent = Get-Content $helperPath -Raw
            $stateContent = Get-Content $stateHelperPath -Raw
            $reconcilerContent = Get-Content $reconcilerPath -Raw

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'EndpointPolicyState.ps1',
                'EndpointStateReconciler.ps1',
                'Get-OpenPathEndpointPolicyState',
                'New-OpenPathWatchdogProtectedModeRepairPlan',
                'Invoke-OpenPathEndpointStateRepairPlan'
            )

            Assert-ContentContainsAll -Content $stateContent -Needles @(
                'function Get-OpenPathEndpointPolicyState',
                'FailOpenActive',
                'ProtectedModeEligible'
            )

            Assert-ContentContainsAll -Content $reconcilerContent -Needles @(
                'function New-OpenPathWatchdogProtectedModeRepairPlan',
                'StartAcrylicService',
                'RestartAcrylicService',
                'SetOpenPathFirewall',
                'SetLocalDns'
            )
        }

        It "Reports FAIL_OPEN, STALE_FAILSAFE and CRITICAL states" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $helperContent = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathWatchdogOutcome',
                'Send-OpenPathHealthReport'
            )

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'FAIL_OPEN',
                'STALE_FAILSAFE',
                'CRITICAL'
            )
        }

        It "Does not repair protected DNS or firewall while the local fail-open marker is active" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $helperContent = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '-FailOpenActive $checkResult.FailOpenActive'
            )

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                '$policyState = Get-OpenPathEndpointPolicyState',
                '$shouldRunProtectedModeChecks = [bool]$policyState.ProtectedModeEligible',
                'Watchdog: local fail-open whitelist marker active; skipping protected-mode DNS/firewall recovery',
                'FailOpenActive = [bool]$policyState.FailOpenActive',
                '$status = ''FAIL_OPEN''',
                'fail_open_active'
            )
        }

        It "Repairs local DNS when any active IPv4 adapter is missing loopback DNS" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $reconcilerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointStateReconciler.ps1"
            $helperContent = Get-Content $helperPath -Raw
            $reconcilerContent = Get-Content $reconcilerPath -Raw

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'function Get-OpenPathActiveIpv4AdaptersMissingLocalDns',
                'Get-NetAdapter -ErrorAction SilentlyContinue',
                'Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $interfaceIndex',
                'active IPv4 adapters missing local DNS',
                '-AffectedLocalDnsAdapterNames $affectedAdapterNames',
                '$shouldRunProtectedModeChecks'
            )

            Assert-ContentContainsAll -Content $reconcilerContent -Needles @(
                '[string[]]$AffectedLocalDnsAdapterNames = @()',
                '$adapterSuffix',
                '$actions += ''SetLocalDns'''
            )
        }
    }

    Context "DNS probe selection" {
        It "Relies on the shared DNS probe instead of a hard-coded public domain" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $helperContent = Get-Content $helperPath -Raw

            $content.Contains('Test-DNSResolution -Domain "google.com"') | Should -BeFalse
            Assert-ContentContainsAll -Content $content -Needles @(
                '. (Join-Path $OpenPathRoot ''lib\internal\Watchdog.Runtime.ps1'')',
                'Invoke-OpenPathWatchdogChecks'
            )
            $helperContent.Contains('(Test-DNSResolution)') | Should -BeTrue
        }
    }

    Context "Checkpoint recovery" {
        It "Attempts checkpoint recovery when watchdog reaches CRITICAL" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $helperContent = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathWatchdogOutcome'
            )

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'enableCheckpointRollback',
                'Restore-CheckpointFromWatchdog',
                'Checkpoint rollback restored DNS state'
            )
        }

        It "Does not let SSE listener failures alone trigger checkpoint rollback" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $helperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$recoveryEligibleIssues = @()',
                '$shouldIncrementFailCount = $status -eq ''DEGRADED'' -and $RecoveryEligibleIssues.Count -gt 0',
                '$issues += "SSE listener not running"'
            )
            $content.Contains('$recoveryEligibleIssues += "SSE listener not running"') | Should -BeFalse
        }
    }
}
