Set-StrictMode -Version Latest

Describe 'Installer configuration runtime safety' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'lib' 'install' 'Installer.Config.ps1')

        $installerScriptPath = Join-Path $PSScriptRoot '..' 'Install-OpenPath.ps1'
        $installerTokens = $null
        $installerParseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerScriptPath, [ref]$installerTokens, [ref]$installerParseErrors)
        $installerConfigValueFunction = $installerAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OpenPathInstallerConfigValue'
            }, $true)
        @($installerParseErrors).Count | Should -Be 0
        $installerConfigValueFunction | Should -Not -BeNullOrEmpty
    }

    It 'reads AppControl intent from the ordered dictionary returned by the config helper' {
        . ([scriptblock]::Create($installerConfigValueFunction.Extent.Text))

        $config = New-OpenPathInstallerConfig -AgentVersion 'test' -PrimaryDNS '127.0.0.1' -EnforceManagedBrowserBoundary:$true -AppControlProfile StrictApplicationAllowlist
        Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'appControlProfile' -DefaultValue 'ManagedBrowserCompatibility' | Should -Be 'StrictApplicationAllowlist'
        Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'nonAdminAppControlMode' -DefaultValue 'AuditOnly' | Should -Be 'Enforced'
        Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'enableNonAdminAppControl' -DefaultValue $false | Should -BeTrue
        Get-OpenPathInstallerConfigValue -Config $config -PropertyName 'missingKey' -DefaultValue 'fallback' | Should -Be 'fallback'
    }

    It 'reads hashtable, property-object, and null configurations without regressing defaults' {
        . ([scriptblock]::Create($installerConfigValueFunction.Extent.Text))

        Get-OpenPathInstallerConfigValue -Config @{ appControlProfile = 'HashtableProfile' } -PropertyName 'appControlProfile' -DefaultValue 'x' | Should -Be 'HashtableProfile'
        Get-OpenPathInstallerConfigValue -Config ([pscustomobject]@{ appControlProfile = 'ObjectProfile' }) -PropertyName 'appControlProfile' -DefaultValue 'x' | Should -Be 'ObjectProfile'
        Get-OpenPathInstallerConfigValue -Config $null -PropertyName 'appControlProfile' -DefaultValue 'null-default' | Should -Be 'null-default'
    }

    It 'constructs strict config with an explicit empty catalog and pending boundary' {
        $config = New-OpenPathInstallerConfig -AgentVersion 'test' -PrimaryDNS '127.0.0.1' -EnforceManagedBrowserBoundary:$true -AppControlProfile StrictApplicationAllowlist
        $config.activeAppControlProfile | Should -Be 'none'
        $config.appControlCommitState | Should -Be 'pending'
        $config.installState | Should -Be 'installing'
        $config.approvedApplicationCatalog.schemaVersion | Should -Be 1
        @($config.approvedApplicationCatalog.applications).Count | Should -Be 0
    }

    It 'keeps compatibility catalog null when it was not supplied' {
        $config = New-OpenPathInstallerConfig -AgentVersion 'test' -PrimaryDNS '127.0.0.1'
        $null -eq $config.approvedApplicationCatalog | Should -BeTrue
        $config.appControlCommitState | Should -Be 'none'
    }

    It 'preserves an explicitly supplied catalog instead of using truthiness' {
        $catalog = [pscustomobject]@{ schemaVersion = 1; applications = @() }
        $config = New-OpenPathInstallerConfig -AgentVersion 'test' -PrimaryDNS '127.0.0.1' -AppControlProfile StrictApplicationAllowlist -ApprovedApplicationCatalog $catalog
        $config.approvedApplicationCatalog | Should -Be $catalog
    }

    It 'rejects a non-null invalid catalog' {
        { New-OpenPathInstallerConfig -AgentVersion 'test' -PrimaryDNS '127.0.0.1' -AppControlProfile StrictApplicationAllowlist -ApprovedApplicationCatalog ([pscustomobject]@{ applications = @() }) } | Should -Throw
        { New-OpenPathInstallerConfig -AgentVersion 'test' -PrimaryDNS '127.0.0.1' -AppControlProfile StrictApplicationAllowlist -ApprovedApplicationCatalog ([pscustomobject]@{ schemaVersion = 1; applications = 'not-a-collection' }) } | Should -Throw
    }

    It 'has one definition of each app-control parameter and key' {
        $path = Join-Path $PSScriptRoot '..' 'lib' 'install' 'Installer.Config.ps1'
        $content = Get-Content -LiteralPath $path -Raw
        ([regex]::Matches($content, '\[string\]\$AppControlProfile')).Count | Should -Be 1
        ([regex]::Matches($content, '\[object\]\$ApprovedApplicationCatalog')).Count | Should -Be 1
        ([regex]::Matches($content, '(?m)^\s*appControlProfile\s*=')).Count | Should -Be 1
        ([regex]::Matches($content, '(?m)^\s*approvedApplicationCatalog\s*=')).Count | Should -Be 1
    }

    It 'reports duplicate parameters and hash keys through the parser without executing the fixture' {
        $fixture = Join-Path $TestDrive 'duplicate-config.ps1'
        @'
function New-DuplicateConfig {
    param([string]$AppControlProfile, [string]$AppControlProfile)
    $config = @{ appControlProfile = 'one'; appControlProfile = 'two' }
    $config
}
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($fixture, [ref]$tokens, [ref]$parseErrors) | Out-Null
        @($parseErrors).Count | Should -BeGreaterThan 0
    }
}
