import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { describe, test } from 'node:test';

import { projectRoot } from './support.mjs';

const checker = resolve(projectRoot, 'scripts/check-npm-audit-critical.mjs');

function runChecker(report) {
  const dir = mkdtempSync(join(tmpdir(), 'openpath-audit-check-'));
  const reportPath = join(dir, 'audit-report.json');

  try {
    writeFileSync(reportPath, typeof report === 'string' ? report : JSON.stringify(report), 'utf8');

    return spawnSync(process.execPath, [checker, reportPath], {
      cwd: projectRoot,
      encoding: 'utf8',
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('npm audit critical gate', () => {
  test('allows high vulnerabilities when critical count is zero', () => {
    const result = runChecker({
      metadata: {
        vulnerabilities: {
          info: 0,
          low: 0,
          moderate: 0,
          high: 7,
          critical: 0,
          total: 7,
        },
      },
    });

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /critical=0 high=7/);
  });

  test('fails when npm audit reports critical vulnerabilities', () => {
    const result = runChecker({
      metadata: {
        vulnerabilities: {
          high: 0,
          critical: 1,
          total: 1,
        },
      },
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /found 1 critical npm audit vulnerabilities/);
  });

  test('fails closed for corrupt or non npm-audit JSON', () => {
    const corrupt = runChecker('{');
    assert.equal(corrupt.status, 1);
    assert.match(corrupt.stderr, /could not read valid JSON/);

    const missingShape = runChecker({ vulnerabilities: { critical: 0 } });
    assert.equal(missingShape.status, 1);
    assert.match(missingShape.stderr, /missing metadata\.vulnerabilities/);
  });
});
