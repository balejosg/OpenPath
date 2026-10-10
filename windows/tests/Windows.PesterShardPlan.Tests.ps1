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

    It 'splits the measured AppControl partitions over shards 1-4 and the rest over the remainder with ShardCount 6' {
        $plans = @(
            1..6 | ForEach-Object {
                Get-WindowsPesterShardPlan -AllSuitePaths $allPaths -ShardIndex $_ -ShardCount 6
            }
        )
        $expectedTags = @(
            'AppControlShardA1',
            'AppControlShardA2',
            'AppControlShardB1',
            'AppControlShardB2'
        )
        for ($shard = 1; $shard -le 4; $shard++) {
            @($plans[$shard - 1].SuitePaths) | Should -Be @($heavyPath)
            $plans[$shard - 1].Tag | Should -Be $expectedTags[$shard - 1]
            $plans[$shard - 1].ExcludeTag | Should -BeNullOrEmpty
        }

        for ($shard = 5; $shard -le 6; $shard++) {
            $plans[$shard - 1].Tag | Should -BeNullOrEmpty
            $plans[$shard - 1].ExcludeTag | Should -BeNullOrEmpty
        }

        $remainder = @($plans[4].SuitePaths) + @($plans[5].SuitePaths)
        $remainder.Count | Should -Be 41
        @($remainder | Sort-Object -Unique).Count | Should -Be 41
        foreach ($path in $remainingPaths) {
            @($remainder) | Should -Contain $path
        }
    }

    It 'fails closed for shard counts that cannot bound the measured heavy suite' {
        foreach ($shardCount in 2..5) {
            { Get-WindowsPesterShardPlan -AllSuitePaths $allPaths -ShardIndex 1 -ShardCount $shardCount } |
                Should -Throw '*needs at least 6 shards*'
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
        { Get-WindowsPesterShardPlan -AllSuitePaths @($heavyPath) -ShardIndex 6 -ShardCount 6 } |
            Should -Throw '*selected no test files*'
    }
}
