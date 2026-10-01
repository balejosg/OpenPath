function Get-NativeHostValidDomains {
    <#
    .SYNOPSIS
    Filters a domain list to lowercase ASCII-safe hostnames, capped at a configurable maximum count.
    #>
    param(
        [AllowNull()]
        [object[]]$Domains = @()
    )

    $maxDomains = 200
    if ($script:MaxDomains) {
        try { $maxDomains = [Math]::Max(1, [int]$script:MaxDomains) } catch { $maxDomains = 200 }
    }

    return @($Domains) |
        Where-Object { $_ -is [string] } |
        ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } |
        Where-Object { $_ -match '^[a-z0-9.-]+$' } |
        Select-Object -First $maxDomains
}

function Get-NativeHostPolicyDecision {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][PSCustomObject]$Sections,
        [AllowNull()][PSCustomObject]$State = $null
    )

    $known = -not $Sections.PSObject.Properties['PolicyKnown'] -or $Sections.PolicyKnown -eq $true
    $version = if ($Sections.PSObject.Properties['PolicyVersion']) { [string]$Sections.PolicyVersion } else { 'legacy-snapshot' }
    if (-not $known -or -not $version) {
        return [PSCustomObject]@{ Decision = 'unknown'; Reason = 'policy-unavailable'; Active = $null; InWhitelist = $false; Version = '' }
    }

    $disabled = $Sections.PSObject.Properties['IsDisabled'] -and $Sections.IsDisabled -eq $true
    if ($disabled) {
        return [PSCustomObject]@{ Decision = 'allowed'; Reason = 'policy-inactive'; Active = $false; InWhitelist = $true; Version = $version }
    }

    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Sections.Whitelist)) {
        $normalized = Normalize-NativeHostRuntimeDependencyHost -Value $entry
        if ($normalized) { [void]$whitelistSet.Add($normalized) }
    }
    $protected = Get-OpenPathRuntimeDependencyProtectedHosts -State $State
    if (Test-OpenPathProtectedRuntimeDependencyHost -Hostname $Domain -ProtectedHosts $protected) {
        return [PSCustomObject]@{ Decision = 'allowed'; Reason = 'protected-infrastructure'; Active = $true; InWhitelist = $true; Version = $version }
    }
    if (Test-NativeHostBlockedSubdomainMatch -Domain $Domain -BlockedSubdomains @($Sections.BlockedSubdomains)) {
        return [PSCustomObject]@{ Decision = 'blocked'; Reason = 'blocked-subdomain'; Active = $true; InWhitelist = $false; Version = $version }
    }
    if (Test-NativeHostWhitelistCoversHost -Hostname $Domain -WhitelistSet $whitelistSet) {
        return [PSCustomObject]@{ Decision = 'allowed'; Reason = 'whitelist-domain'; Active = $true; InWhitelist = $true; Version = $version }
    }
    foreach ($dependency in @($(if ($State -and $State.PSObject.Properties['runtimeDependencyDomains']) { $State.runtimeDependencyDomains }))) {
        if ($Domain -eq (Normalize-NativeHostRuntimeDependencyHost -Value $dependency)) {
            return [PSCustomObject]@{ Decision = 'allowed'; Reason = 'runtime-dependency-exact'; Active = $true; InWhitelist = $true; Version = $version }
        }
    }
    foreach ($portal in @($(if ($State -and $State.PSObject.Properties['captivePortalDomains']) { $State.captivePortalDomains }))) {
        $normalizedPortal = Normalize-NativeHostRuntimeDependencyHost -Value $portal
        if ($normalizedPortal -and ($Domain -eq $normalizedPortal -or $Domain.EndsWith(".$normalizedPortal", [System.StringComparison]::OrdinalIgnoreCase))) {
            return [PSCustomObject]@{ Decision = 'allowed'; Reason = 'captive-portal-domain'; Active = $true; InWhitelist = $true; Version = $version }
        }
    }
    return [PSCustomObject]@{ Decision = 'blocked'; Reason = 'default-deny'; Active = $true; InWhitelist = $false; Version = $version }
}
function Normalize-NativeHostRuntimeDependencyHost {
    <#
    .SYNOPSIS
    Normalizes a runtime dependency host value using the shared OpenPath normalization helper.
    #>
    param([AllowNull()][object]$Value)

    return (Normalize-OpenPathRuntimeDependencyHost -Value $Value)
}
function Normalize-NativeHostCaptivePortalTriggerHost {
    <#
    .SYNOPSIS
    Normalizes a captive portal trigger host value using the runtime dependency host normalizer.
    #>
    param([AllowNull()][object]$Value)

    return (Normalize-NativeHostRuntimeDependencyHost -Value $Value)
}
function Test-NativeHostBlockedSubdomainMatch {
    <#
    .SYNOPSIS
    Returns true when a domain matches any entry in the blocked subdomains list.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string[]]$BlockedSubdomains = @()
    )

    foreach ($blockedSubdomain in @($BlockedSubdomains)) {
        if (Test-OpenPathBlockedSubdomainMatch -Domain $Domain -BlockedSubdomains @($blockedSubdomain)) { return $true }
    }

    return $false
}
function Test-NativeHostWhitelistCoversHost {
    <#
    .SYNOPSIS
    Returns true when the whitelist set covers the specified hostname via the shared coverage helper.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [System.Collections.Generic.HashSet[string]]$WhitelistSet
    )

    return (Test-OpenPathWhitelistCoversHost -Hostname $Hostname -WhitelistSet $WhitelistSet)
}
function Invoke-NativeHostMutex {
    <#
    .SYNOPSIS
    Acquires a named mutex, executes an action block, and releases the mutex in a finally block.
    .DESCRIPTION
    Throws when the mutex cannot be acquired within the timeout. Handles abandoned mutex exceptions
    by treating them as a successful acquisition.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        # bounds the wait for the named system mutex before throwing a timeout error.
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
    <#
    .SYNOPSIS
    Loads the DNS module from the OpenPath root when it is present on disk.
    #>
    $dnsModulePath = Join-Path $script:OpenPathRoot 'lib\DNS.psm1'
    if (Test-Path $dnsModulePath -ErrorAction SilentlyContinue) {
        Import-Module $dnsModulePath -Force -ErrorAction Stop
    }
}
function Get-NativeHostTaskRunner {
    <#
    .SYNOPSIS
    Returns a schtasks runner object used to trigger and wait on scheduled tasks.
    #>
    if (-not (Get-Command -Name 'New-OpenPathSchtasksRunner' -ErrorAction SilentlyContinue)) {
        Initialize-NativeHostTaskRunnerSupport
    }
    return (New-OpenPathSchtasksRunner)
}
function Test-NativeWhitelistContainsDomains {
    <#
    .SYNOPSIS
    Returns true when all supplied domains are present in the current native whitelist mirror.
    #>
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
    <#
    .SYNOPSIS
    Sanitizes and truncates a value for safe inclusion in a native host action log entry.
    #>
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = ([string]$Value).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
    $text = ConvertTo-OpenPathRedactedValue -Value $text
    $text = $text -replace '\s+', ' '
    if ($text.Length -gt 240) {
        return $text.Substring(0, 240)
    }

    return $text
}
# Phase 2C: capabilities, the retirement switch and chatty-action log policy.
$script:NativeHostChattyActionStats = @{}
$script:NativeHostDependencyReadyState = @{}
$script:NativeHostChattyActions = @(
    'check-local-runtime-dependency',
    'get-policy-version',
    'get-blocked-paths',
    'get-blocked-subdomains',
    'get-allowed-paths',
    'report-extension-diagnostics'
)

function Test-NativeHostChattyAction {
    <#
    .SYNOPSIS
    Returns true for poll-style actions that must not log one line per message.
    #>
    param([AllowNull()][string]$Action)

    if (-not $Action) { return $false }
    return ($script:NativeHostChattyActions -contains $Action)
}

function Write-NativeHostChattyActionLog {
    <#
    .SYNOPSIS
    Counts a poll-style action message and emits an aggregate log line at most once per window.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [int]$WindowSeconds = 60
    )

    try {
        $now = Get-Date
        $entry = $script:NativeHostChattyActionStats[$Action]
        if (-not $entry) {
            $entry = @{ count = 0; lastSummaryAt = $now }
            $script:NativeHostChattyActionStats[$Action] = $entry
        }
        $entry.count = 1 + [int]$entry.count
        $elapsedSeconds = ($now - $entry.lastSummaryAt).TotalSeconds
        if ($elapsedSeconds -ge $WindowSeconds -or $entry.count -ge 500) {
            Write-NativeHostStageLog -Stage 'chatty-aggregate' -Fields @{
                action = $Action
                count = $entry.count
                windowSeconds = [int]$elapsedSeconds
            }
            $entry.count = 0
            $entry.lastSummaryAt = $now
        }
    }
    catch {
        return
    }
}

function Update-NativeHostDependencyReadyState {
    <#
    .SYNOPSIS
    Records an entry's ready state and logs only false->true transitions.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost,
        [bool]$Ready = $false
    )

    $key = "$($AnchorHost.ToLowerInvariant())|$($DependencyHost.ToLowerInvariant())"
    $previous = $script:NativeHostDependencyReadyState[$key]
    $script:NativeHostDependencyReadyState[$key] = $Ready
    if ($Ready -and $previous -ne $true) {
        Write-NativeHostStageLog -Stage 'runtime-dependency-ready-transition' -Domains @($DependencyHost) -Fields @{ anchorHost = $AnchorHost }
        return $true
    }
    return $false
}

function Test-NativeHostPersistentTransportDisabled {
    <#
    .SYNOPSIS
    Retirement switch for the Phase 2C persistent transport. Reads the Windows
    agent config (data\config.json) so turning it off never requires a new XPI.
    Default: enabled (announce).
    #>
    try {
        $configPath = Join-Path $script:OpenPathRoot 'data\config.json'
        if (-not (Test-Path -LiteralPath $configPath -ErrorAction SilentlyContinue)) { return $false }
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $config.PSObject.Properties['runtimeDependencyPersistentTransportDisabled']) { return $false }

        $value = $config.runtimeDependencyPersistentTransportDisabled
        if ($value -is [bool]) { return [bool]$value }
        if ($value -is [string]) {
            return ([string]$value).Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on', 'disabled')
        }
        return [bool]$value
    }
    catch {
        return $false
    }
}

function Get-NativeHostCapabilities {
    <#
    .SYNOPSIS
    Capabilities announced by ping. The retirement switch drops the two
    capabilities that change request handling (enqueue and auto-reload).
    #>
    $capabilities = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-NativeHostPersistentTransportDisabled)) {
        $capabilities.Add('runtime-dependency-enqueue')
    }
    $capabilities.Add('runtime-dependency-check-batch')
    $capabilities.Add('message-id-echo')
    if (-not (Test-NativeHostPersistentTransportDisabled)) {
        $capabilities.Add('runtime-dependency-auto-reload')
    }
    if (-not (Test-NativeHostPersistentTransportDisabled) -and -not (Test-NativeHostExtensionDiagnosticsDisabled)) {
        $capabilities.Add('extension-diagnostics')
    }
    return $capabilities.ToArray()
}

function Test-NativeHostExtensionDiagnosticsDisabled {
    <#
    .SYNOPSIS
    Phase 2E E1 retirement switch for the extension-diagnostics action. Reads
    the Windows agent config (data\config.json, key extensionDiagnosticsDisabled)
    so turning the diagnostics off never requires a new XPI. Default: enabled.
    #>
    try {
        $configPath = Join-Path $script:OpenPathRoot 'data\config.json'
        if (-not (Test-Path -LiteralPath $configPath -ErrorAction SilentlyContinue)) { return $false }
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $config.PSObject.Properties['extensionDiagnosticsDisabled']) { return $false }

        $value = $config.extensionDiagnosticsDisabled
        if ($value -is [bool]) { return [bool]$value }
        if ($value -is [string]) {
            return ([string]$value).Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on', 'disabled')
        }
        return [bool]$value
    }
    catch {
        return $false
    }
}

$script:NativeHostExtensionDiagnosticAllowedFields = @(
    'ts', 'kind', 'tabId', 'frameId', 'type', 'anchorHost', 'dependencyHost', 'host',
    'transport', 'from', 'to', 'outcome', 'ms', 'reason', 'navigationId', 'methodKnown',
    'committed', 'source'
)
$script:NativeHostExtensionDiagnosticWindow = $null

function ConvertTo-NativeHostExtensionDiagnosticEvent {
    <#
    .SYNOPSIS
    Phase 2E E1 sanitizer: hosts, types, reason codes, ids and ms only. URLs,
    free text and unknown fields are dropped so a compromised or buggy caller
    cannot leak page data into the user's native-host.log.
    #>
    param([Parameter(Mandatory = $false)][object]$Event)

    $sanitized = [ordered]@{}
    if ($null -eq $Event) { return $sanitized }

    foreach ($field in $script:NativeHostExtensionDiagnosticAllowedFields) {
        $value = $null
        if ($Event -is [System.Collections.IDictionary]) {
            if (-not $Event.Contains($field)) { continue }
            $value = $Event[$field]
        }
        else {
            $property = $Event.PSObject.Properties[$field]
            if ($null -eq $property) { continue }
            $value = $property.Value
        }
        if ($null -eq $value) { continue }

        if ($value -is [bool]) {
            $sanitized[$field] = [bool]$value
            continue
        }
        if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
            $sanitized[$field] = [int]$value
            continue
        }
        $text = ([string]$value).Trim()
        if ($text.Length -eq 0) { continue }
        if ($text -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { continue }
        if ($text.Length -gt 120) { $text = $text.Substring(0, 120) }
        $sanitized[$field] = $text
    }

    return $sanitized
}

function Invoke-NativeHostReportExtensionDiagnostics {
    <#
    .SYNOPSIS
    Phase 2E E1: writes the extension diagnostics batch (at most 50 events per
    message, at most 60 messages per minute) as one
    `stage=extension-diagnostic {json}` line per event.
    #>
    param([Parameter(Mandatory = $false)][object]$Message)

    $written = 0
    $dropped = 0
    try {
        $window = $script:NativeHostExtensionDiagnosticWindow
        $now = Get-Date
        if ($null -eq $window -or ($now - $window.start).TotalSeconds -ge 60) {
            $window = @{ start = $now; messages = 0; dropped = 0 }
            $script:NativeHostExtensionDiagnosticWindow = $window
        }
        $window.messages = [int]$window.messages + 1
        if ($window.messages -gt 60) {
            $window.dropped = [int]$window.dropped + 1
            return @{
                success = $true
                action = 'report-extension-diagnostics'
                written = 0
                rateLimited = $true
            }
        }

        $events = @()
        if ($null -ne $Message) {
            if ($Message -is [System.Collections.IDictionary]) {
                if ($Message.Contains('events')) { $events = @($Message['events']) }
            }
            else {
                $property = $Message.PSObject.Properties['events']
                if ($null -ne $property) { $events = @($property.Value) }
            }
        }

        foreach ($event in ($events | Select-Object -First 50)) {
            $sanitized = ConvertTo-NativeHostExtensionDiagnosticEvent -Event $event
            if ($sanitized.Count -eq 0) { continue }
            $json = $sanitized | ConvertTo-Json -Compress -Depth 3
            Write-NativeHostLog ("stage=extension-diagnostic " + $json)
            $written = $written + 1
        }
        if ($events.Count -gt 50) {
            $dropped = [int]$events.Count - 50
        }
    }
    catch {
        return @{
            success = $false
            action = 'report-extension-diagnostics'
            error = "extension diagnostics failed: $($_.Exception.Message)"
        }
    }

    return @{
        success = $true
        action = 'report-extension-diagnostics'
        written = $written
        dropped = $dropped
    }
}

function Get-NativeHostProtocolVersion {
    # Phase 2C persistent transport protocol version.
    return 2
}

function Write-NativeHostActionLog {
    <#
    .SYNOPSIS
    Writes a structured native host action log line when the native host logger is available.
    #>
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
function Write-NativeHostStageLog {
    <#
    .SYNOPSIS
    Writes a compact pipeline stage mark (message received, queue written, task triggered, readiness observed, response sent) to the native host log.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [string[]]$Domains = @(),
        [AllowNull()][string]$Message = '',
        [long]$ElapsedMs = 0,
        [hashtable]$Fields = @{}
    )

    try {
        if (-not (Get-Command Write-NativeHostLog -ErrorAction SilentlyContinue)) {
            return
        }

        $parts = @("stage=$Stage")
        if ($ElapsedMs -gt 0) { $parts += "elapsedMs=$ElapsedMs" }
        $safeDomains = @(Get-NativeHostValidDomains -Domains $Domains)
        if ($safeDomains.Count -gt 0) { $parts += "domains=$($safeDomains -join ',')" }
        if ($Message) { $parts += "message=$(Format-NativeHostActionLogValue -Value $Message)" }
        foreach ($key in @($Fields.Keys | Sort-Object)) {
            if ($key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { continue }
            $value = $Fields[$key]
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
            $parts += "$key=$(Format-NativeHostActionLogValue -Value $value)"
        }

        Write-NativeHostLog ("Native host {0}" -f ($parts -join ' '))
    }
    catch {
        return
    }
}
function Get-NativeHostMachineName {
    <#
    .SYNOPSIS
    Returns the machine name from the native host state, falling back to the environment computer name.
    #>
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
    <#
    .SYNOPSIS
    Resolves the API URL from the native host state via the request setup state helper.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    Initialize-NativeHostRequestSetupSupport
    $requestSetupState = Get-OpenPathRequestSetupState -Config $State
    return [string]$requestSetupState.RequestApiUrl
}
function Get-NativeHostMachineToken {
    <#
    .SYNOPSIS
    Resolves the machine bearer token from the native host state via the request setup state helper.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    Initialize-NativeHostRequestSetupSupport
    $requestSetupState = Get-OpenPathRequestSetupState -Config $State
    return [string]$requestSetupState.MachineToken
}
function Get-NativeHostBlockedPathResponse {
    <#
    .SYNOPSIS
    Builds the native host response payload for a get-blocked-paths action from the current whitelist sections.
    #>
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
function Get-NativeHostAllowedPathResponse {
    <#
    .SYNOPSIS
    Builds the native host response payload for a get-allowed-paths action from the current whitelist sections.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Sections
    )

    $paths = @($Sections.AllowedPaths)
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
        action = 'get-allowed-paths'
        paths = $paths
        count = $paths.Count
        hash = $digest
        mtime = $mtime
        source = $script:WhitelistPath
    }
}
function Get-NativeHostBlockedSubdomainResponse {
    <#
    .SYNOPSIS
    Builds the native host response payload for a get-blocked-subdomains action from the current whitelist sections.
    #>
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
