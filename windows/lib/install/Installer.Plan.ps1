function ConvertTo-OpenPathInstallPhaseInput {
    param(
        [AllowNull()]
        [object]$Inputs
    )

    $redactedNames = @(
        'RegistrationToken',
        'EnrollmentToken',
        'HealthApiSecret',
        'Token',
        'Secret'
    )
    $safeInputs = [ordered]@{}

    if (-not $Inputs) {
        return [pscustomobject]$safeInputs
    }

    $properties = if ($Inputs -is [hashtable]) {
        $Inputs.Keys | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_; Value = $Inputs[$_] }
        }
    }
    else {
        $Inputs.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Value = $_.Value }
        }
    }

    foreach ($property in $properties) {
        $name = [string]$property.Name
        $shouldRedact = $false
        foreach ($redactedName in $redactedNames) {
            if ($name -like "*$redactedName*") {
                $shouldRedact = $true
                break
            }
        }

        $safeInputs[$name] = if ($shouldRedact -and $null -ne $property.Value -and [string]$property.Value -ne '') {
            '<redacted>'
        }
        else {
            $property.Value
        }
    }

    return [pscustomobject]$safeInputs
}

function New-OpenPathInstallPhase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$Step = 0,

        [int]$TotalSteps = 0,

        [string]$Status = '',

        [AllowNull()]
        [object]$Inputs = $null,

        [string]$RecoveryHint = '',

        [scriptblock]$Action = $null
    )

    [pscustomobject]@{
        Type = 'OpenPathInstallPhase'
        Name = $Name
        Step = $Step
        TotalSteps = $TotalSteps
        Status = $Status
        Inputs = ConvertTo-OpenPathInstallPhaseInput -Inputs $Inputs
        RecoveryHint = $RecoveryHint
        Action = $Action
    }
}

function New-OpenPathInstallPlan {
    param(
        [hashtable]$Parameters = @{},

        [string]$OpenPathRoot = 'C:\OpenPath',

        [string]$ScriptDir = ''
    )

    $context = [pscustomobject]@{
        OpenPathRoot = $OpenPathRoot
        ScriptDir = $ScriptDir
        Results = @()
    }

    $phases = @(
        New-OpenPathInstallPhase -Name 'existing-install-cleanup' -RecoveryHint 'Check file locks and rerun the installer as Administrator.'
        New-OpenPathInstallPhase -Name 'preflight' -Step 0 -TotalSteps 7 -Status 'Running preflight validation' -Inputs @{ SkipPreflight = $Parameters.SkipPreflight } -RecoveryHint 'Run Pre-Install-Validation.ps1 manually and fix reported prerequisites.'
        New-OpenPathInstallPhase -Name 'directories' -Step 1 -TotalSteps 7 -Status 'Creating directory structure' -RecoveryHint 'Check permissions for C:\OpenPath.'
        New-OpenPathInstallPhase -Name 'runtime' -Step 2 -TotalSteps 7 -Status 'Copying modules and scripts' -RecoveryHint 'Verify installer package contents and retry from a local directory.'
        New-OpenPathInstallPhase -Name 'configuration' -Step 3 -TotalSteps 7 -Status 'Creating configuration' -Inputs $Parameters -RecoveryHint 'Check installer parameters and enrollment configuration.'
        New-OpenPathInstallPhase -Name 'acrylic' -Step 4 -TotalSteps 7 -Status 'Installing Acrylic DNS Proxy' -Inputs @{ SkipAcrylic = $Parameters.SkipAcrylic } -RecoveryHint 'Install or repair Acrylic DNS Proxy, then rerun the installer.'
        New-OpenPathInstallPhase -Name 'acrylic-configuration' -RecoveryHint 'Check Acrylic configuration file permissions.'
        New-OpenPathInstallPhase -Name 'local-dns' -Step 5 -TotalSteps 7 -Status 'Configuring local DNS' -RecoveryHint 'Check adapter DNS permissions and current network state.'
        New-OpenPathInstallPhase -Name 'enrollment' -Inputs @{
            ApiUrl = $Parameters.ApiUrl
            Classroom = $Parameters.Classroom
            ClassroomId = $Parameters.ClassroomId
            RegistrationToken = $Parameters.RegistrationToken
            EnrollmentToken = $Parameters.EnrollmentToken
            MachineName = $Parameters.MachineName
        } -RecoveryHint 'Check API URL, classroom identifier, token validity, and network connectivity.'
        New-OpenPathInstallPhase -Name 'native-host' -RecoveryHint 'Check Firefox native messaging host registry entries and request setup state.'
        New-OpenPathInstallPhase -Name 'first-update' -Step 7 -TotalSteps 7 -Status 'Running first update' -RecoveryHint 'Run OpenPath.ps1 update after enrollment and network connectivity are available.'
        New-OpenPathInstallPhase -Name 'firefox-managed-extension-ready' -RecoveryHint 'Check Firefox policy, signed extension URL, and native host runtime registration.'
        New-OpenPathInstallPhase -Name 'scheduled-tasks' -Step 6 -TotalSteps 7 -Status 'Registering scheduled tasks' -RecoveryHint 'Check Task Scheduler service and Administrator privileges.'
        New-OpenPathInstallPhase -Name 'realtime-updates' -RecoveryHint 'Check request setup state and SSE listener startup.'
        New-OpenPathInstallPhase -Name 'app-control' -RecoveryHint 'Check AppLocker support and local security policy permissions.'
        New-OpenPathInstallPhase -Name 'browser-inventory' -Inputs @{ BrowserCleanupMode = $Parameters.BrowserCleanupMode } -RecoveryHint 'Review browser inventory permissions and cleanup mode.'
        New-OpenPathInstallPhase -Name 'integrity' -RecoveryHint 'Check installed file permissions before generating integrity baseline.'
        New-OpenPathInstallPhase -Name 'timing' -Inputs @{ TimingOutputPath = $Parameters.TimingOutputPath } -RecoveryHint 'Check timing output path permissions.'
        New-OpenPathInstallPhase -Name 'summary' -RecoveryHint 'Check collected installer context before reporting summary.'
    )

    [pscustomobject]@{
        Type = 'OpenPathInstallPlan'
        Parameters = [pscustomobject]$Parameters
        Context = $context
        Phases = $phases
    }
}

function Invoke-OpenPathInstallPhase {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Phase,

        [AllowNull()]
        [object]$Context = $null
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $errorRecord = $null
    $status = 'success'
    $success = $true

    try {
        if ((Get-Command Show-InstallerProgress -ErrorAction SilentlyContinue) -and $Phase.PSObject.Properties['Step'] -and $Phase.TotalSteps -gt 0 -and $Phase.Status) {
            Show-InstallerProgress -Step $Phase.Step -Total $Phase.TotalSteps -Status $Phase.Status
        }
        if ($Phase.Action) {
            & $Phase.Action $Context
        }
    }
    catch {
        $success = $false
        $status = 'failed'
        $errorRecord = $_
    }
    finally {
        $stopwatch.Stop()
    }

    $normalizedError = if ($errorRecord) {
        [pscustomobject]@{
            Message = [string]$errorRecord.Exception.Message
            Category = [string]$errorRecord.CategoryInfo.Category
            FullyQualifiedErrorId = [string]$errorRecord.FullyQualifiedErrorId
        }
    }
    else {
        $null
    }

    $result = [pscustomobject]@{
        Type = 'OpenPathInstallResult'
        Name = [string]$Phase.Name
        Success = $success
        Status = $status
        DurationMs = [int64]$stopwatch.ElapsedMilliseconds
        Inputs = ConvertTo-OpenPathInstallPhaseInput -Inputs $Phase.Inputs
        Error = $normalizedError
        RecoveryHint = [string]$Phase.RecoveryHint
    }

    if ($Context -and $Context.PSObject.Properties['Results']) {
        $Context.Results += $result
    }

    return $result
}
