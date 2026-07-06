if (-not (Get-Command -Name 'Get-OpenPathWhitelistSectionsFromLines' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $whitelistSectionsPath = Join-Path $PSScriptRoot 'Common.Whitelist.Sections.ps1'
    if (Test-Path $whitelistSectionsPath -ErrorAction SilentlyContinue) {
        . $whitelistSectionsPath
    }
}

function Get-ValidWhitelistDomainsFromFile {
    <#
    .SYNOPSIS
        Returns syntactically valid domains from a whitelist file
    .PARAMETER Path
        Full path to whitelist file
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $sections = Get-OpenPathWhitelistSectionsFromFile -Path $Path

    return @(
        @($sections.Whitelist) |
            ForEach-Object { $_.Trim() } |
            Where-Object { Test-OpenPathDomainFormat -Domain $_ }
    )
}

function ConvertTo-OpenPathWhitelistFileContent {
    <#
    .SYNOPSIS
        Serializes the effective whitelist policy file with all supported sections.
    #>
    param(
        [string[]]$Whitelist = @(),

        [string[]]$BlockedSubdomains = @(),

        [string[]]$BlockedPaths = @(),

        [string[]]$AllowedPaths = @(),

        [switch]$Disabled
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    if ($Disabled) {
        $lines.Add('#DESACTIVADO') | Out-Null
    }

    $lines.Add('## WHITELIST') | Out-Null
    foreach ($domain in @($Whitelist)) {
        $trimmed = ([string]$domain).Trim()
        if ($trimmed) {
            $lines.Add($trimmed) | Out-Null
        }
    }

    $lines.Add('') | Out-Null
    $lines.Add('## BLOCKED-SUBDOMAINS') | Out-Null
    foreach ($subdomain in @($BlockedSubdomains)) {
        $trimmed = ([string]$subdomain).Trim()
        if ($trimmed) {
            $lines.Add($trimmed) | Out-Null
        }
    }

    $lines.Add('') | Out-Null
    $lines.Add('## BLOCKED-PATHS') | Out-Null
    foreach ($pathRule in @($BlockedPaths)) {
        $trimmed = ([string]$pathRule).Trim()
        if ($trimmed) {
            $lines.Add($trimmed) | Out-Null
        }
    }

    $lines.Add('') | Out-Null
    $lines.Add('## ALLOWED-PATHS') | Out-Null
    foreach ($pathRule in @($AllowedPaths)) {
        $trimmed = ([string]$pathRule).Trim()
        if ($trimmed) {
            $lines.Add($trimmed) | Out-Null
        }
    }

    return ($lines -join [Environment]::NewLine).TrimEnd()
}

function Save-OpenPathWhitelistCheckpoint {
    <#
    .SYNOPSIS
        Saves the current whitelist into a timestamped checkpoint folder
    .PARAMETER WhitelistPath
        Path to current whitelist file
    .PARAMETER MaxCheckpoints
        Maximum number of checkpoint folders to keep
    .PARAMETER Reason
        Reason for checkpoint creation
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath,

        [int]$MaxCheckpoints = 3,

        [string]$Reason = 'pre-update'
    )

    if (-not (Test-Path $WhitelistPath)) {
        return [PSCustomObject]@{
            Success = $false
            CheckpointPath = $null
            Error = 'Whitelist file not found'
        }
    }

    try {
        if (-not (Test-Path $script:CheckpointPath)) {
            New-Item -ItemType Directory -Path $script:CheckpointPath -Force | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $checkpointPath = Join-Path $script:CheckpointPath "checkpoint-$timestamp"

        if (-not $PSCmdlet.ShouldProcess($checkpointPath, 'Create whitelist checkpoint')) {
            return [PSCustomObject]@{
                Success = $false
                CheckpointPath = $null
                Error = 'Operation cancelled by WhatIf/Confirm'
            }
        }

        New-Item -ItemType Directory -Path $checkpointPath -Force | Out-Null
        Copy-Item $WhitelistPath (Join-Path $checkpointPath 'whitelist.txt') -Force

        @{
            createdAt = (Get-Date -Format 'o')
            reason = $Reason
            source = $WhitelistPath
        } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $checkpointPath 'metadata.json') -Encoding UTF8

        if ($MaxCheckpoints -lt 1) {
            $MaxCheckpoints = 1
        }

        $checkpoints = Get-ChildItem $script:CheckpointPath -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending

        if ($checkpoints.Count -gt $MaxCheckpoints) {
            $checkpoints | Select-Object -Skip $MaxCheckpoints | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

        return [PSCustomObject]@{
            Success = $true
            CheckpointPath = $checkpointPath
            Error = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            CheckpointPath = $null
            Error = "Failed to create checkpoint: $_"
        }
    }
}

function Get-OpenPathLatestCheckpoint {
    <#
    .SYNOPSIS
        Returns latest available whitelist checkpoint metadata
    #>
    if (-not (Test-Path $script:CheckpointPath)) {
        return $null
    }

    $latest = Get-ChildItem $script:CheckpointPath -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latest) {
        return $null
    }

    $checkpointWhitelist = Join-Path $latest.FullName 'whitelist.txt'
    if (-not (Test-Path $checkpointWhitelist)) {
        return $null
    }

    $metadataPath = Join-Path $latest.FullName 'metadata.json'
    $metadata = $null
    if (Test-Path $metadataPath) {
        try {
            $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        }
        catch {
            $metadata = $null
        }
    }

    return [PSCustomObject]@{
        Path = $latest.FullName
        WhitelistPath = $checkpointWhitelist
        Metadata = $metadata
    }
}

function Restore-OpenPathLatestCheckpoint {
    <#
    .SYNOPSIS
        Restores the latest whitelist checkpoint and reapplies DNS enforcement state
    .PARAMETER Config
        OpenPath config object with enableFirewall/primaryDNS settings
    .PARAMETER WhitelistPath
        Destination whitelist path to restore into
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$WhitelistPath
    )

    $result = [ordered]@{
        Success = $false
        CheckpointPath = $null
        DomainCount = 0
        Error = $null
    }

    $checkpoint = Get-OpenPathLatestCheckpoint
    if (-not $checkpoint) {
        $result.Error = 'No checkpoint available'
        return [PSCustomObject]$result
    }

    if (-not $PSCmdlet.ShouldProcess($WhitelistPath, "Restore checkpoint from $($checkpoint.Path)")) {
        $result.Error = 'Operation cancelled by WhatIf/Confirm'
        return [PSCustomObject]$result
    }

    try {
        Copy-Item $checkpoint.WhitelistPath $WhitelistPath -Force

        $domains = Get-ValidWhitelistDomainsFromFile -Path $WhitelistPath
        if ($domains.Count -lt 1) {
            $result.Error = 'Checkpoint restore aborted: no valid domains in checkpoint whitelist'
            return [PSCustomObject]$result
        }

        Update-AcrylicHost -WhitelistedDomains $domains -BlockedSubdomains @() | Out-Null
        Restore-OpenPathProtectedMode -Config $Config | Out-Null

        $result.Success = $true
        $result.CheckpointPath = $checkpoint.Path
        $result.DomainCount = $domains.Count
        return [PSCustomObject]$result
    }
    catch {
        $result.Error = "Checkpoint restore failed: $_"
        return [PSCustomObject]$result
    }
}
