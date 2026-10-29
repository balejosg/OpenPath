# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# PSScriptAnalyzer suppressions:
# - Write-Host is intentional for interactive uninstaller
# - BOM not required for UTF-8 (files are already UTF-8 without BOM)
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstalls the OpenPath DNS system for Windows
.DESCRIPTION
    Removes firewall rules, scheduled tasks, browser policies, 
    and restores original DNS settings.
.PARAMETER KeepAcrylic
    Keep Acrylic DNS Proxy installed
.PARAMETER KeepLogs
    Keep log files
#>

param(
    [switch]$KeepAcrylic,
    [switch]$KeepLogs
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot
$script:OpenPathBrowserPolicyIssues = 0

function Convert-ToRegistryProviderPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    if ($RegistryPath -match '^HKLM\\') {
        return "Registry::HKEY_LOCAL_MACHINE\\$($RegistryPath.Substring(5))"
    }

    throw "Unsupported registry hive path: $RegistryPath"
}

function Remove-RegistryKeyIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    $providerPath = Convert-ToRegistryProviderPath -RegistryPath $RegistryPath
    if (Test-Path $providerPath) {
        Remove-Item -Path $providerPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-OpenPathScheduledTask {
    $tasks = Get-ScheduledTask -TaskName "OpenPath-*" -ErrorAction SilentlyContinue

    foreach ($task in $tasks) {
        Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Stop-OpenPathRootedProcess {
    $processIds = @()

    $processIds += Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Id -ne $PID -and
            $_.Path -and
            $_.Path.StartsWith($OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -ExpandProperty Id

    $processIds += Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like "*$OpenPathRoot*"
        } |
        Select-Object -ExpandProperty ProcessId

    $processIds |
        Where-Object { $_ } |
        Select-Object -Unique |
        ForEach-Object {
            Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        }
}

function Remove-OpenPathFallbackAppLockerRules {
    if (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
        try {
            $policyXml = [xml](Get-AppLockerPolicy -Local -Xml -ErrorAction Stop)
            $managedRules = @()
            foreach ($rule in @($policyXml.SelectNodes('//*[@Name]'))) {
                if ($rule -is [System.Xml.XmlElement] -and $rule.GetAttribute('Name') -like 'OpenPath non-admin app control*') {
                    $managedRules += $rule
                }
            }
            if ($managedRules.Count -eq 0) { return $true }
        }
        catch {
            throw 'Unable to inspect local AppLocker policy; manual recovery is required.'
        }
    }

    $modulePath = Join-Path $OpenPathRoot 'lib\AppControl.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw 'AppControl owner module is unavailable; manual recovery is required.'
    }
    Import-Module $modulePath -Force -Global -ErrorAction Stop
    if (-not (Remove-OpenPathNonAdminAppControl -OpenPathRoot $OpenPathRoot -Confirm:$false)) {
        throw 'Central AppControl removal did not verify; manual recovery is required.'
    }
}

function Select-OpenPathUninstallScalarValue {
    param([object]$Value)

    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            return $item
        }
    }

    return $null
}

function ConvertTo-OpenPathUninstallNullableInt {
    param([object]$Value)

    $scalarValue = Select-OpenPathUninstallScalarValue -Value $Value
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

function ConvertTo-OpenPathUninstallFirewallManifestRuleNames {
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

function Get-OpenPathUninstallFirewallManifestRuleNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }

    try {
        $parsed = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return ConvertTo-OpenPathUninstallFirewallManifestRuleNames -Value $parsed
    }
    catch {
        Write-Warning "Ignoring unreadable firewall manifest at $Path; falling back to OpenPath firewall rule discovery. $_"
        return @()
    }
}

function Test-OpenPathUninstallLoopbackAddress {
    param([object]$Address)

    $text = ([string]$Address).Trim()
    return ($text -eq '::1' -or $text -eq '0.0.0.0' -or $text -match '^127\.')
}

function Restore-OpenPathOriginalDns {
    $snapshotPath = Join-Path $OpenPathRoot 'data\original-dns.json'
    if ((Test-Path $snapshotPath) -and (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) {
        try {
            # v2 snapshots wrap the per-adapter entries in an `adapters` property;
            # legacy snapshots are a bare array of entries.
            $snapshotPayload = Get-Content $snapshotPath -Raw | ConvertFrom-Json
            $snapshot = if ($snapshotPayload.PSObject.Properties['adapters']) { @($snapshotPayload.adapters) } else { @($snapshotPayload) }
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
            foreach ($entry in $snapshot) {
                $adapter = $adapters | Where-Object { [string]$_.InterfaceGuid -eq [string]$entry.InterfaceGuid } | Select-Object -First 1
                $entryInterfaceIndex = ConvertTo-OpenPathUninstallNullableInt -Value $entry.InterfaceIndex
                if (-not $adapter -and $null -ne $entryInterfaceIndex) {
                    $adapter = $adapters | Where-Object {
                        (ConvertTo-OpenPathUninstallNullableInt -Value $_.ifIndex) -eq $entryInterfaceIndex
                    } | Select-Object -First 1
                }
                if (-not $adapter -and $entry.InterfaceAlias) {
                    $adapter = $adapters | Where-Object { $_.Name -eq [string]$entry.InterfaceAlias } | Select-Object -First 1
                }
                if (-not $adapter) { continue }

                $adapterInterfaceIndex = ConvertTo-OpenPathUninstallNullableInt -Value $adapter.ifIndex
                if ($null -eq $adapterInterfaceIndex) { continue }

                # A loopback address in the snapshot is OpenPath's own pin (Acrylic), which is
                # being removed: never restore it.
                $servers = @($entry.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object {
                        $_ -and -not (Test-OpenPathUninstallLoopbackAddress -Address $_)
                    })
                if ($servers.Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $adapterInterfaceIndex -ServerAddresses $servers -ErrorAction SilentlyContinue
                }
                else {
                    Set-DnsClientServerAddress -InterfaceIndex $adapterInterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            Write-Host "  Snapshot DNS restore failed: $_" -ForegroundColor Yellow
        }
    }
    else {
        Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
        }
    }

    # Safety net: whatever the snapshot said, no adapter may keep a loopback resolver once
    # the local DNS proxy is gone, or the machine loses name resolution.
    if (Get-Command -Name Get-DnsClientServerAddress -ErrorAction SilentlyContinue) {
        foreach ($dnsEntry in @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) {
            $stillLoopback = @($dnsEntry.ServerAddresses | Where-Object {
                    $_ -and (Test-OpenPathUninstallLoopbackAddress -Address $_)
                })
            if ($stillLoopback.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $dnsEntry.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            }
        }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Remove-OpenPathFirefoxExtensionSettingsEntries {
    # Direct registry removal of the OpenPath entries (matched by id or by the OpenPath XPI
    # install_url) from the Firefox ExtensionSettings value. Foreign entries are rewritten as they
    # were and are never resurrected: the value is read fresh, filtered and written back.
    param(
        [Parameter(Mandatory = $true)][string]$PolicyKey,
        [Parameter(Mandatory = $true)][string[]]$ExtensionIds
    )

    $settingsValue = $null
    try { $settingsValue = (Get-ItemProperty -Path $PolicyKey -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings } catch {}

    $remaining = [ordered]@{}
    $removedAny = $false
    foreach ($entry in @($settingsValue)) {
        if (-not $entry) { continue }
        try { $parsed = [string]$entry | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        foreach ($property in @($parsed.PSObject.Properties)) {
            $installUrl = if ($property.Value.PSObject.Properties['install_url']) { [string]$property.Value.install_url } else { '' }
            if ($property.Name -in $ExtensionIds -or $installUrl -match '/api/extensions/firefox/openpath\.xpi(?:[?#]|$)') {
                $removedAny = $true
            }
            else {
                $remaining[$property.Name] = $property.Value
            }
        }
    }

    if (-not $removedAny) { return }
    if ($remaining.Count -eq 0) {
        Remove-ItemProperty -Path $PolicyKey -Name 'ExtensionSettings' -ErrorAction SilentlyContinue
    }
    else {
        New-ItemProperty -Path $PolicyKey -Name 'ExtensionSettings' -Value @($remaining | ConvertTo-Json -Depth 10 -Compress) -PropertyType MultiString -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Test-OpenPathUninstallFirefoxPolicyExternallyManaged {
    # True only when the policy store positively reports a domain GPO or MDM as the owner of the
    # Firefox ExtensionSettings value. Unknown owners are treated as not external.
    if (-not (Get-Command -Name Get-OpenPathPolicyValueOwner -ErrorAction SilentlyContinue)) { return $false }
    try {
        $ownerInfo = Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Mozilla\Firefox' -ValueName 'ExtensionSettings'
        return [bool]($ownerInfo -and ([string]$ownerInfo.Owner -eq 'DomainGpo' -or [string]$ownerInfo.Owner -eq 'Mdm'))
    }
    catch {
        return $false
    }
}

function Remove-OpenPathUninstallPolicyStoreLedger {
    # The policy store ledger (HKLM:\SOFTWARE\OpenPath\PolicyStore) tells OpenPath's own local GPO
    # entries apart from vendor ones. Delete it only when every browser policy removal succeeded;
    # otherwise keep it so a later install still recognises the entries left behind as OpenPath's.
    param([AllowNull()][object]$BrowserPolicyRemoval)

    if (-not $BrowserPolicyRemoval -or -not $BrowserPolicyRemoval.Complete -or $script:OpenPathBrowserPolicyIssues -gt 0) {
        Write-Host "  Policy store ledger kept (HKLM:\SOFTWARE\OpenPath\PolicyStore) because browser policy removal was incomplete" -ForegroundColor Yellow
        return $false
    }
    if (-not (Get-Command -Name Remove-OpenPathPolicyStoreLedger -ErrorAction SilentlyContinue)) { return $false }
    return [bool](Remove-OpenPathPolicyStoreLedger)
}

function Remove-OpenPathFirefoxManagedExtension {
    # With -EntryRemovedByStore the OpenPath entries in ExtensionSettings are removed through the
    # local GPO policy store (so they also leave Registry.pol, not only the registry). For any id the
    # store could not remove, the direct registry removal runs as a fallback unless a domain GPO or
    # MDM owns the value (then it is left untouched and a warning is printed). Without the flag only
    # the direct registry removal runs.
    param([switch]$EntryRemovedByStore)

    # Install force-installs the extension through the machine registry policy
    # (HKLM\SOFTWARE\Policies\Mozilla\Firefox\ExtensionSettings). Deleting only
    # distribution\policies.json leaves that registry policy in place, and dropping a
    # policy never removes an add-on that Firefox already installed: the extension has to
    # be uninstalled explicitly through the Extensions\Uninstall policy.
    $policyKey = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
    $extensionIds = New-Object System.Collections.Generic.List[string]
    $extensionIds.Add('openpath-block-monitor@openpath')
    # Pre-2026-05-10 agents registered the extension under the previous id.
    $extensionIds.Add('monitor-bloqueos@openpath')

    $configPath = Join-Path $OpenPathRoot 'data\config.json'
    if (Test-Path $configPath) {
        try {
            $configuredId = [string](Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).firefoxExtensionId
            if ($configuredId.Trim()) { $extensionIds.Add($configuredId.Trim()) }
        }
        catch {
            Write-Warning "Ignoring unreadable OpenPath config at ${configPath}: $_"
        }
    }

    $settingsValue = $null
    try { $settingsValue = (Get-ItemProperty -Path $policyKey -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings } catch {}

    $hadManagedEntry = $false
    foreach ($entry in @($settingsValue)) {
        if (-not $entry) { continue }
        try { $parsed = [string]$entry | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        foreach ($property in @($parsed.PSObject.Properties)) {
            $installUrl = if ($property.Value.PSObject.Properties['install_url']) { [string]$property.Value.install_url } else { '' }
            if ($property.Name -in $extensionIds -or $installUrl -match '/api/extensions/firefox/openpath\.xpi(?:[?#]|$)') {
                $hadManagedEntry = $true
                if ($property.Name -notin $extensionIds) { $extensionIds.Add($property.Name) }
            }
        }
    }

    if ($EntryRemovedByStore) {
        # Legacy and renamed ids (matched by install_url above) are not covered by
        # Remove-BrowserPolicy, which only knows the current id. Each call is a no-op when the
        # id is absent and never touches entries it does not own.
        $storeFailedIds = New-Object System.Collections.Generic.List[string]
        $storeCommandAvailable = [bool](Get-Command -Name Remove-OpenPathFirefoxMachineExtensionPolicy -ErrorAction SilentlyContinue)
        foreach ($storeId in @($extensionIds | Select-Object -Unique)) {
            if (-not $storeCommandAvailable) { $storeFailedIds.Add($storeId); continue }
            try {
                $removed = Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy ([pscustomobject]@{ ExtensionId = $storeId })
                # $false also means "id not present"; the direct fallback below is a no-op then.
                if (-not $removed) { $storeFailedIds.Add($storeId) }
            }
            catch {
                Write-Warning "Could not remove Firefox policy entry ${storeId} through the policy store: $_"
                $storeFailedIds.Add($storeId)
            }
        }

        if ($storeFailedIds.Count -gt 0 -and $hadManagedEntry) {
            if (Test-OpenPathUninstallFirefoxPolicyExternallyManaged) {
                $script:OpenPathBrowserPolicyIssues++
                Write-Host "  WARNING: The Firefox ExtensionSettings policy is managed by a domain GPO or MDM; the OpenPath entry was left in place. Remove it from that policy." -ForegroundColor Yellow
            }
            else {
                Remove-OpenPathFirefoxExtensionSettingsEntries -PolicyKey $policyKey -ExtensionIds @($storeFailedIds)
                $script:OpenPathBrowserPolicyIssues++
                Write-Host "  WARNING: The policy store did not remove the Firefox OpenPath entry; it was removed from the registry directly. The local GPO may re-apply it at the next Group Policy refresh." -ForegroundColor Yellow
            }
        }
    }
    elseif ($hadManagedEntry) {
        Remove-OpenPathFirefoxExtensionSettingsEntries -PolicyKey $policyKey -ExtensionIds @($extensionIds)
    }

    $firefoxInstalled = @(
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $hadManagedEntry -and -not $firefoxInstalled) { return }

    $uninstallKey = "$policyKey\Extensions\Uninstall"
    if (-not (Test-Path $uninstallKey)) {
        New-Item -Path $uninstallKey -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $existing = @()
    try {
        $existing = @((Get-Item -Path $uninstallKey -ErrorAction Stop).Property | ForEach-Object {
                [string](Get-ItemProperty -Path $uninstallKey -Name $_).$_
            })
    }
    catch {}
    $slot = @($existing).Count
    foreach ($id in @($extensionIds | Select-Object -Unique)) {
        if ($id -in $existing) { continue }
        $slot++
        New-ItemProperty -Path $uninstallKey -Name ([string]$slot) -Value $id -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Restore-OpenPathOutboundDefault {
    # The optional egress floor flips each profile's DefaultOutboundAction to Block; deleting
    # its Allow rules without restoring the default would leave all egress blocked.
    if (-not (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue)) { return }

    $previous = @{}
    $statePath = Join-Path $OpenPathRoot 'data\egress-floor-prev-outbound.json'
    $hasState = Test-Path $statePath
    if ($hasState) {
        try {
            $parsed = (Get-Content $statePath -ErrorAction Stop) -join "`n" | ConvertFrom-Json -ErrorAction Stop
            foreach ($property in $parsed.PSObject.Properties) {
                $previous[$property.Name] = [string]$property.Value
            }
        }
        catch {
            Write-Warning "Ignoring unreadable egress-floor state at $statePath; restoring Allow. $_"
        }
    }

    foreach ($profileName in @('Domain', 'Private', 'Public')) {
        $current = $null
        if (Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
            $current = [string](Get-NetFirewallProfile -Profile $profileName -ErrorAction SilentlyContinue).DefaultOutboundAction
        }
        if (-not $hasState -and $current -ne 'Block') { continue }

        # Never restore Block, even when a damaged state file records it.
        $action = 'Allow'
        if ($previous[$profileName] -in @('Allow', 'NotConfigured')) {
            $action = $previous[$profileName]
        }
        Set-NetFirewallProfile -Profile $profileName -DefaultOutboundAction $action -ErrorAction SilentlyContinue
    }
}

function Remove-OpenPathFirewallRules {
    Restore-OpenPathOutboundDefault

    $manifestPath = Join-Path $OpenPathRoot 'data\firewall-rules.json'
    foreach ($ruleName in @(Get-OpenPathUninstallFirewallManifestRuleNames -Path $manifestPath)) {
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }

    Get-NetFirewallRule -Group 'OpenPath' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName "OpenPath-DNS-*" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

function Remove-OpenPathInstallRoot {
    param(
        [switch]$KeepLogs
    )

    if (-not (Test-Path $OpenPathRoot)) {
        return
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            foreach ($pendingEnrollmentPath in @(
                    (Join-Path $OpenPathRoot 'data\pending-enrollment.json.dpapi'),
                    (Join-Path $OpenPathRoot 'data\pending-enrollment.json')
                )) {
                if (Test-Path $pendingEnrollmentPath) {
                    Remove-Item -LiteralPath $pendingEnrollmentPath -Force -ErrorAction SilentlyContinue
                }
            }

            if ($KeepLogs) {
                Get-ChildItem $OpenPathRoot -Exclude "data" -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction Stop

                $dataPath = Join-Path $OpenPathRoot "data"
                if (Test-Path $dataPath) {
                    Get-ChildItem $dataPath -Exclude "logs" -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction Stop
                }

                return
            }

            Remove-Item $OpenPathRoot -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path $OpenPathRoot)) {
                return
            }
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }
        }

        Stop-OpenPathRootedProcess
        Start-Sleep -Milliseconds (300 * $attempt)
    }

    if (Test-Path $OpenPathRoot) {
        throw "OpenPath install root still exists after cleanup: $OpenPathRoot"
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  OpenPath DNS for Windows - Uninstaller" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Import modules if available
if (Test-Path "$OpenPathRoot\lib\Common.psm1") {
    Import-Module "$OpenPathRoot\lib\Common.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\DNS.psm1") {
    Import-Module "$OpenPathRoot\lib\DNS.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Network.psm1") {
    Import-Module "$OpenPathRoot\lib\Network.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Firewall.psm1") {
    Import-Module "$OpenPathRoot\lib\Firewall.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\AppControl.psm1") {
    Import-Module "$OpenPathRoot\lib\AppControl.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Browser.psm1") {
    Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Services.psm1") {
    Import-Module "$OpenPathRoot\lib\Services.psm1" -Force -ErrorAction SilentlyContinue
}

# Step 1: Remove scheduled tasks
Write-Host "[1/6] Removing scheduled tasks..." -ForegroundColor Yellow
Stop-OpenPathScheduledTask
Write-Host "  Scheduled tasks removed" -ForegroundColor Green

# Step 2: Restore DNS
Write-Host "[2/6] Restoring DNS configuration..." -ForegroundColor Yellow
Restore-OpenPathOriginalDns
Write-Host "  DNS restored" -ForegroundColor Green
if (Get-Command -Name Restore-OpenPathOriginalBridgeFilters -ErrorAction SilentlyContinue) {
    Restore-OpenPathOriginalBridgeFilters
    Write-Host "  Bridged-adapter filters restored" -ForegroundColor Green
}

# Step 3: Remove firewall rules
Write-Host "[3/6] Removing firewall rules..." -ForegroundColor Yellow
Remove-OpenPathFirewallRules
Write-Host "  Firewall rules removed" -ForegroundColor Green

if (Get-Command -Name Remove-OpenPathNonAdminAppControl -ErrorAction SilentlyContinue) {
    Remove-OpenPathNonAdminAppControl | Out-Null
}
else {
    Remove-OpenPathFallbackAppLockerRules
}

if (Get-Command -Name Remove-OpenPathRestrictedGroup -ErrorAction SilentlyContinue) {
    Remove-OpenPathRestrictedGroup | Out-Null
}

# Step 4: Remove browser policies
Write-Host "[4/6] Removing browser policies..." -ForegroundColor Yellow

# Firefox
$firefoxPolicies = @(
    "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json"
)
foreach ($path in $firefoxPolicies) {
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

# Browser policies live in the registry and in the local GPO (Registry.pol): remove them through
# the policy store when Browser.psm1 loaded, otherwise fall back to the direct registry logic.
# The Firefox function runs first so it can still read the entries it has to hand to the store.
$browserPolicyStoreAvailable = [bool](Get-Command -Name Remove-BrowserPolicy -ErrorAction SilentlyContinue)
Remove-OpenPathFirefoxManagedExtension -EntryRemovedByStore:$browserPolicyStoreAvailable

$browserPolicyRemovedViaStore = $false
if ($browserPolicyStoreAvailable) {
    $browserPolicyRemoval = $null
    try {
        if ((Get-Command -Name Remove-BrowserPolicy).Parameters.ContainsKey('PassThru')) {
            $browserPolicyRemoval = Remove-BrowserPolicy -PassThru
        }
        else {
            Remove-BrowserPolicy | Out-Null
        }
        $browserPolicyRemovedViaStore = $true
    }
    catch {
        $script:OpenPathBrowserPolicyIssues++
        Write-Host "  WARNING: Could not remove browser policies through the policy store; removing the Chromium policy keys from the registry directly (the local GPO may re-apply them): $_" -ForegroundColor Yellow
    }
    Remove-OpenPathUninstallPolicyStoreLedger -BrowserPolicyRemoval $browserPolicyRemoval | Out-Null
}

$firefoxNativeHostRegistryPaths = @(
    'HKLM\SOFTWARE\Mozilla\NativeMessagingHosts\whitelist_native_host',
    'HKLM\SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\whitelist_native_host'
)
foreach ($registryPath in $firefoxNativeHostRegistryPaths) {
    Remove-RegistryKeyIfPresent -RegistryPath $registryPath
}

$firefoxNativeHostArtifacts = @(
    "$OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.cmd",
    # Phase 5: compiled host, its build source and the build manifest/diagnostics.
    "$OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.exe",
    "$OpenPathRoot\browser-extension\firefox\native\OpenPathNativeHost.cs",
    "$OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.manifest.json",
    "$OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.build.json",
    # Phase 8: staged prebuilt signed host (the recursive native-host removal
    # below covers them too; kept explicit so a layout change cannot leave a
    # stale signed binary behind).
    "$OpenPathRoot\native-host\signed\OpenPath-NativeHost.exe",
    "$OpenPathRoot\native-host\signed\OpenPath-NativeHost.signing.json",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.State.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Protocol.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Actions.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Actions.Bootstrap.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Actions.Shared.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Actions.RuntimeDependency.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Actions.CaptivePortal.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\NativeHost.Actions.MessageDispatch.ps1",
    "$OpenPathRoot\browser-extension\firefox\native\whitelist_native_host.json",
    "$OpenPathRoot\browser-extension\firefox\native\native-state.json",
    "$OpenPathRoot\browser-extension\firefox\native\whitelist.txt"
)
foreach ($artifactPath in $firefoxNativeHostArtifacts) {
    if (Test-Path $artifactPath) {
        Remove-Item $artifactPath -Force -ErrorAction SilentlyContinue
    }
}

# Phase 5: the compiled-host source directory in the install root.
Remove-Item (Join-Path $OpenPathRoot 'native-host') -Recurse -Force -ErrorAction SilentlyContinue

# Phase 8: the offline payload manifest kept for the signed-host anchor.
Remove-Item (Join-Path $OpenPathRoot 'payload-manifest.json') -Force -ErrorAction SilentlyContinue

# Chrome/Edge registry
$regPaths = @(
    "HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist",
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist",
    "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist",
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
)
if (-not $browserPolicyRemovedViaStore) {
    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
if ($script:OpenPathBrowserPolicyIssues -gt 0) {
    Write-Host "  Browser policies removed with warnings (see above)" -ForegroundColor Yellow
}
else {
    Write-Host "  Browser policies removed" -ForegroundColor Green
}

# Step 5: Stop and optionally remove Acrylic
Write-Host "[5/6] Stopping Acrylic DNS..." -ForegroundColor Yellow
$acrylicService = Get-Service -DisplayName "*Acrylic*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($acrylicService) {
    Stop-Service -Name $acrylicService.Name -Force -ErrorAction SilentlyContinue
    
    if (-not $KeepAcrylic) {
        # Uninstall Acrylic service
        $acrylicPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
        if (Test-Path "$acrylicPath\AcrylicService.exe") {
            # AcrylicService.exe /UNINSTALL can block indefinitely (for example when
            # its service or driver is still in use). Bound the wait, terminate the
            # helper, and rely on the sc.exe service deletion below so the
            # standalone uninstall never hangs.
            $acrylicUninstall = Start-Process -FilePath "$acrylicPath\AcrylicService.exe" -ArgumentList '/UNINSTALL' -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
            if ($acrylicUninstall) {
                if (-not $acrylicUninstall.WaitForExit(120000)) {
                    Write-Host "  Acrylic uninstaller did not exit within 120s; terminating it" -ForegroundColor Yellow
                    try { $acrylicUninstall.Kill() } catch {}
                }
                try { $acrylicUninstall.Dispose() } catch {}
            }
        }
        $remainingAcrylicService = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
        if ($remainingAcrylicService) {
            & sc.exe delete AcrylicDNSProxySvc 2>$null | Out-Null
        }
        Write-Host "  Acrylic stopped and uninstalled" -ForegroundColor Green
    }
    else {
        Write-Host "  Acrylic stopped (kept installed)" -ForegroundColor Green
    }
}
else {
    Write-Host "  Acrylic not found" -ForegroundColor Yellow
}

# Step 6: Remove whitelist files
Write-Host "[6/6] Removing files..." -ForegroundColor Yellow
if (Test-Path $OpenPathRoot) {
    Stop-OpenPathRootedProcess

    if ($KeepLogs) {
        Remove-OpenPathInstallRoot -KeepLogs
        Write-Host "  Files removed (logs preserved)" -ForegroundColor Green
    }
    else {
        Remove-OpenPathInstallRoot
        Write-Host "  Files removed" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  UNINSTALL COMPLETED" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "The system has been restored to its original state."
Write-Host "A restart may be required to apply all changes."
Write-Host ""

# Report success explicitly: without this the process exit code is inherited
# from the last native command (for example sc.exe deleting an already absent
# service), which made a successful uninstall look like a failure.
exit 0
