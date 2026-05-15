function Get-OpenPathRuntimeDependencyQueuePath {
    [CmdletBinding()]
    param()

    if ($env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH) {
        return $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH
    }

    $root = if ($script:OpenPathRoot) { $script:OpenPathRoot } else { 'C:\OpenPath' }
    return (Join-Path $root 'data\runtime-dependency-queue')
}

function Find-OpenPathRuntimeDependencyQueueRequest {
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

    if (-not (Test-Path $QueuePath -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $QueuePath -Force | Out-Null
    }

    $existingRequestPath = Find-OpenPathRuntimeDependencyQueueRequest `
        -AnchorHost $normalizedAnchor `
        -DependencyHost $normalizedDependency `
        -RequestType $normalizedRequestType `
        -QueuePath $QueuePath
    if ($existingRequestPath) { return $existingRequestPath }

    $requestId = [Guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $QueuePath "$requestId.json"
    @{
        version = 1
        queuedAt = (Get-Date).ToUniversalTime().ToString('o')
        anchorHost = $normalizedAnchor
        dependencyHost = $normalizedDependency
        requestType = $normalizedRequestType
        source = 'firefox-webrequest-local'
    } | ConvertTo-Json -Depth 6 | Set-Content $requestPath -Encoding UTF8 -Force

    return $requestPath
}

function Read-OpenPathRuntimeDependencyQueueRequests {
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
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    Remove-Item $Path -Force -ErrorAction SilentlyContinue
}

function Invoke-OpenPathRuntimeDependencyQueue {
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
