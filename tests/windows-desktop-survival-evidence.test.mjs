import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const validator = 'scripts/validate-windows-desktop-survival-evidence.mjs';
const sourceSha = 'a'.repeat(40);
const templateSha256 = 'b'.repeat(64);
const personalizedExeSha256 = 'c'.repeat(64);
const runId = 'run-2026-09-18-001';

function evidence(overrides = {}) {
  return {
    schemaVersion: 1,
    sourceCommitSha: sourceSha,
    templateSha256,
    personalizedExeSha256,
    runId,
    generatedAt: '2026-09-18T00:00:00.000Z',
    os: { productType: 'client', edition: 'Pro', build: '26100.1', architecture: 'x64' },
    appControlProfile: 'StrictApplicationAllowlist',
    catalogApplicationCount: 0,
    initialProfileExisted: false,
    policyBeforeSha256: 'd'.repeat(64),
    policyAfterSha256: 'e'.repeat(64),
    bootIdBefore: 'boot-before',
    bootIdAfter: 'boot-after',
    preRebootAdminDesktop: 'passed',
    firstStudentInteractiveLogon: 'passed',
    preRebootStudentBoundary: 'passed',
    loginScreenAfterReboot: 'passed',
    postRebootAdminDesktop: 'passed',
    postRebootStudentDesktop: 'passed',
    postRebootStudentBoundary: 'passed',
    uninstallOrRollback: 'passed',
    cleanup: 'passed',
    criticalUnexpectedDenials: [],
    fixtures: {
      exeAndDll: 'passed',
      msiAndScript: 'passed',
      packagedAppExecution: 'passed',
    },
    phases: {
      prepare: { status: 'passed', evidenceRef: 'prepare.json' },
      observe: { status: 'passed', evidenceRef: 'observe.json' },
      afterReboot: { status: 'passed', evidenceRef: 'after-reboot.json' },
      cleanup: { status: 'passed', evidenceRef: 'cleanup.json' },
    },
    ...overrides,
  };
}

function run(value, args = {}) {
  const root = mkdtempSync(join(tmpdir(), 'openpath-survival-'));
  const evidencePath = join(root, 'evidence.json');
  writeFileSync(evidencePath, JSON.stringify(value));
  const cliArgs = [
    validator,
    '--evidence',
    evidencePath,
    '--source-sha',
    args.sourceSha ?? sourceSha,
    '--template-sha256',
    args.templateSha256 ?? templateSha256,
    '--personalized-exe-sha256',
    args.personalizedExeSha256 ?? personalizedExeSha256,
    '--run-id',
    args.runId ?? runId,
  ];
  try {
    execFileSync(process.execPath, cliArgs, {
      cwd: process.cwd(),
      encoding: 'utf8',
      stdio: 'pipe',
    });
    return { code: 0 };
  } catch (error) {
    return { code: error.status ?? 1, output: `${error.stdout ?? ''}${error.stderr ?? ''}` };
  }
}

test('accepts complete Pro client evidence with distinct boot ids and phase artifacts', () => {
  assert.equal(run(evidence()).code, 0);
});

test('rejects a green summary when the Windows job was skipped', () => {
  assert.notEqual(
    run(
      evidence({
        phases: {
          ...evidence().phases,
          observe: { status: 'skipped', evidenceRef: 'observe.json' },
        },
      })
    ).code,
    0
  );
});

test('rejects Server even when every phase is marked passed', () => {
  assert.notEqual(run(evidence({ os: { ...evidence().os, productType: 'server' } })).code, 0);
});

test('rejects identical boot ids and mismatched source/template/EXE/run identity', () => {
  assert.notEqual(run(evidence({ bootIdAfter: 'boot-before' })).code, 0);
  assert.notEqual(run(evidence(), { sourceSha: 'f'.repeat(40) }).code, 0);
  assert.notEqual(run(evidence(), { templateSha256: 'f'.repeat(64) }).code, 0);
  assert.notEqual(run(evidence(), { personalizedExeSha256: 'f'.repeat(64) }).code, 0);
  assert.notEqual(run(evidence(), { runId: 'different-run' }).code, 0);
});

test('rejects missing or incorrectly typed required fields and failed cleanup', () => {
  const missing = evidence();
  delete missing.postRebootStudentDesktop;
  assert.notEqual(run(missing).code, 0);
  assert.notEqual(run(evidence({ cleanup: true })).code, 0);
  assert.notEqual(run(evidence({ catalogApplicationCount: '0' })).code, 0);
  assert.notEqual(
    run(evidence({ fixtures: { ...evidence().fixtures, packagedAppExecution: true } })).code,
    0
  );
});

test('requires evidence references for every successful phase and rejects unexpected critical denials', () => {
  const noReference = evidence();
  noReference.phases.prepare = { status: 'passed' };
  assert.notEqual(run(noReference).code, 0);
  assert.notEqual(run(evidence({ criticalUnexpectedDenials: ['runtime'] })).code, 0);
});
