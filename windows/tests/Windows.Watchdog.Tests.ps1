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

        It "Behaviorally includes configured captive portal domains in recovery results" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            . (Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.RecoveryTransition.ps1")
            $content = Get-Content $scriptPath -Raw
            $start = $content.IndexOf('function Get-OpenPathRecoveryUtcNow')
            $end = $content.IndexOf('$queuePath = Get-OpenPathCapabilityStoragePath')
            . ([scriptblock]::Create($content.Substring($start, $end - $start)))

            $requestPath = Join-Path $TestDrive 'request.json'
            $resultPath = Join-Path $TestDrive 'result'
            $progressPath = Join-Path $TestDrive 'progress'
            @{
                requestId = 'configured-domain-request'
                triggerHost = 'detectportal.firefox.com'
            } | ConvertTo-Json -Depth 4 | Set-Content -Path $requestPath -Encoding UTF8
            (Get-Item $requestPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)

            function Get-OpenPathCaptivePortalRecoveryState { return 'Portal' }
            function Update-OpenPathCaptivePortalObservation { return $true }
            function Enable-OpenPathCaptivePortalMode { return $true }
            function Get-OpenPathCaptivePortalMarker {
                [PSCustomObject]@{
                    mode = 'limited'
                    allowedHosts = @('detectportal.firefox.com')
                    limitedModeReady = $true
                    discoveryTruncated = $false
                    fallbackMode = 'none'
                    pendingRuntimeHosts = @()
                }
            }
            function Get-OpenPathCaptivePortalAllowedHosts {
                param([string[]]$Hosts = @())

                @($Hosts | ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
            }
            function Get-OpenPathConfiguredCaptivePortalDomains {
                @('nce.wedu.comunidad.madrid')
            }
            function Get-OpenPathRecentCaptivePortalRecoverySuccess {
                return $null
            }

            $envelope = [PSCustomObject]@{
                File = Get-Item $requestPath
                Request = (Get-Content $requestPath -Raw | ConvertFrom-Json)
            }

            Invoke-OpenPathCaptivePortalRecoveryRequest -RequestEnvelope $envelope -ResultPath $resultPath -ProgressPath $progressPath -NowUtc ([DateTime]::UtcNow)

            $result = Get-Content (Join-Path $resultPath 'configured-domain-request.json') -Raw | ConvertFrom-Json
            @($result.effectiveExactHosts) | Should -Contain 'detectportal.firefox.com'
            @($result.effectiveExactHosts) | Should -Contain 'nce.wedu.comunidad.madrid'
            @($result.configuredCaptivePortalDomains) | Should -Be @('nce.wedu.comunidad.madrid')
            $result.configuredCaptivePortalDomainsApplied | Should -BeFalse
        }

        It "Restores protected mode when reconcile request reports authenticated state" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $content = Get-Content $scriptPath -Raw
            $start = $content.IndexOf('function Get-OpenPathRecoveryUtcNow')
            $end = $content.IndexOf('$queuePath = Get-OpenPathCapabilityStoragePath')
            . ([scriptblock]::Create($content.Substring($start, $end - $start)))

            $requestPath = Join-Path $TestDrive 'request-authenticated.json'
            $resultPath = Join-Path $TestDrive 'result-authenticated'
            $progressPath = Join-Path $TestDrive 'progress-authenticated'
            @{
                requestId = 'authenticated-reconcile-request'
                operation = 'reconcile'
                portalState = 'authenticated'
            } | ConvertTo-Json -Depth 4 | Set-Content -Path $requestPath -Encoding UTF8
            (Get-Item $requestPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)

            function Get-OpenPathCaptivePortalRecoveryState { return 'Portal' }
            function Update-OpenPathCaptivePortalObservation { return $true }
            function Disable-OpenPathCaptivePortalMode { return $true }
            function Test-OpenPathCaptivePortalModeActive { return $false }
            function Get-OpenPathCaptivePortalAllowedHosts {
                param([string[]]$Hosts = @())

                @($Hosts | ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
            }
            function Get-OpenPathCaptivePortalProtectedModeExitEvidence {
                [PSCustomObject]@{
                    protectedModeRestored = $true
                    localDnsLoopbackRestored = $true
                    acrylicNormalRestored = $true
                    dnsResolutionHealthy = $true
                    sinkholeHealthy = $true
                    firewallExpectedActive = $false
                    firewallHealthy = $false
                    markerCleared = $true
                }
            }

            $envelope = [PSCustomObject]@{
                File = Get-Item $requestPath
                Request = (Get-Content $requestPath -Raw | ConvertFrom-Json)
            }

            Invoke-OpenPathCaptivePortalRecoveryRequest -RequestEnvelope $envelope -ResultPath $resultPath -ProgressPath $progressPath -NowUtc ([DateTime]::UtcNow)

            $result = Get-Content (Join-Path $resultPath 'authenticated-reconcile-request.json') -Raw | ConvertFrom-Json
            $result.success | Should -BeTrue
            $result.state | Should -Be 'Authenticated'
            $result.portalModeActive | Should -BeFalse
            $result.portalExitRoute | Should -Be 'reconcile-authenticated'
            $result.protectedModeRestored | Should -BeTrue
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
                'Write-AcrylicHostsFile -Path $hostsPath -Content $content',
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
            $diagnosticsModulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.DiagnosticsDiscovery.ps1"
            $moduleContent = Get-Content $modulePath -Raw
            $diagnosticsModuleContent = Get-Content $diagnosticsModulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                "internal\CaptivePortal.DiagnosticsDiscovery.ps1",
                'Get-OpenPathCaptivePortalDynamicHosts',
                'discoveryTruncated',
                'bootstrapHosts',
                'observedRuntimeHosts',
                'pendingRuntimeHosts',
                'fallbackMode',
                'limitedModeReady'
            )

            Assert-ContentContainsAll -Content $diagnosticsModuleContent -Needles @(
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

            Assert-ContentContainsAll -Content $diagnosticsModuleContent -Needles @(
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

        It "Behaviorally reads only safe configured captive portal domains from config" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $module = Import-Module $modulePath -Force -PassThru

            $result = & $module {
                function Get-OpenPathConfig {
                    [PSCustomObject]@{
                        captivePortalDomains = @(
                            ' NCE.WEDU.COMUNIDAD.MADRID. ',
                            'nce.wedu.comunidad.madrid',
                            'login.example.test',
                            'https://portal.example/login',
                            '*.example.test',
                            '10.77.0.1',
                            'printer.local',
                            'intranet'
                        )
                    }
                }

                Get-OpenPathConfiguredCaptivePortalDomains
            }

            @($result) | Should -Be @('nce.wedu.comunidad.madrid', 'login.example.test')
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
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.DiagnosticsDiscovery.ps1"
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

        It "Renders limited Acrylic from declared captive portal hosts before NX block" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $enableBody -Needles @(
                '$baseRecoveryHosts = @(Get-OpenPathCaptivePortalAllowedHosts -Hosts (@($existingHosts) + @($AllowedHosts) + @($configuredCaptivePortalDomains)))',
                '$renderedHosts = @($baseRecoveryHosts)',
                'New-OpenPathLimitedCaptivePortalHostsDefinition -PortalRecoveryDomains $renderedHosts',
                'Set-OpenPathCaptivePortalMarker -State $State -Mode limited',
                '-BootstrapHosts',
                '-RedirectHosts',
                '-ResourceHosts',
                '-ObservedRuntimeHosts',
                '-PendingRuntimeHosts',
                '-DiscoveryTruncated',
                '-FallbackMode'
            )

            $enableBody | Should -Not -Match 'Get-OpenPathCaptivePortalDynamicHosts'
            $enableBody | Should -Not -Match 'Get-OpenPathCaptivePortalBootstrapHosts'
            $enableBody.IndexOf('$baseRecoveryHosts = @(Get-OpenPathCaptivePortalAllowedHosts') |
                Should -BeLessThan $enableBody.IndexOf('New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody.IndexOf('$renderedHosts = @($baseRecoveryHosts)') |
                Should -BeLessThan $enableBody.IndexOf('New-OpenPathLimitedCaptivePortalHostsDefinition')
        }

        It "Behaviorally applies configured captive portal domains in limited mode markers" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $module = Import-Module $modulePath -Force -PassThru
            $statePath = Join-Path $TestDrive "captive-portal-active.json"
            $acrylicPath = Join-Path $TestDrive "Acrylic"
            New-Item -ItemType Directory -Path $acrylicPath -Force | Out-Null

            $marker = & $module {
                param([string]$StatePath, [string]$AcrylicPath)

                $script:CaptivePortalStatePath = $StatePath
                $script:TestAcrylicPath = $AcrylicPath

                function Get-OpenPathConfig {
                    [PSCustomObject]@{
                        captivePortalDomains = @('NCE.WEDU.COMUNIDAD.MADRID')
                    }
                }
                function Get-AcrylicPath { return $script:TestAcrylicPath }
                function Resolve-OpenPathCaptivePortalUpstreamDns {
                    [PSCustomObject]@{
                        Address = '192.0.2.53'
                        Source = 'test'
                        UsableForLimited = $true
                        Verified = $true
                    }
                }
                function Set-OpenPathLimitedCaptivePortalAcrylicConfiguration { return $true }
                function Set-LocalDNS { return $true }
                function Restart-AcrylicService { return $true }
                function Test-OpenPathLimitedCaptivePortalProtection { return $true }
                function Get-OpenPathCaptivePortalBootstrapHosts {
                    [PSCustomObject]@{
                        bootstrapHosts = @()
                        redirectHosts = @()
                        resourceHosts = @()
                        truncated = $false
                        errors = @()
                    }
                }

                Enable-OpenPathCaptivePortalLimitedMode -State Portal -AllowedHosts @('detectportal.firefox.com') -TtlSeconds 60 | Out-Null
                Get-OpenPathCaptivePortalMarker
            } $statePath $acrylicPath

            @($marker.allowedHosts) | Should -Be @('detectportal.firefox.com', 'nce.wedu.comunidad.madrid')
            @($marker.configuredCaptivePortalDomains) | Should -Be @('nce.wedu.comunidad.madrid')
            $marker.configuredCaptivePortalDomainsApplied | Should -BeTrue
        }

        It "Renders configured captive portal domains with subdomain coverage in limited mode while keeping discovered hosts exact" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $module = Import-Module $modulePath -Force -PassThru

            # 'redirect.example.test' is an auto-discovered recovery host (not admin-configured,
            # not an essential domain); 'nce.wedu.comunidad.madrid' is the admin-configured portal domain.
            $content = & $module {
                function Get-OpenPathConfiguredCaptivePortalDomains { @('nce.wedu.comunidad.madrid') }

                $definition = New-OpenPathLimitedCaptivePortalHostsDefinition `
                    -PortalRecoveryDomains @('redirect.example.test', 'nce.wedu.comunidad.madrid') `
                    -UpstreamDns '192.0.2.53'
                ConvertTo-AcrylicHostsContent -Definition $definition
            }

            # Admin-configured portal domain: must cover the host AND all subdomains.
            $content | Should -Match 'FW nce\.wedu\.comunidad\.madrid'
            $content | Should -Match 'FW >nce\.wedu\.comunidad\.madrid'
            # Auto-discovered recovery host: stays exact (no descendant forward).
            $content | Should -Match 'FW redirect\.example\.test'
            $content | Should -Not -Match 'FW >redirect\.example\.test'
            # Default block must still come last so everything else is NXDOMAIN'd.
            $content.IndexOf('FW >nce.wedu.comunidad.madrid') | Should -BeLessThan $content.IndexOf('NX *')
        }

        It "Performs one limited-mode render without bootstrap discovery promotion" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $enableBody -Needles @(
                '$renderedHosts = @($baseRecoveryHosts)',
                'New-OpenPathLimitedCaptivePortalHostsDefinition -PortalRecoveryDomains $renderedHosts',
                'Restart-AcrylicService -TimeoutSeconds $script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds -SkipBatchFallback',
                'Test-OpenPathLimitedCaptivePortalProtection -PortalRecoveryDomains $renderedHosts',
                '$limitedModeReady = (',
                '-LimitedModeReady $limitedModeReady'
            )

            $enableBody | Should -Not -Match 'for \(\$bootstrapIteration = 0'
            $enableBody | Should -Not -Match 'Get-OpenPathCaptivePortalBootstrapHosts'
            $enableBody.IndexOf('New-OpenPathLimitedCaptivePortalHostsDefinition') |
                Should -BeLessThan $enableBody.IndexOf('Restart-AcrylicService -TimeoutSeconds $script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds -SkipBatchFallback')
        }

        It "Marks limited mode ready only when declared recovery hosts are rendered" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $enableBody -Needles @(
                '$declaredRecoveryHostsApplied = ($baseRecoveryHosts.Count -gt 0)',
                'foreach ($hostName in @($baseRecoveryHosts))',
                '$allowedMarkerHosts = @($renderedHosts)',
                '$limitedModeReady = ($declaredRecoveryHostsApplied -and $configuredCaptivePortalDomainsApplied)'
            )
            $enableBody | Should -Not -Match 'pendingDiscoveredHostsAfterRender'
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

        It "Stays fail-closed and retries instead of downgrading to passthrough when limited DNS verification fails" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $enableBody -Needles @(
                'captive portal limited mode verification failed; staying protected and retrying next cycle',
                'Restore-OpenPathLimitedCaptivePortalAttempt',
                '-LimitedModeReady $false'
            )
            # A failed limited verification must never open the machine: after the
            # verification call there is no passthrough downgrade left in the body.
            $limitedVerificationIndex = $enableBody.IndexOf('Test-OpenPathLimitedCaptivePortalProtection -PortalRecoveryDomains $renderedHosts')
            $limitedVerificationIndex | Should -BeGreaterThan 0
            $enableBody.Substring($limitedVerificationIndex) | Should -Not -Match 'Enable-OpenPathCaptivePortalPassthroughMode'
        }

        It "Reserves the passthrough fallback for the no-recovery-hosts case only" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $passthroughStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalPassthroughMode')
            $limitedStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $passthroughBody = $moduleContent.Substring($passthroughStart, $limitedStart - $passthroughStart)
            $limitedBody = $moduleContent.Substring($limitedStart, $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition') - $limitedStart)

            Assert-ContentContainsAll -Content $passthroughBody -Needles @(
                '[switch]$ForcePassthrough',
                'if (-not $ForcePassthrough -and $ExistingMarker -and (Get-OpenPathCaptivePortalMarkerMode -Marker $ExistingMarker) -eq ''limited'')'
            )
            # The only remaining passthrough call in limited mode is the
            # zero-recovery-hosts guard at the top of the function.
            $zeroHostsIndex = $limitedBody.IndexOf('if ($baseRecoveryHosts.Count -le 0)')
            $zeroHostsIndex | Should -BeGreaterThan 0
            $passthroughCallIndex = $limitedBody.IndexOf('Enable-OpenPathCaptivePortalPassthroughMode')
            $passthroughCallIndex | Should -BeGreaterThan $zeroHostsIndex
            $limitedBody.IndexOf('Enable-OpenPathCaptivePortalPassthroughMode', $passthroughCallIndex + 1) | Should -Be -1
        }

        It "Keeps connectivity-probe domains resolvable in the limited-mode affinity mask" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $domainsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Domains.ps1"
            $commonPath = Join-Path $PSScriptRoot ".." "lib" "Common.psm1"
            $moduleContent = Get-Content $modulePath -Raw
            $domainsContent = Get-Content $domainsPath -Raw
            $commonContent = Get-Content $commonPath -Raw

            # Without the probe domains in the limited-mode Acrylic mask the
            # watchdog can never observe 'Authenticated' (every probe
            # transport-fails against a portal-domains-only mask), so the
            # autonomous close after portal login is structurally impossible and
            # the marker survives authentication.
            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'Get-OpenPathCaptivePortalProbeDomains',
                '@(Get-AcrylicExactAffinityMaskEntries -Domains $probeDomains)'
            )
            Assert-ContentContainsAll -Content $domainsContent -Needles @(
                'function Get-OpenPathCaptivePortalProbeDomains',
                'Domains = @(Get-OpenPathCaptivePortalProbeDomains)'
            )
            $commonContent | Should -Match "'Get-OpenPathCaptivePortalProbeDomains',"
        }

        It "Routes limited portal Acrylic writes through the shared atomic writer under the policy lock" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $policyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.AcrylicPolicyTransaction.ps1"
            $moduleContent = Get-Content $modulePath -Raw
            $policyContent = Get-Content $policyPath -Raw
            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                "internal\AcrylicConfigWriter.ps1",
                'Write-AcrylicConfigFile -Path $configPath -Content $iniContent'
            )
            Assert-ContentContainsAll -Content $enableBody -Needles @(
                'Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction -State limitedRecovery',
                'Write-AcrylicHostsFile -Path $hostsPath -Content $content',
                'Set-OpenPathLimitedCaptivePortalAcrylicConfiguration -UpstreamDns ([string]$upstream.Address) -PortalRecoveryDomains $renderedHosts -SkipPolicyStateLock'
            )
            $policyContent | Should -Match 'Invoke-AcrylicPolicyStateLocked -Action'
            $enableBody | Should -Not -Match 'Set-Content -Path \$hostsPath'
        }

        It "Routes Acrylic captive portal changes through named policy transactions" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $policyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.AcrylicPolicyTransaction.ps1"
            $moduleContent = Get-Content $modulePath -Raw
            $policyContent = Get-Content $policyPath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                "internal\CaptivePortal.AcrylicPolicyTransaction.ps1",
                'Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction -State limitedRecovery',
                'Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction -State restoredProtected',
                'Get-OpenPathCaptivePortalAcrylicPolicyState -State normalProtected'
            )
            Assert-ContentContainsAll -Content $policyContent -Needles @(
                "ValidateSet('normalProtected', 'limitedRecovery', 'restoredProtected')",
                'function Invoke-OpenPathCaptivePortalAcrylicPolicyTransaction',
                'Invoke-AcrylicPolicyStateLocked -Action',
                'function Get-OpenPathCaptivePortalAcrylicPolicyState',
                'normalProtected',
                'limitedRecovery',
                'restoredProtected'
            )
        }

        It "Falls back when the global Acrylic policy mutex is inaccessible" {
            $writerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "AcrylicConfigWriter.ps1"
            $writerContent = Get-Content $writerPath -Raw

            Assert-ContentContainsAll -Content $writerContent -Needles @(
                'Invoke-AcrylicPolicyStateFallbackLocked',
                'UnauthorizedAccessException',
                'OpenPathPolicyStateLock.fallback.lock',
                'Acrylic policy global mutex unavailable; using fallback file lock'
            )
        }

        It "Rebuilds limited mode Acrylic configuration from an empty ini file" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $module = Import-Module $modulePath -Force -PassThru
            $acrylicPath = Join-Path $TestDrive "Acrylic-limited-empty"
            New-Item -ItemType Directory -Path $acrylicPath -Force | Out-Null
            $configPath = Join-Path $acrylicPath 'AcrylicConfiguration.ini'
            '' | Set-Content -Path $configPath -Encoding ASCII

            $configContent = & $module {
                param([string]$AcrylicPath)

                function Get-AcrylicPath { return $AcrylicPath }
                function Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') }

                Set-OpenPathLimitedCaptivePortalAcrylicConfiguration -UpstreamDns '192.0.2.53' -PortalRecoveryDomains @('nce.127.0.0.1.sslip.io') | Should -BeTrue
                Get-Content -Path (Join-Path $AcrylicPath 'AcrylicConfiguration.ini') -Raw
            } $acrylicPath

            Assert-ContentContainsAll -Content $configContent -Needles @(
                '[GlobalSection]',
                'PrimaryServerAddress=192.0.2.53',
                'SecondaryServerAddress=192.0.2.53',
                'PrimaryServerPort=53',
                'SecondaryServerPort=53',
                'LocalIPv4BindingAddress=0.0.0.0',
                'LocalIPv4BindingPort=53',
                'PrimaryServerDomainNameAffinityMask=nce.127.0.0.1.sslip.io',
                'SecondaryServerDomainNameAffinityMask=nce.127.0.0.1.sslip.io',
                'IgnoreNegativeResponsesFromPrimaryServer=No',
                'AddressCacheDisabled=No',
                '[AllowedAddressesSection]',
                'IP1=127.*',
                'IP2=::1'
            )
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
                'function Test-OpenPathLimitedCaptivePortalDnsResolution',
                'function Test-OpenPathLimitedCaptivePortalRecoveryHost',
                'Test-OpenPathLimitedCaptivePortalRecoveryHost -Domain $recoveryHost',
                'Test-OpenPathLimitedCaptivePortalDnsResolution -Domain $Domain',
                'Test-OpenPathLimitedCaptivePortalProtection -PortalRecoveryDomains $renderedHosts',
                'Resolve-OpenPathDnsWithRetry -Domain $Domain -Server ''127.0.0.1''',
                'Get-AcrylicExactForwardRule -Domain $Domain',
                '$match.Index -lt $defaultBlockIndex'
            )
            Assert-ContentContainsAll -Content $protectionBody -Needles @(
                '[string[]]$PortalRecoveryDomains = @()',
                'Get-OpenPathCaptivePortalAllowedHosts -Hosts $PortalRecoveryDomains',
                '$recoveryHost',
                'NX \*',
                '-DnsMaxAttempts $DnsMaxAttempts',
                '-DnsAttemptTimeoutSeconds $DnsAttemptTimeoutSeconds'
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

        It "Verifies configured portal domains against the renderer's inclusive rules, not a hardcoded exact FW line" {
            # Regression: New-OpenPathLimitedCaptivePortalHostsDefinition renders configured
            # captive portal domains subdomain-inclusively (sslip hosts get a static mapping
            # plus 'FW >domain' and NO exact 'FW domain' line), so the recovery-host
            # verification must derive its expected lines from the same rule generator or
            # limited mode always rolls back for sslip-based portal fixtures.
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $recoveryHostStart = $moduleContent.IndexOf('function Test-OpenPathLimitedCaptivePortalRecoveryHost')
            $configurationStart = $moduleContent.IndexOf('function Set-OpenPathLimitedCaptivePortalAcrylicConfiguration')
            $recoveryHostBody = $moduleContent.Substring($recoveryHostStart, $configurationStart - $recoveryHostStart)

            Assert-ContentContainsAll -Content $recoveryHostBody -Needles @(
                'Get-OpenPathConfiguredCaptivePortalDomains',
                'Get-AcrylicForwardRules -Domain $Domain',
                'Get-AcrylicExactForwardRule -Domain $Domain',
                'foreach ($expectedRule in $expectedRules)',
                '$match.Index -lt $defaultBlockIndex'
            )
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
            $content | Should -Match 'if \(\$state -eq ''Authenticated''\)\s*\{\s*Invoke-OpenPathCaptivePortalAuthenticatedRestore -RequestId \$requestId -Operation \$operation -ResultPath \$ResultPath -ProgressPath \$ProgressPath -TriggerHost \$triggerHost'
            $content | Should -Not -Match 'if \(\$state -eq ''Authenticated'' -and \(Test-OpenPathCaptivePortalModeActive\)\)'
            $content | Should -Not -Match 'success = \$disabled\s+operation = \$operation'
        }

        It "Retries verified protected-mode restoration before clearing captive portal state" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $disableStart = $moduleContent.IndexOf('function Disable-OpenPathCaptivePortalMode')
            $exportStart = $moduleContent.IndexOf('Export-ModuleMember')
            $disableBody = $moduleContent.Substring($disableStart, $exportStart - $disableStart)

            Assert-ContentContainsAll -Content $disableBody -Needles @(
                '$maxRestoreAttempts = 3',
                'for ($attempt = 1; $attempt -le $maxRestoreAttempts; $attempt++)',
                'Restore-OpenPathCaptivePortalAcrylicHostState',
                'Restore-OpenPathProtectedMode -Config $Config',
                'Get-OpenPathCaptivePortalProtectedModeExitEvidence',
                '$restoreEvidence',
                '$restoreSucceeded = [bool]$restoreEvidence.localPostureRestored',
                '$postRestoreEvidence.localPostureRestored',
                'Clear-OpenPathCaptivePortalMarker',
                '$postClearEvidence.localPostureRestored'
            )

            $disableBody.IndexOf('$restoreSucceeded = [bool]$restoreEvidence.localPostureRestored') |
                Should -BeLessThan ($disableBody.IndexOf('Clear-OpenPathCaptivePortalMarker'))
            $disableBody.IndexOf('$postRestoreEvidence.localPostureRestored') |
                Should -BeLessThan ($disableBody.IndexOf('Clear-OpenPathCaptivePortalMarker'))
            $disableBody | Should -Match 'if \(-not \$restoreSucceeded\)[\s\S]*return \$false'
        }

        It "Never keeps a relaxed posture alive over upstream health when closing portal mode" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            $disableStart = $moduleContent.IndexOf('function Disable-OpenPathCaptivePortalMode')
            $exportStart = $moduleContent.IndexOf('Export-ModuleMember')
            $disableBody = $moduleContent.Substring($disableStart, $exportStart - $disableStart)

            # The exit evidence separates the machine-local posture (loopback DNS,
            # normal Acrylic policy, sinkhole, firewall) from upstream resolution,
            # which is a network condition and must never gate the marker close.
            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                '$localPostureRestored = ($normalProtected -and $sinkholeHealthy -and ((-not $firewallExpected) -or $firewallHealthy))',
                'upstreamHealthy = $dnsResolutionHealthy',
                'localPostureRestored = $localPostureRestored'
            )
            Assert-ContentContainsAll -Content $disableBody -Needles @(
                'portal_closed_upstream_unhealthy'
            )
            $disableBody | Should -Not -Match '\$restoreSucceeded = \[bool\]\$restoreEvidence\.enforcementRestored'
            $disableBody | Should -Not -Match '\$restoreSucceeded = \[bool\]\$restoreEvidence\.dnsResolutionHealthy'
        }

        It "Closes expired captive portal markers from the per-minute watchdog cycle" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $helperContent = Get-Content $helperPath -Raw
            $moduleContent = Get-Content $modulePath -Raw
            $scriptContent = Get-Content $scriptPath -Raw

            # The per-cycle reads use -SkipExpiredRestore on purpose (no side
            # effects in a state read), so the prechecks must close an expired
            # marker explicitly instead of leaving it in limbo until a native-host
            # request or the update runtime happens to run.
            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'function Test-OpenPathCaptivePortalMarkerExpired',
                '''Test-OpenPathCaptivePortalMarkerExpired'','
            )
            Assert-ContentContainsAll -Content $helperContent -Needles @(
                'Test-OpenPathCaptivePortalMarkerExpired -Marker $activeMarker',
                'failed to close expired captive portal marker; marker preserved'
            )
            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                'Test-OpenPathCaptivePortalMarkerExpired'
            )
        }

        It "Closes any active captive portal marker immediately on authenticated detection and preserves the marker when restore fails" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $policyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.CaptivePortalPolicy.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $helperContent = Get-Content $helperPath -Raw
            $policyContent = Get-Content $policyPath -Raw
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                '$markerMode',
                '$captivityOutcome -eq ''closeAuthenticated''',
                'Disable-OpenPathCaptivePortalMode -Config $Config',
                'failed to close authenticated captive portal mode; marker preserved'
            )
            Assert-ContentContainsAll -Content $policyContent -Needles @(
                '$MarkerMode -ne ''''',
                '$CaptiveState -eq ''Authenticated''',
                'closeAuthenticated'
            )

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'keeping captive portal marker active',
                'protectedModeRestored',
                'markerCleared'
            )
        }

        It "Refreshes limited portal mode instead of restoring protected mode while the portal is still detected" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $policyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.CaptivePortalPolicy.ps1"
            $helperContent = Get-Content $helperPath -Raw
            $moduleContent = Get-Content $modulePath -Raw
            $policyContent = Get-Content $policyPath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                '[switch]$SkipExpiredRestore',
                'if ($SkipExpiredRestore) { return $true }'
            )
            Assert-ContentContainsAll -Content $helperContent -Needles @(
                "Watchdog.CaptivePortalPolicy.ps1",
                'Get-OpenPathWatchdogCaptivePortalPolicyOutcome',
                'Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore',
                '$captivityOutcome -eq ''keepLimited''',
                '$portalRecoveryHosts = @($activeMarker.allowedHosts',
                'Enable-OpenPathCaptivePortalMode -State $captiveState -PortalRecoveryDomains $portalRecoveryHosts'
            )
            Assert-ContentContainsAll -Content $policyContent -Needles @(
                'function Get-OpenPathWatchdogCaptivePortalPolicyOutcome',
                'noAction',
                'keepLimited',
                'restoreProtected',
                'closeAuthenticated',
                'emergencyPassthrough',
                'unsafeMarker'
            )
            $helperContent.IndexOf('Test-OpenPathCaptivePortalModeActive -SkipExpiredRestore') |
                Should -BeLessThan $helperContent.IndexOf('Test-OpenPathCaptivePortalState -TimeoutSec 3')
            $helperContent.IndexOf('$captivityOutcome = Get-OpenPathWatchdogCaptivePortalPolicyOutcome') |
                Should -BeLessThan $helperContent.IndexOf('$portalObservation.ShouldEnterPortal')
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
