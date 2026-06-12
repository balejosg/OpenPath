# OpenPath browser request readiness fact collectors for Windows

Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.EnforcementDecision.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxPolicy.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxNativeHost.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\AppControl.psm1" -Force -ErrorAction SilentlyContinue

function Test-OpenPathFirefoxNativeHostRegistrationProof {
    <#
    .SYNOPSIS
    Checks whether the Firefox native host is fully registered on this machine.

    .DESCRIPTION
    Verifies that the manifest file, wrapper script, and state file are all present on disk, and
    that at least one of the expected registry entries reports a default value via reg.exe.
    All four conditions must hold; a missing registry entry alone is treated as unregistered.
    #>
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
    <#
    .SYNOPSIS
    Returns the registry path where managed policy values are stored for a given Chromium-based browser.
    #>
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
    <#
    .SYNOPSIS
    Reads a single named value from a registry key, returning null if the key or property is absent.
    #>
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
    <#
    .SYNOPSIS
    Reads all numerically named registry value entries from a key and returns them as an array of strings.

    .DESCRIPTION
    Chromium-family browsers store policy lists (extension forcelists, URL blocklists) as numbered
    entries under a sub-key.  This helper collects those entries in an order-independent way so
    callers can check for required values without concern for the index assigned by the OS.
    #>
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
    <#
    .SYNOPSIS
    Returns true when the managed extension update URL is present in the Chromium browser's force-install extension list.
    #>
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
    <#
    .SYNOPSIS
    Reads the DnsOverHttpsMode policy value for a Chromium-based browser from the registry.

    .NOTES
    Returns an empty string when the value is absent.  The caller compares the result against
    "off" to determine whether DNS-over-HTTPS is disabled as required by the enforcement policy.
    #>
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
    <#
    .SYNOPSIS
    Returns the URL blocklist entries currently applied to a Chromium-based browser via registry policy.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser
    )

    $policyPath = Get-OpenPathChromiumPolicyRegistryPath -Browser $Browser
    return @(Get-OpenPathRegistryListValues -Path "$policyPath\URLBlocklist")
}

function Get-OpenPathGoogleSearchBlockPattern {
    <#
    .SYNOPSIS
    Returns the URL pattern used to block Google Search in the Chromium URL blocklist policy.

    .NOTES
    The pattern is read from the browser policy spec when available; otherwise the maintained
    contract default is returned.
    #>
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
    <#
    .SYNOPSIS
    Returns the list of URL patterns used to block Google Doodle games and distracting Google pages in the Chromium URL blocklist policy.

    .NOTES
    Patterns are read from the browser policy spec when available; otherwise the maintained
    contract defaults covering snake arcade, Doodle subdomains, and logos are returned.
    #>
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
    <#
    .SYNOPSIS
    Returns true when the supplied URL blocklist contains all patterns required by the current policy spec.

    .NOTES
    Required patterns are assembled by combining the Google Search block pattern and the Google game
    block patterns sourced from the policy spec.  The check delegates the actual comparison to the
    pure decision layer.
    #>
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
    <#
    .SYNOPSIS
    Returns true when the given DNS-over-HTTPS mode value satisfies the enforcement policy requirement.
    #>
    param(
        [AllowNull()]
        [object]$DohMode = $null
    )

    return Test-OpenPathChromiumDohModeDecision -DohMode $DohMode
}

function Test-OpenPathReadinessTruthy {
    <#
    .SYNOPSIS
    Coerces an arbitrary probe result to a boolean, treating null as false.
    #>
    param(
        [AllowNull()]
        [object]$Value = $null
    )

    return Test-OpenPathBrowserDecisionTruthy -Value $Value
}

function Test-OpenPathStudentBrowserApproved {
    <#
    .SYNOPSIS
    Returns true when the given browser family appears in the list of browsers approved for students.
    #>
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
    <#
    .SYNOPSIS
    Collects the live browser inventory and returns a safe fallback with empty lists on error.

    .NOTES
    Used by readiness collectors that must tolerate missing or inaccessible inventory data without
    failing the entire readiness evaluation.
    #>
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
    <#
    .SYNOPSIS
    Returns true when the named browser appears in the approved-browsers list of the supplied inventory.
    #>
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
    <#
    .SYNOPSIS
    Returns true when the inventory contains at least one unmanaged browser or portable browser risk.
    #>
    param(
        [AllowNull()]
        [object]$BrowserInventory = $null
    )

    return Test-OpenPathUnmanagedBrowserFindingsPresentDecision -BrowserInventory $BrowserInventory
}

function Get-OpenPathFirefoxReadinessFacts {
    <#
    .SYNOPSIS
    Collects all Firefox readiness facts by probing the managed extension policy, native host
    registration, native host state file, and machine policy application.

    .DESCRIPTION
    Each probe is performed live unless the caller supplies a pre-collected value for the
    corresponding parameter, which allows tests to inject mocked results without touching the
    registry or filesystem.  The returned object includes individual readiness flags and is consumed
    by the request-readiness evaluation layer.
    #>
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
    <#
    .SYNOPSIS
    Collects the managed-extension, DNS-over-HTTPS mode, and URL blocklist readiness facts for a
    single Chromium-based browser by probing registry policy values.

    .DESCRIPTION
    Callers may supply pre-collected probe values for any of the three policy dimensions to allow
    test injection.  The result also includes whether the browser is installed in the approved
    inventory and whether the student configuration approves that browser family.
    #>
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
    <#
    .SYNOPSIS
    Collects readiness facts for both Edge and Chrome by running per-browser registry probes and
    returning a combined object with an Edge entry and a Chrome entry.

    .DESCRIPTION
    Callers may supply pre-collected probe values for any per-browser dimension.  The parameter
    names use an Edge or Chrome prefix; those prefixes are stripped and the values are forwarded
    to the per-browser fact collector.  Omitting a prefixed parameter causes the fact collector to
    perform the live registry probe for that dimension.
    #>
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
    <#
    .SYNOPSIS
    Determines whether application control is active and correctly configured for the approved browser set.

    .DESCRIPTION
    When no pre-collected value is supplied the function calls the app control probe if it is
    available; otherwise it defaults to inactive.  A structured active object is supported: if the
    object carries a BlocksUnapprovedEdge property and Edge is not in the approved list, the active
    flag is downgraded to false to prevent false-positive readiness when Edge is not actually blocked.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$AppControlActive = $null,

        [string[]]$ApprovedStudentBrowsers = @('Firefox')
    )

    if (-not $PSBoundParameters.ContainsKey('AppControlActive')) {
        if (Get-Command -Name 'Test-OpenPathNonAdminAppControlActive' -ErrorAction SilentlyContinue) {
            $AppControlActive = Test-OpenPathNonAdminAppControlActive -ApprovedBrowsers $ApprovedStudentBrowsers
        }
        else {
            $AppControlActive = $false
        }
    }

    $active = Test-OpenPathReadinessTruthy -Value $AppControlActive
    if ($AppControlActive -and $AppControlActive -isnot [bool]) {
        if ($AppControlActive.PSObject.Properties['Active']) {
            $active = Test-OpenPathReadinessTruthy -Value $AppControlActive.Active
        }
        if (
            $active -and
            -not (Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $ApprovedStudentBrowsers -Browser Edge) -and
            $AppControlActive.PSObject.Properties['BlocksUnapprovedEdge'] -and
            -not (Test-OpenPathReadinessTruthy -Value $AppControlActive.BlocksUnapprovedEdge)
        ) {
            $active = $false
        }
    }

    return [PSCustomObject]@{
        Active = $active
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
