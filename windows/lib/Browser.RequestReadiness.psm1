# OpenPath browser request readiness facts for Windows

Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\RequestSetup.State.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxPolicy.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxNativeHost.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\AppControl.psm1" -Force -ErrorAction SilentlyContinue

function Test-OpenPathBrowserRequestSetupReady {
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $requestSetupState = Get-OpenPathRequestSetupState -Config $Config
    return [bool]$requestSetupState.Ready
}

function Test-OpenPathFirefoxNativeHostRegistrationProof {
    $manifestPath = Get-OpenPathFirefoxNativeHostManifestPath
    $wrapperPath = Get-OpenPathFirefoxNativeHostWrapperPath
    $statePath = Get-OpenPathFirefoxNativeStatePath

    if (-not (Test-Path $manifestPath)) {
        return $false
    }
    if (-not (Test-Path $wrapperPath)) {
        return $false
    }
    if (-not (Test-Path $statePath)) {
        return $false
    }

    $registryPaths = @(Get-OpenPathFirefoxNativeHostRegistryPaths)
    foreach ($registryPath in $registryPaths) {
        try {
            & reg.exe QUERY $registryPath /ve *> $null
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        }
        catch {
            # Keep probing remaining registry views.
        }
    }

    return $false
}

function Get-OpenPathReadinessBooleanConfigValue {
    param(
        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [bool]$DefaultValue = $false
    )

    if (-not $Config -or -not $Config.PSObject.Properties[$PropertyName]) {
        return $DefaultValue
    }

    $value = $Config.PSObject.Properties[$PropertyName].Value
    if ($null -eq $value) {
        return $DefaultValue
    }
    if ($value -is [bool]) {
        return [bool]$value
    }

    $text = ([string]$value).Trim().ToLowerInvariant()
    if (@('false', '0', 'no', 'off') -contains $text) {
        return $false
    }
    if (@('true', '1', 'yes', 'on') -contains $text) {
        return $true
    }

    return $DefaultValue
}

function Test-OpenPathManagedBrowserBoundaryStrictMode {
    param(
        [AllowNull()]
        [object]$Config
    )

    if ($Config -and $Config.PSObject.Properties['enforceManagedBrowserBoundary']) {
        return Get-OpenPathReadinessBooleanConfigValue `
            -Config $Config `
            -PropertyName 'enforceManagedBrowserBoundary' `
            -DefaultValue $true
    }

    $requestSetupState = Get-OpenPathRequestSetupState -Config $Config

    return [bool](
        $requestSetupState.ClassroomConfigured -or
        $requestSetupState.WhitelistUrl
    )
}

function Get-OpenPathChromiumPolicyRegistryPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser
    )

    if ($Browser -eq 'Edge') {
        return 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    }

    return 'HKLM:\SOFTWARE\Policies\Google\Chrome'
}

function Get-OpenPathRegistryPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        if ($item -and $item.PSObject.Properties[$Name]) {
            return $item.PSObject.Properties[$Name].Value
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-OpenPathRegistryListValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $item = Get-ItemProperty -Path $Path -ErrorAction Stop
    }
    catch {
        return @()
    }

    $values = @()
    foreach ($property in @($item.PSObject.Properties)) {
        if ($property.Name -match '^\d+$' -and $null -ne $property.Value) {
            $values += [string]$property.Value
        }
    }

    return @($values)
}

function Test-OpenPathChromiumExtensionForcelistReady {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser
    )

    $policyPath = Get-OpenPathChromiumPolicyRegistryPath -Browser $Browser
    $forcelistPath = "$policyPath\ExtensionInstallForcelist"
    $values = @(Get-OpenPathRegistryListValues -Path $forcelistPath)

    return [bool](@($values | Where-Object {
                $_ -match '/api/extensions/chromium/updates\.xml($|[?#])' -or
                $_ -match '/api/extensions/chromium/updates\.xml$'
            }).Count -gt 0)
}

function Get-OpenPathChromiumDohMode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser
    )

    $policyPath = Get-OpenPathChromiumPolicyRegistryPath -Browser $Browser
    $value = Get-OpenPathRegistryPropertyValue -Path $policyPath -Name 'DnsOverHttpsMode'
    if ($null -eq $value) {
        return ''
    }

    return [string]$value
}

function Get-OpenPathChromiumUrlBlocklist {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser
    )

    $policyPath = Get-OpenPathChromiumPolicyRegistryPath -Browser $Browser
    return @(Get-OpenPathRegistryListValues -Path "$policyPath\URLBlocklist")
}

function Get-OpenPathGoogleSearchBlockPattern {
    try {
        $policySpec = Get-OpenPathBrowserPolicySpec
        if ($policySpec -and $policySpec.chromium -and $policySpec.chromium.googleSearchBlock) {
            return [string]$policySpec.chromium.googleSearchBlock
        }
    }
    catch {
        # Fall back to the maintained Chromium policy contract default.
    }

    return '*://www.google.*/search*'
}

function Get-OpenPathGoogleGameBlockPatterns {
    try {
        $policySpec = Get-OpenPathBrowserPolicySpec
        if ($policySpec -and $policySpec.chromium -and $policySpec.chromium.googleGameBlocks) {
            return @($policySpec.chromium.googleGameBlocks | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
    }
    catch {
        # Fall back to the maintained Chromium policy contract defaults.
    }

    return @(
        '*://www.google.*/fbx?fbx=snake_arcade*',
        '*://doodles.google/*',
        '*://*.doodles.google/*',
        '*://www.google.*/logos/*'
    )
}

function Test-OpenPathChromiumUrlBlocklistReady {
    param(
        [AllowNull()]
        [object[]]$UrlBlocklist = $null
    )

    $googleSearchBlock = Get-OpenPathGoogleSearchBlockPattern
    $presentBlocks = @($UrlBlocklist | ForEach-Object { [string]$_ })
    $hasGoogleSearchBlock = [bool](@($presentBlocks | Where-Object {
                $_.Equals($googleSearchBlock, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0)
    if (-not $hasGoogleSearchBlock) {
        return $false
    }

    foreach ($googleGameBlock in @(Get-OpenPathGoogleGameBlockPatterns)) {
        $hasGoogleGameBlock = [bool](@($presentBlocks | Where-Object {
                    $_.Equals($googleGameBlock, [System.StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0)
        if (-not $hasGoogleGameBlock) {
            return $false
        }
    }

    return $true
}

function Test-OpenPathChromiumDohModeReady {
    param(
        [AllowNull()]
        [object]$DohMode = $null
    )

    return ([string]$DohMode).Trim().Equals('off', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-OpenPathReadinessTruthy {
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

function Get-OpenPathApprovedStudentBrowsers {
    param(
        [AllowNull()]
        [object]$Config
    )

    $configured = $null
    if ($Config -and $Config.PSObject.Properties['approvedStudentBrowsers']) {
        $configured = $Config.PSObject.Properties['approvedStudentBrowsers'].Value
    }

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

function Test-OpenPathStudentBrowserApproved {
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

function Get-OpenPathReadinessBrowserInventory {
    try {
        return Get-OpenPathBrowserInventory
    }
    catch {
        return [PSCustomObject]@{
            ApprovedBrowsers = @()
            UnmanagedBrowsers = @()
            PortableBrowserRisks = @()
        }
    }
}

function Test-OpenPathApprovedBrowserInstalled {
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

function Test-OpenPathUnmanagedBrowserFindingsPresent {
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

function Add-OpenPathChromiumReadinessFacts {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Facts,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$FailureReasons,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser,

        [Parameter(Mandatory = $true)]
        [bool]$Installed,

        [Parameter(Mandatory = $true)]
        [bool]$StrictMode,

        [Parameter(Mandatory = $true)]
        [bool]$Approved,

        [Parameter(Mandatory = $true)]
        [bool]$AppControlActive,

        [AllowNull()]
        [object]$ManagedExtension = $null,

        [AllowNull()]
        [object]$DohMode = $null,

        [AllowNull()]
        [object[]]$UrlBlocklist = $null
    )

    $factPrefix = $Browser.ToLowerInvariant()
    if (-not $Installed) {
        $Facts["${factPrefix}_approval"] = 'not_installed'
        $Facts["${factPrefix}_managed_extension"] = 'not_installed'
        $Facts["${factPrefix}_doh_mode"] = 'not_installed'
        $Facts["${factPrefix}_url_blocklist"] = 'not_installed'
        return
    }

    if (-not $Approved) {
        $Facts["${factPrefix}_approval"] = if ($AppControlActive) { 'not_approved_blocked_by_app_control' } else { 'not_approved_app_control_missing' }
        $Facts["${factPrefix}_managed_extension"] = 'not_approved'
        $Facts["${factPrefix}_doh_mode"] = 'not_approved'
        $Facts["${factPrefix}_url_blocklist"] = 'not_approved'
        if ($StrictMode -and -not $AppControlActive) {
            $FailureReasons.Add("${factPrefix}_not_approved_app_control_missing")
        }
        return
    }

    $managedReady = Test-OpenPathReadinessTruthy -Value $ManagedExtension
    $dohReady = Test-OpenPathChromiumDohModeReady -DohMode $DohMode
    $urlBlocklistReady = Test-OpenPathChromiumUrlBlocklistReady -UrlBlocklist $UrlBlocklist

    $Facts["${factPrefix}_approval"] = 'approved'
    $Facts["${factPrefix}_managed_extension"] = if ($managedReady) { 'ready' } else { 'missing' }
    $Facts["${factPrefix}_doh_mode"] = if ($dohReady) { 'ready' } else { 'missing' }
    $Facts["${factPrefix}_url_blocklist"] = if ($urlBlocklistReady) { 'ready' } else { 'missing' }

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

function Get-OpenPathBrowserRequestReadiness {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null,

        [AllowNull()]
        [object]$ManagedExtensionPolicy = $null,

        [AllowNull()]
        [object]$NativeHostRegistered = $null,

        [AllowNull()]
        [object]$NativeHostStatePresent = $null,

        [AllowNull()]
        [object]$FirefoxMachinePolicyApplied = $null,

        [AllowNull()]
        [object]$EdgeManagedExtension = $null,

        [AllowNull()]
        [object]$EdgeDohMode = $null,

        [AllowNull()]
        [object[]]$EdgeUrlBlocklist = $null,

        [AllowNull()]
        [object]$ChromeManagedExtension = $null,

        [AllowNull()]
        [object]$ChromeDohMode = $null,

        [AllowNull()]
        [object[]]$ChromeUrlBlocklist = $null,

        [AllowNull()]
        [object]$AppControlActive = $null,

        [AllowNull()]
        [object]$BrowserInventory = $null
    )

    if (-not $PSBoundParameters.ContainsKey('Config') -or -not $Config) {
        try {
            $Config = Get-OpenPathConfig
        }
        catch {
            $Config = $null
        }
    }

    if (-not $PSBoundParameters.ContainsKey('ManagedExtensionPolicy')) {
        $ManagedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy
    }

    if (-not $PSBoundParameters.ContainsKey('NativeHostRegistered')) {
        $NativeHostRegistered = Test-OpenPathFirefoxNativeHostRegistrationProof
    }

    if (-not $PSBoundParameters.ContainsKey('NativeHostStatePresent')) {
        $NativeHostStatePresent = Test-Path (Get-OpenPathFirefoxNativeStatePath)
    }

    if (-not $PSBoundParameters.ContainsKey('FirefoxMachinePolicyApplied')) {
        $FirefoxMachinePolicyApplied = Test-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $ManagedExtensionPolicy
    }

    if (-not $PSBoundParameters.ContainsKey('BrowserInventory')) {
        $BrowserInventory = Get-OpenPathReadinessBrowserInventory
    }

    if (-not $PSBoundParameters.ContainsKey('EdgeManagedExtension')) {
        $EdgeManagedExtension = Test-OpenPathChromiumExtensionForcelistReady -Browser Edge
    }

    if (-not $PSBoundParameters.ContainsKey('EdgeDohMode')) {
        $EdgeDohMode = Get-OpenPathChromiumDohMode -Browser Edge
    }

    if (-not $PSBoundParameters.ContainsKey('EdgeUrlBlocklist')) {
        $EdgeUrlBlocklist = @(Get-OpenPathChromiumUrlBlocklist -Browser Edge)
    }

    if (-not $PSBoundParameters.ContainsKey('ChromeManagedExtension')) {
        $ChromeManagedExtension = Test-OpenPathChromiumExtensionForcelistReady -Browser Chrome
    }

    if (-not $PSBoundParameters.ContainsKey('ChromeDohMode')) {
        $ChromeDohMode = Get-OpenPathChromiumDohMode -Browser Chrome
    }

    if (-not $PSBoundParameters.ContainsKey('ChromeUrlBlocklist')) {
        $ChromeUrlBlocklist = @(Get-OpenPathChromiumUrlBlocklist -Browser Chrome)
    }

    if (-not $PSBoundParameters.ContainsKey('AppControlActive')) {
        if (Get-Command -Name 'Test-OpenPathNonAdminAppControlActive' -ErrorAction SilentlyContinue) {
            $AppControlActive = Test-OpenPathNonAdminAppControlActive
        }
        else {
            $AppControlActive = $false
        }
    }

    $strictMode = Test-OpenPathManagedBrowserBoundaryStrictMode -Config $Config
    $approvedStudentBrowsers = @(Get-OpenPathApprovedStudentBrowsers -Config $Config)
    $appControlReady = Test-OpenPathReadinessTruthy -Value $AppControlActive
    $edgeInstalled = Test-OpenPathApprovedBrowserInstalled -BrowserInventory $BrowserInventory -BrowserName 'Microsoft Edge'
    $chromeInstalled = Test-OpenPathApprovedBrowserInstalled -BrowserInventory $BrowserInventory -BrowserName 'Google Chrome'
    $unmanagedBrowserFindingsPresent = Test-OpenPathUnmanagedBrowserFindingsPresent -BrowserInventory $BrowserInventory

    $facts = [ordered]@{}
    $failureReasons = New-Object System.Collections.Generic.List[string]

    if (Test-OpenPathBrowserRequestSetupReady -Config $Config) {
        $facts.request_setup = 'ready'
    }
    else {
        $facts.request_setup = 'missing'
        $failureReasons.Add('request_setup_incomplete')
    }

    if ($ManagedExtensionPolicy -and $ManagedExtensionPolicy.ExtensionId -and $ManagedExtensionPolicy.InstallUrl) {
        $facts.firefox_managed_extension = 'ready'
    }
    else {
        $facts.firefox_managed_extension = 'missing'
        $failureReasons.Add('firefox_managed_extension_missing')
    }

    if ([bool]$FirefoxMachinePolicyApplied) {
        $facts.firefox_machine_policy = 'ready'
    }
    else {
        $facts.firefox_machine_policy = 'missing'
        $failureReasons.Add('firefox_machine_policy_missing')
    }

    if ([bool]$NativeHostRegistered -and [bool]$NativeHostStatePresent) {
        $facts.firefox_native_host = 'ready'
    }
    else {
        $facts.firefox_native_host = 'missing'
        $failureReasons.Add('firefox_native_host_missing')
    }

    Add-OpenPathChromiumReadinessFacts `
        -Facts $facts `
        -FailureReasons $failureReasons `
        -Browser Edge `
        -Installed $edgeInstalled `
        -StrictMode $strictMode `
        -Approved (Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $approvedStudentBrowsers -Browser Edge) `
        -AppControlActive $appControlReady `
        -ManagedExtension $EdgeManagedExtension `
        -DohMode $EdgeDohMode `
        -UrlBlocklist $EdgeUrlBlocklist

    Add-OpenPathChromiumReadinessFacts `
        -Facts $facts `
        -FailureReasons $failureReasons `
        -Browser Chrome `
        -Installed $chromeInstalled `
        -StrictMode $strictMode `
        -Approved (Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $approvedStudentBrowsers -Browser Chrome) `
        -AppControlActive $appControlReady `
        -ManagedExtension $ChromeManagedExtension `
        -DohMode $ChromeDohMode `
        -UrlBlocklist $ChromeUrlBlocklist

    if ($appControlReady) {
        $facts.app_control_active = 'ready'
    }
    else {
        $facts.app_control_active = 'missing'
        if ($strictMode) {
            $failureReasons.Add('app_control_inactive')
        }
    }

    if ($unmanagedBrowserFindingsPresent) {
        $facts.unmanaged_browsers_detected = 'found'
        if ($strictMode) {
            $failureReasons.Add('unmanaged_browsers_detected')
        }
    }
    else {
        $facts.unmanaged_browsers_detected = 'ready'
    }

    return [PSCustomObject]@{
        Platform = 'windows'
        Ready = ($failureReasons.Count -eq 0)
        Facts = [PSCustomObject]$facts
        FailureReasons = @($failureReasons)
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserRequestReadiness',
    'Get-OpenPathApprovedStudentBrowsers',
    'Get-OpenPathGoogleGameBlockPatterns',
    'Test-OpenPathStudentBrowserApproved',
    'Test-OpenPathBrowserRequestSetupReady',
    'Test-OpenPathFirefoxNativeHostRegistrationProof'
)
