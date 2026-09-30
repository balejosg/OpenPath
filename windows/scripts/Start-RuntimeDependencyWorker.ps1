# OpenPath runtime dependency resident worker
#
# #Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs the resident runtime dependency worker until the service is stopped.
.DESCRIPTION
    Imports the update runtime modules once and then watches the local
    runtime-dependency-queue, applying learned dependency batches in-process.
    Removes the per-batch schtasks.exe + cold PowerShell start from the runtime
    dependency path and heartbeats for the Firefox native host fallback check.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force

# Warm the update runtime session before the first dependency batch arrives so the
# first apply does not pay the module/session initialization on the critical path.
$prewarmStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Initialize-OpenPathUpdateRuntimeSession -OpenPathRoot $OpenPathRoot
$prewarmStopwatch.Stop()
Write-OpenPathLog ("Runtime dependency worker runtime session pre-warmed (ms={0})" -f $prewarmStopwatch.ElapsedMilliseconds)

$exitCode = Start-OpenPathRuntimeDependencyWorker -OpenPathRoot $OpenPathRoot
exit $exitCode
