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
});
