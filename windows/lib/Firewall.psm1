# OpenPath Firewall Module for Windows
# Manages Windows Firewall rules to prevent DNS bypass

$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue
Import-Module "$modulePath\lib\Browser.Inventory.psm1" -ErrorAction SilentlyContinue

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
    'Get-OpenPathDnsEgressBlockRanges',
    'Get-OpenPathStudentEgressFloorRules',
    'Get-OpenPathStudentNetworkPrograms',
    'Set-OpenPathStudentEgressFloor',
    'Test-OpenPathStudentEgressFloorDrift',
    'Get-OpenPathEgressFloorStudentProgramsFromConfig',
    'Enable-OpenPathEgressFloorAudit',
    'Disable-OpenPathEgressFloorAudit',
    'Get-OpenPathEgressFloorBlockedConnections',
    'Format-OpenPathEgressFloorReport',
    'Get-OpenPathEgressFloorProfileNames',
    'Get-OpenPathEgressFloorPreviousOutboundStatePath',
    'Save-OpenPathEgressFloorPreviousOutbound',
    'Restore-OpenPathEgressFloorPreviousOutbound',
    'Remove-OpenPathEgressFloorRules',
    'Add-OpenPathCaptivePortalUpstreamFirewallAllow',
    'Remove-OpenPathFirewall',
    'Test-FirewallActive',
    'Get-FirewallStatus',
    'Disable-OpenPathFirewall',
    'Enable-OpenPathFirewall'
)
