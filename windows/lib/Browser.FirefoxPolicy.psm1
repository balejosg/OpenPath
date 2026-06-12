# OpenPath Firefox managed extension policy helpers for Windows

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop

function Get-OpenPathFirefoxExtensionRoot {
    <#
    .SYNOPSIS
    Returns the local path where the unsigned Firefox extension bundle is stored.
    #>
    return "$script:OpenPathRoot\browser-extension\firefox"
}

function Get-OpenPathFirefoxReleaseMetadataPath {
    <#
    .SYNOPSIS
    Returns the local path to the staged Firefox release extension metadata file.
    #>
    return "$script:OpenPathRoot\browser-extension\firefox-release\metadata.json"
}

function Get-OpenPathFirefoxReleaseXpiPath {
    <#
    .SYNOPSIS
    Returns the local path to the staged signed Firefox extension XPI file.
    #>
    return "$script:OpenPathRoot\browser-extension\firefox-release\openpath-firefox-extension.xpi"
}

function Get-OpenPathDefaultFirefoxExtensionId {
    <#
    .SYNOPSIS
    Returns the well-known fallback extension ID used when no metadata is available.
    #>
    return 'openpath-block-monitor@openpath'
}

function Get-OpenPathFirefoxMachinePolicyRegistryPath {
    <#
    .SYNOPSIS
    Returns the registry path where Firefox machine-level managed policies are stored.
    #>
    return 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
}

function ConvertFrom-OpenPathFirefoxMachineExtensionSettings {
    <#
    .SYNOPSIS
    Parses the Firefox machine ExtensionSettings registry multi-string value into an ordered dictionary.
    #>
    param(
        [AllowNull()]
        [object]$Value
    )

    $settings = [ordered]@{}
    foreach ($entry in @($Value)) {
        if (-not $entry) {
            continue
        }

        try {
            $parsed = [string]$entry | ConvertFrom-Json -ErrorAction Stop
            foreach ($property in @($parsed.PSObject.Properties)) {
                $settings[$property.Name] = $property.Value
            }
        }
        catch {
            Write-OpenPathLog "Failed to parse Firefox machine ExtensionSettings registry value: $_" -Level WARN
        }
    }

    return $settings
}

function Get-OpenPathFirefoxMachineExtensionSettings {
    <#
    .SYNOPSIS
    Reads and parses the Firefox machine ExtensionSettings registry value, returning an empty dictionary when absent.
    #>
    $registryPath = Get-OpenPathFirefoxMachinePolicyRegistryPath
    try {
        $registryValue = Get-ItemProperty -Path $registryPath -Name 'ExtensionSettings' -ErrorAction Stop
        return ConvertFrom-OpenPathFirefoxMachineExtensionSettings -Value $registryValue.ExtensionSettings
    }
    catch {
        return [ordered]@{}
    }
}

function ConvertTo-OpenPathFirefoxMachineExtensionSettingsValue {
    <#
    .SYNOPSIS
    Serializes an extension settings dictionary to the multi-string format expected by the registry.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Settings
    )

    $root = [ordered]@{}
    foreach ($key in $Settings.Keys) {
        $root[[string]$key] = $Settings[$key]
    }

    return @($root | ConvertTo-Json -Depth 10 -Compress)
}

function Get-OpenPathConfiguredFirefoxManagedExtensionPolicy {
    <#
    .SYNOPSIS
    Returns a managed extension policy from explicit config properties, or null when config is incomplete.
    #>
    param(
        [AllowNull()]
        [object]$Config,

        [AllowNull()]
        [object]$Metadata = $null
    )

    $configuredExtensionId = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'firefoxExtensionId'
    $configuredInstallUrl = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'firefoxExtensionInstallUrl'

    if ($configuredExtensionId -and $configuredInstallUrl) {
        return [PSCustomObject]@{
            ExtensionId = $configuredExtensionId
            InstallUrl = Add-OpenPathFirefoxManagedApiInstallUrlVersion `
                -InstallUrl $configuredInstallUrl `
                -Metadata $Metadata
            Source = 'configured-install-url'
        }
    }

    if ($configuredExtensionId -or $configuredInstallUrl) {
        Write-OpenPathLog 'Firefox signed extension config is incomplete; both firefoxExtensionId and firefoxExtensionInstallUrl are required' -Level WARN
    }

    return $null
}

function Get-OpenPathFirefoxReleaseMetadata {
    <#
    .SYNOPSIS
    Reads and parses the staged Firefox release extension metadata JSON file, returning null when absent or invalid.
    #>
    $metadataPath = Get-OpenPathFirefoxReleaseMetadataPath
    if (-not (Test-Path $metadataPath)) {
        return $null
    }

    try {
        return Get-Content $metadataPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-OpenPathLog "Failed to parse Firefox release extension metadata: $_" -Level WARN
        return $null
    }
}

function Get-OpenPathFirefoxReleaseExtensionId {
    <#
    .SYNOPSIS
    Extracts the extension ID string from a release metadata object, returning an empty string when absent.
    #>
    param(
        [AllowNull()]
        [object]$Metadata
    )

    if ($Metadata -and $Metadata.PSObject.Properties['extensionId'] -and $Metadata.extensionId) {
        return ([string]$Metadata.extensionId).Trim()
    }

    return ''
}

function Get-OpenPathFirefoxReleaseMetadataVersion {
    <#
    .SYNOPSIS
    Extracts the version string from a release metadata object, returning an empty string when absent.
    #>
    param(
        [AllowNull()]
        [object]$Metadata
    )

    if ($Metadata -and $Metadata.PSObject.Properties['version'] -and $Metadata.version) {
        return ([string]$Metadata.version).Trim()
    }

    return ''
}

function Add-OpenPathFirefoxManagedApiInstallUrlVersion {
    <#
    .SYNOPSIS
    Appends or replaces the openpath_version query parameter on a managed API install URL using the metadata version.
    .DESCRIPTION
    Only modifies URLs that match the managed API path pattern. Non-matching URLs are returned unchanged.
    If either the URL or version is empty the original URL is returned unchanged.
    #>
    param(
        [AllowNull()]
        [string]$InstallUrl,

        [AllowNull()]
        [object]$Metadata
    )

    $url = ([string]$InstallUrl).Trim()
    $version = Get-OpenPathFirefoxReleaseMetadataVersion -Metadata $Metadata
    if (-not $url -or -not $version) {
        return $url
    }

    if ($url -notmatch '^https?://' -or $url -notmatch '/api/extensions/firefox/openpath\.xpi(?:[?#]|$)') {
        return $url
    }

    $encodedVersion = [uri]::EscapeDataString($version)
    $fragment = ''
    $urlWithoutFragment = $url
    $fragmentIndex = $url.IndexOf('#')
    if ($fragmentIndex -ge 0) {
        $fragment = $url.Substring($fragmentIndex)
        $urlWithoutFragment = $url.Substring(0, $fragmentIndex)
    }

    if ($urlWithoutFragment -match '([?&])openpath_version=') {
        return (($urlWithoutFragment -replace '([?&])openpath_version=[^&]*', "`${1}openpath_version=$encodedVersion") + $fragment)
    }

    $separator = if ($urlWithoutFragment.Contains('?')) { '&' } else { '?' }
    return "$urlWithoutFragment${separator}openpath_version=$encodedVersion$fragment"
}

function Resolve-OpenPathFirefoxReleaseInstallSpec {
    <#
    .SYNOPSIS
    Resolves the best available Firefox extension install source from config and local staged artifacts.
    .DESCRIPTION
    Prefers the managed API URL when both an API base URL and a local signed XPI are present.
    Falls back to a local file URL if the XPI exists without an API base URL, then to the metadata
    install URL. Returns null when no valid source can be resolved.
    #>
    param(
        [AllowNull()]
        [object]$Config,

        [AllowNull()]
        [object]$Metadata
    )

    $apiBaseUrl = Get-OpenPathConfigTrimmedValue -Config $Config -PropertyName 'apiUrl'
    if ($apiBaseUrl) {
        $apiBaseUrl = $apiBaseUrl.TrimEnd('/')
    }

    $signedXpiPath = Get-OpenPathFirefoxReleaseXpiPath
    if ($apiBaseUrl -and (Test-Path $signedXpiPath)) {
        return [PSCustomObject]@{
            InstallUrl = Add-OpenPathFirefoxManagedApiInstallUrlVersion `
                -InstallUrl "$apiBaseUrl/api/extensions/firefox/openpath.xpi" `
                -Metadata $Metadata
            Source = 'managed-api'
        }
    }

    if (Test-Path $signedXpiPath) {
        return [PSCustomObject]@{
            InstallUrl = (ConvertTo-OpenPathFileUrl -Path $signedXpiPath)
            Source = 'staged-release'
        }
    }

    if ($Metadata -and $Metadata.PSObject.Properties['installUrl'] -and $Metadata.installUrl) {
        return [PSCustomObject]@{
            InstallUrl = ([string]$Metadata.installUrl).Trim()
            Source = 'metadata-install-url'
        }
    }

    return $null
}

function Get-OpenPathFirefoxManagedExtensionPolicy {
    <#
    .SYNOPSIS
    Resolves the effective Firefox managed extension policy from config and staged release artifacts.
    #>
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $config = $Config
    if (-not $PSBoundParameters.ContainsKey('Config')) {
        try {
            $config = Get-OpenPathConfig
        }
        catch {
            # Allow policy generation to proceed without a persisted config.
        }
    }

    $metadata = Get-OpenPathFirefoxReleaseMetadata

    $configuredPolicy = Get-OpenPathConfiguredFirefoxManagedExtensionPolicy -Config $config -Metadata $metadata
    if ($configuredPolicy) {
        return $configuredPolicy
    }

    if (-not $metadata) {
        return $null
    }

    $extensionId = Get-OpenPathFirefoxReleaseExtensionId -Metadata $metadata
    if (-not $extensionId) {
        Write-OpenPathLog 'Firefox release extension metadata is incomplete' -Level WARN
        return $null
    }

    $installSpec = Resolve-OpenPathFirefoxReleaseInstallSpec -Config $config -Metadata $metadata
    if (-not $installSpec) {
        Write-OpenPathLog 'Firefox release extension metadata did not resolve to a signed XPI source' -Level WARN
        return $null
    }

    return [PSCustomObject]@{
        ExtensionId = $extensionId
        InstallUrl = $installSpec.InstallUrl
        Source = $installSpec.Source
    }
}

function Set-OpenPathFirefoxMachineExtensionPolicy {
    <#
    .SYNOPSIS
    Writes or updates the Firefox machine ExtensionSettings registry entry for the managed extension.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagedExtensionPolicy
    )

    if (-not $ManagedExtensionPolicy.ExtensionId -or -not $ManagedExtensionPolicy.InstallUrl) {
        return $false
    }

    try {
        $registryPath = Get-OpenPathFirefoxMachinePolicyRegistryPath
        if (-not (Test-Path $registryPath)) {
            New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
        }

        $settings = Get-OpenPathFirefoxMachineExtensionSettings
        $settings[[string]$ManagedExtensionPolicy.ExtensionId] = [ordered]@{
            installation_mode = 'force_installed'
            install_url = [string]$ManagedExtensionPolicy.InstallUrl
        }

        $value = ConvertTo-OpenPathFirefoxMachineExtensionSettingsValue -Settings $settings
        New-ItemProperty -Path $registryPath -Name 'ExtensionSettings' -Value $value -PropertyType MultiString -Force -ErrorAction Stop | Out-Null
        Write-OpenPathLog "Firefox machine ExtensionSettings policy written to: $registryPath"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to set Firefox machine ExtensionSettings policy: $_" -Level WARN
        return $false
    }
}

function Test-OpenPathFirefoxMachineExtensionPolicy {
    <#
    .SYNOPSIS
    Returns true when the live registry entry matches the expected extension ID, mode, and install URL.
    #>
    param(
        [AllowNull()]
        [object]$ManagedExtensionPolicy = $null
    )

    if (-not $ManagedExtensionPolicy) {
        $ManagedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy
    }

    if (-not $ManagedExtensionPolicy -or -not $ManagedExtensionPolicy.ExtensionId -or -not $ManagedExtensionPolicy.InstallUrl) {
        return $false
    }

    $settings = Get-OpenPathFirefoxMachineExtensionSettings
    if (-not $settings.Contains([string]$ManagedExtensionPolicy.ExtensionId)) {
        return $false
    }

    $entry = $settings[[string]$ManagedExtensionPolicy.ExtensionId]
    if (-not $entry) {
        return $false
    }

    $installMode = if ($entry.PSObject.Properties['installation_mode']) { [string]$entry.installation_mode } else { '' }
    $installUrl = if ($entry.PSObject.Properties['install_url']) { [string]$entry.install_url } else { '' }

    return ($installMode -eq 'force_installed' -and $installUrl -eq [string]$ManagedExtensionPolicy.InstallUrl)
}

function New-OpenPathFirefoxManagedExtensionReadyResult {
    <#
    .SYNOPSIS
    Constructs a standardized readiness result object for Firefox managed extension checks.
    #>
    param(
        [bool]$Ready,

        [string]$FailureCode = '',

        [string]$Message = '',

        [string]$PolicyPath = '',

        [bool]$ExtensionInstalled = $false,

        [bool]$ExtensionActive = $false,

        [string]$InstallUrl = '',

        [string]$ExtensionId = '',

        [string]$FirefoxPath = '',

        [string]$ProfilePath = ''
    )

    return [PSCustomObject]@{
        Ready = $Ready
        FailureCode = $FailureCode
        Message = $Message
        PolicyPath = $PolicyPath
        ExtensionInstalled = $ExtensionInstalled
        ExtensionActive = $ExtensionActive
        InstallUrl = $InstallUrl
        ExtensionId = $ExtensionId
        FirefoxPath = $FirefoxPath
        ProfilePath = $ProfilePath
    }
}

function Resolve-OpenPathFirefoxReleaseExecutable {
    <#
    .SYNOPSIS
    Returns the path to the installed Firefox Release executable, or an empty string when not found.
    #>
    $candidates = @(
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return [string]$candidate
        }
    }

    return ''
}

function Get-OpenPathFirefoxProfileExtensionEvidence {
    <#
    .SYNOPSIS
    Inspects a Firefox profile directory for evidence that the managed extension is installed and active.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilePath,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionId
    )

    $registryPath = Join-Path $ProfilePath 'extensions.json'
    $profileExtensionPath = Join-Path (Join-Path $ProfilePath 'extensions') "$ExtensionId.xpi"
    $registryAddon = $null

    if (Test-Path $registryPath) {
        try {
            $registry = Get-Content $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $registryAddon = @($registry.addons | Where-Object { $_.id -eq $ExtensionId } | Select-Object -First 1)[0]
        }
        catch {
            $registryAddon = $null
        }
    }

    $registryAddonPresent = $null -ne $registryAddon
    $profileExtensionPresent = Test-Path $profileExtensionPath
    $registryAddonActive = $false
    if ($registryAddonPresent) {
        $activeValue = if ($registryAddon.PSObject.Properties['active']) { $registryAddon.active } else { $true }
        $userDisabled = if ($registryAddon.PSObject.Properties['userDisabled']) { [bool]$registryAddon.userDisabled } else { $false }
        $registryAddonActive = ([bool]$activeValue) -and (-not $userDisabled)
    }

    return [PSCustomObject]@{
        RegistryPath = $registryPath
        ProfileExtensionPath = $profileExtensionPath
        RegistryAddonPresent = $registryAddonPresent
        ProfileExtensionPresent = $profileExtensionPresent
        ExtensionInstalled = [bool]($registryAddonPresent -or $profileExtensionPresent)
        ExtensionActive = [bool]($registryAddonActive -or ($profileExtensionPresent -and -not $registryAddonPresent))
    }
}

function Invoke-OpenPathFirefoxManagedExtensionRuntimeProbe {
    <#
    .SYNOPSIS
    Launches Firefox headless with a temporary profile and waits to confirm the managed extension is registered.
    .DESCRIPTION
    Creates an isolated temporary profile, starts Firefox headless, and polls for extension evidence up to
    the specified timeout. The temporary profile and process are cleaned up in the finally block regardless
    of the outcome.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FirefoxPath,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionId,

        [int]$TimeoutSeconds = 30
    )

    $profileDir = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-firefox-managed-extension-$([Guid]::NewGuid().ToString('N'))"
    $process = $null
    $evidence = $null

    try {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        $process = Start-Process `
            -FilePath $FirefoxPath `
            -ArgumentList @('-headless', '-no-remote', '-profile', $profileDir, 'about:blank') `
            -PassThru

        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
        do {
            $evidence = Get-OpenPathFirefoxProfileExtensionEvidence -ProfilePath $profileDir -ExtensionId $ExtensionId
            if ($evidence.ExtensionInstalled) {
                break
            }

            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)

        if (-not $evidence) {
            $evidence = Get-OpenPathFirefoxProfileExtensionEvidence -ProfilePath $profileDir -ExtensionId $ExtensionId
        }

        return [PSCustomObject]@{
            ExtensionInstalled = [bool]$evidence.ExtensionInstalled
            ExtensionActive = [bool]$evidence.ExtensionActive
            Message = if ($evidence.ExtensionInstalled) {
                'Firefox registered the managed extension in the runtime profile.'
            }
            else {
                "Firefox did not register $ExtensionId in extensions.json or profile XPI path."
            }
            ProfilePath = $profileDir
            RegistryPath = $evidence.RegistryPath
            ProfileExtensionPath = $evidence.ProfileExtensionPath
        }
    }
    catch {
        return [PSCustomObject]@{
            ExtensionInstalled = $false
            ExtensionActive = $false
            Message = "Firefox runtime registration probe failed: $($_.Exception.Message)"
            ProfilePath = $profileDir
            RegistryPath = Join-Path $profileDir 'extensions.json'
            ProfileExtensionPath = Join-Path (Join-Path $profileDir 'extensions') "$ExtensionId.xpi"
        }
    }
    finally {
        if ($process -and -not $process.HasExited) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }

        Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-OpenPathFirefoxManagedExtensionReady {
    <#
    .SYNOPSIS
    Checks whether the Firefox managed extension policy is fully configured and optionally verified at runtime.
    .DESCRIPTION
    Validates the machine registry policy and Firefox installation. When RequireRuntimeRegistration is set,
    also launches a headless Firefox probe to confirm the extension is registered in a live profile.
    #>
    param(
        [AllowNull()]
        [object]$Config = $null,

        [switch]$RequireRuntimeRegistration
    )

    $policyPath = Get-OpenPathFirefoxMachinePolicyRegistryPath
    if ($PSBoundParameters.ContainsKey('Config')) {
        $managedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy -Config $Config
    }
    else {
        $managedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy
    }

    if (-not $managedExtensionPolicy -or -not $managedExtensionPolicy.ExtensionId -or -not $managedExtensionPolicy.InstallUrl) {
        return New-OpenPathFirefoxManagedExtensionReadyResult `
            -Ready $false `
            -FailureCode 'firefox-managed-policy-missing' `
            -Message 'Firefox managed extension policy is missing; signed extension id and install_url are required.' `
            -PolicyPath $policyPath
    }

    $extensionId = [string]$managedExtensionPolicy.ExtensionId
    $installUrl = [string]$managedExtensionPolicy.InstallUrl
    $firefoxPath = Resolve-OpenPathFirefoxReleaseExecutable

    if (-not (Test-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $managedExtensionPolicy)) {
        return New-OpenPathFirefoxManagedExtensionReadyResult `
            -Ready $false `
            -FailureCode 'firefox-machine-policy-missing' `
            -Message "Firefox machine ExtensionSettings does not contain $extensionId with installation_mode=force_installed and install_url=$installUrl." `
            -PolicyPath $policyPath `
            -InstallUrl $installUrl `
            -ExtensionId $extensionId `
            -FirefoxPath $firefoxPath
    }

    if (-not $firefoxPath) {
        return New-OpenPathFirefoxManagedExtensionReadyResult `
            -Ready $false `
            -FailureCode 'firefox-release-missing' `
            -Message 'Firefox Release is not installed. Classroom unattended installs require Mozilla Firefox Release before the managed extension can be verified.' `
            -PolicyPath $policyPath `
            -InstallUrl $installUrl `
            -ExtensionId $extensionId
    }

    if (-not $RequireRuntimeRegistration) {
        return New-OpenPathFirefoxManagedExtensionReadyResult `
            -Ready $true `
            -Message 'Firefox managed extension policy is ready.' `
            -PolicyPath $policyPath `
            -InstallUrl $installUrl `
            -ExtensionId $extensionId `
            -FirefoxPath $firefoxPath
    }

    $runtimeProbe = Invoke-OpenPathFirefoxManagedExtensionRuntimeProbe -FirefoxPath $firefoxPath -ExtensionId $extensionId
    if (-not $runtimeProbe.ExtensionInstalled) {
        return New-OpenPathFirefoxManagedExtensionReadyResult `
            -Ready $false `
            -FailureCode 'firefox-extension-runtime-missing' `
            -Message ([string]$runtimeProbe.Message) `
            -PolicyPath $policyPath `
            -ExtensionInstalled $false `
            -ExtensionActive $false `
            -InstallUrl $installUrl `
            -ExtensionId $extensionId `
            -FirefoxPath $firefoxPath `
            -ProfilePath ([string]$runtimeProbe.ProfilePath)
    }

    if (-not $runtimeProbe.ExtensionActive) {
        return New-OpenPathFirefoxManagedExtensionReadyResult `
            -Ready $false `
            -FailureCode 'firefox-extension-runtime-inactive' `
            -Message "Firefox registered $extensionId but did not activate it." `
            -PolicyPath $policyPath `
            -ExtensionInstalled $true `
            -ExtensionActive $false `
            -InstallUrl $installUrl `
            -ExtensionId $extensionId `
            -FirefoxPath $firefoxPath `
            -ProfilePath ([string]$runtimeProbe.ProfilePath)
    }

    return New-OpenPathFirefoxManagedExtensionReadyResult `
        -Ready $true `
        -Message ([string]$runtimeProbe.Message) `
        -PolicyPath $policyPath `
        -ExtensionInstalled $true `
        -ExtensionActive $true `
        -InstallUrl $installUrl `
        -ExtensionId $extensionId `
        -FirefoxPath $firefoxPath `
        -ProfilePath ([string]$runtimeProbe.ProfilePath)
}

function Remove-OpenPathFirefoxMachineExtensionPolicy {
    <#
    .SYNOPSIS
    Removes the OpenPath extension entry from the Firefox machine ExtensionSettings registry value.
    .DESCRIPTION
    When the entry being removed was the last one, the entire ExtensionSettings registry value is deleted.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ManagedExtensionPolicy = $null
    )

    if (-not $ManagedExtensionPolicy) {
        $ManagedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy
    }

    try {
        $registryPath = Get-OpenPathFirefoxMachinePolicyRegistryPath
        $settings = Get-OpenPathFirefoxMachineExtensionSettings
        $extensionId = if ($ManagedExtensionPolicy -and $ManagedExtensionPolicy.ExtensionId) {
            [string]$ManagedExtensionPolicy.ExtensionId
        }
        else {
            Get-OpenPathDefaultFirefoxExtensionId
        }

        if (-not $settings.Contains($extensionId)) {
            return $false
        }

        $settings.Remove($extensionId)
        if ($settings.Count -eq 0) {
            Remove-ItemProperty -Path $registryPath -Name 'ExtensionSettings' -ErrorAction SilentlyContinue
        }
        else {
            $value = ConvertTo-OpenPathFirefoxMachineExtensionSettingsValue -Settings $settings
            New-ItemProperty -Path $registryPath -Name 'ExtensionSettings' -Value $value -PropertyType MultiString -Force -ErrorAction Stop | Out-Null
        }

        Write-OpenPathLog "Firefox machine ExtensionSettings OpenPath entry removed from: $registryPath"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to remove Firefox machine ExtensionSettings policy: $_" -Level WARN
        return $false
    }
}

function Sync-OpenPathFirefoxManagedExtensionPolicy {
    <#
    .SYNOPSIS
    Writes the Firefox managed extension policy to both the machine registry and the distribution policies.json file.
    .DESCRIPTION
    Iterates over known Firefox installation directories. When a managed extension policy is resolved,
    writes the force-install entry to each valid Firefox distribution directory and to the machine registry.
    When no policy is resolved, removes stale policy files and logs a warning.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    if (-not $PSCmdlet.ShouldProcess("Firefox", "Configure managed extension policy")) {
        return $false
    }

    Write-OpenPathLog "Configuring Firefox managed extension policy..."

    $firefoxPaths = @(
        "$env:ProgramFiles\Mozilla Firefox\distribution",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution"
    )

    $policiesSet = $false
    $unsignedExtensionManifest = "$(Get-OpenPathFirefoxExtensionRoot)\manifest.json"
    if ($PSBoundParameters.ContainsKey('Config')) {
        $managedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy -Config $Config
    }
    else {
        $managedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy
    }
    $signedExtensionWarningWritten = $false

    if ($managedExtensionPolicy) {
        if (Set-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $managedExtensionPolicy) {
            $policiesSet = $true
        }
    }
    else {
        Remove-OpenPathFirefoxMachineExtensionPolicy | Out-Null
    }

    foreach ($firefoxPath in $firefoxPaths) {
        $firefoxExe = Split-Path $firefoxPath -Parent
        if (-not (Test-Path "$firefoxExe\firefox.exe")) {
            continue
        }

        if (-not (Test-Path $firefoxPath)) {
            New-Item -ItemType Directory -Path $firefoxPath -Force | Out-Null
        }

        if ($managedExtensionPolicy) {
            $policies = @{
                policies = @{
                    ExtensionSettings = @{
                        $managedExtensionPolicy.ExtensionId = @{
                            installation_mode = 'force_installed'
                            install_url = $managedExtensionPolicy.InstallUrl
                        }
                    }
                }
            }
        }
        else {
            $policiesPath = "$firefoxPath\policies.json"
            if (Test-Path $policiesPath) {
                Remove-Item $policiesPath -Force -ErrorAction SilentlyContinue
                Write-OpenPathLog "Removed stale Firefox policies from: $policiesPath"
            }

            if (-not $signedExtensionWarningWritten) {
                if (Test-Path $unsignedExtensionManifest) {
                    Write-OpenPathLog 'Unsigned Firefox extension bundle detected, but Firefox Release requires a signed XPI distribution; removing Firefox policies until signed extension config is available' -Level WARN
                }
                else {
                    Write-OpenPathLog 'No signed Firefox extension distribution configured; removing Firefox policies until extension auto-install is available' -Level WARN
                }

                $signedExtensionWarningWritten = $true
            }

            continue
        }

        $policiesPath = "$firefoxPath\policies.json"
        $policiesJson = $policies | ConvertTo-Json -Depth 10
        Write-OpenPathUtf8NoBomFile -Path $policiesPath -Value $policiesJson

        Write-OpenPathLog "Firefox managed extension policy written to: $policiesPath"
        $policiesSet = $true
    }

    if (-not $policiesSet) {
        Write-OpenPathLog "Firefox not found or managed extension unavailable, skipping Firefox managed extension policy" -Level WARN
    }

    return $policiesSet
}

Export-ModuleMember -Function @(
    'Get-OpenPathFirefoxExtensionRoot',
    'Get-OpenPathFirefoxReleaseMetadataPath',
    'Get-OpenPathFirefoxReleaseXpiPath',
    'Get-OpenPathFirefoxManagedExtensionPolicy',
    'Get-OpenPathFirefoxMachineExtensionSettings',
    'Set-OpenPathFirefoxMachineExtensionPolicy',
    'Test-OpenPathFirefoxMachineExtensionPolicy',
    'Test-OpenPathFirefoxManagedExtensionReady',
    'Remove-OpenPathFirefoxMachineExtensionPolicy',
    'Sync-OpenPathFirefoxManagedExtensionPolicy'
)
