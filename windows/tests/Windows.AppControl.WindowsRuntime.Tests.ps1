Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.WindowsRuntime.psm1') -Force -Global

Describe 'Windows runtime baseline discovery' {
    BeforeAll {
        $script:osClient = [pscustomobject]@{ ProductType = 'client'; Edition = 'Pro'; Build = '26100'; Architecture = 'x64' }
        $script:identity = [pscustomobject]@{ PublisherName = 'CN=Microsoft Windows'; ProductName = 'ShellExperienceHost'; BinaryName = 'ShellExperienceHost.exe' }
    }

    It 'selects protected SystemApps roots and exact declared dependencies only' {
        $framework = [pscustomobject]@{ Name = 'Windows.Framework'; PublisherId = 'Microsoft'; Version = '2.0.0.0'; InstallLocation = 'C:\Program Files\WindowsApps\Windows.Framework_2'; Dependencies = @(); AppLockerIdentity = [pscustomobject]@{ PublisherName = 'CN=Microsoft Framework'; ProductName = 'Windows.Framework'; BinaryName = 'framework.dll' } }
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
        $badIdentity = [pscustomobject]@{ PublisherName = 'O=MICROSOFT CORPORATION*'; ProductName = 'Shell'; BinaryName = 'shell.exe' }
        { Get-OpenPathWindowsRuntimePackageIdentity -Package ([pscustomobject]@{ Name = 'Shell'; PublisherId = 'Microsoft'; Version = '1'; InstallLocation = 'C:\Windows\SystemApps\Shell' }) -NativeIdentity $badIdentity } | Should -Throw 'appcontrol_publisher_identity_invalid'
        $escaped = [pscustomobject]@{ Name = 'Shell'; PublisherId = 'Microsoft'; Version = '1'; InstallLocation = 'C:\Windows\SystemApps\..\System32'; Dependencies = @(); AppLockerIdentity = $script:identity }
        $baseline = Get-OpenPathWindowsRuntimeBaseline -PackageInventory @($escaped) -OsIdentity $script:osClient -WindowsRoot 'C:\Windows' -AppLockerIdentityResolver { param($package) $package.AppLockerIdentity }
        $baseline.Status | Should -Be 'failed'
    }
}
