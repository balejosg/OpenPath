<##
.SYNOPSIS
    Shard planning for the isolated Windows Pester runner.
.DESCRIPTION
    Pure helper for run-windows-pester-isolated.ps1. Given the discovered leaf
    test files and a shard index/count it returns the suite paths and the
    Pester tag filter that belong to that shard. It lives in its own module so
    the plan can be unit-tested without executing the full runner.
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
    $heavySplitTag = 'AppControlShardA'
    $heavySuitePath = @($AllSuitePaths | Where-Object { (Split-Path $_ -Leaf) -eq $heavySuiteName })
    $remainingSuitePaths = @($AllSuitePaths | Where-Object { (Split-Path $_ -Leaf) -ne $heavySuiteName })
    # With three or more shards the heavy AppControl suite is split in two by its
    # AppControlShardA tag (Tag on shard 1, ExcludeTag on shard 2) so neither half
    # can exceed the job budget. Shards 3..N take the remaining leaf suites.
    $heavySharding = $ShardCount -ge 3 -and $heavySuitePath.Count -eq 1
    $suitePaths = if ($heavySharding) {
        if ($ShardIndex -le 2) {
            @($heavySuitePath)
        }
        else {
            @(
                for ($index = 0; $index -lt $remainingSuitePaths.Count; $index++) {
                    if (($index % ($ShardCount - 2)) -eq ($ShardIndex - 3)) {
                        $remainingSuitePaths[$index]
                    }
                }
            )
        }
    }
    elseif ($ShardCount -gt 1 -and $heavySuitePath.Count -eq 1) {
        if ($ShardIndex -eq 1) {
            @($heavySuitePath)
        }
        else {
            @(
                for ($index = 0; $index -lt $remainingSuitePaths.Count; $index++) {
                    if (($index % ($ShardCount - 1)) -eq ($ShardIndex - 2)) {
                        $remainingSuitePaths[$index]
                    }
                }
            )
        }
    }
    else {
        @(
            for ($index = 0; $index -lt $AllSuitePaths.Count; $index++) {
                if (($index % $ShardCount) -eq ($ShardIndex - 1)) {
                    $AllSuitePaths[$index]
                }
            }
        )
    }
    if ($suitePaths.Count -eq 0) {
        throw "Pester shard $ShardIndex of $ShardCount selected no test files."
    }

    $tag = $null
    $excludeTag = $null
    if ($heavySharding -and $ShardIndex -eq 1) { $tag = $heavySplitTag }
    elseif ($heavySharding -and $ShardIndex -eq 2) { $excludeTag = $heavySplitTag }

    return [pscustomobject]@{
        SuitePaths = @($suitePaths)
        Tag        = $tag
        ExcludeTag = $excludeTag
    }
}

Export-ModuleMember -Function Get-WindowsPesterShardPlan
