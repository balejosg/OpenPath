import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

import { validateEvidence } from '../scripts/lib/windows-personalized-offline-installer-evidence.mjs';

const cli = path.resolve('scripts/validate-windows-personalized-offline-installer-evidence.mjs');

const successEvidence = {
  status: 'generated',
  runner: 'windows-2025-runner-01',
  generateStatus: 200,
  downloadStatus: 200,
  downloadBytes: 1048576,
  downloadSha256: 'a'.repeat(64),
  downloadHeadersVerified: true,
  replayStatus: 410,
  trailerValidated: true,
  payloadManifestValidated: null,
  pendingStateObserved: null,
  retryOutcome: 'not-run',
  pendingStateCleared: null,
  uninstalled: null,
  installationPreserved: true,
};

const failureEvidence = {
  status: 'failed',
  code: 'windows-personalized-offline-installer-e2e-failed',
  failureStage: 'http-generate-download-replay',
  failureCode: 'canary-result-download-status',
  physicalExeFailure: {
    status: 'failed',
    code: 'physical-exe-e2e-failed',
    failureStage: 'install',
    failureDetailCode: 'installer-exit-1',
    installerExitCode: 1,
  },
  runner: 'windows-2025-runner-01',
};

test('accepts success and failure evidence written by the lane', () => {
  assert.doesNotThrow(() => validateEvidence(successEvidence));
  assert.doesNotThrow(() => validateEvidence(failureEvidence));
});

const forbiddenCases = [
  {
    name: 'credential field name in a key',
    fixture: { status: 'ok', enrollmentToken: 'synthetic-credential-value' },
    category: 'credential-field',
    path: '$.enrollmentToken',
  },
  {
    name: 'credential field name in a value',
    fixture: { status: 'ok', note: 'contains accessToken in free text' },
    category: 'credential-field',
    path: '$.note',
  },
  {
    name: 'Bearer scheme',
    fixture: { status: 'ok', note: 'Bearer synthetic-bearer-value' },
    category: 'bearer-scheme',
    path: '$.note',
  },
  {
    name: 'JWT value',
    fixture: {
      status: 'ok',
      descriptor: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ.c2lnbmF0dXJl',
    },
    category: 'token-value',
    path: '$.descriptor',
  },
  {
    name: 'opaque token value',
    fixture: {
      status: 'ok',
      descriptor: 'SyntheticToken0123456789AbCdEf0123456789',
    },
    category: 'token-value',
    path: '$.descriptor',
  },
  {
    name: 'log path',
    fixture: { status: 'ok', note: 'C:\\runner\\temp\\api.err.log' },
    category: 'log-path',
    path: '$.note',
  },
  {
    name: 'log content',
    fixture: {
      status: 'ok',
      output: '2026-11-17T10:00:00Z INFO synthetic log line',
    },
    category: 'log-content',
    path: '$.output',
  },
  {
    name: 'exception message value',
    fixture: {
      status: 'failed',
      detail: 'System.InvalidOperationException: synthetic failure',
    },
    category: 'exception-message',
    path: '$.detail',
  },
  {
    name: 'exception message key',
    fixture: { status: 'failed', exceptionMessage: 'synthetic exception text' },
    category: 'exception-message',
    path: '$.exceptionMessage',
  },
  {
    name: 'nested array value',
    fixture: {
      status: 'ok',
      result: {
        items: [{ ok: true }, { nested: { note: 'Bearer synthetic-nested' } }],
      },
    },
    category: 'bearer-scheme',
    path: '$.result.items[1].nested.note',
  },
];

for (const forbiddenCase of forbiddenCases) {
  test(`rejects ${forbiddenCase.name}`, () => {
    assert.throws(
      () => validateEvidence(forbiddenCase.fixture),
      (error) => {
        assert.match(error.message, /evidence rejected/);
        assert.ok(
          error.message.includes(`${forbiddenCase.category} at ${forbiddenCase.path}`),
          `expected ${forbiddenCase.category} at ${forbiddenCase.path}, got: ${error.message}`
        );
        return true;
      }
    );
  });
}

test('CLI accepts valid evidence and reports success without values', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'openpath personalized evidence # % '));
  try {
    const evidence = path.join(root, 'windows-personalized-offline-installer-evidence.json');
    writeFileSync(evidence, JSON.stringify(successEvidence));
    const result = spawnSync(process.execPath, [cli, '--evidence', evidence], {
      cwd: process.cwd(),
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /evidence valid/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('CLI reports only category and key path for rejected evidence', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'openpath personalized evidence # % '));
  try {
    const evidence = path.join(root, 'windows-personalized-offline-installer-evidence.json');
    const secret = 'Bearer synthetic-cli-secret';
    writeFileSync(evidence, JSON.stringify({ note: secret }));
    const result = spawnSync(process.execPath, [cli, '--evidence', evidence], {
      cwd: process.cwd(),
      encoding: 'utf8',
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /bearer-scheme at \$\.note/);
    assert.ok(!result.stderr.includes(secret));
    assert.ok(!result.stdout.includes(secret));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('CLI rejects invalid JSON without echoing its contents', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'openpath personalized evidence # % '));
  try {
    const evidence = path.join(root, 'windows-personalized-offline-installer-evidence.json');
    const secret = 'Bearer synthetic-invalid-json-secret';
    writeFileSync(evidence, `{"note":"${secret}",}`);
    const result = spawnSync(process.execPath, [cli, '--evidence', evidence], {
      cwd: process.cwd(),
      encoding: 'utf8',
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /not valid JSON/);
    assert.ok(!result.stderr.includes(secret));
    assert.ok(!result.stdout.includes(secret));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
