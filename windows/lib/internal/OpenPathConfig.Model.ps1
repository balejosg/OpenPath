function Set-OpenPathConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )

    if ($Config.PSObject.Properties[$Name]) {
        $Config.$Name = $Value
    }
    else {
        $Config | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Get-OpenPathConfigValue {
    param(
        [AllowNull()]
        [object]$Config = $null,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue = ''
    )

    if (-not $Config -or -not $Config.PSObject -or -not $Config.PSObject.Properties[$Name] -or $null -eq $Config.$Name) {
        return $DefaultValue
    }

    return $Config.$Name
}

function ConvertTo-OpenPathNormalizedConfig {
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $normalized = [PSCustomObject]@{}
    if ($Config -is [System.Collections.IDictionary]) {
        foreach ($key in $Config.Keys) {
            Set-OpenPathConfigValue -Config $normalized -Name ([string]$key) -Value $Config[$key]
        }
    }
    elseif ($Config -and $Config.PSObject) {
        foreach ($property in $Config.PSObject.Properties) {
            Set-OpenPathConfigValue -Config $normalized -Name $property.Name -Value $property.Value
        }
    }

    $apiUrl = [string](Get-OpenPathConfigValue -Config $normalized -Name 'apiUrl' -DefaultValue '')
    $requestApiUrl = [string](Get-OpenPathConfigValue -Config $normalized -Name 'requestApiUrl' -DefaultValue '')
    $resolvedApiUrl = if (-not [string]::IsNullOrWhiteSpace($requestApiUrl)) { $requestApiUrl } else { $apiUrl }
    $resolvedApiUrl = $resolvedApiUrl.Trim().TrimEnd('/')

    if ($resolvedApiUrl) {
        Set-OpenPathConfigValue -Config $normalized -Name 'apiUrl' -Value $resolvedApiUrl
        Set-OpenPathConfigValue -Config $normalized -Name 'requestApiUrl' -Value $resolvedApiUrl
    }

    foreach ($stringProperty in @('whitelistUrl', 'classroom', 'classroomId', 'machineName', 'version')) {
        $value = [string](Get-OpenPathConfigValue -Config $normalized -Name $stringProperty -DefaultValue '')
        Set-OpenPathConfigValue -Config $normalized -Name $stringProperty -Value $value.Trim()
    }

    # Log rotation defaults: 5 MB threshold, keep 3 archives
    $logMaxSizeMb = Get-OpenPathConfigValue -Config $normalized -Name 'logMaxSizeMb' -DefaultValue 5
    $logMaxSizeMb = try { [int]$logMaxSizeMb } catch { 5 }
    if ($logMaxSizeMb -lt 1) { $logMaxSizeMb = 5 }
    Set-OpenPathConfigValue -Config $normalized -Name 'logMaxSizeMb' -Value $logMaxSizeMb

    $logKeepFiles = Get-OpenPathConfigValue -Config $normalized -Name 'logKeepFiles' -DefaultValue 3
    $logKeepFiles = try { [int]$logKeepFiles } catch { 3 }
    if ($logKeepFiles -lt 1) { $logKeepFiles = 3 }
    Set-OpenPathConfigValue -Config $normalized -Name 'logKeepFiles' -Value $logKeepFiles

    return $normalized
}

function Test-OpenPathConfig {
    param(
        [AllowNull()]
        [object]$Config = $null
    )

    $normalized = ConvertTo-OpenPathNormalizedConfig -Config $Config
    $missingFields = @()
    $apiUrl = [string](Get-OpenPathConfigValue -Config $normalized -Name 'apiUrl' -DefaultValue '')
    $whitelistUrl = [string](Get-OpenPathConfigValue -Config $normalized -Name 'whitelistUrl' -DefaultValue '')
    $classroom = [string](Get-OpenPathConfigValue -Config $normalized -Name 'classroom' -DefaultValue '')
    $classroomId = [string](Get-OpenPathConfigValue -Config $normalized -Name 'classroomId' -DefaultValue '')

    if ($apiUrl -notmatch '^https?://\S+$') {
        $missingFields += 'apiUrl'
    }
    if ($whitelistUrl -notmatch '^https?://\S+$') {
        $missingFields += 'whitelistUrl'
    }
    if (-not $classroom -and -not $classroomId) {
        $missingFields += 'classroom'
    }

    return [PSCustomObject]@{
        Valid = ($missingFields.Count -eq 0)
        MissingFields = @($missingFields)
        Config = $normalized
    }
}
