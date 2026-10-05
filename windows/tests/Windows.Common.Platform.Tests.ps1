Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

Describe "Platform script composition" {
    It "Routes update runtime helpers through the shared module" {
        $updateScriptPath = Join-Path $PSScriptRoot ".." "scripts" "Update-OpenPath.ps1"
        $runtimeModulePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
        $content = Get-Content $updateScriptPath -Raw
        $runtimeContent = Get-Content $runtimeModulePath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force',
            '$exitCode = Invoke-OpenPathUpdateCycle -OpenPathRoot $OpenPathRoot',
            'exit $exitCode'
        )

        Assert-ContentContainsAll -Content $runtimeContent -Needles @(
            '. (Join-Path $OpenPathRoot ''lib\internal\Update.Script.Apply.ps1'')',
            '. (Join-Path $OpenPathRoot ''lib\internal\Update.Script.Rollback.ps1'')'
        )

        Assert-ContentContainsAll -Content $runtimeContent -Needles @(
            'Clear-StaleFailsafeState',
            'Enter-StaleWhitelistFailsafe',
            'Restore-OpenPathCheckpoint',
            'Write-UpdateCatchLog',
            'Sync-FirefoxNativeHostMirror'
        )
    }
}
