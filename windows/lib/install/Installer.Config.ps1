function Get-OpenPathInstallerAgentVersion {
    # returns the agent version string from OPENPATH_VERSION env var, the VERSION file
    # adjacent to scriptdir, or '0.0.0' as a fallback.
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

        [string[]]$ApprovedStudentBrowsers = @('Firefox'),

        [ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]
        [string]$BrowserCleanupMode = 'ReportOnly'
    )

    $config = @{
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
        installState = 'installing'
        appControlCommitState = if ($EnforceManagedBrowserBoundary) { 'pending' } else { 'none' }
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

function Write-OpenPathAtomicJsonFile {
    <#
    .SYNOPSIS
        Atomically writes JSON content to disk using a temp file and Win32 atomic replace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Data,

        [int]$Depth = 10
    )

    $parentDir = Split-Path -Path $Path -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $json = $Data | ConvertTo-Json -Depth $Depth
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $tempPath = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$Path.bak.$([guid]::NewGuid().ToString('N'))"

    try {
        [System.IO.File]::WriteAllText($tempPath, $json, $utf8WithoutBom)

        if (Test-Path -LiteralPath $Path) {
            try {
                [System.IO.File]::Replace($tempPath, $Path, $backupPath, $true)
            }
            catch {
                [System.IO.File]::Copy($tempPath, $Path, $true)
                [System.IO.File]::Delete($tempPath)
            }
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}
