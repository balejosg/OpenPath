function Get-OpenPathControlPlaneHostsPath {
    <#
    .SYNOPSIS
    Returns the Windows hosts file path used by the control-plane valve.
    #>
    [CmdletBinding()]
    param()

    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = 'C:\Windows'
    }
    return [System.IO.Path]::Combine($systemRoot, 'System32', 'drivers', 'etc', 'hosts')
}

function Get-OpenPathControlPlaneDnsCachePath {
    <#
    .SYNOPSIS
    Returns the last-known-good control-plane DNS cache path.
    #>
    param([string]$OpenPathRoot = '')

    $dataRoot = Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot
    return [System.IO.Path]::Combine($dataRoot, 'control-plane-dns-cache.json')
}

function Get-OpenPathDnsFailureModeStatePath {
    <#
    .SYNOPSIS
    Returns the active failure-mode marker path.
    #>
    param([string]$OpenPathRoot = '')

    $dataRoot = Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot
    return [System.IO.Path]::Combine($dataRoot, 'dns-failure-mode.json')
}

function Test-OpenPathControlPlaneIpv4 {
    <#
    .SYNOPSIS
    Accepts only routable unicast IPv4 addresses for the control-plane valve.
    #>
    param([object]$Address)

    $text = ([string]$Address).Trim()
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($text, [ref]$parsed)) {
        return $false
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $octets = $text.Split('.')
    if ($octets.Count -ne 4) { return $false }
    $first = [int]$octets[0]
    if ($first -eq 0 -or $first -eq 127) { return $false }
    if ($first -ge 224 -and $first -le 239) { return $false }
    return $true
}

function Read-OpenPathControlPlaneDnsCache {
    <#
    .SYNOPSIS
    Reads the last-known-good control-plane DNS cache.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    $cache = [PSCustomObject]@{
        capturedAt = ''
        hosts = @{}
    }

    $path = Get-OpenPathControlPlaneDnsCachePath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path $path)) {
        return $cache
    }

    try {
        $stored = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($stored.PSObject.Properties['capturedAt']) {
            $cache.capturedAt = ConvertTo-OpenPathIsoTimestamp -Value $stored.capturedAt
        }
        if ($stored.PSObject.Properties['hosts'] -and $stored.hosts) {
            foreach ($property in $stored.hosts.PSObject.Properties) {
                $cache.hosts[[string]$property.Name] = @($property.Value | ForEach-Object { [string]$_ } | Where-Object { Test-OpenPathControlPlaneIpv4 -Address $_ })
            }
        }
    }
    catch {
        Write-OpenPathLog "Could not read the control-plane DNS cache: $_" -Level WARN
    }

    return $cache
}

function Get-OpenPathControlPlaneHostsFromConfig {
    <#
    .SYNOPSIS
    Extracts non-literal hostnames from the configured apiUrl and whitelistUrl.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Config)

    $hosts = [System.Collections.Generic.List[string]]::new()
    if (-not $Config) { return @() }

    foreach ($propertyName in @('apiUrl', 'whitelistUrl')) {
        if (-not $Config.PSObject.Properties[$propertyName] -or -not $Config.$propertyName) {
            continue
        }
        $url = [string]$Config.$propertyName
        try {
            $uri = [System.Uri]$url
            $hostName = $uri.Host
        }
        catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }
        $literal = $null
        if ([System.Net.IPAddress]::TryParse($hostName, [ref]$literal)) { continue }
        if (-not $hosts.Contains($hostName.ToLowerInvariant())) {
            $hosts.Add($hostName.ToLowerInvariant()) | Out-Null
        }
    }

    return @($hosts)
}

function Test-OpenPathControlPlaneDnsCacheFresh {
    <#
    .SYNOPSIS
    Returns true when the cache timestamp is present and no older than MaxAgeDays.
    #>
    param(
        [AllowNull()][object]$CapturedAt,
        [int]$MaxAgeDays = 30
    )

    if ([string]::IsNullOrWhiteSpace([string]$CapturedAt)) { return $false }
    $parsed = [DateTimeOffset]::MinValue
    try {
        if (-not [DateTimeOffset]::TryParse(
                [string]$CapturedAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsed)) {
            return $false
        }
    }
    catch {
        return $false
    }
    return ((([DateTimeOffset]::UtcNow) - $parsed).TotalDays -le $MaxAgeDays)
}

function Update-OpenPathControlPlaneDnsCache {
    <#
    .SYNOPSIS
    Captures the last-known-good control-plane addresses through the local Acrylic proxy.
    .DESCRIPTION
    Runs only in healthy cycles. It resolves each configured control-plane host through
    127.0.0.1, keeps valid unicast IPv4 answers, and rewrites the cache only when the
    answer set changes or the stored capture is older than 24 hours.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Config,
        [string]$OpenPathRoot = '',
        [int]$MaxAgeHours = 24
    )

    $hostNames = @(Get-OpenPathControlPlaneHostsFromConfig -Config $Config)
    if ($hostNames.Count -eq 0) {
        return $false
    }

    $existing = Read-OpenPathControlPlaneDnsCache -OpenPathRoot $OpenPathRoot
    $resolved = [ordered]@{}
    foreach ($existingHost in @($existing.hosts.Keys)) {
        if ($hostNames -contains $existingHost) {
            $resolved[$existingHost] = @($existing.hosts[$existingHost])
        }
    }

    foreach ($hostName in @($hostNames | Sort-Object)) {
        try {
            $answers = @(Invoke-OpenPathDnsResolveNameWithTimeout `
                    -Domain $hostName `
                    -Server '127.0.0.1' `
                    -AttemptTimeoutSeconds 3)
            $addresses = @(
                $answers |
                    ForEach-Object {
                        if ($_.PSObject.Properties['IPAddress']) { [string]$_.IPAddress }
                        elseif ($_.PSObject.Properties['IPAddressToString']) { [string]$_.IPAddressToString }
                    } |
                    Where-Object { $_ -and (Test-OpenPathControlPlaneIpv4 -Address $_) } |
                    Sort-Object -Unique
            )
            if ($addresses.Count -gt 0) {
                $resolved[$hostName] = @($addresses)
            }
        }
        catch {
            Write-OpenPathLog "Control-plane DNS capture failed for ${hostName}: $_" -Level WARN
        }
    }

    if ($resolved.Count -eq 0) {
        return $false
    }

    $orderedResolved = [ordered]@{}
    foreach ($hostName in @($resolved.Keys | Sort-Object)) {
        $orderedResolved[$hostName] = $resolved[$hostName]
    }
    $resolved = $orderedResolved

    $existingJson = ($existing.hosts | ConvertTo-Json -Depth 5 -Compress)
    $resolvedJson = ($resolved | ConvertTo-Json -Depth 5 -Compress)
    $captureAgeHours = [double]::PositiveInfinity
    if ($existing.capturedAt) {
        $parsed = [DateTimeOffset]::MinValue
        try {
            if ([DateTimeOffset]::TryParse(
                    [string]$existing.capturedAt,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind,
                    [ref]$parsed)) {
                $captureAgeHours = ((([DateTimeOffset]::UtcNow) - $parsed).TotalHours)
            }
        }
        catch {
            $captureAgeHours = [double]::PositiveInfinity
        }
    }

    if ($existingJson -eq $resolvedJson -and $captureAgeHours -lt $MaxAgeHours) {
        return $false
    }

    $payload = [PSCustomObject]@{
        capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
        hosts = $resolved
    }
    Write-OpenPathAtomicJsonFile -Path (Get-OpenPathControlPlaneDnsCachePath -OpenPathRoot $OpenPathRoot) -Data $payload -Depth 6
    return $true
}

function Read-OpenPathDnsFailureModeState {
    <#
    .SYNOPSIS
    Reads the active failure-mode marker, returning null when absent or invalid.
    #>
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    $path = Get-OpenPathDnsFailureModeStatePath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path $path)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $state.PSObject.Properties['mode'] -or [string]$state.mode -notin @('protected', 'open')) {
            return $null
        }
        return $state
    }
    catch {
        Write-OpenPathLog "Could not read the DNS failure-mode marker: $_" -Level WARN
        return $null
    }
}

function Get-OpenPathControlPlaneHostsText {
    <#
    .SYNOPSIS
    Reads the hosts file through Latin-1 so every existing byte round-trips unchanged.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
}

function Write-OpenPathControlPlaneHostsText {
    <#
    .SYNOPSIS
    Atomically replaces the hosts file while preserving existing bytes and attributes.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $readOnly = $false
    $originalAttributes = $null
    if (Test-Path $Path) {
        $originalAttributes = [System.IO.File]::GetAttributes($Path)
        if (($originalAttributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            $readOnly = $true
            [System.IO.File]::SetAttributes($Path, ($originalAttributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
        }
    }

    $encoding = [System.Text.Encoding]::GetEncoding(28591)
    $bytes = $encoding.GetBytes($Text)
    $tempPath = "$Path.openpath-$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.openpath-$([Guid]::NewGuid().ToString('N')).bak"
    $written = $false
    try {
        for ($attempt = 1; $attempt -le 3 -and -not $written; $attempt++) {
            try {
                [System.IO.File]::WriteAllBytes($tempPath, $bytes)
                if (Test-Path $Path) {
                    [System.IO.File]::Replace($tempPath, $Path, $backupPath)
                }
                else {
                    [System.IO.File]::Move($tempPath, $Path)
                }
                $written = $true
            }
            catch {
                if ($attempt -ge 3) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    finally {
        if (Test-Path $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        if ($readOnly -and $null -ne $originalAttributes) {
            [System.IO.File]::SetAttributes($Path, $originalAttributes)
        }
    }
}

function Remove-OpenPathControlPlaneValveBlockFromText {
    <#
    .SYNOPSIS
    Removes every marked valve block from hosts text without touching user content.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $beginMarker = '# BEGIN OpenPath control-plane valve'
    $endMarker = '# END OpenPath control-plane valve'
    while ($true) {
        $startIndex = $Text.IndexOf($beginMarker, [System.StringComparison]::Ordinal)
        if ($startIndex -lt 0) { break }
        $endIndex = $Text.IndexOf($endMarker, $startIndex, [System.StringComparison]::Ordinal)
        if ($endIndex -lt 0) { break }
        $endIndex += $endMarker.Length
        if ($endIndex -lt $Text.Length -and $Text[$endIndex] -eq "`r") { $endIndex++ }
        if ($endIndex -lt $Text.Length -and $Text[$endIndex] -eq "`n") { $endIndex++ }
        if ($startIndex -gt 0) {
            if ($startIndex -ge 2 -and $Text.Substring($startIndex - 2, 2) -eq "`r`n") {
                $startIndex -= 2
            }
            elseif ($Text[$startIndex - 1] -eq "`n") {
                $startIndex -= 1
            }
        }
        $Text = $Text.Remove($startIndex, $endIndex - $startIndex)
    }
    return $Text
}

function New-OpenPathControlPlaneValveBlock {
    <#
    .SYNOPSIS
    Renders the marked valve block with CRLF line endings and no BOM.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Lines)

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('# BEGIN OpenPath control-plane valve')
    [void]$builder.Append("`r`n")
    foreach ($line in @($Lines)) {
        [void]$builder.Append($line)
        [void]$builder.Append("`r`n")
    }
    [void]$builder.Append('# END OpenPath control-plane valve')
    [void]$builder.Append("`r`n")
    return $builder.ToString()
}

function Set-OpenPathControlPlaneValveHostsBlock {
    <#
    .SYNOPSIS
    Writes the valve block at the top of the hosts file, replacing an existing block.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HostsPath,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    $desiredBlock = New-OpenPathControlPlaneValveBlock -Lines $Lines
    $currentText = Get-OpenPathControlPlaneHostsText -Path $HostsPath
    if ($currentText.StartsWith($desiredBlock, [System.StringComparison]::Ordinal)) {
        return [PSCustomObject]@{ Changed = $false; Success = $true }
    }

    $remainingText = Remove-OpenPathControlPlaneValveBlockFromText -Text $currentText
    $newText = $desiredBlock + $remainingText
    Write-OpenPathControlPlaneHostsText -Path $HostsPath -Text $newText
    return [PSCustomObject]@{ Changed = $true; Success = $true }
}

function Enable-OpenPathControlPlaneValve {
    <#
    .SYNOPSIS
    Activates the host-file control-plane valve from the last-known-good cache.
    .DESCRIPTION
    Fails closed: without a fresh cache the hosts file is untouched and the caller reports
    control_plane_valve_unavailable. The block contains at most eight address/host lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowNull()][object]$Config,
        [string]$OpenPathRoot = '',
        [string]$HostsPath = (Get-OpenPathControlPlaneHostsPath)
    )

    $result = [PSCustomObject]@{
        Activated = $false
        ReasonCode = $null
        ValveHosts = @()
        Detail = ''
    }

    $cache = Read-OpenPathControlPlaneDnsCache -OpenPathRoot $OpenPathRoot
    if (-not $cache.capturedAt -or -not (Test-OpenPathControlPlaneDnsCacheFresh -CapturedAt $cache.capturedAt -MaxAgeDays 30)) {
        $result.ReasonCode = 'control_plane_valve_unavailable'
        $result.Detail = 'No fresh control-plane DNS cache is available'
        return $result
    }

    $lines = @(
        foreach ($hostName in @($cache.hosts.Keys | Sort-Object)) {
            foreach ($address in @($cache.hosts[$hostName])) {
                if (Test-OpenPathControlPlaneIpv4 -Address $address) {
                    "$address $hostName"
                }
            }
        }
    ) | Select-Object -First 8

    if (@($lines).Count -eq 0) {
        $result.ReasonCode = 'control_plane_valve_unavailable'
        $result.Detail = 'The control-plane DNS cache has no usable IPv4 addresses'
        return $result
    }

    try {
        Set-OpenPathControlPlaneValveHostsBlock -HostsPath $HostsPath -Lines @($lines) | Out-Null
    }
    catch {
        Write-OpenPathLog "Could not write the control-plane valve block: $_" -Level WARN
        $result.ReasonCode = 'control_plane_valve_unavailable'
        $result.Detail = [string]$_.Exception.Message
        return $result
    }

    $valveHosts = @(
        foreach ($line in @($lines)) {
            $parts = $line -split '\s+', 2
            if ($parts.Count -eq 2) { $parts[1] }
        }
    ) | Select-Object -Unique

    $state = [PSCustomObject]@{
        mode = 'protected'
        reason = [string]$Reason
        enteredAt = [DateTimeOffset]::UtcNow.ToString('o')
        valveHosts = @($valveHosts)
    }
    Write-OpenPathAtomicJsonFile -Path (Get-OpenPathDnsFailureModeStatePath -OpenPathRoot $OpenPathRoot) -Data $state -Depth 5
    Clear-OpenPathDnsClientCache | Out-Null

    $result.Activated = $true
    $result.ValveHosts = @($valveHosts)
    return $result
}

function Disable-OpenPathControlPlaneValve {
    <#
    .SYNOPSIS
    Removes the control-plane valve block and the failure-mode marker.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = '',
        [string]$HostsPath = (Get-OpenPathControlPlaneHostsPath)
    )

    $result = [PSCustomObject]@{
        Changed = $false
        Success = $true
    }

    if (Test-Path $HostsPath) {
        $currentText = Get-OpenPathControlPlaneHostsText -Path $HostsPath
        $remainingText = Remove-OpenPathControlPlaneValveBlockFromText -Text $currentText
        if ($remainingText -ne $currentText) {
            try {
                Write-OpenPathControlPlaneHostsText -Path $HostsPath -Text $remainingText
                $result.Changed = $true
            }
            catch {
                Write-OpenPathLog "Could not remove the control-plane valve block: $_" -Level WARN
                $result.Success = $false
            }
        }
    }

    $statePath = Get-OpenPathDnsFailureModeStatePath -OpenPathRoot $OpenPathRoot
    if (Test-Path $statePath) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        $result.Changed = $true
    }

    if ($result.Changed) {
        Clear-OpenPathDnsClientCache | Out-Null
    }
    return $result
}

function Enable-OpenPathDnsFailureOpenMode {
    <#
    .SYNOPSIS
    Activates the opt-in fail-open escape hatch for a local DNS proxy failure.
    .DESCRIPTION
    Restores the filtered original DNS configuration and removes the DNS firewall, but
    never touches browser policies. The marker is recorded before the report so a later
    cycle can recover the protected posture once Acrylic is healthy again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowNull()][object]$Config,
        [string]$OpenPathRoot = ''
    )

    $result = [PSCustomObject]@{
        Activated = $false
        ReasonCode = $null
        Detail = ''
    }

    try {
        Restore-OriginalDNS
        $firewallRemoveCommand = Get-Command -Name 'Remove-OpenPathFirewall' -ErrorAction SilentlyContinue
        if (-not $firewallRemoveCommand) {
            $firewallRemoveCommand = Get-Command -Name 'Firewall\Remove-OpenPathFirewall' -ErrorAction SilentlyContinue
        }
        if ($firewallRemoveCommand) {
            & $firewallRemoveCommand | Out-Null
        }
        else {
            Write-OpenPathLog 'Remove-OpenPathFirewall is unavailable; the DNS failure open mode could not remove the firewall' -Level WARN
        }

        $state = [PSCustomObject]@{
            mode = 'open'
            reason = [string]$Reason
            enteredAt = [DateTimeOffset]::UtcNow.ToString('o')
            valveHosts = @()
        }
        Write-OpenPathAtomicJsonFile -Path (Get-OpenPathDnsFailureModeStatePath -OpenPathRoot $OpenPathRoot) -Data $state -Depth 5
        Clear-OpenPathDnsClientCache | Out-Null

        $result.Activated = $true
        $result.ReasonCode = 'fail_open_activated'
    }
    catch {
        $result.Detail = [string]$_.Exception.Message
        Write-OpenPathLog "Could not activate the DNS failure open mode: $_" -Level WARN
    }

    return $result
}

function Close-OpenPathDnsFailureMode {
    <#
    .SYNOPSIS
    Exits the DNS failure mode and restores protected posture unless whitelist fail-open is active.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Config,
        [string]$OpenPathRoot = '',
        [string]$HostsPath = (Get-OpenPathControlPlaneHostsPath),
        [bool]$ProtectedModeSuppressed = $false
    )

    $state = Read-OpenPathDnsFailureModeState -OpenPathRoot $OpenPathRoot
    $wasOpen = [bool]($state -and [string]$state.mode -eq 'open')
    $disableResult = Disable-OpenPathControlPlaneValve -OpenPathRoot $OpenPathRoot -HostsPath $HostsPath
    $restoredProtectedMode = $false

    if ($wasOpen -and -not $ProtectedModeSuppressed -and (Get-Command -Name 'Common\Restore-OpenPathProtectedMode' -ErrorAction SilentlyContinue)) {
        try {
            $restoredProtectedMode = [bool](Common\Restore-OpenPathProtectedMode -Config $Config)
        }
        catch {
            Write-OpenPathLog "Could not restore protected mode after the DNS failure open mode: $_" -Level WARN
        }
    }

    return [PSCustomObject]@{
        WasOpen = $wasOpen
        Changed = [bool]$disableResult.Changed
        RestoredProtectedMode = $restoredProtectedMode
    }
}

function Remove-OpenPathOrphanControlPlaneValve {
    <#
    .SYNOPSIS
    Removes a marked valve block left behind without an active failure-mode marker.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = '',
        [string]$HostsPath = (Get-OpenPathControlPlaneHostsPath)
    )

    if (Read-OpenPathDnsFailureModeState -OpenPathRoot $OpenPathRoot) {
        return $false
    }
    if (-not (Test-Path $HostsPath)) {
        return $false
    }

    $currentText = Get-OpenPathControlPlaneHostsText -Path $HostsPath
    $remainingText = Remove-OpenPathControlPlaneValveBlockFromText -Text $currentText
    if ($remainingText -eq $currentText) {
        return $false
    }

    try {
        Write-OpenPathControlPlaneHostsText -Path $HostsPath -Text $remainingText
        Clear-OpenPathDnsClientCache | Out-Null
        Write-OpenPathLog 'Removed an orphaned control-plane valve block from the hosts file' -Level WARN
        return $true
    }
    catch {
        Write-OpenPathLog "Could not remove the orphaned control-plane valve block: $_" -Level WARN
        return $false
    }
}
