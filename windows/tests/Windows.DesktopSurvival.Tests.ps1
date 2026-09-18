Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

Describe 'Windows Desktop Survival harness' {
    It 'requires an explicit phase and records blocked platform validation without mutating policy' {
        $scriptPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-desktop-survival.ps1'
        Test-Path -LiteralPath $scriptPath -PathType Leaf | Should -BeTrue
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content | Should -Match 'ValidateSet.*Prepare.*Observe.*AfterReboot.*Cleanup'
        $content | Should -Match 'BLOCKED_PLATFORM_VALIDATION'
        $content | Should -Not -Match 'Set-AppLockerPolicy'
        $content | Should -Not -Match 'Restart-Computer'
    }

    It 'does not treat a boot timestamp or profile creation as an interactive login' {
        $content = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-desktop-survival.ps1') -Raw
        $content | Should -Not -Match 'CreateProfile.*passed'
        $content | Should -Match 'ControllerCommand'
    }
}
