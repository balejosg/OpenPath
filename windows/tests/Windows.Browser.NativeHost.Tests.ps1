# OpenPath Windows browser native host tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.psm1" -Force -Global -ErrorAction Stop

Describe "Browser Module - Native Host" {
    BeforeAll {
        $browserModulePath = Join-Path (Join-Path $PSScriptRoot ".." "lib") "Browser.psm1"
        Import-Module $browserModulePath -Force -Global -ErrorAction Stop
    }

    Context "Request setup state projection" {
        BeforeAll {
            $requestSetupModulePath = Join-Path $PSScriptRoot ".." "lib" "RequestSetup.State.psm1"
            Import-Module $requestSetupModulePath -Force -Global -ErrorAction Stop
        }

        It "Projects complete request setup from config as ready" {
            $config = [PSCustomObject]@{
                apiUrl = "https://school.example/"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
                machineName = "lab-pc-01"
                version = "test-version"
            }

            $state = Get-OpenPathRequestSetupState -Config $config

            $state.Status | Should -Be "ready"
            $state.Ready | Should -BeTrue
            $state.RequestApiUrl | Should -Be "https://school.example"
            $state.MachineToken | Should -Be "machine-token-123"
            $state.ClassroomId | Should -Be "classroom-123"
            $state.ApiUrlConfigured | Should -BeTrue
            $state.WhitelistTokenConfigured | Should -BeTrue
            $state.ClassroomConfigured | Should -BeTrue
        }

        It "Projects missing request fields as incomplete without changing public semantics" {
            $cases = @(
                @{
                    Name = "missing api"
                    Config = [PSCustomObject]@{
                        whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                        classroomId = "classroom-123"
                    }
                    Field = "apiUrl"
                },
                @{
                    Name = "invalid whitelist"
                    Config = [PSCustomObject]@{
                        apiUrl = "https://school.example"
                        whitelistUrl = "https://school.example/not-tokenized.txt"
                        classroomId = "classroom-123"
                    }
                    Field = "whitelistUrl"
                },
                @{
                    Name = "missing classroom"
                    Config = [PSCustomObject]@{
                        apiUrl = "https://school.example"
                        whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                    }
                    Field = "classroom"
                }
            )

            foreach ($case in $cases) {
                $state = Get-OpenPathRequestSetupState -Config $case.Config

                $state.Status | Should -Be "incomplete" -Because $case.Name
                $state.Ready | Should -BeFalse -Because $case.Name
                @($state.MissingFields) | Should -Contain $case.Field -Because $case.Name
            }
        }

        It "Projects configs without request setup intent as not requested" {
            $state = Get-OpenPathRequestSetupState -Config ([PSCustomObject]@{
                    version = "test-version"
                })

            $state.Status | Should -Be "not_requested"
            $state.Ready | Should -BeFalse
            $state.ApiUrlConfigured | Should -BeFalse
            $state.WhitelistTokenConfigured | Should -BeFalse
            $state.ClassroomConfigured | Should -BeFalse
            $state.DiagnosticMessage | Should -Be "OpenPath request setup was not requested."
        }

        It "Builds normalized Firefox native host state JSON payloads" {
            $config = [PSCustomObject]@{
                apiUrl = "https://school.example/"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroom = "group-a"
                classroomId = "classroom-123"
                version = "test-version"
            }

            $nativeState = New-OpenPathRequestSetupNativeHostState `
                -Config $config `
                -MachineName "lab-pc-01" `
                -SyncedAt "2026-05-04T00:00:00.0000000Z"

            $nativeState.machineName | Should -Be "lab-pc-01"
            $nativeState.apiUrl | Should -Be "https://school.example"
            $nativeState.requestApiUrl | Should -Be "https://school.example"
            $nativeState.whitelistUrl | Should -Be "https://school.example/w/machine-token-123/whitelist.txt"
            $nativeState.classroom | Should -Be "group-a"
            $nativeState.classroomId | Should -Be "classroom-123"
            $nativeState.version | Should -Be "test-version"
            $nativeState.syncedAt | Should -Be "2026-05-04T00:00:00.0000000Z"
        }
    }

    Context "Native host registration" {
        It "Serves request config from the staged native directory without reading locked agent internals" {
            $repoWindowsRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-host-test-" + [Guid]::NewGuid().ToString("N"))
            $nativeRoot = Join-Path $tempRoot "browser-extension\firefox\native"
            New-Item -ItemType Directory -Path $nativeRoot -Force | Out-Null

            try {
                . (Join-Path $repoWindowsRoot "lib\internal\NativeHost.ArtifactCatalog.ps1")
                $nativeFiles = @(Get-OpenPathNativeHostArtifactNames)
                $nativeFiles | Should -Contain "RuntimeDependency.Protocol.ps1"

                foreach ($nativeFile in $nativeFiles) {
                    $sourcePath = Join-Path $repoWindowsRoot "scripts\$nativeFile"
                    if (-not (Test-Path $sourcePath)) {
                        $sourcePath = Join-Path $repoWindowsRoot "lib\internal\$nativeFile"
                    }
                    if (-not (Test-Path $sourcePath)) {
                        $sourcePath = Join-Path $repoWindowsRoot "lib\$nativeFile"
                    }

                    Copy-Item $sourcePath -Destination (Join-Path $nativeRoot $nativeFile) -Force
                }

                @{
                    machineName = "lab-pc-01"
                    apiUrl = "https://school.example"
                    requestApiUrl = "https://school.example"
                    whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                    version = "test-version"
                } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $nativeRoot "native-state.json") -Encoding UTF8

                $nativeScriptPath = Join-Path $nativeRoot "OpenPath-NativeHost.ps1"
                $processStart = [System.Diagnostics.ProcessStartInfo]::new()
                $processStart.FileName = (Get-Process -Id $PID).Path
                $processStart.ArgumentList.Add("-NoProfile")
                $processStart.ArgumentList.Add("-ExecutionPolicy")
                $processStart.ArgumentList.Add("Bypass")
                $processStart.ArgumentList.Add("-File")
                $processStart.ArgumentList.Add($nativeScriptPath)
                $processStart.RedirectStandardInput = $true
                $processStart.RedirectStandardOutput = $true
                $processStart.RedirectStandardError = $true
                $processStart.UseShellExecute = $false

                function Read-NativeHostProcessBytes {
                    param(
                        [Parameter(Mandatory = $true)]
                        [System.IO.Stream]$Stream,

                        [Parameter(Mandatory = $true)]
                        [int]$Count,

                        [Parameter(Mandatory = $true)]
                        [string]$Description
                    )

                    $buffer = New-Object byte[] $Count
                    $offset = 0
                    while ($offset -lt $Count) {
                        $readTask = $Stream.ReadAsync($buffer, $offset, $Count - $offset)
                        if (-not $readTask.Wait([TimeSpan]::FromSeconds(5))) {
                            throw "Timed out reading $Description from native host"
                        }

                        $chunkSize = $readTask.Result
                        if ($chunkSize -le 0) {
                            throw "Native host stdout closed while reading $Description"
                        }

                        $offset += $chunkSize
                    }

                    return $buffer
                }

                $process = [System.Diagnostics.Process]::Start($processStart)
                $stderrTask = $process.StandardError.ReadToEndAsync()
                try {
                    $messageJson = (@{ action = "get-config" } | ConvertTo-Json -Compress)
                    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($messageJson)
                    $lengthBytes = [System.BitConverter]::GetBytes([int]$messageBytes.Length)
                    $process.StandardInput.BaseStream.Write($lengthBytes, 0, $lengthBytes.Length)
                    $process.StandardInput.BaseStream.Write($messageBytes, 0, $messageBytes.Length)
                    $process.StandardInput.BaseStream.Flush()
                    $process.StandardInput.Close()

                    $responseLengthBytes = Read-NativeHostProcessBytes `
                        -Stream $process.StandardOutput.BaseStream `
                        -Count 4 `
                        -Description "response length"
                    $responseLength = [System.BitConverter]::ToInt32($responseLengthBytes, 0)
                    if ($responseLength -le 0 -or $responseLength -gt 1MB) {
                        throw "Native host returned invalid response length: $responseLength"
                    }

                    $responseBytes = Read-NativeHostProcessBytes `
                        -Stream $process.StandardOutput.BaseStream `
                        -Count $responseLength `
                        -Description "response body"
                    $response = [System.Text.Encoding]::UTF8.GetString($responseBytes) | ConvertFrom-Json
                    $response.success | Should -BeTrue
                    $response.requestApiUrl | Should -Be "https://school.example"
                    $response.hostname | Should -Be "lab-pc-01"
                    $response.machineToken | Should -Be "machine-token-123"
                }
                finally {
                    if ($null -ne $process) {
                        $nativeHostExited = $process.WaitForExit(5000)
                        if (-not $nativeHostExited) {
                            try {
                                $process.Kill($true)
                            }
                            catch {
                                try {
                                    $process.Kill()
                                }
                                catch {
                                    # The process may have exited between WaitForExit and Kill.
                                }
                            }

                            $null = $process.WaitForExit(5000)
                        }

                        if ($null -ne $stderrTask -and $stderrTask.Wait(5000) -and $stderrTask.Result) {
                            Write-Host ("Native host stderr: {0}" -f $stderrTask.Result)
                        }

                        $process.Dispose()

                        if (-not $nativeHostExited) {
                            throw "Native host process did not exit after stdin closed"
                        }
                    }
                }
            }
            finally {
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Requires complete request setup before native host registration or state sync" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $nativeHostContent = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                'Import-Module "$PSScriptRoot\RequestSetup.State.psm1"',
                'function Get-OpenPathFirefoxNativeHostRequestSetupState',
                'function Test-OpenPathFirefoxNativeHostRequestSetupComplete',
                'Get-OpenPathFirefoxNativeHostRequestSetupState -Config $Config',
                'Get-OpenPathRequestSetupState -Config $Config',
                '$requestSetupState.DiagnosticMessage',
                'Unregister-OpenPathFirefoxNativeHost | Out-Null',
                'skipping native host registration'
            )
        }

        It "Stores classroom identity in native host state for request diagnostics" {
            $requestSetupModulePath = Join-Path $PSScriptRoot ".." "lib" "RequestSetup.State.psm1"
            $requestSetupContent = Get-Content $requestSetupModulePath -Raw

            Assert-ContentContainsAll -Content $requestSetupContent -Needles @(
                'New-OpenPathRequestSetupNativeHostState',
                'classroom = [string]$state.Classroom',
                'classroomId = [string]$state.ClassroomId'
            )
        }

        It "Accepts only complete classroom request setup for native host registration" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            Import-Module $nativeHostModulePath -Force -Global -ErrorAction Stop

            $completeConfig = [PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }
            $missingWhitelist = [PSCustomObject]@{
                apiUrl = "https://school.example"
                classroomId = "classroom-123"
            }
            $missingClassroom = [PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
            }
            $invalidApi = [PSCustomObject]@{
                apiUrl = "school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }

            Test-OpenPathFirefoxNativeHostRequestSetupComplete -Config $completeConfig | Should -BeTrue
            Test-OpenPathFirefoxNativeHostRequestSetupComplete -Config $missingWhitelist | Should -BeFalse
            Test-OpenPathFirefoxNativeHostRequestSetupComplete -Config $missingClassroom | Should -BeFalse
            Test-OpenPathFirefoxNativeHostRequestSetupComplete -Config $invalidApi | Should -BeFalse
        }

        It "Re-stages native host artifacts before writing the Firefox manifest" {
            $browserModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.psm1"
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $artifactCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.ArtifactCatalog.ps1"
            $browserContent = Get-Content $browserModulePath -Raw
            $nativeHostContent = Get-Content $nativeHostModulePath -Raw

            . $artifactCatalogPath
            $artifactNames = @(Get-OpenPathNativeHostArtifactNames)
            $artifactNames | Should -Contain 'OpenPath-NativeHost.ps1'
            $artifactNames | Should -Contain 'OpenPath-NativeHost.cmd'
            $artifactNames | Should -Contain 'NativeHost.Actions.ps1'
            $artifactNames | Should -Contain 'RuntimeDependency.Protocol.ps1'

            $sourceRoot = Join-Path $TestDrive 'scripts'
            $nativeRoot = Join-Path $TestDrive 'native'
            $libRoot = Join-Path $TestDrive 'lib'
            $internalRoot = Join-Path $libRoot 'internal'
            New-Item -ItemType Directory -Path $sourceRoot, $nativeRoot, $libRoot, $internalRoot -Force | Out-Null

            $candidateRoots = @(Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $sourceRoot -NativeRoot $nativeRoot)
            $candidateRoots | Should -Contain $sourceRoot
            $candidateRoots | Should -Contain $libRoot
            $candidateRoots | Should -Contain $internalRoot
            $candidateRoots | Should -Contain $nativeRoot

            New-Item -ItemType File -Path (Join-Path $sourceRoot 'OpenPath-NativeHost.ps1') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $internalRoot 'NativeHost.Actions.ps1') -Force | Out-Null
            $resolution = Resolve-OpenPathNativeHostArtifactSources `
                -ArtifactNames @('OpenPath-NativeHost.ps1', 'NativeHost.Actions.ps1', 'missing.ps1') `
                -CandidateRoots $candidateRoots
            $resolution.Sources['OpenPath-NativeHost.ps1'] | Should -Be $sourceRoot
            $resolution.Sources['NativeHost.Actions.ps1'] | Should -Be $internalRoot
            @($resolution.Missing) | Should -Contain 'missing.ps1'

            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                '. (Join-Path $PSScriptRoot ''internal\NativeHost.ArtifactCatalog.ps1'')',
                'function Sync-OpenPathFirefoxNativeHostArtifacts',
                'Get-OpenPathNativeHostArtifactNames',
                'Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $SourceRoot -NativeRoot $nativeRoot',
                'Resolve-OpenPathNativeHostArtifactSources -ArtifactNames $artifactNames -CandidateRoots $candidateRoots',
                '[string]::Equals($sourcePath, $destinationPath, [System.StringComparison]::OrdinalIgnoreCase)'
            )
            $nativeFilesForRuntimeDependency = @(Get-OpenPathNativeHostArtifactNames)
            $nativeFilesForRuntimeDependency | Should -Contain 'RuntimeDependency.Protocol.ps1'

            Assert-ContentContainsAll -Content $browserContent -Needles @(
                'function Sync-OpenPathFirefoxNativeHostArtifacts',
                'Browser.FirefoxNativeHost\Sync-OpenPathFirefoxNativeHostArtifacts -SourceRoot $SourceRoot'
            )

            $nativeActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Shared.ps1") -Raw)
            Assert-ContentContainsAll -Content $nativeActionsContent -Needles @(
                'Import-NativeHostRequestSetupStateModule',
                'RequestSetup.State.psm1',
                'Get-OpenPathRequestSetupState -Config $State',
                'RequestSetup.State.psm1 is required for native host request setup interpretation.',
                'Import-NativeHostCaptivePortalModule',
                'lib\CaptivePortal.psm1',
                'Test-OpenPathCaptivePortalState',
                '$requestSetupState.MachineToken'
            )
        }

        It "Native host script prefers staged support files before locked agent internals" {
            $nativeHostScriptPath = Join-Path $PSScriptRoot ".." "scripts" "OpenPath-NativeHost.ps1"
            $nativeHostContent = Get-Content $nativeHostScriptPath -Raw

            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                'function Resolve-OpenPathNativeHostRoot',
                'function Resolve-OpenPathNativeHostSupportPath',
                '$stagedStateHelperPath = Join-Path $script:NativeRoot ''NativeHost.State.ps1''',
                '$script:OpenPathRoot = Resolve-OpenPathNativeHostRoot',
                '$script:RuntimeDependencyTaskName = ''OpenPath-RuntimeDependencyApply''',
                '$ProgressPreference = ''SilentlyContinue''',
                '$InformationPreference = ''SilentlyContinue''',
                '(Join-Path $script:NativeRoot $FileName)',
                '(Join-Path $script:OpenPathRoot "lib\internal\$FileName")',
                '$null = . (Resolve-OpenPathNativeHostSupportPath -FileName ''NativeHost.State.ps1'')',
                '$null = . (Resolve-OpenPathNativeHostSupportPath -FileName ''NativeHost.Protocol.ps1'')',
                '$null = . (Resolve-OpenPathNativeHostSupportPath -FileName ''NativeHost.Actions.ps1'')'
            )

            $legacyImportPattern = [regex]::Escape("Join-Path `$PSScriptRoot '..\lib\internal\NativeHost.State.ps1'")
            $nativeHostContent | Should -Not -Match $legacyImportPattern
        }

        It "Grants standard users read and execute access to the update task" {
            $servicesModulePath = Join-Path $PSScriptRoot ".." "lib" "Services.psm1"
            $taskHelperPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Services.TaskBuilders.ps1"
            $content = Get-Content $servicesModulePath -Raw
            $taskHelperContent = Get-Content $taskHelperPath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Grant-OpenPathTaskRunAccessToUsers',
                'GetTask($TaskName)',
                'GetSecurityDescriptor(0xF)',
                'SetSecurityDescriptor($updatedSecurityDescriptor, 0)',
                'Get-OpenPathScheduledTaskCatalog',
                '$script:UsersRunTaskAce = $script:ScheduledTaskCatalog.UsersRunTaskAce',
                'Grant-OpenPathTaskRunAccessToUsers -TaskName $updateDefinition.TaskName',
                'Grant-OpenPathTaskRunAccessToUsers -TaskName $runtimeDependencyDefinition.TaskName'
            )

            Assert-ContentContainsAll -Content $taskHelperContent -Needles @(
                'function New-OpenPathUpdateTaskDefinition',
                'Get-OpenPathScheduledTaskSpec -TaskType Update',
                '-TaskName $taskSpec.Name'
            )
        }

        It "Waits for requested update-whitelist domains to reach the native whitelist mirror" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Shared.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.RuntimeDependency.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.MessageDispatch.ps1") -Raw)

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'TaskRunner.ps1',
                'Invoke-OpenPathScheduledTask',
                '-Runner (Get-NativeHostTaskRunner)',
                '-WaitCondition {',
                'function Get-NativeHostValidDomains',
                'function Test-NativeWhitelistContainsDomains',
                'function Invoke-NativeHostSharedUpdateTrigger',
                'Global\OpenPathNativeWhitelistUpdateTrigger',
                '$script:RuntimeDependencyTaskName',
                '$triggerState = @{',
                '$triggerState[''Fallback''] = [bool]$taskResult.fallback',
                '$Message.domains',
                'Invoke-UpdateTask -Domains $domains',
                'Get-WhitelistSections',
                '1000',
                'OpenPath update task did not write expected domains'
            )
        }

        It "Delegates runtime dependency task trigger and wait behavior to TaskRunner" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Shared.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.RuntimeDependency.ps1") -Raw)

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'function Get-NativeHostTaskRunner',
                'Invoke-OpenPathScheduledTask `',
                '-TaskName $triggerState[''TaskName'']',
                '-FallbackTaskName $script:UpdateTaskName',
                '-ShouldFallback $hasRuntimeDependencyWait',
                '-TimeoutSeconds $TimeoutSeconds',
                '-WaitCondition {',
                'Test-NativeHostRuntimeDependencyQueueRequestProcessed -RequestPath $RuntimeDependencyRequestPath',
                'runtimeDependencyFallback = [bool]$taskResult.fallback',
                'updateTaskName = [string]$taskResult.taskName',
                'updateTriggerMs = [int]$taskResult.triggerMs',
                'updateWaitMs = [int]$taskResult.waitMs'
            )

            $nativeHostActionsContent | Should -Not -Match '&\s*schtasks\.exe\s*/Run'
        }

        It "Returns blocked subdomains from the native whitelist mirror" {
            $nativeStatePath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1"
            $nativeActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $stateContent = Get-Content $nativeStatePath -Raw
            $actionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Shared.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.MessageDispatch.ps1") -Raw)

            Assert-ContentContainsAll -Content $stateContent -Needles @(
                'BlockedSubdomains = @()',
                '''BLOCKED-SUBDOMAINS'' { $result.BlockedSubdomains += $trimmed }'
            )
            Assert-ContentContainsAll -Content $actionsContent -Needles @(
                'function Get-NativeHostBlockedSubdomainResponse',
                '$subdomains = @($Sections.BlockedSubdomains)',
                "action = 'get-blocked-subdomains'",
                'subdomains = $subdomains',
                "'get-blocked-subdomains' {"
            )
        }

        It "Returns allowed paths from the native whitelist mirror via get-allowed-paths action" {
            $nativeStatePath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1"
            $stateContent = Get-Content $nativeStatePath -Raw
            $actionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Shared.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.MessageDispatch.ps1") -Raw)

            # NativeHost.State.ps1 must declare and populate AllowedPaths
            Assert-ContentContainsAll -Content $stateContent -Needles @(
                'AllowedPaths = @()',
                '''ALLOWED-PATHS'' { $result.AllowedPaths += $trimmed }'
            )

            # NativeHost.Actions.Shared.ps1 must expose the response builder and dispatch must route the action
            Assert-ContentContainsAll -Content $actionsContent -Needles @(
                'function Get-NativeHostAllowedPathResponse',
                '$paths = @($Sections.AllowedPaths)',
                "action = 'get-allowed-paths'",
                'paths = $paths',
                "'get-allowed-paths' {"
            )

            # ALLOWED-PATHS must not bleed into WHITELIST entries (the section switch must route it away)
            $stateContent | Should -Match "'ALLOWED-PATHS'"
            $stateContent | Should -Not -Match "ALLOWED-PATHS.*Whitelist\s*\+="
        }

        It "Supports local runtime dependency overlay action without full URL fields" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.RuntimeDependency.ps1") -Raw)
            $runtimeDependencyProtocolPath = Join-Path $PSScriptRoot ".." "lib" "internal" "RuntimeDependency.Protocol.ps1"
            $runtimeDependencyProtocolContent = Get-Content $runtimeDependencyProtocolPath -Raw
            $runtimeDependencyQueuePath = Join-Path $PSScriptRoot ".." "lib" "internal" "RuntimeDependency.Queue.ps1"
            $runtimeDependencyQueueContent = Get-Content $runtimeDependencyQueuePath -Raw
            $runtimeDependencyOverlayPath = Join-Path $PSScriptRoot ".." "lib" "internal" "RuntimeDependency.Overlay.ps1"
            $runtimeDependencyOverlayContent = Get-Content $runtimeDependencyOverlayPath -Raw
            $installerStagingPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $installerStagingContent = Get-Content $installerStagingPath -Raw
            $updateRuntimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $updateRuntimeContent = Get-Content $updateRuntimePath -Raw

            Assert-ContentContainsAll -Content $runtimeDependencyProtocolContent -Needles @(
                '$script:OpenPathRuntimeDependencyActionAllowLocal = ''allow-local-runtime-dependency''',
                '$script:OpenPathRuntimeDependencyActionAllowLocalBatch = ''allow-local-runtime-dependency-batch''',
                '$script:OpenPathRuntimeDependencyBatchMaxEntries = 20',
                '$script:OpenPathRuntimeDependencyQueueVersion = 1',
                '$script:OpenPathRuntimeDependencyOverlayVersion = 1',
                '$script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal = ''firefox-webrequest-local'''
            )
            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'RuntimeDependency.Protocol.ps1',
                '$script:OpenPathRuntimeDependencyActionAllowLocal',
                '$script:OpenPathRuntimeDependencyActionAllowLocalBatch',
                '$script:OpenPathRuntimeDependencyBatchMaxEntries',
                'function Invoke-NativeHostLocalRuntimeDependencyAction',
                'function Invoke-NativeHostLocalRuntimeDependencyBatchAction',
                'function Get-NativeHostRuntimeDependencyQueuePath',
                'function Find-NativeHostRuntimeDependencyQueueRequest',
                'function Write-NativeHostRuntimeDependencyQueueRequest',
                'Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue',
                'Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay',
                'anchorHost',
                'dependencyHost',
                'requestType',
                'source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal',
                'Sensitive fields are not accepted',
                'reason = ''dependency-already-whitelisted''',
                'reason = ''runtime-dependency-overlay-present''',
                '-RuntimeDependencyDomains $queuedDependencyHosts',
                '-TimeoutSeconds 14',
                'queueWriteMs',
                'updateTriggerMs',
                'runtimeDependencyFastPath',
                'runtimeDependencyFallback'
            )
            Assert-ContentContainsAll -Content $runtimeDependencyQueueContent -Needles @(
                'RuntimeDependency.Protocol.ps1',
                'version = $script:OpenPathRuntimeDependencyQueueVersion',
                'source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal'
            )
            Assert-ContentContainsAll -Content $runtimeDependencyOverlayContent -Needles @(
                'RuntimeDependency.Protocol.ps1',
                'version = $script:OpenPathRuntimeDependencyOverlayVersion',
                'source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal'
            )
            Assert-ContentContainsAll -Content $installerStagingContent -Needles @(
                'Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue',
                'Set-OpenPathCapabilityStorageAcl -Path $runtimeDependencyQueuePath -Profile RuntimeDependencyQueue',
                'NativeHost.ArtifactCatalog.ps1',
                'Get-OpenPathNativeHostArtifactNames',
                'Resolve-OpenPathNativeHostArtifactSources'
            )
            Assert-ContentContainsAll -Content $updateRuntimeContent -Needles @(
                'Invoke-OpenPathRuntimeDependencyQueue',
                'Update-AcrylicHost -WhitelistedDomains $runtimeDependencyQueueSections.Whitelist',
                'function Invoke-OpenPathRuntimeDependencyFastApply',
                'Runtime dependency queue processed'
            )

            $nativeHostActionsContent | Should -Not -Match 'Write-NativeHostRuntimeDependencyOverlay'
            $nativeHostActionsContent | Should -Not -Match 'Read-NativeHostRuntimeDependencyOverlay'
            $nativeHostActionsContent | Should -Not -Match 'Update-AcrylicHost -WhitelistedDomains'
            $nativeHostActionsContent | Should -Not -Match '(?s)function Find-NativeHostRuntimeDependencyQueueRequest.*?foreach \(\$requestFile'
            $nativeHostActionsContent | Should -Not -Match '\[string\]\$Host\b'
            $nativeHostActionsContent | Should -Not -Match 'foreach \(\$host in'
            $nativeHostActionsContent | Should -Not -Match '/api/requests/auto'
        }

        It "Supports captive portal recovery without URL fields or whitelist/runtime overlay mutation" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Shared.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.CaptivePortal.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.MessageDispatch.ps1") -Raw)
            $recoveryQueueAdapterPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.CaptivePortalRecoveryQueue.ps1"
            $recoveryQueueAdapterContent = Get-Content $recoveryQueueAdapterPath -Raw
            $nativeHostRecoveryContent = "$nativeHostActionsContent`n$recoveryQueueAdapterContent"
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $scriptContent = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $nativeHostRecoveryContent -Needles @(
                'recover-captive-portal-navigation',
                'function Normalize-NativeHostCaptivePortalTriggerHost',
                'function Write-NativeHostCaptivePortalRecoveryRequest',
                'function Read-NativeHostCaptivePortalRecoveryResult',
                'function Get-NativeHostRecentCaptivePortalRecoverySuccess',
                'function Invoke-NativeHostCaptivePortalRecoveryAction',
                'NativeHost.CaptivePortalRecoveryQueue.ps1',
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryQueue',
                'Get-OpenPathCapabilityStoragePath -Name CaptivePortalRecoveryResult',
                'Global\OpenPathCaptivePortalRecoveryTrigger',
                'OpenPath-CaptivePortalRecovery',
                '[Guid]::NewGuid().ToString(''N'')',
                'operation',
                'source',
                'triggerHost',
                'portalRecoveryHosts',
                'portalState',
                'tabId',
                'createdAtUtc',
                'portalModeActive',
                'requestId',
                'recentSuccess',
                'triggerMs',
                'waitMs',
                '[int]$TimeoutSeconds = 90',
                '$boundedTimeoutSeconds = [Math]::Max(1, [Math]::Min(90, $TimeoutSeconds))',
                '-TimeoutMilliseconds ($boundedTimeoutSeconds * 1000)',
                '-TimeoutSeconds $boundedTimeoutSeconds',
                '$state -eq ''Authenticated'' -and -not $portalModeActive -and $postAuthRestored',
                '$localDnsLoopbackRestored',
                '$acrylicNormalRestored',
                '$dnsResolutionHealthy',
                '$sinkholeHealthy',
                '$markerCleared',
                'state = ''Timeout''',
                'recoveryQueueClassification'
            )
            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                'function Invoke-OpenPathCaptivePortalAuthenticatedRestore',
                'if ($state -eq ''Authenticated'')',
                'portalExitRoute = if ($protectedModeRestored) { "$Operation-authenticated" } else { "$Operation-authenticated-restore-failed" }'
            )

            $recoveryFunction = [regex]::Match(
                $nativeHostActionsContent,
                '(?s)function Invoke-NativeHostCaptivePortalRecoveryAction.*?(?=function Test-NativeWhitelistContainsDomains)'
            ).Value
            $recoveryFunction | Should -Not -Match 'Global\\OpenPathNativeWhitelistUpdateTrigger'
            $recoveryFunction | Should -Not -Match 'Invoke-UpdateTask'
            $recoveryFunction | Should -Not -Match 'Write-NativeHostRuntimeDependencyQueueRequest'
            $recoveryFunction | Should -Not -Match 'Update-AcrylicHost'
            $recoveryFunction | Should -Not -Match 'whitelistUrl'
            $recoveryFunction | Should -Not -Match 'cookies?'
            $recoveryFunction | Should -Not -Match 'query'
            $recoveryFunction | Should -Not -Match 'New-Guid'
        }

        It "Centralizes captive portal Task Scheduler queue classification in a native host adapter" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $adapterPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.CaptivePortalRecoveryQueue.ps1"
            $artifactCatalogPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.ArtifactCatalog.ps1"
            $nativeHostActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.CaptivePortal.ps1") -Raw)
            $adapterContent = Get-Content $adapterPath -Raw
            $artifactCatalogContent = Get-Content $artifactCatalogPath -Raw

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'NativeHost.CaptivePortalRecoveryQueue.ps1',
                'Get-NativeHostCaptivePortalRecoveryQueueClassification',
                'Read-NativeHostCaptivePortalRecoveryResultEnvelope',
                'Write-NativeHostCaptivePortalRecoveryRequest'
            )
            Assert-ContentContainsAll -Content $adapterContent -Needles @(
                'function Write-NativeHostCaptivePortalRecoveryRequest',
                'function Read-NativeHostCaptivePortalRecoveryResultEnvelope',
                'function Get-NativeHostCaptivePortalRecoveryQueueClassification',
                'missing-result',
                'stale-result',
                'task-timeout',
                'task-disabled',
                'success',
                'authenticated-restore-failed'
            )
            $artifactCatalogContent | Should -Match 'NativeHost\.CaptivePortalRecoveryQueue\.ps1'
        }

        It "Rejects invalid captive portal trigger hosts before queueing or triggering tasks" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $script:capturedTaskNames = @()
            function Invoke-OpenPathScheduledTask {
                param([string]$TaskName)
                $script:capturedTaskNames += $TaskName
                return @{ success = $true; taskName = $TaskName; triggerMs = 0; waitMs = 0 }
            }

            $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                -Message ([PSCustomObject]@{ triggerHost = 'https://portal.example/login?token=secret'; tabId = 9 })

            $result.success | Should -BeFalse
            $result.action | Should -Be 'recover-captive-portal-navigation'
            $result.state | Should -Be 'InvalidHost'
            $result.triggerHost | Should -Be ''
            @($script:capturedTaskNames).Count | Should -Be 0
        }

        It "Queues valid captive portal recovery and triggers only the recovery task" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            $script:capturedTaskNames = @()
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [object]$Runner,
                        [int]$TimeoutSeconds,
                        [scriptblock]$WaitCondition,
                        [int]$PollMilliseconds
                    )
                    $script:capturedTaskNames += $TaskName
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        state = 'Portal'
                        success = $true
                        portalModeActive = $true
                        activeMarkerMode = 'limited'
                        allowedHosts = @('portal.example')
                        portalRecoveryHosts = @($request.portalRecoveryHosts)
                        recoveryHostsApplied = $true
                        limitedModeReady = $true
                        recentSuccessEligible = $true
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 3; waitMs = 4 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{
                        triggerHost = 'Portal.Example.'
                        portalRecoveryHosts = @(
                            'Portal.Example.',
                            'Login.Wedu.Example.',
                            'https://leak.wedu.example/login?token=secret',
                            '10.77.0.1'
                        )
                        tabId = 12
                    })

                $result.success | Should -BeTrue
                $result.state | Should -Be 'Portal'
                $result.portalModeActive | Should -BeTrue
                $result.triggerHost | Should -Be 'portal.example'
                $result.taskName | Should -Be 'OpenPath-CaptivePortalRecovery'
                $result.triggerMs | Should -Be 3
                $result.waitMs | Should -Be 4
                @($result.portalRecoveryHosts) | Should -Be @('portal.example', 'login.wedu.example')
                @($script:capturedTaskNames) | Should -Be @('OpenPath-CaptivePortalRecovery')

                $queuedRaw = Get-ChildItem -Path $queuePath -Filter *.json | Select-Object -First 1 | Get-Content -Raw
                $queued = $queuedRaw | ConvertFrom-Json
                [string]$queued.requestId | Should -Be $result.requestId
                [string]$queued.operation | Should -Be 'open'
                [string]$queued.triggerHost | Should -Be 'portal.example'
                [string]$queued.source | Should -Be 'native-host'
                [string]$queued.portalState | Should -Be 'Unknown'
                [int]$queued.tabId | Should -Be 12
                @($queued.portalRecoveryHosts) | Should -Be @('portal.example', 'login.wedu.example')
                $queuedRaw | Should -Match '"createdAtUtc":\s*"[^"]+Z"'
                $queued.PSObject.Properties.Name | Should -Not -Contain 'url'
                $queued.PSObject.Properties.Name | Should -Not -Contain 'cookies'
                $queued.PSObject.Properties.Name | Should -Not -Contain 'query'
                $queuedRaw | Should -Not -Match 'token=secret'
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Reports open success when a late recovery task closes an authenticated marker" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [scriptblock]$WaitCondition
                    )
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        operation = 'open'
                        state = 'Authenticated'
                        success = $true
                        portalModeActive = $false
                        protectedModeRestored = $true
                        localDnsLoopbackRestored = $true
                        acrylicNormalRestored = $true
                        dnsResolutionHealthy = $true
                        sinkholeHealthy = $true
                        firewallExpectedActive = $true
                        firewallHealthy = $true
                        markerCleared = $true
                        portalExitRoute = 'open-authenticated'
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 2; waitMs = 3 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example'; tabId = 12 })

                $result.success | Should -BeTrue
                $result.operation | Should -Be 'open'
                $result.state | Should -Be 'Authenticated'
                $result.portalModeActive | Should -BeFalse
                $result.protectedModeRestored | Should -BeTrue
                $result.portalExitRoute | Should -Be 'open-authenticated'
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Does not report open success when exact recovery host evidence is missing" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [scriptblock]$WaitCondition
                    )
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        state = 'Portal'
                        success = $true
                        portalModeActive = $true
                        activeMarkerMode = 'limited'
                        allowedHosts = @('other.example')
                        recoveryHostsApplied = $false
                        recentSuccessEligible = $false
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 3; waitMs = 4 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example'; tabId = 12 })

                $result.success | Should -BeFalse
                $result.state | Should -Be 'Portal'
                $result.portalModeActive | Should -BeTrue
                $result.recoveryHostsApplied | Should -BeFalse
                @($result.allowedHosts) | Should -Not -Contain 'portal.example'
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Queues captive portal reconcile without requiring a trigger host" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [scriptblock]$WaitCondition
                    )
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        operation = 'reconcile'
                        state = 'Authenticated'
                        success = $true
                        portalModeActive = $false
                        protectedModeRestored = $true
                        localDnsLoopbackRestored = $true
                        acrylicNormalRestored = $true
                        dnsResolutionHealthy = $true
                        sinkholeHealthy = $true
                        firewallExpectedActive = $true
                        firewallHealthy = $true
                        markerCleared = $true
                        portalExitRoute = 'reconcile-authenticated'
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 2; waitMs = 3 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ operation = 'reconcile'; portalState = 'not_captive'; source = 'firefox-captivePortal' })

                $result.success | Should -BeTrue
                $result.operation | Should -Be 'reconcile'
                $result.state | Should -Be 'Authenticated'
                $result.portalModeActive | Should -BeFalse
                $result.triggerHost | Should -Be ''

                $queued = Get-ChildItem -Path $queuePath -Filter *.json | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
                [string]$queued.operation | Should -Be 'reconcile'
                [string]$queued.triggerHost | Should -Be ''
                [string]$queued.source | Should -Be 'firefox-captivePortal'
                [string]$queued.portalState | Should -Be 'not_captive'
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Triggers proactive reconcile during check when an active marker is already authenticated" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-check-restore-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            $script:OpenPathRoot = $tempRoot
            $script:CapturedCaptivePortalRestoreTimeoutSeconds = $null
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data') -Force | Out-Null
                @{
                    active = $true
                    mode = 'limited'
                    state = 'Portal'
                    expiresAt = ([DateTime]::UtcNow.AddMinutes(2)).ToString('o')
                } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path (Join-Path $tempRoot 'data') 'captive-portal-active.json')

                function Get-NativeHostCaptivePortalActiveMarker {
                    return [PSCustomObject]@{
                        active = $true
                        mode = 'limited'
                        state = 'Portal'
                        expiresAt = ([DateTime]::UtcNow.AddMinutes(2)).ToString('o')
                    }
                }

                function Test-OpenPathCaptivePortalState {
                    param([int]$TimeoutSec)
                    return 'Authenticated'
                }

                function Resolve-DomainIp {
                    param([string]$Domain)
                    return '127.0.0.1'
                }

                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [object]$Runner,
                        [int]$TimeoutSeconds,
                        [int]$PollMilliseconds,
                        [scriptblock]$WaitCondition
                    )
                    $script:CapturedCaptivePortalRestoreTimeoutSeconds = $TimeoutSeconds
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        operation = 'reconcile'
                        state = 'Authenticated'
                        success = $true
                        portalModeActive = $false
                        protectedModeRestored = $true
                        markerCleared = $true
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 2; waitMs = 3 }
                }

                $result = Invoke-NativeHostCheckAction `
                    -Message ([PSCustomObject]@{ domains = @('portal.example') }) `
                    -Sections ([PSCustomObject]@{ Whitelist = @() })

                $result.success | Should -BeTrue
                $result.action | Should -Be 'check'
                @($result.results).Count | Should -Be 1

                $queued = Get-ChildItem -Path $queuePath -Filter *.json | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
                [string]$queued.operation | Should -Be 'reconcile'
                [string]$queued.portalState | Should -Be 'authenticated'
                [string]$queued.source | Should -Be 'native-host-check'
                $script:CapturedCaptivePortalRestoreTimeoutSeconds | Should -Be 8
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath, $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue
                Remove-Variable -Name CapturedCaptivePortalRestoreTimeoutSeconds -Scope Script -ErrorAction SilentlyContinue
            }
        }

        It "Does not report reconcile success when protected mode evidence is false" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [scriptblock]$WaitCondition
                    )
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        operation = 'reconcile'
                        state = 'Authenticated'
                        success = $true
                        portalModeActive = $false
                        protectedModeRestored = $false
                        localDnsLoopbackRestored = $true
                        acrylicNormalRestored = $false
                        dnsResolutionHealthy = $true
                        sinkholeHealthy = $true
                        firewallExpectedActive = $true
                        firewallHealthy = $true
                        markerCleared = $true
                        portalExitRoute = 'reconcile-authenticated-restore-failed'
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 2; waitMs = 3 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ operation = 'reconcile'; portalState = 'not_captive'; source = 'firefox-captivePortal' })

                $result.success | Should -BeFalse
                $result.operation | Should -Be 'reconcile'
                $result.state | Should -Be 'Authenticated'
                $result.portalModeActive | Should -BeFalse
                $result.protectedModeRestored | Should -BeFalse
                $result.portalExitRoute | Should -Be 'reconcile-authenticated-restore-failed'
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Returns recent captive portal recovery success without triggering the elevated task again" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            $script:capturedTaskNames = @()
            try {
                New-Item -ItemType Directory -Path $resultPath -Force | Out-Null
                @{
                    requestId = 'recent-request'
                    state = 'Portal'
                    success = $true
                    portalModeActive = $true
                    activeMarkerMode = 'limited'
                    allowedHosts = @('portal.example')
                    recoveryHostsApplied = $true
                    limitedModeReady = $true
                    recentSuccessEligible = $true
                } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $resultPath 'recent-request.json')

                function Invoke-OpenPathScheduledTask {
                    param([string]$TaskName)
                    $script:capturedTaskNames += $TaskName
                    return @{ success = $true; taskName = $TaskName; triggerMs = 0; waitMs = 0 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example'; tabId = 14 })

                $result.success | Should -BeTrue
                $result.state | Should -Be 'RecentSuccess'
                $result.portalModeActive | Should -BeTrue
                $result.requestId | Should -Be 'recent-request'
                $result.triggerMs | Should -Be 0
                $result.waitMs | Should -Be 0
                @($script:capturedTaskNames).Count | Should -Be 0
                Test-Path $queuePath | Should -BeFalse
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Does not treat an active passthrough marker as terminal success even for the same trigger host" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-passthrough-" + [guid]::NewGuid().ToString('N'))
            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $script:capturedTaskNames = @()
            $script:OpenPathRoot = $tempRoot
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data') -Force | Out-Null
                @{
                    active = $true
                    state = 'Portal'
                    mode = 'passthrough'
                    allowedHosts = @('portal.example')
                    expiresAt = ([DateTime]::UtcNow.AddMinutes(5)).ToString('o')
                } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $tempRoot 'data\captive-portal-active.json')

                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [object]$Runner,
                        [int]$TimeoutSeconds,
                        [scriptblock]$WaitCondition,
                        [int]$PollMilliseconds
                    )
                    $script:capturedTaskNames += $TaskName
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        state = 'Portal'
                        success = $true
                        portalModeActive = $true
                        activeMarkerMode = 'limited'
                        allowedHosts = @('portal.example')
                        recoveryHostsApplied = $true
                        limitedModeReady = $true
                        recentSuccessEligible = $true
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 1; waitMs = 2 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example'; tabId = 27 })

                $result.success | Should -BeTrue
                $result.state | Should -Be 'Portal'
                $result.portalModeActive | Should -BeTrue
                $result.triggerMs | Should -Be 1
                $result.waitMs | Should -Be 2
                @($script:capturedTaskNames) | Should -Be @('OpenPath-CaptivePortalRecovery')
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $tempRoot, $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Does not reuse recent scheduled-task success when Acrylic update evidence is missing" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            $script:capturedTaskNames = @()
            try {
                New-Item -ItemType Directory -Path $resultPath -Force | Out-Null
                @{
                    requestId = 'recent-request'
                    state = 'Portal'
                    success = $true
                    portalModeActive = $true
                    recentSuccessEligible = $false
                    activeMarkerMode = 'passthrough'
                } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $resultPath 'recent-request.json')

                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [object]$Runner,
                        [int]$TimeoutSeconds,
                        [scriptblock]$WaitCondition,
                        [int]$PollMilliseconds
                    )
                    $script:capturedTaskNames += $TaskName
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    @{
                        requestId = [string]$request.requestId
                        state = 'Portal'
                        success = $true
                        portalModeActive = $true
                        activeMarkerMode = 'limited'
                        allowedHosts = @('portal.example')
                        recoveryHostsApplied = $true
                        limitedModeReady = $true
                        recentSuccessEligible = $true
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 3; waitMs = 4 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example'; tabId = 28 })

                $result.success | Should -BeTrue
                $result.state | Should -Be 'Portal'
                $result.requestId | Should -Not -Be 'recent-request'
                @($script:capturedTaskNames) | Should -Be @('OpenPath-CaptivePortalRecovery')
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Does not treat a recent passthrough marker as terminal success when a new trigger host arrives" {
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $content = Get-Content $scriptPath -Raw
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.CaptivePortal.ps1") -Raw)

            Assert-ContentContainsAll -Content $content -Needles @(
                'recentSuccessSource',
                '$recentSuccess.Source',
                '$portalRecoveryHosts',
                'Enable-OpenPathCaptivePortalMode -State Portal -PortalRecoveryDomains $portalRecoveryHosts'
            )
            Assert-ContentContainsAll -Content $nativeContent -Needles @(
                'Get-NativeHostCaptivePortalActiveMarker',
                'Get-NativeHostCaptivePortalMarkerSummary',
                'Test-NativeHostRecentCaptivePortalSuccessEligible',
                'RecentSuccessEligible',
                'allowedHosts',
                'recentSuccessEligible',
                'Invoke-OpenPathScheduledTask'
            )
        }

        It "Ignores stale captive portal recovery results with a different request id" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [scriptblock]$WaitCondition
                    )
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = 'different-request-id'
                        state = 'Portal'
                        success = $true
                        portalModeActive = $true
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH 'different-request-id.json')
                    & $WaitCondition | Should -BeFalse
                    return @{ success = $false; taskName = $TaskName; triggerMs = 1; waitMs = 20000; timedOut = $true; error = 'Timed out waiting for task condition' }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example' })

                $result.success | Should -BeFalse
                $result.state | Should -Be 'Timeout'
                $result.portalModeActive | Should -BeFalse
                $result.waitMs | Should -Be 20000
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Surfaces captive portal limited-mode readiness fields through native host responses" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.CaptivePortal.ps1") -Raw
            $transitionPath = Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.RecoveryTransition.ps1"
            $transitionContent = Get-Content $transitionPath -Raw
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $scriptContent = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'bootstrapHosts',
                'redirectHosts',
                'resourceHosts',
                'observedRuntimeHosts',
                'effectiveExactHosts',
                'pendingRuntimeHosts',
                'discoveryTruncated',
                'fallbackMode',
                'limitedModeReady',
                'configuredCaptivePortalDomains',
                'configuredCaptivePortalDomainsApplied',
                '$result.PSObject.Properties[''limitedModeReady'']'
            )

            Assert-ContentContainsAll -Content $transitionContent -Needles @(
                'limitedModeReady',
                'LimitedModeReady',
                'fallbackMode',
                'FallbackMode'
            )

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                'bootstrapHosts',
                'redirectHosts',
                'resourceHosts',
                'observedRuntimeHosts',
                'pendingRuntimeHosts',
                'discoveryTruncated',
                'fallbackMode',
                'limitedModeReady',
                'configuredCaptivePortalDomains',
                'configuredCaptivePortalDomainsApplied',
                '$markerSummary.limitedModeReady',
                '$payload.limitedModeReady'
            )
        }

        It "Centralizes captive portal recovery transition decisions in the shared internal helper" {
            $transitionPath = Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.RecoveryTransition.ps1"
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $transitionContent = Get-Content $transitionPath -Raw
            $nativeHostActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.CaptivePortal.ps1") -Raw)
            $scriptContent = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $transitionContent -Needles @(
                'function Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary',
                'function Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess',
                'limitedModeReady',
                'configuredCaptivePortalDomainsApplied',
                'fallbackMode',
                'recentSuccessEligible'
            )

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                "CaptivePortal.RecoveryTransition.ps1",
                'Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary',
                'Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess'
            )

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                "CaptivePortal.RecoveryTransition.ps1",
                'Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary',
                'Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess'
            )
        }

        It "Requires limitedModeReady and non-passthrough mode for recent captive portal success eligibility" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.CaptivePortal.ps1") -Raw
            $transitionPath = Join-Path $PSScriptRoot ".." "lib" "internal" "CaptivePortal.RecoveryTransition.ps1"
            $transitionContent = Get-Content $transitionPath -Raw
            $scriptPath = Join-Path $PSScriptRoot ".." "scripts" "Recover-CaptivePortal.ps1"
            $scriptContent = Get-Content $scriptPath -Raw

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'LimitedModeReady',
                'DiscoveryTruncated',
                'FallbackMode',
                'Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess'
            )

            Assert-ContentContainsAll -Content $transitionContent -Needles @(
                'limitedModeReady',
                'LimitedModeReady',
                '$fallbackMode -eq ''passthrough'''
            )

            Assert-ContentContainsAll -Content $scriptContent -Needles @(
                'limitedModeReady = [bool]$markerSummary.limitedModeReady',
                'discoveryTruncated = [bool]$markerSummary.discoveryTruncated',
                'fallbackMode = [string]$markerSummary.fallbackMode',
                'Test-OpenPathCaptivePortalRecoveryTransitionRecentSuccess'
            )
        }

        It "Behaviorally treats dynamic discovery fields as diagnostics for RecentSuccess" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $missingReady = [PSCustomObject]@{
                RecentSuccessEligible = $true
                DiscoveryTruncated = $false
                FallbackMode = 'none'
                ActiveMarkerMode = 'limited'
                AllowedHosts = @('portal.example')
            }
            $notReady = [PSCustomObject]@{
                RecentSuccessEligible = $true
                LimitedModeReady = $false
                DiscoveryTruncated = $false
                FallbackMode = 'none'
                ActiveMarkerMode = 'limited'
                AllowedHosts = @('portal.example')
            }
            $truncated = [PSCustomObject]@{
                RecentSuccessEligible = $true
                LimitedModeReady = $true
                DiscoveryTruncated = $true
                FallbackMode = 'none'
                ActiveMarkerMode = 'limited'
                AllowedHosts = @('portal.example')
            }
            $pending = [PSCustomObject]@{
                RecentSuccessEligible = $true
                LimitedModeReady = $true
                DiscoveryTruncated = $false
                FallbackMode = 'none'
                ActiveMarkerMode = 'limited'
                PendingRuntimeHosts = @('cdn.portal.example')
                AllowedHosts = @('portal.example')
            }
            $passthrough = [PSCustomObject]@{
                RecentSuccessEligible = $true
                LimitedModeReady = $true
                DiscoveryTruncated = $false
                FallbackMode = 'passthrough'
                ActiveMarkerMode = 'limited'
                AllowedHosts = @('portal.example')
            }
            $ready = [PSCustomObject]@{
                RecentSuccessEligible = $true
                LimitedModeReady = $true
                DiscoveryTruncated = $false
                FallbackMode = 'none'
                ActiveMarkerMode = 'limited'
                AllowedHosts = @('portal.example')
            }

            Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $missingReady -TriggerHost 'portal.example' | Should -BeFalse
            Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $notReady -TriggerHost 'portal.example' | Should -BeFalse
            Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $truncated -TriggerHost 'portal.example' | Should -BeTrue
            Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $pending -TriggerHost 'portal.example' | Should -BeTrue
            Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $passthrough -TriggerHost 'portal.example' | Should -BeFalse
            Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $ready -TriggerHost 'portal.example' | Should -BeTrue
        }

        It "Behaviorally rejects RecentSuccess unless configured captive portal domains are applied" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            try {
                function Get-OpenPathConfiguredCaptivePortalDomains {
                    @('nce.wedu.comunidad.madrid')
                }

                $missingConfiguredDomain = [PSCustomObject]@{
                    RecentSuccessEligible = $true
                    LimitedModeReady = $true
                    DiscoveryTruncated = $false
                    FallbackMode = 'none'
                    ActiveMarkerMode = 'limited'
                    PendingRuntimeHosts = @()
                    AllowedHosts = @('detectportal.firefox.com')
                }
                $readyWithConfiguredDomain = [PSCustomObject]@{
                    RecentSuccessEligible = $true
                    LimitedModeReady = $true
                    DiscoveryTruncated = $false
                    FallbackMode = 'none'
                    ActiveMarkerMode = 'limited'
                    PendingRuntimeHosts = @()
                    AllowedHosts = @('detectportal.firefox.com', 'nce.wedu.comunidad.madrid')
                }

                Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $missingConfiguredDomain -TriggerHost 'detectportal.firefox.com' | Should -BeFalse
                Test-NativeHostRecentCaptivePortalSuccessEligible -RecentSuccess $readyWithConfiguredDomain -TriggerHost 'detectportal.firefox.com' | Should -BeTrue

                $summary = Get-NativeHostCaptivePortalMarkerSummary -Marker ([PSCustomObject]@{
                        mode = 'limited'
                        allowedHosts = @('detectportal.firefox.com')
                        limitedModeReady = $true
                        discoveryTruncated = $false
                        fallbackMode = 'none'
                        pendingRuntimeHosts = @()
                    }) -TriggerHost 'detectportal.firefox.com'

                @($summary.effectiveExactHosts) | Should -Contain 'nce.wedu.comunidad.madrid'
                @($summary.configuredCaptivePortalDomains) | Should -Be @('nce.wedu.comunidad.madrid')
                $summary.configuredCaptivePortalDomainsApplied | Should -BeFalse
                $summary.recentSuccessEligible | Should -BeFalse
            }
            finally {
                Remove-Item Function:Get-OpenPathConfiguredCaptivePortalDomains -ErrorAction SilentlyContinue
            }
        }

        It "Returns task and storage diagnostics when captive portal recovery times out" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $progressPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-progress-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH = $progressPath
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [scriptblock]$WaitCondition
                    )
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        phase = 'state-probe'
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH "$($request.requestId).json")
                    & $WaitCondition | Should -BeFalse
                    return @{
                        success = $false
                        taskName = $TaskName
                        triggerMs = 2
                        waitMs = 20000
                        timedOut = $true
                        error = 'Timed out waiting for task condition'
                        taskState = 'Running'
                        taskLastResult = 267009
                        taskLastResultHex = '0x00041301'
                    }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example' })

                $result.success | Should -BeFalse
                $result.state | Should -Be 'Timeout'
                $result.portalModeActive | Should -BeFalse
                $result.taskState | Should -Be 'Running'
                $result.taskLastResult | Should -Be 267009
                $result.taskLastResultHex | Should -Be '0x00041301'
                $result.queuePath | Should -Be $queuePath
                $result.resultPath | Should -Be $resultPath
                $result.progressPath | Should -Be $progressPath
                $result.queueFileCount | Should -Be 1
                $result.resultFileCount | Should -Be 0
                $result.progressFileCount | Should -Be 1
                @($result.pendingRequestIds) | Should -Contain $result.requestId
                @($result.progressRequestIds) | Should -Contain $result.requestId
                $result.latestProgressPhase | Should -Be 'state-probe'
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath, $progressPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Returns clean non-portal captive portal recovery fallback" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath

            $queuePath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-queue-" + [guid]::NewGuid().ToString('N'))
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-captive-result-" + [guid]::NewGuid().ToString('N'))
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH = $queuePath
            $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH = $resultPath
            try {
                function Invoke-OpenPathScheduledTask {
                    param(
                        [string]$TaskName,
                        [scriptblock]$WaitCondition
                    )
                    $request = Get-ChildItem -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -Filter *.json |
                        Select-Object -First 1 |
                        Get-Content -Raw |
                        ConvertFrom-Json
                    New-Item -ItemType Directory -Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -Force | Out-Null
                    @{
                        requestId = [string]$request.requestId
                        state = 'Authenticated'
                        success = $false
                        portalModeActive = $false
                    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH "$($request.requestId).json")
                    & $WaitCondition | Out-Null
                    return @{ success = $true; taskName = $TaskName; triggerMs = 2; waitMs = 5 }
                }

                $result = Invoke-NativeHostCaptivePortalRecoveryAction `
                    -Message ([PSCustomObject]@{ triggerHost = 'portal.example' })

                $result.success | Should -BeFalse
                $result.state | Should -Be 'Authenticated'
                $result.portalModeActive | Should -BeFalse
            }
            finally {
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH -ErrorAction SilentlyContinue
                Remove-Item $queuePath, $resultPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Exposes portal recovery eligibility in native check results" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath
            $script:NativeHostPortalProbeCache = @{}

            function Resolve-DomainIp {
                param([string]$Domain)
                return "127.0.0.1"
            }
            function Test-OpenPathCaptivePortalState {
                param([int]$TimeoutSec)
                return 'Portal'
            }

            $sections = [PSCustomObject]@{
                Whitelist = @()
            }

            $result = Invoke-NativeHostCheckAction `
                -Message ([PSCustomObject]@{ domains = @('portal.example'); error = 'NS_ERROR_UNKNOWN_HOST'; source = 'blocked-screen-navigation' }) `
                -Sections $sections

            $result.success | Should -BeTrue
            $result.results[0].domain | Should -Be 'portal.example'
            $result.results[0].portal_recovery_eligible | Should -BeTrue
            $result.results[0].portal_recovery_signal | Should -Be 'sync-probe'
        }

        It "Ignores expired captive portal markers and stale observations in native check results" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath
            $script:NativeHostPortalProbeCache = @{}

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-portal-signal-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data') -Force | Out-Null
                @{
                    active = $true
                    state = 'Portal'
                    mode = 'passthrough'
                    expiresAt = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o')
                    updatedAt = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o')
                } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $tempRoot 'data\captive-portal-active.json')
                @{
                    detectedState = 'Portal'
                    updatedAt = ([DateTime]::UtcNow.AddMinutes(-10)).ToString('o')
                } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $tempRoot 'data\captive-portal-observation.json')

                function Resolve-DomainIp {
                    param([string]$Domain)
                    return "127.0.0.1"
                }

                $sections = [PSCustomObject]@{
                    Whitelist = @()
                }

                $result = Invoke-NativeHostCheckAction `
                    -Message ([PSCustomObject]@{ domains = @('portal.example') }) `
                    -Sections $sections

                $result.results[0].portal_recovery_eligible | Should -BeFalse
                $result.results[0].portal_recovery_signal | Should -Be 'none'
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Caches bounded sync probes for native portal eligibility" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath
            $script:NativeHostPortalProbeCache = @{}
            $script:portalProbeCount = 0

            function Resolve-DomainIp {
                param([string]$Domain)
                return "127.0.0.1"
            }
            function Test-OpenPathCaptivePortalState {
                param([int]$TimeoutSec)
                $script:portalProbeCount += 1
                return 'Portal'
            }

            $sections = [PSCustomObject]@{
                Whitelist = @()
            }
            $message = [PSCustomObject]@{ domains = @('portal.example'); error = 'NS_ERROR_UNKNOWN_HOST'; source = 'blocked-screen-navigation' }

            $first = Invoke-NativeHostCheckAction -Message $message -Sections $sections
            $second = Invoke-NativeHostCheckAction -Message $message -Sections $sections

            $first.results[0].portal_recovery_signal | Should -Be 'sync-probe'
            $second.results[0].portal_recovery_signal | Should -Be 'sync-probe'
            $script:portalProbeCount | Should -Be 1
        }

        It "Rejects system and browser update hosts as runtime dependencies" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            . $nativeHostActionsPath

            $state = [PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }
            $sections = [PSCustomObject]@{
                Whitelist = @('school.example')
                BlockedSubdomains = @()
            }

            foreach ($dependencyHost in @(
                    'windowsupdate.com',
                    'download.windowsupdate.com',
                    'delivery.mp.microsoft.com',
                    'login.microsoftonline.com',
                    'assets.azureedge.net',
                    'tenant.blob.core.windows.net',
                    'aus5.mozilla.org',
                    'download.mozilla.org',
                    'firefox.settings.services.mozilla.com',
                    'versioncheck.addons.mozilla.org',
                    'safebrowsing.googleapis.com',
                    'ciscobinary.openh264.org'
                )) {
                $candidate = Resolve-NativeHostLocalRuntimeDependencyCandidate `
                    -State $state `
                    -Sections $sections `
                    -Message ([PSCustomObject]@{
                        anchorHost = 'school.example'
                        dependencyHost = $dependencyHost
                        requestType = 'script'
                    })

                $candidate.Valid | Should -BeFalse -Because "$dependencyHost must stay protected"
                $candidate.Result.error | Should -Be 'Protected hosts are not accepted as runtime dependencies'
            }
        }

        It "Logs native action evidence without depending on downstream wrappers" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Bootstrap.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.Shared.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.RuntimeDependency.ps1") -Raw) + "`n" + (Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.MessageDispatch.ps1") -Raw)

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'Common.Redaction.ps1',
                'function Write-NativeHostActionLog',
                'function Invoke-NativeHostMessageAction',
                'Get-Command Write-NativeHostLog -ErrorAction SilentlyContinue',
                'action=$Action',
                'elapsedMs=',
                'domains=',
                '[hashtable]$ExtraFields = @{}',
                '$fields += "$key=$(Format-NativeHostActionLogValue -Value $value)"',
                'updateTriggerMs',
                'updateWaitMs',
                "if (`$action -ne 'update-whitelist')",
                "Write-NativeHostActionLog -Action `$action",
                'Write-NativeHostActionLog -Action ''update-whitelist'''
            )

            $nativeHostActionsContent | Should -Not -Match ('Classroom' + 'Path')
            $nativeHostActionsContent | Should -Not -Match ('C' + 'P_')
        }

        It "Uses shared redaction for native host action log values" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            function Get-WhitelistSections {
                return [PSCustomObject]@{
                    Whitelist = @()
                    BlockedSubdomains = @()
                }
            }
            function global:Write-NativeHostLog {
                param([string]$Message)
                $global:CapturedNativeHostLog = $Message
            }

            $script:OpenPathRoot = Join-Path $TestDrive "OpenPath"
            $script:NativeRoot = Join-Path $TestDrive "native"
            $script:MaxDomains = 50
            New-Item -ItemType Directory -Path $script:NativeRoot -Force | Out-Null
            Copy-Item (Join-Path $PSScriptRoot ".." "lib" "RequestSetup.State.psm1") -Destination (Join-Path $script:NativeRoot "RequestSetup.State.psm1") -Force
            Copy-Item (Join-Path $PSScriptRoot ".." "lib" "internal" "CapabilityStorage.ps1") -Destination (Join-Path $script:NativeRoot "CapabilityStorage.ps1") -Force
            Copy-Item (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Redaction.ps1") -Destination (Join-Path $script:NativeRoot "Common.Redaction.ps1") -Force

            . $nativeHostActionsPath

            Write-NativeHostActionLog `
                -Action "get-config" `
                -Success $true `
                -ExtraFields @{
                    whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                    apiUrl = "https://school.example"
                    detail = "first`t line`nsecond line"
                    longValue = ("x" * 260)
                }

            $global:CapturedNativeHostLog | Should -Match "whitelistUrl=https://school.example/w/\[redacted\]/whitelist.txt"
            $global:CapturedNativeHostLog | Should -Match "apiUrl=https://school.example"
            $global:CapturedNativeHostLog | Should -Match "detail=first line second line"
            $global:CapturedNativeHostLog | Should -Not -Match ("x" * 241)
            $global:CapturedNativeHostLog | Should -Not -Match "machine-token-123"

            Remove-Item function:\Write-NativeHostLog -ErrorAction SilentlyContinue
            Remove-Variable -Name CapturedNativeHostLog -Scope Global -ErrorAction SilentlyContinue
        }

        It "Writes native host logs with shared file access and retry tolerance" {
            $nativeHostScriptPath = Join-Path $PSScriptRoot ".." "scripts" "OpenPath-NativeHost.ps1"
            $nativeHostScriptContent = Get-Content $nativeHostScriptPath -Raw

            Assert-ContentContainsAll -Content $nativeHostScriptContent -Needles @(
                'function Write-NativeHostLog',
                '[System.IO.File]::Open',
                '[System.IO.FileShare]::ReadWrite',
                'for ($attempt = 1; $attempt -le 5; $attempt++)',
                'Start-Sleep -Milliseconds'
            )

            $nativeHostScriptContent | Should -Not -Match 'Add-Content -Path \$script:LogPath'
        }
    }
}
