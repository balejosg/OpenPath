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
# Shared reversion leaves: dependency-free, work with no OpenPath module loaded.
. (Join-Path $PSScriptRoot 'lib\internal\DNS.AdapterSnapshot.ps1')
. (Join-Path $PSScriptRoot 'lib\internal\Firewall.Teardown.ps1')
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

function Get-OpenPathUninstallAncestorProcessIds {
    # Returns the ids of $ProcessId and its ancestors from Win32_Process-shaped
    # rows (ProcessId, ParentProcessId). A wrapper such as
    # `cmd /c powershell -File C:\OpenPath\Uninstall-OpenPath.ps1` has the
    # install root in its command line, and killing it would end the caller's
    # wait early with a bogus exit code.
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [AllowEmptyCollection()][object[]]$Processes = @()
    )

    $parentById = @{}
    foreach ($process in @($Processes)) {
        if ($null -eq $process) { continue }
        $parentById[[int]$process.ProcessId] = [int]$process.ParentProcessId
    }

    $ancestors = [System.Collections.Generic.List[int]]::new()
    $current = $ProcessId
    while ($current -gt 0 -and -not $ancestors.Contains($current)) {
        $ancestors.Add($current)
        if (-not $parentById.ContainsKey($current)) { break }
        $current = $parentById[$current]
    }
    return @($ancestors)
}

function Stop-OpenPathRootedProcess {
    # Stops every process running from, or launched with, the install root and
    # waits for it to exit. Repeats a few rounds so children spawned by a
    # process while it was being stopped are caught too.
    param([int]$MaxRounds = 3, [int]$ExitWaitSeconds = 15)

    for ($round = 0; $round -lt $MaxRounds; $round++) {
        $cimProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $excludedIds = @(Get-OpenPathUninstallAncestorProcessIds -ProcessId $PID -Processes $cimProcesses)
        $processIds = @()

        $processIds += Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Id -notin $excludedIds -and
                $_.Path -and
                $_.Path.StartsWith($OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Select-Object -ExpandProperty Id

        $processIds += $cimProcesses |
            Where-Object {
                $_.ProcessId -notin $excludedIds -and
                $_.CommandLine -like "*$OpenPathRoot*"
            } |
            Select-Object -ExpandProperty ProcessId

        $processIds = @($processIds | Where-Object { $_ } | Select-Object -Unique)
        if ($processIds.Count -eq 0) { return }

        foreach ($processId in $processIds) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        # Stop-Process returns once termination is requested; wait for the exit
        # so a stopped watchdog cannot still be finishing a repair afterwards.
        Wait-Process -Id $processIds -Timeout $ExitWaitSeconds -ErrorAction SilentlyContinue
    }

    Write-Warning "OpenPath processes were still starting after $MaxRounds stop rounds."
}

function Enter-OpenPathUninstallUpdateLock {
    # Global\OpenPathUpdateLock serializes the whitelist update cycle and the
    # watchdog's DNS/firewall repair. Every holder is an OpenPath-rooted process
    # that Stop-OpenPathRootedProcess has already stopped, so this normally
    # succeeds at once (possibly as an abandoned mutex); it is a second line of
    # defense against a holder the process sweep missed. It does NOT cover the
    # watchdog's restricted-group sync or AppControl repair, which run outside
    # this mutex: stopping the processes is what keeps those from racing.
    param([int]$TimeoutSeconds = 60)

    $mutex = $null
    $acquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\OpenPathUpdateLock')
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
    }
    catch {
        if ($mutex) { $mutex.Dispose() }
        Write-Warning "Could not open Global\OpenPathUpdateLock: $_"
        return $null
    }

    if (-not $acquired) {
        if ($mutex) { $mutex.Dispose() }
        throw "Timed out after ${TimeoutSeconds}s waiting for Global\OpenPathUpdateLock; a watchdog or whitelist update is still running."
    }
    return $mutex
}

function Exit-OpenPathUninstallUpdateLock {
    param([AllowNull()][object]$Mutex)

    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
}

function Get-OpenPathUninstallManagedAppLockerRuleCount {
    # Counts OpenPath-managed rules in the local AppLocker policy XML; -1 when
    # AppLocker cannot be queried on this machine.
    param([AllowNull()][string]$PolicyXml)

    # An unbound [string] parameter is '' (never $null), so test whether it was
    # passed rather than whether it is null.
    if (-not $PSBoundParameters.ContainsKey('PolicyXml')) {
        if (-not (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { return -1 }
        try {
            $PolicyXml = [string](Get-AppLockerPolicy -Local -Xml -ErrorAction Stop)
        }
        catch {
            throw 'Unable to inspect local AppLocker policy; manual recovery is required.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($PolicyXml)) { return 0 }

    try { $policyDocument = [xml]$PolicyXml }
    catch { throw 'Unable to inspect local AppLocker policy; manual recovery is required.' }

    $count = 0
    foreach ($rule in @($policyDocument.SelectNodes('//*[@Name]'))) {
        if ($rule -is [System.Xml.XmlElement] -and $rule.GetAttribute('Name') -like 'OpenPath non-admin app control*') {
            $count++
        }
    }
    return $count
}

function Remove-OpenPathFallbackAppLockerRules {
    if ((Get-OpenPathUninstallManagedAppLockerRuleCount) -eq 0) { return $true }

    $modulePath = Join-Path $OpenPathRoot 'lib\AppControl.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw 'AppControl owner module is unavailable; manual recovery is required.'
    }
    Import-Module $modulePath -Force -Global -ErrorAction Stop
    if (-not (Remove-OpenPathNonAdminAppControl -OpenPathRoot $OpenPathRoot -Confirm:$false)) {
        throw 'Central AppControl removal did not verify; manual recovery is required.'
    }
}

function Restore-OpenPathOriginalDns {
    # The restore rule lives in Invoke-OpenPathOriginalDnsRestore (lib\internal\DNS.AdapterSnapshot.ps1).
    # Uninstall policy: keep going past a failing adapter and report each snapshot failure.
    $snapshotPath = Join-Path $OpenPathRoot 'data\original-dns.json'
    $restore = Invoke-OpenPathOriginalDnsRestore -SnapshotPath $snapshotPath -OnAdapterError Continue
    if ($restore.UsedSnapshot) {
        foreach ($restoreError in @($restore.Errors)) {
            Write-Host "  Snapshot DNS restore failed: $restoreError" -ForegroundColor Yellow
        }
    }
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
    $presentIds = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($settingsValue)) {
        if (-not $entry) { continue }
        try { $parsed = [string]$entry | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        foreach ($property in @($parsed.PSObject.Properties)) {
            $presentIds.Add([string]$property.Name)
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
            # The current and legacy ids are always tried; an id that is not in the value is not a failure.
            $storeIdPresent = ($storeId -in $presentIds)
            if (-not $storeCommandAvailable) {
                if ($storeIdPresent) { $storeFailedIds.Add($storeId) }
                continue
            }
            try {
                $removed = Remove-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy ([pscustomobject]@{ ExtensionId = $storeId })
                # $false also means "id not present", which is only a failure when the id was there.
                if (-not $removed -and $storeIdPresent) { $storeFailedIds.Add($storeId) }
            }
            catch {
                Write-Warning "Could not remove Firefox policy entry ${storeId} through the policy store: $_"
                if ($storeIdPresent) { $storeFailedIds.Add($storeId) }
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

function Remove-OpenPathFirewallRules {
    # The teardown (outbound default first, then the audit setting, then the rules) lives in
    # Invoke-OpenPathFirewallTeardown (lib\internal\Firewall.Teardown.ps1). The optional egress
    # floor flips each profile's DefaultOutboundAction to Block; deleting its Allow rules
    # without restoring the default would leave all egress blocked. Uninstall policy: without
    # usable state only profiles that are currently Block are set to Allow; failures warn.
    $outboundStatePath = Join-Path $OpenPathRoot 'data\egress-floor-prev-outbound.json'
    $auditStatePath = Join-Path $OpenPathRoot 'data\egress-floor-audit-prev.json'
    $manifestPath = Join-Path $OpenPathRoot 'data\firewall-rules.json'
    $teardown = Invoke-OpenPathFirewallTeardown -OutboundStatePath $outboundStatePath -AuditStatePath $auditStatePath -ManifestPath $manifestPath -WhenNoState OnlyBlocked -KeepRulesWhenOutboundFails

    foreach ($outboundError in @($teardown.Outbound.Errors)) {
        Write-Warning "Failed restoring $outboundError"
    }
    if ($teardown.RulesKept) {
        Write-Warning "OpenPath firewall rules were kept because a profile could not be restored from Block; restore it with Set-NetFirewallProfile -DefaultOutboundAction Allow, then remove the rules named OpenPath-DNS-*."
    }
    if ($teardown.Outbound.StateUnreadable) {
        Write-Warning "Ignoring unreadable egress-floor state at $outboundStatePath; restoring Allow. $($teardown.Outbound.StateError)"
    }
    if ($teardown.Audit.Error) {
        Write-Warning "Could not restore the Filtering Platform Connection audit setting from ${auditStatePath}: $($teardown.Audit.Error)"
    }
    if ($teardown.Rules.ManifestError) {
        Write-Warning "Ignoring unreadable firewall manifest at $manifestPath; falling back to OpenPath firewall rule discovery. $($teardown.Rules.ManifestError)"
    }
}

function Remove-OpenPathUninstallDnsFailureArtifacts {
    # Removes the control-plane hosts valve and the DNS failure-mode state/cache files.
    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot = 'C:\Windows' }
    $hostsPath = "$systemRoot\System32\drivers\etc\hosts"

    if (Test-Path $hostsPath) {
        try {
            $encoding = [System.Text.Encoding]::GetEncoding(28591)
            $text = $encoding.GetString([System.IO.File]::ReadAllBytes($hostsPath))
            $beginMarker = '# BEGIN OpenPath control-plane valve'
            $endMarker = '# END OpenPath control-plane valve'
            $changed = $false
            while ($true) {
                $startIndex = $text.IndexOf($beginMarker, [System.StringComparison]::Ordinal)
                if ($startIndex -lt 0) { break }
                $endIndex = $text.IndexOf($endMarker, $startIndex, [System.StringComparison]::Ordinal)
                if ($endIndex -lt 0) { break }
                $endIndex += $endMarker.Length
                if ($endIndex -lt $text.Length -and $text[$endIndex] -eq "`r") { $endIndex++ }
                if ($endIndex -lt $text.Length -and $text[$endIndex] -eq "`n") { $endIndex++ }
                if ($startIndex -ge 2 -and $text.Substring($startIndex - 2, 2) -eq "`r`n") {
                    $startIndex -= 2
                }
                elseif ($startIndex -ge 1 -and $text[$startIndex - 1] -eq "`n") {
                    $startIndex -= 1
                }
                $text = $text.Remove($startIndex, $endIndex - $startIndex)
                $changed = $true
            }
            if ($changed) {
                [System.IO.File]::WriteAllBytes($hostsPath, $encoding.GetBytes($text))
            }
        }
        catch {
            Write-Host "  WARNING: Could not remove the control-plane hosts valve: $_" -ForegroundColor Yellow
        }
    }

    foreach ($relativePath in @(
            'data\dns-failure-mode.json',
            'data\control-plane-dns-cache.json',
            'data\acrylic-repair-state.json'
        )) {
        $artifactPath = Join-Path $OpenPathRoot $relativePath
        if (Test-Path $artifactPath) {
            Remove-Item -LiteralPath $artifactPath -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath (Join-Path $OpenPathRoot 'data\cache\acrylic') -Recurse -Force -ErrorAction SilentlyContinue
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
if (Test-Path "$OpenPathRoot\lib\Browser.psm1") {
    Import-Module "$OpenPathRoot\lib\Browser.psm1" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$OpenPathRoot\lib\Services.psm1") {
    Import-Module "$OpenPathRoot\lib\Services.psm1" -Force -ErrorAction SilentlyContinue
}
# Import AppControl last: Browser.psm1 re-imports it with -Force into its own
# scope, which on Windows PowerShell 5.1 drops the copy imported here and leaves
# Remove-OpenPathNonAdminAppControl and Remove-OpenPathRestrictedGroup undefined.
if (Test-Path "$OpenPathRoot\lib\AppControl.psm1") {
    Import-Module "$OpenPathRoot\lib\AppControl.psm1" -Force -ErrorAction SilentlyContinue
}

# Step 1: Remove scheduled tasks
Write-Host "[1/6] Removing scheduled tasks..." -ForegroundColor Yellow
Stop-OpenPathScheduledTask
Write-Host "  Scheduled tasks removed" -ForegroundColor Green

# Stopping a task does not reliably end every process it started. A surviving
# watchdog recreates OpenPath-Restricted and repairs the AppLocker rules when it
# finds them missing, and holds Global\OpenPath-AppControl-v1 while it does, so
# Remove-OpenPathNonAdminAppControl could also give up on a busy lock. Both were
# observed as rollback-group-remains and rollback-openpath-rules-remain in the
# desktop-survival cleanup lane. Stop every rooted process before any removal;
# the tasks are gone, so nothing restarts them.
Stop-OpenPathRootedProcess
Write-Host "  OpenPath processes stopped" -ForegroundColor Green

$uninstallUpdateLock = Enter-OpenPathUninstallUpdateLock
$uninstallLeftovers = @()

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

# Both removals swallow their own failures (the AppControl one also returns
# $false on a busy transaction lock). Record what survived and fail at the end,
# after the remaining steps ran, so a leftover cannot pass as success.
if ((Get-Command -Name Get-LocalGroup -ErrorAction SilentlyContinue) -and
    (Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue)) {
    $uninstallLeftovers += 'OpenPath-Restricted group still exists after uninstall.'
}
if ((Get-OpenPathUninstallManagedAppLockerRuleCount) -gt 0) {
    $uninstallLeftovers += 'OpenPath AppLocker rules remain in the local policy after uninstall.'
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
    # Catch anything started from the install root since Step 1 before the
    # files are deleted.
    Stop-OpenPathRootedProcess
    Exit-OpenPathUninstallUpdateLock -Mutex $uninstallUpdateLock
    Remove-OpenPathUninstallDnsFailureArtifacts

    if ($KeepLogs) {
        Remove-OpenPathInstallRoot -KeepLogs
        Write-Host "  Files removed (logs preserved)" -ForegroundColor Green
    }
    else {
        Remove-OpenPathInstallRoot
        Write-Host "  Files removed" -ForegroundColor Green
    }
}

if ($uninstallLeftovers.Count -gt 0) {
    Exit-OpenPathUninstallUpdateLock -Mutex $uninstallUpdateLock
    Write-Host ""
    Write-Host "UNINSTALL INCOMPLETE:" -ForegroundColor Red
    foreach ($leftover in $uninstallLeftovers) {
        Write-Host "  $leftover" -ForegroundColor Red
    }
    # The install root (and this script) is already gone, so re-running is not
    # an option: name the manual fix instead.
    Write-Host "Remove them manually: Remove-LocalGroup -Name 'OpenPath-Restricted', and delete the 'OpenPath non-admin app control*' rules with secpol.msc or Set-AppLockerPolicy." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  UNINSTALL COMPLETED" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "The system has been restored to its original state."
Write-Host "A restart may be required to apply all changes."
Write-Host ""

# Release the watchdog/whitelist serialization mutex on every path that reached
# the end (the install root may already be absent, so the Step 6 release is not
# guaranteed to run). Releasing twice is harmless.
Exit-OpenPathUninstallUpdateLock -Mutex $uninstallUpdateLock

# Report success explicitly: without this the process exit code is inherited
# from the last native command (for example sc.exe deleting an already absent
# service), which made a successful uninstall look like a failure.
exit 0
