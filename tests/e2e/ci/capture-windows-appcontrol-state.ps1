[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9-]{1,64}$')]
    [string]$Label
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-OpenPathSidString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }
    if ($Value.PSObject.Properties['Value']) {
        return [string]$Value.Value
    }
    return [string]$Value
}

function Get-OpenPathPolicyObservation {
    param([Parameter(Mandatory = $true)][ValidateSet('Local', 'Effective')][string]$Kind)

    try {
        $policyText = if ($Kind -eq 'Local') {
            Get-AppLockerPolicy -Local -Xml -ErrorAction Stop
        }
        else {
            Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop
        }
        if ([string]::IsNullOrWhiteSpace([string]$policyText)) {
            return [pscustomobject][ordered]@{ Status = 'absent'; Sha256 = ''; Collections = @() }
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$policyText)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
        $xml = [xml]$policyText
        $collections = @(
            $xml.AppLockerPolicy.RuleCollection | ForEach-Object {
                [pscustomobject][ordered]@{
                    Type = [string]$_.Type
                    EnforcementMode = [string]$_.EnforcementMode
                    RuleCount = @($_.FilePathRule).Count + @($_.FilePublisherRule).Count + @($_.FileHashRule).Count
                }
            }
        )
        return [pscustomobject][ordered]@{ Status = 'present'; Sha256 = $digest; Collections = $collections }
    }
    catch {
        return [pscustomobject][ordered]@{ Status = 'error'; Sha256 = ''; Collections = @() }
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    throw 'OutputPath must include a parent directory'
}
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$administrators = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
$restrictedGroup = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue
$restrictedMembers = @(
    if ($restrictedGroup) {
        Get-LocalGroupMember -Group $restrictedGroup.Name -ErrorAction Stop
    }
)
$profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)
$appIdentityService = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
$windowsCurrentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

$observation = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Label = $Label
    CapturedAt = (Get-Date).ToUniversalTime().ToString('o')
    Environment = [pscustomobject][ordered]@{
        ComputerName = $env:COMPUTERNAME
        ProductName = [string]$windowsCurrentVersion.ProductName
        DisplayVersion = [string]$windowsCurrentVersion.DisplayVersion
        CurrentBuild = [string]$windowsCurrentVersion.CurrentBuild
        Ubr = [int]$windowsCurrentVersion.UBR
        OsArchitecture = (Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture
        PowerShellProcessArchitecture = "$(8 * [IntPtr]::Size)-bit"
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    }
    Capabilities = [pscustomobject][ordered]@{
        AppLockerCommands = @(
            'Get-AppLockerPolicy', 'Set-AppLockerPolicy', 'Test-AppLockerPolicy' |
                Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue }
        )
        AppIdentityServiceStatus = if ($appIdentityService) { [string]$appIdentityService.Status } else { 'unavailable' }
    }
    Users = [pscustomobject][ordered]@{
        Enabled = @(
            Get-LocalUser -ErrorAction Stop |
                Where-Object Enabled |
                Sort-Object Name |
                ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = [string]$_.Name
                        Sid = ConvertTo-OpenPathSidString $_.SID
                        IsAdministrator = (ConvertTo-OpenPathSidString $_.SID) -in @($administrators | ForEach-Object { ConvertTo-OpenPathSidString $_.SID })
                    }
                }
        )
        Profiles = @(
            $profiles | ForEach-Object {
                [pscustomobject][ordered]@{
                    Sid = [string]$_.SID
                    LocalPath = [string]$_.LocalPath
                    Special = if ($_.PSObject.Properties['Special']) { [bool]$_.Special } else { 'not-observed' }
                    Loaded = if ($_.PSObject.Properties['Loaded']) { [bool]$_.Loaded } else { 'not-observed' }
                    DirectoryExists = if ([string]::IsNullOrWhiteSpace([string]$_.LocalPath)) { $false } else { Test-Path -LiteralPath ([string]$_.LocalPath) -PathType Container }
                }
            }
        )
    }
    RestrictedGroup = [pscustomobject][ordered]@{
        Exists = [bool]$restrictedGroup
        Sid = if ($restrictedGroup) { ConvertTo-OpenPathSidString $restrictedGroup.SID } else { '' }
        MemberCount = $restrictedMembers.Count
        Members = @(
            $restrictedMembers | ForEach-Object {
                [pscustomobject][ordered]@{
                    Name = [string]$_.Name
                    Sid = ConvertTo-OpenPathSidString $_.SID
                    PrincipalSource = [string]$_.PrincipalSource
                }
            }
        )
    }
    Policies = [pscustomobject][ordered]@{
        Local = Get-OpenPathPolicyObservation -Kind Local
        Effective = Get-OpenPathPolicyObservation -Kind Effective
    }
    OpenPathRootExists = Test-Path -LiteralPath 'C:\ProgramData\OpenPath' -PathType Container
    OpenPathTasks = @(Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName)
}

$tempPath = "$OutputPath.tmp-$([guid]::NewGuid().ToString('N'))"
try {
    $observation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force
    & icacls.exe $OutputPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
}
finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}

$observation | ConvertTo-Json -Depth 8 -Compress
