function ConvertTo-OpenPathInstallerRegistryProviderPath {
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
    param([Parameter(Mandatory = $true)][string]$RegistryPath)

    try {
        return (Test-Path (ConvertTo-OpenPathInstallerRegistryProviderPath -RegistryPath $RegistryPath))
    }
    catch {
        return $false
    }
}

function Remove-OpenPathInstallerRegistryKeyIfPresent {
    param([Parameter(Mandatory = $true)][string]$RegistryPath)

    $providerPath = ConvertTo-OpenPathInstallerRegistryProviderPath -RegistryPath $RegistryPath
    if (Test-Path $providerPath) {
        Remove-Item -Path $providerPath -Recurse -Force -ErrorAction Stop
    }
}

function Test-OpenPathExistingInstallation {
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
            if (@($rules | Where-Object { $_.Name -like 'OpenPath non-admin app control*' }).Count -gt 0) {
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
    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) { return }
    $tasks = @(Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue)
    foreach ($task in $tasks) {
        Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
    }
}

function Stop-OpenPathInstallerRootedProcess {
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
    if (-not (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { return }

    $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
    $removed = $false
    foreach ($collection in @($policyXml.AppLockerPolicy.RuleCollection)) {
        foreach ($rule in @($collection.ChildNodes)) {
            if ($rule.Name -like 'OpenPath non-admin app control*') {
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

function Remove-OpenPathInstallerFirewallRules {
    if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Remove-NetFirewallRule -ErrorAction SilentlyContinue)) { return }

    $manifestPath = Join-Path 'C:\OpenPath' 'data\firewall-rules.json'
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

    Get-NetFirewallRule -DisplayName 'OpenPath-DNS-*' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction Stop
}

function Restore-OpenPathInstallerDnsSettings {
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command -Name Set-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return }

    $snapshotPath = Join-Path 'C:\OpenPath' 'data\original-dns.json'
    if (Test-Path $snapshotPath) {
        $snapshot = @(Get-Content $snapshotPath -Raw | ConvertFrom-Json)
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        foreach ($entry in $snapshot) {
            $adapter = @($adapters | Where-Object { [string]$_.InterfaceGuid -eq [string]$entry.InterfaceGuid } | Select-Object -First 1)
            if (-not $adapter -and $entry.InterfaceIndex -ne $null) {
                $adapter = @($adapters | Where-Object { $_.ifIndex -eq [int]$entry.InterfaceIndex } | Select-Object -First 1)
            }
            if (-not $adapter -and $entry.InterfaceAlias) {
                $adapter = @($adapters | Where-Object { $_.Name -eq [string]$entry.InterfaceAlias } | Select-Object -First 1)
            }
            if (-not $adapter) { continue }

            $servers = @($entry.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object { $_ })
            if ($servers.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $servers -ErrorAction Stop
            }
            else {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
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
