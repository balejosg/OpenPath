if (-not (Get-Command -Name 'Set-OpenPathCapabilityStorageAcl' -ErrorAction SilentlyContinue) -and $PSScriptRoot) {
    $capabilityStoragePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'internal\CapabilityStorage.ps1'
    if (Test-Path $capabilityStoragePath -ErrorAction SilentlyContinue) {
        . $capabilityStoragePath
    }
}

$script:OpenPathOfflineConfigSchemaVersion = 1
$script:OpenPathOfflineMaxCaptivePortalDomains = 16
$script:OpenPathOfflineMaxStringChars = 2048
$script:OpenPathOfflineApprovedBrowsers = @('Firefox', 'Chrome', 'Edge')

function Assert-OpenPathOfflineSchemaVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $versionProperty = $Config.PSObject.Properties['schemaVersion']
    if (-not $versionProperty -or $versionProperty.Value -ne $script:OpenPathOfflineConfigSchemaVersion) {
        throw "Offline installer configuration schemaVersion must be $($script:OpenPathOfflineConfigSchemaVersion)"
    }
}

function Assert-OpenPathOfflineHttpsUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Offline installer configuration field '$Name' is required"
    }
    if ($Value.Length -gt $script:OpenPathOfflineMaxStringChars) {
        throw "Offline installer configuration field '$Name' exceeds the maximum length of $($script:OpenPathOfflineMaxStringChars) characters"
    }

    $uri = [System.Uri]$null
    if (-not ([System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)) -or $uri.Scheme -ne 'https') {
        throw "Offline installer configuration field '$Name' must be an absolute https URL"
    }
}

function Assert-OpenPathOfflineNonEmptyString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$MaximumLength = 512
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Offline installer configuration field '$Name' is required"
    }
    if ($Value.Length -gt $MaximumLength) {
        throw "Offline installer configuration field '$Name' exceeds the maximum length of $MaximumLength characters"
    }
    if ($Value -match '[\x00-\x1f]') {
        throw "Offline installer configuration field '$Name' must not contain control characters"
    }
}

function ConvertTo-OpenPathOfflineUtcDateTime {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Value -is [System.DateTime]) {
        return $Value.ToUniversalTime()
    }

    $valueText = [string]$Value
    $parsed = [System.DateTime]::MinValue
    if (-not [System.DateTime]::TryParse(
            $valueText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw "Offline installer configuration field '$Name' must be an ISO-8601 date"
    }

    if ($parsed.Kind -eq [System.DateTimeKind]::Unspecified) {
        throw "Offline installer configuration field '$Name' must include a UTC offset or Z designator"
    }

    return $parsed.ToUniversalTime()
}

function ConvertFrom-OpenPathOfflineConfigObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ($Config -isnot [PSCustomObject]) {
        throw 'Offline installer configuration must be a JSON object'
    }

    Assert-OpenPathOfflineSchemaVersion -Config $Config

    foreach ($requiredName in @('apiUrl', 'classroomId', 'enrollmentToken', 'enrollmentTokenExpiresAt')) {
        $property = $Config.PSObject.Properties[$requiredName]
        if (-not $property) {
            throw "Offline installer configuration is missing required field '$requiredName'"
        }
    }

    Assert-OpenPathOfflineHttpsUrl -Value ([string]$Config.apiUrl) -Name 'apiUrl'
    Assert-OpenPathOfflineNonEmptyString `
        -Value ([string]$Config.classroomId) `
        -Name 'classroomId' `
        -MaximumLength 128
    Assert-OpenPathOfflineNonEmptyString `
        -Value ([string]$Config.enrollmentToken) `
        -Name 'enrollmentToken' `
        -MaximumLength 8192

    $expiresAt = ConvertTo-OpenPathOfflineUtcDateTime `
        -Value $Config.enrollmentTokenExpiresAt `
        -Name 'enrollmentTokenExpiresAt'

    $captivePortalDomains = @()
    $domainsProperty = $Config.PSObject.Properties['captivePortalDomains']
    if ($domainsProperty -and $null -ne $domainsProperty.Value) {
        if ($domainsProperty.Value -isnot [System.Array]) {
            throw 'Offline installer configuration field captivePortalDomains must be an array'
        }
        if (@($domainsProperty.Value).Count -gt $script:OpenPathOfflineMaxCaptivePortalDomains) {
            throw "Offline installer configuration field captivePortalDomains exceeds the maximum of $($script:OpenPathOfflineMaxCaptivePortalDomains) entries"
        }
        foreach ($domain in @($domainsProperty.Value)) {
            Assert-OpenPathOfflineNonEmptyString `
                -Value ([string]$domain) `
                -Name 'captivePortalDomains entry' `
                -MaximumLength 253
        }
        $captivePortalDomains = @($domainsProperty.Value | ForEach-Object { [string]$_ })
    }

    $installFirefoxIfMissing = $false
    $enforceManagedBrowserBoundary = $false
    $approvedStudentBrowsers = @('Firefox')
    $optionsProperty = $Config.PSObject.Properties['options']
    if ($optionsProperty -and $null -ne $optionsProperty.Value) {
        if ($optionsProperty.Value -isnot [PSCustomObject]) {
            throw 'Offline installer configuration field options must be an object'
        }

        $firefoxProperty = $optionsProperty.Value.PSObject.Properties['installFirefoxIfMissing']
        if ($firefoxProperty -and $null -ne $firefoxProperty.Value) {
            if ($firefoxProperty.Value -isnot [bool]) {
                throw 'Offline installer configuration field options.installFirefoxIfMissing must be a boolean'
            }
            $installFirefoxIfMissing = [bool]$firefoxProperty.Value
        }

        $boundaryProperty = $optionsProperty.Value.PSObject.Properties['enforceManagedBrowserBoundary']
        if ($boundaryProperty -and $null -ne $boundaryProperty.Value) {
            if ($boundaryProperty.Value -isnot [bool]) {
                throw 'Offline installer configuration field options.enforceManagedBrowserBoundary must be a boolean'
            }
            $enforceManagedBrowserBoundary = [bool]$boundaryProperty.Value
        }

        $browsersProperty = $optionsProperty.Value.PSObject.Properties['approvedStudentBrowsers']
        if ($browsersProperty -and $null -ne $browsersProperty.Value) {
            if ($browsersProperty.Value -isnot [System.Array]) {
                throw 'Offline installer configuration field options.approvedStudentBrowsers must be an array'
            }
            foreach ($browser in @($browsersProperty.Value)) {
                $browserName = [string]$browser
                if ($script:OpenPathOfflineApprovedBrowsers -notcontains $browserName) {
                    throw "Offline installer configuration field options.approvedStudentBrowsers contains unsupported browser '$browserName'"
                }
            }
            $approvedStudentBrowsers = @($browsersProperty.Value | ForEach-Object { [string]$_ })
        }
    }

    return [PSCustomObject]@{
        ApiUrl = [string]$Config.apiUrl
        ClassroomId = [string]$Config.classroomId
        EnrollmentToken = [string]$Config.enrollmentToken
        EnrollmentTokenExpiresAt = $expiresAt
        CaptivePortalDomains = $captivePortalDomains
        InstallFirefoxIfMissing = $installFirefoxIfMissing
        EnforceManagedBrowserBoundary = $enforceManagedBrowserBoundary
        ApprovedStudentBrowsers = $approvedStudentBrowsers
    }
}

function Read-OpenPathOfflineConfigText {
    <#
    .SYNOPSIS
        Validates an already-extracted offline configuration payload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigJson
    )

    try {
        $config = $ConfigJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Offline installer configuration is not valid JSON: $_"
    }

    return ConvertFrom-OpenPathOfflineConfigObject -Config $config
}

function Read-OpenPathOfflineConfig {
    <#
    .SYNOPSIS
        Reads and strictly validates the generic offline installer configuration JSON.
    .PARAMETER Path
        Path to the offline configuration file written by the bootstrapper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Offline installer configuration not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return Read-OpenPathOfflineConfigText -ConfigJson $raw
}

function Assert-OpenPathOfflinePayloadManifest {
    <#
    .SYNOPSIS
        Verifies every required payload in the offline manifest against the staged files.
    .DESCRIPTION
        Fails closed when the manifest is missing, unreadable, or any required payload
        is absent, resized, or hash-mismatched. Performs no network operations.
    .PARAMETER ManifestPath
        Path to the payload manifest JSON produced at build time.
    .PARAMETER StagingRoot
        Directory the manifest paths are relative to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [string]$StagingRoot
    )

    if (-not (Test-Path $ManifestPath)) {
        throw "Offline payload manifest not found: $ManifestPath"
    }

    $manifest = $null
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Offline payload manifest is not valid JSON: $_"
    }

    $entries = $manifest
    if ($manifest -isnot [System.Array] -and $manifest.PSObject.Properties['payloads']) {
        $entries = $manifest.payloads
    }
    if ($entries -isnot [System.Array]) {
        throw 'Offline payload manifest must contain a payloads array'
    }

    $failures = @()
    foreach ($entry in @($entries)) {
        $relativePath = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            $failures += 'manifest entry without a path'
            continue
        }

        $stagedPath = Join-Path $StagingRoot $relativePath
        if (-not (Test-Path $stagedPath)) {
            $failures += "missing payload: $relativePath"
            continue
        }

        $expectedSha256 = [string]$entry.sha256
        if (-not [string]::IsNullOrWhiteSpace($expectedSha256)) {
            $actualSha256 = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($actualSha256 -ne $expectedSha256.ToLowerInvariant()) {
                $failures += "sha256 mismatch for ${relativePath}: expected $expectedSha256 got $actualSha256"
                continue
            }
        }

        $expectedSize = $entry.size
        if ($null -ne $expectedSize) {
            $actualSize = (Get-Item -LiteralPath $stagedPath -ErrorAction Stop).Length
            if ([long]$actualSize -ne [long]$expectedSize) {
                $failures += "size mismatch for ${relativePath}: expected $expectedSize got $actualSize"
            }
        }
    }

    if ($failures.Count -gt 0) {
        throw ("Offline payload verification failed:`n" + ($failures -join "`n"))
    }
}

function Get-OpenPathOfflineManifestEntry {
    <#
    .SYNOPSIS
        Returns a single payload manifest entry by relative path, failing closed when absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if (-not (Test-Path $ManifestPath)) {
        throw "Offline payload manifest not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $entries = $manifest
    if ($manifest -isnot [System.Array] -and $manifest.PSObject.Properties['payloads']) {
        $entries = $manifest.payloads
    }

    foreach ($entry in @($entries)) {
        if ([string]$entry.path -eq $RelativePath) {
            return $entry
        }
    }

    throw "Offline payload manifest has no entry for '$RelativePath'"
}

function Install-AcrylicDNSFromLocalSource {
    <#
    .SYNOPSIS
        Installs Acrylic DNS Proxy from a validated local portable ZIP with no network access.
    .PARAMETER AcrylicZipPath
        Staged Acrylic-Portable.zip shipped inside the offline installer package.
    .PARAMETER ExpectedSha256
        SHA-256 digest the ZIP must match before extraction.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AcrylicZipPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [string]$InstallDir = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy",

        [switch]$Force
    )

    if ((Test-AcrylicInstalled) -and -not $Force) {
        Write-OpenPathLog 'Acrylic DNS Proxy already installed; local source install skipped'
        return $true
    }

    if (-not (Test-Path $AcrylicZipPath)) {
        throw "Staged Acrylic ZIP not found: $AcrylicZipPath"
    }

    if (-not $PSCmdlet.ShouldProcess("Acrylic DNS Proxy from $AcrylicZipPath", 'Install locally')) {
        return $false
    }

    Assert-AcrylicDownloadHash -Path $AcrylicZipPath -ExpectedSha256 $ExpectedSha256 -ArtifactName (Split-Path $AcrylicZipPath -Leaf)
    if (-not (Test-AcrylicPortableArchive -Path $AcrylicZipPath)) {
        throw 'Staged Acrylic archive is not a valid portable release'
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("acrylic-offline-" + [Guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Expand-Archive -LiteralPath $AcrylicZipPath -DestinationPath $tempDir -Force
        if (-not (Test-Path $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }

        $extractedDir = Get-ChildItem $tempDir -Directory | Select-Object -First 1
        if ($extractedDir) {
            Copy-Item "$($extractedDir.FullName)\*" $installDir -Recurse -Force
        }
        else {
            Copy-Item "$tempDir\*" $installDir -Recurse -Force -Exclude '*.zip'
        }

        if (-not (Test-Path (Join-Path $installDir 'AcrylicService.exe'))) {
            throw 'Local Acrylic install did not produce AcrylicService.exe'
        }

        Register-AcrylicServiceFromPath -AcrylicPath $installDir | Out-Null
        Write-OpenPathLog 'Acrylic DNS Proxy installed from local offline source'
        return $true
    }
    finally {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-OpenPathPendingEnrollmentStatePath {
    <#
    .SYNOPSIS
        Returns the DPAPI blob path for deferred enrollment state under the agent data directory.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    if ([string]::IsNullOrWhiteSpace($OpenPathRoot)) {
        $OpenPathRoot = if ($script:OpenPathRoot) { $script:OpenPathRoot } else { 'C:\OpenPath' }
    }

    return (Join-Path $OpenPathRoot 'data\pending-enrollment.json.dpapi')
}

function Save-OpenPathPendingEnrollmentState {
    <#
    .SYNOPSIS
        Persists deferred enrollment state protected by machine-scope DPAPI and restrictive ACLs.
    .DESCRIPTION
        The enrollment token is never written in plaintext. If DPAPI or ACL protection cannot be
        applied the function throws instead of leaving the token readable on disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$ApiUrl,

        [Parameter(Mandatory = $true)]
        [string]$ClassroomId,

        [Parameter(Mandatory = $true)]
        [string]$EnrollmentToken,

        [Parameter(Mandatory = $true)]
        [string]$ExpiresAt
    )

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

    $state = [PSCustomObject]@{
        apiUrl = $ApiUrl
        classroomId = $ClassroomId
        enrollmentToken = $EnrollmentToken
        expiresAt = $ExpiresAt
        savedAtUtc = [System.DateTime]::UtcNow.ToString('o')
    }

    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Compress))
    $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $jsonBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine)

    $dataDir = Join-Path $OpenPathRoot 'data'
    if (-not (Test-Path $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    $statePath = Get-OpenPathPendingEnrollmentStatePath -OpenPathRoot $OpenPathRoot
    [System.IO.File]::WriteAllBytes($statePath, $protectedBytes)

    try {
        Set-OpenPathCapabilityStorageAcl -Path $statePath -Profile RestrictedRoot
    }
    catch {
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
        throw "Could not apply restrictive ACLs to pending enrollment state; token was not persisted: $_"
    }

    Write-OpenPathLog "Saved deferred enrollment state for classroom $ClassroomId" -Level INFO
    return $statePath
}

function Read-OpenPathPendingEnrollmentState {
    <#
    .SYNOPSIS
        Reads and decrypts the pending enrollment state, returning null when absent.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

    $statePath = Get-OpenPathPendingEnrollmentStatePath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path $statePath)) {
        return $null
    }

    try {
        $protectedBytes = [System.IO.File]::ReadAllBytes($statePath)
        $jsonBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return ([System.Text.Encoding]::UTF8.GetString($jsonBytes) | ConvertFrom-Json)
    }
    catch {
        Write-OpenPathLog "Pending enrollment state could not be decrypted: $_" -Level WARN
        return $null
    }
}

function Clear-OpenPathPendingEnrollmentState {
    <#
    .SYNOPSIS
        Deletes the pending enrollment state and its expired informational marker.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    foreach ($candidate in @(
            (Get-OpenPathPendingEnrollmentStatePath -OpenPathRoot $OpenPathRoot),
            (Join-Path $OpenPathRoot 'data\pending-enrollment.json')
        )) {
        if (Test-Path $candidate) {
            Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-OpenPathPendingEnrollmentExpired {
    <#
    .SYNOPSIS
        Returns true when the pending enrollment expiry instant has passed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $expiresAt = ConvertTo-OpenPathOfflineUtcDateTime `
        -Value $State.expiresAt `
        -Name 'pending enrollment expiresAt'

    return ([System.DateTime]::UtcNow -ge $expiresAt)
}

function Invoke-OpenPathPendingEnrollmentRetry {
    <#
    .SYNOPSIS
        Attempts deferred enrollment from pending state during startup/watchdog cycles.
    .DESCRIPTION
        On success the pending state is cleared immediately. After token expiry the DPAPI blob is
        deleted, an EXPIRED marker without secrets is retained for diagnosis, and an actionable
        error requiring re-installation is logged. The bearer token is never logged.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    $state = Read-OpenPathPendingEnrollmentState -OpenPathRoot $OpenPathRoot
    if (-not $state) {
        return [PSCustomObject]@{ Outcome = 'NOT_PENDING'; MachineRegistered = '' }
    }

    if (Test-OpenPathPendingEnrollmentExpired -State $state) {
        Clear-OpenPathPendingEnrollmentState -OpenPathRoot $OpenPathRoot
        $expiredMarker = [PSCustomObject]@{
            status = 'EXPIRED'
            classroomId = [string]$state.classroomId
            expiresAt = [string]$state.expiresAt
            diagnostic = 'Embedded enrollment token expired before the machine obtained connectivity. Re-install with a fresh offline installer.'
        }
        $expiredMarker | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $OpenPathRoot 'data\pending-enrollment.json') -Encoding UTF8
        Write-OpenPathLog 'Deferred enrollment failed: embedded token expired. Re-install OpenPath with a fresh offline installer.' -Level ERROR
        return [PSCustomObject]@{ Outcome = 'EXPIRED'; MachineRegistered = '' }
    }

    $enrollScript = Join-Path $OpenPathRoot 'scripts\Enroll-Machine.ps1'
    if (-not (Test-Path $enrollScript)) {
        Write-OpenPathLog 'Deferred enrollment retry skipped: enrollment script not found' -Level WARN
        return [PSCustomObject]@{ Outcome = 'FAILED'; MachineRegistered = '' }
    }

    try {
        $enrollParams = @{
            ApiUrl = [string]$state.apiUrl
            ClassroomId = [string]$state.classroomId
            EnrollmentToken = [string]$state.enrollmentToken
            OpenPathRoot = $OpenPathRoot
            Unattended = $true
            SkipTokenValidation = $true
            Quiet = $true
        }

        $enrollResult = & $enrollScript @enrollParams
        if ($enrollResult -and $enrollResult.Success) {
            Clear-OpenPathPendingEnrollmentState -OpenPathRoot $OpenPathRoot
            Write-OpenPathLog 'Deferred enrollment completed successfully on retry' -Level INFO
            return [PSCustomObject]@{ Outcome = 'REGISTERED'; MachineRegistered = 'REGISTERED'; WhitelistUrl = [string]$enrollResult.WhitelistUrl }
        }

        Write-OpenPathLog 'Deferred enrollment retry did not complete; will retry on the next cycle' -Level WARN
        return [PSCustomObject]@{ Outcome = 'FAILED'; MachineRegistered = '' }
    }
    catch {
        Write-OpenPathLog "Deferred enrollment retry failed without exposing credentials: $_" -Level WARN
        return [PSCustomObject]@{ Outcome = 'FAILED'; MachineRegistered = '' }
    }
}
