function Import-NativeHostRequestSetupStateModule {
    if (Get-Command -Name 'Get-OpenPathRequestSetupState' -ErrorAction SilentlyContinue) {
        return
    }

    $candidatePaths = @()
    if (Get-Variable -Name NativeRoot -Scope Script -ErrorAction SilentlyContinue) {
        $candidatePaths += (Join-Path $script:NativeRoot 'RequestSetup.State.psm1')
    }
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $candidatePaths += (Join-Path $script:OpenPathRoot 'lib\RequestSetup.State.psm1')
    }
    if ($PSScriptRoot) {
        $candidatePaths += (Join-Path $PSScriptRoot 'RequestSetup.State.psm1')
        $candidatePaths += (Join-Path (Split-Path $PSScriptRoot -Parent) 'RequestSetup.State.psm1')
    }

    foreach ($candidatePath in ($candidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $candidatePath -ErrorAction SilentlyContinue) {
            Import-Module $candidatePath -Force -ErrorAction Stop
            return
        }
    }

    throw 'RequestSetup.State.psm1 is required for native host request setup interpretation.'
}

Import-NativeHostRequestSetupStateModule

function Get-NativeHostValidDomains {
    param(
        [AllowNull()]
        [object[]]$Domains = @()
    )

    return @($Domains) |
        Where-Object { $_ -is [string] } |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { $_ -match '^[a-z0-9.-]+$' } |
        Select-Object -First $script:MaxDomains
}

function Get-NativeHostRuntimeDependencyQueuePath {
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH) {
        return $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH
    }

    return (Join-Path $script:OpenPathRoot 'data\runtime-dependency-queue')
}

function Get-NativeHostRuntimeDependencySettings {
    $ttlDays = 7
    $capacity = 300
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) {
        try { $ttlDays = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS) } catch { $ttlDays = 7 }
    }
    if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) {
        try { $capacity = [Math]::Max(1, [int]$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY) } catch { $capacity = 300 }
    }

    return [PSCustomObject]@{
        TtlDays = $ttlDays
        Capacity = $capacity
    }
}

function Normalize-NativeHostRuntimeDependencyHost {
    param([AllowNull()][object]$Value)

    if (-not ($Value -is [string])) { return '' }
    $normalized = ([string]$Value).Trim().Trim('.').ToLowerInvariant()
    if (-not $normalized) { return '' }
    if ($normalized.EndsWith('.local', [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    if ($normalized.Length -lt 4 -or $normalized.Length -gt 253) { return '' }
    if ($normalized -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$') { return '' }
    return $normalized
}

function Test-NativeHostBlockedSubdomainMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string[]]$BlockedSubdomains = @()
    )

    foreach ($blockedSubdomain in @($BlockedSubdomains)) {
        $blocked = Normalize-NativeHostRuntimeDependencyHost -Value $blockedSubdomain
        if (-not $blocked) { continue }
        if ($Domain.Equals($blocked, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Domain.EndsWith(".$blocked", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    return $false
}

function Test-NativeHostWhitelistCoversHost {
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [System.Collections.Generic.HashSet[string]]$WhitelistSet
    )

    if (-not $Hostname -or -not $WhitelistSet) { return $false }
    if ($WhitelistSet.Contains($Hostname)) { return $true }

    foreach ($whitelistedDomain in $WhitelistSet) {
        if (-not $whitelistedDomain) { continue }
        if ($Hostname.EndsWith(".$whitelistedDomain", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-NativeHostProtectedRuntimeDependencyHosts {
    param([Parameter(Mandatory = $true)][PSCustomObject]$State)

    $hosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($protectedHost in @(
            'raw.githubusercontent.com',
            'github.com',
            'githubusercontent.com',
            'api.github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
            'sourceforge.net',
            'downloads.sourceforge.net',
            'detectportal.firefox.com',
            'connectivity-check.ubuntu.com',
            'captive.apple.com',
            'www.msftconnecttest.com',
            'msftconnecttest.com',
            'clients3.google.com',
            'windowsupdate.microsoft.com',
            'update.microsoft.com',
            'time.windows.com',
            'time.google.com'
        )) {
        $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $protectedHost
        if ($normalized) { [void]$hosts.Add($normalized) }
    }

    foreach ($propertyName in @('apiUrl', 'requestApiUrl', 'whitelistUrl')) {
        if (-not $State.PSObject.Properties[$propertyName]) { continue }
        try {
            $uri = [System.Uri]([string]$State.$propertyName)
            $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $uri.Host
            if ($normalized) { [void]$hosts.Add($normalized) }
        }
        catch { }
    }

    return $hosts
}

function Test-NativeHostSensitiveRuntimeDependencyField {
    param([Parameter(Mandatory = $true)][object]$Message)

    $blockedFields = @(
        'url',
        'resourceUrl',
        'target_url',
        'targetUrl',
        'originUrl',
        'documentUrl',
        'pageUrl',
        'headers',
        'body',
        'path',
        'query',
        'dom',
        'title',
        'resources'
    )

    foreach ($field in $blockedFields) {
        if ($Message.PSObject.Properties[$field]) {
            return $true
        }
    }

    return $false
}

function Find-NativeHostRuntimeDependencyQueueRequest {
    param(
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost,
        [Parameter(Mandatory = $true)][string]$RequestType,
        [Parameter(Mandatory = $true)][string]$QueuePath
    )

    if (-not (Test-Path $QueuePath -ErrorAction SilentlyContinue)) {
        return ''
    }

    foreach ($requestFile in @(Get-ChildItem -Path $QueuePath -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)) {
        try {
            $request = Get-Content $requestFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $queuedAnchor = Normalize-NativeHostRuntimeDependencyHost -Value $request.anchorHost
            $queuedDependency = Normalize-NativeHostRuntimeDependencyHost -Value $request.dependencyHost
            $queuedRequestType = if ($request.requestType -is [string]) { ([string]$request.requestType).Trim().ToLowerInvariant() } else { '' }

            if ($queuedAnchor -eq $AnchorHost -and $queuedDependency -eq $DependencyHost -and $queuedRequestType -eq $RequestType) {
                return $requestFile.FullName
            }
        }
        catch {
            continue
        }
    }

    return ''
}

function Write-NativeHostRuntimeDependencyQueueRequest {
    param(
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost,
        [Parameter(Mandatory = $true)][string]$RequestType
    )

    $queuePath = Get-NativeHostRuntimeDependencyQueuePath
    if (-not (Test-Path $queuePath -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $queuePath -Force | Out-Null
    }

    $existingRequestPath = Find-NativeHostRuntimeDependencyQueueRequest `
        -AnchorHost $AnchorHost `
        -DependencyHost $DependencyHost `
        -RequestType $RequestType `
        -QueuePath $queuePath
    if ($existingRequestPath) {
        return $existingRequestPath
    }

    $requestId = [Guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $queuePath "$requestId.json"
    @{
        version = 1
        queuedAt = (Get-Date).ToUniversalTime().ToString('o')
        anchorHost = $AnchorHost
        dependencyHost = $DependencyHost
        requestType = $RequestType
        source = 'firefox-webrequest-local'
    } | ConvertTo-Json -Depth 6 | Set-Content $requestPath -Encoding UTF8 -Force

    return $requestPath
}

function Test-NativeHostRuntimeDependencyOverlayContainsDomains {
    param([string[]]$Domains = @())

    if (@($Domains).Count -eq 0) {
        return $true
    }

    $path = if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH) {
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
    }
    else {
        Join-Path $script:OpenPathRoot 'data\runtime-dependency-overlay.json'
    }
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $entryHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($parsed.entries)) {
            if ($entry.PSObject.Properties['dependencyHost'] -and $entry.dependencyHost) {
                [void]$entryHosts.Add(([string]$entry.dependencyHost).Trim().Trim('.').ToLowerInvariant())
            }
        }

        foreach ($domain in @($Domains)) {
            $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $domain
            if (-not $normalized -or -not $entryHosts.Contains($normalized)) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-NativeHostLog "Failed to inspect runtime dependency overlay: $_"
        return $false
    }
}

function Test-NativeHostRuntimeDependencyQueueRequestProcessed {
    param([AllowNull()][string]$RequestPath = '')

    if ([string]::IsNullOrWhiteSpace($RequestPath)) {
        return $true
    }

    return -not (Test-Path $RequestPath -ErrorAction SilentlyContinue)
}

function Invoke-NativeHostMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$TimeoutMilliseconds = 15000
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $Name)
        try { $lockAcquired = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [System.Threading.AbandonedMutexException] { $lockAcquired = $true }
        if (-not $lockAcquired) {
            throw "Timed out waiting for $Name"
        }
        return (& $Action)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try { $mutex.ReleaseMutex() } catch [System.ApplicationException] { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Import-NativeHostDnsModule {
    $dnsModulePath = Join-Path $script:OpenPathRoot 'lib\DNS.psm1'
    if (Test-Path $dnsModulePath -ErrorAction SilentlyContinue) {
        Import-Module $dnsModulePath -Force -ErrorAction Stop
    }
}

function Resolve-NativeHostLocalRuntimeDependencyCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    if (Test-NativeHostSensitiveRuntimeDependencyField -Message $Message) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Sensitive fields are not accepted' }
        }
    }

    $anchorHost = Normalize-NativeHostRuntimeDependencyHost -Value $Message.anchorHost
    $dependencyHost = Normalize-NativeHostRuntimeDependencyHost -Value $Message.dependencyHost
    $requestType = if ($Message.requestType -is [string]) { ([string]$Message.requestType).Trim().ToLowerInvariant() } else { '' }

    if (-not $anchorHost -or -not $dependencyHost -or -not $requestType) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Invalid runtime dependency payload' }
        }
    }
    if ($requestType -eq 'main_frame') {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'main_frame dependencies are not supported' }
        }
    }
    if ($anchorHost -eq $dependencyHost) {
        return @{
            Valid = $false
            Result = @{ success = $true; action = 'allow-local-runtime-dependency'; skipped = $true; reason = 'same-host' }
        }
    }

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($Sections.Whitelist)) {
        $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $domain
        if ($normalized) { [void]$whitelistSet.Add($normalized) }
    }
    if (-not (Test-NativeHostWhitelistCoversHost -Hostname $anchorHost -WhitelistSet $whitelistSet)) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Anchor host is not locally whitelisted' }
        }
    }

    $protectedHosts = Get-NativeHostProtectedRuntimeDependencyHosts -State $State
    if ($protectedHosts.Contains($anchorHost) -or $protectedHosts.Contains($dependencyHost)) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Protected hosts are not accepted as runtime dependencies' }
        }
    }
    if (Test-NativeHostBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains @($Sections.BlockedSubdomains)) {
        return @{
            Valid = $false
            Result = @{ success = $false; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; error = 'Blocked hosts are not accepted as runtime dependencies' }
        }
    }
    if (Test-NativeHostWhitelistCoversHost -Hostname $dependencyHost -WhitelistSet $whitelistSet) {
        return @{
            Valid = $false
            Result = @{ success = $true; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; skipped = $true; reason = 'dependency-already-whitelisted' }
        }
    }
    if (Test-NativeHostRuntimeDependencyOverlayContainsDomains -Domains @($dependencyHost)) {
        return @{
            Valid = $false
            Result = @{ success = $true; action = 'allow-local-runtime-dependency'; anchorHost = $anchorHost; dependencyHost = $dependencyHost; requestType = $requestType; skipped = $true; reason = 'runtime-dependency-overlay-present' }
        }
    }

    return @{
        Valid = $true
        AnchorHost = $anchorHost
        DependencyHost = $dependencyHost
        RequestType = $requestType
    }
}

function Invoke-NativeHostLocalRuntimeDependencyAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $Message -State $State -Sections $Sections
    if ($candidate.Valid -ne $true) {
        return $candidate.Result
    }

    $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $requestPath = Write-NativeHostRuntimeDependencyQueueRequest `
        -AnchorHost $candidate.AnchorHost `
        -DependencyHost $candidate.DependencyHost `
        -RequestType $candidate.RequestType
    $queueWriteStopwatch.Stop()

    $updateResult = Invoke-UpdateTask `
        -RuntimeDependencyDomains @($candidate.DependencyHost) `
        -RuntimeDependencyRequestPath $requestPath `
        -TimeoutSeconds 14
    if ($updateResult.success -ne $true) {
        return @{
            success = $false
            action = 'allow-local-runtime-dependency'
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
            error = $updateResult.error
        }
    }

    return @{
        success = $true
        action = 'allow-local-runtime-dependency'
        anchorHost = $candidate.AnchorHost
        dependencyHost = $candidate.DependencyHost
        requestType = $candidate.RequestType
        queued = $true
        requestPath = $requestPath
        queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
        updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        source = 'firefox-webrequest-local'
    }
}

function Invoke-NativeHostLocalRuntimeDependencyBatchAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $entries = @($Message.entries)
    if ($entries.Count -eq 0) {
        return @{ success = $false; action = 'allow-local-runtime-dependency-batch'; error = 'Invalid runtime dependency batch payload'; results = @() }
    }

    $results = @()
    $queuedResults = @()
    $queuedDependencyHosts = @()
    $updateResult = $null

    foreach ($entry in @($entries | Select-Object -First 20)) {
        $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate -Message $entry -State $State -Sections $Sections
        if ($candidate.Valid -ne $true) {
            $results += $candidate.Result
            continue
        }

        $queueWriteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $requestPath = Write-NativeHostRuntimeDependencyQueueRequest `
            -AnchorHost $candidate.AnchorHost `
            -DependencyHost $candidate.DependencyHost `
            -RequestType $candidate.RequestType
        $queueWriteStopwatch.Stop()
        $result = @{
            success = $true
            action = 'allow-local-runtime-dependency'
            anchorHost = $candidate.AnchorHost
            dependencyHost = $candidate.DependencyHost
            requestType = $candidate.RequestType
            queued = $true
            requestPath = $requestPath
            queueWriteMs = [int]$queueWriteStopwatch.ElapsedMilliseconds
            source = 'firefox-webrequest-local'
        }
        $results += $result
        $queuedResults += $result
        $queuedDependencyHosts += $candidate.DependencyHost
    }

    if ($entries.Count -gt 20) {
        $results += @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Runtime dependency batch limit exceeded' }
    }

    if ($queuedDependencyHosts.Count -gt 0) {
        $queuedDependencyHosts = @($queuedDependencyHosts | Sort-Object -Unique)
        $updateResult = Invoke-UpdateTask `
            -RuntimeDependencyDomains $queuedDependencyHosts `
            -TimeoutSeconds 14
        if ($updateResult.success -ne $true) {
            foreach ($result in $queuedResults) {
                $result.success = $false
                $result.error = $updateResult.error
            }
        }
        foreach ($result in $queuedResults) {
            $result.updateTriggerMs = if ($updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
            $result.updateWaitMs = if ($updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
            $result.updateElapsedMs = if ($updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
            $result.runtimeDependencyFastPath = if ($updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
            $result.runtimeDependencyFallback = if ($updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
            $result.updateTaskName = if ($updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        }
    }

    $failedResults = @($results | Where-Object { $_.success -ne $true })
    return @{
        success = ($failedResults.Count -eq 0)
        action = 'allow-local-runtime-dependency-batch'
        count = $results.Count
        queuedCount = $queuedResults.Count
        queueWriteMs = [int](@($queuedResults | ForEach-Object { if ($_.ContainsKey('queueWriteMs')) { [int]$_.queueWriteMs } else { 0 } } | Measure-Object -Sum).Sum)
        updateTriggerMs = if ($updateResult -and $updateResult.ContainsKey('updateTriggerMs')) { [int]$updateResult.updateTriggerMs } else { 0 }
        updateWaitMs = if ($updateResult -and $updateResult.ContainsKey('updateWaitMs')) { [int]$updateResult.updateWaitMs } else { 0 }
        updateElapsedMs = if ($updateResult -and $updateResult.ContainsKey('elapsedMs')) { [int]$updateResult.elapsedMs } else { 0 }
        runtimeDependencyFastPath = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFastPath')) { [bool]$updateResult.runtimeDependencyFastPath } else { $false }
        runtimeDependencyFallback = if ($updateResult -and $updateResult.ContainsKey('runtimeDependencyFallback')) { [bool]$updateResult.runtimeDependencyFallback } else { $false }
        updateTaskName = if ($updateResult -and $updateResult.ContainsKey('updateTaskName')) { [string]$updateResult.updateTaskName } else { '' }
        results = $results
    }
}

function Test-NativeWhitelistContainsDomains {
    param(
        [string[]]$Domains = @()
    )

    if (@($Domains).Count -eq 0) {
        return $true
    }

    $sections = Get-WhitelistSections
    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($sections.Whitelist)) {
        if ($domain) {
            $null = $whitelistSet.Add([string]$domain)
        }
    }

    foreach ($domain in @($Domains)) {
        if (-not $whitelistSet.Contains($domain)) {
            return $false
        }
    }

    return $true
}

function Format-NativeHostActionLogValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = ([string]$Value).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
    $text = $text -replace '/w/[^/\s]+/whitelist\.txt', '/w/[redacted]/whitelist.txt'
    $text = $text -replace '(?i)(token=)[^&\s]+', '$1[redacted]'
    $text = $text -replace '\s+', ' '
    if ($text.Length -gt 240) {
        return $text.Substring(0, 240)
    }

    return $text
}

function Write-NativeHostActionLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string[]]$Domains = @(),
        [bool]$Success = $false,
        [AllowNull()]
        [string]$Message = '',
        [AllowNull()]
        [string]$ErrorMessage = '',
        [long]$ElapsedMs = 0,
        [hashtable]$ExtraFields = @{}
    )

    try {
        if (-not (Get-Command Write-NativeHostLog -ErrorAction SilentlyContinue)) {
            return
        }

        $safeDomains = @(Get-NativeHostValidDomains -Domains $Domains)
        $fields = @(
            "action=$Action",
            "success=$($Success -eq $true)",
            "elapsedMs=$ElapsedMs",
            "domains=$($safeDomains -join ',')"
        )
        if ($Message) {
            $fields += "message=$(Format-NativeHostActionLogValue -Value $Message)"
        }
        if ($ErrorMessage) {
            $fields += "error=$(Format-NativeHostActionLogValue -Value $ErrorMessage)"
        }
        foreach ($key in @($ExtraFields.Keys | Sort-Object)) {
            if ($key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { continue }
            $value = $ExtraFields[$key]
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
            $fields += "$key=$(Format-NativeHostActionLogValue -Value $value)"
        }

        Write-NativeHostLog ("Native host {0}" -f ($fields -join ' '))
    }
    catch {
        return
    }
}

function Invoke-NativeHostSharedUpdateTrigger {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$TriggerAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$WaitAction
    )

    $mutex = $null
    $lockAcquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\OpenPathNativeWhitelistUpdateTrigger')
        try {
            $lockAcquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if ($lockAcquired) {
            $triggerResult = & $TriggerAction
            if (
                $triggerResult -is [System.Collections.IDictionary] -and
                $triggerResult.ContainsKey('success') -and
                $triggerResult.success -ne $true
            ) {
                return $triggerResult
            }
        }

        return (& $WaitAction)
    }
    finally {
        if ($lockAcquired -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # Ignore if mutex ownership was already released by the runtime.
            }
        }

        if ($mutex) {
            $mutex.Dispose()
        }
    }
}

function Invoke-UpdateTask {
    param(
        [string[]]$Domains = @(),
        [string[]]$RuntimeDependencyDomains = @(),
        [AllowNull()][string]$RuntimeDependencyRequestPath = '',
        [int]$TimeoutSeconds = 45
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $hasRuntimeDependencyWait = @($RuntimeDependencyDomains).Count -gt 0
        if ((-not $hasRuntimeDependencyWait) -and (Test-NativeWhitelistContainsDomains -Domains $Domains)) {
            $result = @{
                success = $true
                action = 'update-whitelist'
                message = 'OpenPath update task triggered'
                domains = @($Domains)
            }
        }
        else {
            $triggeredTaskName = if (
                $hasRuntimeDependencyWait -and
                (Get-Variable -Name RuntimeDependencyTaskName -Scope Script -ErrorAction SilentlyContinue) -and
                -not [string]::IsNullOrWhiteSpace($script:RuntimeDependencyTaskName)
            ) {
                [string]$script:RuntimeDependencyTaskName
            }
            else {
                [string]$script:UpdateTaskName
            }
            $triggerState = @{
                TaskName = $triggeredTaskName
                Fallback = $false
                TriggerMs = 0
            }
            $result = Invoke-NativeHostSharedUpdateTrigger `
                -TriggerAction {
                    $triggerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $null = & schtasks.exe /Run /TN $triggerState['TaskName'] 2>$null
                    $triggerExitCode = $LASTEXITCODE
                    if ($triggerExitCode -ne 0 -and $hasRuntimeDependencyWait -and $triggerState['TaskName'] -ne $script:UpdateTaskName) {
                        $triggerState['Fallback'] = $true
                        $null = & schtasks.exe /Run /TN $script:UpdateTaskName 2>$null
                        $triggerExitCode = $LASTEXITCODE
                        $triggerState['TaskName'] = [string]$script:UpdateTaskName
                    }
                    $triggerStopwatch.Stop()
                    $triggerState['TriggerMs'] = [int]$triggerStopwatch.ElapsedMilliseconds

                    if ($triggerExitCode -ne 0) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = "schtasks exit code $triggerExitCode"
                            domains = @($Domains)
                            runtimeDependencyFastPath = $hasRuntimeDependencyWait
                            runtimeDependencyFallback = [bool]$triggerState['Fallback']
                            updateTaskName = [string]$triggerState['TaskName']
                            updateTriggerMs = [int]$triggerState['TriggerMs']
                        }
                    }

                    return @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task triggered'
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$triggerState['Fallback']
                        updateTaskName = [string]$triggerState['TaskName']
                        updateTriggerMs = [int]$triggerState['TriggerMs']
                    }
                } `
                -WaitAction {
                    $waitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                    while ((Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 1000
                        $whitelistReady = Test-NativeWhitelistContainsDomains -Domains $Domains
                        $runtimeDependencyReady = (
                            (Test-NativeHostRuntimeDependencyQueueRequestProcessed -RequestPath $RuntimeDependencyRequestPath) -and
                            (
                                -not [string]::IsNullOrWhiteSpace($RuntimeDependencyRequestPath) -or
                                (Test-NativeHostRuntimeDependencyOverlayContainsDomains -Domains $RuntimeDependencyDomains)
                            )
                        )
                        if ($whitelistReady -and $runtimeDependencyReady) {
                            $waitStopwatch.Stop()
                            return @{
                                success = $true
                                action = 'update-whitelist'
                                message = 'OpenPath update task wrote expected domains'
                                domains = @($Domains)
                                runtimeDependencyFastPath = $hasRuntimeDependencyWait
                                runtimeDependencyFallback = [bool]$triggerState['Fallback']
                                updateTaskName = [string]$triggerState['TaskName']
                                updateTriggerMs = [int]$triggerState['TriggerMs']
                                updateWaitMs = [int]$waitStopwatch.ElapsedMilliseconds
                            }
                        }
                    }

                    $waitStopwatch.Stop()
                    return @{
                        success = $false
                        action = 'update-whitelist'
                        error = "OpenPath update task did not write expected domains: $(@($Domains + $RuntimeDependencyDomains) -join ', ')"
                        domains = @($Domains)
                        runtimeDependencyFastPath = $hasRuntimeDependencyWait
                        runtimeDependencyFallback = [bool]$triggerState['Fallback']
                        updateTaskName = [string]$triggerState['TaskName']
                        updateTriggerMs = [int]$triggerState['TriggerMs']
                        updateWaitMs = [int]$waitStopwatch.ElapsedMilliseconds
                    }
                }
        }
    }
    catch {
        $result = @{
            success = $false
            action = 'update-whitelist'
            error = [string]$_
            domains = @($Domains)
        }
    }

    $stopwatch.Stop()
    $logMessage = ''
    if ($result.ContainsKey('message')) {
        $logMessage = [string]$result.message
    }
    $logError = ''
    if ($result.ContainsKey('error')) {
        $logError = [string]$result.error
    }

    Write-NativeHostActionLog -Action 'update-whitelist' `
        -Domains $Domains `
        -Success ($result.success -eq $true) `
        -Message $logMessage `
        -ErrorMessage $logError `
        -ElapsedMs $stopwatch.ElapsedMilliseconds

    $result['elapsedMs'] = [int]$stopwatch.ElapsedMilliseconds
    return $result
}

function Get-NativeHostMachineName {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    if ($State.PSObject.Properties['machineName'] -and $State.machineName) {
        return [string]$State.machineName
    }

    return [string]$env:COMPUTERNAME
}

function Get-NativeHostApiUrl {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    $requestSetupState = Get-OpenPathRequestSetupState -Config $State
    return [string]$requestSetupState.RequestApiUrl
}

function Get-NativeHostMachineToken {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    $requestSetupState = Get-OpenPathRequestSetupState -Config $State
    return [string]$requestSetupState.MachineToken
}

function Get-NativeHostBlockedPathResponse {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $paths = @($Sections.BlockedPaths)
    $digest = ''
    if ($paths.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($paths -join "`n"))
            $digest = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }

    $mtime = 0
    if (Test-Path $script:WhitelistPath) {
        $whitelistItem = Get-Item $script:WhitelistPath
        $mtime = [int]([DateTimeOffset]$whitelistItem.LastWriteTimeUtc).ToUnixTimeSeconds()
    }

    return @{
        success = $true
        action = 'get-blocked-paths'
        paths = $paths
        count = $paths.Count
        hash = $digest
        mtime = $mtime
        source = $script:WhitelistPath
    }
}

function Get-NativeHostBlockedSubdomainResponse {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $subdomains = @($Sections.BlockedSubdomains)
    $digest = ''
    if ($subdomains.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($subdomains -join "`n"))
            $digest = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }

    $mtime = 0
    if (Test-Path $script:WhitelistPath) {
        $whitelistItem = Get-Item $script:WhitelistPath
        $mtime = [int]([DateTimeOffset]$whitelistItem.LastWriteTimeUtc).ToUnixTimeSeconds()
    }

    return @{
        success = $true
        action = 'get-blocked-subdomains'
        subdomains = $subdomains
        count = $subdomains.Count
        hash = $digest
        mtime = $mtime
        source = $script:WhitelistPath
    }
}

function Invoke-NativeHostCheckAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $validDomains = Get-NativeHostValidDomains -Domains @($Message.domains)

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($Sections.Whitelist)) {
        if ($domain) {
            $null = $whitelistSet.Add([string]$domain)
        }
    }

    $results = foreach ($domain in $validDomains) {
        @{
            domain = $domain
            in_whitelist = $whitelistSet.Contains($domain)
            resolved_ip = (Resolve-DomainIp -Domain $domain)
        }
    }

    return @{
        success = $true
        action = 'check'
        results = @($results)
    }
}

function Invoke-NativeHostMessageAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [object]$Sections,

        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    switch ($Action) {
        'ping' {
            return @{
                success = $true
                action = 'ping'
                message = 'pong'
                version = if ($State.PSObject.Properties['version']) { [string]$State.version } else { '' }
            }
        }

        'get-hostname' {
            return @{
                success = $true
                action = 'get-hostname'
                hostname = (Get-NativeHostMachineName -State $State)
            }
        }

        'get-machine-token' {
            $token = Get-NativeHostMachineToken -State $State
            if (-not $token) {
                return @{
                    success = $false
                    action = 'get-machine-token'
                    error = 'Machine token not available'
                }
            }

            return @{
                success = $true
                action = 'get-machine-token'
                token = $token
            }
        }

        'get-config' {
            $requestSetupState = Get-OpenPathRequestSetupState -Config $State
            $apiUrl = [string]$requestSetupState.RequestApiUrl

            if (-not $apiUrl) {
                return @{
                    success = $false
                    action = 'get-config'
                    error = 'API URL is not configured'
                }
            }

            return @{
                success = $true
                action = 'get-config'
                apiUrl = $apiUrl
                requestApiUrl = $apiUrl
                fallbackApiUrls = @()
                hostname = (Get-NativeHostMachineName -State $State)
                machineToken = [string]$requestSetupState.MachineToken
                whitelistUrl = [string]$requestSetupState.WhitelistUrl
            }
        }

        'get-blocked-paths' {
            return (Get-NativeHostBlockedPathResponse -Sections $sections)
        }

        'get-blocked-subdomains' {
            return (Get-NativeHostBlockedSubdomainResponse -Sections $sections)
        }

        'check' {
            return (Invoke-NativeHostCheckAction -Message $Message -Sections $sections)
        }

        'update-whitelist' {
            $domains = Get-NativeHostValidDomains -Domains @($Message.domains)
            return (Invoke-UpdateTask -Domains $domains)
        }

        'allow-local-runtime-dependency' {
            return (Invoke-NativeHostLocalRuntimeDependencyAction -Message $Message -State $State -Sections $sections)
        }

        'allow-local-runtime-dependency-batch' {
            return (Invoke-NativeHostLocalRuntimeDependencyBatchAction -Message $Message -State $State -Sections $sections)
        }

        default {
            return @{
                success = $false
                error = "Unknown action: $action"
            }
        }
    }
}

function Handle-Message {
    param(
        [AllowNull()]
        [object]$Message
    )

    if (-not ($Message -is [System.Collections.IDictionary]) -and -not $Message.PSObject) {
        return @{ success = $false; error = 'Invalid message format' }
    }

    $state = Read-NativeState
    $sections = Get-WhitelistSections
    $action = [string]$Message.action
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null

    try {
        $result = Invoke-NativeHostMessageAction -Message $Message -State $state -Sections $sections -Action $action
    }
    catch {
        $result = @{
            success = $false
            action = $action
            error = [string]$_
        }
    }
    finally {
        $stopwatch.Stop()
    }

    if ($action -ne 'update-whitelist') {
        $logMessage = ''
        if ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('message')) {
            $logMessage = [string]$result.message
        }
        $logError = ''
        if ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('error')) {
            $logError = [string]$result.error
        }
        $domains = @()
        if ($action -eq 'check') {
            $domains = @(Get-NativeHostValidDomains -Domains @($Message.domains))
        }
        elseif ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('dependencyHost')) {
            $domains = @(Get-NativeHostValidDomains -Domains @($result.dependencyHost))
        }
        elseif ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('results')) {
            $domains = @(Get-NativeHostValidDomains -Domains @($result.results | ForEach-Object { $_.dependencyHost }))
        }

        $extraFields = @{}
        if ($result -is [System.Collections.IDictionary]) {
            foreach ($key in @(
                    'queueWriteMs',
                    'updateTriggerMs',
                    'updateWaitMs',
                    'updateElapsedMs',
                    'runtimeDependencyFastPath',
                    'runtimeDependencyFallback',
                    'updateTaskName'
                )) {
                if ($result.ContainsKey($key)) {
                    $extraFields[$key] = $result[$key]
                }
            }
        }

        Write-NativeHostActionLog -Action $action `
            -Domains $domains `
            -Success ($result.success -eq $true) `
            -Message $logMessage `
            -ErrorMessage $logError `
            -ElapsedMs $stopwatch.ElapsedMilliseconds `
            -ExtraFields $extraFields
    }

    return $result
}
