# OpenPath Browser Policies Module for Windows
# Manages Firefox and Chrome/Edge policies

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\PolicyStore.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxPolicy.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxConfig.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxNativeHost.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.ReadinessFacts.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.RequestReadiness.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Diagnostics.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.EnforcementStatus.psm1" -Force -ErrorAction Stop

function Get-OpenPathChromiumManagedMetadataPath {
    # returns the path to the chromium managed extension metadata file
    return "$script:OpenPathRoot\browser-extension\chromium-managed\metadata.json"
}

function Get-OpenPathChromiumManagedPolicy {
    # reads the chromium managed extension metadata and builds the policy object
    # returns null when the metadata file is absent or the api url is not configured
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $metadataPath = Get-OpenPathChromiumManagedMetadataPath
    if (-not (Test-Path $metadataPath)) {
        return $null
    }

    $config = $Config
    if (-not $PSBoundParameters.ContainsKey('Config')) {
        $config = Get-OpenPathConfig
    }
    if (-not $config -or -not $config.PSObject.Properties['apiUrl'] -or -not $config.apiUrl) {
        Write-OpenPathLog 'Chromium managed extension metadata found but apiUrl is not configured' -Level WARN
        return $null
    }

    try {
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-OpenPathLog "Failed to parse Chromium managed extension metadata: $_" -Level WARN
        return $null
    }

    if (-not $metadata.extensionId -or -not $metadata.version) {
        Write-OpenPathLog 'Chromium managed extension metadata is incomplete' -Level WARN
        return $null
    }

    $apiBaseUrl = ([string]$config.apiUrl).TrimEnd('/')
    return [PSCustomObject]@{
        ExtensionId = [string]$metadata.extensionId
        Version = [string]$metadata.version
        UpdateUrl = "$apiBaseUrl/api/extensions/chromium/updates.xml"
    }
}

function Sync-OpenPathFirefoxNativeHostArtifacts {
    # delegates to the firefox native host module to copy staged native artifacts
    [CmdletBinding()]
    param(
        [string]$SourceRoot = "$script:OpenPathRoot\scripts"
    )

    Browser.FirefoxNativeHost\Sync-OpenPathFirefoxNativeHostArtifacts -SourceRoot $SourceRoot
}

function Sync-OpenPathFirefoxNativeHostState {
    # delegates to the firefox native host module to write the native state file
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null,

        [string]$WhitelistPath = "$script:OpenPathRoot\data\whitelist.txt",

        [switch]$ClearWhitelist
    )

    Browser.FirefoxNativeHost\Sync-OpenPathFirefoxNativeHostState -Config $Config -WhitelistPath $WhitelistPath -ClearWhitelist:$ClearWhitelist
}

function Get-OpenPathSmartAppControlState {
    # Phase 8e: re-exports the Smart App Control state reader from the Firefox
    # native host module; the watchdog script resolves it through Get-Command,
    # so the reader must be visible from the Browser module.
    [CmdletBinding()]
    param()

    Browser.FirefoxNativeHost\Get-OpenPathSmartAppControlState
}

function Register-OpenPathFirefoxNativeHost {
    # delegates to the firefox native host module to register the native messaging host manifest
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null,

        [switch]$ClearWhitelist,

        [switch]$PreserveExistingOnNotReady
    )

    Browser.FirefoxNativeHost\Register-OpenPathFirefoxNativeHost -Config $Config -ClearWhitelist:$ClearWhitelist -PreserveExistingOnNotReady:$PreserveExistingOnNotReady
}

function Unregister-OpenPathFirefoxNativeHost {
    # delegates to the firefox native host module to remove the native messaging host manifest
    [CmdletBinding()]
    param()

    Browser.FirefoxNativeHost\Unregister-OpenPathFirefoxNativeHost
}

function Get-OpenPathBrowserDoctorReport {
    # delegates to the browser diagnostics module to collect the full browser doctor report
    [CmdletBinding()]
    param()

    Browser.Diagnostics\Get-OpenPathBrowserDoctorReport
}

function Get-OpenPathBrowserRequestReadiness {
    # delegates to the request readiness module to assess whether a browser request can proceed
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    Browser.RequestReadiness\Get-OpenPathBrowserRequestReadiness -Config $Config
}

function Get-OpenPathBrowserInventory {
    # delegates to the browser inventory module to detect installed browsers and optional cleanup
    [CmdletBinding()]
    param(
        [ValidateSet('ReportOnly', 'RemoveKnownInstallers')]
        [string]$Mode = 'ReportOnly',

        [AllowNull()]
        [object[]]$UninstallEntries = $null,

        [AllowNull()]
        [object[]]$FileCandidates = $null
    )

    $arguments = @{
        Mode = $Mode
    }
    if ($PSBoundParameters.ContainsKey('UninstallEntries')) {
        $arguments.UninstallEntries = $UninstallEntries
    }
    if ($PSBoundParameters.ContainsKey('FileCandidates')) {
        $arguments.FileCandidates = $FileCandidates
    }

    Browser.Inventory\Get-OpenPathBrowserInventory @arguments
}

function Get-OpenPathBrowserInventoryUninstallEntries {
    # delegates to the browser inventory module to return the uninstall registry entries
    [CmdletBinding()]
    param()

    Browser.Inventory\Get-OpenPathBrowserInventoryUninstallEntries
}

function Get-OpenPathBrowserInventoryFileCandidates {
    # delegates to the browser inventory module to return filesystem candidates for installed browsers
    [CmdletBinding()]
    param()

    Browser.Inventory\Get-OpenPathBrowserInventoryFileCandidates
}

function Get-OpenPathBrowserEnforcementStatus {
    # delegates to the enforcement status module to summarize per-browser policy enforcement state
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    if ($PSBoundParameters.ContainsKey('Config')) {
        Browser.EnforcementStatus\Get-OpenPathBrowserEnforcementStatus -Config $Config
    }
    else {
        Browser.EnforcementStatus\Get-OpenPathBrowserEnforcementStatus
    }
}

function Sync-OpenPathFirefoxManagedExtensionPolicy {
    # delegates to the firefox policy module to write the managed extension policy file
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    if ($PSBoundParameters.ContainsKey('Config')) {
        Browser.FirefoxPolicy\Sync-OpenPathFirefoxManagedExtensionPolicy -Config $Config
    }
    else {
        Browser.FirefoxPolicy\Sync-OpenPathFirefoxManagedExtensionPolicy
    }
}

function Test-OpenPathFirefoxManagedExtensionReady {
    # delegates to the firefox policy module to check whether the managed extension is ready
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null,

        [switch]$RequireRuntimeRegistration
    )

    if ($PSBoundParameters.ContainsKey('Config')) {
        Browser.FirefoxPolicy\Test-OpenPathFirefoxManagedExtensionReady `
            -Config $Config `
            -RequireRuntimeRegistration:$RequireRuntimeRegistration
    }
    else {
        Browser.FirefoxPolicy\Test-OpenPathFirefoxManagedExtensionReady `
            -RequireRuntimeRegistration:$RequireRuntimeRegistration
    }
}

function Sync-OpenPathFirefoxNetworkAutoconfig {
    # delegates to the firefox config module to write the network autoconfig file
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Browser.FirefoxConfig\Sync-OpenPathFirefoxNetworkAutoconfig
}

function Get-OpenPathChromiumPolicyBrowsers {
    # returns the policy-store key (no HKLM prefix) and display registry path for each chromium browser
    return @(
        [PSCustomObject]@{ StoreKey = 'Software\Policies\Google\Chrome'; RegPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome' },
        [PSCustomObject]@{ StoreKey = 'Software\Policies\Microsoft\Edge'; RegPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
    )
}

function Clear-OpenPathLegacyChromiumListValues {
    # pre-store versions rewrote list keys directly in the registry on every run, so their numbered
    # values are neither in the ledger nor in Registry.pol and the diff-based mirror would never
    # delete them. When the list key is registry-only (owner Unknown) remove those numbered values
    # once; after the first sync the values live in Registry.pol and this never repeats.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ListKey
    )

    try {
        $owner = Get-OpenPathPolicyValueOwner -Key $ListKey -ValueName ''
        if (-not $owner -or [string]$owner.Owner -ne 'Unknown') {
            return
        }

        $regPath = "HKLM:\$ListKey"
        if (-not (Test-Path -LiteralPath $regPath)) {
            return
        }

        $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
        if (-not $props) {
            return
        }

        $numberedNames = @($props.PSObject.Properties |
            Where-Object { $_.Name -match '^\d+$' } |
            ForEach-Object { $_.Name })
        foreach ($name in $numberedNames) {
            Remove-ItemProperty -LiteralPath $regPath -Name $name -Force -ErrorAction Stop
        }
        if ($numberedNames.Count -gt 0) {
            Write-OpenPathLog "Removed $($numberedNames.Count) legacy registry-only policy value(s) from $regPath before syncing through the local GPO store" -Level INFO
        }
    }
    catch {
        Write-OpenPathLog "Could not clear legacy Chromium policy values for ${ListKey}: $_" -Level WARN
    }
}

function Test-OpenPathChromiumStoreResult {
    # logs a WARN and returns $false when a policy store result reports a failure
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [AllowEmptyString()]
        [string]$ValueName = ''
    )

    $target = $Key
    if ($ValueName) {
        $target = "$Key|$ValueName"
    }

    if (-not $Result) {
        Write-OpenPathLog "Chromium policy store returned no result for $target" -Level WARN
        return $false
    }

    $failureCode = ''
    if ($Result.PSObject.Properties['FailureCode']) {
        $failureCode = [string]$Result.FailureCode
    }

    if ($failureCode -eq 'policy-externally-managed') {
        Write-OpenPathLog "Chromium policy $target is managed by $($Result.Owner) ($($Result.GpoName)); OpenPath cannot write it" -Level WARN
        return $false
    }

    if ($failureCode) {
        Write-OpenPathLog "Failed to write Chromium policy ${target}: $failureCode" -Level WARN
        return $false
    }

    if ($Result.PSObject.Properties['Applied'] -and -not $Result.Applied) {
        Write-OpenPathLog "Chromium policy $target was not applied" -Level WARN
        return $false
    }

    return $true
}

function Set-ChromePolicy {
    # writes chromium url blocklist and search provider policies for chrome and edge through the local GPO store
    # also installs the managed extension force-list entry when metadata is present
    # returns $false when any policy could not be written (for example a domain GPO or MDM owns it)
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$BlockedPaths = @(),

        [AllowNull()]
        [object]$Config = $null
    )

    if (-not $PSCmdlet.ShouldProcess("Chrome/Edge", "Configure browser policies via local GPO store")) {
        return $false
    }

    Write-OpenPathLog "Configuring Chrome/Edge policies..."
    if ($PSBoundParameters.ContainsKey('Config')) {
        $managedExtensionPolicy = Get-OpenPathChromiumManagedPolicy -Config $Config
    }
    else {
        $managedExtensionPolicy = Get-OpenPathChromiumManagedPolicy
    }
    $policySpec = Get-OpenPathBrowserPolicySpec
    $chromiumSpec = $policySpec.chromium

    $blocklistValues = New-Object System.Collections.Generic.List[string]
    foreach ($path in $BlockedPaths) {
        if ($path) {
            $blocklistValues.Add([string]$path)
        }
    }
    $blocklistValues.Add([string]$chromiumSpec.googleSearchBlock)
    foreach ($googleGameBlock in @($chromiumSpec.googleGameBlocks)) {
        if ($googleGameBlock) {
            $blocklistValues.Add([string]$googleGameBlock)
        }
    }

    $scalarValues = @(
        [PSCustomObject]@{ Name = 'DefaultSearchProviderEnabled'; Type = 'DWord'; Value = ([int]$chromiumSpec.defaultSearchProviderEnabled) },
        [PSCustomObject]@{ Name = 'DefaultSearchProviderName'; Type = 'String'; Value = ([string]$chromiumSpec.defaultSearchProviderName) },
        [PSCustomObject]@{ Name = 'DefaultSearchProviderSearchURL'; Type = 'String'; Value = ([string]$chromiumSpec.defaultSearchProviderSearchURL) },
        [PSCustomObject]@{ Name = 'DnsOverHttpsMode'; Type = 'String'; Value = ([string]$chromiumSpec.dnsOverHttpsMode) }
    )

    $allApplied = $true
    foreach ($browser in @(Get-OpenPathChromiumPolicyBrowsers)) {
        $browserApplied = $true
        try {
            $blocklistKey = "$($browser.StoreKey)\URLBlocklist"
            Clear-OpenPathLegacyChromiumListValues -ListKey $blocklistKey
            $result = Sync-OpenPathManagedPolicyList -Key $blocklistKey -Values @($blocklistValues.ToArray())
            if (-not (Test-OpenPathChromiumStoreResult -Result $result -Key $blocklistKey)) {
                $browserApplied = $false
            }

            foreach ($scalar in $scalarValues) {
                $result = Set-OpenPathManagedPolicyValue `
                    -Key $browser.StoreKey `
                    -ValueName $scalar.Name `
                    -Type $scalar.Type `
                    -Value $scalar.Value
                if (-not (Test-OpenPathChromiumStoreResult -Result $result -Key $browser.StoreKey -ValueName $scalar.Name)) {
                    $browserApplied = $false
                }
            }

            if ($managedExtensionPolicy) {
                $forcelistKey = "$($browser.StoreKey)\ExtensionInstallForcelist"
                Clear-OpenPathLegacyChromiumListValues -ListKey $forcelistKey
                $forcelistValue = "$($managedExtensionPolicy.ExtensionId);$($managedExtensionPolicy.UpdateUrl)"
                $result = Sync-OpenPathManagedPolicyList -Key $forcelistKey -Values @($forcelistValue)
                if (-not (Test-OpenPathChromiumStoreResult -Result $result -Key $forcelistKey)) {
                    $browserApplied = $false
                }
            }

            if ($browserApplied) {
                Write-OpenPathLog "Policies written to: $($browser.RegPath)"
            }
        }
        catch {
            Write-OpenPathLog "Failed to set policies for $($browser.RegPath) : $_" -Level WARN
            $browserApplied = $false
        }

        if (-not $browserApplied) {
            $allApplied = $false
        }
    }

    return $allApplied
}

function Write-OpenPathChromiumRemoveOutcome {
    # logs a WARN (never an error) when the policy store could not remove an OpenPath-owned entry
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [AllowEmptyString()]
        [string]$ValueName = ''
    )

    if (-not $Result -or -not $Result.PSObject.Properties['FailureCode'] -or -not $Result.FailureCode) {
        return
    }

    $target = $Key
    if ($ValueName) {
        $target = "$Key|$ValueName"
    }
    Write-OpenPathLog "Could not remove Chromium policy ${target}: $($Result.FailureCode)" -Level WARN
}

function Remove-BrowserPolicy {
    # removes OpenPath browser policies (chromium via the local GPO store, firefox policy files)
    # foreign entries in the same policy keys are left untouched
    # when preserve flag is set, keeps the firefox managed extension policy instead of deleting it
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$PreserveFirefoxManagedExtension
    )

    if (-not $PSCmdlet.ShouldProcess("All browsers", "Remove OpenPath browser policies")) {
        return
    }

    Write-OpenPathLog "Removing browser policies..."

    $firefoxPaths = @(
        "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json"
    )

    if (-not $PreserveFirefoxManagedExtension) {
        foreach ($path in $firefoxPaths) {
            if (Test-Path $path) {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($PreserveFirefoxManagedExtension) {
        try {
            Sync-OpenPathFirefoxManagedExtensionPolicy | Out-Null
        }
        catch {
            Write-OpenPathLog "Failed to refresh preserved Firefox managed extension policy: $_" -Level WARN
        }
    }
    else {
        Browser.FirefoxPolicy\Remove-OpenPathFirefoxMachineExtensionPolicy | Out-Null
    }
    Browser.FirefoxConfig\Remove-OpenPathFirefoxNetworkAutoconfig | Out-Null

    $scalarNames = @(
        'DefaultSearchProviderEnabled',
        'DefaultSearchProviderName',
        'DefaultSearchProviderSearchURL',
        'DnsOverHttpsMode'
    )

    foreach ($browser in @(Get-OpenPathChromiumPolicyBrowsers)) {
        foreach ($listName in @('URLBlocklist', 'ExtensionInstallForcelist')) {
            $listKey = "$($browser.StoreKey)\$listName"
            try {
                # an upgrade that never re-synced leaves registry-only legacy values the ledger does not know
                Clear-OpenPathLegacyChromiumListValues -ListKey $listKey
                $result = Remove-OpenPathManagedPolicyList -Key $listKey
                Write-OpenPathChromiumRemoveOutcome -Result $result -Key $listKey
            }
            catch {
                Write-OpenPathLog "Failed to remove Chromium policy ${listKey}: $_" -Level WARN
            }
        }

        foreach ($scalarName in $scalarNames) {
            try {
                $result = Remove-OpenPathManagedPolicyValue -Key $browser.StoreKey -ValueName $scalarName
                Write-OpenPathChromiumRemoveOutcome -Result $result -Key $browser.StoreKey -ValueName $scalarName
            }
            catch {
                Write-OpenPathLog "Failed to remove Chromium policy $($browser.StoreKey)|${scalarName}: $_" -Level WARN
            }
        }
    }

    Write-OpenPathLog "Browser policies removed"
}

function Set-AllBrowserPolicy {
    # applies policy to all supported browsers: firefox extension, network autoconfig, and chromium
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$BlockedPaths = @(),

        [AllowNull()]
        [object]$Config = $null
    )

    if (-not $PSCmdlet.ShouldProcess("All browsers", "Configure browser policies")) {
        return
    }

    if ($PSBoundParameters.ContainsKey('Config')) {
        Sync-OpenPathFirefoxManagedExtensionPolicy -Config $Config
    }
    else {
        Sync-OpenPathFirefoxManagedExtensionPolicy
    }
    Sync-OpenPathFirefoxNetworkAutoconfig
    if ($PSBoundParameters.ContainsKey('Config')) {
        Set-ChromePolicy -BlockedPaths $BlockedPaths -Config $Config
    }
    else {
        Set-ChromePolicy -BlockedPaths $BlockedPaths
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserDoctorReport',
    'Get-OpenPathBrowserRequestReadiness',
    'Get-OpenPathFirefoxReadinessFacts',
    'Get-OpenPathChromiumReadinessFacts',
    'Get-OpenPathAppControlReadinessFacts',
    'Get-OpenPathBrowserInventory',
    'Get-OpenPathBrowserInventoryUninstallEntries',
    'Get-OpenPathBrowserInventoryFileCandidates',
    'Get-OpenPathBrowserEnforcementStatus',
    'Register-OpenPathFirefoxNativeHost',
    'Sync-OpenPathFirefoxNativeHostArtifacts',
    'Sync-OpenPathFirefoxNativeHostState',
    # Phase 8e: watchdog-visible Smart App Control state reader.
    'Get-OpenPathSmartAppControlState',
    # Phase 8b: the compiled-host ensure/health entrypoints were only visible
    # inside their module, so the self-update retry, the watchdog health report
    # and the installer SAC notice silently skipped them (Get-Command found
    # nothing). They are re-exported here so every Browser consumer resolves
    # them.
    'Invoke-OpenPathFirefoxNativeHostCompiledEnsure',
    'Get-OpenPathFirefoxNativeHostCompiledHealth',
    'Unregister-OpenPathFirefoxNativeHost',
    'Sync-OpenPathFirefoxManagedExtensionPolicy',
    'Test-OpenPathFirefoxManagedExtensionReady',
    # Local GPO policy store: the installer forces a Group Policy refresh before
    # the readiness check, and uninstall removes legacy-id Firefox entries
    # through the store; both consume Browser.psm1 only.
    'Invoke-OpenPathPolicyRefresh',
    'Remove-OpenPathFirefoxMachineExtensionPolicy',
    'Sync-OpenPathFirefoxNetworkAutoconfig',
    'Set-ChromePolicy',
    'Remove-BrowserPolicy',
    'Set-AllBrowserPolicy'
)
