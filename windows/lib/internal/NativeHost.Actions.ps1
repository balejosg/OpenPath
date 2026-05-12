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

function Get-NativeHostRuntimeDependencyOverlayPath {
    return (Join-Path $script:OpenPathRoot 'data\runtime-dependency-overlay.json')
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

function Read-NativeHostRuntimeDependencyOverlay {
    $path = Get-NativeHostRuntimeDependencyOverlayPath
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return @($parsed.entries)
    }
    catch {
        Write-NativeHostLog "Failed to read runtime dependency overlay: $_"
        return @()
    }
}

function Write-NativeHostRuntimeDependencyOverlay {
    param([object[]]$Entries = @())

    $path = Get-NativeHostRuntimeDependencyOverlayPath
    $directory = Split-Path $path -Parent
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $payload = @{
        version = 1
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        entries = @($Entries)
    } | ConvertTo-Json -Depth 8

    $tempPath = "$path.tmp"
    $payload | Set-Content $tempPath -Encoding UTF8 -Force
    Move-Item $tempPath $path -Force
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

function Invoke-NativeHostLocalRuntimeDependencyAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    if (Test-NativeHostSensitiveRuntimeDependencyField -Message $Message) {
        return @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Sensitive fields are not accepted' }
    }

    $anchorHost = Normalize-NativeHostRuntimeDependencyHost -Value $Message.anchorHost
    $dependencyHost = Normalize-NativeHostRuntimeDependencyHost -Value $Message.dependencyHost
    $requestType = if ($Message.requestType -is [string]) { ([string]$Message.requestType).Trim().ToLowerInvariant() } else { '' }

    if (-not $anchorHost -or -not $dependencyHost -or -not $requestType) {
        return @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Invalid runtime dependency payload' }
    }
    if ($requestType -eq 'main_frame') {
        return @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'main_frame dependencies are not supported' }
    }
    if ($anchorHost -eq $dependencyHost) {
        return @{ success = $true; action = 'allow-local-runtime-dependency'; skipped = $true; reason = 'same-host' }
    }

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @($Sections.Whitelist)) {
        $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $domain
        if ($normalized) { [void]$whitelistSet.Add($normalized) }
    }
    if (-not (Test-NativeHostWhitelistCoversHost -Hostname $anchorHost -WhitelistSet $whitelistSet)) {
        return @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Anchor host is not locally approved' }
    }

    $protectedHosts = Get-NativeHostProtectedRuntimeDependencyHosts -State $State
    if ($protectedHosts.Contains($anchorHost) -or $protectedHosts.Contains($dependencyHost)) {
        return @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Protected hosts are not eligible for runtime dependencies' }
    }
    if (Test-NativeHostBlockedSubdomainMatch -Domain $dependencyHost -BlockedSubdomains @($Sections.BlockedSubdomains)) {
        return @{ success = $false; action = 'allow-local-runtime-dependency'; error = 'Dependency host is explicitly blocked' }
    }

    $settings = Get-NativeHostRuntimeDependencySettings

    return Invoke-NativeHostMutex -Name 'Global\OpenPathUpdateLock' -Action {
        Invoke-NativeHostMutex -Name 'Global\OpenPathPolicyStateLock' -Action {
            $now = (Get-Date).ToUniversalTime()
            $expiresAt = $now.AddDays($settings.TtlDays)
            $entries = @(Read-NativeHostRuntimeDependencyOverlay)
            $keptEntries = @()
            $updated = $false

            foreach ($entry in $entries) {
                $entryDependency = if ($entry.PSObject.Properties['dependencyHost']) { Normalize-NativeHostRuntimeDependencyHost -Value $entry.dependencyHost } else { '' }
                $entryAnchor = if ($entry.PSObject.Properties['anchorHost']) { Normalize-NativeHostRuntimeDependencyHost -Value $entry.anchorHost } else { '' }
                $entryExpiresAt = if ($entry.PSObject.Properties['expiresAt']) { [string]$entry.expiresAt } else { '' }
                $isExpired = $false
                if ($entryExpiresAt) {
                    try { $isExpired = ([DateTimeOffset]::Parse($entryExpiresAt).UtcDateTime -le $now) }
                    catch { $isExpired = $true }
                }

                if (
                    -not $entryDependency -or
                    -not $entryAnchor -or
                    $isExpired -or
                    -not (Test-NativeHostWhitelistCoversHost -Hostname $entryAnchor -WhitelistSet $whitelistSet) -or
                    $protectedHosts.Contains($entryDependency) -or
                    (Test-NativeHostBlockedSubdomainMatch -Domain $entryDependency -BlockedSubdomains @($Sections.BlockedSubdomains))
                ) {
                    continue
                }

                if ($entryDependency -eq $dependencyHost -and $entryAnchor -eq $anchorHost) {
                    $requestTypes = @($entry.requestTypes)
                    if ($requestTypes -notcontains $requestType) {
                        $requestTypes += $requestType
                    }
                    $entry.lastSeen = $now.ToString('o')
                    $entry.expiresAt = $expiresAt.ToString('o')
                    $entry.requestTypes = @($requestTypes | Sort-Object -Unique)
                    $updated = $true
                }

                $keptEntries += $entry
            }

            if (-not $updated) {
                $keptEntries += [PSCustomObject]@{
                    dependencyHost = $dependencyHost
                    anchorHost = $anchorHost
                    requestTypes = @($requestType)
                    firstSeen = $now.ToString('o')
                    lastSeen = $now.ToString('o')
                    expiresAt = $expiresAt.ToString('o')
                    source = 'firefox-webrequest-local'
                }
            }

            $keptEntries = @(
                $keptEntries |
                    Sort-Object @{ Expression = { if ($_.PSObject.Properties['lastSeen']) { [string]$_.lastSeen } else { '' } }; Descending = $true } |
                    Select-Object -First $settings.Capacity
            )

            Write-NativeHostRuntimeDependencyOverlay -Entries $keptEntries
            Import-NativeHostDnsModule
            if (Get-Command -Name 'Update-AcrylicHost' -ErrorAction SilentlyContinue) {
                Update-AcrylicHost -WhitelistedDomains @($Sections.Whitelist) -BlockedSubdomains @($Sections.BlockedSubdomains) | Out-Null
            }

            return @{
                success = $true
                action = 'allow-local-runtime-dependency'
                anchorHost = $anchorHost
                dependencyHost = $dependencyHost
                requestType = $requestType
                expiresAt = $expiresAt.ToString('o')
                source = 'firefox-webrequest-local'
            }
        }
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
        [long]$ElapsedMs = 0
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
        [int]$TimeoutSeconds = 45
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        if (Test-NativeWhitelistContainsDomains -Domains $Domains) {
            $result = @{
                success = $true
                action = 'update-whitelist'
                message = 'OpenPath update task triggered'
                domains = @($Domains)
            }
        }
        else {
            $result = Invoke-NativeHostSharedUpdateTrigger `
                -TriggerAction {
                    $null = & schtasks.exe /Run /TN $script:UpdateTaskName 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        return @{
                            success = $false
                            action = 'update-whitelist'
                            error = "schtasks exit code $LASTEXITCODE"
                            domains = @($Domains)
                        }
                    }

                    return @{
                        success = $true
                        action = 'update-whitelist'
                        message = 'OpenPath update task triggered'
                        domains = @($Domains)
                    }
                } `
                -WaitAction {
                    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                    while ((Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 1000
                        if (Test-NativeWhitelistContainsDomains -Domains $Domains) {
                            return @{
                                success = $true
                                action = 'update-whitelist'
                                message = 'OpenPath update task wrote expected domains'
                                domains = @($Domains)
                            }
                        }
                    }

                    return @{
                        success = $false
                        action = 'update-whitelist'
                        error = "OpenPath update task did not write expected domains: $(@($Domains) -join ', ')"
                        domains = @($Domains)
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

        Write-NativeHostActionLog -Action $action `
            -Domains $domains `
            -Success ($result.success -eq $true) `
            -Message $logMessage `
            -ErrorMessage $logError `
            -ElapsedMs $stopwatch.ElapsedMilliseconds
    }

    return $result
}
