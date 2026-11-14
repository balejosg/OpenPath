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
                [string]$UpdatedAt = '',
                [string]$RunId = ''
            )

            $updateRoot = Join-Path $Root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
                $BackupRoot = Join-Path $updateRoot 'backups/run-test'
            }
            if (-not (Test-Path -LiteralPath $BackupRoot)) {
                New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
            }
            if ([string]::IsNullOrWhiteSpace($UpdatedAt)) {
                $UpdatedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }

            $journal = [PSCustomObject]@{
                schemaVersion   = $SchemaVersion
                phase           = $Phase
                runId           = $RunId
                durable         = $true
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

        function Write-RecoverySupersededJournal {
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [object[]]$Files = @(),
                [string]$Phase = 'committed',
                [int]$SchemaVersion = 2,
                [string]$BackupRoot = '',
                [string]$TargetVersion = '9.9.7',
                [string]$TargetBuild = 'build-stuck',
                [string]$UpdatedAt = '2026-11-13T10:00:00.0000000Z',
                [string]$RunId = 'run-stuck'
            )

            $updateRoot = Join-Path $Root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
                $BackupRoot = Join-Path $updateRoot 'backups/run-stuck'
            }

            [PSCustomObject]@{
                schemaVersion        = $SchemaVersion
                phase                = $Phase
                runId                = $RunId
                durable              = $true
                targetVersion        = $TargetVersion
                targetBuild          = $TargetBuild
                previousVersion      = '9.9.6'
                previousBuild        = 'build-older'
                backupRoot           = $BackupRoot
                createdAt            = '2026-11-13T09:00:00.0000000Z'
                updatedAt            = $UpdatedAt
                finalizationAttempts = 2
                files                = @($Files)
            } | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath (Join-Path $updateRoot 'superseded-update-journal.json') -Encoding UTF8
        }

        function Invoke-RecoveryScript {
            param([Parameter(Mandatory = $true)][string]$Root)

            $output = & $script:PwshPath -NoProfile -NonInteractive -File $script:RecoveryScriptPath -OpenPathRoot $Root 2>&1
            return [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output   = (@($output) -join [Environment]::NewLine)
            }
        }

        function Write-RecoveryIntent {
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [Parameter(Mandatory = $true)][object[]]$Files,
                [string]$RunId = 'run-intent',
                [string]$Phase = 'replacing',
                [string]$BackupRoot = '',
                [string]$CreatedAt = '2026-11-14T09:00:00.0000000Z',
                [string]$TargetVersion = '9.9.9',
                [string]$TargetBuild = 'build-new'
            )

            $updateRoot = Join-Path $Root 'data/agent-update'
            if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
                $BackupRoot = Join-Path $updateRoot "backups/$RunId"
            }
            New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

            $intent = [PSCustomObject]@{
                schemaVersion   = 2
                phase           = $Phase
                runId           = $RunId
                durable         = $true
                targetVersion   = $TargetVersion
                targetBuild     = $TargetBuild
                previousVersion = '9.9.8'
                previousBuild   = 'build-old'
                backupRoot      = $BackupRoot
                createdAt       = $CreatedAt
                updatedAt       = $CreatedAt
                files           = @($Files)
            }
            $intent | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath (Join-Path $BackupRoot 'journal-intent.json') -Encoding UTF8
            return $BackupRoot
        }

        function Write-RecoveryMarker {
            param(
                [Parameter(Mandatory = $true)][string]$BackupRoot,
                [Parameter(Mandatory = $true)][string]$RunId,
                [string]$TargetVersion = '9.9.9',
                [string]$TargetBuild = 'build-new'
            )

            [PSCustomObject]@{
                schemaVersion = 1
                runId         = $RunId
                targetVersion = $TargetVersion
                targetBuild   = $TargetBuild
                committedAt   = '2026-11-14T09:05:00.0000000Z'
            } | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath (Join-Path $BackupRoot 'committed.marker') -Encoding UTF8
        }

        function Write-ZeroFile {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [int]$Length = 47241
            )

            $directory = Split-Path $Path -Parent
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Length))
        }

        function New-IntentRollbackFixture {
            param(
                [ValidateSet('partial', 'untouched')][string]$Kind = 'partial',
                [switch]$ZeroIntent,
                [switch]$NoIntent
            )

            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            $backupRoot = Join-Path $updateRoot 'backups/run-intent'
            $oldHash = Get-TestContentHash -Content 'old-a'
            $newHash = Get-TestContentHash -Content 'new-a'
            $newBHash = Get-TestContentHash -Content 'new-b'

            New-RecoveryFile -Path (Join-Path $root 'lib/a.ps1') -Content 'old-a'
            if ($Kind -eq 'partial') {
                New-RecoveryFile -Path (Join-Path $root 'lib/a.ps1') -Content 'new-a'
                New-RecoveryFile -Path (Join-Path $root 'lib/b.ps1') -Content 'new-b'
            }
            New-RecoveryFile -Path (Join-Path $backupRoot 'lib/a.ps1') -Content 'old-a'

            $files = @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                    -PreviousSha256 $oldHash -TargetSha256 $newHash
            )
            if ($Kind -eq 'partial') {
                $files += New-RecoveryJournalEntry -RelativePath 'lib\b.ps1' -ExistedBefore $false `
                    -TargetSha256 $newBHash
            }

            if ($ZeroIntent) {
                Write-ZeroFile -Path (Join-Path $backupRoot 'journal-intent.json')
            }
            elseif (-not $NoIntent) {
                Write-RecoveryIntent -Root $root -Files $files -BackupRoot $backupRoot | Out-Null
            }

            return [PSCustomObject]@{
                Root       = $root
                BackupRoot = $backupRoot
                Files      = $files
                OldHash    = $oldHash
                NewHash    = $newHash
            }
        }

        function Write-RecoveryStateFile {
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [string]$State = 'blocked',
                [int]$Attempts = 1,
                [string]$LastAttemptAt = '',
                [string]$ReasonCode = 'self_update_recovery_journal_unreadable'
            )

            $updateRoot = Join-Path $Root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            if ([string]::IsNullOrWhiteSpace($LastAttemptAt)) {
                $LastAttemptAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }
            [PSCustomObject]@{
                schemaVersion  = 1
                state          = $State
                reasonCode     = $ReasonCode
                attempts       = $Attempts
                firstSeenAt    = $LastAttemptAt
                lastAttemptAt  = $LastAttemptAt
                repairAttempts = 0
                lastRepairAt   = ''
                runId          = 'run-intent'
            } | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath (Join-Path $updateRoot 'recovery-state.json') -Encoding UTF8
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

        It "Blocks a journal with an unknown schema and does no hashing on the next run" {
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
            $updateRoot = Join-Path $root 'data/agent-update'
            Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
            $reportPath = Join-Path $updateRoot 'recovery-report.json'
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.status | Should -Be 'DEGRADED'
            $report.reasonCode | Should -Be 'self_update_recovery_journal_schema_unsupported'
            $report.actions | Should -Be 'self_update_recovery_blocked'
            $state = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-state.json') -Raw | ConvertFrom-Json
            $state.state | Should -Be 'blocked'
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'Blocked interrupted update recovery'

            # A second invocation returns before it may hash or touch anything.
            Write-RecoveryJournal -Root $root -Phase 'replacing' -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $false `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )
            $second = Invoke-RecoveryScript -Root $root
            $second.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeTrue
            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'new-a'
        }

        It "Blocks an unreadable journal instead of resuming the integrity check" {
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
            $report.reasonCode | Should -Be 'self_update_recovery_journal_unreadable'
            $report.actions | Should -Be 'self_update_recovery_blocked'
            $state = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-state.json') -Raw | ConvertFrom-Json
            $state.state | Should -Be 'blocked'
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'Blocked interrupted update recovery'
        }

        It "Rolls back from the intent when the journal is <Shape>" -ForEach @(
            @{ Shape = 'zero-filled' }
            @{ Shape = 'cut' }
            @{ Shape = 'missing-fields' }
            @{ Shape = 'schema-1' }
        ) {
            $fixture = New-IntentRollbackFixture -Kind partial
            $root = $fixture.Root
            $updateRoot = Join-Path $root 'data/agent-update'
            $journalPath = Join-Path $updateRoot 'update-journal.json'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            switch ($Shape) {
                'zero-filled' { Write-ZeroFile -Path $journalPath }
                'cut' { Set-Content -LiteralPath $journalPath -Value '{ "schemaVersion": 2, "phase": ' -Encoding UTF8 }
                'missing-fields' { Set-Content -LiteralPath $journalPath -Value '{ "schemaVersion": 2, "phase": "replacing" }' -Encoding UTF8 }
                'schema-1' {
                    Write-RecoveryJournal -Root $root -SchemaVersion 1 -BackupRoot $fixture.BackupRoot -Files $fixture.Files
                }
            }

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
            Test-Path -LiteralPath (Join-Path $root 'lib/b.ps1') | Should -BeFalse
            Test-Path -LiteralPath $journalPath | Should -BeFalse
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $fixture.BackupRoot 'journal-intent.json') | Should -BeFalse
            Test-Path -LiteralPath $fixture.BackupRoot | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $updateRoot 'recovery-state.json') | Should -BeFalse
            $report = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-report.json') -Raw | ConvertFrom-Json
            $report.reasonCode | Should -Match 'self_update_recovery_rolled_back'
        }

        It "Promotes the intent to committed when the journal is unusable and a marker exists" {
            $fixture = New-IntentRollbackFixture -Kind partial
            $root = $fixture.Root
            $updateRoot = Join-Path $root 'data/agent-update'
            $journalPath = Join-Path $updateRoot 'update-journal.json'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            Write-ZeroFile -Path $journalPath
            Write-RecoveryMarker -BackupRoot $fixture.BackupRoot -RunId 'run-intent'

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
            (Get-Content -LiteralPath (Join-Path $root 'lib/b.ps1') -Raw).Trim() | Should -Be 'new-b'
            $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $journal.phase | Should -Be 'committed'
            $journal.runId | Should -Be 'run-intent'
            $journal.targetBuild | Should -Be 'build-new'
            Test-Path -LiteralPath (Join-Path $fixture.BackupRoot 'committed.marker') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $updateRoot 'recovery-report.json') | Should -BeFalse
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'Promoted the run intent to a committed journal'
        }

        It "Promotes a validating journal to committed from the marker" {
            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            $destination = Join-Path $root 'lib/a.ps1'
            New-RecoveryFile -Path $destination -Content 'new-a'
            Write-RecoveryJournal -Root $root -Phase 'validating' -RunId 'run-validating' -BackupRoot (Join-Path $updateRoot 'backups/run-validating') -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $false `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )
            Write-RecoveryMarker -BackupRoot (Join-Path $updateRoot 'backups/run-validating') -RunId 'run-validating'

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            $journal = Get-Content -LiteralPath (Join-Path $updateRoot 'update-journal.json') -Raw | ConvertFrom-Json
            $journal.phase | Should -Be 'committed'
            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $updateRoot 'recovery-report.json') | Should -BeFalse
        }

        It "Removes an orphan run without a report when the journal is missing and the tree is untouched" {
            $fixture = New-IntentRollbackFixture -Kind untouched
            $root = $fixture.Root
            $updateRoot = Join-Path $root 'data/agent-update'

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
            Test-Path -LiteralPath $fixture.BackupRoot | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $updateRoot 'recovery-report.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $updateRoot 'recovery-state.json') | Should -BeFalse
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'orphan run'
        }

        It "Blocks when the intent is <Case>" -ForEach @(
            @{ Case = 'zero-filled' }
            @{ Case = 'absent' }
        ) {
            $fixture = if ($Case -eq 'zero-filled') {
                New-IntentRollbackFixture -Kind partial -ZeroIntent
            }
            else {
                New-IntentRollbackFixture -Kind partial -NoIntent
            }
            $root = $fixture.Root
            $updateRoot = Join-Path $root 'data/agent-update'
            $journalPath = Join-Path $updateRoot 'update-journal.json'
            Write-ZeroFile -Path $journalPath

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'lib/b.ps1') | Should -BeTrue
            $state = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-state.json') -Raw | ConvertFrom-Json
            $state.state | Should -Be 'blocked'
            $state.reasonCode | Should -Be 'self_update_recovery_journal_unreadable'
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
            $report = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-report.json') -Raw | ConvertFrom-Json
            $report.actions | Should -Be 'self_update_recovery_blocked'
        }

        It "Chooses the newer intent that does not belong to the superseded journal" {
            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            $oldHash = Get-TestContentHash -Content 'old-a'
            $newHash = Get-TestContentHash -Content 'new-a'
            $files = @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                    -PreviousSha256 $oldHash -TargetSha256 $newHash
            )
            New-RecoveryFile -Path (Join-Path $root 'lib/a.ps1') -Content 'new-a'
            New-RecoveryFile -Path (Join-Path $updateRoot 'backups/run-old/lib/a.ps1') -Content 'old-a'
            New-RecoveryFile -Path (Join-Path $updateRoot 'backups/run-new/lib/a.ps1') -Content 'old-a'
            Write-RecoveryIntent -Root $root -Files $files -RunId 'run-old' -CreatedAt '2026-11-14T10:00:00.0000000Z' | Out-Null
            Write-RecoveryIntent -Root $root -Files $files -RunId 'run-new' -CreatedAt '2026-11-14T09:00:00.0000000Z' | Out-Null
            Write-RecoverySupersededJournal -Root $root -RunId 'run-old' -Files $files | Out-Null
            Write-ZeroFile -Path (Join-Path $updateRoot 'update-journal.json')

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
            Test-Path -LiteralPath (Join-Path $updateRoot 'backups/run-new') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $updateRoot 'backups/run-old') | Should -BeTrue
            $journal = Get-Content -LiteralPath (Join-Path $updateRoot 'update-journal.json') -Raw | ConvertFrom-Json
            $journal.phase | Should -Be 'committed'
            $journal.runId | Should -Be 'run-old'
            $journal.targetBuild | Should -Be 'build-stuck'
        }

        It "Keeps a 069bc89c schema-2 journal behaving as today (<Phase>)" -ForEach @(
            @{ Phase = 'replacing' }
            @{ Phase = 'validating' }
            @{ Phase = 'committed' }
        ) {
            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            $backupRoot = Join-Path $updateRoot 'backups/run-legacy'
            $oldHash = Get-TestContentHash -Content 'old-a'
            $newHash = Get-TestContentHash -Content 'new-a'
            New-RecoveryFile -Path (Join-Path $root 'lib/a.ps1') -Content 'new-a'
            New-RecoveryFile -Path (Join-Path $backupRoot 'lib/a.ps1') -Content 'old-a'
            Write-RecoveryJournal -Root $root -Phase $Phase -BackupRoot $backupRoot -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                    -PreviousSha256 $oldHash -TargetSha256 $newHash
            )

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            if ($Phase -eq 'committed') {
                (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
                Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeTrue
            }
            else {
                (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
                Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeFalse
                $report = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-report.json') -Raw | ConvertFrom-Json
                $report.reasonCode | Should -Match 'self_update_recovery_rolled_back'
            }
        }

        It "Leaves a zero-filled backup alone and keeps the journal for the next attempt" {
            $fixture = New-PartialRollbackFixture -Kind corrupt-backup
            $root = $fixture.Root
            Write-ZeroFile -Path (Join-Path $fixture.BackupRoot 'lib/a.ps1') -Length 279

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeTrue
            $state = Get-Content -LiteralPath (Join-Path $root 'data/agent-update/recovery-state.json') -Raw | ConvertFrom-Json
            $state.attempts | Should -Be 1
            $state.state | Should -Be 'retrying'
        }

        It "Stops after three incomplete rollbacks and returns without hashing while blocked" {
            $fixture = New-PartialRollbackFixture -Kind corrupt-backup
            $root = $fixture.Root
            $updateRoot = Join-Path $root 'data/agent-update'
            $statePath = Join-Path $updateRoot 'recovery-state.json'

            $first = Invoke-RecoveryScript -Root $root
            $first.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).attempts | Should -Be 1

            $rewind = {
                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $state.lastAttemptAt = [DateTime]::UtcNow.AddMinutes(-11).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
            }
            & $rewind
            $second = Invoke-RecoveryScript -Root $root
            $second.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).attempts | Should -Be 2

            & $rewind
            $third = Invoke-RecoveryScript -Root $root
            $third.ExitCode | Should -Not -Be 0
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $state.attempts | Should -Be 3
            $state.state | Should -Be 'blocked'
            $report = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-report.json') -Raw | ConvertFrom-Json
            $report.reasonCode | Should -Be 'self_update_recovery_blocked'

            Write-RecoveryJournal -Root $root -RunId 'run-after-block' -Phase 'replacing' -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib/a.ps1' -ExistedBefore $true `
                    -PreviousSha256 (Get-TestContentHash -Content 'old-a') `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )
            $fourth = Invoke-RecoveryScript -Root $root
            $fourth.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
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

        It "Moves a superseded journal into place when no journal exists" {
            $root = New-RecoveryRoot
            Write-RecoverySupersededJournal -Root $root
            $supersededPath = Join-Path $root 'data/agent-update/superseded-update-journal.json'
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            $supersededBytes = [System.IO.File]::ReadAllBytes($supersededPath)

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath $journalPath | Should -BeTrue
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be ([Convert]::ToBase64String($supersededBytes))
            Test-Path -LiteralPath $supersededPath | Should -BeFalse
            $journalOnDisk = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $journalOnDisk.phase | Should -Be 'committed'
            $journalOnDisk.finalizationAttempts | Should -Be 2
            (Get-Content -LiteralPath $journalPath -Raw) | Should -Match '2026-11-13T10:00:00\.0000000Z'
        }

        It "Puts the superseded journal in place after a complete rollback" {
            $fixture = New-PartialRollbackFixture -Kind partial
            $root = $fixture.Root
            Write-RecoverySupersededJournal -Root $root
            $supersededPath = Join-Path $root 'data/agent-update/superseded-update-journal.json'
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            $supersededBytes = [System.IO.File]::ReadAllBytes($supersededPath)

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
            Test-Path -LiteralPath (Join-Path $root 'lib/b.ps1') | Should -BeFalse
            Test-Path -LiteralPath $journalPath | Should -BeTrue
            Test-Path -LiteralPath $supersededPath | Should -BeFalse
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be ([Convert]::ToBase64String($supersededBytes))

            $reportPath = Join-Path $root 'data/agent-update/recovery-report.json'
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.reasonCode | Should -Match 'self_update_recovery_rolled_back'
            $report.build | Should -Be 'build-new'
        }

        It "Keeps both journals when the replacement rollback is incomplete" {
            $fixture = New-PartialRollbackFixture -Kind corrupt-backup
            $root = $fixture.Root
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            $journalBytes = [System.IO.File]::ReadAllBytes($journalPath)
            Write-RecoverySupersededJournal -Root $root
            $supersededPath = Join-Path $root 'data/agent-update/superseded-update-journal.json'
            $supersededBytes = [System.IO.File]::ReadAllBytes($supersededPath)

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Not -Be 0
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be ([Convert]::ToBase64String($journalBytes))
            Test-Path -LiteralPath $supersededPath | Should -BeTrue
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($supersededPath)) |
                Should -Be ([Convert]::ToBase64String($supersededBytes))
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
        }

        It "Quarantines an unusable superseded journal (<Kind>)" -ForEach @(
            @{ Kind = 'unreadable' }
            @{ Kind = 'schema1' }
        ) {
            $root = New-RecoveryRoot
            $updateRoot = Join-Path $root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            $supersededPath = Join-Path $updateRoot 'superseded-update-journal.json'
            if ($Kind -eq 'unreadable') {
                Set-Content -LiteralPath $supersededPath -Value '{ "schemaVersion": 2, "phase": ' -Encoding UTF8
            }
            else {
                Write-RecoverySupersededJournal -Root $root -SchemaVersion 1
            }

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeFalse
            Test-Path -LiteralPath $supersededPath | Should -BeFalse
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
            $report = Get-Content -LiteralPath (Join-Path $updateRoot 'recovery-report.json') -Raw | ConvertFrom-Json
            $report.reasonCode | Should -Match '^self_update_recovery_journal_'
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'quarantin'
        }

        It "Quarantines an unusable superseded journal and removes the rolled-back journal" {
            $fixture = New-PartialRollbackFixture -Kind partial
            $root = $fixture.Root
            $updateRoot = Join-Path $root 'data/agent-update'
            $supersededPath = Join-Path $updateRoot 'superseded-update-journal.json'
            Set-Content -LiteralPath $supersededPath -Value '{ "schemaVersion": 2, "phase": ' -Encoding UTF8

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'old-a'
            Test-Path -LiteralPath (Join-Path $root 'lib/b.ps1') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $updateRoot 'update-journal.json') | Should -BeFalse
            Test-Path -LiteralPath $supersededPath | Should -BeFalse
            @(Get-ChildItem -LiteralPath $updateRoot -Filter 'update-journal.quarantine-*.json' -File).Count | Should -Be 1
        }

        It "Leaves a committed journal and its superseded sibling for the updater" {
            $root = New-RecoveryRoot
            $destination = Join-Path $root 'lib/a.ps1'
            New-RecoveryFile -Path $destination -Content 'new-a'
            $backupRoot = Join-Path $root 'data/agent-update/backups/run-current'
            Write-RecoveryJournal -Root $root -Phase 'committed' -BackupRoot $backupRoot -Files @(
                New-RecoveryJournalEntry -RelativePath 'lib\a.ps1' -ExistedBefore $true `
                    -PreviousSha256 (Get-TestContentHash -Content 'old-a') `
                    -TargetSha256 (Get-TestContentHash -Content 'new-a')
            )
            $journalPath = Join-Path $root 'data/agent-update/update-journal.json'
            $journalBytes = [System.IO.File]::ReadAllBytes($journalPath)
            Write-RecoverySupersededJournal -Root $root
            $supersededPath = Join-Path $root 'data/agent-update/superseded-update-journal.json'
            $supersededBytes = [System.IO.File]::ReadAllBytes($supersededPath)

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) |
                Should -Be ([Convert]::ToBase64String($journalBytes))
            Test-Path -LiteralPath $supersededPath | Should -BeTrue
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($supersededPath)) |
                Should -Be ([Convert]::ToBase64String($supersededBytes))
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

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeFalse
            $state = Get-Content -LiteralPath (Join-Path $root 'data/agent-update/recovery-state.json') -Raw | ConvertFrom-Json
            $state.state | Should -Be 'blocked'
            $report = Get-Content -LiteralPath (Join-Path $root 'data/agent-update/recovery-report.json') -Raw | ConvertFrom-Json
            $report.actions | Should -Be 'self_update_recovery_blocked'
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

            $scriptComplete = (
                $scriptResult.ExitCode -eq 0 -and
                -not (Test-Path -LiteralPath (Join-Path $scriptFixture.Root 'data/agent-update/update-journal.json')) -and
                -not (Test-Path -LiteralPath (Join-Path $scriptFixture.Root 'data/agent-update/recovery-state.json'))
            )
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
