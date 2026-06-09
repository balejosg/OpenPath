function Copy-OpenPathDirectRunnerNativeArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$InstalledOpenPathRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactName,
        [string]$MissingArtifactContext = 'direct-runner overlay'
    )

    $candidateRoots = @(
        (Join-Path $RepoRoot 'windows\scripts'),
        (Join-Path $RepoRoot 'windows\lib'),
        (Join-Path $RepoRoot 'windows\lib\internal')
    )
    $sourcePath = $candidateRoots |
        ForEach-Object { Join-Path $_ $ArtifactName } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $sourcePath) {
        throw "Native host artifact was not found in ${MissingArtifactContext}: $ArtifactName"
    }

    $nativeRoot = Join-Path $InstalledOpenPathRoot 'browser-extension\firefox\native'
    New-Item -ItemType Directory -Path $nativeRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $nativeRoot $ArtifactName) -Force
}

function Stage-OpenPathDirectRunnerRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$InstalledOpenPathRoot = 'C:\OpenPath',
        [string]$InstalledRecoveryScriptPath = '',
        [string]$MissingArtifactContext = 'direct-runner overlay'
    )

    if ([string]::IsNullOrWhiteSpace($InstalledRecoveryScriptPath)) {
        $InstalledRecoveryScriptPath = Join-Path $InstalledOpenPathRoot 'scripts\Recover-CaptivePortal.ps1'
    }

    $installedLibRoot = Join-Path $InstalledOpenPathRoot 'lib'
    $installedScriptRoot = Join-Path $InstalledOpenPathRoot 'scripts'
    New-Item -ItemType Directory -Path $installedLibRoot, $installedScriptRoot -Force | Out-Null

    Copy-Item -Path (Join-Path $RepoRoot 'windows\lib\*') -Destination $installedLibRoot -Recurse -Force
    # Install ALL runtime scripts (Test-DNSHealth.ps1, Recover-CaptivePortal.ps1, etc.),
    # mirroring the production installer. Previously only Recover-CaptivePortal.ps1 was
    # staged, so the registered OpenPath-Watchdog task pointed at a missing
    # scripts\Test-DNSHealth.ps1 and exited 0xFFFD0000 without ever running portal
    # detection -- which is why autonomous detection never entered limited mode.
    Get-ChildItem -Path (Join-Path $RepoRoot 'windows\scripts\*.ps1') -ErrorAction SilentlyContinue |
        Copy-Item -Destination $installedScriptRoot -Force
    Get-ChildItem -Path (Join-Path $RepoRoot 'windows\scripts\*.cmd') -ErrorAction SilentlyContinue |
        Copy-Item -Destination $installedScriptRoot -Force
    Copy-Item `
        -LiteralPath (Join-Path $RepoRoot 'windows\scripts\Recover-CaptivePortal.ps1') `
        -Destination $InstalledRecoveryScriptPath `
        -Force

    $nativeHostArtifactCatalogPath = Join-Path $RepoRoot 'windows\lib\internal\NativeHost.ArtifactCatalog.ps1'
    if (-not (Test-Path -LiteralPath $nativeHostArtifactCatalogPath)) {
        throw "Native host artifact catalog was not found in ${MissingArtifactContext}: NativeHost.ArtifactCatalog.ps1"
    }
    . $nativeHostArtifactCatalogPath

    foreach ($artifactName in @(Get-OpenPathNativeHostArtifactNames)) {
        Copy-OpenPathDirectRunnerNativeArtifact `
            -RepoRoot $RepoRoot `
            -InstalledOpenPathRoot $InstalledOpenPathRoot `
            -ArtifactName $artifactName `
            -MissingArtifactContext $MissingArtifactContext
    }

    Import-Module (Join-Path $RepoRoot 'windows\lib\Services.psm1') -Force
    Register-OpenPathTask | Out-Null
}
