# OpenPath browser common helpers for Windows

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop

function Get-OpenPathBrowserPolicySpecPath {
    # returns the resolved path to the browser policy spec json; checks env override first, then installed path, then source tree
    if ($env:OPENPATH_BROWSER_POLICY_SPEC -and (Test-Path $env:OPENPATH_BROWSER_POLICY_SPEC)) {
        return [string]$env:OPENPATH_BROWSER_POLICY_SPEC
    }

    $installedPath = Join-Path $PSScriptRoot 'browser-policy-spec.json'
    if (Test-Path $installedPath) {
        return $installedPath
    }

    $sourceTreePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\runtime\browser-policy-spec.json'))
    if (Test-Path $sourceTreePath) {
        return $sourceTreePath
    }

    throw "Browser policy spec not found"
}

function Get-OpenPathBrowserPolicySpec {
    # loads and deserializes the browser policy spec from its resolved path
    $specPath = Get-OpenPathBrowserPolicySpecPath
    return Get-Content $specPath -Raw | ConvertFrom-Json -ErrorAction Stop
}

function ConvertTo-OpenPathFileUrl {
    # converts a local or UNC filesystem path into an absolute file:// URI string
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $absolutePath = ''
    if ($Path -match '^[A-Za-z]:[\\/]') {
        $absolutePath = $Path
    }
    else {
        $resolvedPath = Resolve-Path $Path -ErrorAction SilentlyContinue
        $providerPath = if ($resolvedPath) { $resolvedPath.ProviderPath } else { $Path }
        $absolutePath = [System.IO.Path]::GetFullPath($providerPath)
    }

    if ($absolutePath.StartsWith('\')) {
        $uncParts = $absolutePath.TrimStart('\') -split '\\', 2
        $uriBuilder = [System.UriBuilder]::new()
        $uriBuilder.Scheme = [System.Uri]::UriSchemeFile
        $uriBuilder.Host = $uncParts[0]
        $uriBuilder.Path = if ($uncParts.Length -gt 1) { $uncParts[1] -replace '\\', '/' } else { '' }
        return $uriBuilder.Uri.AbsoluteUri
    }

    $uriBuilder = [System.UriBuilder]::new()
    $uriBuilder.Scheme = [System.Uri]::UriSchemeFile
    $uriBuilder.Host = ''
    $uriBuilder.Path = $absolutePath -replace '\\', '/'
    return $uriBuilder.Uri.AbsoluteUri
}

function Write-OpenPathUtf8NoBomFile {
    # writes text to a file with utf-8 encoding and no BOM; creates parent directories if absent
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [string]$Value
    )

    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Get-OpenPathConfigTrimmedValue {
    # returns the trimmed string value of a named config property, or empty string when absent or null
    param(
        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if (
        $Config -and
        $Config.PSObject.Properties[$PropertyName] -and
        $Config.PSObject.Properties[$PropertyName].Value
    ) {
        return ([string]$Config.PSObject.Properties[$PropertyName].Value).Trim()
    }

    return ''
}

function ConvertTo-OpenPathRegistryProviderPath {
    # converts an HKLM\ registry path string into the PowerShell Registry:: provider path form
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    if ($RegistryPath -match '^HKLM\\') {
        return "Registry::HKEY_LOCAL_MACHINE\\$($RegistryPath.Substring(5))"
    }

    throw "Unsupported registry hive path: $RegistryPath"
}

function Remove-OpenPathRegistryKeyIfPresent {
    # silently removes a registry key and all its children; does nothing if the key does not exist
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    $providerPath = ConvertTo-OpenPathRegistryProviderPath -RegistryPath $RegistryPath
    if (Test-Path $providerPath) {
        Remove-Item -Path $providerPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathScheduledTaskSecurityDescriptor {
    # returns the SDDL security descriptor string for a named scheduled task, or null on any error
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    try {
        $schedule = New-Object -ComObject 'Schedule.Service'
        $schedule.Connect()
        $task = $schedule.GetFolder('\').GetTask($TaskName)
        return [string]$task.GetSecurityDescriptor(0xF)
    }
    catch {
        return $null
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserPolicySpecPath',
    'Get-OpenPathBrowserPolicySpec',
    'ConvertTo-OpenPathFileUrl',
    'Write-OpenPathUtf8NoBomFile',
    'Get-OpenPathConfigTrimmedValue',
    'ConvertTo-OpenPathRegistryProviderPath',
    'Remove-OpenPathRegistryKeyIfPresent',
    'Get-OpenPathScheduledTaskSecurityDescriptor'
)
