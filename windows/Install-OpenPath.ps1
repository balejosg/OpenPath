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
    [string]$TimingOutputPath = ""
)

$ErrorActionPreference = 'Stop'
$OpenPathRoot = 'C:\OpenPath'
$scriptDir = $PSScriptRoot
$apiBaseUrl = if ($ApiUrl) { $ApiUrl.TrimEnd('/') } else { '' }
$installerHelperRoot = Join-Path $scriptDir 'lib\install'

if (-not (Test-Path "$scriptDir\lib\*.psm1")) {
    $parentDir = Split-Path $scriptDir -Parent
    if (Test-Path "$parentDir\windows\lib\*.psm1") {
        $scriptDir = "$parentDir\windows"
        $installerHelperRoot = Join-Path $scriptDir 'lib\install'
    }
    else {
        Write-Host "ERROR: Modules not found in $scriptDir\lib\" -ForegroundColor Red
        Write-Host '  Ensure lib\*.psm1 files are in the same directory as the installer' -ForegroundColor Yellow
        exit 1
    }
}

. (Join-Path $installerHelperRoot 'Installer.Progress.ps1')
. (Join-Path $installerHelperRoot 'Installer.Config.ps1')
. (Join-Path $installerHelperRoot 'Installer.Runtime.ps1')
. (Join-Path $installerHelperRoot 'Installer.ChromiumGuidance.ps1')
. (Join-Path $installerHelperRoot 'Installer.Dns.ps1')
. (Join-Path $installerHelperRoot 'Installer.Staging.ps1')
. (Join-Path $installerHelperRoot 'Installer.Enrollment.ps1')

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
    exit 1
}

$usesEnrollmentToken = [bool]$EnrollmentToken
$usesRegistrationToken = [bool]$RegistrationToken

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
else {
    Write-InstallerNotice 'Installing OpenPath DNS for Windows...'
}

Write-InstallerNotice 'Browser cleanup is hygiene. Application allowlist is the enforcement boundary.'

if ($WhatIfPreference) {
    $PSCmdlet.ShouldProcess('OpenPath install root', 'Create install directories') | Out-Null
    $PSCmdlet.ShouldProcess('OpenPath runtime', 'Copy modules and scripts') | Out-Null
    $PSCmdlet.ShouldProcess("$OpenPathRoot\data\config.json", 'Write installer configuration') | Out-Null
    if ($BrowserCleanupMode -ne 'Disabled') {
        $PSCmdlet.ShouldProcess('Browser cleanup inventory', "Report unmanaged browsers with $BrowserCleanupMode mode") | Out-Null
    }
    $PSCmdlet.ShouldProcess('All browsers', 'Configure browser policies') | Out-Null
    if ($enforceManagedBrowserBoundary) {
        $PSCmdlet.ShouldProcess('Windows AppLocker', 'Configure OpenPath non-admin app control in Enforced mode') | Out-Null
    }
    exit 0
}

if ($SkipPreflight) {
    Write-InstallerVerbose '[Preflight] Omitido por -SkipPreflight'
}
else {
    $validationScript = Join-Path $scriptDir 'scripts\Pre-Install-Validation.ps1'
    if (Test-Path $validationScript) {
        Show-InstallerProgress -Step 0 -Total 7 -Status 'Ejecutando validacion previa'
        $validationOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validationScript 2>&1
        if ($LASTEXITCODE -ne 0) {
            $validationOutput | ForEach-Object { Write-InstallerError "$_" }
            Write-InstallerError 'ERROR: Pre-install validation failed'
            exit 1
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

Show-InstallerProgress -Step 1 -Total 7 -Status 'Creando estructura de directorios'
if ($PSCmdlet.ShouldProcess('OpenPath install root', 'Create install directories')) {
    Initialize-OpenPathInstallDirectories -OpenPathRoot $OpenPathRoot
}

Show-InstallerProgress -Step 2 -Total 7 -Status 'Copiando modulos y scripts'
if ($PSCmdlet.ShouldProcess('OpenPath runtime', 'Copy modules and scripts')) {
    Copy-OpenPathInstallerRuntime `
        -OpenPathRoot $OpenPathRoot `
        -ScriptDir $scriptDir `
        -Unattended:$Unattended `
        -ChromeExtensionStoreUrl $ChromeExtensionStoreUrl `
        -EdgeExtensionStoreUrl $EdgeExtensionStoreUrl `
        -FirefoxExtensionId $FirefoxExtensionId `
        -FirefoxExtensionInstallUrl $FirefoxExtensionInstallUrl
}

Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\RequestSetup.State.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\Firewall.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\AppControl.psm1" -Force -Global

Show-InstallerProgress -Step 3 -Total 7 -Status 'Creando configuracion'
$primaryDNS = Get-InstallerPrimaryDNS
$agentVersion = Get-OpenPathInstallerAgentVersion -ScriptDir $scriptDir
$config = New-OpenPathInstallerConfig `
    -WhitelistUrl $WhitelistUrl `
    -AgentVersion $agentVersion `
    -PrimaryDNS $primaryDNS `
    -ApiBaseUrl $apiBaseUrl `
    -Classroom $Classroom `
    -ClassroomId $ClassroomId `
    -HealthApiSecret $HealthApiSecret `
    -FirefoxExtensionId $FirefoxExtensionId `
    -FirefoxExtensionInstallUrl $FirefoxExtensionInstallUrl `
    -ChromeExtensionStoreUrl $ChromeExtensionStoreUrl `
    -EdgeExtensionStoreUrl $EdgeExtensionStoreUrl `
    -EnforceManagedBrowserBoundary:$enforceManagedBrowserBoundary `
    -ApprovedStudentBrowsers $ApprovedStudentBrowsers `
    -BrowserCleanupMode $BrowserCleanupMode
if ($PSCmdlet.ShouldProcess("$OpenPathRoot\data\config.json", 'Write installer configuration')) {
    $config | ConvertTo-Json -Depth 10 | Set-Content "$OpenPathRoot\data\config.json" -Encoding UTF8
}
Write-InstallerVerbose "  DNS upstream: $primaryDNS"

Import-Module "$OpenPathRoot\lib\DNS.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -Global
Import-Module "$OpenPathRoot\lib\Services.psm1" -Force -Global
$deferLocalDnsUntilRemoteBootstrap = $classroomModeRequested -or [bool]$WhitelistUrl

Show-InstallerProgress -Step 4 -Total 7 -Status 'Instalando Acrylic DNS Proxy'
Start-OpenPathInstallTimedStep -Name 'acrylic'
if (-not $SkipAcrylic) {
    if (Test-AcrylicInstalled) {
        Write-InstallerVerbose '  Acrylic ya instalado'
        if ((-not $WhatIfPreference) -and (Ensure-AcrylicService -Start)) {
            Write-InstallerVerbose '  Servicio Acrylic listo'
        }
        else {
            Write-InstallerWarning '  ADVERTENCIA: No se pudo registrar o iniciar el servicio Acrylic automaticamente'
        }
    }
    else {
        $installed = Install-AcrylicDNS -WhatIf:$WhatIfPreference
        if ($installed) {
            Write-InstallerVerbose '  Acrylic instalado'
        }
        else {
            Write-InstallerWarning '  ADVERTENCIA: No se pudo instalar Acrylic automaticamente'
            Write-InstallerWarning '  Descarga manual: https://mayakron.altervista.org/support/acrylic/Home.htm'
        }
    }
}
else {
    Write-InstallerWarning '  Instalacion de Acrylic omitida'
}
Complete-OpenPathInstallTimedStep -Name 'acrylic'

Start-OpenPathInstallTimedStep -Name 'acrylic-configuration'
Set-AcrylicConfiguration -WhatIf:$WhatIfPreference
Complete-OpenPathInstallTimedStep -Name 'acrylic-configuration'

Show-InstallerProgress -Step 5 -Total 7 -Status 'Configurando DNS local'
Start-OpenPathInstallTimedStep -Name 'local-dns'
if ($deferLocalDnsUntilRemoteBootstrap) {
    Write-InstallerVerbose '  DNS local se activara tras descargar y aplicar la primera whitelist'
}
else {
    Set-LocalDNS -WhatIf:$WhatIfPreference
    Write-InstallerVerbose '  DNS configurado a 127.0.0.1'
}
Complete-OpenPathInstallTimedStep -Name 'local-dns'

Show-InstallerProgress -Step 6 -Total 7 -Status 'Registrando tareas programadas'
Start-OpenPathInstallTimedStep -Name 'scheduled-tasks'
Register-OpenPathTask -UpdateIntervalMinutes 15 -WatchdogIntervalMinutes 1 -WhatIf:$WhatIfPreference
Write-InstallerVerbose '  Tareas registradas'
Complete-OpenPathInstallTimedStep -Name 'scheduled-tasks'

$machineRegistered = 'NOT_REQUESTED'
$enrollmentError = ''
if ($classroomModeRequested) {
    Start-OpenPathInstallTimedStep -Name 'enrollment'
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
    Complete-OpenPathInstallTimedStep -Name 'enrollment' -Status $machineRegistered

    if ($classroomModeRequested -and $Unattended -and $machineRegistered -ne 'REGISTERED') {
        Write-InstallerError 'ERROR: Classroom enrollment did not complete; domain requests will not be configured.'
        if ($enrollmentError) {
            Write-InstallerError "  $enrollmentError"
        }
        exit 1
    }
}

$nativeHostRegistered = $false
$nativeHostRequestSetup = $null
try {
    Import-Module "$OpenPathRoot\lib\RequestSetup.State.psm1" -Force -Global
    $nativeHostConfig = Get-OpenPathConfig
    $nativeHostRequestSetup = Get-OpenPathRequestSetupState -Config $nativeHostConfig
    if ($PSCmdlet.ShouldProcess('Firefox native messaging host', 'Register OpenPath native host after enrollment')) {
        $nativeHostRegistered = Register-OpenPathFirefoxNativeHost -Config $nativeHostConfig -ClearWhitelist
    }
    if ($classroomModeRequested -and (-not $nativeHostRegistered -or -not $nativeHostRequestSetup.Ready)) {
        $requestSetupMessage = if ($nativeHostRequestSetup -and $nativeHostRequestSetup.DiagnosticMessage) {
            [string]$nativeHostRequestSetup.DiagnosticMessage
        }
        else {
            'OpenPath request setup is incomplete.'
        }
        Write-InstallerWarning "  ADVERTENCIA: Registro del host nativo de Firefox incompleto tras enrollment. $requestSetupMessage"
    }
}
catch {
    Write-InstallerWarning "  ADVERTENCIA: No se pudo registrar el host nativo de Firefox tras enrollment: $_"
}

if ($classroomModeRequested -and $Unattended -and (-not $nativeHostRegistered -or -not $nativeHostRequestSetup -or -not $nativeHostRequestSetup.Ready)) {
    Write-InstallerError 'ERROR: Firefox native host registration incomplete; domain requests will not be configured.'
    exit 1
}

Show-InstallerProgress -Step 7 -Total 7 -Status 'Ejecutando primera actualizacion'
Start-OpenPathInstallTimedStep -Name 'first-update'
Invoke-OpenPathInstallerFirstUpdate `
    -OpenPathRoot $OpenPathRoot `
    -ClassroomModeRequested:$classroomModeRequested `
    -MachineRegistered $machineRegistered
Complete-OpenPathInstallTimedStep -Name 'first-update'

try {
    Start-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready'
    $firefoxReadyConfig = Get-OpenPathConfig
    if ($classroomModeRequested -and $Unattended) {
        $firefoxReady = Test-OpenPathFirefoxManagedExtensionReady -Config $firefoxReadyConfig
        if (-not $firefoxReady.Ready) {
            Complete-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready' -Status 'failed' -ErrorMessage ([string]$firefoxReady.FailureCode)
            Write-InstallerError 'ERROR: Firefox managed extension is not active after installation.'
            Write-InstallerError "  Failure: $($firefoxReady.FailureCode)"
            Write-InstallerError "  $($firefoxReady.Message)"
            exit 1
        }
    }
    elseif ($classroomModeRequested) {
        $firefoxReady = Test-OpenPathFirefoxManagedExtensionReady -Config $firefoxReadyConfig
        if (-not $firefoxReady.Ready) {
            Write-InstallerWarning "  ADVERTENCIA: Firefox managed extension readiness incomplete: $($firefoxReady.Message)"
        }
    }
    Complete-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready'
}
catch {
    Complete-OpenPathInstallTimedStep -Name 'firefox-managed-extension-ready' -Status 'failed' -ErrorMessage ([string]$_)
    if ($classroomModeRequested -and $Unattended) {
        Write-InstallerError 'ERROR: Firefox managed extension is not active after installation.'
        Write-InstallerError "  $_"
        exit 1
    }

    Write-InstallerWarning "  ADVERTENCIA: No se pudo validar Firefox managed extension readiness: $_"
}

Start-OpenPathInstallTimedStep -Name 'realtime-updates'
Start-OpenPathInstallerRealtimeUpdates `
    -ClassroomModeRequested:$classroomModeRequested `
    -MachineRegistered $machineRegistered | Out-Null
Complete-OpenPathInstallTimedStep -Name 'realtime-updates'

try {
    Start-OpenPathInstallTimedStep -Name 'app-control'
    $enableNonAdminAppControl = [bool](Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'enableNonAdminAppControl' -DefaultValue $true)
    $nonAdminAppControlMode = [string](Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'nonAdminAppControlMode' -DefaultValue 'Enforced')
    $approvedStudentBrowsers = @($config.approvedStudentBrowsers)
    if ($enableNonAdminAppControl) {
        Set-OpenPathNonAdminAppControl -OpenPathRoot $OpenPathRoot -Mode $nonAdminAppControlMode -ApprovedBrowsers $approvedStudentBrowsers -WhatIf:$WhatIfPreference | Out-Null
    }
    else {
        Write-InstallerVerbose '  Managed browser boundary disabled; AppLocker boundary not applied'
    }
    Complete-OpenPathInstallTimedStep -Name 'app-control'
}
catch {
    Complete-OpenPathInstallTimedStep -Name 'app-control' -Status 'warning' -ErrorMessage ([string]$_)
    Write-InstallerWarning "  ADVERTENCIA: No se pudo configurar AppLocker para usuarios no administradores: $_"
}

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
                Write-InstallerWarning '  ADVERTENCIA: RemoveKnownInstallers reports candidates only; automatic browser uninstall is not enabled in this release.'
            }
        }
        catch {
            Write-InstallerWarning "  ADVERTENCIA: No se pudo generar el reporte de navegadores: $_"
        }
    }
}

Initialize-OpenPathInstallerIntegrity
Save-OpenPathInstallTiming -Path $TimingOutputPath

Write-OpenPathInstallerSummary `
    -ClassroomModeRequested:$classroomModeRequested `
    -Classroom $Classroom `
    -ClassroomId $ClassroomId `
    -MachineRegistered $machineRegistered `
    -WhitelistUrl $WhitelistUrl `
    -AgentVersion $agentVersion `
    -PrimaryDNS $primaryDNS

exit 0
