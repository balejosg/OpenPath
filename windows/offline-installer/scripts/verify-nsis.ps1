# OpenPath NSIS compiler supply-chain verification.
# Fails closed (exit 1) when the resolved makensis.exe hash is not in
# windows/offline-installer/nsis-hashes.json or when the compiler version
# does not match the pinned release.

[CmdletBinding()]
param(
    [string]$MakensisPath = ''
)

$ErrorActionPreference = 'Stop'

$hashesPath = Join-Path $PSScriptRoot '..\nsis-hashes.json'
if (-not (Test-Path $hashesPath)) {
    Write-Error "NSIS hash pin file not found: $hashesPath"
    exit 1
}

$pins = Get-Content -LiteralPath $hashesPath -Raw | ConvertFrom-Json
$pinnedVersion = [string]$pins.version
$acceptedHashes = @($pins.acceptedMakensisSha256 | ForEach-Object { [string]$_ }).ToLowerInvariant()

$candidates = @()
if ($MakensisPath) {
    $candidates += $MakensisPath
}
else {
    $resolvedCommand = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($resolvedCommand) {
        $candidates += $resolvedCommand.Source
    }

    # Chocolatey installs a shim into its bin directory; prefer the real
    # compiler binaries inside the package layout over hashed shims.
    $chocoRoot = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { "$env:ProgramData\chocolatey" }
    $candidates += @(
        (Join-Path $chocoRoot "lib\nsis\tools\nsis-$pinnedVersion\Bin\makensis.exe"),
        (Join-Path $chocoRoot 'lib\nsis\tools\Bin\makensis.exe')
    )
}

$matched = $null
foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not (Test-Path $candidate)) {
        continue
    }

    $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Checked $candidate -> $actualHash"
    if ($acceptedHashes -contains $actualHash) {
        $matched = [pscustomobject]@{ Path = $candidate; Hash = $actualHash }
        break
    }
}

if (-not $matched) {
    $inspected = @($candidates | Where-Object { $_ -and (Test-Path $_) })
    if ($inspected.Count -eq 0) {
        Write-Host ("::error title=supply-chain-violation::makensis.exe was not found on this runner; " +
            "install pinned NSIS $pinnedVersion before building the template")
    }
    else {
        Write-Host ("::error title=supply-chain-violation::makensis.exe SHA-256 mismatch. " +
            "Expected one of [$($acceptedHashes -join ', ')]; inspected: $($inspected -join ', ')")
    }
    exit 1
}

$makensis = $matched.Path

$versionOutput = $null
try {
    $versionOutput = (& $matched.Path -VERSION 2>&1 | Out-String).Trim()
}
catch {
    if ($IsWindows) {
        Write-Host "::error title=supply-chain-violation::could not query makensis version: $_"
        exit 1
    }
    Write-Host 'Skipping makensis version query on a non-Windows host (hash assertion already passed)'
}

if ($null -ne $versionOutput) {
    $versionParts = $pinnedVersion.Split('.')
    $expectedHexParts = @()
    foreach ($part in $versionParts) {
        $expectedHexParts += ('{0:x2}' -f [int]$part)
    }
    $expectedHex = ($expectedHexParts -join '')
    $normalizedVersionOutput = $versionOutput.ToLowerInvariant() -replace '^v', ''
    if ($normalizedVersionOutput -ne $expectedHex -and $normalizedVersionOutput -ne $pinnedVersion) {
        Write-Host ("::error title=supply-chain-violation::makensis version mismatch. " +
            "Pinned $pinnedVersion, compiler reported '$versionOutput'")
        exit 1
    }
}

Write-Host "NSIS $pinnedVersion verified: $($matched.Path) ($($matched.Hash))"
exit 0
