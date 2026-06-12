function Resolve-OpenPathWindowsRoot {
    # returns the OpenPath installation root, preferring the explicit $OpenPathRoot argument, then OPENPATH_WINDOWS_ROOT, then OPENPATH_ROOT env vars, defaulting to C:\OpenPath.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$OpenPathRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($OpenPathRoot)) {
        return $OpenPathRoot.TrimEnd('\')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENPATH_WINDOWS_ROOT)) {
        return ([string]$env:OPENPATH_WINDOWS_ROOT).TrimEnd('\')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENPATH_ROOT)) {
        return ([string]$env:OPENPATH_ROOT).TrimEnd('\')
    }

    return 'C:\OpenPath'
}
