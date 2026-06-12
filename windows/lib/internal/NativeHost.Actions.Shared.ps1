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
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { $_ -match '^[a-z0-9.-]+$' } |
        Select-Object -First $maxDomains
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
