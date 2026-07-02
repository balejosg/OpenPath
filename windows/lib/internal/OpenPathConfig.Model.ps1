function Set-OpenPathConfigValue {
    # sets or adds a named property on a pscustomobject config, using add-member when the property is absent
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
    # returns the named property from config, or $DefaultValue when the config is null/missing/the property is absent
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
    # converts a hashtable or pscustomobject config into a normalized pscustomobject with trimmed urls and validated numeric defaults
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

    # SSE update cooldown default: 10 seconds (mirrors Linux SSE_UPDATE_COOLDOWN=10)
    $sseUpdateCooldown = Get-OpenPathConfigValue -Config $normalized -Name 'sseUpdateCooldown' -DefaultValue 10
    $sseUpdateCooldown = try { [int]$sseUpdateCooldown } catch { 10 }
    if ($sseUpdateCooldown -lt 1) { $sseUpdateCooldown = 10 }
    Set-OpenPathConfigValue -Config $normalized -Name 'sseUpdateCooldown' -Value $sseUpdateCooldown

    return $normalized
}

function Test-OpenPathConfigUrlSecure {
    # https everywhere; http only for loopback (dev/CI), never for remote endpoints.
    param([string]$Url)
    if ($Url -match '^https://\S+$') { return $true }
    return ($Url -match '^http://(localhost|127\.0\.0\.1)(:\d+)?(/\S*)?$')
}

function Test-OpenPathConfig {
    # validates that a config object has a reachable apiUrl, whitelistUrl, and at least one of classroom/classroomId; returns Valid, MissingFields, Config
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

    if (-not (Test-OpenPathConfigUrlSecure -Url $apiUrl)) {
        $missingFields += 'apiUrl'
    }
    if (-not (Test-OpenPathConfigUrlSecure -Url $whitelistUrl)) {
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
