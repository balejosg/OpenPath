Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-OpenPathTargetSidString {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($Value.PSObject.Properties['Value']) { return [string]$Value.Value }
    return [string]$Value
}

function New-OpenPathDisposablePassword {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return 'A9!z' + ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]', '') + '!'
}

function Invoke-OpenPathCreateDisposableProfile {
    param([string]$Sid, [string]$UserName)
    if (-not ('OpenPathDisposableProfileNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class OpenPathDisposableProfileNative {
  [DllImport("userenv.dll", EntryPoint="CreateProfile", ExactSpelling=true, CharSet=CharSet.Unicode)]
  public static extern int CreateProfile(
    [MarshalAs(UnmanagedType.LPWStr)] string sid,
    [MarshalAs(UnmanagedType.LPWStr)] string user,
    [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,
    uint length);
}
'@
    }
    $buffer = New-Object System.Text.StringBuilder 260
    $status = [OpenPathDisposableProfileNative]::CreateProfile($Sid, $UserName, $buffer, [uint32]$buffer.Capacity)
    if ($status -ne 0) { throw ('disposable-target-profile-create-failed-0x{0:X8}' -f $status) }
    return $buffer.ToString()
}

function Assert-OpenPathDisposableTarget {
    param([Parameter(Mandatory = $true)][object]$Target)
    $user = Get-LocalUser -Name $Target.UserName -ErrorAction SilentlyContinue
    if (-not $user) { throw 'disposable-target-user-missing' }
    if (-not [bool]$user.Enabled) { throw 'disposable-target-user-disabled' }

    $admin = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    $adminSids = @(Get-LocalGroupMember -Group $admin.Name -ErrorAction Stop | ForEach-Object {
        ConvertTo-OpenPathTargetSidString $_.SID
    })
    if ($Target.Sid -in $adminSids) { throw 'disposable-target-is-administrator' }

    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($Target.Sid)'" -ErrorAction Stop)
    $valid = @($profiles | Where-Object {
        $_.PSObject.Properties['Special'] -and $_.Special -eq $false -and
        -not [string]::IsNullOrWhiteSpace([string]$_.LocalPath) -and
        [System.IO.Directory]::Exists([string]$_.LocalPath)
    })
    if ($profiles.Count -ne 1 -or $valid.Count -ne 1) { throw 'disposable-target-profile-not-materialized' }
    if (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$valid[0].LocalPath),
            [System.IO.Path]::GetFullPath([string]$Target.ProfilePath),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'disposable-target-profile-path-mismatch'
    }
    return [pscustomobject]@{
        preparedTarget = $true
        enabled = $true
        administrator = $false
        profileMaterialized = $true
        profileSpecial = $false
    }
}

function New-OpenPathDisposableStandardTarget {
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $userName = "op-e2e-$suffix"
    $password = New-OpenPathDisposablePassword
    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    $created = $false
    $target = $null
    try {
        $user = New-LocalUser -Name $userName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop
        $created = $true
        Enable-LocalUser -Name $userName -ErrorAction Stop
        $sid = ConvertTo-OpenPathTargetSidString $user.SID
        $profilePath = Invoke-OpenPathCreateDisposableProfile -Sid $sid -UserName $userName
        $target = [pscustomobject]@{ UserName = $userName; Sid = $sid; ProfilePath = $profilePath; Password = $password }
        $null = Assert-OpenPathDisposableTarget -Target $target
        return $target
    }
    catch {
        if ($null -ne $target) {
            try { Remove-OpenPathDisposableStandardTarget -Target $target | Out-Null } catch {}
        }
        elseif ($created) {
            Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        $securePassword = $null
    }
}

function Assert-OpenPathPreparedTargetInstalled {
    param([Parameter(Mandatory = $true)][object]$Target)
    $targetState = Assert-OpenPathDisposableTarget -Target $Target
    $group = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue
    if (-not $group) { throw 'installed-restricted-group-missing' }
    $memberSids = @(Get-LocalGroupMember -Group $group.Name -ErrorAction Stop | ForEach-Object {
        ConvertTo-OpenPathTargetSidString $_.SID
    })
    if ($memberSids.Count -ne 1 -or $memberSids[0] -ne $Target.Sid) {
        throw 'installed-restricted-target-sid-mismatch'
    }
    return [pscustomobject]@{
        Sid = $Target.Sid
        profilePath = $Target.ProfilePath
        enabled = $targetState.enabled
        administrator = $targetState.administrator
        profileMaterialized = $targetState.profileMaterialized
        profileSpecial = $targetState.profileSpecial
        restrictedGroupMember = $true
    }
}

function Invoke-OpenPathSystemRecoveryProbe {
    param([Parameter(Mandatory = $true)][string]$MarkerPath)
    $taskName = "OpenPathRecoveryProbe-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\cmd.exe" -Argument "/d /c type nul > `"$MarkerPath`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $MarkerPath)) { Start-Sleep -Milliseconds 250 }
        if (-not (Test-Path -LiteralPath $MarkerPath)) { throw 'system-recovery-probe-not-observed' }
        return [pscustomobject]@{ executed = $true; principal = 'SYSTEM' }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenPathWatchdogProbe {
    $task = Get-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
    $before = Get-ScheduledTaskInfo -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
    Start-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-ScheduledTaskInfo -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
        $currentTask = Get-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
    } while ((Get-Date) -lt $deadline -and ($after.LastRunTime -le $before.LastRunTime -or [string]$currentTask.State -eq 'Running'))
    if ($after.LastRunTime -le $before.LastRunTime) { throw 'watchdog-last-run-time-did-not-advance' }
    if ([uint32]$after.LastTaskResult -ne 0) { throw "watchdog-task-result-$([uint32]$after.LastTaskResult)" }
    return [pscustomobject]@{
        taskPath = [string]$task.TaskPath
        execute = [string]$task.Actions.Execute
        arguments = [string]$task.Actions.Arguments
        principal = [string]$task.Principal.UserId
        lastRunTimeAdvanced = $true
        lastTaskResult = 0
    }
}

function Invoke-OpenPathNativePolicyProbe {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$FirefoxPath,
        [Parameter(Mandatory = $true)][string]$EdgePath,
        [Parameter(Mandatory = $true)][string]$ProbePath
    )
    if (-not [Environment]::Is64BitProcess) { throw 'boundary-harness-process-not-64-bit' }
    $nativeShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $nativeShell -PathType Leaf)) { throw 'boundary-native-powershell-missing' }
    $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-native-policy-$([guid]::NewGuid().ToString('N')).json"
    try {
        & $nativeShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-InstalledBoundaryNative.ps1') `
            -OpenPathRoot $OpenPathRoot -StudentSid $Target.Sid -FirefoxPath $FirefoxPath -EdgePath $EdgePath `
            -ProbePath $ProbePath -OutputPath $outputPath *> $null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw "boundary-native-policy-probe-failed-$LASTEXITCODE"
        }
        return Get-Content -LiteralPath $outputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenPathInstalledBoundaryProbes {
    param([Parameter(Mandatory = $true)][object]$Target, [string]$OpenPathRoot = 'C:\OpenPath')
    Import-Module (Join-Path $PSScriptRoot 'BrowserBoundaryProbe.psm1') -Force -ErrorAction Stop
    $firefox = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $firefox) { throw 'boundary-firefox-missing' }
    if (-not $edge) { throw 'boundary-edge-missing' }
    $probeExe = Join-Path $Target.ProfilePath 'openpath-e2e-probe.exe'
    $probeMarker = Join-Path $Target.ProfilePath 'openpath-e2e-probe.marker'
    New-OpenPathProbePayloadBinary -OutputPath $probeExe
    $policy = Invoke-OpenPathNativePolicyProbe -Target $Target -OpenPathRoot $OpenPathRoot -FirefoxPath $firefox -EdgePath $edge -ProbePath $probeExe
    $firefoxRun = Invoke-StudentExecutableTaskProbe -ProbeName 'Canonical Firefox allow' -UserName $Target.UserName -Password $Target.Password -ExecutablePath $firefox -Expectation ExpectAllowed -ProcessName firefox -StudentSid $Target.Sid
    $edgeRun = Invoke-StudentExecutableTaskProbe -ProbeName 'Canonical Edge deny' -UserName $Target.UserName -Password $Target.Password -ExecutablePath $edge -Arguments '--new-window about:blank' -Expectation ExpectDenied -ProcessName msedge -StudentSid $Target.Sid
    $peRun = Invoke-StudentExecutableTaskProbe -ProbeName 'Canonical benign PE deny' -UserName $Target.UserName -Password $Target.Password -ExecutablePath $probeExe -Arguments "`"$probeMarker`"" -Expectation ExpectDenied -StudentSid $Target.Sid -MarkerPath $probeMarker
    $recovery = Invoke-OpenPathSystemRecoveryProbe -MarkerPath (Join-Path $env:ProgramData "OpenPathRecoveryProbe-$([guid]::NewGuid().ToString('N')).marker")
    $watchdog = Invoke-OpenPathWatchdogProbe
    Remove-Item -LiteralPath $probeExe,$probeMarker -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ policyEvaluation = $policy; firefoxExecution = $firefoxRun; edgeExecution = $edgeRun; benignPeExecution = $peRun; recovery = $recovery; watchdog = $watchdog }
}

function Remove-OpenPathDisposableStandardTarget {
    param([Parameter(Mandatory = $true)][object]$Target)
    $profile = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($Target.Sid)'" -ErrorAction SilentlyContinue)
    foreach ($record in $profile) {
        if ($record.Special -eq $false -and $record.Loaded -eq $false) { Remove-CimInstance -InputObject $record -ErrorAction Stop }
    }
    Remove-LocalUser -Name $Target.UserName -ErrorAction SilentlyContinue
    $Target.Password = $null
    return [pscustomobject]@{ profileRemoved = (@(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($Target.Sid)'" -ErrorAction SilentlyContinue).Count -eq 0); userRemoved = (-not (Get-LocalUser -Name $Target.UserName -ErrorAction SilentlyContinue)); credentialDestroyed = ($null -eq $Target.Password) }
}

Export-ModuleMember -Function New-OpenPathDisposableStandardTarget, Assert-OpenPathDisposableTarget, Assert-OpenPathPreparedTargetInstalled, Invoke-OpenPathInstalledBoundaryProbes, Remove-OpenPathDisposableStandardTarget
