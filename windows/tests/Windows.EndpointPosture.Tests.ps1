#Requires -Modules Pester

# Endpoint posture: reports when a classroom is open (whitelist disabled) while
# protection is still active on the PC, so the contradiction is visible in the
# health report instead of showing up only as failed browsing.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:windowsRoot = Join-Path $PSScriptRoot '..'
    $script:internalPath = Join-Path (Join-Path $script:windowsRoot 'lib') 'internal'
    $script:leafPath = Join-Path $script:internalPath 'EndpointPosture.ps1'

    # Stubs for the commands the leaf reads live state through. They only need
    # to exist so Pester can mock them on hosts that lack the real cmdlets.
    function Test-OpenPathCaptivePortalClassroomDisabled { $false }
    function Test-OpenPathCaptivePortalModeActive { param([switch]$SkipExpiredRestore) $false }
    function Test-FirewallActive { $false }
    function Get-NetAdapter { param($ErrorAction) @() }
    function Get-DnsClientServerAddress { param($AddressFamily, $InterfaceIndex, $ErrorAction) @() }
    function Write-OpenPathLog { param($Message, $Level) }
    function Enter-OpenPathAgentUpdateLock { param([int]$TimeoutMilliseconds = 0) [pscustomobject]@{ Acquired = $true; Mutex = $null } }
    function Exit-OpenPathAgentUpdateLock { param($Lock) }
    function Read-OpenPathDnsFailureModeState { param([string]$OpenPathRoot = '') $null }
    function New-OpenPathEndpointStateRepairPlan { param($PolicyState, $Mode, [bool]$QueueChanged, [bool]$EnableBrowserPolicies) [pscustomobject]@{ Mode = $Mode; Actions = @() } }
    function Invoke-OpenPathEndpointStateRepairPlan { param($Plan, $Config, [string[]]$BlockedPaths) @() }

    # Pure parsers the repair reads the whitelist through, loaded for real so the
    # tests drive it with an actual whitelist file.
    . (Join-Path $script:internalPath 'Common.Whitelist.Sections.ps1')
    . (Join-Path $script:internalPath 'EndpointPolicyState.ps1')

    . $script:leafPath
}

Describe 'Get-OpenPathOpenClassroomPostureFindings' {
    It 'reports nothing when the classroom is enabled' {
        $findings = @(Get-OpenPathOpenClassroomPostureFindings `
                -ClassroomDisabled $false -PortalModeActive $false -FirewallActive $true -DnsPinned $true)

        $findings.Count | Should -Be 0
    }

    It 'reports nothing during captive portal mode' {
        $findings = @(Get-OpenPathOpenClassroomPostureFindings `
                -ClassroomDisabled $true -PortalModeActive $true -FirewallActive $true -DnsPinned $true)

        $findings.Count | Should -Be 0
    }

    It 'reports nothing for an open classroom with no protection left' {
        $findings = @(Get-OpenPathOpenClassroomPostureFindings `
                -ClassroomDisabled $true -PortalModeActive $false -FirewallActive $false -DnsPinned $false)

        $findings.Count | Should -Be 0
    }

    It 'reports the firewall code alone' {
        $findings = @(Get-OpenPathOpenClassroomPostureFindings `
                -ClassroomDisabled $true -PortalModeActive $false -FirewallActive $true -DnsPinned $false)

        $findings | Should -Be @('open_classroom_firewall_active')
    }

    It 'reports the DNS code alone' {
        $findings = @(Get-OpenPathOpenClassroomPostureFindings `
                -ClassroomDisabled $true -PortalModeActive $false -FirewallActive $false -DnsPinned $true)

        $findings | Should -Be @('open_classroom_dns_pinned')
    }

    It 'reports both codes in a stable order' {
        $findings = @(Get-OpenPathOpenClassroomPostureFindings `
                -ClassroomDisabled $true -PortalModeActive $false -FirewallActive $true -DnsPinned $true)

        $findings | Should -Be @('open_classroom_firewall_active', 'open_classroom_dns_pinned')
    }
}

Describe 'Get-OpenPathOpenClassroomPosture' {
    BeforeEach {
        Mock Write-OpenPathLog {}
        Mock Test-OpenPathCaptivePortalClassroomDisabled { $true }
        Mock Test-OpenPathCaptivePortalModeActive { $false }
        Mock Test-FirewallActive { $true }
        Mock Get-NetAdapter { @([pscustomobject]@{ Status = 'Up'; ifIndex = 7 }) }
        Mock Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @('127.0.0.1') } }
    }

    It 'reads live state and reports both findings for an open classroom still protected' {
        $posture = Get-OpenPathOpenClassroomPosture

        $posture.ClassroomDisabled | Should -BeTrue
        $posture.PortalModeActive | Should -BeFalse
        $posture.FirewallActive | Should -BeTrue
        $posture.DnsPinned | Should -BeTrue
        @($posture.Findings) | Should -Be @('open_classroom_firewall_active', 'open_classroom_dns_pinned')
    }

    It 'does not treat an adapter on another resolver as pinned' {
        Mock Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @('10.0.0.1', '127.0.0.1') } }
        Mock Test-FirewallActive { $false }

        $posture = Get-OpenPathOpenClassroomPosture

        $posture.DnsPinned | Should -BeFalse
        @($posture.Findings).Count | Should -Be 0
    }

    It 'ignores adapters that are not up' {
        Mock Get-NetAdapter { @([pscustomobject]@{ Status = 'Disconnected'; ifIndex = 7 }) }
        Mock Test-FirewallActive { $false }

        (Get-OpenPathOpenClassroomPosture).DnsPinned | Should -BeFalse
    }

    It 'reports no findings for an enabled classroom' {
        Mock Test-OpenPathCaptivePortalClassroomDisabled { $false }

        $posture = Get-OpenPathOpenClassroomPosture

        $posture.ClassroomDisabled | Should -BeFalse
        @($posture.Findings).Count | Should -Be 0
    }

    It 'reports no findings while captive portal mode is active' {
        Mock Test-OpenPathCaptivePortalModeActive { $true }

        $posture = Get-OpenPathOpenClassroomPosture

        $posture.PortalModeActive | Should -BeTrue
        @($posture.Findings).Count | Should -Be 0
    }

    It 'does not probe firewall or DNS for an enabled classroom' {
        Mock Test-OpenPathCaptivePortalClassroomDisabled { $false }

        $posture = Get-OpenPathOpenClassroomPosture

        $posture.FirewallActive | Should -BeFalse
        $posture.DnsPinned | Should -BeFalse
        Should -Invoke Test-FirewallActive -Times 0 -Exactly
        Should -Invoke Get-NetAdapter -Times 0 -Exactly
    }

    It 'does not probe firewall or DNS while captive portal mode is active' {
        Mock Test-OpenPathCaptivePortalModeActive { $true }

        $posture = Get-OpenPathOpenClassroomPosture

        $posture.FirewallActive | Should -BeFalse
        $posture.DnsPinned | Should -BeFalse
        Should -Invoke Test-FirewallActive -Times 0 -Exactly
        Should -Invoke Get-NetAdapter -Times 0 -Exactly
    }

    It 'probes firewall and DNS once each for an open classroom outside portal mode' {
        Get-OpenPathOpenClassroomPosture | Out-Null

        Should -Invoke Test-FirewallActive -Times 1 -Exactly
        Should -Invoke Get-NetAdapter -Times 1 -Exactly
    }

    It 'does not run the expired-marker restore while reading portal state' {
        Get-OpenPathOpenClassroomPosture | Out-Null

        Should -Invoke Test-OpenPathCaptivePortalModeActive -Times 1 -Exactly -ParameterFilter { $SkipExpiredRestore }
    }

    It 'never throws and reports an enabled classroom when classroom state cannot be read' {
        Mock Test-OpenPathCaptivePortalClassroomDisabled { throw 'unreadable whitelist' }

        { Get-OpenPathOpenClassroomPosture } | Should -Not -Throw
        $posture = Get-OpenPathOpenClassroomPosture

        $posture.ClassroomDisabled | Should -BeFalse
        @($posture.Findings).Count | Should -Be 0
    }

    It 'counts a failed firewall probe as not active without throwing' {
        Mock Test-FirewallActive { throw 'NetSecurity unavailable' }

        $posture = Get-OpenPathOpenClassroomPosture

        $posture.FirewallActive | Should -BeFalse
        @($posture.Findings) | Should -Be @('open_classroom_dns_pinned')
    }

    It 'counts a failed DNS probe as not pinned without throwing' {
        Mock Get-NetAdapter { throw 'DnsClient unavailable' }

        $posture = Get-OpenPathOpenClassroomPosture

        $posture.DnsPinned | Should -BeFalse
        @($posture.Findings) | Should -Be @('open_classroom_firewall_active')
    }

    It 'counts a failed portal probe as portal mode not active without throwing' {
        Mock Test-OpenPathCaptivePortalModeActive { throw 'marker unreadable' }

        { Get-OpenPathOpenClassroomPosture } | Should -Not -Throw
        (Get-OpenPathOpenClassroomPosture).PortalModeActive | Should -BeFalse
    }
}

Describe 'Test-OpenPathAdapterDnsPinnedToLocalResolver' {
    BeforeEach {
        Mock Get-NetAdapter { @([pscustomobject]@{ Status = 'Up'; ifIndex = 7 }) }
    }

    It 'is true when an up adapter resolves through the local proxy first' {
        Mock Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @('127.0.0.1') } }

        Test-OpenPathAdapterDnsPinnedToLocalResolver | Should -BeTrue
    }

    It 'is false when the local proxy is not the first server' {
        Mock Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @('8.8.8.8', '127.0.0.1') } }

        Test-OpenPathAdapterDnsPinnedToLocalResolver | Should -BeFalse
    }
}

Describe 'Merge-OpenPathReasonCodes' {
    It 'adds findings to existing reason codes and deduplicates' {
        $merged = @(Merge-OpenPathReasonCodes `
                -ReasonCodes @('fail_open_activated', 'open_classroom_dns_pinned') `
                -AdditionalReasonCodes @('open_classroom_firewall_active', 'open_classroom_dns_pinned'))

        $merged | Should -Be @('fail_open_activated', 'open_classroom_dns_pinned', 'open_classroom_firewall_active')
    }

    It 'returns the existing codes unchanged when there is nothing to add' {
        $merged = @(Merge-OpenPathReasonCodes -ReasonCodes @('a_code') -AdditionalReasonCodes @())

        $merged | Should -Be @('a_code')
    }

    It 'accepts empty inputs' {
        @(Merge-OpenPathReasonCodes -ReasonCodes @() -AdditionalReasonCodes @()).Count | Should -Be 0
    }
}

Describe 'Get-OpenPathOutcomeReasonCodesWithPosture' {
    BeforeEach {
        Mock Write-OpenPathLog {}
        Mock Test-OpenPathCaptivePortalClassroomDisabled { $true }
        Mock Test-OpenPathCaptivePortalModeActive { $false }
        Mock Test-FirewallActive { $true }
        Mock Get-NetAdapter { @([pscustomobject]@{ Status = 'Up'; ifIndex = 7 }) }
        Mock Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @('127.0.0.1') } }
        $script:outcome = [pscustomobject]@{
            Status      = 'FAIL_OPEN'
            Actions     = 'fail_open_activated'
            ReasonCodes = @('fail_open_activated', 'open_classroom_dns_pinned')
        }
    }

    It 'merges findings into the existing codes without duplicates' {
        $codes = @(Get-OpenPathOutcomeReasonCodesWithPosture -Outcome $script:outcome)

        $codes | Should -Be @('fail_open_activated', 'open_classroom_dns_pinned', 'open_classroom_firewall_active')
    }

    It 'leaves the outcome Status, Actions and ReasonCodes untouched' {
        Get-OpenPathOutcomeReasonCodesWithPosture -Outcome $script:outcome | Out-Null

        $script:outcome.Status | Should -Be 'FAIL_OPEN'
        $script:outcome.Actions | Should -Be 'fail_open_activated'
        @($script:outcome.ReasonCodes) | Should -Be @('fail_open_activated', 'open_classroom_dns_pinned')
    }

    It 'returns the existing codes when there are no findings' {
        Mock Test-OpenPathCaptivePortalClassroomDisabled { $false }

        @(Get-OpenPathOutcomeReasonCodesWithPosture -Outcome $script:outcome) |
            Should -Be @('fail_open_activated', 'open_classroom_dns_pinned')
    }

    It 'keeps the existing codes and logs when the posture itself fails' {
        Mock Get-OpenPathOpenClassroomPosture { throw 'posture exploded' }

        $codes = @(Get-OpenPathOutcomeReasonCodesWithPosture -Outcome $script:outcome)

        $codes | Should -Be @('fail_open_activated', 'open_classroom_dns_pinned')
        Should -Invoke Write-OpenPathLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'handles an outcome with no reason codes' {
        $bare = [pscustomobject]@{ Status = 'HEALTHY'; Actions = 'watchdog_ok'; ReasonCodes = @() }

        @(Get-OpenPathOutcomeReasonCodesWithPosture -Outcome $bare) |
            Should -Be @('open_classroom_firewall_active', 'open_classroom_dns_pinned')
    }
}

Describe 'Invoke-OpenPathOpenClassroomPostureRepair' {
    BeforeAll {
        function Invoke-TestPostureCycle {
            param([datetime]$NowUtc = $script:now)
            Invoke-OpenPathOpenClassroomPostureRepair -Config $script:config -OpenPathRoot $script:root -NowUtc $NowUtc -UpdateMutexName $script:updateMutexName
        }

        # Holds a named mutex on another thread (a mutex is re-entrant on its owner,
        # so holding it here would not exclude the code under test).
        function Start-TestMutexHolder {
            param([string]$Name)
            $release = [System.Threading.ManualResetEventSlim]::new($false)
            $acquired = [System.Threading.ManualResetEventSlim]::new($false)
            $ps = [powershell]::Create()
            [void]$ps.AddScript({
                    param($MutexName, $Release, $Acquired)
                    $m = [System.Threading.Mutex]::new($false, $MutexName)
                    [void]$m.WaitOne()
                    $Acquired.Set()
                    $Release.Wait()
                    $m.ReleaseMutex()
                    $m.Dispose()
                }).AddArgument($Name).AddArgument($release).AddArgument($acquired)
            $handle = $ps.BeginInvoke()
            [void]$acquired.Wait(10000)
            [pscustomobject]@{ Release = $release; Ps = $ps; Handle = $handle }
        }

        function Stop-TestMutexHolder {
            param($Holder)
            $Holder.Release.Set()
            [void]$Holder.Ps.EndInvoke($Holder.Handle)
            $Holder.Ps.Dispose()
        }
    }

    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:dataDir = Join-Path $script:root 'data'
        New-Item -ItemType Directory -Path $script:dataDir -Force | Out-Null
        $script:whitelistPath = Join-Path $script:dataDir 'whitelist.txt'
        $script:updateMutexName = 'OpenPathTest.UpdateLock.' + [guid]::NewGuid().ToString('N')
        $script:streakPath = Join-Path $script:dataDir 'open-classroom-posture-streak.txt'
        $script:attemptPath = Join-Path $script:dataDir 'open-classroom-posture-repair-attempt.txt'
        $script:now = [datetime]::new(2026, 11, 18, 10, 0, 0, [System.DateTimeKind]::Utc)
        $script:config = [pscustomobject]@{ whitelistUrl = 'https://example.invalid/w' }

        # State the mocks share: the live protection the repair is meant to remove.
        $script:protectionLive = $true
        $script:repairCalls = 0
        $script:repairPlanModes = @()
        $script:lockExits = 0
        $script:postureReads = 0
        $script:classroomDisabled = $true
        $script:portalActive = $false

        Set-Content -LiteralPath $script:whitelistPath -Value "## WHITELIST`nexample.org`n#DESACTIVADO"

        Mock Write-OpenPathLog {}
        Mock Read-OpenPathDnsFailureModeState { $null }
        Mock Get-OpenPathOpenClassroomPosture {
            $script:postureReads++
            $findings = if ($script:classroomDisabled -and -not $script:portalActive -and $script:protectionLive) {
                @('open_classroom_firewall_active')
            }
            else { @() }
            [pscustomobject]@{
                ClassroomDisabled = $script:classroomDisabled
                PortalModeActive  = $script:portalActive
                FirewallActive    = $script:protectionLive
                DnsPinned         = $false
                Findings          = $findings
            }
        }
        Mock Enter-OpenPathAgentUpdateLock { [pscustomobject]@{ Acquired = $true; Mutex = $null } }
        Mock Exit-OpenPathAgentUpdateLock { $script:lockExits++ }
        Mock New-OpenPathEndpointStateRepairPlan {
            $script:repairPlanModes += [string]$Mode
            [pscustomobject]@{ Mode = $Mode; Actions = @('RemoveFirewall') }
        }
        Mock Invoke-OpenPathEndpointStateRepairPlan {
            $script:repairCalls++
            $script:protectionLive = $false
            @('RemoveFirewall')
        }
    }

    It 'only records the streak on the first cycle with findings' {
        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $result.Reason | Should -Be 'streak_recorded'
        $script:repairCalls | Should -Be 0
        Test-Path -LiteralPath $script:streakPath | Should -BeTrue
        Should -Invoke Enter-OpenPathAgentUpdateLock -Times 0 -Exactly
    }

    It 'repairs once on the second consecutive cycle with findings, as a fail-open plan under the update lock' {
        Invoke-TestPostureCycle | Out-Null
        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeTrue
        $result.Skipped | Should -BeFalse
        $result.Reason | Should -Be 'open_classroom_reopened'
        $script:repairCalls | Should -Be 1
        $script:repairPlanModes | Should -Be @('FailOpen')
        Should -Invoke Enter-OpenPathAgentUpdateLock -Times 1 -Exactly -ParameterFilter { $TimeoutMilliseconds -eq 0 }
        $script:lockExits | Should -Be 1
        Test-Path -LiteralPath $script:streakPath | Should -BeFalse
    }

    It 'does not repair again on the cycle after a successful repair' {
        Invoke-TestPostureCycle | Out-Null
        Invoke-TestPostureCycle | Out-Null
        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $script:repairCalls | Should -Be 1
    }

    It 'resets the streak on a clean cycle so a later finding starts counting again' {
        Invoke-TestPostureCycle | Out-Null
        $script:protectionLive = $false
        $clean = Invoke-TestPostureCycle
        $script:protectionLive = $true
        $again = Invoke-TestPostureCycle

        $clean.Skipped | Should -BeTrue
        $clean.Reason | Should -Be 'no_findings'
        $again.Reason | Should -Be 'streak_recorded'
        $script:repairCalls | Should -Be 0
    }

    It 'skips without resetting the streak when the update lock is busy' {
        Invoke-TestPostureCycle | Out-Null
        Mock Enter-OpenPathAgentUpdateLock { [pscustomobject]@{ Acquired = $false; Mutex = $null } }

        $busy = Invoke-TestPostureCycle

        $busy.Repaired | Should -BeFalse
        $busy.Skipped | Should -BeTrue
        $busy.Reason | Should -Be 'update_lock_busy'
        $script:repairCalls | Should -Be 0
        Test-Path -LiteralPath $script:streakPath | Should -BeTrue

        # Once the lock frees, the very next cycle repairs: the streak was preserved.
        Mock Enter-OpenPathAgentUpdateLock { [pscustomobject]@{ Acquired = $true; Mutex = $null } }
        (Invoke-TestPostureCycle).Repaired | Should -BeTrue
    }

    It 'does not repair a whitelist that was re-enabled after the first check' {
        Invoke-TestPostureCycle | Out-Null
        # The second cycle's findings were read while the classroom was still open;
        # the update that holds the lock re-enables it before the repair re-reads it.
        Mock Enter-OpenPathAgentUpdateLock {
            Set-Content -LiteralPath $script:whitelistPath -Value "## WHITELIST`nexample.org"
            [pscustomobject]@{ Acquired = $true; Mutex = $null }
        }

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $result.Reason | Should -Be 'classroom_no_longer_open'
        $script:repairCalls | Should -Be 0
        $script:lockExits | Should -Be 1
        Test-Path -LiteralPath $script:streakPath | Should -BeFalse
    }

    It 'does not repair when the posture is clean once the lock is held' {
        Invoke-TestPostureCycle | Out-Null
        Mock Enter-OpenPathAgentUpdateLock {
            $script:protectionLive = $false
            [pscustomobject]@{ Acquired = $true; Mutex = $null }
        }

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Reason | Should -Be 'no_findings'
        $script:repairCalls | Should -Be 0
        $script:lockExits | Should -Be 1
    }

    It 'never repairs an enabled classroom, whatever protection is live' {
        Set-Content -LiteralPath $script:whitelistPath -Value "## WHITELIST`nexample.org"
        $script:classroomDisabled = $false
        Set-Content -LiteralPath $script:streakPath -Value ([string]$script:now.Ticks)

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $script:repairCalls | Should -Be 0
        Should -Invoke Enter-OpenPathAgentUpdateLock -Times 0 -Exactly
        Test-Path -LiteralPath $script:streakPath | Should -BeFalse
    }

    It 'never repairs while captive portal mode is active' {
        $script:portalActive = $true
        Set-Content -LiteralPath $script:streakPath -Value ([string]$script:now.Ticks)

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $script:repairCalls | Should -Be 0
        Should -Invoke Enter-OpenPathAgentUpdateLock -Times 0 -Exactly
    }

    It 'never repairs while a DNS failure mode is active' {
        Mock Read-OpenPathDnsFailureModeState { [pscustomobject]@{ mode = 'open' } }
        Set-Content -LiteralPath $script:streakPath -Value ([string]$script:now.Ticks)

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $result.Reason | Should -Be 'dns_failure_mode_active'
        $script:repairCalls | Should -Be 0
    }

    It 'does nothing when the whitelist state cannot be read' {
        Set-Content -LiteralPath $script:streakPath -Value ([string]$script:now.Ticks)
        Remove-Item -LiteralPath $script:whitelistPath

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $result.Reason | Should -Be 'whitelist_unreadable'
        $script:repairCalls | Should -Be 0
        $script:postureReads | Should -Be 0
        (Get-Content -LiteralPath $script:streakPath -Raw).Trim() | Should -Be ([string]$script:now.Ticks)

        Set-Content -LiteralPath $script:whitelistPath -Value '#DESACTIVADO'
        Mock Get-OpenPathWhitelistSectionsFromFile { throw 'file is locked' }
        (Invoke-TestPostureCycle).Reason | Should -Be 'whitelist_unreadable'
        $script:repairCalls | Should -Be 0
    }

    It 'logs a failed repair and retries it only after the backoff' {
        Mock Invoke-OpenPathEndpointStateRepairPlan { $script:repairCalls++; throw 'adapter busy' }
        Invoke-TestPostureCycle | Out-Null

        $failed = Invoke-TestPostureCycle
        $failed.Repaired | Should -BeFalse
        $failed.Skipped | Should -BeFalse
        $failed.Reason | Should -Be 'repair_failed'
        $script:repairCalls | Should -Be 1
        Should -Invoke Write-OpenPathLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'adapter busy' }
        $script:lockExits | Should -Be 1

        # the watchdog runs every minute; each backoff cycle keeps the streak fresh
        foreach ($minute in 1..29) {
            $waiting = Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes($minute)
            $waiting.Skipped | Should -BeTrue
            $waiting.Reason | Should -Be 'repair_backoff'
        }
        $script:repairCalls | Should -Be 1

        $retry = Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(31)
        $retry.Reason | Should -Be 'repair_failed'
        $script:repairCalls | Should -Be 2
    }

    It 'treats protection that survives the repair as a failed repair and backs off' {
        # A third-party local resolver on 127.0.0.1 keeps the adapter DNS pinned.
        Mock Invoke-OpenPathEndpointStateRepairPlan { $script:repairCalls++; @('RestoreOriginalDns') }
        Invoke-TestPostureCycle | Out-Null

        $failed = Invoke-TestPostureCycle
        $failed.Repaired | Should -BeFalse
        $failed.Reason | Should -Be 'repair_failed'

        (Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(1)).Reason | Should -Be 'repair_backoff'
        $script:repairCalls | Should -Be 1
    }

    It 'clears the backoff on a clean cycle' {
        Mock Invoke-OpenPathEndpointStateRepairPlan { $script:repairCalls++; throw 'adapter busy' }
        Invoke-TestPostureCycle | Out-Null
        Invoke-TestPostureCycle | Out-Null
        Test-Path -LiteralPath $script:attemptPath | Should -BeTrue

        $script:protectionLive = $false
        Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(1) | Out-Null
        Test-Path -LiteralPath $script:attemptPath | Should -BeFalse

        $script:protectionLive = $true
        Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(2) | Out-Null
        (Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(3)).Reason | Should -Be 'repair_failed'
        $script:repairCalls | Should -Be 2
    }

    It 'tolerates a corrupt streak file and a corrupt or future-dated attempt file' {
        Set-Content -LiteralPath $script:streakPath -Value 'garbage'
        (Invoke-TestPostureCycle).Reason | Should -Be 'streak_recorded'

        Set-Content -LiteralPath $script:attemptPath -Value 'not-a-number'
        (Invoke-TestPostureCycle).Repaired | Should -BeTrue

        $script:protectionLive = $true
        Set-Content -LiteralPath $script:streakPath -Value ([string]$script:now.Ticks)
        $future = $script:now.AddDays(3650).Ticks
        Set-Content -LiteralPath $script:attemptPath -Value ([string]$future)
        (Invoke-TestPostureCycle).Repaired | Should -BeTrue
    }

    It 'does not run while the whitelist update cycle holds its mutex, and keeps the streak' {
        Invoke-TestPostureCycle | Out-Null
        $holder = Start-TestMutexHolder -Name $script:updateMutexName
        try {
            $busy = Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(1)

            $busy.Repaired | Should -BeFalse
            $busy.Skipped | Should -BeTrue
            $busy.Reason | Should -Be 'update_lock_busy'
            $script:repairCalls | Should -Be 0
            Should -Invoke Enter-OpenPathAgentUpdateLock -Times 0 -Exactly
            Test-Path -LiteralPath $script:streakPath | Should -BeTrue
        }
        finally {
            Stop-TestMutexHolder -Holder $holder
        }

        (Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(2)).Repaired | Should -BeTrue
    }

    It 'holds the update mutex through the repair and releases both locks afterwards' {
        $script:mutexHeldDuringRepair = $null
        Mock Invoke-OpenPathEndpointStateRepairPlan {
            # another thread must find the whitelist update mutex taken while repairing
            $probe = [powershell]::Create()
            [void]$probe.AddScript({
                    param($MutexName)
                    $m = [System.Threading.Mutex]::new($false, $MutexName)
                    $got = $m.WaitOne(0)
                    if ($got) { $m.ReleaseMutex() }
                    $m.Dispose()
                    -not $got
                }).AddArgument($script:updateMutexName)
            $script:mutexHeldDuringRepair = [bool]@($probe.Invoke())[0]
            $probe.Dispose()
            $script:repairCalls++
            $script:protectionLive = $false
            @('RemoveFirewall')
        }
        Invoke-TestPostureCycle | Out-Null
        (Invoke-TestPostureCycle).Repaired | Should -BeTrue

        $script:mutexHeldDuringRepair | Should -BeTrue
        $script:lockExits | Should -Be 1
        # released afterwards: a holder on another thread can take it at once
        $holder = Start-TestMutexHolder -Name $script:updateMutexName
        Stop-TestMutexHolder -Holder $holder
    }

    It 'does not count an old streak as consecutive' {
        Invoke-TestPostureCycle | Out-Null

        $late = Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(10)

        $late.Reason | Should -Be 'streak_recorded'
        $script:repairCalls | Should -Be 0
        (Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(11)).Repaired | Should -BeTrue
    }

    It 'treats a future-dated streak as not consecutive' {
        Set-Content -LiteralPath $script:streakPath -Value ([string]$script:now.AddDays(30).Ticks)

        (Invoke-TestPostureCycle).Reason | Should -Be 'streak_recorded'
        $script:repairCalls | Should -Be 0
    }

    It 'refreshes the streak while the update lock is busy so the next free cycle still repairs' {
        Invoke-TestPostureCycle | Out-Null
        Mock Enter-OpenPathAgentUpdateLock { [pscustomobject]@{ Acquired = $false; Mutex = $null } }
        Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(4) | Out-Null
        Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(8) | Out-Null
        Mock Enter-OpenPathAgentUpdateLock { [pscustomobject]@{ Acquired = $true; Mutex = $null } }

        (Invoke-TestPostureCycle -NowUtc $script:now.AddMinutes(12)).Repaired | Should -BeTrue
    }

    It 'never repairs while the stale-whitelist fail-safe is active' {
        Set-Content -LiteralPath (Join-Path $script:dataDir 'stale-failsafe-state.json') -Value '{}'
        Set-Content -LiteralPath $script:streakPath -Value ([string]$script:now.Ticks)

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $result.Reason | Should -Be 'stale_failsafe_active'
        $script:repairCalls | Should -Be 0
        Test-Path -LiteralPath $script:streakPath | Should -BeFalse
    }

    It 'does not report success when the classroom stopped being open during the repair' {
        Mock Invoke-OpenPathEndpointStateRepairPlan {
            $script:repairCalls++
            $script:protectionLive = $false
            $script:classroomDisabled = $false
            @('RemoveFirewall')
        }
        Invoke-TestPostureCycle | Out-Null

        $result = Invoke-TestPostureCycle

        $result.Repaired | Should -BeFalse
        $result.Skipped | Should -BeFalse
        $result.Reason | Should -Be 'classroom_changed_during_repair'
    }

    It 'does not report success when portal mode started during the repair' {
        Mock Invoke-OpenPathEndpointStateRepairPlan {
            $script:repairCalls++
            $script:protectionLive = $false
            $script:portalActive = $true
            @('RemoveFirewall')
        }
        Invoke-TestPostureCycle | Out-Null

        (Invoke-TestPostureCycle).Repaired | Should -BeFalse
    }

    It 'clears the streak and backoff state on request' {
        Set-Content -LiteralPath $script:streakPath -Value '1'
        Set-Content -LiteralPath $script:attemptPath -Value '1'

        Clear-OpenPathOpenClassroomPostureState -OpenPathRoot $script:root

        Test-Path -LiteralPath $script:streakPath | Should -BeFalse
        Test-Path -LiteralPath $script:attemptPath | Should -BeFalse
    }

    It 'writes its state atomically and leaves no temporary files behind' {
        Invoke-TestPostureCycle | Out-Null
        Invoke-TestPostureCycle | Out-Null
        # overwriting an existing state file goes through the atomic replace
        Write-OpenPathPostureStateNumber -Path $script:attemptPath -Value 7 | Should -BeTrue
        Write-OpenPathPostureStateNumber -Path $script:attemptPath -Value 8 | Should -BeTrue
        Read-OpenPathPostureStateNumber -Path $script:attemptPath | Should -Be 8

        @(Get-ChildItem -LiteralPath $script:dataDir -Filter '*.tmp.*').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:dataDir -Filter '*.bak.*').Count | Should -Be 0
    }
}

Describe 'Endpoint posture wiring' {
    It 'feeds the outcome reason codes through the posture merge and sends them in the report' {
        $content = Get-Content (Join-Path (Join-Path $script:windowsRoot 'scripts') 'Test-DNSHealth.ps1') -Raw

        $mergeIndex = $content.IndexOf('$outcome.ReasonCodes = @(Get-OpenPathOutcomeReasonCodesWithPosture -Outcome $outcome)')
        $sendIndex = $content.IndexOf('Send-OpenPathHealthReport -Status $outcome.Status')

        $mergeIndex | Should -BeGreaterThan -1
        $sendIndex | Should -BeGreaterThan $mergeIndex
        $content | Should -Match '(?s)Send-OpenPathHealthReport -Status \$outcome\.Status.*?-ReasonCodes @\(\$outcome\.ReasonCodes\)'
    }

    It 'is loaded beside its siblings by the watchdog runtime and not separately by the watchdog script' {
        $runtime = Get-Content (Join-Path $script:internalPath 'Watchdog.Runtime.ps1') -Raw
        $script = Get-Content (Join-Path (Join-Path $script:windowsRoot 'scripts') 'Test-DNSHealth.ps1') -Raw

        $runtime.Contains(". (Join-Path `$PSScriptRoot 'EndpointPosture.ps1')") | Should -BeTrue
        $script.Contains('EndpointPosture.ps1') | Should -BeFalse
    }

    It 'calls the repair from the watchdog fail-open branch and reports the reopen through the cycle reason codes' {
        $runtime = Get-Content (Join-Path $script:internalPath 'Watchdog.Runtime.ps1') -Raw

        $runtime | Should -Match '(?s)if \(\$policyState\.FailOpenActive\) \{.*?skipping protected-mode DNS/firewall recovery.*?-not \$PortalModeActive.*?-not \$failureModeActive.*?-not \$policyState\.StaleFailsafeActive.*?Invoke-OpenPathOpenClassroomPostureRepair -Config \$Config -OpenPathRoot \$OpenPathRoot.*?& \$addReasonCode ''open_classroom_reopened'''
    }

    It 'is required by the post-update health gate' {
        $gate = Get-Content (Join-Path (Join-Path $script:windowsRoot 'scripts') 'Test-OpenPathAgentUpdateHealth.ps1') -Raw

        Assert-ContentContainsAll -Content $gate -Needles @(
            "'Get-OpenPathOpenClassroomPosture'",
            "'Merge-OpenPathReasonCodes'",
            "'Invoke-OpenPathOpenClassroomPostureRepair'",
            "'Clear-OpenPathOpenClassroomPostureState'",
            "'Test-OpenPathAdapterDnsPinnedToLocalResolver'"
        )
    }

    It 'is imported by the update runtime, which used to own the moved function' {
        $runtime = Get-Content (Join-Path (Join-Path $script:windowsRoot 'lib') 'Update.Runtime.psm1') -Raw

        Assert-ContentContainsAll -Content $runtime -Needles @(
            "lib\internal\EndpointPosture.ps1",
            "'Test-OpenPathAdapterDnsPinnedToLocalResolver'"
        )
    }

    It 'is protected by the integrity baseline' {
        $content = Get-Content (Join-Path $script:internalPath 'Common.Integrity.ps1') -Raw

        $content.Contains('$script:OpenPathRoot\lib\internal\EndpointPosture.ps1') | Should -BeTrue
    }

    It 'defines each posture function exactly once across the agent so the hotfix tool sees no shadow' {
        $names = @(
            'Test-OpenPathAdapterDnsPinnedToLocalResolver',
            'Get-OpenPathOpenClassroomPostureFindings',
            'Get-OpenPathOpenClassroomPosture',
            'Merge-OpenPathReasonCodes',
            'Get-OpenPathOutcomeReasonCodesWithPosture',
            'Invoke-OpenPathOpenClassroomPostureRepair',
            'Clear-OpenPathOpenClassroomPostureState'
        )
        $files = @(Get-ChildItem -Path $script:windowsRoot -Recurse -File -Include '*.ps1', '*.psm1' |
                Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' })

        foreach ($name in $names) {
            $definitions = @($files | Select-String -Pattern ('^\s*function\s+' + [regex]::Escape($name) + '\b'))
            $definitions.Count | Should -Be 1 -Because "$name must have a single definition"
            ([System.IO.Path]::GetFileName($definitions[0].Path)) | Should -Be 'EndpointPosture.ps1'
        }
    }
}
