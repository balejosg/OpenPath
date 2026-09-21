Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.WindowsRuntime.psm1') -Force -Global

Describe 'Windows runtime baseline discovery' {
    BeforeAll {
        # AppControl tests reload their module and its dependencies during the
        # same Pester process. Re-import this leaf's public module at execution
        # time so combined CI shards retain the runtime command surface.
        Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.WindowsRuntime.psm1') -Force -Global -ErrorAction Stop
        $script:osClient = [pscustomobject]@{ ProductType = 'client'; Edition = 'Pro'; Build = '26100'; Architecture = 'x64' }
        $script:identity = [pscustomobject]@{
            AppX = $true
            Publisher = [pscustomobject]@{ PublisherName = 'CN=Microsoft Windows'; ProductName = 'ShellExperienceHost'; BinaryName = 'ShellExperienceHost.exe' }
        }
    }

    It 'selects protected SystemApps roots and exact declared dependencies only' {
        $framework = [pscustomobject]@{ Name = 'Windows.Framework'; PublisherId = 'Microsoft'; Version = '2.0.0.0'; InstallLocation = 'C:\Program Files\WindowsApps\Windows.Framework_2'; Dependencies = @(); AppLockerIdentity = [pscustomobject]@{ AppX = $true; Publisher = [pscustomobject]@{ PublisherName = 'CN=Microsoft Framework'; ProductName = 'Windows.Framework'; BinaryName = 'framework.dll' } } }
        $root = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\ShellExperienceHost_1'; Dependencies = @([pscustomobject]@{ Name = 'Windows.Framework'; PublisherId = 'Microsoft'; MinVersion = '1.0.0.0' }); AppLockerIdentity = $script:identity }
        $evil = [pscustomobject]@{ Name = 'ThirdParty'; PublisherId = 'Microsoft'; Version = '9.0.0.0'; InstallLocation = 'C:\Windows\SystemAppsEvil\ThirdParty'; Dependencies = @(); AppLockerIdentity = [pscustomobject]@{ PublisherName = 'CN=ThirdParty'; ProductName = 'ThirdParty'; BinaryName = 'thirdparty.exe' } }
        $baseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root, $framework, $evil) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $baseline.Status | Should -Be 'passed'
        @($baseline.Packages | ForEach-Object Name) | Should -Contain 'ShellExperienceHost'
        @($baseline.Packages | ForEach-Object Name) | Should -Contain 'Windows.Framework'
        @($baseline.Packages | ForEach-Object Name) | Should -Not -Contain 'ThirdParty'
        (Test-OpenPathWindowsRuntimeBaseline -Baseline $baseline) | Should -BeTrue
    }

    It 'rejects server and inventory failures instead of treating an empty list as a client baseline' {
        $server = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @() -OsIdentity ([pscustomobject]@{ ProductType = 'server'; Edition = 'Server'; Build = '1'; Architecture = 'x64' }) -WindowsRoot 'C:\Windows'
        (Test-OpenPathWindowsRuntimeBaseline -Baseline $server) | Should -BeFalse
        function global:Get-AppxPackage { throw 'Appx provider unavailable' }
        Mock Get-AppxPackage { throw 'Appx provider unavailable' }
        $failed = Get-OpenPathWindowsRuntimeBaseline -OsIdentity $script:osClient -WindowsRoot 'C:\Windows'
        $failed.Status | Should -Be 'failed'
        $failed.ReasonCodes | Should -Contain 'appcontrol_windows_runtime_inventory_failed'
        Remove-Item Function:\Get-AppxPackage -ErrorAction SilentlyContinue
    }

    It 'rejects partial publisher identities and path escapes' {
        $badIdentity = [pscustomobject]@{ AppX = $true; Publisher = [pscustomobject]@{ PublisherName = 'O=MICROSOFT CORPORATION*'; ProductName = 'Shell'; BinaryName = 'shell.exe' } }
        { Get-OpenPathWindowsRuntimePackageIdentity -Package ([pscustomobject]@{ Name = 'Shell'; PublisherId = 'Microsoft'; Version = '1'; InstallLocation = 'C:\Windows\SystemApps\Shell' }) -NativeIdentity $badIdentity } | Should -Throw 'appcontrol_publisher_identity_invalid'
        $escaped = [pscustomobject]@{ Name = 'Shell'; PublisherId = 'Microsoft'; Version = '1'; InstallLocation = 'C:\Windows\SystemApps\..\System32'; Dependencies = @(); AppLockerIdentity = $script:identity }
        $baseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($escaped) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $baseline.Status | Should -Be 'failed'
        $dependency = [pscustomobject]@{ Name = 'Runtime.Framework'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Program Files\WindowsApps\Runtime.Framework_1'; Dependencies = @(); AppLockerIdentity = $script:identity }
        $rootWithEscapedDependency = [pscustomobject]@{ Name = 'Shell'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\Shell_1'; Dependencies = @([pscustomobject]@{ Name = 'Runtime.Framework'; PublisherId = 'Microsoft' }); AppLockerIdentity = $script:identity }
        $dependency.InstallLocation = 'C:\Program Files\WindowsApps\..\System32\Runtime.Framework_1'
        $dependencyBaseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($rootWithEscapedDependency, $dependency) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $dependencyBaseline.Status | Should -Be 'failed'
    }

    It 'uses the native package overload and rejects incomplete or false AppX identities' {
        $root = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\ShellExperienceHost_1'; Dependencies = @() }
        function global:Get-AppLockerFileInformation {
            param([object[]]$Packages, [object]$ErrorAction)
            $script:nativePackageCallCount = $script:nativePackageCallCount + 1
            [pscustomobject]@{ AppX = $true; Publisher = [pscustomobject]@{ PublisherName = 'CN=Microsoft Windows'; ProductName = 'ShellExperienceHost'; BinaryName = '*' } }
        }
        $script:nativePackageCallCount = 0
        try {
            $baseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows'
            $baseline.Status | Should -Be 'passed'
            $script:nativePackageCallCount | Should -Be 1
            @($baseline.NativeAppLockerPackages).Count | Should -Be 1
            @($baseline.NativeAppLockerPackages)[0].Name | Should -Be 'ShellExperienceHost'
            $falseIdentity = [pscustomobject]@{ AppX = $false; Publisher = [pscustomobject]@{ PublisherName = 'CN=Microsoft Windows'; ProductName = 'ShellExperienceHost'; BinaryName = '*' } }
            { Get-OpenPathWindowsRuntimePackageIdentity -Package $root -NativeIdentity $falseIdentity } | Should -Throw 'appcontrol_publisher_identity_invalid'
            $missingPublisher = [pscustomobject]@{ AppX = $true }
            { Get-OpenPathWindowsRuntimePackageIdentity -Package $root -NativeIdentity $missingPublisher } | Should -Throw 'appcontrol_publisher_identity_invalid'
        }
        finally {
            Remove-Item Function:\Get-AppLockerFileInformation -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed for empty or duplicate native provider responses' {
        $root = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\ShellExperienceHost_1'; Dependencies = @() }
        $empty = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) @() }
        $empty.Status | Should -Be 'failed'
        $duplicate = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver {
            param($package)
            @(
                $script:identity
                $script:identity
            )
        }
        $duplicate.Status | Should -Be 'failed'
    }

    It 'skips AppX framework packages that AppLocker cannot represent' {
        $framework = [pscustomobject]@{ Name = 'Microsoft.VCLibs.140.00'; PublisherId = 'Microsoft'; Version = '14.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\Microsoft.VCLibs.140.00_1'; Dependencies = @(); IsFramework = $true; AppLockerIdentity = @() }
        $root = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\ShellExperienceHost_1'; Dependencies = @(); IsFramework = $false; AppLockerIdentity = $script:identity }
        $baseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root, $framework) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $baseline.Status | Should -Be 'passed'
        @($baseline.Packages | ForEach-Object Name) | Should -Not -Contain 'Microsoft.VCLibs.140.00'
        @($baseline.NativeAppLockerPackages).Count | Should -Be 1
        @($baseline.Packages).Count | Should -Be @($baseline.NativeAppLockerPackages).Count
        (Test-OpenPathWindowsRuntimeBaseline -Baseline $baseline) | Should -BeTrue
    }

    It 'still fails closed when a non-framework package has no AppLocker identity' {
        $root = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\ShellExperienceHost_1'; Dependencies = @(); IsFramework = $false; AppLockerIdentity = @() }
        $baseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $baseline.Status | Should -Be 'failed'
        $baseline.ReasonCodes | Should -Contain 'appcontrol_windows_runtime_inventory_failed'
    }

    It 'resolves exact dependency publisher, version, architecture, leaves and cycles' {
        $dep = [pscustomobject]@{ Name = 'Runtime.Framework'; PublisherId = 'Trusted'; Version = '2.0.0.0'; Architecture = 'x64'; InstallLocation = 'C:\Windows\SystemApps\Runtime.Framework_2'; Dependencies = @(); AppLockerIdentity = $script:identity }
        $root = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Trusted'; Version = '1.0.0.0'; Architecture = 'x64'; InstallLocation = 'C:\Windows\SystemApps\ShellExperienceHost_1'; Dependencies = @([pscustomobject]@{ Name = 'Runtime.Framework'; PublisherId = 'Trusted'; MinVersion = '1.0.0.0'; Architecture = 'x64' }); AppLockerIdentity = $script:identity }
        $wrongPublisher = $dep.PSObject.Copy(); $wrongPublisher.PublisherId = 'Other'
        $baseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root, $dep, $wrongPublisher) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $baseline.Status | Should -Be 'passed'
        @($baseline.NativePackages | ForEach-Object Name) | Should -Contain 'Runtime.Framework'
        $missing = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $missing.Status | Should -Be 'failed'

        $cycleA = $root.PSObject.Copy(); $cycleB = $dep.PSObject.Copy(); $cycleA.Dependencies = @([pscustomobject]@{ Name = 'Runtime.Framework'; PublisherId = 'Trusted' }); $cycleB.Dependencies = @([pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Trusted' })
        $cycled = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($cycleA, $cycleB) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $cycled.Status | Should -Be 'failed'
    }

    It 'rejects denied required runtime packages and altered canonical hashes' {
        $root = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherId = 'Microsoft'; Version = '1.0.0.0'; InstallLocation = 'C:\Windows\SystemApps\ShellExperienceHost_1'; Dependencies = @(); AppLockerIdentity = $script:identity }
        $denied = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root) -DeniedPackageNames @('ShellExperienceHost') -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $denied.Status | Should -Be 'failed'
        $denied.ReasonCodes | Should -Contain 'appcontrol_windows_runtime_policy_conflict'
        $valid = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($root) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $valid.BaseHash = ('0' * 64)
        Test-OpenPathWindowsRuntimeBaseline -Baseline $valid | Should -BeFalse
    }
}
