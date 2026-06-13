# OpenPath Network Module for Windows
# Host network-adapter controls that complement the DNS sinkhole and firewall policy.
# Currently: neutralizing hypervisor "bridged" networking so guest VMs cannot become
# unfiltered LAN peers, while leaving NAT-mode guests (which the host filters) working.

$modulePath = Split-Path $PSScriptRoot -Parent
Import-Module "$modulePath\lib\Common.psm1" -ErrorAction SilentlyContinue

$script:NetworkHelperRoot = Join-Path $PSScriptRoot 'internal'

. (Join-Path $script:NetworkHelperRoot 'Network.BridgeFilters.ps1')

Export-ModuleMember -Function @(
    'Get-OpenPathBridgeFilterCatalog',
    'Get-OpenPathAdaptersWithBridgeFilters',
    'Save-OpenPathOriginalBridgeFilterSnapshot',
    'Disable-OpenPathBridgeFilters',
    'Restore-OpenPathOriginalBridgeFilters'
)
