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
        Write-Host '  ADVERTENCIA: Registro no completado; se omite primera actualizacion' -ForegroundColor Yellow
        $shouldRunFirstUpdate = $false
    }

    if (-not $shouldRunFirstUpdate) {
        return
    }

    try {
        & "$OpenPathRoot\scripts\Update-OpenPath.ps1"
        Write-InstallerVerbose '  Primera actualizacion completada'
    }
    catch {
        Write-Host '  ADVERTENCIA: Primera actualizacion fallida (se reintentara)' -ForegroundColor Yellow
    }
}

function Start-OpenPathInstallerRealtimeUpdates {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ClassroomModeRequested,

        [Parameter(Mandatory = $true)]
        [string]$MachineRegistered
    )

    if ($ClassroomModeRequested -and $MachineRegistered -ne 'REGISTERED') {
        Write-Host '  ADVERTENCIA: Registro no completado; se omite listener SSE' -ForegroundColor Yellow
        return $false
    }

    try {
        $config = Get-OpenPathConfig
        $readiness = Get-OpenPathBrowserRequestReadiness -Config $config
        if (-not $readiness.Ready) {
            Write-Host '  ADVERTENCIA: Configuracion de solicitudes incompleta; se omite listener SSE' -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "  ADVERTENCIA: No se pudo validar la configuracion de solicitudes: $_" -ForegroundColor Yellow
        return $false
    }

    if (Start-OpenPathTask -TaskType SSE) {
        Write-InstallerVerbose '  Listener SSE iniciado'
        return $true
    }

    Write-Host '  ADVERTENCIA: No se pudo iniciar el listener SSE automaticamente' -ForegroundColor Yellow
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
        Write-Host '  ADVERTENCIA: No se pudo inicializar baseline de integridad' -ForegroundColor Yellow
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

    if ($VerbosePreference -eq 'Continue') {
        Write-Host ''
        Write-Host '==========================================' -ForegroundColor Cyan
        Write-Host '  Verificando instalacion...' -ForegroundColor Cyan
        Write-Host '==========================================' -ForegroundColor Cyan
    }

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
    Write-Host '  INSTALACION COMPLETADA' -ForegroundColor Green
    Write-Host '==========================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Configuracion:'
    if ($ClassroomModeRequested) {
        if ($Classroom) { Write-Host "  - Classroom: $Classroom" }
        if ($ClassroomId) { Write-Host "  - Classroom ID: $ClassroomId" }
        Write-Host "  - Enrollment: $MachineRegistered"
        if ($ClassroomModeRequested -and $MachineRegistered -ne 'REGISTERED') {
            Write-Host '  - Solicitudes de dominio: NO CONFIGURADAS' -ForegroundColor Red
            Write-Host '    Para repararlo, ejecuta .\OpenPath.ps1 enroll con los parametros del aula.' -ForegroundColor Yellow
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

    if ($VerbosePreference -eq 'Continue') {
        Write-Host 'Comandos utiles:'
        Write-Host '  .\OpenPath.ps1 status          # Estado del agente'
        Write-Host '  .\OpenPath.ps1 update          # Forzar actualizacion'
        Write-Host '  .\OpenPath.ps1 health          # Ejecutar watchdog'
        Write-Host '  .\OpenPath.ps1 self-update --check  # Comprobar actualizacion de agente'
        Write-Host "  nslookup $dnsProbeDomain 127.0.0.1  # Probar DNS"
        Write-Host '  Get-ScheduledTask OpenPath-*  # Ver tareas'
        if ($ClassroomModeRequested) {
            Write-Host '  .\OpenPath.ps1 rotate-token -Secret <secret>  # Rotar token'
            Write-Host '  .\OpenPath.ps1 enroll -Classroom <aula> -ApiUrl <url> -RegistrationToken <token>'
            Write-Host '  .\OpenPath.ps1 enroll -ApiUrl <url> -ClassroomId <id> -EnrollmentToken <token> -Unattended'
        }
        Write-Host ''
    }
    else {
        Write-Host 'Comando de gestion: .\OpenPath.ps1 status'
        Write-Host ''
    }

    if ($VerbosePreference -ne 'Continue' -and -not [Console]::IsOutputRedirected) {
        Write-Progress -Activity 'Installing OpenPath' -Completed
    }

    Write-Host 'Desinstalar: .\Uninstall-OpenPath.ps1'
    Write-Host ''
}
