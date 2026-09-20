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

function Set-OpenPathDisposableTargetUserRight {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$Right,
        [Parameter(Mandatory = $true)][bool]$Present
    )
    $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-user-right-$([guid]::NewGuid().ToString('N'))"
    $cfgPath = Join-Path $workRoot 'rights.inf'
    $dbPath = Join-Path $workRoot 'rights.sdb'
    $entry = "*$Sid"
    try {
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
        & secedit.exe /export /cfg $cfgPath /areas USER_RIGHTS *> $null
        if ($LASTEXITCODE -ne 0) { throw "disposable-target-user-right-export-failed-$LASTEXITCODE" }

        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in Get-Content -LiteralPath $cfgPath) { $lines.Add([string]$line) }
        $rightPattern = '^\s*' + [regex]::Escape($Right) + '\s*='
        $rightIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match $rightPattern) { $rightIndex = $index; break }
        }

        $members = [System.Collections.Generic.List[string]]::new()
        if ($rightIndex -ge 0) {
            $value = ($lines[$rightIndex] -split '=', 2)[1]
            foreach ($member in ($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if ($member -ne $entry) { $members.Add($member) }
            }
        }
        if ($Present) { $members.Add($entry) }
        $replacement = "$Right = $($members -join ',')"
        if ($rightIndex -ge 0) {
            $lines[$rightIndex] = $replacement
        }
        elseif ($Present) {
            if ($lines.IndexOf('[Privilege Rights]') -lt 0) { $lines.Add('[Privilege Rights]') }
            $lines.Add($replacement)
        }
        else {
            return
        }

        $lines | Set-Content -LiteralPath $cfgPath -Encoding Unicode
        & secedit.exe /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS *> $null
        if ($LASTEXITCODE -ne 0) { throw "disposable-target-user-right-configure-failed-$LASTEXITCODE" }
    }
    finally {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Grant-OpenPathDisposableTargetUserRight {
    param([string]$Sid, [string]$Right)
    Set-OpenPathDisposableTargetUserRight -Sid $Sid -Right $Right -Present $true
}

function Revoke-OpenPathDisposableTargetUserRight {
    param([string]$Sid, [string]$Right)
    Set-OpenPathDisposableTargetUserRight -Sid $Sid -Right $Right -Present $false
}

function Assert-OpenPathDisposableTarget {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [ValidateSet('Required', 'Absent')][string]$ProfileExpectation = 'Required'
    )
    $user = Get-LocalUser -Name $Target.UserName -ErrorAction SilentlyContinue
    if (-not $user) { throw 'disposable-target-user-missing' }
    if (-not [bool]$user.Enabled) { throw 'disposable-target-user-disabled' }

    $admin = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    $adminSids = @(Get-LocalGroupMember -Group $admin.Name -ErrorAction Stop | ForEach-Object {
        ConvertTo-OpenPathTargetSidString $_.SID
    })
    if ($Target.Sid -in $adminSids) { throw 'disposable-target-is-administrator' }

    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($Target.Sid)'" -ErrorAction Stop)
    if ($ProfileExpectation -eq 'Absent') {
        if ($profiles.Count -ne 0) { throw 'disposable-target-profile-unexpectedly-materialized' }
        return [pscustomobject]@{
            preparedTarget = $true
            enabled = $true
            administrator = $false
            profileMaterialized = $false
            profileSpecial = $false
        }
    }
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
    param(
        [string]$UserName = '',
        [bool]$MaterializeProfile = $true
    )
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
        $UserName = "op-e2e-$suffix"
    }
    $password = New-OpenPathDisposablePassword
    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    $created = $false
    $target = $null
    try {
        $user = New-LocalUser -Name $UserName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop
        $created = $true
        Enable-LocalUser -Name $UserName -ErrorAction Stop
        $sid = ConvertTo-OpenPathTargetSidString $user.SID
        $profilePath = if ($MaterializeProfile) { Invoke-OpenPathCreateDisposableProfile -Sid $sid -UserName $UserName } else { '' }
        Grant-OpenPathDisposableTargetUserRight -Sid $sid -Right 'SeBatchLogonRight'
        $target = [pscustomobject]@{ UserName = $UserName; Sid = $sid; ProfilePath = $profilePath; Password = $password; BatchLogonRightGranted = $true }
        $profileExpectation = if ($MaterializeProfile) { 'Required' } else { 'Absent' }
        $null = Assert-OpenPathDisposableTarget -Target $target -ProfileExpectation $profileExpectation
        return $target
    }
    catch {
        if ($null -ne $target) {
            try { Remove-OpenPathDisposableStandardTarget -Target $target | Out-Null } catch {}
        }
        elseif ($created) {
            Remove-LocalUser -Name $UserName -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        $securePassword = $null
    }
}

function Initialize-OpenPathDisposableTargetProfile {
    param([Parameter(Mandatory = $true)][object]$Target)

    $null = Assert-OpenPathDisposableTarget -Target $Target -ProfileExpectation Absent
    $Target.ProfilePath = Invoke-OpenPathCreateDisposableProfile -Sid $Target.Sid -UserName $Target.UserName
    $null = Assert-OpenPathDisposableTarget -Target $Target -ProfileExpectation Required
    return $Target
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

function ConvertTo-OpenPathWatchdogTaskSnapshot {
    param([AllowNull()][object]$Task, [AllowNull()][object]$TaskInfo)
    if ($null -eq $Task -and $null -eq $TaskInfo) { return $null }
    $state = if ($null -ne $Task) { [string]$Task.State } else { $null }
    $lastRunTimeUtc = $null
    if ($null -ne $TaskInfo -and $null -ne $TaskInfo.LastRunTime) {
        $lastRunTimeUtc = ([datetime]$TaskInfo.LastRunTime).ToUniversalTime().ToString('o')
    }
    $lastTaskResult = if ($null -ne $TaskInfo -and $null -ne $TaskInfo.LastTaskResult) { [uint32]$TaskInfo.LastTaskResult } else { $null }
    return [pscustomobject][ordered]@{
        state = $state
        lastRunTimeUtc = $lastRunTimeUtc
        lastTaskResult = $lastTaskResult
    }
}

function New-OpenPathWatchdogFailureEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [AllowNull()][object]$Initial,
        [AllowNull()][object]$Final,
        [Parameter(Mandatory = $true)][bool]$StartRequested
    )
    return [pscustomobject][ordered]@{
        status = 'failed'
        code = $Code
        initial = $Initial
        final = $Final
        startRequested = $StartRequested
    }
}

function ConvertTo-OpenPathWatchdogBoundaryProjection {
    param([Parameter(Mandatory = $true)][object]$Evidence)
    $initial = ConvertTo-OpenPathWatchdogTaskSnapshot -Task $(if ($Evidence.initial) { [pscustomobject]@{ State=$Evidence.initial.state } }) -TaskInfo $(if ($Evidence.initial) { [pscustomobject]@{ LastRunTime=$(if($Evidence.initial.lastRunTimeUtc){[datetime]$Evidence.initial.lastRunTimeUtc}); LastTaskResult=$Evidence.initial.lastTaskResult } })
    $final = ConvertTo-OpenPathWatchdogTaskSnapshot -Task $(if ($Evidence.final) { [pscustomobject]@{ State=$Evidence.final.state } }) -TaskInfo $(if ($Evidence.final) { [pscustomobject]@{ LastRunTime=$(if($Evidence.final.lastRunTimeUtc){[datetime]$Evidence.final.lastRunTimeUtc}); LastTaskResult=$Evidence.final.lastTaskResult } })
    return [pscustomobject][ordered]@{
        status = [string]$Evidence.status
        code = [string]$Evidence.code
        initial = $initial
        final = $final
        startRequested = [bool]$Evidence.startRequested
    }
}

function New-OpenPathDisposableWatchdogBoundaryException {
    param([Parameter(Mandatory = $true)][object]$Evidence)
    $failure = [System.InvalidOperationException]::new('boundary-watchdog-execution-failed')
    $failure.Data['OpenPathWatchdogBoundaryEvidence'] = ConvertTo-OpenPathWatchdogBoundaryProjection -Evidence $Evidence
    return $failure
}

function Invoke-OpenPathWatchdogProbe {
    $task = $null
    $before = $null
    try {
        $task = Get-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
        $before = Get-ScheduledTaskInfo -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
    }
    catch {
        return New-OpenPathWatchdogFailureEvidence -Code 'task-query-failed' -Initial $null -Final $null -StartRequested:$false
    }
    $initial = ConvertTo-OpenPathWatchdogTaskSnapshot -Task $task -TaskInfo $before
    try {
        Start-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
    }
    catch {
        return New-OpenPathWatchdogFailureEvidence -Code 'task-start-failed' -Initial $initial -Final $null -StartRequested:$true
    }
    $deadline = (Get-Date).AddSeconds(30)
    $after = $null
    $currentTask = $null
    do {
        Start-Sleep -Milliseconds 500
        try {
            $after = Get-ScheduledTaskInfo -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
            $currentTask = Get-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction Stop
        }
        catch {
            $queryFailureFinal = ConvertTo-OpenPathWatchdogTaskSnapshot -Task $currentTask -TaskInfo $after
            return New-OpenPathWatchdogFailureEvidence -Code 'task-query-failed' -Initial $initial -Final $queryFailureFinal -StartRequested:$true
        }
    } while ((Get-Date) -lt $deadline -and ($after.LastRunTime -le $before.LastRunTime -or [string]$currentTask.State -eq 'Running'))
    $final = ConvertTo-OpenPathWatchdogTaskSnapshot -Task $currentTask -TaskInfo $after
    if ($after.LastRunTime -le $before.LastRunTime) {
        return New-OpenPathWatchdogFailureEvidence -Code 'last-run-time-did-not-advance' -Initial $initial -Final $final -StartRequested:$true
    }
    if ([uint32]$after.LastTaskResult -ne 0) {
        return New-OpenPathWatchdogFailureEvidence -Code 'task-result-nonzero' -Initial $initial -Final $final -StartRequested:$true
    }
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
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'boundary-native-policy-probe-no-result'
        }
        $nativeResult = Get-Content -LiteralPath $outputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($LASTEXITCODE -ne 0 -or $nativeResult.status -ne 'ok') {
            if ([string]$nativeResult.code -match '^boundary-native-[a-z-]{1,80}-failed$') { throw [string]$nativeResult.code }
            throw 'boundary-native-policy-probe-failed'
        }
        return $nativeResult
    }
    finally {
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathDisposableBoundaryFailureEvidence {
    $getter = Get-Command -Name Get-OpenPathLastBoundaryProbeFailureEvidence -ErrorAction SilentlyContinue
    if (-not $getter) { return $null }
    return & $getter
}

function Get-OpenPathDisposableFlatEdgeBoundaryFailureContract {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [object]$Diagnostic = $null
    )

    $contractGetter = Get-Command -Name Get-OpenPathFlatEdgeBoundaryFailureContract -ErrorAction SilentlyContinue
    if (-not $contractGetter) { return $null }
    return & $contractGetter @PSBoundParameters
}

function Invoke-OpenPathDisposableEdgeBoundaryDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$StudentSid,
        [string]$Arguments = '--new-window about:blank',
        [string]$PackagedAppPattern = 'MicrosoftEdge|Microsoft\.MicrosoftEdge|msedge',
        [int]$ProbeTimeoutSeconds = 5,
        [int[]]$AttemptOffsetsSeconds = @(0, 5, 15, 30)
    )

    $diagnostic = Get-Command -Name Invoke-OpenPathEdgeBoundaryDiagnostic -ErrorAction SilentlyContinue
    if (-not $diagnostic) { throw 'edge-boundary-diagnostic-command-unavailable' }
    return & $diagnostic @PSBoundParameters
}

function Invoke-OpenPathDisposablePolicyConverterStart {
    $result = [ordered]@{ status='inconclusive'; code=$null; action='none'; startedAtUtc=$null; completedAtUtc=$null; restored=$null; restoreRequired=$false; startRunObserved=$false; preAction=$null; postAction=$null }
    $task = Get-ScheduledTask -TaskName 'PolicyConverter' -TaskPath '\Microsoft\Windows\AppID\' -ErrorAction Stop
    $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
    $beforeEnabled = if ($task.Settings.PSObject.Properties['Enabled']) { $task.Settings.Enabled } else { $null }
    $beforeLastRun = $info.LastRunTime
    $beforeLastRunUtc = if ($null -ne $beforeLastRun) { $beforeLastRun.ToUniversalTime().ToString('o') } else { $null }
    $result.preAction = [ordered]@{ state=[string]$task.State; enabled=$beforeEnabled; lastRunTimeUtc=$beforeLastRunUtc; lastTaskResult=$info.LastTaskResult }
    if ($null -eq $beforeEnabled -or $null -eq $task.State -or $null -eq $info.LastRunTime -or $null -eq $info.LastTaskResult) { $result.code='task-snapshot-unknown'; return $result }
    if ([string]$task.State -eq 'Running') { $result.code='task-already-running'; return $result }
    $changedEnabled = $false
    try {
        if (-not [bool]$beforeEnabled) {
            Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
            $changedEnabled = $true
        }
        $result.action='start'
        $result.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $currentTask = Get-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            $currentInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            $newRun = $null -ne $currentInfo.LastRunTime -and ($null -eq $beforeLastRun -or $currentInfo.LastRunTime -gt $beforeLastRun)
            if ($newRun -and [string]$currentTask.State -ne 'Running' -and $currentInfo.LastTaskResult -eq 0) {
                $result.status='observed'; $result.code='task-run-observed'; $result.startRunObserved=$true; $result.postAction=[ordered]@{ state=[string]$currentTask.State; enabled=$currentTask.Settings.Enabled; lastRunTimeUtc=$currentInfo.LastRunTime.ToUniversalTime().ToString('o'); lastTaskResult=$currentInfo.LastTaskResult }; $result.completedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); break
            }
        } while ((Get-Date) -lt $deadline)
        if ($result.status -ne 'observed') { $result.code='task-run-not-confirmed' }
    } catch { $result.code='task-start-query-failed' }
    $result.restoreRequired = $changedEnabled
    return [pscustomobject]$result
}

function Restore-OpenPathDisposablePolicyConverterTask {
    try { Disable-ScheduledTask -TaskName 'PolicyConverter' -TaskPath '\Microsoft\Windows\AppID\' -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Resolve-OpenPathDisposableEdgeBoundaryFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Exception]$Exception,
        [object]$Target = $null,
        [ValidateSet('Untouched','Started')][string]$PolicyConverterMode = 'Untouched'
    )

    $initial = $null
    try {
        if ($Exception.Data -and $Exception.Data.Contains('OpenPathEdgeBoundaryEvidence')) {
            $initial = $Exception.Data['OpenPathEdgeBoundaryEvidence']
        }
    }
    catch {}
    if (-not $initial) {
        try { $initial = Get-OpenPathDisposableBoundaryFailureEvidence } catch {}
    }
    if (-not $initial -or [string]$initial.probeName -ne 'Canonical Edge deny') { return $null }

    # Detach the primary observation before any later diagnostic can mutate
    # module-scoped probe state. This object contains only the bounded fields
    # already allowlisted by BrowserBoundaryProbe.
    $initialSnapshot = $initial | ConvertTo-Json -Depth 14 | ConvertFrom-Json
    $repeat = $null
    $policyConverter = [ordered]@{ status='not-started'; code='untouched'; action='none'; restored=$null; restoreRequired=$false; startRunObserved=$false }
    try {
        if ($Target -and $Target.UserName -and $Target.Password) {
            if ($PolicyConverterMode -eq 'Started') {
                try { $policyConverter = Invoke-OpenPathDisposablePolicyConverterStart } catch { $policyConverter = [ordered]@{ status='inconclusive'; code='task-start-query-failed'; action='none'; restored=$false; restoreRequired=$false; startRunObserved=$false } }
            }
            if ($PolicyConverterMode -eq 'Started' -and $policyConverter.status -ne 'observed') {
                return [pscustomobject][ordered]@{ initial = $initialSnapshot; repeat = $null; deniedPeControl = $null; contract = $null; policyConverter = $policyConverter }
            }
            try {
                $repeat = Invoke-OpenPathDisposableEdgeBoundaryDiagnostic `
                    -UserName $Target.UserName `
                    -Password $Target.Password `
                    -ExecutablePath $initialSnapshot.executablePath `
                    -StudentSid $initialSnapshot.studentSid
            }
            catch {
                $repeat = [pscustomobject][ordered]@{ status = 'unavailable'; code = 'edge-boundary-diagnostic-failed' }
            }
        }
        try { $deniedPeControl = Invoke-OpenPathDisposableDeniedPeControl -Target $Target }
        catch { $deniedPeControl = [pscustomobject]@{ status='unavailable'; code='benign-pe-control-failed'; outcome='inconclusive'; policyReapplied=$false } }
        try { $contract = Get-OpenPathDisposableFlatEdgeBoundaryFailureContract -Evidence $initialSnapshot -Diagnostic $repeat } catch {}
        return [pscustomobject][ordered]@{ initial = $initialSnapshot; repeat = $repeat; deniedPeControl = $deniedPeControl; contract = $contract; policyConverter = $policyConverter }
    }
    finally {
        if ($policyConverter.restoreRequired) { $policyConverter.restored = Restore-OpenPathDisposablePolicyConverterTask }
    }
}

function Write-OpenPathOfflineInstallerEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Payload | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-OpenPathDisposableEdgeBoundaryException {
    $failure = [System.InvalidOperationException]::new('boundary-edge-execution-failed')
    try {
        $evidence = Get-OpenPathDisposableBoundaryFailureEvidence
        if ($evidence) { $failure.Data['OpenPathEdgeBoundaryEvidence'] = $evidence }
    }
    catch {}
    return $failure
}

function Invoke-OpenPathInstalledBoundaryProbes {
    param([Parameter(Mandatory = $true)][object]$Target, [string]$OpenPathRoot = 'C:\OpenPath', [string]$ProbePayloadPath = '')
    Import-Module (Join-Path $PSScriptRoot 'BrowserBoundaryProbe.psm1') -Force -ErrorAction Stop
    $firefox = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $firefox) { throw 'boundary-firefox-missing' }
    if (-not $edge) { throw 'boundary-edge-missing' }
    $probeId = [guid]::NewGuid().ToString('N')
    $probeRoot = Join-Path $Target.ProfilePath "OpenPathPortableProbe-$probeId"
    $probeLocations = [ordered]@{
        Downloads = Join-Path $Target.ProfilePath "Downloads\OpenPathProbe-$probeId\openpath-e2e-probe.exe"
        Desktop = Join-Path $Target.ProfilePath "Desktop\OpenPathProbe-$probeId\openpath-e2e-probe.exe"
        LocalAppDataTemp = Join-Path $Target.ProfilePath "AppData\Local\Temp\OpenPathProbe-$probeId\openpath-e2e-probe.exe"
        ArbitraryWritable = Join-Path $probeRoot 'future-browser-renamed.exe'
    }
    $removableDrive = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DeviceID'] -and -not [string]::IsNullOrWhiteSpace([string]$_.DeviceID) } |
            Select-Object -First 1)
    if ($removableDrive.Count -eq 1) {
        $probeLocations.Removable = Join-Path "$($removableDrive[0].DeviceID)\" "OpenPathProbe-$probeId\portable-renamed.exe"
    }
    $probeMarkers = [ordered]@{}
    $portableRuns = [ordered]@{}
    $createdProbePaths = [System.Collections.Generic.List[string]]::new()
    $createdProbeDirectories = [System.Collections.Generic.List[string]]::new()
    $policy = $null
    $firefoxRun = $null
    $edgeRun = $null
    $recovery = $null
    $watchdog = $null
    $studentFirefoxProfile = Join-Path $Target.ProfilePath "OpenPathFirefoxProbe-$([guid]::NewGuid().ToString('N'))"
    try {
        if ($ProbePayloadPath -and -not (Test-Path -LiteralPath $ProbePayloadPath -PathType Leaf)) { throw 'boundary-probe-payload-missing' }
        foreach ($entry in $probeLocations.GetEnumerator()) {
            $probeDirectory = Split-Path -Parent $entry.Value
            if (-not (Test-Path -LiteralPath $probeDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
                $createdProbeDirectories.Add($probeDirectory)
            }
            if ($ProbePayloadPath) {
                Copy-Item -LiteralPath $ProbePayloadPath -Destination $entry.Value -Force
            }
            else {
                $probeExe = $entry.Value
                New-OpenPathProbePayloadBinary -OutputPath $probeExe
            }
            $createdProbePaths.Add($entry.Value)
            $probeMarkers[$entry.Key] = "$($entry.Value).marker"
        }
        $probeExe = $probeLocations.ArbitraryWritable
        $policy = Invoke-OpenPathNativePolicyProbe -Target $Target -OpenPathRoot $OpenPathRoot -FirefoxPath $firefox -EdgePath $edge -ProbePath $probeExe
        $firefoxRun = Invoke-StudentExecutableTaskProbe -ProbeName 'Canonical Firefox allow' -UserName $Target.UserName -Password $Target.Password -ExecutablePath $firefox -Arguments "-CreateProfile `"OpenPathProbe $studentFirefoxProfile`"" -Expectation ExpectAllowed -StudentSid $Target.Sid -MarkerPath $studentFirefoxProfile -UseNativeStudentProcess
        try {
            $edgeRun = Invoke-StudentExecutableTaskProbe -ProbeName 'Canonical Edge deny' -UserName $Target.UserName -Password $Target.Password -ExecutablePath $edge -Arguments '--new-window about:blank' -Expectation ExpectDenied -ProcessName msedge -StudentSid $Target.Sid -PackagedAppPattern 'MicrosoftEdge|Microsoft\.MicrosoftEdge|msedge' -CaptureEnforcementDiagnostics -UseNativeStudentProcess
        }
        catch {
            throw (New-OpenPathDisposableEdgeBoundaryException)
        }
        foreach ($entry in $probeLocations.GetEnumerator()) {
            try {
                $portableRuns[$entry.Key] = Invoke-StudentExecutableTaskProbe -ProbeName "Portable PE deny ($($entry.Key))" -UserName $Target.UserName -Password $Target.Password -ExecutablePath $entry.Value -Arguments "`"$($probeMarkers[$entry.Key])`"" -Expectation ExpectDenied -StudentSid $Target.Sid -MarkerPath $probeMarkers[$entry.Key] -UseNativeStudentProcess
            }
            catch { throw "boundary-portable-pe-execution-failed-$($entry.Key)" }
        }
        try { $recovery = Invoke-OpenPathSystemRecoveryProbe -MarkerPath (Join-Path $env:ProgramData "OpenPathRecoveryProbe-$([guid]::NewGuid().ToString('N')).marker") } catch { throw 'boundary-system-recovery-failed' }
        try { $watchdog = Invoke-OpenPathWatchdogProbe } catch { throw 'boundary-watchdog-execution-failed' }
        if ($watchdog.PSObject.Properties['status'] -and $watchdog.status -eq 'failed') { throw (New-OpenPathDisposableWatchdogBoundaryException -Evidence $watchdog) }
        return [pscustomobject]@{ policyEvaluation = $policy; firefoxExecution = $firefoxRun; edgeExecution = $edgeRun; portableExecutions = [pscustomobject]$portableRuns; recovery = $recovery; watchdog = $watchdog }
    }
    catch {
        if ($_.Exception.Message -eq 'boundary-firefox-execution-failed' -or $_.Exception.Message -like 'boundary-*') { throw }
        throw 'boundary-firefox-execution-failed'
    }
    finally {
        Remove-Item -LiteralPath $studentFirefoxProfile -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($probePath in $createdProbePaths) { Remove-Item -LiteralPath $probePath,"$probePath.marker" -Force -ErrorAction SilentlyContinue }
        foreach ($directoryPath in @($createdProbeDirectories | Sort-Object { $_.Length } -Descending)) { Remove-Item -LiteralPath $directoryPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-OpenPathDisposableStandardTarget {
    param([Parameter(Mandatory = $true)][object]$Target)
    $userRightRemoved = -not ($Target.PSObject.Properties['BatchLogonRightGranted'] -and $Target.BatchLogonRightGranted)
    if ($Target.PSObject.Properties['BatchLogonRightGranted'] -and $Target.BatchLogonRightGranted) {
        try {
            Revoke-OpenPathDisposableTargetUserRight -Sid $Target.Sid -Right 'SeBatchLogonRight'
            $Target.BatchLogonRightGranted = $false
            $userRightRemoved = $true
        }
        catch { $userRightRemoved = $false }
    }
    $profileRemoved = $false
    try {
        $profileDeadline = (Get-Date).AddSeconds(20)
        do {
            $profile = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($Target.Sid)'" -ErrorAction SilentlyContinue)
            if ($profile.Count -eq 0 -or @($profile | Where-Object { $_.Loaded }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $profileDeadline)
        foreach ($record in $profile) {
            if ($record.Special -eq $false -and $record.Loaded -eq $false) { Remove-CimInstance -InputObject $record -ErrorAction Stop }
        }
        $profileRemoved = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($Target.Sid)'" -ErrorAction SilentlyContinue).Count -eq 0
    }
    catch { $profileRemoved = $false }
    try { Remove-LocalUser -Name $Target.UserName -ErrorAction SilentlyContinue } catch {}
    $userRemoved = -not (Get-LocalUser -Name $Target.UserName -ErrorAction SilentlyContinue)
    $Target.Password = $null
    return [pscustomobject]@{ userRightRemoved = $userRightRemoved; profileRemoved = $profileRemoved; userRemoved = $userRemoved; credentialDestroyed = ($null -eq $Target.Password) }
}

function ConvertTo-OpenPathDisposableRuntimeProjection {
    param([object]$Runtime)
    if (-not $Runtime) { return $null }
    $projection = [ordered]@{}
    foreach ($propertyName in @('supported','edition','version','bitness','processId')) {
        if ($Runtime.PSObject.Properties[$propertyName]) {
            $projection[$propertyName] = $Runtime.$propertyName
        }
    }
    return [pscustomobject]$projection
}

function ConvertTo-OpenPathDisposableNativePolicyProjection {
    param([object]$Native)
    if (-not $Native) { return $null }
    return [pscustomobject][ordered]@{
        status = if ($Native.PSObject.Properties['status']) { $Native.status } else { $null }
        decision = if ($Native.PSObject.Properties['decision']) { $Native.decision } else { $null }
        path = if ($Native.PSObject.Properties['path']) { $Native.path } else { $null }
        userSid = if ($Native.PSObject.Properties['userSid']) { $Native.userSid } else { $null }
        runtime = ConvertTo-OpenPathDisposableRuntimeProjection -Runtime $(if ($Native.PSObject.Properties['runtime']) { $Native.runtime })
    }
}

function Get-OpenPathDisposableFieldValue {
    param([object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-OpenPathDisposablePolicyConverterClock { Get-Date }

function Get-OpenPathDisposableRuntimeContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    [pscustomobject][ordered]@{
        edition = [string]$PSVersionTable.PSEdition
        version = [string]$PSVersionTable.PSVersion
        bitness = if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }
        processId = [int]$PID
        identitySid = if ($identity.User) { [string]$identity.User.Value } else { $null }
        isSystem = [bool]($identity.User -and $identity.User.Value -eq 'S-1-5-18')
        isAdministrator = [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

function Get-OpenPathDisposablePolicyConverterTaskQuery {
    @(Get-ScheduledTask -TaskName 'PolicyConverter' -TaskPath '\Microsoft\Windows\AppID\' -ErrorAction Stop)
}

function Get-OpenPathDisposablePolicyConverterTaskInfoQuery {
    param([Parameter(Mandatory = $true)][object]$Task)
    Get-ScheduledTaskInfo -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
}

function Get-OpenPathDisposableAppIdServiceQuery {
    @(Get-CimInstance -ClassName Win32_Service -Filter "Name='AppIDSvc'" -ErrorAction Stop)
}

function Get-OpenPathDisposableAppIdProcessQuery {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    Get-Process -Id $ProcessId -ErrorAction Stop
}

function Test-OpenPathDisposableNotFoundError {
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)
    $errorId = [string]$ErrorRecord.FullyQualifiedErrorId
    return $errorId -match '^(NoMatchingMSFT_ScheduledTask|CmdletizationQuery_NotFound|NoProcessFoundForGivenId)(,|$)'
}

function Get-OpenPathDisposablePolicyConverterObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('before-exe-launch','before-boundary-probes','contrast-before-intervention','contrast-after-intervention','contrast-after-child','contrast-after-restoration')][string]$Context)

    $capturedAt = Get-OpenPathDisposablePolicyConverterClock
    $capturedAtUtc = $capturedAt.ToUniversalTime().ToString('o')
    $runtime = Get-OpenPathDisposableRuntimeContext

    $taskObject = $null
    try {
        $tasks = @(Get-OpenPathDisposablePolicyConverterTaskQuery)
        if ($tasks.Count -eq 0) {
            $task = [pscustomobject][ordered]@{ queryStatus='absent'; code=$null; exists=$false; name='PolicyConverter'; path='\Microsoft\Windows\AppID\'; state=$null; enabled=$null }
        }
        elseif ($tasks.Count -eq 1) {
            $taskObject = $tasks[0]
            $taskEnabled = if ($taskObject.PSObject.Properties['Settings'] -and $taskObject.Settings -and $taskObject.Settings.PSObject.Properties['Enabled'] -and $null -ne $taskObject.Settings.Enabled) { [bool]$taskObject.Settings.Enabled } else { $null }
            $task = [pscustomobject][ordered]@{ queryStatus='observed'; code=$null; exists=$true; name=[string]$taskObject.TaskName; path=[string]$taskObject.TaskPath; state=[string]$taskObject.State; enabled=$taskEnabled }
        }
        else {
            $task = [pscustomobject][ordered]@{ queryStatus='failed'; code='policy-converter-task-query-ambiguous'; exists=$null; name='PolicyConverter'; path='\Microsoft\Windows\AppID\'; state=$null; enabled=$null }
        }
    }
    catch {
        if (Test-OpenPathDisposableNotFoundError $_) {
            $task = [pscustomobject][ordered]@{ queryStatus='absent'; code='policy-converter-task-not-found'; exists=$false; name='PolicyConverter'; path='\Microsoft\Windows\AppID\'; state=$null; enabled=$null }
        }
        else {
            $task = [pscustomobject][ordered]@{ queryStatus='failed'; code='policy-converter-task-query-failed'; exists=$null; name='PolicyConverter'; path='\Microsoft\Windows\AppID\'; state=$null; enabled=$null }
        }
    }

    if (-not $taskObject) {
        $taskInfoStatus = if ($task.queryStatus -eq 'absent') { 'not-observed-task-absent' } else { 'not-observed-task-unavailable' }
        $taskInfo = [pscustomobject][ordered]@{ queryStatus=$taskInfoStatus; code=$null; lastRunTimeUtc=$null; lastTaskResult=$null }
    }
    else {
        try {
            $info = Get-OpenPathDisposablePolicyConverterTaskInfoQuery -Task $taskObject
            $lastRunTimeUtc = if ($null -ne $info.LastRunTime) { ([datetime]$info.LastRunTime).ToUniversalTime().ToString('o') } else { $null }
            $lastTaskResult = if ($null -ne $info.LastTaskResult) { [long]$info.LastTaskResult } else { $null }
            $taskInfo = [pscustomobject][ordered]@{ queryStatus='observed'; code=$null; lastRunTimeUtc=$lastRunTimeUtc; lastTaskResult=$lastTaskResult }
        }
        catch {
            if (Test-OpenPathDisposableNotFoundError $_) {
                $taskInfo = [pscustomobject][ordered]@{ queryStatus='absent'; code='policy-converter-task-info-not-found'; lastRunTimeUtc=$null; lastTaskResult=$null }
            }
            else {
                $taskInfo = [pscustomobject][ordered]@{ queryStatus='failed'; code='policy-converter-task-info-query-failed'; lastRunTimeUtc=$null; lastTaskResult=$null }
            }
        }
    }

    $serviceObject = $null
    try {
        $services = @(Get-OpenPathDisposableAppIdServiceQuery)
        if ($services.Count -eq 0) {
            $service = [pscustomobject][ordered]@{ queryStatus='absent'; code=$null; name='AppIDSvc'; state=$null; startMode=$null; processId=$null }
        }
        elseif ($services.Count -eq 1) {
            $serviceObject = $services[0]
            $servicePid = if ($serviceObject.PSObject.Properties['ProcessId'] -and $null -ne $serviceObject.ProcessId) { [int]$serviceObject.ProcessId } else { $null }
            $service = [pscustomobject][ordered]@{ queryStatus='observed'; code=$null; name='AppIDSvc'; state=[string]$serviceObject.State; startMode=[string]$serviceObject.StartMode; processId=$servicePid }
        }
        else {
            $service = [pscustomobject][ordered]@{ queryStatus='failed'; code='appid-service-query-ambiguous'; name='AppIDSvc'; state=$null; startMode=$null; processId=$null }
        }
    }
    catch {
        if (Test-OpenPathDisposableNotFoundError $_) {
            $service = [pscustomobject][ordered]@{ queryStatus='absent'; code='appid-service-not-found'; name='AppIDSvc'; state=$null; startMode=$null; processId=$null }
        }
        else {
            $service = [pscustomobject][ordered]@{ queryStatus='failed'; code='appid-service-query-failed'; name='AppIDSvc'; state=$null; startMode=$null; processId=$null }
        }
    }

    if (-not $serviceObject) {
        $processStatus = if ($service.queryStatus -eq 'absent') { 'not-observed-service-absent' } else { 'not-observed-service-unavailable' }
        $process = [pscustomobject][ordered]@{ queryStatus=$processStatus; code=$null; processId=$null; creationTimeUtc=$null }
    }
    elseif ($null -eq $service.processId) {
        $process = [pscustomobject][ordered]@{ queryStatus='not-observed-service-pid-unavailable'; code=$null; processId=$null; creationTimeUtc=$null }
    }
    elseif ([int]$service.processId -le 0) {
        $process = [pscustomobject][ordered]@{ queryStatus='not-observed-service-pid-zero'; code=$null; processId=[int]$service.processId; creationTimeUtc=$null }
    }
    else {
        try {
            $processObject = Get-OpenPathDisposableAppIdProcessQuery -ProcessId ([int]$service.processId)
            $creationTimeUtc = if ($processObject -and $null -ne $processObject.StartTime) { ([datetime]$processObject.StartTime).ToUniversalTime().ToString('o') } else { $null }
            if ($processObject) {
                $process = [pscustomobject][ordered]@{ queryStatus='observed'; code=$null; processId=[int]$service.processId; creationTimeUtc=$creationTimeUtc }
            }
            else {
                $process = [pscustomobject][ordered]@{ queryStatus='absent'; code=$null; processId=[int]$service.processId; creationTimeUtc=$null }
            }
        }
        catch {
            if (Test-OpenPathDisposableNotFoundError $_) {
                $process = [pscustomobject][ordered]@{ queryStatus='absent'; code='appid-process-not-found'; processId=[int]$service.processId; creationTimeUtc=$null }
            }
            else {
                $process = [pscustomobject][ordered]@{ queryStatus='failed'; code='appid-process-query-failed'; processId=[int]$service.processId; creationTimeUtc=$null }
            }
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        status = 'observed'
        context = $Context
        capturedAtUtc = $capturedAtUtc
        runtime = $runtime
        task = $task
        taskInfo = $taskInfo
        service = $service
        process = $process
    }
}

function Invoke-OpenPathDisposablePostApplicationPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$FailureResult,
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$Lifecycle
    )

    $notStarted = {
        param([string]$Reason)
        [pscustomobject][ordered]@{
            status = 'not-started'
            reason = $Reason
            trigger = $null
            anchor = $null
            startedAtUtc = $null
            endedAtUtc = $null
            policyReapplied = $false
            edge = $null
            deniedPeControl = $null
        }
    }
    $failureDetailCode = Get-OpenPathDisposableFieldValue -InputObject $FailureResult -Name 'failureDetailCode'
    if ([string]$failureDetailCode -ne 'boundary-edge-execution-failed') {
        return & $notStarted 'original-failure-not-edge-boundary'
    }
    $edgeBoundaryEvidence = Get-OpenPathDisposableFieldValue -InputObject $FailureResult -Name 'edgeBoundaryEvidence'
    $initial = Get-OpenPathDisposableFieldValue -InputObject $edgeBoundaryEvidence -Name 'initial'
    if (-not $initial) {
        return & $notStarted 'original-edge-evidence-unavailable'
    }
    $initialProbeName = [string](Get-OpenPathDisposableFieldValue -InputObject $initial -Name 'probeName')
    $edgePath = [string](Get-OpenPathDisposableFieldValue -InputObject $initial -Name 'executablePath')
    $studentSid = [string](Get-OpenPathDisposableFieldValue -InputObject $initial -Name 'studentSid')
    if ($initialProbeName -ne 'Canonical Edge deny' -or
        [string]::IsNullOrWhiteSpace($edgePath) -or [string]::IsNullOrWhiteSpace($studentSid) -or
        -not $Target.PSObject.Properties['Sid'] -or
        -not [string]::Equals([string]$Target.Sid, $studentSid, [StringComparison]::OrdinalIgnoreCase) -or
        -not $Target.PSObject.Properties['UserName'] -or -not $Target.UserName -or
        -not $Target.PSObject.Properties['Password'] -or -not $Target.Password) {
        return & $notStarted 'original-edge-subject-unavailable'
    }
    $lifecycleStatus = Get-OpenPathDisposableFieldValue -InputObject $Lifecycle -Name 'status'
    $window = Get-OpenPathDisposableFieldValue -InputObject $Lifecycle -Name 'window'
    $queries = Get-OpenPathDisposableFieldValue -InputObject $Lifecycle -Name 'queries'
    $query = Get-OpenPathDisposableFieldValue -InputObject $queries -Name '8001'
    if ([string]$lifecycleStatus -ne 'observed' -or -not $window -or -not $query) {
        return & $notStarted 'lifecycle-8001-unavailable'
    }
    $native = Get-OpenPathDisposableFieldValue -InputObject $query -Name 'nativePowerShellComparison'
    $queryStatus = Get-OpenPathDisposableFieldValue -InputObject $query -Name 'status'
    $querySucceeded = Get-OpenPathDisposableFieldValue -InputObject $query -Name 'querySucceeded'
    $queryEventCount = Get-OpenPathDisposableFieldValue -InputObject $query -Name 'eventCount'
    $nativeStatus = Get-OpenPathDisposableFieldValue -InputObject $native -Name 'status'
    $nativeSucceeded = Get-OpenPathDisposableFieldValue -InputObject $native -Name 'querySucceeded'
    $nativeEventCount = Get-OpenPathDisposableFieldValue -InputObject $native -Name 'eventCount'
    if ([string]$queryStatus -ne 'QUERY_SUCCEEDED_MATCHES' -or -not [bool]$querySucceeded -or [int]$queryEventCount -lt 1 -or
        -not $native -or [string]$nativeStatus -ne 'QUERY_SUCCEEDED_MATCHES' -or -not [bool]$nativeSucceeded -or [int]$nativeEventCount -lt 1) {
        return & $notStarted 'lifecycle-8001-native-match-unavailable'
    }
    $windowStart = $null
    $windowEnd = $null
    try {
        $windowStart = [datetime](Get-OpenPathDisposableFieldValue -InputObject $window -Name 'launchRequestedAtUtc')
        $windowEnd = [datetime](Get-OpenPathDisposableFieldValue -InputObject $window -Name 'captureEndedAtUtc')
    }
    catch {}
    if (-not $windowStart -or -not $windowEnd -or $windowEnd -lt $windowStart) {
        return & $notStarted 'lifecycle-window-invalid'
    }
    $validAnchors = @()
    foreach ($event in @((Get-OpenPathDisposableFieldValue -InputObject $query -Name 'events'))) {
        $observedEventId = Get-OpenPathDisposableFieldValue -InputObject $event -Name 'id'
        $observedRecordId = Get-OpenPathDisposableFieldValue -InputObject $event -Name 'recordId'
        $observedTime = Get-OpenPathDisposableFieldValue -InputObject $event -Name 'timeCreatedUtc'
        $parsingStatus = Get-OpenPathDisposableFieldValue -InputObject $event -Name 'parsingStatus'
        if (-not $event -or $null -eq $observedEventId -or $null -eq $observedRecordId -or
            -not $observedTime -or [string]$parsingStatus -ne 'fieldless') { continue }
        $eventId = $null
        $recordId = $null
        $eventTime = $null
        try {
            $eventId = [int]$observedEventId
            $recordId = [long]$observedRecordId
            $eventTime = [datetime]$observedTime
        }
        catch { continue }
        if ($eventId -eq 8001 -and $recordId -gt 0 -and $eventTime -ge $windowStart -and $eventTime -le $windowEnd) {
            $validAnchors += [pscustomobject]@{ id=$eventId; recordId=$recordId; time=$eventTime }
        }
    }
    $selectedAnchor = $validAnchors | Sort-Object time, recordId | Select-Object -Last 1
    if (-not $selectedAnchor) { return & $notStarted 'lifecycle-8001-anchor-invalid' }

    $startedAt = Get-Date
    if ($selectedAnchor.time -gt $startedAt) { return & $notStarted 'lifecycle-8001-anchor-future' }
    $startedAtUtc = $startedAt.ToUniversalTime().ToString('o')
    $anchorTimeUtc = $selectedAnchor.time.ToUniversalTime().ToString('o')
    $edge = $null
    $deniedPeControl = $null
    try {
        try {
            $run = Invoke-StudentExecutableTaskProbe `
                -ProbeName 'Post-application Edge deny' `
                -UserName $Target.UserName `
                -Password $Target.Password `
                -ExecutablePath $edgePath `
                -Arguments '--new-window about:blank' `
                -Expectation ExpectDenied `
                -ProcessName 'msedge' `
                -StudentSid $studentSid `
                -PackagedAppPattern 'MicrosoftEdge|Microsoft\.MicrosoftEdge|msedge' `
                -TimeoutSeconds 5 `
                -SuppressFailureDiagnostics `
                -CaptureEnforcementDiagnostics `
                -UseNativeStudentProcess
            $correlated = if ($run.evidence -and $run.evidence.PSObject.Properties['correlatedEvent']) { $run.evidence.correlatedEvent } else { $null }
            $denyObserved = $false
            if ($correlated -and $correlated.PSObject.Properties['id'] -and
                $correlated.PSObject.Properties['observedPath'] -and $correlated.observedPath -and
                $correlated.PSObject.Properties['observedUserSid'] -and $correlated.observedUserSid) {
                $denyId = $null
                try { $denyId = [int]$correlated.id } catch {}
                $denyObserved = $denyId -in @(8004, 8022) -and
                    [string]::Equals([string]$correlated.observedPath, $edgePath, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string]$correlated.observedUserSid, $studentSid, [StringComparison]::OrdinalIgnoreCase)
            }
            $edge = [pscustomobject][ordered]@{
                status = 'observed'
                outcome = if ($denyObserved) { 'blocked' } else { 'inconclusive' }
                executablePath = $edgePath
                studentSid = $studentSid
                evidence = $run.evidence
            }
        }
        catch {
            $edgeFailedAt = Get-Date
            $failureEvidence = $null
            try { $failureEvidence = Get-OpenPathDisposableBoundaryFailureEvidence } catch {}
            $registeredAt = $null
            if ($failureEvidence -and $failureEvidence.PSObject.Properties['taskRegisteredAtUtc'] -and $failureEvidence.taskRegisteredAtUtc) {
                try { $registeredAt = [datetime]$failureEvidence.taskRegisteredAtUtc } catch {}
            }
            $evidenceMatches = $failureEvidence -and
                $failureEvidence.PSObject.Properties['probeName'] -and [string]$failureEvidence.probeName -eq 'Post-application Edge deny' -and
                $failureEvidence.PSObject.Properties['executablePath'] -and [string]::Equals([string]$failureEvidence.executablePath, $edgePath, [StringComparison]::OrdinalIgnoreCase) -and
                $failureEvidence.PSObject.Properties['studentSid'] -and [string]::Equals([string]$failureEvidence.studentSid, $studentSid, [StringComparison]::OrdinalIgnoreCase) -and
                $registeredAt -and $registeredAt -ge $startedAt -and $registeredAt -le $edgeFailedAt
            if ($evidenceMatches) {
                $snapshot = $failureEvidence | ConvertTo-Json -Depth 14 | ConvertFrom-Json
                $executionObserved = $false
                if ($snapshot.PSObject.Properties['failureCode'] -and [string]$snapshot.failureCode -eq 'exact-student-process-observed-without-block-event') {
                    foreach ($process in @($snapshot.processes)) {
                        $tokenMatch = $process.PSObject.Properties['tokenUserSid'] -and $process.tokenUserSid -and
                            [string]::Equals([string]$process.tokenUserSid, $studentSid, [StringComparison]::OrdinalIgnoreCase)
                        $samFallback = $process.PSObject.Properties['tokenUserSid'] -and $null -eq $process.tokenUserSid -and
                            $process.PSObject.Properties['samSid'] -and [string]::Equals([string]$process.samSid, $studentSid, [StringComparison]::OrdinalIgnoreCase) -and
                            $process.PSObject.Properties['samTokenSidMatch'] -and ($null -eq $process.samTokenSidMatch -or [bool]$process.samTokenSidMatch)
                        if ($process.PSObject.Properties['matchesStudentSid'] -and [bool]$process.matchesStudentSid -and
                            $process.PSObject.Properties['executablePath'] -and [string]::Equals([string]$process.executablePath, $edgePath, [StringComparison]::OrdinalIgnoreCase) -and
                            ($tokenMatch -or $samFallback)) {
                            $executionObserved = $true
                            break
                        }
                    }
                }
                $edge = [pscustomobject][ordered]@{
                    status = 'observed'
                    outcome = if ($executionObserved) { 'execution-observed' } else { 'inconclusive' }
                    executablePath = $edgePath
                    studentSid = $studentSid
                    evidence = $snapshot
                }
            }
            else {
                $edge = [pscustomobject][ordered]@{
                    status = 'unavailable'
                    code = 'post-application-edge-evidence-unavailable'
                    outcome = 'inconclusive'
                    executablePath = $edgePath
                    studentSid = $studentSid
                }
            }
        }
    }
    finally {
        $peStartedAt = Get-Date
        try {
            $deniedPeControl = Invoke-OpenPathDisposableDeniedPeControl -Target $Target
        }
        catch {
            $peEndedAt = Get-Date
            $peStartedAtUtc = $peStartedAt.ToUniversalTime().ToString('o')
            $peEndedAtUtc = $peEndedAt.ToUniversalTime().ToString('o')
            $deniedPeControl = [pscustomobject][ordered]@{
                status = 'unavailable'
                code = 'benign-pe-control-failed'
                outcome = 'inconclusive'
                startedAtUtc = $peStartedAtUtc
                endedAtUtc = $peEndedAtUtc
                policyReapplied = $false
            }
        }
    }
    $endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    return [pscustomobject][ordered]@{
        status = 'observed'
        reason = $null
        trigger = 'actual-8001-with-native-match'
        anchor = [pscustomobject][ordered]@{ id=[int]$selectedAnchor.id; recordId=[long]$selectedAnchor.recordId; timeCreatedUtc=$anchorTimeUtc }
        startedAtUtc = $startedAtUtc
        endedAtUtc = $endedAtUtc
        policyReapplied = $false
        edge = $edge
        deniedPeControl = $deniedPeControl
    }
}

function Invoke-OpenPathDisposableDeniedPeControl {
    param([Parameter(Mandatory = $true)][object]$Target)
    $start = (Get-Date).ToUniversalTime().ToString('o')
    $probePath = if ($Target.ProfilePath) { Join-Path $Target.ProfilePath 'openpath-e2e-probe.exe' }
    if (-not $probePath -or -not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ status='unavailable'; code='benign-pe-missing'; outcome='inconclusive'; policyReapplied=$false; startedAtUtc=$start; endedAtUtc=(Get-Date).ToUniversalTime().ToString('o') }
    }
    $marker = Join-Path $Target.ProfilePath ("openpath-e2e-probe-$([guid]::NewGuid().ToString('N')).marker")
    try {
        $policyCommand = Get-Command -Name Get-OpenPathTestAppLockerPolicyDecision -ErrorAction SilentlyContinue
        $policy = if ($policyCommand) {
            & $policyCommand -ExecutablePath $probePath -StudentSid $Target.Sid
        }
        else {
            [pscustomobject][ordered]@{ status='unknown'; decision='unknown'; exactPath=$probePath; exactSid=$Target.Sid; runtime=$null; nativePowerShellComparison=$null }
        }
        $policyProjection = [pscustomobject][ordered]@{
            status = $policy.status
            decision = $policy.decision
            exactPath = $policy.exactPath
            exactSid = $policy.exactSid
            runtime = ConvertTo-OpenPathDisposableRuntimeProjection -Runtime $(if ($policy.PSObject.Properties['runtime']) { $policy.runtime })
            nativePowerShellComparison = ConvertTo-OpenPathDisposableNativePolicyProjection -Native $(if ($policy.PSObject.Properties['nativePowerShellComparison']) { $policy.nativePowerShellComparison })
        }
        try {
            $peHash = (Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash
            $run = Invoke-StudentExecutableTaskProbe -ProbeName 'Canonical benign PE deny control' -UserName $Target.UserName -Password $Target.Password -ExecutablePath $probePath -Arguments "`"$marker`"" -Expectation ExpectDenied -ProcessName 'openpath-e2e-probe' -StudentSid $Target.Sid -CaptureEnforcementDiagnostics -UseNativeStudentProcess
            $correlated = if ($run.evidence.PSObject.Properties['correlatedEvent']) { $run.evidence.correlatedEvent } else { $null }
            $blocked = $false
            if ($correlated -and $correlated.PSObject.Properties['id'] -and $correlated.PSObject.Properties['observedPath'] -and $correlated.PSObject.Properties['observedUserSid'] -and [int]$correlated.id -eq 8004) {
                $blocked = [string]::Equals([string]$correlated.observedPath, $probePath, [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$correlated.observedUserSid, [string]$Target.Sid, [StringComparison]::OrdinalIgnoreCase)
            }
            $markerObserved = Test-Path -LiteralPath $marker
            return [pscustomobject][ordered]@{
                status = 'observed'
                outcome = if ($markerObserved) { 'execution-observed' } elseif ($blocked) { 'blocked' } else { 'inconclusive' }
                executablePath = $probePath
                executableSha256 = $peHash
                studentSid = $Target.Sid
                markerObserved = $markerObserved
                startedAtUtc = $start
                endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                policyReapplied = $false
                testAppLockerPolicyDecision = $policyProjection
                evidence = $run.evidence
            }
        }
        catch {
            $evidence = Get-OpenPathLastBoundaryProbeFailureEvidence
            $exactProcess = $false
            if ($evidence -and $evidence.PSObject.Properties['failureCode'] -and [string]$evidence.failureCode -eq 'exact-student-process-observed-without-block-event') {
                foreach ($process in @($evidence.processes)) {
                    $tokenMatch = $process -and $process.PSObject.Properties['tokenUserSid'] -and [string]::Equals([string]$process.tokenUserSid, [string]$Target.Sid, [StringComparison]::OrdinalIgnoreCase)
                    $samFallback = $process -and $process.PSObject.Properties['tokenUserSid'] -and $null -eq $process.tokenUserSid -and $process.PSObject.Properties['samSid'] -and [string]::Equals([string]$process.samSid, [string]$Target.Sid, [StringComparison]::OrdinalIgnoreCase) -and $process.PSObject.Properties['samTokenSidMatch'] -and ($null -eq $process.samTokenSidMatch -or [bool]$process.samTokenSidMatch)
                    if ($process -and $process.PSObject.Properties['matchesStudentSid'] -and [bool]$process.matchesStudentSid -and [string]::Equals([string]$process.executablePath, $probePath, [StringComparison]::OrdinalIgnoreCase) -and ($tokenMatch -or $samFallback)) { $exactProcess = $true; break }
                }
            }
            return [pscustomobject][ordered]@{
                status = 'observed'
                outcome = if ((Test-Path -LiteralPath $marker) -or $exactProcess) { 'execution-observed' } else { 'inconclusive' }
                executablePath = $probePath
                executableSha256 = $peHash
                studentSid = $Target.Sid
                markerObserved = Test-Path -LiteralPath $marker
                startedAtUtc = $start
                endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                policyReapplied = $false
                testAppLockerPolicyDecision = $policyProjection
                evidence = $evidence
            }
        }
    }
    catch {
        return [pscustomobject][ordered]@{ status='unavailable'; code='benign-pe-control-failed'; outcome='inconclusive'; executablePath=$probePath; studentSid=$Target.Sid; startedAtUtc=$start; endedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); policyReapplied=$false }
    }
    finally { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
}

function Test-OpenPathDisposableSafeSegment {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw "invalid-$Name"
    }
}

function ConvertTo-OpenPathDisposableProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    # CommandLineToArgvW-compatible quoting.  This is used only for
    # ProcessStartInfo.Arguments; no shell or text command interpreter is used.
    if ($Value -notmatch '[\s"\\]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Write-OpenPathDisposableJsonAtomic {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Get-OpenPathDisposableCanonicalPhase {
    param([Parameter(Mandatory = $true)][string]$Mode)
    switch ($Mode) {
        'Prepare' { return 'prepare' }
        'Observe' { return 'observe' }
        'AfterReboot' { return 'afterReboot' }
        'Cleanup' { return 'cleanup' }
        default { throw 'invalid-mode' }
    }
}

function Invoke-OpenPathDisposableWindowsController {
    <#
    .SYNOPSIS
    Runs one phase of an externally controlled disposable Windows target.
    .DESCRIPTION
    This adapter owns only its child process and its run/attempt/scenario
    directory.  It never provisions a VM, applies policy, or turns a missing
    controller into a passing observation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Observe', 'AfterReboot', 'Cleanup')][string]$Mode,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$RunAttempt,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ScenarioId,
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ArtifactsRoot,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 1800,
        [string]$TemplatePath = '',
        [string]$PersonalizedExePath = ''
    )

    $phase = Get-OpenPathDisposableCanonicalPhase -Mode $Mode
    Test-OpenPathDisposableSafeSegment -Value $RunId -Name 'run-id'
    Test-OpenPathDisposableSafeSegment -Value $ScenarioId -Name 'scenario-id'
    if (-not [IO.Path]::IsPathFullyQualified($Command)) { throw 'controller-command-must-be-absolute' }
    if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) {
        return [pscustomobject][ordered]@{ status = 'blocked'; code = 'BLOCKED_PLATFORM_VALIDATION'; phase = $phase; runId = $RunId; runAttempt = $RunAttempt; scenarioId = $ScenarioId }
    }

    $runRoot = Join-Path (Join-Path (Join-Path $ArtifactsRoot $RunId) ([string]$RunAttempt)) $ScenarioId
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $runRootFull = [IO.Path]::GetFullPath($runRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $payloadFull = [IO.Path]::GetFullPath($PayloadPath)
    if (-not [string]::Equals($payloadFull, $runRootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $payloadFull.StartsWith($runRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'controller-payload-outside-scenario'
    }
    $outputPath = Join-Path $runRoot "$phase-observation.json"
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    $nonce = [guid]::NewGuid().ToString('N')
    $payload = [ordered]@{
        schemaVersion = 2
        suiteKind = if ($env:OPENPATH_SUITE_KIND) { [string]$env:OPENPATH_SUITE_KIND } else { 'DesktopSurvival' }
        policyConverterMode = if ($env:OPENPATH_POLICY_CONVERTER_MODE) { [string]$env:OPENPATH_POLICY_CONVERTER_MODE } else { $null }
        runId = $RunId
        runAttempt = $RunAttempt
        scenarioId = $ScenarioId
        phase = $phase
        sourceCommitSha = if ($env:OPENPATH_SOURCE_SHA) { [string]$env:OPENPATH_SOURCE_SHA } else { '' }
        correlationNonce = $nonce
        outputPath = $outputPath
        artifactsRoot = $runRoot
    }
    if ([string]$payload.suiteKind -eq 'PolicyConverterContrast') {
        $payload.contrastHarness = 'tests/e2e/ci/run-windows-policy-converter-contrast.ps1'
    }
    else {
        $payload.desktopHarness = 'tests/e2e/ci/run-windows-offline-installer-exe.ps1'
    }
    foreach ($artifact in @(
            [pscustomobject]@{ Path = $TemplatePath; PathKey = 'templatePath'; HashKey = 'templateSha256'; ErrorCode = 'controller-template-missing' },
            [pscustomobject]@{ Path = $PersonalizedExePath; PathKey = 'personalizedExePath'; HashKey = 'personalizedExeSha256'; ErrorCode = 'controller-personalized-exe-missing' }
        )) {
        if ([string]::IsNullOrWhiteSpace($artifact.Path)) { continue }
        if (-not (Test-Path -LiteralPath $artifact.Path -PathType Leaf)) { throw $artifact.ErrorCode }
        $resolved = (Resolve-Path -LiteralPath $artifact.Path -ErrorAction Stop).Path
        $payload[$artifact.PathKey] = $resolved
        $payload[$artifact.HashKey] = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (Test-Path -LiteralPath $PayloadPath -PathType Leaf) {
        try {
            $existingPayload = Get-Content -LiteralPath $PayloadPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($property in @($existingPayload.PSObject.Properties)) {
                if (-not $payload.Contains($property.Name)) { $payload[$property.Name] = $property.Value }
            }
        }
        catch { throw 'controller-payload-invalid' }
    }
    Write-OpenPathDisposableJsonAtomic -Path $PayloadPath -Value $payload

    $hostPath = $Command
    $arguments = @('-PayloadPath', $PayloadPath, '-OutputPath', $outputPath, '-Mode', $Mode, '-RunId', $RunId, '-RunAttempt', ([string]$RunAttempt), '-ScenarioId', $ScenarioId, '-CorrelationNonce', $nonce)
    if ([IO.Path]::GetExtension($Command).ToLowerInvariant() -eq '.ps1') {
        $pwsh = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) { $pwsh = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue }
        if ($null -eq $pwsh) {
            return [pscustomobject][ordered]@{ status = 'blocked'; code = 'BLOCKED_PLATFORM_VALIDATION'; phase = $phase; runId = $RunId; runAttempt = $RunAttempt; scenarioId = $ScenarioId }
        }
        $hostPath = [string]$pwsh.Source
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $Command) + $arguments
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-OpenPathDisposableProcessArgument -Value ([string]$_) }) -join ' ')
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'controller-start-failed' }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
            throw 'controller-timeout'
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0) {
            # Exit code 2 is the documented blocked signal, but it only counts
            # as blocked with a correlated blocked observation on disk. A bare
            # exit code must never turn into a passing or blocked result.
            if ($process.ExitCode -eq 2 -and
                (Test-OpenPathDisposableBlockedObservation -Path $outputPath -Mode $Mode -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $ScenarioId -ExpectedNonce $nonce)) {
                return [pscustomobject][ordered]@{ status = 'blocked'; code = 'BLOCKED_PLATFORM_VALIDATION'; phase = $phase; runId = $RunId; runAttempt = $RunAttempt; scenarioId = $ScenarioId }
            }
            throw ('controller-exit-{0}' -f $process.ExitCode)
        }
        # Do not report a successful child exit until the phase output is
        # present and correlated. The phase script re-reads it for its payload,
        # but this adapter is also a public contract used by direct callers.
        Read-OpenPathDisposableWindowsObservation -Path $outputPath -Mode $Mode -RunId $RunId -RunAttempt $RunAttempt -ScenarioId $ScenarioId -ExpectedNonce $nonce | Out-Null
        return [pscustomobject][ordered]@{ status = 'completed'; code = 'controller-completed'; phase = $phase; runId = $RunId; runAttempt = $RunAttempt; scenarioId = $ScenarioId; correlationNonce = $nonce; outputPath = $outputPath; stdout = if ($stdout.Length -gt 2048) { $stdout.Substring(0, 2048) } else { $stdout }; stderr = if ($stderr.Length -gt 2048) { $stderr.Substring(0, 2048) } else { $stderr } }
    }
    finally { $process.Dispose() }
}

function Test-OpenPathDisposableBlockedObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Observe', 'AfterReboot', 'Cleanup')][string]$Mode,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$RunAttempt,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ScenarioId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{32}$')][string]$ExpectedNonce
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $observation = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    foreach ($name in @('status', 'runId', 'runAttempt', 'scenarioId', 'phase', 'correlationNonce')) {
        if ($null -eq $observation.PSObject.Properties[$name]) { return $false }
    }
    $phase = Get-OpenPathDisposableCanonicalPhase -Mode $Mode
    return ([string]$observation.status -eq 'blocked' -and
        [string]$observation.runId -eq $RunId -and
        [int]$observation.runAttempt -eq $RunAttempt -and
        [string]$observation.scenarioId -eq $ScenarioId -and
        [string]$observation.phase -eq $phase -and
        [string]$observation.correlationNonce -eq $ExpectedNonce)
}

function Read-OpenPathDisposableWindowsObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Observe', 'AfterReboot', 'Cleanup')][string]$Mode,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$RunAttempt,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ScenarioId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{32}$')][string]$ExpectedNonce
    )
    $phase = Get-OpenPathDisposableCanonicalPhase -Mode $Mode
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'controller-observation-missing' }
    try { $observation = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw 'controller-observation-invalid-json' }
    foreach ($name in @('runId', 'runAttempt', 'scenarioId', 'phase', 'correlationNonce', 'status', 'observation')) {
        if ($null -eq $observation.PSObject.Properties[$name]) { throw "controller-observation-missing-$name" }
    }
    if ([string]$observation.status -ne 'passed' -or [string]$observation.runId -ne $RunId -or [int]$observation.runAttempt -ne $RunAttempt -or [string]$observation.scenarioId -ne $ScenarioId -or [string]$observation.phase -ne $phase -or [string]$observation.correlationNonce -ne $ExpectedNonce) {
        throw 'controller-observation-correlation-mismatch'
    }
    # ConvertFrom-Json returns PSCustomObject for a JSON object. Arrays,
    # scalars and null bodies are not observations even when status=passed.
    if ($null -eq $observation.observation -or
        $observation.observation -is [System.Array] -or
        $observation.observation -is [string] -or
        $observation.observation -is [System.ValueType]) {
        throw 'controller-observation-body-invalid'
    }
    return $observation
}

Export-ModuleMember -Function New-OpenPathDisposableStandardTarget, Initialize-OpenPathDisposableTargetProfile, Assert-OpenPathDisposableTarget, Assert-OpenPathPreparedTargetInstalled, Invoke-OpenPathInstalledBoundaryProbes, Get-OpenPathDisposableBoundaryFailureEvidence, Get-OpenPathDisposableFlatEdgeBoundaryFailureContract, Invoke-OpenPathDisposableEdgeBoundaryDiagnostic, Invoke-OpenPathDisposableDeniedPeControl, Invoke-OpenPathDisposablePostApplicationPair, Get-OpenPathDisposablePolicyConverterObservation, New-OpenPathDisposableEdgeBoundaryException, Resolve-OpenPathDisposableEdgeBoundaryFailure, Write-OpenPathOfflineInstallerEvidence, Remove-OpenPathDisposableStandardTarget, Invoke-OpenPathDisposableWindowsController, Read-OpenPathDisposableWindowsObservation
