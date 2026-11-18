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

Describe 'Endpoint posture wiring' {
    It 'is loaded by the watchdog script and listed as a required command' {
        $content = Get-Content (Join-Path (Join-Path $script:windowsRoot 'scripts') 'Test-DNSHealth.ps1') -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            "lib\internal\EndpointPosture.ps1",
            "'Test-OpenPathCaptivePortalClassroomDisabled'",
            'Get-OpenPathOpenClassroomPosture',
            'Merge-OpenPathReasonCodes'
        )
    }

    It 'merges the posture findings into the report before it is sent' {
        $content = Get-Content (Join-Path (Join-Path $script:windowsRoot 'scripts') 'Test-DNSHealth.ps1') -Raw

        $postureIndex = $content.IndexOf('Get-OpenPathOpenClassroomPosture')
        $sendIndex = $content.IndexOf('Send-OpenPathHealthReport -Status $outcome.Status')

        $postureIndex | Should -BeGreaterThan -1
        $sendIndex | Should -BeGreaterThan $postureIndex
        $content | Should -Match '\$outcome\.ReasonCodes\s*=\s*@\(Merge-OpenPathReasonCodes'
        $content | Should -Match '-ReasonCodes @\(\$outcome\.ReasonCodes\)'
    }

    It 'keeps the watchdog status untouched by the posture' {
        $content = Get-Content (Join-Path (Join-Path $script:windowsRoot 'scripts') 'Test-DNSHealth.ps1') -Raw

        $content | Should -Not -Match '\$outcome\.Status\s*=\s*[^\r\n]*OpenClassroom'
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
            'Merge-OpenPathReasonCodes'
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
