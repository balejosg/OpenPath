if (-not (Get-Command -Name 'Get-OpenPathWhitelistSectionsFromFile' -ErrorAction SilentlyContinue)) {
    $whitelistSectionsCandidatePaths = @()
    if ($PSScriptRoot) {
        $whitelistSectionsCandidatePaths += (Join-Path $PSScriptRoot 'Common.Whitelist.Sections.ps1')
    }
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $whitelistSectionsCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\Common.Whitelist.Sections.ps1')
    }
    foreach ($whitelistSectionsCandidatePath in ($whitelistSectionsCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $whitelistSectionsCandidatePath -ErrorAction SilentlyContinue) {
            . $whitelistSectionsCandidatePath
            break
        }
    }
}

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
    # returns the native whitelist mirror sections via the shared owner parser
    # (Common.Whitelist.Sections.ps1). Unlike the old inline copy this includes
    # IsDisabled (additive; the entry parsing is byte-identical because sentinel
    # lines start with '#' and were already skipped as comments).
    if (-not (Test-Path $script:WhitelistPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $missing = Get-OpenPathWhitelistSectionsFromLines -Lines @()
        $missing | Add-Member -NotePropertyName PolicyKnown -NotePropertyValue $false -Force
        $missing | Add-Member -NotePropertyName PolicyVersion -NotePropertyValue '' -Force
        return $missing
    }

    try {
        $whitelistBytes = [System.IO.File]::ReadAllBytes($script:WhitelistPath)
        $text = [System.Text.Encoding]::UTF8.GetString($whitelistBytes)
        $sections = Get-OpenPathWhitelistSectionsFromLines -Lines @($text -split "`r?`n")
        $stateBytes = if (Test-Path $script:StatePath -PathType Leaf -ErrorAction SilentlyContinue) {
            [System.IO.File]::ReadAllBytes($script:StatePath)
        }
        else { [byte[]]@() }
        $combined = [byte[]]::new($whitelistBytes.Length + 1 + $stateBytes.Length)
        [Array]::Copy($whitelistBytes, 0, $combined, 0, $whitelistBytes.Length)
        $combined[$whitelistBytes.Length] = 0
        [Array]::Copy($stateBytes, 0, $combined, $whitelistBytes.Length + 1, $stateBytes.Length)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $version = -join ($sha.ComputeHash($combined) | ForEach-Object { $_.ToString('x2') })
        }
        finally { $sha.Dispose() }
        $sections | Add-Member -NotePropertyName PolicyKnown -NotePropertyValue $true -Force
        $sections | Add-Member -NotePropertyName PolicyVersion -NotePropertyValue $version -Force
        return $sections
    }
    catch {
        $failed = Get-OpenPathWhitelistSectionsFromLines -Lines @()
        $failed | Add-Member -NotePropertyName PolicyKnown -NotePropertyValue $false -Force
        $failed | Add-Member -NotePropertyName PolicyVersion -NotePropertyValue '' -Force
        return $failed
    }
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
