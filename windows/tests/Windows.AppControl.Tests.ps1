Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

$modulePath = Join-Path $PSScriptRoot ".." "lib"
Get-Module AppControl | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module "$modulePath\AppControl.psm1" -Force -Global -ErrorAction Stop

Describe "AppControl Module" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Get-Module AppControl | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module "$modulePath\AppControl.psm1" -Force -Global -ErrorAction Stop
        function global:Get-LocalGroup { throw 'not found' }
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

            $spec.RestrictedSid | Should -Be 'S-1-5-32-545'
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
            $spec.RestrictedSid | Should -Be 'S-1-5-32-545'
        }

        It "Scopes user Deny and Allow rules to the restricted group SID when the group exists" {
            function global:Get-LocalGroup { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-10-20-30-4242' } } }
            try {
                $spec = New-OpenPathNonAdminAppLockerPolicySpec
                $spec.RestrictedSid | Should -Be 'S-1-5-21-10-20-30-4242'

                $xml = New-OpenPathAppLockerPolicyXml -Spec $spec
                $xml | Should -Match 'S-1-5-21-10-20-30-4242'
                $xml | Should -Not -Match ([regex]::Escape('S-1-5-32-545'))
            }
            finally {
                Remove-Item Function:\Get-LocalGroup -ErrorAction SilentlyContinue
            }
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
            $moduleContent | Should -Match '(?s)function Get-OpenPathNonAdminAppControlHealth.*?Test-OpenPathAppLockerBoundaryPolicy'
            $moduleContent | Should -Match '(?s)function Test-OpenPathNonAdminAppControlActive.*?Get-OpenPathNonAdminAppControlHealth'
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

        It "Fails closed without modifying AppLocker when administrator detection is false" {
            if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) {
                function global:Set-AppLockerPolicy { param($XMLPolicy) }
            }

            Mock Test-AdminPrivileges { $false } -ModuleName AppControl
            Mock Set-AppLockerPolicy { throw 'AppLocker mutation must not be attempted' } -ModuleName AppControl

            Set-OpenPathNonAdminAppControl -OpenPathRoot $TestDrive -Mode Enforced -ApprovedBrowsers @('Firefox') -Confirm:$false | Should -BeFalse
            Should -Invoke Set-AppLockerPolicy -ModuleName AppControl -Times 0 -Exactly
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

        It "Returns false when effective AppLocker policy is empty or missing collections" {
            function global:Set-AppLockerPolicy {}
            function global:Get-AppLockerPolicy {
                param([switch]$Local, [switch]$Effective, [switch]$Xml)
                if ($Effective) {
                    return '<AppLockerPolicy Version="1" />'
                }
                $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
                return (New-OpenPathAppLockerPolicyXml -Spec $spec)
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

        It "Returns false when Test-AppLockerPolicy allows an arbitrary user-writable executable by default" {
            function global:Set-AppLockerPolicy {}
            function global:Get-AppLockerPolicy {
                param([switch]$Local, [switch]$Effective, [switch]$Xml)
                if ($Xml) {
                    $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
                    return (New-OpenPathAppLockerPolicyXml -Spec $spec)
                }
                return [pscustomobject]@{
                    RuleCollections = @([pscustomobject]@{ Type = 'Exe' }, [pscustomobject]@{ Type = 'Appx' })
                }
            }
            function global:Get-Service {
                [PSCustomObject]@{ Name = 'AppIDSvc'; Status = 'Running' }
            }
            function global:Test-AppLockerPolicy {
                param($Path, $User, [Parameter(ValueFromPipeline = $true)]$PolicyObject)
                @($Path | ForEach-Object {
                    [pscustomobject]@{
                        FilePath = $_
                        PolicyDecision = 'AllowedByDefault'
                        MatchingRule = $null
                    }
                })
            }

            try {
                Test-OpenPathNonAdminAppControlActive | Should -BeFalse
            }
            finally {
                Remove-Item Function:\Set-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-Service -ErrorAction SilentlyContinue
                Remove-Item Function:\Test-AppLockerPolicy -ErrorAction SilentlyContinue
            }
        }

        It "Returns true when local and effective policies and Test-AppLockerPolicy validate expected enforcement" {
            $global:opLegacyProbeGroupSid = 'S-1-5-21-10-20-30-4242'
            $global:opLegacyProbeStudentSid = 'S-1-5-21-10-20-30-1001'
            $global:opLegacyProbeProfilePath = Join-Path $TestDrive 'legacy-student'
            $global:opLegacyProbeSystemRoot = Join-Path $TestDrive 'legacy-windows'
            $global:opLegacyProbeSourcePath = Join-Path (Join-Path $global:opLegacyProbeSystemRoot 'System32') 'cmd.exe'
            $global:opLegacyPreviousSystemRoot = $env:SystemRoot
            $env:SystemRoot = $global:opLegacyProbeSystemRoot
            New-Item -ItemType Directory -Path $global:opLegacyProbeProfilePath, (Split-Path $global:opLegacyProbeSourcePath -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllBytes($global:opLegacyProbeSourcePath, [byte[]](0x4d, 0x5a, 0x90, 0x00))

            function global:Set-AppLockerPolicy {}
            function global:Get-AppLockerPolicy {
                param([switch]$Local, [switch]$Effective, [switch]$Xml)
                if ($Xml) {
                    $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
                    return (New-OpenPathAppLockerPolicyXml -Spec $spec)
                }
                return [pscustomobject]@{
                    RuleCollections = @([pscustomobject]@{ Type = 'Exe' }, [pscustomobject]@{ Type = 'Appx' })
                }
            }
            function global:Get-Service {
                [PSCustomObject]@{ Name = 'AppIDSvc'; Status = 'Running' }
            }
            function global:Get-LocalGroup {
                param([string]$Name, [string]$SID)
                [pscustomobject]@{ Name = $Name; SID = [pscustomobject]@{ Value = $global:opLegacyProbeGroupSid } }
            }
            function global:Get-LocalGroupMember {
                param([string]$Group)
                [pscustomobject]@{ SID = [pscustomobject]@{ Value = $global:opLegacyProbeStudentSid } }
            }
            function global:Get-CimInstance {
                param([string]$ClassName)
                [pscustomobject]@{ SID = $global:opLegacyProbeStudentSid; LocalPath = $global:opLegacyProbeProfilePath; Special = $false }
            }
            function global:Test-AppLockerPolicy {
                param($Path, $User, [Parameter(ValueFromPipeline = $true)]$PolicyObject)
                @($Path | ForEach-Object {
                    $decision = if ($_ -like '*firefox.exe') {
                        'Allowed'
                    } elseif ($_ -like '*msedge.exe') {
                        'Denied'
                    } else {
                        'DeniedByDefault'
                    }
                    [pscustomobject]@{
                        FilePath = $_
                        PolicyDecision = $decision
                        MatchingRule = 'rule'
                    }
                })
            }

            try {
                Mock Get-OpenPathAppControlExistingSamplePaths {
                    param([string[]]$Paths, [string]$Label)
                    @($Paths | Select-Object -First 1)
                } -ModuleName AppControl
                Test-OpenPathNonAdminAppControlActive | Should -BeTrue
            }
            finally {
                if ($null -eq $global:opLegacyPreviousSystemRoot) {
                    Remove-Item Env:SystemRoot -ErrorAction SilentlyContinue
                }
                else {
                    $env:SystemRoot = $global:opLegacyPreviousSystemRoot
                }
                Remove-Item Function:\Set-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-Service -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-LocalGroup -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-LocalGroupMember -ErrorAction SilentlyContinue
                Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue
                Remove-Item Function:\Test-AppLockerPolicy -ErrorAction SilentlyContinue
                Remove-Item Variable:\opLegacyProbeGroupSid, Variable:\opLegacyProbeStudentSid, Variable:\opLegacyProbeProfilePath, Variable:\opLegacyProbeSystemRoot, Variable:\opLegacyProbeSourcePath, Variable:\opLegacyPreviousSystemRoot -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Effective AppLocker probe validation" {
        BeforeEach {
            $global:opProbeGroupSid = 'S-1-5-21-10-20-30-4242'
            $global:opProbeStudentSid = 'S-1-5-21-10-20-30-1001'
            $global:opProbeProfilePath = Join-Path $TestDrive 'different-student'
            $global:opProbeSystemRoot = Join-Path $TestDrive 'windows'
            $global:opProbeSourcePath = Join-Path (Join-Path $global:opProbeSystemRoot 'System32') 'cmd.exe'
            $global:opProbeDecision = 'Denied'
            $global:opProbeThrows = $false
            $global:opProbeNoDecisions = $false
            $global:opObservedProbePaths = @()
            $global:opObservedProbeUsers = @()
            $global:opPreviousSystemRoot = $env:SystemRoot
            $env:SystemRoot = $global:opProbeSystemRoot

            New-Item -ItemType Directory -Path $global:opProbeProfilePath, (Split-Path $global:opProbeSourcePath -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllBytes($global:opProbeSourcePath, [byte[]](0x4d, 0x5a, 0x90, 0x00))

            function global:Set-AppLockerPolicy {}
            function global:Get-AppLockerPolicy {
                param([switch]$Local, [switch]$Effective, [switch]$Xml)
                if ($Xml) {
                    $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
                    return (New-OpenPathAppLockerPolicyXml -Spec $spec)
                }
                return [pscustomobject]@{
                    RuleCollections = @([pscustomobject]@{ Type = 'Exe' }, [pscustomobject]@{ Type = 'Appx' })
                }
            }
            function global:Get-Service {
                [pscustomobject]@{ Name = 'AppIDSvc'; Status = 'Running' }
            }
            function global:Get-LocalGroup {
                param([string]$Name, [string]$SID)
                [pscustomobject]@{ Name = $Name; SID = [pscustomobject]@{ Value = $global:opProbeGroupSid } }
            }
            function global:Get-LocalGroupMember {
                param([string]$Group)
                if ($Group -eq 'OpenPath-Restricted') {
                    return [pscustomobject]@{ SID = [pscustomobject]@{ Value = $global:opProbeStudentSid } }
                }
                return @()
            }
            function global:Get-CimInstance {
                param([string]$ClassName)
                [pscustomobject]@{ SID = $global:opProbeStudentSid; LocalPath = $global:opProbeProfilePath; Special = $false }
            }
            function global:Test-AppLockerPolicy {
                param($Path, $User, [Parameter(ValueFromPipeline = $true)]$PolicyObject)
                $global:opObservedProbePaths += @($Path)
                $global:opObservedProbeUsers += $User
                if ($global:opProbeThrows) {
                    throw 'injected Test-AppLockerPolicy failure'
                }
                if ($global:opProbeNoDecisions) {
                    return
                }
                @($Path | ForEach-Object {
                    $decision = if ($_ -like '*firefox.exe') { 'Allowed' } elseif ($_ -like '*msedge.exe') { 'Denied' } else { $global:opProbeDecision }
                    [pscustomobject]@{
                        FilePath = $_
                        PolicyDecision = $decision
                        MatchingRule = 'rule'
                    }
                })
            }

            Mock Get-OpenPathAppControlExistingSamplePaths {
                param([string[]]$Paths, [string]$Label)
                @($Paths | Select-Object -First 1)
            } -ModuleName AppControl
        }

        AfterEach {
            if ($null -eq $global:opPreviousSystemRoot) {
                Remove-Item Env:SystemRoot -ErrorAction SilentlyContinue
            }
            else {
                $env:SystemRoot = $global:opPreviousSystemRoot
            }
            Remove-Item Function:\Set-AppLockerPolicy, Function:\Get-AppLockerPolicy, Function:\Get-Service, Function:\Get-LocalGroup, Function:\Get-LocalGroupMember, Function:\Get-CimInstance, Function:\Test-AppLockerPolicy -ErrorAction SilentlyContinue
            Remove-Item Variable:\opProbeGroupSid, Variable:\opProbeStudentSid, Variable:\opProbeProfilePath, Variable:\opProbeSystemRoot, Variable:\opProbeSourcePath, Variable:\opProbeDecision, Variable:\opProbeThrows, Variable:\opProbeNoDecisions, Variable:\opObservedProbePaths, Variable:\opObservedProbeUsers, Variable:\opPreviousSystemRoot -ErrorAction SilentlyContinue
        }

        It "resolves the profile of a restricted user without depending on alumno" {
            Test-OpenPathNonAdminAppControlActive | Should -BeTrue
            @($global:opObservedProbePaths | Where-Object { $_ -match '(?i)\\alumno\\' }) | Should -BeNullOrEmpty
            @($global:opObservedProbePaths | Where-Object { $_ -like "$($global:opProbeProfilePath)*" }).Count | Should -BeGreaterThan 0
            @($global:opObservedProbeUsers) | Should -Contain $global:opProbeStudentSid
        }

        It "creates initially absent probes and removes them after effective evaluation" {
            $probeDirectories = @(
                (Join-Path $global:opProbeProfilePath 'Downloads'),
                (Join-Path $global:opProbeProfilePath 'Desktop'),
                (Join-Path $global:opProbeProfilePath 'AppData\Local\Temp')
            )
            foreach ($directory in $probeDirectories) {
                Test-Path -LiteralPath $directory | Should -BeFalse
            }

            Test-OpenPathNonAdminAppControlActive | Should -BeTrue

            foreach ($directory in $probeDirectories) {
                Test-Path -LiteralPath $directory | Should -BeFalse
            }
            $controlledProbePaths = @(
                $global:opObservedProbePaths |
                    Where-Object { $_ -match '(?i)(?:\\|/)openpath-appcontrol-probe-[^\\/]+\.exe$' }
            )
            $controlledProbePaths.Count | Should -Be 3
            @($controlledProbePaths | Where-Object { Test-Path -LiteralPath $_ }) | Should -BeNullOrEmpty
        }

        It "accepts an effective Denied decision for the controlled probe" {
            $global:opProbeDecision = 'Denied'
            Test-OpenPathNonAdminAppControlActive | Should -BeTrue
        }

        It "rejects AllowedByDefault for the controlled probe" {
            $global:opProbeDecision = 'AllowedByDefault'
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse
        }

        It "fails closed when the restricted group or profile cannot be resolved" {
            function global:Get-LocalGroup { throw 'restricted group unavailable' }
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse

            function global:Get-LocalGroup {
                param([string]$Name, [string]$SID)
                [pscustomobject]@{ Name = $Name; SID = $null }
            }
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse

            function global:Get-LocalGroup {
                param([string]$Name, [string]$SID)
                [pscustomobject]@{ Name = $Name; SID = [pscustomobject]@{ Value = $global:opProbeGroupSid } }
            }
            function global:Get-CimInstance { return @() }
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse
        }

        It "fails closed when probe preparation fails" {
            Mock Get-OpenPathAppControlProbeSourcePath {
                throw 'injected AppControl probe source failure'
            } -ModuleName AppControl
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse
        }

        It "fails closed when policy evaluation fails or returns no decisions" {
            $global:opProbeThrows = $true
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse
            foreach ($directory in @(
                    (Join-Path $global:opProbeProfilePath 'Downloads'),
                    (Join-Path $global:opProbeProfilePath 'Desktop'),
                    (Join-Path $global:opProbeProfilePath 'AppData\Local\Temp')
                )) {
                Test-Path -LiteralPath $directory | Should -BeFalse
            }

            $global:opProbeThrows = $false
            $global:opProbeNoDecisions = $true
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse
        }

        It "fails closed when Test-AppLockerPolicy is unavailable instead of trusting XML" {
            Remove-Item Function:\Test-AppLockerPolicy -ErrorAction SilentlyContinue
            Test-OpenPathNonAdminAppControlActive | Should -BeFalse
        }
    }

    Context "Structured AppControl health contract" {
        BeforeEach {
            $global:opHealthGroupSid = 'S-1-5-21-10-20-30-4242'
            $global:opHealthStudentSid = 'S-1-5-21-10-20-30-1001'
            $global:opHealthProfilePath = Join-Path $TestDrive 'health-student'
            $global:opHealthSystemRoot = Join-Path $TestDrive 'health-windows'
            $global:opHealthSourcePath = Join-Path (Join-Path $global:opHealthSystemRoot 'System32') 'cmd.exe'
            $global:opHealthLocalPolicyState = 'valid'
            $global:opHealthEffectivePolicyState = 'valid'
            $global:opHealthAppIdStatus = 'Running'
            $global:opHealthArbitraryDecision = 'DeniedByDefault'
            $global:opHealthEdgeDecision = 'Denied'
            $global:opHealthFirefoxDecision = 'Allowed'
            $global:opHealthPolicyMode = 'Enforced'
            $global:opHealthTargetMissing = $false
            $global:opHealthRuntimeEffectiveObjectState = 'valid'
            $global:opHealthRuntimeEvaluatorState = 'valid'
            $global:opHealthSampleCount = 1
            $global:opHealthSampleFailureLabel = ''
            $global:opHealthPreviousSystemRoot = $env:SystemRoot
            $env:SystemRoot = $global:opHealthSystemRoot

            New-Item -ItemType Directory -Path $global:opHealthProfilePath, (Split-Path $global:opHealthSourcePath -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllBytes($global:opHealthSourcePath, [byte[]](0x4d, 0x5a, 0x90, 0x00))

            function global:Set-AppLockerPolicy {}
            function global:Get-AppLockerPolicy {
                param([switch]$Local, [switch]$Effective, [switch]$Xml)
                if ($Xml) {
                    $state = if ($Local) { $global:opHealthLocalPolicyState } else { $global:opHealthEffectivePolicyState }
                    if ($state -eq 'absent') {
                        return $null
                    }
                    if ($state -eq 'invalid') {
                        return '<AppLockerPolicy'
                    }
                    $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath' -Mode $global:opHealthPolicyMode
                    return (New-OpenPathAppLockerPolicyXml -Spec $spec)
                }

                if ($Effective) {
                    if ($global:opHealthRuntimeEffectiveObjectState -eq 'absent') {
                        return $null
                    }
                    if ($global:opHealthRuntimeEffectiveObjectState -eq 'empty') {
                        return [pscustomobject]@{ RuleCollections = @() }
                    }
                }
                return [pscustomobject]@{
                    RuleCollections = @([pscustomobject]@{ Type = 'Exe' }, [pscustomobject]@{ Type = 'Appx' })
                }
            }
            function global:Get-Service {
                [pscustomobject]@{ Name = 'AppIDSvc'; Status = $global:opHealthAppIdStatus }
            }
            function global:Get-LocalGroup {
                param([string]$Name, [string]$SID)
                if ($global:opHealthTargetMissing) {
                    throw 'OpenPath-Restricted group unavailable'
                }
                [pscustomobject]@{ Name = $Name; SID = [pscustomobject]@{ Value = $global:opHealthGroupSid } }
            }
            function global:Get-LocalGroupMember {
                param([string]$Group)
                [pscustomobject]@{ SID = [pscustomobject]@{ Value = $global:opHealthStudentSid } }
            }
            function global:Get-CimInstance {
                param([string]$ClassName)
                [pscustomobject]@{ SID = $global:opHealthStudentSid; LocalPath = $global:opHealthProfilePath; Special = $false }
            }
            function global:Test-AppLockerPolicy {
                param($Path, $User, [Parameter(ValueFromPipeline = $true)]$PolicyObject)
                if ($global:opHealthRuntimeEvaluatorState -eq 'throw') {
                    throw 'injected runtime evaluator failure'
                }
                if ($global:opHealthRuntimeEvaluatorState -eq 'no-decisions') {
                    return
                }
                $decisions = @($Path | ForEach-Object {
                    $pathText = [string]$_
                    $decision = if ($pathText -match '(?i)firefox\.exe$') {
                        if ($global:opHealthFirefoxDecision -eq 'mixed') {
                            if ($pathText -match '(?i)\(x86\)') { 'Denied' } else { 'Allowed' }
                        }
                        else {
                            $global:opHealthFirefoxDecision
                        }
                    }
                    elseif ($pathText -match '(?i)msedge\.exe$') {
                        if ($global:opHealthEdgeDecision -eq 'mixed') {
                            if ($pathText -match '(?i)\(x86\)') { 'Allowed' } else { 'Denied' }
                        }
                        else {
                            $global:opHealthEdgeDecision
                        }
                    }
                    else {
                        $global:opHealthArbitraryDecision
                    }
                    [pscustomobject]@{
                        FilePath = $pathText
                        PolicyDecision = $decision
                        MatchingRule = 'health-test-rule'
                    }
                })
                if ($global:opHealthRuntimeEvaluatorState -eq 'partial') {
                    return @($decisions | Select-Object -First 1)
                }
                return $decisions
            }

            Mock Get-OpenPathAppControlExistingSamplePaths {
                param([string[]]$Paths, [string]$Label)
                if ($global:opHealthSampleFailureLabel -eq $Label) {
                    throw "injected $Label sample lookup failure"
                }
                @($Paths | Select-Object -First $global:opHealthSampleCount)
            } -ModuleName AppControl
        }

        AfterEach {
            if ($null -eq $global:opHealthPreviousSystemRoot) {
                Remove-Item Env:SystemRoot -ErrorAction SilentlyContinue
            }
            else {
                $env:SystemRoot = $global:opHealthPreviousSystemRoot
            }
            Remove-Item Function:\Set-AppLockerPolicy, Function:\Get-AppLockerPolicy, Function:\Get-Service, Function:\Get-LocalGroup, Function:\Get-LocalGroupMember, Function:\Get-CimInstance, Function:\Test-AppLockerPolicy -ErrorAction SilentlyContinue
            Remove-Item Variable:\opHealthGroupSid, Variable:\opHealthStudentSid, Variable:\opHealthProfilePath, Variable:\opHealthSystemRoot, Variable:\opHealthSourcePath, Variable:\opHealthLocalPolicyState, Variable:\opHealthEffectivePolicyState, Variable:\opHealthAppIdStatus, Variable:\opHealthArbitraryDecision, Variable:\opHealthEdgeDecision, Variable:\opHealthFirefoxDecision, Variable:\opHealthPolicyMode, Variable:\opHealthTargetMissing, Variable:\opHealthRuntimeEffectiveObjectState, Variable:\opHealthRuntimeEvaluatorState, Variable:\opHealthSampleCount, Variable:\opHealthSampleFailureLabel, Variable:\opHealthPreviousSystemRoot -ErrorAction SilentlyContinue
        }

        It "returns a deterministic healthy contract and keeps the boolean compatibility seam" {
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.Healthy | Should -BeTrue
            $health.Mode | Should -Be 'Enforced'
            @($health.ReasonCodes).Count | Should -Be 0
            $health.CapabilityAvailable | Should -BeTrue
            $health.RestrictedTargetValid | Should -BeTrue
            $health.AppIdentityServiceRunning | Should -BeTrue
            $health.LocalPolicyPresent | Should -BeTrue
            $health.LocalPolicyValid | Should -BeTrue
            $health.EffectivePolicyPresent | Should -BeTrue
            $health.EffectivePolicyValid | Should -BeTrue
            $health.RuntimeEvaluationAvailable | Should -BeTrue
            $health.RuntimeBoundaryValid | Should -BeTrue
            Test-OpenPathNonAdminAppControlActive | Should -BeTrue
        }

        It "reports unavailable AppLocker management capability" {
            Remove-Item Function:\Set-AppLockerPolicy, Function:\Get-AppLockerPolicy -ErrorAction SilentlyContinue
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.Healthy | Should -BeFalse
            $health.CapabilityAvailable | Should -BeFalse
            @($health.ReasonCodes) | Should -Be @('appcontrol_capability_unavailable')
        }

        It "preserves the requested AuditOnly mode in the health contract" {
            $global:opHealthPolicyMode = 'AuditOnly'
            $health = Get-OpenPathNonAdminAppControlHealth -Mode AuditOnly

            $health.Mode | Should -Be 'AuditOnly'
            $health.Healthy | Should -BeTrue
        }

        It "distinguishes local policy absence from invalidity" {
            $global:opHealthLocalPolicyState = 'absent'
            $absent = Get-OpenPathNonAdminAppControlHealth
            $absent.LocalPolicyPresent | Should -BeFalse
            $absent.LocalPolicyValid | Should -BeFalse
            @($absent.ReasonCodes) | Should -Contain 'appcontrol_local_policy_absent'
            @($absent.ReasonCodes) | Should -Not -Contain 'appcontrol_local_policy_invalid'

            $global:opHealthLocalPolicyState = 'invalid'
            $invalid = Get-OpenPathNonAdminAppControlHealth
            $invalid.LocalPolicyPresent | Should -BeTrue
            $invalid.LocalPolicyValid | Should -BeFalse
            @($invalid.ReasonCodes) | Should -Contain 'appcontrol_local_policy_invalid'
            @($invalid.ReasonCodes) | Should -Not -Contain 'appcontrol_local_policy_absent'
        }

        It "distinguishes effective policy absence from invalidity" {
            $global:opHealthEffectivePolicyState = 'absent'
            $absent = Get-OpenPathNonAdminAppControlHealth
            $absent.EffectivePolicyPresent | Should -BeFalse
            $absent.EffectivePolicyValid | Should -BeFalse
            @($absent.ReasonCodes) | Should -Contain 'appcontrol_effective_policy_absent'
            @($absent.ReasonCodes) | Should -Not -Contain 'appcontrol_effective_policy_invalid'

            $global:opHealthEffectivePolicyState = 'invalid'
            $invalid = Get-OpenPathNonAdminAppControlHealth
            $invalid.EffectivePolicyPresent | Should -BeTrue
            $invalid.EffectivePolicyValid | Should -BeFalse
            @($invalid.ReasonCodes) | Should -Contain 'appcontrol_effective_policy_invalid'
            @($invalid.ReasonCodes) | Should -Not -Contain 'appcontrol_effective_policy_absent'
        }

        It "reports a missing current OpenPath restricted target instead of trusting the BUILTIN Users fallback" {
            $global:opHealthTargetMissing = $true
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.Healthy | Should -BeFalse
            $health.RestrictedTargetValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_restricted_target_missing'
        }

        It "reports a stopped Application Identity service" {
            $global:opHealthAppIdStatus = 'Stopped'
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.Healthy | Should -BeFalse
            $health.AppIdentityServiceRunning | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_appidsvc_not_running'
        }

        It "reports an arbitrary executable allowed by the effective evaluator" {
            $global:opHealthArbitraryDecision = 'AllowedByDefault'
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.RuntimeEvaluationAvailable | Should -BeTrue
            $health.RuntimeBoundaryValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_arbitrary_exe_allowed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "reports an unapproved Edge executable allowed by the effective evaluator" {
            $global:opHealthEdgeDecision = 'Allowed'
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.RuntimeBoundaryValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_edge_allowed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "reports an approved Firefox executable that is not allowed by the effective evaluator" {
            $global:opHealthFirefoxDecision = 'Denied'
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.RuntimeBoundaryValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_firefox_not_allowed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "reports generic runtime failure for an unavailable or empty effective policy object" {
            foreach ($state in @('absent', 'empty')) {
                $global:opHealthRuntimeEffectiveObjectState = $state
                $health = Get-OpenPathNonAdminAppControlHealth

                $health.Healthy | Should -BeFalse
                $health.RuntimeEvaluationAvailable | Should -BeTrue
                $health.RuntimeBoundaryValid | Should -BeFalse
                @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_evaluation_failed'
                @($health.ReasonCodes).Count | Should -BeGreaterThan 0
            }
        }

        It "reports generic runtime failure when Test-AppLockerPolicy throws or returns no decisions" {
            foreach ($state in @('throw', 'no-decisions')) {
                $global:opHealthRuntimeEvaluatorState = $state
                $health = Get-OpenPathNonAdminAppControlHealth

                $health.Healthy | Should -BeFalse
                $health.RuntimeEvaluationAvailable | Should -BeTrue
                $health.RuntimeBoundaryValid | Should -BeFalse
                @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_evaluation_failed'
                @($health.ReasonCodes).Count | Should -BeGreaterThan 0
            }
        }

        It "reports generic runtime failure when a probe decision is missing" {
            $global:opHealthRuntimeEvaluatorState = 'partial'
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.Healthy | Should -BeFalse
            $health.RuntimeEvaluationAvailable | Should -BeTrue
            $health.RuntimeBoundaryValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_evaluation_failed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "reports generic runtime failure when Edge or Firefox samples cannot be resolved" {
            foreach ($label in @('Edge', 'Firefox')) {
                $global:opHealthSampleFailureLabel = $label
                $health = Get-OpenPathNonAdminAppControlHealth

                $health.Healthy | Should -BeFalse
                $health.RuntimeEvaluationAvailable | Should -BeTrue
                $health.RuntimeBoundaryValid | Should -BeFalse
                @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_evaluation_failed'
                @($health.ReasonCodes).Count | Should -BeGreaterThan 0
            }
        }

        It "requires every sampled Edge decision to be Denied" {
            $global:opHealthSampleCount = 2
            $global:opHealthEdgeDecision = 'mixed'
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.Healthy | Should -BeFalse
            $health.RuntimeBoundaryValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_edge_allowed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "requires every sampled approved Firefox decision to be Allowed" {
            $global:opHealthSampleCount = 2
            $global:opHealthFirefoxDecision = 'mixed'
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.Healthy | Should -BeFalse
            $health.RuntimeBoundaryValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_firefox_not_allowed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "reports unavailable runtime evaluation" {
            Remove-Item Function:\Test-AppLockerPolicy -ErrorAction SilentlyContinue
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.RuntimeEvaluationAvailable | Should -BeFalse
            $health.RuntimeBoundaryValid | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_evaluation_unavailable'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "reports failed probe cleanup independently of valid runtime decisions" {
            Mock Remove-OpenPathAppControlEvaluationProbeSet {
                param([object]$ProbeSet)
                foreach ($probePath in @($ProbeSet.Paths)) {
                    if ([System.IO.File]::Exists([string]$probePath)) {
                        [System.IO.File]::Delete([string]$probePath)
                    }
                }
                foreach ($directoryPath in @($ProbeSet.CreatedDirectories | Sort-Object Length -Descending)) {
                    if ([System.IO.Directory]::Exists([string]$directoryPath) -and @([System.IO.Directory]::GetFileSystemEntries([string]$directoryPath)).Count -eq 0) {
                        [System.IO.Directory]::Delete([string]$directoryPath)
                    }
                }
                return $false
            } -ModuleName AppControl
            $health = Get-OpenPathNonAdminAppControlHealth

            $health.RuntimeBoundaryValid | Should -BeTrue
            $health.Healthy | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_probe_cleanup_failed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0
        }

        It "reports and cleans a partial probe creation cleanup failure" {
            $blockedDirectory = Join-Path $global:opHealthProfilePath 'Desktop'
            if (Test-Path -LiteralPath $blockedDirectory) {
                Remove-Item -LiteralPath $blockedDirectory -Recurse -Force
            }
            New-Item -ItemType File -Path $blockedDirectory -Force | Out-Null
            Mock Remove-OpenPathAppControlEvaluationProbeSet {
                param([object]$ProbeSet)
                foreach ($probePath in @($ProbeSet.Paths)) {
                    if ([System.IO.File]::Exists([string]$probePath)) {
                        [System.IO.File]::Delete([string]$probePath)
                    }
                }
                foreach ($directoryPath in @($ProbeSet.CreatedDirectories | Sort-Object Length -Descending)) {
                    if ([System.IO.Directory]::Exists([string]$directoryPath) -and @([System.IO.Directory]::GetFileSystemEntries([string]$directoryPath)).Count -eq 0) {
                        [System.IO.Directory]::Delete([string]$directoryPath)
                    }
                }
                return $false
            } -ModuleName AppControl

            $health = Get-OpenPathNonAdminAppControlHealth
            $health.Healthy | Should -BeFalse
            @($health.ReasonCodes) | Should -Contain 'appcontrol_probe_cleanup_failed'
            @($health.ReasonCodes) | Should -Contain 'appcontrol_runtime_evaluation_failed'
            @($health.ReasonCodes).Count | Should -BeGreaterThan 0

            $remainingProbeFiles = @(Get-ChildItem -LiteralPath $global:opHealthProfilePath -Filter 'openpath-appcontrol-probe-*.exe' -Recurse -File -ErrorAction SilentlyContinue)
            $remainingProbeFiles.Count | Should -Be 0
            Remove-Item -LiteralPath $blockedDirectory -Force -ErrorAction SilentlyContinue
        }

        It "always includes a reason when a covered runtime health check is unhealthy" {
            $assertHasReason = {
                param([object]$Snapshot)
                $Snapshot.Healthy | Should -BeFalse
                @($Snapshot.ReasonCodes).Count | Should -BeGreaterThan 0
            }

            $global:opHealthRuntimeEffectiveObjectState = 'absent'
            & $assertHasReason (Get-OpenPathNonAdminAppControlHealth)

            $global:opHealthRuntimeEffectiveObjectState = 'valid'
            $global:opHealthRuntimeEvaluatorState = 'no-decisions'
            & $assertHasReason (Get-OpenPathNonAdminAppControlHealth)

            $global:opHealthRuntimeEvaluatorState = 'valid'
            $global:opHealthSampleFailureLabel = 'Edge'
            & $assertHasReason (Get-OpenPathNonAdminAppControlHealth)

            $global:opHealthSampleFailureLabel = ''
            $global:opHealthEdgeDecision = 'mixed'
            $global:opHealthSampleCount = 2
            & $assertHasReason (Get-OpenPathNonAdminAppControlHealth)
        }

        It "deduplicates reasons in stable observation order without diagnostic values" {
            $global:opHealthAppIdStatus = 'Stopped'
            $global:opHealthLocalPolicyState = 'absent'
            $global:opHealthEffectivePolicyState = 'absent'
            $health = Get-OpenPathNonAdminAppControlHealth
            $codes = @($health.ReasonCodes)

            $codes | Should -Be @(
                'appcontrol_appidsvc_not_running',
                'appcontrol_local_policy_absent',
                'appcontrol_effective_policy_absent'
            )
            @($codes | Select-Object -Unique).Count | Should -Be $codes.Count
            ($codes -join ' ') | Should -Not -Match '[\\/:]|https?://|S-1-|[A-Za-z]:\\'
        }
    }

    Context "AppControl sample path resolution" {
        It "uses existing executable samples and fails closed when none exist" {
            $existingPath = Join-Path $TestDrive 'edge.exe'
            $missingPath = Join-Path $TestDrive 'missing-edge.exe'
            [System.IO.File]::WriteAllBytes($existingPath, [byte[]](0x4d, 0x5a, 0x90, 0x00))

            InModuleScope AppControl -Parameters @{ ExistingPath = $existingPath; MissingPath = $missingPath } {
                param($ExistingPath, $MissingPath)

                @(Get-OpenPathAppControlExistingSamplePaths -Paths @($ExistingPath, $MissingPath) -Label 'Edge') |
                    Should -Be $ExistingPath
                {
                    Get-OpenPathAppControlExistingSamplePaths -Paths @($MissingPath) -Label 'Edge'
                } | Should -Throw '*Unable to locate an existing Edge executable*'
            }
        }
    }

    Context "Restricted group SID and membership sync" {
        AfterEach {
            Remove-Item Function:\Get-LocalGroup -ErrorAction SilentlyContinue
            function global:Get-LocalGroup { throw 'not found' }
            Remove-Item Function:\New-LocalGroup -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-LocalGroupMember -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-LocalUser -ErrorAction SilentlyContinue
            Remove-Item Function:\Add-LocalGroupMember -ErrorAction SilentlyContinue
            Remove-Item Variable:\opNewGroupCalls -ErrorAction SilentlyContinue
            Remove-Item Variable:\opAddedMembers -ErrorAction SilentlyContinue
        }

        It "Falls back to BUILTIN\Users SID when the restricted group is missing" {
            function global:Get-LocalGroup { throw 'not found' }
            (Get-OpenPathRestrictedGroupSid) | Should -Be 'S-1-5-32-545'
        }

        It "Returns the restricted group SID when the group exists" {
            function global:Get-LocalGroup { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-100-200-300-999' } } }
            (Get-OpenPathRestrictedGroupSid) | Should -Be 'S-1-5-21-100-200-300-999'
        }

        It "Creates the group and adds enabled non-admins with CreateIfMissing" {
            $global:opNewGroupCalls = 0
            $global:opAddedMembers = @()
            function global:Get-LocalGroup { throw 'not found' }
            function global:New-LocalGroup { $global:opNewGroupCalls++; [pscustomobject]@{ Name = 'OpenPath-Restricted'; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } }
            function global:Get-LocalGroupMember {
                param($Group)
                if ($Group -eq 'Administrators') { return @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } }) }
                return @($global:opAddedMembers | ForEach-Object { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } } })
            }
            function global:Get-LocalUser {
                @(
                    [pscustomobject]@{ Name = 'student';  Enabled = $true;  SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } },
                    [pscustomobject]@{ Name = 'admin';    Enabled = $true;  SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } },
                    [pscustomobject]@{ Name = 'disabled'; Enabled = $false; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1002' } }
                )
            }
            function global:Add-LocalGroupMember { param($Group, $Member) $global:opAddedMembers += [string]$Member }

            $result = Sync-OpenPathRestrictedGroup -CreateIfMissing $true
            $result | Should -BeTrue
            $global:opNewGroupCalls | Should -Be 1
            @($global:opAddedMembers) | Should -Be @('student')
        }

        It "Does not create the group when absent and CreateIfMissing is false" {
            $global:opNewGroupCalls = 0
            function global:Get-LocalGroup { throw 'not found' }
            function global:New-LocalGroup { $global:opNewGroupCalls++ }

            $result = Sync-OpenPathRestrictedGroup
            $result | Should -BeFalse
            $global:opNewGroupCalls | Should -Be 0
        }

        It "Does not re-add existing members and skips admins" {
            $global:opAddedMembers = @()
            function global:Get-LocalGroup { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } }
            function global:Get-LocalGroupMember {
                param($Group)
                if ($Group -eq 'Administrators') { return @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } }) }
                $members = @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } })
                if ('student2' -in $global:opAddedMembers) {
                    $members += [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1003' } }
                }
                return $members
            }
            function global:Get-LocalUser {
                @(
                    [pscustomobject]@{ Name = 'student';  Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } },
                    [pscustomobject]@{ Name = 'student2'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1003' } },
                    [pscustomobject]@{ Name = 'admin';    Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } }
                )
            }
            function global:Add-LocalGroupMember { param($Group, $Member) $global:opAddedMembers += [string]$Member }

            Sync-OpenPathRestrictedGroup -CreateIfMissing $true | Should -BeTrue
            @($global:opAddedMembers) | Should -Be @('student2')
        }

        It "Returns false when Add-LocalGroupMember throws" {
            function global:Get-LocalGroup { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } }
            function global:Get-LocalGroupMember {
                param($Group)
                if ($Group -eq 'Administrators') { return @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } }) }
                return @()
            }
            function global:Get-LocalUser {
                @(
                    [pscustomobject]@{ Name = 'student'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }
                )
            }
            function global:Add-LocalGroupMember { throw 'access denied adding to group' }

            Sync-OpenPathRestrictedGroup -CreateIfMissing $true | Should -BeFalse
        }

        It "Returns false when a non-admin user remains missing from membership postcondition" {
            function global:Get-LocalGroup { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } }
            function global:Get-LocalGroupMember {
                param($Group)
                # Returns empty even after Add-LocalGroupMember
                return @()
            }
            function global:Get-LocalUser {
                @(
                    [pscustomobject]@{ Name = 'student'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }
                )
            }
            function global:Add-LocalGroupMember { param($Group, $Member) }

            Sync-OpenPathRestrictedGroup -CreateIfMissing $true | Should -BeFalse
        }

        It "Returns false and never calls Add-LocalGroupMember when Administrators enumeration throws" {
            $global:opAddedMembers = @()
            function global:Get-LocalGroup { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } }
            function global:Get-LocalGroupMember {
                param($Group)
                throw 'RPC server unavailable enumerating Administrators'
            }
            function global:Get-LocalUser {
                @(
                    [pscustomobject]@{ Name = 'student'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } },
                    [pscustomobject]@{ Name = 'admin';   Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } }
                )
            }
            function global:Add-LocalGroupMember { param($Group, $Member) $global:opAddedMembers += [string]$Member }

            $result = Sync-OpenPathRestrictedGroup -CreateIfMissing $true
            $result | Should -BeFalse
            @($global:opAddedMembers).Count | Should -Be 0
        }

        It "Never adds enabled admin accounts to OpenPath-Restricted" {
            $global:opAddedMembers = @()
            function global:Get-LocalGroup { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } }
            function global:Get-LocalGroupMember {
                param($Group)
                if ($Group -eq 'Administrators') {
                    return @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } })
                }
                $members = @()
                if ('student' -in $global:opAddedMembers) {
                    $members += [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }
                }
                return $members
            }
            function global:Get-LocalUser {
                @(
                    [pscustomobject]@{ Name = 'admin';   Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } },
                    [pscustomobject]@{ Name = 'student'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }
                )
            }
            function global:Add-LocalGroupMember { param($Group, $Member) $global:opAddedMembers += [string]$Member }

            $result = Sync-OpenPathRestrictedGroup -CreateIfMissing $true
            $result | Should -BeTrue
            @($global:opAddedMembers) | Should -Be @('student')
            'admin' -in @($global:opAddedMembers) | Should -BeFalse
        }

        It "Removes the restricted group when it exists and is silent when absent" {
            $global:opRemoveCalls = 0
            function global:Get-LocalGroup { [pscustomobject]@{ Name = 'OpenPath-Restricted' } }
            function global:Remove-LocalGroup { param($Name) $global:opRemoveCalls++ }
            try {
                Remove-OpenPathRestrictedGroup
                $global:opRemoveCalls | Should -Be 1
            }
            finally {
                Remove-Item Function:\Get-LocalGroup -ErrorAction SilentlyContinue
                Remove-Item Function:\Remove-LocalGroup -ErrorAction SilentlyContinue
            }
        }
    }

    AfterAll {
        Remove-Item Function:\Get-LocalGroup -ErrorAction SilentlyContinue
    }
}
