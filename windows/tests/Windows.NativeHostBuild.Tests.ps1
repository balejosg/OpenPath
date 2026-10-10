# Phase 5 B3/B4/B5: compiled native host build, launch-path selection and
# security contracts.

Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

Describe 'Compiled native host (Phase 5)' {
    BeforeAll {
        $script:BuildModulePath = Join-Path $PSScriptRoot '..\lib\internal\NativeHost.Build.ps1'
        $script:CatalogPath = Join-Path $PSScriptRoot '..\lib\internal\NativeHost.ArtifactCatalog.ps1'
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:SourcePath = Join-Path $script:RepoRoot 'windows\native-host\OpenPathNativeHost.cs'
    }

    Context 'Compiler resolution' {
        It 'Resolves the in-box .NET Framework compiler or reports none' {
            . $script:BuildModulePath
            $compiler = Get-OpenPathNativeHostCompilerPath
            if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
                $compiler | Should -Not -Be ''
                $compiler | Should -Match 'csc\.exe$'
                (Test-Path -LiteralPath $compiler) | Should -BeTrue
            }
            else {
                $compiler | Should -Be ''
            }
        }

        It 'Reports the Smart App Control / WDAC state without throwing' {
            . $script:BuildModulePath
            $state = Get-OpenPathSmartAppControlState
            $state.PSObject.Properties['State'] | Should -Not -BeNullOrEmpty
            $state.State | Should -BeIn @('unknown', 'off', 'enforcement', 'evaluation', 'not-configured')
            ($state.BlockingUnsignedBinaries -is [bool]) | Should -BeTrue
        }
    }

    Context 'Build, health check and manifest' {
        BeforeEach {
            . $script:BuildModulePath
            $script:Root = Join-Path $TestDrive ('native-build-' + [guid]::NewGuid().ToString('N'))
            $script:NativeRoot = Join-Path $script:Root 'browser-extension\firefox\native'
            New-Item -ItemType Directory -Path $script:NativeRoot -Force | Out-Null
            $script:Source = Join-Path $script:Root 'OpenPathNativeHost.cs'
            Set-Content -LiteralPath $script:Source -Value '// fixture source' -Encoding ASCII
            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $script:CompileTracker = $compileTracker
            # Fake compiler: writes the requested output and reports success.
            $script:GoodCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                Set-Content -LiteralPath $outputPath -Value 'MZ-fake-executable' -Encoding ASCII
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }.GetNewClosure()
            $script:BadCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                [pscustomobject]@{ ExitCode = 1; Output = 'source.cs(1,1): error CS0000: fixture' }
            }.GetNewClosure()
            $script:HealthyProcess = {
                param($executablePath)
                [pscustomobject]@{ Healthy = $true; Version = '9.9.9'; ProtocolVersion = 2; Capabilities = @('runtime-dependency-check-batch'); ElapsedMs = 12; Error = '' }
            }
            $script:UnhealthyProcess = {
                param($executablePath)
                [pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 10; Error = 'health-check-timeout' }
            }
        }

        It 'Compiles, health-checks and swaps in the executable with a manifest' {
            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess
            $result.Status | Should -Be 'Built'
            $result.BuiltNow | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe')) | Should -BeTrue
            $manifestPath = Join-Path $script:NativeRoot 'OpenPath-NativeHost.manifest.json'
            (Test-Path -LiteralPath $manifestPath) | Should -BeTrue
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest.healthStatus | Should -Be 'healthy'
            $manifest.executable | Should -Be 'OpenPath-NativeHost.exe'
            $manifest.sourceSha256 | Should -Be (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest.executableSha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
            $script:CompileTracker.Calls | Should -Be 1
        }

        It 'Skips the compiler when the source hash matches a healthy manifest' {
            Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess | Out-Null
            $script:CompileTracker.Calls | Should -Be 1
            $second = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess
            $second.Status | Should -Be 'BuildSkipped'
            $script:CompileTracker.Calls | Should -Be 1
        }

        It 'Backs off compiler retries for an hour while the source is unchanged (Phase 5.2 D2)' {
            $first = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:BadCompiler -ProcessInvoker $script:HealthyProcess
            $first.Status | Should -Be 'Fallback'
            $script:CompileTracker.Calls | Should -Be 1

            # Immediate second attempt: no compiler call at all.
            $second = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:BadCompiler -ProcessInvoker $script:HealthyProcess
            $second.Status | Should -Be 'Fallback'
            $second.BackoffActive | Should -BeTrue
            $second.Error | Should -Be 'native-host-compile-backoff'
            $second.NextAttemptAt | Should -Not -BeNullOrEmpty
            $script:CompileTracker.Calls | Should -Be 1

            # A changed source clears the backoff and compiles again.
            Set-Content -LiteralPath $script:Source -Value '// changed after the failure' -Encoding ASCII
            $third = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess
            $third.Status | Should -Be 'Built'
            $script:CompileTracker.Calls | Should -Be 2

            # Force always retries.
            Set-Content -LiteralPath $script:Source -Value '// changed again' -Encoding ASCII
            Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:BadCompiler -ProcessInvoker $script:HealthyProcess | Out-Null
            $forced = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess -Force
            $forced.Status | Should -Be 'Built'
            $script:CompileTracker.Calls | Should -Be 4
        }

        It 'Keeps the previous executable and reports Fallback when compilation fails' {
            Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess | Out-Null
            $executable = Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe'
            $previousHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
            Set-Content -LiteralPath $script:Source -Value '// changed source' -Encoding ASCII
            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:BadCompiler -ProcessInvoker $script:HealthyProcess
            $result.Status | Should -Be 'Fallback'
            $result.Error | Should -Match 'CS0000'
            $result.ExecutablePath | Should -Be $executable
            (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash | Should -Be $previousHash
            $diagnosticsPath = Join-Path $script:NativeRoot 'OpenPath-NativeHost.build.json'
            (Test-Path -LiteralPath $diagnosticsPath) | Should -BeTrue
            ((Get-Content -LiteralPath $diagnosticsPath -Raw | ConvertFrom-Json).status) | Should -Be 'CompilationFailed'
        }

        It 'Never swaps in an executable that fails the framed ping health check' {
            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:UnhealthyProcess
            $result.Status | Should -Be 'Fallback'
            $result.Error | Should -Be 'health-check-timeout'
            (Test-Path -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe')) | Should -BeFalse
            $result.ExecutablePath | Should -Be ''
            $diagnostics = Get-Content -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.build.json') -Raw | ConvertFrom-Json
            $diagnostics.status | Should -Be 'HealthCheckFailed'
        }

        It 'Reports SourceMissing when the payload source is absent' {
            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath (Join-Path $script:Root 'missing.cs') -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess
            $result.Status | Should -Be 'Fallback'
            $result.Error | Should -Be 'native-host-source-missing'
            $script:CompileTracker.Calls | Should -Be 0
        }

        It 'Points the launch path at the executable only for a healthy matching manifest' {
            (Get-OpenPathNativeHostLaunchPath -NativeRoot $script:NativeRoot) | Should -Be (Join-Path $script:NativeRoot 'OpenPath-NativeHost.cmd')
            Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess | Out-Null
            (Get-OpenPathNativeHostLaunchPath -NativeRoot $script:NativeRoot) | Should -Be (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe')
            # A tampered executable no longer matches the manifest hash.
            Set-Content -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe') -Value 'tampered' -Encoding ASCII
            (Get-OpenPathNativeHostLaunchPath -NativeRoot $script:NativeRoot) | Should -Be (Join-Path $script:NativeRoot 'OpenPath-NativeHost.cmd')
        }

        It 'Removes the executable, manifest and temp files on uninstall cleanup' {
            Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess | Out-Null
            New-Item -ItemType File -Path (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe.deadbeef.tmp') -Force | Out-Null
            Remove-OpenPathNativeHostExecutableArtifacts -NativeRoot $script:NativeRoot
            (Test-Path -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe')) | Should -BeFalse
            (Test-Path -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.manifest.json')) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:NativeRoot -Filter '*.tmp' -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
    }

    Context 'Artifact catalog and offline staging' {
        It 'Stages the C# source and searches the native-host install directory' {
            . $script:CatalogPath
            @(Get-OpenPathNativeHostArtifactNames) | Should -Contain 'OpenPathNativeHost.cs'
            $sourceRoot = Join-Path $TestDrive 'scripts'
            New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
            $roots = @(Get-OpenPathNativeHostArtifactCandidateRoots -SourceRoot $sourceRoot)
            $roots | Should -Contain (Join-Path (Split-Path $sourceRoot -Parent) 'native-host')
        }

        It 'Resolves the repository source from the native-host candidate root' {
            . $script:CatalogPath
            $resolution = Resolve-OpenPathNativeHostArtifactSources `
                -ArtifactNames @('OpenPathNativeHost.cs') `
                -CandidateRoots @(Join-Path $script:RepoRoot 'windows\native-host')
            @($resolution.Missing).Count | Should -Be 0
            $resolution.Sources['OpenPathNativeHost.cs'] | Should -Be (Join-Path $script:RepoRoot 'windows\native-host')
        }

        It 'Treats the C# source as an optional build input and stages it in the install root' {
            . $script:CatalogPath
            (Test-OpenPathNativeHostBuildInput -Name 'OpenPathNativeHost.cs') | Should -BeTrue
            (Test-OpenPathNativeHostBuildInput -Name 'OpenPath-NativeHost.ps1') | Should -BeFalse

            # A sync on an updated machine must not fail when only the build
            # input is missing; the existing host stays registered.
            $syncText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\Browser.FirefoxNativeHost.psm1') -Raw
            $syncText | Should -Match 'Test-OpenPathNativeHostBuildInput'
            $syncText | Should -Match 'keeping the existing host'

            # The installer stages native-host/ at the install root, keeps it
            # across reinstalls and the offline path requires it.
            $stagingText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\install\Installer.Staging.ps1') -Raw
            $stagingText | Should -Match "Join-Path \`$ScriptDir 'native-host'"
            $stagingText | Should -Match "Join-Path \`$OpenPathRoot 'native-host'"
            $cleanupText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\install\Installer.Cleanup.ps1') -Raw
            $cleanupText | Should -Match "'native-host'"
            $directStagingText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\windows-direct-runtime-staging.ps1') -Raw
            $directStagingText | Should -Match 'windows\\native-host'
        }
    }

    Context 'Registration contract' {
        It 'Registers the compiled host after a health-checked build and keeps the cmd fallback' {
            $moduleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\Browser.FirefoxNativeHost.psm1') -Raw
            $moduleText | Should -Match 'Build-OpenPathFirefoxNativeHostExecutable'
            $moduleText | Should -Match 'Get-OpenPathNativeHostLaunchPath -NativeRoot \$nativeRoot'
            $moduleText | Should -Match 'path = \$launchPath'
            # Phase 8: the availability message is logged once per state change
            # with the product reason code; with the classroom AppControl
            # boundary the restricted student has no PowerShell fallback at all.
            $moduleText | Should -Match 'Write-OpenPathNativeHostFallbackState'
            $moduleText | Should -Match 'Restricted student users have no native host'
        }

        It 'Removes the compiled host artifacts on unregister' {
            $moduleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\Browser.FirefoxNativeHost.psm1') -Raw
            $moduleText | Should -Match 'Remove-OpenPathNativeHostExecutableArtifacts'
        }
    }

    Context 'Security contracts (B4)' {
        BeforeAll {
            $script:SourceText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'windows\native-host\OpenPathNativeHost.cs') -Raw
        }

        It 'Never launches an interpreter from the compiled host' {
            $script:SourceText | Should -Not -Match 'powershell\.exe'
            $script:SourceText | Should -Not -Match 'pwsh\.exe'
            $script:SourceText | Should -Not -Match 'cmd\.exe'
            $script:SourceText | Should -Match 'schtasks\.exe'
        }

        It 'Invokes schtasks through the absolute system path (Phase 5.2 D4)' {
            # A relative schtasks.exe inherits the caller's environment and can
            # be hijacked by a planted executable on PATH.
            $script:SourceText | Should -Not -Match 'FileName\s*=\s*"schtasks\.exe"'
            ([regex]::Matches($script:SourceText, 'GetSystemExecutablePath\("schtasks\.exe"\)')).Count | Should -Be 2
        }

        It 'Uses no dynamic code, runtime reflection or optional assemblies' {
            # Phase 8: the assembly metadata attributes need `using
            # System.Reflection`; runtime reflection stays forbidden.
            $reflectionUsages = @(
                $script:SourceText -split "`r?`n" |
                    Where-Object { $_ -match 'System\.Reflection' -and $_ -notmatch '^using System\.Reflection;$' }
            )
            $reflectionUsages.Count | Should -Be 0
            $script:SourceText | Should -Not -Match 'Assembly\.Load'
            $script:SourceText | Should -Not -Match 'Add-Type'
            $script:SourceText | Should -Not -Match 'System\.Web'
            $script:SourceText | Should -Not -Match 'dynamic '
        }

        It 'Generates request ids in the safe guid-N format and enforces the 1MB frame cap' {
            $script:SourceText | Should -Match 'Guid\.NewGuid\(\)\.ToString\("N"\)'
            $script:SourceText | Should -Match 'MaxMessageBytes = 1048576'
            # The SYSTEM consumer keeps its own request-id validation.
            $runnerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\internal\CaptivePortal.RecoveryRunner.ps1') -Raw
            $runnerText | Should -Match 'Test-OpenPathRecoveryRequestId'
        }

        It 'Rejects sensitive dependency fields and validates hosts' {
            $script:SourceText | Should -Match 'Sensitive fields are not accepted'
            $script:SourceText | Should -Match 'Blocked hosts are not accepted as runtime dependencies'
            $script:SourceText | Should -Match 'Protected hosts are not accepted as runtime dependencies'
        }
    }

    Context 'Integrity and uninstall coverage' {
        It 'Covers the compiled executable in the integrity baseline when present' {
            $integrityPath = Join-Path $PSScriptRoot '..\lib\internal\Common.Integrity.ps1'
            $root = Join-Path $TestDrive ('integrity-' + [guid]::NewGuid().ToString('N'))
            $native = Join-Path $root 'browser-extension\firefox\native'
            New-Item -ItemType Directory -Path $native -Force | Out-Null
            # Common.Integrity.ps1 resolves $script:OpenPathRoot; run it in a
            # child scope that sets the variable first.
            $scriptBlock = [scriptblock]::Create(@"
`$script:OpenPathRoot = '$root'
. '$integrityPath'
@(Get-OpenPathCriticalFiles | Where-Object { `$_ -like '*browser-extension*OpenPath-NativeHost.exe' }).Count
"@)
            Set-Content -LiteralPath (Join-Path $native 'OpenPath-NativeHost.exe') -Value 'MZ' -Encoding ASCII
            (& $scriptBlock) | Should -Be 1
            Remove-Item -LiteralPath (Join-Path $native 'OpenPath-NativeHost.exe') -Force
            (& $scriptBlock) | Should -Be 0
        }

        It 'Uninstalls the compiled host artifacts explicitly' {
            $uninstallText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Uninstall-OpenPath.ps1') -Raw
            $uninstallText | Should -Match 'OpenPath-NativeHost\.exe'
            $uninstallText | Should -Match 'OpenPathNativeHost\.cs'
            $uninstallText | Should -Match 'OpenPath-NativeHost\.manifest\.json'
        }
    }

    Context 'Signed prebuilt host (Phase 8)' {
        BeforeEach {
            . $script:BuildModulePath
            $script:Root = Join-Path $TestDrive ('native-signed-' + [guid]::NewGuid().ToString('N'))
            $script:NativeRoot = Join-Path $script:Root 'browser-extension\firefox\native'
            $script:SignedRoot = Join-Path $script:Root 'native-host\signed'
            New-Item -ItemType Directory -Path $script:NativeRoot, $script:SignedRoot -Force | Out-Null
            $script:Source = Join-Path $script:Root 'OpenPathNativeHost.cs'
            Set-Content -LiteralPath $script:Source -Value '// fixture source' -Encoding ASCII
            $script:SignedExe = Join-Path $script:SignedRoot 'OpenPath-NativeHost.exe'
            Set-Content -LiteralPath $script:SignedExe -Value 'MZ-signed-executable' -Encoding ASCII
            $script:SignedMetadataPath = Join-Path $script:SignedRoot 'OpenPath-NativeHost.signing.json'
            $script:SignedSha = (Get-FileHash -LiteralPath $script:SignedExe -Algorithm SHA256).Hash.ToLowerInvariant()
            $script:SourceSha = (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash.ToLowerInvariant()
            $script:Pin = [pscustomobject]@{
                Subject     = 'CN=SignPath Foundation'
                Issuer      = 'CN=SignPath Issuing CA'
                Description = 'OpenPath native host'
            }
            $script:GoodSignature = {
                param($path)
                [pscustomobject]@{
                    Status        = 'Valid'
                    StatusMessage = 'ok'
                    Subject       = 'CN=SignPath Foundation'
                    Issuer        = 'CN=SignPath Issuing CA'
                    Thumbprint    = 'ABCDEF'
                    Timestamped   = $true
                    Description   = 'OpenPath native host'
                }
            }
            $script:HealthyProcess = {
                param($executablePath)
                [pscustomobject]@{ Healthy = $true; Version = '9.9.9'; ProtocolVersion = 2; Capabilities = @(); ElapsedMs = 5; Error = '' }
            }
        }

        It 'Fails closed while the publisher pin is empty' {
            $verification = Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $script:SignedSha
            $verification.Valid | Should -BeFalse
            $verification.Reason | Should -Be 'signature-pin-not-configured'
        }

        It 'Accepts a coherent signature and rejects every mismatch' {
            $good = Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $script:SignedSha -Pin $script:Pin -SignatureReader $script:GoodSignature
            $good.Valid | Should -BeTrue
            $good.Reason | Should -Be 'signature-valid'

            $zeros = ('0' * 64) -join ''
            (Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $zeros -Pin $script:Pin -SignatureReader $script:GoodSignature).Reason | Should -Be 'signed-sha256-mismatch'
            (Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $script:SignedSha -Pin $script:Pin -SignatureReader { param($p) [pscustomobject]@{ Status = 'UnknownError'; StatusMessage = 'untrusted root'; Timestamped = $true } }).Reason | Should -Match 'signature-invalid'
            (Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $script:SignedSha -Pin $script:Pin -SignatureReader { param($p) [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=SignPath Foundation'; Issuer = 'CN=SignPath Issuing CA'; Timestamped = $false } }).Reason | Should -Be 'signature-not-timestamped'
            (Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $script:SignedSha -Pin $script:Pin -SignatureReader { param($p) [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=Someone Else'; Issuer = 'CN=SignPath Issuing CA'; Timestamped = $true } }).Reason | Should -Be 'signature-subject-mismatch'
            (Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $script:SignedSha -Pin $script:Pin -SignatureReader { param($p) [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=SignPath Foundation'; Issuer = 'CN=Other CA'; Timestamped = $true } }).Reason | Should -Be 'signature-issuer-mismatch'
            (Test-OpenPathNativeHostSignedExecutable -ExecutablePath $script:SignedExe -ExpectedSha256 $script:SignedSha -Pin $script:Pin -SignatureReader { param($p) [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=SignPath Foundation'; Issuer = 'CN=SignPath Issuing CA'; Timestamped = $true; Description = 'Something else' } }).Reason | Should -Be 'signature-description-mismatch'
        }

        It 'Anchors the candidate on the payload manifest and installs it without compiling' {
            $manifestPath = Join-Path $script:Root 'payload-manifest.json'
            @{ schemaVersion = 1; payloads = @(@{ path = 'native-host/signed/OpenPath-NativeHost.exe'; sha256 = $script:SignedSha }) } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            @{ sourceSha256 = $script:SourceSha; executableSha256 = $script:SignedSha; signerSubject = 'CN=SignPath Foundation'; signerIssuer = 'CN=SignPath Issuing CA' } |
                ConvertTo-Json | Set-Content -LiteralPath $script:SignedMetadataPath -Encoding UTF8

            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $neverCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                [pscustomobject]@{ ExitCode = 1; Output = 'compilation must not run' }
            }.GetNewClosure()

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -PayloadManifestPath $manifestPath -SignaturePin $script:Pin -SignatureReader $script:GoodSignature -CompilerInvoker $neverCompiler -ProcessInvoker $script:HealthyProcess
            $result.Status | Should -Be 'Built'
            $result.HostSource | Should -Be 'signed-prebuilt'
            $result.BuiltNow | Should -BeTrue
            $compileTracker.Calls | Should -Be 0
            $manifest = Get-Content -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.manifest.json') -Raw | ConvertFrom-Json
            $manifest.hostSource | Should -Be 'signed-prebuilt'
            $manifest.signerSubject | Should -Be 'CN=SignPath Foundation'
            $manifest.anchorSource | Should -Be 'payload-manifest'
            $manifest.sourceSha256 | Should -Be $script:SourceSha
        }

        It 'Rejects a candidate missing from the payload manifest and compiles instead' {
            @{ schemaVersion = 1; payloads = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Root 'payload-manifest.json') -Encoding UTF8
            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $goodCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                Set-Content -LiteralPath $outputPath -Value 'MZ-compiled' -Encoding ASCII
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }.GetNewClosure()

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -SignaturePin $script:Pin -SignatureReader $script:GoodSignature -CompilerInvoker $goodCompiler -ProcessInvoker $script:HealthyProcess
            $result.Status | Should -Be 'Built'
            $result.HostSource | Should -Be 'compiled'
            $result.SignatureRejectedReason | Should -Be 'signed-candidate-payload-anchor-missing'
            $compileTracker.Calls | Should -Be 1
        }

        It 'A valid signed candidate bypasses the compile backoff' {
            @{ status = 'HealthCheckFailed'; error = 'fixture'; sourceSha256 = $script:SourceSha; attempts = 1; attemptedAt = (Get-Date).ToUniversalTime().ToString('o') } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.build.json') -Encoding UTF8
            @{ sourceSha256 = $script:SourceSha; executableSha256 = $script:SignedSha } |
                ConvertTo-Json | Set-Content -LiteralPath $script:SignedMetadataPath -Encoding UTF8
            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $neverCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                [pscustomobject]@{ ExitCode = 1; Output = 'compilation must not run' }
            }.GetNewClosure()

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -SignaturePin $script:Pin -SignatureReader $script:GoodSignature -CompilerInvoker $neverCompiler -ProcessInvoker $script:HealthyProcess
            $result.BackoffActive | Should -BeFalse
            $result.Status | Should -Be 'Built'
            $result.HostSource | Should -Be 'signed-prebuilt'
            $compileTracker.Calls | Should -Be 0
        }

        It 'Records the rejected signature reason when the fallback compiles' {
            $zeros = ('0' * 64) -join ''
            @{ sourceSha256 = $script:SourceSha; executableSha256 = $zeros } |
                ConvertTo-Json | Set-Content -LiteralPath $script:SignedMetadataPath -Encoding UTF8
            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $goodCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                Set-Content -LiteralPath $outputPath -Value 'MZ-compiled' -Encoding ASCII
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }.GetNewClosure()

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -SignaturePin $script:Pin -SignatureReader $script:GoodSignature -CompilerInvoker $goodCompiler -ProcessInvoker $script:HealthyProcess
            $result.Status | Should -Be 'Built'
            $result.HostSource | Should -Be 'compiled'
            $result.SignatureRejectedReason | Should -Be 'signed-sha256-mismatch'
            $diagnostics = Get-Content -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.build.json') -Raw | ConvertFrom-Json
            $diagnostics.signatureRejectedReason | Should -Be 'signed-sha256-mismatch'
        }

        It 'Rejects an executable signed by an untrusted self-signed certificate and compiles (Windows only)' {
            if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') { return }
            $compilerPath = Get-OpenPathNativeHostCompilerPath
            if (-not $compilerPath) { Set-ItResult -Skipped -Because 'the in-box csc.exe is not available'; return }
            $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=OpenPath Test Signer' -CertStoreLocation 'Cert:\CurrentUser\My'
            try {
                # A tiny fresh PE with no catalog fallback: a Microsoft system
                # binary would let Get-AuthenticodeSignature read its catalog
                # signature after a failed embed and hide what is being tested.
                $controlSource = Join-Path $script:Root 'self-signed-control.cs'
                Set-Content -LiteralPath $controlSource -Value 'public static class OpenPathSignedTest { public static void Main() { } }' -Encoding ASCII
                $selfSignedPath = Join-Path $script:Root 'self-signed-candidate.exe'
                $compile = Invoke-OpenPathNativeHostCompilation -SourcePath $controlSource -OutputPath $selfSignedPath -CompilerPath $compilerPath
                $compile.Success | Should -BeTrue -Because "test fixture compilation failed: $($compile.Output)"
                $signResult = Set-AuthenticodeSignature -LiteralPath $selfSignedPath -Certificate $certificate -HashAlgorithm SHA256
                $signResult.Status | Should -Not -Be 'NotSigned' -Because "Set-AuthenticodeSignature: $($signResult.Status) $($signResult.StatusMessage)"
                $signatureAfterSign = Get-AuthenticodeSignature -LiteralPath $selfSignedPath
                $signatureAfterSign.SignatureType | Should -Be 'Authenticode' -Because "the fixture must carry an embedded signature, got SignatureType=$($signatureAfterSign.SignatureType) Status=$($signatureAfterSign.Status)"
                $selfSignedSha = (Get-FileHash -LiteralPath $selfSignedPath -Algorithm SHA256).Hash.ToLowerInvariant()
                $selfSignedPin = [pscustomobject]@{ Subject = 'CN=OpenPath Test Signer'; Issuer = [string]$certificate.Issuer; Description = '' }
                $verification = Test-OpenPathNativeHostSignedExecutable -ExecutablePath $selfSignedPath -ExpectedSha256 $selfSignedSha -Pin $selfSignedPin
                $verification.Valid | Should -BeFalse
                $verification.Reason | Should -Match 'signature-invalid'

                # The staged candidate is rejected outright, so the product compiles.
                Copy-Item -LiteralPath $selfSignedPath -Destination $script:SignedExe -Force
                $stagedSha = (Get-FileHash -LiteralPath $script:SignedExe -Algorithm SHA256).Hash.ToLowerInvariant()
                @{ sourceSha256 = $script:SourceSha; executableSha256 = $stagedSha } |
                    ConvertTo-Json | Set-Content -LiteralPath $script:SignedMetadataPath -Encoding UTF8
                $compileTracker = [pscustomobject]@{ Calls = 0 }
                $goodCompiler = {
                    param($sourcePath, $outputPath)
                    $compileTracker.Calls = $compileTracker.Calls + 1
                    Set-Content -LiteralPath $outputPath -Value 'MZ-compiled' -Encoding ASCII
                    [pscustomobject]@{ ExitCode = 0; Output = '' }
                }.GetNewClosure()

                $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -SignaturePin $selfSignedPin -CompilerInvoker $goodCompiler -ProcessInvoker $script:HealthyProcess
                $result.Status | Should -Be 'Built'
                $result.HostSource | Should -Be 'compiled'
                $compileTracker.Calls | Should -Be 1
            }
            finally {
                Remove-Item -LiteralPath $certificate.PSPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
