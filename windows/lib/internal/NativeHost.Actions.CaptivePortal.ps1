function Get-NativeHostConfiguredCaptivePortalDomains {
    <#
    .SYNOPSIS
    Returns the configured captive portal domains from OpenPath config, or an empty array when unavailable.
    #>
    if (-not (Get-Command -Name 'Get-OpenPathConfiguredCaptivePortalDomains' -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        return @(Get-OpenPathConfiguredCaptivePortalDomains)
    }
    catch {
        return @()
    }
}

function Get-NativeHostCaptivePortalEffectiveHosts {
    <#
    .SYNOPSIS
    Returns the effective allowed captive portal hostnames after normalization and deduplication.
    #>
    param([string[]]$Hosts = @())

    if (Get-Command -Name 'Get-OpenPathCaptivePortalAllowedHosts' -ErrorAction SilentlyContinue) {
        return @(Get-OpenPathCaptivePortalAllowedHosts -Hosts $Hosts)
    }

    return @(
        $Hosts |
            ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Test-NativeHostConfiguredCaptivePortalDomainsApplied {
    <#
    .SYNOPSIS
    Returns true when all configured captive portal domains appear in the allowed hosts list.
    #>
    param(
        [string[]]$AllowedHosts = @(),
        [string[]]$ConfiguredCaptivePortalDomains = @()
    )

    $configuredDomains = @(
        $ConfiguredCaptivePortalDomains |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    foreach ($configuredDomain in @($configuredDomains)) {
        if (@($AllowedHosts) -notcontains $configuredDomain) {
            return $false
        }
    }

    return $true
}

function Get-NativeHostCaptivePortalRecoveryHosts {
    <#
    .SYNOPSIS
    Builds a deduplicated list of valid captive portal recovery hostnames from the trigger host and hint list.
    .DESCRIPTION
    Filters out IP addresses, IPv6 literals, .local hostnames, bare labels without dots, and duplicates.
    The list is capped at MaxHosts entries.
    #>
    param(
        [string]$TriggerHost = '',
        [AllowNull()][object]$PortalRecoveryHosts = $null,
        [int]$MaxHosts = 16
    )

    $hosts = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in (@($TriggerHost) + @($PortalRecoveryHosts))) {
        $hostName = Normalize-NativeHostCaptivePortalTriggerHost -Value $candidate
        if (-not $hostName) { continue }
        if ($hostName -match '^\d{1,3}(?:\.\d{1,3}){3}$' -or $hostName -match '^\[[0-9a-f:]+\]$') { continue }
        if ($hostName.EndsWith('.local', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $hostName.Contains('.')) { continue }
        if ($hosts.Contains($hostName)) { continue }
        if ($hosts.Count -ge $MaxHosts) { break }
        $hosts.Add($hostName)
    }

    return @($hosts)
}

function Get-NativeHostCaptivePortalActiveMarker {
    <#
    .SYNOPSIS
    Reads the captive portal active marker file and returns its payload when the marker is valid and unexpired.
    .DESCRIPTION
    File read+parse delegates to the shared Read-OpenPathCaptivePortalStateJson
    (CaptivePortal.StateFiles.ps1). The active/expiry filtering and the
    Path/LastWriteTimeUtc annotation are native-host semantics and stay here.
    #>
    $markerPath = 'C:\OpenPath\data\captive-portal-active.json'
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $markerPath = Join-Path (Join-Path $script:OpenPathRoot 'data') 'captive-portal-active.json'
    }

    $payload = Read-OpenPathCaptivePortalStateJson -Path $markerPath
    if (-not $payload) {
        return $null
    }

    try {
        if ($payload.PSObject.Properties['active'] -and -not [bool]$payload.active) {
            return $null
        }
        if (-not $payload.PSObject.Properties['expiresAt'] -or -not $payload.expiresAt) {
            return $null
        }
        $expiresAtRaw = $payload.expiresAt
        $expiresAt = if ($expiresAtRaw -is [DateTime]) {
            $expiresAtRaw.ToUniversalTime()
        } else {
            [DateTime]::Parse([string]$expiresAtRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
        if ([DateTime]::UtcNow -ge $expiresAt) {
            return $null
        }
        $payload | Add-Member -NotePropertyName Path -NotePropertyValue $markerPath -Force
        $payload | Add-Member -NotePropertyName LastWriteTimeUtc -NotePropertyValue (Get-Item $markerPath).LastWriteTimeUtc -Force
        return $payload
    }
    catch {
        return $null
    }
}

function Get-NativeHostCaptivePortalMarkerSummary {
    <#
    .SYNOPSIS
    Builds a summary of the active captive portal marker using the shared transition marker helper.
    #>
    param(
        [AllowNull()][object]$Marker,
        [string]$TriggerHost = ''
    )

    return (Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary `
            -Marker $Marker `
            -TriggerHost $TriggerHost `
            -ConfiguredCaptivePortalDomains @(Get-NativeHostConfiguredCaptivePortalDomains) `
            -EffectiveHostResolver { param([string[]]$Hosts) @(Get-NativeHostCaptivePortalEffectiveHosts -Hosts $Hosts) } `
            -ConfiguredDomainsAppliedTester { param([string[]]$AllowedHosts, [string[]]$ConfiguredCaptivePortalDomains) Test-NativeHostConfiguredCaptivePortalDomainsApplied -AllowedHosts $AllowedHosts -ConfiguredCaptivePortalDomains $ConfiguredCaptivePortalDomains })
}

function Get-NativeHostRecentCaptivePortalRecoverySuccess {
    <#
    .SYNOPSIS
    Returns a recent captive portal recovery success record from either an active marker or a result file.
    .DESCRIPTION
    First checks whether the active marker was written within the recency window and returns a summary
    built from it. If no active marker qualifies, scans the recovery result directory for a result file
    written within the window. Returns null when neither source provides a qualifying record.
    #>
    param([int]$RecentSuccessSeconds = 30)

    $activeMarker = Get-NativeHostCaptivePortalActiveMarker
    if ($activeMarker -and $activeMarker.PSObject.Properties['LastWriteTimeUtc']) {
        $markerAgeSeconds = ([DateTime]::UtcNow - $activeMarker.LastWriteTimeUtc).TotalSeconds
        if ($markerAgeSeconds -le [Math]::Max(1, $RecentSuccessSeconds)) {
            $markerSummary = Get-NativeHostCaptivePortalMarkerSummary -Marker $activeMarker
            return [PSCustomObject]@{
                Source = 'active-marker'
                RequestId = ''
                State = if ($activeMarker.PSObject.Properties['state']) { [string]$activeMarker.state } else { 'Portal' }
                PortalModeActive = $true
                Marker = $activeMarker
                ActiveMarkerMode = [string]$markerSummary.activeMarkerMode
                AllowedHosts = @($markerSummary.allowedHosts)
                EffectiveExactHosts = @($markerSummary.effectiveExactHosts)
                ConfiguredCaptivePortalDomains = @($markerSummary.configuredCaptivePortalDomains)
                ConfiguredCaptivePortalDomainsApplied = [bool]$markerSummary.configuredCaptivePortalDomainsApplied
                BootstrapHosts = @($markerSummary.bootstrapHosts)
                RedirectHosts = @($markerSummary.redirectHosts)
                ResourceHosts = @($markerSummary.resourceHosts)
                ObservedRuntimeHosts = @($markerSummary.observedRuntimeHosts)
                PendingRuntimeHosts = @($markerSummary.pendingRuntimeHosts)
                DiscoveryTruncated = [bool]$markerSummary.discoveryTruncated
                FallbackMode = [string]$markerSummary.fallbackMode
                LimitedModeReady = [bool]$markerSummary.limitedModeReady
                RecoveryHostsApplied = [bool]$markerSummary.recoveryHostsApplied
                RecentSuccessEligible = [bool]$markerSummary.recentSuccessEligible
                Path = if ($activeMarker.PSObject.Properties['Path']) { [string]$activeMarker.Path } else { '' }
                LastWriteTimeUtc = $activeMarker.LastWriteTimeUtc
            }
        }
    }

    $resultRoot = Get-NativeHostCaptivePortalRecoveryResultPath
    if (-not (Test-Path $resultRoot -ErrorAction SilentlyContinue)) {
        return $null
    }

    $cutoffUtc = [DateTime]::UtcNow.AddSeconds(-1 * [Math]::Max(1, $RecentSuccessSeconds))
    $recentResultFile = Get-ChildItem -Path $resultRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $cutoffUtc } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $recentResultFile) {
        return $null
    }

    try {
        $payload = Get-Content -Path $recentResultFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $state = if ($payload.PSObject.Properties['state'] -and $payload.state) { [string]$payload.state } else { 'Unknown' }
        $portalModeActive = if ($payload.PSObject.Properties['portalModeActive']) { [bool]$payload.portalModeActive } else { $false }
        $success = if ($payload.PSObject.Properties['success']) { [bool]$payload.success } else { $false }
        if (-not ($success -and ($portalModeActive -or $state -in @('Portal', 'RecentSuccess')))) {
            return $null
        }

        return [PSCustomObject]@{
            Source = 'result'
            RequestId = if ($payload.PSObject.Properties['requestId']) { [string]$payload.requestId } else { '' }
            State = $state
            PortalModeActive = $true
            ActiveMarkerMode = if ($payload.PSObject.Properties['activeMarkerMode']) { [string]$payload.activeMarkerMode } else { '' }
            AllowedHosts = if ($payload.PSObject.Properties['allowedHosts']) { @($payload.allowedHosts) } else { @() }
            EffectiveExactHosts = if ($payload.PSObject.Properties['effectiveExactHosts']) { @($payload.effectiveExactHosts) } elseif ($payload.PSObject.Properties['allowedHosts']) { @(Get-NativeHostCaptivePortalEffectiveHosts -Hosts (@($payload.allowedHosts) + @(Get-NativeHostConfiguredCaptivePortalDomains))) } else { @(Get-NativeHostConfiguredCaptivePortalDomains) }
            ConfiguredCaptivePortalDomains = if ($payload.PSObject.Properties['configuredCaptivePortalDomains']) { @($payload.configuredCaptivePortalDomains) } else { @(Get-NativeHostConfiguredCaptivePortalDomains) }
            ConfiguredCaptivePortalDomainsApplied = if ($payload.PSObject.Properties['configuredCaptivePortalDomainsApplied']) { [bool]$payload.configuredCaptivePortalDomainsApplied } else { Test-NativeHostConfiguredCaptivePortalDomainsApplied -AllowedHosts $(if ($payload.PSObject.Properties['allowedHosts']) { @($payload.allowedHosts) } else { @() }) -ConfiguredCaptivePortalDomains @(Get-NativeHostConfiguredCaptivePortalDomains) }
            BootstrapHosts = if ($payload.PSObject.Properties['bootstrapHosts']) { @($payload.bootstrapHosts) } else { @() }
            RedirectHosts = if ($payload.PSObject.Properties['redirectHosts']) { @($payload.redirectHosts) } else { @() }
            ResourceHosts = if ($payload.PSObject.Properties['resourceHosts']) { @($payload.resourceHosts) } else { @() }
            ObservedRuntimeHosts = if ($payload.PSObject.Properties['observedRuntimeHosts']) { @($payload.observedRuntimeHosts) } else { @() }
            PendingRuntimeHosts = if ($payload.PSObject.Properties['pendingRuntimeHosts']) { @($payload.pendingRuntimeHosts) } else { @() }
            DiscoveryTruncated = if ($payload.PSObject.Properties['discoveryTruncated']) { [bool]$payload.discoveryTruncated } else { $false }
            FallbackMode = if ($payload.PSObject.Properties['fallbackMode']) { [string]$payload.fallbackMode } else { 'none' }
            LimitedModeReady = if ($payload.PSObject.Properties['limitedModeReady']) { [bool]$payload.limitedModeReady } else { $false }
            RecoveryHostsApplied = if ($payload.PSObject.Properties['recoveryHostsApplied']) { [bool]$payload.recoveryHostsApplied } else { $false }
            RecentSuccessEligible = if ($payload.PSObject.Properties['recentSuccessEligible']) { [bool]$payload.recentSuccessEligible } else { $false }
            Payload = $payload
            Path = $recentResultFile.FullName
            LastWriteTimeUtc = $recentResultFile.LastWriteTimeUtc
        }
    }
    catch {
        return $null
    }
}

function Test-NativeHostRecentCaptivePortalSuccessEligible {
    <#
    .SYNOPSIS
    Returns true when a recent captive portal success record qualifies for reuse with the given trigger host.
    #>
    param(
        [AllowNull()][object]$RecentSuccess,
        [string]$TriggerHost = ''
    )

    if (-not $RecentSuccess) {
        return $false
    }

    return (Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess `
            -RecentSuccess $RecentSuccess `
            -TriggerHost $TriggerHost `
            -ConfiguredCaptivePortalDomains @(Get-NativeHostConfiguredCaptivePortalDomains) `
            -ConfiguredDomainsAppliedTester { param([string[]]$AllowedHosts, [string[]]$ConfiguredCaptivePortalDomains) Test-NativeHostConfiguredCaptivePortalDomainsApplied -AllowedHosts $AllowedHosts -ConfiguredCaptivePortalDomains $ConfiguredCaptivePortalDomains })
}

function Invoke-NativeHostCaptivePortalRecoveryAction {
    <#
    .SYNOPSIS
    Orchestrates a captive portal recovery or reconcile operation via the scheduled recovery task.
    .DESCRIPTION
    Dispatches an open or reconcile operation. For open operations with a qualifying recent success,
    returns immediately without triggering the task. Otherwise writes a recovery request, triggers
    the scheduled task, and waits for the result envelope. Returns a structured response with
    portal state, timing, and health diagnostics.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [int]$TimeoutSeconds = 90
    )

    $action = 'recover-captive-portal-navigation'
    $taskName = 'OpenPath-CaptivePortalRecovery'
    $boundedTimeoutSeconds = [Math]::Max(1, [Math]::Min(90, $TimeoutSeconds))
    $operation = 'open'
    if ($Message.PSObject.Properties['operation'] -and $Message.operation) {
        $candidateOperation = ([string]$Message.operation).Trim().ToLowerInvariant()
        if ($candidateOperation -in @('open', 'reconcile')) {
            $operation = $candidateOperation
        }
    }
    $portalState = if ($Message.PSObject.Properties['portalState'] -and $Message.portalState) { [string]$Message.portalState } else { 'Unknown' }
    $source = if ($Message.PSObject.Properties['source'] -and $Message.source) { [string]$Message.source } else { 'native-host' }
    $triggerHost = ''
    if ($Message.PSObject.Properties['triggerHost'] -and $Message.triggerHost) {
        $triggerHost = Normalize-NativeHostCaptivePortalTriggerHost -Value $Message.triggerHost
    }
    $requestedPortalRecoveryHosts = if ($Message.PSObject.Properties['portalRecoveryHosts']) { $Message.portalRecoveryHosts } else { @() }
    $portalRecoveryHosts = Get-NativeHostCaptivePortalRecoveryHosts `
        -TriggerHost $triggerHost `
        -PortalRecoveryHosts $requestedPortalRecoveryHosts

    if ($operation -eq 'open' -and -not $triggerHost) {
        return @{
            success = $false
            action = $action
            state = 'InvalidHost'
            portalModeActive = $false
            triggerHost = ''
            requestId = ''
            taskName = $taskName
            triggerMs = 0
            waitMs = 0
            error = 'Invalid captive portal trigger host'
        }
    }

    $recentSuccess = if ($operation -eq 'open') { Get-NativeHostRecentCaptivePortalRecoverySuccess } else { $null }
    if ($recentSuccess -and (Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $recentSuccess -TriggerHost $triggerHost)) {
            return @{
                success = $true
                action = $action
                operation = $operation
                state = 'RecentSuccess'
                portalModeActive = $true
                triggerHost = $triggerHost
                requestId = [string]$recentSuccess.RequestId
                taskName = $taskName
                triggerMs = 0
                waitMs = 0
                recentSuccess = $true
                recentSuccessSource = [string]$recentSuccess.Source
                recentSuccessEligible = if ($recentSuccess.PSObject.Properties['RecentSuccessEligible']) { [bool]$recentSuccess.RecentSuccessEligible } else { $false }
                activeMarkerMode = if ($recentSuccess.PSObject.Properties['ActiveMarkerMode']) { [string]$recentSuccess.ActiveMarkerMode } else { '' }
                allowedHosts = if ($recentSuccess.PSObject.Properties['AllowedHosts']) { @($recentSuccess.AllowedHosts) } else { @() }
                effectiveExactHosts = if ($recentSuccess.PSObject.Properties['EffectiveExactHosts']) { @($recentSuccess.EffectiveExactHosts) } elseif ($recentSuccess.PSObject.Properties['AllowedHosts']) { @($recentSuccess.AllowedHosts) } else { @() }
                configuredCaptivePortalDomains = if ($recentSuccess.PSObject.Properties['ConfiguredCaptivePortalDomains']) { @($recentSuccess.ConfiguredCaptivePortalDomains) } else { @(Get-NativeHostConfiguredCaptivePortalDomains) }
                configuredCaptivePortalDomainsApplied = if ($recentSuccess.PSObject.Properties['ConfiguredCaptivePortalDomainsApplied']) { [bool]$recentSuccess.ConfiguredCaptivePortalDomainsApplied } else { Test-NativeHostConfiguredCaptivePortalDomainsApplied -AllowedHosts $(if ($recentSuccess.PSObject.Properties['AllowedHosts']) { @($recentSuccess.AllowedHosts) } else { @() }) -ConfiguredCaptivePortalDomains @(Get-NativeHostConfiguredCaptivePortalDomains) }
                portalRecoveryHosts = if ($recentSuccess.PSObject.Properties['PortalRecoveryHosts']) { @($recentSuccess.PortalRecoveryHosts) } else { @($portalRecoveryHosts) }
                bootstrapHosts = if ($recentSuccess.PSObject.Properties['BootstrapHosts']) { @($recentSuccess.BootstrapHosts) } else { @() }
                redirectHosts = if ($recentSuccess.PSObject.Properties['RedirectHosts']) { @($recentSuccess.RedirectHosts) } else { @() }
                resourceHosts = if ($recentSuccess.PSObject.Properties['ResourceHosts']) { @($recentSuccess.ResourceHosts) } else { @() }
                observedRuntimeHosts = if ($recentSuccess.PSObject.Properties['ObservedRuntimeHosts']) { @($recentSuccess.ObservedRuntimeHosts) } else { @() }
                pendingRuntimeHosts = if ($recentSuccess.PSObject.Properties['PendingRuntimeHosts']) { @($recentSuccess.PendingRuntimeHosts) } else { @() }
                discoveryTruncated = if ($recentSuccess.PSObject.Properties['DiscoveryTruncated']) { [bool]$recentSuccess.DiscoveryTruncated } else { $false }
                fallbackMode = if ($recentSuccess.PSObject.Properties['FallbackMode']) { [string]$recentSuccess.FallbackMode } else { 'none' }
                limitedModeReady = if ($recentSuccess.PSObject.Properties['LimitedModeReady']) { [bool]$recentSuccess.LimitedModeReady } else { $false }
                recoveryHostsApplied = if ($recentSuccess.PSObject.Properties['RecoveryHostsApplied']) { [bool]$recentSuccess.RecoveryHostsApplied } else { $false }
            }
    }

    $requestId = [Guid]::NewGuid().ToString('N')
    $tabId = $null
    if ($Message.PSObject.Properties['tabId']) {
        $tabId = $Message.tabId
    }

    $null = Write-NativeHostCaptivePortalRecoveryRequest `
        -RequestId $requestId `
        -TriggerHost $triggerHost `
        -PortalRecoveryHosts $portalRecoveryHosts `
        -Operation $operation `
        -PortalState $portalState `
        -Source $source `
        -TabId $tabId

    try {
        $taskResult = Invoke-NativeHostMutex `
            -Name 'Global\OpenPathCaptivePortalRecoveryTrigger' `
            -TimeoutMilliseconds ($boundedTimeoutSeconds * 1000) `
            -Action {
                Invoke-OpenPathScheduledTask `
                    -TaskName $taskName `
                    -Runner (Get-NativeHostTaskRunner) `
                    -TimeoutSeconds $boundedTimeoutSeconds `
                    -PollMilliseconds 250 `
                    -WaitCondition {
                        return ($null -ne (Read-NativeHostCaptivePortalRecoveryResultEnvelope -RequestId $requestId).Result)
                    }
            }
    }
    catch {
        $response = @{
            success = $false
            action = $action
            operation = $operation
            state = 'TriggerFailed'
            portalModeActive = $false
            triggerHost = $triggerHost
            requestId = $requestId
            taskName = $taskName
            triggerMs = 0
            waitMs = 0
            error = [string]$_
        }
        return (Add-NativeHostCaptivePortalRecoveryDiagnostics -Response $response)
    }

    $taskNameResult = if ($taskResult.ContainsKey('taskName') -and $taskResult.taskName) { [string]$taskResult.taskName } else { $taskName }
    $triggerMs = if ($taskResult.ContainsKey('triggerMs')) { [int]$taskResult.triggerMs } else { 0 }
    $waitMs = if ($taskResult.ContainsKey('waitMs')) { [int]$taskResult.waitMs } else { 0 }

    $resultEnvelope = Read-NativeHostCaptivePortalRecoveryResultEnvelope -RequestId $requestId
    $result = $resultEnvelope.Result
    if (-not $result) {
        $queueClassification = Get-NativeHostCaptivePortalRecoveryQueueClassification `
            -ReadClassification ([string]$resultEnvelope.Classification) `
            -TaskResult $taskResult `
            -Operation $operation
        $response = @{
            success = $false
            action = $action
            operation = $operation
            state = 'Timeout'
            portalModeActive = $false
            triggerHost = $triggerHost
            requestId = $requestId
            taskName = $taskNameResult
            triggerMs = $triggerMs
            waitMs = $waitMs
            recoveryQueueClassification = $queueClassification
            error = if ($taskResult.ContainsKey('error') -and $taskResult.error) { [string]$taskResult.error } else { 'Timed out waiting for captive portal recovery result' }
        }
        return (Add-NativeHostCaptivePortalRecoveryDiagnostics -Response $response -TaskResult $taskResult)
    }

    $state = if ($result.PSObject.Properties['state'] -and $result.state) { [string]$result.state } else { 'Unknown' }
    $portalModeActive = if ($result.PSObject.Properties['portalModeActive']) { [bool]$result.portalModeActive } else { $false }
    $resultSuccess = if ($result.PSObject.Properties['success']) { [bool]$result.success } else { $false }
    $protectedModeRestored = if ($result.PSObject.Properties['protectedModeRestored']) { [bool]$result.protectedModeRestored } else { $false }
    $allowedHosts = if ($result.PSObject.Properties['allowedHosts']) {
        @($result.allowedHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        @()
    }
    $resultPortalRecoveryHosts = if ($result.PSObject.Properties['portalRecoveryHosts']) {
        @($result.portalRecoveryHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        @($portalRecoveryHosts)
    }
    $effectiveExactHosts = if ($result.PSObject.Properties['effectiveExactHosts']) {
        @($result.effectiveExactHosts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        @(Get-NativeHostCaptivePortalEffectiveHosts -Hosts (@($allowedHosts) + @(Get-NativeHostConfiguredCaptivePortalDomains)))
    }
    $configuredCaptivePortalDomains = if ($result.PSObject.Properties['configuredCaptivePortalDomains']) {
        @($result.configuredCaptivePortalDomains | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        @(Get-NativeHostConfiguredCaptivePortalDomains)
    }
    $configuredCaptivePortalDomainsApplied = if ($result.PSObject.Properties['configuredCaptivePortalDomainsApplied']) {
        [bool]$result.configuredCaptivePortalDomainsApplied
    }
    else {
        Test-NativeHostConfiguredCaptivePortalDomainsApplied -AllowedHosts $allowedHosts -ConfiguredCaptivePortalDomains $configuredCaptivePortalDomains
    }
    $recoveryHostsApplied = if ($result.PSObject.Properties['recoveryHostsApplied']) { [bool]$result.recoveryHostsApplied } else { $false }
    $limitedModeReady = if ($result.PSObject.Properties['limitedModeReady']) { [bool]$result.limitedModeReady } else { $false }
    $exactRecoveryHostApplied = $recoveryHostsApplied
    if ($triggerHost) {
        $exactRecoveryHostApplied = ($exactRecoveryHostApplied -and ($allowedHosts -contains $triggerHost))
    }
    $localDnsLoopbackRestored = if ($result.PSObject.Properties['localDnsLoopbackRestored']) { [bool]$result.localDnsLoopbackRestored } else { $false }
    $acrylicNormalRestored = if ($result.PSObject.Properties['acrylicNormalRestored']) { [bool]$result.acrylicNormalRestored } else { $false }
    $dnsResolutionHealthy = if ($result.PSObject.Properties['dnsResolutionHealthy']) { [bool]$result.dnsResolutionHealthy } else { $false }
    $sinkholeHealthy = if ($result.PSObject.Properties['sinkholeHealthy']) { [bool]$result.sinkholeHealthy } else { $false }
    $firewallExpectedActive = if ($result.PSObject.Properties['firewallExpectedActive']) { [bool]$result.firewallExpectedActive } else { $false }
    $firewallHealthy = if ($result.PSObject.Properties['firewallHealthy']) { [bool]$result.firewallHealthy } else { $false }
    $markerCleared = if ($result.PSObject.Properties['markerCleared']) { [bool]$result.markerCleared } else { $false }
    $postAuthRestored = (
        $protectedModeRestored -and
        $localDnsLoopbackRestored -and
        $acrylicNormalRestored -and
        $dnsResolutionHealthy -and
        $sinkholeHealthy -and
        ((-not $firewallExpectedActive) -or $firewallHealthy) -and
        $markerCleared
    )
    $operationSucceeded = if ($operation -eq 'reconcile') {
        ($resultSuccess -and $state -eq 'Authenticated' -and -not $portalModeActive -and $postAuthRestored)
    }
    else {
        ($resultSuccess -and (
            ($state -eq 'Portal' -and $portalModeActive -and $exactRecoveryHostApplied -and $limitedModeReady -and $configuredCaptivePortalDomainsApplied) -or
            ($state -eq 'Authenticated' -and -not $portalModeActive -and $postAuthRestored)
        ))
    }
    $queueClassification = Get-NativeHostCaptivePortalRecoveryQueueClassification `
        -ReadClassification ([string]$resultEnvelope.Classification) `
        -TaskResult $taskResult `
        -Result $result `
        -Operation $operation `
        -OperationSucceeded ([bool]$operationSucceeded)

    return @{
        success = $operationSucceeded
        action = $action
        operation = $operation
        state = $state
        portalModeActive = $portalModeActive
        triggerHost = $triggerHost
        requestId = $requestId
        taskName = $taskNameResult
        triggerMs = $triggerMs
        waitMs = $waitMs
        recoveryQueueClassification = $queueClassification
        portalExitRoute = if ($result.PSObject.Properties['portalExitRoute']) { [string]$result.portalExitRoute } else { '' }
        localDnsLoopbackRestored = $localDnsLoopbackRestored
        acrylicNormalRestored = $acrylicNormalRestored
        dnsResolutionHealthy = $dnsResolutionHealthy
        sinkholeHealthy = $sinkholeHealthy
        firewallExpectedActive = $firewallExpectedActive
        firewallHealthy = $firewallHealthy
        markerCleared = $markerCleared
        protectedModeRestored = $protectedModeRestored
        activeMarkerMode = if ($result.PSObject.Properties['activeMarkerMode']) { [string]$result.activeMarkerMode } else { '' }
        allowedHosts = @($allowedHosts)
        effectiveExactHosts = @($effectiveExactHosts)
        configuredCaptivePortalDomains = @($configuredCaptivePortalDomains)
        configuredCaptivePortalDomainsApplied = [bool]$configuredCaptivePortalDomainsApplied
        portalRecoveryHosts = @($resultPortalRecoveryHosts)
        bootstrapHosts = if ($result.PSObject.Properties['bootstrapHosts']) { @($result.bootstrapHosts) } else { @() }
        redirectHosts = if ($result.PSObject.Properties['redirectHosts']) { @($result.redirectHosts) } else { @() }
        resourceHosts = if ($result.PSObject.Properties['resourceHosts']) { @($result.resourceHosts) } else { @() }
        observedRuntimeHosts = if ($result.PSObject.Properties['observedRuntimeHosts']) { @($result.observedRuntimeHosts) } else { @() }
        pendingRuntimeHosts = if ($result.PSObject.Properties['pendingRuntimeHosts']) { @($result.pendingRuntimeHosts) } else { @() }
        discoveryTruncated = if ($result.PSObject.Properties['discoveryTruncated']) { [bool]$result.discoveryTruncated } else { $false }
        fallbackMode = if ($result.PSObject.Properties['fallbackMode']) { [string]$result.fallbackMode } else { 'none' }
        limitedModeReady = $limitedModeReady
        recoveryHostsApplied = $recoveryHostsApplied
        recentSuccessEligible = if ($result.PSObject.Properties['recentSuccessEligible']) { [bool]$result.recentSuccessEligible } else { $false }
    }
}

function Get-NativeHostCaptivePortalObservation {
    <#
    .SYNOPSIS
    Reads the captive portal observation JSON file, returning null when absent or unparseable.
    #>
    $observationPath = 'C:\OpenPath\data\captive-portal-observation.json'
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $observationPath = Join-Path (Join-Path $script:OpenPathRoot 'data') 'captive-portal-observation.json'
    }

    return (Read-OpenPathCaptivePortalStateJson -Path $observationPath)
}

function Test-NativeHostCaptivePortalObservationRecent {
    <#
    .SYNOPSIS
    Returns true when the observation record shows a Portal state detected within the maximum age window.
    #>
    param(
        [object]$Observation,
        [int]$MaxAgeSeconds = 120
    )

    if (-not $Observation -or -not $Observation.PSObject.Properties['detectedState'] -or [string]$Observation.detectedState -ne 'Portal') {
        return $false
    }

    $timestamp = $null
    foreach ($propertyName in @('updatedAt', 'observedAt', 'detectedAt')) {
        $property = $Observation.PSObject.Properties[$propertyName]
        if ($property -and $property.Value) {
            try {
                $tsRaw = $property.Value
                $timestamp = if ($tsRaw -is [DateTime]) {
                    $tsRaw.ToUniversalTime()
                } else {
                    [DateTime]::Parse([string]$tsRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                }
                break
            }
            catch {
                $timestamp = $null
            }
        }
    }

    if (-not $timestamp) {
        return $false
    }

    return (([DateTime]::UtcNow - $timestamp).TotalSeconds -le [Math]::Max(1, $MaxAgeSeconds))
}

function Test-NativeHostRecoverablePortalError {
    <#
    .SYNOPSIS
    Returns true when the error name is a known recoverable captive portal network error code.
    #>
    param([string]$ErrorName)

    return $ErrorName -in @(
        'NS_ERROR_UNKNOWN_HOST',
        'NS_ERROR_CONNECTION_REFUSED',
        'NS_ERROR_NET_TIMEOUT'
    )
}

function Invoke-NativeHostCaptivePortalSyncProbe {
    <#
    .SYNOPSIS
    Probes the current portal state and returns a signal string, with per-domain cooldown to limit probe frequency.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [int]$CooldownSeconds = 15
    )

    $cacheKey = $Domain.Trim().ToLowerInvariant()
    $now = [DateTime]::UtcNow
    if ($script:NativeHostPortalProbeCache.ContainsKey($cacheKey)) {
        $cached = $script:NativeHostPortalProbeCache[$cacheKey]
        if ($cached -and $cached.PSObject.Properties['ProbedAt'] -and (($now - $cached.ProbedAt).TotalSeconds -lt [Math]::Max(1, $CooldownSeconds))) {
            return [string]$cached.Signal
        }
    }

    $signal = 'none'
    try {
        if ((Test-OpenPathCaptivePortalState -TimeoutSec 2) -eq 'Portal') {
            $signal = 'sync-probe'
        }
    }
    catch {
        $signal = 'none'
    }

    $script:NativeHostPortalProbeCache[$cacheKey] = [PSCustomObject]@{
        ProbedAt = $now
        Signal = $signal
    }
    return $signal
}

function Get-NativeHostPortalRecoverySignal {
    <#
    .SYNOPSIS
    Returns the strongest available portal signal for a domain from the marker, observation, or a live probe.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][object]$Message
    )

    $marker = Get-NativeHostCaptivePortalActiveMarker
    if ($marker) {
        return 'marker'
    }

    $observation = Get-NativeHostCaptivePortalObservation
    if (Test-NativeHostCaptivePortalObservationRecent -Observation $observation) {
        return 'observation'
    }

    if ($Message.PSObject.Properties['portalState'] -and [string]$Message.portalState -eq 'locked_portal') {
        return 'firefox-locked'
    }

    $errorName = if ($Message.PSObject.Properties['error']) { [string]$Message.error } else { '' }
    $source = if ($Message.PSObject.Properties['source']) { [string]$Message.source } else { '' }
    if (
        $source -eq 'blocked-screen-navigation' -and
        (Test-NativeHostRecoverablePortalError -ErrorName $errorName) -and
        (Get-Command -Name 'Test-OpenPathCaptivePortalState' -ErrorAction SilentlyContinue)
    ) {
        return (Invoke-NativeHostCaptivePortalSyncProbe -Domain $Domain)
    }

    return 'none'
}

function Invoke-NativeHostAuthenticatedCaptivePortalRestoreIfNeeded {
    <#
    .SYNOPSIS
    Triggers a reconcile recovery operation when an active marker and authenticated portal state are detected.
    .DESCRIPTION
    Runs at most once per cooldown window per process lifetime. Exits silently when no marker is active,
    when the probe command is unavailable, or when the portal state is not authenticated.
    #>
    param([int]$CooldownSeconds = 15)

    $marker = Get-NativeHostCaptivePortalActiveMarker
    if (-not $marker) {
        return
    }

    $now = [DateTime]::UtcNow
    $cacheKey = 'authenticated-marker-restore'
    if ($script:NativeHostPortalProbeCache.ContainsKey($cacheKey)) {
        $cached = $script:NativeHostPortalProbeCache[$cacheKey]
        if ($cached -and $cached.PSObject.Properties['ProbedAt'] -and (($now - $cached.ProbedAt).TotalSeconds -lt [Math]::Max(1, $CooldownSeconds))) {
            return
        }
    }

    $script:NativeHostPortalProbeCache[$cacheKey] = [PSCustomObject]@{
        ProbedAt = $now
        Signal = 'restore-probe'
    }

    if (-not (Get-Command -Name 'Test-OpenPathCaptivePortalState' -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        if ((Test-OpenPathCaptivePortalState -TimeoutSec 2) -ne 'Authenticated') {
            return
        }

        Invoke-NativeHostCaptivePortalRecoveryAction `
            -Message ([PSCustomObject]@{
                operation = 'reconcile'
                portalState = 'authenticated'
                source = 'native-host-check'
            }) `
            -TimeoutSeconds 8 | Out-Null
    }
    catch {
        return
    }
}
