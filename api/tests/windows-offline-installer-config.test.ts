import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { chmod, mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';

import {
  loadWindowsOfflineInstallerConfig,
  WindowsOfflineInstallerConfigError,
} from '../src/lib/windows-offline-installer-config.js';
import {
  loadCachedWindowsOfflineTemplate,
  WindowsOfflineTemplateCacheError,
} from '../src/lib/windows-offline-installer-template.js';
import {
  checkWindowsOfflineInstallerReadiness,
  resetWindowsOfflineInstallerReadinessCache,
} from '../src/lib/windows-offline-installer-readiness.js';

const TEMPLATE_VERSION = '4.1.0';
const TEMPLATE_COMMIT = 'a'.repeat(40);

async function withTempRoot(run: (root: string) => Promise<void>): Promise<void> {
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-windows-installer-config-'));
  try {
    await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

function baseEnv(root: string): Record<string, string> {
  return {
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: path.join(root, 'templates'),
    OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: path.join(root, 'artifacts'),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: TEMPLATE_VERSION,
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: TEMPLATE_COMMIT,
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: 'b'.repeat(64),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.1.0-aaaaaaa',
    PUBLIC_URL: 'https://openpath.example.test',
  };
}

void describe('OpenPath Windows offline installer configuration', () => {
  void test('loads a pinned template and separate artifact roots', async () => {
    await withTempRoot((root) => {
      const config = loadWindowsOfflineInstallerConfig(baseEnv(root));

      assert.equal(config.templateVersion, TEMPLATE_VERSION);
      assert.equal(config.templateCommit, TEMPLATE_COMMIT);
      assert.equal(config.templateReleaseTag, 'scripts-v4.1.0-aaaaaaa');
      assert.equal(config.templateDir, path.join(root, 'templates'));
      assert.equal(config.artifactsDir, path.join(root, 'artifacts'));
      assert.equal(config.openpathUrl, 'https://openpath.example.test');
      return Promise.resolve();
    });
  });

  void test('fails closed for missing pins, malformed digests, or latest tags', async () => {
    await withTempRoot((root) => {
      assert.throws(
        () =>
          loadWindowsOfflineInstallerConfig({
            ...baseEnv(root),
            OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: 'not-a-digest',
          }),
        WindowsOfflineInstallerConfigError
      );

      assert.throws(
        () =>
          loadWindowsOfflineInstallerConfig({
            ...baseEnv(root),
            OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'latest',
          }),
        /exact release tag/i
      );

      assert.throws(
        () =>
          loadWindowsOfflineInstallerConfig({
            ...baseEnv(root),
            OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: 'not-a-commit',
          }),
        /40-character/i
      );
      return Promise.resolve();
    });
  });

  void test('requires the release tag to identify the configured version and commit', () => {
    assert.throws(
      () =>
        loadWindowsOfflineInstallerConfig({
          ...baseEnv('/tmp/openpath-installer-root'),
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.2.0-aaaaaaa',
        }),
      /RELEASE_TAG/i
    );

    assert.throws(
      () =>
        loadWindowsOfflineInstallerConfig({
          ...baseEnv('/tmp/openpath-installer-root'),
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.1.0-ggggggg',
        }),
      /RELEASE_TAG/i
    );

    assert.throws(
      () =>
        loadWindowsOfflineInstallerConfig({
          ...baseEnv('/tmp/openpath-installer-root'),
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.1.0-bbbbbbb',
        }),
      /RELEASE_TAG/i
    );

    assert.equal(
      loadWindowsOfflineInstallerConfig({
        ...baseEnv('/tmp/openpath-installer-root'),
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.1.0-aaaaaaa',
      }).templateReleaseTag,
      'scripts-v4.1.0-aaaaaaa'
    );
    assert.equal(
      loadWindowsOfflineInstallerConfig({
        ...baseEnv('/tmp/openpath-installer-root'),
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: `scripts-v4.1.0-${'a'.repeat(12)}`,
      }).templateReleaseTag,
      `scripts-v4.1.0-${'a'.repeat(12)}`
    );
  });

  void test('rejects nested template and artifact roots', () => {
    assert.throws(
      () =>
        loadWindowsOfflineInstallerConfig({
          ...baseEnv('/tmp/openpath-installer-root'),
          OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR:
            '/tmp/openpath-installer-root/templates/artifacts',
        }),
      WindowsOfflineInstallerConfigError
    );
  });
});

void describe('OpenPath Windows offline installer template verification', () => {
  void test('requires sidecar and verifies both sidecar and template bytes', async () => {
    await withTempRoot(async (root) => {
      const templateDir = path.join(root, TEMPLATE_VERSION, TEMPLATE_COMMIT);
      await mkdir(templateDir, { recursive: true });
      const templatePath = path.join(templateDir, 'OpenPath-Windows-Setup-Template.exe');
      const templateBytes = Buffer.from('MZ-pinned-template');
      const digest = createHash('sha256').update(templateBytes).digest('hex');
      await writeFile(templatePath, templateBytes);
      await writeFile(`${templatePath}.sha256`, `${digest}  OpenPath-Windows-Setup-Template.exe\n`);

      const loaded = loadCachedWindowsOfflineTemplate(root, {
        version: TEMPLATE_VERSION,
        commit: TEMPLATE_COMMIT,
        sha256: digest,
      });
      assert.equal(loaded.filePath, templatePath);
      assert.equal(loaded.sha256, digest);

      await writeFile(`${templatePath}.sha256`, `${'c'.repeat(64)}  template.exe\n`);
      assert.throws(
        () =>
          loadCachedWindowsOfflineTemplate(root, {
            version: TEMPLATE_VERSION,
            commit: TEMPLATE_COMMIT,
            sha256: digest,
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineTemplateCacheError &&
          error.code === 'SIDECAR_HASH_MISMATCH'
      );
    });
  });
});

void describe('OpenPath Windows offline installer readiness', () => {
  void test('verifies unchanged templates once and never needs network access', async () => {
    await withTempRoot(async (root) => {
      const templateDir = path.join(root, 'templates', TEMPLATE_VERSION, TEMPLATE_COMMIT);
      const artifactsDir = path.join(root, 'artifacts');
      await mkdir(templateDir, { recursive: true });
      await mkdir(artifactsDir, { recursive: true });
      const templatePath = path.join(templateDir, 'OpenPath-Windows-Setup-Template.exe');
      const templateBytes = Buffer.from('MZ-readiness-template');
      const digest = createHash('sha256').update(templateBytes).digest('hex');
      await writeFile(templatePath, templateBytes);
      await writeFile(`${templatePath}.sha256`, `${digest}  template.exe\n`);
      await writeFile(
        `${templatePath}.provenance.json`,
        `${JSON.stringify({
          version: TEMPLATE_VERSION,
          commit: TEMPLATE_COMMIT,
          releaseTag: 'scripts-v4.1.0-aaaaaaa',
          sha256: digest,
        })}\n`
      );
      await chmod(templateDir, 0o755);
      await chmod(templatePath, 0o644);

      resetWindowsOfflineInstallerReadinessCache();
      let hashCalls = 0;
      const env = {
        ...baseEnv(root),
        OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: digest,
      };
      const options = {
        env,
        hashTemplateFile: (filePath: string): string => {
          hashCalls += 1;
          return createHash('sha256').update(readFileSync(filePath)).digest('hex');
        },
        probeArtifactsWrite: (): void => undefined,
      };

      assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), { ready: true, code: 'OK' });
      assert.deepEqual(checkWindowsOfflineInstallerReadiness(options), { ready: true, code: 'OK' });
      assert.equal(hashCalls, 1);
    });
  });
});
