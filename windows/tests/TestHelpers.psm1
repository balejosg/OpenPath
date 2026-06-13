# Shared OpenPath Windows Pester helpers

$script:modulePath = Join-Path $PSScriptRoot ".." "lib"

# Must be at module scope so -Skip checks can use the helpers during discovery.
function Test-FunctionExists {
    param([string]$FunctionName)
    return $null -ne (Get-Command -Name $FunctionName -ErrorAction SilentlyContinue)
}

function Test-IsAdmin {
    if (-not (Test-FunctionExists 'Test-AdminPrivileges')) {
        Import-OpenPathTestModules -ModuleNames @('Common')
    }

    if (Test-FunctionExists 'Test-AdminPrivileges') {
        return Test-AdminPrivileges
    }

    return $false
}

function Import-OpenPathTestModules {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ModuleNames
    )

    foreach ($moduleName in $ModuleNames) {
        $moduleFilePath = Join-Path $script:modulePath "$moduleName.psm1"
        Import-Module $moduleFilePath -Force -Global -ErrorAction Stop
    }
}

function Assert-ContentContainsAll {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string[]]$Needles
    )

    foreach ($needle in $Needles) {
        $Content.Contains($needle) | Should -BeTrue -Because "Expected content to include '$needle'"
    }
}

function Initialize-FirewallRuleCaptureMocks {
    $script:createdFirewallRules = @()
    $script:acrylicServicePresent = $false

    if (-not (Get-Command -Name New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        function global:New-NetFirewallRule { }
    }

    Mock Test-AdminPrivileges { $true } -ModuleName Firewall
    Mock Write-OpenPathLog { } -ModuleName Firewall
    Mock Remove-OpenPathFirewall { $true } -ModuleName Firewall

    Mock New-NetFirewallRule {
        param(
            [string]$DisplayName,
            [string]$Direction,
            [string]$Protocol,
            [object]$RemoteAddress,
            [object]$RemotePort,
            [object]$LocalAddress,
            [object]$LocalPort,
            [string]$Action,
            [string]$Profile,
            [string]$Description,
            [string]$Program
        )

        $script:createdFirewallRules += [PSCustomObject]@{
            DisplayName = $DisplayName
            Direction = $Direction
            Protocol = $Protocol
            RemoteAddress = [string]$RemoteAddress
            RemotePort = [string]$RemotePort
            LocalAddress = [string]$LocalAddress
            LocalPort = [string]$LocalPort
            Action = $Action
            Program = $Program
        }

        return [PSCustomObject]@{ DisplayName = $DisplayName }
    } -ModuleName Firewall

    Mock Test-Path { $script:acrylicServicePresent } -ModuleName Firewall -ParameterFilter { $Path -like '*AcrylicService.exe' }
}

function Get-CapturedFirewallRules {
    return @($script:createdFirewallRules)
}

function Set-FirewallAcrylicServicePresent {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Present
    )

    $script:acrylicServicePresent = $Present
}

function Get-ContractFixturePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $contractsDir = Join-Path $PSScriptRoot '..' '..' 'tests' 'contracts'
    $fixturePath = Join-Path $contractsDir $FileName

    if (-not (Test-Path $fixturePath)) {
        throw "Contract fixture not found: $fixturePath"
    }

    return $fixturePath
}

function Get-ContractFixtureLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $fixturePath = Get-ContractFixturePath -FileName $FileName
    return @(
        Get-Content $fixturePath -ErrorAction Stop |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

function Get-ContractFixtureJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $fixturePath = Get-ContractFixturePath -FileName $FileName
    return Get-Content $fixturePath -Raw | ConvertFrom-Json -ErrorAction Stop
}

Export-ModuleMember -Function @(
    'Test-FunctionExists',
    'Test-IsAdmin',
    'Import-OpenPathTestModules',
    'Assert-ContentContainsAll',
    'Initialize-FirewallRuleCaptureMocks',
    'Get-CapturedFirewallRules',
    'Set-FirewallAcrylicServicePresent',
    'Get-ContractFixturePath',
    'Get-ContractFixtureLines',
    'Get-ContractFixtureJson'
)
