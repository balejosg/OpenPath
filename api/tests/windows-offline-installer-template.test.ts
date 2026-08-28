import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
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

void test('template loader fails closed on a symlinked pinned path', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-loader-link-'));
  const outside = await mkdtemp(path.join(tmpdir(), 'openpath-template-loader-outside-'));
  const version = '4.1.0';
  const commit = 'e'.repeat(40);
  const bytes = Buffer.from('outside-template');
  const digest = createHash('sha256').update(bytes).digest('hex');

  try {
    const outsideCommitDir = path.join(outside, commit);
    await mkdir(outsideCommitDir, { recursive: true });
    const outsideTemplatePath = path.join(outsideCommitDir, 'OpenPath-Windows-Setup-Template.exe');
    await writeFile(outsideTemplatePath, bytes);
    await writeFile(`${outsideTemplatePath}.sha256`, `${digest}  template.exe\n`);
    await symlink(outside, path.join(root, version), 'dir');

    assert.throws(
      () => loadCachedWindowsOfflineTemplate(root, { version, commit, sha256: digest }),
      (error: unknown) =>
        error instanceof WindowsOfflineTemplateCacheError && error.code === 'TEMPLATE_MISSING'
    );
  } finally {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  }
});

void test('template loader rejects unsafe or incomplete generation pointers without legacy fallback', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-loader-generation-'));
  const version = '4.1.0';
  const commit = 'f'.repeat(40);
  const commitDirectory = path.join(root, version, commit);
  const templatePath = path.join(commitDirectory, 'OpenPath-Windows-Setup-Template.exe');
  const bytes = Buffer.from('legacy bytes must not bypass pointer failure');
  const digest = createHash('sha256').update(bytes).digest('hex');

  try {
    await mkdir(commitDirectory, { recursive: true });
    await writeFile(templatePath, bytes);
    await writeFile(`${templatePath}.sha256`, `${digest}  template.exe\n`);
    await writeFile(path.join(commitDirectory, '.current'), '../escape\n');

    assert.throws(
      () => loadCachedWindowsOfflineTemplate(root, { version, commit, sha256: digest }),
      (error: unknown) =>
        error instanceof WindowsOfflineTemplateCacheError && error.code === 'TEMPLATE_MISSING'
    );

    await rm(path.join(commitDirectory, '.current'));
    const outside = await mkdtemp(
      path.join(tmpdir(), 'openpath-template-loader-generation-outside-')
    );
    try {
      await mkdir(path.join(commitDirectory, 'generations'), { recursive: true });
      const generationName = 'generation-ffffffff-ffff-ffff-ffff-ffffffffffff';
      await symlink(outside, path.join(commitDirectory, 'generations', generationName), 'dir');
      await writeFile(path.join(commitDirectory, '.current'), `${generationName}\n`);

      assert.throws(
        () => loadCachedWindowsOfflineTemplate(root, { version, commit, sha256: digest }),
        (error: unknown) =>
          error instanceof WindowsOfflineTemplateCacheError && error.code === 'TEMPLATE_MISSING'
      );
    } finally {
      await rm(outside, { recursive: true, force: true });
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
