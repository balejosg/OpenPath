# OpenPath browser request readiness fact collectors for Windows

Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.EnforcementDecision.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxPolicy.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxNativeHost.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\AppControl.psm1" -Force -ErrorAction SilentlyContinue

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

    return Test-OpenPathChromiumUrlBlocklistDecision `
        -UrlBlocklist $UrlBlocklist `
        -RequiredPatterns $requiredPatterns
}

function Test-OpenPathChromiumDohModeReady {
    param(
        [AllowNull()]
        [object]$DohMode = $null
    )

    return Test-OpenPathChromiumDohModeDecision -DohMode $DohMode
}

function Test-OpenPathReadinessTruthy {
    param(
        [AllowNull()]
        [object]$Value = $null
    )

    return Test-OpenPathBrowserDecisionTruthy -Value $Value
}

function Test-OpenPathStudentBrowserApproved {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedStudentBrowsers,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Edge', 'Chrome')]
        [string]$Browser
    )

    return Test-OpenPathStudentBrowserApprovedDecision `
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

    return Test-OpenPathApprovedBrowserInstalledDecision `
        -BrowserInventory $BrowserInventory `
        -BrowserName $BrowserName
}

function Test-OpenPathUnmanagedBrowserFindingsPresent {
    param(
        [AllowNull()]
        [object]$BrowserInventory = $null
    )

    return Test-OpenPathUnmanagedBrowserFindingsPresentDecision -BrowserInventory $BrowserInventory
}

function Get-OpenPathFirefoxReadinessFacts {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ManagedExtensionPolicy = $null,

        [AllowNull()]
        [object]$NativeHostRegistered = $null,

        [AllowNull()]
        [object]$NativeHostStatePresent = $null,

        [AllowNull()]
        [object]$FirefoxMachinePolicyApplied = $null
    )

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

    return [PSCustomObject]@{
        ManagedExtensionPolicy = $ManagedExtensionPolicy
        ManagedExtensionReady = [bool]($ManagedExtensionPolicy -and $ManagedExtensionPolicy.ExtensionId -and $ManagedExtensionPolicy.InstallUrl)
        MachinePolicyApplied = [bool]$FirefoxMachinePolicyApplied
        NativeHostRegistered = [bool]$NativeHostRegistered
        NativeHostStatePresent = [bool]$NativeHostStatePresent
        NativeHostReady = [bool]([bool]$NativeHostRegistered -and [bool]$NativeHostStatePresent)
    }
}

function Get-OpenPathChromiumBrowserReadinessFacts {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser,

        [Parameter(Mandatory = $true)]
        [string]$BrowserName,

        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedStudentBrowsers,

        [AllowNull()]
        [object]$BrowserInventory = $null,

        [AllowNull()]
        [object]$ManagedExtension = $null,

        [AllowNull()]
        [object]$DohMode = $null,

        [AllowNull()]
        [object[]]$UrlBlocklist = $null
    )

    if (-not $PSBoundParameters.ContainsKey('ManagedExtension')) {
        $ManagedExtension = Test-OpenPathChromiumExtensionForcelistReady -Browser $Browser
    }

    if (-not $PSBoundParameters.ContainsKey('DohMode')) {
        $DohMode = Get-OpenPathChromiumDohMode -Browser $Browser
    }

    if (-not $PSBoundParameters.ContainsKey('UrlBlocklist')) {
        $UrlBlocklist = @(Get-OpenPathChromiumUrlBlocklist -Browser $Browser)
    }

    return [PSCustomObject]@{
        Installed = Test-OpenPathApprovedBrowserInstalled -BrowserInventory $BrowserInventory -BrowserName $BrowserName
        Approved = Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $ApprovedStudentBrowsers -Browser $Browser
        ManagedExtensionReady = Test-OpenPathReadinessTruthy -Value $ManagedExtension
        DohModeReady = Test-OpenPathChromiumDohModeReady -DohMode $DohMode
        UrlBlocklistReady = Test-OpenPathChromiumUrlBlocklistReady -UrlBlocklist $UrlBlocklist
    }
}

function Get-OpenPathChromiumReadinessFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedStudentBrowsers,

        [AllowNull()]
        [object]$BrowserInventory = $null,

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
        [object[]]$ChromeUrlBlocklist = $null
    )

    $edgeParameters = @{
        Browser = 'Edge'
        BrowserName = 'Microsoft Edge'
        ApprovedStudentBrowsers = $ApprovedStudentBrowsers
        BrowserInventory = $BrowserInventory
    }
    foreach ($parameterName in @('EdgeManagedExtension', 'EdgeDohMode', 'EdgeUrlBlocklist')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $targetName = $parameterName -replace '^Edge', ''
            $edgeParameters[$targetName] = (Get-Variable -Name $parameterName -ValueOnly)
        }
    }

    $chromeParameters = @{
        Browser = 'Chrome'
        BrowserName = 'Google Chrome'
        ApprovedStudentBrowsers = $ApprovedStudentBrowsers
        BrowserInventory = $BrowserInventory
    }
    foreach ($parameterName in @('ChromeManagedExtension', 'ChromeDohMode', 'ChromeUrlBlocklist')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $targetName = $parameterName -replace '^Chrome', ''
            $chromeParameters[$targetName] = (Get-Variable -Name $parameterName -ValueOnly)
        }
    }

    return [PSCustomObject]@{
        Edge = Get-OpenPathChromiumBrowserReadinessFacts @edgeParameters
        Chrome = Get-OpenPathChromiumBrowserReadinessFacts @chromeParameters
    }
}

function Get-OpenPathAppControlReadinessFacts {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$AppControlActive = $null
    )

    if (-not $PSBoundParameters.ContainsKey('AppControlActive')) {
        if (Get-Command -Name 'Test-OpenPathNonAdminAppControlActive' -ErrorAction SilentlyContinue) {
            $AppControlActive = Test-OpenPathNonAdminAppControlActive
        }
        else {
            $AppControlActive = $false
        }
    }

    return [PSCustomObject]@{
        Active = Test-OpenPathReadinessTruthy -Value $AppControlActive
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathFirefoxReadinessFacts',
    'Get-OpenPathChromiumReadinessFacts',
    'Get-OpenPathAppControlReadinessFacts',
    'Get-OpenPathGoogleGameBlockPatterns',
    'Get-OpenPathReadinessBrowserInventory',
    'Test-OpenPathApprovedBrowserInstalled',
    'Test-OpenPathChromiumDohModeReady',
    'Test-OpenPathChromiumExtensionForcelistReady',
    'Test-OpenPathChromiumUrlBlocklistReady',
    'Test-OpenPathFirefoxNativeHostRegistrationProof',
    'Test-OpenPathReadinessTruthy',
    'Test-OpenPathStudentBrowserApproved',
    'Test-OpenPathUnmanagedBrowserFindingsPresent'
)
