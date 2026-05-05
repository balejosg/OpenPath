# OpenPath Browser Enforcement Status Module for Windows

Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.RequestReadiness.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\AppControl.psm1" -Force -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\Firewall.psm1" -Force -ErrorAction SilentlyContinue

function Get-OpenPathBrowserStatusConfigValue {
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
    param(
        [AllowNull()]
        [object]$Config
    )

    $active = $false
    if (Get-Command -Name 'Test-OpenPathNonAdminAppControlActive' -ErrorAction SilentlyContinue) {
        try {
            $active = [bool](Test-OpenPathNonAdminAppControlActive)
        }
        catch {
            $active = $false
        }
    }

    if (-not $active) {
        return 'Inactive'
    }

    # AppControl currently exposes active/inactive only; use config mode to label active audit posture.
    $configuredMode = [string](Get-OpenPathBrowserStatusConfigValue -Config $Config -PropertyName 'nonAdminAppControlMode' -DefaultValue 'Enforced')
    if ($configuredMode -eq 'AuditOnly') {
        return 'AuditOnly'
    }

    return 'Enforced'
}

function Get-OpenPathFirewallStatusSummary {
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
    $firewall = Get-OpenPathFirewallStatusSummary

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

    $healthySignals = @(
        ($appLocker -ne 'Inactive'),
        [bool]$inventory.Ready,
        [bool]$readiness.Ready,
        [bool]$firewall.Active
    )
    $healthyCount = @($healthySignals | Where-Object { $_ }).Count
    $overall = if ($healthyCount -eq $healthySignals.Count) {
        'Healthy'
    }
    elseif ($healthyCount -gt 0) {
        'Partial'
    }
    else {
        'Unhealthy'
    }

    return [PSCustomObject]@{
        AppLocker = $appLocker
        ApprovedStudentBrowsers = ($approvedStudentBrowsers -join ', ')
        ApprovedBrowsers = $approvedSummary
        BlockedByAppLockerBrowsers = $blockedByAppLockerSummary
        UnmanagedBrowsers = $unmanagedSummary
        Firewall = $firewall
        BrowserCleanupMode = $browserCleanupMode
        BrowserRequestReadiness = [bool]$readiness.Ready
        Overall = $overall
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserEnforcementStatus'
)
