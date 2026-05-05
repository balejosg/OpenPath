Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\AppControl.psm1" -Force -Global -ErrorAction Stop

Describe "AppControl Module" {
    Context "New-OpenPathNonAdminAppLockerPolicySpec" {
        It "Targets non-admin users with explicit approved browser and OpenPath paths plus user-writable deny paths" {
            $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot 'C:\OpenPath'
            $expectedAllowPaths = @(
                '%WINDIR%\*',
                'C:\OpenPath\*',
                '%PROGRAMFILES%\Mozilla Firefox\firefox.exe',
                '%PROGRAMFILES(X86)%\Mozilla Firefox\firefox.exe',
                '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe',
                '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe',
                '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe',
                '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe'
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
    }
}
