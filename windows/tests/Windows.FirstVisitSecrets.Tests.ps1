# Phase 5.3 B7: no secret may reach the public first-visit artifacts.
#
# The scan is a pure function over a JSON tree; the controller source contract
# pins the redaction, and when OPENPATH_FIRST_VISIT_EVIDENCE_ROOT points at a
# real scene root the same scan runs over it and must return no findings.

Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\first-visit\FirstVisitSecrets.psm1') -Force

Describe 'First-visit artifact secrets (Phase 5.3 B7)' {
    Context 'Scanner' {
        It 'Flags a secret-shaped key with a non-redacted string value' {
            $root = Join-Path $TestDrive 'scan-flag'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'state.json'), '{"guestSecret":"supersecret","machineToken":"abc123","nested":{"apiKey":"k-42"}}')
            $findings = @(Find-OpenPathFirstVisitArtifactSecret -Root $root)
            @($findings).Count | Should -Be 3
            ($findings | ForEach-Object { $_.key }) | Should -Contain '$.guestSecret'
            ($findings | ForEach-Object { $_.key }) | Should -Contain '$.machineToken'
            ($findings | ForEach-Object { $_.key }) | Should -Contain '$.nested.apiKey'
            ($findings | Where-Object { $_.key -eq '$.guestSecret' }).valueLength | Should -Be 11
            # The value itself is never copied into the finding.
            ($findings | ConvertTo-Json -Depth 6 -Compress) | Should -Not -Match 'supersecret'
        }

        It 'Accepts redacted values, hashes and empty values' {
            $root = Join-Path $TestDrive 'scan-redacted'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $sha = ('a' * 64)
            [IO.File]::WriteAllText((Join-Path $root 'ok.json'), ('{"guestSecret":"<redacted>","guestSecretSha256":"' + $sha + '","emptyToken":"","list":[{"password":"<redacted>"}]}'))
            @(Find-OpenPathFirstVisitArtifactSecret -Root $root).Count | Should -Be 0
        }

        It 'Ignores non-credential keys and malformed json' {
            $root = Join-Path $TestDrive 'scan-ignore'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'metrics.json'), '{"whitelistUrl":"https://api.invalid/w/tok12345678/whitelist.txt","secretCount":3,"hostTokenMs":12.5}')
            [IO.File]::WriteAllText((Join-Path $root 'broken.json'), '{"secret":"not-json')
            @(Find-OpenPathFirstVisitArtifactSecret -Root $root).Count | Should -Be 0
        }
    }

    Context 'Controller contract' {
        It 'Redacts the guest secret in the persisted prepare state' {
            $controllerPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\controllers\ProxmoxFirstVisit.ps1'
            $source = Get-Content -LiteralPath (Resolve-Path $controllerPath).Path -Raw
            $source | Should -Match "guestSecret\s*=\s*'<redacted>'"
            $source | Should -Match 'guestSecretSha256'
            $source | Should -Not -Match 'guestSecret\s*=\s*\$settings\.GuestSecret'
        }
    }

    Context 'Real evidence (env-gated)' {
        It 'Finds no secret in the evidence root when one is provided' {
            $root = [string]$env:OPENPATH_FIRST_VISIT_EVIDENCE_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-Host 'OPENPATH_FIRST_VISIT_EVIDENCE_ROOT not set; scanner unit coverage ran above.'
                return
            }
            $findings = @(Find-OpenPathFirstVisitArtifactSecret -Root $root)
            if ($findings.Count -gt 0) { Write-Host ('SECRET-FINDINGS ' + ($findings | ConvertTo-Json -Depth 6 -Compress)) }
            $findings.Count | Should -Be 0 -Because $root
        }
    }
}
