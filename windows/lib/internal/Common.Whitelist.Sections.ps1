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
    .PARAMETER Path
        Full path to whitelist file
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return (Get-OpenPathWhitelistSectionsFromLines -Lines @())
    }

    return (Get-OpenPathWhitelistSectionsFromLines -Lines @(Get-Content $Path -ErrorAction SilentlyContinue))
}
