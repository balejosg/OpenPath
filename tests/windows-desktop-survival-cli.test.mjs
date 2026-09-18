import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';

const cli = path.resolve('scripts/validate-windows-desktop-survival-evidence.mjs');
const sha = 'a'.repeat(64);
const source = '24b2009acf8c1e942060d26cf258fb23f657efa8';

function run(args, cwd) {
  return spawnSync(process.execPath, [cli, ...args], { cwd, encoding: 'utf8' });
}

test('CLI rejects invalid JSON and strict argument errors from a path with spaces and percent signs', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'openpath cli # % Unicode '));
  try {
    const evidence = path.join(root, 'invalid.json');
    writeFileSync(evidence, '{}');
    const common = [
      '--evidence',
      evidence,
      '--evidence-root',
      root,
      '--source-sha',
      source,
      '--template-sha256',
      sha,
      '--personalized-exe-sha256',
      sha,
      '--run-id',
      'run-1',
      '--run-attempt',
      '1',
    ];
    const invalid = run(common, process.cwd());
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /schemaVersion|rejected/);
    const unknown = run([...common, '--unexpected', 'value'], process.cwd());
    assert.notEqual(unknown.status, 0);
    assert.match(unknown.stderr, /unknown argument/);
    const duplicate = run([...common, '--run-id', 'again'], process.cwd());
    assert.notEqual(duplicate.status, 0);
    assert.match(duplicate.stderr, /duplicate argument/);
    const missing = run(common.slice(0, -2), process.cwd());
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /run-attempt/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('importing the evidence library does not execute the CLI', () => {
  const result = spawnSync(
    process.execPath,
    [
      '--input-type=module',
      '-e',
      "import './scripts/lib/windows-desktop-survival-evidence.mjs'; console.log('imported')",
    ],
    {
      cwd: process.cwd(),
      encoding: 'utf8',
    }
  );
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), 'imported');
});
