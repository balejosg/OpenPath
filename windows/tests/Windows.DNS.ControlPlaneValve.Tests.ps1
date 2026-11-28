Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "DNS control-plane valve" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\DNS.psm1" -Force -Global -ErrorAction Stop

        if (-not (Get-Command -Name Reset-WatchdogFailCount -ErrorAction SilentlyContinue)) {
            function global:Reset-WatchdogFailCount { param($WatchdogFailCountPath) }
        }
        if (-not (Get-Command -Name Increment-WatchdogFailCount -ErrorAction SilentlyContinue)) {
            function global:Increment-WatchdogFailCount { param($WatchdogFailCountPath) return 3 }
        }
        if (-not (Get-Command -Name Restore-CheckpointFromWatchdog -ErrorAction SilentlyContinue)) {
            function global:Restore-CheckpointFromWatchdog { param($Config, $OpenPathRoot) return $false }
        }
        if (-not (Get-Command -Name Write-OpenPathLog -ErrorAction SilentlyContinue)) {
            function global:Write-OpenPathLog { param($Message, $Level) }
        }
        if (-not (Get-Command -Name Remove-OpenPathFirewall -ErrorAction SilentlyContinue)) {
            function global:Remove-OpenPathFirewall { return $true }
        }
        . (Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1")
    }

    BeforeEach {
        $script:valveRoot = Join-Path $TestDrive ('valve-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:valveRoot 'data') -Force | Out-Null
        $script:hostsPath = Join-Path $script:valveRoot 'hosts'
        $script:cachePath = Get-OpenPathControlPlaneDnsCachePath -OpenPathRoot $script:valveRoot

        Mock Write-OpenPathLog { } -ModuleName DNS
        Mock Clear-OpenPathDnsClientCache { $true } -ModuleName DNS
        Mock Restore-CheckpointFromWatchdog { return $false }
    }

    Context "Hosts block preservation" {
        It "Adds and removes the valve block without changing user bytes" {
            $originalText = "# user comment`r`n10.1.2.3 custom.example`r`n# café"
            $encoding = [System.Text.Encoding]::GetEncoding(28591)
            [System.IO.File]::WriteAllBytes($script:hostsPath, $encoding.GetBytes($originalText))
            $originalBytes = [System.IO.File]::ReadAllBytes($script:hostsPath)

            [PSCustomObject]@{
                capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
                hosts = [ordered]@{
                    'api.openpath.example.invalid' = @('203.0.113.10')
                    'whitelist.openpath.example.invalid' = @('203.0.113.11')
                }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:cachePath -Encoding UTF8

            $enabled = Enable-OpenPathControlPlaneValve `
                -Reason 'dns_proxy_down' `
                -OpenPathRoot $script:valveRoot `
                -HostsPath $script:hostsPath

            $enabled.Activated | Should -BeTrue
            $enabled.ValveHosts | Should -Contain 'api.openpath.example.invalid'
            $hostsWithBlock = Get-Content -LiteralPath $script:hostsPath -Raw
            $hostsWithBlock | Should -Match '# BEGIN OpenPath control-plane valve'
            $hostsWithBlock | Should -Match '203\.0\.113\.10 api\.openpath\.example\.invalid'
            $hostsWithBlock | Should -Match 'custom\.example'

            $state = Read-OpenPathDnsFailureModeState -OpenPathRoot $script:valveRoot
            $state.mode | Should -Be 'protected'
            $state.reason | Should -Be 'dns_proxy_down'
            $state.valveHosts | Should -Contain 'api.openpath.example.invalid'

            (Disable-OpenPathControlPlaneValve -OpenPathRoot $script:valveRoot -HostsPath $script:hostsPath).Success | Should -BeTrue
            $restoredBytes = [System.IO.File]::ReadAllBytes($script:hostsPath)
            [Convert]::ToBase64String($restoredBytes) | Should -Be ([Convert]::ToBase64String($originalBytes))
            (Read-OpenPathDnsFailureModeState -OpenPathRoot $script:valveRoot) | Should -BeNullOrEmpty
        }

        It "Replaces an existing block instead of duplicating it" {
            $originalText = "# BEGIN OpenPath control-plane valve`r`n198.51.100.9 old.openpath.example.invalid`r`n# END OpenPath control-plane valve`r`n# user entry`r`n10.1.2.3 custom.example`r`n"
            [System.IO.File]::WriteAllText($script:hostsPath, $originalText, [System.Text.Encoding]::GetEncoding(28591))

            [PSCustomObject]@{
                capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
                hosts = [ordered]@{ 'api.openpath.example.invalid' = @('203.0.113.10') }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:cachePath -Encoding UTF8

            Enable-OpenPathControlPlaneValve `
                -Reason 'dns_proxy_down' `
                -OpenPathRoot $script:valveRoot `
                -HostsPath $script:hostsPath | Out-Null

            $hostsContent = Get-Content -LiteralPath $script:hostsPath -Raw
            ([regex]::Matches($hostsContent, '# BEGIN OpenPath control-plane valve')).Count | Should -Be 1
            $hostsContent | Should -Not -Match '198\.51\.100\.9'
            $hostsContent | Should -Match '203\.0\.113\.10 api\.openpath\.example\.invalid'
            $hostsContent | Should -Match 'custom\.example'
        }
    }

    Context "Fail-closed activation" {
        It "Leaves the hosts file untouched when no last-known-good cache exists" {
            $originalBytes = [System.Text.Encoding]::ASCII.GetBytes("# user entry`r`n")
            [System.IO.File]::WriteAllBytes($script:hostsPath, $originalBytes)

            $result = Enable-OpenPathControlPlaneValve `
                -Reason 'dns_proxy_down' `
                -OpenPathRoot $script:valveRoot `
                -HostsPath $script:hostsPath

            $result.Activated | Should -BeFalse
            $result.ReasonCode | Should -Be 'control_plane_valve_unavailable'
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:hostsPath)) |
                Should -Be ([Convert]::ToBase64String($originalBytes))
            (Read-OpenPathDnsFailureModeState -OpenPathRoot $script:valveRoot) | Should -BeNullOrEmpty
        }

        It "Rejects a cache older than 30 days" {
            [PSCustomObject]@{
                capturedAt = [DateTimeOffset]::UtcNow.AddDays(-31).ToString('o')
                hosts = [ordered]@{ 'api.openpath.example.invalid' = @('203.0.113.10') }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:cachePath -Encoding UTF8

            $result = Enable-OpenPathControlPlaneValve `
                -Reason 'dns_proxy_down' `
                -OpenPathRoot $script:valveRoot `
                -HostsPath $script:hostsPath

            $result.Activated | Should -BeFalse
            $result.ReasonCode | Should -Be 'control_plane_valve_unavailable'
        }
    }

    Context "Last-known-good cache" {
        It "Resolves configured hosts through the local proxy and keeps only valid unicast IPv4" {
            Mock Invoke-OpenPathDnsResolveNameWithTimeout {
                param($Domain, $Server, $AttemptTimeoutSeconds)
                if ($Domain -eq 'api.openpath.example.invalid') {
                    return @(
                        [PSCustomObject]@{ IPAddress = '203.0.113.10' },
                        [PSCustomObject]@{ IPAddress = '127.0.0.1' },
                        [PSCustomObject]@{ IPAddress = '224.0.0.1' }
                    )
                }
                return @([PSCustomObject]@{ IPAddress = '203.0.113.11' })
            } -ModuleName DNS

            $config = [PSCustomObject]@{
                apiUrl = 'https://api.openpath.example.invalid/v1'
                whitelistUrl = 'https://whitelist.openpath.example.invalid/w/token/whitelist.txt'
            }

            (Update-OpenPathControlPlaneDnsCache -Config $config -OpenPathRoot $script:valveRoot) | Should -BeTrue
            $cache = Read-OpenPathControlPlaneDnsCache -OpenPathRoot $script:valveRoot
            $cache.hosts['api.openpath.example.invalid'] | Should -Be @('203.0.113.10')
            $cache.hosts['whitelist.openpath.example.invalid'] | Should -Be @('203.0.113.11')
        }

        It "Skips literal-IP control-plane URLs" {
            Mock Invoke-OpenPathDnsResolveNameWithTimeout {
                param($Domain, $Server, $AttemptTimeoutSeconds)
                return @([PSCustomObject]@{ IPAddress = '203.0.113.11' })
            } -ModuleName DNS

            $config = [PSCustomObject]@{
                apiUrl = 'https://203.0.113.5/v1'
                whitelistUrl = 'https://whitelist.openpath.example.invalid/w/token/whitelist.txt'
            }

            Update-OpenPathControlPlaneDnsCache -Config $config -OpenPathRoot $script:valveRoot | Out-Null
            $cache = Read-OpenPathControlPlaneDnsCache -OpenPathRoot $script:valveRoot
            $cache.hosts.ContainsKey('203.0.113.5') | Should -BeFalse
            $cache.hosts['whitelist.openpath.example.invalid'] | Should -Be @('203.0.113.11')
        }
    }

    Context "Orphan cleanup" {
        It "Removes a block with no failure-mode marker" {
            $originalText = "# user entry`r`n"
            $blockText = "# BEGIN OpenPath control-plane valve`r`n203.0.113.10 api.openpath.example.invalid`r`n# END OpenPath control-plane valve`r`n"
            [System.IO.File]::WriteAllText($script:hostsPath, ($blockText + $originalText), [System.Text.Encoding]::GetEncoding(28591))

            (Remove-OpenPathOrphanControlPlaneValve -OpenPathRoot $script:valveRoot -HostsPath $script:hostsPath) | Should -BeTrue
            (Get-Content -LiteralPath $script:hostsPath -Raw) | Should -Be $originalText
        }

        It "Leaves an active marker block in place" {
            [PSCustomObject]@{
                capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
                hosts = [ordered]@{ 'api.openpath.example.invalid' = @('203.0.113.10') }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:cachePath -Encoding UTF8
            Enable-OpenPathControlPlaneValve `
                -Reason 'dns_proxy_down' `
                -OpenPathRoot $script:valveRoot `
                -HostsPath $script:hostsPath | Out-Null

            (Remove-OpenPathOrphanControlPlaneValve -OpenPathRoot $script:valveRoot -HostsPath $script:hostsPath) | Should -BeFalse
            (Get-Content -LiteralPath $script:hostsPath -Raw) | Should -Match '203\.0\.113\.10 api\.openpath\.example\.invalid'
        }
    }

    Context "Watchdog outcome" {
        It "Enters failure mode only after a failed checkpoint rollback with a DNS class" {
            $outcome = Get-OpenPathWatchdogOutcome `
                -Config ([PSCustomObject]@{ enableCheckpointRollback = $true }) `
                -Issues @('DNS proxy failure: dns_proxy_down') `
                -ReasonCodes @('dns_proxy_down') `
                -RecoveryEligibleIssues @('DNS proxy failure: dns_proxy_down') `
                -StaleFailsafeActive $false `
                -IntegrityTampered $false `
                -FailOpenActive $false `
                -PortalModeActive $false `
                -DnsFailureClass 'dns_proxy_down' `
                -FailureModeActive $false `
                -WatchdogFailCountPath (Join-Path $TestDrive 'fails.txt') `
                -OpenPathRoot $TestDrive

            $outcome.Status | Should -Be 'CRITICAL'
            $outcome.EnterDnsFailureMode | Should -BeTrue
        }

        It "Does not enter failure mode while a captive portal is active" {
            $outcome = Get-OpenPathWatchdogOutcome `
                -Config ([PSCustomObject]@{ enableCheckpointRollback = $true }) `
                -Issues @('DNS proxy failure: dns_proxy_down') `
                -ReasonCodes @('dns_proxy_down') `
                -RecoveryEligibleIssues @('DNS proxy failure: dns_proxy_down') `
                -StaleFailsafeActive $false `
                -IntegrityTampered $false `
                -FailOpenActive $false `
                -PortalModeActive $true `
                -DnsFailureClass 'dns_proxy_down' `
                -FailureModeActive $false `
                -WatchdogFailCountPath (Join-Path $TestDrive 'fails.txt') `
                -OpenPathRoot $TestDrive

            $outcome.EnterDnsFailureMode | Should -BeFalse
        }

        It "Reports PROTECTED and resets the counter while the valve is active" {
            $outcome = Get-OpenPathWatchdogOutcome `
                -Config ([PSCustomObject]@{ enableCheckpointRollback = $true }) `
                -Issues @('DNS proxy failure: dns_proxy_down') `
                -ReasonCodes @('dns_proxy_down') `
                -RecoveryEligibleIssues @('DNS proxy failure: dns_proxy_down') `
                -StaleFailsafeActive $false `
                -IntegrityTampered $false `
                -FailOpenActive $false `
                -PortalModeActive $false `
                -DnsFailureClass 'dns_proxy_down' `
                -FailureModeActive $true `
                -WatchdogFailCountPath (Join-Path $TestDrive 'fails.txt') `
                -OpenPathRoot $TestDrive

            $outcome.Status | Should -Be 'PROTECTED'
            $outcome.WatchdogFailCount | Should -Be 0
            $outcome.ReasonCodes | Should -Contain 'control_plane_valve_active'
            $outcome.ReasonCodes | Should -Contain 'dns_proxy_down'
            $outcome.EnterDnsFailureMode | Should -BeFalse
        }
    }

    Context "Failure-mode configuration" {
        It "Defaults unknown failureMode values to protected and preserves open" {
            (ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{ failureMode = 'unexpected' })).failureMode |
                Should -Be 'protected'
            (ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{ failureMode = 'OPEN' })).failureMode |
                Should -Be 'open'
        }

        It "Reports the effective failureMode in the config posture" {
            InModuleScope Common {
                $posture = Get-OpenPathConfigPosture -Config ([PSCustomObject]@{ failureMode = 'open' })
                $posture.failureMode | Should -Be 'open'
            }
        }

        It "Makes open failure mode protected-mode ineligible without conflating whitelist fail-open" {
            $openState = Get-OpenPathEndpointPolicyState -FailureModeState ([PSCustomObject]@{ mode = 'open' })
            $openState.ProtectedModeEligible | Should -BeFalse
            $openState.FailureModeOpenActive | Should -BeTrue
            $openState.FailOpenActive | Should -BeFalse

            $disabledState = Get-OpenPathEndpointPolicyState `
                -WhitelistSections ([PSCustomObject]@{ IsDisabled = $true }) `
                -FailureModeState ([PSCustomObject]@{ mode = 'open' })
            $disabledState.FailOpenActive | Should -BeTrue
            $disabledState.FailureModeOpenActive | Should -BeTrue
            $disabledState.ProtectedModeEligible | Should -BeFalse
        }

        It "Reports FAIL_OPEN with fail_open_activated while the open marker is active" {
            $outcome = Get-OpenPathWatchdogOutcome `
                -Config ([PSCustomObject]@{ enableCheckpointRollback = $true }) `
                -Issues @('DNS proxy failure: dns_proxy_down') `
                -ReasonCodes @('dns_proxy_down') `
                -RecoveryEligibleIssues @('DNS proxy failure: dns_proxy_down') `
                -StaleFailsafeActive $false `
                -IntegrityTampered $false `
                -FailOpenActive $false `
                -PortalModeActive $false `
                -DnsFailureClass 'dns_proxy_down' `
                -FailureModeActive $false `
                -FailureModeOpenActive $true `
                -WatchdogFailCountPath (Join-Path $TestDrive 'fails-open.txt') `
                -OpenPathRoot $TestDrive

            $outcome.Status | Should -Be 'FAIL_OPEN'
            $outcome.ReasonCodes | Should -Contain 'fail_open_activated'
            $outcome.ReasonCodes | Should -Contain 'dns_proxy_down'
            $outcome.EnterDnsFailureMode | Should -BeFalse
        }
    }

    Context "Open-mode activation and exit" {
        It "Records an open marker, restores DNS, and removes the firewall without touching the hosts valve" {
            Mock Restore-OriginalDNS { } -ModuleName DNS

            $result = Enable-OpenPathDnsFailureOpenMode `
                -Reason 'dns_proxy_down' `
                -OpenPathRoot $script:valveRoot

            $result.Activated | Should -BeTrue
            $result.ReasonCode | Should -Be 'fail_open_activated'
            $state = Read-OpenPathDnsFailureModeState -OpenPathRoot $script:valveRoot
            $state.mode | Should -Be 'open'
            $state.reason | Should -Be 'dns_proxy_down'
            Should -Invoke Restore-OriginalDNS -ModuleName DNS -Times 1 -Exactly
            (Test-Path $script:hostsPath) | Should -BeFalse
        }

        It "Restores protected mode on exit unless whitelist fail-open suppresses it" {
            Mock Restore-OriginalDNS { } -ModuleName DNS
            Mock Restore-OpenPathProtectedMode { $true } -ModuleName Common
            # The valve calls Common\Restore-OpenPathProtectedMode module-qualified, which
            # bypasses the mock above, so the real restore runs: stub its host mutators or it
            # points the adapters at 127.0.0.1 and a runner without Acrylic loses DNS.
            Mock Restart-AcrylicService { $true } -ModuleName Common
            Mock Set-LocalDNS { } -ModuleName Common
            if (Get-Command -Name Test-FirewallActive -ErrorAction SilentlyContinue) {
                Mock Test-FirewallActive { $true } -ModuleName Common
            }
            if (Get-Command -Name Set-OpenPathFirewall -ErrorAction SilentlyContinue) {
                Mock Set-OpenPathFirewall { $true } -ModuleName Common
            }

            Enable-OpenPathDnsFailureOpenMode -Reason 'dns_proxy_down' -OpenPathRoot $script:valveRoot | Out-Null
            $closed = Close-OpenPathDnsFailureMode `
                -Config ([PSCustomObject]@{}) `
                -OpenPathRoot $script:valveRoot `
                -ProtectedModeSuppressed $false
            $closed.WasOpen | Should -BeTrue
            (Read-OpenPathDnsFailureModeState -OpenPathRoot $script:valveRoot) | Should -BeNullOrEmpty

            Enable-OpenPathDnsFailureOpenMode -Reason 'dns_proxy_down' -OpenPathRoot $script:valveRoot | Out-Null
            $suppressed = Close-OpenPathDnsFailureMode `
                -Config ([PSCustomObject]@{}) `
                -OpenPathRoot $script:valveRoot `
                -ProtectedModeSuppressed $true
            $suppressed.WasOpen | Should -BeTrue
            $suppressed.RestoredProtectedMode | Should -BeFalse
        }

        It "Wires the protected-mode restore into the exit path" {
            $content = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.ControlPlaneValve.ps1") -Raw
            $content | Should -Match 'Common\\Restore-OpenPathProtectedMode -Config \$Config'
            $content | Should -Match 'ProtectedModeSuppressed'
        }
    }

    Context "Watchdog script ordering" {
        It "Enters the valve before sending the report and cleans orphans before checks" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Test-DNSHealth.ps1"
            $content = Get-Content $scriptPath -Raw

            $orphanIndex = $content.IndexOf('Remove-OpenPathOrphanControlPlaneValve -OpenPathRoot')
            $checksIndex = $content.IndexOf('Invoke-OpenPathWatchdogChecks `')
            $enableIndex = $content.IndexOf('$valveResult = Enable-OpenPathControlPlaneValve')
            $openEnableIndex = $content.IndexOf('$openResult = Enable-OpenPathDnsFailureOpenMode')
            $closeIndex = $content.IndexOf('Close-OpenPathDnsFailureMode `')
            $sendIndex = $content.IndexOf('Send-OpenPathHealthReport -Status $outcome.Status')

            $orphanIndex | Should -BeGreaterThan -1
            $checksIndex | Should -BeGreaterThan -1
            $enableIndex | Should -BeGreaterThan -1
            $openEnableIndex | Should -BeGreaterThan -1
            $closeIndex | Should -BeGreaterThan -1
            $sendIndex | Should -BeGreaterThan -1
            $orphanIndex | Should -BeLessThan $checksIndex
            $enableIndex | Should -BeLessThan $sendIndex
            $openEnableIndex | Should -BeLessThan $sendIndex
            $closeIndex | Should -BeLessThan $sendIndex
        }
    }
}
