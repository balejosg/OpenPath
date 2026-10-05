# Phase 5.3 B7: secret scan for first-visit controller artifacts.
#
# The lane uploads the whole evidence tree as a public artifact. The scan
# walks every JSON file, matches credential-shaped keys and reports a finding
# for any non-empty string value that is not an explicit redaction or a hash.
# The value itself is never echoed: the finding carries length and a SHA-256
# prefix so the leak can be identified without copying it into another file.

function Get-OpenPathFirstVisitSecretValueField {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-OpenPathFirstVisitSecretKey {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $Name -match '(?i)secret|password|passwd|token|credential|api[_-]?key|private[_-]?key'
}

function Test-OpenPathFirstVisitSecretAllowedValue {
    param([Parameter(Mandatory = $true)][string]$Value, [string[]]$AllowedValuePatterns = @())
    $patterns = @('^<redacted>$', '^[0-9a-f]{64}$', '^\*+$') + @($AllowedValuePatterns)
    foreach ($pattern in $patterns) {
        if ($Value -match $pattern) { return $true }
    }
    return $false
}

function Find-OpenPathFirstVisitSecretValue {
    <#
    .SYNOPSIS
    Recursively collects secret-shaped key/value findings from one JSON value.
    #>
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$KeyPath = '$',
        [string[]]$AllowedValuePatterns = @(),
        [int]$Depth = 0
    )
    $findings = New-Object System.Collections.ArrayList
    if ($null -eq $Value -or $Depth -gt 12) { return @() }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $child = $Value[$key]
            $childPath = "$KeyPath.$key"
            if ((Test-OpenPathFirstVisitSecretKey -Name ([string]$key))) {
                if ($child -is [string]) {
                    $text = [string]$child
                    if ($text.Length -gt 0 -and -not (Test-OpenPathFirstVisitSecretAllowedValue -Value $text -AllowedValuePatterns $AllowedValuePatterns)) {
                        $sha = ''
                        try {
                            $sha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
                        }
                        catch { }
                        $null = $findings.Add([ordered]@{ file = $Path; key = $childPath; valueLength = $text.Length; valueSha256_12 = $sha })
                        continue
                    }
                }
            }
            foreach ($finding in @(Find-OpenPathFirstVisitSecretValue -Value $child -Path $Path -KeyPath $childPath -AllowedValuePatterns $AllowedValuePatterns -Depth ($Depth + 1))) {
                $null = $findings.Add($finding)
            }
        }
        return @($findings.ToArray())
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $index = 0
        foreach ($item in $Value) {
            foreach ($finding in @(Find-OpenPathFirstVisitSecretValue -Value $item -Path $Path -KeyPath "$KeyPath[$index]" -AllowedValuePatterns $AllowedValuePatterns -Depth ($Depth + 1))) {
                $null = $findings.Add($finding)
            }
            $index++
        }
        return @($findings.ToArray())
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $bag = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            if ($property.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) { continue }
            $child = $null
            try { $child = $property.Value } catch { continue }
            $bag[[string]$property.Name] = $child
        }
        return @(Find-OpenPathFirstVisitSecretValue -Value $bag -Path $Path -KeyPath $KeyPath -AllowedValuePatterns $AllowedValuePatterns -Depth ($Depth + 1))
    }
    return @()
}

function Find-OpenPathFirstVisitArtifactSecret {
    <#
    .SYNOPSIS
    Walks every JSON file under a first-visit artifacts root for secret-shaped
    keys with unredacted values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$AllowedValuePatterns = @(),
        [int]$MaxFiles = 500
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $findings = New-Object System.Collections.ArrayList
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First $MaxFiles)
    foreach ($file in $files) {
        $text = ''
        try { $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop } catch { continue }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $parsed = $null
        try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        foreach ($finding in @(Find-OpenPathFirstVisitSecretValue -Value $parsed -Path $file.FullName -AllowedValuePatterns $AllowedValuePatterns)) {
            $null = $findings.Add($finding)
        }
    }
    return @($findings.ToArray())
}

Export-ModuleMember -Function Find-OpenPathFirstVisitArtifactSecret, Find-OpenPathFirstVisitSecretValue
