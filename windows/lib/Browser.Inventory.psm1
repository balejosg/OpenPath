# OpenPath browser inventory for Windows

function Get-OpenPathBrowserInventoryUninstallEntries {
    [CmdletBinding()]
    param(
        [string[]]$RegistryPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
    )

    $browserNamePattern = 'Firefox|Chrome|Edge|Brave|Opera|Vivaldi|Tor|Chromium|WebView2|Internet Explorer'
    $entries = @()

    foreach ($registryPath in $RegistryPaths) {
        try {
            $items = @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue)
        }
        catch {
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
                UninstallString = if ($item.UninstallString) { [string]$item.UninstallString } else { '' }
                QuietUninstallString = if ($item.QuietUninstallString) { [string]$item.QuietUninstallString } else { '' }
                RegistryPath = $registryPath
            }
        }
    }

    return @($entries)
}

function Get-OpenPathBrowserInventoryFileCandidates {
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

function New-OpenPathBrowserInventoryFinding {
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
    [CmdletBinding()]
    param(
        [ValidateSet('ReportOnly', 'RemoveKnownInstallers')]
        [string]$Mode = 'ReportOnly',

        [AllowNull()]
        [object[]]$UninstallEntries = $null,

        [AllowNull()]
        [object[]]$FileCandidates = $null
    )

    if (-not $PSBoundParameters.ContainsKey('UninstallEntries')) {
        $UninstallEntries = Get-OpenPathBrowserInventoryUninstallEntries
    }
    if (-not $PSBoundParameters.ContainsKey('FileCandidates')) {
        $FileCandidates = Get-OpenPathBrowserInventoryFileCandidates
    }

    $approved = @{}
    $unmanaged = @{}
    $portableRisks = @{}
    $webRenderingSurfaces = @{}
    $removalCandidates = @{}

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
        $isApproved = @('Mozilla Firefox', 'Microsoft Edge', 'Google Chrome') -contains $name
        $isUnmanaged = @('Brave', 'Opera', 'Vivaldi', 'Tor Browser', 'Internet Explorer', 'Chromium') -contains $name
        $automaticallyRemovable = [bool]($Mode -eq 'RemoveKnownInstallers' -and $isUnmanaged -and $hasUninstall -and -not $isWebView2)
        $action = if ($automaticallyRemovable) { 'RemoveKnownInstaller' } else { 'ReportOnly' }

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
        $isUserWritable = [bool]$candidate.IsUserWritable
        $name = Resolve-OpenPathBrowserInventoryName -Text '' -Path $path
        if (-not $name) {
            continue
        }

        $isWebView2 = $name -eq 'Microsoft Edge WebView2 Runtime'
        $isApproved = @('Mozilla Firefox', 'Microsoft Edge', 'Google Chrome') -contains $name
        $isUnmanaged = @('Brave', 'Opera', 'Vivaldi', 'Tor Browser', 'Internet Explorer', 'Chromium') -contains $name

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

        if ($isApproved -and -not $isUserWritable) {
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

        if ($isUserWritable) {
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
    $ready = [bool]($unmanagedBrowsers.Count -eq 0 -and $portableBrowserRisks.Count -eq 0)

    return [PSCustomObject]@{
        Mode = $Mode
        Ready = $ready
        ExitCode = if ($ready) { 0 } else { 1 }
        ApprovedBrowsers = $approvedBrowsers
        UnmanagedBrowsers = $unmanagedBrowsers
        PortableBrowserRisks = $portableBrowserRisks
        WebRenderingSurfaces = $webSurfaces
        RemovalCandidates = $removable
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserInventory',
    'Get-OpenPathBrowserInventoryUninstallEntries',
    'Get-OpenPathBrowserInventoryFileCandidates'
)
