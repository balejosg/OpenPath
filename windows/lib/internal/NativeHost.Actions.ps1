# NativeHost.Actions.ps1 — thin loader
# Load order matters: Bootstrap -> Shared -> RuntimeDependency -> CaptivePortal -> MessageDispatch
#
# Sub-files:
#   NativeHost.Actions.Bootstrap.ps1         — dependency loading and initialization
#   NativeHost.Actions.Shared.ps1            — shared utility functions
#   NativeHost.Actions.RuntimeDependency.ps1 — runtime dependency queue/overlay actions
#   NativeHost.Actions.CaptivePortal.ps1     — captive portal detection and recovery actions
#   NativeHost.Actions.MessageDispatch.ps1   — message routing and top-level handler

# Phase 2D D2: per-file load times land in the host startup profile. Standalone
# loads fall back to a no-op so this loader works outside the host entry script.
if (-not (Get-Command -Name 'Add-NativeHostStartupProfileEntry' -ErrorAction SilentlyContinue)) {
    function Add-NativeHostStartupProfileEntry {
        param([string]$Name, [long]$Ms = 0)
    }
}

$nativeHostActionsBootstrapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'NativeHost.Actions.Bootstrap.ps1')
Add-NativeHostStartupProfileEntry -Name 'boot' -Ms $nativeHostActionsBootstrapStopwatch.ElapsedMilliseconds
$nativeHostActionsSharedStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'NativeHost.Actions.Shared.ps1')
Add-NativeHostStartupProfileEntry -Name 'shared' -Ms $nativeHostActionsSharedStopwatch.ElapsedMilliseconds
$nativeHostActionsRuntimeDependencyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'NativeHost.Actions.RuntimeDependency.ps1')
Add-NativeHostStartupProfileEntry -Name 'rd-actions' -Ms $nativeHostActionsRuntimeDependencyStopwatch.ElapsedMilliseconds
$nativeHostActionsCaptivePortalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'NativeHost.Actions.CaptivePortal.ps1')
Add-NativeHostStartupProfileEntry -Name 'cp-actions' -Ms $nativeHostActionsCaptivePortalStopwatch.ElapsedMilliseconds
$nativeHostActionsMessageDispatchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'NativeHost.Actions.MessageDispatch.ps1')
Add-NativeHostStartupProfileEntry -Name 'dispatch' -Ms $nativeHostActionsMessageDispatchStopwatch.ElapsedMilliseconds
