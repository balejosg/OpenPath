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
                $nativeFiles = @(
                    "OpenPath-NativeHost.ps1",
                    "OpenPath-NativeHost.cmd",
                    "RequestSetup.State.psm1",
                    "NativeHost.State.ps1",
                    "NativeHost.Protocol.ps1",
                    "NativeHost.Actions.ps1"
                )

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
            $browserContent = Get-Content $browserModulePath -Raw
            $nativeHostContent = Get-Content $nativeHostModulePath -Raw

            Assert-ContentContainsAll -Content $nativeHostContent -Needles @(
                'function Sync-OpenPathFirefoxNativeHostArtifacts',
                "OpenPath-NativeHost.ps1",
                "OpenPath-NativeHost.cmd",
                "RequestSetup.State.psm1",
                "NativeHost.State.ps1",
                "NativeHost.Protocol.ps1",
                "NativeHost.Actions.ps1",
                '(Join-Path $sourceParent ''lib'')',
                '(Join-Path $sourceParent ''lib\internal'')'
            )

            Assert-ContentContainsAll -Content $browserContent -Needles @(
                'function Sync-OpenPathFirefoxNativeHostArtifacts',
                'Browser.FirefoxNativeHost\Sync-OpenPathFirefoxNativeHostArtifacts -SourceRoot $SourceRoot'
            )

            $nativeActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeActionsContent = Get-Content $nativeActionsPath -Raw
            Assert-ContentContainsAll -Content $nativeActionsContent -Needles @(
                'Import-NativeHostRequestSetupStateModule',
                'RequestSetup.State.psm1',
                'Get-OpenPathRequestSetupState -Config $State',
                'RequestSetup.State.psm1 is required for native host request setup interpretation.',
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
                '(Join-Path $script:NativeRoot $FileName)',
                '(Join-Path $script:OpenPathRoot "lib\internal\$FileName")',
                '. (Resolve-OpenPathNativeHostSupportPath -FileName ''NativeHost.State.ps1'')',
                '. (Resolve-OpenPathNativeHostSupportPath -FileName ''NativeHost.Protocol.ps1'')',
                '. (Resolve-OpenPathNativeHostSupportPath -FileName ''NativeHost.Actions.ps1'')'
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
                "(A;;GRGX;;;BU)",
                'Grant-OpenPathTaskRunAccessToUsers -TaskName $updateDefinition.TaskName'
            )

            Assert-ContentContainsAll -Content $taskHelperContent -Needles @(
                'function New-OpenPathUpdateTaskDefinition',
                '-TaskName "$TaskPrefix-Update"'
            )
        }

        It "Waits for requested update-whitelist domains to reach the native whitelist mirror" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = Get-Content $nativeHostActionsPath -Raw

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'function Get-NativeHostValidDomains',
                'function Test-NativeWhitelistContainsDomains',
                'function Invoke-NativeHostSharedUpdateTrigger',
                'Global\OpenPathNativeWhitelistUpdateTrigger',
                '$Message.domains',
                'Invoke-UpdateTask -Domains $domains',
                'Get-WhitelistSections',
                'Start-Sleep -Milliseconds 1000',
                'OpenPath update task did not write expected domains'
            )
        }

        It "Returns blocked subdomains from the native whitelist mirror" {
            $nativeStatePath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.State.ps1"
            $nativeActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $stateContent = Get-Content $nativeStatePath -Raw
            $actionsContent = Get-Content $nativeActionsPath -Raw

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

        It "Supports local runtime dependency overlay action without full URL fields" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = Get-Content $nativeHostActionsPath -Raw
            $installerStagingPath = Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Staging.ps1"
            $installerStagingContent = Get-Content $installerStagingPath -Raw
            $updateRuntimePath = Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1"
            $updateRuntimeContent = Get-Content $updateRuntimePath -Raw

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'allow-local-runtime-dependency',
                'function Invoke-NativeHostLocalRuntimeDependencyAction',
                'function Get-NativeHostRuntimeDependencyQueuePath',
                'function Write-NativeHostRuntimeDependencyQueueRequest',
                'anchorHost',
                'dependencyHost',
                'requestType',
                'runtime-dependency-queue',
                'source = ''firefox-webrequest-local''',
                'Sensitive fields are not accepted'
            )
            Assert-ContentContainsAll -Content $installerStagingContent -Needles @(
                '$OpenPathRoot\data\runtime-dependency-queue',
                '"BUILTIN\Users", "Modify"',
                'Set-Acl $runtimeDependencyQueuePath $runtimeDependencyQueueAcl',
                "'RequestSetup.State.psm1'"
            )
            Assert-ContentContainsAll -Content $updateRuntimeContent -Needles @(
                'Invoke-OpenPathRuntimeDependencyQueue',
                'Update-AcrylicHost -WhitelistedDomains $runtimeDependencyQueueSections.Whitelist',
                'Runtime dependency queue processed'
            )

            $nativeHostActionsContent | Should -Not -Match 'Write-NativeHostRuntimeDependencyOverlay'
            $nativeHostActionsContent | Should -Not -Match 'Read-NativeHostRuntimeDependencyOverlay'
            $nativeHostActionsContent | Should -Not -Match 'Update-AcrylicHost -WhitelistedDomains'
            $nativeHostActionsContent | Should -Not -Match '\[string\]\$Host\b'
            $nativeHostActionsContent | Should -Not -Match 'foreach \(\$host in'
            $nativeHostActionsContent | Should -Not -Match '/api/requests/auto'
        }

        It "Logs native action evidence without depending on downstream wrappers" {
            $nativeHostActionsPath = Join-Path $PSScriptRoot ".." "lib" "internal" "NativeHost.Actions.ps1"
            $nativeHostActionsContent = Get-Content $nativeHostActionsPath -Raw

            Assert-ContentContainsAll -Content $nativeHostActionsContent -Needles @(
                'function Write-NativeHostActionLog',
                'function Invoke-NativeHostMessageAction',
                'Get-Command Write-NativeHostLog -ErrorAction SilentlyContinue',
                'action=$Action',
                'elapsedMs=',
                'domains=',
                "if (`$action -ne 'update-whitelist')",
                "Write-NativeHostActionLog -Action `$action",
                'Write-NativeHostActionLog -Action ''update-whitelist'''
            )

            $nativeHostActionsContent | Should -Not -Match ('Classroom' + 'Path')
            $nativeHostActionsContent | Should -Not -Match ('C' + 'P_')
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
