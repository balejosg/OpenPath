import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

function read(path) {
  return readFileSync(path, 'utf8');
}

test('runtime discovery module exists and exposes the closed baseline contract', () => {
  const path = 'windows/lib/AppControl.WindowsRuntime.psm1';
  assert.ok(existsSync(path), `${path} is required`);
  const module = read(path);
  for (const symbol of [
    'Get-OpenPathWindowsRuntimeBaseline',
    'Test-OpenPathWindowsRuntimeBaseline',
    'Get-OpenPathWindowsRuntimePackageIdentity',
    'Resolve-OpenPathWindowsRuntimeDependencies',
  ]) {
    assert.match(module, new RegExp(`function\\s+${symbol.replaceAll('-', '\\-')}`));
  }
  assert.match(module, /Get-AppxPackage\s+-AllUsers/);
  assert.match(module, /AppLockerFileInformation/);
  assert.match(module, /SchemaVersion/);
  assert.match(module, /SystemApps/);
  assert.match(module, /ImmersiveControlPanel/);
});

test('AppControl uses exact package identities and does not reintroduce partial publisher wildcards', () => {
  const module = read('windows/lib/AppControl.psm1');
  const runtime = read('windows/lib/AppControl.WindowsRuntime.psm1');
  assert.match(module, /StrictApplicationAllowlist/);
  assert.match(module, /ApprovedApplicationPublishersByCollection/);
  assert.match(runtime, /Get-OpenPathWindowsRuntimePackageIdentity/);
  assert.match(runtime, /appcontrol_publisher_identity_invalid/);
  assert.match(runtime, /Contains\('\*'\)/);
  assert.doesNotMatch(runtime, /PublisherName=['"]\*['"][^\n]+ProductName=['"]\*['"]/);
});

test('transaction module defines serialized states and protected snapshots', () => {
  const path = 'windows/lib/AppControl.Transaction.psm1';
  assert.ok(existsSync(path), `${path} is required`);
  const module = read(path);
  for (const state of [
    'prepared',
    'apply-attempted',
    'applied',
    'validated',
    'committed',
    'rollback-attempted',
    'rolled-back',
    'recovery-required',
  ]) {
    assert.match(module, new RegExp(state.replace('-', '\\-')));
  }
  for (const file of ['before-local.xml', 'before-effective.xml', 'candidate.xml', 'state.json']) {
    assert.match(module, new RegExp(file.replace('.', '\\.')));
  }
});

test('release workflow contains an individual Windows Desktop Survival requirement before publication', () => {
  const workflow = read('.github/workflows/release-scripts.yml');
  assert.match(workflow, /Windows Desktop Survival/);
  assert.match(workflow, /validate-windows-desktop-survival-evidence\.mjs/);
  assert.match(workflow, /needs:\s*[^\n]*windows-desktop-survival/);
});

test('desktop harness is controller-only and existing installer lanes can preserve state', () => {
  const harness = read('tests/e2e/ci/run-windows-desktop-survival.ps1');
  const exeLane = read('tests/e2e/ci/run-windows-offline-installer-exe.ps1');
  const httpLane = read('tests/e2e/ci/run-windows-personalized-offline-installer-e2e.ps1');
  assert.match(harness, /BLOCKED_PLATFORM_VALIDATION/);
  assert.match(harness, /DisposableWindowsTarget\.psm1/);
  assert.doesNotMatch(harness, /Set-AppLockerPolicy|Restart-Computer/);
  assert.match(exeLane, /PreserveInstallation/);
  assert.match(httpLane, /PreserveInstallation/);
});

test('web-generated installer payload selects strict profile with an empty additional catalog', () => {
  const service = read('api/src/services/windows-offline-installer-artifact.service.ts');
  assert.match(service, /appControlProfile:\s*['"]StrictApplicationAllowlist['"]/);
  assert.match(
    service,
    /approvedApplicationCatalog:\s*\{\s*schemaVersion:\s*1,\s*applications:\s*\[\]\s*\}/
  );
  const offline = read('windows/lib/install/Installer.Offline.ps1');
  assert.match(offline, /AppControlProfile/);
  assert.match(offline, /ApprovedApplicationCatalog/);
});
