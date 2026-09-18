# Windows AppLocker runtime baseline discovery.  This module only observes the
# endpoint and returns a canonical, serializable description; it never changes
# AppLocker, services, ACLs, or package state.

Set-StrictMode -Version Latest

$script:RuntimeReasonCodes = @{
    InventoryFailed = 'appcontrol_windows_runtime_inventory_failed'
    BaselineInvalid = 'appcontrol_windows_runtime_baseline_invalid'
    RuleMissing = 'appcontrol_windows_runtime_rule_missing'
    PublisherInvalid = 'appcontrol_publisher_identity_invalid'
}

function Get-OpenPathRuntimeSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-OpenPathRuntimeProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties[$name]) {
            return $Object.PSObject.Properties[$name].Value
        }
    }
    return $null
}

function Test-OpenPathRuntimePathUnder {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    if ($Path -match '^(\\\\|//)' -or $Path -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    $fullPath = $Path.Replace('/', '\').TrimEnd('\')
    $fullRoot = $Root.Replace('/', '\').TrimEnd('\')
    return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-OpenPathWindowsRuntimePackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [AllowNull()][object]$NativeIdentity
    )

    $publisher = [string](Get-OpenPathRuntimeProperty $Package @('PublisherId','Publisher'))
    $name = [string](Get-OpenPathRuntimeProperty $Package @('Name','PackageName'))
    $version = [string](Get-OpenPathRuntimeProperty $Package @('Version','PackageVersion'))
    $location = [string](Get-OpenPathRuntimeProperty $Package @('InstallLocation','Path'))
    $native = $NativeIdentity
    if ($null -eq $native) { $native = Get-OpenPathRuntimeProperty $Package @('AppLockerIdentity','NativeIdentity') }
    $nativePublisher = [string](Get-OpenPathRuntimeProperty $native @('PublisherName','Publisher'))
    $nativeProduct = [string](Get-OpenPathRuntimeProperty $native @('ProductName','Product'))
    $nativeBinary = [string](Get-OpenPathRuntimeProperty $native @('BinaryName','Binary'))
    if (-not $nativePublisher -or -not $nativeProduct -or -not $nativeBinary) {
        throw $script:RuntimeReasonCodes.PublisherInvalid
    }
    if ($nativePublisher -eq '*' -or $nativeProduct -eq '*' -or $nativeBinary -eq '*' -or
        $nativePublisher.Contains('*') -or $nativeProduct.Contains('*')) {
        throw $script:RuntimeReasonCodes.PublisherInvalid
    }
    [PSCustomObject]@{
        Name = $name
        Publisher = $publisher
        Version = $version
        InstallLocation = $location
        PublisherName = $nativePublisher
        ProductName = $nativeProduct
        BinaryName = $nativeBinary
    }
}

function Resolve-OpenPathWindowsRuntimeDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][object[]]$Roots
    )

    $byIdentity = @{}
    foreach ($package in $Packages) {
        $name = [string](Get-OpenPathRuntimeProperty $package @('Name','PackageName'))
        $publisher = [string](Get-OpenPathRuntimeProperty $package @('PublisherId','Publisher'))
        if ($name -and $publisher) { $byIdentity["$name|$publisher"] = $package }
    }
    $selected = [ordered]@{}
    $visiting = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Visit([object]$package) {
        $name = [string](Get-OpenPathRuntimeProperty $package @('Name','PackageName'))
        $publisher = [string](Get-OpenPathRuntimeProperty $package @('PublisherId','Publisher'))
        $key = "$name|$publisher"
        if (-not $name -or -not $publisher) { throw $script:RuntimeReasonCodes.BaselineInvalid }
        if ($visited.Contains($key)) { return }
        if (-not $visiting.Add($key)) { throw $script:RuntimeReasonCodes.BaselineInvalid }
        $selected[$key] = $package
        foreach ($dependency in @(Get-OpenPathRuntimeProperty $package @('Dependencies','PackageDependencies'))) {
            $dependencyName = [string](Get-OpenPathRuntimeProperty $dependency @('Name','PackageName','PackageFamilyName'))
            $dependencyPublisher = [string](Get-OpenPathRuntimeProperty $dependency @('PublisherId','Publisher'))
            $minimumVersion = [string](Get-OpenPathRuntimeProperty $dependency @('MinVersion','MinimumVersion','Version'))
            $candidate = $null
            if ($dependencyName -and $dependencyPublisher) { $candidate = $byIdentity["$dependencyName|$dependencyPublisher"] }
            if ($null -eq $candidate -and $dependencyName) {
                $candidate = @($Packages | Where-Object { [string](Get-OpenPathRuntimeProperty $_ @('Name','PackageName')) -eq $dependencyName })[0]
            }
            if ($null -eq $candidate) { throw $script:RuntimeReasonCodes.BaselineInvalid }
            if ($minimumVersion) {
                try {
                    if ([Version]([string](Get-OpenPathRuntimeProperty $candidate @('Version','PackageVersion'))) -lt [Version]$minimumVersion) {
                        throw $script:RuntimeReasonCodes.BaselineInvalid
                    }
                } catch { throw $script:RuntimeReasonCodes.BaselineInvalid }
            }
            Visit $candidate
        }
        [void]$visiting.Remove($key)
        [void]$visited.Add($key)
    }
    foreach ($root in $Roots) { Visit $root }
    return @($selected.Values)
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

    $reasonCodes = [Collections.Generic.List[string]]::new()
    if (-not $WindowsRoot) { $WindowsRoot = 'C:\Windows' }
    if ($null -eq $OsIdentity) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $OsIdentity = [PSCustomObject]@{ ProductType = if ($os.ProductType -eq 1) { 'client' } else { 'server' }; Edition = $os.Caption; Build = $os.BuildNumber; Architecture = $os.OSArchitecture }
        } catch { $OsIdentity = [PSCustomObject]@{ ProductType = 'unknown'; Edition = 'unknown'; Build = 'unknown'; Architecture = 'unknown' } }
    }
    if ($null -eq $PackageInventory) {
        try { $PackageInventory = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
        catch { $reasonCodes.Add($script:RuntimeReasonCodes.InventoryFailed); return [PSCustomObject]@{ SchemaVersion = 1; Status = 'failed'; OS = $OsIdentity; Packages = @(); Dependencies = @(); ReasonCodes = @($reasonCodes); BaseHash = $null } }
    }
    $systemAppsRoot = "$($WindowsRoot.TrimEnd('\'))\SystemApps"
    $immersiveRoot = "$($WindowsRoot.TrimEnd('\'))\ImmersiveControlPanel"
    $roots = @()
    foreach ($package in @($PackageInventory)) {
        $location = [string](Get-OpenPathRuntimeProperty $package @('InstallLocation','Path'))
        if (-not $location) { continue }
        if ((Test-OpenPathRuntimePathUnder -Path $location -Root $systemAppsRoot) -or
            (Test-OpenPathRuntimePathUnder -Path $location -Root $immersiveRoot)) {
            if ($location -match '(^|[\\/])\.\.([\\/]|$)') { $reasonCodes.Add($script:RuntimeReasonCodes.BaselineInvalid); continue }
            $roots += $package
        }
    }
    if ([string]$OsIdentity.ProductType -eq 'client' -and $roots.Count -eq 0) { $reasonCodes.Add($script:RuntimeReasonCodes.BaselineInvalid) }
    try { $selected = @(Resolve-OpenPathWindowsRuntimeDependencies -Packages @($PackageInventory) -Roots $roots) }
    catch { $selected = @(); $reasonCodes.Add($_.Exception.Message) }
    $descriptors = @()
    foreach ($package in $selected) {
        if ([string](Get-OpenPathRuntimeProperty $package @('Name','PackageName')) -in $DeniedPackageNames) { continue }
        try {
            $native = if ($AppLockerIdentityResolver) { & $AppLockerIdentityResolver $package } else {
                if (-not (Get-Command Get-AppLockerFileInformation -ErrorAction SilentlyContinue)) { throw $script:RuntimeReasonCodes.InventoryFailed }
                $probe = Get-ChildItem -LiteralPath ([string](Get-OpenPathRuntimeProperty $package @('InstallLocation', 'Path'))) -File -Recurse -ErrorAction Stop |
                    Where-Object { $_.Extension -in @('.exe', '.dll') } |
                    Select-Object -First 1
                if (-not $probe) { throw $script:RuntimeReasonCodes.InventoryFailed }
                @(Get-AppLockerFileInformation -Path $probe.FullName -ErrorAction Stop | Select-Object -First 1)[0]
            }
            $descriptors += Get-OpenPathWindowsRuntimePackageIdentity -Package $package -NativeIdentity $native
        } catch { $reasonCodes.Add($_.Exception.Message) }
    }
    $canonical = @($descriptors | Sort-Object PublisherName, ProductName, BinaryName, Name | ForEach-Object {
        [ordered]@{ Name = $_.Name; Publisher = $_.Publisher; Version = $_.Version; InstallLocation = $_.InstallLocation; PublisherName = $_.PublisherName; ProductName = $_.ProductName; BinaryName = $_.BinaryName }
    }) | ConvertTo-Json -Depth 10 -Compress
    $status = if ($reasonCodes.Count -eq 0) { 'passed' } else { 'failed' }
    [PSCustomObject]@{
        SchemaVersion = 1
        Status = $status
        OS = $OsIdentity
        Packages = @($descriptors | Sort-Object PublisherName, ProductName, BinaryName, Name)
        Dependencies = @($selected | ForEach-Object { [string](Get-OpenPathRuntimeProperty $_ @('Name','PackageName')) } | Sort-Object -Unique)
        ReasonCodes = @($reasonCodes | Sort-Object -Unique)
        BaseHash = if ($canonical) { Get-OpenPathRuntimeSha256 -Text $canonical } else { $null }
    }
}

function Test-OpenPathWindowsRuntimeBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Baseline)
    if ([int]$Baseline.SchemaVersion -ne 1 -or [string]$Baseline.Status -ne 'passed') { return $false }
    if (-not $Baseline.OS -or [string]$Baseline.OS.ProductType -ne 'client') { return $false }
    if (@($Baseline.Packages).Count -eq 0 -or -not [string]$Baseline.BaseHash) { return $false }
    foreach ($package in @($Baseline.Packages)) {
        if ([string]$package.PublisherName -match '\*' -or [string]$package.ProductName -match '\*' -or [string]$package.BinaryName -match '\*') { return $false }
    }
    return $true
}

Export-ModuleMember -Function Get-OpenPathWindowsRuntimeBaseline, Test-OpenPathWindowsRuntimeBaseline, Get-OpenPathWindowsRuntimePackageIdentity, Resolve-OpenPathWindowsRuntimeDependencies
