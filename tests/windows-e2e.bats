#!/usr/bin/env bats
################################################################################
# windows-e2e.bats - Guardrails for Windows E2E installation coverage
################################################################################

load 'test_helper'

@test "windows e2e runner invokes the real installer" {
    run grep -n "Install-OpenPath\.ps1" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -n -- "-WhitelistUrl" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -n -- "-Unattended" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]
}

@test "windows e2e workflow does not manufacture install state before runner" {
    run grep -n "name: Install Acrylic DNS Proxy" "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -ne 0 ]

    run grep -n "name: Prepare installation" "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -ne 0 ]

    run grep -n "name: Create test configuration" "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -ne 0 ]
}

@test "windows e2e workflow serializes destructive runner access" {
    run grep -nF "Acquire shared Windows runner lock" "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -eq 0 ]

    run grep -nF "Release shared Windows runner lock" "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -eq 0 ]

    run grep -nF "tests/e2e/ci/acquire-shared-windows-runner-lock.ps1" "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -eq 0 ]

    run grep -nF "tests/e2e/ci/release-shared-windows-runner-lock.ps1" "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -eq 0 ]

    run grep -nF "C:\\ProgramData\\OpenPathRunnerLocks\\destructive-openpath-windows" "$PROJECT_DIR/tests/e2e/ci/acquire-shared-windows-runner-lock.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer entrypoints stay ASCII-safe" {
    run grep -nP "[^\\x00-\\x7F]" "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -ne 0 ]

    run grep -nP "[^\\x00-\\x7F]" "$PROJECT_DIR/windows/Uninstall-OpenPath.ps1"
    [ "$status" -ne 0 ]

    run grep -nP "[^\\x00-\\x7F]" "$PROJECT_DIR/windows/scripts/Pre-Install-Validation.ps1"
    [ "$status" -ne 0 ]
}

@test "windows e2e accepts install-time whitelist bootstrap as best effort" {
    run grep -n "proceeding to explicit update validation" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -n "Installed whitelist file is missing after first update" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -ne 0 ]
}

@test "windows standalone bootstrap imports dependent modules globally for updater execution" {
    run grep -nF 'Import-Module "$OpenPathRoot\lib\Update.Runtime.psm1" -Force' "$PROJECT_DIR/windows/scripts/Update-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Invoke-OpenPathUpdateCycle -OpenPathRoot $OpenPathRoot' "$PROJECT_DIR/windows/scripts/Update-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force' "$PROJECT_DIR/windows/lib/Update.Runtime.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'Initialize-OpenPathScriptSession' "$PROJECT_DIR/windows/lib/Update.Runtime.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'Import-Module (Join-Path $OpenPathRoot "lib\$moduleName.psm1") -Force -Global' "$PROJECT_DIR/windows/lib/ScriptBootstrap.psm1"
    [ "$status" -eq 0 ]

    run grep -nF "Import-Module (Join-Path \$OpenPathRoot 'lib\Common.psm1') -Global" "$PROJECT_DIR/windows/lib/ScriptBootstrap.psm1"
    [ "$status" -eq 0 ]

    run grep -nF "'Update-AcrylicHost'" "$PROJECT_DIR/windows/lib/Update.Runtime.psm1"
    [ "$status" -eq 0 ]
}

@test "windows enrollment script uses standalone bootstrap before reconfiguration" {
    run grep -nF 'Import-Module "$OpenPathRoot\lib\ScriptBootstrap.psm1" -Force' "$PROJECT_DIR/windows/scripts/Enroll-Machine.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Initialize-OpenPathScriptSession' "$PROJECT_DIR/windows/scripts/Enroll-Machine.ps1"
    [ "$status" -eq 0 ]

    run grep -nF -- "-DependentModules @('Browser')" "$PROJECT_DIR/windows/scripts/Enroll-Machine.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'Get-OpenPathConfig'" "$PROJECT_DIR/windows/scripts/Enroll-Machine.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'Set-OpenPathConfigValue'" "$PROJECT_DIR/windows/scripts/Enroll-Machine.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'Register-OpenPathFirefoxNativeHost'" "$PROJECT_DIR/windows/scripts/Enroll-Machine.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer stages native host artifacts for later re-registration" {
    run grep -nF "NativeHost.ArtifactCatalog.ps1" "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Get-OpenPathNativeHostArtifactNames" "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Resolve-OpenPathNativeHostArtifactSources" "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'NativeHost.State.ps1'" "$PROJECT_DIR/windows/lib/internal/NativeHost.ArtifactCatalog.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'NativeHost.Protocol.ps1'" "$PROJECT_DIR/windows/lib/internal/NativeHost.ArtifactCatalog.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'NativeHost.Actions.ps1'" "$PROJECT_DIR/windows/lib/internal/NativeHost.ArtifactCatalog.ps1"
    [ "$status" -eq 0 ]
}

@test "windows native host prefers staged support libraries when running under Firefox" {
    run grep -nF 'function Resolve-OpenPathNativeHostRoot' "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'function Resolve-OpenPathNativeHostSupportPath' "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "\$stagedStateHelperPath = Join-Path \$script:NativeRoot 'NativeHost.State.ps1'" "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "\$script:OpenPathRoot = Resolve-OpenPathNativeHostRoot" "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Join-Path $script:NativeRoot $FileName' "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Join-Path $script:OpenPathRoot "lib\internal\$FileName"' "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF ". (Resolve-OpenPathNativeHostSupportPath -FileName 'NativeHost.State.ps1')" "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF ". (Resolve-OpenPathNativeHostSupportPath -FileName 'NativeHost.Protocol.ps1')" "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF ". (Resolve-OpenPathNativeHostSupportPath -FileName 'NativeHost.Actions.ps1')" "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Join-Path \$PSScriptRoot '..\lib\internal\NativeHost.State.ps1'" "$PROJECT_DIR/windows/scripts/OpenPath-NativeHost.ps1"
    [ "$status" -ne 0 ]
}

@test "windows cli re-imports Common globally before self-update commands" {
    run grep -nF 'Import-Module "$openPathRoot\lib\Common.psm1" -Force -Global' "$PROJECT_DIR/windows/OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'OpenPath.ps1 failed to import required common commands' "$PROJECT_DIR/windows/OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'Invoke-OpenPathAgentSelfUpdate'" "$PROJECT_DIR/windows/OpenPath.ps1"
    [ "$status" -eq 0 ]
}

@test "windows common module loads System.Net.Http before standalone downloads" {
    run grep -nF "Common.Http.ps1" "$PROJECT_DIR/windows/lib/Common.psm1"
    [ "$status" -eq 0 ]

    run grep -nF "Common.Http.Assembly.ps1" "$PROJECT_DIR/windows/lib/internal/Common.Http.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "function Ensure-OpenPathHttpAssembly" "$PROJECT_DIR/windows/lib/internal/Common.Http.Assembly.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Add-Type -AssemblyName 'System.Net.Http' -ErrorAction Stop" "$PROJECT_DIR/windows/lib/internal/Common.Http.Assembly.ps1"
    [ "$status" -eq 0 ]
}

@test "windows acrylic hosts generation stays split into settings, model, and render helpers" {
    run grep -nF 'DNS.Acrylic.Config.ps1' "$PROJECT_DIR/windows/lib/DNS.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'AcrylicHostsModel.ps1' "$PROJECT_DIR/windows/lib/DNS.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'AcrylicHostsRenderer.ps1' "$PROJECT_DIR/windows/lib/DNS.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'function Get-OpenPathDnsSettings' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'function Get-AcrylicForwardRules' "$PROJECT_DIR/windows/lib/internal/AcrylicHostsModel.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'function New-AcrylicHostsDefinition' "$PROJECT_DIR/windows/lib/internal/AcrylicHostsModel.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'function ConvertTo-AcrylicHostsContent' "$PROJECT_DIR/windows/lib/internal/AcrylicHostsRenderer.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$dnsSettings = Get-OpenPathDnsSettings' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$definition = New-AcrylicHostsDefinition' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$content = ConvertTo-AcrylicHostsContent -Definition $definition' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"FW $normalizedDomain"' "$PROJECT_DIR/windows/lib/internal/AcrylicHostsModel.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"FW >$normalizedDomain"' "$PROJECT_DIR/windows/lib/internal/AcrylicHostsModel.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$settings.PrimaryDNS = [string]$config.primaryDNS' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$settings.MaxDomains = [int]$config.maxDomains' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$content = @"' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -ne 0 ]

    run grep -nF 'NX >*' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -ne 0 ]
}

@test "windows dns validation retries acrylic readiness before failing" {
    run grep -nF 'DNS.Diagnostics.ps1' "$PROJECT_DIR/windows/lib/DNS.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'function Resolve-OpenPathDnsWithRetry' "$PROJECT_DIR/windows/lib/internal/DNS.Diagnostics.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"IgnoreNegativeResponsesFromPrimaryServer" = "No"' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"IgnoreNegativeResponsesFromSecondaryServer" = "No"' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"AddressCacheNegativeTime" = "0"' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"AddressCacheDisabled" = "No"' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"PrimaryServerDomainNameAffinityMask" = $configuredUpstreamMask' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '"SecondaryServerDomainNameAffinityMask" = $configuredUpstreamMask' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Config.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Start-Sleep -Milliseconds $DelayMilliseconds' "$PROJECT_DIR/windows/lib/internal/DNS.Diagnostics.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Resolve-OpenPathDnsWithRetry -Domain 'google.com' -MaxAttempts 20 -DelayMilliseconds 1500 -AttemptTimeoutSeconds 10" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "(Join-Path \$acrylicPath 'AcrylicConfiguration.ini')" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]
}

@test "windows e2e dumps Acrylic hit logs and per-record diagnostics on failure" {
    run grep -nF "function Set-AcrylicDiagnosticLogging" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'C:\OpenPath\data\logs\acrylic-hit.log'" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'HitLogFileWhat' = 'XHCFRU'" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "@('A', 'AAAA', 'HTTPS')" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "AcrylicService.exe version" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]
}

@test "windows e2e does not let best-effort Acrylic restore mask sinkhole assertions" {
    run grep -nF "function Restart-AcrylicServiceForE2E" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Restart-AcrylicServiceForE2E -Context 'applying sinkhole hosts' -Required" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Restart-AcrylicServiceForE2E -Context 'restoring sinkhole hosts' | Out-Null" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Stop-Service -Name 'AcrylicDNSProxySvc' -Force -ErrorAction Stop" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "WaitForStatus('Running', [TimeSpan]::FromSeconds(20))" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Acrylic service restart failed while \${Context}" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer keeps Acrylic on the modern portable release track" {
    run grep -nF '$installerVersion = "2.2.1"' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Install.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Acrylic/$installerVersion/Acrylic-Portable.zip/download' "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Install.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer re-registers provisioned Acrylic service before validation" {
    run grep -nF "function Ensure-AcrylicService" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Register-AcrylicServiceFromPath -AcrylicPath \$acrylicPath" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Ensure-AcrylicService -Start" "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'Ensure-AcrylicService'" "$PROJECT_DIR/windows/lib/DNS.psm1"
    [ "$status" -eq 0 ]
}

@test "windows acrylic service waits tolerate mocked service objects" {
    run grep -nF "function Wait-AcrylicServiceStatus" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Wait-AcrylicServiceStatus -Name \$service.Name -Status 'Running'" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "\$service.PSObject.Methods.Name -contains 'WaitForStatus'" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]
}

@test "windows acrylic service registration is bounded and verifies service registration" {
    run grep -nF "Start-Process -FilePath \$servicePath -ArgumentList '/INSTALL'" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Install.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "\$installProcess.WaitForExit(" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Install.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Stop-Process -Id \$installProcess.Id -Force" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Install.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "New-Service -Name 'AcrylicDNSProxySvc'" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Install.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "return (\$null -ne \$service)" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Install.ps1"
    [ "$status" -eq 0 ]
}

@test "windows DNS restore uses original adapter snapshot with reset fallback" {
    run grep -nF "return 'C:\OpenPath\data\original-dns.json'" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "[string]\$_.InterfaceGuid -eq [string]\$entry.InterfaceGuid" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Set-DnsClientServerAddress -InterfaceIndex \$adapterInterfaceIndex -ServerAddresses \$servers" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Set-DnsClientServerAddress -InterfaceIndex \$adapterInterfaceIndex -ResetServerAddresses" "$PROJECT_DIR/windows/lib/internal/DNS.Acrylic.Service.ps1"
    [ "$status" -eq 0 ]
}

@test "windows firewall does not install a global DNS port 53 block that overrides Acrylic" {
    run grep -nF 'OpenPath-DNS-Block-DNS-UDP' "$PROJECT_DIR/windows/lib/internal/Firewall.Policy.ps1"
    [ "$status" -ne 0 ]

    run grep -nF 'OpenPath-DNS-Block-DNS-TCP' "$PROJECT_DIR/windows/lib/internal/Firewall.Policy.ps1"
    [ "$status" -ne 0 ]

    run grep -nF 'Firewall.Policy.ps1' "$PROJECT_DIR/windows/lib/Firewall.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'DisplayName "$script:RulePrefix-Allow-$($target.Name)-$protocol"' "$PROJECT_DIR/windows/lib/internal/Firewall.Policy.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Block-Known-DNS-' "$PROJECT_DIR/windows/lib/internal/Firewall.Policy.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer validates direct DNS candidates before picking upstream" {
    run grep -nF 'function Test-InstallerDirectDnsServer' "$PROJECT_DIR/windows/lib/install/Installer.Dns.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'function Test-InstallerDisfavoredDnsServer' "$PROJECT_DIR/windows/lib/install/Installer.Dns.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'168.63.129.16'" "$PROJECT_DIR/windows/lib/install/Installer.Dns.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Resolve-DnsName -Name \$ProbeDomain -Server \$Server -DnsOnly -ErrorAction Stop" "$PROJECT_DIR/windows/lib/install/Installer.Dns.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "@('8.8.8.8', '1.1.1.1', '9.9.9.9', '8.8.4.4')" "$PROJECT_DIR/windows/lib/install/Installer.Dns.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "(@(\$preferredCandidates) + @(\$fallbackCandidates) + @(\$disfavoredCandidates))" "$PROJECT_DIR/windows/lib/install/Installer.Dns.ps1"
    [ "$status" -eq 0 ]
}

@test "windows enrollment bootstrap prefers one verified bundle download" {
    run grep -nF 'bootstrap/bundle.zip' "$PROJECT_DIR/api/src/services/enrollment-service-shared.ts"
    [ "$status" -eq 0 ]

    run grep -nF 'Expand-Archive -LiteralPath $bundlePath -DestinationPath $WindowsRoot -Force' "$PROJECT_DIR/api/src/services/enrollment-service-shared.ts"
    [ "$status" -eq 0 ]

    run grep -nF 'Checksum mismatch for Windows bootstrap bundle' "$PROJECT_DIR/api/src/services/enrollment-service-shared.ts"
    [ "$status" -eq 0 ]

    run grep -nF 'foreach ($file in $manifest.files)' "$PROJECT_DIR/api/src/services/enrollment-service-shared.ts"
    [ "$status" -eq 0 ]
}

@test "windows installer records optional phase timings" {
    run grep -nF '[string]$TimingOutputPath = ""' "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Invoke-OpenPathInstallTimedStep -Name' "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Save-OpenPathInstallTiming -Path $TimingOutputPath' "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer defaults to progress bar and fatal errors only" {
    run grep -nF 'function Write-InstallerError' "$PROJECT_DIR/windows/lib/install/Installer.Progress.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'function Write-InstallerWarning' "$PROJECT_DIR/windows/lib/install/Installer.Progress.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'function Write-InstallerNotice' "$PROJECT_DIR/windows/lib/install/Installer.Progress.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Write-Host "Progress ${Step}/${Total}: $Status"' "$PROJECT_DIR/windows/lib/install/Installer.Progress.ps1"
    [ "$status" -ne 0 ]
}

@test "windows installer avoids pre-enrollment native host registration in classroom mode" {
    run grep -nF "Register-OpenPathFirefoxNativeHost -Config \$config -ClearWhitelist" "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -ne 0 ]

    run grep -nF "Register-OpenPathFirefoxNativeHost -Config \$nativeHostConfig -ClearWhitelist" "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]
}

@test "windows preflight treats missing active adapter enumeration as advisory" {
    run grep -nF '} -FailMessage "No active network adapter found" -Warning' "$PROJECT_DIR/windows/scripts/Pre-Install-Validation.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Test-Requirement "DNS resolution working"' "$PROJECT_DIR/windows/scripts/Pre-Install-Validation.ps1"
    [ "$status" -eq 0 ]
}

@test "windows pester e2e receives whitelist domains from the harness and keeps file fallback" {
    run grep -nF 'OPENPATH_E2E_EXPECTED_WHITELIST_DOMAINS' "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'OPENPATH_E2E_EXPECTED_WHITELIST_DOMAINS' "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Get-ValidWhitelistDomainsFromFile -Path \$whitelistPath" "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "function Resolve-OpenPathDnsWithRetry" "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$result = Resolve-OpenPathDnsWithRetry -Domain $domains[0]' "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "At least one adapter points DNS to 127.0.0.1" "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "function Test-InstalledDnsProxyResolution" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -n 'Can resolve google.com via system DNS' "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -ne 0 ]
}

@test "windows pester e2e creates scheduled task with a service principal" {
    run grep -nF "New-ScheduledTaskPrincipal -UserId 'SYSTEM'" "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF -- "-LogonType ServiceAccount" "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF -- "-Principal \$principal" "$PROJECT_DIR/tests/e2e/Windows-E2E.Tests.ps1"
    [ "$status" -eq 0 ]
}

@test "windows e2e cleanup preserves self-hosted runner Acrylic provisioning" {
    run grep -nF "function Get-OpenPathUninstallArgs" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "\$env:RUNNER_ENVIRONMENT -eq 'self-hosted'" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'-KeepAcrylic'" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "function Get-OpenPathUninstallArgs" "$PROJECT_DIR/tests/e2e/ci/run-windows-student-flow.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "'-KeepAcrylic'" "$PROJECT_DIR/tests/e2e/ci/run-windows-student-flow.ps1"
    [ "$status" -eq 0 ]
}

@test "windows uninstaller stops live OpenPath tasks before removing install root" {
    run grep -nF 'Stop-ScheduledTask -TaskName $task.TaskName' "$PROJECT_DIR/windows/Uninstall-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Stop-OpenPathRootedProcess' "$PROJECT_DIR/windows/Uninstall-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$_.Path.StartsWith($OpenPathRoot, [System.StringComparison]::OrdinalIgnoreCase)' "$PROJECT_DIR/windows/Uninstall-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$_.CommandLine -like "*$OpenPathRoot*"' "$PROJECT_DIR/windows/Uninstall-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Remove-OpenPathInstallRoot' "$PROJECT_DIR/windows/Uninstall-OpenPath.ps1"
    [ "$status" -eq 0 ]
}

@test "windows lifecycle e2e covers agent self-update and uninstall verification" {
    run grep -nF "Testing installed agent self-update against the local server..." "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "OpenPath.ps1' self-update" "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Verifying Windows uninstallation removes installed state..." "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]

    run grep -nF "Expected scheduled task '\$taskName' still exists after uninstall." "$PROJECT_DIR/tests/e2e/ci/run-windows-e2e.ps1"
    [ "$status" -eq 0 ]
}
