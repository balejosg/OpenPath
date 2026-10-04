function Get-OpenPathNativeHostArtifactNames {
    # returns the ordered list of all ps1/psm1/cmd/cs files that must be staged in the native host directory before the host can run.
    return @(
        'OpenPath-NativeHost.ps1',
        'OpenPath-NativeHost.cmd',
        # Phase 5: build input for the compiled host. Staged next to the runtime
        # support files so the build step can find it from either install layout.
        'OpenPathNativeHost.cs',
        'CapabilityStorage.ps1',
        'RequestSetup.State.psm1',
        'Common.Redaction.ps1',
        'Common.Whitelist.Sections.ps1',
        'Common.Domains.Catalog.ps1',
        'RuntimeDependency.Protocol.ps1',
        'RuntimeDependency.Policy.ps1',
        'RuntimeDependency.Queue.ps1',
        'RuntimeDependency.Overlay.ps1',
        'CaptivePortal.RecoveryTransition.ps1',
        'CaptivePortal.StateFiles.ps1',
        'NativeHost.CaptivePortalRecoveryQueue.ps1',
        'TaskRunner.ps1',
        'NativeHost.State.ps1',
        'NativeHost.Protocol.ps1',
        'NativeHost.Actions.ps1',
        'NativeHost.Actions.Bootstrap.ps1',
        'NativeHost.Actions.Shared.ps1',
        'NativeHost.Actions.RuntimeDependency.ps1',
        'NativeHost.Actions.CaptivePortal.ps1',
        'NativeHost.Actions.MessageDispatch.ps1'
    )
}

function Get-OpenPathNativeHostArtifactCandidateRoots {
    # builds a deduplicated list of directory paths to search for artifacts, including $SourceRoot siblings and $NativeRoot.
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
            # Phase 5: the compiled host source lives in native-host/ at the
            # install root (windows/native-host/ in the repository).
            $candidateRoots += (Join-Path $sourceParent 'native-host')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($NativeRoot)) {
        $candidateRoots += $NativeRoot
    }

    return @($candidateRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Resolve-OpenPathNativeHostArtifactSources {
    # maps each artifact name to the first candidate root directory that contains it; collects names with no match in Missing.
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
