function Invoke-NativeHostCheckAction {
    # validates each domain in the message, checks whitelist membership, resolves its IP, and evaluates captive-portal recovery eligibility; returns a per-domain results array.
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

    Invoke-NativeHostAuthenticatedCaptivePortalRestoreIfNeeded

    $results = foreach ($domain in $validDomains) {
        $portalRecoverySignal = Get-NativeHostPortalRecoverySignal -Domain $domain -Message $Message
        @{
            domain = $domain
            in_whitelist = $whitelistSet.Contains($domain)
            resolved_ip = (Resolve-DomainIp -Domain $domain)
            portal_recovery_eligible = ((-not $whitelistSet.Contains($domain)) -and $portalRecoverySignal -ne 'none')
            portal_recovery_signal = $portalRecoverySignal
        }
    }

    return @{
        success = $true
        action = 'check'
        results = @($results)
    }
}

function Invoke-NativeHostMessageAction {
    # dispatches $Action to the appropriate handler and returns a response hashtable; handles ping, config retrieval, domain checks, whitelist updates, runtime-dependency actions, and captive-portal recovery.
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

        'get-allowed-paths' {
            return (Get-NativeHostAllowedPathResponse -Sections $sections)
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

        $script:OpenPathRuntimeDependencyActionAllowLocal {
            return (Invoke-NativeHostLocalRuntimeDependencyAction -Message $Message -State $State -Sections $sections)
        }

        $script:OpenPathRuntimeDependencyActionAllowLocalBatch {
            return (Invoke-NativeHostLocalRuntimeDependencyBatchAction -Message $Message -State $State -Sections $sections)
        }

        'recover-captive-portal-navigation' {
            return (Invoke-NativeHostCaptivePortalRecoveryAction -Message $Message)
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
    # reads native state and whitelist sections, dispatches the message to the action handler, logs the outcome with elapsed time, and returns the response.
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
