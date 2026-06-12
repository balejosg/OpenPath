# OpenPath browser diagnostics for Windows

Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxPolicy.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.FirefoxNativeHost.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\RequestSetup.State.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.RequestReadiness.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction Stop

function Get-OpenPathBrowserDoctorScheduledTaskDiagnostic {
    <#
    .SYNOPSIS
    Probes a scheduled task for presence and user-access permissions, with a hard timeout to
    prevent the browser doctor report from hanging indefinitely.

    .DESCRIPTION
    The check runs in a subprocess using an encoded command so that COM-based task-scheduler
    access does not block the caller.  If the subprocess does not complete within
    TimeoutMilliseconds the process is killed and a timeout result is returned.  The returned
    object always has Present, UserAccess, and Status fields regardless of the outcome.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [int]$TimeoutMilliseconds = 5000
    )

    $fallback = [PSCustomObject]@{
        Present = $false
        UserAccess = 'missing'
        Status = 'missing'
    }

    $taskNameLiteral = $TaskName.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
`$taskName = '$taskNameLiteral'

try {
    `$null = Get-ScheduledTask -TaskName `$taskName -ErrorAction Stop
    `$securityDescriptor = `$null

    try {
        `$schedule = New-Object -ComObject 'Schedule.Service'
        `$schedule.Connect()
        `$task = `$schedule.GetFolder('\').GetTask(`$taskName)
        `$securityDescriptor = [string]`$task.GetSecurityDescriptor(0xF)
    }
    catch {
        `$securityDescriptor = `$null
    }

    `$userAccess = 'unknown'
    if (`$securityDescriptor -and `$securityDescriptor -match '\(A;;[^)]*(?:GX|GA)[^)]*;;;BU\)') {
        `$userAccess = 'granted'
    }
    elseif (`$securityDescriptor) {
        `$userAccess = 'missing'
    }

    [PSCustomObject]@{
        present = `$true
        userAccess = `$userAccess
        status = 'ok'
    } | ConvertTo-Json -Compress
}
catch {
    [PSCustomObject]@{
        present = `$false
        userAccess = 'missing'
        status = 'missing'
    } | ConvertTo-Json -Compress
}
"@

    try {
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'powershell.exe'
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($startInfo)
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill()
                $process.WaitForExit(1000) | Out-Null
            }
            catch {
                # Best-effort cleanup; the diagnostic should still return promptly.
            }

            return [PSCustomObject]@{
                Present = $false
                UserAccess = 'unknown'
                Status = 'Native host update task check timed out'
            }
        }

        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        if (-not $stdout) {
            return $fallback
        }

        $result = $stdout | ConvertFrom-Json -ErrorAction Stop
        return [PSCustomObject]@{
            Present = [bool]$result.present
            UserAccess = if ($result.userAccess) { [string]$result.userAccess } else { 'missing' }
            Status = if ($result.status) { [string]$result.status } else { 'unknown' }
        }
    }
    catch {
        return [PSCustomObject]@{
            Present = $false
            UserAccess = 'unknown'
            Status = "error: $($_.Exception.Message)"
        }
    }
}

function Get-OpenPathBrowserDoctorEvidence {
    <#
    .SYNOPSIS
    Gathers all browser diagnostic evidence into a structured object for use by the doctor report.

    .DESCRIPTION
    Probes the Firefox metadata file, XPI artifact, native host manifest, registry entries, state
    file, whitelist file, and Firefox machine policy.  Also queries the browser inventory for
    approved, unmanaged, and portable-risk findings, and evaluates request readiness from the
    native host state.  The returned structured object is consumed by the report formatter; it is
    not intended for direct operator use.
    #>
    $browserInventory = Get-OpenPathBrowserInventory
    $approvedBrowserSummary = if (@($browserInventory.ApprovedBrowsers).Count -gt 0) {
        @($browserInventory.ApprovedBrowsers | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', '
    }
    else {
        '(none)'
    }
    $unmanagedBrowserSummary = if (@($browserInventory.UnmanagedBrowsers).Count -gt 0) {
        @($browserInventory.UnmanagedBrowsers | ForEach-Object {
                if ($_.Path) { "$($_.Name) ($($_.Path))" }
                elseif ($_.DisplayName) { "$($_.Name) ($($_.DisplayName))" }
                else { $_.Name }
            }) -join '; '
    }
    else {
        '(none)'
    }
    $portableBrowserRiskSummary = if (@($browserInventory.PortableBrowserRisks).Count -gt 0) {
        @($browserInventory.PortableBrowserRisks | ForEach-Object {
                if ($_.Path) { $_.Path } else { $_.Name }
            }) -join '; '
    }
    else {
        '(none)'
    }
    $webRenderingSurfaceSummary = if (@($browserInventory.WebRenderingSurfaces).Count -gt 0) {
        @($browserInventory.WebRenderingSurfaces | ForEach-Object {
                if ($_.DisplayName) { $_.DisplayName }
                elseif ($_.Path) { "$($_.Name) ($($_.Path))" }
                else { $_.Name }
            }) -join '; '
    }
    else {
        '(none)'
    }

    $metadataPath = Get-OpenPathFirefoxReleaseMetadataPath
    $xpiPath = Get-OpenPathFirefoxReleaseXpiPath
    $nativeHostManifestPath = Get-OpenPathFirefoxNativeHostManifestPath
    $nativeHostWrapperPath = Get-OpenPathFirefoxNativeHostWrapperPath
    $nativeHostScriptPath = Get-OpenPathFirefoxNativeHostScriptPath
    $nativeHostStateHelperPath = Join-Path (Get-OpenPathFirefoxNativeHostRoot) 'NativeHost.State.ps1'
    $nativeHostProtocolHelperPath = Join-Path (Get-OpenPathFirefoxNativeHostRoot) 'NativeHost.Protocol.ps1'
    $nativeHostActionsHelperPath = Join-Path (Get-OpenPathFirefoxNativeHostRoot) 'NativeHost.Actions.ps1'
    $nativeHostStatePath = Get-OpenPathFirefoxNativeStatePath
    $nativeHostWhitelistPath = Get-OpenPathFirefoxNativeWhitelistMirrorPath
    $nativeHostUpdateTaskName = Get-OpenPathFirefoxNativeHostUpdateTaskName
    $nativeHostRegistryPaths = Get-OpenPathFirefoxNativeHostRegistryPaths
    $nativeHostRegistrySummary = '(missing)'
    $nativeHostManifestParse = 'missing'
    $nativeHostManifestName = '(missing)'
    $nativeHostAllowedExtensions = '(missing)'
    $nativeHostRegistryPath = ($nativeHostRegistryPaths -join '; ')
    $nativeHostWrapperPresent = Test-Path $nativeHostWrapperPath
    $nativeHostScriptPresent = Test-Path $nativeHostScriptPath
    $nativeHostStateHelperReadable = $false
    $nativeHostProtocolHelperReadable = $false
    $nativeHostActionsHelperReadable = $false
    $nativeHostStateReadable = $false
    $nativeHostWhitelistReadable = $false
    $nativeHostRequestApiConfigured = $false
    $nativeHostWhitelistTokenConfigured = $false
    $nativeHostRequestSetupComplete = $false
    $nativeHostRequestSetupState = $null
    $nativeHostUpdateTaskPresent = $false
    $nativeHostUpdateTaskUserAccess = 'missing'
    $nativeHostUpdateTaskCheck = 'missing'
    $policyCandidates = @(
        "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json"
    )
    $policyPath = @($policyCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)[0]
    if (-not $policyPath) {
        $policyPath = $policyCandidates[0]
    }

    $metadataPresent = Test-Path $metadataPath
    $xpiPresent = Test-Path $xpiPath
    $metadataParseResult = 'missing'
    $policyParseResult = 'missing'
    $policyEncoding = 'missing'
    $policyInstallMode = '(missing)'
    $policyInstallUrl = '(missing)'
    $machineFirefoxPolicy = 'missing'
    $machineFirefoxPolicyInstallUrl = '(missing)'
    $extensionId = '(missing)'
    $extensionVersion = '(missing)'
    $metadataSha256 = '(missing)'
    $xpiSha256 = '(missing)'
    $xpiBytes = 0
    $aclSummary = 'missing'

    if ($metadataPresent) {
        try {
            $metadataText = Get-Content $metadataPath -Raw
            $metadata = $metadataText | ConvertFrom-Json
            $extensionId = if ($metadata.extensionId) { [string]$metadata.extensionId } else { '(missing)' }
            $extensionVersion = if ($metadata.version) { [string]$metadata.version } else { '(missing)' }
            $metadataSha256 = (Get-FileHash $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $metadataParseResult = 'ok'
        }
        catch {
            $metadataParseResult = "error: $($_.Exception.Message)"
        }
    }

    if ($xpiPresent) {
        try {
            $xpiItem = Get-Item $xpiPath
            $xpiBytes = [int64]$xpiItem.Length
            $xpiSha256 = (Get-FileHash $xpiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        catch {
            $xpiSha256 = "error: $($_.Exception.Message)"
        }

        try {
            $aclSummary = @(
                (Get-Acl $xpiPath).Access |
                    Select-Object IdentityReference, FileSystemRights, AccessControlType |
                    ForEach-Object {
                        "$($_.IdentityReference):$($_.FileSystemRights):$($_.AccessControlType)"
                    } |
                    Select-Object -Unique
            ) -join '; '

            if (-not $aclSummary) {
                $aclSummary = 'none'
            }
        }
        catch {
            $aclSummary = "error: $($_.Exception.Message)"
        }
    }

    if (Test-Path $nativeHostManifestPath) {
        try {
            $nativeManifest = Get-Content $nativeHostManifestPath -Raw | ConvertFrom-Json
            $nativeHostManifestParse = 'ok'
            $nativeHostManifestName = if ($nativeManifest.name) { [string]$nativeManifest.name } else { '(missing)' }
            $nativeHostAllowedExtensions = if ($nativeManifest.allowed_extensions) {
                @($nativeManifest.allowed_extensions) -join ', '
            }
            else {
                '(missing)'
            }
        }
        catch {
            $nativeHostManifestParse = "error: $($_.Exception.Message)"
        }
    }

    try {
        if (Test-Path $nativeHostStateHelperPath) {
            $null = Get-Content $nativeHostStateHelperPath -TotalCount 1 -ErrorAction Stop
            $nativeHostStateHelperReadable = $true
        }
    }
    catch {
        $nativeHostStateHelperReadable = $false
    }

    try {
        if (Test-Path $nativeHostProtocolHelperPath) {
            $null = Get-Content $nativeHostProtocolHelperPath -TotalCount 1 -ErrorAction Stop
            $nativeHostProtocolHelperReadable = $true
        }
    }
    catch {
        $nativeHostProtocolHelperReadable = $false
    }

    try {
        if (Test-Path $nativeHostActionsHelperPath) {
            $null = Get-Content $nativeHostActionsHelperPath -TotalCount 1 -ErrorAction Stop
            $nativeHostActionsHelperReadable = $true
        }
    }
    catch {
        $nativeHostActionsHelperReadable = $false
    }

    $nativeHostRegistryStates = @()
    foreach ($registryPath in $nativeHostRegistryPaths) {
        try {
            $query = & reg.exe QUERY $registryPath /ve 2>$null
            if ($LASTEXITCODE -eq 0) {
                $nativeHostRegistryStates += "$registryPath=present"
            }
            else {
                $nativeHostRegistryStates += "$registryPath=missing"
            }
        }
        catch {
            $nativeHostRegistryStates += "$registryPath=error"
        }
    }
    if ($nativeHostRegistryStates.Count -gt 0) {
        $nativeHostRegistrySummary = $nativeHostRegistryStates -join '; '
    }

    try {
        if (Test-Path $nativeHostStatePath) {
            $nativeHostState = Get-Content $nativeHostStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
            $nativeHostStateReadable = $true

            $nativeHostRequestSetupState = Get-OpenPathRequestSetupState -Config $nativeHostState
            $nativeHostRequestApiConfigured = [bool]$nativeHostRequestSetupState.ApiUrlConfigured
            $nativeHostWhitelistTokenConfigured = [bool]$nativeHostRequestSetupState.WhitelistTokenConfigured
            $nativeHostRequestSetupComplete = [bool]$nativeHostRequestSetupState.Ready
        }
    }
    catch {
        $nativeHostStateReadable = $false
        $nativeHostRequestApiConfigured = $false
        $nativeHostWhitelistTokenConfigured = $false
        $nativeHostRequestSetupComplete = $false
    }

    try {
        if (Test-Path $nativeHostWhitelistPath) {
            $null = Get-Content $nativeHostWhitelistPath -TotalCount 1 -ErrorAction Stop
            $nativeHostWhitelistReadable = $true
        }
    }
    catch {
        $nativeHostWhitelistReadable = $false
    }

    $nativeHostUpdateTaskDiagnostic = Get-OpenPathBrowserDoctorScheduledTaskDiagnostic -TaskName $nativeHostUpdateTaskName
    $nativeHostUpdateTaskPresent = $nativeHostUpdateTaskDiagnostic.Present
    $nativeHostUpdateTaskUserAccess = $nativeHostUpdateTaskDiagnostic.UserAccess
    $nativeHostUpdateTaskCheck = $nativeHostUpdateTaskDiagnostic.Status

    $managedExtensionPolicy = Get-OpenPathFirefoxManagedExtensionPolicy
    $resolvedInstallUrl = if ($managedExtensionPolicy) {
        [string]$managedExtensionPolicy.InstallUrl
    }
    else {
        '(unresolved)'
    }
    $machineFirefoxPolicyApplied = Test-OpenPathFirefoxMachineExtensionPolicy -ManagedExtensionPolicy $managedExtensionPolicy
    $machineFirefoxPolicy = if ($machineFirefoxPolicyApplied) { 'ready' } else { 'missing' }
    if ($managedExtensionPolicy -and $managedExtensionPolicy.ExtensionId) {
        try {
            $machineSettings = Get-OpenPathFirefoxMachineExtensionSettings
            if ($machineSettings.Contains([string]$managedExtensionPolicy.ExtensionId)) {
                $machineEntry = $machineSettings[[string]$managedExtensionPolicy.ExtensionId]
                if ($machineEntry.PSObject.Properties['install_url']) {
                    $machineFirefoxPolicyInstallUrl = [string]$machineEntry.install_url
                }
            }
        }
        catch {
            $machineFirefoxPolicyInstallUrl = "error: $($_.Exception.Message)"
        }
    }
    $nativeHostRegistered = [bool](
        $nativeHostManifestParse -eq 'ok' -and
        $nativeHostWrapperPresent -and
        $nativeHostScriptPresent -and
        (@($nativeHostRegistryStates | Where-Object { $_ -like '*=present' }).Count -gt 0)
    )
    $browserRequestReadiness = Get-OpenPathBrowserRequestReadiness `
        -Config $nativeHostRequestSetupState `
        -ManagedExtensionPolicy $managedExtensionPolicy `
        -NativeHostRegistered $nativeHostRegistered `
        -NativeHostStatePresent $nativeHostStateReadable `
        -FirefoxMachinePolicyApplied $machineFirefoxPolicyApplied
    $browserRequestReadinessFacts = @(
        "request_setup=$($browserRequestReadiness.Facts.request_setup)"
        "firefox_managed_extension=$($browserRequestReadiness.Facts.firefox_managed_extension)"
        "firefox_machine_policy=$($browserRequestReadiness.Facts.firefox_machine_policy)"
        "firefox_native_host=$($browserRequestReadiness.Facts.firefox_native_host)"
    ) -join '; '
    $browserRequestReadinessFailures = if (@($browserRequestReadiness.FailureReasons).Count -gt 0) {
        @($browserRequestReadiness.FailureReasons) -join '; '
    }
    else {
        '(none)'
    }

    if (Test-Path $policyPath) {
        try {
            $policyBytes = [System.IO.File]::ReadAllBytes($policyPath)
            $hasUtf8Bom = $policyBytes.Length -ge 3 -and $policyBytes[0] -eq 239 -and $policyBytes[1] -eq 187 -and $policyBytes[2] -eq 191
            $policyEncoding = if ($hasUtf8Bom) { 'utf8-bom' } else { 'utf8-no-bom' }

            $policyJson = Get-Content $policyPath -Raw | ConvertFrom-Json
            $policyParseResult = 'ok'

            $policyEntry = $null
            if ($extensionId -ne '(missing)' -and $policyJson.policies -and $policyJson.policies.ExtensionSettings) {
                $policyEntry = $policyJson.policies.ExtensionSettings.PSObject.Properties[$extensionId]
                if ($policyEntry) {
                    $policyValue = $policyEntry.Value
                    if ($policyValue.PSObject.Properties['installation_mode']) {
                        $policyInstallMode = [string]$policyValue.installation_mode
                    }
                    if ($policyValue.PSObject.Properties['install_url']) {
                        $policyInstallUrl = [string]$policyValue.install_url
                    }
                }
            }
        }
        catch {
            $policyParseResult = "error: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        BrowserInventory = [PSCustomObject]@{
            ApprovedBrowserSummary = $approvedBrowserSummary
            UnmanagedBrowserSummary = $unmanagedBrowserSummary
            PortableBrowserRiskSummary = $portableBrowserRiskSummary
            WebRenderingSurfaceSummary = $webRenderingSurfaceSummary
            Raw = $browserInventory
        }
        Firefox = [PSCustomObject]@{
            MetadataPath = $metadataPath
            MetadataPresent = $metadataPresent
            MetadataParseResult = $metadataParseResult
            ExtensionId = $extensionId
            ExtensionVersion = $extensionVersion
            MetadataSha256 = $metadataSha256
            XpiPath = $xpiPath
            XpiPresent = $xpiPresent
            XpiBytes = $xpiBytes
            XpiSha256 = $xpiSha256
            XpiAclSummary = $aclSummary
            ResolvedInstallUrl = $resolvedInstallUrl
        }
        NativeHost = [PSCustomObject]@{
            ManifestPath = $nativeHostManifestPath
            ManifestParse = $nativeHostManifestParse
            ManifestName = $nativeHostManifestName
            AllowedExtensions = $nativeHostAllowedExtensions
            RegistryPath = $nativeHostRegistryPath
            RegistrySummary = $nativeHostRegistrySummary
            WrapperPath = $nativeHostWrapperPath
            WrapperPresent = $nativeHostWrapperPresent
            ScriptPath = $nativeHostScriptPath
            ScriptPresent = $nativeHostScriptPresent
            StateHelperReadable = $nativeHostStateHelperReadable
            ProtocolHelperReadable = $nativeHostProtocolHelperReadable
            ActionsHelperReadable = $nativeHostActionsHelperReadable
            StatePath = $nativeHostStatePath
            StateReadable = $nativeHostStateReadable
            WhitelistReadable = $nativeHostWhitelistReadable
            RequestSetup = [PSCustomObject]@{
                ApiUrlConfigured = $nativeHostRequestApiConfigured
                WhitelistTokenConfigured = $nativeHostWhitelistTokenConfigured
                Ready = $nativeHostRequestSetupComplete
                State = $nativeHostRequestSetupState
            }
            UpdateTaskName = $nativeHostUpdateTaskName
            UpdateTaskCheck = $nativeHostUpdateTaskCheck
            UpdateTaskPresent = $nativeHostUpdateTaskPresent
            UpdateTaskUserAccess = $nativeHostUpdateTaskUserAccess
        }
        BrowserRequestReadiness = [PSCustomObject]@{
            Ready = [bool]$browserRequestReadiness.Ready
            Facts = $browserRequestReadiness.Facts
            FactSummary = $browserRequestReadinessFacts
            FailureReasons = @($browserRequestReadiness.FailureReasons)
            FailureSummary = $browserRequestReadinessFailures
            Raw = $browserRequestReadiness
        }
        MachineFirefoxPolicy = [PSCustomObject]@{
            Status = $machineFirefoxPolicy
            InstallUrl = $machineFirefoxPolicyInstallUrl
        }
        Policy = [PSCustomObject]@{
            Path = $policyPath
            Present = (Test-Path $policyPath)
            Encoding = $policyEncoding
            JsonParse = $policyParseResult
            InstallMode = $policyInstallMode
            InstallUrl = $policyInstallUrl
        }
    }
}

function ConvertTo-OpenPathBrowserDoctorReport {
    <#
    .SYNOPSIS
    Formats a structured evidence object as a human-readable multi-line diagnostics report string.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Evidence
    )

    return @(
        'OpenPath Browser Doctor'
        "Firefox metadata path: $($Evidence.Firefox.MetadataPath)"
        "Firefox metadata present: $($Evidence.Firefox.MetadataPresent)"
        "Firefox metadata parse: $($Evidence.Firefox.MetadataParseResult)"
        "Firefox extension id: $($Evidence.Firefox.ExtensionId)"
        "Firefox extension version: $($Evidence.Firefox.ExtensionVersion)"
        "Firefox metadata sha256: $($Evidence.Firefox.MetadataSha256)"
        "Firefox XPI path: $($Evidence.Firefox.XpiPath)"
        "Firefox XPI present: $($Evidence.Firefox.XpiPresent)"
        "Firefox XPI bytes: $($Evidence.Firefox.XpiBytes)"
        "Firefox XPI sha256: $($Evidence.Firefox.XpiSha256)"
        "Firefox XPI ACL summary: $($Evidence.Firefox.XpiAclSummary)"
        "Native host manifest path: $($Evidence.NativeHost.ManifestPath)"
        "Native host manifest parse: $($Evidence.NativeHost.ManifestParse)"
        "Native host manifest name: $($Evidence.NativeHost.ManifestName)"
        "Native host allowed extensions: $($Evidence.NativeHost.AllowedExtensions)"
        "Native host registry path: $($Evidence.NativeHost.RegistryPath)"
        "Native host registry summary: $($Evidence.NativeHost.RegistrySummary)"
        "Native host wrapper path: $($Evidence.NativeHost.WrapperPath)"
        "Native host wrapper present: $($Evidence.NativeHost.WrapperPresent)"
        "Native host script path: $($Evidence.NativeHost.ScriptPath)"
        "Native host script present: $($Evidence.NativeHost.ScriptPresent)"
        "Native host state helper readable: $($Evidence.NativeHost.StateHelperReadable)"
        "Native host protocol helper readable: $($Evidence.NativeHost.ProtocolHelperReadable)"
        "Native host actions helper readable: $($Evidence.NativeHost.ActionsHelperReadable)"
        "Native host state path: $($Evidence.NativeHost.StatePath)"
        "Native host state readable: $($Evidence.NativeHost.StateReadable)"
        "Native host whitelist readable: $($Evidence.NativeHost.WhitelistReadable)"
        "Native host request API configured: $($Evidence.NativeHost.RequestSetup.ApiUrlConfigured)"
        "Native host whitelist token configured: $($Evidence.NativeHost.RequestSetup.WhitelistTokenConfigured)"
        "Native host request setup complete: $($Evidence.NativeHost.RequestSetup.Ready)"
        "Native host update task: $($Evidence.NativeHost.UpdateTaskName)"
        "Native host update task check: $($Evidence.NativeHost.UpdateTaskCheck)"
        "Native host update task present: $($Evidence.NativeHost.UpdateTaskPresent)"
        "Native host update task user access: $($Evidence.NativeHost.UpdateTaskUserAccess)"
        "Browser request readiness: $($Evidence.BrowserRequestReadiness.Ready)"
        "Browser request readiness facts: $($Evidence.BrowserRequestReadiness.FactSummary)"
        "Browser request readiness failures: $($Evidence.BrowserRequestReadiness.FailureSummary)"
        "Approved managed browsers: $($Evidence.BrowserInventory.ApprovedBrowserSummary)"
        "Unmanaged browsers detected: $($Evidence.BrowserInventory.UnmanagedBrowserSummary)"
        "Portable browser risk: $($Evidence.BrowserInventory.PortableBrowserRiskSummary)"
        "Web rendering surfaces: $($Evidence.BrowserInventory.WebRenderingSurfaceSummary)"
        "Resolved install_url: $($Evidence.Firefox.ResolvedInstallUrl)"
        "Machine Firefox policy: $($Evidence.MachineFirefoxPolicy.Status)"
        "Machine Firefox policy install_url: $($Evidence.MachineFirefoxPolicy.InstallUrl)"
        "Policy file path: $($Evidence.Policy.Path)"
        "Policy file present: $($Evidence.Policy.Present)"
        "Policy encoding: $($Evidence.Policy.Encoding)"
        "Policy JSON parse: $($Evidence.Policy.JsonParse)"
        "Policy install mode: $($Evidence.Policy.InstallMode)"
        "Policy install_url: $($Evidence.Policy.InstallUrl)"
    ) -join [Environment]::NewLine
}

function Get-OpenPathBrowserDoctorReport {
    <#
    .SYNOPSIS
    Collects live browser diagnostic evidence and returns it as a formatted operator-facing report string.
    #>
    return ConvertTo-OpenPathBrowserDoctorReport -Evidence (Get-OpenPathBrowserDoctorEvidence)
}

Export-ModuleMember -Function @(
    'Get-OpenPathBrowserDoctorEvidence',
    'Get-OpenPathBrowserDoctorReport',
    'Get-OpenPathBrowserDoctorScheduledTaskDiagnostic'
)
