function ConvertTo-OpenPathInstallerRegistryProviderPath {
    <#
    .SYNOPSIS
        Converts an HKLM registry path string to the PowerShell Registry:: provider form accepted by path and item cmdlets
    .PARAMETER RegistryPath
        Registry path beginning with HKLM:\ or HKLM\
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    if ($RegistryPath -match '^HKLM:\\') {
        return "Registry::HKEY_LOCAL_MACHINE\$($RegistryPath.Substring(6))"
    }
    if ($RegistryPath -match '^HKLM\\') {
        return "Registry::HKEY_LOCAL_MACHINE\$($RegistryPath.Substring(5))"
    }

    throw "Unsupported registry hive path: $RegistryPath"
}

function Test-OpenPathInstallerRegistryPath {
    <#
    .SYNOPSIS
        Returns true when the given registry path exists, converting it to the provider form first
    .PARAMETER RegistryPath
        Registry path to test
    #>
    param([Parameter(Mandatory = $true)][string]$RegistryPath)

    try {
        return (Test-Path (ConvertTo-OpenPathInstallerRegistryProviderPath -RegistryPath $RegistryPath))
    }
    catch {
        return $false
    }
}

function Remove-OpenPathInstallerRegistryKeyIfPresent {
    <#
    .SYNOPSIS
        Deletes a registry key and all subkeys if it exists; silently succeeds when the key is already absent
    .PARAMETER RegistryPath
        Registry path to remove
    #>
    param([Parameter(Mandatory = $true)][string]$RegistryPath)

    $providerPath = ConvertTo-OpenPathInstallerRegistryProviderPath -RegistryPath $RegistryPath
    if (Test-Path $providerPath) {
        Remove-Item -Path $providerPath -Recurse -Force -ErrorAction Stop
    }
}

function Test-OpenPathExistingInstallation {
    <#
    .SYNOPSIS
        Returns true when evidence of a previous OpenPath installation is found, including scheduled tasks, firewall rules, AppLocker rules, browser policies, or registry keys
    .PARAMETER OpenPathRoot
        Root directory to check for an existing installation
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot
    )

    if (Test-Path $OpenPathRoot) {
        return $true
    }

    if (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $tasks = @(Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue)
        if ($tasks.Count -gt 0) { return $true }
    }

    if (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        $rules = @(Get-NetFirewallRule -DisplayName 'OpenPath-DNS-*' -ErrorAction SilentlyContinue)
        if ($rules.Count -gt 0) { return $true }
    }

    if (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
        try {
            $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
            $rules = @($policyXml.AppLockerPolicy.RuleCollection.FilePathRule)
            if (@($rules | Where-Object {
                        $null -ne $_ -and
                        $_ -is [System.Xml.XmlElement] -and
                        $_.GetAttribute('Name') -like 'OpenPath non-admin app control*'
                    }).Count -gt 0) {
                return $true
            }
        }
        catch {
        }
    }

    $browserArtifacts = @(
        "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json"
    )
    foreach ($artifactPath in $browserArtifacts) {
        if ($artifactPath -and (Test-Path $artifactPath)) { return $true }
    }

    $registryArtifacts = @(
        'HKLM\SOFTWARE\Mozilla\NativeMessagingHosts\whitelist_native_host',
        'HKLM\SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host',
        'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist',
        'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
    )
    foreach ($registryPath in $registryArtifacts) {
        if (Test-OpenPathInstallerRegistryPath -RegistryPath $registryPath) { return $true }
    }

    return $false
}

function Copy-OpenPathInstallerSourceForReinstall {
    <#
    .SYNOPSIS
        Copies the installer source to a temporary directory when it lives inside the install root, so the reinstall can proceed after the root is removed
    .PARAMETER ScriptDir
        Directory containing the running installer package
    .PARAMETER OpenPathRoot
        Root installation directory; if ScriptDir is beneath this, a snapshot is created
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptDir,

        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot
    )

    $sourcePath = [System.IO.Path]::GetFullPath($ScriptDir).TrimEnd('\')
    $installRootPath = [System.IO.Path]::GetFullPath($OpenPathRoot).TrimEnd('\')
    if (-not $sourcePath.StartsWith($installRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $ScriptDir
    }

    $snapshotRoot = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-reinstall-source-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null

    foreach ($directoryName in @('lib', 'scripts', 'browser-extension', 'runtime')) {
        $sourceDirectory = Join-Path $ScriptDir $directoryName
        if (Test-Path $sourceDirectory) {
            Copy-Item $sourceDirectory -Destination $snapshotRoot -Recurse -Force -ErrorAction Stop
        }
    }

    foreach ($fileName in @('Install-OpenPath.ps1', 'Uninstall-OpenPath.ps1', 'OpenPath.ps1', 'Rotate-Token.ps1')) {
        $sourceFile = Join-Path $ScriptDir $fileName
        if (Test-Path $sourceFile) {
            Copy-Item $sourceFile -Destination (Join-Path $snapshotRoot $fileName) -Force -ErrorAction Stop
        }
    }

    $runtimePolicySpec = Join-Path $snapshotRoot 'runtime\browser-policy-spec.json'
    $installedPolicySpec = Join-Path $ScriptDir 'lib\browser-policy-spec.json'
    if ((-not (Test-Path $runtimePolicySpec)) -and (Test-Path $installedPolicySpec)) {
        $runtimeDirectory = Split-Path $runtimePolicySpec -Parent
        New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
        Copy-Item $installedPolicySpec -Destination $runtimePolicySpec -Force -ErrorAction Stop
    }

    return $snapshotRoot
}

function Stop-OpenPathInstallerScheduledTasks {
    <#
    .SYNOPSIS
        Stops and unregisters all OpenPath scheduled tasks matching the OpenPath-* pattern
    #>
    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) { return }
    $tasks = @(Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue)
    foreach ($task in $tasks) {
        Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
    }
}

function Stop-OpenPathInstallerRootedProcess {
    <#
    .SYNOPSIS
        Forcibly terminates any running process whose executable path starts with OpenPathRoot
    .PARAMETER OpenPathRoot
        Root directory; processes running from within it are stopped
    #>
    param([Parameter(Mandatory = $true)][string]$OpenPathRoot)

    $processIds = @()

    $processIds += Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Id -ne $PID -and
            $_.Path -and
            $_.Path.StartsWith($OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -ExpandProperty Id

    if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
        $escapedRoot = $OpenPathRoot.Replace('\', '\')
        $processIds += Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like "*$escapedRoot*"
            } |
            Select-Object -ExpandProperty ProcessId
    }

    $processIds |
        Where-Object { $_ } |
        Select-Object -Unique |
        ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
}

function Remove-OpenPathInstallerAppLockerRules {
    <#
    .SYNOPSIS
        Removes AppLocker rules whose Name attribute begins with 'OpenPath non-admin app control' from the local policy
    #>
    if (-not (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { return }

    $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
    $removed = $false
    foreach ($collection in @($policyXml.AppLockerPolicy.RuleCollection)) {
        foreach ($rule in @($collection.ChildNodes)) {
            if ($null -ne $rule -and
                $rule -is [System.Xml.XmlElement] -and
                $rule.GetAttribute('Name') -like 'OpenPath non-admin app control*') {
                [void]$collection.RemoveChild($rule)
                $removed = $true
            }
        }
    }

    if (-not $removed) { return }

    $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-installer-applocker-cleanup-$([guid]::NewGuid()).xml"
    try {
        $policyXml.Save($policyPath)
        Set-AppLockerPolicy -XMLPolicy $policyPath -ErrorAction Stop
    }
    finally {
        Remove-Item $policyPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-OpenPathInstallerFirewallManifestRuleNames {
    <#
    .SYNOPSIS
        Normalises a firewall manifest value (string, array, or JSON array) into a sorted, unique list of rule name strings
    .PARAMETER Value
        Raw value read from the firewall-rules.json manifest
    #>
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

function Get-OpenPathInstallerFirewallManifestRuleNames {
    <#
    .SYNOPSIS
        Reads the firewall-rules.json manifest at Path and returns the list of rule names; returns an empty array when the file is absent or corrupt
    .PARAMETER Path
        Absolute path to the firewall manifest JSON file
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }

    try {
        $parsed = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return ConvertTo-OpenPathInstallerFirewallManifestRuleNames -Value $parsed
    }
    catch {
        if (Get-Command -Name Write-InstallerWarning -ErrorAction SilentlyContinue) {
            Write-InstallerWarning "  WARNING: Ignoring unreadable firewall manifest at $Path; falling back to OpenPath firewall rule discovery. $_"
        }
        else {
            Write-Warning "Ignoring unreadable firewall manifest at $Path; falling back to OpenPath firewall rule discovery. $_"
        }
        return @()
    }
}

function Remove-OpenPathInstallerFirewallRules {
    <#
    .SYNOPSIS
        Removes all OpenPath firewall rules using the manifest file, the OpenPath group, and the OpenPath-DNS-* wildcard as fallback sources
    #>
    if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Remove-NetFirewallRule -ErrorAction SilentlyContinue)) { return }

    $manifestPath = Join-Path 'C:\OpenPath' 'data\firewall-rules.json'
    foreach ($ruleName in @(Get-OpenPathInstallerFirewallManifestRuleNames -Path $manifestPath)) {
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }

    if (Test-Path $manifestPath) {
        Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
    }

    Get-NetFirewallRule -Group 'OpenPath' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    Get-NetFirewallRule -DisplayName 'OpenPath-DNS-*' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction Stop
}

function Select-OpenPathInstallerScalarValue {
    <#
    .SYNOPSIS
        Returns the first non-null item from Value, which may be a scalar or an array; returns null when all items are null
    .PARAMETER Value
        Scalar or array value from which to extract the first non-null element
    #>
    param([object]$Value)

    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            return $item
        }
    }

    return $null
}

function ConvertTo-OpenPathInstallerNullableInt {
    <#
    .SYNOPSIS
        Converts Value to an integer or returns null when Value is absent, empty, or non-numeric; tolerates legacy array-wrapped interface indexes
    .PARAMETER Value
        Scalar or array value to convert to a nullable integer
    #>
    param([object]$Value)

    $scalarValue = Select-OpenPathInstallerScalarValue -Value $Value
    if ($null -eq $scalarValue) { return $null }

    $stringValue = [string]$scalarValue
    if ([string]::IsNullOrWhiteSpace($stringValue)) { return $null }

    try {
        return [int]$stringValue
    }
    catch {
        return $null
    }
}

function Restore-OpenPathInstallerDnsSettings {
    <#
    .SYNOPSIS
        Restores adapter DNS settings from the original-dns.json snapshot, matching adapters by GUID then index then alias; resets to DHCP when no snapshot exists
    #>
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Set-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return }

    $snapshotPath = Join-Path 'C:\OpenPath' 'data\original-dns.json'
    if (Test-Path $snapshotPath) {
        $snapshot = @(Get-Content $snapshotPath -Raw | ConvertFrom-Json)
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        foreach ($entry in $snapshot) {
            $adapter = $adapters | Where-Object { [string]$_.InterfaceGuid -eq [string]$entry.InterfaceGuid } | Select-Object -First 1
            $entryInterfaceIndex = ConvertTo-OpenPathInstallerNullableInt -Value $entry.InterfaceIndex
            if (-not $adapter -and $null -ne $entryInterfaceIndex) {
                $adapter = $adapters | Where-Object {
                    (ConvertTo-OpenPathInstallerNullableInt -Value $_.ifIndex) -eq $entryInterfaceIndex
                } | Select-Object -First 1
            }
            if (-not $adapter -and $entry.InterfaceAlias) {
                $adapter = $adapters | Where-Object { $_.Name -eq [string]$entry.InterfaceAlias } | Select-Object -First 1
            }
            if (-not $adapter) { continue }

            $adapterInterfaceIndex = ConvertTo-OpenPathInstallerNullableInt -Value $adapter.ifIndex
            if ($null -eq $adapterInterfaceIndex) { continue }

            $servers = @($entry.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object { $_ })
            if ($servers.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $adapterInterfaceIndex -ServerAddresses $servers -ErrorAction Stop
            }
            else {
                Set-DnsClientServerAddress -InterfaceIndex $adapterInterfaceIndex -ResetServerAddresses -ErrorAction Stop
            }
        }
    }
    else {
        Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction Stop
        }
    }
    if (Get-Command -Name Clear-DnsClientCache -ErrorAction SilentlyContinue) {
        Clear-DnsClientCache
    }
}

function Remove-OpenPathInstallerBrowserArtifacts {
    <#
    .SYNOPSIS
        Removes Firefox distribution policy files and all OpenPath-related browser registry keys
    #>
    $firefoxPolicies = @(
        "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json"
    )
    foreach ($path in $firefoxPolicies) {
        if ($path -and (Test-Path $path)) {
            Remove-Item $path -Force -ErrorAction Stop
        }
    }

    $registryPaths = @(
        'HKLM\SOFTWARE\Mozilla\NativeMessagingHosts\whitelist_native_host',
        'HKLM\SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host',
        'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist',
        'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
    )
    foreach ($registryPath in $registryPaths) {
        Remove-OpenPathInstallerRegistryKeyIfPresent -RegistryPath $registryPath
    }
}

function Stop-OpenPathInstallerAcrylicService {
    <#
    .SYNOPSIS
        Stops the Acrylic DNS proxy service; does not uninstall Acrylic regardless of the KeepAcrylic flag (removal is intentionally omitted from reinstall cleanup)
    .PARAMETER KeepAcrylic
        When set, suppresses the informational warning about intentional Acrylic preservation
    #>
    param([switch]$KeepAcrylic)

    if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Stop-Service -ErrorAction SilentlyContinue)) { return }

    $acrylicService = Get-Service -DisplayName '*Acrylic*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($acrylicService) {
        Stop-Service -Name $acrylicService.Name -Force -ErrorAction SilentlyContinue
    }

    if (-not $KeepAcrylic) {
        Write-InstallerWarning '  Acrylic removal is intentionally not performed by reinstall cleanup'
    }
}

function Remove-OpenPathInstallerInstallRoot {
    <#
    .SYNOPSIS
        Removes the OpenPath install root directory, retrying up to five times; when KeepLogs is set, preserves the data\logs subtree
    .PARAMETER OpenPathRoot
        Root directory to remove
    .PARAMETER KeepLogs
        When set, removes all content except data\logs
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [switch]$KeepLogs
    )

    if (-not (Test-Path $OpenPathRoot)) { return }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Stop-OpenPathInstallerRootedProcess -OpenPathRoot $OpenPathRoot

            if ($KeepLogs) {
                Get-ChildItem $OpenPathRoot -Exclude 'data' -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction Stop

                $dataPath = Join-Path $OpenPathRoot 'data'
                if (Test-Path $dataPath) {
                    Get-ChildItem $dataPath -Exclude 'logs' -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction Stop
                }
                return
            }

            Remove-Item $OpenPathRoot -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path $OpenPathRoot)) { return }
        }
        catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds (300 * $attempt)
        }
    }
}

function Invoke-OpenPathInstallerExistingInstallCleanup {
    <#
    .SYNOPSIS
        Orchestrates a full pre-reinstall cleanup: stops tasks and the Acrylic service, restores DNS, removes firewall and AppLocker rules, strips browser artifacts, and deletes the install root
    .PARAMETER OpenPathRoot
        Root directory of the existing installation to clean up
    .PARAMETER KeepAcrylic
        When set, preserves the Acrylic DNS proxy installation
    .PARAMETER KeepLogs
        When set, preserves the data\logs directory during install root removal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [switch]$KeepAcrylic,

        [switch]$KeepLogs
    )

    if (-not (Test-OpenPathExistingInstallation -OpenPathRoot $OpenPathRoot)) {
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess('Existing OpenPath installation', 'Remove before reinstall while keeping Acrylic and logs')) {
        return $false
    }

    Write-InstallerWarning '  Existing OpenPath installation detected; cleaning before reinstall'

    Stop-OpenPathInstallerScheduledTasks
    Restore-OpenPathInstallerDnsSettings
    Remove-OpenPathInstallerFirewallRules
    Remove-OpenPathInstallerAppLockerRules
    Remove-OpenPathInstallerBrowserArtifacts
    Stop-OpenPathInstallerAcrylicService -KeepAcrylic:$KeepAcrylic
    Remove-OpenPathInstallerInstallRoot -KeepLogs:$KeepLogs -OpenPathRoot $OpenPathRoot

    Write-InstallerVerbose '  Existing OpenPath installation cleaned'
    return $true
}
