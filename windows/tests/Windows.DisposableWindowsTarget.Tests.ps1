Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\DisposableWindowsTarget.psm1') -Force

Describe 'Disposable Windows target boundary' {
    It 'rejects observations for another phase or run' {
        $path = Join-Path $TestDrive 'observation.json'
        @{ runId = 'run-a'; runAttempt = 1; scenarioId = 'scenario-a'; phase = 'observe'; correlationNonce = ('a' * 32); status = 'passed'; observation = @{ bootId = 'boot-1' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        { Read-OpenPathDisposableWindowsObservation -Path $path -Mode AfterReboot -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -ExpectedNonce ('a' * 32) } |
            Should -Throw '*correlation-mismatch*'
    }

    It 'accepts only a passed observation with a body' {
        $path = Join-Path $TestDrive 'observation.json'
        @{ runId = 'run-a'; runAttempt = 1; scenarioId = 'scenario-a'; phase = 'observe'; correlationNonce = ('a' * 32); status = 'passed'; observation = @{ bootId = 'boot-1' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        (Read-OpenPathDisposableWindowsObservation -Path $path -Mode Observe -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -ExpectedNonce ('a' * 32)).observation.bootId |
            Should -Be 'boot-1'
    }

    It 'runs the external adapter with a space-safe PowerShell path and validates its fresh output' {
        $artifacts = Join-Path $TestDrive 'adapter artifacts'
        New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
        $payload = Join-Path $artifacts 'run-a/1/scenario-a/controller payload.json'
        $fixture = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tests\e2e\fixtures\fake-windows-desktop-controller.ps1')).Path
        { Invoke-OpenPathDisposableWindowsController -Command $fixture -Mode Observe -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -PayloadPath (Join-Path $artifacts 'outside.json') -ArtifactsRoot $artifacts -TimeoutSeconds 30 } |
            Should -Throw '*payload-outside-scenario*'
        $result = Invoke-OpenPathDisposableWindowsController -Command $fixture -Mode Observe -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -PayloadPath $payload -ArtifactsRoot $artifacts -TimeoutSeconds 30
        $result.status | Should -Be 'completed'
        (Test-Path -LiteralPath $result.outputPath -PathType Leaf) | Should -BeTrue
        $result.correlationNonce | Should -Match '^[0-9a-f]{32}$'
        (Read-OpenPathDisposableWindowsObservation -Path $result.outputPath -Mode Observe -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -ExpectedNonce $result.correlationNonce).status | Should -Be 'passed'
    }

    It 'transports the exact artifact identity into the controller payload' {
        $artifacts = Join-Path $TestDrive 'identity artifacts'
        New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
        $payload = Join-Path $artifacts 'run-a/1/scenario-a/payload.json'
        $template = Join-Path $artifacts 'template.exe'
        $personalized = Join-Path $artifacts 'personalized.exe'
        Set-Content -LiteralPath $template -Value 'template-bytes' -Encoding ASCII
        Set-Content -LiteralPath $personalized -Value 'personalized-bytes' -Encoding ASCII
        $fixture = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tests\e2e\fixtures\fake-windows-desktop-controller.ps1')).Path
        $result = Invoke-OpenPathDisposableWindowsController -Command $fixture -Mode Prepare -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -PayloadPath $payload -ArtifactsRoot $artifacts -TemplatePath $template -PersonalizedExePath $personalized -TimeoutSeconds 30
        $result.status | Should -Be 'completed'
        $written = Get-Content -LiteralPath $payload -Raw | ConvertFrom-Json
        $written.templatePath | Should -Be (Resolve-Path -LiteralPath $template).Path
        $written.personalizedExePath | Should -Be (Resolve-Path -LiteralPath $personalized).Path
        $written.templateSha256 | Should -Be (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant()
        $written.personalizedExeSha256 | Should -Be (Get-FileHash -LiteralPath $personalized -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'propagates a correlated blocked phase and rejects a bare blocked exit code' {
        $artifacts = Join-Path $TestDrive 'blocked propagation'
        New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
        $payload = Join-Path $artifacts 'run-a/1/scenario-a/payload.json'
        $blockedController = Join-Path $artifacts 'blocked-controller.ps1'
        @'
param([string]$OutputPath, [string]$Mode, [string]$RunId, [int]$RunAttempt, [string]$ScenarioId, [string]$CorrelationNonce)
$phase = switch ($Mode) { 'Prepare' { 'prepare' } 'Observe' { 'observe' } 'AfterReboot' { 'afterReboot' } 'Cleanup' { 'cleanup' } }
$observation = [ordered]@{ status = 'blocked'; runId = $RunId; runAttempt = $RunAttempt; scenarioId = $ScenarioId; phase = $phase; correlationNonce = $CorrelationNonce }
[IO.File]::WriteAllText($OutputPath, ($observation | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
exit 2
'@ | Set-Content -LiteralPath $blockedController -Encoding UTF8
        $blocked = Invoke-OpenPathDisposableWindowsController -Command $blockedController -Mode Prepare -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -PayloadPath $payload -ArtifactsRoot $artifacts -TimeoutSeconds 10
        $blocked.status | Should -Be 'blocked'
        $blocked.code | Should -Be 'BLOCKED_PLATFORM_VALIDATION'
        $bare = Join-Path $artifacts 'bare-controller.ps1'
        'exit 2' | Set-Content -LiteralPath $bare -Encoding UTF8
        { Invoke-OpenPathDisposableWindowsController -Command $bare -Mode Prepare -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -PayloadPath $payload -ArtifactsRoot $artifacts -TimeoutSeconds 10 } |
            Should -Throw '*controller-exit-2*'
    }

    It 'returns blocked for a missing controller and rejects a zero-exit controller without output' {
        $artifacts = Join-Path $TestDrive 'blocked artifacts'
        New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
        $payload = Join-Path $artifacts 'run-a/1/scenario-a/payload.json'
        $missing = Join-Path $artifacts 'missing-controller.ps1'
        $blocked = Invoke-OpenPathDisposableWindowsController -Command $missing -Mode Prepare -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -PayloadPath $payload -ArtifactsRoot $artifacts -TimeoutSeconds 1
        $blocked.status | Should -Be 'blocked'
        $empty = Join-Path $artifacts 'empty-controller.ps1'
        'param([string]$OutputPath)' | Set-Content -LiteralPath $empty -Encoding UTF8
        { Invoke-OpenPathDisposableWindowsController -Command $empty -Mode Prepare -RunId run-a -RunAttempt 1 -ScenarioId scenario-a -PayloadPath $payload -ArtifactsRoot $artifacts -TimeoutSeconds 10 } | Should -Throw '*observation-missing*'
    }

    It 'runs Cleanup in finally when Observe fails in the four-scenario suite' {
        $artifacts = Join-Path $TestDrive 'suite artifacts'
        New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
        $template = Join-Path $artifacts 'template.exe'
        $personalized = Join-Path $artifacts 'personalized.exe'
        Set-Content -LiteralPath $template -Value 'template' -Encoding ASCII
        Set-Content -LiteralPath $personalized -Value 'personalized' -Encoding ASCII
        $controller = Join-Path $artifacts 'failing-controller.ps1'
        @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$Mode,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][int]$RunAttempt,
    [Parameter(Mandatory)][string]$ScenarioId,
    [Parameter(Mandatory)][string]$CorrelationNonce
)
if ($Mode -eq 'Observe') { exit 7 }
$phase = switch ($Mode) { 'Prepare' { 'prepare' } 'AfterReboot' { 'afterReboot' } 'Cleanup' { 'cleanup' } default { throw 'invalid-mode' } }
$observation = [ordered]@{ status = 'passed'; runId = $RunId; runAttempt = $RunAttempt; scenarioId = $ScenarioId; phase = $phase; correlationNonce = $CorrelationNonce; observation = [ordered]@{ synthetic = $true } }
[IO.File]::WriteAllText($OutputPath, ($observation | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
exit 0
'@ | Set-Content -LiteralPath $controller -Encoding UTF8
        $suite = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-desktop-survival-suite.ps1')).Path
        $hostPath = (Get-Command pwsh -ErrorAction Stop).Source
        & $hostPath -NoProfile -File $suite -SuiteKind DesktopSurvival -RunId run-suite -RunAttempt 1 -ArtifactsRoot $artifacts -TemplatePath $template -PersonalizedExePath $personalized -ControllerCommand $controller
        $LASTEXITCODE | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $artifacts 'run-suite/1') -Filter 'cleanup.json' -File -Recurse) | Should -HaveCount 4
    }

    It 'keeps the suite blocked when the controller reports a correlated blocked phase' {
        $artifacts = Join-Path $TestDrive 'suite blocked artifacts'
        New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
        $template = Join-Path $artifacts 'template.exe'
        $personalized = Join-Path $artifacts 'personalized.exe'
        Set-Content -LiteralPath $template -Value 'template' -Encoding ASCII
        Set-Content -LiteralPath $personalized -Value 'personalized' -Encoding ASCII
        $controller = Join-Path $artifacts 'blocked-controller.ps1'
        @'
param([string]$OutputPath, [string]$Mode, [string]$RunId, [int]$RunAttempt, [string]$ScenarioId, [string]$CorrelationNonce)
$phase = switch ($Mode) { 'Prepare' { 'prepare' } 'Observe' { 'observe' } 'AfterReboot' { 'afterReboot' } 'Cleanup' { 'cleanup' } }
$observation = [ordered]@{ status = 'blocked'; runId = $RunId; runAttempt = $RunAttempt; scenarioId = $ScenarioId; phase = $phase; correlationNonce = $CorrelationNonce }
[IO.File]::WriteAllText($OutputPath, ($observation | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
exit 2
'@ | Set-Content -LiteralPath $controller -Encoding UTF8
        $suite = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-desktop-survival-suite.ps1')).Path
        $hostPath = (Get-Command pwsh -ErrorAction Stop).Source
        & $hostPath -NoProfile -File $suite -SuiteKind DesktopSurvival -RunId run-blocked -RunAttempt 1 -ArtifactsRoot $artifacts -TemplatePath $template -PersonalizedExePath $personalized -ControllerCommand $controller
        $LASTEXITCODE | Should -Be 2
        $prepareFiles = @(Get-ChildItem -LiteralPath (Join-Path $artifacts 'run-blocked/1') -Filter 'prepare.json' -File -Recurse)
        $prepareFiles.Count | Should -Be 4
        foreach ($phaseFile in $prepareFiles) {
            (Get-Content -LiteralPath $phaseFile.FullName -Raw | ConvertFrom-Json).status | Should -Be 'blocked'
        }
    }
}
