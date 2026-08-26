import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, mkdtemp, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  checkWindowsOfflineInstallerReadiness,
  resetWindowsOfflineInstallerReadinessCache,
} from '../src/lib/windows-offline-installer-readiness.js';

const TEMPLATE_VERSION = '4.1.0';
const TEMPLATE_COMMIT = 'a'.repeat(40);

async function withFixture(run: (fixture: ReadinessFixture) => Promise<void>): Promise<void> {
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-readiness-'));
  const templateBytes = Buffer.from('MZ-valid-readiness-template');
  const templateDigest = createHash('sha256').update(templateBytes).digest('hex');
  const templateDirectory = path.join(root, 'templates', TEMPLATE_VERSION, TEMPLATE_COMMIT);
  const artifactsDirectory = path.join(root, 'artifacts');

  await mkdir(templateDirectory, { recursive: true });
  await mkdir(artifactsDirectory, { recursive: true });
  const templatePath = path.join(templateDirectory, 'OpenPath-Windows-Setup-Template.exe');
  await writeFile(templatePath, templateBytes);
  await writeFile(`${templatePath}.sha256`, `${templateDigest}  template.exe\n`);

  try {
    resetWindowsOfflineInstallerReadinessCache();
    await run({
      root,
      templatePath,
      artifactsDirectory,
      templateDigest,
      env: {
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: path.join(root, 'templates'),
        OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: artifactsDirectory,
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: TEMPLATE_VERSION,
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: TEMPLATE_COMMIT,
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: templateDigest,
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.1.0-aaaaaaa',
      },
    });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

interface ReadinessFixture {
  root: string;
  templatePath: string;
  artifactsDirectory: string;
  templateDigest: string;
  env: Record<string, string>;
}

void test('readiness leaves the capability unconfigured when no offline installer pins exist', () => {
  assert.deepEqual(checkWindowsOfflineInstallerReadiness({ env: {} }), {
    ready: true,
    code: 'NOT_CONFIGURED',
  });
});

void test('readiness is OK for a valid template and an existing writable artifacts directory', async () => {
  await withFixture(async ({ env, artifactsDirectory }) => {
    assert.deepEqual(checkWindowsOfflineInstallerReadiness({ env }), { ready: true, code: 'OK' });

    const leftovers = (await readdir(artifactsDirectory)).filter((name) =>
      name.startsWith('.openpath-readiness-')
    );
    assert.deepEqual(leftovers, []);
  });
});

void test('readiness reports an unavailable artifacts root when it does not exist', async () => {
  await withFixture(async ({ env, artifactsDirectory }) => {
    await rm(artifactsDirectory, { recursive: true, force: true });

    assert.deepEqual(checkWindowsOfflineInstallerReadiness({ env }), {
      ready: false,
      code: 'ARTIFACTS_DIR_UNAVAILABLE',
    });
  });
});

void test('readiness reports an unavailable artifacts root when the path is not a directory', async () => {
  await withFixture(async ({ env, artifactsDirectory }) => {
    await rm(artifactsDirectory, { recursive: true, force: true });
    await writeFile(artifactsDirectory, 'not a directory');

    assert.deepEqual(checkWindowsOfflineInstallerReadiness({ env }), {
      ready: false,
      code: 'ARTIFACTS_DIR_UNAVAILABLE',
    });
  });
});

void test('readiness reports a non-writable artifacts root when the real write probe fails', async () => {
  await withFixture(async ({ env, artifactsDirectory }) => {
    let probedPath = '';
    assert.deepEqual(
      checkWindowsOfflineInstallerReadiness({
        env,
        probeArtifactsWrite: (directory) => {
          probedPath = directory;
          throw new Error('simulated write failure');
        },
      }),
      { ready: false, code: 'ARTIFACTS_DIR_NOT_WRITABLE' }
    );
    assert.equal(probedPath, artifactsDirectory);
    return Promise.resolve();
  });
});

void test('readiness reuses the full template hash for an unchanged template', async () => {
  await withFixture(async ({ env, templatePath }) => {
    let hashCalls = 0;
    const options = {
      env,
      hashTemplateFile: (filePath: string): string => {
        hashCalls += 1;
        return createHash('sha256').update(readFileSync(filePath)).digest('hex');
      },
    };

    assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), { ready: true, code: 'OK' });
    assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), { ready: true, code: 'OK' });
    assert.equal(hashCalls, 1);
    assert.equal((await stat(templatePath)).isFile(), true);
  });
});

void test('readiness revalidates when the template sidecar identity changes', async () => {
  await withFixture(async ({ env, templatePath, templateDigest }) => {
    let hashCalls = 0;
    const options = {
      env,
      hashTemplateFile: (filePath: string): string => {
        hashCalls += 1;
        return createHash('sha256').update(readFileSync(filePath)).digest('hex');
      },
    };

    assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), { ready: true, code: 'OK' });
    await writeFile(`${templatePath}.sha256`, `${templateDigest}  changed-template-name.exe\n`);

    assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), {
      ready: true,
      code: 'OK',
    });
    assert.equal(hashCalls, 2);
  });
});

void test('readiness fails closed when a changed template no longer matches its pin', async () => {
  await withFixture(async ({ env, templatePath }) => {
    const options = { env };
    assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), { ready: true, code: 'OK' });
    await writeFile(templatePath, 'MZ-corrupted-template');

    assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), {
      ready: false,
      code: 'TEMPLATE_HASH_MISMATCH',
    });
  });
});
