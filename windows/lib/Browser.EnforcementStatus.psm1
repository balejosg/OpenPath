# OpenPath Browser Enforcement Status Module for Windows

Import-Module "$PSScriptRoot\Browser.EnforcementDecision.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.RequestReadiness.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\AppControl.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Firewall.psm1" -Force -ErrorAction SilentlyContinue

function Get-OpenPathBrowserStatusConfigValue {
    # reads a named property from the config object, returning a default when the property is absent
    param(
        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($Config -and $Config.PSObject.Properties[$PropertyName]) {
        return $Config.PSObject.Properties[$PropertyName].Value
    }

    return $DefaultValue
}

function Join-OpenPathBrowserStatusSummary {
    # produces a sorted, deduplicated display string from a list of browser findings; returns EmptySummary when the list is empty
    param(
        [AllowNull()]
        [object[]]$Findings = @(),

        [string]$EmptySummary = 'None'
    )

    $summary = @(
        @($Findings) |
            ForEach-Object {
                $name = if ($_.Name) { [string]$_.Name } elseif ($_.DisplayName) { [string]$_.DisplayName } else { 'Unknown' }
                $location = if ($_.Path) { [string]$_.Path } elseif ($_.InstallLocation) { [string]$_.InstallLocation } else { '' }
                if ($location) {
                    "$name ($location)"
                }
                else {
                    $name
                }
            } |
            Sort-Object -Unique
    )

    if ($summary.Count -eq 0) {
        return $EmptySummary
    }

    return ($summary -join ', ')
}

function Get-OpenPathAppLockerStatus {
    # returns 'Enforced', 'AuditOnly', or 'Inactive' based on whether the non-admin app control boundary is currently active
    param(
        [AllowNull()]
        [object]$Config
    )

    if ($Config -and $Config.PSObject.Properties['appControlCommitState'] -and $Config.appControlCommitState -ne 'committed') {
        return 'Inactive'
    }
    if ($Config -and $Config.PSObject.Properties['installState'] -and $Config.installState -in @('installing', 'failed')) {
        return 'Inactive'
    }

    $configuredProfile = [string](Get-OpenPathBrowserStatusConfigValue -Config $Config -PropertyName 'appControlProfile' -DefaultValue 'ManagedBrowserCompatibility')
    if ($configuredProfile -eq 'StrictApplicationAllowlist' -and
        (-not $Config -or -not $Config.PSObject.Properties['activeAppControlProfile'])) {
        return 'Inactive'
    }
    if ($Config -and $Config.PSObject.Properties['activeAppControlProfile']) {
        $activeProfile = [string]$Config.activeAppControlProfile
        if ([string]::IsNullOrWhiteSpace($activeProfile) -or
            $activeProfile -eq 'none' -or
            -not $activeProfile.Equals($configuredProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'Inactive'
        }
    }

    if ($Config -and (-not $Config.PSObject.Properties['appControlCommitState'])) {
        $groupExists = $false
        if (Get-Command -Name 'Get-LocalGroup' -ErrorAction SilentlyContinue) {
            try {
                $null = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
                $groupExists = $true
            }
            catch {
                $groupExists = $false
            }
        }
        if (-not $groupExists) {
            return 'Inactive'
        }
    }

    $configuredMode = [string](Get-OpenPathBrowserStatusConfigValue -Config $Config -PropertyName 'nonAdminAppControlMode' -DefaultValue 'Enforced')
    $approvedStudentBrowsers = @(Get-OpenPathApprovedStudentBrowsers -Config $Config)
    $approvedApplicationCatalog = Get-OpenPathBrowserStatusConfigValue -Config $Config -PropertyName 'approvedApplicationCatalog' -DefaultValue $null
    $active = $false
    if (Get-Command -Name 'Test-OpenPathNonAdminAppControlActive' -ErrorAction SilentlyContinue) {
        try {
            $active = [bool](Test-OpenPathNonAdminAppControlActive `
                    -Mode $configuredMode `
                    -ApprovedBrowsers $approvedStudentBrowsers `
                    -Profile $configuredProfile `
                    -ApplicationCatalog $approvedApplicationCatalog)
        }
        catch {
            $active = $false
        }
    }

    if (-not $active) {
        return 'Inactive'
    }

    if ($configuredMode -eq 'AuditOnly') {
        return 'AuditOnly'
    }

    return 'Enforced'
}

function Get-OpenPathFirewallStatusSummary {
    # returns a normalized object with Active and rule count fields; returns zeroed defaults when the firewall module is unavailable
    $status = $null
    if (Get-Command -Name 'Get-FirewallStatus' -ErrorAction SilentlyContinue) {
        try {
            $status = Get-FirewallStatus
        }
        catch {
            $status = $null
        }
    }

    if (-not $status) {
        return [PSCustomObject]@{
            Active = $false
            TotalRules = 0
            EnabledRules = 0
            BlockRules = 0
            AllowRules = 0
        }
    }

    return [PSCustomObject]@{
        Active = [bool]$status.Active
        TotalRules = [int]$status.TotalRules
        EnabledRules = [int]$status.EnabledRules
        BlockRules = [int]$status.BlockRules
        AllowRules = [int]$status.AllowRules
    }
}

function Get-OpenPathBrowserEnforcementStatus {
    # assembles app control, inventory, request readiness, and firewall facts into a single enforcement status object
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $resolvedConfig = $Config
    if (-not $PSBoundParameters.ContainsKey('Config') -and (Get-Command -Name 'Get-OpenPathConfig' -ErrorAction SilentlyContinue)) {
        try {
            $resolvedConfig = Get-OpenPathConfig
        }
        catch {
            $resolvedConfig = $null
        }
    }

    $browserCleanupMode = [string](Get-OpenPathBrowserStatusConfigValue -Config $resolvedConfig -PropertyName 'browserCleanupMode' -DefaultValue 'ReportOnly')
    if ($browserCleanupMode -notin @('ReportOnly', 'RemoveKnownInstallers', 'Disabled')) {
        $browserCleanupMode = 'ReportOnly'
    }

    $inventoryMode = if ($browserCleanupMode -eq 'RemoveKnownInstallers') { 'RemoveKnownInstallers' } else { 'ReportOnly' }
    $inventory = Get-OpenPathBrowserInventory -Mode $inventoryMode
    $readiness = Get-OpenPathBrowserRequestReadiness -Config $resolvedConfig
    $appLocker = Get-OpenPathAppLockerStatus -Config $resolvedConfig
    $appControlHealth = $null
    if (Get-Command -Name Get-OpenPathNonAdminAppControlHealth -ErrorAction SilentlyContinue) {
        try {
            $configuredMode = [string](Get-OpenPathBrowserStatusConfigValue -Config $resolvedConfig -PropertyName 'nonAdminAppControlMode' -DefaultValue 'Enforced')
            $configuredProfile = [string](Get-OpenPathBrowserStatusConfigValue -Config $resolvedConfig -PropertyName 'appControlProfile' -DefaultValue 'ManagedBrowserCompatibility')
            $configuredCatalog = Get-OpenPathBrowserStatusConfigValue -Config $resolvedConfig -PropertyName 'approvedApplicationCatalog' -DefaultValue $null
            $appControlHealth = Get-OpenPathNonAdminAppControlHealth -Mode $configuredMode -Profile $configuredProfile -ApplicationCatalog $configuredCatalog
        }
        catch {
            $appControlHealth = [pscustomobject][ordered]@{
                Healthy = $false
                WindowsRuntimeValid = $false
                TransactionState = 'unknown'
                ReasonCodes = @('appcontrol_health_check_unavailable')
            }
        }
    }
    if ($null -eq $appControlHealth) {
        $appControlHealth = [pscustomobject][ordered]@{
            Healthy = $false
            WindowsRuntimeValid = $false
            TransactionState = 'unknown'
            ReasonCodes = @('appcontrol_health_check_unavailable')
        }
    }
    $firewall = Get-OpenPathFirewallStatusSummary
    $appControlProfile = [string](Get-OpenPathBrowserStatusConfigValue -Config $resolvedConfig -PropertyName 'appControlProfile' -DefaultValue 'ManagedBrowserCompatibility')
    $activeAppControlProfile = [string](Get-OpenPathBrowserStatusConfigValue -Config $resolvedConfig -PropertyName 'activeAppControlProfile' -DefaultValue 'none')

    $approvedBrowsers = @($inventory.ApprovedBrowsers)
    $unmanagedBrowsers = @($inventory.UnmanagedBrowsers) + @($inventory.PortableBrowserRisks)
    $approvedSummary = Join-OpenPathBrowserStatusSummary -Findings $approvedBrowsers
    $unmanagedSummary = Join-OpenPathBrowserStatusSummary -Findings $unmanagedBrowsers
    $approvedStudentBrowsers = @(Get-OpenPathApprovedStudentBrowsers -Config $resolvedConfig)
    $blockedByAppLockerBrowsers = @()
    if (($appLocker -ne 'Inactive') -and -not (Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $approvedStudentBrowsers -Browser Edge)) {
        $edgeFindings = @($approvedBrowsers | Where-Object { $_.Name -eq 'Microsoft Edge' })
        if ($edgeFindings.Count -gt 0) {
            $blockedByAppLockerBrowsers += $edgeFindings
        }
    }
    if (($appLocker -ne 'Inactive') -and -not (Test-OpenPathStudentBrowserApproved -ApprovedStudentBrowsers $approvedStudentBrowsers -Browser Chrome)) {
        $chromeFindings = @($approvedBrowsers | Where-Object { $_.Name -eq 'Google Chrome' })
        if ($chromeFindings.Count -gt 0) {
            $blockedByAppLockerBrowsers += $chromeFindings
        }
    }
    $blockedByAppLockerSummary = Join-OpenPathBrowserStatusSummary -Findings $blockedByAppLockerBrowsers -EmptySummary 'None'

    $overall = Browser.EnforcementDecision\Get-OpenPathBrowserEnforcementOverallDecision `
        -AppLocker $appLocker `
        -InventoryReady ([bool]$inventory.Ready) `
        -RequestReadinessReady ([bool]$readiness.Ready) `
        -FirewallActive ([bool]$firewall.Active)

    return [PSCustomObject]@{
        AppLocker = $appLocker
        AppControlProfile = $appControlProfile
        ActiveAppControlProfile = $activeAppControlProfile
        ApprovedStudentBrowsers = ($approvedStudentBrowsers -join ', ')
        ApprovedBrowsers = $approvedSummary
        BlockedByAppLockerBrowsers = $blockedByAppLockerSummary
        UnmanagedBrowsers = $unmanagedSummary
        Firewall = $firewall
        BrowserCleanupMode = $browserCleanupMode
        BrowserRequestReadiness = [bool]$readiness.Ready
        WindowsRuntimeValid = if ($appControlHealth.PSObject.Properties['WindowsRuntimeValid']) { [bool]$appControlHealth.WindowsRuntimeValid } else { $false }
        TransactionState = if ($appControlHealth.PSObject.Properties['TransactionState']) { [string]$appControlHealth.TransactionState } else { 'unknown' }
        AppControlReasonCodes = @($appControlHealth.ReasonCodes)
        DesktopRuntimeObservation = 'not-observed'
        AppControlHealth = $appControlHealth
        Overall = $overall
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserEnforcementStatus'
)
