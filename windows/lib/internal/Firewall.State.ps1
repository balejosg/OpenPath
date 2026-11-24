function Get-OpenPathFirewallManifestPath {
    return 'C:\OpenPath\data\firewall-rules.json'
}

$script:FirewallManifestBatch = $null
$script:FirewallManifestBatchPath = ''

function Get-OpenPathFirewallManifestRuleNames {
    # Logging wrapper over Read-OpenPathFirewallManifestRuleNames (Firewall.Teardown.ps1).
    param([Parameter(Mandatory = $true)][string]$Path)

    $manifest = Read-OpenPathFirewallManifestRuleNames -Path $Path
    if ($manifest.Error) {
        Write-OpenPathLog "Ignoring unreadable firewall manifest at $Path; falling back to OpenPath firewall rule discovery. $($manifest.Error)" -Level WARN
    }
    return @($manifest.Names)
}

function Set-OpenPathFirewallManifestRuleNames {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $normalizedNames = @(ConvertTo-OpenPathFirewallManifestRuleNames -Value $Names)
    $json = ConvertTo-Json -InputObject $normalizedNames -Depth 3
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"

    try {
        $json | Set-Content -Path $temporaryPath -Encoding UTF8 -Force
        Move-Item -Path $temporaryPath -Destination $Path -Force
    }
    finally {
        Remove-Item -Path $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-OpenPathFirewallManifestBatch {
    <#
    .SYNOPSIS
        Starts a manifest write batch for a multi-rule apply.
    .DESCRIPTION
        Returns $true when this call owns the batch. A nested call returns $false and joins
        the active batch, so only the owner writes the manifest and clears the batch.
    #>
    param([string]$Path)

    if ($null -ne $script:FirewallManifestBatch) { return $false }
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-OpenPathFirewallManifestPath }
    $script:FirewallManifestBatch = [System.Collections.Generic.List[string]]::new()
    $script:FirewallManifestBatchPath = [string]$Path
    return $true
}

function Complete-OpenPathFirewallManifestBatch {
    <#
    .SYNOPSIS
        Writes the names buffered by Start-OpenPathFirewallManifestBatch once and clears it.
    .DESCRIPTION
        Merges the buffered names with any manifest written in the meantime, writes one sorted
        JSON array, and never throws: a failure is logged and the caller keeps its result.
    #>
    param([string]$Path)

    if ($null -eq $script:FirewallManifestBatch) { return }
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string]$script:FirewallManifestBatchPath }
    $buffered = @($script:FirewallManifestBatch)
    $script:FirewallManifestBatch = $null
    $script:FirewallManifestBatchPath = ''

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $existing = @()
        if (Test-Path $Path) {
            $existing = @(Get-OpenPathFirewallManifestRuleNames -Path $Path)
        }
        $names = @($existing + $buffered | Where-Object { $_ } | Sort-Object -Unique)
        if ($names.Count -eq 0) { return }

        $directory = Split-Path $Path -Parent
        if ($directory -match '^([A-Za-z]):[\\/]' -and -not (Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue)) {
            return
        }
        if ($directory -and -not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        Set-OpenPathFirewallManifestRuleNames -Path $Path -Names $names
    }
    catch {
        Write-OpenPathLog "Failed to write firewall manifest batch: $_" -Level WARN
    }
}

function Add-OpenPathFirewallManifestRule {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($null -ne $script:FirewallManifestBatch) {
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $script:FirewallManifestBatch.Add($Name)
        }
        return
    }

    try {
        $path = Get-OpenPathFirewallManifestPath
        $directory = Split-Path $path -Parent
        if ($directory -match '^([A-Za-z]):[\\/]' -and -not (Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue)) {
            return
        }
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $names = @()
        if (Test-Path $path) {
            $names = @(Get-OpenPathFirewallManifestRuleNames -Path $path)
        }
        $names = @($names + $Name | Where-Object { $_ } | Sort-Object -Unique)
        Set-OpenPathFirewallManifestRuleNames -Path $path -Names $names
    }
    catch {
        Write-OpenPathLog "Failed to update firewall manifest: $_" -Level WARN
    }
}

function New-OpenPathFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$Direction,
        [string]$Protocol,
        [object]$RemoteAddress,
        [object]$RemotePort,
        [object]$LocalAddress,
        [object]$LocalPort,
        [string]$Action,
        [string]$Profile,
        [string]$Description,
        [string]$Program,
        [string]$LocalUser,
        [string]$Package,
        [string]$Service
    )

    $ruleParameters = @{
        DisplayName = $DisplayName
        Group = 'OpenPath'
    }
    foreach ($key in @('Direction', 'Protocol', 'RemoteAddress', 'RemotePort', 'LocalAddress', 'LocalPort', 'Action', 'Profile', 'Description', 'Program', 'LocalUser', 'Package', 'Service')) {
        if ($PSBoundParameters.ContainsKey($key) -and $null -ne $PSBoundParameters[$key] -and [string]$PSBoundParameters[$key] -ne '') {
            $ruleParameters[$key] = $PSBoundParameters[$key]
        }
    }

    $rule = New-NetFirewallRule @ruleParameters
    Add-OpenPathFirewallManifestRule -Name $DisplayName
    return $rule
}

function Remove-OpenPathFirewallRuleObjects {
    param([object[]]$Rules)

    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }

        $rule | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
}

function Remove-OpenPathFirewall {
    <#
    .SYNOPSIS
        Removes all whitelist firewall rules
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Remove OpenPath firewall rules')) {
        return $false
    }

    Write-OpenPathLog 'Removing openpath firewall rules...'

    try {
        # Brick-guard: if the outbound egress floor previously flipped each profile's
        # DefaultOutboundAction to Block, a full firewall teardown that only deletes rules
        # would leave the default at Block with no Allow exceptions == all egress bricked.
        # Restore the persisted pre-floor outbound default (fallback Allow) FIRST. No-op
        # when the floor was never enabled (no state file -> restores to Allow harmlessly).
        if (Get-Command -Name 'Restore-OpenPathEgressFloorPreviousOutbound' -ErrorAction SilentlyContinue) {
            Restore-OpenPathEgressFloorPreviousOutbound
        }
        if (Get-Command -Name 'Disable-OpenPathEgressFloorAudit' -ErrorAction SilentlyContinue) {
            Disable-OpenPathEgressFloorAudit
        }

        # Rule removal (manifest names, then group OpenPath, then the prefix) lives in the
        # Firewall.Teardown.ps1 leaf; failures are ignored here, as before.
        $manifestPath = Get-OpenPathFirewallManifestPath
        $ruleRemoval = Remove-OpenPathFirewallOwnedRules -ManifestPath $manifestPath -RulePrefix $script:RulePrefix -RemoveManifest
        if ($ruleRemoval.ManifestError) {
            Write-OpenPathLog "Ignoring unreadable firewall manifest at $manifestPath; falling back to OpenPath firewall rule discovery. $($ruleRemoval.ManifestError)" -Level WARN
        }

        Write-OpenPathLog 'Firewall rules removed'
        return $true
    }
    catch {
        Write-OpenPathLog "Error removing firewall rules: $_" -Level WARN
        return $false
    }
}

function Test-FirewallActive {
    <#
    .SYNOPSIS
        Checks if whitelist firewall rules are active
    #>
    $rules = Get-NetFirewallRule -DisplayName "$script:RulePrefix-*" -ErrorAction SilentlyContinue
    $blockRules = $rules | Where-Object { $_.Action -eq 'Block' -and $_.Enabled -eq $true }
    return ($blockRules.Count -ge 2)
}

function Get-FirewallStatus {
    <#
    .SYNOPSIS
        Gets detailed status of whitelist firewall rules
    #>
    $rules = Get-NetFirewallRule -DisplayName "$script:RulePrefix-*" -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        TotalRules  = $rules.Count
        EnabledRules = ($rules | Where-Object Enabled).Count
        BlockRules  = ($rules | Where-Object { $_.Action -eq 'Block' }).Count
        AllowRules  = ($rules | Where-Object { $_.Action -eq 'Allow' }).Count
        Active      = (Test-FirewallActive)
    }
}

function Disable-OpenPathFirewall {
    <#
    .SYNOPSIS
        Temporarily disables whitelist firewall rules without removing them
    #>
    Write-OpenPathLog 'Disabling openpath firewall rules...'

    try {
        # Brick-guard: disabling the egress floor's non-student Allow while each profile's
        # DefaultOutboundAction is still Block would cut egress for every user. Tear the
        # floor down first (restores the pre-floor default and audit setting); the next
        # enable/update reapplies it from configuration.
        if (Get-Command -Name 'Remove-OpenPathEgressFloorRules' -ErrorAction SilentlyContinue) {
            Remove-OpenPathEgressFloorRules -RestoreDefaultOutbound $true
        }

        Get-NetFirewallRule -DisplayName "$script:RulePrefix-*" -ErrorAction SilentlyContinue |
            Disable-NetFirewallRule -ErrorAction SilentlyContinue

        Write-OpenPathLog 'Firewall rules disabled'
        return $true
    }
    catch {
        Write-OpenPathLog "Error disabling firewall rules: $_" -Level WARN
        return $false
    }
}

function Enable-OpenPathFirewall {
    <#
    .SYNOPSIS
        Re-enables whitelist firewall rules
    #>
    Write-OpenPathLog 'Enabling openpath firewall rules...'

    try {
        Get-NetFirewallRule -DisplayName "$script:RulePrefix-*" -ErrorAction SilentlyContinue |
            Enable-NetFirewallRule -ErrorAction SilentlyContinue

        Write-OpenPathLog 'Firewall rules enabled'
        return $true
    }
    catch {
        Write-OpenPathLog "Error enabling firewall rules: $_" -Level WARN
        return $false
    }
}
