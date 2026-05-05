function Resolve-OpenPathInstallerEnrollmentContext {
    param(
        [string]$ApiBaseUrl = "",
        [string]$Classroom = "",
        [string]$ClassroomId = "",
        [string]$RegistrationToken = "",
        [string]$EnrollmentToken = "",
        [switch]$Unattended
    )

    if ($RegistrationToken -and $EnrollmentToken) {
        Write-InstallerError "ERROR: -RegistrationToken and -EnrollmentToken cannot be used together"
        exit 1
    }

    if ($ClassroomId -and -not $EnrollmentToken) {
        Write-InstallerError "ERROR: -ClassroomId requires -EnrollmentToken"
        exit 1
    }

    if ((($Classroom -or $ClassroomId -or $RegistrationToken -or $EnrollmentToken) -and -not $ApiBaseUrl)) {
        Write-InstallerError "ERROR: -ApiUrl is required for classroom enrollment parameters"
        exit 1
    }

    $classroomModeRequested = [bool]$ApiBaseUrl -and (
        [bool]$Classroom -or
        [bool]$ClassroomId -or
        [bool]$RegistrationToken -or
        [bool]$EnrollmentToken -or
        [bool]$env:OPENPATH_TOKEN -or
        [bool]$env:OPENPATH_ENROLLMENT_TOKEN
    )

    if ($classroomModeRequested) {
        if (-not $EnrollmentToken -and -not $RegistrationToken -and $env:OPENPATH_ENROLLMENT_TOKEN) {
            $EnrollmentToken = $env:OPENPATH_ENROLLMENT_TOKEN
        }

        if (-not $EnrollmentToken -and -not $RegistrationToken -and $env:OPENPATH_TOKEN) {
            $RegistrationToken = $env:OPENPATH_TOKEN
        }

        if (-not $EnrollmentToken -and -not $RegistrationToken) {
            if ($Unattended) {
                Write-InstallerError "ERROR: Classroom mode requires -EnrollmentToken or -RegistrationToken in unattended mode"
                exit 1
            }

            if ($ClassroomId) {
                $EnrollmentToken = Read-Host "Enter enrollment token"
            }
            else {
                $RegistrationToken = Read-Host "Enter registration token"
            }
        }

        if ($RegistrationToken -and -not $Classroom) {
            Write-InstallerError "ERROR: -Classroom is required when using -RegistrationToken"
            exit 1
        }

        if ($RegistrationToken) {
            Write-InstallerNotice "Validating registration token..." -ForegroundColor Yellow
            try {
                $validateBody = @{ token = $RegistrationToken } | ConvertTo-Json
                $validateResponse = Invoke-RestMethod -Uri "$ApiBaseUrl/api/setup/validate-token" `
                    -Method Post -Body $validateBody -ContentType "application/json" -ErrorAction Stop

                if (-not $validateResponse.valid) {
                    Write-InstallerError "ERROR: Invalid registration token"
                    exit 1
                }
                Write-InstallerNotice "  Registration token validated" -ForegroundColor Green
            }
            catch {
                Write-InstallerError "ERROR: Failed to validate registration token: $_"
                exit 1
            }
        }
    }

    if ($RegistrationToken -and $EnrollmentToken) {
        Write-InstallerError "ERROR: Enrollment token and registration token cannot be combined"
        exit 1
    }

    return [PSCustomObject]@{
        ClassroomModeRequested = [bool]$classroomModeRequested
        RegistrationToken = [string]$RegistrationToken
        EnrollmentToken = [string]$EnrollmentToken
    }
}

function Invoke-OpenPathInstallerEnrollment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$ApiBaseUrl,

        [string]$Classroom = "",

        [string]$ClassroomId = "",

        [string]$EnrollmentToken = "",

        [string]$RegistrationToken = "",

        [string]$MachineName = "",

        [switch]$Unattended
    )

    $result = [ordered]@{
        MachineRegistered = 'NOT_REQUESTED'
        WhitelistUrl = ''
        EnrollmentError = ''
    }

    Write-InstallerVerbose "Registering machine in classroom..."

    $enrollScript = "$OpenPathRoot\scripts\Enroll-Machine.ps1"
    if (-not (Test-Path $enrollScript)) {
        $result.MachineRegistered = 'FAILED'
        $result.EnrollmentError = "Enrollment script not found: $enrollScript"
        Write-InstallerWarning "  Enrollment script not found: $enrollScript"
        return [PSCustomObject]$result
    }

    try {
        $enrollParams = @{
            ApiUrl = $ApiBaseUrl
            OpenPathRoot = $OpenPathRoot
        }
        if ($Classroom) {
            $enrollParams.Classroom = $Classroom
        }
        if ($ClassroomId) {
            $enrollParams.ClassroomId = $ClassroomId
        }
        if ($EnrollmentToken) {
            $enrollParams.EnrollmentToken = $EnrollmentToken
        }
        if ($MachineName) {
            $enrollParams.MachineName = $MachineName
        }
        if ($RegistrationToken) {
            $enrollParams.RegistrationToken = $RegistrationToken
            $enrollParams.SkipTokenValidation = $true
        }
        if ($Unattended) {
            $enrollParams.Unattended = $true
        }

        $enrollResult = & $enrollScript @enrollParams

        if ($enrollResult -and $enrollResult.Success) {
            $result.MachineRegistered = 'REGISTERED'
            if ($enrollResult.WhitelistUrl) {
                $result.WhitelistUrl = [string]$enrollResult.WhitelistUrl
            }
            Write-InstallerVerbose "  Machine registration completed"
        }
        else {
            $result.MachineRegistered = 'FAILED'
            $result.EnrollmentError = 'Machine registration returned an incomplete result'
            Write-InstallerWarning "  Failed to register machine"
        }
    }
    catch {
        $result.MachineRegistered = 'FAILED'
        $result.EnrollmentError = [string]$_
        Write-InstallerWarning "  Error registering machine: $_"
    }

    return [PSCustomObject]$result
}
