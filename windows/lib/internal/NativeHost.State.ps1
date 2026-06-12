function Read-NativeState {
    # reads and parses the native host state json file; returns an empty object when the file is missing or unreadable.
    if (-not (Test-Path $script:StatePath)) {
        return [PSCustomObject]@{}
    }

    try {
        return Get-Content $script:StatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-NativeHostLog "Failed to parse native state: $_"
        return [PSCustomObject]@{}
    }
}

function Get-WhitelistSections {
    # parses the whitelist file into Whitelist, BlockedSubdomains, and BlockedPaths sections; returns empty section arrays when the file is absent.
    $result = [ordered]@{
        Whitelist = @()
        BlockedSubdomains = @()
        BlockedPaths = @()
    }

    if (-not (Test-Path $script:WhitelistPath)) {
        return [PSCustomObject]$result
    }

    $section = 'WHITELIST'
    foreach ($line in Get-Content $script:WhitelistPath -ErrorAction SilentlyContinue) {
        $trimmed = [string]$line
        $trimmed = $trimmed.Trim()

        if (-not $trimmed) {
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
        }
    }

    return [PSCustomObject]$result
}

function Resolve-DomainIp {
    # returns the first IP address string from a DNS lookup of $Domain, or $null when resolution fails or returns no A record.
    param(
        [string]$Domain
    )

    try {
        $record = Resolve-DnsName -Name $Domain -DnsOnly -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -First 1
        if ($record -and $record.IPAddress) {
            return [string]$record.IPAddress
        }
    }
    catch {
        return $null
    }

    return $null
}
