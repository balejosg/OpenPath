# OpenPath Windows Browser Boundary CI Probes & Verification Module

$script:OpenPathLastBoundaryProbeFailureEvidence = $null

function Invoke-ReportAssertNoFailures {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "$Scope browser-boundary report was not produced: $ReportPath"
    }

    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    $failures = @($report.results | Where-Object { $_.status -eq 'fail' })
    if ($failures.Count -gt 0) {
        $names = ($failures | ForEach-Object { $_.name }) -join ', '
        throw "$Scope browser-boundary probes failed: $($failures.Count): $names"
    }

    return $report
}

function Assert-RequiredStudentProbeStatuses {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][string[]]$ProbeNames
    )

    $statuses = [ordered]@{}
    foreach ($probeName in $ProbeNames) {
        $probe = @($Report.results | Where-Object { $_.name -eq $probeName }) | Select-Object -First 1
        if (-not $probe) {
            throw "Required student browser-boundary probe is missing: $probeName"
        }
        $statuses[$probeName] = [string]$probe.status
        if ($probe.status -ne 'pass') {
            throw "Required student browser-boundary probe did not pass: $probeName status=$($probe.status)"
        }
    }

    return [pscustomobject]$statuses
}

function New-OpenPathProbePayloadBinary {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $cscPaths = @(
        "${env:WINDIR}\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "${env:WINDIR}\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $csc = $cscPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) {
        throw "C# compiler csc.exe was not found to build probe payload binary."
    }

    $srcPath = Join-Path ([System.IO.Path]::GetTempPath()) "probe-source-$([guid]::NewGuid().ToString('N')).cs"
    $code = @'
using System;
using System.IO;
using System.Threading;

class Program {
    static void Main(string[] args) {
        if (args.Length > 0 && !string.IsNullOrEmpty(args[0])) {
            try {
                File.WriteAllText(args[0], "executed");
            } catch {}
        }
        Thread.Sleep(30000);
    }
}
'@
    try {
        Set-Content -LiteralPath $srcPath -Value $code -Encoding UTF8
        & $csc /nologo /target:exe /out:$OutputPath $srcPath *> $null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
            throw "csc.exe compilation of probe payload failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Remove-Item -LiteralPath $srcPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenPathSchtasksCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # schtasks can emit a warning on stderr while returning success. Preserve
        # its native exit code instead of promoting that warning to a PowerShell
        # terminating error when the caller uses ErrorActionPreference=Stop.
        $ErrorActionPreference = 'Continue'
        & $Command *> $null
        return [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-OpenPathProcessTokenBoundaryEvidence {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$RestrictedGroupSid = ''
    )

    $unavailable = {
        param([string]$Reason)
        return [pscustomobject][ordered]@{
            status = 'unavailable'
            reason = $Reason
            processId = $ProcessId
            tokenUserSid = $null
            restrictedGroupSid = $RestrictedGroupSid
            restrictedGroupPresent = $null
            restrictedGroupAttributes = $null
            restrictedGroupEnabled = $null
            restrictedGroupDenyOnly = $null
            restrictedGroupDisabled = $null
            restrictedGroupQueryStatus = 'unavailable'
        }
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return & $unavailable 'windows-only'
    }

    try {
        if (-not ([System.Management.Automation.PSTypeName]'OpenPathTokenBoundaryNative').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct SID_AND_ATTRIBUTES {
    public IntPtr Sid;
    public uint Attributes;
}

[StructLayout(LayoutKind.Sequential)]
public struct TOKEN_GROUPS_HEADER {
    public uint GroupCount;
    public SID_AND_ATTRIBUTES Groups;
}

public static class OpenPathTokenBoundaryNative {
    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const uint TokenQuery = 0x0008;
    public const int TokenUser = 1;
    public const int TokenGroups = 2;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr processHandle, uint access, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetTokenInformation(IntPtr tokenHandle, int informationClass, IntPtr information, uint informationLength, out uint returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    public static int SidAndAttributesSize() {
        return Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES));
    }

    public static int TokenGroupsFirstGroupOffset() {
        return (int)Marshal.OffsetOf(typeof(TOKEN_GROUPS_HEADER), "Groups");
    }

    public static SID_AND_ATTRIBUTES ReadSidAndAttributes(IntPtr address) {
        return (SID_AND_ATTRIBUTES)Marshal.PtrToStructure(address, typeof(SID_AND_ATTRIBUTES));
    }
}
'@ -ErrorAction Stop
        }

        $processHandle = [OpenPathTokenBoundaryNative]::OpenProcess(
            [OpenPathTokenBoundaryNative]::ProcessQueryLimitedInformation,
            $false,
            [uint32]$ProcessId)
        if ($processHandle -eq [IntPtr]::Zero) {
            return & $unavailable 'open-process-failed'
        }

        $tokenHandle = [IntPtr]::Zero
        try {
            if (-not [OpenPathTokenBoundaryNative]::OpenProcessToken(
                    $processHandle,
                    [OpenPathTokenBoundaryNative]::TokenQuery,
                    [ref]$tokenHandle)) {
                return & $unavailable 'open-token-failed'
            }

            $tokenUserSid = $null
            $restrictedGroupPresent = $null
            $restrictedGroupAttributes = $null
            $restrictedGroupQueryStatus = if ($RestrictedGroupSid) { 'unavailable' } else { 'not-requested' }
            $tokenUserBuffer = [IntPtr]::Zero
            $groupsBuffer = [IntPtr]::Zero
            try {
                [uint32]$requiredLength = 0
                [OpenPathTokenBoundaryNative]::GetTokenInformation(
                    $tokenHandle,
                    [OpenPathTokenBoundaryNative]::TokenUser,
                    [IntPtr]::Zero,
                    0,
                    [ref]$requiredLength) | Out-Null
                if ($requiredLength -gt 0) {
                    $tokenUserBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$requiredLength)
                    if ([OpenPathTokenBoundaryNative]::GetTokenInformation(
                            $tokenHandle,
                            [OpenPathTokenBoundaryNative]::TokenUser,
                            $tokenUserBuffer,
                            $requiredLength,
                            [ref]$requiredLength)) {
                        $sidPointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($tokenUserBuffer)
                        if ($sidPointer -ne [IntPtr]::Zero) {
                            $tokenUserSid = (New-Object System.Security.Principal.SecurityIdentifier($sidPointer, $null)).Value
                        }
                    }
                }

                if ($RestrictedGroupSid) {
                    [uint32]$requiredLength = 0
                    [OpenPathTokenBoundaryNative]::GetTokenInformation(
                        $tokenHandle,
                        [OpenPathTokenBoundaryNative]::TokenGroups,
                        [IntPtr]::Zero,
                        0,
                        [ref]$requiredLength) | Out-Null
                    if ($requiredLength -gt 0) {
                        $groupsBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$requiredLength)
                        if ([OpenPathTokenBoundaryNative]::GetTokenInformation(
                                $tokenHandle,
                                [OpenPathTokenBoundaryNative]::TokenGroups,
                                $groupsBuffer,
                                $requiredLength,
                                [ref]$requiredLength)) {
                            $groupCount = [Runtime.InteropServices.Marshal]::ReadInt32($groupsBuffer)
                            $groupsOffset = [OpenPathTokenBoundaryNative]::TokenGroupsFirstGroupOffset()
                            $groupStride = [OpenPathTokenBoundaryNative]::SidAndAttributesSize()
                            $restrictedGroupPresent = $false
                            for ($index = 0; $index -lt $groupCount; $index++) {
                                $recordPointer = [IntPtr]::Add($groupsBuffer, $groupsOffset + ($index * $groupStride))
                                $record = [OpenPathTokenBoundaryNative]::ReadSidAndAttributes($recordPointer)
                                $sidPointer = $record.Sid
                                if ($sidPointer -eq [IntPtr]::Zero) { continue }
                                try {
                                    $groupSid = (New-Object System.Security.Principal.SecurityIdentifier($sidPointer, $null)).Value
                                    if ([string]::Equals($groupSid, $RestrictedGroupSid, [System.StringComparison]::OrdinalIgnoreCase)) {
                                        $restrictedGroupPresent = $true
                                        $restrictedGroupAttributes = [uint32]$record.Attributes
                                        break
                                    }
                                }
                                catch {}
                            }
                            $restrictedGroupQueryStatus = 'ok'
                        }
                    }
                }
            }
            finally {
                if ($tokenUserBuffer -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::FreeHGlobal($tokenUserBuffer)
                }
                if ($groupsBuffer -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::FreeHGlobal($groupsBuffer)
                }
            }

            $restrictedGroupEnabled = if ($restrictedGroupPresent) { (($restrictedGroupAttributes -band 0x00000004) -ne 0) } else { $null }
            $restrictedGroupDenyOnly = if ($restrictedGroupPresent) { (($restrictedGroupAttributes -band 0x00000010) -ne 0) } else { $null }
            $restrictedGroupDisabled = if ($restrictedGroupPresent) { -not $restrictedGroupEnabled -and -not $restrictedGroupDenyOnly } else { $null }

            return [pscustomobject][ordered]@{
                status = if ($tokenUserSid) { 'ok' } else { 'partial' }
                reason = if ($tokenUserSid) { $null } else { 'token-user-unavailable' }
                processId = $ProcessId
                tokenUserSid = $tokenUserSid
                restrictedGroupSid = $RestrictedGroupSid
                restrictedGroupPresent = $restrictedGroupPresent
                restrictedGroupAttributes = $restrictedGroupAttributes
                restrictedGroupEnabled = $restrictedGroupEnabled
                restrictedGroupDenyOnly = $restrictedGroupDenyOnly
                restrictedGroupDisabled = $restrictedGroupDisabled
                restrictedGroupQueryStatus = $restrictedGroupQueryStatus
            }
        }
        finally {
            if ($tokenHandle -ne [IntPtr]::Zero) {
                [OpenPathTokenBoundaryNative]::CloseHandle($tokenHandle) | Out-Null
            }
        }
    }
    catch {
        return & $unavailable 'token-query-failed'
    }
    finally {
        if ($processHandle -and $processHandle -ne [IntPtr]::Zero) {
            [OpenPathTokenBoundaryNative]::CloseHandle($processHandle) | Out-Null
        }
    }
}

function Get-OpenPathSamBoundaryEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$StudentSid,
        [string]$GroupName = 'OpenPath-Restricted'
    )

    $evidence = [ordered]@{
        status = 'unavailable'
        reason = $null
        groupName = $GroupName
        groupSid = $null
        targetSid = $StudentSid
        targetMemberPresent = $null
        memberCount = $null
    }
    if ([string]::IsNullOrWhiteSpace($StudentSid)) {
        $evidence.status = 'invalid'
        $evidence.reason = 'student-sid-missing'
        return [pscustomobject]$evidence
    }
    if (-not (Get-Command -Name Get-LocalGroup -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name Get-LocalGroupMember -ErrorAction SilentlyContinue)) {
        $evidence.reason = 'local-group-cmdlets-missing'
        return [pscustomobject]$evidence
    }

    try {
        $group = Get-LocalGroup -Name $GroupName -ErrorAction Stop
        if (-not $group) {
            $evidence.status = 'missing'
            $evidence.reason = 'group-missing'
            return [pscustomobject]$evidence
        }
        $evidence.groupSid = if ($group.PSObject.Properties['SID']) { [string]$group.SID } elseif ($group.PSObject.Properties['Sid']) { [string]$group.Sid } else { $null }
        $members = @(Get-LocalGroupMember -Group ([string]$group.Name) -ErrorAction Stop)
        $evidence.memberCount = $members.Count
        $evidence.targetMemberPresent = @($members | Where-Object {
                $memberSid = if ($_.PSObject.Properties['SID']) { [string]$_.SID } elseif ($_.PSObject.Properties['Sid']) { [string]$_.Sid } else { '' }
                [string]::Equals($memberSid, $StudentSid, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
        $evidence.status = 'ok'
        return [pscustomobject]$evidence
    }
    catch {
        $evidence.reason = 'local-group-query-failed'
        return [pscustomobject]$evidence
    }
}

function Get-OpenPathExactProcessBoundaryEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [Parameter(Mandatory = $true)][string]$StudentSid,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
        [string]$RestrictedGroupSid = ''
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName) -or [string]::IsNullOrWhiteSpace($ExpectedExecutablePath)) {
        return @()
    }

    try {
        $expectedFullPath = [System.IO.Path]::GetFullPath($ExpectedExecutablePath)
        $expectedLeaf = [System.IO.Path]::GetFileName($expectedFullPath)
    }
    catch {
        return @()
    }

    $evidence = @()
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name LIKE '$ProcessName%'" -ErrorAction SilentlyContinue)) {
            $processNameValue = [string]$process.Name
            $processPathValue = [string]$process.ExecutablePath
            if (-not [string]::Equals($processNameValue, $expectedLeaf, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace($processPathValue)) {
                continue
            }
            try {
                $processFullPath = [System.IO.Path]::GetFullPath($processPathValue)
            }
            catch {
                continue
            }
            if (-not [string]::Equals($processFullPath, $expectedFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $samSid = $null
            try {
                $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction SilentlyContinue
                if ($owner) { $samSid = [string]$owner.Sid }
            }
            catch {}

            $processId = [int]$process.ProcessId
            $token = Get-OpenPathProcessTokenBoundaryEvidence -ProcessId $processId -RestrictedGroupSid $RestrictedGroupSid
            $tokenUserSid = [string]$token.tokenUserSid
            $tokenIdentityAvailable = -not [string]::IsNullOrWhiteSpace($tokenUserSid)
            $tokenSidMatches = $tokenIdentityAvailable -and [string]::Equals($tokenUserSid, $StudentSid, [System.StringComparison]::OrdinalIgnoreCase)
            $samSidMatches = -not [string]::IsNullOrWhiteSpace($samSid) -and [string]::Equals($samSid, $StudentSid, [System.StringComparison]::OrdinalIgnoreCase)

            $evidence += [pscustomobject][ordered]@{
                processId = $processId
                name = $processNameValue
                executablePath = $processFullPath
                studentSid = $StudentSid
                samSid = $samSid
                tokenUserSid = $tokenUserSid
                samTokenSidMatch = if ($samSid -and $tokenUserSid) { [string]::Equals($samSid, $tokenUserSid, [System.StringComparison]::OrdinalIgnoreCase) } else { $null }
                tokenQueryStatus = [string]$token.status
                tokenIdentityVerified = $tokenSidMatches
                matchesStudentSid = if ($tokenIdentityAvailable) { $tokenSidMatches } else { $samSidMatches }
                restrictedGroupSid = [string]$token.restrictedGroupSid
                restrictedGroupPresent = $token.restrictedGroupPresent
                restrictedGroupAttributes = $token.restrictedGroupAttributes
                restrictedGroupEnabled = $token.restrictedGroupEnabled
                restrictedGroupDenyOnly = $token.restrictedGroupDenyOnly
                restrictedGroupDisabled = $token.restrictedGroupDisabled
                restrictedGroupQueryStatus = [string]$token.restrictedGroupQueryStatus
            }
        }
    }
    catch {}
    return @($evidence)
}

function Get-OpenPathProbeProcessesForStudent {
    param([string]$ProcessName, [string]$StudentSid, [string]$ExpectedExecutablePath = '', [string]$RestrictedGroupSid = '')
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return @() }
    if ([string]::IsNullOrWhiteSpace($StudentSid)) {
        return @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ ProcessId = $_.Id }
        })
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedExecutablePath)) {
        return @()
    }
    return @(Get-OpenPathExactProcessBoundaryEvidence -ProcessName $ProcessName -StudentSid $StudentSid -ExpectedExecutablePath $ExpectedExecutablePath -RestrictedGroupSid $RestrictedGroupSid |
            Where-Object { $_.matchesStudentSid })
}

function Get-OpenPathEventXmlFields {
    param([Parameter(Mandatory = $true)][object]$Event)

    $fields = [ordered]@{}
    $allowedFieldNames = @(
        'filepath',
        'fullfilepath',
        'path',
        'package',
        'packagename',
        'packagefullname',
        'ruleid',
        'rulename',
        'usersid',
        'user_sid',
        'targetuser',
        'targetusersid',
        'targetusername',
        'processid',
        'pid',
        'targetprocessid',
        'targetlogonid',
        'logonid',
        'logontype',
        'taskname',
        'taskpath'
    )
    $eventXml = $null
    try {
        if ($Event.PSObject.Methods['ToXml']) {
            $eventXml = [xml]$Event.ToXml()
        }
        elseif ($Event.PSObject.Properties['Xml'] -and $Event.Xml) {
            $eventXml = [xml]$Event.Xml
        }
    }
    catch {
        $eventXml = $null
    }
    if (-not $eventXml) {
        return [pscustomobject][ordered]@{ available = $false; fields = $fields }
    }

    # EventData uses <Data Name="..."> while AppLocker 8002/8004 can use
    # UserData/RuleAndFileData leaves. Read only the fields needed for bounded
    # correlation and task/logon identity evidence; never serialize arbitrary XML.
    foreach ($dataNode in @($eventXml.SelectNodes('//*[local-name()="Data"]'))) {
        $nameAttribute = $dataNode.Attributes['Name']
        if (-not $nameAttribute) { continue }
        $name = ([string]$nameAttribute.Value).ToLowerInvariant()
        if ($allowedFieldNames -notcontains $name) { continue }
        if (-not $fields.Contains($name)) {
            $fields[$name] = [string]$dataNode.InnerText
        }
    }

    foreach ($leafNode in @($eventXml.SelectNodes('//*[local-name()="RuleAndFileData"]//*[not(*)]'))) {
        $name = ([string]$leafNode.LocalName).ToLowerInvariant()
        if ($allowedFieldNames -notcontains $name) { continue }
        $value = [string]$leafNode.InnerText
        switch ($name) {
            'targetuser' {
                if (-not $fields.Contains('targetuser')) { $fields.targetuser = $value }
                if (-not $fields.Contains('usersid')) { $fields.usersid = $value }
            }
            'targetprocessid' {
                if (-not $fields.Contains('targetprocessid')) { $fields.targetprocessid = $value }
                if (-not $fields.Contains('processid')) { $fields.processid = $value }
            }
            default {
                if (-not $fields.Contains($name)) { $fields[$name] = $value }
            }
        }
    }

    $execution = $eventXml.SelectSingleNode('//*[local-name()="Execution"]')
    if ($execution -and -not $fields.Contains('processid')) {
        foreach ($attributeName in @('ProcessID', 'ProcessId', 'PID', 'Pid')) {
            $attribute = $execution.Attributes[$attributeName]
            if ($attribute) {
                $fields.processid = [string]$attribute.Value
                break
            }
        }
    }
    return [pscustomobject][ordered]@{ available = $true; fields = $fields }
}

function Get-OpenPathTaskIdentityEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [string]$Principal = '',
        [string]$RunLevel = 'Limited',
        [string]$StudentSid = '',
        [string]$UserName = '',
        [datetime]$StartTime = (Get-Date),
        [string]$RegisteredAtUtc = '',
        [string]$LogonType = '4',
        [switch]$SkipTaskDefinition
    )

    $taskEvidence = [ordered]@{
        status = 'unknown'
        taskName = $TaskName
        expectedStudentSid = if ($StudentSid) { $StudentSid } else { $null }
        taskDefinitionPrincipal = $null
        taskLogonType = $null
        taskRunLevel = $null
        principal = $null
        principalSource = 'unknown'
        runLevel = $null
        runLevelSource = 'unknown'
        registeredAtUtc = if ($RegisteredAtUtc) { $RegisteredAtUtc } else { $null }
        taskSchedulerQueryStatus = 'unknown'
        taskSchedulerEvents = @()
        securityQueryStatus = 'unknown'
        securityLogons = @()
        reason = $null
    }

    if (-not $SkipTaskDefinition -and (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        try {
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            if ($task) {
                $taskEvidence.status = 'observed'
                $taskPrincipal = if ($task.Principal -and $task.Principal.UserId) { [string]$task.Principal.UserId } else { $null }
                if ($taskPrincipal) {
                    $taskEvidence.taskDefinitionPrincipal = $taskPrincipal
                    $taskEvidence.principal = $taskPrincipal
                    $taskEvidence.principalSource = 'task-definition'
                }
                if ($task.Principal -and $task.Principal.LogonType) {
                    $taskEvidence.taskLogonType = [string]$task.Principal.LogonType
                }
                if ($task.Principal -and $task.Principal.RunLevel) {
                    $taskEvidence.taskRunLevel = [string]$task.Principal.RunLevel
                    $taskEvidence.runLevel = $taskEvidence.taskRunLevel
                    $taskEvidence.runLevelSource = 'task-definition'
                }
            }
            elseif (-not $taskEvidence.reason) {
                $taskEvidence.reason = 'task-not-observed'
            }
        }
        catch {
            $taskEvidence.reason = 'task-query-unavailable'
        }
    }
    elseif ($SkipTaskDefinition) {
        $taskEvidence.reason = 'task-definition-query-deferred'
    }
    elseif (-not $taskEvidence.reason) {
        $taskEvidence.reason = 'task-cmdlet-unavailable'
    }

    if (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue) {
        try {
            $taskRecords = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'Microsoft-Windows-TaskScheduler/Operational'
                    Id = @(129, 200, 201)
                    StartTime = $StartTime
                } -ErrorAction Stop)
            $taskEvidence.taskSchedulerQueryStatus = 'observed'
            foreach ($record in @($taskRecords | Select-Object -First 32)) {
                $xmlFields = Get-OpenPathEventXmlFields -Event $record
                $fields = $xmlFields.fields
                $observedTaskName = if ($fields.Contains('taskname')) { [string]$fields.taskname } elseif ($fields.Contains('taskpath')) { [string]$fields.taskpath } else { $null }
                if ($observedTaskName -and $observedTaskName -notmatch [regex]::Escape($TaskName)) { continue }
                $eventPid = $null
                $parsedPid = 0L
                if ($fields.Contains('processid') -and [long]::TryParse([string]$fields.processid, [ref]$parsedPid) -and $parsedPid -gt 0) { $eventPid = [int]$parsedPid }
                $eventTime = $null
                if ($record.PSObject.Properties['TimeCreated'] -and $record.TimeCreated) {
                    try { $eventTime = ([datetime]$record.TimeCreated).ToUniversalTime().ToString('o') } catch {}
                }
                $taskEvidence.taskSchedulerEvents += [pscustomobject][ordered]@{
                    id = [int]$record.Id
                    taskName = $observedTaskName
                    processId = $eventPid
                    pidStatus = if ($null -eq $eventPid) { 'unavailable' } else { 'observed' }
                    timeCreatedUtc = $eventTime
                }
            }
        }
        catch {
            $taskEvidence.taskSchedulerQueryStatus = 'unavailable'
            if (-not $taskEvidence.reason) { $taskEvidence.reason = 'task-scheduler-log-unreadable' }
        }
    }
    else {
        $taskEvidence.taskSchedulerQueryStatus = 'unavailable'
        if (-not $taskEvidence.reason) { $taskEvidence.reason = 'event-log-cmdlet-unavailable' }
    }

    if (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue) {
        try {
            # Read Security 4624 only; never enable auditing or alter policy here.
            $securityRecords = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'Security'
                    Id = 4624
                    StartTime = $StartTime
                } -ErrorAction Stop)
            $taskEvidence.securityQueryStatus = 'observed'
            foreach ($record in @($securityRecords | Select-Object -First 32)) {
                $xmlFields = Get-OpenPathEventXmlFields -Event $record
                if (-not $xmlFields.available) { continue }
                $fields = $xmlFields.fields
                $targetSid = if ($fields.Contains('targetusersid')) { [string]$fields.targetusersid } else { $null }
                $targetName = if ($fields.Contains('targetusername')) { [string]$fields.targetusername } else { $null }
                $userMatches = ([string]::IsNullOrWhiteSpace($StudentSid) -and [string]::IsNullOrWhiteSpace($UserName)) -or
                    ($StudentSid -and $targetSid -and [string]::Equals($StudentSid, $targetSid, [System.StringComparison]::OrdinalIgnoreCase)) -or
                    ($UserName -and $targetName -and ($targetName -split '\\')[-1] -eq $UserName)
                if (-not $userMatches) { continue }
                $securityLogonType = if ($fields.Contains('logontype')) { [string]$fields.logontype } else { $null }
                $securityLogonId = if ($fields.Contains('targetlogonid')) { [string]$fields.targetlogonid } elseif ($fields.Contains('logonid')) { [string]$fields.logonid } else { $null }
                $taskEvidence.securityLogons += [pscustomobject][ordered]@{
                    id = 4624
                    targetUserSid = $targetSid
                    securityLogonType = $securityLogonType
                    logonId = $securityLogonId
                }
            }
        }
        catch {
            $taskEvidence.securityQueryStatus = 'unavailable'
            if (-not $taskEvidence.reason) { $taskEvidence.reason = 'security-log-unreadable' }
        }
    }
    else {
        $taskEvidence.securityQueryStatus = 'unavailable'
        if (-not $taskEvidence.reason) { $taskEvidence.reason = 'event-log-cmdlet-unavailable' }
    }

    return [pscustomobject]$taskEvidence
}

function Get-OpenPathTestAppLockerPolicyDecision {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$StudentSid
    )

    $decision = [ordered]@{
        status = 'unknown'
        decision = 'unknown'
        path = $ExecutablePath
        userSid = $StudentSid
        reason = $null
    }
    if (-not (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name Test-AppLockerPolicy -ErrorAction SilentlyContinue)) {
        $decision.reason = 'policy-command-unavailable'
        return [pscustomobject]$decision
    }
    try {
        $effectivePolicy = Get-AppLockerPolicy -Effective -ErrorAction Stop
        if (-not $effectivePolicy) { throw 'effective-policy-unavailable' }
        $decisions = @($effectivePolicy | Test-AppLockerPolicy -Path @($ExecutablePath) -User $StudentSid -ErrorAction Stop)
        $expectedPath = [System.IO.Path]::GetFullPath($ExecutablePath)
        $matchingDecision = $decisions | Where-Object {
            try { [string]::Equals([System.IO.Path]::GetFullPath([string]$_.FilePath), $expectedPath, [System.StringComparison]::OrdinalIgnoreCase) } catch { $false }
        } | Select-Object -First 1
        if (-not $matchingDecision) { throw 'policy-decision-unavailable' }
        $decision.status = 'observed'
        $decision.decision = if ($matchingDecision.PolicyDecision) { [string]$matchingDecision.PolicyDecision } else { 'unknown' }
    }
    catch {
        $decision.reason = 'policy-evaluation-unavailable'
    }
    return [pscustomobject]$decision
}

function Get-OpenPathAppLockerEventData {
    param([Parameter(Mandatory = $true)][object]$Event)

    $observed = [ordered]@{
        source = 'record-properties'
        path = $null
        package = $null
        ruleId = $null
        ruleName = $null
        userSid = $null
        processId = $null
        targetLogonId = $null
        messageFallback = $null
    }
    $xmlFields = Get-OpenPathEventXmlFields -Event $Event
    if ($xmlFields.available) {
        $observed.source = 'event-xml'
        $fields = $xmlFields.fields
        if ($fields.Contains('fullfilepath') -and -not [string]::IsNullOrWhiteSpace([string]$fields.fullfilepath)) {
            $observed.path = [string]$fields.fullfilepath
        }
        elseif ($fields.Contains('filepath')) {
            $observed.path = [string]$fields.filepath
        }
        elseif ($fields.Contains('path')) {
            $observed.path = [string]$fields.path
        }
        foreach ($fieldName in @('packagefullname', 'packagename', 'package')) {
            if ($fields.Contains($fieldName) -and -not [string]::IsNullOrWhiteSpace([string]$fields[$fieldName])) {
                $observed.package = [string]$fields[$fieldName]
                break
            }
        }
        if ($fields.Contains('ruleid')) { $observed.ruleId = [string]$fields.ruleid }
        if ($fields.Contains('rulename')) { $observed.ruleName = [string]$fields.rulename }
        foreach ($fieldName in @('targetuser', 'usersid', 'user_sid')) {
            if ($fields.Contains($fieldName) -and -not [string]::IsNullOrWhiteSpace([string]$fields[$fieldName])) {
                $observed.userSid = [string]$fields[$fieldName]
                break
            }
        }
        $processIdText = $null
        foreach ($fieldName in @('targetprocessid', 'processid', 'pid')) {
            if ($fields.Contains($fieldName) -and -not [string]::IsNullOrWhiteSpace([string]$fields[$fieldName])) {
                $processIdText = [string]$fields[$fieldName]
                break
            }
        }
        if ($processIdText) {
            $parsedProcessId = 0L
            if ([long]::TryParse($processIdText, [ref]$parsedProcessId) -and $parsedProcessId -gt 0) {
                $observed.processId = [int]$parsedProcessId
            }
        }
        if ($fields.Contains('targetlogonid')) {
            $observed.targetLogonId = [string]$fields.targetlogonid
        }
        elseif ($fields.Contains('logonid')) {
            $observed.targetLogonId = [string]$fields.logonid
        }
    }
    else {
        foreach ($propertyName in @('ExecutablePath', 'FilePath', 'Path')) {
            if ($Event.PSObject.Properties[$propertyName] -and $Event.$propertyName) {
                $observed.path = [string]$Event.$propertyName
                break
            }
        }
        foreach ($propertyName in @('PackageName', 'Package', 'PackageFullName')) {
            if ($Event.PSObject.Properties[$propertyName] -and $Event.$propertyName) {
                $observed.package = [string]$Event.$propertyName
                break
            }
        }
        foreach ($propertyName in @('RuleId', 'RuleID')) {
            if ($Event.PSObject.Properties[$propertyName] -and $Event.$propertyName) {
                $observed.ruleId = [string]$Event.$propertyName
                break
            }
        }
        if ($Event.PSObject.Properties['RuleName'] -and $Event.RuleName) { $observed.ruleName = [string]$Event.RuleName }
        if ($Event.PSObject.Properties['UserSid'] -and $Event.UserSid) { $observed.userSid = [string]$Event.UserSid }
        elseif ($Event.UserId -and $Event.UserId.Value) { $observed.userSid = [string]$Event.UserId.Value }
        foreach ($propertyName in @('TargetLogonId', 'LogonId')) {
            if ($Event.PSObject.Properties[$propertyName] -and $Event.$propertyName) {
                $observed.targetLogonId = [string]$Event.$propertyName
                break
            }
        }
        foreach ($propertyName in @('ProcessId', 'ProcessID', 'Pid', 'PID')) {
            if ($Event.PSObject.Properties[$propertyName]) {
                $parsedProcessId = 0L
                if ([long]::TryParse([string]$Event.$propertyName, [ref]$parsedProcessId) -and $parsedProcessId -gt 0) {
                    $observed.processId = [int]$parsedProcessId
                    break
                }
            }
        }
        # Get-WinEvent records always expose ToXml on Windows. Keep a bounded
        # message fallback for the lightweight test doubles used off-host; no
        # production correlation path relies on localized message text.
        $observed.messageFallback = [string]$Event.Message
    }
    return [pscustomobject]$observed
}

function Get-OpenPathEventProcessId {
    param([Parameter(Mandatory = $true)][object]$Event)
    return (Get-OpenPathAppLockerEventData -Event $Event).processId
}

function Get-OpenPathSafeAppLockerEvent {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][string]$BinaryLeaf,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory = $true)][string]$StudentSid
    )

    $observed = Get-OpenPathAppLockerEventData -Event $Event
    $eventTime = $null
    if ($Event.PSObject.Properties['TimeCreated'] -and $Event.TimeCreated) {
        try { $eventTime = ([datetime]$Event.TimeCreated).ToUniversalTime().ToString('o') } catch {}
    }
    return [pscustomobject][ordered]@{
        id = [int]$Event.Id
        logName = $LogName
        timeCreatedUtc = $eventTime
        observedPath = [string]$observed.path
        observedPackage = [string]$observed.package
        observedRuleId = [string]$observed.ruleId
        observedRuleName = [string]$observed.ruleName
        observedUserSid = [string]$observed.userSid
        observedProcessId = $observed.processId
        observedTargetLogonId = [string]$observed.targetLogonId
        pidStatus = if ($null -eq $observed.processId) { 'unavailable' } else { 'observed' }
        observationSource = [string]$observed.source
        expected = [pscustomobject][ordered]@{
            name = $BinaryLeaf
            executablePath = $ExpectedExecutablePath
            userSid = $StudentSid
        }
    }
}

function Get-OpenPathCorrelatedAppLockerEvent {
    param(
        [Parameter(Mandatory = $true)][object[]]$Events,
        [Parameter(Mandatory = $true)][int[]]$AllowedEventIds,
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][string]$BinaryLeaf,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory = $true)][string]$StudentSid,
        [int[]]$ProcessIds = @(),
        [string]$PackagedAppPattern = ''
    )

    $candidates = @()
    foreach ($event in @($Events)) {
        $eventId = 0
        if (-not [int]::TryParse([string]$event.Id, [ref]$eventId) -or $eventId -notin $AllowedEventIds) { continue }
        $observed = Get-OpenPathAppLockerEventData -Event $event
        $messageFallback = [string]$observed.messageFallback
        $matchesName = if ($observed.path) {
            $observedLeaf = ([string]$observed.path -split '[\\/]')[-1]
            [string]::Equals($observedLeaf, $BinaryLeaf, [System.StringComparison]::OrdinalIgnoreCase)
        }
        elseif ($PackagedAppPattern -and $observed.package) {
            $observed.package -match $PackagedAppPattern
        }
        elseif ($observed.source -eq 'record-properties') {
            ($messageFallback -match [regex]::Escape($BinaryLeaf)) -or
                ($PackagedAppPattern -and $messageFallback -match $PackagedAppPattern)
        }
        else { $false }
        $matchesPath = if ($observed.path) {
            try { [string]::Equals([System.IO.Path]::GetFullPath([string]$observed.path), [System.IO.Path]::GetFullPath($ExpectedExecutablePath), [System.StringComparison]::OrdinalIgnoreCase) } catch { $false }
        }
        elseif ($PackagedAppPattern -and $observed.package) { $true }
        elseif ($observed.source -eq 'record-properties') { $true }
        else { $false }
        $matchesPackage = [string]::IsNullOrWhiteSpace($PackagedAppPattern) -or
            ($observed.package -and $observed.package -match $PackagedAppPattern) -or
            ($observed.source -eq 'record-properties' -and $messageFallback -match $PackagedAppPattern)
        $matchesSid = if ($StudentSid) {
            $observed.userSid -and [string]::Equals([string]$observed.userSid, $StudentSid, [System.StringComparison]::OrdinalIgnoreCase)
        }
        else { $true }
        $eventPid = $observed.processId
        $matchesPid = -not $eventPid -or @($ProcessIds).Count -eq 0 -or ([int]$eventPid -in @($ProcessIds))
        $safeEvent = Get-OpenPathSafeAppLockerEvent -Event $event -LogName $LogName -BinaryLeaf $BinaryLeaf -ExpectedExecutablePath $ExpectedExecutablePath -StudentSid $StudentSid
        $safeEvent | Add-Member -NotePropertyName pidMatched -NotePropertyValue ([bool]$matchesPid)
        $safeEvent | Add-Member -NotePropertyName nameMatched -NotePropertyValue ([bool]$matchesName)
        $safeEvent | Add-Member -NotePropertyName pathMatched -NotePropertyValue ([bool]$matchesPath)
        $safeEvent | Add-Member -NotePropertyName sidMatched -NotePropertyValue ([bool]$matchesSid)
        $safeEvent | Add-Member -NotePropertyName packageMatched -NotePropertyValue ([bool]$matchesPackage)
        $candidates += $safeEvent
        if ($matchesName -and $matchesPath -and $matchesPackage -and $matchesSid -and $matchesPid) {
            return [pscustomobject][ordered]@{
                matched = $true
                event = $safeEvent
                candidates = @($candidates)
            }
        }
    }
    return [pscustomobject][ordered]@{
        matched = $false
        event = $null
        candidates = @($candidates)
    }
}

function Get-OpenPathAppLockerEventQuery {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][int]$EventId,
        [Parameter(Mandatory = $true)][datetime]$StartTime
    )

    $result = [ordered]@{ status = 'unknown'; events = @(); reason = $null }
    if (-not (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue)) {
        $result.status = 'unavailable'
        $result.reason = 'event-log-cmdlet-unavailable'
        return [pscustomobject]$result
    }
    try {
        $result.events = @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; Id = $EventId; StartTime = $StartTime } -ErrorAction Stop)
        $result.status = 'observed'
    }
    catch {
        $result.status = 'unavailable'
        $result.reason = 'event-log-unreadable'
    }
    return [pscustomobject]$result
}

function Merge-OpenPathBoundedEvidence {
    param(
        [object[]]$Existing = @(),
        [object[]]$Incoming = @(),
        [ValidateSet('process', 'event')][string]$Kind = 'event'
    )

    $merged = @()
    $seen = @{}
    foreach ($item in @($Existing) + @($Incoming)) {
        if ($merged.Count -ge 32) { break }
        $key = if ($Kind -eq 'process') {
            "$($item.processId)|$($item.executablePath)"
        }
        else {
            "$($item.id)|$($item.timeCreatedUtc)|$($item.observedProcessId)|$($item.observedPath)|$($item.observedPackage)|$($item.observedRuleId)|$($item.observedUserSid)|$($item.observedTargetLogonId)"
        }
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $merged += $item
        }
    }
    return @($merged)
}

function Set-OpenPathBoundaryProbeFailureEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ProbeName,
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$FailureCode,
        [string]$StudentSid = '',
        [object[]]$Processes = @(),
        [object[]]$Events = @(),
        [int[]]$ExpectedEventIds = @(),
        [object]$SamEvidence = $null,
        [string]$TaskRegisteredAtUtc = '',
        [object]$MatchedEvent = $null,
        [object]$TaskIdentity = $null,
        [object]$TestAppLockerPolicyDecision = $null,
        [hashtable]$AppLockerQueryStatuses = @{}
    )

    $safeProcesses = @($Processes | ForEach-Object {
            [pscustomobject][ordered]@{
                processId = [int]$_.processId
                name = [string]$_.name
                executablePath = [string]$_.executablePath
                studentSid = [string]$_.studentSid
                samSid = [string]$_.samSid
                tokenUserSid = [string]$_.tokenUserSid
                samTokenSidMatch = $_.samTokenSidMatch
                tokenQueryStatus = [string]$_.tokenQueryStatus
                tokenIdentityVerified = $_.tokenIdentityVerified
                matchesStudentSid = $_.matchesStudentSid
                restrictedGroupSid = [string]$_.restrictedGroupSid
                restrictedGroupPresent = $_.restrictedGroupPresent
                restrictedGroupAttributes = $_.restrictedGroupAttributes
                restrictedGroupEnabled = $_.restrictedGroupEnabled
                restrictedGroupDenyOnly = $_.restrictedGroupDenyOnly
                restrictedGroupDisabled = $_.restrictedGroupDisabled
                restrictedGroupQueryStatus = [string]$_.restrictedGroupQueryStatus
            }
        })
    $appLockerFlags = [ordered]@{}
    foreach ($eventId in @(8002, 8004, 8020, 8022)) {
        $eventObserved = @($Events | Where-Object { [int]$_.id -eq $eventId }).Count -gt 0
        $queryStatus = if ($AppLockerQueryStatuses.ContainsKey([string]$eventId)) { [string]$AppLockerQueryStatuses[[string]$eventId] } else { 'unknown' }
        $appLockerFlags["appLocker$eventId"] = if ($eventObserved) { $true } elseif ($queryStatus -eq 'observed') { $false } else { $null }
    }
    $policyDecision = if ($TestAppLockerPolicyDecision) { $TestAppLockerPolicyDecision } else {
        [pscustomobject][ordered]@{ status = 'unknown'; decision = 'unknown'; path = $ExecutablePath; userSid = $StudentSid; reason = 'not-observed' }
    }
    $script:OpenPathLastBoundaryProbeFailureEvidence = [pscustomobject][ordered]@{
        schemaVersion = 1
        probeName = $ProbeName
        executableName = [System.IO.Path]::GetFileName($ExecutablePath)
        executablePath = $ExecutablePath
        studentSid = $StudentSid
        failureCode = $FailureCode
        expectedEventIds = @($ExpectedEventIds)
        samGroupName = if ($SamEvidence) { [string]$SamEvidence.groupName } else { 'OpenPath-Restricted' }
        samGroupSid = if ($SamEvidence) { [string]$SamEvidence.groupSid } else { $null }
        samGroupMemberPresent = if ($SamEvidence -and $null -ne $SamEvidence.targetMemberPresent) { [bool]$SamEvidence.targetMemberPresent } else { $null }
        samGroupMemberCount = if ($SamEvidence -and $null -ne $SamEvidence.memberCount) { [int]$SamEvidence.memberCount } else { $null }
        samGroupQueryStatus = if ($SamEvidence) { [string]$SamEvidence.status } else { 'unavailable' }
        taskRegisteredAtUtc = if ($TaskRegisteredAtUtc) { $TaskRegisteredAtUtc } else { $null }
        processes = @($safeProcesses | Select-Object -First 32)
        events = @($Events | Select-Object -First 32)
        matchedEvent = $MatchedEvent
        taskIdentity = $TaskIdentity
        testAppLockerPolicyDecision = $policyDecision
        appLockerQueryStatuses = $AppLockerQueryStatuses
    }
    $script:OpenPathLastBoundaryProbeFailureEvidence | Add-Member -NotePropertyName appLocker8002 -NotePropertyValue $appLockerFlags.appLocker8002
    $script:OpenPathLastBoundaryProbeFailureEvidence | Add-Member -NotePropertyName appLocker8004 -NotePropertyValue $appLockerFlags.appLocker8004
    $script:OpenPathLastBoundaryProbeFailureEvidence | Add-Member -NotePropertyName appLocker8020 -NotePropertyValue $appLockerFlags.appLocker8020
    $script:OpenPathLastBoundaryProbeFailureEvidence | Add-Member -NotePropertyName appLocker8022 -NotePropertyValue $appLockerFlags.appLocker8022
    $script:OpenPathLastBoundaryProbeFailureEvidence | Add-Member -NotePropertyName edge -NotePropertyValue (Get-OpenPathEdgeBoundaryContract -Evidence $script:OpenPathLastBoundaryProbeFailureEvidence)
    return $script:OpenPathLastBoundaryProbeFailureEvidence
}

function Get-OpenPathLastBoundaryProbeFailureEvidence {
    return $script:OpenPathLastBoundaryProbeFailureEvidence
}

function Get-OpenPathEdgeBoundaryContract {
    param([Parameter(Mandatory = $true)][object]$Evidence)

    $processes = @($Evidence.processes | Select-Object -First 32)
    $firstProcess = if ($processes.Count -gt 0) { $processes[0] } else { $null }
    $policy = if ($Evidence.testAppLockerPolicyDecision) { [string]$Evidence.testAppLockerPolicyDecision.decision } else { 'unknown' }
    return [pscustomobject][ordered]@{
        expectedPath = [string]$Evidence.executablePath
        observedExactProcess = @($processes)
        observedPid = if ($firstProcess) { $firstProcess.processId } else { $null }
        studentSid = [string]$Evidence.studentSid
        restrictedGroupSid = if ($firstProcess -and $firstProcess.restrictedGroupSid) { [string]$firstProcess.restrictedGroupSid } else { [string]$Evidence.samGroupSid }
        restrictedGroupSamMember = $Evidence.samGroupMemberPresent
        restrictedGroupTokenMember = if ($firstProcess) { $firstProcess.restrictedGroupPresent } else { $null }
        testAppLockerPolicyDecision = $policy
        appLocker8002 = $Evidence.appLocker8002
        appLocker8004 = $Evidence.appLocker8004
        appLocker8020 = $Evidence.appLocker8020
        appLocker8022 = $Evidence.appLocker8022
    }
}

function Get-OpenPathFlatEdgeBoundaryFailureContract {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [object]$Diagnostic = $null
    )

    $process = @($Evidence.processes | Select-Object -First 1)
    $process = if ($process.Count -gt 0) { $process[0] } else { $null }
    $event = if ($Evidence.matchedEvent) { $Evidence.matchedEvent } else { @($Evidence.events | Select-Object -First 1)[0] }
    return [pscustomobject][ordered]@{
        edge = Get-OpenPathEdgeBoundaryContract -Evidence $Evidence
        edgeName = [string]$Evidence.executableName
        edgeStudentSid = [string]$Evidence.studentSid
        edgeExecutablePath = [string]$Evidence.executablePath
        edgeFailureCode = [string]$Evidence.failureCode
        edgeExpectedEventIds = @($Evidence.expectedEventIds)
        edgeSamSid = if ($process) { [string]$process.samSid } else { $null }
        edgeTokenUserSid = if ($process) { [string]$process.tokenUserSid } else { $null }
        edgeSamGroupName = [string]$Evidence.samGroupName
        edgeSamGroupSid = [string]$Evidence.samGroupSid
        edgeSamGroupMemberPresent = $Evidence.samGroupMemberPresent
        edgeSamGroupMemberCount = $Evidence.samGroupMemberCount
        edgeRestrictedGroupSid = if ($process) { [string]$process.restrictedGroupSid } else { [string]$Evidence.samGroupSid }
        edgeRestrictedGroupPresent = if ($process) { $process.restrictedGroupPresent } else { $null }
        edgeRestrictedGroupAttributes = if ($process) { $process.restrictedGroupAttributes } else { $null }
        edgeRestrictedGroupEnabled = if ($process) { $process.restrictedGroupEnabled } else { $null }
        edgeRestrictedGroupDenyOnly = if ($process) { $process.restrictedGroupDenyOnly } else { $null }
        edgeRestrictedGroupDisabled = if ($process) { $process.restrictedGroupDisabled } else { $null }
        edgeTaskRegisteredAtUtc = $Evidence.taskRegisteredAtUtc
        edgeEventId = if ($event) { $event.id } else { $null }
        edgeEventProcessId = if ($event) { $event.observedProcessId } else { $null }
        edgeEventPidStatus = if ($event) { [string]$event.pidStatus } else { 'unavailable' }
        edgeObservedPath = if ($event) { [string]$event.observedPath } else { $null }
        edgeObservedPackage = if ($event) { [string]$event.observedPackage } else { $null }
        edgeObservedRuleId = if ($event) { [string]$event.observedRuleId } else { $null }
        edgeObservedRuleName = if ($event) { [string]$event.observedRuleName } else { $null }
        edgeObservedUserSid = if ($event) { [string]$event.observedUserSid } else { $null }
        edgeAttempts = if ($Diagnostic) { @($Diagnostic.attempts) } else { @() }
    }
}

function Invoke-StudentExecutableTaskProbe {
    param(
        [Parameter(Mandatory = $true)][string]$ProbeName,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [string]$Arguments = '',
        [ValidateSet('ExpectDenied', 'ExpectAllowed')][string]$Expectation = 'ExpectDenied',
        [string]$ProcessName = '',
        [string]$StudentSid = $null,
        [string]$MarkerPath = '',
        [string]$PackagedAppPattern = '',
        [int]$TimeoutSeconds = 20,
        [switch]$SuppressFailureDiagnostics
    )

    $script:OpenPathLastBoundaryProbeFailureEvidence = $null

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        throw "$ProbeName FAILED: Executable $ExecutablePath does not exist on host."
    }

    $samBoundaryEvidence = if ($StudentSid) { Get-OpenPathSamBoundaryEvidence -StudentSid $StudentSid } else { $null }
    $restrictedGroupSid = if ($samBoundaryEvidence) { [string]$samBoundaryEvidence.groupSid } else { '' }
    $taskRegisteredAtUtc = $null
    $taskIdentityEvidence = $null
    $testAppLockerPolicyDecision = if ($StudentSid) {
        Get-OpenPathTestAppLockerPolicyDecision -ExecutablePath $ExecutablePath -StudentSid $StudentSid
    }
    else {
        [pscustomobject][ordered]@{ status = 'unknown'; decision = 'unknown'; path = $ExecutablePath; userSid = $StudentSid; reason = 'student-sid-missing' }
    }
    $appLockerQueryStatuses = @{
        '8002' = 'unknown'
        '8004' = 'unknown'
        '8020' = 'unknown'
        '8022' = 'unknown'
    }
    $deniedEventIds = if ($PackagedAppPattern) { @(8004, 8022) } else { @(8004) }
    $allowedEventIds = if ($PackagedAppPattern) { @(8002, 8020) } else { @(8002) }
    $probeTask = "OpenPathProbe-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $taskPrincipal = if ($env:COMPUTERNAME) { "$env:COMPUTERNAME\$UserName" } else { $UserName }
    $useScheduledTaskCmdlets = ($env:OPENPATH_TEST_FORCE_SCHEDULED_TASK_CMDLETS -eq '1') -or
        ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $env:OPENPATH_TEST_FORCE_SCHTASKS -ne '1')
    $quotedExecutablePath = '\"' + $ExecutablePath + '\"'
    $taskCommand = if ($Arguments) { "$quotedExecutablePath $Arguments" } else { $quotedExecutablePath }
    $taskTime = (Get-Date).AddMinutes(1).ToString('HH:mm')

    if ($useScheduledTaskCmdlets) {
        $taskAction = if ($Arguments) {
            New-ScheduledTaskAction -Execute $ExecutablePath -Argument $Arguments
        }
        else {
            New-ScheduledTaskAction -Execute $ExecutablePath
        }
        $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
        Register-ScheduledTask -TaskName $probeTask -Action $taskAction -Trigger $taskTrigger -User "$env:COMPUTERNAME\$UserName" -Password $Password -RunLevel Limited -Force | Out-Null
        $createExitCode = 0
    }
    else {
        $createExitCode = Invoke-OpenPathSchtasksCommand -Command {
            & schtasks.exe /Create /TN $probeTask /SC ONCE /ST $taskTime /TR $taskCommand /RU "$env:COMPUTERNAME\$UserName" /RP $Password /RL LIMITED /F
        }
    }
    if ($createExitCode -ne 0) {
        throw "$ProbeName FAILED: Task creation for $ExecutablePath failed under student credentials ($createExitCode); cannot verify AppLocker boundary."
    }
    $taskRegisteredAt = Get-Date
    $taskRegisteredAtUtc = $taskRegisteredAt.ToUniversalTime().ToString('o')
    $since = $taskRegisteredAt
    $taskIdentityEvidence = Get-OpenPathTaskIdentityEvidence -TaskName $probeTask -Principal $StudentSid -RunLevel 'Limited' -StudentSid $StudentSid -UserName $UserName -StartTime $since -RegisteredAtUtc $taskRegisteredAtUtc -LogonType '4' -SkipTaskDefinition
    try {
        if ($useScheduledTaskCmdlets) {
            Start-ScheduledTask -TaskName $probeTask
            $runExitCode = 0
        }
        else {
            $runExitCode = Invoke-OpenPathSchtasksCommand -Command { & schtasks.exe /Run /TN $probeTask }
        }
        if ($runExitCode -ne 0) {
            throw "$ProbeName FAILED: Task execution for $ExecutablePath failed ($runExitCode)."
        }

        $taskIdentityEvidence = Get-OpenPathTaskIdentityEvidence -TaskName $probeTask -Principal $StudentSid -RunLevel 'Limited' -StudentSid $StudentSid -UserName $UserName -StartTime $since -RegisteredAtUtc $taskRegisteredAtUtc -LogonType '4' -SkipTaskDefinition

        $pollDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $binaryLeaf = [System.IO.Path]::GetFileName($ExecutablePath)

        if ($Expectation -eq 'ExpectDenied') {
            $eventFound = $false
            $blockEventId = 0
            $observedExactProcesses = @()
            $observedExactProcessEvidence = @()
            $observedEventEvidence = @()
            $matchedEventEvidence = $null
            while ((Get-Date) -lt $pollDeadline) {
                if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                    Set-OpenPathBoundaryProbeFailureEvidence -ProbeName $ProbeName -ExecutablePath $ExecutablePath -StudentSid $StudentSid -FailureCode 'marker-created' -Processes $observedExactProcessEvidence -Events $observedEventEvidence -ExpectedEventIds @(8004, 8022) -SamEvidence $samBoundaryEvidence -TaskRegisteredAtUtc $taskRegisteredAtUtc -TaskIdentity $taskIdentityEvidence -TestAppLockerPolicyDecision $testAppLockerPolicyDecision -AppLockerQueryStatuses $appLockerQueryStatuses | Out-Null
                    throw "$ProbeName FAILED: executable ran and created marker file $MarkerPath under student account!"
                }

                $exactProcesses = if ($ProcessName -and $StudentSid) {
                    @(Get-OpenPathExactProcessBoundaryEvidence -ProcessName $ProcessName -StudentSid $StudentSid -ExpectedExecutablePath $ExecutablePath -RestrictedGroupSid $restrictedGroupSid)
                }
                else { @() }
                if ($exactProcesses.Count -gt 0) {
                    $observedExactProcessEvidence = Merge-OpenPathBoundedEvidence -Existing $observedExactProcessEvidence -Incoming $exactProcesses -Kind process
                }
                $studentProcesses = @($exactProcesses | Where-Object { $_.matchesStudentSid })
                if ($studentProcesses.Count -gt 0) {
                    $observedExactProcesses += @($studentProcesses)
                }

                try {
                    $blockQuery = Get-OpenPathAppLockerEventQuery -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -EventId 8004 -StartTime $since
                    $appLockerQueryStatuses['8004'] = $blockQuery.status
                    $blockEvents = @($blockQuery.events)
                    $blockEvidence = Get-OpenPathCorrelatedAppLockerEvent -Events $blockEvents -AllowedEventIds @(8004) -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -BinaryLeaf $binaryLeaf -ExpectedExecutablePath $ExecutablePath -StudentSid $StudentSid -ProcessIds @($observedExactProcesses | ForEach-Object { [int]$_.processId })
                    $observedEventEvidence = Merge-OpenPathBoundedEvidence -Existing $observedEventEvidence -Incoming @($blockEvidence.candidates) -Kind event
                    if ($blockEvidence.matched) {
                        $eventFound = $true
                        $blockEventId = 8004
                        $matchedEventEvidence = $blockEvidence.event
                        break
                    }
                }
                catch {}

                if (-not $eventFound -and -not [string]::IsNullOrWhiteSpace($PackagedAppPattern)) {
                    try {
                        $packagedBlockQuery = Get-OpenPathAppLockerEventQuery -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' -EventId 8022 -StartTime $since
                        $appLockerQueryStatuses['8022'] = $packagedBlockQuery.status
                        $packagedBlockEvents = @($packagedBlockQuery.events)
                        $packagedBlockEvidence = Get-OpenPathCorrelatedAppLockerEvent -Events $packagedBlockEvents -AllowedEventIds @(8022) -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' -BinaryLeaf $binaryLeaf -ExpectedExecutablePath $ExecutablePath -StudentSid $StudentSid -ProcessIds @($observedExactProcesses | ForEach-Object { [int]$_.processId }) -PackagedAppPattern $PackagedAppPattern
                        $observedEventEvidence = Merge-OpenPathBoundedEvidence -Existing $observedEventEvidence -Incoming @($packagedBlockEvidence.candidates) -Kind event
                        if ($packagedBlockEvidence.matched) {
                            $eventFound = $true
                            $blockEventId = 8022
                            $matchedEventEvidence = $packagedBlockEvidence.event
                            break
                        }
                    }
                    catch {}
                }

                Start-Sleep -Seconds 1
            }

            if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                Set-OpenPathBoundaryProbeFailureEvidence -ProbeName $ProbeName -ExecutablePath $ExecutablePath -StudentSid $StudentSid -FailureCode 'marker-created' -Processes $observedExactProcessEvidence -Events $observedEventEvidence -ExpectedEventIds @(8004, 8022) -SamEvidence $samBoundaryEvidence -TaskRegisteredAtUtc $taskRegisteredAtUtc -TaskIdentity $taskIdentityEvidence -TestAppLockerPolicyDecision $testAppLockerPolicyDecision -AppLockerQueryStatuses $appLockerQueryStatuses | Out-Null
                throw "$ProbeName FAILED: executable ran and created marker file $MarkerPath under student account!"
            }

            $exactProcesses = if ($ProcessName -and $StudentSid) {
                @(Get-OpenPathExactProcessBoundaryEvidence -ProcessName $ProcessName -StudentSid $StudentSid -ExpectedExecutablePath $ExecutablePath -RestrictedGroupSid $restrictedGroupSid)
            }
            else { @() }
            if ($exactProcesses.Count -gt 0) {
                $observedExactProcessEvidence = Merge-OpenPathBoundedEvidence -Existing $observedExactProcessEvidence -Incoming $exactProcesses -Kind process
            }
            $studentProcesses = @($exactProcesses | Where-Object { $_.matchesStudentSid })
            if ($studentProcesses.Count -gt 0) {
                $observedExactProcesses += @($studentProcesses)
            }
            if ($observedExactProcesses.Count -gt 0) {
                foreach ($studentProcess in @($observedExactProcesses | Sort-Object processId -Unique)) { Stop-Process -Id $studentProcess.processId -Force -ErrorAction SilentlyContinue }
                if (-not $eventFound) {
                    Write-Host 'OPENPATH_BOUNDARY_PROBE_FAILURE reason=exact-student-process-observed-without-block-event'
                    Set-OpenPathBoundaryProbeFailureEvidence -ProbeName $ProbeName -ExecutablePath $ExecutablePath -StudentSid $StudentSid -FailureCode 'exact-student-process-observed-without-block-event' -Processes $observedExactProcessEvidence -Events $observedEventEvidence -ExpectedEventIds @(8004, 8022) -SamEvidence $samBoundaryEvidence -TaskRegisteredAtUtc $taskRegisteredAtUtc -TaskIdentity $taskIdentityEvidence -TestAppLockerPolicyDecision $testAppLockerPolicyDecision -AppLockerQueryStatuses $appLockerQueryStatuses | Out-Null
                    throw "$ProbeName FAILED: exact executable $binaryLeaf ran under the student SID and no correlated AppLocker block event was observed."
                }
            }

            if (-not $eventFound) {
                if ($useScheduledTaskCmdlets) {
                    $taskState = 'unknown'
                    $lastTaskResult = 'unknown'
                    $lastRunObserved = 'unknown'
                    try {
                        $registeredTask = Get-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
                        if ($registeredTask) { $taskState = [string]$registeredTask.State }
                        $taskInfo = Get-ScheduledTaskInfo -TaskName $probeTask -ErrorAction SilentlyContinue
                        if ($taskInfo) {
                            $lastTaskResult = '0x{0:X8}' -f [uint32]$taskInfo.LastTaskResult
                            $lastRunObserved = ([datetime]$taskInfo.LastRunTime -gt [datetime]::MinValue).ToString().ToLowerInvariant()
                        }
                    }
                    catch {}
                    Write-Host "OPENPATH_BOUNDARY_PROBE_FAILURE state=$taskState lastTaskResult=$lastTaskResult lastRunObserved=$lastRunObserved"
                }
                $expectedEvent = if ($PackagedAppPattern) { '8004/8022 block event' } else { '8004 block event' }
                Set-OpenPathBoundaryProbeFailureEvidence -ProbeName $ProbeName -ExecutablePath $ExecutablePath -StudentSid $StudentSid -FailureCode 'appLocker-block-event-not-observed' -Processes $observedExactProcessEvidence -Events $observedEventEvidence -ExpectedEventIds $deniedEventIds -SamEvidence $samBoundaryEvidence -TaskRegisteredAtUtc $taskRegisteredAtUtc -TaskIdentity $taskIdentityEvidence -TestAppLockerPolicyDecision $testAppLockerPolicyDecision -AppLockerQueryStatuses $appLockerQueryStatuses | Out-Null
                throw "$ProbeName FAILED: AppLocker $expectedEvent was not observed for $binaryLeaf within timeout ($TimeoutSeconds s)."
            }

            return [pscustomobject]@{
                name     = $ProbeName
                section  = 'student'
                status   = 'pass'
                detail   = "Real execution probe: $binaryLeaf denied for student account (AppLocker event $blockEventId confirmed)."
                evidence = [pscustomobject][ordered]@{ appLocker8002Observed = $false; appLocker8004Observed = ($blockEventId -eq 8004); appLocker8020Observed = $false; appLocker8022Observed = ($blockEventId -eq 8022); blockEventId = $blockEventId; correlatedEvent = $matchedEventEvidence; samBoundary = $samBoundaryEvidence; taskRegisteredAtUtc = $taskRegisteredAtUtc }
            }
        }
        else {
            $allowedFound = $false
            $allowEventId = 0
            $allowEventEvidence = $null
            $observedExactProcessEvidence = @()
            $observedEventEvidence = @()
            while ((Get-Date) -lt $pollDeadline) {
                if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
                    $allowedFound = $true
                    break
                }

                $studentProcs = if ($ProcessName -and $StudentSid) {
                    @(Get-OpenPathExactProcessBoundaryEvidence -ProcessName $ProcessName -StudentSid $StudentSid -ExpectedExecutablePath $ExecutablePath -RestrictedGroupSid $restrictedGroupSid |
                            Where-Object { $_.matchesStudentSid })
                }
                elseif ($ProcessName) {
                    @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object {
                            [pscustomobject]@{ processId = $_.Id; name = $_.ProcessName; executablePath = $null }
                        })
                }
                else { @() }
                if ($studentProcs.Count -gt 0) {
                    $observedExactProcessEvidence = Merge-OpenPathBoundedEvidence -Existing $observedExactProcessEvidence -Incoming $studentProcs -Kind process
                    $allowedFound = $true
                    foreach ($sp in $studentProcs) {
                        Stop-Process -Id $sp.processId -Force -ErrorAction SilentlyContinue
                    }
                    break
                }

                try {
                    $allowQuery = Get-OpenPathAppLockerEventQuery -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -EventId 8002 -StartTime $since
                    $appLockerQueryStatuses['8002'] = $allowQuery.status
                    $allowEvents = @($allowQuery.events)
                    $allowEvidence = Get-OpenPathCorrelatedAppLockerEvent -Events $allowEvents -AllowedEventIds @(8002) -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -BinaryLeaf $binaryLeaf -ExpectedExecutablePath $ExecutablePath -StudentSid $StudentSid -ProcessIds @($observedExactProcessEvidence | ForEach-Object { [int]$_.processId })
                    $observedEventEvidence = Merge-OpenPathBoundedEvidence -Existing $observedEventEvidence -Incoming @($allowEvidence.candidates) -Kind event
                    if ($allowEvidence.matched) {
                        $allowedFound = $true
                        $allowEventId = 8002
                        $allowEventEvidence = $allowEvidence.event
                        break
                    }
                }
                catch {}

                if (-not $allowedFound -and -not [string]::IsNullOrWhiteSpace($PackagedAppPattern)) {
                    try {
                        $packagedAllowQuery = Get-OpenPathAppLockerEventQuery -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' -EventId 8020 -StartTime $since
                        $appLockerQueryStatuses['8020'] = $packagedAllowQuery.status
                        $packagedAllowEvents = @($packagedAllowQuery.events)
                        $packagedAllowEvidence = Get-OpenPathCorrelatedAppLockerEvent -Events $packagedAllowEvents -AllowedEventIds @(8020) -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' -BinaryLeaf $binaryLeaf -ExpectedExecutablePath $ExecutablePath -StudentSid $StudentSid -ProcessIds @($observedExactProcessEvidence | ForEach-Object { [int]$_.processId }) -PackagedAppPattern $PackagedAppPattern
                        $observedEventEvidence = Merge-OpenPathBoundedEvidence -Existing $observedEventEvidence -Incoming @($packagedAllowEvidence.candidates) -Kind event
                        if ($packagedAllowEvidence.matched) {
                            $allowedFound = $true
                            $allowEventId = 8020
                            $allowEventEvidence = $packagedAllowEvidence.event
                            break
                        }
                    }
                    catch {}
                }

                Start-Sleep -Seconds 1
            }

            if (-not $allowedFound) {
                Set-OpenPathBoundaryProbeFailureEvidence -ProbeName $ProbeName -ExecutablePath $ExecutablePath -StudentSid $StudentSid -FailureCode 'appLocker-allow-event-not-observed' -Processes $observedExactProcessEvidence -Events $observedEventEvidence -ExpectedEventIds $allowedEventIds -SamEvidence $samBoundaryEvidence -TaskRegisteredAtUtc $taskRegisteredAtUtc -TaskIdentity $taskIdentityEvidence -TestAppLockerPolicyDecision $testAppLockerPolicyDecision -AppLockerQueryStatuses $appLockerQueryStatuses | Out-Null
                throw "$ProbeName FAILED: Allowed execution was not observed for $binaryLeaf attributed to student within timeout ($TimeoutSeconds s)."
            }

            $firstObservedExactProcessEvidence = @($observedExactProcessEvidence | Select-Object -First 1)
            return [pscustomobject]@{
                name     = $ProbeName
                section  = 'student'
                status   = 'pass'
                detail   = "Real execution probe: $binaryLeaf allowed for student account."
                evidence = [pscustomobject][ordered]@{ allowedObserved = $true; allowEventId = $allowEventId; appLocker8002Observed = ($allowEventId -eq 8002); appLocker8020Observed = ($allowEventId -eq 8020); correlatedEvent = $allowEventEvidence; observedExactProcess = $firstObservedExactProcessEvidence; samBoundary = $samBoundaryEvidence; taskIdentity = $taskIdentityEvidence; taskRegisteredAtUtc = $taskRegisteredAtUtc }
            }
        }
    }
    finally {
        if ($useScheduledTaskCmdlets) {
            $registeredProbe = Get-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
            if ($registeredProbe -and [string]$registeredProbe.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
                $stopDeadline = (Get-Date).AddSeconds(10)
                do {
                    Start-Sleep -Milliseconds 100
                    $registeredProbe = Get-ScheduledTask -TaskName $probeTask -ErrorAction SilentlyContinue
                } while ($registeredProbe -and [string]$registeredProbe.State -eq 'Running' -and (Get-Date) -lt $stopDeadline)
            }
            Unregister-ScheduledTask -TaskName $probeTask -Confirm:$false -ErrorAction SilentlyContinue
        }
        else {
            Invoke-OpenPathSchtasksCommand -Command { & schtasks.exe /Delete /TN $probeTask /F } | Out-Null
        }
    }
}

function Invoke-OpenPathEdgeBoundaryDiagnostic {
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

    $requiredOffsets = @(0, 5, 15, 30)
    if ((@($AttemptOffsetsSeconds) -join ',') -ne ($requiredOffsets -join ',')) {
        throw 'edge-boundary-diagnostic-attempt-schedule-invalid'
    }

    $diagnosticStart = Get-Date
    $diagnosticStartedAtUtc = $diagnosticStart.ToUniversalTime().ToString('o')
    $attempts = @()
    for ($index = 0; $index -lt $requiredOffsets.Count; $index++) {
        $offset = [int]$requiredOffsets[$index]
        $targetTime = $diagnosticStart.AddSeconds($offset)
        $delaySeconds = [int][Math]::Ceiling(($targetTime - (Get-Date)).TotalSeconds)
        if ($delaySeconds -gt 0) {
            Start-Sleep -Seconds $delaySeconds
        }

        $attemptLabel = if ($offset -eq 0) { 'T0' } else { "T+$offset" }
        try {
            $probe = Invoke-StudentExecutableTaskProbe `
                -ProbeName "Edge boundary diagnostic $attemptLabel" `
                -UserName $UserName `
                -Password $Password `
                -ExecutablePath $ExecutablePath `
                -Arguments $Arguments `
                -Expectation ExpectDenied `
                -ProcessName 'msedge' `
                -StudentSid $StudentSid `
                -PackagedAppPattern $PackagedAppPattern `
                -TimeoutSeconds $ProbeTimeoutSeconds `
                -SuppressFailureDiagnostics
            $attempts += [pscustomobject][ordered]@{
                label = $attemptLabel
                offsetSeconds = $offset
                status = 'pass'
                observedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                elapsedSeconds = [Math]::Round(((Get-Date) - $diagnosticStart).TotalSeconds, 3)
                evidence = $probe.evidence
            }
        }
        catch {
            $attemptEvidence = Get-OpenPathLastBoundaryProbeFailureEvidence
            $attempts += [pscustomobject][ordered]@{
                label = $attemptLabel
                offsetSeconds = $offset
                status = 'fail'
                observedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                elapsedSeconds = [Math]::Round(((Get-Date) - $diagnosticStart).TotalSeconds, 3)
                failureCode = if ($attemptEvidence) { [string]$attemptEvidence.failureCode } else { 'edge-boundary-diagnostic-attempt-failed' }
                evidence = $attemptEvidence
            }
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        name = 'edge-boundary-diagnostic'
        executableName = [System.IO.Path]::GetFileName($ExecutablePath)
        executablePath = $ExecutablePath
        studentSid = $StudentSid
        diagnosticStartedAtUtc = $diagnosticStartedAtUtc
        attemptOffsetsSeconds = @($requiredOffsets)
        policyReapplied = $false
        attempts = @($attempts)
    }
}

function Assert-InstalledOpenPathBrowserBoundaryAppControl {
    <#
    .SYNOPSIS
        Verifies that OpenPath non-admin AppControl was installed and remains intact.
        This is an assert-only verification: it NEVER attempts to repair or mutates the boundary.
    #>
    param(
        [string]$OpenPathRoot = 'C:\OpenPath'
    )

    $configPath = Join-Path $OpenPathRoot 'data\config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenPath config is missing before browser-boundary probes: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if (-not $config.PSObject.Properties['installState'] -or $config.installState -ne 'complete') {
        throw "OpenPath installState must be 'complete' before browser-boundary probes, observed: '$($config.installState)'"
    }
    if (-not $config.PSObject.Properties['appControlCommitState'] -or $config.appControlCommitState -ne 'committed') {
        throw "OpenPath appControlCommitState must be 'committed' before browser-boundary probes, observed: '$($config.appControlCommitState)'"
    }
    if (-not $config.PSObject.Properties['enableNonAdminAppControl'] -or -not [bool]$config.enableNonAdminAppControl) {
        throw "OpenPath enableNonAdminAppControl must be true before browser-boundary probes."
    }

    if (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $watchdogTask = Get-ScheduledTask -TaskName 'OpenPath-Watchdog' -ErrorAction SilentlyContinue
        if (-not $watchdogTask) {
            throw "OpenPath-Watchdog scheduled task is missing before browser-boundary probes."
        }
    }

    if (Get-Command -Name Get-LocalGroup -ErrorAction SilentlyContinue) {
        $restrictedGroup = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue
        if (-not $restrictedGroup) {
            throw "OpenPath-Restricted local group is missing before browser-boundary probes."
        }
    }

    if (Get-Command -Name Get-Service -ErrorAction SilentlyContinue) {
        $appIdSvc = Get-Service -Name 'AppIDSvc' -ErrorAction SilentlyContinue
        if (-not $appIdSvc -or $appIdSvc.Status -ne 'Running') {
            throw "AppIDSvc service must be Running before browser-boundary probes, observed status: '$($appIdSvc.Status)'"
        }
    }

    $appControlModule = Join-Path $OpenPathRoot 'lib\AppControl.psm1'
    if (-not (Test-Path -LiteralPath $appControlModule)) {
        throw "OpenPath AppControl module is missing: $appControlModule"
    }
    Import-Module $appControlModule -Force -Global -ErrorAction Stop

    $mode = if ($config.PSObject.Properties['nonAdminAppControlMode'] -and $config.nonAdminAppControlMode) { [string]$config.nonAdminAppControlMode } else { 'Enforced' }
    $approvedBrowsers = if ($config.PSObject.Properties['approvedStudentBrowsers'] -and $config.approvedStudentBrowsers) { @($config.approvedStudentBrowsers) } else { @('Firefox') }

    # Pure assert-only: DO NOT CALL Set-OpenPathNonAdminAppControl or repair!
    if (-not (Test-OpenPathNonAdminAppControlActive -Mode $mode -ApprovedBrowsers $approvedBrowsers)) {
        throw "OpenPath AppControl boundary is inactive before browser-boundary probes; installer acceptance failed."
    }

    if (Get-Command -Name Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
        $policyXml = [xml](Get-AppLockerPolicy -Local -Xml -ErrorAction SilentlyContinue)
        if ($policyXml) {
            $adminAllowAllRules = @($policyXml.AppLockerPolicy.RuleCollection.FilePathRule | Where-Object {
                    $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-32-544' -and $_.Conditions.FilePathCondition.Path -eq '*'
                })
            if ($adminAllowAllRules.Count -eq 0) {
                throw 'OpenPath AppControl policy is active but the administrator allow-all rule is missing.'
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-ReportAssertNoFailures',
    'Assert-RequiredStudentProbeStatuses',
    'New-OpenPathProbePayloadBinary',
    'Get-OpenPathProcessTokenBoundaryEvidence',
    'Get-OpenPathSamBoundaryEvidence',
    'Get-OpenPathExactProcessBoundaryEvidence',
    'Get-OpenPathCorrelatedAppLockerEvent',
    'Get-OpenPathTaskIdentityEvidence',
    'Get-OpenPathTestAppLockerPolicyDecision',
    'Get-OpenPathLastBoundaryProbeFailureEvidence',
    'Get-OpenPathFlatEdgeBoundaryFailureContract',
    'Invoke-StudentExecutableTaskProbe',
    'Invoke-OpenPathEdgeBoundaryDiagnostic',
    'Assert-InstalledOpenPathBrowserBoundaryAppControl'
)
