BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

    $modulePath = Join-Path $PSScriptRoot ".." "lib"
    Import-Module "$modulePath\Browser.FirefoxConfig.psm1" -Force -Global -ErrorAction Stop
}

Describe "Firefox network autoconfig" {
    Context "New-OpenPathFirefoxNetworkAutoconfigContent" {
        It "Locks DoH and DNS prefetch without using Firefox enterprise DNSOverHTTPS policy" -Skip:(-not $IsWindows) {
            $content = Browser.FirefoxConfig\New-OpenPathFirefoxNetworkAutoconfigContent

            $content.AutoconfigJs | Should -Match 'general\.config\.filename'
            $content.MozillaCfg | Should -Match 'lockPref\("network\.trr\.mode", 5\)'
            $content.MozillaCfg | Should -Match 'lockPref\("network\.trr\.uri", ""\)'
            $content.MozillaCfg | Should -Match 'lockPref\("network\.dns\.disablePrefetch", true\)'
            $content.MozillaCfg | Should -Match 'lockPref\("network\.dnsCacheExpiration", 0\)'
            $content.MozillaCfg | Should -Not -Match 'DNSOverHTTPS'
        }
    }
}
