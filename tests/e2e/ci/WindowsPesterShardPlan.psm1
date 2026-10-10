<##
.SYNOPSIS
    Shard planning for the isolated Windows Pester runner.
.DESCRIPTION
    Pure helper for run-windows-pester-isolated.ps1. Given the discovered leaf
    test files and a shard index/count it returns the suite paths and the
    Pester tag filter that belong to that shard. It lives in its own module so
    the plan can be unit-tested without executing the full runner.

    Phase 8 C1: the heavy AppControl suite is split into four measured
    partitions. The previous two tag halves exceeded the 70 % budget target on
    the self-hosted runner (tag half: 507-827 s; remainder half: 424-676 s
    against an 825 s single-file budget; progress artifacts of runs
    37772525981 and 37886766064). The four partitions measured 243 s and 258 s
    for the two health-contract halves and 211 s and 207 s for the
    probe/policy-converter and policy-spec/regression groups on a normal day,
    so every partition stays below half of the 577 s target even at the worst
    observed slowdown. Shards 1-4 therefore run the four partitions and the
    remaining leaf suites spread over the remainder shards; shard counts
    between two and five fail closed instead of recreating the over-budget
    split.
#>

function Get-WindowsPesterShardPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$AllSuitePaths,

        [Parameter(Mandatory = $true)]
        [int]$ShardIndex,

        [Parameter(Mandatory = $true)]
        [int]$ShardCount
    )

    $heavySuiteName = 'Windows.AppControl.Tests.ps1'
    $heavyPartitionTags = @(
        'AppControlShardA1',
        'AppControlShardA2',
        'AppControlShardB1',
        'AppControlShardB2'
    )
    $minimumShardCount = $heavyPartitionTags.Count + 2
    $heavySuitePath = @($AllSuitePaths | Where-Object { (Split-Path $_ -Leaf) -eq $heavySuiteName })
    $remainingSuitePaths = @($AllSuitePaths | Where-Object { (Split-Path $_ -Leaf) -ne $heavySuiteName })

    if ($heavySuitePath.Count -eq 1 -and $ShardCount -gt 1) {
        if ($ShardCount -lt $minimumShardCount) {
            throw "The measured Windows AppControl suite needs at least $minimumShardCount shards (four AppControl partitions plus two remainder shards); ShardCount=$ShardCount cannot bound its per-file budget."
        }
        if ($ShardIndex -le $heavyPartitionTags.Count) {
            return [pscustomobject]@{
                SuitePaths = @($heavySuitePath)
                Tag        = $heavyPartitionTags[$ShardIndex - 1]
                ExcludeTag = $null
            }
        }

        $remainderCount = $ShardCount - $heavyPartitionTags.Count
        $remainderIndex = $ShardIndex - $heavyPartitionTags.Count - 1
        $suitePaths = @(
            for ($index = 0; $index -lt $remainingSuitePaths.Count; $index++) {
                if (($index % $remainderCount) -eq $remainderIndex) {
                    $remainingSuitePaths[$index]
                }
            }
        )
        if ($suitePaths.Count -eq 0) {
            throw "Pester shard $ShardIndex of $ShardCount selected no test files."
        }

        return [pscustomobject]@{
            SuitePaths = @($suitePaths)
            Tag        = $null
            ExcludeTag = $null
        }
    }

    $suitePaths = @(
        for ($index = 0; $index -lt $AllSuitePaths.Count; $index++) {
            if (($index % $ShardCount) -eq ($ShardIndex - 1)) {
                $AllSuitePaths[$index]
            }
        }
    )
    if ($suitePaths.Count -eq 0) {
        throw "Pester shard $ShardIndex of $ShardCount selected no test files."
    }

    return [pscustomobject]@{
        SuitePaths = @($suitePaths)
        Tag        = $null
        ExcludeTag = $null
    }
}

Export-ModuleMember -Function Get-WindowsPesterShardPlan
