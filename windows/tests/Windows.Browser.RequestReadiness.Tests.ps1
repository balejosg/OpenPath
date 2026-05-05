# OpenPath Windows browser request readiness tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.RequestReadiness.psm1" -Force -Global -ErrorAction Stop

function global:New-ClassroomReadinessConfig {
    return [PSCustomObject]@{
        apiUrl = "https://school.example"
        whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
        classroomId = "classroom-123"
    }
}

function global:New-FirefoxManagedPolicy {
    return [PSCustomObject]@{
        ExtensionId = "monitor-bloqueos@openpath"
        InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
        Source = "managed-api"
    }
}

function global:New-BrowserInventory {
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

Describe "Browser Module - Request Readiness" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module (Join-Path $modulePath "Browser.RequestReadiness.psm1") -Force -Global -ErrorAction Stop
    }

    It "Reports complete Windows browser request readiness facts" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config ([PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }) `
            -ManagedExtensionPolicy ([PSCustomObject]@{
                ExtensionId = "monitor-bloqueos@openpath"
                InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                Source = "managed-api"
            }) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist @("*://www.google.*/search*") `
            -ChromeManagedExtension $true `
            -ChromeDohMode "off" `
            -ChromeUrlBlocklist @("*://www.google.*/search*") `
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory)

        $result.Platform | Should -Be "windows"
        $result.Ready | Should -BeTrue
        $result.Facts.request_setup | Should -Be "ready"
        $result.Facts.firefox_managed_extension | Should -Be "ready"
        $result.Facts.firefox_machine_policy | Should -Be "ready"
        $result.Facts.PSObject.Properties.Name | Should -Not -Contain "firefox_policy"
        $result.Facts.firefox_native_host | Should -Be "ready"
        $result.Facts.edge_managed_extension | Should -Be "ready"
        $result.Facts.edge_doh_mode | Should -Be "ready"
        $result.Facts.edge_url_blocklist | Should -Be "ready"
        $result.Facts.chrome_managed_extension | Should -Be "ready"
        $result.Facts.chrome_doh_mode | Should -Be "ready"
        $result.Facts.chrome_url_blocklist | Should -Be "ready"
        $result.Facts.app_control_active | Should -Be "ready"
        $result.Facts.unmanaged_browsers_detected | Should -Be "ready"
        @($result.FailureReasons).Count | Should -Be 0
    }

    It "Fails strict readiness when installed Edge is not managed" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig) `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $false `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist @("*://www.google.*/search*") `
            -ChromeManagedExtension $true `
            -ChromeDohMode "off" `
            -ChromeUrlBlocklist @("*://www.google.*/search*") `
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory)

        $result.Ready | Should -BeFalse
        $result.Facts.edge_managed_extension | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "edge_managed_extension_missing"
    }

    It "Keeps Chrome optional when Chrome is not installed" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig) `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist @("*://www.google.*/search*") `
            -ChromeManagedExtension $false `
            -ChromeDohMode "missing" `
            -ChromeUrlBlocklist @() `
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory -ApprovedBrowsers @("Mozilla Firefox", "Microsoft Edge"))

        $result.Ready | Should -BeTrue
        $result.Facts.chrome_managed_extension | Should -Be "not_installed"
        $result.Facts.chrome_doh_mode | Should -Be "not_installed"
        $result.Facts.chrome_url_blocklist | Should -Be "not_installed"
        @($result.FailureReasons) | Should -Not -Contain "chrome_managed_extension_missing"
    }

    It "Fails strict readiness when unmanaged browser findings remain" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig) `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist @("*://www.google.*/search*") `
            -ChromeManagedExtension $true `
            -ChromeDohMode "off" `
            -ChromeUrlBlocklist @("*://www.google.*/search*") `
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory -UnmanagedBrowsers @([PSCustomObject]@{ Name = "Brave" }))

        $result.Ready | Should -BeFalse
        $result.Facts.unmanaged_browsers_detected | Should -Be "found"
        @($result.FailureReasons) | Should -Contain "unmanaged_browsers_detected"
    }

    It "Fails strict readiness when app control is inactive" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig) `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist @("*://www.google.*/search*") `
            -ChromeManagedExtension $true `
            -ChromeDohMode "off" `
            -ChromeUrlBlocklist @("*://www.google.*/search*") `
            -AppControlActive $false `
            -BrowserInventory (New-BrowserInventory)

        $result.Ready | Should -BeFalse
        $result.Facts.app_control_active | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "app_control_inactive"
    }

    It "Keeps Chromium unmanaged findings warning-only outside strict mode" {
        $config = New-ClassroomReadinessConfig
        $config | Add-Member -MemberType NoteProperty -Name "enforceManagedBrowserBoundary" -Value $false

        $result = Get-OpenPathBrowserRequestReadiness `
            -Config $config `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $false `
            -EdgeDohMode "automatic" `
            -EdgeUrlBlocklist @() `
            -ChromeManagedExtension $false `
            -ChromeDohMode "automatic" `
            -ChromeUrlBlocklist @() `
            -AppControlActive $false `
            -BrowserInventory (New-BrowserInventory -UnmanagedBrowsers @([PSCustomObject]@{ Name = "Brave" }))

        $result.Ready | Should -BeTrue
        $result.Facts.edge_managed_extension | Should -Be "missing"
        $result.Facts.unmanaged_browsers_detected | Should -Be "found"
        @($result.FailureReasons) | Should -Not -Contain "edge_managed_extension_missing"
        @($result.FailureReasons) | Should -Not -Contain "unmanaged_browsers_detected"
        @($result.FailureReasons) | Should -Not -Contain "app_control_inactive"
    }

    It "Fails readiness when signed Firefox extension policy is missing" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config ([PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }) `
            -ManagedExtensionPolicy $null `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $false

        $result.Ready | Should -BeFalse
        $result.Facts.firefox_managed_extension | Should -Be "missing"
        $result.Facts.firefox_machine_policy | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "firefox_managed_extension_missing"
        @($result.FailureReasons) | Should -Contain "firefox_machine_policy_missing"
    }

    It "Fails readiness when native host registration proof is missing" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config ([PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }) `
            -ManagedExtensionPolicy ([PSCustomObject]@{
                ExtensionId = "monitor-bloqueos@openpath"
                InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                Source = "managed-api"
            }) `
            -NativeHostRegistered $false `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true

        $result.Ready | Should -BeFalse
        $result.Facts.firefox_native_host | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "firefox_native_host_missing"
    }

    It "Fails readiness when request setup is incomplete" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config ([PSCustomObject]@{
                apiUrl = "school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }) `
            -ManagedExtensionPolicy ([PSCustomObject]@{
                ExtensionId = "monitor-bloqueos@openpath"
                InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                Source = "managed-api"
            }) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true

        $result.Ready | Should -BeFalse
        $result.Facts.request_setup | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "request_setup_incomplete"
    }

    It "Fails readiness when Firefox machine policy is missing" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config ([PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }) `
            -ManagedExtensionPolicy ([PSCustomObject]@{
                ExtensionId = "monitor-bloqueos@openpath"
                InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                Source = "managed-api"
            }) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $false

        $result.Ready | Should -BeFalse
        $result.Facts.firefox_machine_policy | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "firefox_machine_policy_missing"
    }
}
