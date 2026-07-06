# Live rung of the cross-platform firewall contract scenarios: REAL
# Set-OpenPathFirewall apply + REAL Get-NetFirewallRule state on the
# self-hosted lab runner. Invoked ONLY by
# tests/e2e/ci/run-windows-contract-scenarios.ps1 (guarded); the whole
# Describe self-skips without the guard env so an accidental discovery of
# this file never mutates firewall state.

BeforeDiscovery {
    $script:liveAllowed = (
        $env:RUNNER_ENVIRONMENT -eq 'self-hosted' -and
        $env:OPENPATH_CONTRACT_REAL_FIREWALL -eq '1' -and
        $IsWindows
    )
    Import-Module (Join-Path $PSScriptRoot 'contract-scenarios' 'ContractScenarios.Helpers.psm1') -Force

    $script:windowsScenarioCases = @()
    $script:windowsDnsCases = @()
    if ($script:liveAllowed) {
        foreach ($scenario in @(Get-ContractScenarios -Platform windows)) {
            $script:windowsScenarioCases += @{ Id = [string]$scenario.id }
            $dnsEntries = @()
            if ($scenario.expect.PSObject.Properties['dns'] -and $scenario.expect.dns) {
                $dnsEntries = @($scenario.expect.dns)
            }
            foreach ($entry in $dnsEntries) {
                $expectation = $null
                if ($entry.PSObject.Properties['a'] -and $entry.a) {
                    if ($entry.a -is [string]) { $expectation = [string]$entry.a }
                    elseif ($entry.a.PSObject.Properties['windows']) { $expectation = [string]$entry.a.windows }
                }
                if ($expectation) {
                    $script:windowsDnsCases += @{
                        Id          = [string]$scenario.id
                        DnsHost     = [string]$entry.host
                        Expectation = $expectation
                    }
                }
            }
        }
    }
}

Describe 'Live firewall contract scenarios (self-hosted lab runner only)' -Skip:(-not $script:liveAllowed) {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'contract-scenarios' 'ContractScenarios.Helpers.psm1') -Force
        $libPath = Join-Path $PSScriptRoot '..' '..' 'windows' 'lib'
        Import-Module (Join-Path $libPath 'Common.psm1') -Force -Global
        Import-Module (Join-Path $libPath 'Firewall.psm1') -Force -Global

        if (-not (Test-AdminPrivileges)) {
            throw 'The live contract rung requires administrator privileges.'
        }

        # All windows-scoped scenario flags map to Windows defaults (Task 6
        # table), so a single real apply serves every scenario snapshot.
        $script:applied = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8'
        $script:liveRules = @(Get-ContractLiveFirewallRules)

        $script:acrylicService = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*Acrylic*' -or $_.DisplayName -like '*Acrylic*' } |
            Select-Object -First 1
    }

    AfterAll {
        # Restore the runner; the workflow's reset-self-hosted-windows-runner
        # step is the backstop if this suite dies mid-flight.
        if (Get-Command -Name Remove-OpenPathFirewall -ErrorAction SilentlyContinue) {
            Remove-OpenPathFirewall | Out-Null
        }
    }

    It 'applies the policy end-to-end (no mid-apply abort; regression 33d67ea4)' {
        $script:applied | Should -BeTrue
        $script:liveRules.Count | Should -BeGreaterThan 0
    }

    It 'satisfies <Id> egress expectations and rule-state invariants' -ForEach $script:windowsScenarioCases {
        $scenario = Get-ContractScenario -Id $Id

        foreach ($entry in @(Get-ContractWindowsEgressExpectations -Scenario $scenario)) {
            $protocol = if ($entry.PSObject.Properties['proto'] -and $entry.proto) { [string]$entry.proto } else { 'tcp' }
            $verdict = Get-ContractWindowsEgressVerdict -Rules $script:liveRules `
                -Dest ([string]$entry.dest) -Protocol $protocol -Port ([int]$entry.port)
            $verdict | Should -Be ([string]$entry.verdict) `
                -Because "egress $($entry.dest) $protocol/$($entry.port) against live rule state"
        }

        $invariants = @()
        if ($scenario.expect.PSObject.Properties['invariants'] -and $scenario.expect.invariants) {
            $invariants = @($scenario.expect.invariants)
        }
        foreach ($invariant in $invariants) {
            Test-ContractRuleSetInvariant -Invariant $invariant -Rules $script:liveRules |
                Should -BeIn @('pass', 'skipped') -Because "invariant $invariant against live rule state"
        }
    }

    It 'answers DNS for <DnsHost> as <Expectation> via local Acrylic (<Id>)' -ForEach $script:windowsDnsCases {
        if (-not $script:acrylicService -or $script:acrylicService.Status -ne 'Running') {
            Set-ItResult -Skipped -Because 'Acrylic DNS service is not installed/running on this runner (declared SKIP; firewall-state assertions above still ran)'
            return
        }
        if ($Expectation -ne 'blocked') {
            Set-ItResult -Skipped -Because "expectation '$Expectation' needs an enrolled whitelist on the runner; only the 'blocked' class is assertable against a bare Acrylic install"
            return
        }

        $answers = @(
            Resolve-DnsName -Name $DnsHost -Server 127.0.0.1 -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue |
                Where-Object { $_.PSObject.Properties['IPAddress'] } |
                ForEach-Object { [string]$_.IPAddress }
        )
        Test-ContractDnsAnswerBlocked -Addresses $answers |
            Should -BeTrue -Because "blocked host must answer sinkhole/unspecified/no-answer, got: $($answers -join ', ')"
    }
}
