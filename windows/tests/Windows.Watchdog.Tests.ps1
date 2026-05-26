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

        It "Bounds limited portal Acrylic restart and DNS protection verification inside native host budget" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                '$script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds',
                '$script:CaptivePortalLimitedModeDnsMaxAttempts',
                '$script:CaptivePortalLimitedModeDnsDelayMilliseconds',
                'Restart-AcrylicService -TimeoutSeconds $script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds -SkipBatchFallback',
                'Test-OpenPathLimitedCaptivePortalProtection -DnsMaxAttempts $script:CaptivePortalLimitedModeDnsMaxAttempts -DnsDelayMilliseconds $script:CaptivePortalLimitedModeDnsDelayMilliseconds'
            )

            $enableStart = $moduleContent.IndexOf('function Enable-OpenPathCaptivePortalLimitedMode')
            $definitionStart = $moduleContent.IndexOf('function New-OpenPathLimitedCaptivePortalHostsDefinition')
            $enableBody = $moduleContent.Substring($enableStart, $definitionStart - $enableStart)

            $enableBody.IndexOf('Restart-AcrylicService -TimeoutSeconds $script:CaptivePortalLimitedModeServiceRestartTimeoutSeconds -SkipBatchFallback') |
                Should -BeLessThan $enableBody.IndexOf('Test-OpenPathLimitedCaptivePortalProtection -DnsMaxAttempts $script:CaptivePortalLimitedModeDnsMaxAttempts')
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

        It "Closes passthrough immediately on authenticated detection and preserves the marker when restore fails" {
            $helperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "CaptivePortal.psm1"
            $helperContent = Get-Content $helperPath -Raw
            $moduleContent = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $helperContent -Needles @(
                '$markerMode -eq ''passthrough''',
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
                '[int]$ExitAuthenticatedCount = 3',
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
