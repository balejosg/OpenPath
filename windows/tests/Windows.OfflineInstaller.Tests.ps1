Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe "Offline installer" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1")
        . (Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1")
        . (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.System.ps1")

        $script:OfflineTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-offline-tests-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:OfflineTestRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:OfflineTestRoot) {
            Remove-Item $script:OfflineTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Read-OpenPathOfflineConfig" {
        It "Accepts a valid schemaVersion 1 configuration and normalizes the expiry to UTC ISO-8601" {
            $configPath = Join-Path $script:OfflineTestRoot 'valid-offline-config.json'
            @'
{
  "schemaVersion": 1,
  "apiUrl": "https://api.example.test",
  "classroomId": "room_123",
  "enrollmentToken": "token-value",
  "enrollmentTokenExpiresAt": "2026-08-22T10:00:00.000Z",
  "captivePortalDomains": ["login.example.test"],
  "options": {
    "approvedStudentBrowsers": ["Firefox"],
    "installFirefoxIfMissing": true,
    "enforceManagedBrowserBoundary": true
  }
}
'@ | Set-Content -LiteralPath $configPath -Encoding UTF8

            $config = Read-OpenPathOfflineConfig -Path $configPath

            $config.ApiUrl | Should -Be 'https://api.example.test'
            $config.ClassroomId | Should -Be 'room_123'
            $config.EnrollmentToken | Should -Be 'token-value'
            $config.EnrollmentTokenExpiresAt.Kind | Should -Be ([System.DateTimeKind]::Utc)
            $config.CaptivePortalDomains | Should -Be 'login.example.test'
            $config.InstallFirefoxIfMissing | Should -BeTrue
            $config.EnforceManagedBrowserBoundary | Should -BeTrue
        }

        It "Rejects plaintext http API URLs, wrong schema versions, malformed JSON, and missing fields" {
            $rejectCases = @(
                @{ json = '{"schemaVersion":1,"apiUrl":"http://api.example.test","classroomId":"r","enrollmentToken":"t","enrollmentTokenExpiresAt":"2026-08-22T10:00:00.000Z"}'; because = 'http apiUrl' },
                @{ json = '{"schemaVersion":2,"apiUrl":"https://api.example.test","classroomId":"r","enrollmentToken":"t","enrollmentTokenExpiresAt":"2026-08-22T10:00:00.000Z"}'; because = 'unsupported schemaVersion' },
                @{ json = '{not-json'; because = 'malformed JSON' },
                @{ json = '{"schemaVersion":1,"apiUrl":"https://api.example.test"}'; because = 'missing required fields' },
                @{ json = '{"schemaVersion":1,"apiUrl":"https://api.example.test","classroomId":"r","enrollmentToken":"t","enrollmentTokenExpiresAt":"not-a-date"}'; because = 'invalid date' }
            )

            foreach ($case in $rejectCases) {
                $configPath = Join-Path $script:OfflineTestRoot ("reject-" + [Guid]::NewGuid().ToString('N') + ".json")
                $case.json | Set-Content -LiteralPath $configPath -Encoding UTF8
                { Read-OpenPathOfflineConfig -Path $configPath } | Should -Throw -Because $case.because
            }
        }

        It "Fails closed when the configuration file does not exist" {
            { Read-OpenPathOfflineConfig -Path (Join-Path $script:OfflineTestRoot 'missing.json') } | Should -Throw
        }
    }

    Context "Assert-OpenPathOfflinePayloadManifest" {
        It "uses a Windows PowerShell-independent literal hash provider" {
            $offlineModule = Get-Content (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1") -Raw

            $offlineModule | Should -Match 'function Get-OpenPathOfflinePayloadSha256'
            $offlineModule | Should -Match '\[System\.IO\.File\]::OpenRead\(\$Path\)'
            $offlineModule | Should -Not -Match 'Get-FileHash -Path \$stagedPath'
        }

        It "Verifies every required payload by size and sha256 without network access" {
            $stagingRoot = Join-Path $script:OfflineTestRoot 'staging-ok'
            New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'payloads\acrylic') -Force | Out-Null
            $payloadPath = Join-Path $stagingRoot 'payloads\acrylic\Acrylic-Portable.zip'
            'offline-payload-bytes' | Set-Content -LiteralPath $payloadPath -Encoding UTF8
            $hash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $size = (Get-Item -LiteralPath $payloadPath).Length

            $manifestPath = Join-Path $stagingRoot 'payload-manifest.json'
            @{
                payloads = @(
                    @{
                        path = 'payloads/acrylic/Acrylic-Portable.zip'
                        sha256 = $hash
                        size = $size
                    }
                )
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

            { Assert-OpenPathOfflinePayloadManifest -ManifestPath $manifestPath -StagingRoot $stagingRoot } | Should -Not -Throw
        }

        It "Fails closed on missing, hash-mismatched, or resized payloads" {
            $stagingRoot = Join-Path $script:OfflineTestRoot 'staging-bad'
            New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'payloads') -Force | Out-Null
            $presentPath = Join-Path $stagingRoot 'payloads\present.bin'
            'present' | Set-Content -LiteralPath $presentPath -Encoding UTF8
            $wrongHash = (Get-FileHash -LiteralPath $presentPath -Algorithm SHA256).Hash.ToLowerInvariant()

            $manifestPath = Join-Path $stagingRoot 'payload-manifest.json'
            @{
                payloads = @(
                    @{ path = 'payloads/absent.bin'; sha256 = $wrongHash; size = 7 },
                    @{ path = 'payloads/present.bin'; sha256 = ('0' * 64); size = 7 }
                )
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

            { Assert-OpenPathOfflinePayloadManifest -ManifestPath $manifestPath -StagingRoot $stagingRoot } |
                Should -Throw -ExpectedMessage '*Offline payload verification failed*'
        }

        It "Keeps payload hash IO diagnostics bounded to the payload source class" {
            $stagingRoot = Join-Path $script:OfflineTestRoot 'staging-hash-io'
            New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'payloads') -Force | Out-Null
            $payloadPath = Join-Path $stagingRoot 'payloads\pinned.bin'
            'pinned' | Set-Content -LiteralPath $payloadPath -Encoding UTF8
            $manifestPath = Join-Path $stagingRoot 'payload-manifest.json'
            @{
                payloads = @(
                    @{
                        path = 'payloads/pinned.bin'
                        origin = 'pinned:firefox'
                        sha256 = ('0' * 64)
                    }
                )
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

            Mock Get-OpenPathOfflinePayloadSha256 { throw 'simulated hash IO failure' }

            { Assert-OpenPathOfflinePayloadManifest -ManifestPath $manifestPath -StagingRoot $stagingRoot } |
                Should -Throw -ExpectedMessage '*hash-io-pinned-other*'
        }

        It "does not depend on Get-FileHash being auto-loaded by Windows PowerShell" {
            $stagingRoot = Join-Path $script:OfflineTestRoot 'staging-hash-provider'
            New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'payloads') -Force | Out-Null
            $payloadPath = Join-Path $stagingRoot 'payloads\provider.bin'
            'provider' | Set-Content -LiteralPath $payloadPath -Encoding UTF8
            $hash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $size = (Get-Item -LiteralPath $payloadPath).Length
            $manifestPath = Join-Path $stagingRoot 'payload-manifest.json'
            @{
                payloads = @(
                    @{ path = 'payloads/provider.bin'; origin = 'repo:windows'; sha256 = $hash; size = $size }
                )
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

            Mock Get-FileHash { throw "The term 'Get-FileHash' is not recognized as the name of a cmdlet" }

            { Assert-OpenPathOfflinePayloadManifest -ManifestPath $manifestPath -StagingRoot $stagingRoot } |
                Should -Not -Throw
        }

        It "uses a literal hash provider for the Acrylic archive too" {
            $archivePath = Join-Path $script:OfflineTestRoot 'acrylic-hash-provider.bin'
            'acrylic-provider' | Set-Content -LiteralPath $archivePath -Encoding UTF8
            $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

            Mock Get-FileHash { throw "The term 'Get-FileHash' is not recognized as the name of a cmdlet" }

            { Assert-AcrylicDownloadHash -Path $archivePath -ExpectedSha256 $hash -ArtifactName 'Acrylic-Portable.zip' } |
                Should -Not -Throw
        }

        It "Classifies only genuine missing-command errors as command failures" {
            try {
                throw "The term 'Get-FileHash' is not recognized as the name of a cmdlet"
            }
            catch {
                Get-OpenPathOfflinePayloadIoFailureClass -ErrorRecord $_ | Should -Be 'command'
            }

            try {
                throw 'The path could not be found'
            }
            catch {
                Get-OpenPathOfflinePayloadIoFailureClass -ErrorRecord $_ | Should -Be 'not-found'
            }
        }
    }

    Context "Install-AcrylicDNSFromLocalSource" {
        It "Exports every Acrylic helper used by the offline bootstrapper" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "DNS.psm1"
            $exportBlock = [regex]::Match(
                (Get-Content -LiteralPath $modulePath -Raw),
                'Export-ModuleMember -Function @\([\s\S]*?\n\)'
            ).Value

            foreach ($requiredName in @(
                    'Assert-AcrylicDownloadHash',
                    'Test-AcrylicPortableArchive',
                    'Register-AcrylicServiceFromPath')) {
                $exportBlock | Should -Match ("'{0}'," -f $requiredName)
            }
        }

        It "Never references download URLs or Chocolatey in the offline install path" {
            $content = Get-Content (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1") -Raw
            $functionBody = [regex]::Match($content, 'function Install-AcrylicDNSFromLocalSource\s*\{[\s\S]*?\n\}').Value

            $functionBody | Should -Not -Match 'https?://'
            $functionBody | Should -Not -Match 'choco'
            $functionBody | Should -Match 'Assert-AcrylicDownloadHash'
            $functionBody | Should -Match '\[System\.IO\.Compression\.ZipFile\]::ExtractToDirectory'
            $functionBody | Should -Match 'Copy-Item -LiteralPath \$extractedItem\.FullName'
            $functionBody | Should -Match 'Write-OpenPathOfflineInstallPhase'
        }

        It "Throws when the staged ZIP is absent or fails the hash assertion" {
            { Install-AcrylicDNSFromLocalSource `
                    -AcrylicZipPath (Join-Path $script:OfflineTestRoot 'no-such.zip') `
                    -ExpectedSha256 ('0' * 64) } | Should -Throw
        }

        It "Extracts a valid archive with matching hash and stages AcrylicService.exe into the target directory" {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zipDir = Join-Path $script:OfflineTestRoot 'acrylic-zip-src'
            $innerDir = Join-Path $zipDir 'Acrylic'
            New-Item -ItemType Directory -Path $innerDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $innerDir 'AcrylicService.exe') -Value 'Mz' -Encoding ASCII
            $zipPath = Join-Path $script:OfflineTestRoot 'Acrylic-Portable.zip'
            Compress-Archive -Path (Join-Path $zipDir 'Acrylic') -DestinationPath $zipPath -Force
            $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

            Mock Get-AcrylicRegisteredService { return [pscustomobject]@{ Name = 'AcrylicDNSProxySvc'; Status = 'Running' } }
            Mock Register-AcrylicServiceFromPath { return $true } -ParameterFilter { $AcrylicPath -and (Test-Path (Join-Path $AcrylicPath 'AcrylicService.exe')) }
            Mock Test-AcrylicInstalled { return $false }
            Mock Write-OpenPathLog { }

            $targetDir = Join-Path $script:OfflineTestRoot 'acrylic-target'
            Install-AcrylicDNSFromLocalSource `
                -AcrylicZipPath $zipPath `
                -ExpectedSha256 $hash `
                -InstallDir $targetDir | Should -BeTrue

            Should -Invoke Register-AcrylicServiceFromPath -Times 1 -Exactly
            Should -Invoke Write-OpenPathLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'ERROR' }
        }

        It "Extracts a portable archive whose files are at the ZIP root" {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zipSource = Join-Path $script:OfflineTestRoot 'acrylic-root-zip-src'
            New-Item -ItemType Directory -Path $zipSource -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $zipSource 'AcrylicService.exe') -Value 'service' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $zipSource 'AcrylicConfiguration.ini') -Value 'config' -Encoding ASCII
            $zipPath = Join-Path $script:OfflineTestRoot 'Acrylic-root-layout.zip'
            Compress-Archive -Path (Join-Path $zipSource '*') -DestinationPath $zipPath -Force
            $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

            Mock Register-AcrylicServiceFromPath { return $true }
            Mock Test-AcrylicInstalled { return $false }
            Mock Write-OpenPathLog { }

            $targetDir = Join-Path $script:OfflineTestRoot 'acrylic-root-target'
            $statusPath = Join-Path $script:OfflineTestRoot 'acrylic-root-status.txt'
            Install-AcrylicDNSFromLocalSource `
                -AcrylicZipPath $zipPath `
                -ExpectedSha256 $hash `
                -InstallDir $targetDir `
                -FailureStatusPath $statusPath | Should -BeTrue

            Test-Path -LiteralPath (Join-Path $targetDir 'AcrylicService.exe') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $targetDir 'AcrylicConfiguration.ini') | Should -BeTrue
            Get-Content -LiteralPath $statusPath -Raw | Should -Be 'acrylic-local-complete'
        }

        It "Leaves a bounded extraction phase when local staging fails" {
            $zipPath = Join-Path $script:OfflineTestRoot 'invalid-acrylic.zip'
            Set-Content -LiteralPath $zipPath -Value 'not-a-zip' -Encoding ASCII
            $statusPath = Join-Path $script:OfflineTestRoot 'invalid-acrylic-status.txt'

            Mock Assert-AcrylicDownloadHash { }
            Mock Test-AcrylicPortableArchive { return $true }
            Mock Test-AcrylicInstalled { return $false }
            Mock Write-OpenPathLog { }

            {
                Install-AcrylicDNSFromLocalSource `
                    -AcrylicZipPath $zipPath `
                    -ExpectedSha256 ('0' * 64) `
                    -InstallDir (Join-Path $script:OfflineTestRoot 'invalid-acrylic-target') `
                    -FailureStatusPath $statusPath
            } | Should -Throw

            Get-Content -LiteralPath $statusPath -Raw | Should -Be 'acrylic-local-extract'
        }

        It "Distinguishes local ZIP hash and archive validation failures" {
            $zipPath = Join-Path $script:OfflineTestRoot 'validation-acrylic.zip'
            Set-Content -LiteralPath $zipPath -Value 'payload' -Encoding ASCII
            $statusPath = Join-Path $script:OfflineTestRoot 'validation-acrylic-status.txt'
            Mock Test-AcrylicInstalled { return $false }
            Mock Write-OpenPathLog { }

            Mock Assert-AcrylicDownloadHash { throw 'hash failure' }
            {
                Install-AcrylicDNSFromLocalSource `
                    -AcrylicZipPath $zipPath `
                    -ExpectedSha256 ('0' * 64) `
                    -FailureStatusPath $statusPath
            } | Should -Throw
            Get-Content -LiteralPath $statusPath -Raw | Should -Be 'acrylic-local-validate-hash-io'

            Mock Assert-AcrylicDownloadHash { }
            Mock Test-AcrylicPortableArchive { return $false }
            {
                Install-AcrylicDNSFromLocalSource `
                    -AcrylicZipPath $zipPath `
                    -ExpectedSha256 ('0' * 64) `
                    -FailureStatusPath $statusPath
            } | Should -Throw
            Get-Content -LiteralPath $statusPath -Raw | Should -Be 'acrylic-local-validate-archive'
        }

        It "Classifies local ZIP hash I/O and mismatch failures without exposing digests" {
            $zipPath = Join-Path $script:OfflineTestRoot 'hash-acrylic.zip'
            Set-Content -LiteralPath $zipPath -Value 'payload' -Encoding ASCII
            $statusPath = Join-Path $script:OfflineTestRoot 'hash-acrylic-status.txt'
            Mock Test-AcrylicInstalled { return $false }
            Mock Write-OpenPathLog { }

            Mock Get-AcrylicFileSha256 { return ('a' * 64) }
            {
                Install-AcrylicDNSFromLocalSource `
                    -AcrylicZipPath $zipPath `
                    -ExpectedSha256 ('0' * 64) `
                    -FailureStatusPath $statusPath
            } | Should -Throw
            Get-Content -LiteralPath $statusPath -Raw | Should -Be 'acrylic-local-validate-hash-mismatch'

            Mock Get-AcrylicFileSha256 { throw 'hash stream failed' }
            {
                Install-AcrylicDNSFromLocalSource `
                    -AcrylicZipPath $zipPath `
                    -ExpectedSha256 ('0' * 64) `
                    -FailureStatusPath $statusPath
            } | Should -Throw
            Get-Content -LiteralPath $statusPath -Raw | Should -Be 'acrylic-local-validate-hash-io'
        }

        It "Keeps Chocolatey as an online-only fallback that offline never reaches" {
            $onlineInstaller = Get-Content (Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1") -Raw
            $offlineModule = Get-Content (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1") -Raw

            $onlineInstaller | Should -Match 'choco'
            $offlineModule | Should -Not -Match 'choco'
        }
    }

    Context "Pending enrollment state" {
        It "Saves pending state as a DPAPI blob with restrictive ACLs and reads it back" -Skip:(($null -ne $IsWindows) -and (-not $IsWindows)) {
            $openPathRoot = Join-Path $script:OfflineTestRoot 'agent-root'
            New-Item -ItemType Directory -Path (Join-Path $openPathRoot 'data') -Force | Out-Null
            Mock Write-OpenPathLog { }

            $statePath = Save-OpenPathPendingEnrollmentState `
                -OpenPathRoot $openPathRoot `
                -ApiUrl 'https://api.example.test' `
                -ClassroomId 'room_pending' `
                -EnrollmentToken 'bearer-secret-value' `
                -ExpiresAt ([System.DateTime]::UtcNow.AddHours(20).ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + 'Z')

            $statePath | Should -BeLike '*.dpapi'
            Test-Path $statePath | Should -BeTrue

            $rawBytes = [System.IO.File]::ReadAllBytes($statePath)
            [System.Text.Encoding]::UTF8.GetString($rawBytes) | Should -Not -Match 'bearer-secret-value'

            $acl = Get-Acl $statePath
            @($acl.Access).Count | Should -BeGreaterThan 0
            @($acl.Access) | Where-Object { $_.IdentityReference -like '*Users*' } | Should -BeNullOrEmpty

            $state = Read-OpenPathPendingEnrollmentState -OpenPathRoot $openPathRoot
            $state.enrollmentToken | Should -Be 'bearer-secret-value'
            $state.classroomId | Should -Be 'room_pending'
        }

        It "Returns null when no pending state exists" {
            Read-OpenPathPendingEnrollmentState -OpenPathRoot (Join-Path $script:OfflineTestRoot 'empty-root') | Should -BeNullOrEmpty
        }

        It "Detects expired pending state" {
            $expiredState = [PSCustomObject]@{ expiresAt = [System.DateTime]::UtcNow.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + 'Z' }
            $liveState = [PSCustomObject]@{ expiresAt = [System.DateTime]::UtcNow.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + 'Z' }
            $jsonRoundTrippedExpiredState = (@{ expiresAt = $expiredState.expiresAt } | ConvertTo-Json -Compress | ConvertFrom-Json)

            Test-OpenPathPendingEnrollmentExpired -State $expiredState | Should -BeTrue
            Test-OpenPathPendingEnrollmentExpired -State $liveState | Should -BeFalse
            Test-OpenPathPendingEnrollmentExpired -State $jsonRoundTrippedExpiredState | Should -BeTrue
        }

        It "Transitions expired state to an EXPIRED marker without secrets and logs re-installation guidance" -Skip:(($null -ne $IsWindows) -and (-not $IsWindows)) {
            $openPathRoot = Join-Path $script:OfflineTestRoot 'expired-root'
            New-Item -ItemType Directory -Path (Join-Path $openPathRoot 'data') -Force | Out-Null
            Mock Write-OpenPathLog { }

            Save-OpenPathPendingEnrollmentState `
                -OpenPathRoot $openPathRoot `
                -ApiUrl 'https://api.example.test' `
                -ClassroomId 'room_expired' `
                -EnrollmentToken 'expired-secret' `
                -ExpiresAt ([System.DateTime]::UtcNow.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + 'Z') | Out-Null

            $outcome = Invoke-OpenPathPendingEnrollmentRetry -OpenPathRoot $openPathRoot

            $outcome.Outcome | Should -Be 'EXPIRED'
            Test-Path (Get-OpenPathPendingEnrollmentStatePath -OpenPathRoot $openPathRoot) | Should -BeFalse

            $marker = Get-Content (Join-Path $openPathRoot 'data\pending-enrollment.json') -Raw | ConvertFrom-Json
            $marker.status | Should -Be 'EXPIRED'
            ($marker | ConvertTo-Json) | Should -Not -Match 'expired-secret'

            Should -Invoke Write-OpenPathLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'ERROR' }
        }

        It "Clears the pending state after a successful retry enrollment and keeps the token out of logs" {
            $offlineModule = Get-Content (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1") -Raw
            $retryBody = [regex]::Match($offlineModule, 'function Invoke-OpenPathPendingEnrollmentRetry\s*\{[\s\S]*?\n\}').Value

            Assert-ContentContainsAll -Content $retryBody -Needles @(
                'Clear-OpenPathPendingEnrollmentState',
                'Outcome = ''REGISTERED''',
                'Unattended = $true',
                'Quiet = $true'
            )

            $retryBody | Should -Not -Match 'Write-OpenPathLog[^\r\n]*\$state\.enrollmentToken'
            $retryBody | Should -Not -Match 'Write-Host[^\r\n]*\$state\.enrollmentToken'
        }
    }

    Context "Startup consumption wiring" {
        It "Wires pending-enrollment retry into the update cycle without logging the bearer token" {
            $updateRuntime = Get-Content (Join-Path $PSScriptRoot ".." "lib" "Update.Runtime.psm1") -Raw

            Assert-ContentContainsAll -Content $updateRuntime -Needles @(
                'Invoke-OpenPathPendingEnrollmentRetry',
                'Installer.Offline.ps1'
            )

            $retryBlock = [regex]::Match(
                $updateRuntime,
                'Invoke-OpenPathPendingEnrollmentRetry[\s\S]{0,400}',
                'IgnoreCase').Value
            $retryBlock | Should -Not -Match '\.enrollmentToken'
        }
    }

    Context "Browser boundary failure evidence contract" {
        It "preserves sanitized failed Edge evidence before writing the offline E2E artifact" {
            $offlineE2e = Get-Content (Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "run-windows-offline-installer-exe.ps1") -Raw

            Assert-ContentContainsAll -Content $offlineE2e -Needles @(
                'Get-OpenPathLastBoundaryProbeFailureEvidence',
                'Get-OpenPathDisposableBoundaryFailureEvidence',
                'OpenPathEdgeBoundaryEvidence',
                'edgeBoundaryEvidence',
                'edge = if ($edgeFailureContract)',
                'edgeName',
                'edgeStudentSid',
                'edgeExecutablePath',
                'edgeSamGroupSid',
                'edgeRestrictedGroupAttributes',
                'testAppLockerPolicyDecision',
                'edgeTaskRegisteredAtUtc',
                'edgeEventId',
                'edgeTokenObserver',
                'edgePolicyObserver',
                'edgeAppLockerEventQueries',
                'enforcementObservation',
                'edgeEnforcementObservation',
                'Write-SafeEvidence -Payload $failure -Path $EvidencePath'
            )
            $disposableTarget = Get-Content (Join-Path $PSScriptRoot '..' '..' 'tests' 'e2e' 'ci' 'DisposableWindowsTarget.psm1') -Raw
            Assert-ContentContainsAll -Content $disposableTarget -Needles @(
                'Get-OpenPathDisposableBoundaryFailureEvidence',
                'Get-OpenPathDisposableFlatEdgeBoundaryFailureContract',
                'Invoke-OpenPathDisposableEdgeBoundaryDiagnostic',
                "Data['OpenPathEdgeBoundaryEvidence']"
            )
            $offlineE2e | Should -Not -Match '\$failure\.edgeBoundaryEvidence\s*=\s*\$disposableTarget\.Password'
        }

        It "uses bounded Edge diagnostic attempts at T0, plus 5, 15, and 30 seconds without policy reapply" {
            $probeModule = Get-Content (Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "BrowserBoundaryProbe.psm1") -Raw
            $offlineE2e = Get-Content (Join-Path $PSScriptRoot ".." ".." "tests" "e2e" "ci" "run-windows-offline-installer-exe.ps1") -Raw

            Assert-ContentContainsAll -Content $probeModule -Needles @(
                'AttemptOffsetsSeconds = @(0, 5, 15, 30)',
                'policyReapplied = $false',
                'offsetSeconds'
            )
            Assert-ContentContainsAll -Content $offlineE2e -Needles @(
                'Invoke-OpenPathEdgeBoundaryDiagnostic',
                'Invoke-OpenPathDisposableEdgeBoundaryDiagnostic',
                'edgeBoundaryEvidence'
            )
            $diagnosticBody = [regex]::Match($probeModule, 'function Invoke-OpenPathEdgeBoundaryDiagnostic\s*\{[\s\S]*?\n\}').Value
            $diagnosticBody | Should -Not -Match 'Set-OpenPathNonAdminAppControl|Get-AppLockerPolicy|Set-AppLockerPolicy'
        }

        It "round-trips nested Edge and cleanup failures through the real evidence writer" {
            Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\DisposableWindowsTarget.psm1') -Force
            $evidencePath = Join-Path $TestDrive 'edge-failure-roundtrip.json'
            $payload = [ordered]@{
                status = 'failed'; failureDetailCode = 'boundary-edge-execution-failed'
                edgeBoundaryEvidence = [ordered]@{
                    initial = [ordered]@{
                        failureCode = 'exact-student-process-observed-without-block-event'
                        executablePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
                        studentSid = 'S-1-5-21-100-200-300-400'
                        processes = @([ordered]@{
                                processId = 5436
                                restrictedGroupPresent = $null
                                restrictedGroupAttributes = $null
                                restrictedGroupQueryStatus = 'unavailable'
                                tokenObserver = [ordered]@{
                                    processExists = $true
                                    processExistsStatus = 'observed'
                                    errorCode = 87
                                    errorName = 'ERROR_INVALID_PARAMETER'
                                    failureStage = 'OpenProcessToken'
                                    observerArchitecture = '64-bit'
                                    observerPid = 9882
                                    nativeStages = @([ordered]@{ stage = 'OpenProcessToken'; accessMask = '0x00000008'; win32Code = 87; win32Name = 'ERROR_INVALID_PARAMETER' })
                                }
                            })
                        testAppLockerPolicyDecision = [ordered]@{
                            status = 'observed'
                            decision = 'Denied'
                            path = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
                            userSid = 'S-1-5-21-100-200-300-400'
                            runtime = [ordered]@{ edition = 'Core'; version = '7.6.5'; bitness = '64-bit'; processId = 9883 }
                            testAppLockerPolicy = [ordered]@{ available = $true; source = 'AppLocker' }
                            import = [ordered]@{ attempted = $false; result = 'not-required' }
                            nativePowerShellComparison = [ordered]@{
                                status = 'observed'
                                decision = 'Allowed'
                                path = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
                                userSid = 'S-1-5-21-100-200-300-400'
                                runtime = [ordered]@{ edition = 'Desktop'; version = '5.1.26100'; bitness = '64-bit'; processId = 7780 }
                            }
                        }
                        appLockerEventQueries = [ordered]@{
                            '8002' = [ordered]@{
                                status = 'QUERY_SUCCEEDED_MATCHES'
                                channel = 'Microsoft-Windows-AppLocker/EXE and DLL'
                                eventId = 8002
                                channelExists = $true
                                queryAttempted = $true
                                querySucceeded = $true
                                eventCount = 1
                                events = @()
                                correlationStatus = 'CORRELATION_FAILED'
                                correlationException = [ordered]@{ type = 'System.InvalidOperationException'; fullyQualifiedErrorId = 'correlation-failed'; hResult = -1; safeReason = 'event-correlation-failed' }
                            }
                            '8004' = [ordered]@{
                                status = 'QUERY_SUCCEEDED_NO_MATCHES'
                                channel = 'Microsoft-Windows-AppLocker/EXE and DLL'
                                eventId = 8004
                                channelExists = $true
                                queryAttempted = $true
                                querySucceeded = $true
                                eventCount = 0
                                events = @()
                            }
                            '8020' = [ordered]@{
                                status = 'QUERY_FAILED'
                                channel = 'Microsoft-Windows-AppLocker/Packaged app-Execution'
                                eventId = 8020
                                channelExists = $true
                                queryAttempted = $true
                                querySucceeded = $false
                                eventCount = 0
                                exception = [ordered]@{ type = 'System.InvalidOperationException'; fullyQualifiedErrorId = 'event-query-failed'; hResult = -1; safeReason = 'event-query-failed' }
                            }
                            '8022' = [ordered]@{
                                status = 'QUERY_SUCCEEDED_NO_MATCHES'
                                channel = 'Microsoft-Windows-AppLocker/Packaged app-Execution'
                                eventId = 8022
                                channelExists = $true
                                queryAttempted = $true
                                querySucceeded = $true
                                eventCount = 0
                                events = @()
                            }
                        }
                        enforcementObservation = [ordered]@{
                            before = [ordered]@{ phase = 'before-launch'; status = 'observed'; appIdSvc = [ordered]@{ running = $true } }
                            after = [ordered]@{
                                phase = 'after-launch'; status = 'unknown'; reason = 'enforcement-observer-failed'
                                appLocker = [ordered]@{
                                    policy = [ordered]@{ hashAlgorithm = 'SHA256'; hashScope = 'UTF8-AppLockerPolicy-OuterXml' }
                                    queries = [ordered]@{ '8004' = [ordered]@{ status = 'QUERY_SUCCEEDED_NO_MATCHES'; querySucceeded = $true; nativePowerShellComparison = [ordered]@{ status = 'QUERY_SUCCEEDED_NO_MATCHES' } } }
                                }
                            }
                        }
                    }
                    repeat = [ordered]@{ attempts = @([ordered]@{ label = 'T+5'; elapsedSeconds = 5.7; taskName = 'edge-t5'; evidence = [ordered]@{ appLocker8004 = $null; queryStatus = 'failed' } }) }
                }
                cleanupAttempted = $true; cleanupSucceeded = $false
                targetCleanup = [ordered]@{ profileRemoved = $false; credentialDestroyed = $true }
            }

            Write-OpenPathOfflineInstallerEvidence -Payload $payload -Path $evidencePath
            $roundTrip = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json

            $roundTrip.status | Should -Be 'failed'
            $roundTrip.failureDetailCode | Should -Be 'boundary-edge-execution-failed'
            $roundTrip.edgeBoundaryEvidence.initial.failureCode | Should -Be 'exact-student-process-observed-without-block-event'
            $roundTrip.edgeBoundaryEvidence.initial.processes[0].restrictedGroupPresent | Should -BeNullOrEmpty
            $roundTrip.edgeBoundaryEvidence.initial.processes[0].restrictedGroupQueryStatus | Should -Be 'unavailable'
            $roundTrip.edgeBoundaryEvidence.initial.processes[0].tokenObserver.failureStage | Should -Be 'OpenProcessToken'
            $roundTrip.edgeBoundaryEvidence.initial.testAppLockerPolicyDecision.runtime.edition | Should -Be 'Core'
            $roundTrip.edgeBoundaryEvidence.initial.testAppLockerPolicyDecision.nativePowerShellComparison.decision | Should -Be 'Allowed'
            $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8004'.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            @($roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.PSObject.Properties.Name | Sort-Object) | Should -Be @('8002', '8004', '8020', '8022')
            $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8002'.status | Should -Be 'QUERY_SUCCEEDED_MATCHES'
            $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8002'.correlationStatus | Should -Be 'CORRELATION_FAILED'
            $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8002'.correlationException.safeReason | Should -Be 'event-correlation-failed'
            $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8020'.status | Should -Be 'QUERY_FAILED'
            $roundTrip.edgeBoundaryEvidence.initial.appLockerEventQueries.'8022'.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            $roundTrip.edgeBoundaryEvidence.initial.enforcementObservation.before.appIdSvc.running | Should -BeTrue
            $roundTrip.edgeBoundaryEvidence.initial.enforcementObservation.after.appLocker.queries.'8004'.nativePowerShellComparison.status | Should -Be 'QUERY_SUCCEEDED_NO_MATCHES'
            $roundTrip.edgeBoundaryEvidence.repeat.attempts[0].elapsedSeconds | Should -Be 5.7
            $roundTrip.edgeBoundaryEvidence.repeat.attempts[0].evidence.queryStatus | Should -Be 'failed'
            $roundTrip.cleanupSucceeded | Should -BeFalse
            $roundTrip.targetCleanup.profileRemoved | Should -BeFalse
            (Get-Content -LiteralPath $evidencePath -Raw) | Should -Not -Match 'Password|must-not-serialize'
        }
    }

    Context "Uninstall deletion" {
        It "Explicitly removes pending enrollment state files during uninstall" {
            $uninstall = Get-Content (Join-Path $PSScriptRoot ".." "Uninstall-OpenPath.ps1") -Raw

            Assert-ContentContainsAll -Content $uninstall -Needles @(
                'pending-enrollment.json.dpapi',
                'pending-enrollment.json'
            )
        }
    }
}
