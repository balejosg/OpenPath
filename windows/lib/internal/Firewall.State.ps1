function Get-OpenPathFirewallManifestPath {
    return 'C:\OpenPath\data\firewall-rules.json'
}

function ConvertTo-OpenPathFirewallManifestRuleNames {
    param([object]$Value)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }

        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        foreach ($name in @($text -split '\s+' | Where-Object { $_ })) {
            [void]$names.Add([string]$name)
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-OpenPathFirewallManifestRuleNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }

    try {
        $parsed = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return ConvertTo-OpenPathFirewallManifestRuleNames -Value $parsed
    }
    catch {
        Write-OpenPathLog "Ignoring unreadable firewall manifest at $Path; falling back to OpenPath firewall rule discovery. $_" -Level WARN
        return @()
    }
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

function Add-OpenPathFirewallManifestRule {
    param([Parameter(Mandatory = $true)][string]$Name)

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
        [string]$Action,
        [string]$Profile,
        [string]$Description,
        [string]$Program
    )

    $ruleParameters = @{
        DisplayName = $DisplayName
        Group = 'OpenPath'
    }
    foreach ($key in @('Direction', 'Protocol', 'RemoteAddress', 'RemotePort', 'Action', 'Profile', 'Description', 'Program')) {
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
        $manifestPath = Get-OpenPathFirewallManifestPath
        foreach ($ruleName in @(Get-OpenPathFirewallManifestRuleNames -Path $manifestPath)) {
            Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)
        }

        if (Test-Path $manifestPath) {
            Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
        }

        Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -Group 'OpenPath' -ErrorAction SilentlyContinue)

        Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -DisplayName "$script:RulePrefix-*" -ErrorAction SilentlyContinue)

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
