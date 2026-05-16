function Get-OpenPathFirewallManifestPath {
    return 'C:\OpenPath\data\firewall-rules.json'
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
            $names = @(Get-Content $path -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ })
        }
        $names = @($names + $Name | Where-Object { $_ } | Sort-Object -Unique)
        $names | ConvertTo-Json -Depth 3 | Set-Content -Path $path -Encoding UTF8
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
        if (Test-Path $manifestPath) {
            @(Get-Content $manifestPath -Raw | ConvertFrom-Json | ForEach-Object { [string]$_ }) |
                Where-Object { $_ } |
                ForEach-Object {
                    Get-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue |
                        Remove-NetFirewallRule -ErrorAction SilentlyContinue
                }
            Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
        }

        Get-NetFirewallRule -Group 'OpenPath' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

        Get-NetFirewallRule -DisplayName "$script:RulePrefix-*" -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

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
