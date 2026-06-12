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

Import-NativeHostRequestSetupStateModule

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
        . $nativeHostRedactionCandidatePath
        break
    }
}

if (-not (Get-Command -Name 'ConvertTo-OpenPathRedactedValue' -ErrorAction SilentlyContinue)) {
    throw 'Common.Redaction.ps1 is required for native host log redaction.'
}

if (-not (Get-Variable -Name NativeHostPortalProbeCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:NativeHostPortalProbeCache = @{}
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
        . $nativeHostTaskRunnerCandidatePath
        break
    }
}

if (-not (Get-Command -Name 'Invoke-OpenPathScheduledTask' -ErrorAction SilentlyContinue)) {
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

try {
    Import-NativeHostCaptivePortalModule
}
catch {
    # Keep native messaging available even if the optional portal probe module cannot load.
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
        . $nativeHostRuntimeDependencyCandidatePath
    }
}

$nativeHostCaptivePortalQueueCandidatePaths = @()
if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostCaptivePortalQueueCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\NativeHost.CaptivePortalRecoveryQueue.ps1')
}
if ($PSScriptRoot) {
    $nativeHostCaptivePortalQueueCandidatePaths += (Join-Path $PSScriptRoot 'NativeHost.CaptivePortalRecoveryQueue.ps1')
}

foreach ($nativeHostCaptivePortalQueueCandidatePath in ($nativeHostCaptivePortalQueueCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $nativeHostCaptivePortalQueueCandidatePath -ErrorAction SilentlyContinue) {
        . $nativeHostCaptivePortalQueueCandidatePath
        break
    }
}

if (-not (Get-Command -Name 'Get-NativeHostCaptivePortalRecoveryQueueClassification' -ErrorAction SilentlyContinue)) {
    throw 'NativeHost.CaptivePortalRecoveryQueue.ps1 is required for native host captive portal recovery queue handling.'
}

$nativeHostRecoveryTransitionCandidatePaths = @()
if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) {
    $nativeHostRecoveryTransitionCandidatePaths += (Join-Path $script:OpenPathRoot 'lib\internal\CaptivePortal.RecoveryTransition.ps1')
}
if ($PSScriptRoot) {
    $nativeHostRecoveryTransitionCandidatePaths += (Join-Path $PSScriptRoot 'CaptivePortal.RecoveryTransition.ps1')
}

foreach ($nativeHostRecoveryTransitionCandidatePath in ($nativeHostRecoveryTransitionCandidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $nativeHostRecoveryTransitionCandidatePath -ErrorAction SilentlyContinue) {
        . $nativeHostRecoveryTransitionCandidatePath
        break
    }
}

if (-not (Get-Command -Name 'Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary' -ErrorAction SilentlyContinue)) {
    throw 'CaptivePortal.RecoveryTransition.ps1 is required for native host captive portal recovery transitions.'
}

if (-not (Get-Command -Name 'Test-OpenPathRuntimeDependencyCandidate' -ErrorAction SilentlyContinue)) {
    throw 'RuntimeDependency.Policy.ps1 is required for native host runtime dependency validation.'
}

# Native-host runtime dependency actions delegate validation to RuntimeDependency.Policy.ps1.
# Policy result strings preserved: Sensitive fields are not accepted;
# reason = 'dependency-already-whitelisted'
# reason = 'runtime-dependency-overlay-present'

