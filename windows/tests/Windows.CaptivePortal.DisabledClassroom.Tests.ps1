#Requires -Modules Pester

Describe 'Captive portal recovery while the classroom is disabled' {
    BeforeAll {
        $script:libPath = Join-Path (Join-Path $PSScriptRoot '..') 'lib'
        Import-Module (Join-Path $script:libPath 'CaptivePortal.psm1') -Force
    }

    AfterAll {
        Remove-Module CaptivePortal -Force -ErrorAction SilentlyContinue
    }

    Context 'Disable-OpenPathCaptivePortalMode' {
        BeforeEach {
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path (Join-Path $script:root 'data') -Force | Out-Null
            $script:whitelistPath = Join-Path $script:root 'data/whitelist.txt'
            $script:markerPath = Join-Path $script:root 'data/captive-portal-active.json'

            InModuleScope CaptivePortal -Parameters @{ Root = $script:root; Marker = $script:markerPath } {
                param($Root, $Marker)
                $script:savedRoot = $script:OpenPathRoot
                $script:savedMarker = $script:CaptivePortalStatePath
                $script:OpenPathRoot = $Root
                $script:CaptivePortalStatePath = $Marker
            }

            Mock -ModuleName CaptivePortal Write-OpenPathLog {}
            Mock -ModuleName CaptivePortal Restore-OpenPathCaptivePortalAcrylicHostState { $true }
            Mock -ModuleName CaptivePortal Restore-OpenPathProtectedMode { $true }
            Mock -ModuleName CaptivePortal Get-OpenPathCaptivePortalProtectedModeExitEvidence {
                [pscustomobject]@{ localPostureRestored = $true; markerCleared = $true; upstreamHealthy = $true }
            }
        }

        AfterEach {
            InModuleScope CaptivePortal {
                $script:OpenPathRoot = $script:savedRoot
                $script:CaptivePortalStatePath = $script:savedMarker
            }
        }

        It 'does not re-arm protection when no portal marker exists' {
            Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'

            Disable-OpenPathCaptivePortalMode -Config ([pscustomobject]@{}) | Should -BeTrue

            Should -Invoke -ModuleName CaptivePortal Restore-OpenPathProtectedMode -Times 0 -Exactly
        }

        It 'clears an active marker without re-arming protection' {
            Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
            Set-Content -Path $script:markerPath -Value '{}'

            Disable-OpenPathCaptivePortalMode -Config ([pscustomobject]@{}) | Should -BeTrue

            Test-Path $script:markerPath | Should -BeFalse
            Should -Invoke -ModuleName CaptivePortal Restore-OpenPathProtectedMode -Times 0 -Exactly
        }

        It 'still restores protection for an enforcing classroom' {
            Set-Content -Path $script:whitelistPath -Value 'example.org'

            Disable-OpenPathCaptivePortalMode -Config ([pscustomobject]@{}) | Should -BeTrue

            Should -Invoke -ModuleName CaptivePortal Restore-OpenPathProtectedMode -Times 1 -Exactly
        }

        It 'still restores protection when the whitelist is missing' {
            Disable-OpenPathCaptivePortalMode -Config ([pscustomobject]@{}) | Should -BeTrue

            Should -Invoke -ModuleName CaptivePortal Restore-OpenPathProtectedMode -Times 1 -Exactly
        }
    }

    Context 'Test-OpenPathCaptivePortalModeActive' {
        BeforeEach {
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path (Join-Path $script:root 'data') -Force | Out-Null
            $script:whitelistPath = Join-Path $script:root 'data/whitelist.txt'
            $script:markerPath = Join-Path $script:root 'data/captive-portal-active.json'

            InModuleScope CaptivePortal -Parameters @{ Root = $script:root; Marker = $script:markerPath } {
                param($Root, $Marker)
                $script:savedRoot = $script:OpenPathRoot
                $script:savedMarker = $script:CaptivePortalStatePath
                $script:OpenPathRoot = $Root
                $script:CaptivePortalStatePath = $Marker
            }

            $script:expiredMarker = @{
                mode = 'limited'
                since = [DateTime]::UtcNow.AddMinutes(-10).ToString('o')
                expiresAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
                allowedHosts = @()
            } | ConvertTo-Json
            Set-Content -LiteralPath $script:markerPath -Value $script:expiredMarker

            Mock -ModuleName CaptivePortal Write-OpenPathLog { }
            Mock -ModuleName CaptivePortal Disable-OpenPathCaptivePortalMode { $false }
            function global:Set-LocalDNS { $global:OpenPathSetLocalDnsCalls++ }
            $global:OpenPathSetLocalDnsCalls = 0
        }

        AfterEach {
            InModuleScope CaptivePortal {
                $script:OpenPathRoot = $script:savedRoot
                $script:CaptivePortalStatePath = $script:savedMarker
            }
            Remove-Item Function:\Set-LocalDNS -ErrorAction SilentlyContinue
            Remove-Variable -Name OpenPathSetLocalDnsCalls -Scope Global -ErrorAction SilentlyContinue
        }

        It 'clears an expired marker without re-arming DNS when the classroom is disabled' {
            Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'

            Test-OpenPathCaptivePortalModeActive | Should -BeFalse

            Test-Path -LiteralPath $script:markerPath | Should -BeFalse
            $global:OpenPathSetLocalDnsCalls | Should -Be 0
        }

        It 'keeps the fail-closed Set-LocalDNS path when the classroom is enabled' {
            Set-Content -Path $script:whitelistPath -Value 'example.org'

            Test-OpenPathCaptivePortalModeActive | Should -BeFalse

            Test-Path -LiteralPath $script:markerPath | Should -BeTrue
            $global:OpenPathSetLocalDnsCalls | Should -Be 1
        }

        It 'keeps fail-closed enforcement when the whitelist state is unknown' {
            Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
            $lock = [System.IO.File]::Open($script:whitelistPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                Test-OpenPathCaptivePortalModeActive | Should -BeFalse
            }
            finally {
                $lock.Dispose()
            }

            Test-Path -LiteralPath $script:markerPath | Should -BeTrue
            $global:OpenPathSetLocalDnsCalls | Should -Be 1
            Should -Invoke -ModuleName CaptivePortal Write-OpenPathLog -Times 1 -Exactly -ParameterFilter {
                $Message -match 'classroom_state_unknown'
            }
        }
    }

    Context 'Portal entry functions' {
        BeforeEach {
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path (Join-Path $script:root 'data') -Force | Out-Null
            $script:whitelistPath = Join-Path $script:root 'data/whitelist.txt'
            $script:markerPath = Join-Path $script:root 'data/captive-portal-active.json'

            InModuleScope CaptivePortal -Parameters @{ Root = $script:root; Marker = $script:markerPath } {
                param($Root, $Marker)
                $script:savedRoot = $script:OpenPathRoot
                $script:savedMarker = $script:CaptivePortalStatePath
                $script:OpenPathRoot = $Root
                $script:CaptivePortalStatePath = $Marker
            }

            Mock -ModuleName CaptivePortal Write-OpenPathLog { }
            Mock -ModuleName CaptivePortal Restore-OpenPathProtectedMode { $true }
            Mock -ModuleName CaptivePortal Restore-OpenPathCaptivePortalAcrylicHostState { $true }
            function global:Set-LocalDNS { $global:OpenPathSetLocalDnsCalls++ }
            $global:OpenPathSetLocalDnsCalls = 0
        }

        AfterEach {
            InModuleScope CaptivePortal {
                $script:OpenPathRoot = $script:savedRoot
                $script:CaptivePortalStatePath = $script:savedMarker
            }
            Remove-Item Function:\Set-LocalDNS -ErrorAction SilentlyContinue
            Remove-Variable -Name OpenPathSetLocalDnsCalls -Scope Global -ErrorAction SilentlyContinue
        }

        It 'does not enter any portal mode for a disabled classroom and clears an existing marker' {
            Set-Content -Path $script:whitelistPath -Value '# DESACTIVADO'
            Set-Content -LiteralPath $script:markerPath -Value '{}'

            Enable-OpenPathCaptivePortalMode -State Portal | Should -BeFalse
            InModuleScope CaptivePortal {
                Enable-OpenPathCaptivePortalLimitedMode | Should -BeFalse
                Enable-OpenPathCaptivePortalPassthroughMode | Should -BeFalse
                Restore-OpenPathLimitedCaptivePortalAttempt
            }

            Test-Path -LiteralPath $script:markerPath | Should -BeFalse
            Should -Invoke -ModuleName CaptivePortal Restore-OpenPathProtectedMode -Times 0 -Exactly
            Should -Invoke -ModuleName CaptivePortal Restore-OpenPathCaptivePortalAcrylicHostState -Times 0 -Exactly
            $global:OpenPathSetLocalDnsCalls | Should -Be 0
        }

        It 'still enters limited and passthrough modes for an enabled classroom' {
            Set-Content -Path $script:whitelistPath -Value 'example.org'
            Mock -ModuleName CaptivePortal Enable-OpenPathCaptivePortalLimitedMode { $true }
            Mock -ModuleName CaptivePortal Enable-OpenPathCaptivePortalPassthroughMode { $true }

            Enable-OpenPathCaptivePortalMode -State Portal -PortalRecoveryDomains @('portal.example.org') | Should -BeTrue
            Should -Invoke -ModuleName CaptivePortal Enable-OpenPathCaptivePortalLimitedMode -Times 1 -Exactly

            Enable-OpenPathCaptivePortalMode -State Portal | Should -BeTrue
            Should -Invoke -ModuleName CaptivePortal Enable-OpenPathCaptivePortalPassthroughMode -Times 1 -Exactly
        }
    }

    Context 'Watchdog prechecks and passthrough emergency checks' {
        BeforeAll {
            . (Join-Path (Join-Path $script:libPath 'internal') 'Watchdog.Runtime.ps1')
        }

        It 'skips captive portal detection and entry for a disabled classroom' {
            $global:OpenPathWatchdogPortalStateReads = 0
            $global:OpenPathWatchdogPortalCloses = 0
            $global:OpenPathWatchdogDetectionRuns = 0
            $global:OpenPathWatchdogSetLocalDns = 0
            $global:OpenPathWatchdogProtectedRestores = 0
            function Test-OpenPathCaptivePortalClassroomDisabled { $true }
            function Set-LocalDNS { $global:OpenPathWatchdogSetLocalDns++ }
            function Restore-OpenPathProtectedMode { param($Config) $global:OpenPathWatchdogProtectedRestores++ }
            function Test-OpenPathCaptivePortalModeActive {
                param([switch]$SkipExpiredRestore)
                $global:OpenPathWatchdogPortalStateReads++
                $global:OpenPathWatchdogPortalSkipExpiredRestore = $SkipExpiredRestore
                return $true
            }
            function Close-OpenPathCaptivePortalForDisabledClassroom { $global:OpenPathWatchdogPortalCloses++; $true }
            function Test-OpenPathCaptivePortalState {
                param([int]$TimeoutSec = 3)
                $global:OpenPathWatchdogDetectionRuns++
                return 'Portal'
            }
            function Update-OpenPathCaptivePortalObservation { $true }
            function Write-OpenPathLog { param([string]$Message, [string]$Level) }

            try {
                $result = Invoke-OpenPathWatchdogPrechecks `
                    -Config ([pscustomobject]@{ enableNonAdminAppControl = $false }) `
                    -OpenPathRoot $TestDrive

                $result.PortalModeActive | Should -BeFalse
                $result.CaptiveState | Should -Be 'NoNetwork'
                $global:OpenPathWatchdogDetectionRuns | Should -Be 0
                $global:OpenPathWatchdogPortalCloses | Should -Be 1
                $global:OpenPathWatchdogPortalSkipExpiredRestore | Should -BeTrue
                $global:OpenPathWatchdogSetLocalDns | Should -Be 0
                $global:OpenPathWatchdogProtectedRestores | Should -Be 0
            }
            finally {
                Remove-Item Function:\Test-OpenPathCaptivePortalClassroomDisabled, Function:\Test-OpenPathCaptivePortalModeActive -ErrorAction SilentlyContinue
                Remove-Item Function:\Close-OpenPathCaptivePortalForDisabledClassroom, Function:\Test-OpenPathCaptivePortalState -ErrorAction SilentlyContinue
                Remove-Item Function:\Update-OpenPathCaptivePortalObservation, Function:\Write-OpenPathLog -ErrorAction SilentlyContinue
                Remove-Item Function:\Set-LocalDNS, Function:\Restore-OpenPathProtectedMode -ErrorAction SilentlyContinue
                Remove-Variable -Name OpenPathWatchdogPortalStateReads, OpenPathWatchdogPortalCloses -Scope Global -ErrorAction SilentlyContinue
                Remove-Variable -Name OpenPathWatchdogDetectionRuns, OpenPathWatchdogPortalSkipExpiredRestore -Scope Global -ErrorAction SilentlyContinue
                Remove-Variable -Name OpenPathWatchdogSetLocalDns, OpenPathWatchdogProtectedRestores -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'never closes passthrough through the protected-mode path for a disabled classroom' {
            $global:OpenPathPassthroughDisables = 0
            function Test-OpenPathCaptivePortalClassroomDisabled { $true }
            function Get-OpenPathCaptivePortalMarker { [pscustomobject]@{ mode = 'passthrough' } }
            function Get-OpenPathActiveIpv4AdaptersMissingLocalDns { @() }
            function Disable-OpenPathCaptivePortalMode { $global:OpenPathPassthroughDisables++; $true }
            function Close-OpenPathCaptivePortalForDisabledClassroom { $true }
            function Write-OpenPathLog { param([string]$Message, [string]$Level) }

            try {
                $result = Invoke-OpenPathCaptivePortalPassthroughEmergencyChecks `
                    -Config ([pscustomobject]@{}) `
                    -PortalModeActive $true `
                    -CaptiveState 'Portal'

                @($result.Issues).Count | Should -Be 0
                $global:OpenPathPassthroughDisables | Should -Be 0
            }
            finally {
                Remove-Item Function:\Test-OpenPathCaptivePortalClassroomDisabled, Function:\Get-OpenPathCaptivePortalMarker -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-OpenPathActiveIpv4AdaptersMissingLocalDns, Function:\Disable-OpenPathCaptivePortalMode -ErrorAction SilentlyContinue
                Remove-Item Function:\Close-OpenPathCaptivePortalForDisabledClassroom, Function:\Write-OpenPathLog -ErrorAction SilentlyContinue
                Remove-Variable -Name OpenPathPassthroughDisables -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Invoke-OpenPathCaptivePortalRecoveryRequest' {
        BeforeEach {
            . (Join-Path (Join-Path $script:libPath 'internal') 'CaptivePortal.RecoveryTransition.ps1')
            . (Join-Path (Join-Path $script:libPath 'internal') 'CaptivePortal.RecoveryRunner.ps1')

            $script:requestPath = Join-Path $TestDrive 'request.json'
            $script:resultPath = Join-Path $TestDrive 'result'
            $script:progressPath = Join-Path $TestDrive 'progress'
            $script:portalChanges = 0
        }

        It 'answers without touching portal or protection state for <Operation> requests' -ForEach @(
            @{ Operation = 'open'; ProbeState = 'Authenticated' }
            @{ Operation = 'open'; ProbeState = 'Portal' }
            @{ Operation = 'reconcile'; ProbeState = 'Authenticated' }
        ) {
            @{ requestId = 'disabled-request'; operation = $Operation; triggerHost = 'drive.google.com' } |
                ConvertTo-Json | Set-Content -Path $script:requestPath -Encoding UTF8
            (Get-Item $script:requestPath).LastWriteTimeUtc = [DateTime]::UtcNow

            $script:probeState = $ProbeState
            $script:closedMarkers = 0
            $script:selectedHosts = 0
            $script:skipExpiredRestoreUsed = $false
            $script:recoveryLogs = @()
            function Test-OpenPathCaptivePortalClassroomDisabled { $true }
            function Get-OpenPathCaptivePortalRecoveryState { $script:probeState }
            function Update-OpenPathCaptivePortalObservation { $true }
            function Enable-OpenPathCaptivePortalMode { $script:portalChanges++; $true }
            function Disable-OpenPathCaptivePortalMode { $script:portalChanges++; $true }
            function Test-OpenPathCaptivePortalModeActive {
                param([switch]$SkipExpiredRestore)
                $script:skipExpiredRestoreUsed = $SkipExpiredRestore
                return $true
            }
            function Close-OpenPathCaptivePortalForDisabledClassroom { $script:closedMarkers++; $true }
            function Select-OpenPathCaptivePortalAllowedRecoveryHosts {
                param([string[]]$RequestedHosts = @())
                $script:selectedHosts++
                return @()
            }
            function Write-OpenPathLog {
                param([Parameter(ValueFromPipeline = $true)]$Message, $Level)
                $script:recoveryLogs += [string]$Message
            }

            $envelope = [pscustomobject]@{
                File = Get-Item $script:requestPath
                Request = (Get-Content $script:requestPath -Raw | ConvertFrom-Json)
            }

            Invoke-OpenPathCaptivePortalRecoveryRequest -RequestEnvelope $envelope `
                -ResultPath $script:resultPath -ProgressPath $script:progressPath -NowUtc ([DateTime]::UtcNow)

            $result = Get-Content (Join-Path $script:resultPath 'disabled-request.json') -Raw | ConvertFrom-Json
            $result.state | Should -Be 'ClassroomDisabled'
            $result.success | Should -BeFalse
            $result.portalModeActive | Should -BeFalse
            $script:portalChanges | Should -Be 0
            $script:selectedHosts | Should -Be 0
            $script:closedMarkers | Should -Be 1
            $script:skipExpiredRestoreUsed | Should -BeTrue
            @($script:recoveryLogs | Where-Object { $_ -match 'dropped .*www\.wikipedia\.org' }).Count | Should -Be 0
            Test-Path $script:requestPath | Should -BeFalse
        }
    }
}
