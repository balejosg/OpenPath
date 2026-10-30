function Get-OpenPathInstallerAgentVersion {
    # returns the agent version string from OPENPATH_VERSION env var, the VERSION file
    # beside scriptdir (offline package layout) or in its parent (repository layout),
    # or '0.0.0' as a fallback.
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptDir
    )

    if ($env:OPENPATH_VERSION) {
        return [string]$env:OPENPATH_VERSION
    }

    foreach ($versionDir in @($ScriptDir, (Split-Path $ScriptDir -Parent))) {
        if ([string]::IsNullOrWhiteSpace($versionDir)) { continue }
        $versionFilePath = Join-Path $versionDir 'VERSION'
        if (-not (Test-Path -LiteralPath $versionFilePath -PathType Leaf)) { continue }
        try {
            $versionFromFile = (Get-Content -LiteralPath $versionFilePath -Raw).Trim()
            if ($versionFromFile) {
                return $versionFromFile
            }
        }
        catch {
        }
    }

    return '0.0.0'
}

function New-OpenPathInstallerConfig {
    # builds and returns the full config hashtable for a fresh installation; optional fields
    # (api url, classroom, captive portal domains, browser extension ids, etc.) are included
    # only when non-empty.
    param(
        [string]$WhitelistUrl = '',

        [Parameter(Mandatory = $true)]
        [string]$AgentVersion,

        [Parameter(Mandatory = $true)]
        [string]$PrimaryDNS,

        [string]$ApiBaseUrl = '',
        [string]$Classroom = '',
        [string]$ClassroomId = '',
        [string[]]$CaptivePortalDomains = @(),
        [string]$HealthApiSecret = '',
        [string]$FirefoxExtensionId = '',
        [string]$FirefoxExtensionInstallUrl = '',
        [string]$ChromeExtensionStoreUrl = '',
        [string]$EdgeExtensionStoreUrl = '',

        [bool]$EnforceManagedBrowserBoundary = $false,

        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$AppControlProfile = 'ManagedBrowserCompatibility',

        [AllowNull()]
        [object]$ApprovedApplicationCatalog = $null,

        [string[]]$ApprovedStudentBrowsers = @('Firefox'),

        [ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]
        [string]$BrowserCleanupMode = 'ReportOnly',

        # Phase 8e E1: the early smart-app-control phase decision (previous
        # state, action, result, reboot flag and date); persisted so the
        # administrator can see later why the machine was changed.
        [AllowNull()]
        [object]$SmartAppControl = $null
    )

    # A strict profile with no explicit catalog means "no additional
    # applications", not "no Windows runtime".  Compatibility mode retains
    # the historical $null value.  Do not use truthiness here: an empty but
    # explicitly supplied object must still be validated and preserved.
    $normalizedCatalog = $ApprovedApplicationCatalog
    if ($AppControlProfile -eq 'StrictApplicationAllowlist' -and $null -eq $ApprovedApplicationCatalog) {
        $normalizedCatalog = [pscustomobject][ordered]@{
            schemaVersion = 1
            applications = @()
        }
    }
    if ($null -ne $ApprovedApplicationCatalog) {
        $catalogProperties = @($ApprovedApplicationCatalog.PSObject.Properties.Name)
        $hasSchemaVersion = $catalogProperties -contains 'schemaVersion'
        $hasApplications = $catalogProperties -contains 'applications'
        if (-not $hasSchemaVersion -or -not $hasApplications -or
            [int]$ApprovedApplicationCatalog.schemaVersion -ne 1 -or
            $null -eq $ApprovedApplicationCatalog.applications -or
            -not ($ApprovedApplicationCatalog.applications -is [System.Collections.IEnumerable]) -or
            $ApprovedApplicationCatalog.applications -is [string]) {
            throw [System.ArgumentException]::new('ApprovedApplicationCatalog must contain schemaVersion=1 and an applications collection.')
        }
    }

    $config = [ordered]@{
        whitelistUrl = $WhitelistUrl
        version = $AgentVersion
        updateIntervalMinutes = 5
        watchdogIntervalMinutes = 1
        primaryDNS = $PrimaryDNS
        acrylicPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
        enableFirewall = $true
        enableBrowserPolicies = $true
        enableStaleFailsafe = $true
        staleWhitelistMaxAgeHours = 24
        enableIntegrityChecks = $true
        enableKnownDnsIpBlocking = $true
        enableDohIpBlocking = $true
        dnsEgressDefaultDeny = $true
        blockInboundDns = $true
        blockBridgedAdapters = $true
        bridgeFilterComponentIds = @()
        bridgeFilterAllowlist = @()
        enableNonAdminAppControl = $EnforceManagedBrowserBoundary
        nonAdminAppControlMode = 'Enforced'
        appControlProfile = $AppControlProfile
        activeAppControlProfile = 'none'
        approvedApplicationCatalog = $normalizedCatalog
        installState = 'installing'
        appControlCommitState = if ($EnforceManagedBrowserBoundary) { 'pending' } else { 'none' }
        enforceManagedBrowserBoundary = $EnforceManagedBrowserBoundary
        # These fields are intentionally written once.  The constructor does
        # not claim a committed security transition; the AppControl owner does.
        approvedStudentBrowsers = @($ApprovedStudentBrowsers)
        browserCleanupMode = $BrowserCleanupMode
        dohResolverIps = @(Get-DefaultDohResolverIps)
        vpnBlockRules = @(Get-DefaultVpnBlockRules)
        torBlockPorts = @(Get-DefaultTorBlockPorts)
        enableCheckpointRollback = $true
        maxCheckpoints = 3
        sseReconnectMin = 5
        sseReconnectMax = 60
        sseUpdateCooldown = 10
        installedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    if ($ApiBaseUrl) { $config.apiUrl = $ApiBaseUrl }
    if ($Classroom) { $config.classroom = $Classroom }
    if ($ClassroomId) { $config.classroomId = $ClassroomId }
    $config.captivePortalDomains = @($CaptivePortalDomains | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    if ($HealthApiSecret) { $config.healthApiSecret = $HealthApiSecret }
    if ($FirefoxExtensionId -and $FirefoxExtensionInstallUrl) {
        $config.firefoxExtensionId = $FirefoxExtensionId
        $config.firefoxExtensionInstallUrl = $FirefoxExtensionInstallUrl
    }
    if ($ChromeExtensionStoreUrl) { $config.chromeExtensionStoreUrl = $ChromeExtensionStoreUrl }
    if ($EdgeExtensionStoreUrl) { $config.edgeExtensionStoreUrl = $EdgeExtensionStoreUrl }

    # Phase 8e E1: persist the SAC decision with the config (the phase runs
    # before this constructor; the installer forwards its outcome here).
    if ($null -ne $SmartAppControl) {
        $config.smartAppControl = [ordered]@{
            previousState  = [string]$SmartAppControl.PreviousState
            action         = [string]$SmartAppControl.Action
            result         = [string]$SmartAppControl.Result
            rebootRequired = [bool]$SmartAppControl.RebootRequired
            decidedAtUtc   = [string]$SmartAppControl.DecidedAtUtc
        }
    }

    return $config
}

if (-not (Get-Command -Name 'Write-OpenPathAtomicJsonFile' -ErrorAction SilentlyContinue)) {
    $commonConfigPath = Join-Path $PSScriptRoot '..\internal\Common.Config.ps1'
    if (Test-Path -LiteralPath $commonConfigPath) {
        . $commonConfigPath
    }
}
if (-not (Get-Command -Name 'Get-DefaultDohResolverIps' -ErrorAction SilentlyContinue)) {
    $firewallCatalogPath = Join-Path $PSScriptRoot '..\internal\Firewall.Catalog.ps1'
    if (Test-Path -LiteralPath $firewallCatalogPath) {
        . $firewallCatalogPath
    }
}
