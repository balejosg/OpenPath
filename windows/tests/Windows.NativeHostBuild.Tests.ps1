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
    }

    Context 'Registration contract' {
        It 'Registers the compiled host after a health-checked build and keeps the cmd fallback' {
            $moduleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\lib\Browser.FirefoxNativeHost.psm1') -Raw
            $moduleText | Should -Match 'Build-OpenPathFirefoxNativeHostExecutable'
            $moduleText | Should -Match 'Get-OpenPathNativeHostLaunchPath -NativeRoot \$nativeRoot'
            $moduleText | Should -Match 'path = \$launchPath'
            # The build failure path must keep the PowerShell host registered.
            $moduleText | Should -Match 'keeping the PowerShell host fallback'
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

        It 'Uses no dynamic code, reflection or optional assemblies' {
            $script:SourceText | Should -Not -Match 'System\.Reflection'
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
}
