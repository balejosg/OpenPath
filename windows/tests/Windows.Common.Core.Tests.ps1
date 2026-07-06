Describe "Common Module" {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module (Join-Path $modulePath "Common.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "DNS.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Firewall.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Services.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Browser.Common.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Browser.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Browser.FirefoxNativeHost.psm1") -Force -Global -ErrorAction Stop
    }

    Context "Capability-sensitive storage" {
        BeforeAll {
            . (Join-Path $PSScriptRoot ".." "lib" "internal" "CapabilityStorage.ps1")
        }

        It "Derives runtime dependency and native host storage paths from the OpenPath root" {
            $root = Join-Path $TestDrive "OpenPath"

            Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue -OpenPathRoot $root |
                Should -Be (Join-Path $root "data\runtime-dependency-queue")
            Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryQueue -OpenPathRoot $root |
                Should -Be (Join-Path $root "data\captive-portal-recovery-queue")
            Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryResult -OpenPathRoot $root |
                Should -Be (Join-Path $root "data\captive-portal-recovery-result")
            Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryProgress -OpenPathRoot $root |
                Should -Be (Join-Path $root "data\captive-portal-recovery-progress")
            Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $root |
                Should -Be (Join-Path $root "data\runtime-dependency-overlay.json")
            Get-OpenPathCapabilityStoragePath -Name FirefoxNativeHostRoot -OpenPathRoot $root |
                Should -Be (Join-Path $root "browser-extension\firefox\native")
            Get-OpenPathCapabilityStoragePath -Name FirefoxNativeHostState -OpenPathRoot $root |
                Should -Be (Join-Path $root "browser-extension\firefox\native\native-state.json")
        }

        It "Exposes narrow ACL profiles for captive portal recovery queue and result storage" {
            $capabilityStoragePath = Join-Path $PSScriptRoot ".." "lib" "internal" "CapabilityStorage.ps1"
            $content = Get-Content $capabilityStoragePath -Raw

            foreach ($needle in @(
                "'CaptivePortalRecoveryQueue'",
                "'CaptivePortalRecoveryResult'",
                "'CaptivePortalRecoveryProgress'",
                "'CaptivePortalRecoveryQueue'",
                "'CaptivePortalRecoveryResultRead'",
                "elseif (`$Profile -eq 'CaptivePortalRecoveryQueue')",
                "elseif (`$Profile -eq 'CaptivePortalRecoveryResultRead')",
                "'BUILTIN\Users' -Rights 'Modify'",
                "'BUILTIN\Users' -Rights 'ReadAndExecute'"
            )) {
                $content.Contains($needle) | Should -BeTrue -Because "Expected content to include '$needle'"
            }
        }

        It "Honors runtime dependency queue and overlay environment overrides" {
            $previousQueue = $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH
            $previousOverlay = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
            try {
                $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH = Join-Path $TestDrive "queue-override"
                $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = Join-Path $TestDrive "overlay-override.json"

                Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue -OpenPathRoot "C:\OpenPath" |
                    Should -Be $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH
                Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot "C:\OpenPath" |
                    Should -Be $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
                Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlayParent -OpenPathRoot "C:\OpenPath" |
                    Should -Be (Split-Path $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH -Parent)
            }
            finally {
                $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH = $previousQueue
                $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = $previousOverlay
            }
        }

        It "Creates storage directories and applies requested ACL profiles through the central helper" {
            $path = Join-Path $TestDrive "queue"

            Mock Set-OpenPathCapabilityStorageAcl {}
            Mock Test-OpenPathCapabilityStorageAcl { return $true }

            Ensure-OpenPathCapabilityStorageDirectory -Path $path -AclProfile RuntimeDependencyQueue -ValidateAcl |
                Should -Be $path

            Test-Path $path | Should -BeTrue
            Should -Invoke Set-OpenPathCapabilityStorageAcl -Times 1 -ParameterFilter {
                $Path -eq $path -and $Profile -eq 'RuntimeDependencyQueue'
            }
            Should -Invoke Test-OpenPathCapabilityStorageAcl -Times 1 -ParameterFilter {
                $Path -eq $path -and $Profile -eq 'RuntimeDependencyQueue'
            }
        }

        It "Creates captive portal result directories with read-only browser-user validation" {
            $path = Join-Path $TestDrive "captive-result"

            Mock Set-OpenPathCapabilityStorageAcl {}
            Mock Test-OpenPathCapabilityStorageAcl { return $true }

            Ensure-OpenPathCapabilityStorageDirectory -Path $path -AclProfile CaptivePortalRecoveryResultRead -ValidateAcl |
                Should -Be $path

            Test-Path $path | Should -BeTrue
            Should -Invoke Set-OpenPathCapabilityStorageAcl -Times 1 -ParameterFilter {
                $Path -eq $path -and $Profile -eq 'CaptivePortalRecoveryResultRead'
            }
            Should -Invoke Test-OpenPathCapabilityStorageAcl -Times 1 -ParameterFilter {
                $Path -eq $path -and $Profile -eq 'CaptivePortalRecoveryResultRead'
            }
        }

        It "Reports ACL validation failures as storage setup errors" {
            $path = Join-Path $TestDrive "native"

            Mock Set-OpenPathCapabilityStorageAcl {}
            Mock Test-OpenPathCapabilityStorageAcl { return $false }

            { Ensure-OpenPathCapabilityStorageDirectory -Path $path -AclProfile BrowserExtensionRead -ValidateAcl } |
                Should -Throw "Capability storage ACL validation failed*"
        }
    }

    Context "Test-AdminPrivileges" {
        It "Returns a boolean value" -Skip:(-not $IsWindows) {
            $result = InModuleScope Common {
                Test-AdminPrivileges
            }
            $result | Should -BeOfType [bool]
        }
    }

    Context "Write-OpenPathLog" {
        It "Writes INFO level logs" {
            {
                InModuleScope Common {
                    Write-OpenPathLog -Message "Test INFO message" -Level INFO
                }
            } | Should -Not -Throw
        }

        It "Writes WARN level logs" {
            {
                InModuleScope Common {
                    Write-OpenPathLog -Message "Test WARN message" -Level WARN
                }
            } | Should -Not -Throw
        }

        It "Writes ERROR level logs" {
            {
                InModuleScope Common {
                    Write-OpenPathLog -Message "Test ERROR message" -Level ERROR
                }
            } | Should -Not -Throw
        }

        It "Includes PID in log entries" {
            $logPath = "C:\OpenPath\data\logs\openpath.log"
            if (Test-Path $logPath) {
                InModuleScope Common {
                    Write-OpenPathLog -Message "PID test entry" -Level INFO
                }
                $lastLine = Get-Content $logPath -Tail 1
                $lastLine | Should -Match "\[PID:\d+\]"
            }
        }

        It "Appends with shared file access and retry tolerance" {
            $systemModulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.System.ps1"
            $content = Get-Content $systemModulePath -Raw
            $content | Should -Match '\[System\.IO\.FileShare\]::ReadWrite'
            $content | Should -Match 'for \(\$attempt = 1; \$attempt -le 5; \$attempt\+\+\)'
            $content | Should -Not -Match 'Add-Content -Path \$script:LogPath'
        }
    }

    Context "Write-OpenPathLog rotation" {
        # Each test gets an isolated temp directory to avoid cross-test interference.

        It "Rotates the log when it exceeds the size threshold" {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("op-log-rot-" + [Guid]::NewGuid())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            try {
                InModuleScope Common -Parameters @{ TempDir = $tempDir } {
                    $script:LogPath = Join-Path $TempDir 'openpath.log'
                    $script:ConfigPath = Join-Path $TempDir 'config.json'

                    # Write a log file that already exceeds 1 MB threshold
                    $bigContent = 'x' * (2 * 1024 * 1024)   # 2 MB
                    [System.IO.File]::WriteAllText($script:LogPath, $bigContent)

                    # Config: 1 MB threshold, keep 3
                    @{ logMaxSizeMb = 1; logKeepFiles = 3 } | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8

                    Write-OpenPathLog -Message 'rotation trigger' -Level INFO

                    # The active log should now be smaller than the big pre-rotation content
                    (Get-Item $script:LogPath).Length | Should -BeLessThan (2 * 1024 * 1024)
                    # The first archive must exist
                    Test-Path "$($script:LogPath).1" | Should -BeTrue
                }
            }
            finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Respects keep-count: drops archives beyond the configured limit" {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("op-log-keep-" + [Guid]::NewGuid())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            try {
                InModuleScope Common -Parameters @{ TempDir = $tempDir } {
                    $script:LogPath = Join-Path $TempDir 'openpath.log'
                    $script:ConfigPath = Join-Path $TempDir 'config.json'

                    # Pre-seed archives .1 .2 .3 (at the keep limit of 3)
                    @(1, 2, 3) | ForEach-Object {
                        [System.IO.File]::WriteAllText("$($script:LogPath).$_", "archive $_")
                    }

                    # Trigger rotation: write a 2 MB log, threshold is 1 MB
                    $bigContent = 'x' * (2 * 1024 * 1024)
                    [System.IO.File]::WriteAllText($script:LogPath, $bigContent)
                    @{ logMaxSizeMb = 1; logKeepFiles = 3 } | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8

                    Write-OpenPathLog -Message 'keep-count test' -Level INFO

                    # .1 must exist (the just-rotated log)
                    Test-Path "$($script:LogPath).1" | Should -BeTrue
                    # Archives beyond keep-count must not exist
                    Test-Path "$($script:LogPath).4" | Should -BeFalse
                }
            }
            finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Does not lose the log line when rotation fails mid-race" {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("op-log-race-" + [Guid]::NewGuid())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            try {
                InModuleScope Common -Parameters @{ TempDir = $tempDir } {
                    $script:LogPath = Join-Path $TempDir 'openpath.log'
                    $script:ConfigPath = Join-Path $TempDir 'config.json'

                    # Simulate rotation already happened (active log gone) before our call.
                    # Invoke-OpenPathLogRotation with a missing file is a no-op; the write
                    # must still create and populate the active log.
                    @{ logMaxSizeMb = 1; logKeepFiles = 3 } | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8
                    # Do NOT create $script:LogPath -- simulates post-rotation state.

                    Write-OpenPathLog -Message 'race-tolerance check' -Level INFO

                    Test-Path $script:LogPath | Should -BeTrue
                    $written = Get-Content $script:LogPath -Raw
                    $written | Should -Match 'race-tolerance check'
                }
            }
            finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Invoke-OpenPathLogRotation helper shifts archives in numbered order" {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("op-log-shift-" + [Guid]::NewGuid())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            try {
                InModuleScope Common -Parameters @{ TempDir = $tempDir } {
                    $logPath = Join-Path $TempDir 'openpath.log'

                    # Write a 2 MB log and seed .1 and .2 archives
                    $bigContent = 'x' * (2 * 1024 * 1024)
                    [System.IO.File]::WriteAllText($logPath, $bigContent)
                    [System.IO.File]::WriteAllText("$logPath.1", 'old-1')
                    [System.IO.File]::WriteAllText("$logPath.2", 'old-2')

                    Invoke-OpenPathLogRotation -LogPath $logPath -MaxSizeBytes (1MB) -KeepFiles 3

                    # Active log moved to .1, old .1 -> .2, old .2 -> .3
                    Test-Path $logPath      | Should -BeFalse
                    Test-Path "$logPath.1"  | Should -BeTrue
                    Test-Path "$logPath.2"  | Should -BeTrue
                    Test-Path "$logPath.3"  | Should -BeTrue
                    # Content of new .2 is what was in .1
                    Get-Content "$logPath.2" -Raw | Should -Be 'old-1'
                    Get-Content "$logPath.3" -Raw | Should -Be 'old-2'
                }
            }
            finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Get-PrimaryDNS" {
        It "Returns a valid IP address string" -Skip:(-not $IsWindows) {
            $dns = InModuleScope Common {
                Get-PrimaryDNS
            }
            $dns | Should -Not -BeNullOrEmpty
            $dns | Should -Match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'
        }
    }

    Context "HTTP compatibility" {
        It "Loads System.Net.Http types for standalone whitelist downloads" {
            InModuleScope Common {
                { Ensure-OpenPathHttpAssembly } | Should -Not -Throw
                ('System.Net.Http.HttpClientHandler' -as [type]) | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context "Get-OpenPathRuntimeHealth" {
        It "Returns runtime health object with expected boolean properties" {
            $health = InModuleScope Common {
                Get-OpenPathRuntimeHealth
            }

            $health | Should -Not -BeNullOrEmpty
            $health.PSObject.Properties.Name | Should -Contain 'DnsServiceRunning'
            $health.PSObject.Properties.Name | Should -Contain 'DnsResolving'
            $health.DnsServiceRunning | Should -BeOfType [bool]
            $health.DnsResolving | Should -BeOfType [bool]
        }
    }

    Context "Protected mode helpers" {
        It "Defines Restore-OpenPathProtectedMode with optional Acrylic restart" {
            $commonPath = Join-Path $PSScriptRoot ".." "lib" "Common.psm1"
            $domainsHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Domains.ps1"
            $content = Get-Content $domainsHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Restore-OpenPathProtectedMode',
                '[switch]$SkipAcrylicRestart',
                'Restart-AcrylicService',
                'Set-LocalDNS',
                'Set-OpenPathFirewall',
                'Enable-OpenPathFirewall'
            )
        }

        It "Avoids full firewall rebuild when protected-mode firewall rules are already active" {
            $domainsHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Domains.ps1"
            $content = Get-Content $domainsHelperPath -Raw

            $content | Should -Match '(?s)function Restore-OpenPathProtectedMode.*?Test-FirewallActive.*?return \$true.*?Set-OpenPathFirewall'
        }

        It "Reuses Restore-OpenPathProtectedMode during checkpoint restore" {
            $whitelistHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Whitelist.ps1"
            $content = Get-Content $whitelistHelperPath -Raw

            $content | Should -Match '(?s)function Restore-OpenPathLatestCheckpoint.*?Restore-OpenPathProtectedMode -Config \$Config'
        }

        It "Returns the firewall apply result instead of unconditionally reporting success" {
            # Regression: a failed Set-OpenPathFirewall leaves enforcement partially applied,
            # but the branch returned $true regardless, hiding it. It must propagate the
            # boolean result and drop the old `| Out-Null` + `return $true`.
            $domainsHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Domains.ps1"
            $content = Get-Content $domainsHelperPath -Raw

            $content | Should -Match '\$firewallConfigured = \[bool\]\(Set-OpenPathFirewall'
            $content | Should -Match 'return \$firewallConfigured'
            $content | Should -Not -Match 'Set-OpenPathFirewall -UpstreamDNS \$upstream -AcrylicPath \$acrylicPath \| Out-Null'
        }
    }

    Context "Get-OpenPathDnsProbeDomains" {
        It "Prefers cached whitelist domains before protected fallbacks" -Skip:(-not $IsWindows) {
            $expectedWhitelistPath = 'C:\OpenPath\data\whitelist.txt'

            Mock Test-Path { $true } -ModuleName Common -ParameterFilter { $Path -eq $expectedWhitelistPath }
            Mock Get-ValidWhitelistDomainsFromFile { @('safe.example', 'allowed.example') } -ModuleName Common
            Mock Get-OpenPathProtectedDomains { @('raw.githubusercontent.com', 'api.example.com') } -ModuleName Common

            InModuleScope Common {
                $domains = @(Get-OpenPathDnsProbeDomains)

                $domains[0] | Should -Be 'safe.example'
                $domains[1] | Should -Be 'allowed.example'
                $domains | Should -Contain 'raw.githubusercontent.com'
                $domains | Should -Contain 'api.example.com'
            }
        }
    }

    Context "Machine identity helpers" {
        It "Canonicalizes machine names" {
            (InModuleScope Common {
                ConvertTo-OpenPathMachineName -Value 'PC 01__Lab'
            }) | Should -Be 'pc-01-lab'
        }

        It "Builds classroom-scoped machine names" {
            $scoped = InModuleScope Common {
                New-OpenPathScopedMachineName -Hostname 'PC 01__Lab' -ClassroomId 'classroom-123'
            }
            $scoped | Should -Match '^pc-01-lab-[a-f0-9]{8}$'
            $scoped.Length | Should -BeLessOrEqual 63
        }

        It "Builds canonical registration payloads" {
            $body = InModuleScope Common {
                New-OpenPathMachineRegistrationBody -MachineName 'pc-01-abcd1234' -Version '4.1.0' -ClassroomId 'classroom-123'
            }
            $body.hostname | Should -Be 'pc-01-abcd1234'
            $body.version | Should -Be '4.1.0'
            $body.classroomId | Should -Be 'classroom-123'
            $body.PSObject.Properties.Name | Should -Not -Contain 'classroomName'
        }

        It "Resolves registration responses with server-issued machine names" {
            $registration = InModuleScope Common {
                Resolve-OpenPathMachineRegistration `
                    -Response ([PSCustomObject]@{
                        success = $true
                        whitelistUrl = 'https://api.example.com/w/token/whitelist.txt'
                        classroomName = 'Room 101'
                        classroomId = 'classroom-123'
                        machineHostname = 'pc-01-abcd1234'
                    }) `
                    -MachineName 'pc-01-lab' `
                    -Classroom 'Room Local' `
                    -ClassroomId 'fallback-id'
            }

            $registration.WhitelistUrl | Should -Be 'https://api.example.com/w/token/whitelist.txt'
            $registration.Classroom | Should -Be 'Room 101'
            $registration.ClassroomId | Should -Be 'classroom-123'
            $registration.MachineName | Should -Be 'pc-01-abcd1234'
        }
    }

    Context "Self-update helpers" {
        It "Extracts machine token from whitelist URL" {
            $token = InModuleScope Common {
                Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl "https://api.example.com/w/abc123token/whitelist.txt"
            }
            $token | Should -Be 'abc123token'
        }

        It "URL-unescapes percent-encoded machine tokens" {
            InModuleScope Common {
                Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl 'https://api.example.com/w/abc%2Btoken/whitelist.txt'
            } | Should -Be 'abc+token'
        }

        It "Ignores query strings after the whitelist path" {
            InModuleScope Common {
                Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl 'https://api.example.com/w/tok1/whitelist.txt?cache=1'
            } | Should -Be 'tok1'
        }

        It "Returns nothing when the URL path does not end in /whitelist.txt" {
            InModuleScope Common {
                Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl 'https://api.example.com/w/tok1/'
            } | Should -BeNullOrEmpty
        }

        It "Returns nothing for relative or malformed URLs" {
            InModuleScope Common {
                Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl 'not a url /w/tok1/whitelist.txt extra'
            } | Should -BeNullOrEmpty
        }

        It "Update.Runtime shares the canonical machine-token implementation" {
            $updateRuntime = Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'Update.Runtime.psm1') -Force -PassThru
            try {
                & $updateRuntime { Get-OpenPathMachineTokenFromWhitelistUrl -WhitelistUrl 'https://api.example.com/w/abc%2Btoken/whitelist.txt' } | Should -Be 'abc+token'
            }
            finally {
                Remove-Module $updateRuntime -Force -ErrorAction SilentlyContinue
            }
        }

        It "Builds protected domains from configured control-plane URLs and bootstrap hosts" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    apiUrl = 'https://control.example'
                    whitelistUrl = 'https://downloads.example/w/token/whitelist.txt'
                }
            } -ModuleName Common

            $domains = InModuleScope Common {
                Get-OpenPathProtectedDomains
            }

            $domains | Should -Contain 'control.example'
            $domains | Should -Contain 'downloads.example'
            $domains | Should -Contain 'raw.githubusercontent.com'
            $domains | Should -Contain 'api.github.com'
            $domains | Should -Contain 'release-assets.githubusercontent.com'
            $domains | Should -Contain 'sourceforge.net'
            $domains | Should -Contain 'downloads.sourceforge.net'
        }

        It "Builds normalized always-allowed domains from control-plane, Microsoft, and Firefox system roots" {
            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    apiUrl = 'https://control.example'
                    whitelistUrl = 'https://downloads.example/w/token/whitelist.txt'
                }
            } -ModuleName Common

            $domains = InModuleScope Common {
                Get-OpenPathAlwaysAllowedDomains
            }

            $domains | Should -Contain 'control.example'
            $domains | Should -Contain 'downloads.example'
            $domains | Should -Contain 'windowsupdate.com'
            $domains | Should -Contain 'delivery.mp.microsoft.com'
            $domains | Should -Contain 'definitionupdates.microsoft.com'
            $domains | Should -Contain 'login.microsoftonline.com'
            $domains | Should -Contain 'azureedge.net'
            $domains | Should -Contain 'blob.core.windows.net'
            $domains | Should -Contain 'aus5.mozilla.org'
            $domains | Should -Contain 'download.mozilla.org'
            $domains | Should -Contain 'download.cdn.mozilla.net'
            $domains | Should -Contain 'archive.mozilla.org'
            $domains | Should -Contain 'firefox.settings.services.mozilla.com'
            $domains | Should -Contain 'firefox-settings-attachments.cdn.mozilla.net'
            $domains | Should -Contain 'content-signature-2.cdn.mozilla.net'
            $domains | Should -Contain 'addons.mozilla.org'
            $domains | Should -Contain 'versioncheck.addons.mozilla.org'
            $domains | Should -Contain 'services.addons.mozilla.org'
            $domains | Should -Contain 'safebrowsing.googleapis.com'
            $domains | Should -Contain 'ciscobinary.openh264.org'
            $domains | Should -Contain 'redirector.gvt1.com'
            $domains | Should -Contain 'clients2.googleusercontent.com'
            $domains | Should -Not -Contain '*.windowsupdate.com'
            $domains | Should -Not -Contain 'incoming.telemetry.mozilla.org'
            $domains | Should -Not -Contain 'ads.mozilla.org'
            $domains | Should -Not -Contain 'mozilla.cloudflare-dns.com'
            @($domains | Where-Object { $_ -eq 'msftconnecttest.com' }).Count | Should -Be 1
        }

        It "Compares versions correctly" {
            (InModuleScope Common {
                Compare-OpenPathVersion -CurrentVersion '4.1.0' -TargetVersion '4.2.0'
            }) | Should -BeLessThan 0
            (InModuleScope Common {
                Compare-OpenPathVersion -CurrentVersion '4.2.0' -TargetVersion '4.2.0'
            }) | Should -Be 0
            (InModuleScope Common {
                Compare-OpenPathVersion -CurrentVersion '4.3.0' -TargetVersion '4.2.0'
            }) | Should -BeGreaterThan 0
        }
    }

    Context "Domain catalog characterization" {
        It "Pins the captive portal probe domain list" {
            InModuleScope Common { Get-OpenPathCaptivePortalProbeDomains } | Should -Be @(
                'detectportal.firefox.com',
                'connectivity-check.ubuntu.com',
                'captive.apple.com',
                'www.msftconnecttest.com',
                'msftconnecttest.com',
                'clients3.google.com'
            )
        }

        It "Pins the Microsoft system domain roots" {
            $domains = InModuleScope Common { Get-OpenPathMicrosoftSystemDomains }
            $domains | Should -HaveCount 38
            $domains[0] | Should -Be '*.windowsupdate.com'
            $domains | Should -Contain 'msftconnecttest.com'
            $domains | Should -Contain 'blob.core.windows.net'
        }

        It "Pins the Firefox system domain roots" {
            $domains = InModuleScope Common { Get-OpenPathFirefoxSystemDomains }
            $domains | Should -HaveCount 15
            $domains[0] | Should -Be 'aus5.mozilla.org'
            $domains | Should -Contain 'clients2.googleusercontent.com'
        }

        It "Pins the standalone runtime-dependency protected floor at 58 hosts" {
            # Fresh pwsh so no Common export leaks into the Get-Command guards inside
            # Get-OpenPathRuntimeDependencyProtectedHosts (this reproduces the native
            # host context, where only the Policy floor applies).
            $policyPath = Join-Path $PSScriptRoot '..' 'lib' 'internal' 'RuntimeDependency.Policy.ps1'
            $script = "`$ErrorActionPreference='Stop'; . '$policyPath'; `$h = @(Get-OpenPathRuntimeDependencyProtectedHosts); `$h.Count"
            $count = & pwsh -NoProfile -Command $script
            [int]($count | Select-Object -Last 1) | Should -Be 58
        }

        It "Standalone protected floor covers the probe, Microsoft, Firefox, and NTP anchors" {
            $policyPath = Join-Path $PSScriptRoot '..' 'lib' 'internal' 'RuntimeDependency.Policy.ps1'
            $script = "`$ErrorActionPreference='Stop'; . '$policyPath'; @(Get-OpenPathRuntimeDependencyProtectedHosts) -join ','"
            $joined = (& pwsh -NoProfile -Command $script | Select-Object -Last 1)
            foreach ($expected in @('detectportal.firefox.com', 'msftconnecttest.com', 'windowsupdate.com', 'graph.microsoft.com', 'blob.core.windows.net', 'aus5.mozilla.org', 'clients2.googleusercontent.com', 'time.windows.com')) {
                $joined | Should -Match ([regex]::Escape($expected))
            }
        }

        It "Standalone policy floor is composed from the shared domain catalog (fail-closed without it)" {
            $policyPath = Join-Path $PSScriptRoot '..' 'lib' 'internal' 'RuntimeDependency.Policy.ps1'
            $script = "`$ErrorActionPreference='Stop'; . '$policyPath'; if (-not (Get-Command Get-OpenPathMicrosoftSystemDomains -ErrorAction SilentlyContinue)) { 'CATALOG-MISSING' } else { 'CATALOG-LOADED' }"
            (& pwsh -NoProfile -Command $script | Select-Object -Last 1) | Should -Be 'CATALOG-LOADED'
        }
    }

    Context "Get-ValidWhitelistDomainsFromFile" {
        It "Returns valid domains and ignores invalid entries" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-domains-" + [Guid]::NewGuid().ToString() + ".txt")

            try {
                @(
                    'google.com',
                    'example.org',
                    'not-a-domain',
                    'bad..domain.com',
                    '# comment',
                    ''
                ) | Set-Content $tempFile -Encoding UTF8

                $domains = InModuleScope Common -Parameters @{
                    TempFile = $tempFile
                } {
                    Get-ValidWhitelistDomainsFromFile -Path $TempFile
                }

                $domains | Should -Contain 'google.com'
                $domains | Should -Contain 'example.org'
                $domains | Should -Not -Contain 'not-a-domain'
                $domains | Should -Not -Contain 'bad..domain.com'
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "Returns an empty array when file does not exist" {
            $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.txt')
            $domains = InModuleScope Common -Parameters @{
                MissingPath = $missingPath
            } {
                Get-ValidWhitelistDomainsFromFile -Path $MissingPath
            }
            @($domains).Count | Should -Be 0
        }
    }

    Context "Get-OpenPathWhitelistSectionsFromFile" {
        It "Parses whitelist sections from a local whitelist file" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-whitelist-sections-" + [Guid]::NewGuid().ToString() + ".txt")

            try {
                @'
#DESACTIVADO
## WHITELIST
allowed.example

## BLOCKED-SUBDOMAINS
ads.allowed.example

## BLOCKED-PATHS
allowed.example/private
'@ | Set-Content $tempFile -Encoding UTF8

                $sections = InModuleScope Common -Parameters @{
                    TempFile = $tempFile
                } {
                    Get-OpenPathWhitelistSectionsFromFile -Path $TempFile
                }

                $sections.IsDisabled | Should -BeTrue
                $sections.Whitelist | Should -Contain 'allowed.example'
                $sections.BlockedSubdomains | Should -Contain 'ads.allowed.example'
                $sections.BlockedPaths | Should -Contain 'allowed.example/private'
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "Returns empty sections when file does not exist" {
            $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.txt')
            $sections = InModuleScope Common -Parameters @{
                MissingPath = $missingPath
            } {
                Get-OpenPathWhitelistSectionsFromFile -Path $MissingPath
            }

            $sections.IsDisabled | Should -BeFalse
            @($sections.Whitelist).Count | Should -Be 0
            @($sections.BlockedSubdomains).Count | Should -Be 0
            @($sections.BlockedPaths).Count | Should -Be 0
        }

        It "Parses ALLOWED-PATHS section and never leaks path entries into Whitelist" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-allowed-paths-" + [Guid]::NewGuid().ToString() + ".txt")

            try {
                @'
## WHITELIST
youtube.com

## ALLOWED-PATHS
youtube.com/watch?v=abc
'@ | Set-Content $tempFile -Encoding UTF8

                $sections = InModuleScope Common -Parameters @{
                    TempFile = $tempFile
                } {
                    Get-OpenPathWhitelistSectionsFromFile -Path $TempFile
                }

                # Bare domain must be in Whitelist
                $sections.Whitelist | Should -Contain 'youtube.com'

                # Path entry must appear in AllowedPaths, not Whitelist
                $sections.AllowedPaths | Should -Contain 'youtube.com/watch?v=abc'
                $sections.Whitelist | Should -Not -Contain 'youtube.com/watch?v=abc'

                # No entry with a slash must appear in Whitelist
                foreach ($entry in @($sections.Whitelist)) {
                    $entry | Should -Not -Match '/'
                }
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "Flags IsDisabled for a case-insensitive spaced sentinel on any line and drops the line" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-sentinel-" + [Guid]::NewGuid().ToString() + ".txt")
            try {
                "## WHITELIST`nallowed.example`n# desactivado`nsecond.example" | Set-Content $tempFile -Encoding UTF8
                $sections = InModuleScope Common -Parameters @{ TempFile = $tempFile } {
                    Get-OpenPathWhitelistSectionsFromFile -Path $TempFile
                }
                $sections.IsDisabled | Should -BeTrue
                $sections.Whitelist | Should -Contain 'allowed.example'
                $sections.Whitelist | Should -Contain 'second.example'
                $sections.Whitelist | Should -Not -Contain '# desactivado'
            }
            finally { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }

        It "Routes entries under an unknown section header away from every known section" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-unknown-header-" + [Guid]::NewGuid().ToString() + ".txt")
            try {
                "## WHITELIST`nallowed.example`n## FUTURE-SECTION`ndropped.example" | Set-Content $tempFile -Encoding UTF8
                $sections = InModuleScope Common -Parameters @{ TempFile = $tempFile } {
                    Get-OpenPathWhitelistSectionsFromFile -Path $TempFile
                }
                $sections.Whitelist | Should -Not -Contain 'dropped.example'
                $sections.BlockedSubdomains | Should -HaveCount 0
                $sections.BlockedPaths | Should -HaveCount 0
                $sections.AllowedPaths | Should -HaveCount 0
            }
            finally { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }

        It "Uppercases section headers invariantly so lowercase headers are recognized" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-lowercase-header-" + [Guid]::NewGuid().ToString() + ".txt")
            try {
                "## whitelist`nallowed.example`n## blocked-subdomains`nads.allowed.example" | Set-Content $tempFile -Encoding UTF8
                $sections = InModuleScope Common -Parameters @{ TempFile = $tempFile } {
                    Get-OpenPathWhitelistSectionsFromFile -Path $TempFile
                }
                $sections.Whitelist | Should -Contain 'allowed.example'
                $sections.BlockedSubdomains | Should -Contain 'ads.allowed.example'
            }
            finally { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }

        It "Trims whitespace-padded entry lines" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-trim-" + [Guid]::NewGuid().ToString() + ".txt")
            try {
                "## WHITELIST`n  padded.example  " | Set-Content $tempFile -Encoding UTF8
                $sections = InModuleScope Common -Parameters @{ TempFile = $tempFile } {
                    Get-OpenPathWhitelistSectionsFromFile -Path $TempFile
                }
                $sections.Whitelist | Should -Contain 'padded.example'
            }
            finally { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    Context "Get-OpenPathWhitelistSectionsFromLines" {
        It "Parses pre-split lines including CR remnants identically to the file parser" {
            $sections = InModuleScope Common {
                Get-OpenPathWhitelistSectionsFromLines -Lines @(
                    "#DESACTIVADO`r",
                    '## WHITELIST',
                    "allowed.example`r",
                    '## BLOCKED-SUBDOMAINS',
                    'ads.allowed.example'
                )
            }
            $sections.IsDisabled | Should -BeTrue
            $sections.Whitelist | Should -Be @('allowed.example')
            $sections.BlockedSubdomains | Should -Be @('ads.allowed.example')
        }

        It "Returns empty sections for null or empty input" {
            $sections = InModuleScope Common { Get-OpenPathWhitelistSectionsFromLines -Lines @() }
            $sections.IsDisabled | Should -BeFalse
            @($sections.Whitelist).Count | Should -Be 0
            @($sections.AllowedPaths).Count | Should -Be 0
        }
    }

    Context "ConvertTo-OpenPathWhitelistFileContent" {
        It "Serializes whitelist, blocked subdomains, and blocked paths sections" {
            $content = InModuleScope Common {
                ConvertTo-OpenPathWhitelistFileContent `
                    -Whitelist @('allowed.example') `
                    -BlockedSubdomains @('ads.allowed.example') `
                    -BlockedPaths @('allowed.example/private')
            }

            Assert-ContentContainsAll -Content $content -Needles @(
                '## WHITELIST',
                'allowed.example',
                '## BLOCKED-SUBDOMAINS',
                'ads.allowed.example',
                '## BLOCKED-PATHS',
                'allowed.example/private'
            )
        }

        It "Serializes ALLOWED-PATHS section" {
            $content = InModuleScope Common {
                ConvertTo-OpenPathWhitelistFileContent `
                    -Whitelist @('allowed.example') `
                    -BlockedSubdomains @('ads.allowed.example') `
                    -BlockedPaths @('allowed.example/private') `
                    -AllowedPaths @('allowed.example/ok')
            }

            Assert-ContentContainsAll -Content $content -Needles @(
                '## WHITELIST',
                'allowed.example',
                '## BLOCKED-SUBDOMAINS',
                'ads.allowed.example',
                '## BLOCKED-PATHS',
                'allowed.example/private',
                '## ALLOWED-PATHS',
                'allowed.example/ok'
            )
        }
    }

    Context "Get-HostFromUrl" {
        It "Returns host for a valid URL" {
            $parsedHost = InModuleScope Common {
                Get-HostFromUrl -Url 'https://api.example.com/path?x=1'
            }
            $parsedHost | Should -Be 'api.example.com'
        }

        It "Returns null for invalid URL" {
            $parsedHost = InModuleScope Common {
                Get-HostFromUrl -Url 'not-a-valid-url'
            }
            $parsedHost | Should -BeNullOrEmpty
        }

        It "Returns null for empty URL" {
            $parsedHost = InModuleScope Common {
                Get-HostFromUrl -Url ''
            }
            $parsedHost | Should -BeNullOrEmpty
        }
    }

    Context "Test-OpenPathDomainFormat" {
        It "Accepts syntactically valid domains" {
            (InModuleScope Common { Test-OpenPathDomainFormat -Domain 'google.com' }) | Should -BeTrue
            (InModuleScope Common { Test-OpenPathDomainFormat -Domain 'sub.example.org' }) | Should -BeTrue
        }

        It "Rejects invalid domain values" {
            (InModuleScope Common { Test-OpenPathDomainFormat -Domain 'invalid domain' }) | Should -BeFalse
            (InModuleScope Common { Test-OpenPathDomainFormat -Domain 'bad..domain.com' }) | Should -BeFalse
            (InModuleScope Common { Test-OpenPathDomainFormat -Domain '-bad.example.com' }) | Should -BeFalse
            (InModuleScope Common { Test-OpenPathDomainFormat -Domain '' }) | Should -BeFalse
            (InModuleScope Common { Test-OpenPathDomainFormat -Domain $null }) | Should -BeFalse
        }

        It "Matches shared domain contract fixtures" {
            $validDomains = Get-ContractFixtureLines -FileName 'domain-valid.txt'
            foreach ($domain in $validDomains) {
                (InModuleScope Common -Parameters @{ Domain = $domain } {
                    Test-OpenPathDomainFormat -Domain $Domain
                }) | Should -BeTrue
            }

            $invalidDomains = Get-ContractFixtureLines -FileName 'domain-invalid.txt'
            foreach ($domain in $invalidDomains) {
                (InModuleScope Common -Parameters @{ Domain = $domain } {
                    Test-OpenPathDomainFormat -Domain $Domain
                }) | Should -BeFalse
            }
        }
    }

    Context "Get-OpenPathFromUrl" {
        It "Throws when URL is invalid" {
            { Get-OpenPathFromUrl -Url "https://invalid.example.com/404" } | Should -Throw
        }
    }

    Context "Test-InternetConnection" {
        It "Returns a boolean value" {
            $result = InModuleScope Common {
                Test-InternetConnection
            }
            $result | Should -BeOfType [bool]
        }
    }

    Context "Read-OpenPathCaptivePortalStateJson" {
        BeforeAll {
            . (Join-Path $PSScriptRoot '..' 'lib' 'internal' 'CaptivePortal.StateFiles.ps1')
        }

        It "Returns null for a missing file" {
            Read-OpenPathCaptivePortalStateJson -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.json')) | Should -BeNullOrEmpty
        }

        It "Returns null for an empty file" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-empty-" + [Guid]::NewGuid().ToString() + ".json")
            try {
                New-Item -ItemType File -Path $tempFile -Force | Out-Null
                Read-OpenPathCaptivePortalStateJson -Path $tempFile | Should -BeNullOrEmpty
            }
            finally { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }

        It "Returns null for unparseable JSON" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-bad-" + [Guid]::NewGuid().ToString() + ".json")
            try {
                'not json {' | Set-Content $tempFile -Encoding UTF8
                Read-OpenPathCaptivePortalStateJson -Path $tempFile | Should -BeNullOrEmpty
            }
            finally { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }

        It "Parses a valid state file" {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-good-" + [Guid]::NewGuid().ToString() + ".json")
            try {
                '{"active": true, "state": "Portal"}' | Set-Content $tempFile -Encoding UTF8
                (Read-OpenPathCaptivePortalStateJson -Path $tempFile).state | Should -Be 'Portal'
            }
            finally { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
}
