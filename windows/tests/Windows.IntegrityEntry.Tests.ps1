Describe "Update-OpenPathIntegrityEntry" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module (Join-Path $modulePath "Common.psm1") -Force -Global -ErrorAction Stop
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ('oproot-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'data') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'lib') -Force | Out-Null
        $script:FileA = Join-Path $script:Root 'lib/a.bin'
        $script:FileB = Join-Path $script:Root 'lib/b.bin'
        Set-Content -LiteralPath $script:FileA -Value 'old-a' -Encoding ASCII
        Set-Content -LiteralPath $script:FileB -Value 'old-b' -Encoding ASCII
        $script:BaselinePath = Join-Path $script:Root 'data/integrity-baseline.json'
        $script:BackupPath = Join-Path $script:Root 'data/integrity-backup'
        $r = $script:Root; $bl = $script:BaselinePath; $bk = $script:BackupPath
        InModuleScope Common -Parameters @{ r = $r; bl = $bl; bk = $bk } {
            $script:OpenPathRoot = $r
            $script:IntegrityBaselinePath = $bl
            $script:IntegrityBackupPath = $bk
        }
        $hashA = (Get-FileHash -LiteralPath $script:FileA -Algorithm SHA256).Hash
        $hashB = (Get-FileHash -LiteralPath $script:FileB -Algorithm SHA256).Hash
        $script:OldHashA = $hashA
        $script:OldHashB = $hashB
        [PSCustomObject]@{
            generatedAt = '2026-01-01T00:00:00Z'
            entryCount = 2
            entries = @(
                [PSCustomObject]@{ path = $script:FileA; hash = $hashA },
                [PSCustomObject]@{ path = $script:FileB; hash = $hashB }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:BaselinePath -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:BackupPath 'lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:BackupPath 'lib/a.bin') -Value 'old-a' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:BackupPath 'lib/b.bin') -Value 'old-b' -Encoding ASCII
    }

    It "Refreshes the backup and only that entry's hash" {
        Set-Content -LiteralPath $script:FileA -Value 'new-a' -Encoding ASCII
        Set-Content -LiteralPath $script:FileB -Value 'tampered-b' -Encoding ASCII

        (Update-OpenPathIntegrityEntry -Path $script:FileA) | Should -BeTrue

        $baseline = Get-Content -LiteralPath $script:BaselinePath -Raw | ConvertFrom-Json
        $baseline.entryCount | Should -Be 2
        @($baseline.entries).Count | Should -Be 2
        ($baseline.entries | Where-Object { $_.path -eq $script:FileA }).hash |
            Should -Be (Get-FileHash -LiteralPath $script:FileA -Algorithm SHA256).Hash
        ($baseline.entries | Where-Object { $_.path -eq $script:FileB }).hash | Should -Be $script:OldHashB
        (Get-Content -LiteralPath (Join-Path $script:BackupPath 'lib/a.bin') -Raw).Trim() | Should -Be 'new-a'
        (Get-Content -LiteralPath (Join-Path $script:BackupPath 'lib/b.bin') -Raw).Trim() | Should -Be 'old-b'
    }

    It "Returns false for an untracked path and leaves the baseline unchanged" {
        $other = Join-Path $script:Root 'lib/other.bin'
        Set-Content -LiteralPath $other -Value 'x' -Encoding ASCII
        $before = Get-Content -LiteralPath $script:BaselinePath -Raw

        (Update-OpenPathIntegrityEntry -Path $other) | Should -BeFalse

        (Get-Content -LiteralPath $script:BaselinePath -Raw) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $script:BackupPath 'lib/other.bin') | Should -BeFalse
    }

    It "Returns false when the baseline is missing" {
        Remove-Item -LiteralPath $script:BaselinePath -Force
        (Update-OpenPathIntegrityEntry -Path $script:FileA) | Should -BeFalse
    }

    It "Returns false without throwing when the baseline is corrupt" {
        Set-Content -LiteralPath $script:BaselinePath -Value '{not json' -Encoding UTF8
        { Update-OpenPathIntegrityEntry -Path $script:FileA } | Should -Not -Throw
        (Update-OpenPathIntegrityEntry -Path $script:FileA) | Should -BeFalse
    }
}

Describe "Invoke-OpenPathFirefoxNativeHostCompiledEnsure integrity refresh" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module (Join-Path $modulePath "Common.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Browser.Common.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Browser.FirefoxNativeHost.psm1") -Force -Global -ErrorAction Stop
    }

    BeforeEach {
        $script:EnsureNative = Join-Path $TestDrive ('native-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:EnsureNative -Force | Out-Null
        $script:EnsureManifest = Join-Path $script:EnsureNative 'whitelist_native_host.json'
        $script:ExePath = Join-Path $script:EnsureNative 'OpenPath-NativeHost.exe'
        Mock -ModuleName Browser.FirefoxNativeHost Update-OpenPathIntegrityEntry { $true }
        Mock -ModuleName Browser.FirefoxNativeHost Write-OpenPathNativeHostFallbackState { }
        Mock -ModuleName Browser.FirefoxNativeHost Sync-OpenPathFirefoxNativeHostMessagingManifest { $false }
    }

    It "Refreshes the integrity entry for the executable when it was built now" {
        $exe = $script:ExePath
        Mock -ModuleName Browser.FirefoxNativeHost Build-OpenPathFirefoxNativeHostExecutable {
            [pscustomobject]@{ Status = 'Built'; BuiltNow = $true; ExecutablePath = $exe; ExecutableSha256 = 'x'; HostSource = 'c' }
        }.GetNewClosure()

        Invoke-OpenPathFirefoxNativeHostCompiledEnsure -NativeRoot $script:EnsureNative -OpenPathRoot $TestDrive -ManifestPath $script:EnsureManifest | Out-Null

        Should -Invoke -ModuleName Browser.FirefoxNativeHost Update-OpenPathIntegrityEntry -Times 1 -Exactly -ParameterFilter { $Path -eq $exe }
    }

    It "Does not refresh when the build was skipped or failed" {
        $exe = $script:ExePath
        Mock -ModuleName Browser.FirefoxNativeHost Build-OpenPathFirefoxNativeHostExecutable {
            [pscustomobject]@{ Status = 'BuildSkipped'; BuiltNow = $false; ExecutablePath = $exe; ExecutableSha256 = 'x'; HostSource = 'c' }
        }.GetNewClosure()
        Invoke-OpenPathFirefoxNativeHostCompiledEnsure -NativeRoot $script:EnsureNative -OpenPathRoot $TestDrive -ManifestPath $script:EnsureManifest | Out-Null

        Mock -ModuleName Browser.FirefoxNativeHost Build-OpenPathFirefoxNativeHostExecutable { throw 'compile boom' }
        Invoke-OpenPathFirefoxNativeHostCompiledEnsure -NativeRoot $script:EnsureNative -OpenPathRoot $TestDrive -ManifestPath $script:EnsureManifest | Out-Null

        Should -Invoke -ModuleName Browser.FirefoxNativeHost Update-OpenPathIntegrityEntry -Times 0 -Exactly
    }

    It "Holds the agent update lock during the build and releases it afterwards" {
        $exe = $script:ExePath
        $probe = [pscustomobject]@{ Held = $false }
        Mock -ModuleName Browser.FirefoxNativeHost Build-OpenPathFirefoxNativeHostExecutable {
            # A different thread cannot take the lock while the build runs.
            $ps = [powershell]::Create()
            $null = $ps.AddScript({
                $m = [System.Threading.Mutex]::new($false, 'Global\OpenPathAgentUpdateLock')
                try { $got = $m.WaitOne(0); if ($got) { $m.ReleaseMutex() }; -not $got } finally { $m.Dispose() }
            })
            $probe.Held = [bool]($ps.Invoke() | Select-Object -First 1)
            $ps.Dispose()
            [pscustomobject]@{ Status = 'Built'; BuiltNow = $true; ExecutablePath = $exe; ExecutableSha256 = 'x'; HostSource = 'c' }
        }.GetNewClosure()

        Invoke-OpenPathFirefoxNativeHostCompiledEnsure -NativeRoot $script:EnsureNative -OpenPathRoot $TestDrive -ManifestPath $script:EnsureManifest | Out-Null

        $probe.Held | Should -BeTrue
        $after = Enter-OpenPathAgentUpdateLock -TimeoutMilliseconds 0
        try { $after.Acquired | Should -BeTrue } finally { Exit-OpenPathAgentUpdateLock -Lock $after }
    }
}
