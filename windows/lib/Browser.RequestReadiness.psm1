# OpenPath browser request readiness facts for Windows

Import-Module "$PSScriptRoot\Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxPolicy.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxNativeHost.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\AppControl.psm1" -Force -ErrorAction SilentlyContinue

function Test-OpenPathBrowserRequestSetupReady {
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    if (Get-Command -Name 'Test-OpenPathFirefoxNativeHostRequestSetupComplete' -ErrorAction SilentlyContinue) {
        return [bool](Test-OpenPathFirefoxNativeHostRequestSetupComplete -Config $Config)
    }

    if (-not $Config) {
        return $false
    }

    $apiUrl = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'apiUrl'
    $whitelistUrl = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'whitelistUrl'
    $classroom = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'classroom'
    $classroomId = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'classroomId'

    if ($apiUrl -notmatch '^https?://\S+$') {
        return $false
    }
    if ($whitelistUrl -notmatch '/w/[^/]+/whitelist\.txt($|[?#].*)') {
        return $false
    }

    return [bool]($classroom -or $classroomId)
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

    $classroom = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'classroom'
    $classroomId = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'classroomId'
    $whitelistUrl = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'whitelistUrl'

    return [bool]($classroom -or $classroomId -or $whitelistUrl)
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

function Test-OpenPathChromiumUrlBlocklistReady {
    param(
        [AllowNull()]
        [object[]]$UrlBlocklist = $null
    )

    $googleSearchBlock = Get-OpenPathGoogleSearchBlockPattern
    return [bool](@($UrlBlocklist | Where-Object {
                ([string]$_).Equals($googleSearchBlock, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0)
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

        [AllowNull()]
        [object]$ManagedExtension = $null,

        [AllowNull()]
        [object]$DohMode = $null,

        [AllowNull()]
        [object[]]$UrlBlocklist = $null
    )

    $factPrefix = $Browser.ToLowerInvariant()
    if (-not $Installed) {
        $Facts["${factPrefix}_managed_extension"] = 'not_installed'
        $Facts["${factPrefix}_doh_mode"] = 'not_installed'
        $Facts["${factPrefix}_url_blocklist"] = 'not_installed'
        return
    }

    $managedReady = Test-OpenPathReadinessTruthy -Value $ManagedExtension
    $dohReady = Test-OpenPathChromiumDohModeReady -DohMode $DohMode
    $urlBlocklistReady = Test-OpenPathChromiumUrlBlocklistReady -UrlBlocklist $UrlBlocklist

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
        -ManagedExtension $EdgeManagedExtension `
        -DohMode $EdgeDohMode `
        -UrlBlocklist $EdgeUrlBlocklist

    Add-OpenPathChromiumReadinessFacts `
        -Facts $facts `
        -FailureReasons $failureReasons `
        -Browser Chrome `
        -Installed $chromeInstalled `
        -StrictMode $strictMode `
        -ManagedExtension $ChromeManagedExtension `
        -DohMode $ChromeDohMode `
        -UrlBlocklist $ChromeUrlBlocklist

    if (Test-OpenPathReadinessTruthy -Value $AppControlActive) {
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
    'Test-OpenPathBrowserRequestSetupReady',
    'Test-OpenPathFirefoxNativeHostRegistrationProof'
)
