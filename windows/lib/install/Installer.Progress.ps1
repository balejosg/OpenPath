function Write-InstallerNotice {
    # emits an operator-facing message to the console; silently does nothing when not
    # running in verbose mode.
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
    # emits a yellow warning message; silently does nothing when not in verbose mode.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($VerbosePreference -ne 'Continue') { return }

    Write-Host $Message -ForegroundColor Yellow
}

function Write-InstallerError {
    # emits a red error message unconditionally (not gated on verbose mode).
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host $Message -ForegroundColor Red
}

function Write-InstallerVerbose {
    # forwards message to the powershell verbose stream.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Verbose $Message
}

function Show-InstallerProgress {
    # updates the powershell progress bar and, in verbose mode, also emits a step log line;
    # skips the progress bar when console output is redirected.
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
    }

    if ([Console]::IsOutputRedirected) {
        return
    }

    Write-Progress -Activity 'Installing OpenPath' -Status $Status -PercentComplete $percentComplete
}

function Invoke-OpenPathInstallTimedStep {
    # runs scriptblock, records name/status/duration in the script-scoped timing list,
    # and re-throws any error after recording it.
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
    # begins a named timer; pair with the corresponding complete function for open-ended phases.
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
    # stops the timer started by the corresponding start function and appends the record
    # with final status and optional error message to the timing list.
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
    # serializes the accumulated timing records to a json file at path; no-op when path is empty.
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
        Write-InstallerWarning "  WARNING: Could not save installation timings: $_"
    }
}
