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

    if (Get-Command -Name 'Get-OpenPathRequestSetupState' -ErrorAction SilentlyContinue) {
        $requestSetupState = Get-OpenPathRequestSetupState -Config $State
        if ($requestSetupState.RequestApiUrl) {
            return [string]$requestSetupState.RequestApiUrl
        }
    }

    if ($State.PSObject.Properties['requestApiUrl'] -and $State.requestApiUrl) {
        return ([string]$State.requestApiUrl).TrimEnd('/')
    }
    if ($State.PSObject.Properties['apiUrl'] -and $State.apiUrl) {
        return ([string]$State.apiUrl).TrimEnd('/')
    }

    return ''
}

function Get-NativeHostMachineToken {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    $whitelistUrl = if ($State.PSObject.Properties['whitelistUrl']) { [string]$State.whitelistUrl } else { '' }
    if (Get-Command -Name 'Get-OpenPathRequestSetupMachineToken' -ErrorAction SilentlyContinue) {
        return [string](Get-OpenPathRequestSetupMachineToken -WhitelistUrl $whitelistUrl)
    }

    return [string](Get-MachineTokenFromWhitelistUrl -WhitelistUrl $whitelistUrl)
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
            $apiUrl = Get-NativeHostApiUrl -State $State
            $whitelistUrl = if ($State.PSObject.Properties['whitelistUrl']) { [string]$State.whitelistUrl } else { '' }
            $machineToken = Get-NativeHostMachineToken -State $State

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
                machineToken = if ($machineToken) { $machineToken } else { '' }
                whitelistUrl = $whitelistUrl
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
