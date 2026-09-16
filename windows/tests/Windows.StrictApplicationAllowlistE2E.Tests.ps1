Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe 'Strict application allowlist Windows E2E harness' {
    It 'ships a parseable, explicit opt-in real Windows matrix' {
        $scriptPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-strict-application-allowlist.ps1'
        Test-Path -LiteralPath $scriptPath -PathType Leaf | Should -BeTrue

        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
        @($parseErrors).Count | Should -Be 0
    }

    It 'does not silently treat missing strict fixtures or policy observations as passes' {
        $scriptPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-strict-application-allowlist.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'StrictApplicationAllowlist',
            'Test-AppLockerPolicy',
            'Synthetic FutureBrowser is denied by strict default',
            'Unapproved MSI is denied',
            'Unapproved script is denied',
            'Unapproved Appx package is denied',
            'Administrator and SYSTEM Appx recovery',
            'if ($RequireFixture) { ''fail'' } else { ''skip'' }',
            '$_.status -eq ''fail'' -or $_.status -eq ''unknown'''
        )
    }

    It 'never writes the student password to evidence' {
        $scriptPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-strict-application-allowlist.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw

        $content | Should -Not -Match 'password\s*=\s*\$StudentPassword'
        $content | Should -Not -Match 'ConvertTo-Json[^\r\n]*StudentPassword'
    }
}
