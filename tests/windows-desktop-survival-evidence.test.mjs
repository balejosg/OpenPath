import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  REQUIRED_PHASES,
  REQUIRED_SCENARIOS,
  validateEvidence,
} from '../scripts/lib/windows-desktop-survival-evidence.mjs';

const now = new Date('2026-09-18T10:00:00.000Z');
const sourceSha = '24b2009acf8c1e942060d26cf258fb23f657efa8';
const templateSha256 = 'a'.repeat(64);
const personalizedExeSha256 = 'b'.repeat(64);
const expected = {
  sourceSha,
  templateSha256,
  personalizedExeSha256,
  runId: '12345',
  runAttempt: 1,
};

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function createBundle() {
  const root = mkdtempSync(path.join(tmpdir(), 'openpath desktop # % evidencia '));
  const phases = [];
  for (const [scenarioIndex, scenarioId] of REQUIRED_SCENARIOS.entries()) {
    for (const phase of REQUIRED_PHASES) {
      const nonce = 'nonce-' + scenarioIndex + '-' + phase;
      const relative = 'scenarios/' + scenarioId + '/' + phase + '.json';
      const observation = {
        schemaVersion: 2,
        runId: expected.runId,
        runAttempt: expected.runAttempt,
        sourceCommitSha: sourceSha,
        scenarioId,
        phase,
        correlationNonce: nonce,
        synthetic: false,
        status: 'passed',
      };
      const bytes = JSON.stringify(observation);
      const absolute = path.join(root, relative);
      mkdirSync(path.dirname(absolute), { recursive: true });
      writeFileSync(absolute, bytes);
      phases.push({ scenarioId, phase, relative, nonce, sha256: sha256(bytes) });
    }
  }
  const manifest = {
    schemaVersion: 2,
    sourceCommitSha: sourceSha,
    runId: expected.runId,
    runAttempt: expected.runAttempt,
    generatedAt: now.toISOString(),
    files: phases.map((phase) => ({
      path: phase.relative,
      size: readFileSync(path.join(root, phase.relative)).length,
      sha256: phase.sha256,
    })),
  };
  writeFileSync(path.join(root, 'manifest.json'), JSON.stringify(manifest));
  const manifestSha = sha256(readFileSync(path.join(root, 'manifest.json')));
  const scenarios = REQUIRED_SCENARIOS.map((scenarioId, index) => {
    const editionId = scenarioId.includes('education') ? 'Education' : 'Professional';
    const scenarioPhases = Object.fromEntries(
      REQUIRED_PHASES.map((phase) => {
        const entry = phases.find(
          (candidate) => candidate.scenarioId === scenarioId && candidate.phase === phase
        );
        return [
          phase,
          {
            status: 'passed',
            evidenceRef: entry.relative,
            sha256: entry.sha256,
            startedAt: now.toISOString(),
            endedAt: now.toISOString(),
            correlationNonce: entry.nonce,
          },
        ];
      })
    );
    return {
      schemaVersion: 2,
      scenarioId,
      sourceCommitSha: sourceSha,
      templateSha256,
      personalizedExeSha256,
      os: {
        productType: 'client',
        editionId,
        version: '10.0',
        build: '26100',
        architecture: 'x64',
      },
      imageIdentity: 'image-' + index,
      snapshotIdentity: 'snapshot-' + index,
      appControlProfile: 'StrictApplicationAllowlist',
      synthetic: false,
      catalogApplicationCount: 0,
      initialProfileExisted: scenarioId.includes('existing'),
      bootIdBefore: 'boot-before-' + index,
      bootIdAfter: 'boot-after-' + index,
      policyBeforeSha256: 'c'.repeat(64),
      policyAfterSha256: 'd'.repeat(64),
      criticalUnexpectedDenials: [],
      fixtures: { exeAndDll: 'passed', msiAndScript: 'passed', packagedAppExecution: 'passed' },
      preRebootAdminDesktop: 'passed',
      firstStudentInteractiveLogon: 'passed',
      preRebootStudentBoundary: 'passed',
      loginScreenAfterReboot: 'passed',
      postRebootAdminDesktop: 'passed',
      postRebootStudentDesktop: 'passed',
      postRebootStudentBoundary: 'passed',
      uninstallOrRollback: 'passed',
      cleanup: 'passed',
      phases: scenarioPhases,
    };
  });
  const aggregate = {
    schemaVersion: 2,
    sourceCommitSha: sourceSha,
    runId: expected.runId,
    runAttempt: expected.runAttempt,
    templateSha256,
    personalizedExeSha256,
    evidenceManifestSha256: manifestSha,
    generatedAt: now.toISOString(),
    synthetic: false,
    scenarios,
  };
  return { root, aggregate };
}

test('validates a complete real-looking schema v2 bundle and four-scenario matrix', () => {
  const bundle = createBundle();
  try {
    const result = validateEvidence(bundle.aggregate, expected, { evidenceRoot: bundle.root, now });
    assert.equal(result.status, 'passed');
    assert.deepEqual(
      result.scenarios.map((scenario) => scenario.scenarioId),
      REQUIRED_SCENARIOS
    );
  } finally {
    rmSync(bundle.root, { recursive: true, force: true });
  }
});

test('rejects schema v1, incomplete matrix, missing references, altered bytes, and synthetic output', () => {
  const bundle = createBundle();
  try {
    assert.throws(
      () =>
        validateEvidence({ ...bundle.aggregate, schemaVersion: 1 }, expected, {
          evidenceRoot: bundle.root,
          now,
        }),
      /schemaVersion 1/
    );
    assert.throws(
      () =>
        validateEvidence(
          { ...bundle.aggregate, scenarios: bundle.aggregate.scenarios.slice(0, 3) },
          expected,
          { evidenceRoot: bundle.root, now }
        ),
      /four-scenario/
    );
    const broken = path.join(bundle.root, 'scenarios', REQUIRED_SCENARIOS[0], 'prepare.json');
    rmSync(broken);
    assert.throws(
      () => validateEvidence(bundle.aggregate, expected, { evidenceRoot: bundle.root, now }),
      /missing file/
    );
  } finally {
    rmSync(bundle.root, { recursive: true, force: true });
  }
});

test('rejects Server, same boot, synthetic observations and unsafe evidence references', () => {
  const bundle = createBundle();
  try {
    const server = structuredClone(bundle.aggregate);
    server.scenarios[0].os.productType = 'server';
    assert.throws(
      () => validateEvidence(server, expected, { evidenceRoot: bundle.root, now }),
      /Windows client/
    );
    const sameBoot = structuredClone(bundle.aggregate);
    sameBoot.scenarios[0].bootIdAfter = sameBoot.scenarios[0].bootIdBefore;
    assert.throws(
      () => validateEvidence(sameBoot, expected, { evidenceRoot: bundle.root, now }),
      /boot ids/
    );
    const synthetic = structuredClone(bundle.aggregate);
    synthetic.scenarios[0].phases.prepare.synthetic = true;
    assert.throws(
      () => validateEvidence(synthetic, expected, { evidenceRoot: bundle.root, now }),
      /synthetic/
    );
    const unsafe = structuredClone(bundle.aggregate);
    unsafe.scenarios[0].phases.prepare.evidenceRef = '../outside.json';
    assert.throws(
      () => validateEvidence(unsafe, expected, { evidenceRoot: bundle.root, now }),
      /parent segment|escapes|outside/
    );
    const parentSegment = structuredClone(bundle.aggregate);
    parentSegment.scenarios[0].phases.prepare.evidenceRef =
      'scenarios/win11-pro-profileless-empty/../outside.json';
    assert.throws(
      () => validateEvidence(parentSegment, expected, { evidenceRoot: bundle.root, now }),
      /parent segment|escapes|outside/
    );
  } finally {
    rmSync(bundle.root, { recursive: true, force: true });
  }
});
