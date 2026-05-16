Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\AppControl.psm1" -Force -Global -ErrorAction Stop

Describe "AppControl Module" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\AppControl.psm1" -Force -Global -ErrorAction Stop
    }

    Context "New-OpenPathNonAdminAppLockerPolicySpec" {
        It "Defaults non-admin users to Firefox-only browser approval plus OpenPath paths and user-writable deny paths" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            $expectedAllowPaths = @(
                '%WINDIR%\*',
                'C:\OpenPath\*',
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
                '%USERPROFILE%\AppData\Local\*',
                '%APPDATA%\*',
                '%LOCALAPPDATA%\Temp\*',
                '%TEMP%\*'
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
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES%\*'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES(X86)%\*'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES%\Internet Explorer\iexplore.exe'
            @($spec.AllowPaths) | Should -Not -Contain '%PROGRAMFILES(X86)%\Internet Explorer\iexplore.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\curl.exe'
            @($spec.BlockedWindowsTools) | Should -Contain '%WINDIR%\System32\nslookup.exe'
            foreach ($path in $expectedDenyPaths) {
                @($spec.UserWritableDenyPaths) | Should -Contain $path
            }
        }

        It "Allows protected Microsoft WindowsApps launchers without allowing all Program Files" {
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
            $allowedPaths | Should -Not -Contain '%PROGRAMFILES%\*'
            $allowedPaths | Should -Not -Contain 'C:\Program Files\*'
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

            foreach ($collectionType in @('Exe', 'Script')) {
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

            $moduleContent | Should -Match '(?s)function Test-OpenPathNonAdminAppControlActive.*?Where-Object \{ Test-OpenPathAppLockerRuleManaged -Rule \$_ \}'
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
                'Set-Content -Path $script:OpenPathAppLockerBackupPath',
                'Test-OpenPathNonAdminAppControlActive',
                'Set-AppLockerPolicy -XMLPolicy $script:OpenPathAppLockerBackupPath'
            )
        }
    }
}
