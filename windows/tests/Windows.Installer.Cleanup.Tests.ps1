Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Installer cleanup helper" {
    It "Defines reinstall cleanup helpers that preserve Acrylic and logs" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        Test-Path $cleanupHelperPath | Should -BeTrue
        $content = Get-Content $cleanupHelperPath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'function Test-OpenPathExistingInstallation',
            'function Copy-OpenPathInstallerSourceForReinstall',
            'function Invoke-OpenPathInstallerExistingInstallCleanup',
            'function Get-OpenPathInstallerFirewallManifestRuleNames',
            '[switch]$KeepAcrylic',
            '[switch]$KeepLogs',
            'openpath-reinstall-source-',
            'browser-policy-spec.json',
            'Stop-OpenPathInstallerScheduledTasks',
            'Remove-OpenPathInstallerAppLockerRules',
            'Remove-OpenPathInstallerFirewallRules',
            'Restore-OpenPathInstallerDnsSettings',
            'Remove-OpenPathInstallerBrowserArtifacts',
            'Remove-OpenPathInstallerInstallRoot -KeepLogs:$KeepLogs'
        )
    }

    It "Does not uninstall Acrylic as part of reinstall cleanup" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        $content = Get-Content $cleanupHelperPath -Raw

        $content | Should -Not -Match '/UNINSTALL'
        $content | Should -Not -Match 'Remove-Item.*Acrylic DNS Proxy'
        $content | Should -Match 'Acrylic removal is intentionally not performed by reinstall cleanup'
    }

    It "Matches AppLocker rules by Name attribute instead of XML element name" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
        $cleanupContent = Get-Content $cleanupHelperPath -Raw
        $uninstallContent = Get-Content $uninstallPath -Raw

        Assert-ContentContainsAll -Content $cleanupContent -Needles @(
            '$_.GetAttribute(''Name'') -like ''OpenPath non-admin app control*''',
            '$rule.GetAttribute(''Name'') -like ''OpenPath non-admin app control*'''
        )
        Assert-ContentContainsAll -Content $uninstallContent -Needles @(
            '$rule.GetAttribute(''Name'') -like ''OpenPath non-admin app control*'''
        )

        $cleanupContent | Should -Not -Match '\\$rule\\.Name\\s+-like\\s+''OpenPath non-admin app control'
        $cleanupContent | Should -Not -Match '\\$_\\.Name\\s+-like\\s+''OpenPath non-admin app control'
        $uninstallContent | Should -Not -Match '\\$rule\\.Name\\s+-like\\s+''OpenPath non-admin app control'
    }

    It "Ignores AppLocker policies without rule collections" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        . $cleanupHelperPath

        function global:Get-AppLockerPolicy {
            return @'
<AppLockerPolicy Version="1"></AppLockerPolicy>
'@
        }

        function global:Set-AppLockerPolicy {
            throw 'Set-AppLockerPolicy should not be called when no OpenPath rules are present'
        }

        try {
            { Remove-OpenPathInstallerAppLockerRules } | Should -Not -Throw
        }
        finally {
            Remove-Item Function:\Get-AppLockerPolicy -ErrorAction SilentlyContinue
            Remove-Item Function:\Set-AppLockerPolicy -ErrorAction SilentlyContinue
        }
    }

    It "Removes the OpenPath-Restricted group during cleanup" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        $cleanupHelper = Get-Content $cleanupHelperPath -Raw

        Assert-ContentContainsAll -Content $cleanupHelper -Needles @(
            'function Remove-OpenPathInstallerRestrictedGroup',
            "Remove-LocalGroup -Name 'OpenPath-Restricted'"
        )
        $appLockerIndex = $cleanupHelper.IndexOf('Remove-OpenPathInstallerAppLockerRules')
        $restrictedGroupIndex = $cleanupHelper.IndexOf('Remove-OpenPathInstallerRestrictedGroup')
        $appLockerIndex | Should -BeGreaterThan -1
        $restrictedGroupIndex | Should -BeGreaterThan -1
    }

    It "Removes the restricted group when cleanup runs and is silent when absent" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        . $cleanupHelperPath

        $global:opCleanupRemoveCalls = 0
        function global:Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted' } }
        function global:Remove-LocalGroup { param($Name) $global:opCleanupRemoveCalls++ }
        try {
            Remove-OpenPathInstallerRestrictedGroup
            $global:opCleanupRemoveCalls | Should -Be 1
        }
        finally {
            Remove-Item Function:\Get-LocalGroup -ErrorAction SilentlyContinue
            Remove-Item Function:\Remove-LocalGroup -ErrorAction SilentlyContinue
            Remove-Item Variable:\opCleanupRemoveCalls -ErrorAction SilentlyContinue
        }
    }

    It "Uninstall removes the restricted group via AppControl when available" {
        $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
        $content = Get-Content $uninstallPath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            "Get-Command -Name Remove-OpenPathRestrictedGroup -ErrorAction SilentlyContinue",
            'Remove-OpenPathRestrictedGroup | Out-Null'
        )
    }

    It "Restores DNS from legacy snapshots with array interface indexes" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        . $cleanupHelperPath

        $createdCDrive = $false
        if (-not (Get-PSDrive -Name C -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name C -PSProvider FileSystem -Root $TestDrive -Scope Global | Out-Null
            $createdCDrive = $true
        }

        $script:setDnsCalls = @()

        function global:Test-Path {
            param([string]$Path)
            return ([string]$Path).Replace('/', '\') -eq 'C:\OpenPath\data\original-dns.json'
        }

        function global:Get-Content {
            param(
                [string]$Path,
                [switch]$Raw
            )

            return @'
[
  {
    "InterfaceGuid": "stale-guid",
    "InterfaceAlias": "Ethernet",
    "InterfaceIndex": [12, 99],
    "ServerAddresses": ["1.1.1.1", "8.8.8.8"]
  }
]
'@
        }

        function global:Get-NetAdapter {
            [pscustomobject]@{
                InterfaceGuid = 'live-guid'
                Name = 'Ethernet'
                ifIndex = 12
                Status = 'Up'
            }
        }

        function global:Set-DnsClientServerAddress {
            [CmdletBinding()]
            param(
                [int]$InterfaceIndex,
                [string[]]$ServerAddresses,
                [switch]$ResetServerAddresses
            )

            $script:setDnsCalls += [pscustomobject]@{
                InterfaceIndex = $InterfaceIndex
                ServerAddresses = @($ServerAddresses)
                ResetServerAddresses = $ResetServerAddresses.IsPresent
            }
        }

        function global:Clear-DnsClientCache {}

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'

        try {
            { Restore-OpenPathInstallerDnsSettings } | Should -Not -Throw
            $script:setDnsCalls.Count | Should -Be 1
            $script:setDnsCalls[0].InterfaceIndex | Should -Be 12
            $script:setDnsCalls[0].ResetServerAddresses | Should -BeFalse
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
            Remove-Item Function:\Test-Path -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-Content -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-NetAdapter -ErrorAction SilentlyContinue
            Remove-Item Function:\Set-DnsClientServerAddress -ErrorAction SilentlyContinue
            Remove-Item Function:\Clear-DnsClientCache -ErrorAction SilentlyContinue
            Remove-Variable -Name setDnsCalls -Scope Script -ErrorAction SilentlyContinue
            if ($createdCDrive) {
                Remove-PSDrive -Name C -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    It "Ignores a corrupt firewall manifest and still removes OpenPath firewall rules" {
        $cleanupHelperPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Cleanup.ps1"
        . $cleanupHelperPath

        $script:removedFirewallRules = @()
        $script:requestedFirewallRules = @()
        $script:manifestRead = $false
        $createdCDrive = $false
        if (-not (Get-PSDrive -Name C -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name C -PSProvider FileSystem -Root $TestDrive -Scope Global | Out-Null
            $createdCDrive = $true
        }
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'

        function global:Get-NetFirewallRule {
            [CmdletBinding()]
            param(
                [string]$DisplayName,
                [string]$Group
            )

            if ($DisplayName) {
                $script:requestedFirewallRules += $DisplayName
                if ($DisplayName -eq 'OpenPath-DNS-*') {
                    return [PSCustomObject]@{ DisplayName = 'OpenPath-DNS-fallback-rule' }
                }
                return [PSCustomObject]@{ DisplayName = $DisplayName }
            }

            if ($Group -eq 'OpenPath') {
                $script:requestedFirewallRules += 'group:OpenPath'
                return [PSCustomObject]@{ DisplayName = 'OpenPath-group-rule' }
            }
        }

        function global:Remove-NetFirewallRule {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline = $true)]$InputObject)

            process {
                if ($InputObject -and $InputObject.DisplayName) {
                    $script:removedFirewallRules += [string]$InputObject.DisplayName
                }
            }
        }

        function global:Test-Path {
            param([string]$Path)
            return ([string]$Path).Replace('/', '\') -eq 'C:\OpenPath\data\firewall-rules.json'
        }

        function global:Get-Content {
            param(
                [string]$Path,
                [switch]$Raw
            )

            $script:manifestRead = $true
            return '[ "OpenPath-DNS-Allow-Loopback-TCP", '
        }

        function global:Write-InstallerWarning {
            param([string]$Message)
        }

        try {
            { Remove-OpenPathInstallerFirewallRules } | Should -Not -Throw
            $script:manifestRead | Should -BeTrue
            $script:requestedFirewallRules | Should -Contain 'group:OpenPath'
            $script:requestedFirewallRules | Should -Contain 'OpenPath-DNS-*'
            $script:removedFirewallRules | Should -Contain 'OpenPath-group-rule'
            $script:removedFirewallRules | Should -Contain 'OpenPath-DNS-fallback-rule'
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
            Microsoft.PowerShell.Management\Remove-Item Function:\Get-NetFirewallRule -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item Function:\Remove-NetFirewallRule -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item Function:\Test-Path -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item Function:\Get-Content -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item Function:\Write-InstallerWarning -ErrorAction SilentlyContinue
            Remove-Variable -Name removedFirewallRules -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name requestedFirewallRules -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name manifestRead -Scope Script -ErrorAction SilentlyContinue
            if ($createdCDrive) {
                Microsoft.PowerShell.Management\Remove-PSDrive -Name C -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    It "Makes standalone uninstall independent of installed OpenPath modules" {
        $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
        $content = Get-Content $uninstallPath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'function Remove-OpenPathFallbackAppLockerRules',
            'function Restore-OpenPathOriginalDns',
            'function Remove-OpenPathFirewallRules',
            'function Get-OpenPathUninstallFirewallManifestRuleNames',
            'ExtensionInstallForcelist',
            'Start-Process -FilePath "$acrylicPath\AcrylicService.exe" -ArgumentList ''/UNINSTALL''',
            'WaitForExit(120000)',
            '& sc.exe delete AcrylicDNSProxySvc',
            "Get-NetFirewallRule -Group 'OpenPath'",
            "data\original-dns.json",
            "data\firewall-rules.json"
        )
    }
    It "Standalone uninstall restores DNS from v2 snapshots and never keeps a loopback resolver" {
        $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($uninstallPath, [ref]$null, [ref]$null)
        $wanted = @(
            'Select-OpenPathUninstallScalarValue',
            'ConvertTo-OpenPathUninstallNullableInt',
            'Test-OpenPathUninstallLoopbackAddress',
            'Restore-OpenPathOriginalDns'
        )
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }

        $createdCDrive = $false
        if (-not (Get-PSDrive -Name C -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name C -PSProvider FileSystem -Root $TestDrive -Scope Global | Out-Null
            $createdCDrive = $true
        }

        $OpenPathRoot = 'C:\OpenPath'
        $script:setDnsCalls = @()

        function global:Test-Path {
            param([string]$Path)
            return ([string]$Path).Replace('/', '\') -eq 'C:\OpenPath\data\original-dns.json'
        }

        function global:Get-Content {
            param([string]$Path, [switch]$Raw)
            return @'
{
  "version": 2,
  "networkFingerprint": "x",
  "adapters": [
    { "InterfaceGuid": "live-guid", "InterfaceAlias": "Ethernet", "InterfaceIndex": 12, "ServerAddresses": ["127.0.0.1"] },
    { "InterfaceGuid": "wifi-guid", "InterfaceAlias": "Wi-Fi", "InterfaceIndex": 7, "ServerAddresses": ["192.168.1.1", "127.0.0.1"] }
  ]
}
'@
        }

        function global:Get-NetAdapter {
            [pscustomobject]@{ InterfaceGuid = 'live-guid'; Name = 'Ethernet'; ifIndex = 12; Status = 'Up' }
            [pscustomobject]@{ InterfaceGuid = 'wifi-guid'; Name = 'Wi-Fi'; ifIndex = 7; Status = 'Up' }
        }

        function global:Get-DnsClientServerAddress {
            [CmdletBinding()] param()
            [pscustomobject]@{ InterfaceIndex = 99; ServerAddresses = @('127.0.0.1') }
            [pscustomobject]@{ InterfaceIndex = 12; ServerAddresses = @() }
        }

        function global:Set-DnsClientServerAddress {
            [CmdletBinding()]
            param([int]$InterfaceIndex, [string[]]$ServerAddresses, [switch]$ResetServerAddresses)
            $script:setDnsCalls += [pscustomobject]@{
                InterfaceIndex = $InterfaceIndex
                ServerAddresses = @($ServerAddresses)
                ResetServerAddresses = $ResetServerAddresses.IsPresent
            }
        }

        function global:Clear-DnsClientCache {}

        try {
            Restore-OpenPathOriginalDns

            $ethernet = @($script:setDnsCalls | Where-Object InterfaceIndex -eq 12)
            $ethernet.Count | Should -Be 1
            $ethernet[0].ResetServerAddresses | Should -BeTrue

            $wifi = @($script:setDnsCalls | Where-Object InterfaceIndex -eq 7)
            $wifi.Count | Should -Be 1
            $wifi[0].ServerAddresses | Should -Be @('192.168.1.1')

            # Safety net: an adapter outside the snapshot still pinned to loopback is reset.
            $stray = @($script:setDnsCalls | Where-Object InterfaceIndex -eq 99)
            $stray.Count | Should -Be 1
            $stray[0].ResetServerAddresses | Should -BeTrue
        }
        finally {
            Remove-Item Function:\Test-Path -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-Content -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-NetAdapter -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-DnsClientServerAddress -ErrorAction SilentlyContinue
            Remove-Item Function:\Set-DnsClientServerAddress -ErrorAction SilentlyContinue
            Remove-Item Function:\Clear-DnsClientCache -ErrorAction SilentlyContinue
            Remove-Variable -Name setDnsCalls -Scope Script -ErrorAction SilentlyContinue
            if ($createdCDrive) {
                Remove-PSDrive -Name C -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    It "Standalone uninstall restores the outbound firewall default left by the egress floor" {
        $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
        $content = Get-Content $uninstallPath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'function Restore-OpenPathOutboundDefault',
            'egress-floor-prev-outbound.json',
            'Set-NetFirewallProfile -Profile $profileName -DefaultOutboundAction $action'
        )
        $content | Should -Match '(?s)function Remove-OpenPathFirewallRules \{\s+Restore-OpenPathOutboundDefault'
    }
    It "Standalone uninstall removes the Firefox force-install policy and schedules the add-on uninstall" {
        $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($uninstallPath, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-OpenPathFirefoxManagedExtension' }, $true)) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }

        $OpenPathRoot = Join-Path $TestDrive 'OpenPath'
        $script:registryWrites = @()
        $script:registryRemoved = @()
        $script:extensionSettings = @(
            '{"renamed-id@openpath":{"installation_mode":"force_installed","install_url":"https://x.example/api/extensions/firefox/openpath.xpi?openpath_version=1"},"other@vendor":{"installation_mode":"allowed"}}'
        )

        function global:Test-Path {
            param([string]$Path, [string]$LiteralPath)
            $target = [string]$Path + [string]$LiteralPath
            return ($target -like '*firefox.exe')
        }
        function global:Get-ItemProperty {
            [CmdletBinding()] param([string]$Path, [string]$Name)
            if ($Name -eq 'ExtensionSettings') { return [pscustomobject]@{ ExtensionSettings = $script:extensionSettings } }
            throw 'not found'
        }
        function global:Get-Item { [CmdletBinding()] param([string]$Path) throw 'not found' }
        function global:New-Item { [CmdletBinding()] param([string]$Path, [switch]$Force) }
        function global:Remove-ItemProperty { [CmdletBinding()] param([string]$Path, [string]$Name) $script:registryRemoved += $Name }
        function global:New-ItemProperty {
            [CmdletBinding()] param([string]$Path, [string]$Name, $Value, [string]$PropertyType, [switch]$Force)
            $script:registryWrites += [pscustomobject]@{ Path = $Path; Name = $Name; Value = $Value }
        }

        try {
            Remove-OpenPathFirefoxManagedExtension

            # Only the OpenPath entry (matched by install_url, whatever its id) is dropped.
            $settingsWrite = @($script:registryWrites | Where-Object Name -eq 'ExtensionSettings')
            $settingsWrite.Count | Should -Be 1
            $settingsWrite[0].Value[0] | Should -Match 'other@vendor'
            $settingsWrite[0].Value[0] | Should -Not -Match 'renamed-id@openpath'

            $uninstallIds = @($script:registryWrites | Where-Object { $_.Path -like '*Extensions\Uninstall' } | ForEach-Object { $_.Value })
            $uninstallIds | Should -Contain 'renamed-id@openpath'
            $uninstallIds | Should -Contain 'openpath-block-monitor@openpath'
        }
        finally {
            foreach ($name in 'Test-Path', 'Get-ItemProperty', 'Get-Item', 'New-Item', 'Remove-ItemProperty', 'New-ItemProperty') {
                Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
            }
            Remove-Variable -Name registryWrites, registryRemoved, extensionSettings -Scope Script -ErrorAction SilentlyContinue
        }
    }
}
