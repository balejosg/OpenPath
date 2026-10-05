// Phase 3A first-visit lane contracts (source-text assertions).
// Guarded files: .github/workflows/windows-first-visit-lab.yml,
// tests/e2e/ci/run-windows-first-visit-suite.ps1 and
// tests/e2e/ci/controllers/ProxmoxFirstVisit.ps1.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, test } from 'node:test';

import { projectRoot } from './support.mjs';

function read(relativePath) {
  return readFileSync(resolve(projectRoot, relativePath), 'utf8');
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
    // Phase 5.3 P3: never the combined branch/head_sha + status=success listing
    // (it returned stale runs); filter conclusion=success client-side and
    // enforce the lag.
    assert.doesNotMatch(templateCode, /status=success/u);
    assert.match(templateCode, /branch=main&per_page=50/u);
    assert.match(templateCode, /conclusion/u);
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
});
