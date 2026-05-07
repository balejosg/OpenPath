# OpenPath browser request readiness facts for Windows

Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\RequestSetup.State.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.EnforcementDecision.psm1" -Force -ErrorAction Stop
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

    $requiredPatterns = @(
        Get-OpenPathGoogleSearchBlockPattern
        Get-OpenPathGoogleGameBlockPatterns
    )

    return Browser.EnforcementDecision\Test-OpenPathChromiumUrlBlocklistDecision `
        -UrlBlocklist $UrlBlocklist `
        -RequiredPatterns $requiredPatterns
}

function Test-OpenPathChromiumDohModeReady {
    param(
        [AllowNull()]
        [object]$DohMode = $null
    )

    return Browser.EnforcementDecision\Test-OpenPathChromiumDohModeDecision -DohMode $DohMode
}

function Test-OpenPathReadinessTruthy {
    param(
        [AllowNull()]
        [object]$Value = $null
    )

    return Browser.EnforcementDecision\Test-OpenPathBrowserDecisionTruthy -Value $Value
}

function Get-OpenPathApprovedStudentBrowsers {
    param(
        [AllowNull()]
        [object]$Config
    )

    return @(Browser.EnforcementDecision\Get-OpenPathApprovedStudentBrowsersDecision -Config $Config)
}

function Test-OpenPathStudentBrowserApproved {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedStudentBrowsers,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Edge', 'Chrome')]
        [string]$Browser
    )

    return Browser.EnforcementDecision\Test-OpenPathStudentBrowserApprovedDecision `
        -ApprovedStudentBrowsers $ApprovedStudentBrowsers `
        -Browser $Browser
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

    return Browser.EnforcementDecision\Test-OpenPathApprovedBrowserInstalledDecision `
        -BrowserInventory $BrowserInventory `
        -BrowserName $BrowserName
}

function Test-OpenPathUnmanagedBrowserFindingsPresent {
    param(
        [AllowNull()]
        [object]$BrowserInventory = $null
    )

    return Browser.EnforcementDecision\Test-OpenPathUnmanagedBrowserFindingsPresentDecision -BrowserInventory $BrowserInventory
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
    $decisionFacts = [PSCustomObject]@{
        StrictMode = $strictMode
        ApprovedStudentBrowsers = $approvedStudentBrowsers
        RequestSetupReady = Test-OpenPathBrowserRequestSetupReady -Config $Config
        FirefoxManagedExtensionReady = [bool]($ManagedExtensionPolicy -and $ManagedExtensionPolicy.ExtensionId -and $ManagedExtensionPolicy.InstallUrl)
        FirefoxMachinePolicyApplied = [bool]$FirefoxMachinePolicyApplied
        FirefoxNativeHostReady = [bool]([bool]$NativeHostRegistered -and [bool]$NativeHostStatePresent)
        AppControlActive = $appControlReady
        UnmanagedBrowserFindingsPresent = $unmanagedBrowserFindingsPresent
        BrowserInventory = $BrowserInventory
        Chromium = [PSCustomObject]@{
            Edge = [PSCustomObject]@{
                Installed = $edgeInstalled
                Approved = Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $approvedStudentBrowsers -Browser Edge
                ManagedExtensionReady = Test-OpenPathReadinessTruthy -Value $EdgeManagedExtension
                DohModeReady = Test-OpenPathChromiumDohModeReady -DohMode $EdgeDohMode
                UrlBlocklistReady = Test-OpenPathChromiumUrlBlocklistReady -UrlBlocklist $EdgeUrlBlocklist
            }
            Chrome = [PSCustomObject]@{
                Installed = $chromeInstalled
                Approved = Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $approvedStudentBrowsers -Browser Chrome
                ManagedExtensionReady = Test-OpenPathReadinessTruthy -Value $ChromeManagedExtension
                DohModeReady = Test-OpenPathChromiumDohModeReady -DohMode $ChromeDohMode
                UrlBlocklistReady = Test-OpenPathChromiumUrlBlocklistReady -UrlBlocklist $ChromeUrlBlocklist
            }
        }
    }

    return Browser.EnforcementDecision\Get-OpenPathBrowserRequestReadinessDecision -Facts $decisionFacts
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserRequestReadiness',
    'Get-OpenPathApprovedStudentBrowsers',
    'Get-OpenPathGoogleGameBlockPatterns',
    'Test-OpenPathStudentBrowserApproved',
    'Test-OpenPathBrowserRequestSetupReady',
    'Test-OpenPathFirefoxNativeHostRegistrationProof'
)
