function Get-OpenPathNativeHostArtifactNames {
    return @(
        'OpenPath-NativeHost.ps1',
        'OpenPath-NativeHost.cmd',
        'CapabilityStorage.ps1',
        'RequestSetup.State.psm1',
        'Common.Redaction.ps1',
        'RuntimeDependency.Protocol.ps1',
        'RuntimeDependency.Policy.ps1',
        'RuntimeDependency.Queue.ps1',
        'RuntimeDependency.Overlay.ps1',
        'TaskRunner.ps1',
        'NativeHost.State.ps1',
        'NativeHost.Protocol.ps1',
        'NativeHost.Actions.ps1'
    )
}

function Get-OpenPathNativeHostArtifactCandidateRoots {
    param(
        [AllowNull()]
        [string]$SourceRoot = $null,

        [AllowNull()]
        [string]$NativeRoot = $null
    )

    $candidateRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        $candidateRoots += $SourceRoot

        $sourceParent = Split-Path $SourceRoot -Parent
        if (-not [string]::IsNullOrWhiteSpace($sourceParent)) {
            $candidateRoots += (Join-Path $sourceParent 'lib')
            $candidateRoots += (Join-Path $sourceParent 'lib\internal')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($NativeRoot)) {
        $candidateRoots += $NativeRoot
    }

    return @($candidateRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Resolve-OpenPathNativeHostArtifactSources {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArtifactNames,

        [Parameter(Mandatory = $true)]
        [string[]]$CandidateRoots
    )

    $artifactSources = @{}
    $missingArtifacts = @()

    foreach ($artifactName in $ArtifactNames) {
        $artifactSource = $CandidateRoots |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path (Join-Path $_ $artifactName)) } |
            Select-Object -First 1

        if ($artifactSource) {
            $artifactSources[$artifactName] = $artifactSource
            continue
        }

        $missingArtifacts += $artifactName
    }

    return [PSCustomObject]@{
        Sources = $artifactSources
        Missing = @($missingArtifacts)
    }
}
