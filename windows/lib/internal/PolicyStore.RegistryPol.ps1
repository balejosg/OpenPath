# Registry.pol (PReg) and gpt.ini codec for the local GPO policy store.
# Pure file-format helpers; no registry or Group Policy engine access.

$script:OpenPathRegistryCseGuid = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
$script:OpenPathRegistryToolGuid = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'

function Read-OpenPathRegistryPolString {
    # Reads a UTF-16LE NUL-terminated string at $Position and advances past the terminator.
    param(
        [byte[]]$Bytes,
        [ref]$Position
    )

    $start = $Position.Value
    $pos = $start
    while ($true) {
        if ($pos + 1 -ge $Bytes.Length) {
            throw 'local-gpo-unreadable: truncated string in Registry.pol'
        }
        if ($Bytes[$pos] -eq 0 -and $Bytes[$pos + 1] -eq 0) { break }
        $pos += 2
    }
    $text = [System.Text.Encoding]::Unicode.GetString($Bytes, $start, $pos - $start)
    $Position.Value = $pos + 2
    return $text
}

function Assert-OpenPathRegistryPolDelimiter {
    param(
        [byte[]]$Bytes,
        [int]$Position,
        [char]$Expected
    )

    if ($Position + 1 -ge $Bytes.Length -or $Bytes[$Position] -ne [byte]$Expected -or $Bytes[$Position + 1] -ne 0) {
        throw "local-gpo-unreadable: expected '$Expected' at offset $Position in Registry.pol"
    }
}

# Note: like any PowerShell function, a single-element result unrolls; wrap call sites in @().
function Read-OpenPathRegistryPolFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        throw "local-gpo-unreadable: cannot read ${Path}: $($_.Exception.Message)"
    }
    if ($bytes.Length -lt 8 -or
        [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'PReg' -or
        [BitConverter]::ToUInt32($bytes, 4) -ne 1) {
        throw "local-gpo-unreadable: $Path does not have a PReg version 1 header"
    }

    $entries = New-Object System.Collections.ArrayList
    $pos = 8
    while ($pos -lt $bytes.Length) {
        Assert-OpenPathRegistryPolDelimiter -Bytes $bytes -Position $pos -Expected '['
        $pos += 2
        $key = Read-OpenPathRegistryPolString -Bytes $bytes -Position ([ref]$pos)
        Assert-OpenPathRegistryPolDelimiter -Bytes $bytes -Position $pos -Expected ';'
        $pos += 2
        $valueName = Read-OpenPathRegistryPolString -Bytes $bytes -Position ([ref]$pos)
        Assert-OpenPathRegistryPolDelimiter -Bytes $bytes -Position $pos -Expected ';'
        $pos += 2
        if ($pos + 4 -gt $bytes.Length) { throw 'local-gpo-unreadable: truncated type in Registry.pol' }
        $type = [BitConverter]::ToUInt32($bytes, $pos)
        $pos += 4
        Assert-OpenPathRegistryPolDelimiter -Bytes $bytes -Position $pos -Expected ';'
        $pos += 2
        if ($pos + 4 -gt $bytes.Length) { throw 'local-gpo-unreadable: truncated size in Registry.pol' }
        $size = [BitConverter]::ToUInt32($bytes, $pos)
        $pos += 4
        Assert-OpenPathRegistryPolDelimiter -Bytes $bytes -Position $pos -Expected ';'
        $pos += 2
        if ([int64]$pos + [int64]$size + 2 -gt [int64]$bytes.Length) {
            throw 'local-gpo-unreadable: truncated data in Registry.pol'
        }
        $data = New-Object byte[] ([int]$size)
        if ($size -gt 0) { [Array]::Copy($bytes, $pos, $data, 0, [int]$size) }
        $pos += [int]$size
        Assert-OpenPathRegistryPolDelimiter -Bytes $bytes -Position $pos -Expected ']'
        $pos += 2

        [void]$entries.Add([pscustomobject]@{ Key = $key; ValueName = $valueName; Type = $type; Data = $data })
    }

    return $entries.ToArray()
}

function Write-OpenPathRegistryPolFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $unicode = [System.Text.Encoding]::Unicode
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))
        $writer.Write([uint32]1)
        foreach ($entry in $Entries) {
            $data = [byte[]]$entry.Data
            $writer.Write($unicode.GetBytes('['))
            $writer.Write($unicode.GetBytes([string]$entry.Key + [char]0))
            $writer.Write($unicode.GetBytes(';'))
            $writer.Write($unicode.GetBytes([string]$entry.ValueName + [char]0))
            $writer.Write($unicode.GetBytes(';'))
            $writer.Write([uint32]$entry.Type)
            $writer.Write($unicode.GetBytes(';'))
            $writer.Write([uint32]$data.Length)
            $writer.Write($unicode.GetBytes(';'))
            $writer.Write($data)
            $writer.Write($unicode.GetBytes(']'))
        }
        $writer.Flush()
        $content = $stream.ToArray()
    }
    finally {
        $writer.Dispose()
    }

    $tmpPath = "$Path.openpath-tmp"
    $bakPath = "$Path.openpath-bak"
    try {
        [System.IO.File]::WriteAllBytes($tmpPath, $content)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Copy-Item -LiteralPath $Path -Destination $bakPath -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function ConvertTo-OpenPathRegistryPolData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('String', 'MultiString', 'DWord')][string]$Type,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][object]$Value
    )

    $unicode = [System.Text.Encoding]::Unicode
    switch ($Type) {
        'String' {
            return @{ Type = [uint32]1; Data = [byte[]]$unicode.GetBytes(([string]$Value) + [char]0) }
        }
        'MultiString' {
            $lines = @($Value | ForEach-Object { [string]$_ })
            $text = ''
            foreach ($line in $lines) { $text += $line + [char]0 }
            $text += [char]0
            return @{ Type = [uint32]7; Data = [byte[]]$unicode.GetBytes($text) }
        }
        'DWord' {
            return @{ Type = [uint32]4; Data = [byte[]][BitConverter]::GetBytes([uint32]$Value) }
        }
    }
}

function ConvertFrom-OpenPathRegistryPolData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uint32]$Type,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Data
    )

    $unicode = [System.Text.Encoding]::Unicode
    switch ([int]$Type) {
        1 {
            return $unicode.GetString($Data).TrimEnd([char]0)
        }
        7 {
            $text = $unicode.GetString($Data)
            $parts = @($text.Split([char]0))
            # Drop the empty tail produced by the per-line and final terminators.
            $lines = New-Object System.Collections.ArrayList
            $count = $parts.Count
            while ($count -gt 0 -and $parts[$count - 1] -eq '') { $count-- }
            for ($i = 0; $i -lt $count; $i++) { [void]$lines.Add([string]$parts[$i]) }
            return [string[]]$lines.ToArray()
        }
        4 {
            if ($Data.Length -lt 4) { throw 'local-gpo-unreadable: REG_DWORD data shorter than 4 bytes' }
            return [int][BitConverter]::ToInt32($Data, 0)
        }
        default {
            throw "Unsupported Registry.pol value type: $Type"
        }
    }
}

function Step-OpenPathLocalGpoMachineVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GptIniPath)

    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $registryBracket = '[' + $script:OpenPathRegistryCseGuid + $script:OpenPathRegistryToolGuid + ']'
    $cseName = 'gPCMachineExtensionNames'

    $directory = Split-Path -Parent $GptIniPath
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $GptIniPath -PathType Leaf)) {
        $text = "[General]`r`n$cseName=$registryBracket`r`nVersion=1`r`n"
        [System.IO.File]::WriteAllText($GptIniPath, $text, $latin1)
        return 1
    }

    $text = [System.IO.File]::ReadAllText($GptIniPath, $latin1)
    $newline = "`r`n"
    $lines = New-Object System.Collections.ArrayList
    foreach ($line in [regex]::Split($text, "`r`n|`n")) { [void]$lines.Add($line) }
    # A trailing newline yields one empty tail element; keep it so the file ends the same way.
    $hasTail = ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '')
    if ($hasTail) { $lines.RemoveAt($lines.Count - 1) }

    $generalIndex = -1
    $versionIndex = -1
    $cseIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($generalIndex -lt 0 -and $line.Trim() -ieq '[General]') { $generalIndex = $i }
        elseif ($versionIndex -lt 0 -and $line -match '^\s*Version\s*=') { $versionIndex = $i }
        elseif ($cseIndex -lt 0 -and $line -match ('^\s*' + $cseName + '\s*=')) { $cseIndex = $i }
    }

    if ($generalIndex -lt 0) {
        $lines.Insert(0, '[General]')
        $generalIndex = 0
        if ($versionIndex -ge 0) { $versionIndex++ }
        if ($cseIndex -ge 0) { $cseIndex++ }
    }

    # Machine half = low 16 bits, user half = high 16 bits.
    $current = [int64]0
    if ($versionIndex -ge 0) {
        $m = [regex]::Match([string]$lines[$versionIndex], '=\s*(\d+)')
        if ($m.Success) { $current = [int64]$m.Groups[1].Value }
    }
    $machine = (($current -band 0xFFFF) + 1) -band 0xFFFF
    $newVersion = [int](($current -band 0xFFFF0000) -bor $machine)
    $versionLine = "Version=$newVersion"
    if ($versionIndex -ge 0) {
        $lines[$versionIndex] = $versionLine
    }
    else {
        $lines.Add($versionLine) | Out-Null
    }

    if ($cseIndex -ge 0) {
        $value = ([string]$lines[$cseIndex]).Substring(([string]$lines[$cseIndex]).IndexOf('=') + 1)
        $brackets = New-Object System.Collections.ArrayList
        foreach ($b in [regex]::Matches($value, '\[[^\]]*\]')) { [void]$brackets.Add($b.Value) }
        $hasRegistry = $false
        foreach ($b in $brackets) {
            if ($b.StartsWith('[' + $script:OpenPathRegistryCseGuid, [System.StringComparison]::OrdinalIgnoreCase)) { $hasRegistry = $true }
        }
        if (-not $hasRegistry) {
            $insertAt = $brackets.Count
            for ($i = 0; $i -lt $brackets.Count; $i++) {
                $guid = [regex]::Match([string]$brackets[$i], '^\[(\{[^}]*\})').Groups[1].Value
                if ([string]::Compare($guid, $script:OpenPathRegistryCseGuid, [System.StringComparison]::OrdinalIgnoreCase) -gt 0) {
                    $insertAt = $i
                    break
                }
            }
            $brackets.Insert($insertAt, $registryBracket)
            $lines[$cseIndex] = "$cseName=" + (($brackets.ToArray()) -join '')
        }
    }
    else {
        $lines.Insert($generalIndex + 1, "$cseName=$registryBracket")
    }

    $output = ($lines.ToArray() -join $newline) + $newline
    [System.IO.File]::WriteAllText($GptIniPath, $output, $latin1)
    return $newVersion
}
