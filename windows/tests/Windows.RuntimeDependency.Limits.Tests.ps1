# Runtime dependency overlay limits and audit trail.
#
# Pure-logic Pester coverage (pwsh 7 + Pester 5, no Windows-only cmdlets).
# Every test isolates $script:OpenPathRoot under $TestDrive and passes an
# explicit audit path so nothing under C:\OpenPath is touched.

Describe 'Runtime dependency overlay limits' {
    BeforeAll {
        $script:internalLib = Join-Path $PSScriptRoot '..' 'lib' 'internal'
        $script:previousOpenPathRoot = $script:OpenPathRoot
        $script:previousAuditPath = $env:OPENPATH_RUNTIME_DEPENDENCY_AUDIT_PATH
        $script:previousMaxPerAnchor = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_MAX_PER_ANCHOR
        $script:previousRateLimit = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_LIMIT
        $script:previousRateWindow = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_WINDOW_MINUTES
        $script:previousOverlayPath = $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH
        $script:previousQueuePath = $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH

        . (Join-Path $script:internalLib 'CapabilityStorage.ps1')
        . (Join-Path $script:internalLib 'RuntimeDependency.Policy.ps1')

        # The audit file ACL is a Windows-only operation. Stub the shared ACL
        # helpers so the Linux lane can assert that the restricted profile is
        # requested without running icacls.
        $script:auditAclProfiles = [System.Collections.Generic.List[string]]::new()
        function Test-OpenPathCapabilityStorageAcl {
            param([string]$Path, [string]$Profile)
            return $false
        }
        function Set-OpenPathCapabilityStorageAcl {
            param([string]$Path, [string]$Profile)
            [void]$script:auditAclProfiles.Add($Profile)
        }
        function Write-OpenPathLog {
            param([string]$Message, [string]$Level = 'INFO')
            $script:capturedLogs += [string]$Message
        }
        $script:capturedLogs = @()

        . (Join-Path $script:internalLib 'RuntimeDependency.Overlay.ps1')
        . (Join-Path $script:internalLib 'RuntimeDependency.Queue.ps1')
    }

    AfterAll {
        $script:OpenPathRoot = $script:previousOpenPathRoot
        $env:OPENPATH_RUNTIME_DEPENDENCY_AUDIT_PATH = $script:previousAuditPath
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_MAX_PER_ANCHOR = $script:previousMaxPerAnchor
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_LIMIT = $script:previousRateLimit
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_WINDOW_MINUTES = $script:previousRateWindow
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = $script:previousOverlayPath
        $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH = $script:previousQueuePath
    }

    BeforeEach {
        $script:OpenPathRoot = Join-Path $TestDrive ('openpath-root-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:OpenPathRoot 'data') -Force | Out-Null
        $env:OPENPATH_RUNTIME_DEPENDENCY_AUDIT_PATH = $null
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_MAX_PER_ANCHOR = $null
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_LIMIT = $null
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_WINDOW_MINUTES = $null
        $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH = $null
        $env:OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH = $null
        $script:capturedLogs = @()
        $script:auditAclProfiles.Clear()
    }

    Context 'Per-anchor live dependency limit' {
        It 'Rejects a new dependency when the anchor already has its maximum live dependencies' {
            $auditPath = Join-Path $TestDrive 'audit-anchor.log'
            $now = [DateTimeOffset]::UtcNow
            $entries = @(
                [PSCustomObject]@{
                    dependencyHost = 'dep-one.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('script')
                    firstSeen = $now.AddMinutes(-30).ToString('o')
                    lastSeen = $now.AddMinutes(-30).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                },
                [PSCustomObject]@{
                    dependencyHost = 'dep-two.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('image')
                    firstSeen = $now.AddMinutes(-20).ToString('o')
                    lastSeen = $now.AddMinutes(-20).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                },
                [PSCustomObject]@{
                    dependencyHost = 'dep-three.example.net'
                    anchorHost = 'anchor-two.example.com'
                    requestTypes = @('script')
                    firstSeen = $now.AddMinutes(-10).ToString('o')
                    lastSeen = $now.AddMinutes(-10).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                }
            )

            $result = Update-OpenPathRuntimeDependencyOverlay `
                -Entries $entries `
                -Requests @(
                    [PSCustomObject]@{ anchorHost = 'anchor-one.example.com'; dependencyHost = 'dep-new.example.net'; requestType = 'script' },
                    [PSCustomObject]@{ anchorHost = 'anchor-two.example.com'; dependencyHost = 'dep-four.example.net'; requestType = 'image' }
                ) `
                -WhitelistedDomains @('anchor-one.example.com', 'anchor-two.example.com') `
                -BlockedSubdomains @() `
                -Capacity 100 `
                -TtlDays 7 `
                -MaxPerAnchor 2 `
                -RateLimit 100 `
                -RateWindowMinutes 5 `
                -AuditPath $auditPath

            $result.LimitRejected | Should -Be 1
            $result.Rejected | Should -Be 1
            $result.Processed | Should -Be 1
            $result.Entries.dependencyHost | Should -Not -Contain 'dep-new.example.net'
            $result.Entries.dependencyHost | Should -Contain 'dep-four.example.net'
            $result.Rejections.Count | Should -Be 1
            $result.Rejections[0].Reason | Should -Be 'anchor-capacity'
            $result.Rejections[0].Error | Should -Match 'anchor'

            $lines = @(Get-Content -LiteralPath $auditPath -Encoding UTF8)
            $lines.Count | Should -Be 2
            @($lines | Where-Object { $_ -match 'event=rejected anchor=anchor-one\.example\.com dependency=dep-new\.example\.net type=script reason=anchor-capacity' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'event=accepted anchor=anchor-two\.example\.com dependency=dep-four\.example\.net type=image reason=new-dependency' }).Count | Should -Be 1
        }

        It 'Allows an existing pair to refresh without counting it as a new acceptance' {
            $auditPath = Join-Path $TestDrive 'audit-refresh.log'
            $now = [DateTimeOffset]::UtcNow
            $entries = @(
                [PSCustomObject]@{
                    dependencyHost = 'dep-one.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('script')
                    firstSeen = $now.AddMinutes(-30).ToString('o')
                    lastSeen = $now.AddMinutes(-30).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                },
                [PSCustomObject]@{
                    dependencyHost = 'dep-two.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('image')
                    firstSeen = $now.AddMinutes(-20).ToString('o')
                    lastSeen = $now.AddMinutes(-20).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                }
            )

            $result = Update-OpenPathRuntimeDependencyOverlay `
                -Entries $entries `
                -Requests @(
                    [PSCustomObject]@{ anchorHost = 'anchor-one.example.com'; dependencyHost = 'dep-one.example.net'; requestType = 'xmlhttprequest' }
                ) `
                -WhitelistedDomains @('anchor-one.example.com') `
                -BlockedSubdomains @() `
                -Capacity 100 `
                -TtlDays 7 `
                -MaxPerAnchor 2 `
                -RateLimit 100 `
                -RateWindowMinutes 5 `
                -AuditPath $auditPath

            $result.LimitRejected | Should -Be 0
            $result.Processed | Should -Be 1
            $refreshed = @($result.Entries | Where-Object { $_.dependencyHost -eq 'dep-one.example.net' })[0]
            @($refreshed.requestTypes) | Should -Contain 'xmlhttprequest'
            Test-Path -LiteralPath $auditPath | Should -BeFalse
        }
    }

    Context 'Machine-wide new dependency rate limit' {
        It 'Rejects new dependencies once the sliding window limit is reached' {
            $auditPath = Join-Path $TestDrive 'audit-rate.log'
            $now = [DateTimeOffset]::UtcNow
            $entries = @(
                [PSCustomObject]@{
                    dependencyHost = 'recent-one.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('script')
                    firstSeen = $now.AddMinutes(-1).ToString('o')
                    lastSeen = $now.AddMinutes(-1).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                },
                [PSCustomObject]@{
                    dependencyHost = 'recent-two.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('image')
                    firstSeen = $now.AddMinutes(-2).ToString('o')
                    lastSeen = $now.AddMinutes(-2).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                },
                [PSCustomObject]@{
                    dependencyHost = 'old-one.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('font')
                    firstSeen = $now.AddMinutes(-30).ToString('o')
                    lastSeen = $now.AddMinutes(-30).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                }
            )

            $result = Update-OpenPathRuntimeDependencyOverlay `
                -Entries $entries `
                -Requests @(
                    [PSCustomObject]@{ anchorHost = 'anchor-one.example.com'; dependencyHost = 'new-one.example.net'; requestType = 'script' },
                    [PSCustomObject]@{ anchorHost = 'anchor-one.example.com'; dependencyHost = 'new-two.example.net'; requestType = 'script' },
                    [PSCustomObject]@{ anchorHost = 'anchor-one.example.com'; dependencyHost = 'new-three.example.net'; requestType = 'script' }
                ) `
                -WhitelistedDomains @('anchor-one.example.com') `
                -BlockedSubdomains @() `
                -Capacity 100 `
                -TtlDays 7 `
                -MaxPerAnchor 100 `
                -RateLimit 3 `
                -RateWindowMinutes 5 `
                -AuditPath $auditPath

            $result.LimitRejected | Should -Be 2
            $result.Rejected | Should -Be 2
            $result.Processed | Should -Be 1
            $result.Entries.dependencyHost | Should -Contain 'new-one.example.net'
            $result.Entries.dependencyHost | Should -Not -Contain 'new-two.example.net'
            $result.Entries.dependencyHost | Should -Not -Contain 'new-three.example.net'
            @($result.Rejections | Where-Object { $_.Reason -eq 'rate-limit' }).Count | Should -Be 2
            @($result.Rejections | Where-Object { $_.Error -match 'rate limit' }).Count | Should -Be 2

            $lines = @(Get-Content -LiteralPath $auditPath -Encoding UTF8)
            $lines.Count | Should -Be 3
            @($lines | Where-Object { $_ -match 'event=accepted anchor=anchor-one\.example\.com dependency=new-one\.example\.net type=script reason=new-dependency' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'event=rejected .* reason=rate-limit' }).Count | Should -Be 2
        }

        It 'Does not count entries whose firstSeen is outside the window' {
            $auditPath = Join-Path $TestDrive 'audit-rate-old.log'
            $now = [DateTimeOffset]::UtcNow
            $entries = @(
                [PSCustomObject]@{
                    dependencyHost = 'old-one.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('script')
                    firstSeen = $now.AddMinutes(-30).ToString('o')
                    lastSeen = $now.AddMinutes(-30).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                }
            )

            $result = Update-OpenPathRuntimeDependencyOverlay `
                -Entries $entries `
                -Requests @(
                    [PSCustomObject]@{ anchorHost = 'anchor-one.example.com'; dependencyHost = 'new-one.example.net'; requestType = 'script' }
                ) `
                -WhitelistedDomains @('anchor-one.example.com') `
                -BlockedSubdomains @() `
                -Capacity 100 `
                -TtlDays 7 `
                -MaxPerAnchor 100 `
                -RateLimit 1 `
                -RateWindowMinutes 5 `
                -AuditPath $auditPath

            $result.LimitRejected | Should -Be 0
            $result.Entries.dependencyHost | Should -Contain 'new-one.example.net'
        }
    }

    Context 'Queue wiring' {
        It 'Passes the configured limits and audit path from settings into the overlay update' {
            $auditPath = Join-Path $TestDrive 'audit-queue.log'
            $env:OPENPATH_RUNTIME_DEPENDENCY_AUDIT_PATH = $auditPath
            $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_MAX_PER_ANCHOR = '1'
            $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_LIMIT = '100'
            $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_WINDOW_MINUTES = '5'

            $queuePath = Join-Path $TestDrive 'queue'
            New-Item -ItemType Directory -Path $queuePath -Force | Out-Null
            $now = [DateTimeOffset]::UtcNow
            $overlayPath = Get-OpenPathRuntimeDependencyOverlayPath
            Write-OpenPathRuntimeDependencyOverlay -Path $overlayPath -Entries @(
                [PSCustomObject]@{
                    dependencyHost = 'dep-one.example.net'
                    anchorHost = 'anchor-one.example.com'
                    requestTypes = @('script')
                    firstSeen = $now.AddMinutes(-10).ToString('o')
                    lastSeen = $now.AddMinutes(-10).ToString('o')
                    expiresAt = $now.AddDays(1).ToString('o')
                    source = 'firefox-webrequest-local'
                }
            )

            $null = Write-OpenPathRuntimeDependencyQueueRequest `
                -AnchorHost 'anchor-one.example.com' `
                -DependencyHost 'dep-two.example.net' `
                -RequestType 'script' `
                -QueuePath $queuePath
            $null = Write-OpenPathRuntimeDependencyQueueRequest `
                -AnchorHost 'anchor-two.example.com' `
                -DependencyHost 'dep-three.example.net' `
                -RequestType 'image' `
                -QueuePath $queuePath

            $result = Invoke-OpenPathRuntimeDependencyQueue `
                -WhitelistedDomains @('anchor-one.example.com', 'anchor-two.example.com') `
                -BlockedSubdomains @() `
                -QueuePath $queuePath

            $result.LimitRejected | Should -Be 1
            $result.Rejected | Should -Be 1
            $result.Processed | Should -Be 1
            $result.Rejections[0].Reason | Should -Be 'anchor-capacity'
            $overlay = @(Read-OpenPathRuntimeDependencyOverlay -Path $overlayPath)
            $overlay.dependencyHost | Should -Contain 'dep-one.example.net'
            $overlay.dependencyHost | Should -Contain 'dep-three.example.net'
            $overlay.dependencyHost | Should -Not -Contain 'dep-two.example.net'
            $lines = @(Get-Content -LiteralPath $auditPath -Encoding UTF8)
            @($lines | Where-Object { $_ -match 'event=rejected .* reason=anchor-capacity' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'event=accepted .* reason=new-dependency' }).Count | Should -Be 1
        }
    }

    Context 'Audit trail' {
        It 'Writes UTC timestamps that parse with invariant culture and requests the restricted ACL profile' {
            $auditPath = Join-Path $TestDrive 'audit-format.log'
            $result = Update-OpenPathRuntimeDependencyOverlay `
                -Entries @() `
                -Requests @(
                    [PSCustomObject]@{ anchorHost = 'anchor-one.example.com'; dependencyHost = 'dep-one.example.net'; requestType = 'script' }
                ) `
                -WhitelistedDomains @('anchor-one.example.com') `
                -BlockedSubdomains @() `
                -Capacity 100 `
                -TtlDays 7 `
                -MaxPerAnchor 10 `
                -RateLimit 10 `
                -RateWindowMinutes 5 `
                -AuditPath $auditPath

            $result.LimitRejected | Should -Be 0
            $line = @(Get-Content -LiteralPath $auditPath -Encoding UTF8)[0]
            $null = $line -match '^(?<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z) '
            $Matches.timestamp | Should -Not -BeNullOrEmpty
            # ps-culture-allow: invariant culture and round-trip kind are supplied on the continued arguments
            $parsed = [DateTimeOffset]::Parse(
                $Matches.timestamp,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
            $parsed.Offset | Should -Be ([TimeSpan]::Zero)
            $line | Should -Match 'anchor=anchor-one\.example\.com dependency=dep-one\.example\.net type=script reason=new-dependency'
            $script:auditAclProfiles | Should -Contain 'RestrictedRoot'
            $script:auditAclProfiles | Should -Not -Contain 'RuntimeDependencyRead'
        }
    }

    Context 'Settings' {
        It 'Uses the evidence-backed defaults and reads environment overrides' {
            $defaults = Get-OpenPathRuntimeDependencyOverlaySettings
            $defaults.TtlDays | Should -Be 7
            $defaults.Capacity | Should -Be 300
            $defaults.MaxPerAnchor | Should -Be 32
            $defaults.RateLimit | Should -Be 60
            $defaults.RateWindowMinutes | Should -Be 5

            $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_MAX_PER_ANCHOR = '7'
            $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_LIMIT = '11'
            $env:OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_WINDOW_MINUTES = '3'
            $env:OPENPATH_RUNTIME_DEPENDENCY_AUDIT_PATH = (Join-Path $TestDrive 'custom-audit.log')

            $overridden = Get-OpenPathRuntimeDependencyOverlaySettings
            $overridden.MaxPerAnchor | Should -Be 7
            $overridden.RateLimit | Should -Be 11
            $overridden.RateWindowMinutes | Should -Be 3
            $overridden.AuditPath | Should -Be (Join-Path $TestDrive 'custom-audit.log')
        }
    }
}
