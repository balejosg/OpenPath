[CmdletBinding()]
param(
    [switch]$Child,
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..' '..' '..'),
    [string]$ResultsPath = 'windows-test-results.xml',
    [int]$TimeoutSeconds = 840,
    [int]$ShardIndex = 1,
    [int]$ShardCount = 1
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$BasePath = (Get-Location).Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Invoke-IsolatedPesterHost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$ResultsPath,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int]$ShardIndex,

        [Parameter(Mandatory = $true)]
        [int]$ShardCount
    )

    function Receive-CompletedStream {
        param(
            [Parameter(Mandatory = $true)]
            $Task,

            [Parameter(Mandatory = $true)]
            [string]$StreamName,

            [int]$TimeoutMilliseconds = 5000
        )

        try {
            if ($Task.Wait($TimeoutMilliseconds)) {
                return $Task.GetAwaiter().GetResult()
            }
        }
        catch {
            return "<failed to read $StreamName stream: $($_.Exception.Message)>"
        }

        return "<$StreamName stream did not close within $TimeoutMilliseconds ms after process timeout>"
    }

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($argument in @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $ScriptPath,
            '-Child',
            '-RepoRoot',
            $RepoRoot,
            '-ResultsPath',
            $ResultsPath,
            '-TimeoutSeconds',
            [string]$TimeoutSeconds,
            '-ShardIndex',
            [string]$ShardIndex,
            '-ShardCount',
            [string]$ShardCount
        )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $null = $startInfo.Environment.Remove('RUNNER_TRACKING_ID')
    $startInfo.Environment['OPENPATH_WINDOWS_CI_ISOLATED_PESTER'] = '1'

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'Failed to start isolated Windows Pester host.'
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $killedProcess = $false
            try {
                $process.Kill($true)
                $killedProcess = $true
            }
            catch {
                # Best effort; the Actions job timeout remains the outer guard.
            }

            if ($killedProcess) {
                try {
                    [void]$process.WaitForExit(5000)
                }
                catch {
                    # The timeout path must never hang while collecting diagnostics.
                }
            }

            $stdout = Receive-CompletedStream -Task $stdoutTask -StreamName 'STDOUT'
            $stderr = Receive-CompletedStream -Task $stderrTask -StreamName 'STDERR'
            throw "Isolated Windows Pester host timed out after $TimeoutSeconds seconds. KillIssued=$killedProcess.`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
        }

        # A child can exit while a descendant still owns an inherited pipe.
        # Bound the normal drain too; otherwise the outer job can hang forever
        # after the Pester process has already produced its exit code.
        $stdout = Receive-CompletedStream -Task $stdoutTask -StreamName 'STDOUT'
        $stderr = Receive-CompletedStream -Task $stderrTask -StreamName 'STDERR'

        if ($stdout) {
            $stdout | Out-Host
        }

        if ($stderr) {
            $stderr | Out-Host
        }

        if ($process.ExitCode -ne 0) {
            throw "Isolated Windows Pester host failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-WindowsPesterSuite {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$ResultsPath,

        [Parameter(Mandatory = $true)]
        [int]$ShardIndex,

        [Parameter(Mandatory = $true)]
        [int]$ShardCount
    )

    Set-StrictMode -Off
    Set-Location $RepoRoot

    if (Test-Path $ResultsPath) {
        Remove-Item $ResultsPath -Force
    }

    $minimumPesterVersion = [version]'5.0.0'
    $availablePester = Get-Module -ListAvailable -Name Pester |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $availablePester -or $availablePester.Version -lt $minimumPesterVersion) {
        Install-Module -Name Pester -MinimumVersion $minimumPesterVersion.ToString() -Force -Scope CurrentUser
    }

    Import-Module Pester -MinimumVersion $minimumPesterVersion -ErrorAction Stop

    $aggregatorSuites = @(
        'Windows.Tests.ps1',
        'Windows.Common.Tests.ps1',
        'Windows.DNS.Tests.ps1'
    )
    $allSuitePaths = @(
        Get-ChildItem -Path 'windows/tests' -Filter '*.Tests.ps1' -File |
            Where-Object { $_.Name -notin $aggregatorSuites } |
            Sort-Object FullName |
            ForEach-Object { $_.FullName }
    )

    if ($allSuitePaths.Count -eq 0) {
        throw 'Windows Pester suite discovery returned no leaf test files.'
    }

    if ($ShardCount -lt 1 -or $ShardIndex -lt 1 -or $ShardIndex -gt $ShardCount) {
        throw "Invalid Pester shard $ShardIndex of $ShardCount."
    }

    $heavySuiteName = 'Windows.AppControl.Tests.ps1'
    $heavySuitePath = @($allSuitePaths | Where-Object { (Split-Path $_ -Leaf) -eq $heavySuiteName })
    $remainingSuitePaths = @($allSuitePaths | Where-Object { (Split-Path $_ -Leaf) -ne $heavySuiteName })
    $suitePaths = if ($ShardCount -gt 1 -and $heavySuitePath.Count -eq 1) {
        if ($ShardIndex -eq 1) {
            @($heavySuitePath)
        }
        else {
            @(
                for ($index = 0; $index -lt $remainingSuitePaths.Count; $index++) {
                    if (($index % ($ShardCount - 1)) -eq ($ShardIndex - 2)) {
                        $remainingSuitePaths[$index]
                    }
                }
            )
        }
    }
    else {
        @(
            for ($index = 0; $index -lt $allSuitePaths.Count; $index++) {
                if (($index % $ShardCount) -eq ($ShardIndex - 1)) {
                    $allSuitePaths[$index]
                }
            }
        )
    }
    if ($suitePaths.Count -eq 0) {
        throw "Pester shard $ShardIndex of $ShardCount selected no test files."
    }

    Write-Host ("Running Windows Pester shard {0}/{1}: {2}/{3} files" -f $ShardIndex, $ShardCount, $suitePaths.Count, $allSuitePaths.Count)

    $config = New-PesterConfiguration
    $config.Run.Path = $suitePaths
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $ResultsPath
    $config.TestResult.OutputFormat = 'NUnitXml'

    try {
        $result = Invoke-Pester -Configuration $config

        if (-not (Test-Path $ResultsPath)) {
            throw 'Windows Pester suite did not produce windows-test-results.xml.'
        }

        if ($null -eq $result) {
            throw 'Invoke-Pester returned no result object.'
        }

        if ($result.FailedCount -gt 0) {
            throw "Windows Pester suite reported $($result.FailedCount) failure(s)."
        }
    }
    finally {
        $jobs = @(Get-Job -ErrorAction SilentlyContinue)
        if ($jobs.Count -gt 0) {
            Write-Host ("Stopping lingering PowerShell jobs: {0}" -f $jobs.Count)
            $jobs | Stop-Job -ErrorAction SilentlyContinue
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}

$RepoRoot = Resolve-FullPath -Path $RepoRoot
$ResultsPath = Resolve-FullPath -Path $ResultsPath -BasePath $RepoRoot
$resultsDirectory = Split-Path $ResultsPath -Parent

if ($resultsDirectory -and -not (Test-Path $resultsDirectory)) {
    New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
}

if ($Child) {
    Invoke-WindowsPesterSuite -RepoRoot $RepoRoot -ResultsPath $ResultsPath `
        -ShardIndex $ShardIndex -ShardCount $ShardCount
    return
}

Invoke-IsolatedPesterHost `
    -ScriptPath $MyInvocation.MyCommand.Path `
    -RepoRoot $RepoRoot `
    -ResultsPath $ResultsPath `
    -TimeoutSeconds $TimeoutSeconds `
    -ShardIndex $ShardIndex `
    -ShardCount $ShardCount

if (-not (Test-Path $ResultsPath)) {
    throw 'Windows Pester suite did not produce windows-test-results.xml.'
}
