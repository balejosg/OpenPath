# OpenPath Firefox native host helpers for Windows

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\RequestSetup.State.psm1" -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'internal\NativeHost.ArtifactCatalog.ps1')
. (Join-Path $PSScriptRoot 'internal\NativeHost.Build.ps1')

function Get-OpenPathFirefoxNativeHostName {
    # returns the fixed native messaging host identifier registered with Firefox
    return 'whitelist_native_host'
}

function Get-OpenPathFirefoxNativeHostRoot {
    # returns the capability storage directory where native host artifacts and state are staged
    return (Get-OpenPathCapabilityStoragePath -Name FirefoxNativeHostRoot -OpenPathRoot $script:OpenPathRoot)
}

function Get-OpenPathFirefoxNativeHostManifestPath {
    # returns the full path to the native messaging manifest json file
    return "$(Get-OpenPathFirefoxNativeHostRoot)\whitelist_native_host.json"
}

function Get-OpenPathFirefoxNativeHostScriptPath {
    # returns the full path to the staged native host powershell script
    return "$(Get-OpenPathFirefoxNativeHostRoot)\OpenPath-NativeHost.ps1"
}

function Get-OpenPathFirefoxNativeHostWrapperPath {
    # returns the full path to the cmd wrapper that Firefox uses to launch the native host script
    return "$(Get-OpenPathFirefoxNativeHostRoot)\OpenPath-NativeHost.cmd"
}

function Get-OpenPathFirefoxNativeStatePath {
    # returns the path to the json file that stores the synced native host state for the browser extension
    return (Get-OpenPathCapabilityStoragePath -Name FirefoxNativeHostState -OpenPathRoot $script:OpenPathRoot)
}

function Get-OpenPathFirefoxNativeWhitelistMirrorPath {
    # returns the path to the whitelist mirror file staged for the native host to serve to the extension
    return (Get-OpenPathCapabilityStoragePath -Name FirefoxNativeHostWhitelistMirror -OpenPathRoot $script:OpenPathRoot)
}

function Get-OpenPathFirefoxNativeHostUpdateTaskName {
    # returns the scheduled task name the native host triggers to apply whitelist updates
    return 'OpenPath-Update'
}

function Get-OpenPathFirefoxNativeHostRegistryPaths {
    # returns both 64-bit and 32-bit HKLM registry paths for the Firefox native messaging host entry
    return @(
        'HKLM\SOFTWARE\Mozilla\NativeMessagingHosts\whitelist_native_host',
        'HKLM\SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host'
    )
}

function Get-OpenPathFirefoxNativeHostRequestSetupState {
    # resolves config if not supplied, then delegates to the shared request setup state projection
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    if (-not $Config) {
        try {
            $Config = Get-OpenPathConfig
        }
        catch {
            $Config = [PSCustomObject]@{}
        }
    }

    return (Get-OpenPathRequestSetupState -Config $Config)
}

function Test-OpenPathFirefoxNativeHostRequestSetupComplete {
    # returns true only when request setup is fully configured and the native host may be registered
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $requestSetupState = Get-OpenPathFirefoxNativeHostRequestSetupState -Config $Config
    return [bool]$requestSetupState.Ready
}

function Sync-OpenPathFirefoxNativeHostArtifacts {
    # copies native host support files from source roots into the capability storage directory; throws if any artifact is missing
    param(
        [string]$SourceRoot = "$script:OpenPathRoot\scripts"
    )

    $nativeRoot = Get-OpenPathFirefoxNativeHostRoot
    Ensure-OpenPathCapabilityStorageDirectory -Path $nativeRoot | Out-Null

    $artifactNames = @(Get-OpenPathNativeHostArtifactNames)
    $candidateRoots = @(Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $SourceRoot -NativeRoot $nativeRoot)
    $artifactResolution = Resolve-OpenPathNativeHostArtifactSources -ArtifactNames $artifactNames -CandidateRoots $candidateRoots
    $artifactSources = $artifactResolution.Sources
    $missingArtifacts = @($artifactResolution.Missing)

    $missingRequired = @($missingArtifacts | Where-Object { -not (Test-OpenPathNativeHostBuildInput -Name $_) })
    if ($missingRequired.Count -gt 0) {
        throw "Firefox native host artifacts not found in ${SourceRoot}: $($missingRequired -join ', ')"
    }
    if ($missingArtifacts.Count -gt 0) {
        # An updated machine may not have the C# source yet; the compiled host
        # build step reports SourceMissing and the existing host (compiled or
        # cmd fallback) stays registered.
        Write-OpenPathLog "Compiled native host build inputs not found in ${SourceRoot} ($($missingArtifacts -join ', ')); keeping the existing host." -Level WARN
    }

    foreach ($artifactName in $artifactNames) {
        if (-not $artifactSources.ContainsKey($artifactName)) { continue }
        $sourcePath = Join-Path $artifactSources[$artifactName] $artifactName
        $destinationPath = Join-Path $nativeRoot $artifactName
        if (-not [string]::Equals($sourcePath, $destinationPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item $sourcePath -Destination $destinationPath -Force
        }
    }

    return $true
}

function Sync-OpenPathFirefoxNativeHostState {
    # writes the native state json and optionally copies or clears the whitelist mirror; returns false and cleans up when request setup is incomplete
    param(
        [AllowNull()]
        [object]$Config = $null,

        [string]$WhitelistPath = "$script:OpenPathRoot\data\whitelist.txt",

        [switch]$ClearWhitelist
    )

    $nativeRoot = Get-OpenPathFirefoxNativeHostRoot
    Ensure-OpenPathCapabilityStorageDirectory -Path $nativeRoot | Out-Null

    if (-not $Config) {
        try {
            $Config = Get-OpenPathConfig
        }
        catch {
            $Config = [PSCustomObject]@{}
        }
    }

    $requestSetupState = Get-OpenPathFirefoxNativeHostRequestSetupState -Config $Config
    if (-not $requestSetupState.Ready) {
        $diagnosticMessage = if ($requestSetupState.DiagnosticMessage) {
            [string]$requestSetupState.DiagnosticMessage
        }
        else {
            'OpenPath request setup is incomplete.'
        }
        Write-OpenPathLog "Firefox native host request setup is incomplete; skipping native host state sync. $diagnosticMessage" -Level WARN
        Remove-Item (Get-OpenPathFirefoxNativeStatePath) -Force -ErrorAction SilentlyContinue
        Remove-Item (Get-OpenPathFirefoxNativeWhitelistMirrorPath) -Force -ErrorAction SilentlyContinue
        return $false
    }

    $machineName = if (
        $Config -and
        $Config.PSObject.Properties['machineName'] -and
        $Config.machineName
    ) {
        [string]$Config.machineName
    }
    else {
        [string]$env:COMPUTERNAME
    }

    $statePath = Get-OpenPathFirefoxNativeStatePath
    $nativeState = New-OpenPathRequestSetupNativeHostState `
        -Config $Config `
        -MachineName $machineName `
        -SyncedAt (Get-Date -Format 'o')
    $nativeState['captivePortalDomains'] = @(
        if ($Config.PSObject.Properties['captivePortalDomains']) {
            @($Config.captivePortalDomains | ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
        }
    )
    $runtimeDependencyOverlayPath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $script:OpenPathRoot
    $runtimeDependencyDomains = @()
    if (Test-Path $runtimeDependencyOverlayPath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $overlay = Get-Content $runtimeDependencyOverlayPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $runtimeDependencyDomains = @(
                @($overlay.entries) |
                    ForEach-Object { ([string]$_.dependencyHost).Trim().TrimEnd('.').ToLowerInvariant() } |
                    Where-Object { $_ } |
                    Select-Object -Unique
            )
        }
        catch {
            $runtimeDependencyDomains = @()
        }
    }
    $nativeState['runtimeDependencyDomains'] = @($runtimeDependencyDomains)
    $stateJson = $nativeState | ConvertTo-Json -Depth 8
    Write-OpenPathUtf8NoBomFile -Path $statePath -Value $stateJson

    $whitelistMirrorPath = Get-OpenPathFirefoxNativeWhitelistMirrorPath
    if ($ClearWhitelist) {
        Remove-Item $whitelistMirrorPath -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path $WhitelistPath) {
        Copy-Item $WhitelistPath -Destination $whitelistMirrorPath -Force
    }

    return $true
}

function Invoke-OpenPathFirefoxNativeHostCompiledEnsure {
    <#
    .SYNOPSIS
        Single entry point that keeps the compiled native host in sync with the
        installed C# source.
    .DESCRIPTION
        Phase 5.2 D2: installation/enrollment, agent self-update and the
        periodic Update task all call this. Never throws; the outcome carries
        Status (Built/BuildSkipped/Fallback), BackoffActive and the error so the
        caller can log it. A failed attempt backs off for an hour while the
        source is unchanged.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Config = $null)

    $nativeRoot = Get-OpenPathFirefoxNativeHostRoot
    try { Ensure-OpenPathCapabilityStorageDirectory -Path $nativeRoot | Out-Null } catch { }
    $result = $null
    try {
        $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $nativeRoot -OpenPathRoot $script:OpenPathRoot
    }
    catch {
        $result = [pscustomobject][ordered]@{
            Status = 'Failed'; Error = [string]$_; BackoffActive = $false; NextAttemptAt = ''
            BuiltNow = $false; ExecutablePath = ''; ManifestPath = ''; SourcePath = ''
            SourceSha256 = ''; ExecutableSha256 = ''; Health = $null
        }
    }
    if ($result.BackoffActive) {
        Write-OpenPathLog "Compiled native host refresh is in failure backoff until $($result.NextAttemptAt): $($result.Error)" -Level WARN
    }
    elseif ($result.Status -eq 'Fallback') {
        Write-OpenPathLog "Compiled native host refresh failed; keeping the previous host: $($result.Error)" -Level WARN
    }
    elseif ($result.Status -in @('Built', 'BuildSkipped')) {
        Write-OpenPathLog "Compiled native host ensured ($($result.Status), sha256=$($result.ExecutableSha256))."
    }
    return $result
}

function Get-OpenPathFirefoxNativeHostCompiledHealth {
    <#
    .SYNOPSIS
        Reports whether the registered native host is the healthy compiled
        executable, with a stable reason code for the watchdog.
    .DESCRIPTION
        Phase 5.2 D3: with the AppControl boundary active (enableNonAdminAppControl)
        and a registered host that is not the healthy compiled .exe, the
        Firefox path rules fail open. Reason codes:
          native_host_compile_failed, native_host_health_ping_failed,
          native_host_smart_app_control_blocked, native_host_compiled_unavailable.
        Read-only and best-effort; it never throws.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Config = $null,
        [string]$NativeRoot = '',
        [string]$OpenPathRoot = '',
        # Test seam: the Firefox messaging manifest to inspect.
        [string]$ManifestPath = ''
    )

    if (-not $NativeRoot) { $NativeRoot = Get-OpenPathFirefoxNativeHostRoot }
    if (-not $OpenPathRoot) { $OpenPathRoot = $script:OpenPathRoot }
    if (-not $ManifestPath) { $ManifestPath = Get-OpenPathFirefoxNativeHostManifestPath }
    $boundaryActive = $false
    if ($Config -and $Config.PSObject.Properties['enableNonAdminAppControl']) {
        $boundaryActive = [bool]$Config.enableNonAdminAppControl
    }
    $health = [ordered]@{
        BoundaryActive   = $boundaryActive
        RegisteredPath   = ''
        UsesCompiledHost = $false
        CompiledHealthy  = $false
        CompileStatus    = ''
        ReasonCode       = ''
    }
    try {
        $manifestPath = $ManifestPath
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $health.RegisteredPath = [string]$manifest.path
        }
    }
    catch { }
    $executableName = Get-OpenPathNativeHostExecutableName
    $executablePath = Join-Path $NativeRoot $executableName
    $health.UsesCompiledHost = [bool]($health.RegisteredPath -and ((Split-Path -Leaf $health.RegisteredPath) -ieq $executableName))
    $buildManifest = $null
    $diagnostics = $null
    try {
        $buildManifestPath = Join-Path $NativeRoot (Get-OpenPathNativeHostBuildManifestName)
        if (Test-Path -LiteralPath $buildManifestPath -PathType Leaf) {
            $buildManifest = Get-Content -LiteralPath $buildManifestPath -Raw | ConvertFrom-Json
        }
        $diagnosticsPath = Join-Path $NativeRoot (Get-OpenPathNativeHostBuildDiagnosticsName)
        if (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf) {
            $diagnostics = Get-Content -LiteralPath $diagnosticsPath -Raw | ConvertFrom-Json
        }
    }
    catch { }
    if ((Test-Path -LiteralPath $executablePath -PathType Leaf) -and $buildManifest -and ([string]$buildManifest.healthStatus -eq 'healthy')) {
        try {
            $healthy = ([string]$buildManifest.executableSha256 -eq (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant())
            if ($healthy) {
                $sourcePath = Get-OpenPathNativeHostInstalledSourcePath -OpenPathRoot $OpenPathRoot -NativeRoot $NativeRoot
                if ($sourcePath) {
                    $currentSourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ([string]$buildManifest.sourceSha256 -and ($currentSourceHash -ne [string]$buildManifest.sourceSha256)) {
                        $healthy = $false
                    }
                }
            }
            $health.CompiledHealthy = $healthy
        }
        catch { $health.CompiledHealthy = $false }
    }
    if (-not $boundaryActive) { return [pscustomobject]$health }
    if ($health.UsesCompiledHost -and $health.CompiledHealthy) { return [pscustomobject]$health }
    $status = if ($diagnostics) { [string]$diagnostics.status } else { '' }
    $health.CompileStatus = $status
    $sac = Get-OpenPathSmartAppControlState
    $health.ReasonCode = if ($status -in @('CompilationFailed', 'SourceMissing', 'Failed')) { 'native_host_compile_failed' }
        elseif ($status -eq 'HealthCheckFailed') { 'native_host_health_ping_failed' }
        elseif ($sac.State -eq 'enforcement' -and -not $health.CompiledHealthy) { 'native_host_smart_app_control_blocked' }
        else { 'native_host_compiled_unavailable' }
    return [pscustomobject]$health
}

function Register-OpenPathFirefoxNativeHost {
    # stages artifacts, writes the manifest, and sets both registry entries; skips registration entirely when request setup is incomplete
    param(
        [AllowNull()]
        [object]$Config = $null,

        [switch]$ClearWhitelist,

        # Preserve an already-registered native host when request setup is incomplete instead of
        # unregistering it. Used by the update path: a transiently incomplete config (for example
        # during token rotation) must never tear down a working browser integration.
        [switch]$PreserveExistingOnNotReady
    )

    $nativeRoot = Get-OpenPathFirefoxNativeHostRoot
    Ensure-OpenPathCapabilityStorageDirectory -Path $nativeRoot | Out-Null

    $requestSetupState = Get-OpenPathFirefoxNativeHostRequestSetupState -Config $Config
    if (-not $requestSetupState.Ready) {
        $diagnosticMessage = if ($requestSetupState.DiagnosticMessage) {
            [string]$requestSetupState.DiagnosticMessage
        }
        else {
            'OpenPath request setup is incomplete.'
        }
        if ($PreserveExistingOnNotReady) {
            Write-OpenPathLog "Firefox native host request setup is incomplete; preserving existing native host registration. $diagnosticMessage" -Level WARN
            return $false
        }
        Write-OpenPathLog "Firefox native host request setup is incomplete; skipping native host registration. $diagnosticMessage" -Level WARN
        Unregister-OpenPathFirefoxNativeHost | Out-Null
        return $false
    }

    Sync-OpenPathFirefoxNativeHostArtifacts | Out-Null

    # Phase 5: compile the C# host when the source changed and point the
    # manifest at it only after a framed ping health check. Any failure keeps
    # the cmd/PowerShell host registered (never a manifest pointing at a
    # missing or unhealthy executable).
    try {
        $buildResult = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $nativeRoot -OpenPathRoot $script:OpenPathRoot
        if ($buildResult.Status -eq 'Fallback') {
            Write-OpenPathLog "Compiled native host unavailable; keeping the PowerShell host fallback. $($buildResult.Error)" -Level WARN
        }
        elseif ($buildResult.Status -in @('Built', 'BuildSkipped')) {
            Write-OpenPathLog "Compiled native host ready ($($buildResult.Status), sha256=$($buildResult.ExecutableSha256))."
        }
    }
    catch {
        Write-OpenPathLog "Compiled native host build failed; keeping the PowerShell host fallback: $_" -Level WARN
    }

    $manifestPath = Get-OpenPathFirefoxNativeHostManifestPath
    $wrapperPath = Get-OpenPathFirefoxNativeHostWrapperPath
    $launchPath = Get-OpenPathNativeHostLaunchPath -NativeRoot $nativeRoot
    $manifestJson = [ordered]@{
        name = Get-OpenPathFirefoxNativeHostName
        description = 'OpenPath Windows Native Messaging Host'
        path = $launchPath
        type = 'stdio'
        allowed_extensions = @('openpath-block-monitor@openpath')
    } | ConvertTo-Json -Depth 8
    Write-OpenPathUtf8NoBomFile -Path $manifestPath -Value $manifestJson

    foreach ($registryPath in Get-OpenPathFirefoxNativeHostRegistryPaths) {
        & reg.exe ADD $registryPath /ve /d $manifestPath /f | Out-Null
    }

    Sync-OpenPathFirefoxNativeHostState -Config $Config -ClearWhitelist:$ClearWhitelist | Out-Null
    return $true
}

function Unregister-OpenPathFirefoxNativeHost {
    # removes registry entries, manifest, staged artifacts, the compiled host and
    # its build manifest; always returns true
    foreach ($registryPath in Get-OpenPathFirefoxNativeHostRegistryPaths) {
        Remove-OpenPathRegistryKeyIfPresent -RegistryPath $registryPath
    }
    try { Remove-OpenPathNativeHostExecutableArtifacts -NativeRoot (Get-OpenPathFirefoxNativeHostRoot) } catch { }

    $paths = @(
        (Get-OpenPathFirefoxNativeHostManifestPath),
        @((Get-OpenPathNativeHostArtifactNames) | ForEach-Object { Join-Path (Get-OpenPathFirefoxNativeHostRoot) $_ }),
        (Get-OpenPathFirefoxNativeStatePath),
        (Get-OpenPathFirefoxNativeWhitelistMirrorPath)
    )

    foreach ($path in $paths) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }

    return $true
}

Export-ModuleMember -Function @(
    'Get-OpenPathFirefoxNativeHostRoot',
    'Get-OpenPathFirefoxNativeHostManifestPath',
    'Get-OpenPathFirefoxNativeHostScriptPath',
    'Get-OpenPathFirefoxNativeHostWrapperPath',
    'Get-OpenPathFirefoxNativeStatePath',
    'Get-OpenPathFirefoxNativeWhitelistMirrorPath',
    'Get-OpenPathFirefoxNativeHostUpdateTaskName',
    'Get-OpenPathFirefoxNativeHostRegistryPaths',
    'Test-OpenPathFirefoxNativeHostRequestSetupComplete',
    'Sync-OpenPathFirefoxNativeHostArtifacts',
    'Sync-OpenPathFirefoxNativeHostState',
    'Invoke-OpenPathFirefoxNativeHostCompiledEnsure',
    'Get-OpenPathFirefoxNativeHostCompiledHealth',
    'Register-OpenPathFirefoxNativeHost',
    'Unregister-OpenPathFirefoxNativeHost'
)
