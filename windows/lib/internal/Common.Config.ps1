. (Join-Path $PSScriptRoot 'OpenPathConfig.Model.ps1')

function Get-OpenPathConfig {
    <#
    .SYNOPSIS
        Reads the openpath configuration from config.json
    .OUTPUTS
        PSCustomObject with configuration values
    #>
    if (-not (Test-Path $script:ConfigPath)) {
        Write-OpenPathLog "Config file not found at $($script:ConfigPath)" -Level ERROR
        throw "Configuration file not found"
    }

    return Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
}

function Write-OpenPathAtomicJsonFile {
    <#
    .SYNOPSIS
        Atomically writes JSON content to disk using a temp file and Win32 atomic replace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Data,

        [int]$Depth = 10
    )

    $parentDir = Split-Path -Path $Path -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $json = $Data | ConvertTo-Json -Depth $Depth
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $tempPath = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$Path.bak.$([guid]::NewGuid().ToString('N'))"

    try {
        [System.IO.File]::WriteAllText($tempPath, $json, $utf8WithoutBom)

        if (Test-Path -LiteralPath $Path) {
            try {
                [System.IO.File]::Replace($tempPath, $Path, $backupPath, $true)
            }
            catch {
                [System.IO.File]::Copy($tempPath, $Path, $true)
                [System.IO.File]::Delete($tempPath)
            }
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-OpenPathConfig {
    <#
    .SYNOPSIS
        Saves configuration to config.json
    .PARAMETER Config
        Configuration object to save
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $configDir = Split-Path $script:ConfigPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($script:ConfigPath, "Save configuration")) {
        Write-OpenPathAtomicJsonFile -Path $script:ConfigPath -Data $Config -Depth 10
        Write-OpenPathLog "Configuration saved"
    }
}

function ConvertTo-OpenPathMachineName {
    param(
        [string]$Value
    )

    if (-not $Value) {
        return ''
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = $normalized -replace '[^a-z0-9-]+', '-'
    $normalized = $normalized -replace '-+', '-'
    return $normalized.Trim('-')
}

function New-OpenPathScopedMachineName {
    <#
    .SYNOPSIS
        Builds a deterministic classroom-scoped machine identifier from the local hostname.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hostname,

        [Parameter(Mandatory = $true)]
        [string]$ClassroomId
    )

    $base = ConvertTo-OpenPathMachineName -Value $Hostname
    if (-not $base) {
        $base = 'machine'
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($ClassroomId)
        $hashBytes = $sha.ComputeHash($bytes)
        $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 8)
    }
    finally {
        $sha.Dispose()
    }

    $suffix = "-$hash"
    $maxBaseLength = [Math]::Max(1, 63 - $suffix.Length)
    if ($base.Length -gt $maxBaseLength) {
        $base = $base.Substring(0, $maxBaseLength).TrimEnd('-')
    }
    if (-not $base) {
        $base = 'machine'
    }

    return "$base$suffix"
}

function Get-OpenPathMachineName {
    <#
    .SYNOPSIS
        Returns the persisted machine identifier, falling back to COMPUTERNAME.
    #>
    try {
        $config = Get-OpenPathConfig
        if ($config.PSObject.Properties['machineName'] -and $config.machineName) {
            return [string]$config.machineName
        }
    }
    catch {
        # Fall back to the system hostname if config is unavailable.
    }

    return [string]$env:COMPUTERNAME
}

function Set-OpenPathMachineName {
    <#
    .SYNOPSIS
        Persists the machine identifier into the in-memory config object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$MachineName
    )

    $normalized = ConvertTo-OpenPathMachineName -Value $MachineName
    if (-not $normalized) {
        throw 'MachineName must include at least one letter or number'
    }

    if ($Config.PSObject.Properties['machineName']) {
        $Config.machineName = $normalized
    }
    else {
        $Config | Add-Member -MemberType NoteProperty -Name 'machineName' -Value $normalized -Force
    }

    return $normalized
}

function New-OpenPathMachineRegistrationBody {
    <#
    .SYNOPSIS
        Builds the canonical machine registration request payload.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineName,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [string]$Classroom = '',

        [string]$ClassroomId = ''
    )

    $body = [ordered]@{
        hostname = $MachineName
        version = $Version
    }

    if ($ClassroomId) {
        $body.classroomId = $ClassroomId
    }
    elseif ($Classroom) {
        $body.classroomName = $Classroom
    }

    return [PSCustomObject]$body
}

function Resolve-OpenPathMachineRegistration {
    <#
    .SYNOPSIS
        Normalizes the API registration response into canonical classroom/machine fields.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [string]$MachineName = '',

        [string]$Classroom = '',

        [string]$ClassroomId = ''
    )

    if (-not $Response.success) {
        throw "Machine registration failed: $($Response | ConvertTo-Json -Compress)"
    }

    if (-not $Response.whitelistUrl) {
        throw 'Registration succeeded but no tokenized whitelist URL was returned'
    }

    $resolvedClassroom = if ($Response.PSObject.Properties['classroomName'] -and $Response.classroomName) {
        [string]$Response.classroomName
    }
    else {
        [string]$Classroom
    }

    $resolvedClassroomId = if ($Response.PSObject.Properties['classroomId'] -and $Response.classroomId) {
        [string]$Response.classroomId
    }
    else {
        [string]$ClassroomId
    }

    $resolvedMachineName = if ($Response.PSObject.Properties['machineHostname'] -and $Response.machineHostname) {
        [string]$Response.machineHostname
    }
    else {
        [string]$MachineName
    }

    return [PSCustomObject]@{
        Success = $true
        WhitelistUrl = [string]$Response.whitelistUrl
        Classroom = $resolvedClassroom
        ClassroomId = $resolvedClassroomId
        MachineName = $resolvedMachineName
    }
}
