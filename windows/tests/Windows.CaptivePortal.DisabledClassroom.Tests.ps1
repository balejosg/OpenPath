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
            function Test-OpenPathCaptivePortalClassroomDisabled { $true }
            function Get-OpenPathCaptivePortalRecoveryState { $script:probeState }
            function Update-OpenPathCaptivePortalObservation { $true }
            function Enable-OpenPathCaptivePortalMode { $script:portalChanges++; $true }
            function Disable-OpenPathCaptivePortalMode { $script:portalChanges++; $true }
            function Test-OpenPathCaptivePortalModeActive { $false }
            function Select-OpenPathCaptivePortalAllowedRecoveryHosts { param([string[]]$RequestedHosts = @()) @() }

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
            Test-Path $script:requestPath | Should -BeFalse
        }
    }
}
