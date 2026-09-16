# OpenPath browser inventory for Windows

Import-Module "$PSScriptRoot\Browser.EnforcementDecision.psm1" -Force -ErrorAction Stop
$script:OpenPathBrowserInventoryDiscoveryErrors = @()

function Get-OpenPathBrowserInventoryUninstallEntries {
    <#
    .SYNOPSIS
    Reads browser-related uninstall entries from the Windows registry and returns them as structured objects.

    .DESCRIPTION
    Scans both the 64-bit and 32-bit uninstall registry hives, filtering entries whose display name
    matches a known set of browser keywords.  Each entry is returned with its display name, version,
    install location, uninstall string, and quiet uninstall string so that the inventory can classify
    and optionally remove the software.
    #>
    [CmdletBinding()]
    param(
        [string[]]$RegistryPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
    )

    $browserNamePattern = 'Firefox|Chrome|Edge|Brave|Opera|Vivaldi|Tor|Chromium|WebView2|Internet Explorer'
    $entries = @()

    foreach ($registryPath in $RegistryPaths) {
        try {
            $items = @(Get-ItemProperty -Path $registryPath -ErrorAction Stop)
        }
        catch {
            if ($env:OS -eq 'Windows_NT') { $script:OpenPathBrowserInventoryDiscoveryErrors += "Uninstall registry read failed: $registryPath" }
            $items = @()
        }

        foreach ($item in $items) {
            if (-not $item.DisplayName -or $item.DisplayName -notmatch $browserNamePattern) {
                continue
            }

            $entries += [PSCustomObject]@{
                DisplayName = [string]$item.DisplayName
                DisplayVersion = if ($item.DisplayVersion) { [string]$item.DisplayVersion } else { '' }
                InstallLocation = if ($item.InstallLocation) { [string]$item.InstallLocation } else { '' }
                DisplayIcon = if ($item.DisplayIcon) { [string]$item.DisplayIcon } else { '' }
                UninstallString = if ($item.UninstallString) { [string]$item.UninstallString } else { '' }
                QuietUninstallString = if ($item.QuietUninstallString) { [string]$item.QuietUninstallString } else { '' }
                RegistryPath = $registryPath
            }
        }
    }

    return @($entries)
}

function Get-OpenPathBrowserInventoryFileCandidates {
    <#
    .SYNOPSIS
    Searches well-known filesystem locations for browser executable files and returns matching candidates.

    .DESCRIPTION
    Scans Program Files, local app data, Downloads, and Desktop by default.  For system-writable
    roots, candidates are matched against a fixed list of relative paths.  For user-writable roots,
    a recursive search for portable browser executables is also performed.  Each candidate carries
    the full path, its source root name, and whether the root is user-writable, so that the
    inventory can flag portable or user-installed browser risks.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$SearchRoots = $null
    )

    if ($null -eq $SearchRoots) {
        $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        $downloadsPath = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' } else { $null }
        $desktopPath = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Desktop' } else { $null }

        $SearchRoots = @(
            [PSCustomObject]@{ Name = 'ProgramFiles'; Path = $env:ProgramFiles; IsUserWritable = $false },
            [PSCustomObject]@{ Name = 'ProgramFilesX86'; Path = $programFilesX86; IsUserWritable = $false },
            [PSCustomObject]@{ Name = 'LocalAppData'; Path = $env:LOCALAPPDATA; IsUserWritable = $true },
            [PSCustomObject]@{ Name = 'Downloads'; Path = $downloadsPath; IsUserWritable = $true },
            [PSCustomObject]@{ Name = 'Desktop'; Path = $desktopPath; IsUserWritable = $true }
        )
    }

    $relativeCandidates = @(
        'Mozilla Firefox\firefox.exe',
        'Microsoft\Edge\Application\msedge.exe',
        'Google\Chrome\Application\chrome.exe',
        'BraveSoftware\Brave-Browser\Application\brave.exe',
        'Opera\launcher.exe',
        'Opera\opera.exe',
        'Opera GX\launcher.exe',
        'Vivaldi\Application\vivaldi.exe',
        'Tor Browser\Browser\firefox.exe',
        'Internet Explorer\iexplore.exe',
        'Microsoft\EdgeWebView\Application\*\msedgewebview2.exe',
        'Chromium\Application\chrome.exe',
        'Chromium\Application\chromium.exe',
        'FirefoxPortable\App\Firefox\firefox.exe',
        'FirefoxPortable\App\Firefox64\firefox.exe'
    )
    $portableExecutableNames = @('firefox.exe', 'chrome.exe', 'chromium.exe', 'brave.exe', 'opera.exe', 'vivaldi.exe')
    $seen = @{}
    $candidates = @()

    foreach ($root in @($SearchRoots)) {
        if (-not $root -or -not $root.Path) {
            continue
        }

        $rootPath = [string]$root.Path
        $rootName = if ($root.PSObject.Properties['Name'] -and $root.Name) { [string]$root.Name } else { $rootPath }
        $isUserWritable = [bool]$root.IsUserWritable

        foreach ($relativePath in $relativeCandidates) {
            $candidatePath = Join-Path $rootPath $relativePath
            try {
                $items = @(Get-Item -Path $candidatePath -ErrorAction SilentlyContinue)
            }
            catch {
                $items = @()
            }

            foreach ($item in $items) {
                if (-not $item -or -not $item.FullName) {
                    continue
                }

                $key = ([string]$item.FullName).ToLowerInvariant()
                if ($seen.ContainsKey($key)) {
                    continue
                }

                $seen[$key] = $true
                $candidates += [PSCustomObject]@{
                    Path = [string]$item.FullName
                    SourceRoot = $rootName
                    IsUserWritable = $isUserWritable
                }
            }
        }

        if ($isUserWritable -and (Test-Path $rootPath)) {
            foreach ($executableName in $portableExecutableNames) {
                try {
                    $items = @(Get-ChildItem -Path $rootPath -Filter $executableName -File -Recurse -ErrorAction SilentlyContinue)
                }
                catch {
                    $items = @()
                }

                foreach ($item in $items) {
                    $key = ([string]$item.FullName).ToLowerInvariant()
                    if ($seen.ContainsKey($key)) {
                        continue
                    }

                    $seen[$key] = $true
                    $candidates += [PSCustomObject]@{
                        Path = [string]$item.FullName
                        SourceRoot = $rootName
                        IsUserWritable = $true
                    }
                }
            }
        }
    }

    return @($candidates)
}

function Get-OpenPathBrowserInventoryAppPathEntries {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Items = $null)
    if ($null -eq $Items) {
        $Items = @()
        foreach ($registryPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\*')) {
            $registryRoot = $registryPath.TrimEnd('*').TrimEnd('\')
            try {
                if (Test-Path -LiteralPath $registryRoot -ErrorAction Stop) {
                    $Items += @(Get-ItemProperty -Path $registryPath -ErrorAction Stop)
                }
            }
            catch {
                if ($env:OS -eq 'Windows_NT') { $script:OpenPathBrowserInventoryDiscoveryErrors += "App Paths read failed: $registryPath" }
            }
        }
    }
    return @($Items | ForEach-Object {
            $path = if ($_.'(default)') { [string]$_.'(default)' } elseif ($_.ExecutablePath) { [string]$_.ExecutablePath } else { '' }
            $name = Resolve-OpenPathBrowserInventoryName -Text '' -Path $path
            if ($name -and $path -match '\.exe$') {
                [pscustomobject]@{ DisplayName=$name; DisplayVersion=''; InstallLocation=''; DisplayIcon=$path; UninstallString=''; QuietUninstallString=''; IdentitySource='AppPaths' }
            }
        })
}

function New-OpenPathBrowserInventoryFinding {
    <#
    .SYNOPSIS
    Constructs a standardized browser inventory finding object with all classification and metadata fields.

    .NOTES
    The returned object is a value type used throughout the inventory and enforcement pipeline.
    Defaults are chosen so that callers only need to supply the fields that differ from the safe
    report-only baseline.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Category,

        [string]$Source = '',
        [string]$Path = '',
        [string]$DisplayName = '',
        [string]$DisplayVersion = '',
        [string]$InstallLocation = '',
        [string]$UninstallString = '',
        [string]$QuietUninstallString = '',
        [bool]$IsApproved = $false,
        [bool]$IsPortable = $false,
        [bool]$IsUserWritable = $false,
        [bool]$AutomaticallyRemovable = $false,
        [string]$CleanupMode = 'ReportOnly',
        [string]$Action = 'ReportOnly'
    )

    return [PSCustomObject]@{
        Name = $Name
        Category = $Category
        Source = $Source
        Path = $Path
        DisplayName = $DisplayName
        DisplayVersion = $DisplayVersion
        InstallLocation = $InstallLocation
        UninstallString = $UninstallString
        QuietUninstallString = $QuietUninstallString
        IsApproved = $IsApproved
        IsPortable = $IsPortable
        IsUserWritable = $IsUserWritable
        AutomaticallyRemovable = $AutomaticallyRemovable
        CleanupMode = $CleanupMode
        Action = $Action
    }
}

function Resolve-OpenPathBrowserInventoryName {
    <#
    .SYNOPSIS
    Maps a raw display name or file path to a canonical browser name used throughout the inventory.

    .DESCRIPTION
    Matching is done against a priority-ordered set of patterns so that ambiguous executables such
    as firefox.exe under a Tor Browser path are resolved to the correct family.  Returns an empty
    string when no known browser is recognized.
    #>
    param(
        [string]$Text,
        [string]$Path = ''
    )

    $value = "$Text $Path"

    if ($value -match 'WebView2') { return 'Microsoft Edge WebView2 Runtime' }
    if ($value -match 'Internet Explorer|iexplore\.exe') { return 'Internet Explorer' }
    if ($value -match 'Tor Browser') { return 'Tor Browser' }
    if ($value -match 'Brave|brave\.exe') { return 'Brave' }
    if ($value -match 'Opera|opera\.exe|\\Opera(?: GX)?\\launcher\.exe') { return 'Opera' }
    if ($value -match 'Vivaldi|vivaldi\.exe') { return 'Vivaldi' }
    if ($value -match 'Mozilla Firefox|Firefox Browser|\\Mozilla Firefox\\|firefox\.exe') { return 'Mozilla Firefox' }
    if ($Text -match '^(Microsoft Edge|Microsoft Edge Browser)$' -or $Path -match '\\Microsoft\\Edge\\Application\\|msedge\.exe') { return 'Microsoft Edge' }
    if ($value -match 'Google Chrome|\\Google\\Chrome\\Application\\') { return 'Google Chrome' }
    if ($value -match 'Chromium|chromium\.exe') { return 'Chromium' }

    return ''
}

function Add-OpenPathBrowserInventoryFinding {
    <#
    .SYNOPSIS
    Inserts a finding into a deduplication hashtable keyed by category, name, path, display name,
    and install location so that the same browser entry is not counted more than once.
    #>
    param(
        [hashtable]$Target,
        [object]$Finding
    )

    $key = @($Finding.Category, $Finding.Name, $Finding.Path, $Finding.DisplayName, $Finding.InstallLocation) -join '|'
    $key = $key.ToLowerInvariant()
    if (-not $Target.ContainsKey($key)) {
        $Target[$key] = $Finding
    }
}

function Get-OpenPathBrowserInventory {
    <#
    .SYNOPSIS
    Scans registry uninstall entries and filesystem candidates to produce a full browser inventory
    with approved, unmanaged, portable-risk, web-rendering-surface, and removal-candidate lists.

    .DESCRIPTION
    In ReportOnly mode no software is removed; findings are classified and returned for operator
    review.  In RemoveKnownInstallers mode unmanaged browsers that have a quiet uninstall string
    and are not WebView2 are marked automatically removable, though removal itself must be
    triggered separately.  The inventory delegates the ready/exit-code decision to the pure
    enforcement decision layer so that the readiness contract stays consistent across callers.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ReportOnly', 'RemoveKnownInstallers')]
        [string]$Mode = 'ReportOnly',

        [AllowNull()]
        [object[]]$UninstallEntries = $null,

        [AllowNull()]
        [object[]]$FileCandidates = $null,

        [AllowNull()][object[]]$AppPathEntries = $null,

        [string[]]$DiscoveryErrors = @()
    )

    $script:OpenPathBrowserInventoryDiscoveryErrors = @()
    if (-not $PSBoundParameters.ContainsKey('UninstallEntries')) {
        $UninstallEntries = Get-OpenPathBrowserInventoryUninstallEntries
    }
    if (-not $PSBoundParameters.ContainsKey('FileCandidates')) {
        $FileCandidates = Get-OpenPathBrowserInventoryFileCandidates
    }
    if (-not $PSBoundParameters.ContainsKey('AppPathEntries')) {
        $AppPathEntries = if ($PSBoundParameters.ContainsKey('UninstallEntries') -or $PSBoundParameters.ContainsKey('FileCandidates')) { @() } else { Get-OpenPathBrowserInventoryAppPathEntries }
    }
    $DiscoveryErrors = @($DiscoveryErrors) + @($script:OpenPathBrowserInventoryDiscoveryErrors)

    $UninstallEntries = @($UninstallEntries) + @($AppPathEntries)
    $approved = @{}
    $unmanaged = @{}
    $portableRisks = @{}
    $webRenderingSurfaces = @{}
    $removalCandidates = @{}
    $executableIdentities = @{}

    $executableNames = @{
        'Mozilla Firefox' = 'firefox.exe'; 'Microsoft Edge' = 'msedge.exe'; 'Google Chrome' = 'chrome.exe'
        'Brave' = 'brave.exe'; 'Opera' = 'opera.exe'; 'Vivaldi' = 'vivaldi.exe'
        'Tor Browser' = 'firefox.exe'; 'Internet Explorer' = 'iexplore.exe'; 'Chromium' = 'chrome.exe'
    }

    $addIdentity = {
        param(
            [string]$Name,
            [string]$Path,
            [string]$Source,
            [bool]$IsApproved,
            [bool]$IsUserWritable = $false
        )
        if ([string]::IsNullOrWhiteSpace($Path) -or -not $executableNames.ContainsKey($Name)) { return }
        $normalizedPath = $Path.Trim().Trim('"') -replace ',\s*-?\d+$', ''
        if (-not $normalizedPath.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalizedPath = "$($normalizedPath.TrimEnd('\'))\$($executableNames[$Name])"
        }
        $family = switch ($Name) {
            'Mozilla Firefox' { 'Firefox' }; 'Microsoft Edge' { 'Edge' }; 'Google Chrome' { 'Chrome' }; default { $Name }
        }
        $key = $normalizedPath.ToLowerInvariant()
        $executableIdentities[$key] = [pscustomobject]@{
            Family = $family
            ExecutablePath = $normalizedPath
            Source = $Source
            IsApproved = [bool]($IsApproved -and -not $IsUserWritable)
            IsUserWritable = [bool]$IsUserWritable
        }
    }

    foreach ($entry in @($UninstallEntries)) {
        if (-not $entry -or -not $entry.DisplayName) {
            continue
        }

        $name = Resolve-OpenPathBrowserInventoryName -Text ([string]$entry.DisplayName) -Path ([string]$entry.InstallLocation)
        if (-not $name) {
            continue
        }

        $quietUninstall = if ($entry.QuietUninstallString) { [string]$entry.QuietUninstallString } else { '' }
        $uninstall = if ($entry.UninstallString) { [string]$entry.UninstallString } else { '' }
        $hasUninstall = [bool]($quietUninstall -or $uninstall)
        $isWebView2 = $name -eq 'Microsoft Edge WebView2 Runtime'
        $identityPath = if ($entry.PSObject.Properties['DisplayIcon'] -and $entry.DisplayIcon) {
            [string]$entry.DisplayIcon
        }
        elseif ($entry.InstallLocation) {
            [string]$entry.InstallLocation
        }
        else {
            ''
        }
        $registryUserWritable = [bool]($entry.PSObject.Properties['RegistryPath'] -and [string]$entry.RegistryPath -match '^(?i)HKCU:')
        $pathUserWritable = [bool]($identityPath -match '(?i)\\Users\\|\\AppData\\|\\Downloads\\|\\Desktop\\')
        $isUserWritable = [bool]($registryUserWritable -or $pathUserWritable)
        $isPortablePath = [bool]($identityPath -match '(?i)FirefoxPortable|ChromiumPortable|\\Tor Browser\\|\\Portable(?:\\|$)')
        $isApproved = [bool](@('Mozilla Firefox', 'Microsoft Edge', 'Google Chrome') -contains $name -and
            -not $isUserWritable -and -not $isPortablePath)
        $isUnmanaged = [bool](@('Brave', 'Opera', 'Vivaldi', 'Tor Browser', 'Internet Explorer', 'Chromium') -contains $name -or
            ($isPortablePath -and -not $isWebView2))
        $automaticallyRemovable = [bool]($Mode -eq 'RemoveKnownInstallers' -and $isUnmanaged -and $hasUninstall -and -not $isWebView2)
        $action = if ($automaticallyRemovable) { 'RemoveKnownInstaller' } else { 'ReportOnly' }

        if ($entry.PSObject.Properties['DisplayIcon'] -and $entry.DisplayIcon) {
            $identitySource = if ($entry.PSObject.Properties['IdentitySource'] -and $entry.IdentitySource) { [string]$entry.IdentitySource } else { 'RegistryDisplayIcon' }
            & $addIdentity $name ([string]$entry.DisplayIcon) $identitySource $isApproved $isUserWritable
        }
        elseif ($entry.InstallLocation) {
            & $addIdentity $name ([string]$entry.InstallLocation) 'RegistryInstallLocation' $isApproved $isUserWritable
        }

        if (($isUserWritable -or $isPortablePath) -and $name -in @('Mozilla Firefox', 'Microsoft Edge', 'Google Chrome')) {
            $isUnmanaged = $true
        }

        $finding = New-OpenPathBrowserInventoryFinding `
            -Name $name `
            -Category $(if ($isWebView2) { 'WebRenderingSurface' } elseif ($isApproved) { 'ApprovedBrowser' } else { 'UnmanagedBrowser' }) `
            -Source 'RegistryUninstall' `
            -DisplayName ([string]$entry.DisplayName) `
            -DisplayVersion $(if ($entry.DisplayVersion) { [string]$entry.DisplayVersion } else { '' }) `
            -InstallLocation $(if ($entry.InstallLocation) { [string]$entry.InstallLocation } else { '' }) `
            -UninstallString $uninstall `
            -QuietUninstallString $quietUninstall `
            -IsApproved:$isApproved `
            -IsPortable:$isPortablePath `
            -IsUserWritable:$isUserWritable `
            -AutomaticallyRemovable:$automaticallyRemovable `
            -CleanupMode $Mode `
            -Action $action

        if ($isWebView2) {
            Add-OpenPathBrowserInventoryFinding -Target $webRenderingSurfaces -Finding $finding
        }
        elseif ($isApproved) {
            Add-OpenPathBrowserInventoryFinding -Target $approved -Finding $finding
        }
        elseif ($isUnmanaged) {
            Add-OpenPathBrowserInventoryFinding -Target $unmanaged -Finding $finding
            if ($automaticallyRemovable) {
                Add-OpenPathBrowserInventoryFinding -Target $removalCandidates -Finding $finding
            }
        }
    }

    foreach ($candidate in @($FileCandidates)) {
        if (-not $candidate -or -not $candidate.Path) {
            continue
        }

        $path = [string]$candidate.Path
        $sourceRoot = if ($candidate.PSObject.Properties['SourceRoot'] -and $candidate.SourceRoot) { [string]$candidate.SourceRoot } else { 'FileSystem' }
        $isUserWritable = [bool]($candidate.IsUserWritable -or $path -match '(?i)\\Users\\|\\AppData\\|\\Downloads\\|\\Desktop\\')
        $isPortablePath = [bool]($path -match '(?i)FirefoxPortable|ChromiumPortable|\\Tor Browser\\|\\Portable(?:\\|$)')
        $name = Resolve-OpenPathBrowserInventoryName -Text '' -Path $path
        if (-not $name) {
            continue
        }

        $isWebView2 = $name -eq 'Microsoft Edge WebView2 Runtime'
        $isApproved = [bool](@('Mozilla Firefox', 'Microsoft Edge', 'Google Chrome') -contains $name -and
            -not $isUserWritable -and -not $isPortablePath)
        $isUnmanaged = [bool](@('Brave', 'Opera', 'Vivaldi', 'Tor Browser', 'Internet Explorer', 'Chromium') -contains $name -or
            ($isPortablePath -or ($isUserWritable -and $name -in @('Mozilla Firefox', 'Microsoft Edge', 'Google Chrome'))))
        & $addIdentity $name $path $sourceRoot $isApproved $isUserWritable

        if ($isWebView2) {
            Add-OpenPathBrowserInventoryFinding -Target $webRenderingSurfaces -Finding (New-OpenPathBrowserInventoryFinding `
                    -Name $name `
                    -Category 'WebRenderingSurface' `
                    -Source $sourceRoot `
                    -Path $path `
                    -IsUserWritable:$isUserWritable `
                    -CleanupMode $Mode)
            continue
        }

        if ($isApproved -and -not $isUserWritable -and -not $isPortablePath) {
            Add-OpenPathBrowserInventoryFinding -Target $approved -Finding (New-OpenPathBrowserInventoryFinding `
                    -Name $name `
                    -Category 'ApprovedBrowser' `
                    -Source $sourceRoot `
                    -Path $path `
                    -IsApproved:$true `
                    -CleanupMode $Mode)
        }

        if ($isUnmanaged) {
            Add-OpenPathBrowserInventoryFinding -Target $unmanaged -Finding (New-OpenPathBrowserInventoryFinding `
                    -Name $name `
                    -Category 'UnmanagedBrowser' `
                    -Source $sourceRoot `
                    -Path $path `
                    -IsUserWritable:$isUserWritable `
                    -CleanupMode $Mode)
        }

        if ($isUserWritable -or $isPortablePath) {
            $portableName = $null
            if ($name -eq 'Mozilla Firefox' -or $path -match 'FirefoxPortable') {
                $portableName = 'Firefox portable'
            }
            elseif ($name -eq 'Chromium' -or $path -match 'Chromium') {
                $portableName = 'Chromium portable'
            }
            elseif ($name -eq 'Tor Browser') {
                $portableName = 'Tor Browser'
            }
            elseif (@('Brave', 'Opera', 'Vivaldi') -contains $name) {
                $portableName = "$name portable"
            }

            if ($portableName) {
                Add-OpenPathBrowserInventoryFinding -Target $portableRisks -Finding (New-OpenPathBrowserInventoryFinding `
                        -Name $portableName `
                        -Category 'PortableBrowserRisk' `
                        -Source $sourceRoot `
                        -Path $path `
                        -IsPortable:$true `
                        -IsUserWritable:$true `
                        -CleanupMode $Mode)
            }
        }
    }

    $approvedBrowsers = @($approved.Values | Sort-Object Name, Path, DisplayName)
    $unmanagedBrowsers = @($unmanaged.Values | Sort-Object Name, Path, DisplayName)
    $portableBrowserRisks = @($portableRisks.Values | Sort-Object Name, Path)
    $webSurfaces = @($webRenderingSurfaces.Values | Sort-Object Name, Path, DisplayName)
    $removable = @($removalCandidates.Values | Sort-Object Name, DisplayName, Path)
    $decision = Get-OpenPathBrowserInventoryDecision `
        -UnmanagedBrowsers $unmanagedBrowsers `
        -PortableBrowserRisks $portableBrowserRisks

    return [PSCustomObject]@{
        Mode = $Mode
        Ready = [bool]$decision.Ready
        ExitCode = [int]$decision.ExitCode
        ApprovedBrowsers = $approvedBrowsers
        UnmanagedBrowsers = $unmanagedBrowsers
        PortableBrowserRisks = $portableBrowserRisks
        WebRenderingSurfaces = $webSurfaces
        RemovalCandidates = $removable
        ExecutableIdentities = @($executableIdentities.Values | Sort-Object Family, ExecutablePath)
        DiscoveryStatus = if (@($DiscoveryErrors).Count -gt 0) { 'Degraded' } else { 'Complete' }
        DiscoveryErrors = @($DiscoveryErrors)
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserInventory',
    'Get-OpenPathBrowserInventoryUninstallEntries',
    'Get-OpenPathBrowserInventoryFileCandidates',
    'Get-OpenPathBrowserInventoryAppPathEntries'
)
