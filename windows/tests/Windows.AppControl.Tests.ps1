Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\AppControl.psm1" -Force -Global -ErrorAction Stop

Describe "AppControl Module" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\AppControl.psm1" -Force -Global -ErrorAction Stop
    }

    Context "New-OpenPathNonAdminAppLockerPolicySpec" {
        It "Defaults non-admin users to Firefox-only browser approval plus admin-managed install paths and user-writable deny paths" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            $expectedAllowPaths = @(
                '%WINDIR%\*',
                'C:\OpenPath\*',
                '%PROGRAMFILES%\*',
                '%PROGRAMFILES(X86)%\*',
                'C:\Program Files\*',
                'C:\Program Files (x86)\*',
                '%PROGRAMFILES%\WindowsApps\Microsoft.*\*',
                '%PROGRAMFILES%\WindowsApps\MicrosoftWindows.*\*',
                'C:\Program Files\WindowsApps\Microsoft.*\*',
                'C:\Program Files\WindowsApps\MicrosoftWindows.*\*',
                '%PROGRAMFILES%\Mozilla Firefox\firefox.exe',
                '%PROGRAMFILES(X86)%\Mozilla Firefox\firefox.exe'
            )
            $expectedDenyPaths = @(
                '%USERPROFILE%\Downloads\*',
                '%USERPROFILE%\Desktop\*',
                '%LOCALAPPDATA%\Temp\*',
                '%TEMP%\*'
            )
            $expectedAlwaysDeniedBrowsers = @(
                '%PROGRAMFILES%\BraveSoftware\Brave-Browser\Application\brave.exe',
                '%PROGRAMFILES(X86)%\BraveSoftware\Brave-Browser\Application\brave.exe',
                'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
                'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
                '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe',
                '%PROGRAMFILES%\Opera\launcher.exe',
                '%PROGRAMFILES(X86)%\Opera\launcher.exe',
                '%LOCALAPPDATA%\Programs\Opera\launcher.exe',
                '%PROGRAMFILES%\Opera\opera.exe',
                '%PROGRAMFILES(X86)%\Opera\opera.exe',
                '%LOCALAPPDATA%\Programs\Opera\opera.exe',
                '%PROGRAMFILES%\Vivaldi\Application\vivaldi.exe',
                '%PROGRAMFILES(X86)%\Vivaldi\Application\vivaldi.exe',
                '%LOCALAPPDATA%\Vivaldi\Application\vivaldi.exe',
                '%PROGRAMFILES%\Tor Browser\Browser\firefox.exe',
                '%PROGRAMFILES(X86)%\Tor Browser\Browser\firefox.exe',
                '%PROGRAMFILES%\Chromium\Application\chrome.exe',
                '%PROGRAMFILES(X86)%\Chromium\Application\chrome.exe',
                '%LOCALAPPDATA%\Chromium\Application\chrome.exe',
                '%PROGRAMFILES%\Chromium\Application\chromium.exe',
                '%PROGRAMFILES(X86)%\Chromium\Application\chromium.exe',
                '%LOCALAPPDATA%\Chromium\Application\chromium.exe',
                '%PROGRAMFILES%\Ungoogled Chromium\Application\chrome.exe',
                '%PROGRAMFILES(X86)%\Ungoogled Chromium\Application\chrome.exe',
                '%LOCALAPPDATA%\Ungoogled Chromium\Application\chrome.exe',
                '%PROGRAMFILES%\Ungoogled Chromium\Application\chromium.exe',
                '%PROGRAMFILES(X86)%\Ungoogled Chromium\Application\chromium.exe',
                '%LOCALAPPDATA%\Ungoogled Chromium\Application\chromium.exe',
                '%PROGRAMFILES%\Floorp\floorp.exe',
                '%PROGRAMFILES(X86)%\Floorp\floorp.exe',
                '%LOCALAPPDATA%\Floorp\floorp.exe',
                '%PROGRAMFILES%\Internet Explorer\iexplore.exe',
                '%PROGRAMFILES(X86)%\Internet Explorer\iexplore.exe',
                'C:\Program Files\Internet Explorer\iexplore.exe',
                'C:\Program Files (x86)\Internet Explorer\iexplore.exe'
            )

            $spec.NonAdminSid | Should -Be 'S-1-5-32-545'
            $spec.AdminSid | Should -Be 'S-1-5-32-544'
            $spec.SystemSid | Should -Be 'S-1-5-18'
            $spec.Mode | Should -Be 'Enforced'
            foreach ($path in $expectedAllowPaths) {
                @($spec.AllowPaths) | Should -Contain $path
            }
            @($spec.ApprovedBrowsers) | Should -Contain 'Firefox'
            @($spec.ApprovedBrowsers) | Should -Not -Contain 'Edge'
            @($spec.ApprovedBrowsers) | Should -Not -Contain 'Chrome'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Not -Contain 'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Not -Contain 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe'
            @($spec.AllowPaths) | Should -Not -Contain 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            @($spec.AllowPaths) | Should -Not -Contain 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
            @($spec.UserWritableDenyPaths) | Should -Not -Contain '%USERPROFILE%\AppData\Local\*'
            @($spec.UserWritableDenyPaths) | Should -Not -Contain '%APPDATA%\*'
            @($spec.AllowPaths) | Should -Not -Contain '%LOCALAPPDATA%\*'
            foreach ($path in $expectedAlwaysDeniedBrowsers) {
                @($spec.UnapprovedBrowserDenyPaths) | Should -Contain $path
            }
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\curl.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\nslookup.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\ssh.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe'
            # W-1(a): the inbox scripting/transfer hosts that can open a raw socket to an
            # IP literal must be blocked because enforcement is name-only with no transport
            # floor by default. Windows PowerShell lives under WindowsPowerShell\v1.0, so
            # the bare System32\powershell.exe path is intentionally NOT used (it would
            # never match the real binary).
            @($spec.BlockedWindowsTools) | Should -Not -Contain '%WINDIR%\System32\powershell.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%PROGRAMFILES%\PowerShell\7\pwsh.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%PROGRAMFILES(X86)%\PowerShell\7\pwsh.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\ftp.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\SysWOW64\ftp.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\tftp.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\SysWOW64\tftp.exe'
            foreach ($path in $expectedDenyPaths) {
                @($spec.UserWritableDenyPaths) | Should -Contain $path
            }
        }

        It "Uses the configured OpenPath root for runtime allow paths" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'D:\OpenPathLab'

            @($spec.AllowPaths) | Should -Contain 'D:\OpenPathLab\*'
            @($spec.AllowPaths) | Should -Not -Contain 'C:\OpenPath\*'
        }

        It "Allows protected Microsoft WindowsApps launchers and admin-managed Program Files without approving unmanaged browsers" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec
            $exeCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Exe' })[0]
            $allowRules = @($exeCollection.FilePathRule | Where-Object {
                    $_.GetAttribute('Action') -eq 'Allow' -and
                    $_.GetAttribute('UserOrGroupSid') -eq 'S-1-5-32-545'
                })
            $allowedPaths = @($allowRules | ForEach-Object { $_.Conditions.FilePathCondition.GetAttribute('Path') })

            $allowedPaths | Should -Contain '%PROGRAMFILES%\WindowsApps\Microsoft.*\*'
            $allowedPaths | Should -Contain '%PROGRAMFILES%\WindowsApps\MicrosoftWindows.*\*'
            $allowedPaths | Should -Contain 'C:\Program Files\WindowsApps\Microsoft.*\*'
            $allowedPaths | Should -Contain 'C:\Program Files\WindowsApps\MicrosoftWindows.*\*'
            $allowedPaths | Should -Contain '%PROGRAMFILES%\*'
            $allowedPaths | Should -Contain '%PROGRAMFILES(X86)%\*'
            $allowedPaths | Should -Contain 'C:\Program Files\*'
            $allowedPaths | Should -Contain 'C:\Program Files (x86)\*'

            $denyRules = @($exeCollection.FilePathRule | Where-Object {
                    $_.GetAttribute('Action') -eq 'Deny' -and
                    $_.GetAttribute('UserOrGroupSid') -eq 'S-1-5-32-545'
                })
            $deniedPaths = @($denyRules | ForEach-Object { $_.Conditions.FilePathCondition.GetAttribute('Path') })
            $deniedPaths | Should -Contain '%PROGRAMFILES%\BraveSoftware\Brave-Browser\Application\brave.exe'
            $deniedPaths | Should -Contain '%PROGRAMFILES%\Internet Explorer\iexplore.exe'
        }

        It "Allows future explicit Edge approval without approving Chrome" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath' -ApprovedBrowsers @('Firefox', 'Edge')

            @($spec.ApprovedBrowsers) | Should -Contain 'Firefox'
            @($spec.ApprovedBrowsers) | Should -Contain 'Edge'
            @($spec.ApprovedBrowsers) | Should -Not -Contain 'Chrome'
            @($spec.AllowPaths) | Should -Contain '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Contain '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Contain 'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Contain 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe'
            @($spec.AllowPaths) | Should -Not -Contain 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            @($spec.AllowPaths) | Should -Not -Contain 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Not -Contain '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Not -Contain '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Not -Contain 'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Not -Contain 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
        }

        It "Denies Firefox when it is not an approved student browser" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath' -ApprovedBrowsers @('Edge')

            @($spec.ApprovedBrowsers) | Should -Contain 'Edge'
            @($spec.ApprovedBrowsers) | Should -Not -Contain 'Firefox'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES%\Mozilla Firefox\firefox.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES%\Mozilla Firefox\firefox.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain '%PROGRAMFILES(X86)%\Mozilla Firefox\firefox.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files\Mozilla Firefox\firefox.exe'
            @($spec.UnapprovedBrowserDenyPaths) | Should -Contain 'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
        }

        It "Supports AuditOnly mode without changing the target group" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath' -Mode 'AuditOnly'

            $spec.Mode | Should -Be 'AuditOnly'
            $spec.NonAdminSid | Should -Be 'S-1-5-32-545'
        }

        It "Generates AppLocker rule ids without braces for GuidType compatibility" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec

            $rules = @($policy.AppLockerPolicy.RuleCollection.FilePathRule | Where-Object { $null -ne $_ })
            $rules.Count | Should -BeGreaterThan 0
            foreach ($rule in $rules) {
                $ruleId = $rule.GetAttribute('Id')
                $ruleId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                $ruleId | Should -Not -Match '^\{'
            }
        }

        It "Generates Appx FilePublisherRules instead of leaving packaged apps NotConfigured" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            $policyXml = New-OpenPathAppLockerPolicyXml -Spec $spec
            $policyXml | Should -Not -Match '<RuleCollection Type="Appx" EnforcementMode="NotConfigured"'
            $policyXml | Should -Match '<RuleCollection Type="Appx" EnforcementMode="Enabled">'
            [xml]$policy = $policyXml

            $appxCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]
            $appxCollection | Should -Not -BeNullOrEmpty
            $appxCollection.GetAttribute('EnforcementMode') | Should -Be 'Enabled'
            $appxCollection.GetAttribute('EnforcementMode') | Should -Not -Be 'NotConfigured'

            $rules = @($appxCollection.FilePublisherRule)
            $allowRule = @($rules | Where-Object { $_.GetAttribute('Name') -eq 'OpenPath non-admin app control Appx users allow Microsoft signed packaged apps' })[0]
            $allowRule | Should -Not -BeNullOrEmpty
            $allowRule.GetAttribute('Action') | Should -Be 'Allow'
            $allowRule.GetAttribute('UserOrGroupSid') | Should -Be 'S-1-1-0'
            $condition = $allowRule.Conditions.FilePublisherCondition
            # Scoped to Microsoft-signed packages only — not a global wildcard publisher.
            $condition.GetAttribute('PublisherName') | Should -Be 'O=MICROSOFT CORPORATION*'
            $condition.GetAttribute('ProductName') | Should -Be '*'
            $condition.GetAttribute('BinaryName') | Should -Be '*'
            $condition.BinaryVersionRange.GetAttribute('LowSection') | Should -Be '*'
            $condition.BinaryVersionRange.GetAttribute('HighSection') | Should -Be '*'
        }

        It "Does not emit a global Appx allow with PublisherName wildcard and ProductName wildcard" {
            # Finding #10: a ProductName='*' allow under PublisherName='*' lets a standard user run
            # any sideloaded packaged app, bypassing the per-product Edge denies.
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec
            $appxCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]

            $globalWildcardAllowRules = @($appxCollection.FilePublisherRule | Where-Object {
                $_.GetAttribute('Action') -eq 'Allow' -and
                $_.Conditions.FilePublisherCondition.GetAttribute('PublisherName') -eq '*' -and
                $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*'
            })
            $globalWildcardAllowRules.Count | Should -Be 0

            # The scoped Microsoft-publisher allow must be present in its place.
            $microsoftAllowRule = @($appxCollection.FilePublisherRule | Where-Object {
                $_.GetAttribute('Action') -eq 'Allow' -and
                $_.GetAttribute('UserOrGroupSid') -eq 'S-1-1-0' -and
                $_.Conditions.FilePublisherCondition.GetAttribute('PublisherName') -eq 'O=MICROSOFT CORPORATION*' -and
                $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*'
            })
            $microsoftAllowRule.Count | Should -Be 1
        }

        It "Generates Appx denies for unapproved Edge products while preserving the signed packaged-app allow" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec
            $appxCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]

            $appxCollection.GetAttribute('EnforcementMode') | Should -Be 'Enabled'
            $allowRule = @($appxCollection.FilePublisherRule | Where-Object {
                    $_.GetAttribute('Action') -eq 'Allow' -and
                    $_.GetAttribute('UserOrGroupSid') -eq 'S-1-1-0' -and
                    $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*'
                })[0]
            $allowRule | Should -Not -BeNullOrEmpty

            $deniedProducts = @(
                $appxCollection.FilePublisherRule |
                    Where-Object {
                        $_.GetAttribute('Action') -eq 'Deny' -and
                        $_.GetAttribute('UserOrGroupSid') -eq 'S-1-5-32-545'
                    } |
                    ForEach-Object { $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') }
            )
            $deniedProducts | Should -Contain 'Microsoft.MicrosoftEdge'
            $deniedProducts | Should -Contain 'Microsoft.MicrosoftEdge.Stable'
        }

        It "Omits Edge Appx denies when Edge is explicitly approved" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath' -ApprovedBrowsers @('Firefox', 'Edge')
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec
            $appxCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]

            $deniedProducts = @(
                $appxCollection.FilePublisherRule |
                    Where-Object { $_.GetAttribute('Action') -eq 'Deny' } |
                    ForEach-Object { $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') }
            )
            $deniedProducts | Should -Not -Contain 'Microsoft.MicrosoftEdge'
            $deniedProducts | Should -Not -Contain 'Microsoft.MicrosoftEdge.Stable'
        }

        It "W-1(a): blocks socket-capable inbox interpreters wherever their allow path lives, including pwsh under Program Files" {
            # The bypass: powershell.exe -c Invoke-WebRequest -Uri https://<IP>/ reaches any
            # IP and spoofs the Host header, because enforcement is name-only with no
            # transport floor by default. pwsh.exe lives under %PROGRAMFILES%\PowerShell\7,
            # which is covered by the %PROGRAMFILES%\* allow -- that allow does NOT carry the
            # %WINDIR% exception list -- so an explicit non-admin Deny is required.
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec
            $exeCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Exe' })[0]

            $nonAdminDenyPaths = @(
                $exeCollection.FilePathRule |
                    Where-Object {
                        $_.GetAttribute('Action') -eq 'Deny' -and
                        $_.GetAttribute('UserOrGroupSid') -eq 'S-1-5-32-545'
                    } |
                    ForEach-Object { $_.Conditions.FilePathCondition.GetAttribute('Path') }
            )

            foreach ($blockedTool in @(
                    '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe',
                    '%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe',
                    '%PROGRAMFILES%\PowerShell\7\pwsh.exe',
                    '%PROGRAMFILES(X86)%\PowerShell\7\pwsh.exe',
                    '%WINDIR%\System32\ftp.exe',
                    '%WINDIR%\System32\tftp.exe',
                    '%WINDIR%\System32\curl.exe'
                )) {
                $nonAdminDenyPaths | Should -Contain $blockedTool
            }

            # The %WINDIR%\* allow exception mechanism for the WINDIR tools is preserved.
            $windirAllowRule = @($exeCollection.FilePathRule | Where-Object {
                    $_.GetAttribute('Action') -eq 'Allow' -and
                    $_.GetAttribute('UserOrGroupSid') -eq 'S-1-5-32-545' -and
                    $_.Conditions.FilePathCondition.GetAttribute('Path') -eq '%WINDIR%\*'
                })[0]
            $windirAllowRule | Should -Not -BeNullOrEmpty
            $windirExceptionPaths = @($windirAllowRule.Exceptions.FilePathCondition | ForEach-Object { $_.GetAttribute('Path') })
            $windirExceptionPaths | Should -Contain '%WINDIR%\System32\curl.exe'
            $windirExceptionPaths | Should -Contain '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe'
        }

        It "W-2: denies the parallel-network-stack Microsoft Appx packages while preserving the signed allow" {
            # The blanket O=MICROSOFT CORPORATION* / ProductName='*' allow lets WSL, Windows
            # Terminal, and the OpenSSH/Telnet Appx run -- each a parallel unfiltered network
            # stack. Deny beats Allow in AppLocker, so explicit per-product denies neutralise
            # them without removing the broad allow that keeps inbox/Store apps usable.
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            $spec.AlwaysDeniedAppxProducts | Should -Contain 'Microsoft.WSL'
            $spec.AlwaysDeniedAppxProducts | Should -Contain 'Microsoft.WindowsTerminal'
            $spec.AlwaysDeniedAppxProducts | Should -Contain 'Microsoft.OpenSSHClient'

            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec
            $appxCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]

            $deniedProducts = @(
                $appxCollection.FilePublisherRule |
                    Where-Object {
                        $_.GetAttribute('Action') -eq 'Deny' -and
                        $_.GetAttribute('UserOrGroupSid') -eq 'S-1-5-32-545'
                    } |
                    ForEach-Object { $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') }
            )
            foreach ($product in @($spec.AlwaysDeniedAppxProducts)) {
                $deniedProducts | Should -Contain $product
            }

            # The Microsoft-signed allow is still present in its place.
            $microsoftAllowRule = @($appxCollection.FilePublisherRule | Where-Object {
                    $_.GetAttribute('Action') -eq 'Allow' -and
                    $_.GetAttribute('UserOrGroupSid') -eq 'S-1-1-0' -and
                    $_.Conditions.FilePublisherCondition.GetAttribute('PublisherName') -eq 'O=MICROSOFT CORPORATION*' -and
                    $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*'
                })
            $microsoftAllowRule.Count | Should -Be 1
        }

        It "W-2: keeps the parallel-network-stack Appx denies even when Edge is approved" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath' -ApprovedBrowsers @('Firefox', 'Edge')
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec
            $appxCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]

            $deniedProducts = @(
                $appxCollection.FilePublisherRule |
                    Where-Object { $_.GetAttribute('Action') -eq 'Deny' } |
                    ForEach-Object { $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') }
            )
            # Edge denies are dropped (Edge approved) but the parallel-stack denies remain.
            $deniedProducts | Should -Not -Contain 'Microsoft.MicrosoftEdge'
            $deniedProducts | Should -Contain 'Microsoft.WSL'
            $deniedProducts | Should -Contain 'Microsoft.OpenSSHClient'
        }

        It "W-2: boundary policy validator requires the parallel-network-stack Appx denies" {
            InModuleScope AppControl {
                $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
                [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec

                # A correct policy passes the boundary validator.
                Test-OpenPathAppLockerBoundaryPolicy -PolicyXml $policy -Mode 'Enforced' | Should -BeTrue

                # Stripping the WSL deny must make the boundary validator fail.
                $appxCollection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]
                $wslDeny = @($appxCollection.FilePublisherRule | Where-Object {
                        $_.GetAttribute('Action') -eq 'Deny' -and
                        $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq 'Microsoft.WSL'
                    })[0]
                [void]$appxCollection.RemoveChild($wslDeny)
                Test-OpenPathAppLockerBoundaryPolicy -PolicyXml $policy -Mode 'Enforced' | Should -BeFalse
            }
        }

        It "Generates non-admin deny rules for user-writable paths before user allow rules in Exe and Script collections" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec

            foreach ($collectionType in @('Exe', 'Script')) {
                $collection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq $collectionType })[0]
                $rules = @($collection.FilePathRule)

                foreach ($path in @($spec.UserWritableDenyPaths)) {
                    $matchingRules = @($rules | Where-Object {
                            $_.GetAttribute('Action') -eq 'Deny' -and
                            $_.GetAttribute('UserOrGroupSid') -eq 'S-1-5-32-545' -and
                            $_.Conditions.FilePathCondition.GetAttribute('Path') -eq $path
                        })
                    $matchingRules.Count | Should -Be 1
                }

                $firstUserAllowIndex = -1
                $lastUserDenyIndex = -1
                for ($index = 0; $index -lt $rules.Count; $index++) {
                    $rule = $rules[$index]
                    if ($rule.GetAttribute('UserOrGroupSid') -ne 'S-1-5-32-545') {
                        continue
                    }
                    if ($rule.GetAttribute('Action') -eq 'Allow' -and $firstUserAllowIndex -eq -1) {
                        $firstUserAllowIndex = $index
                    }
                    if ($rule.GetAttribute('Action') -eq 'Deny') {
                        $lastUserDenyIndex = $index
                    }
                }
                $lastUserDenyIndex | Should -BeLessThan $firstUserAllowIndex
            }
        }

        It "Preserves administrator and SYSTEM allow-all rules in generated XML" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec

            foreach ($collectionType in @('Exe', 'Script')) {
                $collection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq $collectionType })[0]
                $rules = @($collection.FilePathRule)

                foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
                    $matchingRules = @($rules | Where-Object {
                            $_.GetAttribute('Action') -eq 'Allow' -and
                            $_.GetAttribute('UserOrGroupSid') -eq $sid -and
                            $_.Conditions.FilePathCondition.GetAttribute('Path') -eq '*'
                        })
                    $matchingRules.Count | Should -Be 1
                }
            }
        }

        It "Sets generated rule collection enforcement to AuditOnly when requested" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath' -Mode 'AuditOnly'
            [xml]$policy = New-OpenPathAppLockerPolicyXml -Spec $spec

            foreach ($collectionType in @('Exe', 'Script', 'Appx')) {
                $collection = @($policy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq $collectionType })[0]
                $collection.GetAttribute('EnforcementMode') | Should -Be 'AuditOnly'
            }
        }

        It "Merges OpenPath rules while preserving non-OpenPath rules" {
            [xml]$currentPolicy = @'
<AppLockerPolicy Version="1">
    <RuleCollection Type="Exe" EnforcementMode="Enabled">
      <FilePathRule Id="11111111-1111-1111-1111-111111111111" Name="Vendor allow" Description="Existing rule" UserOrGroupSid="S-1-5-32-545" Action="Allow">
        <Conditions><FilePathCondition Path="C:\Vendor\*" /></Conditions>
      </FilePathRule>
      <FilePathRule Id="22222222-2222-2222-2222-222222222222" Name="OpenPath non-admin app control stale" Description="Managed by OpenPath" UserOrGroupSid="S-1-5-32-545" Action="Allow">
        <Conditions><FilePathCondition Path="C:\OldOpenPath\*" /></Conditions>
      </FilePathRule>
    </RuleCollection>
    <RuleCollection Type="Script" EnforcementMode="Enabled" />
    <RuleCollection Type="Appx" EnforcementMode="NotConfigured">
      <FilePublisherRule Id="33333333-3333-3333-3333-333333333333" Name="Vendor packaged allow" Description="Existing rule" UserOrGroupSid="S-1-1-0" Action="Allow">
        <Conditions><FilePublisherCondition PublisherName="CN=Vendor" ProductName="VendorApp" BinaryName="*"><BinaryVersionRange LowSection="*" HighSection="*" /></FilePublisherCondition></Conditions>
      </FilePublisherRule>
    </RuleCollection>
</AppLockerPolicy>
'@
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$openPathPolicy = New-OpenPathAppLockerPolicyXml -Spec $spec

            $mergedPolicy = Merge-OpenPathAppLockerPolicyXml -CurrentPolicy $currentPolicy -OpenPathPolicy $openPathPolicy
            $exeRules = @($mergedPolicy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Exe' }).FilePathRule
            $ruleNames = @($exeRules | ForEach-Object { $_.GetAttribute('Name') })

            $ruleNames | Should -Contain 'Vendor allow'
            $ruleNames | Should -Not -Contain 'OpenPath non-admin app control stale'
            @($exeRules | Where-Object { $_.Conditions.FilePathCondition.GetAttribute('Path') -eq 'C:\OldOpenPath\*' }).Count | Should -Be 0
            @($ruleNames | Where-Object { $_ -like 'OpenPath non-admin app control*' }).Count | Should -BeGreaterThan 0

            $appxCollection = @($mergedPolicy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]
            $appxCollection.GetAttribute('EnforcementMode') | Should -Be 'Enabled'
            $appxRuleNames = @($appxCollection.FilePublisherRule | ForEach-Object { $_.GetAttribute('Name') })
            $appxRuleNames | Should -Contain 'Vendor packaged allow'
            $appxRuleNames | Should -Contain 'OpenPath non-admin app control Appx users allow Microsoft signed packaged apps'
            $openPathAppxRule = @($appxCollection.FilePublisherRule | Where-Object { $_.GetAttribute('Name') -eq 'OpenPath non-admin app control Appx users allow Microsoft signed packaged apps' })[0]
            $openPathAppxRule.GetAttribute('Action') | Should -Be 'Allow'
            $openPathAppxRule.GetAttribute('UserOrGroupSid') | Should -Be 'S-1-1-0'
            # Scoped to Microsoft-signed packages only — not a global wildcard publisher.
            $openPathAppxRule.Conditions.FilePublisherCondition.GetAttribute('PublisherName') | Should -Be 'O=MICROSOFT CORPORATION*'
            $openPathAppxRule.Conditions.FilePublisherCondition.GetAttribute('ProductName') | Should -Be '*'
            $openPathAppxRule.Conditions.FilePublisherCondition.GetAttribute('BinaryName') | Should -Be '*'
            $openPathAppxRule.Conditions.FilePublisherCondition.BinaryVersionRange.GetAttribute('LowSection') | Should -Be '*'
            $openPathAppxRule.Conditions.FilePublisherCondition.BinaryVersionRange.GetAttribute('HighSection') | Should -Be '*'
        }

        It "Merges OpenPath rules into a pristine policy that has no RuleCollection children" {
            # Regression: a machine that has never had AppLocker configured returns
            # '<AppLockerPolicy Version="1" />' with zero RuleCollection children, so
            # $CurrentPolicy.AppLockerPolicy.RuleCollection is a scalar $null. Piping
            # that $null into Where-Object { $_.GetAttribute(...) } ran the filter once
            # with $_ = $null and threw "You cannot call a method on a null-valued
            # expression", which aborted the mandatory installer app-control phase.
            [xml]$currentPolicy = '<AppLockerPolicy Version="1" />'
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            [xml]$openPathPolicy = New-OpenPathAppLockerPolicyXml -Spec $spec

            { Merge-OpenPathAppLockerPolicyXml -CurrentPolicy $currentPolicy -OpenPathPolicy $openPathPolicy } | Should -Not -Throw

            $mergedPolicy = Merge-OpenPathAppLockerPolicyXml -CurrentPolicy ([xml]'<AppLockerPolicy Version="1" />') -OpenPathPolicy $openPathPolicy
            $exeCollection = @($mergedPolicy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Exe' })[0]
            $exeCollection | Should -Not -BeNullOrEmpty
            $exeCollection.GetAttribute('EnforcementMode') | Should -Be 'Enabled'
            @($exeCollection.FilePathRule | Where-Object { $_.GetAttribute('Name') -like 'OpenPath non-admin app control*' }).Count | Should -BeGreaterThan 0

            $appxCollection = @($mergedPolicy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq 'Appx' })[0]
            $appxCollection | Should -Not -BeNullOrEmpty
            $appxCollection.GetAttribute('EnforcementMode') | Should -Be 'Enabled'
        }

        It "Classifies managed AppLocker rules using the rule Name attribute" {
            [xml]$policy = @'
<AppLockerPolicy Version="1">
    <RuleCollection Type="Exe" EnforcementMode="Enabled">
      <FilePathRule Id="11111111-1111-1111-1111-111111111111" Name="OpenPath non-admin app control stale" Description="Managed by OpenPath" UserOrGroupSid="S-1-5-32-545" Action="Allow">
        <Conditions><FilePathCondition Path="C:\OldOpenPath\*" /></Conditions>
      </FilePathRule>
      <FilePathRule Id="22222222-2222-2222-2222-222222222222" Name="Vendor allow" Description="Existing rule" UserOrGroupSid="S-1-5-32-545" Action="Allow">
        <Conditions><FilePathCondition Path="C:\Vendor\*" /></Conditions>
      </FilePathRule>
    </RuleCollection>
</AppLockerPolicy>
'@
            $rules = @($policy.AppLockerPolicy.RuleCollection.ChildNodes)

            InModuleScope AppControl -Parameters @{ ManagedRule = $rules[0]; VendorRule = $rules[1] } {
                $ManagedRule.LocalName | Should -Be 'FilePathRule'
                Get-OpenPathAppLockerRuleName -Rule $ManagedRule | Should -Be 'OpenPath non-admin app control stale'
                Test-OpenPathAppLockerRuleManaged -Rule $ManagedRule | Should -BeTrue
                Test-OpenPathAppLockerRuleManaged -Rule $VendorRule | Should -BeFalse
            }
        }

        It "Uses AppLocker rule Name attributes for active detection and removal" {
            $moduleContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "AppControl.psm1") -Raw

            $moduleContent | Should -Match '(?s)function Test-OpenPathFilePathRulePresent.*?Test-OpenPathAppLockerRuleManaged -Rule \$_'
            $moduleContent | Should -Match '(?s)function Test-OpenPathFilePublisherRulePresent.*?Test-OpenPathAppLockerRuleManaged -Rule \$_'
            $moduleContent | Should -Match '(?s)function Test-OpenPathNonAdminAppControlActive.*?Test-OpenPathAppLockerBoundaryPolicy'
            $moduleContent | Should -Match '(?s)function Remove-OpenPathNonAdminAppControl.*?if \(Test-OpenPathAppLockerRuleManaged -Rule \$rule\)'
            $moduleContent | Should -Not -Match '\$rule\.Name -like "\$script:OpenPathAppControlRulePrefix\*"'
            $moduleContent | Should -Not -Match '\$_\.Name -like "\$script:OpenPathAppControlRulePrefix\*"'
        }

        It "Uses backup and validation when applying AppLocker policy" {
            $moduleContent = Get-Content (Join-Path $PSScriptRoot ".." "lib" "AppControl.psm1") -Raw

            Assert-ContentContainsAll -Content $moduleContent -Needles @(
                'applocker-backup.xml',
                'Merge-OpenPathAppLockerPolicyXml',
                'Get-OpenPathAppLockerRuleName',
                'Test-OpenPathAppLockerRuleManaged',
                'if (@($sourceCollection.ChildNodes).Count -eq 0)',
                '$appLockerBackupPath = Join-Path (Join-Path $OpenPathRoot ''data'') ''applocker-backup.xml''',
                'Set-Content -Path $appLockerBackupPath',
                'Test-OpenPathNonAdminAppControlActive',
                'Set-AppLockerPolicy -XMLPolicy $appLockerBackupPath'
            )
        }

        It "Does not treat a partial managed AppLocker policy as an active browser boundary" {
            function global:Set-AppLockerPolicy {}
            function global:Get-AppLockerPolicy {
@'
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="11111111-1111-1111-1111-111111111111" Name="OpenPath non-admin app control Exe users allow C-OpenPath" Description="Managed by OpenPath" UserOrGroupSid="S-1-5-32-545" Action="Allow">
      <Conditions><FilePathCondition Path="C:\OpenPath\*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
'@
            }
            function global:Get-Service {
                [PSCustomObject]@{ Name = 'AppIDSvc'; Status = 'Running' }
            }

            try {
                Test-OpenPathNonAdminAppControlActive | Should -BeFalse
            }
            finally {
                Remove-Item Function:\Set-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-Service -ErrorAction SilentlyContinue
            }
        }

        It "Requires AppIDSvc to be running for an active browser boundary" {
            function global:Set-AppLockerPolicy {}
            function global:Get-AppLockerPolicy {
                $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
                New-OpenPathAppLockerPolicyXml -Spec $spec
            }
            function global:Get-Service {
                [PSCustomObject]@{ Name = 'AppIDSvc'; Status = 'Stopped' }
            }

            try {
                Test-OpenPathNonAdminAppControlActive | Should -BeFalse
            }
            finally {
                Remove-Item Function:\Set-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-Service -ErrorAction SilentlyContinue
            }
        }
    }
}
