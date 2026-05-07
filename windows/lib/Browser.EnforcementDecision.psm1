# OpenPath pure browser enforcement decisions for Windows

function Test-OpenPathBrowserDecisionTruthy {
    param(
        [AllowNull()]
        [object]$Value = $null
    )

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }

    return [bool]$Value
}

function Get-OpenPathBrowserDecisionProperty {
    param(
        [AllowNull()]
        [object]$InputObject = $null,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($InputObject -and $InputObject.PSObject.Properties[$PropertyName]) {
        return $InputObject.PSObject.Properties[$PropertyName].Value
    }

    return $DefaultValue
}

function Get-OpenPathApprovedStudentBrowsersDecision {
    param(
        [AllowNull()]
        [object]$Config
    )

    $configured = Get-OpenPathBrowserDecisionProperty -InputObject $Config -PropertyName 'approvedStudentBrowsers'
    if ($null -eq $configured) {
        return @('Firefox')
    }

    $values = if ($configured -is [string]) {
        @($configured -split ',')
    }
    else {
        @($configured)
    }

    $approved = @(
        $values |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ } |
            ForEach-Object {
                if ($_ -in @('Firefox', 'Mozilla Firefox')) { 'Firefox' }
                elseif ($_ -in @('Edge', 'Microsoft Edge')) { 'Edge' }
                elseif ($_ -in @('Chrome', 'Google Chrome')) { 'Chrome' }
            } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )

    if ($approved.Count -eq 0) {
        return @('Firefox')
    }

    return @($approved)
}

function Test-OpenPathStudentBrowserApprovedDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedStudentBrowsers,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Edge', 'Chrome')]
        [string]$Browser
    )

    return [bool](@($ApprovedStudentBrowsers | Where-Object {
                ([string]$_).Equals($Browser, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0)
}

function Test-OpenPathChromiumDohModeDecision {
    param(
        [AllowNull()]
        [object]$DohMode = $null
    )

    return ([string]$DohMode).Trim().Equals('off', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-OpenPathChromiumUrlBlocklistDecision {
    param(
        [AllowNull()]
        [object[]]$UrlBlocklist = $null,

        [AllowNull()]
        [string[]]$RequiredPatterns = @()
    )

    $presentBlocks = @($UrlBlocklist | ForEach-Object { [string]$_ })
    foreach ($requiredPattern in @($RequiredPatterns | Where-Object { $_ })) {
        $hasBlock = [bool](@($presentBlocks | Where-Object {
                    $_.Equals($requiredPattern, [System.StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0)
        if (-not $hasBlock) {
            return $false
        }
    }

    return $true
}

function Test-OpenPathApprovedBrowserInstalledDecision {
    param(
        [AllowNull()]
        [object]$BrowserInventory = $null,

        [Parameter(Mandatory = $true)]
        [string]$BrowserName
    )

    if (-not $BrowserInventory -or -not $BrowserInventory.PSObject.Properties['ApprovedBrowsers']) {
        return $false
    }

    return [bool](@($BrowserInventory.ApprovedBrowsers | Where-Object {
                $_ -and $_.PSObject.Properties['Name'] -and ([string]$_.Name) -eq $BrowserName
            }).Count -gt 0)
}

function Test-OpenPathUnmanagedBrowserFindingsPresentDecision {
    param(
        [AllowNull()]
        [object]$BrowserInventory = $null
    )

    if (-not $BrowserInventory) {
        return $false
    }

    $unmanagedCount = if ($BrowserInventory.PSObject.Properties['UnmanagedBrowsers']) {
        @($BrowserInventory.UnmanagedBrowsers).Count
    }
    else {
        0
    }
    $portableCount = if ($BrowserInventory.PSObject.Properties['PortableBrowserRisks']) {
        @($BrowserInventory.PortableBrowserRisks).Count
    }
    else {
        0
    }

    return [bool](($unmanagedCount + $portableCount) -gt 0)
}

function Add-OpenPathChromiumReadinessDecision {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$OutputFacts,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$FailureReasons,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser,

        [Parameter(Mandatory = $true)]
        [object]$Facts,

        [Parameter(Mandatory = $true)]
        [bool]$StrictMode,

        [Parameter(Mandatory = $true)]
        [bool]$AppControlActive
    )

    $factPrefix = $Browser.ToLowerInvariant()
    $installed = Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'Installed' -DefaultValue $false)
    $approved = Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'Approved' -DefaultValue $false)

    if (-not $installed) {
        $OutputFacts["${factPrefix}_approval"] = 'not_installed'
        $OutputFacts["${factPrefix}_managed_extension"] = 'not_installed'
        $OutputFacts["${factPrefix}_doh_mode"] = 'not_installed'
        $OutputFacts["${factPrefix}_url_blocklist"] = 'not_installed'
        return
    }

    if (-not $approved) {
        $OutputFacts["${factPrefix}_approval"] = if ($AppControlActive) { 'not_approved_blocked_by_app_control' } else { 'not_approved_app_control_missing' }
        $OutputFacts["${factPrefix}_managed_extension"] = 'not_approved'
        $OutputFacts["${factPrefix}_doh_mode"] = 'not_approved'
        $OutputFacts["${factPrefix}_url_blocklist"] = 'not_approved'
        if ($StrictMode -and -not $AppControlActive) {
            $FailureReasons.Add("${factPrefix}_not_approved_app_control_missing")
        }
        return
    }

    $managedReady = Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'ManagedExtensionReady' -DefaultValue $false)
    $dohReady = Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'DohModeReady' -DefaultValue $false)
    $urlBlocklistReady = Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'UrlBlocklistReady' -DefaultValue $false)

    $OutputFacts["${factPrefix}_approval"] = 'approved'
    $OutputFacts["${factPrefix}_managed_extension"] = if ($managedReady) { 'ready' } else { 'missing' }
    $OutputFacts["${factPrefix}_doh_mode"] = if ($dohReady) { 'ready' } else { 'missing' }
    $OutputFacts["${factPrefix}_url_blocklist"] = if ($urlBlocklistReady) { 'ready' } else { 'missing' }

    if ($StrictMode) {
        if (-not $managedReady) {
            $FailureReasons.Add("${factPrefix}_managed_extension_missing")
        }
        if (-not $dohReady) {
            $FailureReasons.Add("${factPrefix}_doh_mode_missing")
        }
        if (-not $urlBlocklistReady) {
            $FailureReasons.Add("${factPrefix}_url_blocklist_missing")
        }
    }
}

function Get-OpenPathBrowserRequestReadinessDecision {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Facts
    )

    $strictMode = Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'StrictMode' -DefaultValue $false)
    $appControlReady = Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'AppControlActive' -DefaultValue $false)
    $chromiumFacts = Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'Chromium' -DefaultValue ([PSCustomObject]@{})
    $edgeFacts = Get-OpenPathBrowserDecisionProperty -InputObject $chromiumFacts -PropertyName 'Edge' -DefaultValue ([PSCustomObject]@{})
    $chromeFacts = Get-OpenPathBrowserDecisionProperty -InputObject $chromiumFacts -PropertyName 'Chrome' -DefaultValue ([PSCustomObject]@{})
    $outputFacts = [ordered]@{}
    $failureReasons = New-Object System.Collections.Generic.List[string]

    if (Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'RequestSetupReady' -DefaultValue $false)) {
        $outputFacts.request_setup = 'ready'
    }
    else {
        $outputFacts.request_setup = 'missing'
        $failureReasons.Add('request_setup_incomplete')
    }

    if (Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'FirefoxManagedExtensionReady' -DefaultValue $false)) {
        $outputFacts.firefox_managed_extension = 'ready'
    }
    else {
        $outputFacts.firefox_managed_extension = 'missing'
        $failureReasons.Add('firefox_managed_extension_missing')
    }

    if (Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'FirefoxMachinePolicyApplied' -DefaultValue $false)) {
        $outputFacts.firefox_machine_policy = 'ready'
    }
    else {
        $outputFacts.firefox_machine_policy = 'missing'
        $failureReasons.Add('firefox_machine_policy_missing')
    }

    if (Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'FirefoxNativeHostReady' -DefaultValue $false)) {
        $outputFacts.firefox_native_host = 'ready'
    }
    else {
        $outputFacts.firefox_native_host = 'missing'
        $failureReasons.Add('firefox_native_host_missing')
    }

    Add-OpenPathChromiumReadinessDecision `
        -OutputFacts $outputFacts `
        -FailureReasons $failureReasons `
        -Browser Edge `
        -Facts $edgeFacts `
        -StrictMode $strictMode `
        -AppControlActive $appControlReady

    Add-OpenPathChromiumReadinessDecision `
        -OutputFacts $outputFacts `
        -FailureReasons $failureReasons `
        -Browser Chrome `
        -Facts $chromeFacts `
        -StrictMode $strictMode `
        -AppControlActive $appControlReady

    if ($appControlReady) {
        $outputFacts.app_control_active = 'ready'
    }
    else {
        $outputFacts.app_control_active = 'missing'
        if ($strictMode) {
            $failureReasons.Add('app_control_inactive')
        }
    }

    if (Test-OpenPathBrowserDecisionTruthy -Value (Get-OpenPathBrowserDecisionProperty -InputObject $Facts -PropertyName 'UnmanagedBrowserFindingsPresent' -DefaultValue $false)) {
        $outputFacts.unmanaged_browsers_detected = 'found'
        if ($strictMode) {
            $failureReasons.Add('unmanaged_browsers_detected')
        }
    }
    else {
        $outputFacts.unmanaged_browsers_detected = 'ready'
    }

    return [PSCustomObject]@{
        Platform = 'windows'
        Ready = ($failureReasons.Count -eq 0)
        Facts = [PSCustomObject]$outputFacts
        FailureReasons = @($failureReasons)
    }
}

function Get-OpenPathBrowserInventoryDecision {
    param(
        [AllowNull()]
        [object[]]$UnmanagedBrowsers = @(),

        [AllowNull()]
        [object[]]$PortableBrowserRisks = @()
    )

    $ready = [bool](@($UnmanagedBrowsers).Count -eq 0 -and @($PortableBrowserRisks).Count -eq 0)
    return [PSCustomObject]@{
        Ready = $ready
        ExitCode = if ($ready) { 0 } else { 1 }
    }
}

function Get-OpenPathBrowserEnforcementOverallDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppLocker,

        [Parameter(Mandatory = $true)]
        [bool]$InventoryReady,

        [Parameter(Mandatory = $true)]
        [bool]$RequestReadinessReady,

        [Parameter(Mandatory = $true)]
        [bool]$FirewallActive
    )

    $healthySignals = @(
        ($AppLocker -ne 'Inactive'),
        $InventoryReady,
        $RequestReadinessReady,
        $FirewallActive
    )
    $healthyCount = @($healthySignals | Where-Object { $_ }).Count
    if ($healthyCount -eq $healthySignals.Count) {
        return 'Healthy'
    }
    if ($healthyCount -gt 0) {
        return 'Partial'
    }

    return 'Unhealthy'
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserRequestReadinessDecision',
    'Get-OpenPathBrowserInventoryDecision',
    'Get-OpenPathBrowserEnforcementOverallDecision',
    'Get-OpenPathApprovedStudentBrowsersDecision',
    'Test-OpenPathStudentBrowserApprovedDecision',
    'Test-OpenPathChromiumDohModeDecision',
    'Test-OpenPathChromiumUrlBlocklistDecision',
    'Test-OpenPathApprovedBrowserInstalledDecision',
    'Test-OpenPathUnmanagedBrowserFindingsPresentDecision',
    'Test-OpenPathBrowserDecisionTruthy'
)
