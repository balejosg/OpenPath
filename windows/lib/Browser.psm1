# OpenPath Browser Policies Module for Windows
# Manages Firefox and Chrome/Edge policies

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
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

function Register-OpenPathFirefoxNativeHost {
    # delegates to the firefox native host module to register the native messaging host manifest
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null,

        [switch]$ClearWhitelist
    )

    Browser.FirefoxNativeHost\Register-OpenPathFirefoxNativeHost -Config $Config -ClearWhitelist:$ClearWhitelist
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

function Set-ChromePolicy {
    # writes chromium url blocklist and search provider policy registry keys for chrome and edge
    # also installs the managed extension force-list entry when metadata is present
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$BlockedPaths = @(),

        [AllowNull()]
        [object]$Config = $null
    )

    if (-not $PSCmdlet.ShouldProcess("Chrome/Edge", "Configure browser policies via Registry")) {
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

    $regPaths = @(
        "HKLM:\SOFTWARE\Policies\Google\Chrome",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    )

    foreach ($regPath in $regPaths) {
        try {
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force | Out-Null
            }

            $blocklistPath = "$regPath\URLBlocklist"
            if (Test-Path $blocklistPath) {
                Remove-Item $blocklistPath -Recurse -Force
            }
            New-Item -Path $blocklistPath -Force | Out-Null

            $i = 1
            foreach ($path in $BlockedPaths) {
                if ($path) {
                    Set-ItemProperty -Path $blocklistPath -Name $i -Value $path
                    $i++
                }
            }

            Set-ItemProperty -Path $blocklistPath -Name $i -Value ([string]$chromiumSpec.googleSearchBlock)
            $i++
            foreach ($googleGameBlock in @($chromiumSpec.googleGameBlocks)) {
                if ($googleGameBlock) {
                    Set-ItemProperty -Path $blocklistPath -Name $i -Value ([string]$googleGameBlock)
                    $i++
                }
            }
            Set-ItemProperty -Path $regPath -Name "DefaultSearchProviderEnabled" -Value ([int]$chromiumSpec.defaultSearchProviderEnabled) -Type DWord
            Set-ItemProperty -Path $regPath -Name "DefaultSearchProviderName" -Value ([string]$chromiumSpec.defaultSearchProviderName)
            Set-ItemProperty -Path $regPath -Name "DefaultSearchProviderSearchURL" -Value ([string]$chromiumSpec.defaultSearchProviderSearchURL)
            Set-ItemProperty -Path $regPath -Name "DnsOverHttpsMode" -Value ([string]$chromiumSpec.dnsOverHttpsMode) -Type String

            if ($managedExtensionPolicy) {
                $forcelistPath = "$regPath\ExtensionInstallForcelist"
                if (Test-Path $forcelistPath) {
                    Remove-Item $forcelistPath -Recurse -Force
                }
                New-Item -Path $forcelistPath -Force | Out-Null
                Set-ItemProperty -Path $forcelistPath -Name 1 -Value "$($managedExtensionPolicy.ExtensionId);$($managedExtensionPolicy.UpdateUrl)"
            }

            Write-OpenPathLog "Policies written to: $regPath"
        }
        catch {
            Write-OpenPathLog "Failed to set policies for $regPath : $_" -Level WARN
        }
    }

    return $true
}

function Remove-BrowserPolicy {
    # removes all browser policy registry keys and policy files
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

    $regPaths = @(
        "HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist",
        "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
    )

    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
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
    'Unregister-OpenPathFirefoxNativeHost',
    'Sync-OpenPathFirefoxManagedExtensionPolicy',
    'Test-OpenPathFirefoxManagedExtensionReady',
    'Sync-OpenPathFirefoxNetworkAutoconfig',
    'Set-ChromePolicy',
    'Remove-BrowserPolicy',
    'Set-AllBrowserPolicy'
)
