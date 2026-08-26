import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { access, chmod, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
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

async function withRedirectServer(
  templateBytes: Buffer,
  sidecarText: string,
  run: (origin: string) => Promise<void>
): Promise<void> {
  const server = createServer((request, response) => {
    const isSidecar = request.url?.includes('sidecar') === true;
    if (request.url?.startsWith('/final/') !== true) {
      response.statusCode = 302;
      response.setHeader('Location', isSidecar ? '/final/sidecar' : '/final/template');
      response.end();
      return;
    }

    response.statusCode = 200;
    response.end(isSidecar ? sidecarText : templateBytes);
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      resolve();
    });
  });

  try {
    const address = server.address();
    assert.ok(address !== null && typeof address !== 'string');
    await run(`http://127.0.0.1:${String(address.port)}`);
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => {
        if (error) reject(error);
        else resolve();
      });
    });
  }
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

  void test('follows a real GitHub-style asset redirect while retaining the exact initial URLs', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-redirect-'));
    const templateBytes = Buffer.from('redirected template bytes');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const requestedUrls: string[] = [];

    try {
      await withRedirectServer(
        templateBytes,
        `${digest}  OpenPath-Windows-Setup-Template.exe\n`,
        async (origin) => {
          const result = await provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: async (url, init) => {
              requestedUrls.push(requestUrl(url));
              assert.equal(init?.redirect, 'follow');
              const asset = requestUrl(url).endsWith('.sha256') ? 'sidecar' : 'template';
              const redirectedResponse = await fetch(`${origin}/${asset}`, init);
              Object.defineProperty(redirectedResponse, 'url', {
                configurable: true,
                value: `https://release-assets.githubusercontent.com/github-production-release-asset/${asset}`,
              });
              return redirectedResponse;
            },
          });

          assert.equal(result.status, 'provisioned');
        }
      );
      assert.deepEqual(requestedUrls, [
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe',
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe.sha256',
      ]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('maps a release asset 404 to DOWNLOAD_FAILED', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-404-'));
    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env: envFor(root, 'a'.repeat(64)),
            fetchImpl: () => Promise.resolve(response('not found', 404)),
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'DOWNLOAD_FAILED'
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('maps a release asset network failure to DOWNLOAD_FAILED', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-network-error-'));
    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env: envFor(root, 'a'.repeat(64)),
            fetchImpl: () => Promise.reject(new Error('network unavailable')),
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'DOWNLOAD_FAILED'
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('rejects a redirect that remains a different logical release tag', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-wrong-tag-'));
    const templateBytes = Buffer.from('template bytes from another tag');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const wrongTagUrl =
      'https://github.com/balejosg/openpath/releases/download/scripts-v4.0.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe';

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              const result = requestUrl(url).endsWith('.sha256')
                ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
                : response(templateBytes);
              Object.defineProperty(result, 'url', { value: wrongTagUrl });
              return Promise.resolve(result);
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'DOWNLOAD_FAILED'
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('rejects a redirect outside GitHub asset storage', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-untrusted-redirect-'));
    const templateBytes = Buffer.from('template bytes from an untrusted redirect');
    const digest = sha256(templateBytes);
    const untrustedUrl = 'https://downloads.example.test/template.exe';

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env: envFor(root, digest),
            fetchImpl: (url) => {
              const result = requestUrl(url).endsWith('.sha256')
                ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
                : response(templateBytes);
              Object.defineProperty(result, 'url', { value: untrustedUrl });
              return Promise.resolve(result);
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'DOWNLOAD_FAILED'
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('publishes template directories and files with portable read-only permissions', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-permissions-'));
    const templateBytes = Buffer.from('portable permissions template');
    const digest = sha256(templateBytes);

    try {
      await provisionWindowsOfflineInstallerTemplate({
        env: envFor(root, digest),
        fetchImpl: (url) =>
          Promise.resolve(
            requestUrl(url).endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          ),
      });

      const config = loadWindowsOfflineInstallerConfig(envFor(root, digest));
      const versionDirectory = path.join(config.templateDir, config.templateVersion);
      const commitDirectory = path.dirname(getWindowsOfflineInstallerTemplatePath(config));
      const templatePath = getWindowsOfflineInstallerTemplatePath(config);
      const sidecarPath = `${templatePath}.sha256`;

      assert.equal((await stat(versionDirectory)).mode & 0o777, 0o755);
      assert.equal((await stat(commitDirectory)).mode & 0o777, 0o755);
      assert.equal((await stat(templatePath)).mode & 0o777, 0o444);
      assert.equal((await stat(sidecarPath)).mode & 0o777, 0o444);
      assert.equal((await stat(templatePath)).mode & 0o002, 0);
      assert.equal((await stat(sidecarPath)).mode & 0o002, 0);
      await chmod(root, 0o755);
      assert.equal((await readFile(templatePath)).equals(templateBytes), true);
      assert.match(await readFile(sidecarPath, 'utf8'), new RegExp(digest));
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
