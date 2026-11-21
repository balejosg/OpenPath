function Get-OpenPathCriticalFiles {
    <#
    .SYNOPSIS
        Returns critical files covered by integrity baseline checks
    #>
    $files = @(
        "$script:OpenPathRoot\lib\Common.psm1",
        "$script:OpenPathRoot\lib\ScriptBootstrap.psm1",
        "$script:OpenPathRoot\lib\DNS.psm1",
        "$script:OpenPathRoot\lib\Firewall.psm1",
        "$script:OpenPathRoot\lib\AppControl.psm1",
        "$script:OpenPathRoot\lib\Browser.psm1",
        "$script:OpenPathRoot\lib\Browser.Common.psm1",
        "$script:OpenPathRoot\lib\Browser.FirefoxPolicy.psm1",
        "$script:OpenPathRoot\lib\Browser.FirefoxConfig.psm1",
        "$script:OpenPathRoot\lib\Browser.FirefoxNativeHost.psm1",
        "$script:OpenPathRoot\lib\Browser.Diagnostics.psm1",
        "$script:OpenPathRoot\lib\browser-policy-spec.json",
        "$script:OpenPathRoot\lib\Services.psm1",
        "$script:OpenPathRoot\lib\CaptivePortal.psm1",
        "$script:OpenPathRoot\lib\Update.Runtime.psm1",
        "$script:OpenPathRoot\lib\internal\Common.System.ps1",
        "$script:OpenPathRoot\lib\internal\Common.Config.ps1",
        "$script:OpenPathRoot\lib\internal\Common.Domains.ps1",
        "$script:OpenPathRoot\lib\internal\Common.Http.ps1",
        "$script:OpenPathRoot\lib\internal\Common.Whitelist.ps1",
        "$script:OpenPathRoot\lib\internal\Common.Integrity.ps1",
        "$script:OpenPathRoot\lib\internal\Common.Network.ps1",
        "$script:OpenPathRoot\lib\internal\Common.Update.ps1",
        "$script:OpenPathRoot\lib\internal\AgentReleaseSignature.ps1",
        "$script:OpenPathRoot\lib\agent-release-public-key.xml",
        "$script:OpenPathRoot\lib\internal\CapabilityStorage.ps1",
        "$script:OpenPathRoot\lib\internal\EndpointPosture.ps1",
        "$script:OpenPathRoot\lib\internal\EndpointStateReconciler.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.Bootstrap.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.Shared.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.RuntimeDependency.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.CaptivePortal.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.MessageDispatch.ps1",
        "$script:OpenPathRoot\lib\internal\RuntimeDependency.Worker.ps1",
        "$script:OpenPathRoot\lib\internal\Watchdog.Runtime.ps1",
        "$script:OpenPathRoot\lib\internal\CaptivePortal.RecoveryRunner.ps1",
        # Reversion leaves: dot-sourced by DNS.psm1/Firewall.psm1 under SYSTEM and by the
        # installer and uninstaller; they decide how adapter DNS and the firewall are restored.
        "$script:OpenPathRoot\lib\internal\DNS.AdapterSnapshot.ps1",
        # W-5: WindowsRoot.ps1 is dot-sourced first by every SYSTEM-run script and module
        # to resolve $OpenPathRoot. The native-messaging host and the install/bootstrap
        # helpers are likewise dot-sourced under SYSTEM. Replacing any of them yields SYSTEM
        # code execution, so they belong in the integrity baseline alongside the other
        # SYSTEM-reachable scripts.
        "$script:OpenPathRoot\lib\internal\WindowsRoot.ps1",
        # The root launcher is the AgentUpdate task entry point. A zero-filled
        # or replaced launcher runs SYSTEM code and cannot be recovered by the
        # watchdog unless the launcher itself is tracked.
        "$script:OpenPathRoot\OpenPath.ps1",
        "$script:OpenPathRoot\scripts\OpenPath-NativeHost.ps1",
        "$script:OpenPathRoot\scripts\Update-OpenPath.ps1",
        "$script:OpenPathRoot\scripts\Test-DNSHealth.ps1",
        "$script:OpenPathRoot\scripts\Start-SSEListener.ps1",
        "$script:OpenPathRoot\scripts\Apply-RuntimeDependencyQueue.ps1",
        "$script:OpenPathRoot\scripts\Start-RuntimeDependencyWorker.ps1",
        "$script:OpenPathRoot\scripts\Recover-CaptivePortal.ps1",
        "$script:OpenPathRoot\scripts\Recover-OpenPathAgentUpdate.ps1",
        "$script:OpenPathRoot\scripts\Test-OpenPathAgentUpdateHealth.ps1"
    )

    # W-5: include the install/bootstrap helpers under lib\install (all dot-sourced by the
    # SYSTEM-run installer). Enumerated dynamically so new install helpers are covered
    # automatically; missing files are dropped by the Test-Path filter below.
    $installDir = "$script:OpenPathRoot\lib\install"
    if (Test-Path $installDir) {
        $files += @(
            Get-ChildItem -Path $installDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName }
        )
    }

    # Phase 5: the compiled native host is generated at install/update time under
    # the restricted runtime root and is launched by the student's browser, so a
    # tampered binary would be a boundary escape. Covered whenever it exists.
    $nativeHostExecutable = "$script:OpenPathRoot\browser-extension\firefox\native\OpenPath-NativeHost.exe"
    if (Test-Path -LiteralPath $nativeHostExecutable -PathType Leaf) {
        $files += $nativeHostExecutable
    }

    return $files | Where-Object { Test-Path $_ }
}

function Get-OpenPathRelativePath {
    <#
    .SYNOPSIS
        Converts an absolute OpenPath path into a path relative to C:\OpenPath
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path.StartsWith($script:OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($script:OpenPathRoot.Length).TrimStart('\')
    }

    return [System.IO.Path]::GetFileName($Path)
}

function Save-OpenPathIntegrityBackup {
    <#
    .SYNOPSIS
        Saves backup copies of critical files used for integrity restoration
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess($script:IntegrityBackupPath, 'Save integrity backup')) {
        return $false
    }

    try {
        New-Item -ItemType Directory -Path $script:IntegrityBackupPath -Force | Out-Null

        foreach ($file in Get-OpenPathCriticalFiles) {
            $relativePath = Get-OpenPathRelativePath -Path $file
            $backupPath = Join-Path $script:IntegrityBackupPath $relativePath
            $backupDir = Split-Path $backupPath -Parent
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }

            $tempPath = "$backupPath.openpath-update-integrity-$([guid]::NewGuid().ToString('N')).tmp"
            try {
                Copy-OpenPathAgentUpdateFileDurable -SourcePath $file -DestinationPath $tempPath | Out-Null
                Move-OpenPathAgentUpdateFileIntoPlace -TempPath $tempPath -DestinationPath $backupPath
            }
            finally {
                if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Write-OpenPathLog 'Integrity backup saved'
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to save integrity backup: $_" -Level WARN
        return $false
    }
}

function New-OpenPathIntegrityBaseline {
    <#
    .SYNOPSIS
        Creates integrity baseline hashes for critical files
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess($script:IntegrityBaselinePath, 'Generate integrity baseline')) {
        return $false
    }

    try {
        $entries = @()
        foreach ($file in Get-OpenPathCriticalFiles) {
            $hash = (Get-FileHash -Path $file -Algorithm SHA256 -ErrorAction Stop).Hash
            $entries += [PSCustomObject]@{
                path = $file
                hash = $hash
            }
        }

        $baseline = [PSCustomObject]@{
            generatedAt = (Get-Date -Format 'o')
            entryCount = $entries.Count
            entries = $entries
        }

        Write-OpenPathAtomicJsonFile -Path $script:IntegrityBaselinePath -Data $baseline -Depth 10
        Write-OpenPathLog "Integrity baseline generated for $($entries.Count) files"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to generate integrity baseline: $_" -Level ERROR
        return $false
    }
}

function Update-OpenPathIntegrityEntry {
    <#
    .SYNOPSIS
        Re-blesses a single tracked file in the integrity backup and baseline
    .DESCRIPTION
        Files that the agent legitimately regenerates outside a self-update (the
        compiled native host) would otherwise be reverted by the watchdog to the
        previous backup, which makes the next cycle rebuild them again. Only the
        entry for Path is refreshed so tampering with any other file is not
        hidden. Returns $false (never throws) when the baseline does not track
        the path or on error.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $script:IntegrityBaselinePath) -or
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $false
        }

        $baseline = Get-Content -LiteralPath $script:IntegrityBaselinePath -Raw | ConvertFrom-Json
        $entries = @($baseline.entries)
        $entry = $entries | Where-Object { [string]$_.path -ieq $Path } | Select-Object -First 1
        if (-not $entry) {
            return $false
        }

        $backupPath = Join-Path $script:IntegrityBackupPath (Get-OpenPathRelativePath -Path ([string]$entry.path))
        $backupDir = Split-Path $backupPath -Parent
        if (-not (Test-Path -LiteralPath $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $tempPath = "$backupPath.openpath-update-integrity-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            Copy-OpenPathAgentUpdateFileDurable -SourcePath $Path -DestinationPath $tempPath | Out-Null
            Move-OpenPathAgentUpdateFileIntoPlace -TempPath $tempPath -DestinationPath $backupPath
        }
        finally {
            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }

        $entry.hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        Write-OpenPathAtomicJsonFile -Path $script:IntegrityBaselinePath -Data $baseline -Depth 10
        Write-OpenPathLog "Integrity entry refreshed for $Path"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to refresh integrity entry for ${Path}: $_" -Level WARN
        return $false
    }
}

function Test-OpenPathIntegrity {
    <#
    .SYNOPSIS
        Checks critical files against the integrity baseline
    #>
    $result = [ordered]@{
        Healthy = $true
        BaselinePresent = $false
        CheckedFiles = 0
        TamperedFiles = @()
        MissingFiles = @()
        Errors = @()
    }

    if (-not (Test-Path $script:IntegrityBaselinePath)) {
        return [PSCustomObject]$result
    }

    $result.BaselinePresent = $true

    try {
        $baseline = Get-Content $script:IntegrityBaselinePath -Raw | ConvertFrom-Json
        $entries = @($baseline.entries)
    }
    catch {
        $result.Healthy = $false
        $result.Errors += "Invalid integrity baseline: $_"
        return [PSCustomObject]$result
    }

    foreach ($entry in $entries) {
        $path = [string]$entry.path
        $expectedHash = [string]$entry.hash
        if (-not $path -or -not $expectedHash) {
            continue
        }

        $result.CheckedFiles += 1

        if (-not (Test-Path $path)) {
            $result.MissingFiles += $path
            continue
        }

        try {
            $currentHash = (Get-FileHash -Path $path -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($currentHash -ne $expectedHash) {
                $result.TamperedFiles += $path
            }
        }
        catch {
            $result.Errors += "Unable to hash $path : $_"
        }
    }

    if (($result.TamperedFiles.Count -gt 0) -or ($result.MissingFiles.Count -gt 0) -or ($result.Errors.Count -gt 0)) {
        $result.Healthy = $false
    }

    return [PSCustomObject]$result
}

function Restore-OpenPathIntegrity {
    <#
    .SYNOPSIS
        Attempts bounded restoration of integrity using local backup copies
    .PARAMETER IntegrityResult
        Optional result from Test-OpenPathIntegrity to avoid re-checking
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$IntegrityResult
    )

    if (-not $IntegrityResult) {
        $IntegrityResult = Test-OpenPathIntegrity
    }

    if (-not $IntegrityResult.BaselinePresent) {
        $baselineCreated = New-OpenPathIntegrityBaseline
        return [PSCustomObject]@{
            RestoredFiles = @()
            PendingFiles = @()
            Healthy = [bool]$baselineCreated
            BaselineRecreated = [bool]$baselineCreated
        }
    }

    $restoredFiles = @()
    $pendingFiles = @()
    $targets = @($IntegrityResult.MissingFiles + $IntegrityResult.TamperedFiles)
    $targets = @($targets | Sort-Object -Unique)

    $baselineEntries = @()
    try {
        $baselineForRestore = Get-Content -LiteralPath $script:IntegrityBaselinePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $baselineEntries = @($baselineForRestore.entries)
    }
    catch {
        $baselineEntries = @()
    }

    foreach ($path in $targets) {
        $relativePath = Get-OpenPathRelativePath -Path $path
        $backupPath = Join-Path $script:IntegrityBackupPath $relativePath

        $baselineEntry = $baselineEntries | Where-Object { [string]$_.path -ieq $path } | Select-Object -First 1
        $expectedHash = if ($baselineEntry) { [string]$baselineEntry.hash } else { '' }
        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            $pendingFiles += $path
            continue
        }

        if (-not (Test-Path $backupPath)) {
            $pendingFiles += $path
            continue
        }

        $backupHash = ''
        try {
            $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            $pendingFiles += $path
            continue
        }
        if (-not [string]::Equals($backupHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $pendingFiles += $path
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($path, "Restore from $backupPath")) {
            $pendingFiles += $path
            continue
        }

        $tempPath = "$path.openpath-update-integrity-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            $destinationDir = Split-Path $path -Parent
            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }

            $copiedHash = Copy-OpenPathAgentUpdateFileDurable -SourcePath $backupPath -DestinationPath $tempPath
            if (-not [string]::Equals($copiedHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                $pendingFiles += $path
                continue
            }
            Move-OpenPathAgentUpdateFileIntoPlace -TempPath $tempPath -DestinationPath $path
            $restoredFiles += $path
        }
        catch {
            $pendingFiles += $path
            Write-OpenPathLog "Failed to restore $path : $_" -Level WARN
        }
        finally {
            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($restoredFiles.Count -gt 0) {
        New-OpenPathIntegrityBaseline | Out-Null
    }

    $postCheck = Test-OpenPathIntegrity
    return [PSCustomObject]@{
        RestoredFiles = $restoredFiles
        PendingFiles = ($pendingFiles | Sort-Object -Unique)
        Healthy = [bool]$postCheck.Healthy
        BaselineRecreated = $false
    }
}
