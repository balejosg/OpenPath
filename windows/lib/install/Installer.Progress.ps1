function Write-InstallerNotice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$ForegroundColor = ''
    )

    if ($VerbosePreference -ne 'Continue') { return }

    if ($ForegroundColor) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host $Message
    }
}

function Write-InstallerWarning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($VerbosePreference -ne 'Continue') { return }

    Write-Host $Message -ForegroundColor Yellow
}

function Write-InstallerError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host $Message -ForegroundColor Red
}

function Write-InstallerVerbose {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Verbose $Message
}

function Show-InstallerProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Step,

        [Parameter(Mandatory = $true)]
        [int]$Total,

        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    $percentComplete = [Math]::Min(100, [Math]::Max(0, [int](($Step / $Total) * 100)))
    if ($VerbosePreference -eq 'Continue') {
        Write-Verbose "[$Step/$Total] $Status"
        return
    }

    if ([Console]::IsOutputRedirected) {
        return
    }

    Write-Progress -Activity 'Installing OpenPath' -Status $Status -PercentComplete $percentComplete
}

function Invoke-OpenPathInstallTimedStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    if (-not $script:OpenPathInstallTimingRecords) {
        $script:OpenPathInstallTimingRecords = @()
    }

    $startedAt = Get-Date
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'success'
    $errorMessage = $null

    try {
        & $ScriptBlock
    }
    catch {
        $status = 'failure'
        $errorMessage = $_.Exception.Message
        throw
    }
    finally {
        $timer.Stop()
        $script:OpenPathInstallTimingRecords += [PSCustomObject]@{
            name            = $Name
            status          = $status
            startedAt       = $startedAt.ToString('o')
            endedAt         = (Get-Date).ToString('o')
            durationMs      = [Math]::Round($timer.Elapsed.TotalMilliseconds, 0)
            durationSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
            error           = $errorMessage
        }
    }
}

function Start-OpenPathInstallTimedStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $script:OpenPathInstallTimingStarts) {
        $script:OpenPathInstallTimingStarts = @{}
    }
    $script:OpenPathInstallTimingStarts[$Name] = @{
        StartedAt = Get-Date
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Complete-OpenPathInstallTimedStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Status = 'success',

        [string]$ErrorMessage = ''
    )

    if (-not $script:OpenPathInstallTimingRecords) {
        $script:OpenPathInstallTimingRecords = @()
    }

    $record = if ($script:OpenPathInstallTimingStarts) { $script:OpenPathInstallTimingStarts[$Name] } else { $null }
    $timer = if ($record) { $record.Stopwatch } else { [System.Diagnostics.Stopwatch]::StartNew() }
    $startedAt = if ($record) { $record.StartedAt } else { Get-Date }
    $timer.Stop()

    $script:OpenPathInstallTimingRecords += [PSCustomObject]@{
        name            = $Name
        status          = $Status
        startedAt       = $startedAt.ToString('o')
        endedAt         = (Get-Date).ToString('o')
        durationMs      = [Math]::Round($timer.Elapsed.TotalMilliseconds, 0)
        durationSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        error           = if ($ErrorMessage) { $ErrorMessage } else { $null }
    }
}

function Save-OpenPathInstallTiming {
    param(
        [string]$Path = ''
    )

    if (-not $Path) { return }

    try {
        $parent = Split-Path $Path -Parent
        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        @($script:OpenPathInstallTimingRecords) |
            ConvertTo-Json -Depth 5 |
            Set-Content -Path $Path -Encoding UTF8
    }
    catch {
        Write-InstallerWarning "  ADVERTENCIA: No se pudieron guardar timings de instalacion: $_"
    }
}
