# OpenPath Firefox native host helpers for Windows

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\RequestSetup.State.psm1" -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'internal\NativeHost.ArtifactCatalog.ps1')

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

    if ($missingArtifacts.Count -gt 0) {
        throw "Firefox native host artifacts not found in ${SourceRoot}: $($missingArtifacts -join ', ')"
    }

    foreach ($artifactName in $artifactNames) {
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

function Register-OpenPathFirefoxNativeHost {
    # stages artifacts, writes the manifest, and sets both registry entries; skips registration entirely when request setup is incomplete
    param(
        [AllowNull()]
        [object]$Config = $null,

        [switch]$ClearWhitelist
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
        Write-OpenPathLog "Firefox native host request setup is incomplete; skipping native host registration. $diagnosticMessage" -Level WARN
        Unregister-OpenPathFirefoxNativeHost | Out-Null
        return $false
    }

    Sync-OpenPathFirefoxNativeHostArtifacts | Out-Null

    $manifestPath = Get-OpenPathFirefoxNativeHostManifestPath
    $wrapperPath = Get-OpenPathFirefoxNativeHostWrapperPath
    $manifestJson = [ordered]@{
        name = Get-OpenPathFirefoxNativeHostName
        description = 'OpenPath Windows Native Messaging Host'
        path = $wrapperPath
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
    # removes registry entries, manifest, staged artifacts, state file, and whitelist mirror; always returns true
    foreach ($registryPath in Get-OpenPathFirefoxNativeHostRegistryPaths) {
        Remove-OpenPathRegistryKeyIfPresent -RegistryPath $registryPath
    }

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
    'Register-OpenPathFirefoxNativeHost',
    'Unregister-OpenPathFirefoxNativeHost'
)
