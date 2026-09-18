import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { validateContrastEvidence } from '../scripts/validate-windows-policy-converter-contrast-evidence.mjs';

const expected = {
  sourceSha: '24b2009acf8c1e942060d26cf258fb23f657efa8',
  templateSha256: 'a'.repeat(64),
  personalizedExeSha256: 'b'.repeat(64),
  runId: '12345',
  runAttempt: 1,
};

function sha(value) {
  return createHash('sha256').update(value).digest('hex');
}

function bundle(mode = 'Untouched') {
  const root = mkdtempSync(path.join(tmpdir(), 'openpath-contrast-evidence-'));
  const scenarioId = 'win11-policy-converter-' + mode.toLowerCase();
  const timestamp = '2026-09-18T12:00:00.000Z';
  const phaseRecords = {};
  const files = [];
  for (const phase of ['prepare', 'observe', 'afterReboot', 'cleanup']) {
    const nonce = 'nonce-' + phase;
    const relative = `run/${scenarioId}/${phase}-observation.json`;
    const observation = {
      schemaVersion: 2,
      status: 'passed',
      runId: expected.runId,
      runAttempt: expected.runAttempt,
      sourceCommitSha: expected.sourceSha,
      scenarioId,
      phase,
      correlationNonce: nonce,
      synthetic: false,
    };
    const bytes = JSON.stringify(observation);
    const absolute = path.join(root, relative);
    mkdirSync(path.dirname(absolute), { recursive: true });
    writeFileSync(absolute, bytes);
    const hash = sha(bytes);
    files.push({ path: relative, size: Buffer.byteLength(bytes), sha256: hash });
    phaseRecords[phase] = {
      status: 'passed',
      evidenceRef: relative,
      sha256: hash,
      correlationNonce: nonce,
      startedAt: timestamp,
      endedAt: timestamp,
    };
  }
  const manifest = {
    schemaVersion: 2,
    suiteKind: 'PolicyConverterContrast',
    policyConverterMode: mode,
    sourceCommitSha: expected.sourceSha,
    runId: expected.runId,
    runAttempt: expected.runAttempt,
    generatedAt: timestamp,
    files,
  };
  const manifestName = `contrast-${mode.toLowerCase()}-manifest.json`;
  writeFileSync(path.join(root, manifestName), JSON.stringify(manifest));
  const manifestHash = sha(readFileSync(path.join(root, manifestName)));
  const aggregate = {
    schemaVersion: 2,
    suiteKind: 'PolicyConverterContrast',
    policyConverterMode: mode,
    sourceCommitSha: expected.sourceSha,
    runId: expected.runId,
    runAttempt: expected.runAttempt,
    templateSha256: expected.templateSha256,
    personalizedExeSha256: expected.personalizedExeSha256,
    evidenceManifestSha256: manifestHash,
    generatedAt: timestamp,
    synthetic: false,
    scenarioId,
    phases: phaseRecords,
  };
  return { root, aggregate };
}

test('validates a complete contrast phase bundle', () => {
  const value = bundle();
  try {
    assert.equal(
      validateContrastEvidence(
        value.aggregate,
        { ...expected, mode: 'Untouched', manifestName: 'contrast-untouched-manifest.json' },
        value.root
      ).status,
      'passed'
    );
  } finally {
    rmSync(value.root, { recursive: true, force: true });
  }
});

test('rejects synthetic observations and wrong mode', () => {
  const value = bundle('Started');
  try {
    const synthetic = structuredClone(value.aggregate);
    synthetic.synthetic = true;
    assert.throws(
      () =>
        validateContrastEvidence(
          synthetic,
          { ...expected, mode: 'Started', manifestName: 'contrast-started-manifest.json' },
          value.root
        ),
      /synthetic/
    );
    assert.throws(
      () =>
        validateContrastEvidence(
          value.aggregate,
          { ...expected, mode: 'Untouched', manifestName: 'contrast-untouched-manifest.json' },
          value.root
        ),
      /policyConverterMode/
    );
  } finally {
    rmSync(value.root, { recursive: true, force: true });
  }
});
