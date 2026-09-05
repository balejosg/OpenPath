Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Installer" {
    Context "Phase pipeline" {
        BeforeAll {
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Plan.ps1")
        }

        It "Builds the installer plan in execution order while preserving public parameter inputs" {
            $inputParameters = @{
                WhitelistUrl = 'https://allow.example.test'
                SkipAcrylic = $true
                SkipPreflight = $true
                Classroom = 'math'
                ApiUrl = 'https://api.example.test'
                RegistrationToken = 'reg-secret'
                EnrollmentToken = ''
                ClassroomId = ''
                MachineName = 'student-01'
                FirefoxExtensionId = 'openpath@example'
                FirefoxExtensionInstallUrl = 'https://addons.example/openpath.xpi'
                ChromeExtensionStoreUrl = 'https://chrome.example/openpath'
                EdgeExtensionStoreUrl = 'https://edge.example/openpath'
                Unattended = $true
                HealthApiSecret = 'health-secret'
                EnforceManagedBrowserBoundary = $true
                ApprovedStudentBrowsers = @('Firefox')
                BrowserCleanupMode = 'ReportOnly'
                TimingOutputPath = 'C:\OpenPath\timing.json'
            }

            $plan = New-OpenPathInstallPlan -Parameters $inputParameters -OpenPathRoot 'C:\OpenPath' -ScriptDir 'C:\pkg\windows'

            $plan.Type | Should -Be 'OpenPathInstallPlan'
            @($plan.Phases.Name) | Should -Be @(
                'existing-install-cleanup',
                'preflight',
                'directories',
                'runtime',
                'offline-payload-verification',
                'configuration',
                'acrylic',
                'acrylic-configuration',
                'local-dns',
                'enrollment',
                'native-host',
                'first-update',
                'scheduled-tasks',
                'app-control',
                'firefox-managed-extension-ready',
                'realtime-updates',
                'browser-inventory',
                'integrity',
                'timing',
                'summary'
            )
            $plan.Context.OpenPathRoot | Should -Be 'C:\OpenPath'
            $plan.Context.ScriptDir | Should -Be 'C:\pkg\windows'
            $plan.Parameters.WhitelistUrl | Should -Be 'https://allow.example.test'
            $plan.Parameters.BrowserCleanupMode | Should -Be 'ReportOnly'
            ($plan.Phases | Where-Object Name -eq 'firefox-managed-extension-ready').RecoveryHint |
                Should -Be 'Check Firefox Release installation and executable discovery; inspect managed extension policy only after executable discovery succeeds.'
        }

        It "Returns structured success and failure results for installer phases" {
            $success = Invoke-OpenPathInstallPhase -Phase ([pscustomobject]@{
                    Name = 'configuration'
                    Step = 3
                    TotalSteps = 7
                    Status = 'Creating configuration'
                    Inputs = @{ WhitelistUrl = 'https://allow.example.test'; RegistrationToken = 'secret-token' }
                    RecoveryHint = 'Check installer configuration inputs.'
                    Action = { param($Context) $Context.Value = 42 }
                }) -Context ([pscustomobject]@{ Value = 0 })

            $success.Type | Should -Be 'OpenPathInstallResult'
            $success.Name | Should -Be 'configuration'
            $success.Success | Should -BeTrue
            $success.Status | Should -Be 'success'
            $success.DurationMs | Should -BeGreaterOrEqual 0
            $success.Inputs.WhitelistUrl | Should -Be 'https://allow.example.test'
            $success.Inputs.RegistrationToken | Should -Be '<redacted>'
            $success.Error | Should -BeNullOrEmpty

            $failure = Invoke-OpenPathInstallPhase -Phase ([pscustomobject]@{
                    Name = 'enrollment'
                    Step = 9
                    TotalSteps = 7
                    Status = 'Registrando equipo'
                    Inputs = @{ EnrollmentToken = 'enroll-secret'; MachineName = 'student-01' }
                    RecoveryHint = 'Re-run enrollment after checking API URL and token.'
                    Action = { throw 'registration failed' }
                }) -Context ([pscustomobject]@{})

            $failure.Type | Should -Be 'OpenPathInstallResult'
            $failure.Name | Should -Be 'enrollment'
            $failure.Success | Should -BeFalse
            $failure.Status | Should -Be 'failed'
            $failure.Inputs.EnrollmentToken | Should -Be '<redacted>'
            $failure.Inputs.MachineName | Should -Be 'student-01'
            $failure.Error.Message | Should -BeLike '*registration failed*'
            $failure.Error.Category | Should -Not -BeNullOrEmpty
            $failure.RecoveryHint | Should -Be 'Re-run enrollment after checking API URL and token.'
        }

        It "Keeps Install-OpenPath public parameters compatible while using the phase pipeline helper" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[string]$WhitelistUrl = ""',
                '[switch]$SkipAcrylic',
                '[switch]$SkipPreflight',
                '[string]$Classroom = ""',
                '[string]$ApiUrl = ""',
                '[string]$RegistrationToken = ""',
                '[string]$EnrollmentToken = ""',
                '[string]$ClassroomId = ""',
                '[string]$MachineName = ""',
                '[string]$FirefoxExtensionId = ""',
                '[string]$FirefoxExtensionInstallUrl = ""',
                '[string]$ChromeExtensionStoreUrl = ""',
                '[string]$EdgeExtensionStoreUrl = ""',
                '[switch]$Unattended',
                '[string]$HealthApiSecret = ""',
                '[switch]$EnforceManagedBrowserBoundary',
                '[string[]]$ApprovedStudentBrowsers = @(''Firefox'')',
                '[string]$BrowserCleanupMode = ''ReportOnly''',
                '[string]$TimingOutputPath = ""',
                'Installer.Plan.ps1',
                'New-OpenPathInstallPlan',
                'Invoke-OpenPathInstallPhase'
            )
        }

        It "Executes representative installer phases through structured phase results" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $phaseNames = @(
                'configuration',
                'acrylic',
                'scheduled-tasks',
                'enrollment',
                'native-host',
                'first-update',
                'app-control',
                'browser-inventory',
                'integrity',
                'timing',
                'summary'
            )

            foreach ($phaseName in $phaseNames) {
                $content | Should -Match "Invoke-OpenPathPlanned(?:Warning)?Phase -Name '$phaseName'"
            }
        }

        It "Treats Acrylic service and configuration failures as fatal before local DNS" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Acrylic is installed but the AcrylicDNSProxySvc service could not be registered or started',
                'Acrylic installation failed or did not produce a running AcrylicDNSProxySvc service',
                '$acrylicConfigurationApplied = Set-AcrylicConfiguration -CaptivePortalDomains $CaptivePortalDomains -WhatIf:$WhatIfPreference',
                "throw 'Acrylic configuration failed'",
                "Invoke-OpenPathPlannedPhase -Name 'acrylic-configuration'",
                "Invoke-OpenPathPlannedPhase -Name 'local-dns'"
            )
            $content.IndexOf("Invoke-OpenPathPlannedPhase -Name 'acrylic-configuration'") | Should -BeLessThan $content.IndexOf("Invoke-OpenPathPlannedPhase -Name 'local-dns'")
        }

        It "keeps Acrylic installer failure evidence at bounded operation phases" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            foreach ($phase in @(
                    'acrylic-detect-existing',
                    'acrylic-resolve-manifest',
                'acrylic-install-local',
                'acrylic-ensure-service'
                )) {
                $content | Should -Match ([regex]::Escape($phase))
            }
        }

        It "Rolls back OpenPath-owned mutations through catchable installer failures delegating to Installer.Cleanup.ps1" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            # Install-OpenPath.ps1 must delegate exclusively to Installer.Cleanup.ps1 and not define its own orphaned Invoke-OpenPathInstallRollback
            $content | Should -Not -Match '(?m)^\s*function\s+Invoke-OpenPathInstallRollback\b'
            $content | Should -Match "Installer\.Cleanup\.ps1"

            Assert-ContentContainsAll -Content $content -Needles @(
                '$script:OpenPathInstallerMutated = $false',
                'Invoke-OpenPathInstallRollback -OpenPathRoot $OpenPathRoot',
                'Write-OpenPathInstallerFailureStatus',
                'trap {',
                'throw "Installer phase failed: $($Result.Name)"'
            )
            $content | Should -Not -Match 'Assert-OpenPathInstallPhaseSucceeded[\s\S]*?exit 1'

            # Installer.Cleanup.ps1 is the sole canonical owner of Invoke-OpenPathInstallRollback and its cleanup steps
            $cleanupPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
            $cleanupContent = Get-Content $cleanupPath -Raw
            Assert-ContentContainsAll -Content $cleanupContent -Needles @(
                'function Invoke-OpenPathInstallRollback',
                'Stop-OpenPathInstallerScheduledTasks',
                'Restore-OpenPathInstallerDnsSettings',
                'Remove-OpenPathInstallerFirewallRules',
                'Remove-OpenPathInstallerAppLockerRules',
                'Remove-OpenPathInstallerRestrictedGroup',
                'Remove-OpenPathInstallerBrowserArtifacts',
                'Stop-OpenPathInstallerAcrylicService -KeepAcrylic',
                'Remove-Item -LiteralPath $configPath',
                '$script:OpenPathInstallRollbackResult',
                'VerifiedNonOperational'
            )
        }

        It "Executes rollback leaving host VerifiedNonOperational when firefox-managed-extension-ready fails after app-control" {
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1")

            $root = Join-Path $TestDrive "rollback-lifecycle-test"
            $dataDir = Join-Path $root "data"
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            $configPath = Join-Path $dataDir "config.json"

            if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Get-ScheduledTask { param($TaskName) } }
            if (-not (Get-Command Stop-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Stop-ScheduledTask { param($TaskName, $TaskPath) } }
            if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm) } }
            if (-not (Get-Command Get-LocalGroup -ErrorAction SilentlyContinue)) { function global:Get-LocalGroup { param($Name) } }
            if (-not (Get-Command Remove-LocalGroup -ErrorAction SilentlyContinue)) { function global:Remove-LocalGroup { param($Name) } }
            if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Get-AppLockerPolicy { param([switch]$Local, [switch]$Xml) } }
            if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Set-AppLockerPolicy { param($XMLPolicy) } }

            $script:mockTasks = [System.Collections.Generic.List[string]]::new()
            $script:mockGroupPresent = $true
            $script:mockAppLockerRules = [System.Collections.Generic.List[string]]::new()

            Mock Get-ScheduledTask {
                param($TaskName)
                return @($script:mockTasks | ForEach-Object { [pscustomobject]@{ TaskName = $_; TaskPath = '\OpenPath\' } })
            }
            Mock Stop-ScheduledTask { param($TaskName, $TaskPath) }
            Mock Unregister-ScheduledTask {
                param($TaskName, $TaskPath, [switch]$Confirm)
                [void]$script:mockTasks.Remove($TaskName)
            }
            Mock Get-LocalGroup {
                param($Name)
                if ($script:mockGroupPresent) { return [pscustomobject]@{ Name = 'OpenPath-Restricted' } }
                return $null
            }
            Mock Remove-LocalGroup {
                param($Name)
                $script:mockGroupPresent = $false
            }
            Mock Get-AppLockerPolicy {
                param([switch]$Local, [switch]$Xml)
                $ruleNodes = ($script:mockAppLockerRules | ForEach-Object { "<FilePathRule Id=`"$([guid]::NewGuid())`" Name=`"OpenPath non-admin app control - $_`" Action=`"Deny`" UserOrGroupSid=`"S-1-5-32-545`"><Conditions><FilePathCondition Path=`"%OSDRIVE%\*`" /></Conditions></FilePathRule>" }) -join ''
                return "<AppLockerPolicy Version=`"1`"><RuleCollection Type=`"Exe`" EnforcementMode=`"Enabled`">$ruleNodes</RuleCollection></AppLockerPolicy>"
            }
            Mock Set-AppLockerPolicy {
                param($XMLPolicy)
                $script:mockAppLockerRules.Clear()
            }
            Mock Restore-OpenPathInstallerDnsSettings { }
            Mock Remove-OpenPathInstallerFirewallRules { }
            Mock Remove-OpenPathInstallerBrowserArtifacts { }
            Mock Stop-OpenPathInstallerAcrylicService { }

            $script:OpenPathInstallerRollingBack = $false
            $script:OpenPathInstallRollbackResult = $null

            # 1. Configuration phase
            $phaseConfig = Invoke-OpenPathInstallPhase -Phase (New-OpenPathInstallPhase -Name 'configuration' -Action {
                $initialConfig = [ordered]@{
                    installState = 'installing'
                    appControlCommitState = 'pending'
                    enableNonAdminAppControl = $true
                    nonAdminAppControlMode = 'Enforced'
                    approvedStudentBrowsers = @('Firefox')
                }
                $initialConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
            })
            $phaseConfig.Success | Should -BeTrue
            Test-Path -LiteralPath $configPath | Should -BeTrue

            # 2. Scheduled-tasks phase
            $phaseTasks = Invoke-OpenPathInstallPhase -Phase (New-OpenPathInstallPhase -Name 'scheduled-tasks' -Action {
                $script:mockTasks.Add('OpenPath-Update')
                $script:mockTasks.Add('OpenPath-Watchdog')
            })
            $phaseTasks.Success | Should -BeTrue
            $script:mockTasks.Count | Should -Be 2

            # 3. App-control phase: configures boundary, commits security point
            $phaseAppControl = Invoke-OpenPathInstallPhase -Phase (New-OpenPathInstallPhase -Name 'app-control' -Action {
                $script:mockAppLockerRules.Add('BlockDownloads')
                $committed = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
                $committed.appControlCommitState = 'committed'
                $committed | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
            })
            $phaseAppControl.Success | Should -BeTrue
            (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).appControlCommitState | Should -Be 'committed'

            # 4. Firefox-managed-extension-ready phase: throws failure
            $phaseFirefox = Invoke-OpenPathInstallPhase -Phase (New-OpenPathInstallPhase -Name 'firefox-managed-extension-ready' -Action {
                throw 'Firefox managed extension policy is not ready'
            })
            $phaseFirefox.Success | Should -BeFalse

            # 5. Rollback triggered
            $rollbackResult = Invoke-OpenPathInstallRollback -OpenPathRoot $root

            # 6. Host verified non-operational and clean
            $rollbackResult.Attempted | Should -BeTrue
            $rollbackResult.Success | Should -BeTrue
            $rollbackResult.VerifiedNonOperational | Should -BeTrue
            $rollbackResult.Errors.Count | Should -Be 0
            Test-Path -LiteralPath $configPath | Should -BeFalse
            $script:mockTasks.Count | Should -Be 0
            $script:mockGroupPresent | Should -BeFalse
            $script:mockAppLockerRules.Count | Should -Be 0
        }

        It "Refuses full health and degrades when interrupted install reboot occurs with pending commitState" {
            . (Join-Path $PSScriptRoot ".." "lib" "internal" "Watchdog.Runtime.ps1")
            Import-Module (Join-Path $PSScriptRoot ".." "lib" "Browser.EnforcementStatus.psm1") -Force

            $interruptedConfig = [pscustomobject]@{
                installState = 'installing'
                appControlCommitState = 'pending'
                enableNonAdminAppControl = $true
                nonAdminAppControlMode = 'Enforced'
                approvedStudentBrowsers = @('Firefox')
                enableIntegrityChecks = $false
                enableAcrylic = $false
                enableLocalDns = $false
                whitelistUrl = 'https://example.com/whitelist'
                apiUrl = ''
                dnsHealthCheckDomain = 'example.com'
            }

            $status = InModuleScope Browser.EnforcementStatus -Parameters @{ Cfg = $interruptedConfig } {
                Get-OpenPathAppLockerStatus -Config $Cfg
            }
            $status | Should -Be 'Inactive'

            if (-not (Get-Command Write-OpenPathLog -ErrorAction SilentlyContinue)) { function global:Write-OpenPathLog { } }
            if (-not (Get-Command Increment-WatchdogFailCount -ErrorAction SilentlyContinue)) { function global:Increment-WatchdogFailCount { return 1 } }
            if (-not (Get-Command Reset-WatchdogFailCount -ErrorAction SilentlyContinue)) { function global:Reset-WatchdogFailCount { return 0 } }
            if (-not (Get-Command Get-OpenPathEndpointPolicyState -ErrorAction SilentlyContinue)) { function global:Get-OpenPathEndpointPolicyState { return [pscustomobject]@{ FailOpenActive = $false; ProtectedModeEligible = $true } } }
            if (-not (Get-Command Get-OpenPathWhitelistSectionsFromFile -ErrorAction SilentlyContinue)) { function global:Get-OpenPathWhitelistSectionsFromFile { return [pscustomobject]@{} } }
            if (-not (Get-Command Invoke-OpenPathCaptivePortalPassthroughEmergencyChecks -ErrorAction SilentlyContinue)) { function global:Invoke-OpenPathCaptivePortalPassthroughEmergencyChecks { return [pscustomobject]@{ Issues = @() } } }
            if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) { function global:Get-Service { return $null } }
            if (-not (Get-Command Test-OpenPathNonAdminAppControlActive -ErrorAction SilentlyContinue)) { function global:Test-OpenPathNonAdminAppControlActive { } }
            if (-not (Get-Command Set-OpenPathNonAdminAppControl -ErrorAction SilentlyContinue)) { function global:Set-OpenPathNonAdminAppControl { } }

            $watchdogRoot = Join-Path $TestDrive "watchdog-interrupted-root"
            $watchdogData = Join-Path $watchdogRoot "data"
            New-Item -ItemType Directory -Path $watchdogData -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $watchdogData "whitelist.txt") -Value "allow test.example" -Encoding UTF8
            $staleFailsafeStatePath = Join-Path $watchdogData "stale-failsafe-state.json"

            Mock Test-OpenPathNonAdminAppControlActive { return $false }
            Mock Set-OpenPathNonAdminAppControl { return $false }

            $runtimeChecks = Invoke-OpenPathWatchdogChecks `
                -Config $interruptedConfig `
                -PortalModeActive $false `
                -CaptiveState 'Direct' `
                -OpenPathRoot $watchdogRoot `
                -StaleFailsafeStatePath $staleFailsafeStatePath `
                -GroupSyncFailed $false

            $outcome = Get-OpenPathWatchdogOutcome `
                -Config $interruptedConfig `
                -Issues $runtimeChecks.Issues `
                -RecoveryEligibleIssues $runtimeChecks.RecoveryEligibleIssues `
                -StaleFailsafeActive $false `
                -IntegrityTampered $false `
                -FailOpenActive $false `
                -PortalModeActive $false `
                -WatchdogFailCountPath (Join-Path $TestDrive 'watchdog-fails.txt') `
                -OpenPathRoot $watchdogRoot

            $outcome.Status | Should -Be 'DEGRADED'
            @($runtimeChecks.Issues) | Should -Contain 'AppControl commit state is uncommitted (pending)'
        }
    }

    Context "Atomic configuration writes" {
        BeforeAll {
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1")
        }

        It "creates new JSON file atomically and creates parent directories" {
            $testDir = Join-Path $TestDrive "atomic-create-test" "sub" "dir"
            $testFile = Join-Path $testDir "config.json"
            $data = [ordered]@{
                installState = 'installing'
                version = '2.5.0'
                settings = @{ enabled = $true; count = 10 }
            }

            Write-OpenPathAtomicJsonFile -Path $testFile -Data $data
            Test-Path -LiteralPath $testFile | Should -BeTrue

            $readBack = Get-Content -LiteralPath $testFile -Raw | ConvertFrom-Json
            $readBack.installState | Should -Be 'installing'
            $readBack.version | Should -Be '2.5.0'
            $readBack.settings.enabled | Should -BeTrue
            $readBack.settings.count | Should -Be 10

            # No temporary files left behind
            $orphans = @(Get-ChildItem -LiteralPath $testDir -Filter "*.tmp.*")
            $orphans.Count | Should -Be 0
        }

        It "atomically replaces existing JSON file without leaving orphaned files" {
            $testDir = Join-Path $TestDrive "atomic-replace-test"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $testFile = Join-Path $testDir "config.json"

            Write-OpenPathAtomicJsonFile -Path $testFile -Data @{ stage = 'first'; value = 1 }
            $first = Get-Content -LiteralPath $testFile -Raw | ConvertFrom-Json
            $first.stage | Should -Be 'first'

            Write-OpenPathAtomicJsonFile -Path $testFile -Data @{ stage = 'second'; value = 2 }
            $second = Get-Content -LiteralPath $testFile -Raw | ConvertFrom-Json
            $second.stage | Should -Be 'second'
            $second.value | Should -Be 2

            @(Get-ChildItem -LiteralPath $testDir -Filter "*.tmp.*").Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $testDir -Filter "*.bak.*").Count | Should -Be 0
        }

        It "cleans up temporary files if write or replace fails" {
            $testDir = Join-Path $TestDrive "atomic-fail-test"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            # Attempt to write to a directory path as if it were a file
            { Write-OpenPathAtomicJsonFile -Path $testDir -Data @{ error = $true } } | Should -Throw

            @(Get-ChildItem -LiteralPath (Split-Path $testDir -Parent) -Filter "*.tmp.*").Count | Should -Be 0
        }
    }

    Context "Installer lifecycle failure injection and rollback" {
        BeforeAll {
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Plan.ps1")
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1")
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1")
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1")
        }

        BeforeEach {
            $script:mockTasks = [System.Collections.Generic.List[string]]::new()
            $script:mockGroupPresent = $false
            $script:mockAppLockerRules = [System.Collections.Generic.List[string]]::new()
            $script:OpenPathInstallerRollingBack = $false
            $script:OpenPathInstallRollbackResult = $null
            $script:OpenPathInstallPhaseResults = @()

            if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Get-ScheduledTask { param($TaskName) } }
            if (-not (Get-Command Stop-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Stop-ScheduledTask { param($TaskName, $TaskPath) } }
            if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm) } }
            if (-not (Get-Command Get-LocalGroup -ErrorAction SilentlyContinue)) { function global:Get-LocalGroup { param($Name) } }
            if (-not (Get-Command Remove-LocalGroup -ErrorAction SilentlyContinue)) { function global:Remove-LocalGroup { param($Name) } }
            if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Get-AppLockerPolicy { param([switch]$Local, [switch]$Xml) } }
            if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Set-AppLockerPolicy { param($XMLPolicy) } }

            Mock Get-ScheduledTask {
                param($TaskName)
                return @($script:mockTasks | ForEach-Object { [pscustomobject]@{ TaskName = $_; TaskPath = '\OpenPath\' } })
            }
            Mock Stop-ScheduledTask { param($TaskName, $TaskPath) }
            Mock Unregister-ScheduledTask {
                param($TaskName, $TaskPath, [switch]$Confirm)
                [void]$script:mockTasks.Remove($TaskName)
            }
            Mock Get-LocalGroup {
                param($Name)
                if ($script:mockGroupPresent) { return [pscustomobject]@{ Name = 'OpenPath-Restricted' } }
                return $null
            }
            Mock Remove-LocalGroup {
                param($Name)
                $script:mockGroupPresent = $false
            }
            Mock Get-AppLockerPolicy {
                param([switch]$Local, [switch]$Xml)
                $ruleNodes = ($script:mockAppLockerRules | ForEach-Object { "<FilePathRule Id=`"$([guid]::NewGuid())`" Name=`"OpenPath non-admin app control - $_`" Action=`"Deny`" UserOrGroupSid=`"S-1-5-32-545`"><Conditions><FilePathCondition Path=`"%OSDRIVE%\*`" /></Conditions></FilePathRule>" }) -join ''
                return "<AppLockerPolicy Version=`"1`"><RuleCollection Type=`"Exe`" EnforcementMode=`"Enabled`">$ruleNodes</RuleCollection></AppLockerPolicy>"
            }
            Mock Set-AppLockerPolicy {
                param($XMLPolicy)
                $script:mockAppLockerRules.Clear()
            }
            Mock Restore-OpenPathInstallerDnsSettings { }
            Mock Remove-OpenPathInstallerFirewallRules { }
            Mock Remove-OpenPathInstallerBrowserArtifacts { }
            Mock Stop-OpenPathInstallerAcrylicService { }
        }

        AfterEach {
            $env:OPENPATH_TEST_ENVIRONMENT = $null
            $env:OPENPATH_TEST_FAIL_PHASE = $null
            $env:OPENPATH_TEST_FAIL_AFTER_PHASE = $null
        }

        It "rolls back completely when failure is injected at firefox-managed-extension-ready after app-control" {
            $root = Join-Path $TestDrive "inject-fail-firefox"
            $dataDir = Join-Path $root "data"
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            $configPath = Join-Path $dataDir "config.json"
            $statusPath = Join-Path $dataDir "failure-status"

            $plan = New-OpenPathInstallPlan -Parameters @{ EnforceManagedBrowserBoundary = $true } -ScriptDir $PSScriptRoot -OpenPathRoot $root

            # Execute configuration phase
            Invoke-OpenPathPlannedPhase -Name 'configuration' -Plan $plan -Action {
                Write-OpenPathAtomicJsonFile -Path $configPath -Data @{
                    installState = 'installing'
                    appControlCommitState = 'pending'
                }
            }

            # Execute scheduled-tasks phase
            Invoke-OpenPathPlannedPhase -Name 'scheduled-tasks' -Plan $plan -Action {
                $script:mockTasks.Add('OpenPath-Update')
                $script:mockTasks.Add('OpenPath-Watchdog')
            }

            # Execute app-control phase
            Invoke-OpenPathPlannedPhase -Name 'app-control' -Plan $plan -Action {
                $script:mockGroupPresent = $true
                $script:mockAppLockerRules.Add('BlockDownloads')
                Write-OpenPathAtomicJsonFile -Path $configPath -Data @{
                    installState = 'installing'
                    appControlCommitState = 'committed'
                }
            }

            $script:mockGroupPresent | Should -BeTrue
            $script:mockAppLockerRules.Count | Should -Be 1
            $script:mockTasks.Count | Should -Be 2

            # Inject failure at firefox-managed-extension-ready
            $env:OPENPATH_TEST_ENVIRONMENT = '1'
            $env:OPENPATH_TEST_FAIL_PHASE = 'firefox-managed-extension-ready'

            $caughtError = $null
            try {
                Invoke-OpenPathPlannedPhase -Name 'firefox-managed-extension-ready' -Plan $plan -Action { }
            }
            catch {
                $caughtError = $_
                $rollback = Invoke-OpenPathInstallRollback -OpenPathRoot $root
                Write-OpenPathInstallerFailureStatus -Path $statusPath -Phase 'firefox-managed-extension-ready' -RollbackAttempted $true -RollbackResult $rollback
            }

            $caughtError | Should -Not -BeNullOrEmpty
            $caughtError.Exception.Message | Should -Match 'Injected test failure at phase: firefox-managed-extension-ready'

            # Rollback verification
            $script:OpenPathInstallRollbackResult.Attempted | Should -BeTrue
            $script:OpenPathInstallRollbackResult.Success | Should -BeTrue
            $script:OpenPathInstallRollbackResult.VerifiedNonOperational | Should -BeTrue
            $script:OpenPathInstallRollbackResult.Errors.Count | Should -Be 0
            Test-Path -LiteralPath $configPath | Should -BeFalse
            $script:mockTasks.Count | Should -Be 0
            $script:mockGroupPresent | Should -BeFalse
            $script:mockAppLockerRules.Count | Should -Be 0

            # Status file verification
            Test-Path -LiteralPath "$statusPath.json" | Should -BeTrue
            $statusJson = Get-Content -LiteralPath "$statusPath.json" -Raw | ConvertFrom-Json
            $statusJson.Phase | Should -Be 'firefox-managed-extension-ready'
            $statusJson.RollbackAttempted | Should -BeTrue
            $statusJson.RollbackResult.VerifiedNonOperational | Should -BeTrue
        }

        It "rolls back cleanly without errors when failure is injected before app-control (scheduled-tasks)" {
            $root = Join-Path $TestDrive "inject-fail-pre-appcontrol"
            $dataDir = Join-Path $root "data"
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            $configPath = Join-Path $dataDir "config.json"
            $statusPath = Join-Path $dataDir "failure-status"

            $plan = New-OpenPathInstallPlan -Parameters @{ EnforceManagedBrowserBoundary = $true } -ScriptDir $PSScriptRoot -OpenPathRoot $root

            Invoke-OpenPathPlannedPhase -Name 'configuration' -Plan $plan -Action {
                Write-OpenPathAtomicJsonFile -Path $configPath -Data @{
                    installState = 'installing'
                    appControlCommitState = 'pending'
                }
            }

            # Inject failure at scheduled-tasks (before app-control)
            $env:OPENPATH_TEST_ENVIRONMENT = '1'
            $env:OPENPATH_TEST_FAIL_PHASE = 'scheduled-tasks'

            $caughtError = $null
            try {
                Invoke-OpenPathPlannedPhase -Name 'scheduled-tasks' -Plan $plan -Action {
                    $script:mockTasks.Add('OpenPath-Update')
                }
            }
            catch {
                $caughtError = $_
                $rollback = Invoke-OpenPathInstallRollback -OpenPathRoot $root
                Write-OpenPathInstallerFailureStatus -Path $statusPath -Phase 'scheduled-tasks' -RollbackAttempted $true -RollbackResult $rollback
            }

            $caughtError | Should -Not -BeNullOrEmpty
            $caughtError.Exception.Message | Should -Match 'Injected test failure at phase: scheduled-tasks'

            $script:OpenPathInstallRollbackResult.Attempted | Should -BeTrue
            $script:OpenPathInstallRollbackResult.Success | Should -BeTrue
            $script:OpenPathInstallRollbackResult.VerifiedNonOperational | Should -BeTrue
            $script:OpenPathInstallRollbackResult.Errors.Count | Should -Be 0
            Test-Path -LiteralPath $configPath | Should -BeFalse
            $script:mockGroupPresent | Should -BeFalse
            $script:mockAppLockerRules.Count | Should -Be 0
        }

        It "rolls back committed security state when failure is injected immediately after app-control" {
            $root = Join-Path $TestDrive "inject-fail-after-appcontrol"
            $dataDir = Join-Path $root "data"
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            $configPath = Join-Path $dataDir "config.json"
            $statusPath = Join-Path $dataDir "failure-status"

            $plan = New-OpenPathInstallPlan -Parameters @{ EnforceManagedBrowserBoundary = $true } -ScriptDir $PSScriptRoot -OpenPathRoot $root

            Invoke-OpenPathPlannedPhase -Name 'configuration' -Plan $plan -Action {
                Write-OpenPathAtomicJsonFile -Path $configPath -Data @{
                    installState = 'installing'
                    appControlCommitState = 'pending'
                }
            }

            Invoke-OpenPathPlannedPhase -Name 'scheduled-tasks' -Plan $plan -Action {
                $script:mockTasks.Add('OpenPath-Update')
            }

            # Inject failure immediately AFTER app-control completes
            $env:OPENPATH_TEST_ENVIRONMENT = '1'
            $env:OPENPATH_TEST_FAIL_AFTER_PHASE = 'app-control'

            $caughtError = $null
            try {
                Invoke-OpenPathPlannedPhase -Name 'app-control' -Plan $plan -Action {
                    $script:mockGroupPresent = $true
                    $script:mockAppLockerRules.Add('BlockDownloads')
                    Write-OpenPathAtomicJsonFile -Path $configPath -Data @{
                        installState = 'installing'
                        appControlCommitState = 'committed'
                    }
                }
            }
            catch {
                $caughtError = $_
                $rollback = Invoke-OpenPathInstallRollback -OpenPathRoot $root
                Write-OpenPathInstallerFailureStatus -Path $statusPath -Phase $script:OpenPathInstallerCurrentPhase -RollbackAttempted $true -RollbackResult $rollback
            }

            $caughtError | Should -Not -BeNullOrEmpty
            $caughtError.Exception.Message | Should -Match 'Injected test failure immediately after phase: app-control'
            $script:OpenPathInstallerCurrentPhase | Should -Be 'post-app-control'

            $script:OpenPathInstallRollbackResult.Attempted | Should -BeTrue
            $script:OpenPathInstallRollbackResult.Success | Should -BeTrue
            $script:OpenPathInstallRollbackResult.VerifiedNonOperational | Should -BeTrue
            $script:OpenPathInstallRollbackResult.Errors.Count | Should -Be 0
            Test-Path -LiteralPath $configPath | Should -BeFalse
            $script:mockGroupPresent | Should -BeFalse
            $script:mockAppLockerRules.Count | Should -Be 0
            $script:mockTasks.Count | Should -Be 0

            $statusJson = Get-Content -LiteralPath "$statusPath.json" -Raw | ConvertFrom-Json
            $statusJson.Phase | Should -Be 'post-app-control'
            $statusJson.RollbackAttempted | Should -BeTrue
            $statusJson.RollbackResult.VerifiedNonOperational | Should -BeTrue
        }
    }

    Context "ACL lockdown" {
        BeforeAll {
            . (Join-Path $PSScriptRoot ".." "lib" "internal" "CapabilityStorage.ps1")
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Progress.ps1")
            . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1")
        }

        It "Keeps SYSTEM and Administrators able to traverse the restricted install tree" -Skip:($IsWindows -ne $true -or -not (Test-IsAdmin)) {
            $root = Join-Path $TestDrive "OpenPath-install-root"

            {
                Initialize-OpenPathInstallDirectories -OpenPathRoot $root
            } | Should -Not -Throw

            foreach ($relativePath in @(
                    '',
                    'data',
                    'data\runtime-dependency-queue',
                    'browser-extension'
                )) {
                $path = if ($relativePath) { Join-Path $root $relativePath } else { $root }
                $acl = Get-Acl -LiteralPath $path

                @($acl.Access | Where-Object {
                        ([string]$_.IdentityReference) -eq 'NT AUTHORITY\SYSTEM' -and
                        ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl
                    }).Count | Should -BeGreaterThan 0 -Because "SYSTEM must retain full control at $relativePath"

                @($acl.Access | Where-Object {
                        ([string]$_.IdentityReference) -eq 'BUILTIN\Administrators' -and
                        ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl
                    }).Count | Should -BeGreaterThan 0 -Because "Administrators must retain full control at $relativePath"
            }
        }

        It "Sets restrictive file permissions during installation" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Set-OpenPathCapabilityStorageAcl -Path $OpenPathRoot -Profile RestrictedRoot',
                'CapabilityStorage.ps1'
            )
        }

        It "Grants local users read access to staged browser extension artifacts" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$browserExtensionAclPath = "$OpenPathRoot\browser-extension"',
                'Set-OpenPathCapabilityStorageAcl -Path $browserExtensionAclPath -Profile BrowserExtensionRead',
                'Read access granted for browser extension artifacts'
            )
        }

        It "Creates captive portal recovery queue and result directories with narrow ACLs" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryQueue',
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryResult',
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryProgress',
                'Set-OpenPathCapabilityStorageAcl -Path $captivePortalRecoveryQueuePath -Profile CaptivePortalRecoveryQueue',
                'Set-OpenPathCapabilityStorageAcl -Path $captivePortalRecoveryResultPath -Profile CaptivePortalRecoveryResultRead',
                'Set-OpenPathCapabilityStorageAcl -Path $captivePortalRecoveryProgressPath -Profile CaptivePortalRecoveryResultRead'
            )
        }

        It "Stages Firefox release assets beneath the user-readable browser-extension ACL root" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$browserExtensionAclPath = "$OpenPathRoot\browser-extension"',
                '$firefoxReleaseTarget = "$OpenPathRoot\browser-extension\firefox-release"',
                'Signed Firefox Release artifacts staged in $OpenPathRoot\browser-extension\firefox-release'
            )
        }

        It "Stages Chromium managed rollout metadata beneath the user-readable browser-extension ACL root" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$browserExtensionAclPath = "$OpenPathRoot\browser-extension"',
                '$chromiumManagedCandidates = @(',
                "firefox-extension\build\chromium-managed",
                '$chromiumManagedTarget = "$OpenPathRoot\browser-extension\chromium-managed"',
                'Chromium managed rollout metadata staged in $OpenPathRoot\browser-extension\chromium-managed'
            )
        }

        It "Stages Windows native host assets beneath the user-readable Firefox native directory" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $catalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.ArtifactCatalog.ps1"
            $content = Get-Content $scriptPath -Raw

            . $catalogPath
            $artifactNames = @(Get-OpenPathNativeHostArtifactNames)
            $artifactNames | Should -Contain 'OpenPath-NativeHost.ps1'
            $artifactNames | Should -Contain 'OpenPath-NativeHost.cmd'
            $artifactNames | Should -Contain 'NativeHost.Actions.ps1'
            $artifactNames | Should -Contain 'RuntimeDependency.Protocol.ps1'

            $scriptRoot = Join-Path $TestDrive 'package\scripts'
            $libRoot = Join-Path $TestDrive 'package\lib'
            $internalRoot = Join-Path $libRoot 'internal'
            New-Item -ItemType Directory -Path $scriptRoot, $libRoot, $internalRoot -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $scriptRoot 'OpenPath-NativeHost.ps1') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $internalRoot 'NativeHost.Actions.ps1') -Force | Out-Null

            $candidateRoots = @(Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $scriptRoot)
            $resolution = Resolve-OpenPathNativeHostArtifactSources `
                -ArtifactNames @('OpenPath-NativeHost.ps1', 'NativeHost.Actions.ps1', 'missing.ps1') `
                -CandidateRoots $candidateRoots
            $resolution.Sources['OpenPath-NativeHost.ps1'] | Should -Be $scriptRoot
            $resolution.Sources['NativeHost.Actions.ps1'] | Should -Be $internalRoot
            @($resolution.Missing) | Should -Contain 'missing.ps1'

            Assert-ContentContainsAll -Content $content -Needles @(
                '$firefoxNativeHostTarget = "$OpenPathRoot\browser-extension\firefox\native"',
                'NativeHost.ArtifactCatalog.ps1',
                'Get-OpenPathNativeHostArtifactNames',
                'Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $nativeHostSourceRoot',
                'Resolve-OpenPathNativeHostArtifactSources -ArtifactNames $nativeHostArtifacts -CandidateRoots $nativeHostSourceRoots',
                'Firefox native host assets staged in $OpenPathRoot\browser-extension\firefox\native'
            )
        }

        It "Copies command wrappers into the installed scripts directory for later re-registration" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$requiredScriptFiles = @(',
                'Enroll-Machine.ps1',
                'Required installer script missing from bootstrap package',
                'Required installer script was not staged into OpenPath runtime',
                'Get-ChildItem "$ScriptDir\scripts\*.cmd" -ErrorAction SilentlyContinue',
                'Copy-Item -Destination "$OpenPathRoot\scripts\" -Force'
            )
        }

        It "Stages installer helpers so installed reinstall entrypoints remain runnable" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'New-Item -ItemType Directory -Path "$OpenPathRoot\lib\install" -Force',
                'Get-ChildItem "$ScriptDir\lib\install\*.ps1" -ErrorAction Stop',
                'Copy-Item -Destination "$OpenPathRoot\lib\install\" -Force',
                'Installer.Cleanup.ps1'
            )
        }

        It "Registers Firefox native messaging host in both 64-bit and WOW6432Node registry views" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $content = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Mozilla\NativeMessagingHosts\whitelist_native_host',
                'WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host',
                "allowed_extensions = @('openpath-block-monitor@openpath')",
                'name = Get-OpenPathFirefoxNativeHostName'
            )
        }

        It "Uses braced interpolation for SourceRoot error messages before a colon" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $content = Get-Content $nativeHostModulePath -Raw

            $content.Contains('Firefox native host artifacts not found in ${SourceRoot}:') | Should -BeTrue
            $content.Contains('Firefox native host artifacts not found in $SourceRoot:') | Should -BeFalse
        }

        It "Skips registry deletion when Firefox native host keys are already absent in the shared browser helpers" {
            $browserCommonModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.Common.psm1"
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $browserCommonContent = Get-Content $browserCommonModulePath -Raw
            $nativeHostContent = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $browserCommonContent -Needles @(
                'function ConvertTo-OpenPathRegistryProviderPath',
                'return "Registry::HKEY_LOCAL_MACHINE\\$($RegistryPath.Substring(5))"',
                'if ($RegistryPath -match ''^HKLM\\'')',
                'if (Test-Path $providerPath)'
            )
            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                'Remove-OpenPathRegistryKeyIfPresent -RegistryPath $registryPath'
            )
            $browserCommonContent.Contains('& reg.exe DELETE $registryPath /f 2>$null | Out-Null') | Should -BeFalse
        }

        It "Falls back to the staged native host directory during re-registration after self-update" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $content = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $SourceRoot -NativeRoot $nativeRoot',
                'Resolve-OpenPathNativeHostArtifactSources -ArtifactNames $artifactNames -CandidateRoots $candidateRoots',
                '[string]::Equals($sourcePath, $destinationPath, [System.StringComparison]::OrdinalIgnoreCase)'
            )
        }
    }

    Context "Source path validation" {
        It "Validates modules exist before copying" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Modules not found',
                'Test-Path "$scriptDir\lib\*.psm1"'
            )
        }
    }

    Context "Checkpoint defaults" {
        It "Configures checkpoint rollback defaults during install" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            $content = Get-Content $scriptPath -Raw
            $configHelper = Get-Content $configHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'New-OpenPathInstallerConfig',
                'Installer.Config.ps1'
            )
            Assert-ContentContainsAll -Content $configHelper -Needles @(
                'enableCheckpointRollback',
                'maxCheckpoints',
                'enableDohIpBlocking',
                'dohResolverIps',
                'vpnBlockRules',
                'torBlockPorts',
                'Get-DefaultDohResolverIps',
                'Get-DefaultVpnBlockRules',
                'Get-DefaultTorBlockPorts'
            )
        }
    }

    Context "Enrollment extraction" {
        It "Uses Enroll-Machine script for classroom registration" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"
            $enrollScriptPath = Join-Path $PSScriptRoot ".." "scripts" "Enroll-Machine.ps1"
            $content = Get-Content $scriptPath -Raw

            Test-Path $enrollScriptPath | Should -BeTrue
            Assert-ContentContainsAll -Content $content -Needles @(
                'Enroll-Machine.ps1',
                'SkipTokenValidation',
                'Machine registration completed'
            )
        }
    }

    Context "Enrollment argument forwarding" {
        It "Uses named parameter splatting for classroom registration" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$enrollParams = @{',
                '& $enrollScript @enrollParams'
            )
            $content.Contains('$enrollArgs = @(') | Should -BeFalse
            $content.Contains('& $enrollScript @enrollArgs') | Should -BeFalse
        }
    }

    Context "Unattended enrollment support" {
        It "Supports enrollment-token unattended parameters in installer" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[string]$EnrollmentToken = ""',
                '[string]$ClassroomId = ""',
                '[switch]$Unattended',
                '-EnrollmentToken',
                '-ClassroomId',
                '-Unattended'
            )
        }

        It "Supports optional Chromium store URLs for unmanaged browser installs" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            $content = Get-Content $scriptPath -Raw
            $configHelper = Get-Content $configHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[string]$ChromeExtensionStoreUrl = ""',
                '[string]$EdgeExtensionStoreUrl = ""',
                '-ChromeExtensionStoreUrl $ChromeExtensionStoreUrl',
                '-EdgeExtensionStoreUrl $EdgeExtensionStoreUrl'
            )

            Assert-ContentContainsAll -Content $configHelper -Needles @(
                '$config.chromeExtensionStoreUrl = $ChromeExtensionStoreUrl',
                '$config.edgeExtensionStoreUrl = $EdgeExtensionStoreUrl'
            )
        }

        It "Supports managed browser boundary and cleanup installer options" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            $content = Get-Content $scriptPath -Raw
            $configHelper = Get-Content $configHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[switch]$EnforceManagedBrowserBoundary',
                '[string[]]$ApprovedStudentBrowsers = @(''Firefox'')',
                "[ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]",
                '[string]$BrowserCleanupMode = ''ReportOnly''',
                '-EnforceManagedBrowserBoundary:$enforceManagedBrowserBoundary',
                '-ApprovedStudentBrowsers $ApprovedStudentBrowsers',
                '-BrowserCleanupMode $BrowserCleanupMode'
            )

            Assert-ContentContainsAll -Content $configHelper -Needles @(
                '[bool]$EnforceManagedBrowserBoundary = $false',
                '[string[]]$ApprovedStudentBrowsers = @(''Firefox'')',
                "[ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]",
                '[string]$BrowserCleanupMode = ''ReportOnly''',
                'enforceManagedBrowserBoundary = $EnforceManagedBrowserBoundary',
                'approvedStudentBrowsers = @($ApprovedStudentBrowsers)',
                'browserCleanupMode = $BrowserCleanupMode'
            )
        }

        It "Persists managed browser boundary and cleanup mode in installer config" {
            $firewallCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Catalog.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            . $firewallCatalogPath
            . $configHelperPath

            $config = New-OpenPathInstallerConfig `
                -WhitelistUrl '' `
                -AgentVersion 'test-version' `
                -PrimaryDNS '8.8.8.8' `
                -EnforceManagedBrowserBoundary:$true `
                -BrowserCleanupMode RemoveKnownInstallers

            $config.enforceManagedBrowserBoundary | Should -BeTrue
            @($config.approvedStudentBrowsers) | Should -Be @('Firefox')
            $config.browserCleanupMode | Should -Be 'RemoveKnownInstallers'
        }

        It "Defaults browser cleanup to report-only in installer config" {
            $firewallCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Catalog.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            . $firewallCatalogPath
            . $configHelperPath

            $config = New-OpenPathInstallerConfig `
                -WhitelistUrl '' `
                -AgentVersion 'test-version' `
                -PrimaryDNS '8.8.8.8'

            $config.browserCleanupMode | Should -Be 'ReportOnly'
            $config.enforceManagedBrowserBoundary | Should -BeFalse
        }

        It "Defaults classroom unattended installs to managed browser boundary enforcement" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$enforceManagedBrowserBoundary = [bool]$EnforceManagedBrowserBoundary',
                'if ($classroomModeRequested -and $Unattended -and -not $PSBoundParameters.ContainsKey(''EnforceManagedBrowserBoundary''))',
                '$enforceManagedBrowserBoundary = $true'
            )
        }
    }

    Context "Enrollment before first update" {
        It "Allows enrollment-mode config to start without a whitelist URL" {
            $firewallCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Firewall.Catalog.ps1"
            $configHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Config.ps1"
            . $firewallCatalogPath
            . $configHelperPath

            $config = New-OpenPathInstallerConfig `
                -WhitelistUrl '' `
                -AgentVersion 'test-version' `
                -PrimaryDNS '8.8.8.8' `
                -ApiBaseUrl 'https://api.example.test' `
                -ClassroomId 'cls_test'

            $config.whitelistUrl | Should -Be ''
            $config.apiUrl | Should -Be 'https://api.example.test'
            $config.classroomId | Should -Be 'cls_test'
        }

        It "Registers Firefox native host after enrollment produces complete request setup" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$nativeHostConfig = Get-OpenPathConfig',
                '$nativeHostRequestSetup = Get-OpenPathRequestSetupState -Config $nativeHostConfig',
                '$nativeHostRegistered = Register-OpenPathFirefoxNativeHost -Config $nativeHostConfig -ClearWhitelist',
                '$nativeHostRequestSetup.DiagnosticMessage',
                'Could not register Firefox native host after enrollment'
            )

            $content | Should -Match 'try \{\s+Import-Module "\$OpenPathRoot\\lib\\RequestSetup\.State\.psm1" -Force -Global\s+\$nativeHostConfig = Get-OpenPathConfig'
        }

        It "Defers local DNS activation until remote bootstrap can write Acrylic hosts" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$deferLocalDnsUntilRemoteBootstrap = $classroomModeRequested -or [bool]$WhitelistUrl',
                'DNS local se activara tras descargar y aplicar la primera whitelist',
                'Ensure-InstallerRemoteBootstrapDns -ApiBaseUrl $apiBaseUrl -PrimaryDNS $primaryDNS -WhatIf:$WhatIfPreference',
                'DNS remoto verificado para enrollment',
                'Set-LocalDNS',
                'Invoke-OpenPathInstallerFirstUpdate'
            )

            $content | Should -Match '(?s)if \(\$deferLocalDnsUntilRemoteBootstrap\).*?Ensure-InstallerRemoteBootstrapDns.*?else \{\s+Set-LocalDNS'
            $content | Should -Match '(?s)Invoke-OpenPathInstallerFirstUpdate'
            $content | Should -Not -Match '(?s)Set-LocalDNS\s+Write-InstallerVerbose ''  DNS configurado a 127\.0\.0\.1''\s+Show-InstallerProgress -Step 6'
        }

        It "Fails unattended classroom installs when enrollment or native host registration is incomplete" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'if ($classroomModeRequested -and $Unattended -and $machineRegistered -ne ''REGISTERED'')',
                'ERROR: Classroom enrollment did not complete; domain requests will not be configured.',
                'if ($classroomModeRequested -and $Unattended -and -not $pendingEnrollment -and (-not $nativeHostRegistered -or -not $nativeHostRequestSetup -or -not $nativeHostRequestSetup.Ready))',
                'ERROR: Firefox native host registration incomplete; domain requests will not be configured.',
                'exit 1'
            )
        }

        It "Fails ClassroomPath installs when Firefox managed extension policy is not ready" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $browserModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.psm1"
            $content = Get-Content $scriptPath -Raw
            $browserModule = Get-Content $browserModulePath -Raw

            $content | Should -Match 'if \(\$classroomModeRequested\)'
            $content | Should -Match 'Test-OpenPathFirefoxManagedExtensionReady -Config \$firefoxReadyConfig'
            $content | Should -Not -Match 'Test-OpenPathFirefoxManagedExtensionReady -Config \$firefoxReadyConfig -RequireRuntimeRegistration'

            Assert-ContentContainsAll -Content $content -Needles @(
                'Test-OpenPathFirefoxManagedExtensionReady -Config $firefoxReadyConfig',
                'ERROR: Firefox managed extension policy is not ready after installation.',
                '$firefoxReady.FailureCode',
                '$firefoxReady.Message',
                'exit 1'
            )

            $content | Should -Match '(?s)Invoke-OpenPathInstallerFirstUpdate.*Test-OpenPathFirefoxManagedExtensionReady'
            $browserModule | Should -Match 'function Test-OpenPathFirefoxManagedExtensionReady'
        }

        It "Restores installer config after first-update rollback before Firefox readiness" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Restore-OpenPathInstallerConfigIfMissing',
                '-Config $config',
                '$firefoxReadyConfig = Get-OpenPathConfig'
            )

            $content | Should -Match '(?s)Invoke-OpenPathInstallerFirstUpdate.*Restore-OpenPathInstallerConfigIfMissing.*\$firefoxReadyConfig = Get-OpenPathConfig'
        }

        It "Exits successfully after writing the installer summary" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match 'Write-OpenPathInstallerSummary[\s\S]*exit 0'
        }

        It "Skips first update when classroom registration fails" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Invoke-OpenPathInstallerFirstUpdate',
                'Installer.Runtime.ps1'
            )

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                'Registration not completed; skipping first update',
                '$ClassroomModeRequested -and $MachineRegistered -ne ''REGISTERED'''
            )
        }

        It "Runs the first update in a subprocess so retryable update failures do not exit the installer" {
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$OpenPathRoot\scripts\Update-OpenPath.ps1"',
                '$updateExitCode = $LASTEXITCODE',
                'First update failed with code $updateExitCode (will retry)'
            )

            $runtimeHelper | Should -Not -Match '(?m)^\s*& "\$OpenPathRoot\\scripts\\Update-OpenPath\.ps1"\s*$'
        }

        It "Fails closed when browser policy spec is missing from installer runtime" {
            $stagingHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $stagingHelper = Get-Content $stagingHelperPath -Raw

            Assert-ContentContainsAll -Content $stagingHelper -Needles @(
                '$browserPolicySpecInstalled = $false',
                '$browserPolicySpecInstalled = $true',
                'Browser policy spec not found in installer runtime'
            )

            $stagingHelper | Should -Match '(?s)foreach \(\$browserPolicySpecSource in \$browserPolicySpecCandidates\).*?\$browserPolicySpecInstalled = \$true.*?if \(-not \$browserPolicySpecInstalled\).*?throw'
        }

        It "Allows optional summary fields to be empty" {
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                '[string]$Classroom = ''''',
                '[string]$ClassroomId = ''''',
                '[string]$WhitelistUrl = '''''
            )

            $runtimeHelper | Should -Not -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[string\]\$Classroom\s*,'
            $runtimeHelper | Should -Not -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[string\]\$ClassroomId\s*,'
            $runtimeHelper | Should -Not -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[string\]\$WhitelistUrl\s*,'
        }

        It "Warns when classroom installs finish without enrollment" {
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                '$ClassroomModeRequested -and $MachineRegistered -ne ''REGISTERED''',
                'Domain requests: NOT CONFIGURED',
                'run .\OpenPath.ps1 enroll'
            )
        }
    }

    Context "Operational script installation" {
        It "Copies OpenPath.ps1 and Rotate-Token.ps1 into install root" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.Contains("'OpenPath.ps1', 'Rotate-Token.ps1'") | Should -BeTrue
        }

        It "Stages internal PowerShell helpers alongside lib modules" {
            $scriptPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$OpenPathRoot\lib\internal',
                'Get-ChildItem "$ScriptDir\lib\internal\*.ps1"',
                'Destination "$OpenPathRoot\lib\internal\"'
            )
        }

        It "Stages Chromium unmanaged browser install guidance when store URLs are configured" {
            $guidanceHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"
            $content = Get-Content $guidanceHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$OpenPathRoot\browser-extension\chromium-unmanaged',
                '[InternetShortcut]',
                'Install OpenPath for Google Chrome.url',
                'Install OpenPath for Microsoft Edge.url'
            )
        }

        It "Opens unmanaged Chromium store guidance only during interactive installs" {
            $guidanceHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"
            $content = Get-Content $guidanceHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'if (-not $Unattended)',
                'Start-Process -FilePath $browserTarget.ExecutablePath -ArgumentList $browserTarget.StoreUrl',
                'Chromium store guidance staged for unattended install'
            )
        }
    }

    Context "Pre-install validation integration" {
        It "Runs pre-install validation by default and supports SkipPreflight" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'SkipPreflight',
                'scripts\Pre-Install-Validation.ps1',
                'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
            )
            $content.Contains('tests\Pre-Install-Validation.ps1') | Should -BeFalse
        }

        It "Uses SkipPreflight in Windows CI harnesses that install inside constrained runner environments" {
            $windowsE2EPath = Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "run-windows-e2e.ps1"
            $windowsStudentPath = Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "run-windows-student-flow.ps1"
            $windowsE2EContent = Get-Content $windowsE2EPath -Raw
            $windowsStudentContent = Get-Content $windowsStudentPath -Raw

            $windowsE2EContent | Should -Match '(?s)Install-OpenPath\.ps1.*?-SkipPreflight.*?-Unattended'
            $windowsStudentContent | Should -Match '(?s)Install-OpenPath\.ps1.*?-SkipPreflight.*?-Unattended'
        }
    }

    Context "Quiet progress output" {
        It "Uses PowerShell verbose semantics and progress helpers for installer output" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $guidanceHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"
            $progressHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Progress.ps1"
            $guidanceHelper = Get-Content $guidanceHelperPath -Raw
            $progressHelper = Get-Content $progressHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[CmdletBinding(SupportsShouldProcess)]',
                'Invoke-OpenPathPlannedPhase -Name ''directories''',
                'Installer.Progress.ps1',
                "Installer.Plan.ps1",
                "Installer.ChromiumGuidance.ps1"
            )

            Assert-ContentContainsAll -Content $progressHelper -Needles @(
                'function Show-InstallerProgress',
                'Write-Progress -Activity ''Installing OpenPath''',
                'function Write-InstallerVerbose',
                'Write-Verbose $Message'
            )

            Assert-ContentContainsAll -Content $guidanceHelper -Needles @(
                'function Get-OpenPathChromiumBrowserTargets',
                'function Install-OpenPathChromiumUnmanagedGuidance'
            )
        }

        It "Does not emit empty verbose installer messages during classroom enrollment" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content.Contains('Write-InstallerVerbose ""') | Should -BeFalse
        }

        It "Keeps redirected progress silent and centralizes installer output levels" {
            $progressHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Progress.ps1"
            $progressHelper = Get-Content $progressHelperPath -Raw

            Assert-ContentContainsAll -Content $progressHelper -Needles @(
                'function Write-InstallerError',
                'function Write-InstallerWarning',
                'function Write-InstallerNotice',
                "if (`$VerbosePreference -ne 'Continue') { return }",
                'Write-Progress -Activity ''Installing OpenPath'''
            )

            $progressHelper.Contains('Write-Host "Progress ${Step}/${Total}: $Status"') | Should -BeFalse
        }

        It "Suppresses non-error installer output by default" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$script:OpenPathInstallerQuietMode = $VerbosePreference -ne ''Continue''',
                '$WarningPreference = ''SilentlyContinue''',
                '$InformationPreference = ''SilentlyContinue''',
                '$env:OPENPATH_QUIET_INSTALL = ''1'''
            )
            $content | Should -Not -Match '\$ProgressPreference\s*=\s*''SilentlyContinue'''

            $content | Should -Match '(?s)if \(\$VerbosePreference -eq ''Continue''\).*?OpenPath DNS para Windows - Instalador'
            $content | Should -Not -Match 'else \{\s+Write-InstallerNotice ''Installing OpenPath DNS for Windows\.\.\.''\s+\}'
        }

        It "Keeps the PowerShell progress bar available in normal installer runs" {
            $progressHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Progress.ps1"
            $progressHelper = Get-Content $progressHelperPath -Raw
            $showProgressFunction = [regex]::Match(
                $progressHelper,
                '(?s)function Show-InstallerProgress \{.*?\n\}'
            ).Value

            $showProgressFunction | Should -Match "Write-Progress -Activity 'Installing OpenPath'"
            $showProgressFunction | Should -Not -Match "if \(\`$VerbosePreference -ne 'Continue'\)"
            $showProgressFunction | Should -Not -Match "(?s)if \(\`$VerbosePreference -eq 'Continue'\) \{[^}]*return"
        }

        It "Keeps enrollment script host output quiet during normal installer enrollment" {
            $enrollmentHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"
            $enrollScriptPath = Join-Path $PSScriptRoot ".." "scripts" "Enroll-Machine.ps1"
            $enrollmentHelper = Get-Content $enrollmentHelperPath -Raw
            $enrollScript = Get-Content $enrollScriptPath -Raw

            Assert-ContentContainsAll -Content $enrollmentHelper -Needles @(
                'if ($VerbosePreference -ne ''Continue'') {',
                '$enrollParams.Quiet = $true'
            )

            Assert-ContentContainsAll -Content $enrollScript -Needles @(
                '[switch]$Quiet',
                'function Write-EnrollmentNotice',
                'if ($Quiet) { return }'
            )

            $enrollScript | Should -Not -Match '(?m)^\s*Write-Host\s+'
        }

        It "Suppresses non-error module logs during quiet installer runs" {
            $commonSystemPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.System.ps1"
            $commonSystem = Get-Content $commonSystemPath -Raw

            $commonSystem | Should -Match 'if \(\$env:OPENPATH_QUIET_INSTALL -eq ''1'' -and \$Level -ne "ERROR"\)'
            $commonSystem | Should -Match 'return'
        }

        It "Downloads Acrylic without curl progress in quiet installer runs" {
            $acrylicInstallPath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1"
            $acrylicInstall = Get-Content $acrylicInstallPath -Raw

            $acrylicInstall | Should -Match '& \$curl\.Source -fL -sS --retry 3 --retry-delay 2'
        }

        It "Routes non-fatal installer messages through warning or verbose-only helpers" {
            $installHelperPaths = @(
                (Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.ChromiumGuidance.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Enrollment.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"),
                (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1")
            )

            foreach ($helperPath in $installHelperPaths) {
                $content = Get-Content $helperPath -Raw
                $content | Should -Not -Match 'Write-Host\s+[''"][^''"]*WARNING:'
                $content | Should -Not -Match "Write-Warning\s+"
            }
        }

        It "Supports WhatIf and distinguishes browser cleanup from enforcement" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '[CmdletBinding(SupportsShouldProcess)]',
                'Browser cleanup is hygiene. Application allowlist is the enforcement boundary.',
                '$PSCmdlet.ShouldProcess(''OpenPath install root'', ''Create install directories'')',
                '-WhatIf:$WhatIfPreference',
                '$WhatIfPreference'
            )
        }
    }

    Context "Primary DNS detection" {
        It "Uses an installer helper instead of indexing directly into adapter DNS arrays" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $dnsHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Dns.ps1"
            $dnsHelper = Get-Content $dnsHelperPath -Raw

            $content.Contains('Installer.Dns.ps1') | Should -BeTrue
            $content.Contains('$primaryDNS = Get-InstallerPrimaryDNS') | Should -BeTrue
            $content.Contains('Select-Object -First 1).ServerAddresses[0]') | Should -BeFalse
            $dnsHelper.Contains('function Get-InstallerPrimaryDNS') | Should -BeTrue
            $dnsHelper.Contains('function Ensure-InstallerRemoteBootstrapDns') | Should -BeTrue
            $dnsHelper.Contains('Set-DnsClientServerAddress') | Should -BeTrue
            $dnsHelper.Contains('Resolve-DnsName -Name $hostname') | Should -BeTrue
        }

        It "Does not mutate adapter DNS during remote bootstrap WhatIf" {
            $dnsHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Dns.ps1"
            . $dnsHelperPath

            $script:setDnsCalls = 0
            $script:clearCacheCalls = 0

            function Resolve-DnsName {
                [CmdletBinding()]
                param(
                    [string]$Name,
                    [string]$Type,
                    [switch]$QuickTimeout,
                    [string]$Server,
                    [switch]$DnsOnly
                )

                throw "Simulated DNS failure for $Name"
            }

            function Get-NetAdapter {
                [CmdletBinding()]
                param()

                [pscustomobject]@{ Status = 'Up'; ifIndex = 12 }
            }

            function Set-DnsClientServerAddress {
                [CmdletBinding()]
                param(
                    [int]$InterfaceIndex,
                    [string[]]$ServerAddresses
                )

                $script:setDnsCalls += 1
                throw 'WhatIf should not mutate live adapter DNS'
            }

            function Clear-DnsClientCache {
                [CmdletBinding()]
                param()

                $script:clearCacheCalls += 1
            }

            try {
                {
                    Ensure-InstallerRemoteBootstrapDns -ApiBaseUrl 'https://api.example.test' -PrimaryDNS '8.8.8.8' -WhatIf
                } | Should -Not -Throw

                $script:setDnsCalls | Should -Be 0
                $script:clearCacheCalls | Should -Be 0
            }
            finally {
                Remove-Item function:\Resolve-DnsName -ErrorAction SilentlyContinue
                Remove-Item function:\Get-NetAdapter -ErrorAction SilentlyContinue
                Remove-Item function:\Set-DnsClientServerAddress -ErrorAction SilentlyContinue
                Remove-Item function:\Clear-DnsClientCache -ErrorAction SilentlyContinue
                Remove-Variable -Name setDnsCalls -Scope Script -ErrorAction SilentlyContinue
                Remove-Variable -Name clearCacheCalls -Scope Script -ErrorAction SilentlyContinue
            }
        }
    }

    Context "DNS probe guidance" {
        It "Derives the suggested nslookup domain from the shared probe list" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Write-OpenPathInstallerSummary',
                'Installer.Runtime.ps1'
            )
            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                'Get-OpenPathDnsProbeDomains',
                'nslookup $dnsProbeDomain 127.0.0.1'
            )
            $content.Contains('Test-DNSResolution -Domain "google.com"') | Should -BeFalse
            $content.Contains('nslookup google.com 127.0.0.1') | Should -BeFalse
        }

        It "Does not fail the installer summary when the firewall helper is unavailable" {
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"

            function Test-AcrylicInstalled { return $true }
            function Test-DNSResolution { return $true }
            function Get-ScheduledTask { return @() }
            Remove-Item function:\Test-FirewallActive -ErrorAction SilentlyContinue

            . $runtimeHelperPath

            { Get-OpenPathInstallerChecks } | Should -Not -Throw
            $checks = @(Get-OpenPathInstallerChecks)
            ($checks | Where-Object { $_.Name -eq 'Firewall' }).Status | Should -Be 'WARN'
        }

        It "Imports runtime modules globally for dot-sourced installer helpers" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\Firewall.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\AppControl.psm1" -Force -Global',
                "Get-Command -Name 'AppControl\Set-OpenPathNonAdminAppControl' -ErrorAction Stop",
                "Get-Command -Name 'AppControl\Test-OpenPathNonAdminAppControlActive' -ErrorAction Stop",
                "Get-Command -Name 'AppControl\Remove-OpenPathNonAdminAppControl' -ErrorAction Stop",
                "Get-Command -Name 'AppControl\Sync-OpenPathRestrictedGroup' -ErrorAction Stop",
                'Import-Module "$OpenPathRoot\lib\DNS.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -Global',
                'Import-Module "$OpenPathRoot\lib\Services.psm1" -Force -Global'
            )
        }

        It "Keeps deferred enrollment save failures diagnosable without exposing state" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw
            $offlinePath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1"
            $offlineContent = Get-Content $offlinePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                "`$script:OpenPathInstallerCurrentPhase = 'enrollment-attempt'",
                "`$script:OpenPathInstallerCurrentPhase = 'enrollment-save-pending'",
                "`$script:OpenPathInstallerCurrentPhase = 'enrollment-pending-saved'"
            )
            Assert-ContentContainsAll -Content $offlineContent -Needles @(
                "Write-OpenPathOfflineInstallPhase -Path `$FailureStatusPath -Phase 'enrollment-pending-protect'",
                "Write-OpenPathOfflineInstallPhase -Path `$FailureStatusPath -Phase 'enrollment-pending-write'",
                "Write-OpenPathOfflineInstallPhase -Path `$FailureStatusPath -Phase 'enrollment-pending-acl'",
                "Write-OpenPathOfflineInstallPhase -Path `$FailureStatusPath -Phase 'enrollment-pending-complete'"
            )
            $content | Should -Match ([regex]::Escape("if (`$phase -notin @('acrylic-install-local', 'enrollment-save-pending') -or -not `$FailureStatusPath)"))
        }

        It "Classifies pending ACL failures without exposing raw exception data" {
            $offlinePath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1"
            $content = Get-Content $offlinePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Get-OpenPathPendingEnrollmentAclFailurePhase',
                'enrollment-pending-acl-access',
                'enrollment-pending-acl-descriptor',
                'enrollment-pending-acl-command',
                'enrollment-pending-acl-failed',
                'Write-OpenPathOfflineInstallPhase -Path $FailureStatusPath -Phase $aclFailurePhase'
            )
            $content | Should -Not -Match 'Write-OpenPathOfflineInstallPhase\s+-Path\s+\$FailureStatusPath\s+-Phase\s+\$\{?\$_'
        }

        It "Loads the installer cleanup helper before install steps can mutate an existing runtime" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                ". (Join-Path `$installerHelperRoot 'Installer.Cleanup.ps1')",
                'Copy-OpenPathInstallerSourceForReinstall',
                'Invoke-OpenPathInstallerExistingInstallCleanup',
                '-KeepAcrylic',
                '-KeepLogs'
            )

            $snapshotIndex = $content.IndexOf('Copy-OpenPathInstallerSourceForReinstall')
            $cleanupIndex = $content.IndexOf('Invoke-OpenPathInstallerExistingInstallCleanup')
            $directoryIndex = $content.IndexOf('Initialize-OpenPathInstallDirectories')
            $copyIndex = $content.IndexOf('Copy-OpenPathInstallerRuntime')

            $snapshotIndex | Should -BeGreaterThan -1
            $cleanupIndex | Should -BeGreaterThan -1
            $snapshotIndex | Should -BeLessThan $cleanupIndex
            $cleanupIndex | Should -BeLessThan $directoryIndex
            $cleanupIndex | Should -BeLessThan $copyIndex
        }

        It "Skips blank preflight validation lines before reporting installer errors" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match '\$validationOutput\s*\|\s*Where-Object\s*\{\s*-not\s*\[string\]::IsNullOrWhiteSpace\(\$_\)\s*\}\s*\|\s*ForEach-Object\s*\{\s*Write-InstallerError\s+"\$_"\s*\}'
        }

        It "Defines reinstall cleanup as full OpenPath removal while preserving Acrylic and logs" {
            $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
            Test-Path $cleanupHelperPath | Should -BeTrue
            $cleanupHelper = Get-Content $cleanupHelperPath -Raw

            Assert-ContentContainsAll -Content $cleanupHelper -Needles @(
                'function Test-OpenPathExistingInstallation',
                'function Copy-OpenPathInstallerSourceForReinstall',
                'function Invoke-OpenPathInstallerExistingInstallCleanup',
                '[switch]$KeepAcrylic',
                '[switch]$KeepLogs',
                'openpath-reinstall-source-',
                'browser-policy-spec.json',
                'Stop-OpenPathInstallerScheduledTasks',
                'Remove-OpenPathInstallerAppLockerRules',
                'Remove-OpenPathInstallerFirewallRules',
                'Restore-OpenPathInstallerDnsSettings',
                'Remove-OpenPathInstallerBrowserArtifacts',
                'Remove-OpenPathInstallerInstallRoot -KeepLogs:$KeepLogs'
            )
            $cleanupHelper | Should -Not -Match '/UNINSTALL'
            $cleanupHelper | Should -Not -Match 'Remove-Item.*Acrylic DNS Proxy'
        }

        It "Reads installer config values from the hashtable returned by the config helper" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Get-OpenPathInstallerConfigValue',
                '$Config -is [hashtable]',
                '$Config.ContainsKey($PropertyName)',
                '$enableNonAdminAppControl = [bool](Get-OpenPathInstallerConfigValue',
                "-PropertyName 'enableNonAdminAppControl' -DefaultValue `$true",
                "-PropertyName 'nonAdminAppControlMode' -DefaultValue 'Enforced'"
            )
        }

        It "Removes stale OpenPath AppLocker rules when managed browser boundary is disabled" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match '(?s)if \(\$enableNonAdminAppControl\).*?\$script:OpenPathAppControlCommands\.Set.*?else \{.*?\$script:OpenPathAppControlCommands\.Remove.*?-Confirm:\$false.*?Managed browser boundary disabled; AppLocker boundary not applied'
        }

        It "Syncs the restricted group before applying AppControl in the app-control phase" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match '(?s)\$script:OpenPathAppControlCommands\.Sync -CreateIfMissing \$true'
            $syncIndex = $content.IndexOf('$script:OpenPathAppControlCommands.Sync -CreateIfMissing $true')
            $setIndex = $content.IndexOf('$appControlApplied = [bool](& $script:OpenPathAppControlCommands.Set')
            $syncIndex | Should -BeGreaterThan -1
            $setIndex | Should -BeGreaterThan -1
            $syncIndex | Should -BeLessThan $setIndex
        }

        It "Fails the app-control phase when restricted group sync returns false" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match '(?s)\$groupSynced = \[bool\]\(& \$script:OpenPathAppControlCommands\.Sync -CreateIfMissing \$true\)'
            $content | Should -Match '(?s)if \(-not \$groupSynced\) \{.*?throw ''Sync-OpenPathRestrictedGroup failed to create or synchronize the OpenPath-Restricted local group\.'''
        }

        It "Fails the app-control phase when required AppControl cannot be applied and validated" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            $content | Should -Match "\$phaseResult = Invoke-OpenPathPlannedPhase -Name 'app-control'"
            $content | Should -Not -Match "\$phaseResult = Invoke-OpenPathPlannedWarningPhase -Name 'app-control'"
            $content | Should -Match '(?s)\$appControlApplied = \[bool\]\(& \$script:OpenPathAppControlCommands\.Set.*?-ApprovedBrowsers \$approvedStudentBrowsers'
            $content | Should -Match '(?s)if \(-not \$appControlApplied\) \{.*?throw ''Set-OpenPathNonAdminAppControl did not apply the required AppControl boundary\.'''
            $content | Should -Match '(?s)\$script:OpenPathAppControlCommands\.Test\s+`?\s*-Mode \$nonAdminAppControlMode\s+`?\s*-ApprovedBrowsers \$approvedStudentBrowsers'
            $content | Should -Match 'Assert-OpenPathInstallPhaseSucceeded -Result \$phaseResult'
        }
    }

    Context "SSE bootstrap" {
        It "Starts the SSE listener only after enrollment and first update can provide request config" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Install-OpenPath.ps1"
            $runtimeHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Runtime.ps1"
            $content = Get-Content $scriptPath -Raw
            $runtimeHelper = Get-Content $runtimeHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Register-OpenPathTask -UpdateIntervalMinutes 5 -WatchdogIntervalMinutes 1',
                'Invoke-OpenPathInstallerFirstUpdate',
                'Start-OpenPathInstallerRealtimeUpdates'
            )

            Assert-ContentContainsAll -Content $runtimeHelper -Needles @(
                'function Start-OpenPathInstallerRealtimeUpdates',
                'Get-OpenPathBrowserRequestReadiness',
                'Start-OpenPathTask -TaskType SSE'
            )

            $content | Should -Match '(?s)Invoke-OpenPathInstallerEnrollment.*Invoke-OpenPathInstallerFirstUpdate.*Register-OpenPathTask -UpdateIntervalMinutes 5 -WatchdogIntervalMinutes 1.*Start-OpenPathInstallerRealtimeUpdates'
            $content | Should -Not -Match '(?s)Register-OpenPathTask -UpdateIntervalMinutes 5 -WatchdogIntervalMinutes 1.*Start-OpenPathTask -TaskType SSE.*Invoke-OpenPathInstallerEnrollment'
        }
    }

    Context "Update browser policy config handoff" {
        It "Passes the already loaded update config into browser policy application" {
            $applyPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Update.Script.Apply.ps1"
            $browserPath = Join-Path $PSScriptRoot ".." "lib" "Browser.psm1"
            $reconcilerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "EndpointStateReconciler.ps1"
            $applyContent = Get-Content $applyPath -Raw
            $browserContent = Get-Content $browserPath -Raw
            $reconcilerContent = Get-Content $reconcilerPath -Raw

            Assert-ContentContainsAll -Content $applyContent -Needles @(
                'Invoke-OpenPathEndpointStateRepairPlan `',
                '-Config $Config `',
                '-BlockedPaths $Whitelist.BlockedPaths'
            )
            Assert-ContentContainsAll -Content $reconcilerContent -Needles @(
                'Set-AllBrowserPolicy -BlockedPaths $BlockedPaths -Config $Config'
            )
            Assert-ContentContainsAll -Content $browserContent -Needles @(
                'function Set-AllBrowserPolicy',
                'Sync-OpenPathFirefoxManagedExtensionPolicy -Config $Config',
                'Set-ChromePolicy -BlockedPaths $BlockedPaths -Config $Config'
            )
        }
    }
}

Describe "Uninstaller" {
    Context "Running task cleanup" {
        It "Stops scheduled tasks and OpenPath-rooted processes before removing installed files" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Stop-ScheduledTask -TaskName $task.TaskName',
                'Stop-OpenPathRootedProcess',
                '$_.Path.StartsWith($OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)',
                '$_.CommandLine -like "*$OpenPathRoot*"',
                'Remove-OpenPathInstallRoot'
            )
        }
    }

    Context "Firefox native host cleanup" {
        It "Removes Firefox native messaging registry entries and staged host artifacts" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Mozilla\NativeMessagingHosts\whitelist_native_host',
                'WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host',
                'OpenPath-NativeHost.ps1',
                'OpenPath-NativeHost.cmd',
                'NativeHost.State.ps1',
                'NativeHost.Protocol.ps1',
                'NativeHost.Actions.ps1'
            )
        }

        It "Skips registry deletion when Firefox native host keys are already absent" {
            $scriptPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
            $content = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Convert-ToRegistryProviderPath',
                'return "Registry::HKEY_LOCAL_MACHINE\\$($RegistryPath.Substring(5))"',
                'if ($RegistryPath -match ''^HKLM\\'')',
                'if (Test-Path $providerPath)',
                'Remove-Item -Path $providerPath -Recurse -Force -ErrorAction SilentlyContinue'
            )
            $content.Contains('& reg.exe DELETE $registryPath /f 2>$null | Out-Null') | Should -BeFalse
        }
    }
}
