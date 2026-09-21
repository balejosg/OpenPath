# Windows AppX/AppLocker runtime discovery. Observation-only: no policy,
# service, ACL, or package mutations are performed in this module.
Set-StrictMode -Version Latest

$script:RuntimeReasonCodes = @{
    InventoryFailed = 'appcontrol_windows_runtime_inventory_failed'
    BaselineInvalid = 'appcontrol_windows_runtime_baseline_invalid'
    RuleMissing = 'appcontrol_windows_runtime_rule_missing'
    PublisherInvalid = 'appcontrol_publisher_identity_invalid'
    PolicyConflict = 'appcontrol_windows_runtime_policy_conflict'
}

function Get-OpenPathRuntimeSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function Get-OpenPathRuntimeProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function ConvertTo-OpenPathRuntimeVersion {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [Version]'0.0.0.0' }
    try { return [Version]([string]$Value) } catch { throw $script:RuntimeReasonCodes.BaselineInvalid }
}

function Test-OpenPathRuntimePathUnder {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    if ($Path -match '^(\\\\|//)' -or $Path -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    $fullPath = $Path.Replace('/', '\').TrimEnd('\')
    $fullRoot = $Root.Replace('/', '\').TrimEnd('\')
    if (-not ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase))) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    catch {
        # Test fixtures can describe an image path not mounted on the host.
    }
    return $true
}

function Join-OpenPathRuntimePath {
    param([Parameter(Mandatory = $true)][string]$Base, [Parameter(Mandatory = $true)][string]$Child)
    if ($Base -match '^[A-Za-z]:[\\/]') {
        return $Base.TrimEnd('\', '/') + '\' + $Child.TrimStart('\', '/')
    }
    return Join-Path $Base $Child
}

function Get-OpenPathRuntimePackageKey {
    param([Parameter(Mandatory = $true)][object]$Package)
    $name = [string](Get-OpenPathRuntimeProperty $Package @('Name', 'PackageName'))
    $publisher = [string](Get-OpenPathRuntimeProperty $Package @('PublisherId', 'Publisher'))
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($publisher)) {
        throw $script:RuntimeReasonCodes.BaselineInvalid
    }
    return $name + '|' + $publisher
}

function Get-OpenPathWindowsRuntimePackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [AllowNull()][object]$NativeIdentity
    )
    $name = [string](Get-OpenPathRuntimeProperty $Package @('Name', 'PackageName'))
    $registeredPublisher = [string](Get-OpenPathRuntimeProperty $Package @('PublisherId', 'Publisher'))
    $version = [string](Get-OpenPathRuntimeProperty $Package @('Version', 'PackageVersion'))
    $location = [string](Get-OpenPathRuntimeProperty $Package @('InstallLocation', 'Path'))
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($location)) {
        throw $script:RuntimeReasonCodes.BaselineInvalid
    }
    if ($null -eq $NativeIdentity) {
        $NativeIdentity = Get-OpenPathRuntimeProperty $Package @('AppLockerIdentity', 'NativeIdentity')
    }
    if ($null -eq $NativeIdentity) { throw $script:RuntimeReasonCodes.InventoryFailed }

    # The package overload returns a native AppLocker AppX identity.  Do not
    # fall back to the flattened fields exposed by Get-AppxPackage or to the
    # registry PublisherId: either would turn an incomplete observation into
    # an authorization.  The provider must positively identify an AppX.
    $appx = Get-OpenPathRuntimeProperty $NativeIdentity @('AppX', 'Appx')
    if ($appx -isnot [bool] -or -not [bool]$appx) { throw $script:RuntimeReasonCodes.PublisherInvalid }
    $publisherObject = Get-OpenPathRuntimeProperty $NativeIdentity @('Publisher')
    if ($null -eq $publisherObject) { throw $script:RuntimeReasonCodes.PublisherInvalid }
    $nativePackageName = [string](Get-OpenPathRuntimeProperty $NativeIdentity @('PackageName', 'Name'))
    if ($nativePackageName -and -not $nativePackageName.Equals($name, [StringComparison]::OrdinalIgnoreCase)) {
        throw $script:RuntimeReasonCodes.PublisherInvalid
    }
    $publisherName = [string](Get-OpenPathRuntimeProperty $publisherObject @('PublisherName'))
    $productName = [string](Get-OpenPathRuntimeProperty $publisherObject @('ProductName'))
    $binaryName = [string](Get-OpenPathRuntimeProperty $publisherObject @('BinaryName'))
    if ([string]::IsNullOrWhiteSpace($publisherName) -or
        [string]::IsNullOrWhiteSpace($productName) -or
        [string]::IsNullOrWhiteSpace($binaryName)) {
        throw $script:RuntimeReasonCodes.PublisherInvalid
    }
    # BinaryName='*' is a valid native package identity. PublisherName and
    # ProductName are the trust boundary and never accept wildcards.
    if ($publisherName.Contains('*') -or $productName.Contains('*') -or
        $publisherName.Contains('?') -or $productName.Contains('?')) {
        throw $script:RuntimeReasonCodes.PublisherInvalid
    }
    foreach ($manifestProperty in @('ProductName', 'ManifestProductName')) {
        $manifestName = [string](Get-OpenPathRuntimeProperty $Package @($manifestProperty))
        if ($manifestName -and -not $manifestName.Equals($productName, [StringComparison]::OrdinalIgnoreCase)) {
            throw $script:RuntimeReasonCodes.PublisherInvalid
        }
    }
    [PSCustomObject][ordered]@{
        Name = $name
        Publisher = $registeredPublisher
        PublisherIdentity = [PSCustomObject][ordered]@{
            PublisherName = $publisherName
            ProductName = $productName
            BinaryName = $binaryName
        }
        Version = $version
        InstallLocation = $location
        PublisherName = $publisherName
        ProductName = $productName
        BinaryName = $binaryName
        AppX = $true
    }
}

function Get-OpenPathRuntimeDependencyCandidates {
    param([Parameter(Mandatory = $true)][object[]]$Packages, [Parameter(Mandatory = $true)][object]$Dependency)
    $name = [string](Get-OpenPathRuntimeProperty $Dependency @('Name', 'PackageName', 'PackageFamilyName'))
    $publisher = [string](Get-OpenPathRuntimeProperty $Dependency @('PublisherId', 'Publisher'))
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($publisher)) {
        throw $script:RuntimeReasonCodes.BaselineInvalid
    }
    $minimum = ConvertTo-OpenPathRuntimeVersion (Get-OpenPathRuntimeProperty $Dependency @('MinVersion', 'MinimumVersion', 'Version'))
    $architecture = [string](Get-OpenPathRuntimeProperty $Dependency @('Architecture'))
    $candidates = @($Packages | Where-Object {
        $candidateName = [string](Get-OpenPathRuntimeProperty $_ @('Name', 'PackageName'))
        $candidatePublisher = [string](Get-OpenPathRuntimeProperty $_ @('PublisherId', 'Publisher'))
        $candidateArchitecture = [string](Get-OpenPathRuntimeProperty $_ @('Architecture'))
        $candidateName.Equals($name, [StringComparison]::OrdinalIgnoreCase) -and
            $candidatePublisher.Equals($publisher, [StringComparison]::OrdinalIgnoreCase) -and
            ((ConvertTo-OpenPathRuntimeVersion (Get-OpenPathRuntimeProperty $_ @('Version', 'PackageVersion'))) -ge $minimum) -and
            (-not $architecture -or
                ($candidateArchitecture -and $candidateArchitecture.Equals($architecture, [StringComparison]::OrdinalIgnoreCase)))
    })
    if ($candidates.Count -eq 0) { throw $script:RuntimeReasonCodes.BaselineInvalid }
    @($candidates | Sort-Object @{ Expression = { ConvertTo-OpenPathRuntimeVersion (Get-OpenPathRuntimeProperty $_ @('Version', 'PackageVersion')) }; Descending = $true }, @{ Expression = { [string](Get-OpenPathRuntimeProperty $_ @('Architecture')) }; Descending = $false })
}

function Resolve-OpenPathWindowsRuntimeDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Packages, [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Roots)
    $selected = [ordered]@{}
    $visiting = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    function Visit([object]$Package) {
        if ($selected.Count -ge 4096) { throw $script:RuntimeReasonCodes.BaselineInvalid }
        $key = Get-OpenPathRuntimePackageKey -Package $Package
        if ($visited.Contains($key)) { return }
        if (-not $visiting.Add($key)) { throw $script:RuntimeReasonCodes.BaselineInvalid }
        $selected[$key] = $Package
        foreach ($dependency in @(Get-OpenPathRuntimeProperty $Package @('Dependencies', 'PackageDependencies'))) {
            if ($null -eq $dependency) { continue }
            $candidates = @(Get-OpenPathRuntimeDependencyCandidates -Packages $Packages -Dependency $dependency)
            $topVersion = ConvertTo-OpenPathRuntimeVersion (Get-OpenPathRuntimeProperty $candidates[0] @('Version', 'PackageVersion'))
            $ties = @($candidates | Where-Object {
                (ConvertTo-OpenPathRuntimeVersion (Get-OpenPathRuntimeProperty $_ @('Version', 'PackageVersion'))) -eq $topVersion
            })
            if ($ties.Count -gt 1) { throw $script:RuntimeReasonCodes.BaselineInvalid }
            Visit $candidates[0]
        }
        [void]$visiting.Remove($key)
        [void]$visited.Add($key)
    }
    foreach ($root in @($Roots)) { if ($null -ne $root) { Visit $root } }
    @($selected.Values)
}

function Get-OpenPathRuntimeCanonicalPayload {
    param([Parameter(Mandatory = $true)][object]$OsIdentity, [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Packages, [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Dependencies)
    $orderedPackages = @($Packages | Sort-Object PublisherName, ProductName, BinaryName, Name, Version | ForEach-Object {
        [ordered]@{
            Name = [string]$_.Name
            Publisher = [string]$_.Publisher
            Version = [string]$_.Version
            InstallLocation = [string]$_.InstallLocation
            PublisherName = [string]$_.PublisherName
            ProductName = [string]$_.ProductName
            BinaryName = [string]$_.BinaryName
            AppX = [bool]$_.AppX
        }
    })
    ([ordered]@{
        OS = [ordered]@{
            ProductType = [string]$OsIdentity.ProductType
            Edition = [string]$OsIdentity.Edition
            Build = [string]$OsIdentity.Build
            Architecture = [string]$OsIdentity.Architecture
        }
        Packages = $orderedPackages
        Dependencies = @($Dependencies | Sort-Object -Unique)
    } | ConvertTo-Json -Depth 20 -Compress)
}

function Get-OpenPathWindowsRuntimeBaseline {
    [CmdletBinding()]
    param(
        [object[]]$PackageInventory,
        [object]$OsIdentity,
        [string]$WindowsRoot = $env:WINDIR,
        [scriptblock]$AppLockerIdentityResolver,
        [string[]]$DeniedPackageNames = @()
    )
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if (-not $WindowsRoot) { $WindowsRoot = 'C:\Windows' }
    if ($null -eq $OsIdentity) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $OsIdentity = [PSCustomObject][ordered]@{
                ProductType = if ($os.ProductType -eq 1) { 'client' } else { 'server' }
                Edition = [string]$os.Caption
                Build = [string]$os.BuildNumber
                Architecture = [string]$os.OSArchitecture
            }
        }
        catch {
            $OsIdentity = [PSCustomObject][ordered]@{ ProductType = 'unknown'; Edition = 'unknown'; Build = 'unknown'; Architecture = 'unknown' }
        }
    }
    if ($null -eq $PackageInventory) {
        try { $PackageInventory = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
        catch {
            return [PSCustomObject][ordered]@{
                SchemaVersion = 2
                Status = 'failed'
                OS = $OsIdentity
                Packages = @()
                NativePackages = @()
                Dependencies = @()
                ReasonCodes = @($script:RuntimeReasonCodes.InventoryFailed)
                BaseHash = $null
            }
        }
    }
    $systemAppsRoot = Join-OpenPathRuntimePath -Base $WindowsRoot -Child 'SystemApps'
    $immersiveRoot = Join-OpenPathRuntimePath -Base $WindowsRoot -Child 'ImmersiveControlPanel'
    # Framework/resource packages normally live below the protected
    # WindowsApps root and may enter only through a dependency edge.  Derive
    # the drive-qualified path without using Path.GetFullPath (which would
    # interpret a Windows fixture as a Linux path on the test host).
    $windowsAppsRoot = if ($WindowsRoot -match '^([A-Za-z]):[\\/]') {
        $matches[1] + ':\Program Files\WindowsApps'
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$env:ProgramFiles)) {
        Join-OpenPathRuntimePath -Base ([string]$env:ProgramFiles) -Child 'WindowsApps'
    }
    else { '' }
    $allowedRuntimeRoots = @($systemAppsRoot, $immersiveRoot, $windowsAppsRoot | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $roots = @($PackageInventory | Where-Object {
        $location = [string](Get-OpenPathRuntimeProperty $_ @('InstallLocation', 'Path'))
        (Test-OpenPathRuntimePathUnder -Path $location -Root $systemAppsRoot) -or
            (Test-OpenPathRuntimePathUnder -Path $location -Root $immersiveRoot)
    })
    if ([string]$OsIdentity.ProductType -eq 'client' -and $roots.Count -eq 0) {
        [void]$reasons.Add($script:RuntimeReasonCodes.BaselineInvalid)
    }
    $selected = @()
    try { $selected = @(Resolve-OpenPathWindowsRuntimeDependencies -Packages @($PackageInventory) -Roots $roots) }
    catch { [void]$reasons.Add([string]$_.Exception.Message) }
    $descriptors = New-Object System.Collections.Generic.List[object]
    $nativeAppLockerPackages = New-Object System.Collections.Generic.List[object]
    foreach ($package in $selected) {
        $packageLocation = [string](Get-OpenPathRuntimeProperty $package @('InstallLocation', 'Path'))
        if (-not (@($allowedRuntimeRoots | Where-Object {
                    Test-OpenPathRuntimePathUnder -Path $packageLocation -Root $_
                }).Count -gt 0)) {
            [void]$reasons.Add($script:RuntimeReasonCodes.BaselineInvalid)
            continue
        }
        $packageName = [string](Get-OpenPathRuntimeProperty $package @('Name', 'PackageName'))
        if ($DeniedPackageNames -contains $packageName) {
            [void]$reasons.Add($script:RuntimeReasonCodes.PolicyConflict)
            continue
        }
        try {
            if ($AppLockerIdentityResolver) {
                $nativeResults = @(& $AppLockerIdentityResolver $package)
            }
            else {
                if (-not (Get-Command -Name Get-AppLockerFileInformation -ErrorAction SilentlyContinue)) {
                    throw $script:RuntimeReasonCodes.InventoryFailed
                }
                $nativeResults = @(Get-AppLockerFileInformation -Packages @($package) -ErrorAction Stop)
            }
            if ($nativeResults.Count -eq 0 -and [bool](Get-OpenPathRuntimeProperty $package @('IsFramework'))) {
                # AppLocker exposes no application identity for AppX framework
                # packages, so Get-AppLockerFileInformation -Packages returns no
                # entries for them.  Real Windows clients ship these frameworks
                # under SystemApps; they are consumed through their parent
                # packages' dependency edges and are not separately launchable,
                # so a missing identity must not fail the strict baseline.
                continue
            }
            if ($nativeResults.Count -ne 1) { throw $script:RuntimeReasonCodes.InventoryFailed }
            $native = $nativeResults[0]
            [void]$descriptors.Add((Get-OpenPathWindowsRuntimePackageIdentity -Package $package -NativeIdentity $native))
            # Test-AppLockerPolicy -Packages binds AppxPackage inputs, not the
            # FileInformation readback.  Keep the inventory package object so the
            # runtime preflight and health probes stay 1:1 with Packages.
            [void]$nativeAppLockerPackages.Add($package)
        }
        catch { [void]$reasons.Add([string]$_.Exception.Message) }
    }
    $descriptorArray = @($descriptors | Sort-Object PublisherName, ProductName, BinaryName, Name, Version)
    $dependencyNames = @($selected | ForEach-Object {
        [string](Get-OpenPathRuntimeProperty $_ @('Name', 'PackageName'))
    } | Sort-Object -Unique)
    $canonical = Get-OpenPathRuntimeCanonicalPayload -OsIdentity $OsIdentity -Packages $descriptorArray -Dependencies $dependencyNames
    [PSCustomObject][ordered]@{
        SchemaVersion = 2
        Status = if ($reasons.Count -eq 0) { 'passed' } else { 'failed' }
        OS = $OsIdentity
        Packages = $descriptorArray
        NativePackages = @($selected)
        NativeAppLockerPackages = @($nativeAppLockerPackages.ToArray())
        Dependencies = $dependencyNames
        ReasonCodes = @($reasons | Sort-Object -Unique)
        CanonicalPayload = $canonical
        BaseHash = if ($canonical) { Get-OpenPathRuntimeSha256 -Text $canonical } else { $null }
    }
}

function Test-OpenPathWindowsRuntimeBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Baseline)
    if ([int]$Baseline.SchemaVersion -ne 2 -or [string]$Baseline.Status -ne 'passed') { return $false }
    if ($null -eq $Baseline.OS -or [string]$Baseline.OS.ProductType -ne 'client') { return $false }
    $packages = @($Baseline.Packages)
    if ($packages.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$Baseline.BaseHash)) { return $false }
    foreach ($package in $packages) {
        if ([string]::IsNullOrWhiteSpace([string]$package.PublisherName) -or
            ([string]$package.PublisherName).Contains('*') -or
            [string]::IsNullOrWhiteSpace([string]$package.ProductName) -or
            ([string]$package.ProductName).Contains('*') -or
            [string]::IsNullOrWhiteSpace([string]$package.BinaryName)) { return $false }
        if ($null -eq $package.PSObject.Properties['AppX'] -or $package.AppX -isnot [bool] -or -not [bool]$package.AppX) { return $false }
    }
    $canonical = Get-OpenPathRuntimeCanonicalPayload -OsIdentity $Baseline.OS -Packages $packages -Dependencies @($Baseline.Dependencies)
    [string]::Equals((Get-OpenPathRuntimeSha256 -Text $canonical), [string]$Baseline.BaseHash, [StringComparison]::OrdinalIgnoreCase)
}

Export-ModuleMember -Function Get-OpenPathWindowsRuntimeBaseline, Test-OpenPathWindowsRuntimeBaseline, Get-OpenPathWindowsRuntimePackageIdentity, Resolve-OpenPathWindowsRuntimeDependencies
