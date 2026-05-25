# OpenPath DNS Common Module for Windows
# Provides shared functions for all openpath components

param()

# Configuration paths
$script:InternalModulePath = Join-Path $PSScriptRoot 'internal'
. (Join-Path $script:InternalModulePath 'WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
$script:ConfigPath = "$script:OpenPathRoot\data\config.json"
$script:LogPath = "$script:OpenPathRoot\data\logs\openpath.log"
$script:IntegrityBaselinePath = "$script:OpenPathRoot\data\integrity-baseline.json"
$script:IntegrityBackupPath = "$script:OpenPathRoot\data\integrity-backup"
$script:CheckpointPath = "$script:OpenPathRoot\data\checkpoints"
$script:DomainPattern = '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
. (Join-Path $script:InternalModulePath 'Common.System.ps1')
. (Join-Path $script:InternalModulePath 'CapabilityStorage.ps1')
. (Join-Path $script:InternalModulePath 'Common.Redaction.ps1')
. (Join-Path $script:InternalModulePath 'Common.Config.ps1')
. (Join-Path $script:InternalModulePath 'Common.Domains.ps1')
. (Join-Path $script:InternalModulePath 'Common.Http.ps1')
. (Join-Path $script:InternalModulePath 'Common.Whitelist.ps1')
. (Join-Path $script:InternalModulePath 'Common.Integrity.ps1')
. (Join-Path $script:InternalModulePath 'Common.Network.ps1')
. (Join-Path $script:InternalModulePath 'Common.Update.ps1')

Export-ModuleMember -Function @(
    'Test-AdminPrivileges',
    'Write-OpenPathLog',
    'Resolve-OpenPathWindowsRoot',
    'Get-OpenPathCapabilityStorageRoot',
    'Get-OpenPathCapabilityStoragePath',
    'Set-OpenPathCapabilityStorageAcl',
    'Test-OpenPathCapabilityStorageAcl',
    'Ensure-OpenPathCapabilityStorageDirectory',
    'Get-OpenPathConfig',
    'Set-OpenPathConfig',
    'Set-OpenPathConfigValue',
    'Get-OpenPathConfigValue',
    'ConvertTo-OpenPathNormalizedConfig',
    'Test-OpenPathConfig',
    'ConvertTo-OpenPathRedactedValue',
    'ConvertTo-OpenPathRedactedObject',
    'Get-OpenPathFileAgeHours',
    'Get-HostFromUrl',
    'Normalize-OpenPathAlwaysAllowedDomain',
    'Get-OpenPathProtectedDomains',
    'Get-OpenPathMicrosoftSystemDomains',
    'Get-OpenPathFirefoxSystemDomains',
    'Get-OpenPathAlwaysAllowedDomainGroups',
    'Get-OpenPathAlwaysAllowedDomains',
    'ConvertTo-OpenPathMachineName',
    'Get-OpenPathMachineName',
    'Test-OpenPathDomainFormat',
    'Get-OpenPathRuntimeHealth',
    'Restore-OpenPathProtectedMode',
    'Get-OpenPathDnsProbeDomains',
    'Get-ValidWhitelistDomainsFromFile',
    'Get-OpenPathWhitelistSectionsFromFile',
    'ConvertTo-OpenPathWhitelistFileContent',
    'Save-OpenPathWhitelistCheckpoint',
    'Get-OpenPathLatestCheckpoint',
    'Restore-OpenPathLatestCheckpoint',
    'Get-OpenPathCriticalFiles',
    'Save-OpenPathIntegrityBackup',
    'New-OpenPathIntegrityBaseline',
    'Test-OpenPathIntegrity',
    'Restore-OpenPathIntegrity',
    'Get-PrimaryDNS',
    'Get-OpenPathCaptivePortalUpstreamDns',
    'Get-OpenPathFromUrl',
    'Test-InternetConnection',
    'Send-OpenPathHealthReport',
    'Get-OpenPathMachineTokenFromWhitelistUrl',
    'New-OpenPathScopedMachineName',
    'New-OpenPathMachineRegistrationBody',
    'Resolve-OpenPathMachineRegistration',
    'Set-OpenPathMachineName',
    'Compare-OpenPathVersion',
    'Invoke-OpenPathAgentSelfUpdate'
)
