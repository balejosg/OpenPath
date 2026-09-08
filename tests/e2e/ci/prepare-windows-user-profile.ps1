[CmdletBinding()]
param(
    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-OpenPathSidString {
    param(
        [Parameter(Mandatory = $false)][object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value.PSObject.Properties['Value']) {
        return [string]$Value.Value
    }

    return [string]$Value
}

function Get-OpenPathValidProfile {
    param(
        [Parameter(Mandatory = $true)][object[]]$Profiles,
        [Parameter(Mandatory = $true)][string]$Sid
    )

    foreach ($profile in $Profiles) {
        $profileSid = ConvertTo-OpenPathSidString -Value $profile.SID
        $profilePath = [string]$profile.LocalPath
        $hasSpecial = $null -ne $profile.PSObject.Properties['Special']
        $isSpecial = if ($hasSpecial) { [bool]$profile.Special } else { $true }

        if (
            ($profileSid -eq $Sid) -and
            $hasSpecial -and
            (-not $isSpecial) -and
            (-not [string]::IsNullOrWhiteSpace($profilePath)) -and
            [System.IO.Directory]::Exists($profilePath)
        ) {
            return $profile
        }
    }

    return $null
}

function Get-OpenPathProfileDiagnostics {
    param(
        [Parameter(Mandatory = $true)][object[]]$Profiles,
        [Parameter(Mandatory = $true)][string]$Sid
    )

    $diagnostics = @()
    foreach ($profile in $Profiles) {
        if ((ConvertTo-OpenPathSidString -Value $profile.SID) -ne $Sid) {
            continue
        }

        $profilePath = [string]$profile.LocalPath
        $isSpecial = if ($profile.PSObject.Properties['Special']) {
            [bool]$profile.Special
        }
        else {
            $null
        }

        $diagnostics += [string]([pscustomobject]@{
            SID             = $Sid
            LocalPath       = $profilePath
            Special         = $isSpecial
            DirectoryExists = [System.IO.Directory]::Exists($profilePath)
        } | ConvertTo-Json -Compress)
    }

    return $diagnostics
}

function Invoke-OpenPathCreateProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$UserName
    )

    if (-not ('OpenPathUserProfileNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class OpenPathUserProfileNative
{
    [DllImport("userenv.dll", EntryPoint = "CreateProfile", SetLastError = false, ExactSpelling = true)]
    public static extern int CreateProfile(
        [MarshalAs(UnmanagedType.LPWStr)] string userSid,
        [MarshalAs(UnmanagedType.LPWStr)] string userName,
        [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder profilePath,
        uint cchProfilePath);
}
'@
    }

    $profilePathBuffer = New-Object System.Text.StringBuilder 260
    $result = [OpenPathUserProfileNative]::CreateProfile(
        $Sid,
        $UserName,
        $profilePathBuffer,
        [uint32]$profilePathBuffer.Capacity)
    if ($result -ne 0) {
        throw ('CreateProfile failed for {0} (HRESULT 0x{1:X8})' -f $UserName, $result)
    }

    $createdPath = $profilePathBuffer.ToString()
    if ([string]::IsNullOrWhiteSpace($createdPath)) {
        throw "CreateProfile returned an empty path for $UserName ($Sid)"
    }

    return $createdPath
}

function Remove-OpenPathCreatedProfileAfterFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [string]$ExpectedPath
    )

    $profiles = @(
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { (ConvertTo-OpenPathSidString -Value $_.SID) -eq $Sid }
    )
    if ($profiles.Count -eq 0) {
        return 'no-profile-created'
    }
    if ($profiles.Count -ne 1) {
        throw "Refusing compensating cleanup for $Sid because $($profiles.Count) profile records exist"
    }

    $profile = $profiles[0]
    if (
        $null -eq $profile.PSObject.Properties['Special'] -or
        $profile.Special -ne $false -or
        $null -eq $profile.PSObject.Properties['Loaded'] -or
        $profile.Loaded -ne $false -or
        [string]::IsNullOrWhiteSpace([string]$profile.LocalPath) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedPath) -and
            -not [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$profile.LocalPath),
                [System.IO.Path]::GetFullPath($ExpectedPath),
                [System.StringComparison]::OrdinalIgnoreCase))
    ) {
        throw "Refusing compensating cleanup because the created profile for $Sid cannot be verified safely"
    }

    Remove-CimInstance -InputObject $profile -ErrorAction Stop
    return 'removed'
}

function Resolve-OpenPathProfileTarget {
    $adminGroup = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    if ($null -eq $adminGroup) {
        throw 'Unable to resolve the local Administrators group by SID S-1-5-32-544'
    }

    $adminGroupSid = ConvertTo-OpenPathSidString -Value $adminGroup.SID
    if ($adminGroupSid -ne 'S-1-5-32-544') {
        throw "Resolved local group SID did not match Administrators: $adminGroupSid"
    }

    $adminMembers = @(Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop)
    if ($adminMembers.Count -eq 0) {
        throw 'Administrators membership enumeration returned no members; refusing to select a profile'
    }

    $adminMemberSids = @()
    foreach ($member in $adminMembers) {
        $memberSid = ConvertTo-OpenPathSidString -Value $member.SID
        if ([string]::IsNullOrWhiteSpace($memberSid)) {
            throw 'Administrators membership enumeration returned a member without a SID'
        }
        $adminMemberSids += $memberSid
    }

    $enabledUsers = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled })
    if ($enabledUsers.Count -eq 0) {
        throw 'No enabled local users are available for AppControl profile validation'
    }

    $candidateUsers = @()
    foreach ($user in $enabledUsers) {
        $userSid = ConvertTo-OpenPathSidString -Value $user.SID
        if ([string]::IsNullOrWhiteSpace($userSid)) {
            throw "Enabled local user '$($user.Name)' has no resolvable SID"
        }
        if ($userSid -notin $adminMemberSids) {
            $candidateUsers += $user
        }
    }

    if ($candidateUsers.Count -eq 0) {
        throw 'No enabled non-administrator local user is available for AppControl profile validation'
    }

    # Take one complete inventory before selecting a candidate. A candidate with
    # invalid records is never modified; only a SID with no profile record may
    # be passed to the native profile creation API.
    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)
    $invalidProfileDiagnostics = @()

    foreach ($user in @($candidateUsers | Sort-Object -Property Name)) {
        $userSid = ConvertTo-OpenPathSidString -Value $user.SID
        $userProfiles = @($profiles | Where-Object {
                (ConvertTo-OpenPathSidString -Value $_.SID) -eq $userSid
            })
        $validProfile = if ($userProfiles.Count -eq 1) {
            Get-OpenPathValidProfile -Profiles $userProfiles -Sid $userSid
        }
        else {
            $null
        }
        if ($userProfiles.Count -eq 1 -and $null -ne $validProfile) {
            return [pscustomobject]@{
                SID            = $userSid
                UserName       = [string]$user.Name
                LocalPath      = [string]$validProfile.LocalPath
                createdByHarness = $false
            }
        }

        if ($userProfiles.Count -gt 0) {
            $profileDiagnostics = (Get-OpenPathProfileDiagnostics -Profiles $userProfiles -Sid $userSid) -join '; '
            $invalidProfileDiagnostics += "User '$($user.Name)' ($userSid): $profileDiagnostics"
            continue
        }

        $createdPath = $null
        $createSucceeded = $false
        try {
            $createdPath = Invoke-OpenPathCreateProfile -Sid $userSid -UserName ([string]$user.Name)
            $createSucceeded = $true
            $createdProfiles = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$userSid'" -ErrorAction Stop)
            $createdValidProfiles = @($createdProfiles | Where-Object {
                    $candidate = Get-OpenPathValidProfile -Profiles @($_) -Sid $userSid
                    $null -ne $candidate
                })
            if ($createdProfiles.Count -ne 1 -or $createdValidProfiles.Count -ne 1) {
                throw "CreateProfile did not produce exactly one valid profile for '$($user.Name)' ($userSid); records=$($createdProfiles.Count)"
            }

            $createdProfile = $createdValidProfiles[0]
            if (-not [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$createdProfile.LocalPath),
                [System.IO.Path]::GetFullPath($createdPath),
                [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "CreateProfile returned a path that does not match Win32_UserProfile for '$($user.Name)' ($userSid)"
            }
            return [pscustomobject]@{
                SID              = $userSid
                UserName         = [string]$user.Name
                LocalPath        = [string]$createdProfile.LocalPath
                createdByHarness = $true
            }
        }
        catch {
            $primaryError = $_.Exception.Message
            if (-not $createSucceeded) {
                throw
            }
            try {
                $cleanupResult = Remove-OpenPathCreatedProfileAfterFailure -Sid $userSid -ExpectedPath $createdPath
            }
            catch {
                throw "$primaryError Compensating profile cleanup also failed: $($_.Exception.Message)"
            }
            throw "$primaryError Compensating profile cleanup: $cleanupResult."
        }
    }

    $details = if ($invalidProfileDiagnostics.Count -gt 0) {
        $invalidProfileDiagnostics -join ' | '
    }
    else {
        'no valid candidate profile records were found'
    }
    throw "Unable to resolve a valid non-administrator user profile without modifying invalid records: $details"
}

$resolvedEvidencePath = $EvidencePath
if ([string]::IsNullOrWhiteSpace($resolvedEvidencePath)) {
    $resolvedEvidencePath = $env:OPENPATH_WINDOWS_PROFILE_EVIDENCE_PATH
}
if ([string]::IsNullOrWhiteSpace($resolvedEvidencePath)) {
    $resolvedEvidencePath = Join-Path $PSScriptRoot '..\artifacts\windows-student-policy\windows-user-profile-evidence.json'
}

$resolvedEvidencePath = [System.IO.Path]::GetFullPath($resolvedEvidencePath)
$evidenceDirectory = Split-Path -Parent $resolvedEvidencePath
if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory) -and -not [System.IO.Directory]::Exists($evidenceDirectory)) {
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
}

$target = Resolve-OpenPathProfileTarget
try {
    $target | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resolvedEvidencePath -Encoding UTF8 -ErrorAction Stop
}
catch {
    $primaryError = $_.Exception.Message
    if ($target.createdByHarness -eq $true) {
        try {
            $cleanupResult = Remove-OpenPathCreatedProfileAfterFailure -Sid ([string]$target.SID) -ExpectedPath ([string]$target.LocalPath)
        }
        catch {
            throw "$primaryError Compensating profile cleanup also failed: $($_.Exception.Message)"
        }
        throw "$primaryError Compensating profile cleanup: $cleanupResult."
    }
    throw
}
$env:OPENPATH_WINDOWS_PROFILE_EVIDENCE_PATH = $resolvedEvidencePath

Write-Host ("Prepared Windows profile for {0} ({1}) at {2}; createdByHarness={3}" -f $target.UserName, $target.SID, $target.LocalPath, $target.createdByHarness)
