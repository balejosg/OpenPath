function Compare-OpenPathVersion {
    <#
    .SYNOPSIS
        Compares semantic-like versions and returns -1, 0, or 1
    #>
    param(
        [string]$CurrentVersion,
        [string]$TargetVersion
    )

    $currentMatch = [regex]::Match([string]$CurrentVersion, '\d+(?:\.\d+){0,3}')
    $targetMatch = [regex]::Match([string]$TargetVersion, '\d+(?:\.\d+){0,3}')

    $currentNormalized = if ($currentMatch.Success) { $currentMatch.Value } else { '0.0.0' }
    $targetNormalized = if ($targetMatch.Success) { $targetMatch.Value } else { '0.0.0' }

    try {
        $currentParsed = [version]$currentNormalized
        $targetParsed = [version]$targetNormalized
        return $currentParsed.CompareTo($targetParsed)
    }
    catch {
        return [string]::Compare($currentNormalized, $targetNormalized, $true)
    }
}

function Test-OpenPathAgentUpdateNeeded {
    <#
    .SYNOPSIS
        Decides whether the agent must apply the server's Windows agent package
    .DESCRIPTION
        A newer server version always updates and an older one never does. At an
        equal version the agent updates when the server publishes a build
        fingerprint that differs from the one recorded at the last update, so new
        code ships without a manual version bump. Servers that publish no build
        keep the version-only behaviour.
    #>
    param(
        [string]$CurrentVersion,
        [string]$CurrentBuild,
        [string]$TargetVersion,
        [string]$TargetBuild
    )

    $comparison = Compare-OpenPathVersion -CurrentVersion $CurrentVersion -TargetVersion $TargetVersion
    if ($comparison -lt 0) { return $true }
    if ($comparison -gt 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($TargetBuild)) { return $false }
    return (-not [string]::Equals([string]$CurrentBuild, $TargetBuild, [System.StringComparison]::OrdinalIgnoreCase))
}
