Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "DNS proxy health" {
    BeforeAll {
        if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) {
            function global:Get-Service { }
        }
        if (-not (Get-Command -Name Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
            function global:Get-NetUDPEndpoint { }
        }

        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\DNS.psm1" -Force -Global -ErrorAction Stop
    }

    Context "Get-OpenPathDnsProxyState" {
        BeforeEach {
            $global:dnsProxyHealthLogs = @()
            Mock Test-AcrylicInstalled { $true } -ModuleName DNS
            Mock Get-AcrylicPath { Join-Path $TestDrive 'acrylic' } -ModuleName DNS
            Mock Test-Path { $true } -ModuleName DNS -ParameterFilter { $Path -eq (Join-Path $TestDrive 'acrylic' 'AcrylicService.exe') }
            Mock Write-OpenPathLog {
                param($Message, $Level)
                $global:dnsProxyHealthLogs += [PSCustomObject]@{ Message = [string]$Message; Level = [string]$Level }
            } -ModuleName DNS
            Mock Stop-Process { } -ModuleName DNS
        }

        AfterEach {
            Remove-Variable -Name dnsProxyHealthLogs -Scope Global -ErrorAction SilentlyContinue
        }

        It "Reports listening when the service is running and Acrylic owns 127.0.0.1:53" {
            Mock Get-Service { [PSCustomObject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
            Mock Get-NetUDPEndpoint { @([PSCustomObject]@{ OwningProcess = 1234 }) } -ModuleName DNS
            Mock Get-Process { [PSCustomObject]@{ Id = 1234; ProcessName = 'AcrylicService' } } -ModuleName DNS -ParameterFilter { $Id -eq 1234 }

            $state = Get-OpenPathDnsProxyState

            $state.State | Should -Be 'listening'
            $state.ServiceStatus | Should -Be 'Running'
            $state.ListenerPid | Should -Be 1234
            $state.ListenerProcessName | Should -Be 'AcrylicService'
            $state.AcrylicInstalled | Should -BeTrue
        }

        It "Reports missing when Acrylic is not installed" {
            Mock Test-AcrylicInstalled { $false } -ModuleName DNS

            $state = Get-OpenPathDnsProxyState

            $state.State | Should -Be 'missing'
            $state.AcrylicInstalled | Should -BeFalse
        }

        It "Reports missing when the service file disappeared from the install path" {
            Mock Test-Path { $false } -ModuleName DNS -ParameterFilter { $Path -eq (Join-Path $TestDrive 'acrylic' 'AcrylicService.exe') }

            $state = Get-OpenPathDnsProxyState

            $state.State | Should -Be 'missing'
            $state.AcrylicInstalled | Should -BeTrue
        }

        It "Reports service-down when the service is stopped" {
            Mock Get-Service { [PSCustomObject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Stopped' } } -ModuleName DNS
            Mock Get-NetUDPEndpoint { @() } -ModuleName DNS

            $state = Get-OpenPathDnsProxyState

            $state.State | Should -Be 'service-down'
            $state.ServiceStatus | Should -Be 'Stopped'
        }

        It "Reports service-down when the service runs but no listener owns port 53" {
            Mock Get-Service { [PSCustomObject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
            Mock Get-NetUDPEndpoint { @() } -ModuleName DNS

            $state = Get-OpenPathDnsProxyState

            $state.State | Should -Be 'service-down'
            $state.ListenerPid | Should -BeNullOrEmpty
        }

        It "Reports port-conflict without terminating the foreign process" {
            Mock Get-Service { [PSCustomObject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
            Mock Get-NetUDPEndpoint { @([PSCustomObject]@{ OwningProcess = 4321 }) } -ModuleName DNS
            Mock Get-Process { [PSCustomObject]@{ Id = 4321; ProcessName = 'chrome' } } -ModuleName DNS -ParameterFilter { $Id -eq 4321 }

            $state = Get-OpenPathDnsProxyState

            $state.State | Should -Be 'port-conflict'
            $state.ListenerPid | Should -Be 4321
            $state.ListenerProcessName | Should -Be 'chrome'
            Should -Invoke Stop-Process -ModuleName DNS -Times 0 -Exactly
            $conflictLog = @($global:dnsProxyHealthLogs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'chrome' -and $_.Message -match '4321' })
            $conflictLog.Count | Should -BeGreaterThan 0
        }

        It "Reports unknown instead of a failure class when the listener probe throws" {
            Mock Get-Service { [PSCustomObject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } } -ModuleName DNS
            Mock Get-NetUDPEndpoint { throw 'access denied' } -ModuleName DNS

            $state = Get-OpenPathDnsProxyState

            $state.State | Should -Be 'unknown'
            (Get-OpenPathDnsFailureClass -ProxyState $state -LocalResolutionHealthy $false) | Should -BeNullOrEmpty
        }
    }

    Context "Invoke-OpenPathDnsProxyRepair" {
        BeforeEach {
            $global:openPathFirewallCalls = @()
            $script:repairRoot = Join-Path $TestDrive ('repair-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $script:repairRoot 'data') -Force | Out-Null
            $script:repairCachePath = Get-OpenPathAcrylicCachePath -OpenPathRoot $script:repairRoot

            Mock Write-OpenPathLog { } -ModuleName DNS
            Mock Get-OpenPathAcrylicArtifactSpec {
                [PSCustomObject]@{
                    Version = '2.2.1'
                    PortableZipSha256 = ('a' * 64)
                    ExecutableInstallerSha256 = ('b' * 64)
                    PortableZipUrls = @('https://openpath.example.invalid/Acrylic-Portable.zip')
                    ExecutableInstallerUrls = @('https://openpath.example.invalid/Acrylic.exe')
                }
            } -ModuleName DNS
            Mock Assert-AcrylicDownloadHash { } -ModuleName DNS
            Mock Test-AcrylicPortableArchive { $true } -ModuleName DNS
            Mock Install-OpenPathAcrylicFromVerifiedArchive { $true } -ModuleName DNS
            Mock Update-AcrylicHost { $true } -ModuleName DNS
            Mock Restart-AcrylicService { $true } -ModuleName DNS
            Mock Get-AcrylicPath { Join-Path $script:repairRoot 'acrylic' } -ModuleName DNS
            Mock Invoke-AcrylicPortableDownload { } -ModuleName DNS
            Mock Save-OpenPathAcrylicArtifactToCache { $script:repairCachePath } -ModuleName DNS

            if (-not (Get-Command -Name Set-OpenPathFirewall -ErrorAction SilentlyContinue)) {
                function global:Set-OpenPathFirewall {
                    param($UpstreamDNS, $AcrylicPath)
                    $global:openPathFirewallCalls += [PSCustomObject]@{ UpstreamDNS = $UpstreamDNS; AcrylicPath = $AcrylicPath }
                    return $true
                }
            }
        }

        AfterEach {
            Remove-Variable -Name openPathFirewallCalls -Scope Global -ErrorAction SilentlyContinue
        }

        It "Starts and re-registers the service for dns_proxy_down" {
            Mock Ensure-AcrylicService { param([switch]$Start) $script:ensureStartRequested = [bool]$Start; return $true } -ModuleName DNS
            Mock Set-AcrylicServiceAutoStart { $true } -ModuleName DNS

            $result = Invoke-OpenPathDnsProxyRepair -FailureClass 'dns_proxy_down' -OpenPathRoot $script:repairRoot

            $result.Attempted | Should -BeTrue
            $result.Repaired | Should -BeTrue
            $script:ensureStartRequested | Should -BeTrue
        }

        It "Reports reinstall unavailable without downloading when no cache exists" {
            $result = Invoke-OpenPathDnsProxyRepair -FailureClass 'dns_proxy_missing' -OpenPathRoot $script:repairRoot

            $result.Attempted | Should -BeFalse
            $result.ReasonCode | Should -Be 'dns_proxy_reinstall_unavailable'
            Should -Invoke Invoke-AcrylicPortableDownload -ModuleName DNS -Times 0 -Exactly
            Should -Invoke Install-OpenPathAcrylicFromVerifiedArchive -ModuleName DNS -Times 0 -Exactly
        }

        It "Does not extract or reinstall when the cached hash fails validation" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:repairCachePath) -Force | Out-Null
            Set-Content -LiteralPath $script:repairCachePath -Value 'payload' -Encoding ASCII
            Mock Assert-AcrylicDownloadHash { throw 'Acrylic-Portable.zip SHA256 mismatch' } -ModuleName DNS

            $result = Invoke-OpenPathDnsProxyRepair -FailureClass 'dns_proxy_missing' -OpenPathRoot $script:repairRoot

            $result.Attempted | Should -BeTrue
            $result.ReasonCode | Should -Be 'dns_proxy_reinstall_unavailable'
            Should -Invoke Install-OpenPathAcrylicFromVerifiedArchive -ModuleName DNS -Times 0 -Exactly
        }

        It "Respects the 30-minute reinstall throttle" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:repairCachePath) -Force | Out-Null
            Set-Content -LiteralPath $script:repairCachePath -Value 'payload' -Encoding ASCII
            $statePath = Get-OpenPathAcrylicRepairStatePath -OpenPathRoot $script:repairRoot
            [PSCustomObject]@{
                lastReinstallAttemptAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
                lastReinstallResult = 'failed'
                lastCacheSeedAttemptAt = ''
            } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

            $result = Invoke-OpenPathDnsProxyRepair -FailureClass 'dns_proxy_missing' -OpenPathRoot $script:repairRoot

            $result.Attempted | Should -BeFalse
            $result.Detail | Should -Match 'throttle'
            Should -Invoke Install-OpenPathAcrylicFromVerifiedArchive -ModuleName DNS -Times 0 -Exactly
        }

        It "Reapplies Acrylic host content and the firewall after a successful reinstall" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:repairCachePath) -Force | Out-Null
            Set-Content -LiteralPath $script:repairCachePath -Value 'payload' -Encoding ASCII
            $config = [PSCustomObject]@{ primaryDNS = '10.0.0.53' }

            $result = Invoke-OpenPathDnsProxyRepair -FailureClass 'dns_proxy_missing' -Config $config -OpenPathRoot $script:repairRoot

            $result.Repaired | Should -BeTrue
            $result.ReasonCode | Should -Be 'dns_proxy_reinstalled'
            Should -Invoke Install-OpenPathAcrylicFromVerifiedArchive -ModuleName DNS -Times 1 -Exactly
            Should -Invoke Update-AcrylicHost -ModuleName DNS -Times 1 -Exactly
            Should -Invoke Restart-AcrylicService -ModuleName DNS -Times 1 -Exactly
            @($global:openPathFirewallCalls).Count | Should -Be 1
            $global:openPathFirewallCalls[0].UpstreamDNS | Should -Be '10.0.0.53'
        }

        It "Does not repair port conflicts or upstream failures" {
            $portConflict = Invoke-OpenPathDnsProxyRepair -FailureClass 'dns_port_conflict' -OpenPathRoot $script:repairRoot
            $upstream = Invoke-OpenPathDnsProxyRepair -FailureClass 'dns_upstream_unreachable' -OpenPathRoot $script:repairRoot

            $portConflict.Attempted | Should -BeFalse
            $upstream.Attempted | Should -BeFalse
        }

        It "Seeds the artifact cache at most once per 24 hours" {
            $proxyState = [PSCustomObject]@{ State = 'listening' }

            $first = Invoke-OpenPathAcrylicArtifactCacheSeed `
                -ProxyState $proxyState `
                -LocalResolutionHealthy $true `
                -OpenPathRoot $script:repairRoot
            $second = Invoke-OpenPathAcrylicArtifactCacheSeed `
                -ProxyState $proxyState `
                -LocalResolutionHealthy $true `
                -OpenPathRoot $script:repairRoot

            $first | Should -BeTrue
            $second | Should -BeFalse
            Should -Invoke Invoke-AcrylicPortableDownload -ModuleName DNS -Times 1 -Exactly
            Should -Invoke Save-OpenPathAcrylicArtifactToCache -ModuleName DNS -Times 1 -Exactly
        }
    }

    Context "Watchdog integration" {
        It "Returns the DNS failure class and marks it recovery-eligible" {
            $watchdogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1"
            $content = Get-Content $watchdogPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathDnsProxyState',
                'Get-OpenPathDnsFailureClass',
                '& $addReasonCode $dnsFailureClass',
                '$recoveryEligibleIssues += $dnsFailureIssue',
                'DnsFailureClass = $dnsFailureClass'
            )
        }
    }

    Context "Get-OpenPathDnsFailureClass" {
        It "Maps missing, service-down and port-conflict states to distinct reason codes" {
            (Get-OpenPathDnsFailureClass -ProxyState ([PSCustomObject]@{ State = 'missing' }) -LocalResolutionHealthy $false) | Should -Be 'dns_proxy_missing'
            (Get-OpenPathDnsFailureClass -ProxyState ([PSCustomObject]@{ State = 'service-down' }) -LocalResolutionHealthy $false) | Should -Be 'dns_proxy_down'
            (Get-OpenPathDnsFailureClass -ProxyState ([PSCustomObject]@{ State = 'port-conflict' }) -LocalResolutionHealthy $false) | Should -Be 'dns_port_conflict'
        }

        It "Reports an upstream failure only when the proxy listens but cannot resolve through itself" {
            $listening = [PSCustomObject]@{ State = 'listening' }

            (Get-OpenPathDnsFailureClass -ProxyState $listening -LocalResolutionHealthy $false) | Should -Be 'dns_upstream_unreachable'
            (Get-OpenPathDnsFailureClass -ProxyState $listening -LocalResolutionHealthy $true) | Should -BeNullOrEmpty
            (Get-OpenPathDnsFailureClass -ProxyState $listening -LocalResolutionHealthy $null) | Should -BeNullOrEmpty
        }

        It "Returns no class for unknown state or absent proxy state" {
            (Get-OpenPathDnsFailureClass -ProxyState ([PSCustomObject]@{ State = 'unknown' }) -LocalResolutionHealthy $false) | Should -BeNullOrEmpty
            (Get-OpenPathDnsFailureClass -ProxyState $null -LocalResolutionHealthy $false) | Should -BeNullOrEmpty
        }
    }
}
