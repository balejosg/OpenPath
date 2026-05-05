# OpenPath Script Bootstrap Module for Windows
# Centralizes standalone script initialization for PowerShell entrypoints.

function Initialize-OpenPathScriptSession {
    <#
    .SYNOPSIS
        Imports OpenPath modules for a standalone script session and validates required commands.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [string[]]$DependentModules = @(),

        [string[]]$RequiredCommands = @(),

        [string]$ScriptName = 'OpenPath script'
    )

    $orderedModules = @($DependentModules)
    if ($orderedModules -contains 'Firewall') {
        $orderedModules = @($orderedModules | Where-Object { $_ -ne 'Firewall' })
        $insertAfter = -1
        for ($index = 0; $index -lt $orderedModules.Count; $index++) {
            if ($orderedModules[$index] -in @('Browser', 'CaptivePortal')) {
                $insertAfter = $index
            }
        }

        if ($insertAfter -lt 0 -or $insertAfter -ge ($orderedModules.Count - 1)) {
            $orderedModules = @($orderedModules) + @('Firewall')
        }
        else {
            $orderedModules = @($orderedModules[0..$insertAfter]) + @('Firewall') + @($orderedModules[($insertAfter + 1)..($orderedModules.Count - 1)])
        }
    }

    foreach ($moduleName in @($orderedModules)) {
        if (-not $moduleName -or $moduleName -in @('Common', 'ScriptBootstrap')) {
            continue
        }

        Import-Module (Join-Path $OpenPathRoot "lib\$moduleName.psm1") -Force -Global
    }

    # Import Common globally after dependent modules so exported helpers stay
    # visible in standalone script sessions. Avoid -Force here: reloading
    # Common unloads modules that depend on it in the same session.
    Import-Module (Join-Path $OpenPathRoot 'lib\Common.psm1') -Global

    $missingCommands = @(
        $RequiredCommands | Where-Object {
            -not (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }
    )

    if ($missingCommands.Count -gt 0) {
        throw "$ScriptName failed to import required commands: $($missingCommands -join ', ')"
    }

    return $true
}

Export-ModuleMember -Function @(
    'Initialize-OpenPathScriptSession'
)
