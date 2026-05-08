import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test } from 'node:test';

const currentFilePath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(currentFilePath), '..');

describe('Windows self-hosted runner reset contract', () => {
  test('kills stale OpenPath PowerShell update workers before removing state', () => {
    const resetScript = readFileSync(
      resolve(repoRoot, 'tests/e2e/ci/reset-self-hosted-windows-runner.ps1'),
      'utf8'
    );

    assert.match(resetScript, /C:\\OpenPath\\scripts\\Update-OpenPath\.ps1/);
    assert.match(resetScript, /C:\\OpenPath\\scripts\\Start-SSEListener\.ps1/);
    assert.ok(
      resetScript.indexOf('Get-CimInstance Win32_Process') < resetScript.indexOf("'C:\\OpenPath'")
    );
  });
});
