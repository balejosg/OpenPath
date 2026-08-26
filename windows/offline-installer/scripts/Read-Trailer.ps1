# OpenPath offline installer trailer reader.
# Validates the versioned trailer appended to the template executable and
# writes the customized configuration to an ACL-restricted file for
# Install-OpenPath.ps1 -OfflineConfigPath. Exit codes follow the installer
# contract: 0 success, 10 invalid trailer/configuration.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputConfigPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ExecutablePath)) {
    Write-Error "Executable not found: $ExecutablePath"
    exit 10
}

$offlineModuleCandidates = @(
    (Join-Path $PSScriptRoot '..\lib\install\Installer.Offline.ps1'),
    (Join-Path $PSScriptRoot '..\..\lib\install\Installer.Offline.ps1'),
    (Join-Path $PSScriptRoot '..\..\..\windows\lib\install\Installer.Offline.ps1')
)
$offlineModule = $offlineModuleCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $offlineModule) {
    throw 'Offline validation module not found beside trailer reader'
}

$offlineModuleRoot = Split-Path -Parent $offlineModule
$capabilityStorage = Join-Path (Join-Path (Split-Path -Parent $offlineModuleRoot) 'internal') 'CapabilityStorage.ps1'
if (-not (Test-Path -LiteralPath $capabilityStorage -PathType Leaf)) {
    throw 'Capability storage module not found beside offline validation module'
}

. $capabilityStorage
. $offlineModule

try {
    $fileStream = [System.IO.File]::OpenRead($ExecutablePath)
    try {
        $length = $fileStream.Length
        if ($length -lt 65604) {
            throw 'Executable is too small to contain an offline trailer'
        }

        $epilogue = New-Object byte[] 16
        $null = $fileStream.Seek($length - 16, 'Begin')
        if ($fileStream.Read($epilogue, 0, 16) -ne 16) {
            throw 'Short read while reading the trailer epilogue'
        }

        if ([System.Text.Encoding]::ASCII.GetString($epilogue, 0, 4) -ne 'OPWS') {
            throw 'Missing OPWS epilogue magic; this executable has no offline trailer'
        }

        $slotLength = [BitConverter]::ToUInt32($epilogue, 4)
        $headerSize = [BitConverter]::ToUInt32($epilogue, 8)
        $epilogueSize = [BitConverter]::ToUInt32($epilogue, 12)

        if ($epilogueSize -ne 16 -or $headerSize -ne 52 -or $slotLength -ne 65536) {
            throw "Unsupported trailer geometry (slot=$slotLength header=$headerSize epilogue=$epilogueSize)"
        }

        $header = New-Object byte[] 52
        $trailerStart = $length - $headerSize - $slotLength - $epilogueSize
        $null = $fileStream.Seek($trailerStart, 'Begin')
        if ($fileStream.Read($header, 0, 52) -ne 52) {
            throw 'Short read while reading the trailer header'
        }

        if ([System.Text.Encoding]::ASCII.GetString($header, 0, 8) -ne "OPWSI1`0`0") {
            throw 'Invalid trailer header magic'
        }

        $schemaVersion = [BitConverter]::ToUInt16($header, 8)
        $flags = [BitConverter]::ToUInt16($header, 10)
        $payloadLength = [BitConverter]::ToUInt32($header, 12)
        $declaredSlotLength = [BitConverter]::ToUInt32($header, 16)

        if ($schemaVersion -ne 1) { throw "Unsupported schemaVersion $schemaVersion" }
        if ($flags -ne 0) { throw "Reserved flags must be zero (got $flags)" }
        if ($declaredSlotLength -ne $slotLength) { throw 'Header and epilogue slot lengths disagree' }
        if ($payloadLength -gt $slotLength) { throw 'Payload exceeds the fixed slot size' }

        $payload = New-Object byte[] $payloadLength
        $null = $fileStream.Seek($trailerStart + $headerSize, 'Begin')
        $offset = 0
        while ($offset -lt $payloadLength) {
            $read = $fileStream.Read($payload, $offset, $payloadLength - $offset)
            if ($read -le 0) { throw 'Short read while reading the payload slot' }
            $offset += $read
        }

        $padding = New-Object byte[] ($slotLength - $payloadLength)
        if (($slotLength - $payloadLength) -gt 0) {
            $null = $fileStream.Seek($trailerStart + $headerSize + $payloadLength, 'Begin')
            if ($fileStream.Read($padding, 0, $padding.Length) -ne $padding.Length) {
                throw 'Short read while reading slot padding'
            }
            foreach ($paddingByte in $padding) {
                if ($paddingByte -ne 0) { throw 'Slot padding must be zero bytes' }
            }
        }
    }
    finally {
        $fileStream.Dispose()
    }

    $expectedSha256 = [System.BitConverter]::ToString($header, 20, 32).Replace('-', '').ToLowerInvariant()
    $actualSha256 = [System.Security.Cryptography.SHA256]::Create().ComputeHash($payload)
    $actualHex = ([System.BitConverter]::ToString($actualSha256)).Replace('-', '').ToLowerInvariant()
    if ($expectedSha256 -ne $actualHex) {
        throw 'Trailer payload SHA-256 mismatch'
    }

    $configText = [System.Text.Encoding]::UTF8.GetString($payload)
    try {
        $config = $configText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Trailer payload is not valid JSON: $_"
    }

    $classroomProperty = $config.PSObject.Properties['classroomId']
    if ($classroomProperty -and [string]$classroomProperty.Value -eq 'template-placeholder') {
        Write-Error 'This is the uncustomized template; generate a classroom installer before installing.'
        exit 10
    }

    $validated = Read-OpenPathOfflineConfigText -ConfigJson $configText

    $outputDir = Split-Path -Parent $OutputConfigPath
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputConfigPath, $configText, (New-Object System.Text.UTF8Encoding($false)))
    Set-OpenPathCapabilityStorageAcl -Path $OutputConfigPath -Profile RestrictedRoot

    Write-Host "Offline configuration extracted for classroom $($validated.ClassroomId)"
    exit 0
}
catch {
    Write-Error "Invalid offline installer trailer: $_"
    exit 10
}
