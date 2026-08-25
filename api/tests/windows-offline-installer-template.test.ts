import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  loadCachedWindowsOfflineTemplate,
  WindowsOfflineTemplateCacheError,
} from '../src/lib/windows-offline-installer-template.js';

void test('template loader accepts only the exact version and commit with a matching sidecar', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-loader-'));
  const version = '4.1.0';
  const commit = 'd'.repeat(40);
  const templateDir = path.join(root, version, commit);
  const templatePath = path.join(templateDir, 'OpenPath-Windows-Setup-Template.exe');
  const bytes = Buffer.from('pinned-template');
  const digest = createHash('sha256').update(bytes).digest('hex');

  try {
    await mkdir(templateDir, { recursive: true });
    await writeFile(templatePath, bytes);
    await writeFile(`${templatePath}.sha256`, `${digest}  ${path.basename(templatePath)}\n`);

    const loaded = loadCachedWindowsOfflineTemplate(root, { version, commit, sha256: digest });
    assert.equal(loaded.filePath, templatePath);
    assert.equal(loaded.sha256, digest);

    await writeFile(`${templatePath}.sha256`, 'not-a-sha256 template.exe\n');
    assert.throws(
      () => loadCachedWindowsOfflineTemplate(root, { version, commit, sha256: digest }),
      (error: unknown) =>
        error instanceof WindowsOfflineTemplateCacheError && error.code === 'SIDECAR_INVALID'
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
