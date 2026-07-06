#
# Windows.ContractConstants.Tests.ps1
#
# Sync-guard for the shared whitelist wire-format contract
# (shared/contracts/whitelist-format.contract.json).
#
# Unlike the Linux and TypeScript sides, Windows does NOT get a generated
# parallel include here: a concurrent session already extracted the Windows
# domain/detection-host lists into catalog functions
# (Common.Domains.Catalog.ps1, CaptivePortal.psm1). This suite instead PINS
# those already-existing, already-tested functions to the same contract
# values so the three language layers cannot silently drift apart.
#
# Pure by design: reads the contract JSON and dot-sources/imports pure
# catalog functions only. No admin rights, no live Windows APIs, no network -
# must pass on this Linux dev box and on the hosted windows-2025 runner alike.

Describe 'Contract constants sync-guard (whitelist-format.contract.json)' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        $contractPath = Join-Path $repoRoot 'shared' 'contracts' 'whitelist-format.contract.json'
        $script:Contract = Get-Content -Path $contractPath -Raw | ConvertFrom-Json

        # Pure domain-catalog function: Get-OpenPathCaptivePortalProbeDomains
        . (Join-Path $repoRoot 'windows' 'lib' 'internal' 'Common.Domains.Catalog.ps1')

        # Pure wire-format section parser/serializer:
        # ConvertTo-OpenPathWhitelistFileContent (Common.Whitelist.ps1) dot-sources
        # its sibling Common.Whitelist.Sections.ps1 only when that function isn't
        # already defined, so load both explicitly and in dependency order.
        . (Join-Path $repoRoot 'windows' 'lib' 'internal' 'Common.Whitelist.Sections.ps1')
        . (Join-Path $repoRoot 'windows' 'lib' 'internal' 'Common.Whitelist.ps1')

        # CaptivePortal.psm1 owns Get-OpenPathCaptivePortalDetectionHosts. It is a
        # full module (not a leaf pure-function file), but importing it performs
        # only local path resolution at load time - no admin/network calls - so it
        # is safe to import here (the same pattern windows/tests/Windows.Watchdog.Tests.ps1
        # already uses).
        Import-Module (Join-Path $repoRoot 'windows' 'lib' 'CaptivePortal.psm1') -Force
    }

    Context 'Windows captive-portal probe domains (Common.Domains.Catalog.ps1)' {
        It 'matches the contract windows probe list exactly, order preserved' {
            $actual = @(Get-OpenPathCaptivePortalProbeDomains)
            $expected = @($script:Contract.captivePortalProbeDomains.windows)
            ($actual -join '|') | Should -BeExactly ($expected -join '|')
            $actual.Count | Should -Be 6
        }
    }

    Context 'Windows captive-portal detection hosts (CaptivePortal.psm1)' {
        It 'matches the contract windows detection-hosts list exactly, order preserved' {
            $actual = @(Get-OpenPathCaptivePortalDetectionHosts)
            $expected = @($script:Contract.captivePortalProbeDomains.windowsDetectionHosts)
            ($actual -join '|') | Should -BeExactly ($expected -join '|')
            $actual.Count | Should -Be 4
        }
    }

    Context 'Windows disabled sentinel + section headers (Common.Whitelist.ps1 serializer)' {
        # ConvertTo-OpenPathWhitelistFileContent is the canonical whitelist.txt
        # serializer; it emits the disabled sentinel and all four section headers
        # as inline literals (there is no standalone shared constant for them yet
        # on the Windows side - see task-1-plan9-report.md for the note on this).
        It 'emits the contract disabled sentinel with no trailing content' {
            $content = ConvertTo-OpenPathWhitelistFileContent -Whitelist @('example.com') -Disabled
            $firstLine = ($content -split "`r?`n")[0]
            $firstLine | Should -BeExactly $script:Contract.disabledSentinel
        }

        It 'emits all four contract section headers, in contract order' {
            $content = ConvertTo-OpenPathWhitelistFileContent -Whitelist @('a.example') -BlockedSubdomains @('b.example') -BlockedPaths @('/c') -AllowedPaths @('/d')
            $lines = @($content -split "`r?`n")

            $headers = $script:Contract.sectionHeaders
            $expectedOrder = @($headers.whitelist, $headers.blockedSubdomains, $headers.blockedPaths, $headers.allowedPaths)
            $actualHeaderLines = @($lines | Where-Object { $_ -like '## *' })

            ($actualHeaderLines -join '|') | Should -BeExactly ($expectedOrder -join '|')
        }

        It 'the wire-format parser recognizes the contract sentinel and section headers as round-trippable' {
            # Common.Whitelist.Sections.ps1's Get-OpenPathWhitelistSectionsFromLines is the
            # reader half of the same contract; assert it reads back what the serializer
            # (and the contract) produce.
            $written = ConvertTo-OpenPathWhitelistFileContent -Whitelist @('example.com') -Disabled
            $parsed = Get-OpenPathWhitelistSectionsFromLines -Lines @($written -split "`r?`n")

            $parsed.IsDisabled | Should -BeTrue
            $parsed.Whitelist | Should -Contain 'example.com'
        }
    }
}
