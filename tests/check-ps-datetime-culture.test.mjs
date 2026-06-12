import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { describe, test } from 'node:test';

const projectRoot = resolve(new URL('.', import.meta.url).pathname, '..');
const checker = resolve(projectRoot, 'scripts/check-ps-datetime-culture.mjs');

function runChecker(args) {
  return spawnSync(process.execPath, [checker, ...args], {
    cwd: projectRoot,
    encoding: 'utf8',
  });
}

function withTempDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'openpath-ps-culture-'));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('PS DateTime culture guard', () => {
  test('compliant file passes (exit 0)', () => {
    withTempDir((dir) => {
      const ps1 = join(dir, 'good.ps1');
      writeFileSync(
        ps1,
        [
          '    $dt = [DateTime]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)',
          "    $dt2 = [DateTime]::ParseExact($s, 'yyyyMMdd', [CultureInfo]::InvariantCulture)",
        ].join('\n'),
        'utf8'
      );

      const result = runChecker([ps1]);
      assert.equal(result.status, 0, `expected exit 0, stderr: ${result.stderr}`);
      assert.match(result.stdout, /passed/i);
    });
  });

  test('violating file fails (exit 1) and output names the file and line', () => {
    withTempDir((dir) => {
      const ps1 = join(dir, 'bad.ps1');
      writeFileSync(
        ps1,
        ['# some header', '    $dt = [DateTime]::Parse($someString)', '    Write-Host "done"'].join(
          '\n'
        ),
        'utf8'
      );

      const result = runChecker([ps1]);
      assert.equal(result.status, 1, `expected exit 1, stdout: ${result.stdout}`);
      const combined = result.stdout + result.stderr;
      assert.ok(combined.includes('bad.ps1'), `output should name the file; got: ${combined}`);
      assert.ok(combined.includes(':2:'), `output should include line number 2; got: ${combined}`);
    });
  });

  test('ps-culture-allow exempted file passes (exit 0)', () => {
    withTempDir((dir) => {
      const ps1 = join(dir, 'allowed.ps1');
      writeFileSync(
        ps1,
        [
          '    # ps-culture-allow: numeric-only ISO input, locale-safe',
          '    $dt = [DateTime]::Parse($numericOnly)',
          '    $dt2 = [DateTime]::Parse($x) # ps-culture-allow: verified safe format',
        ].join('\n'),
        'utf8'
      );

      const result = runChecker([ps1]);
      assert.equal(result.status, 0, `expected exit 0, stderr: ${result.stderr}`);
    });
  });

  test('--self-check passes (exit 0)', () => {
    const result = runChecker(['--self-check']);
    assert.equal(result.status, 0, `--self-check failed: ${result.stdout}${result.stderr}`);
    assert.match(result.stdout, /self-check passed/i);
  });

  test('nonexistent file arg does not crash (exit 0)', () => {
    const result = runChecker(['/nonexistent/path/that/does/not/exist.ps1']);
    assert.equal(
      result.status,
      0,
      `expected exit 0 for nonexistent file; stderr: ${result.stderr}`
    );
  });
});
