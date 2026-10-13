# Phase 8e E0.2: deterministic H1 probe.
#
# Compiles the real Windows native host source and pings it twice from a real
# Windows PowerShell 5.1 child:
#   - control: the console input encoding has no preamble (OEM code page);
#   - preamble: the child sets [Console]::InputEncoding to UTF8Encoding($true),
#     so .NET Framework's Process.StandardInput StreamWriter writes EF BB BF on
#     the host's stdin before the first frame (the H1 trigger).
#
# Expected red with the cbe99261 source: the preamble ping ends as
# health-check-exited with exit code 0 (the host reads EF BB BF 22 as the frame
# length). With the Phase 8e E0.1 diagnosis the host log names the literal
# header (header=efbbbf22); with the E0.3 fix the BOM is discarded once per
# process and the ping answers pong.
#
# Read-only for the machine: it compiles into WorkDir, starts the candidate and
# reads the host log. It never registers anything with Firefox.
[CmdletBinding()]
param(
    # Source compiled when -ExecutablePath is not provided.
    [string]$SourcePath = '',
    # Existing executable to ping instead of compiling (installed host).
    [string]$ExecutablePath = '',
    # The ping module (NativeHost.Build.ps1) used by the child for the real
    # Test-OpenPathNativeHostExecutable.
    [string]$PingModulePath = '',
    [string]$WorkDir = '',
    [string]$JsonOut = ''
)

$ErrorActionPreference = 'Stop'
$probeRoot = if ($WorkDir) { $WorkDir } else { Join-Path ([IO.Path]::GetTempPath()) ('openpath-h1-probe-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null

# The probe lives at tests/e2e/ci: three levels below the repository root.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $SourcePath -and -not $ExecutablePath) {
    $SourcePath = Join-Path $repoRoot 'windows\native-host\OpenPathNativeHost.cs'
}
if (-not $PingModulePath) {
    $PingModulePath = Join-Path $repoRoot 'windows\lib\internal\NativeHost.Build.ps1'
}
if (-not (Test-Path -LiteralPath $PingModulePath -PathType Leaf)) {
    throw "ping module not found: $PingModulePath"
}
. $PingModulePath

if (-not $ExecutablePath) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "source not found: $SourcePath"
    }
    $compilerPath = Get-OpenPathNativeHostCompilerPath
    if (-not $compilerPath) { throw 'the in-box .NET Framework compiler is not available' }
    $ExecutablePath = Join-Path $probeRoot 'OpenPath-NativeHost.probe.exe'
    $compilation = Invoke-OpenPathNativeHostCompilation -SourcePath $SourcePath -OutputPath $ExecutablePath -CompilerPath $compilerPath
    if (-not $compilation.Success) {
        throw "compilation failed: $($compilation.Output)"
    }
}

$childScriptPath = Join-Path $probeRoot 'ping-with-preamble.ps1'
$childScript = @'
param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$PingModulePath,
    # 'true'/'false' as text: powershell.exe -File binds arguments as strings,
    # where a [bool] parameter would reject (or silently misparse) 'False'.
    [string]$WithPreamble = 'false',
    [string]$ResultPath = ''
)

$withPreambleBool = ([string]$WithPreamble).Trim().ToLowerInvariant() -eq 'true'
$encodingError = ''
try {
    # Real Windows PowerShell 5.1 (.NET Framework): the console input encoding
    # decides the preamble Process.StandardInput writes on the host's stdin.
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($withPreambleBool)
}
catch {
    $encodingError = [string]$_
}

. $PingModulePath
$health = Test-OpenPathNativeHostExecutable -ExecutablePath $ExecutablePath -TimeoutSeconds 20
$record = [ordered]@{
    withPreamble   = $withPreambleBool
    healthy        = [bool]$health.Healthy
    protocolVersion = [int]$health.ProtocolVersion
    error          = [string]$health.Error
    exitCode       = $health.ExitCode
    hasExited      = [bool]$health.HasExited
    pid            = [int]$health.Pid
    elapsedMs      = [int]$health.ElapsedMs
    stderr         = [string]$health.Stderr
    stdinCodePage  = [int]$health.StdinCodePage
    stdinPreambleBytes = [string]$health.StdinPreambleBytes
    encodingError  = $encodingError
}
if ($ResultPath) {
    [IO.File]::WriteAllText($ResultPath, ($record | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
Write-Output ($record | ConvertTo-Json -Depth 6 -Compress)
'@
[IO.File]::WriteAllText($childScriptPath, $childScript, [Text.UTF8Encoding]::new($false))

$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { throw 'Windows PowerShell 5.1 not found' }

$hostLogPath = ''
$base = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
if (-not [string]::IsNullOrWhiteSpace($base)) {
    $hostLogPath = Join-Path (Join-Path $base 'OpenPath') 'native-host.log'
}

function Invoke-PreambleProbeChild {
    param([bool]$WithPreamble)

    $resultPath = Join-Path $probeRoot ("ping-{0}.json" -f ($(if ($WithPreamble) { 'preamble' } else { 'control' })))
    $logSizeBefore = -1
    if ($hostLogPath -and (Test-Path -LiteralPath $hostLogPath -PathType Leaf)) {
        $logSizeBefore = (Get-Item -LiteralPath $hostLogPath).Length
    }
    $flagValue = if ($WithPreamble) { 'true' } else { 'false' }
    $output = & $powershellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childScriptPath -ExecutablePath $ExecutablePath -PingModulePath $PingModulePath -WithPreamble $flagValue -ResultPath $resultPath 2>&1
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "the preamble probe child did not produce a result ($(($output | Out-String).Trim()))"
    }
    $record = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $stopLines = @()
    if ($hostLogPath -and (Test-Path -LiteralPath $hostLogPath -PathType Leaf)) {
        Start-Sleep -Milliseconds 200
        $text = [IO.File]::ReadAllText($hostLogPath)
        $tail = if ($logSizeBefore -gt 0 -and $text.Length -gt $logSizeBefore) { $text.Substring($logSizeBefore) } else { $text }
        $stopLines = @($tail -split "`r?`n" | Where-Object { $_ -match 'Native host stdin read stopped:' })
    }
    return [pscustomobject]@{ record = $record; stopLines = @($stopLines) }
}

$control = Invoke-PreambleProbeChild -WithPreamble $false
$preamble = Invoke-PreambleProbeChild -WithPreamble $true

$report = [ordered]@{
    schemaVersion  = 1
    executablePath = $ExecutablePath
    sourcePath     = $SourcePath
    hostLogPath    = $hostLogPath
    control        = $control.record
    withPreamble   = $preamble.record
    hostStopLines  = @($preamble.stopLines)
    capturedAtUtc  = [DateTime]::UtcNow.ToString('o')
}
$reportJson = $report | ConvertTo-Json -Depth 8
if ($JsonOut) {
    [IO.File]::WriteAllText($JsonOut, $reportJson, [Text.UTF8Encoding]::new($false))
}
Write-Output $reportJson
