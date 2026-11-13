Describe "OpenPath agent update recovery" {
    BeforeAll {
        $script:WindowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $script:RecoveryScriptPath = Join-Path $script:WindowsRoot 'scripts/Recover-OpenPathAgentUpdate.ps1'
        $script:GateScriptPath = Join-Path $script:WindowsRoot 'scripts/Test-OpenPathAgentUpdateHealth.ps1'
        $script:PwshPath = (Get-Process -Id $PID).Path

        function New-RecoveryRoot {
            $root = Join-Path $TestDrive ('recovery-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            return $root
        }

        function New-RecoveryFile {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$Content
            )

            $directory = Split-Path $Path -Parent
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
        }

        function Get-TestFileHash {
            param([Parameter(Mandatory = $true)][string]$Path)

            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        function Get-TestContentHash {
            param([Parameter(Mandatory = $true)][string]$Content)

            $path = Join-Path $TestDrive ('hash-source-' + [guid]::NewGuid().ToString('N'))
            New-RecoveryFile -Path $path -Content $Content
            try {
                return Get-TestFileHash -Path $path
            }
            finally {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }

        function New-RecoveryJournalEntry {
            param(
                [Parameter(Mandatory = $true)][string]$RelativePath,
                [Parameter(Mandatory = $true)][bool]$ExistedBefore,
                [string]$PreviousSha256 = '',
                [Parameter(Mandatory = $true)][string]$TargetSha256
            )

            return [PSCustomObject]@{
                relativePath    = $RelativePath
                existedBefore   = $ExistedBefore
                previousSha256  = $PreviousSha256
                sha256          = $TargetSha256
            }
        }

        function Write-RecoveryJournal {
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [Parameter(Mandatory = $true)][object[]]$Files,
                [string]$Phase = 'replacing',
                [int]$SchemaVersion = 2,
                [string]$BackupRoot = '',
                [string]$UpdatedAt = ''
            )

            $updateRoot = Join-Path $Root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
                $BackupRoot = Join-Path $updateRoot 'backups/run-test'
            }
            if ([string]::IsNullOrWhiteSpace($UpdatedAt)) {
                $UpdatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }

            $journal = [PSCustomObject]@{
                schemaVersion   = $SchemaVersion
                phase           = $Phase
                targetVersion   = '9.9.9'
                targetBuild     = 'build-new'
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $BackupRoot
                createdAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                updatedAt       = $UpdatedAt
                files           = @($Files)
            }

            $journal | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath (Join-Path $updateRoot 'update-journal.json') -Encoding UTF8
        }

        function Invoke-RecoveryScript {
            param([Parameter(Mandatory = $true)][string]$Root)

            $output = & $script:PwshPath -NoProfile -NonInteractive -File $script:RecoveryScriptPath -OpenPathRoot $Root 2>&1
            return [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output   = (@($output) -join [Environment]::NewLine)
            }
        }

        function New-FakeAgentRoot {
            $root = New-RecoveryRoot
            $lib = Join-Path $root 'lib'
            $internal = Join-Path $lib 'internal'
            New-Item -ItemType Directory -Path $internal -Force | Out-Null

            $modules = @{
                'Common.psm1' = @'
function Write-OpenPathLog { param([string]$Message, [string]$Level = 'INFO') }
function Get-OpenPathConfig { }
function Get-OpenPathRuntimeHealth { }
function Send-OpenPathHealthReport { }
function Invoke-OpenPathAgentSelfUpdate { }
function Get-OpenPathCriticalFiles { }
function Test-OpenPathIntegrity { }
function Restore-OpenPathIntegrity { }
Export-ModuleMember -Function *
'@
                'DNS.psm1' = @'
function Get-AcrylicPath { }
function Test-DNSResolution { }
function Set-LocalDNS { }
function Restart-AcrylicService { }
Export-ModuleMember -Function *
'@
                'Network.psm1' = @'
function Get-OpenPathBridgeFilterCatalog { }
Export-ModuleMember -Function *
'@
                'Services.psm1' = @'
function Get-OpenPathTaskStatus { }
Export-ModuleMember -Function *
'@
                'Browser.psm1' = @'
function Get-OpenPathBrowserDoctorReport { }
Export-ModuleMember -Function *
'@
                'CaptivePortal.psm1' = @'
function Test-OpenPathCaptivePortalModeActive { }
Export-ModuleMember -Function *
'@
                'AppControl.psm1' = @'
function Test-OpenPathNonAdminAppControlActive { }
Export-ModuleMember -Function *
'@
                'Firewall.psm1' = @'
function Set-OpenPathFirewall { }
function Test-FirewallActive { }
Export-ModuleMember -Function *
'@
                'Update.Runtime.psm1' = @'
function Invoke-OpenPathUpdateCycle { }
Export-ModuleMember -Function *
'@
            }

            foreach ($name in $modules.Keys) {
                Set-Content -LiteralPath (Join-Path $lib $name) -Value $modules[$name] -Encoding ASCII
            }
            Set-Content -LiteralPath (Join-Path $internal 'Watchdog.Runtime.ps1') `
                -Value 'function Invoke-OpenPathWatchdogChecks { }' -Encoding ASCII

            return $root
        }

        function Invoke-GateScript {
            param([Parameter(Mandatory = $true)][string]$Root)

            $output = & $script:PwshPath -NoProfile -NonInteractive -File $script:GateScriptPath -OpenPathRoot $Root 2>&1
            return [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output   = (@($output) -join [Environment]::NewLine)
            }
        }

        function New-PartialRollbackFixture {
            param([ValidateSet('partial', 'corrupt-backup', 'untouched', 'stale-backup', 'outside')][string]$Kind = 'partial')

            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            $backupRoot = Join-Path $updateRoot 'backups/run-current'
            $oldHash = Get-TestContentHash -Content 'old-a'
            $newHash = Get-TestContentHash -Content 'new-a'
            $newBHash = Get-TestContentHash -Content 'new-b'

            New-RecoveryFile -Path (Join-Path $root 'lib/a.ps1') -Content 'new-a'

            if ($Kind -eq 'untouched') {
                New-RecoveryFile -Path (Join-Path $root 'lib/a.ps1') -Content 'old-a'
                $files = @(
                    New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                        -PreviousSha256 $oldHash -TargetSha256 $newHash
                )
            }
            elseif ($Kind -eq 'outside') {
                $backupRoot = Join-Path $updateRoot 'backups-x/run-current'
                New-RecoveryFile -Path (Join-Path $backupRoot 'lib/a.ps1') -Content 'old-a'
                $files = @(
                    New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                        -PreviousSha256 $oldHash -TargetSha256 $newHash
                )
            }
            else {
                $backupContent = if ($Kind -eq 'corrupt-backup') { 'corrupt-a' } else { 'old-a' }
                New-RecoveryFile -Path (Join-Path $backupRoot 'lib/a.ps1') -Content $backupContent
                if ($Kind -eq 'stale-backup') {
                    New-RecoveryFile -Path (Join-Path $updateRoot 'backups/9.9.8/lib/a.ps1') -Content 'stale-a'
                }
                $files = @(
                    New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                        -PreviousSha256 $oldHash -TargetSha256 $newHash
                )
            }

            if ($Kind -eq 'partial') {
                New-RecoveryFile -Path (Join-Path $root 'lib/b.ps1') -Content 'new-b'
                $files += New-RecoveryJournalEntry -RelativePath 'lib\b.ps1' -ExistedBefore $false `
                    -TargetSha256 $newBHash
            }

            Write-RecoveryJournal -Root $root -BackupRoot $backupRoot -Files $files

            return [PSCustomObject]@{
                Root   = $root
                BackupRoot = $backupRoot
                Files  = $files
            }
        }
    }

    Context "Standalone recovery script" {
        It "Contains no module import or lib dot-source (no OpenPath module dependency)" {
            $content = Get-Content -LiteralPath $script:RecoveryScriptPath -Raw

            $content | Should -Not -Match 'Import-Module'
            $content | Should -Not -Match '(?m)^\s*\.\s+'
            $content | Should -Not -Match '(?m)^\s*\.\s*\('
            $content | Should -Not -Match '(?m)^\s*exit\b'
            $content | Should -Match 'update-journal\.json'
            $content | Should -Match 'schemaVersion'
        }

        It "Does nothing when there is no journal" {
            $root = New-RecoveryRoot

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $root 'data/logs/openpath.log') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/recovery-report.json') | Should -BeFalse
        }

        It "Quarantines a journal with an unknown schema and writes a recovery report" {
            $root = New-RecoveryRoot
            $destination = Join-Path $root 'lib/a.ps1'
            New-RecoveryFile -Path $destination -Content 'new-a'
            Write-RecoveryJournal -Root $root -SchemaVersion 1 -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $false `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Join-Path $root 'data/agent-update') -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
            $reportPath = Join-Path $root 'data/agent-update/recovery-report.json'
            Test-Path -LiteralPath $reportPath | Should -BeTrue
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.status | Should -Be 'DEGRADED'
            $report.reasonCode | Should -Match '^self_update_recovery_journal_'
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'quarantin'
        }

        It "Quarantines an unreadable journal and resumes the integrity check" {
            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $updateRoot 'update-journal.json') `
                -Value '{ "schemaVersion": 2, "phase": ' -Encoding UTF8

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
            $report = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-report.json') -Raw | ConvertFrom-Json
            $report.reasonCode | Should -Match '^self_update_recovery_journal_'
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'quarantin'
        }

        It "Keeps at most three quarantined journals" {
            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            foreach ($index in 1..5) {
                $path = Join-Path $updateRoot ("update-journal.quarantine-20200101T00000{0}Z-old.json" -f $index)
                Set-Content -LiteralPath $path -Value '{}' -Encoding UTF8
                (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-$index)
            }
            Set-Content -LiteralPath (Join-Path $updateRoot 'update-journal.json') `
                -Value '{ "schemaVersion": 2, "phase": ' -Encoding UTF8

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 3
        }

        It "Leaves a committed journal in place" {
            $root = New-RecoveryRoot
            $destination = Join-Path $root 'lib/a.ps1'
            New-RecoveryFile -Path $destination -Content 'new-a'
            $backupRoot = Join-Path $root 'data/agent-update/backups/run-current'
            New-RecoveryFile -Path (Join-Path $backupRoot 'lib/a.ps1') -Content 'old-a'
            Write-RecoveryJournal -Root $root -Phase 'committed' -BackupRoot $backupRoot -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                    -PreviousSha256 (Get-TestContentHash -Content 'old-a') `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/recovery-report.json') | Should -BeFalse
        }

        It "Returns to the calling entry script instead of terminating its session" {
            $root = New-RecoveryRoot
            Write-RecoveryJournal -Root $root -Phase 'committed' -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $false `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )

            & $script:RecoveryScriptPath -OpenPathRoot $root
            $marker = Join-Path $TestDrive ('after-recovery-' + [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $marker -Value 'continued' -Encoding ASCII

            Test-Path -LiteralPath $marker | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeTrue
        }

        It "Rolls a partially replaced tree back to the previous version and removes new files" {
            $fixture = New-PartialRollbackFixture -Kind partial
            $root = $fixture.Root

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
            Test-Path -LiteralPath (Join-Path $root 'lib/b.ps1') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeFalse

            $reportPath = Join-Path $root 'data/agent-update/recovery-report.json'
            Test-Path -LiteralPath $reportPath | Should -BeTrue
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.status | Should -Be 'DEGRADED'
            $report.reasonCode | Should -Match 'self_update_recovery_rolled_back'
            $report.build | Should -Be 'build-new'
        }

        It "Ignores a stale backup from an earlier update run" {
            $fixture = New-PartialRollbackFixture -Kind stale-backup
            $root = $fixture.Root

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
        }

        It "Does not overwrite a file when the backup hash is not the pre-update hash" {
            $fixture = New-PartialRollbackFixture -Kind corrupt-backup
            $root = $fixture.Root

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeTrue
            $report = Get-Content -LiteralPath (Join-Path $root 'data/agent-update/recovery-report.json') -Raw | ConvertFrom-Json
            $report.reasonCode | Should -Match 'self_update_recovery_failed'
        }

        It "Leaves an untouched file alone when no backup exists" {
            $fixture = New-PartialRollbackFixture -Kind untouched
            $root = $fixture.Root

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeFalse
        }

        It "Rejects a backup root in a sibling directory whose name merely starts with backups" {
            $fixture = New-PartialRollbackFixture -Kind outside
            $root = $fixture.Root

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeTrue
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'outside the update backup directory'
        }

        It "Does nothing while a live updater holds the update lock" {
            $root = New-RecoveryRoot
            $destination = Join-Path $root 'lib/a.ps1'
            New-RecoveryFile -Path $destination -Content 'new-a'
            Write-RecoveryJournal -Root $root -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $false `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )

            $holderScript = @"
`$m = [System.Threading.Mutex]::new(`$false, 'Global\OpenPathAgentUpdateLock')
`$null = `$m.WaitOne()
[Console]::Out.WriteLine('held'); [Console]::Out.Flush()
`$null = [Console]::In.ReadLine()
`$m.ReleaseMutex()
"@
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:PwshPath)
            $psi.ArgumentList.Add('-NoProfile')
            $psi.ArgumentList.Add('-Command')
            $psi.ArgumentList.Add($holderScript)
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $holder = [System.Diagnostics.Process]::Start($psi)
            try {
                $holder.StandardOutput.ReadLine() | Should -Be 'held'

                $result = Invoke-RecoveryScript -Root $root

                $result.ExitCode | Should -Be 0
                (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'new-a'
                Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeTrue
            }
            finally {
                if (-not $holder.HasExited) {
                    $holder.StandardInput.WriteLine('release')
                    $null = $holder.WaitForExit(30000)
                }
                if (-not $holder.HasExited) { $holder.Kill() }
                $holder.Dispose()
            }
        }

        It "Sends a pending recovery report through the common health reporter" {
            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            [PSCustomObject]@{
                schemaVersion = 1
                status        = 'DEGRADED'
                reasonCode    = 'self_update_recovery_rolled_back_9_9_9_build_new'
                actions       = 'self_update_recovery_rolled_back'
                version       = '9.9.8'
                build         = 'build-new'
                recordedAt    = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $updateRoot 'recovery-report.json') -Encoding UTF8

            $modulePath = Join-Path $PSScriptRoot ".." "lib" "Common.psm1"
            Import-Module $modulePath -Force -Global
            InModuleScope Common -Parameters @{ Root = $root } {
                $script:OpenPathRoot = $Root
                $script:CapturedReport = $null
                Mock Send-OpenPathHealthReport {
                    param($Status, $DnsServiceRunning, $DnsResolving, $FailCount, $Actions, $Version, $ReasonCodes)
                    $script:CapturedReport = [PSCustomObject]@{
                        Status      = $Status
                        Actions     = $Actions
                        Version     = $Version
                        ReasonCodes = @($ReasonCodes)
                    }
                    return $true
                }

                $sent = Send-OpenPathAgentUpdateRecoveryReport -OpenPathRoot $Root

                $sent | Should -BeTrue
                $script:CapturedReport.Status | Should -Be 'DEGRADED'
                $script:CapturedReport.Actions | Should -Be 'self_update_recovery_rolled_back'
                (@($script:CapturedReport.ReasonCodes) -join ' ') | Should -Match 'self_update_recovery_rolled_back'
                Test-Path -LiteralPath (Join-Path $Root 'data/agent-update/recovery-report.json') | Should -BeFalse
            }
        }
    }

    Context "Rollback rule parity" {
        It "Applies the same restore rule in the standalone script and the updater (<Kind>)" -ForEach @(
            @{ Kind = 'partial' }
            @{ Kind = 'corrupt-backup' }
            @{ Kind = 'untouched' }
            @{ Kind = 'stale-backup' }
            @{ Kind = 'outside' }
        ) {
            $scriptFixture = New-PartialRollbackFixture -Kind $Kind
            $moduleFixture = New-PartialRollbackFixture -Kind $Kind

            $scriptResult = Invoke-RecoveryScript -Root $scriptFixture.Root

            $modulePath = Join-Path $PSScriptRoot ".." "lib" "Common.psm1"
            Import-Module $modulePath -Force -Global
            $moduleResult = InModuleScope Common -Parameters @{
                Root = $moduleFixture.Root
                JournalPath = (Join-Path $moduleFixture.Root 'data/agent-update/update-journal.json')
            } {
                $script:OpenPathRoot = $Root
                $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
                Restore-OpenPathAgentUpdateJournalBackups -OpenPathRoot $Root -Journal $journal
            }

            $scriptComplete = ($scriptResult.ExitCode -eq 0)
            [bool]$moduleResult.Complete | Should -Be $scriptComplete

            $scriptFile = Join-Path $scriptFixture.Root 'lib/a.ps1'
            $moduleFile = Join-Path $moduleFixture.Root 'lib/a.ps1'
            (Get-Content -LiteralPath $scriptFile -Raw).Trim() | Should -Be (Get-Content -LiteralPath $moduleFile -Raw).Trim()
            Test-Path -LiteralPath (Join-Path $scriptFixture.Root 'lib/b.ps1') | Should -Be (Test-Path -LiteralPath (Join-Path $moduleFixture.Root 'lib/b.ps1'))
        }
    }

    Context "Update health gate script" {
        It "Exits zero when the full module set loads and exposes the required commands" {
            $root = New-FakeAgentRoot

            $result = Invoke-GateScript -Root $root

            $result.ExitCode | Should -Be 0
        }

        It "Exits non-zero when a required module cannot be loaded" {
            $root = New-FakeAgentRoot
            Remove-Item -LiteralPath (Join-Path $root 'lib/Services.psm1') -Force

            $result = Invoke-GateScript -Root $root

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'health gate failed'
        }

        It "Runs the gate through a bounded child process and reports its exit code" {
            $root = New-RecoveryRoot
            $scripts = Join-Path $root 'scripts'
            New-Item -ItemType Directory -Path $scripts -Force | Out-Null
            $gatePath = Join-Path $scripts 'Test-OpenPathAgentUpdateHealth.ps1'
            Set-Content -LiteralPath $gatePath -Encoding ASCII -Value @'
param([string]$OpenPathRoot = '')
if (Test-Path -LiteralPath (Join-Path $OpenPathRoot 'gate-fail.flag')) {
    [Console]::Error.WriteLine('gate boom')
    exit 1
}
exit 0
'@

            $modulePath = Join-Path $PSScriptRoot ".." "lib" "Common.psm1"
            Import-Module $modulePath -Force -Global
            InModuleScope Common -Parameters @{ Root = $root; PwshPath = $script:PwshPath } {
                $healthy = Invoke-OpenPathAgentUpdateHealthGate -OpenPathRoot $Root -PowerShellPath $PwshPath -TimeoutSeconds 30
                $healthy.Healthy | Should -BeTrue

                Set-Content -LiteralPath (Join-Path $Root 'gate-fail.flag') -Value '1' -Encoding ASCII
                $failed = Invoke-OpenPathAgentUpdateHealthGate -OpenPathRoot $Root -PowerShellPath $PwshPath -TimeoutSeconds 30
                $failed.Healthy | Should -BeFalse
                $failed.ExitCode | Should -Be 1
                $failed.Message | Should -Match 'gate boom'
            }
        }

        It "Fails the gate when the child process exceeds the timeout" {
            $root = New-RecoveryRoot
            $scripts = Join-Path $root 'scripts'
            New-Item -ItemType Directory -Path $scripts -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $scripts 'Test-OpenPathAgentUpdateHealth.ps1') -Encoding ASCII -Value @'
param([string]$OpenPathRoot = '')
Start-Sleep -Seconds 20
exit 0
'@

            $modulePath = Join-Path $PSScriptRoot ".." "lib" "Common.psm1"
            Import-Module $modulePath -Force -Global
            InModuleScope Common -Parameters @{ Root = $root; PwshPath = $script:PwshPath } {
                $result = Invoke-OpenPathAgentUpdateHealthGate -OpenPathRoot $Root -PowerShellPath $PwshPath -TimeoutSeconds 2
                $result.Healthy | Should -BeFalse
                $result.TimedOut | Should -BeTrue
            }
        }
    }

    Context "Entry point recovery wiring" {
        It "Runs recovery before the first module import in every task entry script and the CLI" {
            $entryScripts = @(
                'scripts/Update-OpenPath.ps1',
                'scripts/Test-DNSHealth.ps1',
                'scripts/Start-SSEListener.ps1',
                'scripts/Apply-RuntimeDependencyQueue.ps1',
                'scripts/Start-RuntimeDependencyWorker.ps1',
                'scripts/Recover-CaptivePortal.ps1',
                'OpenPath.ps1'
            )

            foreach ($relativePath in $entryScripts) {
                $path = Join-Path $script:WindowsRoot $relativePath
                $content = Get-Content -LiteralPath $path -Raw
                $recoveryCall = $content.IndexOf('Recover-OpenPathAgentUpdate.ps1')
                $firstImport = $content.IndexOf('Import-Module')

                $recoveryCall | Should -BeGreaterThan -1 -Because "$relativePath must invoke the recovery script"
                $firstImport | Should -BeGreaterThan -1 -Because "$relativePath must still import its modules"
                $recoveryCall | Should -BeLessThan $firstImport -Because "$relativePath must recover a mixed tree before importing modules"
            }
        }

        It "Adds both new SYSTEM scripts to the integrity critical file list" {
            $content = Get-Content -LiteralPath (Join-Path $script:WindowsRoot 'lib/internal/Common.Integrity.ps1') -Raw

            $content | Should -Match 'scripts\\Recover-OpenPathAgentUpdate\.ps1'
            $content | Should -Match 'scripts\\Test-OpenPathAgentUpdateHealth\.ps1'
        }

        It "Skips watchdog integrity restore while an update journal exists" {
            $content = Get-Content -LiteralPath (Join-Path $script:WindowsRoot 'lib/internal/Watchdog.Runtime.ps1') -Raw
            $journalGuard = $content.IndexOf('Test-Path $updateJournalPath')
            $restoreCall = $content.IndexOf('Restore-OpenPathIntegrity -IntegrityResult')

            $content | Should -Match 'update-journal\.json'
            $journalGuard | Should -BeGreaterThan -1
            $restoreCall | Should -BeGreaterThan -1
            $journalGuard | Should -BeLessThan $restoreCall
        }
    }
}
