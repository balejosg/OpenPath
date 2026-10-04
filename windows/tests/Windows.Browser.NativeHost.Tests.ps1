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

    Context "Native host manifest parity with the shared contract fixture" {
        BeforeAll {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            Import-Module $nativeHostModulePath -Force -Global -ErrorAction Stop
        }

        It "Builds the manifest from the fixture name, type and allowed extension" {
            $fixture = Get-ContractFixtureJson -FileName 'browser-firefox-native-host.json'
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $nativeHostContent = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                "return '$($fixture.name)'",
                "\$($fixture.manifestFilename)",
                "type = '$($fixture.type)'",
                "allowed_extensions = @('$($fixture.allowedExtensions[0])')",
                # Phase 5: the manifest points at the compiled host when one is
                # health-checked, with the cmd wrapper as the fallback.
                'path = $launchPath',
                'Get-OpenPathNativeHostLaunchPath -NativeRoot $nativeRoot'
            )
        }

        It "Registers both HKLM registry views for the fixture host name" {
            $fixture = Get-ContractFixtureJson -FileName 'browser-firefox-native-host.json'

            $registryPaths = @(Get-OpenPathFirefoxNativeHostRegistryPaths)
            $registryPaths.Count | Should -Be 2
            $registryPaths | Should -Contain "HKLM\SOFTWARE\Mozilla\NativeMessagingHosts\$($fixture.name)"
            $registryPaths | Should -Contain "HKLM\SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\$($fixture.name)"
        }

        It "Points the manifest at the staged cmd wrapper exec target" {
            $fixture = Get-ContractFixtureJson -FileName 'browser-firefox-native-host.json'

            (Get-OpenPathFirefoxNativeHostManifestPath) | Should -BeLike "*\$($fixture.manifestFilename)"
            (Get-OpenPathFirefoxNativeHostWrapperPath) | Should -BeLike "*\OpenPath-NativeHost.cmd"

            . (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.ArtifactCatalog.ps1")
            @(Get-OpenPathNativeHostArtifactNames) | Should -Contain 'OpenPath-NativeHost.cmd'
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

                # Phase 5: resolve sources exactly like the installer/update path
                # (scripts, lib, lib\internal and native-host candidates).
                $artifactResolution = Resolve-OpenPathNativeHostArtifactSources `
                    -ArtifactNames $nativeFiles `
                    -CandidateRoots @(Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot (Join-Path $repoWindowsRoot "scripts") -NativeRoot $nativeRoot)
                @($artifactResolution.Missing).Count | Should -Be 0

                foreach ($nativeFile in $nativeFiles) {
                    $sourcePath = Join-Path $artifactResolution.Sources[$nativeFile] $nativeFile
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

        It "Preserves an existing native host registration when request setup is incomplete during updates" {
            $nativeHostModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.FirefoxNativeHost.psm1"
            $browserModulePath = Join-Path $PSScriptRoot ".." "lib" "Browser.psm1"
            $updateModulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Update.ps1"
            $nativeHostContent = Get-Content $nativeHostModulePath -Raw
            $browserContent = Get-Content $browserModulePath -Raw
            $updateContent = Get-Content $updateModulePath -Raw

            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                '[switch]$PreserveExistingOnNotReady',
                'preserving existing native host registration',
                'if ($PreserveExistingOnNotReady) {'
            )

            Assert-ContentContainsAll -Content $browserContent -Needles @(
                '[switch]$PreserveExistingOnNotReady',
                'PreserveExistingOnNotReady:$PreserveExistingOnNotReady'
            )

            Assert-ContentContainsAll -Content $updateContent -Needles @(
                'Register-OpenPathFirefoxNativeHost -Config $config -PreserveExistingOnNotReady'
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
                '100',
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
                '$runtimeDependencyReady = Test-NativeHostRuntimeDependencyReady',
                '-Domains $RuntimeDependencyDomains',
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

            $whitelistSectionsContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Whitelist.Sections.ps1") -Raw
            Assert-ContentContainsAll -Content $stateContent -Needles @(
                '[System.IO.File]::ReadAllBytes($script:WhitelistPath)',
                'Get-OpenPathWhitelistSectionsFromLines'
            )
            Assert-ContentContainsAll -Content $whitelistSectionsContent -Needles @(
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

            # The shared owner parser must declare and populate AllowedPaths
            $whitelistSectionsContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Whitelist.Sections.ps1") -Raw
            Assert-ContentContainsAll -Content $stateContent -Needles @(
                '[System.IO.File]::ReadAllBytes($script:WhitelistPath)',
                'Get-OpenPathWhitelistSectionsFromLines'
            )
            Assert-ContentContainsAll -Content $whitelistSectionsContent -Needles @(
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
            $whitelistSectionsContent | Should -Match "'ALLOWED-PATHS'"
            $whitelistSectionsContent | Should -Not -Match "ALLOWED-PATHS.*Whitelist\s*\+="
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
                '$script:OpenPathRuntimeDependencyActionCheckLocal = ''check-local-runtime-dependency''',
                '$script:OpenPathRuntimeDependencyBatchMaxEntries = 20',
                '$script:OpenPathRuntimeDependencyQueueVersion = 1',
                '$script:OpenPathRuntimeDependencyOverlayVersion = 1',
                '$script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal = ''firefox-webrequest-local'''
            )
            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'RuntimeDependency.Protocol.ps1',
                '$script:OpenPathRuntimeDependencyActionAllowLocal',
                '$script:OpenPathRuntimeDependencyActionAllowLocalBatch',
                '$script:OpenPathRuntimeDependencyActionCheckLocal',
                '$script:OpenPathRuntimeDependencyBatchMaxEntries',
                'function Invoke-NativeHostLocalRuntimeDependencyAction',
                'function Invoke-NativeHostLocalRuntimeDependencyBatchAction',
                'function Invoke-NativeHostLocalRuntimeDependencyCheckAction',
                'function Test-NativeHostRuntimeDependencyReady',
                'function Test-NativeHostRuntimeDependencyOverlayApplied',
                'Write-OpenPathRuntimeDependencyQueueRequest `',
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
                'runtimeDependencyFallback',
                'runtimeDependencyState = ''ready''',
                'runtimeDependencyState = ''error'''
            )
            Assert-ContentContainsAll -Content $runtimeDependencyQueueContent -Needles @(
                'RuntimeDependency.Protocol.ps1',
                'version = $script:OpenPathRuntimeDependencyQueueVersion',
                'source = $script:OpenPathRuntimeDependencySourceFirefoxWebRequestLocal',
                'Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue'
            )
            Assert-ContentContainsAll -Content $runtimeDependencyOverlayContent -Needles @(
                'RuntimeDependency.Protocol.ps1',
                'version = $script:OpenPathRuntimeDependencyOverlayVersion',
                '$nextGeneration = $previousGeneration + 1',
                'appliedGeneration = $previousAppliedGeneration',
                'function Set-OpenPathRuntimeDependencyOverlayApplied',
                'function Test-OpenPathRuntimeDependencyEntryReady',
                'function Get-OpenPathRuntimeDependencyPairKey',
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
                'Set-OpenPathRuntimeDependencyOverlayApplied | Out-Null',
                'Runtime dependency queue processed'
            )

            $nativeHostActionsContent | Should -Not -Match 'Write-NativeHostRuntimeDependencyOverlay'
            $nativeHostActionsContent | Should -Not -Match 'Read-NativeHostRuntimeDependencyOverlay'
            $nativeHostActionsContent | Should -Not -Match 'Update-AcrylicHost -WhitelistedDomains'
            $nativeHostActionsContent | Should -Not -Match 'function Find-NativeHostRuntimeDependencyQueueRequest'
            $nativeHostActionsContent | Should -Not -Match 'function Write-NativeHostRuntimeDependencyQueueRequest'
            $nativeHostActionsContent | Should -Not -Match 'function Get-NativeHostMicrosoftSystemRuntimeDependencyRoots'
            $nativeHostActionsContent | Should -Not -Match 'function Get-NativeHostRuntimeDependencySettings'
            $nativeHostActionsContent | Should -Not -Match 'function Get-NativeHostProtectedRuntimeDependencyHosts'
            $nativeHostActionsContent | Should -Not -Match 'function Test-NativeHostProtectedRuntimeDependencyHost'
            $nativeHostActionsContent | Should -Not -Match 'function Test-NativeHostSensitiveRuntimeDependencyField'
            $nativeHostActionsContent | Should -Not -Match 'function Get-NativeHostRuntimeDependencyQueuePath'
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
            $recoveryFunction | Should -Not -Match 'Write-(?:NativeHost|OpenPath)RuntimeDependencyQueueRequest'
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

        It "Skips DNS resolution and reports active policy for denied native checks" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath
            $script:ResolveDomainIpCallCount = 0

            function Resolve-DomainIp {
                param([string]$Domain)
                $script:ResolveDomainIpCallCount += 1
                return '203.0.113.10'
            }
            function Get-NativeHostPortalRecoverySignal {
                param([string]$Domain, [object]$Message)
                return 'none'
            }
            function Invoke-NativeHostAuthenticatedCaptivePortalRestoreIfNeeded {}

            $result = Invoke-NativeHostCheckAction `
                -Message ([PSCustomObject]@{ domains = @('blocked.example', 'allowed.example') }) `
                -Sections ([PSCustomObject]@{ Whitelist = @('allowed.example') })

            $blocked = $result.results | Where-Object { $_.domain -eq 'blocked.example' }
            $allowed = $result.results | Where-Object { $_.domain -eq 'allowed.example' }

            $result.success | Should -BeTrue
            $blocked.in_whitelist | Should -BeFalse
            $blocked.resolved_ip | Should -BeNullOrEmpty
            $blocked.policy_active | Should -BeTrue
            $allowed.in_whitelist | Should -BeTrue
            $allowed.resolved_ip | Should -Be '203.0.113.10'
            $allowed.policy_active | Should -BeTrue
            $script:ResolveDomainIpCallCount | Should -Be 1
        }

        It "Allows static connectivity hosts through native policy when the mirrored whitelist omits them" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            . $nativeHostActionsPath
            $script:ResolveDomainIpCallCount = 0

            function Resolve-DomainIp {
                param([string]$Domain)
                $script:ResolveDomainIpCallCount += 1
                return '203.0.113.10'
            }
            function Get-NativeHostPortalRecoverySignal {
                param([string]$Domain, [object]$Message)
                return 'none'
            }
            function Invoke-NativeHostAuthenticatedCaptivePortalRestoreIfNeeded {}

            $result = Invoke-NativeHostCheckAction `
                -Message ([PSCustomObject]@{ domains = @('detectportal.firefox.com', 'www.msftconnecttest.com', 'blocked.example') }) `
                -Sections ([PSCustomObject]@{ Whitelist = @() })

            $detectPortal = $result.results | Where-Object { $_.domain -eq 'detectportal.firefox.com' }
            $msftConnectTest = $result.results | Where-Object { $_.domain -eq 'www.msftconnecttest.com' }
            $blocked = $result.results | Where-Object { $_.domain -eq 'blocked.example' }

            $detectPortal.in_whitelist | Should -BeTrue
            $detectPortal.resolved_ip | Should -Be '203.0.113.10'
            $msftConnectTest.in_whitelist | Should -BeTrue
            $msftConnectTest.resolved_ip | Should -Be '203.0.113.10'
            $blocked.in_whitelist | Should -BeFalse
            $blocked.resolved_ip | Should -BeNullOrEmpty
            $script:ResolveDomainIpCallCount | Should -Be 2
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

            # Isolate $script:OpenPathRoot so a real C:\OpenPath install's captive-portal
            # marker/observation files (present on the self-hosted runner) cannot leak in and
            # downgrade the signal from the intended live 'sync-probe' to 'observation'.
            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-portal-signal-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data') -Force | Out-Null

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
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
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

            # Isolate $script:OpenPathRoot so a real C:\OpenPath install's captive-portal
            # marker/observation files (present on the self-hosted runner) cannot leak in and
            # downgrade the signal from the intended live 'sync-probe' to 'observation'.
            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-portal-signal-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data') -Force | Out-Null

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
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
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

        It "Reports runtime dependency readiness only after the overlay generation is applied" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-runtime-ready-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                . $nativeHostActionsPath

                $overlayPath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $tempRoot
                New-Item -ItemType Directory -Path (Split-Path $overlayPath -Parent) -Force | Out-Null
                @{
                    version = 1
                    generation = 1
                    appliedGeneration = 0
                    updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
                    entries = @(
                        @{
                            dependencyHost = 'cdn-ready.example'
                            anchorHost = 'www.reddit.com'
                            requestTypes = @('script')
                            firstSeen = [DateTimeOffset]::UtcNow.ToString('o')
                            lastSeen = [DateTimeOffset]::UtcNow.ToString('o')
                            expiresAt = [DateTimeOffset]::UtcNow.AddDays(1).ToString('o')
                            source = 'firefox-webrequest-local'
                        }
                    )
                } | ConvertTo-Json -Depth 6 | Set-Content -Path $overlayPath

                $pending = Invoke-NativeHostLocalRuntimeDependencyCheckAction -Message ([PSCustomObject]@{
                        anchorHost = 'www.reddit.com'
                        dependencyHost = 'cdn-ready.example'
                    })
                $pending.success | Should -BeTrue
                $pending.ready | Should -BeFalse
                $pending.runtimeDependencyState | Should -Be 'pending'

                # The queue request file is gone and the overlay contains the host,
                # but the content generation has not been reloaded yet.
                (Test-NativeHostRuntimeDependencyReady -RequestPath (Join-Path $tempRoot 'processed-request.json') -Domains @('cdn-ready.example')) | Should -BeFalse

                $appliedOverlay = Get-Content $overlayPath -Raw | ConvertFrom-Json
                $appliedOverlay.appliedGeneration = $appliedOverlay.generation
                $appliedOverlay | ConvertTo-Json -Depth 6 | Set-Content -Path $overlayPath

                $ready = Invoke-NativeHostLocalRuntimeDependencyCheckAction -Message ([PSCustomObject]@{
                        anchorHost = 'www.reddit.com'
                        dependencyHost = 'cdn-ready.example'
                    })
                $ready.ready | Should -BeTrue
                $ready.runtimeDependencyState | Should -Be 'ready'
                $ready.expiresAt | Should -Not -BeNullOrEmpty

                (Test-NativeHostRuntimeDependencyReady -RequestPath (Join-Path $tempRoot 'processed-request.json') -Domains @('cdn-ready.example')) | Should -BeTrue

                # An unprocessed queue request keeps readiness false even when the overlay is applied.
                $queuedRequestPath = Join-Path $tempRoot 'queued-request.json'
                Set-Content -Path $queuedRequestPath -Value '{}'
                (Test-NativeHostRuntimeDependencyReady -RequestPath $queuedRequestPath -Domains @('cdn-ready.example')) | Should -BeFalse
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Answers runtime dependency enqueue mode immediately with the per-entry state" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-enqueue-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                . $nativeHostActionsPath
                $sections = [PSCustomObject]@{
                    Whitelist = @('allowed.example')
                    BlockedSubdomains = @()
                    BlockedPaths = @()
                    PolicyKnown = $true
                    PolicyVersion = 'test'
                }
                $state = [PSCustomObject]@{}

                $started = Get-Date
                $response = Invoke-NativeHostLocalRuntimeDependencyAction -Message ([PSCustomObject]@{
                        action = 'allow-local-runtime-dependency'
                        mode = 'enqueue'
                        anchorHost = 'allowed.example'
                        dependencyHost = 'cdn.example'
                        requestType = 'fetch'
                    }) -State $state -Sections $sections
                ((Get-Date) - $started).TotalSeconds | Should -BeLessThan 5

                $response.success | Should -BeTrue
                $response.mode | Should -Be 'enqueue'
                $response.queued | Should -BeTrue
                $response.ready | Should -BeFalse
                $response.runtimeDependencyState | Should -Be 'pending'
                $response.dependencyHost | Should -Be 'cdn.example'

                $queuePath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyQueue -OpenPathRoot $tempRoot
                @(Get-ChildItem -Path $queuePath -Filter '*.json' -ErrorAction SilentlyContinue).Count | Should -Be 1

                $unsupported = Invoke-NativeHostLocalRuntimeDependencyAction -Message ([PSCustomObject]@{
                        action = 'allow-local-runtime-dependency'
                        mode = 'teleport'
                        anchorHost = 'allowed.example'
                        dependencyHost = 'cdn.example'
                        requestType = 'fetch'
                    }) -State $state -Sections $sections
                $unsupported.success | Should -BeFalse
                $unsupported.error | Should -Be 'Unsupported runtime dependency mode'
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Answers runtime dependency check batches per entry and echoes the correlation id" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $previousStatePath = if (Get-Variable -Name StatePath -Scope Script -ErrorAction SilentlyContinue) { $script:StatePath } else { $null }
            $previousWhitelistPath = if (Get-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue) { $script:WhitelistPath } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-check-batch-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                . $nativeHostActionsPath
                $overlayPath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $tempRoot
                New-Item -ItemType Directory -Path (Split-Path $overlayPath -Parent) -Force | Out-Null
                @{
                    version = 1
                    generation = 2
                    appliedGeneration = 1
                    entries = @(
                        @{ anchorHost = 'www.reddit.com'; dependencyHost = 'cdn-one.example'; generation = 1 },
                        @{ anchorHost = 'www.reddit.com'; dependencyHost = 'cdn-two.example'; generation = 2 }
                    )
                } | ConvertTo-Json -Depth 6 | Set-Content -Path $overlayPath

                $batch = Invoke-NativeHostLocalRuntimeDependencyCheckAction -Message ([PSCustomObject]@{
                        action = 'check-local-runtime-dependency'
                        entries = @(
                            [PSCustomObject]@{ anchorHost = 'www.reddit.com'; dependencyHost = 'cdn-one.example' },
                            [PSCustomObject]@{ anchorHost = 'www.reddit.com'; dependencyHost = 'cdn-two.example' }
                        )
                    })

                $batch.success | Should -BeTrue
                $batch.count | Should -Be 2
                $batch.results[0].ready | Should -BeTrue
                $batch.results[0].runtimeDependencyState | Should -Be 'ready'
                $batch.results[1].ready | Should -BeFalse
                $batch.results[1].runtimeDependencyState | Should -Be 'pending'

                # The wait condition uses the same per-entry rule: the applied entry
                # is ready while the newer batch is still pending.
                (Test-NativeHostRuntimeDependencyReady -RequestPath '' -Domains @('cdn-one.example')) | Should -BeTrue
                (Test-NativeHostRuntimeDependencyReady -RequestPath '' -Domains @('cdn-two.example')) | Should -BeFalse

                # The correlation id is echoed by Handle-Message for every action.
                $script:StatePath = Join-Path $tempRoot 'native-state.json'
                $script:WhitelistPath = Join-Path $tempRoot 'whitelist.txt'
                Set-Content -Path $script:WhitelistPath -Value '## WHITELIST'
                $null = . (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1")
                $ping = Handle-Message -Message ([PSCustomObject]@{ action = 'ping'; id = 'port-9' })
                $ping.success | Should -BeTrue
                $ping.id | Should -Be 'port-9'

                $pingWithoutId = Handle-Message -Message ([PSCustomObject]@{ action = 'ping' })
                $pingWithoutId.ContainsKey('id') | Should -BeFalse
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                if ($null -ne $previousStatePath) { $script:StatePath = $previousStatePath } else { Remove-Variable -Name StatePath -Scope Script -ErrorAction SilentlyContinue }
                if ($null -ne $previousWhitelistPath) { $script:WhitelistPath = $previousWhitelistPath } else { Remove-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Treats a recent worker busy mark as alive during long batches" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-busy-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                . $nativeHostActionsPath
                $statePath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyWorkerState -OpenPathRoot $tempRoot
                New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null

                # Simulated 30 s batch: the idle heartbeat is 25 s old but the busy
                # mark is fresh, so the native host must not fall back to schtasks.
                @{
                    pid = 55
                    heartbeatEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-25).ToUnixTimeMilliseconds()
                    busySince = [DateTimeOffset]::UtcNow.AddSeconds(-5).ToString('o')
                    busySinceEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeMilliseconds()
                    busyStage = 'acrylic-reload'
                } | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath

                (Test-NativeHostRuntimeDependencyWorkerFresh -MaxAgeSeconds 10 -BusyMaxAgeSeconds 120) | Should -BeTrue

                # Beyond the busy window the worker is not alive.
                @{
                    pid = 55
                    heartbeatEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-25).ToUnixTimeMilliseconds()
                    busySinceEpochMs = [DateTimeOffset]::UtcNow.AddSeconds(-300).ToUnixTimeMilliseconds()
                } | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath
                (Test-NativeHostRuntimeDependencyWorkerFresh -MaxAgeSeconds 10 -BusyMaxAgeSeconds 120) | Should -BeFalse
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Announces the persistent transport protocol and capabilities, honoring the retirement switch" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-capabilities-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data') -Force | Out-Null
                $script:StatePath = Join-Path $tempRoot 'native-state.json'
                $script:WhitelistPath = Join-Path $tempRoot 'whitelist.txt'
                Set-Content -Path $script:WhitelistPath -Value '## WHITELIST' -Encoding ASCII
                . $nativeHostActionsPath
                $null = . (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1")

                $ping = Handle-Message -Message ([PSCustomObject]@{ action = 'ping' })
                $ping.success | Should -BeTrue
                $ping.protocolVersion | Should -Be 2
                @($ping.capabilities) | Should -Contain 'runtime-dependency-enqueue'
                @($ping.capabilities) | Should -Contain 'runtime-dependency-check-batch'
                @($ping.capabilities) | Should -Contain 'message-id-echo'
                @($ping.capabilities) | Should -Contain 'runtime-dependency-auto-reload'

                # Retirement switch: turning the persistent transport off must
                # never require a new signed XPI.
                @{ runtimeDependencyPersistentTransportDisabled = $true } |
                    ConvertTo-Json | Set-Content -Path (Join-Path $tempRoot 'data\config.json') -Encoding UTF8
                $disabledPing = Handle-Message -Message ([PSCustomObject]@{ action = 'ping' })
                $disabledPing.protocolVersion | Should -Be 2
                @($disabledPing.capabilities) | Should -Not -Contain 'runtime-dependency-enqueue'
                @($disabledPing.capabilities) | Should -Not -Contain 'runtime-dependency-auto-reload'
                @($disabledPing.capabilities) | Should -Contain 'runtime-dependency-check-batch'
                @($disabledPing.capabilities) | Should -Contain 'message-id-echo'

                # A string value is honored too (config files edited by hand).
                @{ runtimeDependencyPersistentTransportDisabled = 'true' } |
                    ConvertTo-Json | Set-Content -Path (Join-Path $tempRoot 'data\config.json') -Encoding UTF8
                @((Handle-Message -Message ([PSCustomObject]@{ action = 'ping' })).capabilities) |
                    Should -Not -Contain 'runtime-dependency-enqueue'
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Announces the extension-diagnostics capability and honors its own switch" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-diag-capabilities-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data') -Force | Out-Null
                $script:StatePath = Join-Path $tempRoot 'native-state.json'
                $script:WhitelistPath = Join-Path $tempRoot 'whitelist.txt'
                Set-Content -Path $script:WhitelistPath -Value '## WHITELIST' -Encoding ASCII
                . $nativeHostActionsPath
                $null = . (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1")

                $ping = Handle-Message -Message ([PSCustomObject]@{ action = 'ping' })
                @($ping.capabilities) | Should -Contain 'extension-diagnostics'

                # Its own switch retires only the diagnostics action.
                @{ extensionDiagnosticsDisabled = $true } |
                    ConvertTo-Json | Set-Content -Path (Join-Path $tempRoot 'data\config.json') -Encoding UTF8
                $offPing = Handle-Message -Message ([PSCustomObject]@{ action = 'ping' })
                @($offPing.capabilities) | Should -Not -Contain 'extension-diagnostics'
                @($offPing.capabilities) | Should -Contain 'runtime-dependency-enqueue'
                @($offPing.capabilities) | Should -Contain 'runtime-dependency-auto-reload'

                # The transport retirement switch also drops the diagnostics.
                @{ runtimeDependencyPersistentTransportDisabled = $true } |
                    ConvertTo-Json | Set-Content -Path (Join-Path $tempRoot 'data\config.json') -Encoding UTF8
                @((Handle-Message -Message ([PSCustomObject]@{ action = 'ping' })).capabilities) |
                    Should -Not -Contain 'extension-diagnostics'
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Writes sanitized stage=extension-diagnostic lines and caps the batch at 50" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $global:CapturedExtensionDiagnosticLines = @()
            function Write-NativeHostLog {
                param([string]$Message)
                $global:CapturedExtensionDiagnosticLines += $Message
            }
            try {
                . $nativeHostActionsPath
                $script:NativeHostExtensionDiagnosticFirstLogged = $false

                $events = @()
                for ($index = 0; $index -lt 60; $index++) {
                    $events += @{
                        ts = 1790900000000 + $index
                        kind = 'hold'
                        dependencyHost = 'cdn.example'
                        anchorHost = 'https://evil.example/private?token=secret'
                        reason = 'https://tracker.example/pixel?id=1'
                        tabId = $index
                        ms = 12
                        unexpected = 'must-be-dropped'
                    }
                }
                $response = Invoke-NativeHostReportExtensionDiagnostics -Message @{ events = $events }
                $response.success | Should -BeTrue
                $response.written | Should -Be 50
                $response.dropped | Should -Be 10
                # Phase 3A G0: the first-receipt line proves the batch arrived.
                $batchLines = @($global:CapturedExtensionDiagnosticLines | Where-Object { $_ -match 'stage=extension-diagnostic-batch' })
                $batchLines.Count | Should -Be 1
                $batchLines[0] | Should -Match 'first=true'
                $batchLines[0] | Should -Match 'received=60'
                $batchLines[0] | Should -Match 'written=50'
                $batchLines[0] | Should -Match 'dropped=10'
                $diagnosticLines = @($global:CapturedExtensionDiagnosticLines | Where-Object { $_ -match 'stage=extension-diagnostic \{' })
                $diagnosticLines.Count | Should -Be 50
                $first = $diagnosticLines[0]
                $first | Should -Not -Match 'evil\.example'
                $first | Should -Not -Match 'tracker\.example'
                $first | Should -Not -Match 'unexpected'
                $first | Should -Not -Match 'must-be-dropped'
                # Phase 3A: epoch milliseconds exceed Int32 and must survive.
                $first | Should -Match '"ts":1790900000000'
            }
            finally {
                Remove-Variable -Name CapturedExtensionDiagnosticLines -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It "Serves a realistic diagnostics batch through the real framed native-message loop" {
            # Phase 3A G0: the 2E tests called the handler directly. This test
            # spawns the real host process and speaks the native-messaging
            # framing over stdin/stdout: ping, then a 50-event diagnostics batch.
            $nativeHostScriptPath = Join-Path $PSScriptRoot ".." "scripts" "OpenPath-NativeHost.ps1"

            $engines = [System.Collections.Generic.List[string]]::new()
            if ($env:SystemRoot) {
                $legacyEngine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (Test-Path -LiteralPath $legacyEngine) { $engines.Add($legacyEngine) }
            }
            $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwshCommand) { $engines.Add($pwshCommand.Source) }
            $engines.Count | Should -BeGreaterThan 0

            foreach ($engine in $engines) {
                $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-loop-" + [Guid]::NewGuid().ToString("N"))
                New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
                $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = $engine
                $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$nativeHostScriptPath`""
                $startInfo.UseShellExecute = $false
                $startInfo.RedirectStandardInput = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $tempRoot
                $startInfo.EnvironmentVariables['TEMP'] = $tempRoot
                $startInfo.EnvironmentVariables['TMP'] = $tempRoot
                $process = [System.Diagnostics.Process]::Start($startInfo)

                # A stuck host must fail the test instead of hanging the shard.
                $watchdog = [System.Threading.Timer]::new(
                    [System.Threading.TimerCallback] {
                        param($state)
                        try { $state.Kill() } catch { }
                    },
                    $process,
                    90000,
                    [System.Threading.Timeout]::Infinite
                )

                try {
                    $writeFrame = {
                        param([object]$Payload)
                        $json = $Payload | ConvertTo-Json -Depth 6 -Compress
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $lengthBytes = [System.BitConverter]::GetBytes([int]$bytes.Length)
                        $stdin = $process.StandardInput.BaseStream
                        $stdin.Write($lengthBytes, 0, 4)
                        $stdin.Write($bytes, 0, $bytes.Length)
                        $stdin.Flush()
                    }
                    $readFrame = {
                        $stdout = $process.StandardOutput.BaseStream
                        $lengthBuffer = New-Object byte[] 4
                        $read = 0
                        while ($read -lt 4) {
                            $chunk = $stdout.Read($lengthBuffer, $read, 4 - $read)
                            if ($chunk -le 0) { return $null }
                            $read += $chunk
                        }
                        $length = [System.BitConverter]::ToInt32($lengthBuffer, 0)
                        $payload = New-Object byte[] $length
                        $offset = 0
                        while ($offset -lt $length) {
                            $chunk = $stdout.Read($payload, $offset, $length - $offset)
                            if ($chunk -le 0) { return $null }
                            $offset += $chunk
                        }
                        return ([System.Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json)
                    }

                    $events = @()
                    for ($index = 0; $index -lt 50; $index++) {
                        $events += @{
                            ts = 1790900000000 + $index
                            kind = 'hold'
                            tabId = 4
                            frameId = 0
                            type = 'stylesheet'
                            anchorHost = 'anchor.example'
                            dependencyHost = ("dep-{0}.example" -f $index)
                            transport = 'ready'
                            outcome = 'ready'
                            ms = 100 + $index
                            reason = 'reloaded'
                            unknownField = 'https://evil.example/private?token=secret'
                        }
                    }

                    & $writeFrame @{ id = 7; action = 'ping' }
                    $ping = & $readFrame
                    & $writeFrame @{ id = 8; action = 'report-extension-diagnostics'; events = $events }
                    $report = & $readFrame
                    $process.StandardInput.Close()
                    $process.WaitForExit(15000) | Out-Null

                    $ping.id | Should -Be 7
                    @($ping.capabilities) | Should -Contain 'extension-diagnostics'
                    $report.id | Should -Be 8
                    $report.success | Should -BeTrue
                    $report.written | Should -Be 50
                    $report.dropped | Should -Be 0

                    $logPath = Join-Path $tempRoot 'OpenPath\native-host.log'
                    (Test-Path -LiteralPath $logPath) | Should -BeTrue
                    $lines = Get-Content -LiteralPath $logPath
                    $diagnosticLines = @($lines | Where-Object { $_ -match 'stage=extension-diagnostic \{' })
                    $diagnosticLines.Count | Should -Be 50
                    $diagnosticLines[0] | Should -Match '"ts":1790900000000'
                    $diagnosticLines[0] | Should -Match 'dep-0\.example'
                    $diagnosticLines[0] | Should -Not -Match 'evil\.example'
                    $batchLines = @($lines | Where-Object { $_ -match 'stage=extension-diagnostic-batch first=true received=50 written=50 dropped=0' })
                    $batchLines.Count | Should -Be 1
                }
                finally {
                    $watchdog.Dispose()
                    if (-not $process.HasExited) { $process.Kill() }
                    $process.Dispose()
                    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It "Picks up whitelist changes between messages of one persistent process" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $previousWhitelistPath = if (Get-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue) { $script:WhitelistPath } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-freshness-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data\runtime-dependency-queue') -Force | Out-Null
                $script:StatePath = Join-Path $tempRoot 'native-state.json'
                $script:WhitelistPath = Join-Path $tempRoot 'native-whitelist.txt'
                Set-Content -Path $script:WhitelistPath -Value "## WHITELIST$([Environment]::NewLine)allowed.example" -Encoding ASCII
                . $nativeHostActionsPath
                $null = . (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1")

                # First message: the anchor is not in the mirror yet.
                $before = Handle-Message -Message ([PSCustomObject]@{
                        action = 'allow-local-runtime-dependency'
                        mode = 'enqueue'
                        anchorHost = 'freshness.example'
                        dependencyHost = 'cdn.example'
                        requestType = 'script'
                    })
                $before.success | Should -BeFalse
                $before.error | Should -Be 'Anchor host is not locally whitelisted'

                # The mirror changes on disk; the same process must see it on the
                # next message (mtime/size keyed validation cache).
                Start-Sleep -Milliseconds 1200
                Set-Content -Path $script:WhitelistPath -Value "## WHITELIST$([Environment]::NewLine)allowed.example$([Environment]::NewLine)freshness.example" -Encoding ASCII

                $after = Handle-Message -Message ([PSCustomObject]@{
                        action = 'allow-local-runtime-dependency'
                        mode = 'enqueue'
                        anchorHost = 'freshness.example'
                        dependencyHost = 'cdn.example'
                        requestType = 'script'
                    })
                $after.success | Should -BeTrue
                $after.queued | Should -BeTrue
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                if ($null -ne $previousWhitelistPath) { $script:WhitelistPath = $previousWhitelistPath }
                else { Remove-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Logs ready transitions and aggregates instead of one line per poll" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $previousWhitelistPath = if (Get-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue) { $script:WhitelistPath } else { $null }
            $global:openPathCapturedNativeHostLogs = @()
            if (-not (Get-Command Write-NativeHostLog -ErrorAction SilentlyContinue)) {
                function global:Write-NativeHostLog {
                    param([string]$Message)
                    $global:openPathCapturedNativeHostLogs += $Message
                }
            }

            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-chatty-log-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                # The native host would create its storage dirs lazily; this
                # test writes the whitelist mirror first, so create the root.
                New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
                . $nativeHostActionsPath
                $null = . (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1")
                $script:StatePath = Join-Path $tempRoot 'native-state.json'
                $script:WhitelistPath = Join-Path $tempRoot 'whitelist.txt'
                Set-Content -Path $script:WhitelistPath -Value '## WHITELIST' -Encoding ASCII

                $overlayPath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $tempRoot
                New-Item -ItemType Directory -Path (Split-Path $overlayPath -Parent) -Force | Out-Null
                @{ version = 1; generation = 1; appliedGeneration = 1; entries = @() } |
                    ConvertTo-Json -Depth 6 | Set-Content -Path $overlayPath -Encoding UTF8

                $global:openPathCapturedNativeHostLogs = @()
                for ($i = 0; $i -lt 3; $i++) {
                    $poll = Handle-Message -Message ([PSCustomObject]@{
                            action = 'check-local-runtime-dependency'
                            anchorHost = 'allowed.example'
                            dependencyHost = 'cdn.example'
                        })
                    $poll.ready | Should -BeFalse
                }
                ($global:openPathCapturedNativeHostLogs | Where-Object { $_ -match 'action=check-local-runtime-dependency' }).Count | Should -Be 0

                @{
                    version = 1
                    generation = 1
                    appliedGeneration = 2
                    entries = @(@{
                            anchorHost = 'allowed.example'
                            dependencyHost = 'cdn.example'
                            generation = 1
                        })
                } | ConvertTo-Json -Depth 6 | Set-Content -Path $overlayPath -Encoding UTF8

                $ready = Handle-Message -Message ([PSCustomObject]@{
                        action = 'check-local-runtime-dependency'
                        anchorHost = 'allowed.example'
                        dependencyHost = 'cdn.example'
                    })
                $ready.ready | Should -BeTrue
                ($global:openPathCapturedNativeHostLogs | Where-Object { $_ -match 'runtime-dependency-ready-transition' }).Count | Should -Be 1
                ($global:openPathCapturedNativeHostLogs | Where-Object { $_ -match 'action=check-local-runtime-dependency' }).Count | Should -Be 0

                # The source contract keeps the main loop from logging every poll.
                $hostScriptContent = Get-Content (Join-Path $PSScriptRoot ".." "scripts" "OpenPath-NativeHost.ps1") -Raw
                $hostScriptContent | Should -Match 'Test-NativeHostChattyAction -Action \$messageAction'
                $hostScriptContent | Should -Match 'Write-NativeHostChattyActionLog -Action \$messageAction'
                $dispatchContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.MessageDispatch.ps1") -Raw
                $dispatchContent | Should -Match 'Test-NativeHostChattyAction -Action \$action'
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                if ($null -ne $previousWhitelistPath) { $script:WhitelistPath = $previousWhitelistPath }
                else { Remove-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Measures hot in-process latency for the actions served over the port" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"

            $previousOpenPathRoot = if (Get-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue) { $script:OpenPathRoot } else { $null }
            $previousWhitelistPath = if (Get-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue) { $script:WhitelistPath } else { $null }
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-native-latency-" + [Guid]::NewGuid().ToString("N"))
            $script:OpenPathRoot = $tempRoot
            try {
                New-Item -ItemType Directory -Path (Join-Path $tempRoot 'data\runtime-dependency-queue') -Force | Out-Null
                $script:StatePath = Join-Path $tempRoot 'native-state.json'
                $script:WhitelistPath = Join-Path $tempRoot 'whitelist.txt'
                Set-Content -Path $script:WhitelistPath -Value "## WHITELIST$([Environment]::NewLine)allowed.example" -Encoding ASCII
                . $nativeHostActionsPath
                $null = . (Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1")

                $overlayPath = Get-OpenPathCapabilityStoragePath -Name RuntimeDependencyOverlay -OpenPathRoot $tempRoot
                New-Item -ItemType Directory -Path (Split-Path $overlayPath -Parent) -Force | Out-Null
                @{ version = 1; generation = 1; appliedGeneration = 1; entries = @() } |
                    ConvertTo-Json -Depth 6 | Set-Content -Path $overlayPath -Encoding UTF8

                $measure = {
                    param([scriptblock]$Action)
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    & $Action | Out-Null
                    $stopwatch.Stop()
                    return [int]$stopwatch.ElapsedMilliseconds
                }

                $pingMs = & $measure { Handle-Message -Message ([PSCustomObject]@{ action = 'ping' }) }
                $checkMs = & $measure {
                    Handle-Message -Message ([PSCustomObject]@{
                            action = 'check-local-runtime-dependency'
                            anchorHost = 'allowed.example'
                            dependencyHost = 'cdn.example'
                        })
                }
                $enqueueMs = & $measure {
                    Handle-Message -Message ([PSCustomObject]@{
                            action = 'allow-local-runtime-dependency'
                            mode = 'enqueue'
                            anchorHost = 'allowed.example'
                            dependencyHost = 'cdn.example'
                            requestType = 'script'
                        })
                }
                # Phase 2D D2: the first enqueue must not pay a lazy load the
                # second one does not; measure both and report the pair.
                $enqueueMs2 = & $measure {
                    Handle-Message -Message ([PSCustomObject]@{
                            action = 'allow-local-runtime-dependency'
                            mode = 'enqueue'
                            anchorHost = 'allowed.example'
                            dependencyHost = 'cdn-two.example'
                            requestType = 'script'
                        })
                }

                Write-Host ("Native host hot-path latency (in-process): ping=$($pingMs)ms check=$($checkMs)ms enqueue=$($enqueueMs)ms enqueue2=$($enqueueMs2)ms")
                $pingMs | Should -BeLessThan 500
                $checkMs | Should -BeLessThan 500
                $enqueueMs | Should -BeLessThan 500
                $enqueueMs2 | Should -BeLessThan 500
            }
            finally {
                if ($null -ne $previousOpenPathRoot) { $script:OpenPathRoot = $previousOpenPathRoot }
                else { Remove-Variable -Name OpenPathRoot -Scope Script -ErrorAction SilentlyContinue }
                if ($null -ne $previousWhitelistPath) { $script:WhitelistPath = $previousWhitelistPath }
                else { Remove-Variable -Name WhitelistPath -Scope Script -ErrorAction SilentlyContinue }
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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

        Context "Explicit native policy verdict" {
            BeforeEach {
                $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
                . $nativeHostActionsPath
                function Resolve-DomainIp { param([string]$Domain) return '203.0.113.10' }
                function Get-NativeHostPortalRecoverySignal { param([string]$Domain, [object]$Message) return 'none' }
                function Invoke-NativeHostAuthenticatedCaptivePortalRestoreIfNeeded {}
            }

            It "Allows whitelist descendants but preserves explicit blocked-subdomain exclusions" {
                $sections = [PSCustomObject]@{
                    Whitelist = @('allowed.example')
                    BlockedSubdomains = @('blocked.allowed.example')
                    IsDisabled = $false
                    PolicyKnown = $true
                    PolicyVersion = 'policy-v1'
                }
                $result = Invoke-NativeHostCheckAction `
                    -Message ([PSCustomObject]@{ domains = @('WWW.Allowed.Example.', 'blocked.allowed.example') }) `
                    -Sections $sections `
                    -State ([PSCustomObject]@{})

                $result.success | Should -BeTrue
                $result.results[0].in_whitelist | Should -BeTrue
                $result.results[0].policy_decision | Should -Be 'allowed'
                $result.results[0].policy_reason | Should -Be 'whitelist-domain'
                $result.results[0].policy_version | Should -Be 'policy-v1'
                $result.results[1].in_whitelist | Should -BeFalse
                $result.results[1].policy_decision | Should -Be 'blocked'
                $result.results[1].policy_reason | Should -Be 'blocked-subdomain'
            }

            It "Treats disabled policy as allowed and an unavailable snapshot as unknown" {
                $inactive = Invoke-NativeHostCheckAction `
                    -Message ([PSCustomObject]@{ domains = @('blocked.example') }) `
                    -Sections ([PSCustomObject]@{ Whitelist = @(); BlockedSubdomains = @(); IsDisabled = $true; PolicyKnown = $true; PolicyVersion = 'disabled-v1' }) `
                    -State ([PSCustomObject]@{})
                $inactive.results[0].in_whitelist | Should -BeTrue
                $inactive.results[0].policy_active | Should -BeFalse
                $inactive.results[0].policy_decision | Should -Be 'allowed'

                $unknown = Invoke-NativeHostCheckAction `
                    -Message ([PSCustomObject]@{ domains = @('blocked.example') }) `
                    -Sections ([PSCustomObject]@{ Whitelist = @(); BlockedSubdomains = @(); IsDisabled = $false; PolicyKnown = $false; PolicyVersion = '' }) `
                    -State ([PSCustomObject]@{})
                $unknown.success | Should -BeFalse
                $unknown.results[0].policy_decision | Should -Be 'unknown'
                $unknown.results[0].policy_reason | Should -Be 'policy-unavailable'
            }

            It "Keeps runtime dependencies exact while captive portal domains include descendants" {
                $sections = [PSCustomObject]@{ Whitelist = @(); BlockedSubdomains = @(); IsDisabled = $false; PolicyKnown = $true; PolicyVersion = 'policy-v1' }
                $state = [PSCustomObject]@{
                    runtimeDependencyDomains = @('cdn.dependency.example')
                    captivePortalDomains = @('portal.example')
                }
                $result = Invoke-NativeHostCheckAction `
                    -Message ([PSCustomObject]@{ domains = @('cdn.dependency.example', 'child.cdn.dependency.example', 'login.portal.example') }) `
                    -Sections $sections `
                    -State $state

                $result.results[0].policy_decision | Should -Be 'allowed'
                $result.results[0].policy_reason | Should -Be 'runtime-dependency-exact'
                $result.results[1].policy_decision | Should -Be 'blocked'
                $result.results[2].policy_decision | Should -Be 'allowed'
                $result.results[2].policy_reason | Should -Be 'captive-portal-domain'
            }

            It "Dispatches get-policy-version from the same snapshot revision" {
                $response = Invoke-NativeHostMessageAction `
                    -Message ([PSCustomObject]@{ action = 'get-policy-version' }) `
                    -State ([PSCustomObject]@{}) `
                    -Sections ([PSCustomObject]@{ PolicyKnown = $true; PolicyVersion = 'policy-v2' }) `
                    -Action 'get-policy-version'
                $response.success | Should -BeTrue
                $response.action | Should -Be 'get-policy-version'
                $response.version | Should -Be 'policy-v2'
            }
        }
    }
}

Describe "Phase 2D native host startup profile and hot path" {
    It "Records a once-per-process startup profile in the native host log" {
        $nativeHostScriptPath = Join-Path $PSScriptRoot ".." "scripts" "OpenPath-NativeHost.ps1"
        $nativeHostContent = Get-Content $nativeHostScriptPath -Raw

        Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
            'function Add-NativeHostStartupProfileEntry',
            'function Write-NativeHostStartupProfile',
            'startup-profile',
            'processToScriptMs',
            "firstEnqueueMs",
            'process-to-script'
        )
    }

    It "Serves ping without loading request setup, TaskRunner or captive portal support files" {
        $windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $childScript = @"
`$ErrorActionPreference = 'Stop'
`$root = '$windowsRoot'
`$script:OpenPathRoot = `$root
`$script:MaxDomains = 50
`$script:MaxMessageBytes = 1MB
. (Join-Path `$root 'lib\internal\NativeHost.State.ps1')
. (Join-Path `$root 'lib\internal\NativeHost.Protocol.ps1')
. (Join-Path `$root 'lib\internal\NativeHost.Actions.ps1')
`$sections = [PSCustomObject]@{ PolicyKnown = `$false; PolicyVersion = ''; Whitelist = @(); BlockedSubdomains = @(); BlockedPaths = @(); AllowedPaths = @() }
`$response = Invoke-NativeHostMessageAction -Message ([PSCustomObject]@{ action = 'ping' }) -State ([PSCustomObject]@{}) -Sections `$sections -Action 'ping'
`$report = [ordered]@{
  ping = [bool]`$response.success
  protocolVersion = [int]`$response.protocolVersion
  requestSetup = [bool](Get-Command -Name 'Get-OpenPathRequestSetupState' -ErrorAction SilentlyContinue)
  taskRunner = [bool](Get-Command -Name 'New-OpenPathSchtasksRunner' -ErrorAction SilentlyContinue)
  captiveQueue = [bool](Get-Command -Name 'Get-NativeHostCaptivePortalRecoveryQueueClassification' -ErrorAction SilentlyContinue)
  recoveryTransition = [bool](Get-Command -Name 'Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary' -ErrorAction SilentlyContinue)
  stateFiles = [bool](Get-Command -Name 'Read-OpenPathCaptivePortalStateJson' -ErrorAction SilentlyContinue)
}
`$report | ConvertTo-Json -Compress
"@
        # Prefer Windows PowerShell (the shell the native host actually runs
        # under, which lacks PowerShell 7-only cmdlets) and fall back to pwsh on
        # non-Windows development hosts.
        $shellExe = if (Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue) { 'powershell.exe' } else { 'pwsh' }
        $output = @(& $shellExe -NoProfile -Command $childScript 2>&1)
        $jsonLine = $output | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
        $report = $jsonLine | ConvertFrom-Json

        $report.ping | Should -BeTrue
        $report.protocolVersion | Should -Be 2
        $report.requestSetup | Should -BeFalse
        $report.taskRunner | Should -BeFalse
        $report.captiveQueue | Should -BeFalse
        $report.recoveryTransition | Should -BeFalse
        $report.stateFiles | Should -BeFalse
    }

    It "Loads request setup, TaskRunner and captive portal support files on demand" {
        $windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $childScript = @"
`$ErrorActionPreference = 'Stop'
`$root = '$windowsRoot'
`$script:OpenPathRoot = `$root
`$script:MaxDomains = 50
`$script:MaxMessageBytes = 1MB
. (Join-Path `$root 'lib\internal\NativeHost.State.ps1')
. (Join-Path `$root 'lib\internal\NativeHost.Protocol.ps1')
. (Join-Path `$root 'lib\internal\NativeHost.Actions.ps1')
Initialize-NativeHostRequestSetupSupport
Initialize-NativeHostTaskRunnerSupport
Initialize-NativeHostCaptivePortalSupportFiles
`$runner = Get-NativeHostTaskRunner
`$report = [ordered]@{
  requestSetup = [bool](Get-Command -Name 'Get-OpenPathRequestSetupState' -ErrorAction SilentlyContinue)
  taskRunner = [bool](Get-Command -Name 'New-OpenPathSchtasksRunner' -ErrorAction SilentlyContinue)
  invokeTask = [bool](Get-Command -Name 'Invoke-OpenPathScheduledTask' -ErrorAction SilentlyContinue)
  runner = [bool]`$runner
  captiveQueue = [bool](Get-Command -Name 'Get-NativeHostCaptivePortalRecoveryQueueClassification' -ErrorAction SilentlyContinue)
  recoveryTransition = [bool](Get-Command -Name 'Get-OpenPathCaptivePortalRecoveryTransitionMarkerSummary' -ErrorAction SilentlyContinue)
  stateFiles = [bool](Get-Command -Name 'Read-OpenPathCaptivePortalStateJson' -ErrorAction SilentlyContinue)
}
`$report | ConvertTo-Json -Compress
"@
        $shellExe = if (Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue) { 'powershell.exe' } else { 'pwsh' }
        $output = @(& $shellExe -NoProfile -Command $childScript 2>&1)
        $jsonLine = $output | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
        $report = $jsonLine | ConvertFrom-Json

        $report.requestSetup | Should -BeTrue
        $report.taskRunner | Should -BeTrue
        $report.invokeTask | Should -BeTrue
        $report.runner | Should -BeTrue
        $report.captiveQueue | Should -BeTrue
        $report.recoveryTransition | Should -BeTrue
        $report.stateFiles | Should -BeTrue
    }
}
