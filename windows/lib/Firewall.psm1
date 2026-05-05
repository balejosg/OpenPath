# OpenPath Firewall Module for Windows
# Manages Windows Firewall rules to prevent DNS bypass

$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue

$script:RulePrefix = 'OpenPath-DNS'
$script:FirewallHelperRoot = Join-Path $PSScriptRoot 'internal'

. (Join-Path $script:FirewallHelperRoot 'Firewall.Catalog.ps1')
. (Join-Path $script:FirewallHelperRoot 'Firewall.Policy.ps1')
. (Join-Path $script:FirewallHelperRoot 'Firewall.State.ps1')

Export-ModuleMember -Function @(
    'Get-DefaultDohResolverIps',
    'Get-DefaultResolverBypassClientPrograms',
    'Get-DefaultVpnBlockRules',
    'Get-DefaultTorBlockPorts',
    'Set-OpenPathFirewall',
    'Remove-OpenPathFirewall',
    'Test-FirewallActive',
    'Get-FirewallStatus',
    'Disable-OpenPathFirewall',
    'Enable-OpenPathFirewall'
)
