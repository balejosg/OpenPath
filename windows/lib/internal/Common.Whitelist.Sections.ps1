# Single owner of the whitelist.txt '## section' wire-format parser.
# Canonical copy: includes '#DESACTIVADO' disabled-sentinel handling and
# invariant-uppercase section headers. Pure functions only — no module state,
# no admin calls — so this file is safe to dot-source into the unelevated
# Firefox native messaging host (it is staged via NativeHost.ArtifactCatalog.ps1).

function Get-OpenPathWhitelistSectionsFromLines {
    <#
    .SYNOPSIS
        Parses whitelist document lines into the supported policy sections.
    .PARAMETER Lines
        Whitelist document lines (already split; entries may carry stray CR/whitespace).
    #>
    param(
        [AllowNull()]
        [string[]]$Lines = @()
    )

    $result = [ordered]@{
        Whitelist = @()
        BlockedSubdomains = @()
        BlockedPaths = @()
        AllowedPaths = @()
        IsDisabled = $false
        ReadSucceeded = $true
    }

    $section = 'WHITELIST'
    foreach ($line in @($Lines)) {
        $trimmed = ([string]$line).Trim()

        if (-not $trimmed) {
            continue
        }

        if ($trimmed -match '^#\s*DESACTIVADO\b') {
            $result.IsDisabled = $true
            continue
        }

        if ($trimmed -match '^##\s*(.+)$') {
            $section = $Matches[1].Trim().ToUpperInvariant()
            continue
        }

        if ($trimmed.StartsWith('#')) {
            continue
        }

        switch ($section) {
            'WHITELIST' { $result.Whitelist += $trimmed }
            'BLOCKED-SUBDOMAINS' { $result.BlockedSubdomains += $trimmed }
            'BLOCKED-PATHS' { $result.BlockedPaths += $trimmed }
            'ALLOWED-PATHS' { $result.AllowedPaths += $trimmed }
        }
    }

    return [PSCustomObject]$result
}

function Get-OpenPathWhitelistSectionsFromFile {
    <#
    .SYNOPSIS
        Returns all supported whitelist sections from a local whitelist file.
    .DESCRIPTION
        Opens the file with FileShare.ReadWrite|Delete so a concurrent atomic replace or a
        reader does not fail the parse, and retries transient I/O failures a bounded number
        of times. ReadSucceeded is false when the file is missing or could not be read after
        the retries; callers that enforce policy must treat that as Unknown (fail closed).
    .PARAMETER Path
        Full path to whitelist file
    .PARAMETER MaxAttempts
        Maximum number of read attempts (default 3).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$MaxAttempts = 3
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $missing = Get-OpenPathWhitelistSectionsFromLines -Lines @()
        $missing.PSObject.Properties['ReadSucceeded'].Value = $false
        return $missing
    }

    $attempt = 0
    while ($attempt -lt [Math]::Max(1, $MaxAttempts)) {
        $attempt += 1
        $stream = $null
        $reader = $null
        try {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            $content = $reader.ReadToEnd()
            return (Get-OpenPathWhitelistSectionsFromLines -Lines @($content -split "\r?\n"))
        }
        catch [System.IO.IOException] {
            # Retry below: a transient lock or share violation must not look like
            # an empty (enabled) whitelist.
        }
        catch [System.UnauthorizedAccessException] {
            # Retry below for the same reason as IOException.
        }
        catch {
            # Unexpected read failure: report Unknown instead of throwing from a
            # state read that the watchdog and native host both call.
        }
        finally {
            if ($reader) { $reader.Dispose() }
            elseif ($stream) { $stream.Dispose() }
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Milliseconds 75
        }
    }

    $unreadable = Get-OpenPathWhitelistSectionsFromLines -Lines @()
    $unreadable.PSObject.Properties['ReadSucceeded'].Value = $false
    return $unreadable
}
