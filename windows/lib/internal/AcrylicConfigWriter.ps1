function Set-AcrylicGlobalSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value
    )

    $escapedKey = [regex]::Escape($Key)
    $pattern = "(?m)^$escapedKey=.*$"
    $replacement = "$Key=$Value"
    if ($Content -match $pattern) { return ($Content -replace $pattern, $replacement) }

    $nextSection = [regex]::Match($Content, '(?m)^\[(?!GlobalSection\])[^]]+\]\s*$')
    if ($nextSection.Success) { return $Content.Insert($nextSection.Index, "$replacement`n") }

    return ($Content.TrimEnd() + "`n$replacement`n")
}

function Set-AcrylicAllowedAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Content -notmatch '(?m)^\[AllowedAddressesSection\]\s*$') {
        $Content = $Content.TrimEnd() + "`n`n[AllowedAddressesSection]`n"
    }

    $escapedKey = [regex]::Escape($Key)
    $pattern = "(?m)^$escapedKey=.*$"
    $replacement = "$Key=$Value"
    if ($Content -match $pattern) { return ($Content -replace $pattern, $replacement) }

    $allowedSection = [regex]::Match($Content, '(?m)^\[AllowedAddressesSection\]\s*$')
    if ($allowedSection.Success) { return $Content.Insert($allowedSection.Index + $allowedSection.Length, "`n$replacement") }

    return ($Content.TrimEnd() + "`n`n[AllowedAddressesSection]`n$replacement`n")
}

function Write-AcrylicConfigFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    Set-Content -Path $Path -Value $Content -Encoding ASCII -Force
}

function Write-AcrylicHostsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    Set-Content -Path $Path -Value $Content -Encoding ASCII -Force
}
