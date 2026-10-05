# Produce the native-host parity fixture files with the REAL agent producers.
#
# Phase 5.3 A4: the parity harness used to write every parsed file with
# [Text.UTF8Encoding]::new($false), which hid the production encoding. This
# script runs under Windows PowerShell 5.1 (the shell every scheduled task of
# the agent uses) and calls the producer functions themselves:
#
#   overlay            windows/lib/internal/RuntimeDependency.Overlay.ps1
#                      Write-OpenPathRuntimeDependencyOverlay +
#                      Set-OpenPathRuntimeDependencyOverlayApplied
#   worker state       windows/lib/internal/RuntimeDependency.Worker.ps1
#                      Write-OpenPathRuntimeDependencyWorkerState
#   queue request      windows/lib/internal/RuntimeDependency.Queue.ps1
#                      Write-OpenPathRuntimeDependencyQueueRequest
#   captive marker     windows/lib/CaptivePortal.psm1
#                      Set-OpenPathCaptivePortalMarker
#   captive observ.    windows/lib/CaptivePortal.psm1
#                      Update-OpenPathCaptivePortalObservation
#   whitelist mirror   Copy-Item of data\whitelist.txt (the mirror step of
#                      Sync-OpenPathFirefoxNativeHostState)
#   config.json        [IO.File]::WriteAllText with UTF8Encoding(false), the
#                      exact write of Write-OpenPathAtomicJsonFile (used by
#                      Set-OpenPathConfig)
#   native-state.json  [IO.File]::WriteAllText with UTF8Encoding(false), the
#                      exact write of Write-OpenPathUtf8NoBomFile (used by
#                      Sync-OpenPathFirefoxNativeHostState)
#
# Producer side effects beyond the file write (the capability-storage ACL
# grant) are attempted for real and their failure is recorded, never hidden:
# the file already exists when the ACL step throws.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Root,
    [switch]$AddBomVariants
)

$ErrorActionPreference = 'Stop'
$data = Join-Path $Root 'data'
$native = Join-Path $Root 'browser-extension\firefox\native'
New-Item -ItemType Directory -Path $data, $native -Force | Out-Null

$internal = Join-Path $RepoRoot 'windows\lib\internal'
. (Join-Path $internal 'CapabilityStorage.ps1')
. (Join-Path $internal 'RuntimeDependency.Protocol.ps1')
. (Join-Path $internal 'RuntimeDependency.Policy.ps1')
. (Join-Path $internal 'RuntimeDependency.Queue.ps1')
. (Join-Path $internal 'RuntimeDependency.Overlay.ps1')
. (Join-Path $internal 'RuntimeDependency.Worker.ps1')

# Route every capability-storage path at the fixture root before any producer
# runs (the producers never take a path override for the queue/overlay).
$env:OPENPATH_WINDOWS_ROOT = $Root
$env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = Join-Path $data 'runtime-dependency-overlay.json'
$env:OPENPATH_RUNTIME_DEPENDENCY_WORKER_STATE_PATH = Join-Path $data 'runtime-dependency-worker-state.json'
$env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH = Join-Path $data 'runtime-dependency-queue'
New-Item -ItemType Directory -Path $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH -Force | Out-Null

$meta = [ordered]@{ schemaVersion = 1; producers = [ordered]@{} }
function Add-Meta {
    param([string]$Name, [string]$Producer, [string]$Path, [string]$Error = '')
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $bytes = if ($exists) { [IO.File]::ReadAllBytes($Path) } else { [byte[]]@() }
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $meta.producers[$Name] = [ordered]@{ producer = $Producer; path = $Path; exists = $exists; bom = $bom; error = $Error }
}

function Invoke-Producer {
    param([string]$Name, [string]$Producer, [string]$Path, [scriptblock]$Action)
    $errorText = ''
    try { & $Action | Out-Null }
    catch { $errorText = ($_.Exception.Message -replace '\s+', ' ').Trim() }
    Add-Meta -Name $Name -Producer $Producer -Path $Path -Error $errorText
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 1) Whitelist source + mirror. The update task writes data\whitelist.txt with
# Set-Content -Encoding UTF8 (UTF-8 with BOM under PowerShell 5.1); the native
# host sync copies it byte-for-byte.
$whitelistLines = @(
    '## WHITELIST',
    'anchor1.parity.invalid',
    'depwhitelisted.parity.invalid',
    '## BLOCKED-SUBDOMAINS',
    'blocked9.parity.invalid',
    '## BLOCKED-PATHS',
    'anchor1.parity.invalid/blocked',
    '## ALLOWED-PATHS',
    'anchor1.parity.invalid/allowed'
) -join "`r`n"
$whitelistPath = Join-Path $data 'whitelist.txt'
$whitelistLines | Set-Content -Path $whitelistPath -Encoding UTF8 -Force
$mirrorPath = Join-Path $native 'whitelist.txt'
Copy-Item -LiteralPath $whitelistPath -Destination $mirrorPath -Force
Invoke-Producer -Name 'whitelist-source' -Producer 'Set-Content -Encoding UTF8 (Update.Script.Apply.ps1)' -Path $whitelistPath -Action { $whitelistLines | Set-Content -Path $whitelistPath -Encoding UTF8 -Force }
Invoke-Producer -Name 'whitelist-mirror' -Producer 'Copy-Item (Sync-OpenPathFirefoxNativeHostState)' -Path $mirrorPath -Action { Copy-Item -LiteralPath $whitelistPath -Destination $mirrorPath -Force }

# 2) config.json (writer-equivalent: Write-OpenPathAtomicJsonFile bytes).
$config = [ordered]@{
    apiUrl                                       = 'https://api.parity.invalid'
    requestApiUrl                                = 'https://api.parity.invalid'
    whitelistUrl                                 = 'https://api.parity.invalid/w/tok12345678/whitelist.txt'
    captivePortalDomains                         = @()
    runtimeDependencyPersistentTransportDisabled = $false
    extensionDiagnosticsDisabled                 = $false
}
$configPath = Join-Path $data 'config.json'
Invoke-Producer -Name 'config' -Producer 'Write-OpenPathAtomicJsonFile (Set-OpenPathConfig)' -Path $configPath -Action {
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10), $utf8NoBom)
}

# 3) native-state.json (writer-equivalent: Write-OpenPathUtf8NoBomFile bytes).
$nativeState = [ordered]@{
    machineName              = 'parity-machine'
    whitelistUrl             = 'https://api.parity.invalid/w/tok12345678/whitelist.txt'
    apiUrl                   = 'https://api.parity.invalid'
    requestApiUrl            = 'https://api.parity.invalid'
    classroom                = 'parity-class'
    classroomId              = 'parity-class-id'
    version                  = '9.9.9'
    syncedAt                 = '2026-01-01T00:00:00.0000000Z'
    captivePortalDomains     = @('portal.parity.invalid')
    runtimeDependencyDomains = @('exactdep.parity.invalid')
}
$nativeStatePath = Join-Path $native 'native-state.json'
Invoke-Producer -Name 'native-state' -Producer 'Write-OpenPathUtf8NoBomFile (Sync-OpenPathFirefoxNativeHostState)' -Path $nativeStatePath -Action {
    [IO.File]::WriteAllText($nativeStatePath, ($nativeState | ConvertTo-Json -Depth 6), $utf8NoBom)
}

# 4) Runtime dependency overlay by the real producer: a ready entry
# (written, then marked applied) and a second entry written later that is
# still pending (its generation is newer than appliedGeneration).
$overlayPath = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
$readyEntry = [pscustomobject]@{
    dependencyHost = 'overlaydep.parity.invalid'
    anchorHost     = 'anchor1.parity.invalid'
    requestTypes   = @('script')
    firstSeen      = '2026-01-01T00:00:00.0000000Z'
    lastSeen       = '2026-01-01T00:00:00.0000000Z'
    expiresAt      = '2099-01-01T00:00:00.0000000Z'
    source         = 'firefox-webrequest-local'
}
$pendingEntry = [pscustomobject]@{
    dependencyHost = 'pendingdep.parity.invalid'
    anchorHost     = 'anchor1.parity.invalid'
    requestTypes   = @('script')
    firstSeen      = '2026-01-01T00:00:00.0000000Z'
    lastSeen       = '2026-01-01T00:00:00.0000000Z'
    expiresAt      = '2099-01-01T00:00:00.0000000Z'
    source         = 'firefox-webrequest-local'
}
Invoke-Producer -Name 'overlay-ready' -Producer 'Write-OpenPathRuntimeDependencyOverlay + Set-OpenPathRuntimeDependencyOverlayApplied' -Path $overlayPath -Action {
    Write-OpenPathRuntimeDependencyOverlay -Entries @($readyEntry) -Path $overlayPath
    Set-OpenPathRuntimeDependencyOverlayApplied -Path $overlayPath | Out-Null
    Write-OpenPathRuntimeDependencyOverlay -Entries @($readyEntry, $pendingEntry) -Path $overlayPath
}

# 5) Worker state by the real writer: fresh heartbeat (within 10 s).
$workerStatePath = $env:OPENPATH_RUNTIME_DEPENDENCY_WORKER_STATE_PATH
Invoke-Producer -Name 'worker-state' -Producer 'Write-OpenPathRuntimeDependencyWorkerState' -Path $workerStatePath -Action {
    $state = @{ status = 'idle'; queueDepth = 0; generation = 2 }
    Write-OpenPathRuntimeDependencyWorkerState -State $state -StatePath $workerStatePath -SkipReadAccess | Out-Null
}

# 6) Queue request by the real writer (Set-Content -Encoding UTF8 -> BOM).
$queuePath = Join-Path $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH 'parity-fixed-request.json'
Invoke-Producer -Name 'queue-request' -Producer 'Write-OpenPathRuntimeDependencyQueueRequest' -Path $queuePath -Action {
    # The producer generates a random id; run it and rename to the fixed name
    # the test uses so a re-run is deterministic.
    $produced = Write-OpenPathRuntimeDependencyQueueRequest -AnchorHost 'anchor1.parity.invalid' -DependencyHost 'queueddep.parity.invalid' -RequestType 'script'
    if ($produced -and ($produced -ne $queuePath)) { Move-Item -LiteralPath $produced -Destination $queuePath -Force }
}

# 7) Captive portal marker + observation by the real producers (module import
# with OPENPATH_ROOT at the fixture root).
$markerPath = Join-Path $data 'captive-portal-active.json'
$observationPath = Join-Path $data 'captive-portal-observation.json'
Invoke-Producer -Name 'captive-marker' -Producer 'Set-OpenPathCaptivePortalMarker' -Path $markerPath -Action {
    Import-Module (Join-Path $Root 'lib\CaptivePortal.psm1') -Force -ErrorAction Stop
    Set-OpenPathCaptivePortalMarker -State 'Portal' -AllowedHosts @('portal.parity.invalid') -Mode 'limited' -LimitedModeReady $true -ConfiguredCaptivePortalDomains @('portal.parity.invalid') -ConfiguredCaptivePortalDomainsApplied $true | Out-Null
}
Invoke-Producer -Name 'captive-observation' -Producer 'Update-OpenPathCaptivePortalObservation' -Path $observationPath -Action {
    Import-Module (Join-Path $Root 'lib\CaptivePortal.psm1') -Force -ErrorAction Stop
    Update-OpenPathCaptivePortalObservation -DetectedState 'Portal' -EnterPortalCount 1 | Out-Null
}

# 8) Explicit BOM variants of the files whose real producer writes without a
# BOM: the reader must stay tolerant if a future producer (or an older agent)
# emits the preamble bytes.
if ($AddBomVariants) {
    $bomTargets = @(
        @{ Name = 'config-bom'; Producer = 'BOM variant of config.json'; Path = $configPath },
        @{ Name = 'native-state-bom'; Producer = 'BOM variant of native-state.json'; Path = $nativeStatePath }
    )
    foreach ($target in $bomTargets) {
        Invoke-Producer -Name $target.Name -Producer $target.Producer -Path $target.Path -Action {
            $bytes = [IO.File]::ReadAllBytes($target.Path)
            $withBom = [byte[]]::new($bytes.Length + 3)
            $withBom[0] = 0xEF; $withBom[1] = 0xBB; $withBom[2] = 0xBF
            [Array]::Copy($bytes, 0, $withBom, 3, $bytes.Length)
            [IO.File]::WriteAllBytes($target.Path, $withBom)
        }
    }
}

$metaPath = Join-Path $Root 'parity-producers.json'
[IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 8), $utf8NoBom)
Write-Output ($meta | ConvertTo-Json -Depth 8 -Compress)
