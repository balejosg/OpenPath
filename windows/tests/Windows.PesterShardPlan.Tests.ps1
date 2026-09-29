Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\WindowsPesterShardPlan.psm1') -Force

Describe 'Windows Pester shard plan' {
    BeforeAll {
        $heavyName = 'Windows.AppControl.Tests.ps1'
        $heavyPath = Join-Path $TestDrive $heavyName
        $remainingPaths = @(
            1..41 | ForEach-Object { Join-Path $TestDrive ("Windows.Suite{0:d2}.Tests.ps1" -f $_) }
        )
        $allPaths = @($heavyPath) + $remainingPaths
    }

    It 'runs every suite without a tag filter when ShardCount is 1' {
        $plan = Get-WindowsPesterShardPlan -AllSuitePaths $allPaths -ShardIndex 1 -ShardCount 1
        @($plan.SuitePaths).Count | Should -Be 42
        $plan.Tag | Should -BeNullOrEmpty
        $plan.ExcludeTag | Should -BeNullOrEmpty
    }

    It 'keeps the heavy suite alone on shard 1 and every other suite on shard 2 when ShardCount is 2' {
        $shard1 = Get-WindowsPesterShardPlan -AllSuitePaths $allPaths -ShardIndex 1 -ShardCount 2
        $shard2 = Get-WindowsPesterShardPlan -AllSuitePaths $allPaths -ShardIndex 2 -ShardCount 2
        @($shard1.SuitePaths) | Should -Be @($heavyPath)
        @($shard2.SuitePaths).Count | Should -Be 41
        $shard1.Tag | Should -BeNullOrEmpty
        $shard1.ExcludeTag | Should -BeNullOrEmpty
        $shard2.Tag | Should -BeNullOrEmpty
        $shard2.ExcludeTag | Should -BeNullOrEmpty
    }

    It 'splits the heavy suite by tag on shards 1 and 2 and covers the rest exactly once with ShardCount 5' {
        $plans = @(
            1..5 | ForEach-Object {
                Get-WindowsPesterShardPlan -AllSuitePaths $allPaths -ShardIndex $_ -ShardCount 5
            }
        )
        @($plans[0].SuitePaths) | Should -Be @($heavyPath)
        @($plans[1].SuitePaths) | Should -Be @($heavyPath)
        $plans[0].Tag | Should -Be 'AppControlShardA'
        $plans[0].ExcludeTag | Should -BeNullOrEmpty
        $plans[1].Tag | Should -BeNullOrEmpty
        $plans[1].ExcludeTag | Should -Be 'AppControlShardA'
        for ($shard = 3; $shard -le 5; $shard++) {
            $plans[$shard - 1].Tag | Should -BeNullOrEmpty
            $plans[$shard - 1].ExcludeTag | Should -BeNullOrEmpty
        }

        $remainder = @($plans[2].SuitePaths) + @($plans[3].SuitePaths) + @($plans[4].SuitePaths)
        $remainder.Count | Should -Be 41
        @($remainder | Sort-Object -Unique).Count | Should -Be 41
        foreach ($path in $remainingPaths) {
            @($remainder) | Should -Contain $path
        }
    }

    It 'round-robins every suite when the heavy suite is absent' {
        $shard1 = Get-WindowsPesterShardPlan -AllSuitePaths $remainingPaths -ShardIndex 1 -ShardCount 2
        $shard2 = Get-WindowsPesterShardPlan -AllSuitePaths $remainingPaths -ShardIndex 2 -ShardCount 2
        @($shard1.SuitePaths).Count | Should -Be 21
        @($shard2.SuitePaths).Count | Should -Be 20
        $shard1.Tag | Should -BeNullOrEmpty
        $shard2.ExcludeTag | Should -BeNullOrEmpty
    }

    It 'fails closed when a shard selects no test files' {
        { Get-WindowsPesterShardPlan -AllSuitePaths @($heavyPath) -ShardIndex 3 -ShardCount 5 } |
            Should -Throw '*selected no test files*'
    }
}
