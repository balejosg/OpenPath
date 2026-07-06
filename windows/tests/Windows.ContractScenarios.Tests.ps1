# Mocked unit rung for tests/contracts/scenarios/*.scenario.json on Windows.
# Runs everywhere (GitHub-hosted windows-2025 included): New-NetFirewallRule is
# the capture mock from TestHelpers.psm1, which also mirrors the real cmdlet's
# rejection of /0 prefixes (regression 33d67ea4 fails HERE, not on a live box).
# The real-firewall rung lives in tests/e2e/Windows-ContractScenarios.Tests.ps1
# and only runs on the self-hosted lab runner.

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
Import-Module (Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "contract-scenarios" "ContractScenarios.Helpers.psm1") -Force

Describe "Contract scenarios (mocked Windows unit rung)" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\Firewall.psm1" -Force -ErrorAction SilentlyContinue
    }

    Context "Fixture set" {
        It "contains the MVP scenario ids with filenames matching ids" {
            $scenarios = @(Get-ContractScenarios)
            $scenarios.Count | Should -BeGreaterOrEqual 7
            foreach ($expectedId in @(
                    's01-blocked-domain-sinkhole',
                    's02-blocked-domain-v6-off',
                    's03-whitelisted-domain-allow-set',
                    's04-empty-whitelist-never-brick',
                    's05-upstream-reprobe-owner-confined',
                    's06-bypass-blocks-and-v6-blanket',
                    's07-search-domain-no-fallthrough')) {
                @($scenarios | Where-Object { $_.id -eq $expectedId }).Count | Should -Be 1
            }
        }

        It "maps every windows-scoped scenario to a firewall config without throwing" {
            foreach ($scenario in @(Get-ContractScenarios -Platform windows)) {
                { ConvertTo-ContractWindowsFirewallConfig -Scenario $scenario } | Should -Not -Throw
            }
        }

        It "keeps linux-only flag values out of windows-scoped scenarios" {
            $linuxOnly = [PSCustomObject]@{
                id = 'synthetic'
                given = [PSCustomObject]@{
                    flags = [PSCustomObject]@{ SINKHOLE_FAST_FAIL = '0' }
                }
            }
            { ConvertTo-ContractWindowsFirewallConfig -Scenario $linuxOnly } | Should -Throw
        }

        It "keeps every windows-scoped egress dest class assertable from rule state" {
            foreach ($scenario in @(Get-ContractScenarios -Platform windows)) {
                foreach ($entry in @(Get-ContractWindowsEgressExpectations -Scenario $scenario)) {
                    # Throws on a linux-only dest class (sinkhole-*/resolved*/any-other).
                    { Get-ContractWindowsEgressVerdict -Rules @() -Dest $entry.dest `
                            -Protocol ($entry.proto ?? 'tcp') -Port ([int]$entry.port) } | Should -Not -Throw
                }
            }
        }
    }

    Context "s06-bypass-blocks-and-v6-blanket against Set-OpenPathFirewall (mocked)" {
        BeforeEach {
            Initialize-FirewallRuleCaptureMocks
        }

        It "applies the full anti-bypass catalog, valid v6 halves, no ::1 rule, and completes end-to-end" {
            $scenario = Get-ContractScenario -Id 's06-bypass-blocks-and-v6-blanket'
            $mappedConfig = ConvertTo-ContractWindowsFirewallConfig -Scenario $scenario
            $mappedConfig.enableDohIpBlocking | Should -BeTrue

            Mock Get-OpenPathConfig {
                [PSCustomObject]@{
                    enableDohIpBlocking = $true
                }
            } -ModuleName Firewall

            $result = Set-OpenPathFirewall -UpstreamDNS '8.8.8.8' -AcrylicPath 'C:\OpenPath\Acrylic DNS Proxy'
            # A $true here is ALSO the 33d67ea4 apply-completion guard: an
            # invalid prefix (the mock throws on /0 like real Windows) aborts
            # the whole configuration and returns $false.
            $result | Should -BeTrue

            $rules = @(Get-CapturedFirewallRules)
            $rules.Count | Should -BeGreaterThan 0

            foreach ($entry in @(Get-ContractWindowsEgressExpectations -Scenario $scenario)) {
                $verdict = Get-ContractWindowsEgressVerdict -Rules $rules -Dest $entry.dest `
                    -Protocol ($entry.proto ?? 'tcp') -Port ([int]$entry.port)
                $verdict | Should -Be $entry.verdict -Because "egress $($entry.dest) $($entry.proto)/$($entry.port)"
            }

            foreach ($invariant in @($scenario.expect.invariants)) {
                Test-ContractRuleSetInvariant -Invariant $invariant -Rules $rules |
                    Should -BeIn @('pass', 'skipped') -Because "invariant $invariant"
            }
        }
    }

    Context "DNS-only windows scenarios stay structurally sound (live rung covers the answers)" {
        It "s01/s03 declare no windows-scoped egress and only linux invariants or rule-state invariants" {
            foreach ($id in @('s01-blocked-domain-sinkhole', 's03-whitelisted-domain-allow-set')) {
                $scenario = Get-ContractScenario -Id $id
                @(Get-ContractWindowsEgressExpectations -Scenario $scenario).Count | Should -Be 0
                foreach ($invariant in @($scenario.expect.invariants)) {
                    # Must be known vocabulary: throws on unknown, returns
                    # pass/skipped for known names even with an empty rule set
                    # (rule-count invariants evaluate rule text only).
                    { Test-ContractRuleSetInvariant -Invariant $invariant -Rules @() } | Should -Not -Throw
                }
            }
        }

        It "rejects an unknown invariant name on the Windows side too" {
            { Test-ContractRuleSetInvariant -Invariant 'not-a-real-invariant' -Rules @() } | Should -Throw
        }
    }
}
