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
            '& "$acrylicPath\AcrylicService.exe" /UNINSTALL',
            '& sc.exe delete AcrylicDNSProxySvc',
            "Get-NetFirewallRule -Group 'OpenPath'",
            "data\original-dns.json",
            "data\firewall-rules.json"
        )
    }
}
