function Get-OpenPathCapabilityStorageRoot {
    [CmdletBinding()]
    param([string]$OpenPathRoot = '')

    if ([string]::IsNullOrWhiteSpace($OpenPathRoot)) {
        $OpenPathRoot = if ($script:OpenPathRoot) { $script:OpenPathRoot } else { 'C:\OpenPath' }
    }

    if ($OpenPathRoot -match '^[A-Za-z]:\\' -and -not (Test-Path ([System.IO.Path]::GetPathRoot($OpenPathRoot)) -ErrorAction SilentlyContinue)) {
        return "$OpenPathRoot\data"
    }

    return (Join-Path $OpenPathRoot 'data')
}

function Join-OpenPathCapabilityStoragePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    if ($Parent -match '^[A-Za-z]:\\' -and -not (Test-Path ([System.IO.Path]::GetPathRoot($Parent)) -ErrorAction SilentlyContinue)) {
        return "$Parent\$Child"
    }

    return (Join-Path $Parent $Child)
}

function Get-OpenPathCapabilityStoragePath {
    [CmdletBinding()]
    param(
        [ValidateSet(
            'RuntimeDependencyQueue',
            'CaptivePortalRecoveryQueue',
            'CaptivePortalRecoveryResult',
            'CaptivePortalRecoveryProgress',
            'RuntimeDependencyOverlay',
            'RuntimeDependencyOverlayParent',
            'FirefoxNativeHostRoot',
            'FirefoxNativeHostState',
            'FirefoxNativeHostWhitelistMirror'
        )]
        [string]$Name,

        [string]$OpenPathRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($OpenPathRoot)) {
        $OpenPathRoot = if ($script:OpenPathRoot) { $script:OpenPathRoot } else { 'C:\OpenPath' }
    }

    switch ($Name) {
        'RuntimeDependencyQueue' {
            if ($env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH) {
                return $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH
            }
            return (Join-OpenPathCapabilityStoragePath -Parent (Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot) -Child 'runtime-dependency-queue')
        }
        'CaptivePortalRecoveryQueue' {
            return (Join-OpenPathCapabilityStoragePath -Parent (Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot) -Child 'captive-portal-recovery-queue')
        }
        'CaptivePortalRecoveryResult' {
            return (Join-OpenPathCapabilityStoragePath -Parent (Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot) -Child 'captive-portal-recovery-result')
        }
        'CaptivePortalRecoveryProgress' {
            if ($env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH) {
                return $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH
            }
            return (Join-OpenPathCapabilityStoragePath -Parent (Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot) -Child 'captive-portal-recovery-progress')
        }
        'RuntimeDependencyOverlay' {
            if ($env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH) {
                return $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
            }
            return (Join-OpenPathCapabilityStoragePath -Parent (Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot) -Child 'runtime-dependency-overlay.json')
        }
        'RuntimeDependencyOverlayParent' {
            return (Split-Path (Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $OpenPathRoot) -Parent)
        }
        'FirefoxNativeHostRoot' {
            return (Join-OpenPathCapabilityStoragePath -Parent $OpenPathRoot -Child 'browser-extension\firefox\native')
        }
        'FirefoxNativeHostState' {
            return (Join-OpenPathCapabilityStoragePath -Parent (Get-OpenPathCapabilityStoragePath -Name FirefoxNativeHostRoot -OpenPathRoot $OpenPathRoot) -Child 'native-state.json')
        }
        'FirefoxNativeHostWhitelistMirror' {
            return (Join-OpenPathCapabilityStoragePath -Parent (Get-OpenPathCapabilityStoragePath -Name FirefoxNativeHostRoot -OpenPathRoot $OpenPathRoot) -Child 'whitelist.txt')
        }
    }
}

function New-OpenPathCapabilityStorageAccessRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$Rights
    )

    return (New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Identity,
            $Rights,
            'ContainerInherit,ObjectInherit',
            'None',
            'Allow'
        ))
}

function Set-OpenPathCapabilityStorageAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('RestrictedRoot', 'RuntimeDependencyQueue', 'CaptivePortalRecoveryQueue', 'CaptivePortalRecoveryResultRead', 'BrowserExtensionRead')]
        [string]$Profile = 'RestrictedRoot'
    )

    $acl = Get-Acl $Path
    if ($Profile -eq 'RestrictedRoot') {
        $acl.SetAccessRuleProtection($true, $false)
        @($acl.Access) | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'NT AUTHORITY\SYSTEM' -Rights 'FullControl'))
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Administrators' -Rights 'FullControl'))
    }
    elseif ($Profile -eq 'RuntimeDependencyQueue') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'Modify'))
    }
    elseif ($Profile -eq 'CaptivePortalRecoveryQueue') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'Modify'))
    }
    elseif ($Profile -eq 'CaptivePortalRecoveryResultRead') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'ReadAndExecute'))
    }
    elseif ($Profile -eq 'BrowserExtensionRead') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'ReadAndExecute'))
    }

    Set-Acl $Path $acl
}

function Test-OpenPathCapabilityStorageAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('RestrictedRoot', 'RuntimeDependencyQueue', 'CaptivePortalRecoveryQueue', 'CaptivePortalRecoveryResultRead', 'BrowserExtensionRead')]
        [string]$Profile = 'RestrictedRoot'
    )

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return $false }

    $acl = Get-Acl $Path
    $rules = @($acl.Access)
    if ($Profile -eq 'RestrictedRoot') {
        $hasSystem = @($rules | Where-Object {
                ([string]$_.IdentityReference) -eq 'NT AUTHORITY\SYSTEM' -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl)
            }).Count -gt 0
        $hasAdmins = @($rules | Where-Object {
                ([string]$_.IdentityReference) -eq 'BUILTIN\Administrators' -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl)
            }).Count -gt 0
        return ($hasSystem -and $hasAdmins)
    }

    $expectedRight = if ($Profile -in @('RuntimeDependencyQueue', 'CaptivePortalRecoveryQueue')) {
        [System.Security.AccessControl.FileSystemRights]::Modify
    }
    else {
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    }

    return (@($rules | Where-Object {
                ([string]$_.IdentityReference) -eq 'BUILTIN\Users' -and
                ($_.FileSystemRights -band $expectedRight)
            }).Count -gt 0)
}

function Ensure-OpenPathCapabilityStorageDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('None', 'RestrictedRoot', 'RuntimeDependencyQueue', 'CaptivePortalRecoveryQueue', 'CaptivePortalRecoveryResultRead', 'BrowserExtensionRead')]
        [string]$AclProfile = 'None',
        [switch]$ValidateAcl
    )

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    if ($AclProfile -ne 'None') {
        Set-OpenPathCapabilityStorageAcl -Path $Path -Profile $AclProfile
        if ($ValidateAcl -and -not (Test-OpenPathCapabilityStorageAcl -Path $Path -Profile $AclProfile)) {
            throw "Capability storage ACL validation failed for $Path ($AclProfile)"
        }
    }

    return $Path
}
