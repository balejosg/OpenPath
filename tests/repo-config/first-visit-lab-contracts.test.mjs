// Phase 3A first-visit lane contracts (source-text assertions).
// Guarded files: .github/workflows/windows-first-visit-lab.yml,
// tests/e2e/ci/run-windows-first-visit-suite.ps1 and
// tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { describe, test } from 'node:test';

import { projectRoot } from './support.mjs';

function read(relativePath) {
  return readFileSync(resolve(projectRoot, relativePath), 'utf8');
}

function listFiles(directory) {
  const out = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = join(directory, entry.name);
    if (entry.isDirectory()) {
      out.push(...listFiles(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

describe('first-visit lane contract', () => {
  const workflowPath = '.github/workflows/windows-first-visit-lab.yml';

  test('the lane runs after REL on main, nightly and on demand', () => {
    const workflow = read(workflowPath);
    assert.match(workflow, /workflow_run:/u);
    assert.match(workflow, /workflows: \['Release Installation Scripts'\]/u);
    assert.match(workflow, /schedule:/u);
    assert.match(workflow, /cron: '17 2 \* \* \*'/u);
    assert.match(workflow, /workflow_dispatch:/u);
    assert.match(workflow, /template_run_id:/u);
    assert.match(workflow, /template_sha:/u);
    assert.match(workflow, /scenarios:/u);
    assert.match(workflow, /repetitions:/u);
    assert.match(workflow, /lab_scenario:/u);
    assert.match(workflow, /concurrency:/u);
    assert.match(workflow, /actions\/checkout@v6/u);
    assert.match(workflow, /fetch-depth: 0/u);
    // Phase 3A.2 K2: the range resolver and the per-trigger plan replace the
    // last-commit-only diff and the gh CLI dependency.
    assert.match(workflow, /Resolve-FirstVisitScope\.ps1/u);
    assert.match(workflow, /FirstVisitLanePlan\.psm1/u);
    assert.match(workflow, /steps\.plan\.outputs\.scenarios/u);
    assert.match(workflow, /steps\.template\.outputs\.template_sha/u);
    assert.match(workflow, /archive_download_url/u);
    assert.doesNotMatch(workflow, /gh run /u);
    assert.doesNotMatch(workflow, /gh workflow/u);
    const planModule = read('tests/e2e/ci/first-visit/FirstVisitLanePlan.psm1');
    assert.match(planModule, /fail-open/u);
    assert.match(planModule, /'settled,class-boot'; repetitions = 1; source = 'workflow_run'/u);
    assert.match(
      planModule,
      /'settled,hot,class-boot,floor'; repetitions = 2; source = 'schedule'/u
    );
    assert.match(workflow, /actions\/upload-artifact@v7/u);
  });

  test('the lane consumes the exact template and never signs in AMO', () => {
    const workflow = read(workflowPath);
    assert.match(workflow, /windows-offline-template/u);
    assert.match(workflow, /windows-personalized-exe/u);
    assert.match(workflow, /run-windows-first-visit-suite\.ps1/u);
    assert.match(workflow, /aggregate-windows-first-visit\.ps1/u);
    assert.doesNotMatch(workflow, /sign:firefox-release/u);
    assert.doesNotMatch(workflow, /WEB_EXT_API/u);
    assert.doesNotMatch(workflow, /prepare-firefox-release-artifacts/u);
    assert.doesNotMatch(workflow, /release-extension/u);
  });

  test('the lane serializes on the lab lock and tears down on cancellation', () => {
    const workflow = read(workflowPath);
    assert.match(workflow, /proxmox-disposable-windows-release-lock\.ps1/u);
    assert.match(workflow, /-ReclaimFinishedOwners/u);
    assert.match(workflow, /if: cancelled\(\)/u);
  });

  test('the suite always runs cleanup and the controller refuses dry-run labs', () => {
    const suite = read('tests/e2e/ci/run-windows-first-visit-suite.ps1');
    assert.match(suite, /-Mode 'Cleanup'/u);
    assert.match(suite, /foreach \(\$mode in @\('Prepare', 'Observe'\)\)/u);
    assert.match(suite, /OPENPATH_FIRST_VISIT_LAB_SCENARIO/u);
    const firstVisit = read('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1');
    assert.match(firstVisit, /first-visit-requires-acceptance-lab-config/u);
    const module = read('tests/e2e/ci/controllers/ProxmoxWindowsLab.psm1');
    assert.match(module, /first-visit-requires-acceptance-lab-config/u);
    assert.match(module, /proxmox-lab-lock\.sh/u);
  });

  test('the fixture stays site-agnostic and generates hosts per run', () => {
    const fixture = read('tests/e2e/ci/first-visit/fixture_server.py');
    assert.match(fixture, /sslip\.io/u);
    assert.doesNotMatch(fixture, /reddit|bbc|youtube/iu);
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /Get-FixturePlan/u);
    assert.doesNotMatch(harness, /reddit|bbc|youtube/iu);
    // Phase 5.3: the floor pre-whitelists the dependency hosts, so the
    // before-visit DNS precondition is inverted for it (the first floor
    // dispatch failed with dependency-resolves-before-visit).
    assert.match(harness, /if \(\$plan\.floorMode\)/u);
    assert.match(harness, /floor-dependency-does-not-resolve-before-visit/u);
    assert.match(harness, /floor-anchor-does-not-resolve-before-visit/u);
    // Phase 5.3 P5: the topology evidence reads the WHOLE Acrylic INI (the
    // tail cut PrimaryServerAddress) and searches the whole AcrylicHosts plus
    // drivers\etc\hosts for the anchor line.
    assert.match(harness, /Get-FileTextSafe -Path \$acrylicIni/u);
    assert.doesNotMatch(harness, /Get-FileTailSafe -Path \$acrylicIni/u);
    assert.match(harness, /System32\\drivers\\etc\\hosts/u);
    assert.match(harness, /anchorStaticHostLine/u);
  });

  test('the guest harness never rewrites the browser policy', () => {
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.doesNotMatch(harness, /Set-LabFirefoxPolicy/u);
    assert.doesNotMatch(harness, /Install-DistributedExtension/u);
    assert.doesNotMatch(harness, /reg\.exe.*ExtensionSettings/u);
    assert.doesNotMatch(harness, /distribution\\extensions/u);
    assert.doesNotMatch(harness, /file:\/\//u);
    // Phase 3A.3: the verification verdicts live in a tested module. Lane
    // preconditions (INFRA) are separate from the product host signals.
    assert.match(harness, /Get-FirstVisitPreconditionVerdict/u);
    assert.match(harness, /FirstVisitWarmup\.psm1/u);
    assert.match(harness, /FirstVisitResult\.psm1/u);
    const warmup = read('tests/e2e/ci/first-visit/FirstVisitWarmup.psm1');
    assert.match(warmup, /xpi-fetched-not-registered/u);
    assert.match(warmup, /extension-registered-inactive/u);
    assert.match(warmup, /native-host-blocked-by-appcontrol/u);
    assert.match(warmup, /native-host-not-started/u);
  });

  test('the lane resolves its template from tested code and never cancels a pending run', () => {
    const workflow = read(workflowPath);
    assert.match(workflow, /FirstVisitTemplateSource\.psm1/u);
    assert.match(workflow, /Get-FirstVisitTemplateSourcePlan/u);
    assert.match(workflow, /Resolve-FirstVisitTemplateRun/u);
    // The REST API returns `id`; `database_id` is null and caused every
    // workflow_run resolution to fail in Phase 3A.2.
    assert.doesNotMatch(workflow, /database_id/u);
    assert.doesNotMatch(workflow, /FirstVisitLanePlan[^\n]*runs\?/u);
    // A shared concurrency group cancels the oldest pending run (observed
    // three times); the group is per run and the lock serializes the lab.
    assert.match(workflow, /group: windows-first-visit-lab-\$\{\{ github\.run_id \}\}/u);
    assert.doesNotMatch(workflow, /group: windows-first-visit-lab-\$\{\{ github\.ref \}\}/u);
    const template = read('tests/e2e/ci/first-visit/FirstVisitTemplateSource.psm1');
    assert.match(template, /function Resolve-FirstVisitTemplateRun/u);
    // Strip comments (line and block): the module documents the past bug by name.
    const templateCode = template.replace(/<#[\s\S]*?#>/gu, '').replace(/^\s*#.*$/gmu, '');
    assert.doesNotMatch(templateCode, /database_id/u);
    assert.match(templateCode, /Get-FirstVisitTemplateField -InputObject \$RunEntry -Name 'id'/u);
    assert.match(template, /first-visit-template-not-found/u);
    // Phase 5.3 P5: no branch filter on the listing; filter main+push+success
    // on the client and contrast the result with main HEAD, so a stale listing
    // can never silently resolve an outdated template.
    assert.doesNotMatch(templateCode, /status=success/u);
    assert.doesNotMatch(templateCode, /branch=main&per_page=50/u);
    assert.match(templateCode, /per_page=50/u);
    assert.doesNotMatch(templateCode, /branch=main/u);
    assert.match(templateCode, /head_branch/u);
    assert.match(templateCode, /commits\/main/u);
    assert.match(templateCode, /head_sha=\$headSha/u);
    assert.match(templateCode, /stale = \$true|stale {15}= \$true/u);
    assert.match(workflow, /Template resolver: mode=/u);
    assert.match(workflow, /headSha=\$headSha/u);
    assert.match(workflow, /newer successful release-scripts run/u);
    assert.match(workflow, /template_lag/u);
    assert.match(workflow, /successful run\(s\) behind/u);
    const aggregate = read('tests/e2e/ci/aggregate-windows-first-visit.ps1');
    assert.match(aggregate, /templateSha/u);
    assert.match(aggregate, /Template: \$templateSha \(lag \$templateLag/u);
  });

  test('no guest step can lose its result', () => {
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /function Save-PartialResult/u);
    assert.match(harness, /ConvertTo-FirstVisitResultJson/u);
    assert.match(harness, /function Get-StepResultPayload/u);
    const result = read('tests/e2e/ci/first-visit/FirstVisitResult.psm1');
    assert.match(result, /function Resolve-FirstVisitGuestResult/u);
    assert.match(result, /result-file/u);
    const controller = read('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1');
    assert.match(controller, /Read-OpenPathFirstVisitGuestText/u);
    assert.match(controller, /Resolve-FirstVisitGuestResult/u);
    assert.match(controller, /first-visit-precondition-failed/u);
  });

  test('the warm-up verification renders the warm-up baseline from arguments', () => {
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /\$FixtureBaselineJson/u);
    const controller = read('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1');
    assert.match(controller, /-FixtureBaselineJson/u);
    assert.match(controller, /verify-warmup/u);
    assert.match(controller, /Get-OpenPathFirstVisitBuildCapabilities/u);
    assert.match(controller, /templateXpiSha256/u);
  });

  test('the Acrylic INI parse keeps literal values before any other match (Phase 6 A)', () => {
    const module = read('tests/e2e/ci/first-visit/FirstVisitDnsTopology.psm1');
    // The value is captured BEFORE the interesting-key -match; the previous
    // order overwrote $Matches and stored every value empty.
    assert.match(module, /function ConvertFrom-OpenPathAcrylicIniText/u);
    assert.match(
      module,
      /\$value = \(\[string\]\$Matches\[2\]\)\.Trim\(\)[\s\S]{0,240}if \(\$key -match/u
    );
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /ConvertFrom-OpenPathAcrylicIniText/u);
    const controller = read('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1');
    assert.match(controller, /FirstVisitDnsTopology\.psm1/u);
  });

  test('the lane can simulate Smart App Control and collects its evidence (Phase 6 B)', () => {
    const workflow = read(workflowPath);
    assert.match(workflow, /smart_app_control:/u);
    assert.match(workflow, /-SmartAppControl/u);
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /'sac-apply'/u);
    assert.match(harness, /'sac-state'/u);
    assert.match(harness, /VerifiedAndReputablePolicyState/u);
    assert.match(harness, /Microsoft-Windows-CodeIntegrity\/Operational/u);
    assert.match(harness, /LanguageMode/u);
    const warmup = read('tests/e2e/ci/first-visit/FirstVisitWarmup.psm1');
    assert.match(warmup, /native-host-blocked-by-smart-app-control/u);
    const controller = read('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1');
    assert.match(controller, /first-visit-smart-app-control-requires-class-boot/u);
    assert.match(controller, /sac-not-enforced/u);
    assert.match(controller, /-CodeIntegrityEvents/u);
    assert.match(warmup, /Select-FirstVisitSmartAppControlEvidence/u);
    assert.match(warmup, /blockedBySmartAppControl/u);
  });

  test('the real-site canary only runs by dispatch and is non-blocking (Phase 6 C)', () => {
    const workflow = read(workflowPath);
    assert.match(workflow, /site_url:/u);
    assert.match(workflow, /site_whitelist:/u);
    assert.match(workflow, /-SiteUrl/u);
    assert.match(workflow, /-SiteWhitelist/u);
    // The auto-run/nightly plans never contain site: only a dispatch asks for it.
    const planModule = read('tests/e2e/ci/first-visit/FirstVisitLanePlan.psm1');
    assert.match(
      planModule,
      /'settled,hot,class-boot,floor'; repetitions = 2; source = 'schedule'/u
    );
    assert.match(planModule, /'settled,class-boot'; repetitions = 1; source = 'workflow_run'/u);
    assert.doesNotMatch(planModule, /site/u);
    const suite = read('tests/e2e/ci/run-windows-first-visit-suite.ps1');
    assert.match(suite, /first-visit-site-url-required/u);
    assert.match(suite, /site-class-boot/u);
    const fixture = read('tests/e2e/ci/first-visit/fixture_server.py');
    assert.match(fixture, /siteMode/u);
    assert.match(fixture, /--site-url/u);
    assert.match(fixture, /requires site_url/u);
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /MOZ_LOG/u);
    assert.match(harness, /nsHostResolver/u);
    assert.match(harness, /canaryDiagnostics/u);
    const canary = read('tests/e2e/ci/first-visit/FirstVisitSiteCanary.psm1');
    assert.match(canary, /CANARY-PASS/u);
    assert.match(canary, /CANARY-RED/u);
    assert.match(canary, /holds-not-ready/u);
    assert.match(canary, /negative-lookups-after-ready/u);
    assert.match(canary, /stampGaps/u);
    const outcome = read('tests/e2e/ci/first-visit/FirstVisitOutcome.psm1');
    assert.match(outcome, /CANARY-PASS/u);
    assert.match(outcome, /canary-status-missing/u);
    const aggregate = read('tests/e2e/ci/aggregate-windows-first-visit.ps1');
    assert.match(aggregate, /canaryStatus/u);
    assert.match(aggregate, /'CANARY-PASS', 'CANARY-RED'/u);
  });

  test('no real site name lives in the lane sources (Phase 6.1 D)', () => {
    const forbidden = /(reddit|redditstatic|bbc|youtube)/iu;
    const roots = [
      'tests/e2e/ci/first-visit',
      'windows/tests/Windows.FirstVisitLane.Tests.ps1',
      '.github/workflows/windows-first-visit-lab.yml',
    ];
    const files = [];
    for (const root of roots) {
      const absolute = resolve(projectRoot, root);
      if (statSync(absolute).isDirectory()) {
        files.push(...listFiles(absolute));
      } else {
        files.push(absolute);
      }
    }
    const offenders = [];
    for (const absolute of files) {
      if (absolute.endsWith('.pyc')) continue;
      if (forbidden.test(readFileSync(absolute, 'utf8'))) {
        offenders.push(relative(projectRoot, absolute));
      }
    }
    assert.deepEqual(offenders, [], `real site names found: ${offenders.join(', ')}`);
  });

  test('the visit wrapper owns its launch line and the canary requires navigation (Phase 6.1 A/B)', () => {
    const launch = read('tests/e2e/ci/first-visit/FirstVisitLaunch.psm1');
    assert.match(launch, /function ConvertTo-OpenPathFirstVisitFirefoxCmdBody/u);
    assert.match(launch, /timestamp,rotate:16,nsHostResolver:5/u);
    const launchCode = launch
      .split(/\r?\n/u)
      .filter((line) => !line.trimStart().startsWith('#'))
      .join('\n');
    assert.doesNotMatch(launchCode, /MOZ_LOG_FILE_MAX_SIZE/u);
    assert.match(launch, /\$lines -join/u);
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /FirstVisitLaunch\.psm1/u);
    assert.match(harness, /function Get-PreExistingFirefox/u);
    assert.match(harness, /preExistingFirefox/u);
    assert.match(harness, /pre-existing-firefox-remains/u);
    assert.match(harness, /mozFileNames/u);
    // The -match operator owns $Matches: the moz collector must never keep its
    // list in a variable named $matches (smoke run 37582014698 collect crash).
    assert.match(harness, /mozMatches/u);
    assert.doesNotMatch(harness, /\$matches\.Add/u);
    const canary = read('tests/e2e/ci/first-visit/FirstVisitSiteCanary.psm1');
    assert.match(canary, /siteNavigated/u);
    assert.match(canary, /siteNavigationTs/u);
    assert.match(canary, /navigationEvents/u);
    const outcome = read('tests/e2e/ci/first-visit/FirstVisitOutcome.psm1');
    assert.match(outcome, /site-not-navigated/u);
    const controller = read('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1');
    assert.match(controller, /SceneStartedAt/u);
    assert.match(controller, /siteHost/u);
    assert.match(controller, /-SiteHost/u);
    assert.match(controller, /visitDiagnostics/u);
    // Phase 6.1 fix: the settings AND the observe phase must both accept the
    // site-class-boot variant (the observe exact match lost the canary path).
    const siteModeChecks =
      controller.match(
        /\$siteMode = \(\$scenario -in @\('first-visit-site', 'first-visit-site-class-boot'\)\)/gu
      ) ?? [];
    assert.ok(siteModeChecks.length >= 2, 'settings and observe must both accept site-class-boot');
  });

  test('the SAC proof is a positive control, not the registry (Phase 6.1 C)', () => {
    const harness = read('tests/e2e/ci/first-visit/Invoke-OpenPathFirstVisitGuest.ps1');
    assert.match(harness, /'sac-control'/u);
    assert.match(harness, /'sac-defender-enable'/u);
    assert.match(harness, /control-motw\.exe/u);
    assert.match(harness, /control-plain\.exe/u);
    assert.match(harness, /Zone\.Identifier/u);
    assert.match(harness, /Win32_DeviceGuard/u);
    assert.match(harness, /UsermodeCodeIntegrityPolicyEnforcementStatus/u);
    assert.match(harness, /CiTool\.exe/u);
    assert.match(harness, /'-lp'/u);
    assert.match(harness, /'\/f:xml'/u);
    assert.match(harness, /\/target:exe/u);
    assert.match(harness, /StartupTime|SceneStartedAt/u);
    const warmup = read('tests/e2e/ci/first-visit/FirstVisitWarmup.psm1');
    assert.match(warmup, /function Get-OpenPathFirstVisitSacDecision/u);
    assert.match(warmup, /umciApplied/u);
    assert.match(warmup, /motwBlocked/u);
    assert.match(warmup, /codeIntegrityXml/u);
    const controller = read('tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1');
    assert.match(controller, /Invoke-OpenPathFirstVisitSacAssessment/u);
    assert.match(controller, /sac-defender-enable/u);
    assert.match(controller, /sac-not-enforced/u);
    assert.match(controller, /first-visit-sac-reboot-timeout/u);
    // Phase 6.1 fix: the SAC cycle must REQUEST the reboot it then waits for.
    assert.match(controller, /RequestGuestReboot \$Vmid/u);
    const budget = read('tests/e2e/ci/first-visit/FirstVisitBudget.psm1');
    assert.match(budget, /\[switch\]\$SmartAppControl/u);
    const runner = read('tests/e2e/ci/run-windows-desktop-survival.ps1');
    assert.match(runner, /-SmartAppControl:\$smartAppControl/u);
  });
});
