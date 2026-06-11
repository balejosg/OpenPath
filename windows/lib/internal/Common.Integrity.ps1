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
        "$script:OpenPathRoot\lib\internal\CapabilityStorage.ps1",
        "$script:OpenPathRoot\lib\internal\EndpointStateReconciler.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.Bootstrap.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.Shared.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.RuntimeDependency.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.CaptivePortal.ps1",
        "$script:OpenPathRoot\lib\internal\NativeHost.Actions.MessageDispatch.ps1",
        "$script:OpenPathRoot\lib\internal\Watchdog.Runtime.ps1",
        "$script:OpenPathRoot\scripts\Update-OpenPath.ps1",
        "$script:OpenPathRoot\scripts\Test-DNSHealth.ps1",
        "$script:OpenPathRoot\scripts\Start-SSEListener.ps1"
    )

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

            Copy-Item $file $backupPath -Force
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

        $baseline | ConvertTo-Json -Depth 10 | Set-Content $script:IntegrityBaselinePath -Encoding UTF8
        Write-OpenPathLog "Integrity baseline generated for $($entries.Count) files"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to generate integrity baseline: $_" -Level ERROR
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

    foreach ($path in $targets) {
        $relativePath = Get-OpenPathRelativePath -Path $path
        $backupPath = Join-Path $script:IntegrityBackupPath $relativePath

        if (-not (Test-Path $backupPath)) {
            $pendingFiles += $path
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($path, "Restore from $backupPath")) {
            $pendingFiles += $path
            continue
        }

        try {
            $destinationDir = Split-Path $path -Parent
            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }

            Copy-Item $backupPath $path -Force
            $restoredFiles += $path
        }
        catch {
            $pendingFiles += $path
            Write-OpenPathLog "Failed to restore $path : $_" -Level WARN
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
