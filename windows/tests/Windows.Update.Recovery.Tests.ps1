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

        function Write-RecoveryJournal {
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [Parameter(Mandatory = $true)][object[]]$Files,
                [string]$Phase = 'replacing',
                [int]$SchemaVersion = 1,
                [string]$BackupRoot = ''
            )

            $updateRoot = Join-Path $Root 'data/agent-update'
            New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
            if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
                $BackupRoot = Join-Path $updateRoot 'backups/9.9.8'
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
                updatedAt       = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
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

        It "Ignores and logs an unknown journal schema without touching files" {
            $root = New-RecoveryRoot
            $destination = Join-Path $root 'lib/a.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-a' -Encoding ASCII
            Write-RecoveryJournal -Root $root -SchemaVersion 99 -Files @(
                [PSCustomObject]@{ relativePath = 'lib\a.ps1'; existedBefore = $false; sha256 = ('a' * 64) }
            )

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeTrue
            $log = Get-Content -LiteralPath (Join-Path $root 'data/logs/openpath.log') -Raw
            $log | Should -Match 'schema'
        }

        It "Only removes the journal when its phase is committed" {
            $root = New-RecoveryRoot
            $destination = Join-Path $root 'lib/a.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-a' -Encoding ASCII
            $backupRoot = Join-Path $root 'data/agent-update/backups/9.9.8'
            New-Item -ItemType Directory -Path (Join-Path $backupRoot 'lib') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $backupRoot 'lib/a.ps1') -Value 'old-a' -Encoding ASCII
            Write-RecoveryJournal -Root $root -Phase 'committed' -BackupRoot $backupRoot -Files @(
                [PSCustomObject]@{ relativePath = 'lib\a.ps1'; existedBefore = $true; sha256 = ('a' * 64) }
            )

            $result = Invoke-RecoveryScript -Root $root

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $destination -Raw).Trim() | Should -Be 'new-a'
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/recovery-report.json') | Should -BeFalse
        }

        It "Returns to the calling entry script instead of terminating its session" {
            $root = New-RecoveryRoot
            Write-RecoveryJournal -Root $root -Phase 'committed' -Files @(
                [PSCustomObject]@{ relativePath = 'lib\a.ps1'; existedBefore = $false; sha256 = ('a' * 64) }
            )

            & $script:RecoveryScriptPath -OpenPathRoot $root
            $marker = Join-Path $TestDrive ('after-recovery-' + [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $marker -Value 'continued' -Encoding ASCII

            Test-Path -LiteralPath $marker | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'data/agent-update/update-journal.json') | Should -BeFalse
        }

        It "Rolls a partially replaced tree back to the previous version and removes new files" {
            $root = New-RecoveryRoot
            $backupRoot = Join-Path $root 'data/agent-update/backups/9.9.8'
            New-Item -ItemType Directory -Path (Join-Path $backupRoot 'lib') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $backupRoot 'lib/a.ps1') -Value 'old-a' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $root 'lib/a.ps1') -Value 'new-a' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $root 'lib/b.ps1') -Value 'new-b' -Encoding ASCII
            Write-RecoveryJournal -Root $root -BackupRoot $backupRoot -Files @(
                [PSCustomObject]@{ relativePath = 'lib\a.ps1'; existedBefore = $true; sha256 = ('a' * 64) },
                [PSCustomObject]@{ relativePath = 'lib\b.ps1'; existedBefore = $false; sha256 = ('b' * 64) }
            )

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

        It "Does nothing while a live updater holds the update lock" {
            $root = New-RecoveryRoot
            $destination = Join-Path $root 'lib/a.ps1'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'new-a' -Encoding ASCII
            Write-RecoveryJournal -Root $root -Files @(
                [PSCustomObject]@{ relativePath = 'lib\a.ps1'; existedBefore = $false; sha256 = ('a' * 64) }
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
