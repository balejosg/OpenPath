# NativeHost.Actions.ps1 — thin loader
# Load order matters: Bootstrap -> Shared -> RuntimeDependency -> CaptivePortal -> MessageDispatch
#
# Sub-files:
#   NativeHost.Actions.Bootstrap.ps1         — dependency loading and initialization
#   NativeHost.Actions.Shared.ps1            — shared utility functions
#   NativeHost.Actions.RuntimeDependency.ps1 — runtime dependency queue/overlay actions
#   NativeHost.Actions.CaptivePortal.ps1     — captive portal detection and recovery actions
#   NativeHost.Actions.MessageDispatch.ps1   — message routing and top-level handler

. (Join-Path $PSScriptRoot 'NativeHost.Actions.Bootstrap.ps1')
. (Join-Path $PSScriptRoot 'NativeHost.Actions.Shared.ps1')
. (Join-Path $PSScriptRoot 'NativeHost.Actions.RuntimeDependency.ps1')
. (Join-Path $PSScriptRoot 'NativeHost.Actions.CaptivePortal.ps1')
. (Join-Path $PSScriptRoot 'NativeHost.Actions.MessageDispatch.ps1')
