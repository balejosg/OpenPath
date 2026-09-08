Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Write-Host 'Resetting persistent self-hosted Windows runner state...'

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.Name -in @('node.exe', 'esbuild.exe', 'postgres.exe', 'pg_ctl.exe', 'npm.cmd', 'npm.exe', 'powershell.exe', 'pwsh.exe') -and
        (
            $_.CommandLine -like '*openpath-direct-overlay-*' -or
            $_.CommandLine -like '*openpath-direct-node-v*' -or
            $_.CommandLine -like '*run-windows-student-flow.ps1*' -or
            $_.CommandLine -like '*run-windows-browser-boundary-ci.ps1*' -or
            $_.CommandLine -like '*windows-browser-enforcement.ps1*' -or
            $_.CommandLine -like '*C:\OpenPath\scripts\Update-OpenPath.ps1*' -or
            $_.CommandLine -like '*C:\OpenPath\scripts\Start-SSEListener.ps1*' -or
            $_.CommandLine -like '*openpath-postgres*'
        )
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

$openPathTaskNames = @(
    'OpenPath-AgentUpdate',
    'OpenPath-SSE',
    'OpenPath-Startup',
    'OpenPath-Update',
    'OpenPath-Watchdog'
)

foreach ($taskName in $openPathTaskNames) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object {
        $_.TaskName -like 'OpenPath-*' -or
        $_.TaskName -like 'Whitelist-*' -or
        $_.TaskPath -like '*OpenPath*' -or
        $_.TaskPath -like '*Whitelist*'
    } |
    ForEach-Object {
        Stop-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }

Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Path -and $_.Path.StartsWith('C:\OpenPath', [System.StringComparison]::OrdinalIgnoreCase)) -or
        $_.ProcessName -like 'OpenPath*' -or
        $_.ProcessName -like 'Acrylic*'
    } |
    Stop-Process -Force -ErrorAction SilentlyContinue

$acrylicServiceName = 'AcrylicDNSProxySvc'
Stop-Service -Name $acrylicServiceName -Force -ErrorAction SilentlyContinue

function Restore-OpenPathInstallRootAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $takeownPath = Join-Path $env:SystemRoot 'System32\takeown.exe'
    $icaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'

    if (Test-Path -LiteralPath $takeownPath -PathType Leaf) {
        & $takeownPath /F $Path /R /D Y 2>$null | Out-Null
    }

    if (Test-Path -LiteralPath $icaclsPath -PathType Leaf) {
        # Previous jobs may have applied a non-inheriting SYSTEM/Administrators
        # ACL to the install root. Restore inherited permissions before the
        # cleanup delete, then grant the elevated runner identities traversal
        # and delete rights recursively. This is limited to the known test root.
        & $icaclsPath $Path /reset /T /C /Q 2>$null | Out-Null
        & $icaclsPath $Path /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>$null | Out-Null
    }
}

$pathsToRemove = @(
    'C:\OpenPath'
)

foreach ($path in $pathsToRemove) {
    if ($path -and (Test-Path -LiteralPath $path)) {
        Restore-OpenPathInstallRootAccess -Path $path
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    if (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
        $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
        $changed = $false
        foreach ($collection in @($policyXml.AppLockerPolicy.RuleCollection)) {
            foreach ($rule in @($collection.ChildNodes)) {
                if ($rule.Name -like 'OpenPath non-admin app control*') {
                    [void]$collection.RemoveChild($rule)
                    $changed = $true
                }
            }
        }

        if ($changed -and (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) {
            $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-runner-reset-applocker-$([guid]::NewGuid()).xml"
            $policyXml.Save($policyPath)
            Set-AppLockerPolicy -XMLPolicy $policyPath
            Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Warning "Unable to remove OpenPath AppLocker rules during runner reset: $_"
}

try {
    if (Get-Command Remove-LocalGroup -ErrorAction SilentlyContinue) {
        Remove-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Warning "Unable to remove OpenPath-Restricted group during runner reset: $_"
}


$profileEvidencePath = if (-not [string]::IsNullOrWhiteSpace($env:OPENPATH_WINDOWS_PROFILE_EVIDENCE_PATH)) {
    [System.IO.Path]::GetFullPath($env:OPENPATH_WINDOWS_PROFILE_EVIDENCE_PATH)
}
elseif (-not [string]::IsNullOrWhiteSpace($env:OPENPATH_STUDENT_ARTIFACTS_DIR)) {
    Join-Path ([System.IO.Path]::GetFullPath($env:OPENPATH_STUDENT_ARTIFACTS_DIR)) 'windows-user-profile-evidence.json'
}
else {
    Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path 'tests\e2e\artifacts\windows-student-policy\windows-user-profile-evidence.json'
}

$currentRepoRoot = $null
try {
    $currentRepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
}
catch {
    $currentRepoRoot = $null
}

Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'openpath-direct-overlay-*' -ErrorAction SilentlyContinue |
    Where-Object { -not $currentRepoRoot -or $_.FullName -ne $currentRepoRoot } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$firefoxDistributionPaths = @(
    "${env:ProgramFiles}\Mozilla Firefox\distribution",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution"
)

foreach ($distributionPath in $firefoxDistributionPaths) {
    if (-not $distributionPath) {
        continue
    }

    $firefoxRoot = Split-Path -Parent $distributionPath
    if (-not (Test-Path -LiteralPath $firefoxRoot)) {
        continue
    }

    New-Item -Path $distributionPath -ItemType Directory -Force | Out-Null
    Remove-Item -LiteralPath (Join-Path $distributionPath 'policies.json') -Force -ErrorAction SilentlyContinue
    & icacls $distributionPath /grant 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T | Out-Null
}

$dnsServers = @('1.1.1.1', '8.8.8.8')
$activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' }

foreach ($adapter in $activeAdapters) {
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dnsServers -ErrorAction SilentlyContinue
}

if (-not $activeAdapters) {
    Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses @('1.1.1.1', '8.8.8.8') -ErrorAction SilentlyContinue
}

Clear-DnsClientCache -ErrorAction SilentlyContinue


$profileCleanupFailure = $null
if (Test-Path -LiteralPath $profileEvidencePath -PathType Leaf) {
    $profileEvidence = $null
    $cleanupStatus = 'error'
    $cleanupError = $null
    try {
        $profileEvidence = Get-Content -LiteralPath $profileEvidencePath -Raw | ConvertFrom-Json
        if ($profileEvidence.createdByHarness -ne $true) {
            $cleanupStatus = 'not-owned'
        }
        else {
            $expectedSid = [string]$profileEvidence.SID
            $expectedLocalPath = [string]$profileEvidence.LocalPath
            if ([string]::IsNullOrWhiteSpace($expectedSid) -or [string]::IsNullOrWhiteSpace($expectedLocalPath)) {
                $cleanupStatus = 'refused'
                $cleanupError = 'Harness-owned evidence is missing SID or LocalPath.'
            }
            else {
                $profilesForSid = @(
                    Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
                        Where-Object { [string]$_.SID -ceq $expectedSid }
                )
                if ($profilesForSid.Count -eq 0) {
                    $cleanupStatus = 'already-absent'
                }
                elseif ($profilesForSid.Count -ne 1) {
                    $cleanupStatus = 'refused'
                    $cleanupError = "SID $expectedSid has $($profilesForSid.Count) Win32_UserProfile records."
                }
                else {
                    $profile = $profilesForSid[0]
                    if ([string]$profile.LocalPath -cne $expectedLocalPath) {
                        $cleanupStatus = 'refused'
                        $cleanupError = 'Win32_UserProfile LocalPath does not match evidence.'
                    }
                    elseif ($profile.Special -ne $false) {
                        $cleanupStatus = 'refused'
                        $cleanupError = 'Win32_UserProfile Special is not false.'
                    }
                    elseif ($profile.Loaded -ne $false) {
                        $cleanupStatus = 'refused'
                        $cleanupError = 'Win32_UserProfile is loaded.'
                    }
                    else {
                        Remove-CimInstance -InputObject $profile -ErrorAction Stop
                        $cleanupStatus = 'removed'
                    }
                }
            }
        }
    }
    catch {
        $cleanupStatus = 'error'
        $cleanupError = $_.Exception.Message
    }
    finally {
        if ($null -eq $profileEvidence) {
            $profileEvidence = [pscustomobject]@{
                createdByHarness = $null
                SID              = $null
                UserName         = $null
                LocalPath        = $null
            }
        }
        foreach ($propertyName in @('createdByHarness', 'SID', 'UserName', 'LocalPath')) {
            if ($null -eq $profileEvidence.PSObject.Properties[$propertyName]) {
                $profileEvidence | Add-Member -NotePropertyName $propertyName -NotePropertyValue $null
            }
        }
        $profileEvidence | Add-Member -NotePropertyName cleanupStatus -NotePropertyValue $cleanupStatus -Force
        $profileEvidence | Add-Member -NotePropertyName cleanupAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        if ([string]::IsNullOrWhiteSpace($cleanupError)) {
            $profileEvidence.PSObject.Properties.Remove('cleanupError')
        }
        else {
            $profileEvidence | Add-Member -NotePropertyName cleanupError -NotePropertyValue $cleanupError -Force
        }
        $profileEvidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $profileEvidencePath -Encoding UTF8 -ErrorAction Stop
    }

    if ($cleanupStatus -in @('refused', 'error')) {
        $profileCleanupFailure = "Windows profile cleanup {0}: {1}" -f $cleanupStatus, $cleanupError
        Write-Warning $profileCleanupFailure
    }
    else {
        Write-Host "Windows profile cleanup status: $cleanupStatus"
    }
}

if ($profileCleanupFailure) {
    throw $profileCleanupFailure
}

Write-Host 'Self-hosted Windows runner reset complete.'
