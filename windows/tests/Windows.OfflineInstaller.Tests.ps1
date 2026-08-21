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
    }

    Context "Install-AcrylicDNSFromLocalSource" {
        It "Never references download URLs or Chocolatey in the offline install path" {
            $content = Get-Content (Join-Path $PSScriptRoot ".." "lib" "install" "Installer.Offline.ps1") -Raw
            $functionBody = [regex]::Match($content, 'function Install-AcrylicDNSFromLocalSource\s*\{[\s\S]*?\n\}').Value

            $functionBody | Should -Not -Match 'https?://'
            $functionBody | Should -Not -Match 'choco'
            $functionBody | Should -Match 'Assert-AcrylicDownloadHash'
            $functionBody | Should -Match 'Expand-Archive'
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

            $statePath = Save-OpenPathPendingEnrollmentState `
                -OpenPathRoot $openPathRoot `
                -ApiUrl 'https://api.example.test' `
                -ClassroomId 'room_pending' `
                -EnrollmentToken 'bearer-secret-value' `
                -ExpiresAt ([System.DateTime]::UtcNow.AddHours(20).ToString('o'))

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
            $expiredState = [PSCustomObject]@{ expiresAt = [System.DateTime]::UtcNow.AddMinutes(-5).ToString('o') }
            $liveState = [PSCustomObject]@{ expiresAt = [System.DateTime]::UtcNow.AddHours(1).ToString('o') }

            Test-OpenPathPendingEnrollmentExpired -State $expiredState | Should -BeTrue
            Test-OpenPathPendingEnrollmentExpired -State $liveState | Should -BeFalse
        }

        It "Transitions expired state to an EXPIRED marker without secrets and logs re-installation guidance" -Skip:(($null -ne $IsWindows) -and (-not $IsWindows)) {
            $openPathRoot = Join-Path $script:OfflineTestRoot 'expired-root'
            New-Item -ItemType Directory -Path (Join-Path $openPathRoot 'data') -Force | Out-Null
            Save-OpenPathPendingEnrollmentState `
                -OpenPathRoot $openPathRoot `
                -ApiUrl 'https://api.example.test' `
                -ClassroomId 'room_expired' `
                -EnrollmentToken 'expired-secret' `
                -ExpiresAt ([System.DateTime]::UtcNow.AddMinutes(-10).ToString('o')) | Out-Null

            Mock Write-OpenPathLog { }

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
