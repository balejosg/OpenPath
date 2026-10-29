# OpenPath Windows browser Chromium policy tests

Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force
$modulePath = Join-Path $PSScriptRoot ".." "lib"
Import-Module "$modulePath\Browser.psm1" -Force -Global -ErrorAction Stop

Describe "Browser Module - Chromium Policy" {
    BeforeAll {
        $browserModulePath = Join-Path (Join-Path $PSScriptRoot ".." "lib") "Browser.psm1"
        Import-Module $browserModulePath -Force -Global -ErrorAction Stop
    }

    Context "Set-ChromePolicy" {
        It "Does not throw with empty blocked paths" -Skip:((-not $IsWindows) -or -not (Test-IsAdmin)) {
            { Set-ChromePolicy -BlockedPaths @() } | Should -Not -Throw
        }

        It "Reads Chromium defaults from the shared contract fixture" {
            $contract = Get-ContractFixtureJson -FileName 'browser-chromium-policy.json'
            $contract.defaultSearchProviderName | Should -Be 'DuckDuckGo'
            $contract.defaultSearchProviderSearchURL | Should -Be 'https://duckduckgo.com/?q={searchTerms}'
            $contract.dnsOverHttpsMode | Should -Be 'off'
        }

        Context "through the local GPO policy store" {
            BeforeEach {
                $script:listCalls = @()
                $script:valueCalls = @()
                $script:logCalls = @()
                $script:removedLegacyValues = @()
                $script:legacyOwner = 'None'
                $script:managedPolicy = $null
                $script:listResultOverride = $null
                $script:valueResultOverride = $null

                Mock Get-OpenPathChromiumManagedPolicy { $script:managedPolicy } -ModuleName Browser
                Mock Sync-OpenPathManagedPolicyList {
                    param([string]$Key, [string[]]$Values)
                    $script:listCalls += [PSCustomObject]@{ Key = $Key; Values = @($Values) }
                    if ($script:listResultOverride) { return (& $script:listResultOverride $Key) }
                    return [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'None'; GpoName = ''; FailureCode = '' }
                } -ModuleName Browser
                Mock Set-OpenPathManagedPolicyValue {
                    param([string]$Key, [string]$ValueName, [string]$Type, $Value)
                    $script:valueCalls += [PSCustomObject]@{ Key = $Key; ValueName = $ValueName; Type = $Type; Value = $Value }
                    if ($script:valueResultOverride) { return (& $script:valueResultOverride $Key $ValueName) }
                    return [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'None'; GpoName = ''; FailureCode = '' }
                } -ModuleName Browser
                Mock Get-OpenPathPolicyValueOwner {
                    [PSCustomObject]@{ Owner = $script:legacyOwner; GpoName = ''; Evidence = @() }
                } -ModuleName Browser
                Mock Remove-OpenPathManagedPolicyList { [PSCustomObject]@{ Removed = $true; FailureCode = '' } } -ModuleName Browser
                Mock Remove-OpenPathManagedPolicyValue { [PSCustomObject]@{ Removed = $true; FailureCode = '' } } -ModuleName Browser
                Mock Test-Path { $true } -ModuleName Browser
                Mock Get-ItemProperty {
                    [PSCustomObject]@{ '1' = 'old-a'; '2' = 'old-b'; 'Note' = 'keep'; PSPath = 'x' }
                } -ModuleName Browser
                Mock Remove-ItemProperty {
                    param([string]$Path, [string]$LiteralPath, [string]$Name)
                    $script:removedLegacyValues += [PSCustomObject]@{ Path = "$Path$LiteralPath"; Name = $Name }
                } -ModuleName Browser
                Mock Set-ItemProperty { throw 'Set-ItemProperty must not be used for Chromium policies' } -ModuleName Browser
                Mock New-Item { throw 'New-Item must not be used for Chromium policies' } -ModuleName Browser
                Mock Remove-Item { throw 'Remove-Item must not be used for Chromium policies' } -ModuleName Browser
                Mock Write-OpenPathLog {
                    param([string]$Message, [string]$Level)
                    $script:logCalls += [PSCustomObject]@{ Message = $Message; Level = $Level }
                } -ModuleName Browser
            }

            It "Blocklist goes through Sync list for Chrome and Edge" {
                $result = Set-ChromePolicy -BlockedPaths @('https://openpath.example.invalid/a/*', '', 'https://openpath.example.invalid/b/*')
                $result | Should -BeTrue

                $spec = Get-ContractFixtureJson -FileName 'browser-chromium-policy.json'
                $expected = @('https://openpath.example.invalid/a/*', 'https://openpath.example.invalid/b/*', [string]$spec.googleSearchBlock)
                foreach ($block in @($spec.googleGameBlocks)) { if ($block) { $expected += [string]$block } }

                $blocklistCalls = @($script:listCalls | Where-Object { $_.Key -like '*\URLBlocklist' })
                $blocklistCalls.Count | Should -Be 2
                @($blocklistCalls | ForEach-Object { $_.Key }) | Should -Be @(
                    'Software\Policies\Google\Chrome\URLBlocklist',
                    'Software\Policies\Microsoft\Edge\URLBlocklist'
                )
                foreach ($call in $blocklistCalls) {
                    @($call.Values) | Should -Be $expected
                }
                @($script:logCalls | Where-Object { $_.Message -eq 'Policies written to: HKLM:\SOFTWARE\Policies\Google\Chrome' }).Count | Should -Be 1
                @($script:logCalls | Where-Object { $_.Message -eq 'Policies written to: HKLM:\SOFTWARE\Policies\Microsoft\Edge' }).Count | Should -Be 1
            }

            It "Writes the Google search URL blocklist entry for managed browsers" {
                Set-ChromePolicy -BlockedPaths @() | Should -BeTrue

                $googleBlockCalls = @($script:listCalls | Where-Object {
                        $_.Key -like '*\URLBlocklist' -and @($_.Values) -contains '*://www.google.*/search*'
                    })
                $googleBlockCalls.Count | Should -Be 2
            }

            It "Sets search provider and DnsOverHttpsMode scalar values through the store" {
                Set-ChromePolicy -BlockedPaths @() | Should -BeTrue

                $spec = Get-ContractFixtureJson -FileName 'browser-chromium-policy.json'
                foreach ($key in @('Software\Policies\Google\Chrome', 'Software\Policies\Microsoft\Edge')) {
                    $forKey = @($script:valueCalls | Where-Object { $_.Key -eq $key })
                    $forKey.Count | Should -Be 4

                    $enabled = $forKey | Where-Object { $_.ValueName -eq 'DefaultSearchProviderEnabled' }
                    $enabled.Type | Should -Be 'DWord'
                    $enabled.Value | Should -BeOfType [int]
                    $enabled.Value | Should -Be ([int]$spec.defaultSearchProviderEnabled)

                    ($forKey | Where-Object { $_.ValueName -eq 'DefaultSearchProviderName' }).Type | Should -Be 'String'
                    ($forKey | Where-Object { $_.ValueName -eq 'DefaultSearchProviderSearchURL' }).Type | Should -Be 'String'
                    $doh = $forKey | Where-Object { $_.ValueName -eq 'DnsOverHttpsMode' }
                    $doh.Type | Should -Be 'String'
                    $doh.Value | Should -Be 'off'
                }
            }

            It "Writes ExtensionInstallForcelist through Sync list when a managed extension exists" {
                $script:managedPolicy = [PSCustomObject]@{
                    ExtensionId = 'abcdefghijklmnopabcdefghijklmnop'
                    Version = '2.0.0'
                    UpdateUrl = 'https://openpath.example.invalid/api/extensions/chromium/updates.xml'
                }

                Set-ChromePolicy -BlockedPaths @() | Should -BeTrue

                $forcelistCalls = @($script:listCalls | Where-Object { $_.Key -like '*\ExtensionInstallForcelist' })
                @($forcelistCalls | ForEach-Object { $_.Key }) | Should -Be @(
                    'Software\Policies\Google\Chrome\ExtensionInstallForcelist',
                    'Software\Policies\Microsoft\Edge\ExtensionInstallForcelist'
                )
                foreach ($call in $forcelistCalls) {
                    @($call.Values) | Should -Be @('abcdefghijklmnopabcdefghijklmnop;https://openpath.example.invalid/api/extensions/chromium/updates.xml')
                }
            }

            It "Forcelist skipped when no managed extension" {
                $script:managedPolicy = $null

                Set-ChromePolicy -BlockedPaths @() | Should -BeTrue

                @($script:listCalls | Where-Object { $_.Key -like '*ExtensionInstallForcelist' }).Count | Should -Be 0
                Should -Invoke Remove-OpenPathManagedPolicyList -ModuleName Browser -Times 0 -Exactly
            }

            It "Externally managed key logs warning and returns false" {
                $script:listResultOverride = {
                    param($Key)
                    if ($Key -eq 'Software\Policies\Google\Chrome\URLBlocklist') {
                        return [PSCustomObject]@{ Applied = $false; Changed = $false; Owner = 'DomainGpo'; GpoName = 'School Chrome Policy'; FailureCode = 'policy-externally-managed' }
                    }
                    return [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'None'; GpoName = ''; FailureCode = '' }
                }

                $result = Set-ChromePolicy -BlockedPaths @()
                $result | Should -BeFalse

                $warn = @($script:logCalls | Where-Object {
                        $_.Level -eq 'WARN' -and
                        $_.Message -like '*Software\Policies\Google\Chrome\URLBlocklist*' -and
                        $_.Message -like '*DomainGpo*' -and
                        $_.Message -like '*School Chrome Policy*'
                    })
                $warn.Count | Should -BeGreaterThan 0

                # other keys/browser are still processed
                @($script:listCalls | Where-Object { $_.Key -eq 'Software\Policies\Microsoft\Edge\URLBlocklist' }).Count | Should -Be 1
                @($script:valueCalls | Where-Object { $_.Key -eq 'Software\Policies\Microsoft\Edge' }).Count | Should -Be 4
            }

            It "Externally managed scalar value logs warning and returns false" {
                $script:valueResultOverride = {
                    param($Key, $ValueName)
                    if ($ValueName -eq 'DnsOverHttpsMode') {
                        return [PSCustomObject]@{ Applied = $false; Changed = $false; Owner = 'Mdm'; GpoName = ''; FailureCode = 'policy-externally-managed' }
                    }
                    return [PSCustomObject]@{ Applied = $true; Changed = $true; Owner = 'None'; GpoName = ''; FailureCode = '' }
                }

                Set-ChromePolicy -BlockedPaths @() | Should -BeFalse

                @($script:logCalls | Where-Object {
                        $_.Level -eq 'WARN' -and $_.Message -like '*DnsOverHttpsMode*' -and $_.Message -like '*Mdm*'
                    }).Count | Should -Be 2
            }

            It "Other store failure codes log a warning and return false" {
                $script:listResultOverride = {
                    param($Key)
                    return [PSCustomObject]@{ Applied = $false; Changed = $false; Owner = ''; GpoName = ''; FailureCode = 'local-gpo-unreadable' }
                }

                Set-ChromePolicy -BlockedPaths @() | Should -BeFalse

                @($script:logCalls | Where-Object { $_.Level -eq 'WARN' -and $_.Message -like '*local-gpo-unreadable*' }).Count | Should -BeGreaterThan 0
            }

            It "Clears legacy registry-only numbered list values once before the first sync" {
                $script:legacyOwner = 'Unknown'
                $script:managedPolicy = [PSCustomObject]@{
                    ExtensionId = 'abcdefghijklmnopabcdefghijklmnop'
                    Version = '2.0.0'
                    UpdateUrl = 'https://openpath.example.invalid/api/extensions/chromium/updates.xml'
                }

                Set-ChromePolicy -BlockedPaths @() | Should -BeTrue

                # 4 list keys x 2 numbered values; non-numbered 'Note' is left alone
                @($script:removedLegacyValues).Count | Should -Be 8
                @($script:removedLegacyValues | Where-Object { $_.Name -notmatch '^\d+$' }).Count | Should -Be 0
                @($script:logCalls | Where-Object { $_.Level -eq 'INFO' -and $_.Message -like '*legacy*' }).Count | Should -BeGreaterThan 0
            }

            It "Does not clear list values when the key is already owned by a GPO or absent" {
                foreach ($owner in @('LocalGpo', 'None', 'DomainGpo', 'Mdm')) {
                    $script:removedLegacyValues = @()
                    $script:legacyOwner = $owner
                    Set-ChromePolicy -BlockedPaths @() | Out-Null
                    @($script:removedLegacyValues).Count | Should -Be 0
                }
            }

            It "Skips legacy cleanup for the forcelist when there is no managed extension" {
                $script:legacyOwner = 'Unknown'
                $script:managedPolicy = $null

                Set-ChromePolicy -BlockedPaths @() | Should -BeTrue

                # only the two URLBlocklist keys are cleaned
                @($script:removedLegacyValues).Count | Should -Be 4
                @($script:removedLegacyValues | Where-Object { $_.Path -like '*ExtensionInstallForcelist*' }).Count | Should -Be 0
            }
        }
    }

    Context "Remove-BrowserPolicy" {
        It "Can remove enforcement policies while preserving the Firefox managed extension policy" {
            $script:removedBrowserPolicyPaths = @()
            Mock Test-Path {
                param([string]$Path)
                return ($Path -like '*Mozilla Firefox*distribution*policies.json')
            } -ModuleName Browser
            Mock Remove-Item {
                param([string]$Path)
                $script:removedBrowserPolicyPaths += $Path
            } -ModuleName Browser
            Mock Write-OpenPathLog { } -ModuleName Browser
            Mock Remove-OpenPathManagedPolicyList { [PSCustomObject]@{ Removed = $true; FailureCode = '' } } -ModuleName Browser
            Mock Remove-OpenPathManagedPolicyValue { [PSCustomObject]@{ Removed = $true; FailureCode = '' } } -ModuleName Browser
            Mock Get-OpenPathPolicyValueOwner { [PSCustomObject]@{ Owner = 'None'; GpoName = ''; Evidence = @() } } -ModuleName Browser
            Mock Sync-OpenPathFirefoxManagedExtensionPolicy { return $true } -ModuleName Browser
            Mock Remove-OpenPathFirefoxMachineExtensionPolicy { throw 'Firefox managed extension policy should be preserved' } -ModuleName Browser.FirefoxPolicy
            Mock Remove-OpenPathFirefoxNetworkAutoconfig { } -ModuleName Browser.FirefoxConfig

            { Remove-BrowserPolicy -PreserveFirefoxManagedExtension } | Should -Not -Throw

            Should -Invoke Remove-OpenPathFirefoxMachineExtensionPolicy -ModuleName Browser.FirefoxPolicy -Times 0 -Exactly
            Should -Invoke Sync-OpenPathFirefoxManagedExtensionPolicy -ModuleName Browser -Times 1 -Exactly
            @($script:removedBrowserPolicyPaths | Where-Object { $_ -like '*Mozilla Firefox*distribution*policies.json' }).Count | Should -Be 0
        }

        Context "through the local GPO policy store" {
            BeforeEach {
                $script:removedPaths = @()
                $script:listRemovals = @()
                $script:valueRemovals = @()
                $script:logCalls = @()
                $script:listRemoveResult = $null
                $script:removedLegacy = @()
                $script:legacyOwner = 'None'

                Mock Get-OpenPathPolicyValueOwner {
                    [PSCustomObject]@{ Owner = $script:legacyOwner; GpoName = ''; Evidence = @() }
                } -ModuleName Browser
                Mock Get-ItemProperty { [PSCustomObject]@{ '1' = 'old'; 'Note' = 'keep' } } -ModuleName Browser
                Mock Remove-ItemProperty {
                    param([string]$LiteralPath, [string]$Name)
                    $script:removedLegacy += [PSCustomObject]@{ Path = $LiteralPath; Name = $Name }
                } -ModuleName Browser
                Mock Test-Path { $false } -ModuleName Browser
                Mock Remove-Item {
                    param([string]$Path)
                    $script:removedPaths += $Path
                } -ModuleName Browser
                Mock Write-OpenPathLog {
                    param([string]$Message, [string]$Level)
                    $script:logCalls += [PSCustomObject]@{ Message = $Message; Level = $Level }
                } -ModuleName Browser
                Mock Remove-OpenPathFirefoxMachineExtensionPolicy { $true } -ModuleName Browser.FirefoxPolicy
                Mock Remove-OpenPathFirefoxNetworkAutoconfig { } -ModuleName Browser.FirefoxConfig
                Mock Remove-OpenPathManagedPolicyList {
                    param([string]$Key)
                    $script:listRemovals += $Key
                    if ($script:listRemoveResult) { return (& $script:listRemoveResult $Key) }
                    return [PSCustomObject]@{ Removed = $true; FailureCode = '' }
                } -ModuleName Browser
                Mock Remove-OpenPathManagedPolicyValue {
                    param([string]$Key, [string]$ValueName)
                    $script:valueRemovals += [PSCustomObject]@{ Key = $Key; ValueName = $ValueName }
                    return [PSCustomObject]@{ Removed = $true; FailureCode = '' }
                } -ModuleName Browser
            }

            It "Remove-BrowserPolicy does not Remove-Item policy keys" {
                { Remove-BrowserPolicy } | Should -Not -Throw

                @($script:removedPaths | Where-Object { $_ -like '*URLBlocklist' -or $_ -like '*ExtensionInstallForcelist' }).Count | Should -Be 0
                @($script:listRemovals) | Should -Be @(
                    'Software\Policies\Google\Chrome\URLBlocklist',
                    'Software\Policies\Google\Chrome\ExtensionInstallForcelist',
                    'Software\Policies\Microsoft\Edge\URLBlocklist',
                    'Software\Policies\Microsoft\Edge\ExtensionInstallForcelist'
                )
            }

            It "Removes the scalar Chromium policy values owned by OpenPath for both browsers" {
                Remove-BrowserPolicy

                foreach ($key in @('Software\Policies\Google\Chrome', 'Software\Policies\Microsoft\Edge')) {
                    $names = @($script:valueRemovals | Where-Object { $_.Key -eq $key } | ForEach-Object { $_.ValueName })
                    $names | Should -Be @('DefaultSearchProviderEnabled', 'DefaultSearchProviderName', 'DefaultSearchProviderSearchURL', 'DnsOverHttpsMode')
                }
            }

            It "Clears registry-only legacy numbered values left by pre-store versions" {
                $script:legacyOwner = 'Unknown'
                Mock Test-Path { $true } -ModuleName Browser -ParameterFilter { $LiteralPath -like 'HKLM:*' }

                Remove-BrowserPolicy

                @($script:removedLegacy).Count | Should -Be 4
                @($script:removedLegacy | Where-Object { $_.Name -ne '1' }).Count | Should -Be 0
            }

            It "Treats an externally managed key as a warning, not an error" {
                $script:listRemoveResult = {
                    param($Key)
                    return [PSCustomObject]@{ Removed = $false; FailureCode = 'policy-externally-managed' }
                }

                { Remove-BrowserPolicy } | Should -Not -Throw

                @($script:logCalls | Where-Object { $_.Level -eq 'WARN' -and $_.Message -like '*policy-externally-managed*' }).Count | Should -BeGreaterThan 0
                @($script:logCalls | Where-Object { $_.Level -eq 'ERROR' }).Count | Should -Be 0
                @($script:logCalls | Where-Object { $_.Message -eq 'Browser policies removed' }).Count | Should -Be 1
            }
        }
    }
}
