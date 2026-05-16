# OpenPath runtime dependency fast apply

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Applies queued runtime dependency hosts without running a full whitelist update.
.DESCRIPTION
    Processes the local runtime-dependency-queue, regenerates Acrylic hosts, and
    reloads Acrylic DNS without downloading the remote whitelist or changing
    browser/firewall policy.
#>

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot '..\lib\internal\WindowsRoot.ps1')
$OpenPathRoot = Resolve-OpenPathWindowsRoot

Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force

$exitCode = Invoke-OpenPathRuntimeDependencyFastApply -OpenPathRoot $OpenPathRoot
exit $exitCode
