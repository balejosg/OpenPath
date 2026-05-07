# OpenPath Windows browser enforcement decision tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$script:modulePath = Join-Path $PSScriptRoot ".." "lib"

function global:New-EnforcementDecisionInventory {
    param(
        [string[]]$ApprovedBrowsers = @("Mozilla Firefox", "Microsoft Edge", "Google Chrome"),
        [object[]]$UnmanagedBrowsers = @(),
        [object[]]$PortableBrowserRisks = @()
    )

    return [PSCustomObject]@{
        ApprovedBrowsers = @($ApprovedBrowsers | ForEach-Object { [PSCustomObject]@{ Name = $_ } })
        UnmanagedBrowsers = @($UnmanagedBrowsers)
        PortableBrowserRisks = @($PortableBrowserRisks)
    }
}

function global:New-ChromiumDecisionFacts {
    param(
        [bool]$Installed = $true,
        [bool]$Approved = $true,
        [bool]$ManagedExtensionReady = $true,
        [bool]$DohModeReady = $true,
        [bool]$UrlBlocklistReady = $true
    )

    return [PSCustomObject]@{
        Installed = $Installed
        Approved = $Approved
        ManagedExtensionReady = $ManagedExtensionReady
        DohModeReady = $DohModeReady
        UrlBlocklistReady = $UrlBlocklistReady
    }
}

Describe "Browser Module - Enforcement decisions" {
    BeforeAll {
        $script:modulePath = Join-Path $PSScriptRoot ".." "lib"
        $script:decisionModulePath = Join-Path $script:modulePath "Browser.EnforcementDecision.psm1"
        Import-Module $script:decisionModulePath -Force -Global -ErrorAction Stop
    }

    It "Exports pure browser enforcement decision helpers" {
        $module = Get-Module Browser.EnforcementDecision

        $module.ExportedFunctions.Keys | Should -Contain "Get-OpenPathBrowserRequestReadinessDecision"
        $module.ExportedFunctions.Keys | Should -Contain "Get-OpenPathBrowserInventoryDecision"
        $module.ExportedFunctions.Keys | Should -Contain "Get-OpenPathBrowserEnforcementOverallDecision"
    }

    It "Keeps probes out of the pure decision module" {
        $content = Get-Content $script:decisionModulePath -Raw

        $content | Should -Not -Match "Get-ItemProperty|Get-ChildItem|Test-Path|reg\.exe|Get-FirewallStatus|Test-OpenPathNonAdminAppControlActive|Get-OpenPathBrowserInventory\b|Get-OpenPathFirefox|Get-OpenPathChromium\b"
    }

    It "Builds readiness decisions from supplied browser enforcement facts" {
        $result = Get-OpenPathBrowserRequestReadinessDecision -Facts ([PSCustomObject]@{
                StrictMode = $true
                RequestSetupReady = $true
                FirefoxManagedExtensionReady = $true
                FirefoxMachinePolicyApplied = $true
                FirefoxNativeHostReady = $true
                AppControlActive = $true
                BrowserInventory = New-EnforcementDecisionInventory
                Chromium = [PSCustomObject]@{
                    Edge = New-ChromiumDecisionFacts -ManagedExtensionReady $false -DohModeReady $false -UrlBlocklistReady $false
                    Chrome = New-ChromiumDecisionFacts -Installed $false -Approved $false -ManagedExtensionReady $false -DohModeReady $false -UrlBlocklistReady $false
                }
            })

        $result.Platform | Should -Be "windows"
        $result.Ready | Should -BeFalse
        $result.Facts.edge_approval | Should -Be "approved"
        $result.Facts.edge_managed_extension | Should -Be "missing"
        $result.Facts.edge_doh_mode | Should -Be "missing"
        $result.Facts.edge_url_blocklist | Should -Be "missing"
        $result.Facts.chrome_managed_extension | Should -Be "not_installed"
        @($result.FailureReasons) | Should -Contain "edge_managed_extension_missing"
        @($result.FailureReasons) | Should -Contain "edge_doh_mode_missing"
        @($result.FailureReasons) | Should -Contain "edge_url_blocklist_missing"
    }

    It "Treats unmanaged inventory as the inventory readiness decision" {
        $decision = Get-OpenPathBrowserInventoryDecision `
            -UnmanagedBrowsers @([PSCustomObject]@{ Name = "Brave" }) `
            -PortableBrowserRisks @()

        $decision.Ready | Should -BeFalse
        $decision.ExitCode | Should -Be 1
    }

    It "Maps enforcement signals to overall operator status" {
        Get-OpenPathBrowserEnforcementOverallDecision `
            -AppLocker "Inactive" `
            -InventoryReady $false `
            -RequestReadinessReady $false `
            -FirewallActive $false | Should -Be "Unhealthy"

        Get-OpenPathBrowserEnforcementOverallDecision `
            -AppLocker "AuditOnly" `
            -InventoryReady $true `
            -RequestReadinessReady $true `
            -FirewallActive $true | Should -Be "Healthy"
    }
}
