# OpenPath browser request readiness facts for Windows

Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\RequestSetup.State.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.EnforcementDecision.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.ReadinessFacts.psm1" -Force -ErrorAction Stop

function Test-OpenPathBrowserRequestSetupReady {
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $requestSetupState = Get-OpenPathRequestSetupState -Config $Config
    return [bool]$requestSetupState.Ready
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

function Get-OpenPathApprovedStudentBrowsers {
    param(
        [AllowNull()]
        [object]$Config
    )

    return @(Get-OpenPathApprovedStudentBrowsersDecision -Config $Config)
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

    if (-not $PSBoundParameters.ContainsKey('BrowserInventory')) {
        $BrowserInventory = Get-OpenPathReadinessBrowserInventory
    }

    $strictMode = Test-OpenPathManagedBrowserBoundaryStrictMode -Config $Config
    $approvedStudentBrowsers = @(Get-OpenPathApprovedStudentBrowsers -Config $Config)
    $firefoxFactParameters = @{}
    foreach ($parameterName in @('ManagedExtensionPolicy', 'NativeHostRegistered', 'NativeHostStatePresent', 'FirefoxMachinePolicyApplied')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $firefoxFactParameters[$parameterName] = (Get-Variable -Name $parameterName -ValueOnly)
        }
    }
    $firefoxFacts = Get-OpenPathFirefoxReadinessFacts @firefoxFactParameters

    $chromiumFactParameters = @{
        ApprovedStudentBrowsers = $approvedStudentBrowsers
        BrowserInventory = $BrowserInventory
    }
    foreach ($parameterName in @('EdgeManagedExtension', 'EdgeDohMode', 'EdgeUrlBlocklist', 'ChromeManagedExtension', 'ChromeDohMode', 'ChromeUrlBlocklist')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $chromiumFactParameters[$parameterName] = (Get-Variable -Name $parameterName -ValueOnly)
        }
    }
    $chromiumFacts = Get-OpenPathChromiumReadinessFacts @chromiumFactParameters

    $appControlFactParameters = @{}
    if ($PSBoundParameters.ContainsKey('AppControlActive')) {
        $appControlFactParameters.AppControlActive = $AppControlActive
    }
    $appControlFacts = Get-OpenPathAppControlReadinessFacts @appControlFactParameters
    $unmanagedBrowserFindingsPresent = Test-OpenPathUnmanagedBrowserFindingsPresent -BrowserInventory $BrowserInventory
    $decisionFacts = [PSCustomObject]@{
        StrictMode = $strictMode
        ApprovedStudentBrowsers = $approvedStudentBrowsers
        RequestSetupReady = Test-OpenPathBrowserRequestSetupReady -Config $Config
        FirefoxManagedExtensionReady = $firefoxFacts.ManagedExtensionReady
        FirefoxMachinePolicyApplied = $firefoxFacts.MachinePolicyApplied
        FirefoxNativeHostReady = $firefoxFacts.NativeHostReady
        AppControlActive = $appControlFacts.Active
        UnmanagedBrowserFindingsPresent = $unmanagedBrowserFindingsPresent
        BrowserInventory = $BrowserInventory
        Chromium = $chromiumFacts
    }

    return Get-OpenPathBrowserRequestReadinessDecision -Facts $decisionFacts
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserRequestReadiness',
    'Get-OpenPathApprovedStudentBrowsers',
    'Get-OpenPathGoogleGameBlockPatterns',
    'Test-OpenPathStudentBrowserApproved',
    'Test-OpenPathBrowserRequestSetupReady',
    'Test-OpenPathFirefoxNativeHostRegistrationProof'
)
