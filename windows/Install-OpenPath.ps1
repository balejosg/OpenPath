# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the OpenPath DNS system for Windows
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WhitelistUrl = "",
    [switch]$SkipAcrylic,
    [switch]$SkipPreflight,
    [string]$Classroom = "",
    [string]$ApiUrl = "",
    [string]$RegistrationToken = "",
    [string]$EnrollmentToken = "",
    [string]$ClassroomId = "",
    [string[]]$CaptivePortalDomains = @(),
    [string]$MachineName = "",
    [string]$FirefoxExtensionId = "",
    [string]$FirefoxExtensionInstallUrl = "",
    [string]$ChromeExtensionStoreUrl = "",
    [string]$EdgeExtensionStoreUrl = "",
    [switch]$Unattended,
    [string]$HealthApiSecret = "",
    [switch]$EnforceManagedBrowserBoundary,
    [string[]]$ApprovedStudentBrowsers = @('Firefox'),
    [ValidateSet('ReportOnly', 'RemoveKnownInstallers', 'Disabled')]
    [string]$BrowserCleanupMode = 'ReportOnly',
    [string]$OfflineConfigPath = "",
    [string]$TimingOutputPath = "",
    [string]$FailureStatusPath = ""
)

$ErrorActionPreference = 'Stop'
$script:OpenPathInstallerQuietMode = $VerbosePreference -ne 'Continue'
if ($script:OpenPathInstallerQuietMode) {
    $WarningPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $env:OPENPATH_QUIET_INSTALL = '1'
}
$scriptDir = $PSScriptRoot
$apiBaseUrl = if ($ApiUrl) { $ApiUrl.TrimEnd('/') } else { '' }
$installerHelperRoot = Join-Path $scriptDir 'lib\install'
$script:OpenPathInstallerCurrentPhase = 'startup'

if (-not (Test-Path "$scriptDir\lib\*.psm1")) {
    $parentDir = Split-Path $scriptDir -Parent
    if (Test-Path "$parentDir\windows\lib\*.psm1") {
        $scriptDir = "$parentDir\windows"
        $installerHelperRoot = Join-Path $scriptDir 'lib\install'
    }
    else {
        Write-Host "ERROR: Modules not found in $scriptDir\lib\" -ForegroundColor Red
        Write-Host 'ERROR: Ensure lib\*.psm1 files are in the same directory as the installer' -ForegroundColor Red
        exit 1
    }
}

. (Join-Path $scriptDir 'lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

. (Join-Path $installerHelperRoot 'Installer.Progress.ps1')
. (Join-Path $installerHelperRoot 'Installer.Plan.ps1')
. (Join-Path $installerHelperRoot 'Installer.Config.ps1')
. (Join-Path $installerHelperRoot 'Installer.Runtime.ps1')
. (Join-Path $installerHelperRoot 'Installer.ChromiumGuidance.ps1')
. (Join-Path $installerHelperRoot 'Installer.Cleanup.ps1')
. (Join-Path $installerHelperRoot 'Installer.Dns.ps1')
. (Join-Path $installerHelperRoot 'Installer.Staging.ps1')
. (Join-Path $installerHelperRoot 'Installer.Enrollment.ps1')
. (Join-Path $installerHelperRoot 'Installer.Offline.ps1')

$offlineMode = [bool]$OfflineConfigPath
$offlineEnrollmentExpiresAt = ''
if ($offlineMode) {
    if (-not (Test-Path $OfflineConfigPath)) {
        Write-Host "ERROR: Offline configuration not found: $OfflineConfigPath" -ForegroundColor Red
        exit 10
    }

    try {
        $offlineConfig = Read-OpenPathOfflineConfig -Path $OfflineConfigPath
    }
    catch {
        Write-Host "ERROR: Invalid offline configuration: $($_.Exception.Message)" -ForegroundColor Red
        exit 10
    }

    $apiBaseUrl = $offlineConfig.ApiUrl
    $ClassroomId = $offlineConfig.ClassroomId
    $EnrollmentToken = $offlineConfig.EnrollmentToken
    $offlineEnrollmentExpiresAt = $offlineConfig.EnrollmentTokenExpiresAt.ToString('o')
    if (@($CaptivePortalDomains).Count -eq 0 -and @($offlineConfig.CaptivePortalDomains).Count -gt 0) {
        $CaptivePortalDomains = @($offlineConfig.CaptivePortalDomains)
    }
    if (@($offlineConfig.ApprovedStudentBrowsers).Count -gt 0) {
        $ApprovedStudentBrowsers = @($offlineConfig.ApprovedStudentBrowsers)
    }
}

$enrollmentContext = Resolve-OpenPathInstallerEnrollmentContext `
    -ApiBaseUrl $apiBaseUrl `
    -Classroom $Classroom `
    -ClassroomId $ClassroomId `
    -RegistrationToken $RegistrationToken `
    -EnrollmentToken $EnrollmentToken `
    -Unattended:$Unattended

$classroomModeRequested = [bool]$enrollmentContext.ClassroomModeRequested
$RegistrationToken = [string]$enrollmentContext.RegistrationToken
$EnrollmentToken = [string]$enrollmentContext.EnrollmentToken
$enforceManagedBrowserBoundary = [bool]$EnforceManagedBrowserBoundary
if ($classroomModeRequested -and $Unattended -and -not $PSBoundParameters.ContainsKey('EnforceManagedBrowserBoundary')) {
    $enforceManagedBrowserBoundary = $true
}
if ($offlineMode -and $offlineConfig.EnforceManagedBrowserBoundary -and -not $PSBoundParameters.ContainsKey('EnforceManagedBrowserBoundary')) {
    $enforceManagedBrowserBoundary = $true
}

if (-not $HealthApiSecret -and $env:OPENPATH_HEALTH_API_SECRET) {
    $HealthApiSecret = $env:OPENPATH_HEALTH_API_SECRET
}
if (-not $FirefoxExtensionId -and $env:OPENPATH_FIREFOX_EXTENSION_ID) {
    $FirefoxExtensionId = [string]$env:OPENPATH_FIREFOX_EXTENSION_ID
}
if (-not $FirefoxExtensionInstallUrl -and $env:OPENPATH_FIREFOX_EXTENSION_INSTALL_URL) {
    $FirefoxExtensionInstallUrl = [string]$env:OPENPATH_FIREFOX_EXTENSION_INSTALL_URL
}
if (-not $ChromeExtensionStoreUrl -and $env:OPENPATH_CHROME_EXTENSION_STORE_URL) {
    $ChromeExtensionStoreUrl = [string]$env:OPENPATH_CHROME_EXTENSION_STORE_URL
}
if (-not $EdgeExtensionStoreUrl -and $env:OPENPATH_EDGE_EXTENSION_STORE_URL) {
    $EdgeExtensionStoreUrl = [string]$env:OPENPATH_EDGE_EXTENSION_STORE_URL
}

if (($FirefoxExtensionId -and -not $FirefoxExtensionInstallUrl) -or ($FirefoxExtensionInstallUrl -and -not $FirefoxExtensionId)) {
    Write-InstallerError 'ERROR: -FirefoxExtensionId and -FirefoxExtensionInstallUrl must be provided together'
    throw '-FirefoxExtensionId and -FirefoxExtensionInstallUrl must be provided together'
}

function Write-OpenPathInstallerFailureStatus {
    param(
        [string]$Path = '',
        [string]$Phase = 'startup',
        [bool]$RollbackAttempted = $false,
        [object]$RollbackResult = $null
    )

    if (-not $Path) {
        return
    }

    $safePhase = if ($Phase -match '^[A-Za-z0-9-]{1,64}$') { $Phase } else { 'startup' }
    try {
        $parent = Split-Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $Path -Value $safePhase -NoNewline -Encoding ASCII -Force

        $jsonPath = "$Path.json"
        $statusObj = [pscustomobject]@{
            Phase             = $safePhase
            RollbackAttempted = $RollbackAttempted
            RollbackResult    = $RollbackResult
        }
        Write-OpenPathAtomicJsonFile -Path $jsonPath -Data $statusObj -Depth 10
    }
    catch {
        # Failure diagnostics must never replace the original installer error.
    }
}

function Get-OpenPathInstallerFailurePhase {
    $phase = $script:OpenPathInstallerCurrentPhase
    if ($phase -notin @('acrylic-install-local', 'enrollment-save-pending') -or -not $FailureStatusPath) {
        return $phase
    }

    try {
        $candidate = (Get-Content -LiteralPath $FailureStatusPath -Raw -ErrorAction Stop).Trim()
        if ($candidate -match '^[A-Za-z0-9-]{1,64}$') {
            return $candidate
        }
    }
    catch {
        # Failure diagnostics must never replace the original installer error.
    }

    return $phase
}

function Set-OpenPathOfflinePayloadFailurePhase {
    param(
        [AllowNull()]
        [object]$ErrorRecord
    )

    $message = if ($ErrorRecord -and $ErrorRecord.Exception) {
        [string]$ErrorRecord.Exception.Message
    }
    else {
        ''
    }

    $suffix = if ($message -match 'Offline payload verification failed \[((?:manifest|entry|missing|sha256|size|hash-io|size-io|io|failed)(?:-(?:repo|windows|runtime|extension|pinned|unknown)(?:-(?:command|parameter|null|access|not-found|other))?)?)\]') {
        $Matches[1]
    }
    else {
        'failed'
    }

    $script:OpenPathInstallerCurrentPhase = "offline-payload-verification-$suffix"
}

trap {
    $failurePhase = Get-OpenPathInstallerFailurePhase
    if ($script:OpenPathInstallerMutated) {
        Invoke-OpenPathInstallRollback -OpenPathRoot $OpenPathRoot
    }
    Write-OpenPathInstallerFailureStatus `
        -Path $FailureStatusPath `
        -Phase $failurePhase `
        -RollbackAttempted ([bool]$script:OpenPathInstallerMutated) `
        -RollbackResult $script:OpenPathInstallRollbackResult
    Write-InstallerError "ERROR: $($_.Exception.Message)"
    exit 1
}

$usesEnrollmentToken = [bool]$EnrollmentToken
$usesRegistrationToken = [bool]$RegistrationToken

$installerParameters = @{
    WhitelistUrl = $WhitelistUrl
    SkipAcrylic = [bool]$SkipAcrylic
    SkipPreflight = [bool]$SkipPreflight
    Classroom = $Classroom
    ApiUrl = $apiBaseUrl
    RegistrationToken = $RegistrationToken
    EnrollmentToken = $EnrollmentToken
    ClassroomId = $ClassroomId
    CaptivePortalDomains = @($CaptivePortalDomains)
    MachineName = $MachineName
    FirefoxExtensionId = $FirefoxExtensionId
    FirefoxExtensionInstallUrl = $FirefoxExtensionInstallUrl
    ChromeExtensionStoreUrl = $ChromeExtensionStoreUrl
    EdgeExtensionStoreUrl = $EdgeExtensionStoreUrl
    Unattended = [bool]$Unattended
    HealthApiSecret = $HealthApiSecret
    EnforceManagedBrowserBoundary = $enforceManagedBrowserBoundary
    ApprovedStudentBrowsers = @($ApprovedStudentBrowsers)
    BrowserCleanupMode = $BrowserCleanupMode
    TimingOutputPath = $TimingOutputPath
}
$installPlan = New-OpenPathInstallPlan -Parameters $installerParameters -OpenPathRoot $OpenPathRoot -ScriptDir $scriptDir
$script:OpenPathInstallPhaseResults = @()
$script:OpenPathInstallerMutated = $false
$script:OpenPathInstallerRollingBack = $false

function Get-OpenPathInstallPhaseFromPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $phase = @($installPlan.Phases | Where-Object { $_.Name -eq $Name })[0]
    if (-not $phase) {
        throw "Installer phase not found: $Name"
    }
    return $phase
}

function Invoke-OpenPathPlannedPhase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [scriptblock]$Action = $null
    )

    $script:OpenPathInstallerCurrentPhase = $Name
    if (($env:OPENPATH_TEST_ENVIRONMENT -eq '1' -or $env:PSTEST_ENVIRONMENT -eq '1') -and $env:OPENPATH_TEST_FAIL_PHASE -and ($env:OPENPATH_TEST_FAIL_PHASE -eq $Name)) {
        throw "Injected test failure at phase: $Name"
    }

    $phase = Get-OpenPathInstallPhaseFromPlan -Name $Name
    if ($Action) {
        $phase.Action = $Action
    }
    $result = Invoke-OpenPathInstallPhase -Phase $phase -Context $installPlan.Context
    $script:OpenPathInstallPhaseResults += $result

    if (($env:OPENPATH_TEST_ENVIRONMENT -eq '1' -or $env:PSTEST_ENVIRONMENT -eq '1') -and $env:OPENPATH_TEST_FAIL_AFTER_PHASE -and ($env:OPENPATH_TEST_FAIL_AFTER_PHASE -eq $Name)) {
        $script:OpenPathInstallerCurrentPhase = "post-$Name"
        throw "Injected test failure immediately after phase: $Name"
    }

    return $result
}

function Invoke-OpenPathPlannedWarningPhase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [scriptblock]$Action = $null
    )

    $result = Invoke-OpenPathPlannedPhase -Name $Name -Action $Action
    if (-not $result.Success) {
        $result.Status = 'warning'
    }
    return $result
}

function Assert-OpenPathInstallPhaseSucceeded {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    if ($Result.Success) {
        return
    }

    Write-InstallerError "ERROR: Installer phase failed: $($Result.Name)"
    if ($Result.Error -and $Result.Error.Message) {
        Write-InstallerError "  $($Result.Error.Message)"
    }
    if ($Result.RecoveryHint) {
        Write-InstallerError "  Recovery: $($Result.RecoveryHint)"
    }
    throw "Installer phase failed: $($Result.Name)"
}

function Get-OpenPathInstallerConfigValue {
    param(
        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($Config -is [hashtable] -and $Config.ContainsKey($PropertyName)) {
        return $Config[$PropertyName]
    }
    if ($Config -and $Config.PSObject.Properties[$PropertyName]) {
        return $Config.PSObject.Properties[$PropertyName].Value
    }

    return $DefaultValue
}

if ($VerbosePreference -eq 'Continue') {
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host '  OpenPath DNS para Windows - Instalador' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host ''
    if ($classroomModeRequested) {
        Write-Host 'Classroom mode: enabled'
        if ($Classroom) { Write-Host "Classroom: $Classroom" }
        if ($ClassroomId) { Write-Host "Classroom ID: $ClassroomId" }
        Write-Host "API URL: $apiBaseUrl"
        if ($usesEnrollmentToken) {
            Write-Host 'Enrollment auth: enrollment token'
        }
        elseif ($usesRegistrationToken) {
            Write-Host 'Enrollment auth: registration token'
        }
        if ($HealthApiSecret) { Write-Host 'Health API secret: configured' }
        if ($FirefoxExtensionId -and $FirefoxExtensionInstallUrl) {
            Write-Host 'Firefox signed extension: configured via install URL'
        }
        if ($ChromeExtensionStoreUrl -or $EdgeExtensionStoreUrl) {
            Write-Host 'Chromium store guidance: configured for unmanaged installs'
        }
    }
    elseif ($WhitelistUrl) {
        Write-Host "URL: $WhitelistUrl"
    }
    else {
        Write-Host 'Mode: Standalone (no whitelist URL configured)'
    }

    if (-not $classroomModeRequested -and $FirefoxExtensionId -and $FirefoxExtensionInstallUrl) {
        Write-Host 'Firefox signed extension: configured via install URL'
    }
    if (-not $classroomModeRequested -and ($ChromeExtensionStoreUrl -or $EdgeExtensionStoreUrl)) {
        Write-Host 'Chromium store guidance: configured for unmanaged installs'
    }
    Write-Host "Managed browser boundary: $enforceManagedBrowserBoundary"
    Write-Host "Browser cleanup mode: $BrowserCleanupMode"
    Write-Host ''
}

Write-InstallerNotice 'Browser cleanup is hygiene. Application allowlist is the enforcement boundary.'

if ($WhatIfPreference) {
    $PSCmdlet.ShouldProcess('OpenPath install root', 'Create install directories') | Out-Null
    $PSCmdlet.ShouldProcess('OpenPath runtime', 'Copy modules and scripts') | Out-Null
    $PSCmdlet.ShouldProcess("$OpenPathRoot\data\config.json", 'Write installer configuration') | Out-Null
    $PSCmdlet.ShouldProcess('Existing OpenPath installation', 'Remove before reinstall while keeping Acrylic and logs') | Out-Null
    if ($BrowserCleanupMode -ne 'Disabled') {
        $PSCmdlet.ShouldProcess('Browser cleanup inventory', "Report unmanaged browsers with $BrowserCleanupMode mode") | Out-Null
    }
    $PSCmdlet.ShouldProcess('All browsers', 'Configure browser policies') | Out-Null
    if ($enforceManagedBrowserBoundary) {
        $PSCmdlet.ShouldProcess('Windows AppLocker', 'Configure OpenPath non-admin app control in Enforced mode') | Out-Null
    }
    exit 0
}

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'existing-install-cleanup' -Action {
    $scriptDir = Copy-OpenPathInstallerSourceForReinstall `
        -ScriptDir $scriptDir `
        -OpenPathRoot $OpenPathRoot
    $installerHelperRoot = Join-Path $scriptDir 'lib\install'

    if (Test-OpenPathExistingInstallation -OpenPathRoot $OpenPathRoot) {
        $script:OpenPathInstallerMutated = $true
    }
    Invoke-OpenPathInstallerExistingInstallCleanup `
        -OpenPathRoot $OpenPathRoot `
        -KeepAcrylic `
        -KeepLogs | Out-Null
}
if (-not $phaseResult.Success) {
    Write-InstallerError "ERROR: Existing OpenPath cleanup failed: $($phaseResult.Error.Message)"
    throw 'Existing OpenPath cleanup failed'
}

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'preflight' -Action {
    if ($SkipPreflight) {
        Write-InstallerVerbose '[Preflight] Omitido por -SkipPreflight'
    }
    else {
        $validationScript = Join-Path $scriptDir 'scripts\Pre-Install-Validation.ps1'
        if (Test-Path $validationScript) {
            $validationOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validationScript 2>&1
            if ($LASTEXITCODE -ne 0) {
                $validationOutput |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { Write-InstallerError "$_" }
                Write-InstallerError 'ERROR: Pre-install validation failed'
                throw 'Pre-install validation failed'
            }
            if ($VerbosePreference -eq 'Continue') {
                $validationOutput | ForEach-Object { Write-Verbose "$_" }
            }
            Write-InstallerVerbose '[Preflight] Validacion completada'
        }
        else {
            Write-InstallerWarning '[Preflight] Omitido: paquete sin script de validacion previa'
        }
    }
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'directories' -Action {
    if ($PSCmdlet.ShouldProcess('OpenPath install root', 'Create install directories')) {
        Initialize-OpenPathInstallDirectories -OpenPathRoot $OpenPathRoot
        $script:OpenPathInstallerMutated = $true
    }
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'runtime' -Action {
    if ($PSCmdlet.ShouldProcess('OpenPath runtime', 'Copy modules and scripts')) {
        Copy-OpenPathInstallerRuntime `
            -OpenPathRoot $OpenPathRoot `
            -ScriptDir $scriptDir `
            -Unattended:$Unattended `
            -RequireCompleteStaging:$offlineMode `
            -ChromeExtensionStoreUrl $ChromeExtensionStoreUrl `
            -EdgeExtensionStoreUrl $EdgeExtensionStoreUrl `
            -FirefoxExtensionId $FirefoxExtensionId `
            -FirefoxExtensionInstallUrl $FirefoxExtensionInstallUrl
    }
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

if ($offlineMode) {
    $offlineManifestPath = Join-Path $scriptDir 'payload-manifest.json'
    $phaseResult = Invoke-OpenPathPlannedPhase -Name 'offline-payload-verification' -Action {
        Start-OpenPathInstallTimedStep -Name 'offline-payload-verification'
        try {
            Assert-OpenPathOfflinePayloadManifest `
                -ManifestPath $offlineManifestPath `
                -StagingRoot $scriptDir
        }
        catch {
            Set-OpenPathOfflinePayloadFailurePhase -ErrorRecord $_
            throw
        }
        Complete-OpenPathInstallTimedStep -Name 'offline-payload-verification'
    }
    Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult
}

Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\RequestSetup.State.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\Firewall.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\AppControl.psm1" -Force -Global -ErrorAction Stop
$script:OpenPathAppControlCommands = @{
    Set = Get-Command -Name 'AppControl\Set-OpenPathNonAdminAppControl' -ErrorAction Stop
    Test = Get-Command -Name 'AppControl\Test-OpenPathNonAdminAppControlActive' -ErrorAction Stop
    Remove = Get-Command -Name 'AppControl\Remove-OpenPathNonAdminAppControl' -ErrorAction Stop
    Sync = Get-Command -Name 'AppControl\Sync-OpenPathRestrictedGroup' -ErrorAction Stop
}

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'configuration' -Action {
    $primaryDNS = Get-InstallerPrimaryDNS
    $agentVersion = Get-OpenPathInstallerAgentVersion -ScriptDir $scriptDir
    $config = New-OpenPathInstallerConfig `
        -WhitelistUrl $WhitelistUrl `
        -AgentVersion $agentVersion `
        -PrimaryDNS $primaryDNS `
        -ApiBaseUrl $apiBaseUrl `
        -Classroom $Classroom `
        -ClassroomId $ClassroomId `
        -CaptivePortalDomains $CaptivePortalDomains `
        -HealthApiSecret $HealthApiSecret `
        -FirefoxExtensionId $FirefoxExtensionId `
        -FirefoxExtensionInstallUrl $FirefoxExtensionInstallUrl `
        -ChromeExtensionStoreUrl $ChromeExtensionStoreUrl `
        -EdgeExtensionStoreUrl $EdgeExtensionStoreUrl `
        -EnforceManagedBrowserBoundary:$enforceManagedBrowserBoundary `
        -ApprovedStudentBrowsers $ApprovedStudentBrowsers `
        -BrowserCleanupMode $BrowserCleanupMode
    if ($PSCmdlet.ShouldProcess("$OpenPathRoot\data\config.json", 'Write installer configuration')) {
        Write-OpenPathAtomicJsonFile -Path "$OpenPathRoot\data\config.json" -Data $config -Depth 10
    }
    Set-Variable -Name primaryDNS -Scope Script -Value $primaryDNS
    Set-Variable -Name agentVersion -Scope Script -Value $agentVersion
    Set-Variable -Name config -Scope Script -Value $config
    Write-InstallerVerbose "  DNS upstream: $primaryDNS"
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

Import-Module "$OpenPathRoot\lib\DNS.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\Services.psm1" -Force -Global
$deferLocalDnsUntilRemoteBootstrap = $classroomModeRequested -or [bool]$WhitelistUrl

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'acrylic' -Action {
    Start-OpenPathInstallTimedStep -Name 'acrylic'
    if (-not $SkipAcrylic) {
        $script:OpenPathInstallerCurrentPhase = 'acrylic-detect-existing'
        if (Test-AcrylicInstalled) {
            Write-InstallerVerbose '  Acrylic ya instalado'
            $script:OpenPathInstallerCurrentPhase = 'acrylic-ensure-service'
            if ($WhatIfPreference -or (Ensure-AcrylicService -Start)) {
                Write-InstallerVerbose '  Servicio Acrylic listo'
            }
            else {
                throw 'Acrylic is installed but the AcrylicDNSProxySvc service could not be registered or started'
            }
        }
        elseif ($offlineMode) {
            $script:OpenPathInstallerCurrentPhase = 'acrylic-resolve-manifest'
            $acrylicEntry = Get-OpenPathOfflineManifestEntry `
                -ManifestPath $offlineManifestPath `
                -RelativePath 'payloads/acrylic/Acrylic-Portable.zip'
            $script:OpenPathInstallerCurrentPhase = 'acrylic-install-local'
            $installed = Install-AcrylicDNSFromLocalSource `
                -AcrylicZipPath (Join-Path $scriptDir $acrylicEntry.path) `
                -ExpectedSha256 $acrylicEntry.sha256 `
                -FailureStatusPath $FailureStatusPath `
                -WhatIf:$WhatIfPreference
            $script:OpenPathInstallerCurrentPhase = 'acrylic-ensure-service'
            if ($installed -and ($WhatIfPreference -or ((Test-AcrylicInstalled) -and (Ensure-AcrylicService -Start)))) {
                Write-InstallerVerbose '  Acrylic instalado desde el paquete offline'
            }
            else {
                throw 'Local Acrylic installation failed or did not produce a running AcrylicDNSProxySvc service'
            }
        }
        else {
            $installed = Install-AcrylicDNS -WhatIf:$WhatIfPreference
            if ($installed -and ($WhatIfPreference -or ((Test-AcrylicInstalled) -and (Ensure-AcrylicService -Start)))) {
                Write-InstallerVerbose '  Acrylic instalado'
            }
            else {
                throw 'Acrylic installation failed or did not produce a running AcrylicDNSProxySvc service'
            }
        }
    }
    else {
        Write-InstallerWarning '  Acrylic installation skipped'
    }
    Complete-OpenPathInstallTimedStep -Name 'acrylic'
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'acrylic-configuration' -Action {
    Start-OpenPathInstallTimedStep -Name 'acrylic-configuration'
    if ($SkipAcrylic) {
        Write-InstallerWarning '  Acrylic configuration skipped by -SkipAcrylic'
    }
    else {
        $acrylicConfigurationApplied = Set-AcrylicConfiguration -CaptivePortalDomains $CaptivePortalDomains -WhatIf:$WhatIfPreference
        if (-not ($WhatIfPreference -or $acrylicConfigurationApplied)) {
            throw 'Acrylic configuration failed'
        }
    }
    Complete-OpenPathInstallTimedStep -Name 'acrylic-configuration'
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'local-dns' -Action {
    Start-OpenPathInstallTimedStep -Name 'local-dns'
    if ($offlineMode) {
        Write-InstallerVerbose '  DNS local se activara tras completar el enrolamiento diferido'
    }
    elseif ($deferLocalDnsUntilRemoteBootstrap) {
        Write-InstallerVerbose '  DNS local se activara tras descargar y aplicar la primera whitelist'
        Ensure-InstallerRemoteBootstrapDns -ApiBaseUrl $apiBaseUrl -PrimaryDNS $primaryDNS -WhatIf:$WhatIfPreference | Out-Null
        Write-InstallerVerbose '  DNS remoto verificado para enrollment'
    }
    else {
        Set-LocalDNS -WhatIf:$WhatIfPreference
        Write-InstallerVerbose '  DNS configurado a 127.0.0.1'
    }
    Complete-OpenPathInstallTimedStep -Name 'local-dns'
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$machineRegistered = 'NOT_REQUESTED'
$enrollmentError = ''
if ($classroomModeRequested) {
    $phaseResult = Invoke-OpenPathPlannedPhase -Name 'enrollment' -Action {
        Start-OpenPathInstallTimedStep -Name 'enrollment'
        $script:OpenPathInstallerCurrentPhase = 'enrollment-attempt'
        $enrollmentResult = Invoke-OpenPathInstallerEnrollment `
            -OpenPathRoot $OpenPathRoot `
            -ApiBaseUrl $apiBaseUrl `
            -Classroom $Classroom `
            -ClassroomId $ClassroomId `
            -EnrollmentToken $EnrollmentToken `
            -RegistrationToken $RegistrationToken `
            -MachineName $MachineName `
            -Unattended:$Unattended

        $machineRegistered = [string]$enrollmentResult.MachineRegistered
        if ($enrollmentResult.PSObject.Properties['EnrollmentError'] -and $enrollmentResult.EnrollmentError) {
            $enrollmentError = [string]$enrollmentResult.EnrollmentError
        }
        if ($enrollmentResult.WhitelistUrl) {
            $WhitelistUrl = [string]$enrollmentResult.WhitelistUrl
        }
        Set-Variable -Name machineRegistered -Scope Script -Value $machineRegistered
        Set-Variable -Name enrollmentError -Scope Script -Value $enrollmentError
        Set-Variable -Name WhitelistUrl -Scope Script -Value $WhitelistUrl
        Complete-OpenPathInstallTimedStep -Name 'enrollment' -Status $machineRegistered

        if ($classroomModeRequested -and $Unattended -and $machineRegistered -ne 'REGISTERED') {
            if ($offlineMode) {
                $script:OpenPathInstallerCurrentPhase = 'enrollment-save-pending'
                Save-OpenPathPendingEnrollmentState `
                    -OpenPathRoot $OpenPathRoot `
                    -ApiUrl $apiBaseUrl `
                    -ClassroomId $ClassroomId `
                    -EnrollmentToken $EnrollmentToken `
                    -ExpiresAt $offlineEnrollmentExpiresAt `
                    -FailureStatusPath $FailureStatusPath
                $script:OpenPathInstallerCurrentPhase = 'enrollment-pending-saved'
                $machineRegistered = 'PENDING'
                Set-Variable -Name machineRegistered -Scope Script -Value $machineRegistered
                Write-InstallerWarning '  Enrollment deferred; pending state saved and retry scheduled on next startup with connectivity.'
            }
            else {
                Write-InstallerError 'ERROR: Classroom enrollment did not complete; domain requests will not be configured.'
                if ($enrollmentError) {
                    Write-InstallerError "  $enrollmentError"
                }
                throw 'Classroom enrollment did not complete'
            }
        }
    }
    Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult
}

$nativeHostRegistered = $false
$nativeHostRequestSetup = $null
$phaseResult = Invoke-OpenPathPlannedPhase -Name 'native-host' -Action {
    try {
        Import-Module "$OpenPathRoot\lib\RequestSetup.State.psm1" -Force -Global
        $nativeHostConfig = Get-OpenPathConfig
        $nativeHostRequestSetup = Get-OpenPathRequestSetupState -Config $nativeHostConfig
        if ($PSCmdlet.ShouldProcess('Firefox native messaging host', 'Register OpenPath native host after enrollment')) {
            $nativeHostRegistered = Register-OpenPathFirefoxNativeHost -Config $nativeHostConfig -ClearWhitelist
        }
        Set-Variable -Name nativeHostRegistered -Scope Script -Value $nativeHostRegistered
        Set-Variable -Name nativeHostRequestSetup -Scope Script -Value $nativeHostRequestSetup
        if ($classroomModeRequested -and (-not $nativeHostRegistered -or -not $nativeHostRequestSetup.Ready)) {
            $requestSetupMessage = if ($nativeHostRequestSetup -and $nativeHostRequestSetup.DiagnosticMessage) {
                [string]$nativeHostRequestSetup.DiagnosticMessage
            }
            else {
                'OpenPath request setup is incomplete.'
            }
            Write-InstallerWarning "  WARNING: Firefox native host registration incomplete after enrollment. $requestSetupMessage"
        }
    }
    catch {
        Write-InstallerWarning "  WARNING: Could not register Firefox native host after enrollment: $_"
    }
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$pendingEnrollment = ($machineRegistered -eq 'PENDING')
if ($classroomModeRequested -and $Unattended -and -not $pendingEnrollment -and (-not $nativeHostRegistered -or -not $nativeHostRequestSetup -or -not $nativeHostRequestSetup.Ready)) {
    Write-InstallerError 'ERROR: Firefox native host registration incomplete; domain requests will not be configured.'
    throw 'Firefox native host registration incomplete'
}

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'first-update' -Action {
    Start-OpenPathInstallTimedStep -Name 'first-update'
    Invoke-OpenPathInstallerFirstUpdate `
        -OpenPathRoot $OpenPathRoot `
        -ClassroomModeRequested:$classroomModeRequested `
        -MachineRegistered $machineRegistered
    Complete-OpenPathInstallTimedStep -Name 'first-update'
    Restore-OpenPathInstallerConfigIfMissing `
        -OpenPathRoot $OpenPathRoot `
        -Config $config
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'scheduled-tasks' -Action {
    Start-OpenPathInstallTimedStep -Name 'scheduled-tasks'
    Register-OpenPathTask -UpdateIntervalMinutes 5 -WatchdogIntervalMinutes 1 -WhatIf:$WhatIfPreference
    Write-InstallerVerbose '  Tareas registradas'
    Complete-OpenPathInstallTimedStep -Name 'scheduled-tasks'
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'app-control' -Action {
    try {
        Start-OpenPathInstallTimedStep -Name 'app-control'
        $enableNonAdminAppControl = [bool](Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'enableNonAdminAppControl' -DefaultValue $true)
        $nonAdminAppControlMode = [string](Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'nonAdminAppControlMode' -DefaultValue 'Enforced')
        $approvedStudentBrowsers = @($config.approvedStudentBrowsers)
        if ($enableNonAdminAppControl) {
            $groupSynced = [bool](& $script:OpenPathAppControlCommands.Sync -CreateIfMissing $true)
            if (-not $groupSynced) {
                throw 'Sync-OpenPathRestrictedGroup failed to create or synchronize the OpenPath-Restricted local group.'
            }
            $appControlApplied = [bool](& $script:OpenPathAppControlCommands.Set -OpenPathRoot $OpenPathRoot -Mode $nonAdminAppControlMode -ApprovedBrowsers $approvedStudentBrowsers -WhatIf:$WhatIfPreference)
            if (-not $appControlApplied) {
                throw 'Set-OpenPathNonAdminAppControl did not apply the required AppControl boundary.'
            }
            if (-not (& $script:OpenPathAppControlCommands.Test `
                        -Mode $nonAdminAppControlMode `
                        -ApprovedBrowsers $approvedStudentBrowsers)) {
                throw 'OpenPath AppControl boundary did not validate after installation.'
            }

            # Security commit point: boundary is verified active, atomically commit state
            if ($PSCmdlet.ShouldProcess("$OpenPathRoot\data\config.json", 'Commit AppControl security boundary')) {
                $configPath = Join-Path $OpenPathRoot 'data\config.json'
                if (Test-Path -LiteralPath $configPath) {
                    $committedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
                    $committedConfig.appControlCommitState = 'committed'
                    Write-OpenPathAtomicJsonFile -Path $configPath -Data $committedConfig -Depth 10
                }
            }
            $config.appControlCommitState = 'committed'
            Write-InstallerVerbose '  AppControl security boundary committed'
        }
        else {
            if (& $script:OpenPathAppControlCommands.Test) {
                & $script:OpenPathAppControlCommands.Remove -Confirm:$false -WhatIf:$WhatIfPreference | Out-Null
                Write-InstallerVerbose '  Stale OpenPath AppLocker rules removed'
            }
            Write-InstallerVerbose '  Managed browser boundary disabled; AppLocker boundary not applied'
        }
        Complete-OpenPathInstallTimedStep -Name 'app-control'
    }
    catch {
        Complete-OpenPathInstallTimedStep -Name 'app-control' -Status 'failed' -ErrorMessage ([string]$_)
        Write-InstallerError "ERROR: Could not configure required AppLocker boundary for non-admin users: $_"
        throw
    }
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'firefox-managed-extension-ready' -Action {
    try {
        Start-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready'
        $firefoxReadyConfig = Get-OpenPathConfig
        if ($classroomModeRequested -and -not $pendingEnrollment) {
            $firefoxReady = Test-OpenPathFirefoxManagedExtensionReady -Config $firefoxReadyConfig
            if (-not $firefoxReady.Ready) {
                Complete-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready' -Status 'failed' -ErrorMessage ([string]$firefoxReady.FailureCode)
                Write-InstallerError 'ERROR: Firefox managed extension policy is not ready after installation.'
                Write-InstallerError "  Failure: $($firefoxReady.FailureCode)"
                Write-InstallerError "  $($firefoxReady.Message)"
                throw "Firefox managed extension policy is not ready after installation: $($firefoxReady.FailureCode)"
            }
        }
        Complete-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready'
    }
    catch {
        Complete-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready' -Status 'failed' -ErrorMessage ([string]$_)
        if ($classroomModeRequested -and -not $pendingEnrollment) {
            Write-InstallerError 'ERROR: Firefox managed extension policy is not ready after installation.'
            Write-InstallerError "  $_"
            throw 'Firefox managed extension readiness validation failed'
        }

        Write-InstallerWarning "  WARNING: Could not validate Firefox managed extension readiness: $_"
    }
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'realtime-updates' -Action {
    Start-OpenPathInstallTimedStep -Name 'realtime-updates'
    Start-OpenPathInstallerRealtimeUpdates `
        -ClassroomModeRequested:$classroomModeRequested `
        -MachineRegistered $machineRegistered | Out-Null
    Complete-OpenPathInstallTimedStep -Name 'realtime-updates'
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedWarningPhase -Name 'browser-inventory' -Action {
    if ($BrowserCleanupMode -eq 'Disabled') {
        Write-InstallerVerbose '  Browser cleanup reporting disabled'
    }
    elseif ($PSCmdlet.ShouldProcess('Browser cleanup inventory', "Report unmanaged browsers with $BrowserCleanupMode mode")) {
        Invoke-OpenPathInstallTimedStep -Name 'browser-inventory' -ScriptBlock {
            try {
                $browserInventoryMode = if ($BrowserCleanupMode -eq 'RemoveKnownInstallers') { 'RemoveKnownInstallers' } else { 'ReportOnly' }
                $browserInventory = Get-OpenPathBrowserInventory -Mode $browserInventoryMode
                $unmanagedCount = @($browserInventory.UnmanagedBrowsers).Count + @($browserInventory.PortableBrowserRisks).Count
                $removalCandidateCount = @($browserInventory.RemovalCandidates).Count
                Write-InstallerVerbose "  Browser cleanup report: $unmanagedCount unmanaged finding(s), $removalCandidateCount removable known installer candidate(s)"
                if ($BrowserCleanupMode -eq 'RemoveKnownInstallers' -and $removalCandidateCount -gt 0) {
                    Write-InstallerWarning '  WARNING: RemoveKnownInstallers reports candidates only; automatic browser uninstall is not enabled in this release.'
                }
            }
            catch {
                Write-InstallerWarning "  WARNING: Could not generate browser report: $_"
            }
        }
    }
}

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'integrity' -Action {
    Initialize-OpenPathInstallerIntegrity
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'timing' -Action {
    Save-OpenPathInstallTiming -Path $TimingOutputPath
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

$phaseResult = Invoke-OpenPathPlannedPhase -Name 'summary' -Action {
    if ($PSCmdlet.ShouldProcess("$OpenPathRoot\data\config.json", 'Finalize install state')) {
        $configPath = Join-Path $OpenPathRoot 'data\config.json'
        if (Test-Path -LiteralPath $configPath) {
            $finalConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $finalConfig.installState = 'complete'
            Write-OpenPathAtomicJsonFile -Path $configPath -Data $finalConfig -Depth 10
        }
    }
    $config.installState = 'complete'
    Write-OpenPathInstallerSummary `
        -ClassroomModeRequested:$classroomModeRequested `
        -Classroom $Classroom `
        -ClassroomId $ClassroomId `
        -MachineRegistered $machineRegistered `
        -WhitelistUrl $WhitelistUrl `
        -AgentVersion $agentVersion `
        -PrimaryDNS $primaryDNS
}
Assert-OpenPathInstallPhaseSucceeded -Result $phaseResult

if ($pendingEnrollment) {
    Write-InstallerNotice 'OpenPath is installed. Enrollment is pending; it will retry automatically on the next startup with connectivity.'
    exit 60
}

exit 0
