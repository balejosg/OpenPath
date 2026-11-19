. (Join-Path $PSScriptRoot 'OpenPathConfig.Model.ps1')

function Invoke-OpenPathAtomicFileReplace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TempPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    [System.IO.File]::Replace($TempPath, $DestinationPath, $BackupPath, $true)
}

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

function Write-OpenPathAtomicTextFile {
    <#
    .SYNOPSIS
        Atomically writes text content to disk using a sibling temp file, durable flush, and atomic replace/move.
    .DESCRIPTION
        The final replace/move is retried a bounded number of times when Windows reports a
        sharing violation (for example another process reading the destination without
        FILE_SHARE_DELETE). The writer never falls back to an in-place write: after the last
        attempt it removes the temp file and rethrows, leaving the previous destination intact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [int]$MaxAttempts = 5,

        [switch]$NoTrailingNewline
    )

    $parentDir = Split-Path -Path $Path -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Mirror Set-Content for text files: keep a single trailing newline.
    $payload = [string]$Content
    if (-not $NoTrailingNewline -and -not $payload.EndsWith("`n")) {
        $payload += [Environment]::NewLine
    }

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8WithoutBom.GetBytes($payload)

    $guid = [guid]::NewGuid().ToString('N')
    $tempPath = "$Path.tmp.$guid"
    $backupPath = "$Path.bak.$guid"

    $fileStream = $null
    try {
        $fileStream = [System.IO.File]::Create($tempPath)
        $fileStream.Write($bytes, 0, $bytes.Length)
        $fileStream.Flush($true)
    }
    finally {
        if ($fileStream) {
            $fileStream.Dispose()
            $fileStream = $null
        }
    }

    $attempt = 0
    $lastError = $null
    try {
        while ($attempt -lt [Math]::Max(1, $MaxAttempts)) {
            $attempt += 1
            try {
                if ([System.IO.File]::Exists($Path)) {
                    # Atomic swap into existing destination. If Replace fails, the
                    # existing destination is never partially overwritten in place.
                    Invoke-OpenPathAtomicFileReplace `
                        -TempPath $tempPath `
                        -DestinationPath $Path `
                        -BackupPath $backupPath
                }
                else {
                    # Atomic move into non-existent destination within the same directory.
                    [System.IO.File]::Move($tempPath, $Path)
                }
                $lastError = $null
                break
            }
            catch [System.IO.IOException] {
                $lastError = $_
            }
            catch [System.UnauthorizedAccessException] {
                $lastError = $_
            }

            if ($lastError -and $attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds ([Math]::Min(200, 50 * $attempt))
            }
        }
    }
    finally {
        if ([System.IO.File]::Exists($tempPath)) {
            try { [System.IO.File]::Delete($tempPath) } catch {}
        }
        if ([System.IO.File]::Exists($backupPath)) {
            try { [System.IO.File]::Delete($backupPath) } catch {}
        }
    }

    if ($lastError) {
        Write-OpenPathLog "Atomic text write failed after $attempt attempt(s) for ${Path}: $lastError" -Level WARN
        throw $lastError
    }
}

function Write-OpenPathAtomicJsonFile {
    <#
    .SYNOPSIS
        Atomically writes JSON content to disk using temp file, durable flush, and atomic replace/move.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Data,

        [int]$Depth = 10
    )

    $json = $Data | ConvertTo-Json -Depth $Depth
    Write-OpenPathAtomicTextFile -Path $Path -Content ([string]$json) -NoTrailingNewline
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

function Test-OpenPathProgramFilesCatalogPath {
    <#
    .SYNOPSIS
        True when a catalog path is an exact, administrator-owned Program Files
        executable path (no wildcard, traversal, user profile or AppData segment).
    .DESCRIPTION
        Shared by the AppLocker approval catalog validation and the egress floor, so a
        path that may be granted execution and a path that may be granted network
        access are judged by the same rule.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    $candidate = ([string]$Path).Trim()
    $pathPattern = '^(?i)(?:[A-Z]:\\Program Files(?: \(x86\))?|%PROGRAMFILES%)\\[^*?\\/:<>|]+(?:\\[^*?\\/:<>|]+)*$'
    $knownExtensions = @('.exe', '.com', '.dll', '.ps1', '.bat', '.cmd', '.vbs', '.js', '.wsf', '.msi', '.msp', '.mst')
    $extension = if ($candidate -match '(\.[^.\\]+)$') { $Matches[1].ToLowerInvariant() } else { '' }
    return [bool]($candidate -match $pathPattern -and
        $candidate -notmatch '(?i)\\Users\\|AppData|\.\.' -and
        $knownExtensions -contains $extension)
}
