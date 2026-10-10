[CmdletBinding()]
param(
    [switch]$Child,
    # Grandchild mode: run Pester for one suite file only (used by the child to
    # bound and name a hang per file).
    [string]$SuiteFile = '',
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..' '..' '..'),
    [string]$ResultsPath = 'windows-test-results.xml',
    [string]$ProgressPath = '',
    [int]$TimeoutSeconds = 840,
    # 0 = auto: max(240s, 3 x fair share) capped by the remaining budget. Heavy
    # small shards (the AppControl split) keep the whole budget.
    [int]$FileTimeoutSeconds = 0,
    [int]$ShardIndex = 1,
    [int]$ShardCount = 1,
    # Grandchild filters (Pester tags for the AppControl split).
    [string]$Tag = '',
    [string]$ExcludeTag = ''
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WindowsPesterShardPlan.psm1') -Force

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
        [int]$FileTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [string]$ProgressPath,

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

    function Compress-StreamText {
        # A wedged child can emit tens of MB; the timeout message must stay
        # bounded (Phase 5.3 C1: the hosted 20m hang produced a BlobNotFound
        # log with an unbounded payload).
        param([AllowNull()][string]$Text, [int]$MaxChars = 16384)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        if ($Text.Length -le $MaxChars) { return $Text }
        return $Text.Substring($Text.Length - $MaxChars) + "`n<truncated $($Text.Length - $MaxChars) chars>"
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
            '-ProgressPath',
            $ProgressPath,
            '-TimeoutSeconds',
            [string]$TimeoutSeconds,
            '-FileTimeoutSeconds',
            [string]$FileTimeoutSeconds,
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

            $stdout = Compress-StreamText -Text (Receive-CompletedStream -Task $stdoutTask -StreamName 'STDOUT')
            $stderr = Compress-StreamText -Text (Receive-CompletedStream -Task $stderrTask -StreamName 'STDERR')
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

function Export-ProgressFile {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][object]$Progress
    )
    if ([string]::IsNullOrWhiteSpace($ProgressPath)) { return }
    try {
        $Progress['updatedAt'] = [DateTime]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($ProgressPath, ($Progress | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-Host "failed to write Pester progress file: $($_.Exception.Message)"
    }
}

function Read-PesterXmlSummary {
    param([Parameter(Mandatory = $true)][string]$Path)
    $summary = [ordered]@{ tests = 0; passed = 0; failed = 0; skipped = 0; cases = @(); failedNames = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$summary }
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw
        $root = $xml.'test-results'
        if ($root) {
            foreach ($attribute in @('total', 'failures', 'not-run', 'skipped')) {
                if ($null -ne $root.$attribute) { $summary[$attribute] = [int]$root.$attribute }
            }
            $summary.tests = [int]$root.total
            $summary.skipped = [int]$root.skipped + [int]$root.'not-run'
            $summary.passed = [int]$root.total - [int]$root.failures - $summary.skipped
            $summary.failed = [int]$root.failures
        }
        $cases = @($xml.SelectNodes('//test-case'))
        foreach ($case in $cases) {
            $caseResult = [string]$case.result
            $summary.cases += [ordered]@{ name = [string]$case.name; result = $caseResult; time = [string]$case.time; success = [string]$case.success }
            if ($caseResult -eq 'Failure' -or $caseResult -eq 'Error') { $summary.failedNames += [string]$case.name }
        }
    }
    catch {
        $summary.failedNames += "<unreadable xml: $($_.Exception.Message)>"
        $summary.failed = -1
    }
    return [pscustomobject]$summary
}

function Merge-PesterXml {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SuiteXmlPaths,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $total = 0; $failures = 0; $notRun = 0; $skipped = 0; $errors = 0; $inconclusive = 0; $ignored = 0
    $suites = New-Object System.Collections.ArrayList
    foreach ($path in $SuiteXmlPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            [xml]$xml = Get-Content -LiteralPath $path -Raw
            $root = $xml.'test-results'
            if (-not $root) { continue }
            $total += [int]$root.total
            $failures += [int]$root.failures
            $notRun += [int]$root.'not-run'
            $skipped += [int]$root.skipped
            $errors += [int]$root.errors
            $inconclusive += [int]$root.inconclusive
            $ignored += [int]$root.ignored
            foreach ($node in @($xml.DocumentElement.ChildNodes)) {
                $null = $suites.Add($node)
            }
        }
        catch {
            Write-Host "failed to merge Pester xml $path`: $($_.Exception.Message)"
        }
    }
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    $null = $builder.AppendLine(('<test-results name="windows-pester-merged" total="{0}" errors="{1}" failures="{2}" not-run="{3}" inconclusive="{4}" ignored="{5}" skipped="{6}" invalid="0" date="{7}" time="{8}">' -f $total, $errors, $failures, $notRun, $inconclusive, $ignored, $skipped, (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HH:mm:ss')))
    foreach ($node in $suites) { $null = $builder.AppendLine($node.OuterXml) }
    $null = $builder.AppendLine('</test-results>')
    [IO.File]::WriteAllText($OutputPath, $builder.ToString(), [Text.UTF8Encoding]::new($false))
}

function Invoke-WindowsPesterSuiteSingleFile {
    # Grandchild: run Pester for exactly one suite file and write its NUnit XML.
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$SuiteFile,
        [Parameter(Mandatory = $true)][string]$ResultsPath,
        [string]$Tag = '',
        [string]$ExcludeTag = ''
    )
    Set-StrictMode -Off
    Set-Location $RepoRoot

    $minimumPesterVersion = [version]'5.0.0'
    $availablePester = Get-Module -ListAvailable -Name Pester |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $availablePester -or $availablePester.Version -lt $minimumPesterVersion) {
        Install-Module -Name Pester -MinimumVersion $minimumPesterVersion.ToString() -Force -Scope CurrentUser
    }
    Import-Module Pester -MinimumVersion $minimumPesterVersion -ErrorAction Stop

    $config = New-PesterConfiguration
    $config.Run.Path = @($SuiteFile)
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $ResultsPath
    $config.TestResult.OutputFormat = 'NUnitXml'
    if ($Tag) { $config.Filter.Tag = @($Tag) }
    elseif ($ExcludeTag) { $config.Filter.ExcludeTag = @($ExcludeTag) }
    try {
        $result = Invoke-Pester -Configuration $config
        if ($null -eq $result) {
            throw 'Invoke-Pester returned no result object.'
        }
        if ($result.FailedCount -gt 0) {
            throw "Windows Pester suite reported $($result.FailedCount) failure(s)."
        }
        return 0
    }
    finally {
        $jobs = @(Get-Job -ErrorAction SilentlyContinue)
        if ($jobs.Count -gt 0) {
            $jobs | Stop-Job -ErrorAction SilentlyContinue
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WindowsPesterSuite {
    # Child: per-file bounded execution, progress file, merged results.
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$ResultsPath,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int]$FileTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [string]$ProgressPath,

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

    $plan = Get-WindowsPesterShardPlan -AllSuitePaths $allSuitePaths -ShardIndex $ShardIndex -ShardCount $ShardCount
    $suitePaths = @($plan.SuitePaths)

    $shardFilter = ''
    if ($plan.Tag) { $shardFilter = " (filter: Tag=$($plan.Tag))" }
    elseif ($plan.ExcludeTag) { $shardFilter = " (filter: ExcludeTag=$($plan.ExcludeTag))" }

    Write-Host ("Running Windows Pester shard {0}/{1}: {2}/{3} files{4}" -f $ShardIndex, $ShardCount, $suitePaths.Count, $allSuitePaths.Count, $shardFilter)

    $progress = [ordered]@{
        schemaVersion       = 1
        shardIndex          = $ShardIndex
        shardCount          = $ShardCount
        startedAt           = [DateTime]::UtcNow.ToString('o')
        updatedAt           = ''
        fileTimeoutSeconds  = $FileTimeoutSeconds
        totalBudgetSeconds  = $TimeoutSeconds
        files               = @()
    }
    $perFileAuto = [int][Math]::Max(240, 3 * ($TimeoutSeconds / [Math]::Max(1, $suitePaths.Count)))
    $scriptPath = $PSCommandPath
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $progressPartsRoot = Join-Path ([IO.Path]::GetTempPath()) ("openpath-pester-parts-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $progressPartsRoot -Force | Out-Null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $suiteXmlPaths = New-Object System.Collections.ArrayList
    $failedFiles = New-Object System.Collections.ArrayList
    $firstFailureMessage = ''

    # Bound the stream drain: a descendant holding the inherited pipe can keep
    # ReadToEnd pending after the killed process is gone.
    function Receive-BoundedStream {
        param($Task, [int]$TimeoutMilliseconds = 5000)
        try {
            if ($Task.Wait($TimeoutMilliseconds)) { return $Task.GetAwaiter().GetResult() }
        }
        catch {
            return "<failed to read child stream: $($_.Exception.Message)>"
        }
        return "<child stream did not close within $TimeoutMilliseconds ms>"
    }

    foreach ($file in $suitePaths) {
        $leaf = Split-Path $file -Leaf
        $remaining = $TimeoutSeconds - [int]$watch.Elapsed.TotalSeconds
        $effectiveTimeout = if ($FileTimeoutSeconds -gt 0) { $FileTimeoutSeconds } else { $perFileAuto }
        $effectiveTimeout = [int][Math]::Min($effectiveTimeout, [Math]::Max(30, $remaining - 15))
        $fileProgress = [ordered]@{
            file             = $leaf
            path             = $file
            status           = 'running'
            startedAt        = [DateTime]::UtcNow.ToString('o')
            elapsedMs        = -1
            fileTimeoutSeconds = $effectiveTimeout
            tests            = 0
            passed           = 0
            failed           = 0
            skipped          = 0
            reason           = ''
            cases            = @()
        }
        $progress.files += $fileProgress
        Export-ProgressFile -ProgressPath $ProgressPath -Progress $progress

        if ($remaining -le 30) {
            $fileProgress.status = 'skipped-budget'
            $fileProgress.reason = "insufficient-shard-budget remainingSeconds=$remaining"
            $fileProgress.elapsedMs = 0
            $failedFiles.Add($leaf) | Out-Null
            Export-ProgressFile -ProgressPath $ProgressPath -Progress $progress
            continue
        }

        $partXml = Join-Path $progressPartsRoot ("$leaf.$([guid]::NewGuid().ToString('N')).xml")
        $fileWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Child', '-SuiteFile', $file, '-RepoRoot', $RepoRoot, '-ResultsPath', $partXml, '-ShardIndex', [string]$ShardIndex, '-ShardCount', [string]$ShardCount)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        if ($plan.Tag) { [void]$startInfo.ArgumentList.Add('-Tag'); [void]$startInfo.ArgumentList.Add([string]$plan.Tag) }
        if ($plan.ExcludeTag) { [void]$startInfo.ArgumentList.Add('-ExcludeTag'); [void]$startInfo.ArgumentList.Add([string]$plan.ExcludeTag) }
        $null = $startInfo.Environment.Remove('RUNNER_TRACKING_ID')

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = $false
        if (-not $process.WaitForExit($effectiveTimeout * 1000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            try { [void]$process.WaitForExit(5000) } catch { }
        }
        $fileOutput = Receive-BoundedStream -Task $stdoutTask
        $fileError = Receive-BoundedStream -Task $stderrTask
        $effectiveExit = if ($timedOut) { 124 } elseif ($process.HasExited) { $process.ExitCode } else { 125 }
        $process.Dispose()
        $fileWatch.Stop()

        if ($fileOutput) { Write-Host $fileOutput }
        if ($fileError) { Write-Host $fileError }

        $fileProgress.elapsedMs = [int]$fileWatch.ElapsedMilliseconds
        if (Test-Path -LiteralPath $partXml -PathType Leaf) {
            $null = $suiteXmlPaths.Add($partXml)
            $summary = Read-PesterXmlSummary -Path $partXml
            $fileProgress.tests = $summary.tests
            $fileProgress.passed = $summary.passed
            $fileProgress.failed = $summary.failed
            $fileProgress.skipped = $summary.skipped
            $fileProgress.cases = @($summary.cases)
        }
        if ($timedOut) {
            $fileProgress.status = 'timeout'
            $fileProgress.reason = "file exceeded ${effectiveTimeout}s and was killed"
            # Phase 8 C1: a file timeout must surface as an explicit file line,
            # never as a parameter-binding error when no suite XML was written.
            if (-not $firstFailureMessage) { $firstFailureMessage = "file timed out ($leaf, ${effectiveTimeout}s)" }
        }
        elseif ($effectiveExit -ne 0) {
            $fileProgress.status = 'failed'
            $fileProgress.reason = "exit=$effectiveExit"
            if (-not $firstFailureMessage) {
                $failedNames = @($fileProgress.cases | Where-Object { $_.result -eq 'Failure' -or $_.result -eq 'Error' } | ForEach-Object { [string]$_.name } | Select-Object -First 5)
                $firstFailureMessage = "file failed: $leaf ($($failedNames -join '; '))"
            }
        }
        else {
            $fileProgress.status = 'passed'
        }
        if ($fileProgress.status -ne 'passed') { $failedFiles.Add($leaf) | Out-Null }
        Export-ProgressFile -ProgressPath $ProgressPath -Progress $progress
    }

    Merge-PesterXml -SuiteXmlPaths @($suiteXmlPaths) -OutputPath $ResultsPath
    if (-not (Test-Path $ResultsPath)) {
        if ($firstFailureMessage) { throw "Windows Pester suite produced no suite XML. $firstFailureMessage" }
        throw 'Windows Pester suite did not produce windows-test-results.xml.'
    }

    if ($failedFiles.Count -gt 0) {
        $progress['failedFiles'] = @($failedFiles)
        Export-ProgressFile -ProgressPath $ProgressPath -Progress $progress
        throw "Windows Pester suite reported failures: first=$firstFailureMessage files=$($failedFiles -join ',')"
    }
}

$RepoRoot = Resolve-FullPath -Path $RepoRoot
$ResultsPath = Resolve-FullPath -Path $ResultsPath -BasePath $RepoRoot
if (-not [string]::IsNullOrWhiteSpace($ProgressPath)) {
    $ProgressPath = Resolve-FullPath -Path $ProgressPath -BasePath $RepoRoot
}
$resultsDirectory = Split-Path $ResultsPath -Parent

if ($resultsDirectory -and -not (Test-Path $resultsDirectory)) {
    New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
}

if ($SuiteFile) {
    $resolvedSuite = Resolve-FullPath -Path $SuiteFile -BasePath $RepoRoot
    # Grandchild mode: Tag/ExcludeTag arrive as plain parameters.
    exit (Invoke-WindowsPesterSuiteSingleFile -RepoRoot $RepoRoot -SuiteFile $resolvedSuite -ResultsPath $ResultsPath -Tag ([string]$Tag) -ExcludeTag ([string]$ExcludeTag))
}

if ($Child) {
    Invoke-WindowsPesterSuite -RepoRoot $RepoRoot -ResultsPath $ResultsPath `
        -TimeoutSeconds $TimeoutSeconds -FileTimeoutSeconds $FileTimeoutSeconds -ProgressPath $ProgressPath `
        -ShardIndex $ShardIndex -ShardCount $ShardCount
    return
}

Invoke-IsolatedPesterHost `
    -ScriptPath $MyInvocation.MyCommand.Path `
    -RepoRoot $RepoRoot `
    -ResultsPath $ResultsPath `
    -ProgressPath $ProgressPath `
    -TimeoutSeconds $TimeoutSeconds `
    -FileTimeoutSeconds $FileTimeoutSeconds `
    -ShardIndex $ShardIndex `
    -ShardCount $ShardCount

if (-not (Test-Path $ResultsPath)) {
    throw 'Windows Pester suite did not produce windows-test-results.xml.'
}
