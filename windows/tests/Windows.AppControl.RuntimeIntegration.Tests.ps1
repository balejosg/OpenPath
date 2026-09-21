Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.psm1') -Force -Global
if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Set-AppLockerPolicy { param($XMLPolicy, $ErrorAction) } }
if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Get-AppLockerPolicy { param([switch]$Local, [switch]$Effective, [switch]$Xml, $ErrorAction); '<AppLockerPolicy Version="1" />' } }
if (-not (Get-Command Test-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Test-AppLockerPolicy { param($XmlPolicy, $Packages, $User, $ErrorAction); @([pscustomobject]@{ PolicyDecision = 'Allowed' }) } }
if (-not (Get-Command Get-AppLockerFileInformation -ErrorAction SilentlyContinue)) { function global:Get-AppLockerFileInformation { param($Packages, $Path, $ErrorAction); [pscustomobject]@{ AppX = $true; Publisher = [pscustomobject]@{ PublisherName = 'CN=Runtime'; ProductName = 'Runtime'; BinaryName = '*' } } } }
if (-not (Get-Command Start-Service -ErrorAction SilentlyContinue)) { function global:Start-Service { param($Name, $ErrorAction) } }
if (-not (Get-Command Set-Service -ErrorAction SilentlyContinue)) { function global:Set-Service { param($Name, $StartupType, $ErrorAction) } }

Describe 'AppControl public runtime integration' {
    BeforeAll {
        # Re-establish the public module and platform command shims after the
        # heavyweight AppControl leaf has reloaded/removes its dependencies.
        Import-Module (Join-Path $PSScriptRoot '..\lib\AppControl.psm1') -Force -Global -ErrorAction Stop
        if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Set-AppLockerPolicy { param($XMLPolicy, $ErrorAction) } }
        if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Get-AppLockerPolicy { param([switch]$Local, [switch]$Effective, [switch]$Xml, $ErrorAction); '<AppLockerPolicy Version="1" />' } }
        if (-not (Get-Command Test-AppLockerPolicy -ErrorAction SilentlyContinue)) { function global:Test-AppLockerPolicy { param($XmlPolicy, $Packages, $User, $ErrorAction); @([pscustomobject]@{ PolicyDecision = 'Allowed' }) } }
        if (-not (Get-Command Get-AppLockerFileInformation -ErrorAction SilentlyContinue)) { function global:Get-AppLockerFileInformation { param($Packages, $Path, $ErrorAction); [pscustomobject]@{ AppX = $true; Publisher = [pscustomobject]@{ PublisherName = 'CN=Runtime'; ProductName = 'Runtime'; BinaryName = '*' } } } }
        if (-not (Get-Command Start-Service -ErrorAction SilentlyContinue)) { function global:Start-Service { param($Name, $ErrorAction) } }
        if (-not (Get-Command Set-Service -ErrorAction SilentlyContinue)) { function global:Set-Service { param($Name, $StartupType, $ErrorAction) } }
    }

    It 'fails closed before Set-AppLockerPolicy when strict installed intent is absent' {
        InModuleScope AppControl {
            Mock Set-AppLockerPolicy {}
            Mock Test-AdminPrivileges { $true }
            Mock Test-OpenPathAppControlAvailable { $true }
            $result = Set-OpenPathNonAdminAppControl -OpenPathRoot $TestDrive -Profile StrictApplicationAllowlist -ApplicationCatalog ([pscustomobject]@{ schemaVersion = 1; applications = @() }) -Confirm:$false
            $result | Should -BeFalse
            Should -Invoke Set-AppLockerPolicy -Times 0 -Exactly
        }
    }

    It 'uses runtime discovery and transaction before the public mutation boundary' {
        InModuleScope AppControl {
            $data = Join-Path $TestDrive 'data'
            New-Item -ItemType Directory -Path $data -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $data 'config.json'), (@{
                        appControlProfile = 'StrictApplicationAllowlist'
                        nonAdminAppControlMode = 'Enforced'
                        appControlCommitState = 'pending'
                        activeAppControlProfile = 'none'
                    } | ConvertTo-Json))
            $trace = [System.Collections.Generic.List[string]]::new()
            $native = [pscustomobject]@{ AppX = $true; Publisher = [pscustomobject]@{ PublisherName = 'CN=Runtime'; ProductName = 'Runtime'; BinaryName = '*' } }
            $baseline = [pscustomobject]@{ SchemaVersion = 2; Status = 'Complete'; Packages = @([pscustomobject]@{ Name = 'Runtime'; PublisherName = 'CN=Runtime'; ProductName = 'Runtime'; BinaryName = '*'; AppX = $true }); NativeAppLockerPackages = @($native); CanonicalSha256 = ('a' * 64) }
            Mock Test-AdminPrivileges { $true }
            Mock Test-OpenPathAppControlAvailable { $true }
            Mock Get-AppLockerPolicy { '<AppLockerPolicy Version="1" />' }
            Mock Get-OpenPathWindowsRuntimeBaseline { $trace.Add('runtime'); $baseline }
            Mock Test-OpenPathWindowsRuntimeBaseline { $true }
            Mock New-OpenPathNonAdminAppLockerPolicySpec { $trace.Add('spec'); [pscustomobject]@{ Profile = 'StrictApplicationAllowlist'; Mode = 'Enforced'; BrowserInventory = $null } }
            Mock New-OpenPathAppLockerPolicyXml { '<AppLockerPolicy Version="1" />' }
            Mock Merge-OpenPathAppLockerPolicyXml { [xml]'<AppLockerPolicy Version="1" />' }
            Mock Test-OpenPathAppLockerBoundaryPolicy { $true }
            Mock Get-OpenPathAppControlProbeTarget { [pscustomobject]@{ UserSid = 'S-1-5-21-1'; GroupSid = 'S-1-5-32-545'; ProfileAvailable = $false; ProfilePath = ''; ValidationMode = 'test' } }
            Mock Invoke-OpenPathAppLockerPackageEvaluation { $trace.Add('evaluator'); @([pscustomobject]@{ PolicyDecision = 'Allowed' }) }
            Mock Set-OpenPathAppIdentityServiceAutomatic {}
            Mock Start-Service {}
            Mock Test-OpenPathAppIdentityServiceRunning { $true }
            Mock Invoke-OpenPathAppControlPolicyConverterActivation { [pscustomobject]@{ status = 'observed' } }
            Mock Test-OpenPathNonAdminAppControlActive { $trace.Add('health'); $true }
            Mock Set-AppLockerPolicy { $trace.Add('set') }
            Mock Write-OpenPathLog {}
            $result = Set-OpenPathNonAdminAppControl -OpenPathRoot $TestDrive -Profile StrictApplicationAllowlist -ApplicationCatalog ([pscustomobject]@{ schemaVersion = 1; applications = @() }) -Confirm:$false
            $result | Should -BeTrue
            $trace | Should -Be @('runtime', 'spec', 'evaluator', 'set', 'health')
            Should -Invoke Get-OpenPathWindowsRuntimeBaseline -Times 1 -Exactly
            Should -Invoke Invoke-OpenPathAppLockerPackageEvaluation -Times 1 -Exactly
            Should -Invoke Set-AppLockerPolicy -Times 1 -Exactly
            $stateFile = Get-ChildItem -LiteralPath (Join-Path $TestDrive 'data/appcontrol-transactions') -Filter state.json -File -Recurse | Select-Object -First 1
            $state = Get-Content -LiteralPath $stateFile.FullName -Raw | ConvertFrom-Json
            $state.State | Should -Be 'committed'
            Test-Path -LiteralPath $state.Candidate -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $data 'config.json') -Raw | ConvertFrom-Json).appControlCommitState | Should -Be 'committed'
        }
    }

    It 'requires explicit Allowed for native runtime package evaluation' {
        InModuleScope AppControl {
            $policy = '<AppLockerPolicy Version="1" />'
            $native = [pscustomobject]@{
                Name = 'Runtime'
                PackageFullName = 'Runtime_1.0.0.0_x64__abc'
                Publisher = 'CN=Runtime'
            }
            Mock Test-AppLockerPolicy { @([pscustomobject]@{ PolicyDecision = 'AllowedByDefault' }) }
            { Invoke-OpenPathAppLockerPackageEvaluation -PolicyXml $policy -Packages @($native) -UserSid 'S-1-5-21-1' } | Should -Throw 'appcontrol_windows_runtime_probe_failed'
            Mock Test-AppLockerPolicy { @([pscustomobject]@{ PolicyDecision = 'Allowed' }) }
            $decision = @(Invoke-OpenPathAppLockerPackageEvaluation -PolicyXml $policy -Packages @($native) -UserSid 'S-1-5-21-1')
            $decision.Count | Should -Be 1
            $decision[0].PolicyDecision | Should -Be 'Allowed'
            $decision[0].Expected | Should -Be 'Allowed'
        }
    }

    It 'rejects FileInformation inputs and accepts policy-denied runtime packages' {
        InModuleScope AppControl {
            $fileInformation = [pscustomobject]@{
                AppX = $true
                Publisher = [pscustomobject]@{ PublisherName = 'CN=Runtime'; ProductName = 'Runtime'; BinaryName = '*' }
            }
            { Invoke-OpenPathAppLockerPackageEvaluation -PolicyXml '<AppLockerPolicy Version="1" />' -Packages @($fileInformation) -UserSid 'S-1-5-21-1' } | Should -Throw 'appcontrol_windows_runtime_probe_failed'

            $policy = @'
<AppLockerPolicy Version="1">
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <FilePublisherRule Id="00000000-0000-0000-0000-000000000001" Name="deny devtools" Description="deny" UserOrGroupSid="S-1-5-32-545" Action="Deny">
      <Conditions><FilePublisherCondition PublisherName="*" ProductName="Microsoft.MicrosoftEdgeDevToolsClient" BinaryName="*" /></Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="00000000-0000-0000-0000-000000000002" Name="allow runtime" Description="allow" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePublisherCondition PublisherName="CN=Runtime" ProductName="Microsoft.MicrosoftEdgeDevToolsClient" BinaryName="APPX"><BinaryVersionRange LowSection="0.0.0.0" HighSection="*" /></FilePublisherCondition></Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
'@
            $deniedPackage = [pscustomobject]@{
                Name = 'Microsoft.MicrosoftEdgeDevToolsClient'
                PackageFullName = 'Microsoft.MicrosoftEdgeDevToolsClient_1.0.0.0_x64__abc'
                Publisher = 'CN=Microsoft Windows'
            }
            Mock Test-AppLockerPolicy { @([pscustomobject]@{ PolicyDecision = 'Denied' }) }
            $decision = @(Invoke-OpenPathAppLockerPackageEvaluation -PolicyXml $policy -Packages @($deniedPackage) -UserSid 'S-1-5-21-1')
            $decision.Count | Should -Be 1
            $decision[0].Expected | Should -Be 'Denied'
            $decision[0].PolicyDecision | Should -Be 'Denied'
        }
    }

    It 'validates runtime policies without non-Appx publisher collections' {
        InModuleScope AppControl {
            $package = [pscustomobject]@{ Name = 'ShellExperienceHost'; PublisherName = 'CN=Microsoft Windows'; ProductName = 'ShellExperienceHost'; BinaryName = 'APPX' }
            $baseline = [pscustomobject]@{ SchemaVersion = 2; Status = 'passed'; OS = [pscustomobject]@{ ProductType = 'client'; Edition = 'Pro'; Build = '26100'; Architecture = 'x64' }; Packages = @($package); Dependencies = @(); BaseHash = ('a' * 64) }
            Mock Test-OpenPathWindowsRuntimeBaseline { $true }
            $policy = @'
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="00000000-0000-0000-0000-000000000010" Name="exe" Description="exe" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <FilePublisherRule Id="00000000-0000-0000-0000-000000000011" Name="runtime" Description="runtime" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePublisherCondition PublisherName="CN=Microsoft Windows" ProductName="ShellExperienceHost" BinaryName="APPX"><BinaryVersionRange LowSection="0.0.0.0" HighSection="*" /></FilePublisherCondition></Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
'@
            (Test-OpenPathWindowsRuntimePolicy -WindowsRuntimeBaseline $baseline -PolicyXml ([xml]$policy)) | Should -BeTrue
            (Test-OpenPathWindowsRuntimePolicy -WindowsRuntimeBaseline $baseline -PolicyXml ([xml]'<AppLockerPolicy Version="1"><RuleCollection Type="Exe" EnforcementMode="Enabled" /></AppLockerPolicy>')) | Should -BeFalse
        }
    }

    It 'rolls back when Set-AppLockerPolicy mutates then throws after apply-attempted' {
        InModuleScope AppControl {
            $root = Join-Path $TestDrive 'partial-apply'
            $diagnosticPath = Join-Path $root 'diagnostic.json'
            New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'data/config.json'), (@{
                        appControlProfile = 'ManagedBrowserCompatibility'
                        nonAdminAppControlMode = 'Enforced'
                        appControlCommitState = 'none'
                        activeAppControlProfile = 'none'
                    } | ConvertTo-Json))
            $script:setCalls = 0
            Mock Test-AdminPrivileges { $true }
            Mock Test-OpenPathAppControlAvailable { $true }
            Mock Get-AppLockerPolicy { '<AppLockerPolicy Version="1" />' }
            Mock New-OpenPathNonAdminAppLockerPolicySpec { [pscustomobject]@{ Profile = 'ManagedBrowserCompatibility'; Mode = 'Enforced'; BrowserInventory = $null } }
            Mock New-OpenPathAppLockerPolicyXml { '<AppLockerPolicy Version="1" />' }
            Mock Merge-OpenPathAppLockerPolicyXml { [xml]'<AppLockerPolicy Version="1" />' }
            Mock Test-OpenPathAppLockerBoundaryPolicy { $true }
            Mock Set-AppLockerPolicy {
                $script:setCalls++
                if ($script:setCalls -eq 1) { throw 'injected partial policy mutation' }
            }
            Mock Write-OpenPathLog {}
            $result = Set-OpenPathNonAdminAppControl -OpenPathRoot $root -DiagnosticStatusPath $diagnosticPath -Confirm:$false
            $result | Should -BeFalse
            $script:setCalls | Should -Be 2
            $diagnostic = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json
            $diagnostic.Substep | Should -Be 'policy-apply'
            $diagnostic.InternalRollbackAttempted | Should -BeTrue
            $diagnostic.InternalRollbackSucceeded | Should -BeTrue
        }
    }
}
