function Import-NativeHostRequestSetupStateModule {
    # loads RequestSetup.State.psm1 from the staged native root, the OpenPath lib path, or $PSScriptRoot; throws if the module cannot be found.
    if (Get-Command -Name 'Get-OpenPathRequestSetupState' -ErrorAction SilentlyContinue) {
        return
    }

    $candidatePaths = @()
    if (Get-Variable -Name NativeRoot -Scope Script -ErrorAction SilentlyContinue) {
        $candidatePaths += (Join-Path $script:NativeRoot 'RequestSetup.State.psm1')
    }
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $candidatePaths += (Join-Path $script:OpenPathRoot 'lib\RequestSetup.State.psm1')
    }
    if ($PSScriptRoot) {
        $candidatePaths += (Join-Path $PSScriptRoot 'RequestSetup.State.psm1')
        $candidatePaths += (Join-Path (Split-Path $PSScriptRoot -Parent) 'RequestSetup.State.psm1')
    }

    foreach ($candidatePath in ($candidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $candidatePath -ErrorAction SilentlyContinue) {
            Import-Module $candidatePath -Force -ErrorAction Stop
            return
        }
    }

    throw 'RequestSetup.State.psm1 is required for native host request setup interpretation.'
}

function Initialize-NativeHostRequestSetupSupport {
    <#
    .SYNOPSIS
    Loads the request setup module on demand (Phase 2D D2).
    .DESCRIPTION
    Only get-config, get-machine-token and the shared request-setup helpers need
    this module; loading it during host startup taxed the hot path (ping, enqueue,
    checks, cheap reads) with a module import it never uses.
    #>
    param()

    if (Get-Command -Name 'Get-OpenPathRequestSetupState' -ErrorAction SilentlyContinue) {
        return
    }
    Import-NativeHostRequestSetupStateModule
}

# Phase 2D D2: the startup profile lives in the host entry script. Standalone
# loads (for example Pester dot-sourcing these support files) fall back to a
# no-op so every loader can call the entry unconditionally.
if (-not (Get-Command -Name 'Add-NativeHostStartupProfileEntry' -ErrorAction SilentlyContinue)) {
    function Add-NativeHostStartupProfileEntry {
        param([string]$Name, [long]$Ms = 0)
    }
}

function Import-NativeHostSupportFileWithOverrides {
    <#
    .SYNOPSIS
    Dot-sources a support file while preserving caller-provided function overrides.
    .DESCRIPTION
    Phase 2D lazy loading must never clobber a function that already exists (for
    example a Pester double defined before the first action that needs the file).
    Missing functions are loaded and promoted into script scope so they survive
    the initializer call.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$PreserveFunctions = @()
    )

    $preserved = @{}
    foreach ($name in @($PreserveFunctions)) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($command) { $preserved[$name] = $command.ScriptBlock }
    }

    . $Path

    foreach ($name in @($PreserveFunctions)) {
        if ($preserved.ContainsKey($name)) {
            Set-Item -Path "Function:script:$name" -Value $preserved[$name] -Force
            continue
        }
        $command = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($command) {
            Set-Item -Path "Function:script:$name" -Value $command.ScriptBlock -Force
        }
    }
}

$nativeHostRedactionCandidatePaths = @()
if (Get-Variable -Name NativeRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostRedactionCandidatePaths += (Join-Path $script:NativeRoot 'Common.Redaction.ps1')
}
if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostRedactionCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\Common.Redaction.ps1')
}
if ($PSScriptRoot) {
    $nativeHostRedactionCandidatePaths += (Join-Path $PSScriptRoot 'Common.Redaction.ps1')
}

foreach ($nativeHostRedactionCandidatePath in ($nativeHostRedactionCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $nativeHostRedactionCandidatePath -ErrorAction SilentlyContinue) {
        $nativeHostRedactionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $nativeHostRedactionCandidatePath
        $nativeHostRedactionStopwatch.Stop()
        Add-NativeHostStartupProfileEntry -Name 'redaction' -Ms $nativeHostRedactionStopwatch.ElapsedMilliseconds
        break
    }
}

if (-not (Get-Command -Name 'ConvertTo-OpenPathRedactedValue' -ErrorAction SilentlyContinue)) {
    throw 'Common.Redaction.ps1 is required for native host log redaction.'
}

if (-not (Get-Variable -Name NativeHostPortalProbeCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:NativeHostPortalProbeCache = @{}
}

function Initialize-NativeHostTaskRunnerSupport {
    <#
    .SYNOPSIS
    Loads TaskRunner.ps1 on demand (Phase 2D D2).
    .DESCRIPTION
    The hot path only needs the task runner when it falls back to the scheduled
    update task or nudges the resident worker; the common enqueue path talks to
    the worker queue directly.
    #>
    param()

    if (Get-Command -Name 'New-OpenPathSchtasksRunner' -ErrorAction SilentlyContinue) {
        return
    }

    $nativeHostTaskRunnerCandidatePaths = @()
    if ($PSScriptRoot) {
        $nativeHostTaskRunnerCandidatePaths += (Join-Path $PSScriptRoot 'TaskRunner.ps1')
    }
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $nativeHostTaskRunnerCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\TaskRunner.ps1')
    }

    foreach ($nativeHostTaskRunnerCandidatePath in ($nativeHostTaskRunnerCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $nativeHostTaskRunnerCandidatePath -ErrorAction SilentlyContinue) {
            Import-NativeHostSupportFileWithOverrides `
                -Path $nativeHostTaskRunnerCandidatePath `
                -PreserveFunctions @(
                    'ConvertTo-OpenPathTaskResultHex',
                    'Get-OpenPathScheduledTaskDiagnostics',
                    'Add-OpenPathScheduledTaskDiagnostics',
                    'New-OpenPathSchtasksRunner',
                    'New-OpenPathFakeTaskRunner',
                    'Invoke-OpenPathScheduledTask'
                )
            return
        }
    }

    throw 'TaskRunner.ps1 is required for native host scheduled task execution.'
}

function Import-NativeHostCaptivePortalModule {
    # attempts to load CaptivePortal.psm1 from the OpenPath lib path or the parent of $PSScriptRoot; silently skips when neither path exists.
    if (Get-Command -Name 'Test-OpenPathCaptivePortalState' -ErrorAction SilentlyContinue) {
        return
    }

    $candidatePaths = @()
    if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
        $candidatePaths += (Join-Path $script:OpenPathRoot 'lib\CaptivePortal.psm1')
    }
    if ($PSScriptRoot) {
        $candidatePaths += (Join-Path (Split-Path $PSScriptRoot -Parent) 'CaptivePortal.psm1')
    }

    foreach ($candidatePath in ($candidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $candidatePath -ErrorAction SilentlyContinue) {
            Import-Module $candidatePath -Force -ErrorAction Stop
            return
        }
    }
}

function Initialize-NativeHostCaptivePortalSupport {
    # loads the optional captive-portal probe module on demand. The portal probe is
    # only needed for recovery/probe flows; loading it at process start would tax
    # every dependency message with extra module-import time.
    param()

    if ($script:NativeHostCaptivePortalSupportLoaded) {
        return
    }
    $script:NativeHostCaptivePortalSupportLoaded = $true
    try {
        Import-NativeHostCaptivePortalModule
    }
    catch {
        # Keep native messaging available even if the optional portal probe module cannot load.
    }
}

$nativeHostRuntimeDependencyCandidatePaths = @()
if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\CapabilityStorage.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Protocol.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Policy.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Queue.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\RuntimeDependency.Overlay.ps1')
}
if ($PSScriptRoot) {
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'CapabilityStorage.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Protocol.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Policy.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Queue.ps1')
    $nativeHostRuntimeDependencyCandidatePaths += (Join-Path $PSScriptRoot 'RuntimeDependency.Overlay.ps1')
}

foreach ($nativeHostRuntimeDependencyCandidatePath in ($nativeHostRuntimeDependencyCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $nativeHostRuntimeDependencyCandidatePath -ErrorAction SilentlyContinue) {
        $nativeHostRuntimeDependencyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $nativeHostRuntimeDependencyCandidatePath
        $nativeHostRuntimeDependencyStopwatch.Stop()
        $nativeHostRuntimeDependencyLeaf = (Split-Path $nativeHostRuntimeDependencyCandidatePath -LeafBase).Replace('RuntimeDependency.', '')
        Add-NativeHostStartupProfileEntry -Name ('rd-' + $nativeHostRuntimeDependencyLeaf) -Ms $nativeHostRuntimeDependencyStopwatch.ElapsedMilliseconds
    }
}

function Initialize-NativeHostCaptivePortalSupportFiles {
    <#
    .SYNOPSIS
    Loads the captive portal support files on demand (Phase 2D D2).
    .DESCRIPTION
    Only the captive portal recovery/observation actions need these files; the
    hot path (ping, enqueue, dependency checks, cheap reads) never touches them.
    Existing function overrides (for example Pester doubles) are preserved.
    #>
    param()

    $supportFiles = @(
        @{
            Path     = 'NativeHost.CaptivePortalRecoveryQueue.ps1'
            Commands = @(
                'Get-NativeHostCaptivePortalRecoveryQueuePath',
                'Get-NativeHostCaptivePortalRecoveryResultPath',
                'Get-NativeHostCaptivePortalRecoveryProgressPath',
                'Get-NativeHostCaptivePortalRecoveryFileSnapshot',
                'Get-NativeHostCaptivePortalRecoveryDiagnosticSnapshot',
                'Add-NativeHostCaptivePortalRecoveryDiagnostics',
                'Write-NativeHostCaptivePortalRecoveryRequest',
                'Read-NativeHostCaptivePortalRecoveryResultEnvelope',
                'Read-NativeHostCaptivePortalRecoveryResult',
                'Get-NativeHostCaptivePortalRecoveryQueueClassification'
            )
            Required = 'Get-NativeHostCaptivePortalRecoveryQueueClassification'
            Error    = 'NativeHost.CaptivePortalRecoveryQueue.ps1 is required for native host captive portal recovery queue handling.'
        }
        @{
            Path     = 'CaptivePortal.RecoveryTransition.ps1'
            Commands = @(
                'Get-OpenPathCaptivePortalRecoveryTransitionStringList',
                'Get-OpenPathCaptivePortalRecoveryTransitionProperty',
                'Test-OpenPathCaptivePortalRecoveryTransitionConfiguredDomainsApplied',
                'Get-OpenPathCaptivePortalRecoveryTransitionEffectiveHosts',
                'Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary',
                'Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess'
            )
            Required = 'Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary'
            Error    = 'CaptivePortal.RecoveryTransition.ps1 is required for native host captive portal recovery transitions.'
        }
        @{
            Path     = 'CaptivePortal.StateFiles.ps1'
            Commands = @('Read-OpenPathCaptivePortalStateJson')
            Required = 'Read-OpenPathCaptivePortalStateJson'
            Error    = 'CaptivePortal.StateFiles.ps1 is required for native host captive portal state reads.'
        }
    )

    foreach ($supportFile in $supportFiles) {
        $missing = @($supportFile.Commands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
        if ($missing.Count -eq 0) {
            continue
        }

        $candidatePaths = @()
        if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
            $candidatePaths += (Join-Path $script:OpenPathRoot ('lib\internal\' + $supportFile.Path))
        }
        if ($PSScriptRoot) {
            $candidatePaths += (Join-Path $PSScriptRoot $supportFile.Path)
        }

        foreach ($candidatePath in ($candidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
            if (Test-Path $candidatePath -ErrorAction SilentlyContinue) {
                Import-NativeHostSupportFileWithOverrides -Path $candidatePath -PreserveFunctions $supportFile.Commands
                break
            }
        }

        if (-not (Get-Command -Name $supportFile.Required -ErrorAction SilentlyContinue)) {
            throw $supportFile.Error
        }
    }
}

if (-not (Get-Command -Name 'Test-OpenPathRuntimeDependencyCandidate' -ErrorAction SilentlyContinue)) {
    throw 'RuntimeDependency.Policy.ps1 is required for native host runtime dependency validation.'
}

# Native-host runtime dependency actions delegate validation to RuntimeDependency.Policy.ps1.
# Policy result strings preserved: Sensitive fields are not accepted;
# reason = 'dependency-already-whitelisted'
# reason = 'runtime-dependency-overlay-present'

