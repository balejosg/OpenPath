if (-not (Get-Command -Name 'Get-OpenPathCapabilityStoragePath' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $capabilityStoragePath = Join-Path $PSScriptRoot 'CapabilityStorage.ps1'
    if (Test-Path $capabilityStoragePath -ErrorAction SilentlyContinue) {
        . $capabilityStoragePath
    }
}

if (-not (Get-Variable -Name OpenPathRuntimeDependencyQueueVersion -Scope Script -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $runtimeDependencyProtocolPath = Join-Path $PSScriptRoot 'RuntimeDependency.Protocol.ps1'
    if (Test-Path $runtimeDependencyProtocolPath -ErrorAction SilentlyContinue) {
        . $runtimeDependencyProtocolPath
    }
}

function Get-OpenPathRuntimeDependencyQueuePath {
    # returns the capability storage directory used to hold per-request queue json files
    [CmdletBinding()]
    param()

    return (Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue)
}

function Find-OpenPathRuntimeDependencyQueueRequest {
    # scans queue json files for an existing entry matching the anchor/dependency/requestType triple; returns the file path or empty string
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost,
        [Parameter(Mandatory = $true)][string]$RequestType,
        [string]$QueuePath = (Get-OpenPathRuntimeDependencyQueuePath)
    )

    if (-not (Test-Path $QueuePath -ErrorAction SilentlyContinue)) { return '' }

    foreach ($requestFile in @(Get-ChildItem -Path $QueuePath -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)) {
        try {
            $request = Get-Content $requestFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $queuedAnchor = Normalize-OpenPathRuntimeDependencyHost -Value $request.anchorHost
            $queuedDependency = Normalize-OpenPathRuntimeDependencyHost -Value $request.dependencyHost
            $queuedRequestType = if ($request.requestType -is [string]) { ([string]$request.requestType).Trim().ToLowerInvariant() } else { '' }
            if ($queuedAnchor -eq $AnchorHost -and $queuedDependency -eq $DependencyHost -and $queuedRequestType -eq $RequestType) {
                return $requestFile.FullName
            }
        }
        catch {
            continue
        }
    }

    return ''
}

function Write-OpenPathRuntimeDependencyQueueRequest {
    # validates and normalizes the triple, deduplicates against existing queue files, then writes a new guid-named json request file; returns the path
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AnchorHost,
        [Parameter(Mandatory = $true)][string]$DependencyHost,
        [Parameter(Mandatory = $true)][string]$RequestType,
        [string]$QueuePath = (Get-OpenPathRuntimeDependencyQueuePath)
    )

    $normalizedAnchor = Normalize-OpenPathRuntimeDependencyHost -Value $AnchorHost
    $normalizedDependency = Normalize-OpenPathRuntimeDependencyHost -Value $DependencyHost
    $normalizedRequestType = if ($RequestType -is [string]) { ([string]$RequestType).Trim().ToLowerInvariant() } else { '' }
    if (-not $normalizedAnchor -or -not $normalizedDependency -or -not $normalizedRequestType) {
        throw 'Invalid runtime dependency queue request'
    }

    Ensure-OpenPathCapabilityStorageDirectory -Path $QueuePath | Out-Null

    $existingRequestPath = Find-OpenPathRuntimeDependencyQueueRequest `
        -AnchorHost $normalizedAnchor `
        -DependencyHost $normalizedDependency `
        -RequestType $normalizedRequestType `
        -QueuePath $QueuePath
    if ($existingRequestPath) { return $existingRequestPath }

    $requestId = [Guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $QueuePath "$requestId.json"
    @{
        version = $script:OpenPathRuntimeDependencyQueueVersion
        queuedAt = (Get-Date).ToUniversalTime().ToString('o')
        anchorHost = $normalizedAnchor
        dependencyHost = $normalizedDependency
        requestType = $normalizedRequestType
        source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal
    } | ConvertTo-Json -Depth 6 | Set-Content $requestPath -Encoding UTF8 -Force

    return $requestPath
}

function Read-OpenPathRuntimeDependencyQueueRequests {
    # reads all json files from the queue directory sorted by write time; returns an array of File/Request pairs
    [CmdletBinding()]
    param([string]$QueuePath = (Get-OpenPathRuntimeDependencyQueuePath))

    if (-not (Test-Path $QueuePath -ErrorAction SilentlyContinue)) { return @() }

    return @(
        foreach ($requestFile in @(Get-ChildItem -Path $QueuePath -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)) {
            [PSCustomObject]@{
                File = $requestFile.FullName
                Request = (Get-Content $requestFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            }
        }
    )
}

function Remove-OpenPathRuntimeDependencyQueueRequest {
    # deletes the queue json file at $Path; silently ignores errors
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    Remove-Item $Path -Force -ErrorAction SilentlyContinue
}

function Invoke-OpenPathRuntimeDependencyQueue {
    # drains all queue files, merges them into the overlay via update, and persists the overlay when changed; returns Changed, Processed, Rejected, OverlayWriteMs
    [CmdletBinding()]
    param(
        [string[]]$WhitelistedDomains = @(),
        [string[]]$BlockedSubdomains = @(),
        [string]$QueuePath = (Get-OpenPathRuntimeDependencyQueuePath)
    )

    $result = [ordered]@{
        Changed = $false
        Processed = 0
        Rejected = 0
        OverlayWriteMs = 0
        QueuePath = $QueuePath
    }

    if (-not (Test-Path $QueuePath -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]$result
    }

    $requests = @()
    foreach ($requestEnvelope in @(Read-OpenPathRuntimeDependencyQueueRequests -QueuePath $QueuePath)) {
        try {
            $requests += $requestEnvelope.Request
        }
        catch {
            $result['Rejected'] = [int]$result['Rejected'] + 1
            Write-OpenPathLog "Rejected runtime dependency queue request: $_" -Level WARN
        }
        finally {
            if ($requestEnvelope.PSObject.Properties['File']) {
                Remove-OpenPathRuntimeDependencyQueueRequest -Path $requestEnvelope.File
            }
        }
    }

    $settings = Get-OpenPathRuntimeDependencyOverlaySettings
    $overlayResult = Update-OpenPathRuntimeDependencyOverlay `
        -Entries @(Read-OpenPathRuntimeDependencyOverlay) `
        -Requests $requests `
        -WhitelistedDomains $WhitelistedDomains `
        -BlockedSubdomains $BlockedSubdomains `
        -Capacity $settings.Capacity `
        -TtlDays $settings.TtlDays

    $result['Processed'] = [int]$overlayResult.Processed
    $result['Rejected'] = [int]$result['Rejected'] + [int]$overlayResult.Rejected
    $result['Changed'] = [bool]$overlayResult.Changed

    if ($result['Changed']) {
        $overlayStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-OpenPathRuntimeDependencyOverlay -Entries @($overlayResult.Entries)
        $overlayStopwatch.Stop()
        $result['OverlayWriteMs'] = [int]$overlayStopwatch.ElapsedMilliseconds
    }

    return [PSCustomObject]$result
}
