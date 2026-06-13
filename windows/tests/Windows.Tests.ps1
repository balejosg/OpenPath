# OpenPath Windows Pester Tests
# Aggregates split module and script suites for CI and local Invoke-Pester entrypoints.

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

$script:modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module (Join-Path $script:modulePath "Common.psm1") -Force -Global -ErrorAction Stop
Import-Module (Join-Path $script:modulePath "DNS.psm1") -Force -Global -ErrorAction Stop
Import-Module (Join-Path $script:modulePath "Network.psm1") -Force -Global -ErrorAction Stop
Import-Module (Join-Path $script:modulePath "Firewall.psm1") -Force -Global -ErrorAction Stop

$suiteFiles = @(
    "Windows.Common.Tests.ps1",
    "Windows.DNS.Tests.ps1",
    "Windows.Network.Tests.ps1",
    "Windows.Firewall.Tests.ps1",
    "Windows.AppControl.Tests.ps1",
    "Windows.Services.Tests.ps1",
    "Windows.Cli.Tests.ps1",
    "Windows.Update.Tests.ps1",
    "Windows.Watchdog.Tests.ps1",
    "Windows.Installer.Tests.ps1",
    "Windows.Installer.Cleanup.Tests.ps1",
    "Windows.Enrollment.Tests.ps1",
    "Windows.Whitelist.Tests.ps1",
    "Windows.Browser.RequestReadiness.Tests.ps1",
    "Windows.Browser.NativeHost.Tests.ps1",
    "Windows.Browser.Diagnostics.Tests.ps1",
    "Windows.Browser.FirefoxConfig.Tests.ps1"
)

foreach ($suiteFile in $suiteFiles) {
    . (Join-Path $PSScriptRoot $suiteFile)
}
