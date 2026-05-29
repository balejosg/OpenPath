# OpenPath Windows browser request readiness tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.RequestReadiness.psm1" -Force -Global -ErrorAction Stop

function global:New-ClassroomReadinessConfig {
    param(
        [string[]]$ApprovedStudentBrowsers = @('Firefox')
    )

    return [PSCustomObject]@{
        apiUrl = "https://school.example"
        whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
        classroomId = "classroom-123"
        approvedStudentBrowsers = @($ApprovedStudentBrowsers)
    }
}

function global:New-FirefoxManagedPolicy {
    return [PSCustomObject]@{
        ExtensionId = "openpath-block-monitor@openpath"
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

function global:New-ChromiumUrlBlocklist {
    return @(
        "*://www.google.*/search*",
        "*://www.google.*/fbx?fbx=snake_arcade*",
        "*://doodles.google/*",
        "*://*.doodles.google/*",
        "*://www.google.*/logos/*"
    )
}

Describe "Browser Module - Request Readiness" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module (Join-Path $modulePath "Browser.RequestReadiness.psm1") -Force -Global -ErrorAction Stop
        Import-Module (Join-Path $modulePath "Browser.ReadinessFacts.psm1") -Force -Global -ErrorAction Stop
    }

    Context "Readiness fact collectors" {
        It "Collects Firefox readiness facts behind mocked probes" {
            Mock Get-OpenPathFirefoxManagedExtensionPolicy { New-FirefoxManagedPolicy } -ModuleName Browser.ReadinessFacts
            Mock Test-OpenPathFirefoxNativeHostRegistrationProof { $true } -ModuleName Browser.ReadinessFacts
            Mock Get-OpenPathFirefoxNativeStatePath { "C:\OpenPath\native-host\state.json" } -ModuleName Browser.ReadinessFacts
            Mock Test-Path { $true } -ModuleName Browser.ReadinessFacts -ParameterFilter { $Path -eq "C:\OpenPath\native-host\state.json" }
            Mock Test-OpenPathFirefoxMachineExtensionPolicy { $true } -ModuleName Browser.ReadinessFacts

            $facts = Get-OpenPathFirefoxReadinessFacts

            $facts.ManagedExtensionReady | Should -BeTrue
            $facts.MachinePolicyApplied | Should -BeTrue
            $facts.NativeHostRegistered | Should -BeTrue
            $facts.NativeHostStatePresent | Should -BeTrue
            $facts.NativeHostReady | Should -BeTrue
            Should -Invoke Get-OpenPathFirefoxManagedExtensionPolicy -ModuleName Browser.ReadinessFacts -Times 1 -Exactly
            Should -Invoke Test-OpenPathFirefoxNativeHostRegistrationProof -ModuleName Browser.ReadinessFacts -Times 1 -Exactly
            Should -Invoke Test-Path -ModuleName Browser.ReadinessFacts -Times 1 -Exactly
            Should -Invoke Test-OpenPathFirefoxMachineExtensionPolicy -ModuleName Browser.ReadinessFacts -Times 1 -Exactly
        }

        It "Collects Chromium readiness facts from registry policy probes and inventory" {
            Mock Test-OpenPathChromiumExtensionForcelistReady { $Browser -eq 'Edge' } -ModuleName Browser.ReadinessFacts
            Mock Get-OpenPathChromiumDohMode { if ($Browser -eq 'Edge') { 'off' } else { 'automatic' } } -ModuleName Browser.ReadinessFacts
            Mock Get-OpenPathChromiumUrlBlocklist { if ($Browser -eq 'Edge') { New-ChromiumUrlBlocklist } else { @() } } -ModuleName Browser.ReadinessFacts

            $facts = Get-OpenPathChromiumReadinessFacts `
                -ApprovedStudentBrowsers @('Firefox', 'Edge') `
                -BrowserInventory (New-BrowserInventory -ApprovedBrowsers @('Mozilla Firefox', 'Microsoft Edge'))

            $facts.Edge.Installed | Should -BeTrue
            $facts.Edge.Approved | Should -BeTrue
            $facts.Edge.ManagedExtensionReady | Should -BeTrue
            $facts.Edge.DohModeReady | Should -BeTrue
            $facts.Edge.UrlBlocklistReady | Should -BeTrue
            $facts.Chrome.Installed | Should -BeFalse
            $facts.Chrome.Approved | Should -BeFalse
            $facts.Chrome.ManagedExtensionReady | Should -BeFalse
            Should -Invoke Test-OpenPathChromiumExtensionForcelistReady -ModuleName Browser.ReadinessFacts -Times 2 -Exactly
            Should -Invoke Get-OpenPathChromiumDohMode -ModuleName Browser.ReadinessFacts -Times 2 -Exactly
            Should -Invoke Get-OpenPathChromiumUrlBlocklist -ModuleName Browser.ReadinessFacts -Times 2 -Exactly
        }

        It "Collects AppControl readiness facts through the AppControl probe" {
            Mock Test-OpenPathNonAdminAppControlActive { $ApprovedBrowsers -contains 'Firefox' } -ModuleName Browser.ReadinessFacts

            $facts = Get-OpenPathAppControlReadinessFacts -ApprovedStudentBrowsers @('Firefox')

            $facts.Active | Should -BeTrue
            Should -Invoke Test-OpenPathNonAdminAppControlActive -ModuleName Browser.ReadinessFacts -Times 1 -Exactly
        }

        It "Marks AppControl incomplete when unapproved Edge is not explicitly blocked" {
            $facts = Get-OpenPathAppControlReadinessFacts -AppControlActive ([PSCustomObject]@{
                    Active = $true
                    BlocksUnapprovedEdge = $false
                })

            $facts.Active | Should -BeFalse
        }
    }

    It "Reports complete Windows browser request readiness facts" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig -ApprovedStudentBrowsers @('Firefox', 'Edge', 'Chrome')) `
            -ManagedExtensionPolicy ([PSCustomObject]@{
                ExtensionId = "openpath-block-monitor@openpath"
                InstallUrl = "https://school.example/api/extensions/firefox/openpath.xpi"
                Source = "managed-api"
            }) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist (New-ChromiumUrlBlocklist) `
            -ChromeManagedExtension $true `
            -ChromeDohMode "off" `
            -ChromeUrlBlocklist (New-ChromiumUrlBlocklist) `
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

    It "Treats installed Edge as healthy when it is not approved and AppLocker is active" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig) `
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
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory)

        $result.Ready | Should -BeTrue
        $result.Facts.edge_approval | Should -Be "not_approved_blocked_by_app_control"
        $result.Facts.edge_managed_extension | Should -Be "not_approved"
        @($result.FailureReasons) | Should -Not -Contain "edge_managed_extension_missing"
    }

    It "Fails readiness for installed unapproved Edge unless AppControl proves Edge is blocked" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig) `
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
            -AppControlActive ([PSCustomObject]@{
                    Active = $true
                    BlocksUnapprovedEdge = $false
                }) `
            -BrowserInventory (New-BrowserInventory)

        $result.Ready | Should -BeFalse
        $result.Facts.edge_approval | Should -Be "not_approved_app_control_missing"
        $result.Facts.app_control_active | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "edge_not_approved_app_control_missing"
    }

    It "Fails strict readiness when approved Edge is installed but not fully managed" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig -ApprovedStudentBrowsers @('Firefox', 'Edge')) `
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
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory)

        $result.Ready | Should -BeFalse
        $result.Facts.edge_approval | Should -Be "approved"
        $result.Facts.edge_managed_extension | Should -Be "missing"
        $result.Facts.edge_doh_mode | Should -Be "missing"
        $result.Facts.edge_url_blocklist | Should -Be "missing"
        @($result.FailureReasons) | Should -Contain "edge_managed_extension_missing"
        @($result.FailureReasons) | Should -Contain "edge_doh_mode_missing"
        @($result.FailureReasons) | Should -Contain "edge_url_blocklist_missing"
    }

    It "Keeps Chrome optional when Chrome is not installed" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig -ApprovedStudentBrowsers @('Firefox', 'Edge')) `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist (New-ChromiumUrlBlocklist) `
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
            -Config (New-ClassroomReadinessConfig -ApprovedStudentBrowsers @('Firefox', 'Edge', 'Chrome')) `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist (New-ChromiumUrlBlocklist) `
            -ChromeManagedExtension $true `
            -ChromeDohMode "off" `
            -ChromeUrlBlocklist (New-ChromiumUrlBlocklist) `
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory -UnmanagedBrowsers @([PSCustomObject]@{ Name = "Brave" }))

        $result.Ready | Should -BeFalse
        $result.Facts.unmanaged_browsers_detected | Should -Be "found"
        @($result.FailureReasons) | Should -Contain "unmanaged_browsers_detected"
    }

    It "Fails strict readiness when app control is inactive" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config (New-ClassroomReadinessConfig -ApprovedStudentBrowsers @('Firefox', 'Edge', 'Chrome')) `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -EdgeManagedExtension $true `
            -EdgeDohMode "off" `
            -EdgeUrlBlocklist (New-ChromiumUrlBlocklist) `
            -ChromeManagedExtension $true `
            -ChromeDohMode "off" `
            -ChromeUrlBlocklist (New-ChromiumUrlBlocklist) `
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
        $result.Facts.edge_approval | Should -Be "not_approved_app_control_missing"
        $result.Facts.edge_managed_extension | Should -Be "not_approved"
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
                ExtensionId = "openpath-block-monitor@openpath"
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
                ExtensionId = "openpath-block-monitor@openpath"
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

    It "Uses request setup state for readiness instead of parsing raw config fields" {
        $config = [PSCustomObject]@{
            apiUrl = "not a url"
            whitelistUrl = "not a whitelist token url"
            classroomId = "classroom-123"
            approvedStudentBrowsers = @("Firefox")
        }

        Mock Get-OpenPathRequestSetupState {
            [PSCustomObject]@{
                Ready = $true
                ClassroomConfigured = $true
                WhitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
            }
        } -ModuleName Browser.RequestReadiness

        $result = Get-OpenPathBrowserRequestReadiness `
            -Config $config `
            -ManagedExtensionPolicy (New-FirefoxManagedPolicy) `
            -NativeHostRegistered $true `
            -NativeHostStatePresent $true `
            -FirefoxMachinePolicyApplied $true `
            -AppControlActive $true `
            -BrowserInventory (New-BrowserInventory -ApprovedBrowsers @("Mozilla Firefox"))

        $result.Ready | Should -BeTrue
        $result.Facts.request_setup | Should -Be "ready"
        Should -Invoke Get-OpenPathRequestSetupState -ModuleName Browser.RequestReadiness -Times 2 -Exactly
    }

    It "Fails readiness when Firefox machine policy is missing" {
        $result = Get-OpenPathBrowserRequestReadiness `
            -Config ([PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            }) `
            -ManagedExtensionPolicy ([PSCustomObject]@{
                ExtensionId = "openpath-block-monitor@openpath"
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
