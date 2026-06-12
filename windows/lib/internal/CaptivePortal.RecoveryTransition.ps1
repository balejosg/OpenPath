function Get-OpenPathCaptivePortalRecoveryTransitionStringList {
    # coerces $Value to a flat array of non-blank trimmed strings; returns an empty array when $Value is null.
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return @() }

    return @(
        foreach ($item in @($Value)) {
            $text = ([string]$item).Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $text
            }
        }
    )
}

function Get-OpenPathCaptivePortalRecoveryTransitionProperty {
    # reads the first matching property name from $Names on $InputObject; returns $Default when none is found.
    param(
        [AllowNull()][object]$InputObject,
        [string[]]$Names = @(),
        [AllowNull()][object]$Default = $null
    )

    if (-not $InputObject) { return $Default }
    foreach ($name in @($Names)) {
        if ($InputObject.PSObject.Properties[$name]) {
            return $InputObject.$name
        }
    }
    return $Default
}

function Test-OpenPathCaptivePortalRecoveryTransitionConfiguredDomainsApplied {
    # returns $true when every domain in $ConfiguredCaptivePortalDomains is present in $AllowedHosts, or via $ConfiguredDomainsAppliedTester if supplied.
    param(
        [string[]]$AllowedHosts = @(),
        [string[]]$ConfiguredCaptivePortalDomains = @(),
        [scriptblock]$ConfiguredDomainsAppliedTester = $null
    )

    if ($ConfiguredDomainsAppliedTester) {
        return [bool](& $ConfiguredDomainsAppliedTester @($AllowedHosts) @($ConfiguredCaptivePortalDomains))
    }

    foreach ($configuredDomain in @($ConfiguredCaptivePortalDomains)) {
        if (@($AllowedHosts) -notcontains $configuredDomain) {
            return $false
        }
    }
    return $true
}

function Get-OpenPathCaptivePortalRecoveryTransitionEffectiveHosts {
    # returns a deduplicated lowercase list of trimmed host names from $Hosts, or delegates to $EffectiveHostResolver when supplied.
    param(
        [string[]]$Hosts = @(),
        [scriptblock]$EffectiveHostResolver = $null
    )

    if ($EffectiveHostResolver) {
        return @(& $EffectiveHostResolver @($Hosts))
    }

    return @(
        $Hosts |
            ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary {
    # builds a summary object from the recovery marker capturing host lists, mode flags, and readiness booleans used by the portal transition logic.
    param(
        [AllowNull()][object]$Marker,
        [string]$TriggerHost = '',
        [string[]]$ConfiguredCaptivePortalDomains = @(),
        [scriptblock]$EffectiveHostResolver = $null,
        [scriptblock]$ConfiguredDomainsAppliedTester = $null
    )

    $allowedHosts = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value (Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('allowedHosts', 'AllowedHosts') -Default @())
    $mode = [string](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('mode', 'Mode') -Default '')
    $bootstrapHosts = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value (Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('bootstrapHosts', 'BootstrapHosts') -Default @())
    $redirectHosts = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value (Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('redirectHosts', 'RedirectHosts') -Default @())
    $resourceHosts = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value (Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('resourceHosts', 'ResourceHosts') -Default @())
    $observedRuntimeHosts = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value (Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('observedRuntimeHosts', 'ObservedRuntimeHosts') -Default @())
    $pendingRuntimeHosts = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value (Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('pendingRuntimeHosts', 'PendingRuntimeHosts') -Default @())
    $discoveryTruncated = [bool](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('discoveryTruncated', 'DiscoveryTruncated') -Default $false)
    $fallbackMode = [string](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('fallbackMode', 'FallbackMode') -Default '')
    if (-not $fallbackMode) {
        $fallbackMode = if ($mode -eq 'passthrough') { 'passthrough' } else { 'none' }
    }

    $configuredDomains = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value $ConfiguredCaptivePortalDomains
    $recoveryHostsApplied = ($mode -eq 'limited' -and $allowedHosts.Count -gt 0)
    $configuredCaptivePortalDomainsApplied = Test-OpenPathCaptivePortalRecoveryTransitionConfiguredDomainsApplied `
        -AllowedHosts $allowedHosts `
        -ConfiguredCaptivePortalDomains $configuredDomains `
        -ConfiguredDomainsAppliedTester $ConfiguredDomainsAppliedTester
    $effectiveHosts = Get-OpenPathCaptivePortalRecoveryTransitionEffectiveHosts `
        -Hosts (@($allowedHosts) + @($bootstrapHosts) + @($redirectHosts) + @($resourceHosts) + @($observedRuntimeHosts) + @($configuredDomains)) `
        -EffectiveHostResolver $EffectiveHostResolver
    $declaredRecoveryHosts = Get-OpenPathCaptivePortalRecoveryTransitionEffectiveHosts `
        -Hosts (@($TriggerHost) + @($configuredDomains)) `
        -EffectiveHostResolver $EffectiveHostResolver
    if ($declaredRecoveryHosts.Count -le 0) {
        $declaredRecoveryHosts = @($allowedHosts)
    }

    $declaredRecoveryHostsApplied = ($declaredRecoveryHosts.Count -gt 0)
    foreach ($hostName in @($declaredRecoveryHosts)) {
        if ($allowedHosts -notcontains $hostName) {
            $declaredRecoveryHostsApplied = $false
            break
        }
    }

    $markerLimitedModeReady = [bool](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $Marker -Names @('limitedModeReady', 'LimitedModeReady') -Default $false)
    $limitedModeReady = ($mode -eq 'limited' -and $recoveryHostsApplied -and $markerLimitedModeReady -and $declaredRecoveryHostsApplied -and $configuredCaptivePortalDomainsApplied)
    $recentSuccessEligible = $limitedModeReady
    if ($recentSuccessEligible -and $TriggerHost) {
        $recentSuccessEligible = ($allowedHosts -contains $TriggerHost)
    }

    return [PSCustomObject]@{
        activeMarkerMode = $mode
        allowedHosts = @($allowedHosts)
        effectiveExactHosts = @($effectiveHosts)
        configuredCaptivePortalDomains = @($configuredDomains)
        configuredCaptivePortalDomainsApplied = [bool]$configuredCaptivePortalDomainsApplied
        bootstrapHosts = @($bootstrapHosts)
        redirectHosts = @($redirectHosts)
        resourceHosts = @($resourceHosts)
        observedRuntimeHosts = @($observedRuntimeHosts)
        pendingRuntimeHosts = @($pendingRuntimeHosts)
        discoveryTruncated = [bool]$discoveryTruncated
        fallbackMode = [string]$fallbackMode
        limitedModeReady = [bool]$limitedModeReady
        recoveryHostsApplied = [bool]$recoveryHostsApplied
        recentSuccessEligible = [bool]$recentSuccessEligible
    }
}

function Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess {
    # returns $true when $RecentSuccess carries a valid limited-mode marker that is eligible and not in passthrough; validates $TriggerHost and configured domains when provided.
    param(
        [AllowNull()][object]$RecentSuccess,
        [string]$TriggerHost = '',
        [string[]]$ConfiguredCaptivePortalDomains = @(),
        [scriptblock]$ConfiguredDomainsAppliedTester = $null
    )

    if (-not $RecentSuccess) { return $false }

    $payload = Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $RecentSuccess -Names @('Payload', 'payload') -Default $RecentSuccess
    if (-not $payload) { return $false }

    $eligible = [bool](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $payload -Names @('recentSuccessEligible', 'RecentSuccessEligible') -Default $false)
    if (-not $eligible) { return $false }

    $limitedModeReady = [bool](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $payload -Names @('limitedModeReady', 'LimitedModeReady') -Default $false)
    if (-not $limitedModeReady) { return $false }

    $fallbackMode = [string](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $payload -Names @('fallbackMode', 'FallbackMode') -Default '')
    if ($fallbackMode -eq 'passthrough') { return $false }

    $activeMarkerMode = [string](Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $payload -Names @('activeMarkerMode', 'ActiveMarkerMode') -Default '')
    if ($activeMarkerMode -eq 'passthrough') { return $false }

    $allowedHosts = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value (Get-OpenPathCaptivePortalRecoveryTransitionProperty -InputObject $payload -Names @('allowedHosts', 'AllowedHosts') -Default @())
    if ($TriggerHost -and ($allowedHosts.Count -le 0 -or $allowedHosts -notcontains $TriggerHost)) {
        return $false
    }

    $configuredDomains = Get-OpenPathCaptivePortalRecoveryTransitionStringList -Value $ConfiguredCaptivePortalDomains
    if ($configuredDomains.Count -gt 0) {
        if (-not (Test-OpenPathCaptivePortalRecoveryTransitionConfiguredDomainsApplied -AllowedHosts $allowedHosts -ConfiguredCaptivePortalDomains $configuredDomains -ConfiguredDomainsAppliedTester $ConfiguredDomainsAppliedTester)) {
            return $false
        }
    }

    return $true
}
