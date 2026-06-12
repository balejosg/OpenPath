# OpenPath Windows - SSE Coalescer Pester Tests
#
# Covers Sse.Coalescer.ps1 debounce semantics and config normalisation.
# All time is injected via the NowTime parameter — no Start-Sleep needed.
# Deferred dispatch is injected via DeferAction — no inner-function override needed.
#
# Counters use hashtables (@{ value = 0 }) so that scriptblock closures mutate
# the same object reference across PowerShell scope boundaries.

Describe "Sse.Coalescer" {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

        $coalescerPath = Join-Path $PSScriptRoot ".." "lib" "internal" "Sse.Coalescer.ps1"
        . $coalescerPath

        # Suppress Write-OpenPathLog if it isn't loaded in this scope.
        if (-not (Get-Command -Name 'Write-OpenPathLog' -ErrorAction SilentlyContinue)) {
            function global:Write-OpenPathLog { param([string]$Message, [string]$Level) }
        }

        # Fixed reference epoch used by all time-injection tests.
        $script:T0 = [datetime]::new(2025, 1, 1, 12, 0, 0, [System.DateTimeKind]::Utc)
    }

    # -------------------------------------------------------------------------
    Context "Get-SseCoalescerDefaultCooldown" {
        It "Returns 10 to match Linux SSE_UPDATE_COOLDOWN default" {
            Get-SseCoalescerDefaultCooldown | Should -Be 10
        }
    }

    # -------------------------------------------------------------------------
    Context "New-SseCoalescerState" {
        It "Creates state with MinValue sentinels" {
            $state = New-SseCoalescerState
            $state.LastUpdateTime     | Should -Be ([datetime]::MinValue)
            $state.PendingUpdateDueAt | Should -Be ([datetime]::MinValue)
        }
    }

    # -------------------------------------------------------------------------
    Context "Get-SseUpdateCooldownFromConfig" {
        It "Returns default 10 when config is null" {
            Get-SseUpdateCooldownFromConfig -Config $null | Should -Be 10
        }

        It "Returns default 10 when sseUpdateCooldown key is absent" {
            $config = [PSCustomObject]@{ whitelistUrl = "https://example.com" }
            Get-SseUpdateCooldownFromConfig -Config $config | Should -Be 10
        }

        It "Returns the configured value when valid" {
            $config = [PSCustomObject]@{ sseUpdateCooldown = 30 }
            Get-SseUpdateCooldownFromConfig -Config $config | Should -Be 30
        }

        It "Returns default 10 when sseUpdateCooldown is zero" {
            $config = [PSCustomObject]@{ sseUpdateCooldown = 0 }
            Get-SseUpdateCooldownFromConfig -Config $config | Should -Be 10
        }

        It "Returns default 10 when sseUpdateCooldown is negative" {
            $config = [PSCustomObject]@{ sseUpdateCooldown = -5 }
            Get-SseUpdateCooldownFromConfig -Config $config | Should -Be 10
        }

        It "Returns default 10 when sseUpdateCooldown is non-numeric" {
            $config = [PSCustomObject]@{ sseUpdateCooldown = "fast" }
            Get-SseUpdateCooldownFromConfig -Config $config | Should -Be 10
        }

        It "Accepts string representation of a valid integer" {
            $config = [PSCustomObject]@{ sseUpdateCooldown = "15" }
            Get-SseUpdateCooldownFromConfig -Config $config | Should -Be 15
        }
    }

    # -------------------------------------------------------------------------
    Context "Invoke-SseCoalescerUpdate - immediate trigger (cooldown expired)" {
        It "Single event with no prior update triggers the update action once" {
            $c = @{ immediate = 0 }
            $action     = { $c.immediate++ }
            $deferAction = { param($DelaySeconds, $UpdateAction) }
            $state = New-SseCoalescerState

            $state = Invoke-SseCoalescerUpdate `
                -State $state -UpdateAction $action -CooldownSeconds 10 `
                -NowTime $script:T0 -DeferAction $deferAction

            $c.immediate | Should -Be 1
            $state.LastUpdateTime     | Should -Be $script:T0
            $state.PendingUpdateDueAt | Should -Be ([datetime]::MinValue)
        }

        It "An event after the cooldown window also triggers immediately" {
            $c = @{ immediate = 0 }
            $action     = { $c.immediate++ }
            $deferAction = { param($DelaySeconds, $UpdateAction) }
            $state = New-SseCoalescerState

            # Event 1 at T0: immediate.
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction $action -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction
            # Event 2 at T0+11s (past cooldown): immediate again.
            $t1 = $script:T0.AddSeconds(11)
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction $action -CooldownSeconds 10 -NowTime $t1 -DeferAction $deferAction

            $c.immediate | Should -Be 2
            $state.LastUpdateTime | Should -Be $t1
        }

        It "Exactly at the cooldown boundary (elapsed == cooldown) triggers immediately" {
            $c = @{ immediate = 0 }
            $action     = { $c.immediate++ }
            $deferAction = { param($DelaySeconds, $UpdateAction) }
            $state = New-SseCoalescerState

            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction $action -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction $action -CooldownSeconds 10 -NowTime $script:T0.AddSeconds(10) -DeferAction $deferAction

            $c.immediate | Should -Be 2
        }
    }

    # -------------------------------------------------------------------------
    Context "Invoke-SseCoalescerUpdate - burst coalescing (within cooldown window)" {
        It "N events within the window produce exactly 1 immediate trigger" {
            $c = @{ immediate = 0; deferred = 0 }
            $action     = { $c.immediate++ }
            $deferAction = { param($DelaySeconds, $UpdateAction) $c.deferred++ }
            $state = New-SseCoalescerState

            # Event 1 at T0: elapsed from MinValue >> 10 -> immediate.
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction $action -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction
            # Events 2-5 within window.
            foreach ($offsetSeconds in @(1, 2, 5, 9)) {
                $t = $script:T0.AddSeconds($offsetSeconds)
                $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction $action -CooldownSeconds 10 -NowTime $t -DeferAction $deferAction
            }

            # Exactly 1 immediate trigger (event 1).
            $c.immediate | Should -Be 1
            # Exactly 1 deferred scheduling (event 2 schedules; events 3-5 see pending marker).
            $c.deferred  | Should -Be 1
        }

        It "Events 3..N within the window do NOT re-schedule deferred update" {
            $c = @{ deferred = 0 }
            $deferAction = { param($DelaySeconds, $UpdateAction) $c.deferred++ }
            $state = New-SseCoalescerState

            # Event 1: immediate.
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction
            # Events 2, 3, 4 within window.
            foreach ($s in @(2, 4, 8)) {
                $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0.AddSeconds($s) -DeferAction $deferAction
            }

            # Only 1 deferred schedule, not 3.
            $c.deferred | Should -Be 1
        }

        It "Second burst after deferred fires produces a new deferred schedule" {
            $c = @{ deferred = 0 }
            $deferAction = { param($DelaySeconds, $UpdateAction) $c.deferred++ }
            $state = New-SseCoalescerState

            # Burst 1: event 1 (immediate) + event 2 (deferred).
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0.AddSeconds(2) -DeferAction $deferAction
            $c.deferred | Should -Be 1

            # Simulate deferred job having fired: advance LastUpdateTime, clear pending.
            $state.LastUpdateTime     = $script:T0.AddSeconds(10)
            $state.PendingUpdateDueAt = [datetime]::MinValue

            # Burst 2 event at T0+12 (elapsed=2 < cooldown) -> defers again.
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0.AddSeconds(12) -DeferAction $deferAction
            $c.deferred | Should -Be 2
        }
    }

    # -------------------------------------------------------------------------
    Context "Invoke-SseCoalescerUpdate - state consistency" {
        It "LastUpdateTime is updated to NowTime on immediate trigger" {
            $state = New-SseCoalescerState
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0 -DeferAction { param($d, $a) }
            $state.LastUpdateTime | Should -Be $script:T0
        }

        It "PendingUpdateDueAt is cleared on immediate trigger" {
            $state = New-SseCoalescerState
            $state.PendingUpdateDueAt = $script:T0.AddSeconds(5)  # stale marker

            $tLater = $script:T0.AddSeconds(20)
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $tLater -DeferAction { param($d, $a) }
            $state.PendingUpdateDueAt | Should -Be ([datetime]::MinValue)
        }

        It "LastUpdateTime is NOT updated when deferring" {
            $deferAction = { param($DelaySeconds, $UpdateAction) }
            $state = New-SseCoalescerState

            # Immediate at T0 sets LastUpdateTime = T0.
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction
            $state.LastUpdateTime | Should -Be $script:T0

            # Deferred call at T0+5 must NOT advance LastUpdateTime.
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0.AddSeconds(5) -DeferAction $deferAction
            $state.LastUpdateTime | Should -Be $script:T0
        }

        It "PendingUpdateDueAt is set to now + remaining when deferring" {
            $captured = @{ DelaySeconds = 0 }
            $deferAction = { param($DelaySeconds, $UpdateAction) $captured.DelaySeconds = $DelaySeconds }
            $state = New-SseCoalescerState

            # Immediate at T0.
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction
            # At T0+3, within window. Remaining = ceil(10-3) = 7.
            $t3 = $script:T0.AddSeconds(3)
            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction { } -CooldownSeconds 10 -NowTime $t3 -DeferAction $deferAction

            $captured.DelaySeconds    | Should -Be 7
            $state.PendingUpdateDueAt | Should -Be $t3.AddSeconds(7)
        }
    }

    # -------------------------------------------------------------------------
    Context "Single-event behaviour" {
        It "One event fires exactly one update and no deferred scheduling" {
            $c = @{ immediate = 0; deferred = 0 }
            $action      = { $c.immediate++ }
            $deferAction = { param($DelaySeconds, $UpdateAction) $c.deferred++ }
            $state = New-SseCoalescerState

            $state = Invoke-SseCoalescerUpdate -State $state -UpdateAction $action -CooldownSeconds 10 -NowTime $script:T0 -DeferAction $deferAction

            $c.immediate | Should -Be 1
            $c.deferred  | Should -Be 0
        }
    }

    # -------------------------------------------------------------------------
    Context "SSE Coalescer - listener wiring contract" {
        It "Start-SSEListener.ps1 dot-sources Sse.Coalescer.ps1" {
            $listenerPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $listenerPath -Raw
            $content | Should -Match "Sse\.Coalescer\.ps1"
        }

        It "Start-SSEListener.ps1 uses New-SseCoalescerState to initialise state" {
            $listenerPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $listenerPath -Raw
            $content | Should -Match "New-SseCoalescerState"
        }

        It "Start-SSEListener.ps1 delegates to Invoke-SseCoalescerUpdate" {
            $listenerPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $listenerPath -Raw
            $content | Should -Match "Invoke-SseCoalescerUpdate"
        }

        It "Start-SSEListener.ps1 uses Get-SseUpdateCooldownFromConfig for cooldown" {
            $listenerPath = Join-Path $PSScriptRoot ".." "scripts" "Start-SSEListener.ps1"
            $content = Get-Content $listenerPath -Raw
            $content | Should -Match "Get-SseUpdateCooldownFromConfig"
        }
    }

    # -------------------------------------------------------------------------
    Context "OpenPathConfig.Model.ps1 - sseUpdateCooldown normalisation" {
        BeforeAll {
            . (Join-Path $PSScriptRoot ".." "lib" "internal" "OpenPathConfig.Model.ps1")
        }

        It "Defaults sseUpdateCooldown to 10 when absent" {
            $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                apiUrl       = "https://example.com"
                whitelistUrl = "https://example.com/w/tok/whitelist.txt"
                classroom    = "cls-1"
            })
            $config.sseUpdateCooldown | Should -Be 10
        }

        It "Preserves a valid sseUpdateCooldown value from config" {
            $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                apiUrl            = "https://example.com"
                whitelistUrl      = "https://example.com/w/tok/whitelist.txt"
                classroom         = "cls-1"
                sseUpdateCooldown = 30
            })
            $config.sseUpdateCooldown | Should -Be 30
        }

        It "Resets invalid (zero) sseUpdateCooldown to default 10" {
            $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                apiUrl            = "https://example.com"
                whitelistUrl      = "https://example.com/w/tok/whitelist.txt"
                classroom         = "cls-1"
                sseUpdateCooldown = 0
            })
            $config.sseUpdateCooldown | Should -Be 10
        }

        It "Resets negative sseUpdateCooldown to default 10" {
            $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                apiUrl            = "https://example.com"
                whitelistUrl      = "https://example.com/w/tok/whitelist.txt"
                classroom         = "cls-1"
                sseUpdateCooldown = -1
            })
            $config.sseUpdateCooldown | Should -Be 10
        }

        It "Resets non-numeric sseUpdateCooldown to default 10" {
            $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                apiUrl            = "https://example.com"
                whitelistUrl      = "https://example.com/w/tok/whitelist.txt"
                classroom         = "cls-1"
                sseUpdateCooldown = "fast"
            })
            $config.sseUpdateCooldown | Should -Be 10
        }
    }
}
