function Get-OpenPathInstallerAgentVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptDir
    )

    if ($env:OPENPATH_VERSION) {
        return [string]$env:OPENPATH_VERSION
    }

    $versionFilePath = Join-Path (Split-Path $ScriptDir -Parent) 'VERSION'
    if (Test-Path $versionFilePath) {
        try {
            $versionFromFile = (Get-Content $versionFilePath -Raw).Trim()
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

        [string[]]$ApprovedStudentBrowsers = @('Firefox'),

        [ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]
        [string]$BrowserCleanupMode = 'ReportOnly'
    )

    $config = @{
        whitelistUrl = $WhitelistUrl
        version = $AgentVersion
        updateIntervalMinutes = 15
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
        enableNonAdminAppControl = $EnforceManagedBrowserBoundary
        nonAdminAppControlMode = 'Enforced'
        enforceManagedBrowserBoundary = $EnforceManagedBrowserBoundary
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

    return $config
}
