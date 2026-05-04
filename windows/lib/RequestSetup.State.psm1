# OpenPath Windows request setup state helpers.

function Get-OpenPathRequestSetupStringValue {
    param(
        [AllowNull()]
        [object]$Config = $null,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    if (-not $Config -or -not $Config.PSObject) {
        return ''
    }

    foreach ($propertyName in $PropertyNames) {
        if (
            $Config.PSObject.Properties[$propertyName] -and
            $null -ne $Config.$propertyName
        ) {
            $value = ([string]$Config.$propertyName).Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ''
}

function Get-OpenPathRequestSetupMachineToken {
    param(
        [AllowNull()]
        [string]$WhitelistUrl = ''
    )

    if ([string]::IsNullOrWhiteSpace($WhitelistUrl)) {
        return ''
    }

    if ($WhitelistUrl -match '/w/([^/]+)/') {
        return [string]$Matches[1]
    }

    return ''
}

function Get-OpenPathRequestSetupDiagnosticMessage {
    param(
        [string]$Status = '',
        [string[]]$MissingFields = @()
    )

    switch ($Status) {
        'ready' {
            return ''
        }
        'not_requested' {
            return 'OpenPath request setup was not requested.'
        }
        default {
            $fieldList = @($MissingFields) | Where-Object { $_ } | Select-Object -Unique
            if ($fieldList.Count -eq 0) {
                return 'OpenPath request setup is incomplete.'
            }

            return "OpenPath request setup is incomplete: missing or invalid $($fieldList -join ', ')."
        }
    }
}

function Get-OpenPathRequestSetupState {
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $apiUrl = Get-OpenPathRequestSetupStringValue -Config $Config -PropertyNames @('requestApiUrl', 'apiUrl')
    if ($apiUrl) {
        $apiUrl = $apiUrl.TrimEnd('/')
    }

    $whitelistUrl = Get-OpenPathRequestSetupStringValue -Config $Config -PropertyNames @('whitelistUrl')
    $classroom = Get-OpenPathRequestSetupStringValue -Config $Config -PropertyNames @('classroom')
    $classroomId = Get-OpenPathRequestSetupStringValue -Config $Config -PropertyNames @('classroomId')
    $machineName = Get-OpenPathRequestSetupStringValue -Config $Config -PropertyNames @('machineName')
    $version = Get-OpenPathRequestSetupStringValue -Config $Config -PropertyNames @('version')
    $machineToken = Get-OpenPathRequestSetupMachineToken -WhitelistUrl $whitelistUrl

    $requestSetupRequested = [bool](
        $apiUrl -or
        $whitelistUrl -or
        $classroom -or
        $classroomId
    )
    $missingFields = @()

    if (-not $requestSetupRequested) {
        $status = 'not_requested'
        return [PSCustomObject]([ordered]@{
                Status = $status
                Ready = $false
                RequestSetupRequested = $false
                ApiUrl = ''
                RequestApiUrl = ''
                WhitelistUrl = ''
                MachineToken = ''
                TokenState = 'not_requested'
                Classroom = ''
                ClassroomId = ''
                MachineName = $machineName
                Version = $version
                MissingFields = @()
                DiagnosticMessage = Get-OpenPathRequestSetupDiagnosticMessage -Status $status
            })
    }

    if ($apiUrl -notmatch '^https?://\S+$') {
        $missingFields += 'apiUrl'
    }
    if ($whitelistUrl -notmatch '/w/[^/]+/whitelist\.txt($|[?#].*)') {
        $missingFields += 'whitelistUrl'
    }
    if (-not ($classroom -or $classroomId)) {
        $missingFields += 'classroom'
    }

    $tokenState = if ($machineToken) { 'ready' } elseif ($whitelistUrl) { 'invalid_token_source' } else { 'missing' }
    $status = if ($missingFields.Count -eq 0) { 'ready' } else { 'incomplete' }

    return [PSCustomObject]([ordered]@{
            Status = $status
            Ready = ($status -eq 'ready')
            RequestSetupRequested = $true
            ApiUrl = $apiUrl
            RequestApiUrl = $apiUrl
            WhitelistUrl = $whitelistUrl
            MachineToken = $machineToken
            TokenState = $tokenState
            Classroom = $classroom
            ClassroomId = $classroomId
            MachineName = $machineName
            Version = $version
            MissingFields = @($missingFields)
            DiagnosticMessage = Get-OpenPathRequestSetupDiagnosticMessage -Status $status -MissingFields $missingFields
        })
}

function Test-OpenPathRequestSetupReady {
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $state = Get-OpenPathRequestSetupState -Config $Config
    return [bool]$state.Ready
}

function New-OpenPathRequestSetupNativeHostState {
    param(
        [AllowNull()]
        [object]$Config = $null,

        [string]$MachineName = '',

        [string]$SyncedAt = ''
    )

    $state = Get-OpenPathRequestSetupState -Config $Config
    if (-not $state.Ready) {
        throw $state.DiagnosticMessage
    }

    $resolvedMachineName = if ($MachineName) { $MachineName } else { [string]$state.MachineName }
    return [ordered]@{
        machineName = $resolvedMachineName
        whitelistUrl = [string]$state.WhitelistUrl
        apiUrl = [string]$state.ApiUrl
        requestApiUrl = [string]$state.RequestApiUrl
        classroom = [string]$state.Classroom
        classroomId = [string]$state.ClassroomId
        version = [string]$state.Version
        syncedAt = $SyncedAt
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathRequestSetupState',
    'Get-OpenPathRequestSetupMachineToken',
    'Get-OpenPathRequestSetupDiagnosticMessage',
    'Test-OpenPathRequestSetupReady',
    'New-OpenPathRequestSetupNativeHostState'
)
