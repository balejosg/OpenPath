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

    It "Makes standalone uninstall independent of installed OpenPath modules" {
        $uninstallPath = Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1"
        $content = Get-Content $uninstallPath -Raw

        Assert-ContentContainsAll -Content $content -Needles @(
            'function Remove-OpenPathFallbackAppLockerRules',
            'function Restore-OpenPathOriginalDns',
            'function Remove-OpenPathFirewallRules',
            'ExtensionInstallForcelist',
            '& "$acrylicPath\AcrylicService.exe" /UNINSTALL',
            '& sc.exe delete AcrylicDNSProxySvc',
            "Get-NetFirewallRule -Group 'OpenPath'",
            "data\original-dns.json",
            "data\firewall-rules.json"
        )
    }
}
