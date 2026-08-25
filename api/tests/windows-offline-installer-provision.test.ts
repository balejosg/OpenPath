import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { access, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';

import {
  getWindowsOfflineInstallerTemplatePath,
  loadWindowsOfflineInstallerConfig,
} from '../src/lib/windows-offline-installer-config.js';
import {
  formatProvisionResult,
  provisionWindowsOfflineInstallerTemplate,
  WindowsOfflineInstallerProvisionError,
} from '../src/services/windows-offline-installer-provision.service.js';

function sha256(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function envFor(root: string, digest: string): Record<string, string> {
  return {
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: path.join(root, 'templates'),
    OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: path.join(root, 'artifacts'),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: '4.1.0',
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: 'a'.repeat(40),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: digest,
  };
}

function response(body: Buffer | string, status = 200): Response {
  return new Response(body, { status });
}

function requestUrl(url: string | URL | Request): string {
  if (typeof url === 'string') return url;
  return url instanceof URL ? url.href : url.url;
}

void describe('OpenPath Windows offline installer provisioning', () => {
  void test('verify-only never fetches or repairs a missing pinned template', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-verify-'));
    const env = envFor(root, 'a'.repeat(64));
    let fetchCount = 0;

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            verifyOnly: true,
            fetchImpl: () => {
              fetchCount += 1;
              return Promise.resolve(response('unexpected'));
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError &&
          error.code === 'TEMPLATE_MISSING'
      );
      assert.equal(fetchCount, 0);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('downloads the exact release tag and publishes an atomically verified template', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-provision-'));
    const templateBytes = Buffer.from('deterministic signed template bytes');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const requestedUrls: string[] = [];

    try {
      const result = await provisionWindowsOfflineInstallerTemplate({
        env,
        fetchImpl: (url) => {
          requestedUrls.push(requestUrl(url));
          return Promise.resolve(
            requestUrl(url).endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          );
        },
      });
      const config = loadWindowsOfflineInstallerConfig(env);
      const templatePath = getWindowsOfflineInstallerTemplatePath(config);

      assert.equal(result.status, 'provisioned');
      assert.deepEqual(requestedUrls, [
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe',
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe.sha256',
      ]);
      assert.deepEqual(await readFile(templatePath), templateBytes);
      assert.match(await readFile(`${templatePath}.sha256`, 'utf8'), new RegExp(digest));
      assert.deepEqual((await readdir(path.dirname(templatePath))).sort(), [
        'OpenPath-Windows-Setup-Template.exe',
        'OpenPath-Windows-Setup-Template.exe.sha256',
      ]);

      const cached = await provisionWindowsOfflineInstallerTemplate({
        env,
        fetchImpl: () =>
          Promise.reject(new Error('A verified template must not be downloaded again')),
      });
      assert.deepEqual(cached, {
        status: 'verified',
        filePath: templatePath,
        releaseTag: 'scripts-v4.1.0-aaaaaaa',
        sha256: digest,
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('rejects invalid configuration before network access and formats results safely', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-config-'));
    const env = envFor(root, 'a'.repeat(64));

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env: {
              ...env,
              OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: 'latest',
            },
            verifyOnly: true,
            fetchImpl: () => Promise.resolve(response('unexpected')),
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'CONFIG_INVALID'
      );

      assert.equal(
        formatProvisionResult({
          status: 'verified',
          filePath: '/srv/templates/OpenPath-Windows-Setup-Template.exe',
          releaseTag: 'scripts-v4.1.0-aaaaaaa',
          sha256: 'b'.repeat(64),
        }),
        JSON.stringify({
          status: 'verified',
          releaseTag: 'scripts-v4.1.0-aaaaaaa',
          sha256: 'b'.repeat(64),
        })
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('fails closed and leaves no published template on a digest mismatch', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-mismatch-'));
    const expected = 'a'.repeat(64);
    const env = envFor(root, expected);

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) =>
              Promise.resolve(
                requestUrl(url).endsWith('.sha256')
                  ? response(`${expected}  OpenPath-Windows-Setup-Template.exe\n`)
                  : response(Buffer.from('wrong bytes'))
              ),
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'HASH_MISMATCH'
      );

      await assert.rejects(() => access(path.join(root, 'templates')));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
