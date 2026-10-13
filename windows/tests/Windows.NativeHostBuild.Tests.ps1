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

    Context 'Transient health retry and cause-based backoff (Phase 8b)' {
        BeforeEach {
            . $script:BuildModulePath
            $script:Root = Join-Path $TestDrive ('native-retry-' + [guid]::NewGuid().ToString('N'))
            $script:NativeRoot = Join-Path $script:Root 'browser-extension\firefox\native'
            New-Item -ItemType Directory -Path $script:NativeRoot -Force | Out-Null
            $script:Source = Join-Path $script:Root 'OpenPathNativeHost.cs'
            Set-Content -LiteralPath $script:Source -Value '// fixture source' -Encoding ASCII
            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $script:CompileTracker = $compileTracker
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
                param($executablePath, $timeoutSeconds)
                [pscustomobject]@{ Healthy = $true; Version = '9.9.9'; ProtocolVersion = 2; Capabilities = @(); ElapsedMs = 12; Error = '' }
            }
            $script:AlwaysTimeoutProcess = {
                param($executablePath, $timeoutSeconds)
                [pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 20100; Error = 'health-check-timeout' }
            }
            $script:PingCalls = New-Object System.Collections.ArrayList
            $pingCalls = $script:PingCalls
            $script:TimeoutThenHealthyProcess = {
                param($executablePath, $timeoutSeconds)
                $null = $pingCalls.Add([int]$timeoutSeconds)
                if ($pingCalls.Count -eq 1) {
                    [pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 20100; Error = 'health-check-timeout' }
                }
                else {
                    [pscustomobject]@{ Healthy = $true; Version = '9.9.9'; ProtocolVersion = 2; Capabilities = @(); ElapsedMs = 20; Error = '' }
                }
            }.GetNewClosure()
            $script:AppControlBlockedProcess = {
                param($executablePath, $timeoutSeconds)
                [pscustomobject]@{
                    Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 300
                    Error = 'Exception calling "Start" with "1" argument(s): "An Application Control policy has blocked this file"'
                }
            }
            $script:DiagnosticsPath = Join-Path $script:NativeRoot 'OpenPath-NativeHost.build.json'
        }

        It 'Classifies only timeout and AppControl-launch failures as retryable' {
            . $script:BuildModulePath
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $false; Error = 'health-check-timeout' })) | Should -BeTrue
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $false; Error = 'An Application Control policy has blocked this file' })) | Should -BeTrue
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $false; Error = 'health-check-length' })) | Should -BeFalse
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $false; Error = 'health-check-response' })) | Should -BeFalse
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $true; Error = '' })) | Should -BeFalse
            (Get-OpenPathNativeHostHealthRetryDelayMinutes -HealthAttempts 1) | Should -Be 5
            (Get-OpenPathNativeHostHealthRetryDelayMinutes -HealthAttempts 2) | Should -Be 15
            (Get-OpenPathNativeHostHealthRetryDelayMinutes -HealthAttempts 3) | Should -Be 60
            (Get-OpenPathNativeHostHealthRetryDelayMinutes -HealthAttempts 9) | Should -Be 60
        }

        It 'Does not retry a clean immediate exit: H1 is deterministic (Phase 8e E0.4)' {
            # Phase 8d D4 retried a clean exit because "a second launch of the
            # same binary answers". That premise was false: the working probe
            # was another copy launched from pwsh. The clean exit is the
            # deterministic consequence of a UTF-8 preamble in front of the
            # frame (Phase 8e E0), so it is not retryable.
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $false; Error = 'health-check-exited'; ExitCode = 0; HasExited = $true })) | Should -BeFalse
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $false; Error = 'health-check-exited'; ExitCode = 3; HasExited = $true })) | Should -BeFalse
            (Test-OpenPathNativeHostHealthFailureRetryable -Health ([pscustomobject]@{ Healthy = $false; Error = 'health-check-exited'; HasExited = $true })) | Should -BeFalse

            $script:PingQueue = New-Object System.Collections.ArrayList
            $null = $script:PingQueue.Add([pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 2764; Error = 'health-check-exited'; StartMs = 100; Pid = 41; HasExited = $true; ExitCode = 0; CpuMs = 125; Stderr = '' })
            $null = $script:PingQueue.Add([pscustomobject]@{ Healthy = $true; Version = '9.9.9'; ProtocolVersion = 2; Capabilities = @(); ElapsedMs = 220; Error = ''; StartMs = 5000; Pid = 42; HasExited = $false; ExitCode = $null; CpuMs = 210; Stderr = '' })
            $queue = $script:PingQueue
            $process = {
                param($executablePath, $timeoutSeconds)
                $record = $queue[0]
                $queue.RemoveAt(0)
                $record
            }.GetNewClosure()

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $process

            $result.Status | Should -Be 'Fallback'
            $result.Health.Attempts | Should -Be 1
            @($script:PingQueue).Count | Should -Be 1 -Because 'the clean exit must not consume a second launch'
            $script:CompileTracker.Calls | Should -Be 1
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            @($diagnostics.lastPings).Count | Should -Be 1
            $diagnostics.lastPings[0].error | Should -Be 'health-check-exited'
            (Test-Path -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe')) | Should -BeFalse
        }

        It 'Retries a timed-out ping once with a longer timeout before building' {
            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:TimeoutThenHealthyProcess
            $result.Status | Should -Be 'Built'
            @($script:PingCalls).Count | Should -Be 2
            [int]$script:PingCalls[0] | Should -Be 20
            [int]$script:PingCalls[1] | Should -BeGreaterThan 20
            $result.Health.Attempts | Should -Be 2
            $manifest = Get-Content -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.manifest.json') -Raw | ConvertFrom-Json
            $manifest.healthStatus | Should -Be 'healthy'
        }

        It 'Retries an AppControl 4551 launch denial once and only then backs off' {
            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:AppControlBlockedProcess
            $result.Status | Should -Be 'Fallback'
            $result.Health.Attempts | Should -Be 2
            (Test-Path -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe')) | Should -BeFalse
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.status | Should -Be 'HealthCheckFailed'
            $diagnostics.error | Should -Match 'application control policy has blocked'
            $diagnostics.pingAttempts | Should -Be 2
            $diagnostics.attempts | Should -Be 1
            $diagnostics.healthAttempts | Should -Be 1
            $diagnostics.retryDelayMinutes | Should -Be 5
        }

        It 'Keeps the previous healthy executable when a new source fails health after the retry' {
            Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess | Out-Null
            $executable = Join-Path $script:NativeRoot 'OpenPath-NativeHost.exe'
            $previousHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
            Set-Content -LiteralPath $script:Source -Value '// changed source' -Encoding ASCII

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:AlwaysTimeoutProcess
            $result.Status | Should -Be 'Fallback'
            $result.ExecutablePath | Should -Be $executable
            (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash | Should -Be $previousHash
            $manifest = Get-Content -LiteralPath (Join-Path $script:NativeRoot 'OpenPath-NativeHost.manifest.json') -Raw | ConvertFrom-Json
            $manifest.healthStatus | Should -Be 'healthy'
        }

        It 'Grows the health backoff 5 -> 15 -> 60 minutes and caps the retries per hour' {
            $build = {
                Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:AlwaysTimeoutProcess
            }
            $setAttemptedAtMinutesAgo = {
                param([int]$MinutesAgo)
                $doc = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
                $doc.attemptedAt = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesAgo).ToString('o')
                $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:DiagnosticsPath -Encoding UTF8
            }

            $first = & $build
            $first.Status | Should -Be 'Fallback'
            $script:CompileTracker.Calls | Should -Be 1
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.healthAttempts | Should -Be 1
            $diagnostics.retryDelayMinutes | Should -Be 5
            [math]::Round((([datetime]$diagnostics.nextAttemptAt) - ([datetime]$diagnostics.attemptedAt)).TotalMinutes) | Should -Be 5

            # The immediate second ensure is refused without compiling.
            $second = & $build
            $second.Status | Should -Be 'Fallback'
            $second.BackoffActive | Should -BeTrue
            $second.Error | Should -Be 'native-host-health-backoff'
            $script:CompileTracker.Calls | Should -Be 1
            $second.NextAttemptAt | Should -Not -BeNullOrEmpty

            # Six minutes later the retry compiles again and grows to 15.
            & $setAttemptedAtMinutesAgo -MinutesAgo 6
            $third = & $build
            $third.Status | Should -Be 'Fallback'
            $script:CompileTracker.Calls | Should -Be 2
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.healthAttempts | Should -Be 2
            $diagnostics.retryDelayMinutes | Should -Be 15

            # The grown delay is honoured, then the streak reaches 60.
            $blocked = & $build
            $blocked.BackoffActive | Should -BeTrue
            $script:CompileTracker.Calls | Should -Be 2
            & $setAttemptedAtMinutesAgo -MinutesAgo 16
            $fourth = & $build
            $script:CompileTracker.Calls | Should -Be 3
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.healthAttempts | Should -Be 3
            $diagnostics.retryDelayMinutes | Should -Be 60

            # One hour per retry from now on: no compile loop.
            & $setAttemptedAtMinutesAgo -MinutesAgo 61
            $fifth = & $build
            $script:CompileTracker.Calls | Should -Be 4
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.healthAttempts | Should -Be 4
            $diagnostics.retryDelayMinutes | Should -Be 60
            $immediate = & $build
            $immediate.BackoffActive | Should -BeTrue
            $immediate.Error | Should -Be 'native-host-health-backoff'
            $script:CompileTracker.Calls | Should -Be 4
        }

        It 'Keeps the one-hour backoff for compilation failures and resets the counters with a new source' {
            $first = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:BadCompiler -ProcessInvoker $script:HealthyProcess
            $first.Status | Should -Be 'Fallback'
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.status | Should -Be 'CompilationFailed'
            $diagnostics.healthAttempts | Should -Be 0
            $diagnostics.retryDelayMinutes | Should -Be 60

            $second = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:BadCompiler -ProcessInvoker $script:HealthyProcess
            $second.BackoffActive | Should -BeTrue
            $second.Error | Should -Be 'native-host-compile-backoff'
            $script:CompileTracker.Calls | Should -Be 1

            # A new source hash clears the backoff and the success resets the counters.
            Set-Content -LiteralPath $script:Source -Value '// new source' -Encoding ASCII
            $third = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess
            $third.Status | Should -Be 'Built'
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.status | Should -Be 'Built'
            $diagnostics.attempts | Should -Be 1
            $diagnostics.healthAttempts | Should -Be 0

            # A failure after a success restarts the health streak at 1.
            $fourth = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:AlwaysTimeoutProcess -Force
            $fourth.Status | Should -Be 'Fallback'
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.attempts | Should -Be 1
            $diagnostics.healthAttempts | Should -Be 1
            $diagnostics.retryDelayMinutes | Should -Be 5
        }
    }

    Context 'Hash without Get-FileHash (Phase 8c)' {
        BeforeEach {
            . $script:BuildModulePath
            $script:Root = Join-Path $TestDrive ('native-hash-' + [guid]::NewGuid().ToString('N'))
            $script:NativeRoot = Join-Path $script:Root 'browser-extension\firefox\native'
            New-Item -ItemType Directory -Path $script:NativeRoot -Force | Out-Null
            $script:Source = Join-Path $script:Root 'OpenPathNativeHost.cs'
            Set-Content -LiteralPath $script:Source -Value '// fixture source' -Encoding ASCII
            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $script:CompileTracker = $compileTracker
            $script:GoodCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                Set-Content -LiteralPath $outputPath -Value 'MZ-fake-executable' -Encoding ASCII
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }.GetNewClosure()
            $script:HealthyProcess = {
                param($executablePath, $timeoutSeconds)
                [pscustomobject]@{ Healthy = $true; Version = '9.9.9'; ProtocolVersion = 2; Capabilities = @(); ElapsedMs = 12; Error = '' }
            }
            $script:DiagnosticsPath = Join-Path $script:NativeRoot 'OpenPath-NativeHost.build.json'
        }

        It 'Computes the same lowercase SHA256 hex as Get-FileHash' {
            . $script:BuildModulePath
            $sample = Join-Path $script:Root 'sample.bin'
            [IO.File]::WriteAllBytes($sample, [byte[]](1..97))
            $expected = (Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash.ToLowerInvariant()
            (Get-OpenPathNativeHostFileSha256 -Path $sample) | Should -Be $expected
        }

        It 'Never relies on Get-FileHash in the native host stack (contract)' {
            foreach ($relative in @('windows/lib/internal/NativeHost.Build.ps1', 'windows/lib/Browser.FirefoxNativeHost.psm1')) {
                $path = Join-Path $script:RepoRoot $relative
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
                $calls = $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-FileHash'
                    }, $true)
                @($calls).Count | Should -Be 0 -Because $relative
            }
        }

        It 'Builds and reports healthy in a child session where Get-FileHash is not recognized' {
            $childRoot = Join-Path $TestDrive ('native-hash-child-' + [guid]::NewGuid().ToString('N'))
            $childNative = Join-Path $childRoot 'native'
            New-Item -ItemType Directory -Path $childNative -Force | Out-Null
            $childSource = Join-Path $childRoot 'OpenPathNativeHost.cs'
            Set-Content -LiteralPath $childSource -Value '// child fixture source' -Encoding ASCII
            $buildPath = (Resolve-Path $script:BuildModulePath).Path
            $nativeHostModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\Browser.FirefoxNativeHost.psm1')).Path
            $childScript = @"
function global:Get-FileHash { throw [System.Management.Automation.CommandNotFoundException]::new("The term 'Get-FileHash' is not recognized as the name of a cmdlet, function, script file, or operable program.") }
. '$buildPath'
`$compiler = { param(`$sourcePath, `$outputPath) Set-Content -LiteralPath `$outputPath -Value 'MZ-fake-executable' -Encoding ASCII; [pscustomobject]@{ ExitCode = 0; Output = '' } }
`$process = { param(`$executablePath, `$timeoutSeconds) [pscustomobject]@{ Healthy = `$true; Version = '9.9.9'; ProtocolVersion = 2; Capabilities = @(); ElapsedMs = 5; Error = '' } }
`$result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot '$childNative' -OpenPathRoot '$childRoot' -SourcePath '$childSource' -CompilerInvoker `$compiler -ProcessInvoker `$process
Import-Module '$nativeHostModulePath' -Force -Global -ErrorAction Stop
`$registered = Join-Path '$childRoot' 'whitelist_native_host.json'
[ordered]@{ path = (Join-Path '$childNative' 'OpenPath-NativeHost.exe') } | ConvertTo-Json | Set-Content -LiteralPath `$registered -Encoding UTF8
`$health = Get-OpenPathFirefoxNativeHostCompiledHealth -Config ([pscustomobject]@{ enableNonAdminAppControl = `$true }) -NativeRoot '$childNative' -OpenPathRoot '$childRoot' -ManifestPath `$registered
[ordered]@{
  commandType     = [string](Get-Command Get-FileHash).CommandType
  status          = [string]`$result.Status
  error           = [string]`$result.Error
  compiledHealthy = [bool]`$health.CompiledHealthy
  usesCompiled    = [bool]`$health.UsesCompiledHost
} | ConvertTo-Json -Compress
"@
            $shellExe = if (Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue) { 'powershell.exe' } else { 'pwsh' }
            $output = @(& $shellExe -NoProfile -Command $childScript 2>&1)
            $jsonLine = $output | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
            $child = $jsonLine | ConvertFrom-Json

            $child.commandType | Should -Be 'Function'
            $child.status | Should -BeIn @('Built', 'BuildSkipped')
            $child.error | Should -Be ''
            $child.compiledHealthy | Should -BeTrue
            $child.usesCompiled | Should -BeTrue
        }

        It 'Counts an unreadable source hash as one attempt per backoff hour' {
            . $script:BuildModulePath
            $throwingHash = { param($path) throw 'hash-unreadable-fixture' }
            $first = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess -HashReader $throwingHash
            $first.Status | Should -Be 'Fallback'
            $first.Error | Should -Match 'native-host-source-hash-failed'
            $script:CompileTracker.Calls | Should -Be 0
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            $diagnostics.status | Should -Be 'Failed'
            $diagnostics.attempts | Should -Be 1
            $diagnostics.retryDelayMinutes | Should -Be 60

            # Inside the one-hour window the hash failure is not attempted again.
            $second = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $script:HealthyProcess -HashReader $throwingHash
            $second.BackoffActive | Should -BeTrue
            $second.Error | Should -Be 'native-host-compile-backoff'
            $script:CompileTracker.Calls | Should -Be 0
            (Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json).attempts | Should -Be 1
        }
    }

    Context 'Health ping diagnosis (Phase 8d D2)' {
        BeforeEach {
            . $script:BuildModulePath
            $script:Root = Join-Path $TestDrive ('native-ping-' + [guid]::NewGuid().ToString('N'))
            $script:NativeRoot = Join-Path $script:Root 'native'
            New-Item -ItemType Directory -Path $script:NativeRoot -Force | Out-Null
            $script:Source = Join-Path $script:Root 'OpenPathNativeHost.cs'
            Set-Content -LiteralPath $script:Source -Value '// fixture source' -Encoding ASCII
            $script:DiagnosticsPath = Join-Path $script:NativeRoot 'OpenPath-NativeHost.build.json'
            $compileTracker = [pscustomobject]@{ Calls = 0 }
            $script:CompileTracker = $compileTracker
            $script:GoodCompiler = {
                param($sourcePath, $outputPath)
                $compileTracker.Calls = $compileTracker.Calls + 1
                Set-Content -LiteralPath $outputPath -Value 'MZ-fake-executable' -Encoding ASCII
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }.GetNewClosure()
        }

        BeforeAll {
            # Real-process ping fixtures are compiled with the in-box csc only on
            # Windows; anywhere else the three process tests skip with a reason.
            $script:PingFixtureRoot = Join-Path $TestDrive ('ping-fixtures-' + [guid]::NewGuid().ToString('N'))
            $script:PingFixtures = @{}
            $script:PingFixtureSkipReason = 'requires Windows and the in-box .NET Framework compiler'
            if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
                . $script:BuildModulePath
                $compilerPath = Get-OpenPathNativeHostCompilerPath
                if ($compilerPath) {
                    New-Item -ItemType Directory -Path $script:PingFixtureRoot -Force | Out-Null
                    $sources = @{
                        exit  = @'
using System;
public static class OpenPathPingExitFixture {
    public static int Main() {
        Console.Error.WriteLine("fixture-exit-stderr: the host refused to start");
        return 3;
    }
}
'@
                        hang  = @'
using System;
public static class OpenPathPingHangFixture {
    public static int Main() {
        System.Threading.Thread.Sleep(120000);
        return 0;
    }
}
'@
                        noisy = @'
using System;
public static class OpenPathPingNoisyFixture {
    private static void ReadFull(System.IO.Stream stream, byte[] buffer, int count) {
        int offset = 0;
        while (offset < count) {
            int read = stream.Read(buffer, offset, count - offset);
            if (read <= 0) { throw new System.IO.EndOfStreamException(); }
            offset += read;
        }
    }
    public static int Main() {
        var junk = new string('n', 1024);
        for (int i = 0; i < 64; i++) { Console.Error.WriteLine(junk); }
        var stdin = Console.OpenStandardInput();
        var lengthBytes = new byte[4];
        ReadFull(stdin, lengthBytes, 4);
        var length = BitConverter.ToInt32(lengthBytes, 0);
        var body = new byte[length];
        ReadFull(stdin, body, length);
        var payload = System.Text.Encoding.UTF8.GetBytes("{\"success\":true,\"message\":\"pong\",\"protocolVersion\":2,\"version\":\"9.9.9\",\"capabilities\":[]}");
        var stdout = Console.OpenStandardOutput();
        stdout.Write(BitConverter.GetBytes(payload.Length), 0, 4);
        stdout.Write(payload, 0, payload.Length);
        stdout.Flush();
        return 0;
    }
}
'@
                    }
                    $fixtureErrors = @()
                    foreach ($fixtureName in @($sources.Keys)) {
                        $fixtureSource = Join-Path $script:PingFixtureRoot "$fixtureName.cs"
                        $fixtureExe = Join-Path $script:PingFixtureRoot "$fixtureName.exe"
                        Set-Content -LiteralPath $fixtureSource -Value $sources[$fixtureName] -Encoding ASCII
                        $fixtureCompile = Invoke-OpenPathNativeHostCompilation -SourcePath $fixtureSource -OutputPath $fixtureExe -CompilerPath $compilerPath
                        if ($fixtureCompile.Success) { $script:PingFixtures[$fixtureName] = $fixtureExe }
                        else { $fixtureErrors += "${fixtureName}: $($fixtureCompile.Output)" }
                    }
                    if ($fixtureErrors.Count -gt 0) { $script:PingFixtureSkipReason = "fixture compilation failed: $($fixtureErrors -join ' | ')" }
                }
                else {
                    $script:PingFixtureSkipReason = 'the in-box csc.exe is not available'
                }
            }
        }

        It 'Stores the last two ping attempts with their literal diagnosis in build.json' {
            $script:PingQueue = New-Object System.Collections.ArrayList
            $null = $script:PingQueue.Add([pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 20050; Error = 'health-check-timeout'; StartMs = 1000; Pid = 41; HasExited = $false; ExitCode = $null; CpuMs = 12; Stderr = 'stderr first' })
            $null = $script:PingQueue.Add([pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 340; Error = 'health-check-exited'; StartMs = 21000; Pid = 42; HasExited = $true; ExitCode = 3; CpuMs = 5; Stderr = 'stderr second' })
            $queue = $script:PingQueue
            $process = {
                param($executablePath, $timeoutSeconds)
                $record = $queue[0]
                $queue.RemoveAt(0)
                $record
            }.GetNewClosure()

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $process

            $result.Status | Should -Be 'Fallback'
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            @($diagnostics.lastPings).Count | Should -Be 2
            $diagnostics.lastPings[0].attempt | Should -Be 1
            $diagnostics.lastPings[0].error | Should -Be 'health-check-timeout'
            $diagnostics.lastPings[0].pid | Should -Be 41
            $diagnostics.lastPings[0].elapsedMs | Should -Be 20050
            $diagnostics.lastPings[0].stderr | Should -Be 'stderr first'
            $diagnostics.lastPings[1].attempt | Should -Be 2
            $diagnostics.lastPings[1].error | Should -Be 'health-check-exited'
            $diagnostics.lastPings[1].exitCode | Should -Be 3
            $diagnostics.lastPings[1].cpuMs | Should -Be 5
            $diagnostics.pingAttempts | Should -Be 2
        }

        It 'Captures the parent stdin code page and preamble on every ping (Phase 8e E0.1)' {
            # The .NET Framework Process.StandardInput StreamWriter emits the
            # parent console input encoding preamble (a UTF-8 BOM when the
            # console input code page is 65001) before the first frame. The ping
            # records what this process would emit so the E2E artifact and the
            # WARN line carry the literal cause.
            $health = Test-OpenPathNativeHostExecutable -ExecutablePath (Join-Path $script:NativeRoot 'missing.exe')
            $health.StdinCodePage | Should -Be ([int][Console]::InputEncoding.CodePage)
            $expectedPreamble = ''
            $preamble = [byte[]][Console]::InputEncoding.GetPreamble()
            if ($preamble.Length -gt 0) { $expectedPreamble = (@($preamble | ForEach-Object { $_.ToString('x2') }) -join '') }
            $health.StdinPreambleBytes | Should -Be $expectedPreamble
        }

        It 'Persists the stdin code page and preamble bytes on every lastPings record (Phase 8e E0.1)' {
            $script:PingQueue = New-Object System.Collections.ArrayList
            $null = $script:PingQueue.Add([pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 20050; Error = 'health-check-timeout'; StartMs = 1000; Pid = 41; HasExited = $false; ExitCode = $null; CpuMs = 12; Stderr = ''; StdinCodePage = 65001; StdinPreambleBytes = 'efbbbf' })
            $null = $script:PingQueue.Add([pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 340; Error = 'health-check-exited'; StartMs = 21000; Pid = 42; HasExited = $true; ExitCode = 0; CpuMs = 5; Stderr = ''; StdinCodePage = 437; StdinPreambleBytes = '' })
            $queue = $script:PingQueue
            $process = {
                param($executablePath, $timeoutSeconds)
                $record = $queue[0]
                $queue.RemoveAt(0)
                $record
            }.GetNewClosure()

            $result = Build-OpenPathFirefoxNativeHostExecutable -NativeRoot $script:NativeRoot -OpenPathRoot $script:Root -SourcePath $script:Source -CompilerInvoker $script:GoodCompiler -ProcessInvoker $process

            $result.Status | Should -Be 'Fallback'
            $diagnostics = Get-Content -LiteralPath $script:DiagnosticsPath -Raw | ConvertFrom-Json
            @($diagnostics.lastPings).Count | Should -Be 2
            $diagnostics.lastPings[0].stdinCodePage | Should -Be 65001
            $diagnostics.lastPings[0].stdinPreambleBytes | Should -Be 'efbbbf'
            $diagnostics.lastPings[1].stdinCodePage | Should -Be 437
            $diagnostics.lastPings[1].stdinPreambleBytes | Should -Be ''
        }

        It 'Logs one WARN line per failed ping with its diagnosis' {
            $script:PingLogLines = New-Object System.Collections.ArrayList
            function global:Write-OpenPathLog {
                param([Parameter(Mandatory = $true)][string]$Message, [string]$Level = 'INFO')
                $null = $script:PingLogLines.Add("$Level $Message")
            }
            try {
                $health = Test-OpenPathNativeHostExecutableWithRetry -ExecutablePath (Join-Path $script:NativeRoot 'missing.exe') -ProcessInvoker {
                    param($executablePath, $timeoutSeconds)
                    [pscustomobject]@{ Healthy = $false; Version = ''; ProtocolVersion = 0; Capabilities = @(); ElapsedMs = 20050; Error = 'health-check-timeout'; StartMs = 100; Pid = 7; HasExited = $false; ExitCode = $null; CpuMs = 1; Stderr = 'x'; StdinCodePage = 65001; StdinPreambleBytes = 'efbbbf' }
                }
                $health.Healthy | Should -BeFalse
                @($script:PingLogLines | Where-Object { $_ -match 'health ping failed' }).Count | Should -Be 2
                ($script:PingLogLines -join "`n") | Should -Match 'attempt=1'
                ($script:PingLogLines -join "`n") | Should -Match 'attempt=2'
                ($script:PingLogLines -join "`n") | Should -Match 'health-check-timeout'
                ($script:PingLogLines -join "`n") | Should -Match 'stdinCodePage=65001'
                ($script:PingLogLines -join "`n") | Should -Match "stdinPreambleBytes='efbbbf'"
            }
            finally {
                Remove-Item function:global:Write-OpenPathLog -ErrorAction SilentlyContinue
            }
        }

        It 'Stops at stdout EOF and reports health-check-exited with the exit code (Windows only)' {
            if (-not $script:PingFixtures.ContainsKey('exit')) { Set-ItResult -Skipped -Because $script:PingFixtureSkipReason; return }
            $health = Test-OpenPathNativeHostExecutable -ExecutablePath $script:PingFixtures['exit'] -TimeoutSeconds 20
            $health.Error | Should -Be 'health-check-exited'
            $health.ExitCode | Should -Be 3
            $health.HasExited | Should -BeTrue
            $health.Stderr | Should -Match 'fixture-exit-stderr'
            $health.ElapsedMs | Should -BeLessThan 5000
            $health.Pid | Should -BeGreaterThan 0
            $health.StartMs | Should -BeGreaterThan 0
            ($health.CpuMs -ge 0) | Should -BeTrue
        }

        It 'Reports health-check-timeout with the still-running process and its CPU (Windows only)' {
            if (-not $script:PingFixtures.ContainsKey('hang')) { Set-ItResult -Skipped -Because $script:PingFixtureSkipReason; return }
            $health = Test-OpenPathNativeHostExecutable -ExecutablePath $script:PingFixtures['hang'] -TimeoutSeconds 2
            $health.Error | Should -Be 'health-check-timeout'
            $health.HasExited | Should -BeFalse
            $health.Pid | Should -BeGreaterThan 0
            ($health.CpuMs -ge 0) | Should -BeTrue
            $health.ElapsedMs | Should -BeGreaterThan 1500
        }

        It 'Drains a noisy stderr pipe so the host still answers pong (Windows only)' {
            if (-not $script:PingFixtures.ContainsKey('noisy')) { Set-ItResult -Skipped -Because $script:PingFixtureSkipReason; return }
            $health = Test-OpenPathNativeHostExecutable -ExecutablePath $script:PingFixtures['noisy'] -TimeoutSeconds 20
            $health.Healthy | Should -BeTrue
            ($health.Stderr.Length -le 2048) | Should -BeTrue
        }
    }

    Context 'H1 stdin preamble probe (Phase 8e E0.2)' {
        It 'Answers without a preamble and discards one UTF-8 preamble before the first frame (Windows only)' {
            if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
                Set-ItResult -Skipped -Because 'requires Windows, Windows PowerShell 5.1 and the in-box .NET Framework compiler'
                return
            }
            . $script:BuildModulePath
            if (-not (Get-OpenPathNativeHostCompilerPath)) {
                Set-ItResult -Skipped -Because 'the in-box csc.exe is not available'
                return
            }
            # The BeforeAll paths: Pester resolves them against the test file,
            # and the probe receives every path explicitly so its own repo-root
            # derivation never decides the outcome.
            $probePath = Join-Path $script:RepoRoot 'tests\e2e\ci\probe-native-host-preamble.ps1'
            (Test-Path -LiteralPath $probePath -PathType Leaf) | Should -BeTrue -Because "probe=$probePath repo=$($script:RepoRoot)"
            $realSource = Join-Path $script:RepoRoot 'windows\native-host\OpenPathNativeHost.cs'
            (Test-Path -LiteralPath $realSource -PathType Leaf) | Should -BeTrue -Because "source=$realSource"

            $probeRoot = Join-Path $TestDrive ('h1-preamble-' + [guid]::NewGuid().ToString('N'))
            $probeOut = Join-Path $probeRoot 'probe.json'
            $probeError = ''
            try {
                $probeOutput = @(& $probePath -SourcePath $realSource -PingModulePath $script:BuildModulePath -WorkDir $probeRoot -JsonOut $probeOut 2>&1)
            }
            catch {
                $probeError = [string]$_
                $probeOutput = @($probeError)
            }
            (Test-Path -LiteralPath $probeOut -PathType Leaf) | Should -BeTrue -Because "probeError=$probeError output=$((($probeOutput | Out-String).Trim()))"
            $probe = Get-Content -LiteralPath $probeOut -Raw | ConvertFrom-Json

            # Control: the same binary without a preamble answers pong.
            $probe.control.healthy | Should -BeTrue
            $probe.control.protocolVersion -ge 2 | Should -BeTrue
            $probe.control.stdinPreambleBytes | Should -Be ''

            # The preamble run pings from a real 65001 console whose encoding
            # emits EF BB BF; the host must discard exactly one preamble.
            $probe.withPreamble.healthy | Should -BeTrue -Because ("$($probe.withPreamble.error) exitCode=$($probe.withPreamble.exitCode)")
            $probe.withPreamble.encodingError | Should -Be ''
            $probe.withPreamble.stdinCodePage | Should -Be 65001
            $probe.withPreamble.stdinPreambleBytes | Should -Be 'efbbbf'
            @($probe.hostStopLines | Where-Object { $_ -match 'invalid-frame-length' }).Count | Should -Be 0
        }
    }
}
