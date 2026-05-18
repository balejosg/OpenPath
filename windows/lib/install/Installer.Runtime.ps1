function Invoke-OpenPathInstallerFirstUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [bool]$ClassroomModeRequested,

        [Parameter(Mandatory = $true)]
        [string]$MachineRegistered
    )

    $shouldRunFirstUpdate = $true
    if ($ClassroomModeRequested -and $MachineRegistered -ne 'REGISTERED') {
        Write-InstallerWarning '  WARNING: Registration not completed; skipping first update'
        $shouldRunFirstUpdate = $false
    }

    if (-not $shouldRunFirstUpdate) {
        return
    }

    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$OpenPathRoot\scripts\Update-OpenPath.ps1"
        $updateExitCode = $LASTEXITCODE
        if ($updateExitCode -ne 0) {
            Write-InstallerWarning "  WARNING: First update failed with code $updateExitCode (will retry)"
            return
        }

        Write-InstallerVerbose '  First update completed'
    }
    catch {
        Write-InstallerWarning '  WARNING: First update failed (will retry)'
    }
}

function Restore-OpenPathInstallerConfigIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $configPath = Join-Path $OpenPathRoot 'data\config.json'
    if (Test-Path $configPath) {
        return
    }

    $configDir = Split-Path $configPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
    Write-InstallerWarning '  WARNING: Configuration restored after failed first update'
}

function Start-OpenPathInstallerRealtimeUpdates {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ClassroomModeRequested,

        [Parameter(Mandatory = $true)]
        [string]$MachineRegistered
    )

    if ($ClassroomModeRequested -and $MachineRegistered -ne 'REGISTERED') {
        Write-InstallerWarning '  WARNING: Registration not completed; skipping SSE listener'
        return $false
    }

    try {
        $config = Get-OpenPathConfig
        $readiness = Get-OpenPathBrowserRequestReadiness -Config $config
        if (-not $readiness.Ready) {
            Write-InstallerWarning '  WARNING: Request configuration incomplete; skipping SSE listener'
            return $false
        }
    }
    catch {
        Write-InstallerWarning "  WARNING: Could not validate request configuration: $_"
        return $false
    }

    if (Start-OpenPathTask -TaskType SSE) {
        Write-InstallerVerbose '  Listener SSE iniciado'
        return $true
    }

    Write-InstallerWarning '  WARNING: Could not start SSE listener automatically'
    return $false
}

function Initialize-OpenPathInstallerIntegrity {
    try {
        if (Save-OpenPathIntegrityBackup) {
            if (New-OpenPathIntegrityBaseline) {
                Write-InstallerVerbose '  Baseline de integridad generada'
            }
        }
    }
    catch {
        Write-InstallerWarning '  WARNING: Could not initialize integrity baseline'
    }
}

function Get-OpenPathInstallerChecks {
    $checks = @()

    if ((Get-Command -Name 'Test-AcrylicInstalled' -ErrorAction SilentlyContinue) -and (Test-AcrylicInstalled)) {
        $checks += @{ Name = 'Acrylic DNS'; Status = 'OK' }
    }
    else {
        $checks += @{ Name = 'Acrylic DNS'; Status = 'WARN' }
    }

    if ((Get-Command -Name 'Test-DNSResolution' -ErrorAction SilentlyContinue) -and (Test-DNSResolution)) {
        $checks += @{ Name = 'Resolucion DNS'; Status = 'OK' }
    }
    else {
        $checks += @{ Name = 'Resolucion DNS'; Status = 'FAIL' }
    }

    if ((Get-Command -Name 'Test-FirewallActive' -ErrorAction SilentlyContinue) -and (Test-FirewallActive)) {
        $checks += @{ Name = 'Firewall'; Status = 'OK' }
    }
    else {
        $checks += @{ Name = 'Firewall'; Status = 'WARN' }
    }

    $tasks = @()
    if (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue) {
        $tasks = @(Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue)
    }
    if ($tasks.Count -ge 2) {
        $checks += @{ Name = 'Tareas programadas'; Status = 'OK' }
    }
    else {
        $checks += @{ Name = 'Tareas programadas'; Status = 'WARN' }
    }

    return $checks
}

function Write-OpenPathInstallerSummary {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ClassroomModeRequested,

        [string]$Classroom = '',

        [string]$ClassroomId = '',

        [Parameter(Mandatory = $true)]
        [string]$MachineRegistered,

        [string]$WhitelistUrl = '',

        [Parameter(Mandatory = $true)]
        [string]$AgentVersion,

        [Parameter(Mandatory = $true)]
        [string]$PrimaryDNS
    )

    if ($VerbosePreference -ne 'Continue') {
        if (-not [Console]::IsOutputRedirected) {
            Write-Progress -Activity 'Installing OpenPath' -Completed
        }
        return
    }

    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host '  Verifying installation...' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan

    foreach ($check in @(Get-OpenPathInstallerChecks)) {
        $color = switch ($check.Status) {
            'OK' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
        }
        Write-Host "  $($check.Name): $($check.Status)" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Green
    Write-Host '  INSTALLATION COMPLETED' -ForegroundColor Green
    Write-Host '==========================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Configuration:'
    if ($ClassroomModeRequested) {
        if ($Classroom) { Write-Host "  - Classroom: $Classroom" }
        if ($ClassroomId) { Write-Host "  - Classroom ID: $ClassroomId" }
        Write-Host "  - Enrollment: $MachineRegistered"
        if ($ClassroomModeRequested -and $MachineRegistered -ne 'REGISTERED') {
            Write-Host '  - Domain requests: NOT CONFIGURED' -ForegroundColor Red
            Write-Host '    To repair it, run .\OpenPath.ps1 enroll with the classroom parameters.' -ForegroundColor Yellow
        }
    }
    Write-Host "  - Whitelist: $WhitelistUrl"
    Write-Host "  - Agent version: $AgentVersion"
    Write-Host "  - DNS upstream: $PrimaryDNS"
    Write-Host '  - Actualizacion: SSE real-time + cada 15 min (fallback)'
    Write-Host ''

    $dnsProbeDomain = '<allowed-domain>'
    try {
        $resolvedProbeDomain = @((Get-OpenPathDnsProbeDomains) | Select-Object -First 1)[0]
        if ($resolvedProbeDomain) {
            $dnsProbeDomain = $resolvedProbeDomain
        }
    }
    catch {
    }

    Write-Host 'Comandos utiles:'
    Write-Host '  .\OpenPath.ps1 status          # Estado del agente'
    Write-Host '  .\OpenPath.ps1 update          # Force update'
    Write-Host '  .\OpenPath.ps1 health          # Ejecutar watchdog'
    Write-Host '  .\OpenPath.ps1 self-update --check  # Comprobar actualizacion de agente'
    Write-Host "  nslookup $dnsProbeDomain 127.0.0.1  # Test DNS"
    Write-Host '  Get-ScheduledTask OpenPath-*  # Ver tareas'
    if ($ClassroomModeRequested) {
        Write-Host '  .\OpenPath.ps1 rotate-token -Secret <secret>  # Rotar token'
        Write-Host '  .\OpenPath.ps1 enroll -Classroom <classroom> -ApiUrl <url> -RegistrationToken <token>'
        Write-Host '  .\OpenPath.ps1 enroll -ApiUrl <url> -ClassroomId <id> -EnrollmentToken <token> -Unattended'
    }
    Write-Host ''

    Write-Progress -Activity 'Installing OpenPath' -Completed

    Write-Host 'Uninstall: .\Uninstall-OpenPath.ps1'
    Write-Host ''
}
