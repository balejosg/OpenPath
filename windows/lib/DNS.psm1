# OpenPath DNS Module for Windows
# Manages Acrylic DNS Proxy configuration and service
$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue
$script:InternalModulePath = Join-Path $PSScriptRoot 'internal'

. (Join-Path $script:InternalModulePath 'DNS.Acrylic.Install.ps1')
. (Join-Path $script:InternalModulePath 'DNS.Acrylic.Config.ps1')
. (Join-Path $script:InternalModulePath 'DNS.Acrylic.Service.ps1')
. (Join-Path $script:InternalModulePath 'DNS.Diagnostics.ps1')

Export-ModuleMember -Function @(
    'Get-AcrylicPath',
    'Test-AcrylicInstalled',
    'Install-AcrylicDNS',
    'Ensure-AcrylicService',
    'Update-AcrylicHost',
    'Set-AcrylicConfiguration',
    'Clear-OpenPathRuntimeDependencyOverlay',
    'Get-OpenPathRuntimeDependencyDomains',
    'Set-LocalDNS',
    'Restore-OriginalDNS',
    'Restart-AcrylicService',
    'Start-AcrylicService',
    'Stop-AcrylicService',
    'Resolve-OpenPathDnsWithRetry',
    'Test-DNSResolution',
    'Test-DNSSinkhole'
)
