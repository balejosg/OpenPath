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

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    SSE listener daemon for instant rule updates on Windows
.DESCRIPTION
    Maintains a persistent connection to the API's Server-Sent Events (SSE)
    endpoint. When a whitelist rule change is detected, immediately triggers
    Update-OpenPath.ps1 to apply the new rules without waiting for the
    15-minute fallback timer.

    Reconnects automatically with exponential backoff on connection failure.
#>

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot '..\lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

# Initialize standalone script session via the shared bootstrap helper.
Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force
Initialize-OpenPathScriptSession `
    -OpenPathRoot $OpenPathRoot `
    -RequiredCommands @(
    'Write-OpenPathLog',
    'Get-OpenPathConfig'
) `
    -ScriptName 'Start-SSEListener.ps1' | Out-Null
Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force
Initialize-OpenPathUpdateRuntimeSession -OpenPathRoot $OpenPathRoot

# =============================================================================
# Configuration
# =============================================================================

$script:LastUpdateTime = [datetime]::MinValue
$script:DelayedUpdateDueAt = [datetime]::MinValue

function Get-SSEConfig {
    <#
    .SYNOPSIS
        Reads SSE configuration from config.json with defaults
    #>
    $config = Get-OpenPathConfig

    return @{
        WhitelistUrl    = $config.whitelistUrl
        ReconnectMin    = if ($config.PSObject.Properties['sseReconnectMin']) { $config.sseReconnectMin } else { 5 }
        ReconnectMax    = if ($config.PSObject.Properties['sseReconnectMax']) { $config.sseReconnectMax } else { 60 }
        UpdateCooldown  = if ($config.PSObject.Properties['sseUpdateCooldown']) { $config.sseUpdateCooldown } else { 10 }
    }
}

function Get-MachineToken {
    <#
    .SYNOPSIS
        Extracts machine token from the whitelist URL
    .DESCRIPTION
        URL format: https://server:3000/w/<TOKEN>/whitelist.txt
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistUrl
    )

    if ($WhitelistUrl -match '/w/([^/]+)/') {
        return $Matches[1]
    }

    Write-OpenPathLog "Cannot extract machine token from whitelist URL" -Level ERROR
    throw "Invalid whitelist URL format - cannot extract machine token"
}

function Get-SSEUrl {
    <#
    .SYNOPSIS
        Derives the SSE endpoint URL from the whitelist URL (without token)
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistUrl
    )

    # Extract base URL (scheme + host)
    if ($WhitelistUrl -match '^(https?://[^/]+)') {
        $baseUrl = $Matches[1]
    }
    else {
        throw "Cannot extract base URL from whitelist URL"
    }

    return "$baseUrl/api/machines/events"
}

# =============================================================================
# Update Trigger (with debounce)
# =============================================================================

function Invoke-DebouncedUpdate {
    <#
    .SYNOPSIS
        Triggers an OpenPath update with cooldown debounce
    #>
    param(
        [int]$CooldownSeconds = 10
    )

    $now = Get-Date
    $elapsed = ($now - $script:LastUpdateTime).TotalSeconds

    if ($elapsed -lt $CooldownSeconds) {
        $delaySeconds = [Math]::Max(1, [int][Math]::Ceiling($CooldownSeconds - $elapsed))
        if ($script:DelayedUpdateDueAt -gt $now) {
            Write-OpenPathLog "SSE: Delayed update already queued for $($script:DelayedUpdateDueAt.ToString('o'))"
            return
        }

        $script:DelayedUpdateDueAt = $now.AddSeconds($delaySeconds)
        Write-OpenPathLog "SSE: Queuing delayed update in ${delaySeconds}s (last update ${elapsed}s ago, cooldown ${CooldownSeconds}s)"
        Start-OpenPathSseUpdateProcess -DelaySeconds $delaySeconds
        return
    }

    Write-OpenPathLog "SSE: Whitelist change detected - triggering immediate update"
    $script:LastUpdateTime = $now
    $script:DelayedUpdateDueAt = [datetime]::MinValue

    Start-OpenPathSseUpdateProcess
}

function Start-OpenPathSseUpdateProcess {
    param(
        [int]$DelaySeconds = 0
    )

    if ($DelaySeconds -gt 0) {
        Write-OpenPathLog "SSE: Waiting ${DelaySeconds}s before starting in-process OpenPath update"
        Start-Sleep -Seconds $DelaySeconds
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-OpenPathLog "SSE: Starting in-process OpenPath update"
        [int]$exitCode = Invoke-OpenPathUpdateCycle -OpenPathRoot $OpenPathRoot
        $stopwatch.Stop()
        if ($exitCode -ne 0) {
            Write-OpenPathLog "SSE: In-process OpenPath update failed with exit code $exitCode after $($stopwatch.ElapsedMilliseconds)ms" -Level WARN
            return
        }
        Write-OpenPathLog "SSE: In-process OpenPath update completed in $($stopwatch.ElapsedMilliseconds)ms"
    }
    catch {
        $stopwatch.Stop()
        Write-OpenPathLog "SSE: In-process OpenPath update failed after $($stopwatch.ElapsedMilliseconds)ms: $_" -Level WARN
    }
}

# =============================================================================
# SSE Connection Loop
# =============================================================================

function Start-SSEConnection {
    <#
    .SYNOPSIS
        Maintains a persistent SSE connection with automatic reconnection
    #>
    $sseConfig = Get-SSEConfig

    if (-not $sseConfig.WhitelistUrl) {
        Write-OpenPathLog "SSE: No whitelist URL configured - cannot start SSE listener" -Level ERROR
        exit 1
    }

    $sseUrl = Get-SSEUrl -WhitelistUrl $sseConfig.WhitelistUrl
    $machineToken = Get-MachineToken -WhitelistUrl $sseConfig.WhitelistUrl
    $backoff = $sseConfig.ReconnectMin

    Write-OpenPathLog "SSE listener starting (endpoint: $sseUrl)"

    while ($true) {
        Write-OpenPathLog "SSE: Connecting..."

        $client = $null
        $response = $null
        $stream = $null
        $reader = $null

        try {
            if (-not ('System.Net.Http.HttpClientHandler' -as [type])) {
                try {
                    Add-Type -AssemblyName 'System.Net.Http' -ErrorAction Stop
                }
                catch {
                    [void][System.Reflection.Assembly]::Load('System.Net.Http')
                }
            }

            # Use HttpClient for streaming SSE (Invoke-WebRequest buffers the whole response)
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $client = [System.Net.Http.HttpClient]::new($handler)
            $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

            $request = [System.Net.Http.HttpRequestMessage]::new(
                [System.Net.Http.HttpMethod]::Get,
                $sseUrl
            )
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
                "Bearer", $machineToken
            )
            $request.Headers.Accept.Add(
                [System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("text/event-stream")
            )

            # ResponseHeadersRead allows streaming without buffering the entire body
            $response = $client.SendAsync(
                $request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()

            $response.EnsureSuccessStatusCode()

            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader = [System.IO.StreamReader]::new($stream)

            # Reset backoff on successful connection
            $backoff = $sseConfig.ReconnectMin

            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()

                if (-not $line) { continue }

                # SSE format: "data: {json}"
                if ($line -match '^data:\s*(.+)$') {
                    $payload = $Matches[1]

                    if ($payload -match '"whitelist-changed"') {
                        Invoke-DebouncedUpdate -CooldownSeconds $sseConfig.UpdateCooldown
                    }
                    elseif ($payload -match '"connected"') {
                        Write-OpenPathLog "SSE: Connected to API - listening for rule changes"
                    }
                }
            }
        }
        catch {
            Write-OpenPathLog "SSE: Connection error: $_" -Level WARN
        }
        finally {
            # Clean up resources
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
            if ($client) { $client.Dispose() }
        }

        # Reconnect with exponential backoff
        Write-OpenPathLog "SSE: Connection lost - reconnecting in ${backoff}s"
        Start-Sleep -Seconds $backoff

        $backoff = [Math]::Min($backoff * 2, $sseConfig.ReconnectMax)
    }
}

# =============================================================================
# Main
# =============================================================================

Start-SSEConnection
