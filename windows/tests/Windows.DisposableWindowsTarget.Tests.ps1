Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\DisposableWindowsTarget.psm1') -Force

Describe 'Disposable Windows target boundary' {
    It 'rejects observations for another phase or run' {
        $path = Join-Path $TestDrive 'observation.json'
        @{ runId = 'run-a'; phase = 'observe'; status = 'passed'; observation = @{ bootId = 'boot-1' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        { Read-OpenPathDisposableWindowsObservation -Path $path -Mode AfterReboot -RunId run-a } |
            Should -Throw '*phase-mismatch*'
    }

    It 'accepts only a passed observation with a body' {
        $path = Join-Path $TestDrive 'observation.json'
        @{ runId = 'run-a'; phase = 'observe'; status = 'passed'; observation = @{ bootId = 'boot-1' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        (Read-OpenPathDisposableWindowsObservation -Path $path -Mode Observe -RunId run-a).observation.bootId |
            Should -Be 'boot-1'
    }
}
