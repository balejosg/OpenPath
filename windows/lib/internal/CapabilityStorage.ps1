function Get-OpenPathCapabilityStorageRoot {
    # returns the data subdirectory under $OpenPathRoot, using the script-level root or C:\OpenPath as a fallback.
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
    # joins two path segments; uses string concatenation when $Parent is on a drive root that does not exist on the current host.
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
    # resolves the canonical filesystem path for the named capability store slot; env overrides take precedence for testability.
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
    # constructs a FileSystemAccessRule granting $Rights to $Identity with container/object inheritance for directories or None for files.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$Rights,
        [string]$InheritanceFlags = 'ContainerInherit,ObjectInherit',
        [string]$PropagationFlags = 'None'
    )

    $identityReference = if ($Identity -match '^S-\d-\d+(?:-\d+)+$') {
        New-Object System.Security.Principal.SecurityIdentifier($Identity)
    }
    else {
        New-Object System.Security.Principal.NTAccount($Identity)
    }
    $rightsValue = [System.Enum]::Parse([System.Security.AccessControl.FileSystemRights], $Rights)
    $inheritanceValue = [System.Enum]::Parse([System.Security.AccessControl.InheritanceFlags], $InheritanceFlags)
    $propagationValue = [System.Enum]::Parse([System.Security.AccessControl.PropagationFlags], $PropagationFlags)

    return [System.Security.AccessControl.FileSystemAccessRule]::new(
        $identityReference,
        $rightsValue,
        $inheritanceValue,
        $propagationValue,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
}

function Set-OpenPathCapabilityStorageAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('RestrictedRoot', 'RuntimeDependencyQueue', 'CaptivePortalRecoveryQueue', 'CaptivePortalRecoveryResultRead', 'BrowserExtensionRead')]
        [string]$Profile = 'RestrictedRoot'
    )

    $isContainer = (Test-Path -Path $Path -PathType Container -ErrorAction SilentlyContinue)
    $inheritanceFlags = if ($isContainer) { 'ContainerInherit,ObjectInherit' } else { 'None' }

    if ($Profile -eq 'RestrictedRoot') {
        # Use the inbox Windows ACL tool for the restricted profile. It accepts
        # portable SIDs directly and avoids PowerShell/.NET descriptor behavior
        # differences across Windows PowerShell and PowerShell 7.
        $icaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (-not (Test-Path -LiteralPath $icaclsPath -PathType Leaf)) {
            throw 'Windows ACL tool is unavailable'
        }
        $icaclsArguments = @(
            $Path,
            '/inheritance:r',
            '/grant:r',
            '*S-1-5-18:(F)',
            '*S-1-5-32-544:(F)'
        )
        & $icaclsPath @icaclsArguments 2>$null | Out-Null
        $icaclsExitCode = $LASTEXITCODE
        if ($icaclsExitCode -ne 0) {
            throw "Windows ACL tool failed with exit code $icaclsExitCode"
        }
        return
    }

    $acl = Get-Acl $Path
    if ($Profile -eq 'RuntimeDependencyQueue') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'Modify' -InheritanceFlags $inheritanceFlags))
    }
    elseif ($Profile -eq 'CaptivePortalRecoveryQueue') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'Modify' -InheritanceFlags $inheritanceFlags))
    }
    elseif ($Profile -eq 'CaptivePortalRecoveryResultRead') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'ReadAndExecute' -InheritanceFlags $inheritanceFlags))
    }
    elseif ($Profile -eq 'BrowserExtensionRead') {
        $acl.AddAccessRule((New-OpenPathCapabilityStorageAccessRule -Identity 'BUILTIN\Users' -Rights 'ReadAndExecute' -InheritanceFlags $inheritanceFlags))
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
