import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, test } from 'node:test';
import { projectRoot, readJson, readPackageJson, readText } from './support.mjs';
import { selectWindowsStudentPolicySseGroupWithReason } from '../../scripts/select-windows-student-policy-sse-group.mjs';

describe('repository verification contract', () => {
  test('selenium CI scripts use cross-platform environment setup', () => {
    const seleniumPackage = readJson('tests/selenium/package.json');

    assert.equal(
      seleniumPackage.scripts['test:student-policy:ci'],
      'npx ts-node student-policy-flow.e2e.ts'
    );
    assert.equal(seleniumPackage.scripts['test:ci'], 'npx ts-node firefox-extension.e2e.ts');
  });

  test('student policy selenium entrypoint keeps the local Firefox UUID helper boundary', () => {
    const studentPolicyScript = readText('tests/selenium/student-policy-flow.e2e.ts');

    assert.match(
      studentPolicyScript,
      /from '\.\/firefox-extension-uuid';/,
      'student-policy-flow.e2e.ts should import the Firefox UUID helper from the local selenium package'
    );
    assert.ok(
      !studentPolicyScript.includes('../e2e/student-flow/firefox-extension-uuid'),
      'student-policy-flow.e2e.ts should not import the Firefox UUID helper from tests/e2e'
    );
    assert.ok(
      existsSync(resolve(projectRoot, 'tests/selenium/firefox-extension-uuid.ts')),
      'tests/selenium/firefox-extension-uuid.ts should exist alongside the student policy entrypoint'
    );
    assert.ok(
      existsSync(resolve(projectRoot, 'tests/selenium/firefox-extension-uuid.test.ts')),
      'tests/selenium/firefox-extension-uuid.test.ts should cover the colocated helper'
    );
  });

  test('student policy runners provision selenium package dependencies before execution', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');
    const linuxStudentDockerfile = readText('tests/e2e/Dockerfile.student');

    assert.match(
      windowsRunner,
      /Push-Location \(Join-Path \$script:RepoRoot 'tests\\selenium'\)[\s\S]*npm ci --prefer-offline --no-audit --fund=false \| Out-Host/,
      'Windows student-policy runner should install tests/selenium dependencies from its lockfile before running the suite'
    );
    assert.ok(
      existsSync(resolve(projectRoot, 'tests/selenium/package-lock.json')),
      'tests/selenium/package-lock.json should exist so the Windows runner can use npm ci'
    );
    assert.match(
      linuxStudentDockerfile,
      /COPY tests\/selenium\/package\.json \.\/tests\/selenium\/package\.json[\s\S]*RUN cd \/openpath\/tests\/selenium && npm install/,
      'Linux student-policy image should copy the Selenium package manifests and install its dependencies'
    );
  });

  test('Windows student-policy runner validates SSE group and uploads scenario timings', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /OPENPATH_WINDOWS_STUDENT_SSE_GROUP/,
      'Windows student-policy runner should read the selected SSE scenario group from the workflow environment'
    );
    assert.match(
      windowsRunner,
      /ValidateSet\('full', 'request-lifecycle', 'path-blocking', 'exemptions'\)/,
      'Windows student-policy runner should reject unknown SSE scenario groups'
    );
    assert.match(
      windowsRunner,
      /OPENPATH_STUDENT_DIAGNOSTICS_DIR/,
      'Windows student-policy runner should write Selenium scenario timings into the uploaded artifact directory'
    );
    assert.match(
      windowsRunner,
      /Run Selenium student suite \(sse, \$windowsStudentSseCoverageProfile, \$windowsStudentSseGroup\)/,
      'Windows student-policy timings should include the selected SSE group'
    );
  });

  test('Windows SSE update cycles avoid redundant protected-mode restores', () => {
    const windowsRuntime = readText('windows/lib/Update.Runtime.psm1');

    assert.match(
      windowsRuntime,
      /function Invoke-OpenPathStartupLocalReconcile[\s\S]*\[switch\]\$SkipProtectedModeRestore[\s\S]*Test-OpenPathCaptivePortalModeActive[\s\S]*Invoke-OpenPathCaptivePortalImmediateReconcile[\s\S]*if \(\$SkipProtectedModeRestore\) \{[\s\S]*ProtectedModeRestoreSkipped[\s\S]*Restore-OpenPathProtectedMode -Config \$Config/s,
      'SSE updates should still reconcile an active captive portal before skipping the protected-mode restore'
    );
    assert.match(
      windowsRuntime,
      /Invoke-OpenPathStartupLocalReconcile[\s\S]*-SkipProtectedModeRestore:\(\$TriggerSource -eq 'SSE'\)[\s\S]*Get-OpenPathWhitelistDownloadResult/s,
      'SSE-triggered updates should skip the pre-download protected-mode restore that reconfigures Windows Firewall'
    );
  });

  test('Windows student-policy SSE selector explains narrow and full routing decisions', () => {
    const narrow = selectWindowsStudentPolicySseGroupWithReason([
      'firefox-extension/src/lib/path-blocking.ts',
      'firefox-extension/src/lib/background-path-rules.ts',
    ]);
    assert.equal(narrow.group, 'path-blocking');
    assert.match(
      narrow.reason,
      /matched narrow SSE group 'path-blocking'/,
      'narrow SSE routing should explain the selected group'
    );

    const forcedFull = selectWindowsStudentPolicySseGroupWithReason(['windows/install.ps1']);
    assert.equal(forcedFull.group, 'full');
    assert.match(
      forcedFull.reason,
      /windows\/install\.ps1.*requires full SSE coverage/,
      'Windows runtime changes should explain why full target-platform coverage is required'
    );

    const mixedFull = selectWindowsStudentPolicySseGroupWithReason([
      'firefox-extension/src/lib/path-blocking.ts',
      'api/src/services/request-command-requests.service.ts',
    ]);
    assert.equal(mixedFull.group, 'full');
    assert.match(
      mixedFull.reason,
      /multiple narrow SSE groups matched: path-blocking, request-lifecycle/,
      'mixed narrow families should explain why they fall back to full coverage'
    );
  });

  test('student policy selenium sources stay compatible with their ts-node target', () => {
    const seleniumSources = [
      'tests/selenium/student-policy-client.ts',
      'tests/selenium/student-policy-driver-browser.ts',
      'tests/selenium/student-policy-driver-platform.ts',
      'tests/selenium/student-policy-driver-runtime.ts',
      'tests/selenium/student-policy-driver-state.ts',
      'tests/selenium/student-policy-driver.ts',
      'tests/selenium/student-policy-env.ts',
      'tests/selenium/student-policy-flow.e2e.ts',
      'tests/selenium/student-policy-harness.ts',
      'tests/selenium/student-policy-scenarios.ts',
      'tests/selenium/student-policy-types.ts',
    ];

    for (const sourcePath of seleniumSources) {
      assert.ok(
        !readText(sourcePath).includes('.at('),
        `${sourcePath} should not use Array.prototype.at because the CI ts-node package target does not expose it`
      );
    }
  });

  test('student policy blocked-path scenarios refresh extension rules after forced updates', () => {
    const scenarios = readText('tests/selenium/student-policy-scenarios.ts');

    assert.match(
      scenarios,
      /SP-011 verify main-frame path block[\s\S]*refreshBlockedPaths: true/,
      'blocked-path convergence should refresh extension rules after a forced local update'
    );
    const unblockSegment = scenarios.slice(
      scenarios.indexOf('deleteGroupRule(rule.id'),
      scenarios.indexOf('async function runTemporaryExemptionScenarios')
    );
    assert.match(
      unblockSegment,
      /SP-015 verify path unblock[\s\S]*refreshBlockedPaths: true/,
      'blocked-path unblock convergence should refresh extension rules after deleting the rule'
    );
  });

  test('student policy request lifecycle settles native blocking before blocked-page submission', () => {
    const scenarios = readText('tests/selenium/student-policy-scenarios.ts');

    assert.match(
      scenarios,
      /async function settleBlockedRequestTarget[\s\S]*await driver\.assertDnsBlocked\(targets\.hosts\.request\);[\s\S]*await driver\.assertHttpBlocked\(targets\.requestDomainUrl\);/,
      'request lifecycle preflight should wait for both DNS and HTTP blocking before browser submission'
    );

    const lifecycleStart = scenarios.indexOf('async function runRequestLifecycleScenarioSet');
    const lifecycleSegment = scenarios.slice(
      lifecycleStart,
      scenarios.indexOf('const pending = await client.findPendingRequestByDomain', lifecycleStart)
    );
    assert.match(
      lifecycleSegment,
      /await settleBlockedRequestTarget\(driver, mode, targets\);[\s\S]*openBlockedScreenAndSubmitRequest/,
      'SP-001 should settle native blocking before opening the blocked-page request form'
    );

    const fallbackStart = scenarios.indexOf('export async function runFallbackPropagationProbe');
    const fallbackSegment = scenarios.slice(
      fallbackStart,
      scenarios.indexOf('const pending = await client.findPendingRequestByDomain', fallbackStart)
    );
    assert.match(
      fallbackSegment,
      /await settleBlockedRequestTarget\(driver, mode, targets\);[\s\S]*openBlockedScreenAndSubmitRequest/,
      'fallback propagation should settle native blocking before opening the blocked-page request form'
    );
  });

  test('windows student policy runner packages the Firefox XPI with the canonical build script', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /build-xpi\.sh/,
      'Windows student-policy runner should use firefox-extension/build-xpi.sh to create the Selenium XPI'
    );
    assert.ok(
      !windowsRunner.includes('Compress-Archive'),
      'Windows student-policy runner should not package the Selenium XPI with Compress-Archive'
    );
  });

  test('student policy runners record Firefox XPI SHA-256 after packaging', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      linuxRunner,
      /sha256sum "\$built_xpi_path"[\s\S]*Firefox XPI hash sha256=/,
      'Linux student-policy runner should record the packaged Firefox XPI SHA-256'
    );
    assert.match(
      linuxRunner,
      /firefox-xpi-sha256\.txt/,
      'Linux student-policy runner should persist the Firefox XPI hash in diagnostics artifacts'
    );
    assert.match(
      windowsRunner,
      /Get-FileHash -Algorithm SHA256[\s\S]*Firefox XPI hash sha256=/,
      'Windows student-policy runner should record the packaged Firefox XPI SHA-256'
    );
    assert.match(
      windowsRunner,
      /firefox-xpi-sha256\.txt/,
      'Windows student-policy runner should persist the Firefox XPI hash in diagnostics artifacts'
    );
  });

  test('student policy runners use Turbo-backed Firefox extension build while preserving prebuild cleanup', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');
    const extensionPackage = readJson('firefox-extension/package.json');

    assert.equal(
      extensionPackage.scripts['build:cached'],
      'npm run prebuild && npx turbo run build --filter=@openpath/firefox-extension',
      'Firefox extension cached build should clean first, then let Turbo restore or build outputs'
    );
    assert.match(
      linuxRunner,
      /npm run build:cached --workspace=@openpath\/firefox-extension/,
      'Linux student-policy runner should use the Turbo-backed Firefox extension build script'
    );
    assert.match(
      windowsRunner,
      /npm run build:cached --workspace=@openpath\/firefox-extension/,
      'Windows student-policy runner should use the Turbo-backed Firefox extension build script'
    );
  });

  test('Linux student policy runner uses signed release artifacts only when available', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /build-xpi\.sh/,
      'Linux student-policy runner should use firefox-extension/build-xpi.sh to create the E2E XPI'
    );
    assert.doesNotMatch(
      linuxRunner,
      /build:firefox-release/,
      'Linux student-policy runner should not send unsigned E2E XPIs through the signed release artifact builder'
    );
    assert.match(
      linuxRunner,
      /OPENPATH_FIREFOX_RELEASE_ROOT="\$PROJECT_ROOT\/firefox-extension\/build\/firefox-release"/,
      'Linux student-policy API should read Firefox release artifacts from the repo build output'
    );
    assert.match(
      linuxRunner,
      /run_timed_step "Build workspaces" prepare_workspace[\s\S]*run_timed_step "Start API server" start_api_server/,
      'Linux student-policy runner should prepare Firefox release artifacts before the API can serve openpath.xpi'
    );
  });

  test('student policy runners propagate optional narrow scenario groups', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      linuxRunner,
      /OPENPATH_STUDENT_SCENARIO_GROUP/,
      'Linux student-policy runner should read the optional scenario group'
    );
    assert.match(
      linuxRunner,
      /docker_env_args[\s\S]*OPENPATH_STUDENT_SCENARIO_GROUP/,
      'Linux student-policy runner should pass OPENPATH_STUDENT_SCENARIO_GROUP into docker exec only when set'
    );
    assert.match(
      linuxRunner,
      /Scenario group: \$\{STUDENT_SCENARIO_GROUP:-full\}/,
      'Linux student-policy summary should include the selected scenario group'
    );

    assert.match(
      windowsRunner,
      /\[ValidateSet\('full', 'request-lifecycle', 'path-blocking', 'exemptions'\)\]\[string\]\$ScenarioGroup = 'full'/,
      'Windows student-policy runner should accept an optional ScenarioGroup parameter'
    );
    assert.match(
      windowsRunner,
      /\$originalScenarioGroup = \$env:OPENPATH_STUDENT_SCENARIO_GROUP[\s\S]*OPENPATH_STUDENT_SCENARIO_GROUP = \$ScenarioGroup[\s\S]*originalScenarioGroup/,
      'Windows student-policy runner should snapshot and restore OPENPATH_STUDENT_SCENARIO_GROUP'
    );
    assert.match(
      windowsRunner,
      /scenarioGroup=\$ScenarioGroup/,
      'Windows student-policy trace should include the selected scenario group'
    );
  });

  test('windows student policy runner enables Firefox unsigned addon support for Selenium', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /xpinstall\.signatures\.required/,
      'Windows student-policy runner should disable Firefox addon signature enforcement for the Selenium browser'
    );
    assert.match(
      windowsRunner,
      /extensions\.blocklist\.enabled/,
      'Windows student-policy runner should disable the Firefox extension blocklist for the Selenium browser'
    );
    assert.match(
      windowsRunner,
      /Write-Utf8NoBomLfFile -Path \$autoconfigPath/,
      'Windows student-policy runner should write Firefox autoconfig.js with the LF-only helper'
    );
  });

  test('windows student policy runner requires unsigned-addons-capable Firefox before Selenium', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /function Get-FirefoxBinaryPath/,
      'Windows student-policy runner should resolve a usable Firefox binary through one helper'
    );
    assert.match(
      windowsRunner,
      /choco install firefox-nightly --pre --no-progress -y/,
      'Windows student-policy runner should still prefer Firefox Nightly when no Firefox binary exists'
    );
    assert.match(
      windowsRunner,
      /choco install firefox-dev --pre --no-progress -y/,
      'Windows student-policy runner should try Firefox Developer Edition when Nightly provisioning is unavailable'
    );
    assert.match(
      windowsRunner,
      /Trying Firefox Developer Edition because Nightly is unavailable\./,
      'Windows student-policy runner should verify the Nightly binary exists instead of trusting the Chocolatey exit code'
    );
    assert.match(
      windowsRunner,
      /Only Firefox Release was found/,
      'Windows student-policy runner should reject Release-only runners because unsigned Selenium XPIs will not load'
    );
    assert.ok(
      !windowsRunner.includes('choco install firefox --no-progress -y'),
      'Windows student-policy runner should not fall back to Firefox Release for unsigned extension tests'
    );
    assert.match(
      windowsRunner,
      /ProgramFiles\(x86\)/,
      'Windows student-policy runner should resolve Firefox across both 64-bit and 32-bit install roots'
    );
    assert.match(
      windowsRunner,
      /LOCALAPPDATA/,
      'Windows student-policy runner should also resolve Firefox from per-user install roots'
    );
    assert.match(
      windowsRunner,
      /OPENPATH_FIREFOX_BINARY/,
      'Windows student-policy runner should honor an explicit Firefox binary override when provided'
    );
    assert.match(
      windowsRunner,
      /Test-Path \$overridePath -PathType Leaf/,
      'Windows student-policy runner should require OPENPATH_FIREFOX_BINARY to point to a Firefox executable file'
    );
    assert.match(
      windowsRunner,
      /GetFileName\(\$overridePath\) -ieq 'firefox\.exe'/,
      'Windows student-policy runner should validate that OPENPATH_FIREFOX_BINARY targets firefox.exe'
    );
  });

  test('linux student policy image uses unsigned-addons-capable Firefox for Selenium', () => {
    const linuxStudentDockerfile = readText('tests/e2e/Dockerfile.student');

    assert.match(
      linuxStudentDockerfile,
      /firefox-devedition-latest-ssl/,
      'Linux student-policy image should use Firefox Developer Edition because Selenium loads the unsigned E2E XPI when signed release artifacts are unavailable'
    );
    assert.ok(
      !linuxStudentDockerfile.includes('FIREFOX_VERSION='),
      'Linux student-policy image should not pin Firefox Release/ESR for unsigned extension tests'
    );
    assert.ok(
      !linuxStudentDockerfile.includes('/pub/firefox/releases/'),
      'Linux student-policy image should not download Firefox Release/ESR builds for unsigned extension tests'
    );
    assert.match(
      linuxStudentDockerfile,
      /xz-utils/,
      'Linux student-policy image should install xz-utils so Firefox Developer Edition tar.xz archives can be extracted'
    );
  });

  test('student policy selenium driver supports overriding the Firefox binary path', () => {
    const studentPolicyDriver = readText('tests/selenium/student-policy-driver.ts');

    assert.match(
      studentPolicyDriver,
      /firefoxBinaryPath\?: string;/,
      'student-policy-driver.ts should expose a Firefox binary override'
    );
    assert.match(
      studentPolicyDriver,
      /OPENPATH_FIREFOX_BINARY/,
      'student-policy-driver.ts should read the Firefox binary override from OPENPATH_FIREFOX_BINARY'
    );
    assert.match(
      studentPolicyDriver,
      /options\.setBinary\(this\.firefoxBinaryPath\)/,
      'student-policy-driver.ts should pass the configured Firefox binary path into selenium-webdriver'
    );
  });

  test('student policy selenium driver enables unsigned Firefox XPIs for CI profiles', () => {
    const studentPolicyDriver = readText('tests/selenium/student-policy-driver.ts');

    assert.match(
      studentPolicyDriver,
      /options\.setPreference\('xpinstall\.signatures\.required', false\)/,
      'student-policy-driver.ts should disable Firefox signature enforcement for the unsigned Selenium XPI'
    );
    assert.match(
      studentPolicyDriver,
      /options\.setPreference\('extensions\.blocklist\.enabled', false\)/,
      'student-policy-driver.ts should disable the Firefox blocklist for the unsigned Selenium XPI'
    );
  });

  test('student policy selenium driver disables Firefox DoH for DNS policy assertions', () => {
    const studentPolicyDriver = readText('tests/selenium/student-policy-driver.ts');

    assert.match(
      studentPolicyDriver,
      /options\.setPreference\('network\.trr\.mode', 5\)/,
      'student-policy-driver.ts should force Firefox to use native DNS so Selenium cannot bypass local dnsmasq policy'
    );
    assert.match(
      studentPolicyDriver,
      /options\.setPreference\('network\.trr\.uri', ''\)/,
      'student-policy-driver.ts should clear the Firefox TRR URI in Selenium profiles'
    );
    assert.match(
      studentPolicyDriver,
      /options\.setPreference\('network\.dnsCacheExpiration', 0\)/,
      'student-policy-driver.ts should disable Firefox DNS cache so policy changes converge in the same browser session'
    );
    assert.match(
      studentPolicyDriver,
      /options\.setPreference\('network\.dnsCacheExpirationGracePeriod', 0\)/,
      'student-policy-driver.ts should disable Firefox DNS cache grace period for policy-change tests'
    );
    assert.match(
      studentPolicyDriver,
      /pageLoad: DEFAULT_BLOCKED_TIMEOUT_MS/,
      'student-policy-driver.ts should bound page-load waits for sinkhole-blocked navigations'
    );
  });

  test('student policy Linux HTTP probes use bounded curl timeouts', () => {
    const platformDriver = readText('tests/selenium/student-policy-driver-platform.ts');

    assert.match(
      platformDriver,
      /curl -fsS --connect-timeout 3 --max-time 5/,
      'student-policy-driver-platform.ts should bound Linux curl probes so sinkhole routes cannot hang CI'
    );
  });

  test('windows student policy runner restores Firefox unsigned addon support changes during cleanup', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /function Restore-FirefoxUnsignedAddonSupport/,
      'Windows student-policy runner should define a cleanup routine for Firefox unsigned addon support'
    );
    assert.match(
      windowsRunner,
      /finally\s*\{[\s\S]*?Restore-FirefoxUnsignedAddonSupport/,
      'Windows student-policy runner should invoke the Firefox unsigned addon cleanup routine'
    );
  });

  test('windows student policy runner preserves caller Firefox overrides across Selenium phases', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /\$originalFirefoxBinary = \$env:OPENPATH_FIREFOX_BINARY/,
      'Windows student-policy runner should snapshot any caller-provided Firefox binary override before running Selenium'
    );
    assert.match(
      windowsRunner,
      /if \(\$null -ne \$originalFirefoxBinary\) \{[\s\S]*?\$env:OPENPATH_FIREFOX_BINARY = \$originalFirefoxBinary[\s\S]*?\}\s*else \{[\s\S]*?Remove-Item Env:\\OPENPATH_FIREFOX_BINARY/s,
      'Windows student-policy runner should restore the caller Firefox binary override after each Selenium phase'
    );
  });

  test('windows student policy runner resolves the Firefox binary once before changing directories', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /\$script:FirefoxBinaryPath = \$null/,
      'Windows student-policy runner should cache the resolved Firefox binary path across phases'
    );
    assert.match(
      windowsRunner,
      /if \(\$script:FirefoxBinaryPath\) \{\s*return \$script:FirefoxBinaryPath\s*\}/,
      'Windows student-policy runner should reuse the cached Firefox binary path instead of re-resolving it after Push-Location'
    );
  });

  test('windows student policy runner isolates Firefox config restore failures per file', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /try \{\s*Restore-FirefoxConfigFile -Snapshot \$script:FirefoxUnsignedAddonSupportState\.Autoconfig[\s\S]*?catch \{/,
      'Windows student-policy runner should isolate autoconfig restore failures so later cleanup still runs'
    );
    assert.match(
      windowsRunner,
      /try \{\s*Restore-FirefoxConfigFile -Snapshot \$script:FirefoxUnsignedAddonSupportState\.MozillaCfg[\s\S]*?catch \{/,
      'Windows student-policy runner should isolate mozilla.cfg restore failures so both files are attempted'
    );
  });

  test('windows student policy runner preserves the primary test failure when cleanup also fails', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /\$script:PrimaryFailure = \$null/,
      'Windows student-policy runner should track the primary failure separately from cleanup failures'
    );
    assert.match(
      windowsRunner,
      /\$script:PrimaryFailure = \$_/,
      'Windows student-policy runner should capture the primary failure in the catch block'
    );
    assert.match(
      windowsRunner,
      /if \(\(\$null -ne \$cleanupError\) -and \(\$null -eq \$script:PrimaryFailure\)\) \{[\s\S]*?throw \$cleanupError/s,
      'Windows student-policy runner should only surface cleanup errors when there is no earlier test failure to preserve'
    );
  });

  test('windows student policy runner explicitly tears down OpenPath during cleanup', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');
    const cleanupBlock = windowsRunner.slice(windowsRunner.lastIndexOf('finally {'));

    assert.ok(
      existsSync(resolve(projectRoot, 'windows/Uninstall-OpenPath.ps1')),
      'windows/Uninstall-OpenPath.ps1 should exist for the Windows student-policy cleanup path'
    );
    assert.match(
      windowsRunner,
      /function Get-OpenPathUninstallArgs \{[\s\S]*?Join-Path \$script:RepoRoot 'windows\\Uninstall-OpenPath\.ps1'[\s\S]*?\$env:RUNNER_ENVIRONMENT -eq 'self-hosted'[\s\S]*?'-KeepAcrylic'[\s\S]*?\}/,
      'Windows student-policy runner should build cleanup arguments for windows/Uninstall-OpenPath.ps1 and keep Acrylic on self-hosted runners'
    );
    assert.match(
      cleanupBlock,
      /\$uninstallArgs = Get-OpenPathUninstallArgs[\s\S]*?& powershell\.exe @uninstallArgs/,
      'Windows student-policy runner should invoke windows/Uninstall-OpenPath.ps1 through the cleanup argument helper'
    );
    assert.match(
      cleanupBlock,
      /if \(\$LASTEXITCODE -ne 0\) \{[\s\S]*?Uninstall-OpenPath\.ps1 failed with exit code \$LASTEXITCODE/s,
      'Windows student-policy runner should fail cleanup when Uninstall-OpenPath.ps1 exits non-zero'
    );
    assert.match(
      cleanupBlock,
      /try \{[\s\S]*?\$uninstallArgs = Get-OpenPathUninstallArgs[\s\S]*?& powershell\.exe @uninstallArgs[\s\S]*?catch \{\s*\$cleanupError = \$_\s*\}/s,
      'Windows student-policy runner should isolate uninstall failures so later cleanup still runs'
    );
    assert.match(
      cleanupBlock,
      /try \{[\s\S]*?Get-OpenPathUninstallArgs[\s\S]*?catch \{\s*\$cleanupError = \$_\s*\}[\s\S]*?try \{[\s\S]*?Restore-FirefoxUnsignedAddonSupport[\s\S]*?catch \{[\s\S]*?if \(\$null -eq \$cleanupError\)[\s\S]*?\$cleanupError = \$_[\s\S]*?\}[\s\S]*?try \{[\s\S]*?Stop-BackgroundJobs[\s\S]*?catch \{[\s\S]*?if \(\$null -eq \$cleanupError\)[\s\S]*?\$cleanupError = \$_[\s\S]*?\}[\s\S]*?try \{[\s\S]*?Cleanup-TestPostgres[\s\S]*?catch \{[\s\S]*?if \(\$null -eq \$cleanupError\)[\s\S]*?\$cleanupError = \$_/s,
      'Windows student-policy runner should isolate uninstall cleanup first, then continue Firefox, background job, and Postgres cleanup in order'
    );
  });

  test('windows student policy runner only reports success after cleanup completes', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /\$script:RunSucceeded = \$false/,
      'Windows student-policy runner should track whether the main execution path reached success before cleanup'
    );
    assert.match(
      windowsRunner,
      /finally\s*\{[\s\S]*?if \(\(\$script:RunSucceeded\) -and \(\$null -eq \$cleanupError\) -and \(\$null -eq \$script:PrimaryFailure\)\) \{[\s\S]*?Publish-GitHubStepSummary -Mode 'success'[\s\S]*?Windows student-policy runner completed successfully/s,
      'Windows student-policy runner should publish success only after cleanup succeeds'
    );
  });

  test('windows student policy runner emits per-phase timing evidence', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /function Invoke-TimedStep/,
      'Windows student-policy runner should centralize per-phase timing'
    );
    assert.match(
      windowsRunner,
      /windows-student-policy-timings\.json/,
      'Windows student-policy runner should write timing evidence into diagnostics artifacts'
    );
    assert.match(
      windowsRunner,
      /Windows Student Policy Timing/,
      'Windows student-policy runner should publish timing evidence in the GitHub step summary'
    );
    assert.match(
      windowsRunner,
      /::group::\$Name/,
      'Windows student-policy runner should group each timed phase in GitHub Actions logs'
    );
    assert.match(
      windowsRunner,
      /::endgroup::/,
      'Windows student-policy runner should close each GitHub Actions timing group even on failure'
    );
    assert.match(
      windowsRunner,
      /::notice title=Windows Student Policy Timing::/,
      'Windows student-policy runner should emit a searchable GitHub notice for every timed phase'
    );
    for (const phase of [
      'Build workspaces',
      'Install Selenium dependencies',
      'Ensure test PostgreSQL',
      'Initialize test database',
      'Start API server',
      'Start fixture server',
      'Package Firefox extension',
      'Ensure Firefox and geckodriver',
      'Run Selenium student suite (fallback, fallback-propagation)',
    ]) {
      assert.ok(
        windowsRunner.includes(`Invoke-TimedStep -Name '${phase}'`),
        `Windows student-policy runner should time phase: ${phase}`
      );
    }
    assert.match(
      windowsRunner,
      /Invoke-TimedStep -Name "Run Selenium student suite \(sse, \$windowsStudentSseCoverageProfile, \$windowsStudentSseGroup\)"/,
      'Windows student-policy runner should time the selected SSE group'
    );
  });

  test('windows student policy runner keeps full SSE coverage and narrows fallback to propagation proof', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');
    const seleniumScenarios = readText('tests/selenium/student-policy-scenarios.ts');
    const harness = readText('tests/selenium/student-policy-harness.ts');

    assert.match(
      windowsRunner,
      /param\([\s\S]*\[ValidateSet\('full', 'fallback-propagation', 'dns-discovery-spike', 'dns-evidence-matrix', 'dns-evidence-matrix-v2', 'browser-dependency-observability-spike'\)\]\[string\]\$CoverageProfile/s,
      'Windows student-policy runner should pass an explicit Selenium coverage profile per mode'
    );
    assert.match(
      windowsRunner,
      /\$windowsStudentSseCoverageProfile = if \(\[string\]::IsNullOrWhiteSpace\(\$env:OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE\)\) \{[\s\S]*'full'[\s\S]*\}[\s\S]*Run Selenium student suite \(sse, \$windowsStudentSseCoverageProfile, \$windowsStudentSseGroup\)[\s\S]*Invoke-SeleniumStudentSuite[\s\S]*-Mode 'sse'[\s\S]*-CoverageProfile \$windowsStudentSseCoverageProfile[\s\S]*-ScenarioGroup \$windowsStudentSseGroup/s,
      'Windows student-policy runner should keep full coverage as default while allowing explicit diagnostic SSE profiles'
    );
    assert.match(
      windowsRunner,
      /Run Selenium student suite \(fallback, fallback-propagation\)[\s\S]*Invoke-SeleniumStudentSuite[\s\S]*-Mode 'fallback'[\s\S]*-CoverageProfile 'fallback-propagation'/s,
      'Windows student-policy runner should run fallback as a targeted propagation proof'
    );
    assert.match(
      windowsRunner,
      /\$timeoutMinutes = if \(\(\$Mode -eq 'sse'\) -and \(\$CoverageProfile -eq 'full'\) -and \(\$ScenarioGroup -eq 'full'\)\) \{[\s\S]*35[\s\S]*\$process\.WaitForExit\(\$timeoutMs\)/s,
      'Windows student-policy full SSE should use an explicit timeout budget larger than the historical 20 minute default'
    );
    assert.match(
      windowsRunner,
      /\$env:OPENPATH_STUDENT_COVERAGE_PROFILE = \$CoverageProfile/,
      'Windows student-policy runner should expose the selected profile to the Selenium harness'
    );
    assert.match(
      seleniumScenarios,
      /export async function runFallbackPropagationProbe/,
      'Selenium scenarios should expose a dedicated fallback propagation probe'
    );
    assert.match(
      seleniumScenarios,
      /evaluateBlockedPathDebug\(\s*targets\.sitePrivateUrl,\s*'main_frame'\s*\)[\s\S]*blockedPathOutcome\.redirectUrl[\s\S]*blocked\\.html/,
      'Fallback propagation probe should prove main-frame blocked paths through the blocked-page redirect outcome'
    );
    assert.match(
      seleniumScenarios,
      /finally \{[\s\S]*deleteGroupRule\(rule\.id, driver\.scenario\.groups\.restricted\.id\);[\s\S]*try \{[\s\S]*driver\.forceLocalUpdate\(\);[\s\S]*fallback blocked-path cleanup update error/s,
      'Fallback propagation cleanup should not fail the proof after deleting the API rule'
    );
    assert.match(
      seleniumScenarios,
      /catch \(forceError\) \{[\s\S]*await runAssertion\(\);[\s\S]*forced policy update failed after convergence completed[\s\S]*throw forceError/s,
      'SSE policy settling should tolerate a failed forced update only when the target policy state has already converged'
    );
    assert.match(
      windowsRunner,
      /'C:\\OpenPath\\lib\\internal\\Firewall\.State\.ps1'[\s\S]*'C:\\OpenPath\\lib\\Update\.Runtime\.psm1'/,
      'Windows student-policy diagnostics should capture the installed runtime modules involved in forced policy updates'
    );
    assert.match(
      harness,
      /fallback-propagation[\s\S]*runFallbackPropagationProbe/s,
      'Selenium harness should map the fallback-propagation profile to the targeted probe'
    );
  });

  test('Windows browser enforcement phase keeps explicit opt-in probes and docs contract', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');
    const browserProbe = readText('tests/e2e/ci/windows-browser-enforcement.ps1');
    const browserBoundaryCi = readText('tests/e2e/ci/run-windows-browser-boundary-ci.ps1');
    const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');
    const contractMatrix = readText('docs/testing/student-policy-contract-matrix.md');
    const windowsReadme = readText('windows/README.md');

    assert.match(
      windowsRunner,
      /param\([\s\S]*\[switch\]\$RunBrowserEnforcementProbes/s,
      'Windows student-policy runner should expose browser enforcement probes as an explicit opt-in switch'
    );
    assert.match(
      windowsRunner,
      /OPENPATH_WINDOWS_BROWSER_ENFORCEMENT_PROBES/,
      'Windows student-policy runner should also allow an explicit environment opt-in for browser enforcement probes'
    );
    assert.match(
      windowsRunner,
      /if \(\$RunBrowserEnforcementProbes -or \$env:OPENPATH_WINDOWS_BROWSER_ENFORCEMENT_PROBES -eq '1'\) \{\s*Invoke-TimedStep -Name 'Run Windows browser enforcement probes'/,
      'Windows browser enforcement probes should not run unconditionally in the normal student-policy lane'
    );
    assert.match(
      windowsRunner,
      /OPENPATH_KEEP_CLIENT_FOR_BROWSER_BOUNDARY/,
      'Windows student-policy runner should be able to keep the installed client until browser-boundary CI runs'
    );
    assert.match(
      windowsRunner,
      /Install-OpenPath\.ps1'[\s\S]*-EnforceManagedBrowserBoundary[\s\S]*-Unattended/s,
      'Windows student-policy flow should install with the managed browser AppLocker boundary enabled'
    );
    assert.match(
      windowsRunner,
      /\$process\.Refresh\(\)[\s\S]*if \(\$null -eq \$exitCode\) \{[\s\S]*\$exitCode = 0/s,
      'Windows student-policy process helper should avoid Start-Process ExitCode gaps under LocalSystem'
    );
    assert.match(
      windowsRunner,
      /Quote-Argument -Value \$script:PostgresDataDir[\s\S]*Quote-Argument -Value \$script:PostgresLogPath[\s\S]*Quote-Argument -Value "-p \$\(\$script:PostgresPort\)"/s,
      'Windows student-policy pg_ctl arguments should preserve grouped values for Start-Process'
    );

    assert.match(
      e2eWorkflow,
      /OPENPATH_KEEP_CLIENT_FOR_BROWSER_BOUNDARY: '1'[\s\S]*Run Windows browser boundary probes[\s\S]*run-windows-browser-boundary-ci\.ps1[\s\S]*Restore self-hosted Windows runner state/s,
      'Windows student-policy CI should run browser-boundary probes after the student-policy flow and before runner restore'
    );
    assert.match(
      e2eWorkflow,
      /path: tests\/e2e\/artifacts\/windows-student-policy/,
      'Windows student-policy artifacts should include browser-boundary diagnostics'
    );

    for (const marker of [
      'Firefox managed path blocks known blocked path',
      'Edge Google game URL cannot run as student',
      'Brave cannot start',
      'Opera cannot start',
      'Vivaldi cannot start',
      'Tor cannot start',
      'Portable browser from Downloads cannot start',
      'Portable browser from Desktop cannot start',
      'PowerShell script from Downloads cannot execute',
      'Batch file from Downloads cannot execute',
      'copied into user-writable path cannot execute if present',
      'Google search game result is blocked',
      '1.1.1.1 DoH-by-IP cannot resolve blocked host',
      'curl --resolve Cloudflare bypass command fails',
      'Admin can run management tools',
      'Admin can inspect policies',
      'Admin can recover OpenPath',
      'AppLocker admin allow-all remains intact',
    ]) {
      assert.ok(
        browserProbe.includes(marker),
        `Windows browser enforcement probe should cover: ${marker}`
      );
    }
    assert.match(
      browserProbe,
      /\$probeName = "\$\(\$browser\.Name\) only if managed and blocks known blocked path"/,
      'Windows browser enforcement probe should cover Edge and Chrome managed blocked-path probes'
    );
    assert.match(
      browserProbe,
      /MissingGoogleBlocks/,
      'Chromium management detection should require every maintained Google game block pattern'
    );

    assert.match(
      browserProbe,
      /\[switch\]\$ExecuteProbes/,
      'Windows browser enforcement probe should require an explicit execution flag before launching processes or network commands'
    );
    assert.match(
      browserProbe,
      /\[switch\]\$PrepareProbeFiles/,
      'Windows browser enforcement probe should require an explicit flag before creating probe files'
    );
    assert.match(
      browserBoundaryCi,
      /Assert-InstalledOpenPathBrowserBoundaryAppControl[\s\S]*Set-OpenPathNonAdminAppControl[\s\S]*OpenPath AppControl boundary is still inactive after reapply/s,
      'browser-boundary CI should reassert the installed AppControl boundary before creating the temporary student user'
    );
    assert.match(
      browserBoundaryCi,
      /AppLockerPolicy[\s\S]*S-1-5-32-544[\s\S]*administrator allow-all rule is missing/s,
      'browser-boundary CI should fail before student probes if the admin AppLocker allow-all rule is missing'
    );
    assert.match(
      browserBoundaryCi,
      /New-LocalUser[\s\S]*Invoke-StudentBoundaryTask[\s\S]*-Scope Admin/s,
      'browser-boundary CI should run student probes through a temporary standard user and admin probes with the current token'
    );
    assert.match(
      browserBoundaryCi,
      /-Scope'', ''Student''/,
      'browser-boundary CI scheduled task should run the student probe scope'
    );
    assert.match(
      browserBoundaryCi,
      /student-exit-code\.txt[\s\S]*windows-browser-enforcement-report\.json[\s\S]*Invoke-ReportAssertNoFailures/s,
      'browser-boundary CI should accept a validated student report as completion evidence when the scheduled-task exit marker is missing'
    );
    assert.match(
      browserBoundaryCi,
      /Edge Google game URL cannot run as student[\s\S]*browser-boundary-summary\.json/s,
      'browser-boundary CI should require the Edge Google game URL student probe and summarize artifacts'
    );
    assert.match(
      browserProbe,
      /Phase 1, Phase 3, and Phase 4 are committed/,
      'Windows browser enforcement report should preserve the prerequisite warning'
    );

    assert.match(
      contractMatrix,
      /Windows browser-boundary[\s\S]*target-platform symptom cleared/,
      'Student policy contract matrix should include the Windows browser-boundary evidence rung'
    );
    assert.match(
      windowsReadme,
      /Phase 1[\s\S]*Phase 3[\s\S]*Phase 4[\s\S]*Do not claim the Windows browser-boundary target-platform\s+symptom cleared/s,
      'Windows README should document prerequisites and forbid partial target-platform cleared claims'
    );
    assert.match(
      windowsReadme,
      /reset runner[\s\S]*snapshot VM[\s\S]*rollback VM/s,
      'Windows README should document the reversible runner lab flow'
    );
  });

  test('Firefox approval-max removes the Google game student-policy SSE gate', () => {
    const workflow = readText('.github/workflows/e2e-tests.yml');
    const selector = readText('scripts/select-windows-student-policy-sse-group.mjs');
    const seleniumEnv = readText('tests/selenium/student-policy-env.ts');
    const seleniumHarness = readText('tests/selenium/student-policy-harness.ts');
    const seleniumScenarios = readText('tests/selenium/student-policy-scenarios.ts');
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.doesNotMatch(
      workflow,
      /student_policy_sse_group:[\s\S]*- google-game-blocking/,
      'manual Windows student-policy diagnostics should not expose the removed Firefox Google-game suite'
    );
    assert.doesNotMatch(
      selector,
      /WINDOWS_STUDENT_POLICY_SSE_GROUPS[\s\S]*'google-game-blocking'/,
      'changed-path selector should not route to the removed Firefox Google-game suite'
    );
    assert.doesNotMatch(
      selector,
      /google-(?:search-)?game/,
      'extension Google-game guard files should not be mapped to a narrow SSE group'
    );
    assert.doesNotMatch(
      seleniumEnv,
      /group === 'google-game-blocking'/,
      'Selenium environment validation should reject the removed Google-game group'
    );
    assert.doesNotMatch(
      seleniumHarness,
      /runGoogleGameBlockingScenarios/,
      'Selenium harness should not route the removed Google-game scenario'
    );
    assert.doesNotMatch(
      seleniumScenarios,
      /https:\/\/www\.google\.com\/fbx\?fbx=snake_arcade/,
      'Selenium scenario should not open the removed Google Snake probe'
    );
    assert.doesNotMatch(
      seleniumScenarios,
      /GOOGLE_GAME_POLICY:/,
      'Selenium scenario should not require removed Firefox Google-game diagnostics'
    );
    assert.match(
      windowsRunner,
      /Run Selenium student suite \(sse, \$windowsStudentSseCoverageProfile, \$windowsStudentSseGroup\)/,
      'Windows student-policy should keep the selected group inside the hard Selenium gate'
    );
  });

  test('Chromium managed policy includes direct Google game URL blocks', () => {
    const chromiumContract = readJson('tests/contracts/browser-chromium-policy.json');
    const windowsBrowserModule = readText('windows/lib/Browser.psm1');
    const readinessModule = readText('windows/lib/Browser.RequestReadiness.psm1');

    assert.deepEqual(chromiumContract.googleGameBlocks, [
      '*://www.google.*/fbx?fbx=snake_arcade*',
      '*://doodles.google/*',
      '*://*.doodles.google/*',
      '*://www.google.*/logos/*',
    ]);
    assert.match(
      windowsBrowserModule,
      /foreach \(\$googleGameBlock in @\(\$chromiumSpec\.googleGameBlocks\)\)/,
      'Set-ChromePolicy should write every maintained Google game block pattern'
    );
    assert.match(
      readinessModule,
      /Get-OpenPathGoogleGameBlockPatterns/,
      'Browser readiness should validate the maintained Google game block patterns'
    );
  });

  test('Linux student policy runner emits per-phase timing evidence', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /run_timed_step\(\)/,
      'Linux student-policy runner should centralize per-phase timing'
    );
    assert.match(
      linuxRunner,
      /linux-student-policy-timings\.json/,
      'Linux student-policy runner should write timing evidence into diagnostics artifacts'
    );
    assert.match(
      linuxRunner,
      /Linux Student Policy Timing/,
      'Linux student-policy runner should publish timing evidence in the GitHub step summary'
    );
    for (const phase of [
      'Build workspaces',
      'Ensure test PostgreSQL',
      'Initialize test database',
      'Start API server',
      'Run Selenium student suite (sse)',
      'Run Selenium student suite (fallback, fallback-propagation)',
    ]) {
      assert.ok(
        linuxRunner.includes(`run_timed_step "${phase}"`),
        `Linux student-policy runner should time phase: ${phase}`
      );
    }
  });

  test('Linux student policy runner keeps full SSE coverage and narrows fallback to propagation proof', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /run_student_suite\(\)[\s\S]*local coverage_profile=/,
      'Linux student-policy runner should pass an explicit Selenium coverage profile per mode'
    );
    assert.match(
      linuxRunner,
      /Run Selenium student suite \(sse\)[\s\S]*run_student_suite sse full/,
      'Linux student-policy runner should keep the SSE pass on the full Selenium matrix'
    );
    assert.match(
      linuxRunner,
      /Run Selenium student suite \(fallback, fallback-propagation\)[\s\S]*run_student_suite fallback fallback-propagation/,
      'Linux student-policy runner should run fallback as a targeted propagation proof'
    );
    assert.match(
      linuxRunner,
      /-e OPENPATH_STUDENT_COVERAGE_PROFILE="\$coverage_profile"/,
      'Linux student-policy runner should expose the selected profile to the Selenium harness'
    );
  });

  test('Linux student policy image build uses buildx cache with a docker build fallback', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');
    const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');

    assert.match(
      linuxRunner,
      /docker buildx build[\s\S]*--cache-from type=gha[\s\S]*--cache-to type=gha,mode=max[\s\S]*--load/,
      'Linux student-policy image build should use GitHub Actions cache when buildx is available'
    );
    assert.match(
      linuxRunner,
      /docker build -f "\$_context_dir\/Dockerfile\.student" -t "\$IMAGE_TAG" "\$_context_dir"/,
      'Linux student-policy image build should keep a plain docker build fallback'
    );
    assert.match(
      e2eWorkflow,
      /docker\/setup-buildx-action@v[0-9]+/,
      'E2E workflow should provision buildx before Linux student-policy Docker cache is used'
    );
  });

  test('student policy Selenium harness writes per-scenario timing evidence', () => {
    const harness = readText('tests/selenium/student-policy-harness.ts');
    const scenarios = readText('tests/selenium/student-policy-scenarios.ts');

    assert.match(
      scenarios,
      /student-policy-scenario-timings\.json/,
      'Selenium scenarios should write a per-scenario timing artifact'
    );
    assert.match(
      harness,
      /writeStudentPolicyScenarioTimings\(diagnosticsDir\)/,
      'Selenium harness should flush per-scenario timing evidence after every run'
    );
  });

  test('Linux student policy SP-006 writes a no-auto-allow observation boundary artifact', () => {
    const scenarios = readText('tests/selenium/student-policy-scenarios.ts');
    const helper = readText('tests/selenium/linux-auto-allow-diagnostics.ts');

    assert.match(
      helper,
      /linux-auto-allow-boundary\.json/,
      'Linux auto-allow helper should own the diagnostic artifact filename'
    );
    assert.match(
      helper,
      /firefox-extension-ready[\s\S]*origin-page-load[\s\S]*page-observer[\s\S]*page-resource-candidates[\s\S]*no-automatic-rule-creation[\s\S]*explicit-whitelist-apply[\s\S]*explicit-probe-traffic[\s\S]*artifact-written/,
      'Linux auto-allow helper should expose the no-auto-allow observation phase contract'
    );
    assert.doesNotMatch(
      helper,
      /remote-rule-creation|local-whitelist-apply/,
      'SP-006 diagnostics must not require automatic rule creation as the success contract'
    );
    assert.match(
      helper,
      /id: 'fetch' \| 'xhr' \| 'image' \| 'script' \| 'stylesheet' \| 'font'/,
      'Linux auto-allow helper should expose every functional probe in the artifact contract'
    );
    assert.match(
      scenarios,
      /writeLinuxAutoAllowBoundaryArtifact/,
      'SP-006 should write the Linux auto-allow boundary artifact from the Selenium harness'
    );
    assert.match(
      scenarios,
      /ajaxDependencyFontUrl[\s\S]*font\.woff2[\s\S]*diagnosticId: 'font'/,
      'SP-006 should cover font subresources in the Linux boundary artifact'
    );
    assert.match(
      scenarios,
      /no-automatic-rule-creation[\s\S]*fetchMachineWhitelist\(\)/,
      'SP-006 diagnostics should prove observed dependencies are not automatically published remotely'
    );
    assert.match(
      scenarios,
      /no-automatic-rule-creation[\s\S]*assertWhitelistMissing/,
      'SP-006 diagnostics should prove observed dependencies are not automatically applied locally'
    );
    assert.match(
      helper,
      /linux-runtime-dependency-apply\.json/,
      'Linux runtime dependency apply should use a separate artifact from the SP-006 observation boundary'
    );
    assert.match(
      scenarios,
      /SP-LINUX-RUNTIME-DEPENDENCY-APPLY[\s\S]*assertDnsAllowed[\s\S]*assert\.doesNotMatch/,
      'Linux runtime dependency apply should prove local DNS overlay without remote whitelist mutation'
    );
    assert.match(
      scenarios,
      /explicit-whitelist-apply[\s\S]*ensureWhitelistRule/,
      'SP-006 should validate explicit allowlist application after observation'
    );
    assert.match(
      scenarios,
      /__openpathPageResourceObserverState/,
      'SP-006 should inspect observer state, not only observer installation'
    );
    assert.match(
      scenarios,
      /lastNotification[\s\S]*probe\.url/,
      'SP-006 should prove the probed async dependency emitted a page-resource candidate'
    );
  });

  test('Linux student policy runner highlights readiness failures in GitHub summaries', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /linux-dns-readiness\.err\.log/,
      'Linux student-policy runner should persist DNS readiness failures for artifact and summary parsing'
    );
    assert.match(
      linuxRunner,
      /linux-firefox-readiness\.err\.log/,
      'Linux student-policy runner should persist Firefox readiness failures for artifact and summary parsing'
    );
    assert.match(
      linuxRunner,
      /GITHUB_STEP_SUMMARY[\s\S]*Readiness failures/,
      'Linux student-policy runner should add readiness failures to the GitHub step summary'
    );
    assert.match(
      linuxRunner,
      /Artifacts:[\s\S]*linux-student-policy-timings\.json[\s\S]*linux-dns-readiness\.err\.log[\s\S]*linux-firefox-readiness\.err\.log/,
      'Linux student-policy runner should name the timing and readiness artifacts in the GitHub step summary'
    );
    assert.match(
      linuxRunner,
      /No readiness failures captured\./,
      'Linux student-policy runner should make successful readiness explicit in the GitHub step summary'
    );
    assert.match(
      linuxRunner,
      /on_error\(\)[\s\S]*publish_github_step_summary "failure"/,
      'Linux student-policy runner should publish the diagnostic summary before exiting on failure'
    );
  });

  test('Linux student policy runner surfaces the auto-allow boundary artifact', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');
    const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');

    assert.match(
      linuxRunner,
      /linux-auto-allow-boundary\.json/,
      'Linux student-policy runner should mention the boundary artifact in summaries'
    );
    assert.match(
      linuxRunner,
      /OPENPATH_STUDENT_ARTIFACTS_DIR/,
      'Linux student-policy runner should keep honoring an external artifact directory'
    );
    assert.match(
      e2eWorkflow,
      /Upload Linux student-policy diagnostics[\s\S]*tests\/e2e\/artifacts\/linux-student-policy/,
      'E2E workflow should upload the Linux student-policy artifact directory'
    );
  });

  test('windows DNS renderer separates host blocking from upstream affinity wildcards', () => {
    const dnsModule = readText('windows/lib/DNS.psm1');
    const dnsConfigModule = readText('windows/lib/internal/DNS.Acrylic.Config.ps1');
    const acrylicHostsModel = readText('windows/lib/internal/AcrylicHostsModel.ps1');

    assert.match(
      dnsModule,
      /DNS\.Acrylic\.Config\.ps1/,
      'windows/lib/DNS.psm1 should load the internal Acrylic DNS config module'
    );
    assert.match(
      acrylicHostsModel,
      /function Get-AcrylicForwardRules/,
      'AcrylicHostsModel.ps1 should keep Acrylic wildcard forward generation in a dedicated helper'
    );
    assert.match(
      acrylicHostsModel,
      /Get-AcrylicForwardRules -Domain \$domain -BlockedSubdomains \$BlockedSubdomains/,
      'New-AcrylicHostsDefinition should pass blocked subdomains into wildcard forward generation'
    );
    assert.match(
      acrylicHostsModel,
      /\[string\[\]\]\$BlockedSubdomains = @\(\)/,
      'Get-AcrylicForwardRules should accept the blocked subdomain list'
    );
    assert.match(
      acrylicHostsModel,
      /FW >\$normalizedDomain/,
      'Get-AcrylicForwardRules should still emit FW >domain when no blocked descendants exist'
    );
    assert.match(
      acrylicHostsModel,
      /\$escapedBlockedPattern = \(\$blockedDescendants -join '\\|'\)/,
      'Get-AcrylicForwardRules should combine blocked descendants into a single negative-lookahead pattern'
    );
    assert.match(
      acrylicHostsModel,
      /\$escapedDomain = \[regex\]::Escape\(\$normalizedDomain\)/,
      'Get-AcrylicForwardRules should escape the forwarded parent domain before building the regex rule'
    );
    assert.match(
      acrylicHostsModel,
      /"FW \/\^\(\?!.*\$escapedBlockedPattern.*\$escapedDomain\$"/,
      'Get-AcrylicForwardRules should emit a regex-based FW rule that excludes blocked descendants when needed'
    );
    assert.ok(
      !acrylicHostsModel.includes(
        '"FW /^(?!(?:.*\\.)?(?:$escapedBlockedPattern)$).*\\.$escapedDomain$/"'
      ),
      'Get-AcrylicForwardRules should not emit a trailing slash in Acrylic regex rules'
    );
    assert.match(
      acrylicHostsModel,
      /if \(\$blockedDescendants\.Count -eq 0\) \{[\s\S]*?"FW >\$normalizedDomain"[\s\S]*?\}/,
      'Get-AcrylicForwardRules should keep the wildcard FW shortcut only for domains without blocked descendants'
    );
    assert.match(
      acrylicHostsModel,
      /function Get-AcrylicAffinityMaskEntries/,
      'AcrylicHostsModel.ps1 should keep Acrylic upstream affinity generation in a dedicated helper'
    );
    assert.match(
      acrylicHostsModel,
      /\$domainEntries = if \(\$hasBlockedDescendant\) \{ @\(\$normalizedDomain\) \} else \{ @\(\$normalizedDomain, "\*\.\$normalizedDomain"\) \}/,
      'Get-AcrylicAffinityMaskEntries should omit the parent wildcard when a blocked descendant would otherwise resolve upstream'
    );
    assert.match(
      acrylicHostsModel,
      /\$domainEntries = if \(\$hasBlockedDescendant\)/,
      'Get-AcrylicAffinityMaskEntries should detect blocked descendants before emitting the parent wildcard'
    );
    assert.doesNotMatch(
      dnsConfigModule,
      /function Get-AcrylicForwardRules/,
      'DNS.Acrylic.Config.ps1 should consume the split Acrylic hosts model instead of owning renderer internals'
    );
  });

  test('windows DNS renderer keeps essential domains on unconditional wildcard forwarding', () => {
    const acrylicHostsModel = readText('windows/lib/internal/AcrylicHostsModel.ps1');

    assert.match(
      acrylicHostsModel,
      /\$groupLines \+= @\(Get-AcrylicForwardRules -Domain \$normalizedDomain\)/,
      'Essential control-plane domains should keep unconditional wildcard FW rules'
    );
    assert.ok(
      !acrylicHostsModel.includes(
        '$essentialLines += @(Get-AcrylicForwardRules -Domain $domain -BlockedSubdomains $BlockedSubdomains)'
      ),
      'Essential control-plane domains should not inherit classroom blocked-subdomain overrides'
    );
  });

  test('windows DNS renderer uses documented default NXDOMAIN deny for unmatched fixture misses', () => {
    const acrylicHostsModel = readText('windows/lib/internal/AcrylicHostsModel.ps1');

    assert.match(
      acrylicHostsModel,
      /New-AcrylicHostsSection -Title 'DEFAULT BLOCK \(NXDOMAIN for everything else\)'[\s\S]*-Lines @\('NX \*'\)/,
      'Acrylic default deny should use the documented NX * catch-all so unmatched domains cannot forward upstream'
    );
    assert.ok(
      !acrylicHostsModel.includes(
        "New-AcrylicHostsSection -Title 'DEFAULT BLOCK (sinkhole for everything else)'"
      ),
      'Acrylic default deny should not use a sinkhole fallback when Acrylic can return NXDOMAIN for unmatched domains'
    );
    assert.ok(
      !acrylicHostsModel.includes(
        "New-AcrylicHostsSection -Title 'DEFAULT BLOCK (sinkhole for everything else)' -Description 'This MUST come last after FW rules.' -Lines @('0.0.0.0 *')"
      ),
      'Acrylic default deny should not rely on the bare * wildcard because CI observed it forwarding sslip fixture hosts upstream'
    );
  });

  test('windows Acrylic configuration keeps the hosts cache enabled so policy rules are evaluated', () => {
    const dnsConfigModule = readText('windows/lib/internal/DNS.Acrylic.Config.ps1');
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.ok(
      dnsConfigModule.includes('"AddressCacheDisabled" = "No"'),
      'Set-AcrylicConfiguration should keep Acrylic hosts/cache resolution enabled; Yes makes Acrylic forwarding-only'
    );
    assert.ok(
      !dnsConfigModule.includes('"AddressCacheDisabled" = "Yes"'),
      'Set-AcrylicConfiguration should not disable Acrylic address cache because that bypasses policy hosts in CI'
    );
    assert.ok(
      windowsRunner.includes('AddressCacheDisabled=No'),
      'Windows student-policy runner should assert the installed Acrylic config still evaluates hosts rules'
    );
    assert.ok(
      windowsRunner.includes("'NX *'"),
      'Windows student-policy runner should assert the installed Acrylic hosts file contains the default deny rule'
    );
  });

  test('windows Acrylic configuration limits upstream forwarding to allowed domains', () => {
    const dnsConfigModule = readText('windows/lib/internal/DNS.Acrylic.Config.ps1');
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      dnsConfigModule,
      /\$essentialForwardDomains = @\([\s\S]*?Get-AcrylicEssentialDomainGroups[\s\S]*?\)[\s\S]*?Get-AcrylicAffinityMaskEntries -Domains \$essentialForwardDomains[\s\S]*?Get-AcrylicAffinityMaskEntries -Domains \$WhitelistedDomains -BlockedSubdomains \$BlockedSubdomains/,
      'Set-AcrylicConfiguration should build upstream forwarding masks from essential domains and blocked-descendant-aware whitelisted domains'
    );
    assert.match(
      dnsConfigModule,
      /\$domainAffinityMask = \(\$affinityMaskEntries -join ';'\)/,
      'Set-AcrylicConfiguration should serialize the allowed-domain affinity mask'
    );
    assert.ok(
      dnsConfigModule.includes('"PrimaryServerDomainNameAffinityMask" = $domainAffinityMask') &&
        dnsConfigModule.includes('"SecondaryServerDomainNameAffinityMask" = $domainAffinityMask'),
      'Acrylic upstream resolvers should only forward domains in the allowlist affinity mask'
    );
    assert.ok(
      windowsRunner.includes('PrimaryServerDomainNameAffinityMask=raw.githubusercontent.com') &&
        windowsRunner.includes('SecondaryServerDomainNameAffinityMask=raw.githubusercontent.com'),
      'Windows student-policy runner should assert the installed resolver affinity mask is active'
    );
  });

  test('windows Pester DNS contracts track the Acrylic default-deny and ASCII encoding behavior', () => {
    const pesterDnsTests = readText('windows/tests/Windows.DNS.Core.Tests.ps1');

    assert.ok(
      pesterDnsTests.includes("'NX *'"),
      'Windows DNS Pester tests should assert the documented NX default deny, not the old sinkhole rule'
    );
    assert.ok(
      !pesterDnsTests.includes("'0.0.0.0 /^.*$'"),
      'Windows DNS Pester tests should not expect the old regex sinkhole default-deny rule'
    );
    assert.ok(
      pesterDnsTests.includes('function Assert-IsAsciiEncoding'),
      'Windows DNS Pester tests should normalize mocked Set-Content encoding values before asserting ASCII'
    );
    assert.match(
      pesterDnsTests,
      /BeforeAll\s*\{\s*function Assert-IsAsciiEncoding/,
      'Windows DNS Pester helpers should be defined in BeforeAll so Pester v5 exposes them to It blocks'
    );
    assert.ok(
      !pesterDnsTests.includes("| Should -Be 'ASCII'"),
      'Windows DNS Pester tests should not compare mocked Encoding values with a raw string'
    );
  });

  test('windows Acrylic configuration keeps required global section for fresh portable installs', () => {
    const dnsConfigModule = readText('windows/lib/internal/DNS.Acrylic.Config.ps1');

    assert.match(
      dnsConfigModule,
      /if \(\$iniContent -notmatch '\(\?m\)\^\\\[GlobalSection\\\]\\s\*\$'\) \{\s*\$iniContent = "\[GlobalSection\]`n\$iniContent"\s*\}/,
      'Set-AcrylicConfiguration should create [GlobalSection] before writing settings when AcrylicConfiguration.ini is missing or sectionless'
    );
  });

  test('windows Acrylic configuration seeds required resolver defaults for sparse portable installs', () => {
    const dnsConfigModule = readText('windows/lib/internal/DNS.Acrylic.Config.ps1');
    const acrylicConfigWriter = readText('windows/lib/internal/AcrylicConfigWriter.ps1');

    for (const requiredSetting of [
      '"PrimaryServerPort" = "53"',
      '"PrimaryServerProtocol" = "UDP"',
      '"SecondaryServerPort" = "53"',
      '"SecondaryServerProtocol" = "UDP"',
      '"LocalIPv4BindingAddress" = "0.0.0.0"',
      '"LocalIPv6BindingAddress" = ""',
      '"LocalIPv6BindingPort" = "53"',
      '"GeneratedResponseTimeToLive" = "300"',
      '"HitLogFileWhat" = "XHCF"',
      '"HitLogMaxPendingHits" = "512"',
    ]) {
      assert.ok(
        dnsConfigModule.includes(requiredSetting),
        `Set-AcrylicConfiguration should seed ${requiredSetting} so a sparse AcrylicConfiguration.ini remains service-usable`
      );
    }

    assert.ok(
      acrylicConfigWriter.includes("$Content -notmatch '(?m)^\\[AllowedAddressesSection\\]\\s*$'"),
      'Set-AcrylicConfiguration should preserve or create [AllowedAddressesSection] after the global settings block'
    );
    assert.ok(
      dnsConfigModule.includes("-Key 'IP1' -Value '127.*'") &&
        dnsConfigModule.includes("-Key 'IP2' -Value '::1'"),
      'Set-AcrylicConfiguration should explicitly allow local loopback requests in [AllowedAddressesSection]'
    );
    assert.match(
      acrylicConfigWriter,
      /Set-Content -Path \$Path -Value \$Content -Encoding ASCII -Force/,
      'Update-AcrylicHost should write AcrylicHosts.txt without a UTF-8 BOM so Acrylic can parse it'
    );
    assert.match(
      acrylicConfigWriter,
      /Set-Content -Path \$Path -Value \$Content -Encoding ASCII -Force/,
      'Set-AcrylicConfiguration should write AcrylicConfiguration.ini without a UTF-8 BOM so Acrylic can parse [GlobalSection]'
    );
  });

  test('Windows student-policy diagnostics capture Acrylic DNS state and sslip probes', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    for (const fileName of [
      'AcrylicConfiguration.ini',
      'AcrylicHosts.txt',
      'AcrylicCache.dat',
      'AcrylicDebug.txt',
    ]) {
      assert.ok(
        windowsRunner.includes(fileName),
        `Windows student-policy diagnostics should copy ${fileName} into the artifact bundle when present`
      );
    }

    assert.ok(
      windowsRunner.includes('portal.127.0.0.1.sslip.io') &&
        windowsRunner.includes('api.site.127.0.0.1.sslip.io') &&
        windowsRunner.includes('blocked.127.0.0.1.sslip.io'),
      'Windows student-policy diagnostics should probe the fixture sslip hostnames that Selenium navigates'
    );
    assert.ok(
      windowsRunner.includes('Resolve-DnsName -Name $probeHost -Server 127.0.0.1 -DnsOnly'),
      'Windows student-policy diagnostics should resolve fixture hostnames through the local Acrylic resolver'
    );
    assert.match(
      windowsRunner,
      /Get-NetUDPEndpoint[\s\S]*-LocalPort 53/,
      'Windows student-policy diagnostics should capture UDP/53 listeners so Acrylic binding failures are visible'
    );
    assert.match(
      windowsRunner,
      /catch \{[\s\S]*"ERROR: \$\(\$_\.Exception\.Message\)"/,
      'Windows student-policy diagnostics should include Resolve-DnsName exception messages instead of blank probe sections'
    );
  });

  test('Windows student-policy readiness fails before Selenium when blocked fixture DNS resolves upstream', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');
    const readinessFunction = windowsRunner.match(
      /function Assert-WindowsDnsPolicyReady \{[\s\S]*?\n\}/
    )?.[0];
    assert.ok(readinessFunction, 'Windows student-policy runner should define DNS readiness');

    assert.match(
      readinessFunction,
      /raw\.githubusercontent\.com/,
      'Windows student-policy readiness should verify an essential allowlisted domain before Selenium'
    );
    assert.doesNotMatch(
      readinessFunction,
      /portal\.127\.0\.0\.1\.sslip\.io|api\.site\.127\.0\.0\.1\.sslip\.io/,
      'Windows student-policy readiness should not require fixture hosts to be allowed before Selenium seeds baseline policy'
    );
    assert.match(
      readinessFunction,
      /blocked\.127\.0\.0\.1\.sslip\.io/,
      'Windows student-policy runner should probe an unwhitelisted sslip fixture host before Selenium'
    );
    assert.match(
      readinessFunction,
      /\$blockedFixtureIp = '127\.0\.0\.1'/,
      'Windows student-policy runner should know the sslip fixture IP that indicates a missed DNS block'
    );
    assert.match(
      readinessFunction,
      /\$blockedAddresses = @\([\s\S]*?Resolve-DnsName -Name \$blockedProbeHost[\s\S]*?Where-Object \{ \$_.IPAddress \}[\s\S]*?ForEach-Object \{ \[string\]\$_.IPAddress \}[\s\S]*?\)/,
      'Windows student-policy runner should collect blocked-probe IP addresses through local Acrylic'
    );
    assert.match(
      readinessFunction,
      /\$blockedAddresses -contains \$blockedFixtureIp/,
      'Windows student-policy runner should reject blocked sslip fixture probes that still resolve to 127.0.0.1'
    );
  });

  test('Windows student-policy runner verifies the installed Acrylic runtime before Selenium', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /function Assert-InstalledAcrylicRuntime/,
      'Windows student-policy runner should have a focused post-install Acrylic runtime assertion'
    );
    assert.ok(
      windowsRunner.includes('C:\\OpenPath\\lib\\internal\\DNS.Acrylic.Config.ps1'),
      'Windows student-policy runner should inspect the installed DNS.Acrylic.Config.ps1 file'
    );
    assert.ok(
      windowsRunner.includes('Set-AcrylicGlobalSetting') &&
        windowsRunner.includes('PrimaryServerPort=53') &&
        windowsRunner.includes('AddressCacheDisabled=No') &&
        windowsRunner.includes('AcrylicHosts.txt') &&
        windowsRunner.includes('[AllowedAddressesSection]'),
      'Windows student-policy runner should assert the installed runtime/config contain the current Acrylic defaults'
    );
    assert.ok(
      windowsRunner.includes('Get-FileHash -Algorithm SHA256'),
      'Windows student-policy diagnostics should record file hashes for installed Acrylic runtime evidence'
    );
    assert.match(
      windowsRunner,
      /Install-AndEnrollClient[\s\S]*Assert-InstalledAcrylicRuntime/,
      'Windows student-policy runner should verify Acrylic runtime state immediately after install/enroll/update'
    );
  });

  test('Windows student-policy runner gates Selenium on local Acrylic DNS health', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');

    assert.match(
      windowsRunner,
      /function Assert-WindowsDnsPolicyReady/,
      'Windows student-policy runner should assert local DNS policy readiness before Selenium'
    );
    assert.match(
      windowsRunner,
      /Assert-InstalledAcrylicRuntime[\s\S]*Assert-WindowsDnsPolicyReady/,
      'Windows student-policy runner should check DNS readiness immediately after Acrylic runtime/config validation'
    );
    assert.ok(
      windowsRunner.includes('Get-NetUDPEndpoint -LocalPort 53') &&
        windowsRunner.includes('Get-NetTCPConnection -LocalPort 53'),
      'Windows student-policy runner should fail early when Acrylic is not listening on port 53'
    );
    assert.ok(
      windowsRunner.includes('Resolve-DnsName -Name $probeHost -Server 127.0.0.1 -DnsOnly'),
      'Windows student-policy runner should verify fixture host resolution through local Acrylic before Selenium'
    );
    assert.ok(
      windowsRunner.includes('Get-CimInstance -ClassName Win32_Service') &&
        windowsRunner.includes('Get-WinEvent'),
      'Windows student-policy diagnostics should capture Acrylic service process and event log evidence'
    );
  });

  test('Windows student-policy runner waits for DNS policy readiness before Selenium', () => {
    const windowsRunner = readText('tests/e2e/ci/run-windows-student-flow.ps1');
    const waitFunction = windowsRunner.match(
      /function Wait-WindowsDnsPolicyReady \{[\s\S]*?\n\}\n\nfunction Install-AndEnrollClient/
    )?.[0];

    assert.ok(waitFunction, 'Windows student-policy runner should poll DNS readiness');
    assert.match(
      waitFunction,
      /OPENPATH_WINDOWS_DNS_READINESS_ATTEMPTS/,
      'Windows DNS readiness polling should have an environment override for CI tuning'
    );
    assert.match(
      waitFunction,
      /Assert-WindowsDnsPolicyReady/,
      'Windows DNS readiness polling should reuse the focused readiness assertion'
    );
    assert.match(
      waitFunction,
      /Start-Sleep -Seconds/,
      'Windows DNS readiness polling should wait between attempts instead of racing Selenium'
    );
    assert.match(
      waitFunction,
      /Invoke-DebugDump/,
      'Windows DNS readiness polling should emit full diagnostics before failing'
    );
    assert.match(
      windowsRunner,
      /Assert-InstalledAcrylicRuntime[\s\S]*Wait-WindowsDnsPolicyReady/,
      'Windows student-policy runner should wait for DNS readiness after Acrylic runtime validation'
    );
  });

  test('Linux student-policy readiness fails before Selenium when blocked fixture DNS resolves upstream', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');
    const readinessFunction = linuxRunner.match(
      /assert_linux_dns_policy_ready\(\) \{[\s\S]*?\n\}/
    )?.[0];
    assert.ok(readinessFunction, 'Linux student-policy runner should define DNS readiness');

    assert.match(
      readinessFunction,
      /raw\.githubusercontent\.com/,
      'Linux student-policy readiness should verify an essential allowlisted domain before Selenium'
    );
    assert.doesNotMatch(
      readinessFunction,
      /portal\.\$\{OPENPATH_STUDENT_HOST_SUFFIX\}|api\.site\.\$\{OPENPATH_STUDENT_HOST_SUFFIX\}/,
      'Linux student-policy readiness should not require fixture hosts to be allowed before Selenium seeds baseline policy'
    );
    assert.match(
      readinessFunction,
      /blocked\.\$\{OPENPATH_STUDENT_HOST_SUFFIX\}/,
      'Linux student-policy runner should probe an unwhitelisted sslip fixture host before Selenium'
    );
    assert.match(
      readinessFunction,
      /blocked_fixture_ip="127\.0\.0\.1"/,
      'Linux student-policy runner should know the sslip fixture IP that indicates a missed DNS block'
    );
    assert.match(
      readinessFunction,
      /dig @127\.0\.0\.1 "\$blocked_probe_host"/,
      'Linux student-policy runner should resolve the blocked fixture host through local dnsmasq'
    );
    assert.match(
      readinessFunction,
      /\[\[ "\$blocked_addresses" == \*"\$blocked_fixture_ip"\* \]\]/,
      'Linux student-policy runner should reject blocked sslip fixture probes that still resolve to 127.0.0.1'
    );
  });

  test('Linux student-policy runner waits for DNS policy readiness before Selenium', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');
    const waitFunction = linuxRunner.match(
      /wait_for_linux_dns_policy_ready\(\) \{[\s\S]*?\n\}\n\nassert_linux_firefox_extension_ready/
    )?.[0];

    assert.ok(waitFunction, 'Linux student-policy runner should poll DNS readiness');
    assert.match(
      waitFunction,
      /OPENPATH_LINUX_DNS_READINESS_ATTEMPTS/,
      'Linux DNS readiness polling should have an environment override for CI tuning'
    );
    assert.match(
      waitFunction,
      /assert_linux_dns_policy_ready/,
      'Linux DNS readiness polling should reuse the focused readiness assertion'
    );
    assert.match(
      waitFunction,
      /sleep "\$delay_seconds"/,
      'Linux DNS readiness polling should wait between attempts instead of racing Selenium'
    );
    assert.match(
      waitFunction,
      /debug_state/,
      'Linux DNS readiness polling should emit full diagnostics before failing'
    );
    assert.match(
      linuxRunner,
      /Verify SSE DNS policy readiness" wait_for_linux_dns_policy_ready/,
      'Linux SSE student-policy runner should wait for DNS readiness before Selenium'
    );
    assert.match(
      linuxRunner,
      /Verify fallback DNS policy readiness" wait_for_linux_dns_policy_ready/,
      'Linux fallback student-policy runner should wait for DNS readiness before Selenium'
    );
  });

  test('Linux student-policy runner waits for PostgreSQL query readiness', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /pg_isready -U openpath -d openpath_test[\s\S]*psql -U openpath -d openpath_test -tAc 'SELECT 1'/,
      'Linux student-policy runner should verify PostgreSQL accepts queries before migrations start'
    );
  });

  test('Linux student-policy runner gates Selenium on dnsmasq and Firefox native-host readiness', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /assert_linux_dns_policy_ready\(\) \{[\s\S]*?systemctl is-active --quiet dnsmasq[\s\S]*?ss -/,
      'Linux student-policy runner should fail early when dnsmasq is inactive or not listening before Selenium'
    );
    assert.match(
      linuxRunner,
      /assert_linux_firefox_extension_ready\(\) \{[\s\S]*?openpath-firefox-extension\.xpi[\s\S]*?whitelist_native_host\.json[\s\S]*?manifest_path/,
      'Linux student-policy runner should verify the Firefox XPI and native messaging host before Selenium'
    );
    assert.ok(
      !linuxRunner.includes('native_host="/usr/local/bin/openpath-native-host.py"'),
      'Linux student-policy readiness should validate the native host executable path from the installed Firefox manifest, not a legacy hardcoded path'
    );
    assert.match(
      linuxRunner,
      /manifest_path="\$\(jq -r "\.path \/\/ \\"\\"" "\$root_manifest"\)"[\s\S]*?\[\[ -x "\$manifest_path" \]\]/,
      'Linux student-policy readiness should require the native host path declared by the root Firefox manifest to be executable'
    );
    assert.match(
      linuxRunner,
      /configure_client true[\s\S]*?wait_for_linux_dns_policy_ready[\s\S]*?assert_linux_firefox_extension_ready[\s\S]*?run_student_suite sse/,
      'Linux student-policy runner should gate the SSE Selenium phase after install/enroll/update'
    );
    assert.match(
      linuxRunner,
      /configure_client false[\s\S]*?wait_for_linux_dns_policy_ready[\s\S]*?assert_linux_firefox_extension_ready[\s\S]*?run_student_suite fallback/,
      'Linux student-policy runner should gate the fallback Selenium phase after reconfiguration/update'
    );
  });

  test('Linux student-policy Selenium uses managed Firefox only when signed artifacts exist', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /STUDENT_USE_MANAGED_FIREFOX_EXTENSION=true/,
      'Linux Selenium should switch to managed-extension coverage when a signed Firefox artifact is available'
    );
    assert.match(
      linuxRunner,
      /if \[\[ "\$STUDENT_USE_MANAGED_FIREFOX_EXTENSION" == "true" \]\][\s\S]*?OPENPATH_SKIP_EXTENSION_BUNDLE=1/,
      'Linux Selenium should skip direct XPI loading only in signed managed-extension mode'
    );
    assert.match(
      linuxRunner,
      /Signed Firefox release artifacts not present[\s\S]*?Selenium will load the unsigned XPI directly/,
      'Linux Selenium should avoid AMO signing waits in ordinary E2E runs by using the unsigned bundle path'
    );
  });

  test('Linux student-policy runner seeds baseline policy before enrollment readiness', () => {
    const linuxRunner = readText('tests/e2e/ci/run-linux-student-flow.sh');

    assert.match(
      linuxRunner,
      /seed_initial_baseline_policy\(\) \{[\s\S]*?create-rule[\s\S]*?portal[\s\S]*?host\.docker\.internal/,
      'Linux student-policy runner should create enough initial whitelist rules for first client update'
    );
    assert.match(
      linuxRunner,
      /bootstrap_scenario "Linux Student Policy SSE"[\s\S]*?seed_initial_baseline_policy[\s\S]*?configure_client true/,
      'Linux student-policy runner should seed baseline policy before the SSE install/enroll/update phase'
    );
    assert.match(
      linuxRunner,
      /bootstrap_scenario "Linux Student Policy Fallback"[\s\S]*?seed_initial_baseline_policy[\s\S]*?configure_client false/,
      'Linux student-policy runner should seed baseline policy before the fallback reconfiguration/update phase'
    );
  });

  test('root tooling can resolve drizzle-orm for hoisted drizzle-kit commands', () => {
    const packageJson = readPackageJson();
    const packageLock = readJson('package-lock.json');
    const apiPackageJson = readJson('api/package.json');

    assert.equal(
      packageJson.devDependencies?.['drizzle-orm'],
      apiPackageJson.dependencies['drizzle-orm'],
      'root devDependencies should pin drizzle-orm to the api workspace version for hoisted tooling'
    );
    assert.ok(
      packageLock.packages['node_modules/drizzle-orm'],
      'package-lock.json should install drizzle-orm at the workspace root for hoisted drizzle-kit resolution'
    );
  });
});
