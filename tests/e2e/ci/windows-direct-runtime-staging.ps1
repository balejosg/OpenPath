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
    Copy-Item `
        -LiteralPath (Join-Path $RepoRoot 'windows\scripts\Recover-CaptivePortal.ps1') `
        -Destination $InstalledRecoveryScriptPath `
        -Force

    foreach ($artifactName in @(
            'OpenPath-NativeHost.ps1',
            'OpenPath-NativeHost.cmd',
            'CapabilityStorage.ps1',
            'RequestSetup.State.psm1',
            'Common.Redaction.ps1',
            'RuntimeDependency.Policy.ps1',
            'RuntimeDependency.Queue.ps1',
            'RuntimeDependency.Overlay.ps1',
            'TaskRunner.ps1',
            'NativeHost.State.ps1',
            'NativeHost.Protocol.ps1',
            'NativeHost.Actions.ps1'
        )) {
        Copy-OpenPathDirectRunnerNativeArtifact `
            -RepoRoot $RepoRoot `
            -InstalledOpenPathRoot $InstalledOpenPathRoot `
            -ArtifactName $artifactName `
            -MissingArtifactContext $MissingArtifactContext
    }

    Import-Module (Join-Path $RepoRoot 'windows\lib\Services.psm1') -Force
    Register-OpenPathTask | Out-Null
}
