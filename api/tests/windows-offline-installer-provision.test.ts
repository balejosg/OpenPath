import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { existsSync } from 'node:fs';
import {
  access,
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  symlink,
  utimes,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { describe, test } from 'node:test';

import {
  getWindowsOfflineInstallerTemplatePath,
  loadWindowsOfflineInstallerConfig,
} from '../src/lib/windows-offline-installer-config.js';
import {
  cleanupStaleWindowsOfflineInstallerProvisioningDirectories,
  formatProvisionResult,
  provisionWindowsOfflineInstallerTemplate,
  WindowsOfflineInstallerProvisionError,
} from '../src/services/windows-offline-installer-provision.service.js';
import { loadCachedWindowsOfflineTemplate } from '../src/lib/windows-offline-installer-template.js';

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

function exactCommitProvenance(
  url: string | URL | Request,
  env: Record<string, string>
): Response | null {
  if (!requestUrl(url).includes('/git/ref/tags/')) return null;
  return response(
    JSON.stringify({
      object: { type: 'commit', sha: env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT },
    })
  );
}

function fetchForProvisionTest(
  env: Record<string, string>,
  templateBytes: Buffer,
  digest: string
): (url: string | URL | Request) => Promise<Response> {
  return (url) => {
    const provenance = exactCommitProvenance(url, env);
    if (provenance) return Promise.resolve(provenance);
    return Promise.resolve(
      requestUrl(url).endsWith('.sha256')
        ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
        : response(templateBytes)
    );
  };
}

interface ProvisionWorkerResult {
  code: number | null;
  signal: NodeJS.Signals | null;
  stderr: string;
  stdout: string;
}

function spawnProvisionWorker(
  root: string,
  digest: string,
  templateBytes: Buffer,
  options: {
    crashBeforeCommit?: boolean;
    crashAfterCommit?: boolean;
    renameDelayMs?: number;
  } = {}
): Promise<ProvisionWorkerResult> {
  const env = envFor(root, digest);
  const provisionModuleUrl = pathToFileURL(
    path.resolve('src/services/windows-offline-installer-provision.service.js')
  ).href;
  const workerScript = `
const { rename: renameFile } = await import('node:fs/promises');
const { provisionWindowsOfflineInstallerTemplate } = await import(${JSON.stringify(provisionModuleUrl)});
const configuredEnv = ${JSON.stringify(env)};
const digest = ${JSON.stringify(digest)};
const bytes = Buffer.from(${JSON.stringify(templateBytes.toString('base64'))}, 'base64');
const delayMs = ${String(options.renameDelayMs ?? 0)};
const crashBeforeCommit = ${String(options.crashBeforeCommit === true)};
const crashAfterCommit = ${String(options.crashAfterCommit === true)};
let renameCount = 0;
const fetchImpl = async (url) => {
  const requestedUrl = String(url);
  if (requestedUrl.includes('/git/ref/tags/')) {
    return new Response(JSON.stringify({ object: { type: 'commit', sha: configuredEnv.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT } }));
  }
  if (requestedUrl.endsWith('.sha256')) {
    return new Response(digest + '  OpenPath-Windows-Setup-Template.exe\\n');
  }
  return new Response(bytes);
};
const renamePath = async (sourcePath, targetPath) => {
  if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));
  await renameFile(sourcePath, targetPath);
  renameCount += 1;
  if (crashBeforeCommit && renameCount === 1) process.exit(17);
  if (crashAfterCommit && targetPath.endsWith('.current')) process.exit(17);
};
try {
  const result = await provisionWindowsOfflineInstallerTemplate({ env: configuredEnv, fetchImpl, renamePath });
  process.stdout.write(result.status);
} catch {
  process.exitCode = 1;
}
`;
  const child = spawn(
    process.execPath,
    ['--import', 'tsx', '--input-type=module', '--eval', workerScript],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        ...env,
      },
    }
  );

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk: Buffer) => {
    stdout += chunk.toString();
  });
  child.stderr.on('data', (chunk: Buffer) => {
    stderr += chunk.toString();
  });
  return new Promise<ProvisionWorkerResult>((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => {
      resolve({ code, signal, stderr, stdout });
    });
  });
}

function spawnGenerationReaderWorker(
  root: string,
  firstDigest: string,
  secondDigest: string,
  durationMs = 500
): Promise<ProvisionWorkerResult> {
  const firstEnv = envFor(root, firstDigest);
  const secondEnv = envFor(root, secondDigest);
  const templateModuleUrl = pathToFileURL(
    path.resolve('src/lib/windows-offline-installer-template.js')
  ).href;
  const workerScript = `
const { loadCachedWindowsOfflineTemplate } = await import(${JSON.stringify(templateModuleUrl)});
const firstEnv = ${JSON.stringify(firstEnv)};
const secondEnv = ${JSON.stringify(secondEnv)};
const endAt = Date.now() + ${String(durationMs)};
let successfulReads = 0;
let incompleteReads = 0;
while (Date.now() < endAt) {
  let readSucceeded = false;
  for (const configuredEnv of [firstEnv, secondEnv]) {
    try {
      const loaded = loadCachedWindowsOfflineTemplate(configuredEnv.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR, {
        version: configuredEnv.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION,
        commit: configuredEnv.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT,
        sha256: configuredEnv.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256,
        releaseTag: configuredEnv.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG,
      });
      if (!loaded.filePath.includes('/generations/') && !loaded.filePath.includes('\\\\generations\\\\')) {
        throw new Error('reader did not resolve an immutable generation');
      }
      readSucceeded = true;
      break;
    } catch {}
  }
  if (readSucceeded) successfulReads += 1;
  else incompleteReads += 1;
}
process.stdout.write(JSON.stringify({ successfulReads, incompleteReads }));
`;
  const child = spawn(
    process.execPath,
    ['--import', 'tsx', '--input-type=module', '--eval', workerScript],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        ...firstEnv,
      },
    }
  );

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk: Buffer) => {
    stdout += chunk.toString();
  });
  child.stderr.on('data', (chunk: Buffer) => {
    stderr += chunk.toString();
  });
  return new Promise<ProvisionWorkerResult>((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => {
      resolve({ code, signal, stderr, stdout });
    });
  });
}

async function waitBriefly(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
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

  void test('verify-only does not remove stale provisioning directories', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-verify-cleanup-'));
    const env = envFor(root, 'a'.repeat(64));
    const config = loadWindowsOfflineInstallerConfig(env);
    const staleRoot = path.join(config.templateDir, '.openpath-windows-template-stale');
    const oldTimestamp = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000);

    try {
      await mkdir(staleRoot, { recursive: true });
      await utimes(staleRoot, oldTimestamp, oldTimestamp);

      await assert.rejects(
        () => provisionWindowsOfflineInstallerTemplate({ env, verifyOnly: true }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError &&
          error.code === 'TEMPLATE_MISSING'
      );
      assert.equal(existsSync(staleRoot), true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('rejects a symlinked template version before writing outside the template root', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-link-'));
    const outside = await mkdtemp(path.join(tmpdir(), 'openpath-template-link-outside-'));
    const templateBytes = Buffer.from('symlink escape template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const config = loadWindowsOfflineInstallerConfig(env);

    try {
      await mkdir(config.templateDir, { recursive: true });
      await symlink(outside, path.join(config.templateDir, config.templateVersion), 'dir');

      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              const provenance = exactCommitProvenance(url, env);
              if (provenance) return Promise.resolve(provenance);
              return Promise.resolve(
                requestUrl(url).endsWith('.sha256')
                  ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
                  : response(templateBytes)
              );
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'PUBLISH_FAILED'
      );
      assert.deepEqual(await readdir(outside), []);
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(outside, { recursive: true, force: true });
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
          const provenance = exactCommitProvenance(url, env);
          if (provenance) return Promise.resolve(provenance);
          return Promise.resolve(
            requestUrl(url).endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          );
        },
      });
      const config = loadWindowsOfflineInstallerConfig(env);
      const canonicalTemplatePath = getWindowsOfflineInstallerTemplatePath(config);
      const canonicalDirectory = path.dirname(canonicalTemplatePath);
      const currentPath = path.join(canonicalDirectory, '.current');

      assert.equal(result.status, 'provisioned');
      assert.deepEqual(requestedUrls, [
        'https://api.github.com/repos/balejosg/openpath/git/ref/tags/scripts-v4.1.0-aaaaaaa',
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe',
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe.sha256',
      ]);
      const generationName = (await readFile(currentPath, 'utf8')).trim();
      assert.match(generationName, /^generation-[0-9a-f-]+$/u);
      const generationDirectory = path.join(canonicalDirectory, 'generations', generationName);
      const templatePath = path.join(generationDirectory, 'OpenPath-Windows-Setup-Template.exe');
      assert.deepEqual(await readFile(templatePath), templateBytes);
      assert.match(await readFile(`${templatePath}.sha256`, 'utf8'), new RegExp(digest));
      assert.deepEqual((await readdir(generationDirectory)).sort(), [
        'OpenPath-Windows-Setup-Template.exe',
        'OpenPath-Windows-Setup-Template.exe.provenance.json',
        'OpenPath-Windows-Setup-Template.exe.sha256',
      ]);
      assert.equal(result.filePath, templatePath);

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
              const provenance = exactCommitProvenance(url, env);
              if (provenance) return provenance;
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
        'https://api.github.com/repos/balejosg/openpath/git/ref/tags/scripts-v4.1.0-aaaaaaa',
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe',
        'https://github.com/balejosg/openpath/releases/download/scripts-v4.1.0-aaaaaaa/OpenPath-Windows-Setup-Template.exe.sha256',
      ]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('stages and commits a complete generation with one observable pointer rename', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-same-volume-'));
    const templateBytes = Buffer.from('same-volume template bytes');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const config = loadWindowsOfflineInstallerConfig(env);
    const templatePath = getWindowsOfflineInstallerTemplatePath(config);
    const renameCalls: { source: string; target: string }[] = [];

    try {
      await provisionWindowsOfflineInstallerTemplate({
        env,
        renamePath: async (source, target) => {
          renameCalls.push({ source, target });
          await rename(source, target);
        },
        fetchImpl: (url) => {
          const provenance = exactCommitProvenance(url, env);
          if (provenance) return Promise.resolve(provenance);
          return Promise.resolve(
            requestUrl(url).endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          );
        },
      });

      assert.equal(renameCalls.length, 2);
      const firstRename = renameCalls[0];
      const secondRename = renameCalls[1];
      assert.ok(firstRename);
      assert.ok(secondRename);
      const configuredTemplateDir = env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR;
      if (configuredTemplateDir === undefined) throw new Error('expected template directory');
      const templateRoot = path.resolve(configuredTemplateDir);
      assert.equal(firstRename.source.startsWith(`${templateRoot}${path.sep}`), true);
      assert.equal(firstRename.target.startsWith(`${templateRoot}${path.sep}`), true);
      assert.match(path.basename(firstRename.target), /^generation-[0-9a-f-]+$/u);
      assert.equal(path.basename(secondRename.target), '.current');
      assert.equal(path.dirname(secondRename.target), path.dirname(templatePath));
      assert.equal(
        path.dirname(firstRename.target),
        path.join(path.dirname(templatePath), 'generations')
      );
      assert.equal(existsSync(path.dirname(templatePath)), true);
      assert.equal(existsSync(path.join(path.dirname(templatePath), '.current')), true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('maps a release asset 404 to DOWNLOAD_FAILED', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-404-'));
    const env = envFor(root, 'a'.repeat(64));
    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              const provenance = exactCommitProvenance(url, env);
              return provenance
                ? Promise.resolve(provenance)
                : Promise.resolve(response('not found', 404));
            },
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
    const env = envFor(root, 'a'.repeat(64));
    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              const provenance = exactCommitProvenance(url, env);
              return provenance
                ? Promise.resolve(provenance)
                : Promise.reject(new Error('network unavailable'));
            },
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
              const provenance = exactCommitProvenance(url, env);
              if (provenance) return Promise.resolve(provenance);
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
    const env = envFor(root, digest);
    const untrustedUrl = 'https://downloads.example.test/template.exe';

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              const provenance = exactCommitProvenance(url, env);
              if (provenance) return Promise.resolve(provenance);
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
        fetchImpl: (url) => {
          const currentEnv = envFor(root, digest);
          const provenance = exactCommitProvenance(url, currentEnv);
          if (provenance) return Promise.resolve(provenance);
          return Promise.resolve(
            requestUrl(url).endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          );
        },
      });

      const config = loadWindowsOfflineInstallerConfig(envFor(root, digest));
      const versionDirectory = path.join(config.templateDir, config.templateVersion);
      const commitDirectory = path.dirname(getWindowsOfflineInstallerTemplatePath(config));
      const currentGeneration = (
        await readFile(path.join(commitDirectory, '.current'), 'utf8')
      ).trim();
      const generationDirectory = path.join(commitDirectory, 'generations', currentGeneration);
      const templatePath = path.join(generationDirectory, 'OpenPath-Windows-Setup-Template.exe');
      const sidecarPath = `${templatePath}.sha256`;
      const provenancePath = `${templatePath}.provenance.json`;

      assert.equal((await stat(versionDirectory)).mode & 0o777, 0o755);
      assert.equal((await stat(commitDirectory)).mode & 0o777, 0o755);
      assert.equal((await stat(path.join(commitDirectory, 'generations'))).mode & 0o777, 0o755);
      assert.equal((await stat(generationDirectory)).mode & 0o777, 0o755);
      assert.equal((await stat(templatePath)).mode & 0o777, 0o444);
      assert.equal((await stat(sidecarPath)).mode & 0o777, 0o444);
      assert.equal((await stat(provenancePath)).mode & 0o777, 0o444);
      assert.equal((await stat(templatePath)).mode & 0o002, 0);
      assert.equal((await stat(sidecarPath)).mode & 0o002, 0);
      await chmod(root, 0o755);
      assert.equal((await readFile(templatePath)).equals(templateBytes), true);
      assert.match(await readFile(sidecarPath, 'utf8'), new RegExp(digest));
      assert.match(
        await readFile(provenancePath, 'utf8'),
        /"releaseTag":"scripts-v4\.1\.0-aaaaaaa"/u
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('rejects a full commit that only shares the release tag short prefix', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-provenance-mismatch-'));
    const templateBytes = Buffer.from('provenance mismatch template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const wrongCommit = `a${'b'.repeat(39)}`;

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              if (requestUrl(url).includes('/git/ref/tags/')) {
                return Promise.resolve(
                  response(JSON.stringify({ object: { type: 'commit', sha: wrongCommit } }), 200)
                );
              }
              return Promise.resolve(
                requestUrl(url).endsWith('.sha256')
                  ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
                  : response(templateBytes)
              );
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError &&
          error.code === 'PROVENANCE_MISMATCH'
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('resolves annotated release tags to the exact configured commit', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-annotated-tag-'));
    const templateBytes = Buffer.from('annotated tag template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const annotatedTagObject = 'c'.repeat(40);
    const requestedUrls: string[] = [];

    try {
      const result = await provisionWindowsOfflineInstallerTemplate({
        env,
        fetchImpl: (url) => {
          const urlText = requestUrl(url);
          requestedUrls.push(urlText);
          if (urlText.includes('/git/ref/tags/')) {
            return Promise.resolve(
              response(JSON.stringify({ object: { type: 'tag', sha: annotatedTagObject } }))
            );
          }
          if (urlText.includes(`/git/tags/${annotatedTagObject}`)) {
            return Promise.resolve(
              response(
                JSON.stringify({
                  object: { type: 'commit', sha: env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT },
                })
              )
            );
          }
          return Promise.resolve(
            urlText.endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          );
        },
      });

      assert.equal(result.status, 'provisioned');
      assert.equal(
        requestedUrls.some((url) => url.includes('/git/tags/')),
        true
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('verify-only fails closed when local release provenance is missing', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-provenance-missing-'));
    const templateBytes = Buffer.from('template without provenance');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const config = loadWindowsOfflineInstallerConfig(env);
    const templatePath = getWindowsOfflineInstallerTemplatePath(config);

    try {
      await import('node:fs/promises').then(async ({ mkdir, writeFile }) => {
        await mkdir(path.dirname(templatePath), { recursive: true });
        await writeFile(templatePath, templateBytes);
        await writeFile(`${templatePath}.sha256`, `${digest}  template.exe\n`);
      });

      await assert.rejects(
        () => provisionWindowsOfflineInstallerTemplate({ env, verifyOnly: true }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError &&
          error.code === 'PROVENANCE_MISSING'
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('repairs a corrupt existing template and sidecar in place', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-repair-'));
    const templateBytes = Buffer.from('repaired pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const config = loadWindowsOfflineInstallerConfig(env);
    const templatePath = getWindowsOfflineInstallerTemplatePath(config);

    try {
      await import('node:fs/promises').then(async ({ mkdir, writeFile }) => {
        await mkdir(path.dirname(templatePath), { recursive: true });
        await writeFile(templatePath, 'corrupt template');
        await writeFile(`${templatePath}.sha256`, `${'c'.repeat(64)}  template.exe\n`);
      });

      const result = await provisionWindowsOfflineInstallerTemplate({
        env,
        fetchImpl: (url) => {
          if (requestUrl(url).includes('/git/ref/tags/')) {
            return Promise.resolve(
              response(JSON.stringify({ object: { type: 'commit', sha: 'a'.repeat(40) } }))
            );
          }
          return Promise.resolve(
            requestUrl(url).endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          );
        },
      });

      assert.equal(result.status, 'provisioned');
      assert.deepEqual(await readFile(result.filePath), templateBytes);
      assert.match(await readFile(`${result.filePath}.sha256`, 'utf8'), new RegExp(digest));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('repairs an existing template when only its sidecar is corrupt', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-sidecar-repair-'));
    const templateBytes = Buffer.from('sidecar repaired pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const config = loadWindowsOfflineInstallerConfig(env);
    const templatePath = getWindowsOfflineInstallerTemplatePath(config);

    try {
      await import('node:fs/promises').then(async ({ mkdir, writeFile }) => {
        await mkdir(path.dirname(templatePath), { recursive: true });
        await writeFile(templatePath, templateBytes);
        await writeFile(`${templatePath}.sha256`, `${'c'.repeat(64)}  template.exe\n`);
      });

      const result = await provisionWindowsOfflineInstallerTemplate({
        env,
        fetchImpl: (url) => {
          const provenance = exactCommitProvenance(url, env);
          if (provenance) return Promise.resolve(provenance);
          return Promise.resolve(
            requestUrl(url).endsWith('.sha256')
              ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
              : response(templateBytes)
          );
        },
      });

      assert.equal(result.status, 'provisioned');
      assert.equal((await readFile(result.filePath)).equals(templateBytes), true);
      assert.match(await readFile(`${result.filePath}.sha256`, 'utf8'), new RegExp(digest));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('never replaces a valid cached template after a failed reprovision attempt', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-preserve-valid-'));
    const templateBytes = Buffer.from('valid existing pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const config = loadWindowsOfflineInstallerConfig(env);
    const templatePath = getWindowsOfflineInstallerTemplatePath(config);

    try {
      await import('node:fs/promises').then(async ({ mkdir, writeFile }) => {
        await mkdir(path.dirname(templatePath), { recursive: true });
        await writeFile(templatePath, templateBytes);
        await writeFile(`${templatePath}.sha256`, `${digest}  template.exe\n`);
        await writeFile(
          `${templatePath}.provenance.json`,
          `${JSON.stringify({
            version: config.templateVersion,
            commit: config.templateCommit,
            releaseTag: config.templateReleaseTag,
            sha256: digest,
          })}\n`
        );
      });

      const result = await provisionWindowsOfflineInstallerTemplate({
        env,
        fetchImpl: () => Promise.reject(new Error('network must not be used for valid cache')),
      });

      assert.equal(result.status, 'verified');
      assert.equal((await readFile(templatePath)).equals(templateBytes), true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('concurrent provisioners leave one valid exact template', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-concurrent-'));
    const templateBytes = Buffer.from('concurrent pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);

    try {
      const fetchImpl = (url: string | URL | Request): Promise<Response> => {
        const provenance = exactCommitProvenance(url, env);
        if (provenance) return Promise.resolve(provenance);
        return Promise.resolve(
          requestUrl(url).endsWith('.sha256')
            ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
            : response(templateBytes)
        );
      };
      const results = await Promise.all([
        provisionWindowsOfflineInstallerTemplate({ env, fetchImpl }),
        provisionWindowsOfflineInstallerTemplate({ env, fetchImpl }),
      ]);

      assert.deepEqual(results.map((result) => result.status).sort(), ['provisioned', 'verified']);
      const config = loadWindowsOfflineInstallerConfig(env);
      const loaded = loadCachedWindowsOfflineTemplate(config.templateDir, {
        version: config.templateVersion,
        commit: config.templateCommit,
        sha256: config.templateSha256,
        releaseTag: config.templateReleaseTag,
      });
      assert.equal((await readFile(loaded.filePath)).equals(templateBytes), true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('coordinates provisioners that run in separate processes on one storage root', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-processes-'));
    const templateBytes = Buffer.from('separate process pinned template');
    const digest = sha256(templateBytes);

    try {
      const results = await Promise.all([
        spawnProvisionWorker(root, digest, templateBytes, { renameDelayMs: 20 }),
        spawnProvisionWorker(root, digest, templateBytes, { renameDelayMs: 20 }),
      ]);

      for (const result of results) {
        assert.equal(result.code, 0, result.stderr);
        assert.equal(result.signal, null);
      }

      const config = loadWindowsOfflineInstallerConfig(envFor(root, digest));
      assert.doesNotThrow(() =>
        loadCachedWindowsOfflineTemplate(config.templateDir, {
          version: config.templateVersion,
          commit: config.templateCommit,
          sha256: config.templateSha256,
          releaseTag: config.templateReleaseTag,
        })
      );
      const loaded = loadCachedWindowsOfflineTemplate(config.templateDir, {
        version: config.templateVersion,
        commit: config.templateCommit,
        sha256: config.templateSha256,
        releaseTag: config.templateReleaseTag,
      });
      assert.deepEqual(await readFile(loaded.filePath), templateBytes);

      const lockPath = path.join(
        config.templateDir,
        config.templateVersion,
        config.templateCommit,
        '.publish.lock'
      );
      await writeFile(lockPath, '');
      await cleanupStaleWindowsOfflineInstallerProvisioningDirectories(config);
      assert.equal(existsSync(lockPath), true);
      await rm(lockPath, { force: true });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('lets a separate-process reader observe only complete old or new generations', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-reader-'));
    const firstBytes = Buffer.from('first reader-visible pinned template');
    const secondBytes = Buffer.from('second reader-visible pinned template');
    const firstDigest = sha256(firstBytes);
    const secondDigest = sha256(secondBytes);
    const firstEnv = envFor(root, firstDigest);
    const secondEnv = envFor(root, secondDigest);

    const fetchFor =
      (
        env: Record<string, string>,
        templateBytes: Buffer,
        digest: string
      ): ((url: string | URL | Request) => Promise<Response>) =>
      (url) => {
        const provenance = exactCommitProvenance(url, env);
        if (provenance) return Promise.resolve(provenance);
        return Promise.resolve(
          requestUrl(url).endsWith('.sha256')
            ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
            : response(templateBytes)
        );
      };

    try {
      await provisionWindowsOfflineInstallerTemplate({
        env: firstEnv,
        fetchImpl: fetchFor(firstEnv, firstBytes, firstDigest),
      });

      let releaseCommit!: () => void;
      let signalCommitReached!: () => void;
      const commitReached = new Promise<void>((resolve) => {
        signalCommitReached = resolve;
      });
      const holdCommit = new Promise<void>((resolve) => {
        releaseCommit = resolve;
      });
      const reader = spawnGenerationReaderWorker(root, firstDigest, secondDigest, 700);
      const publisher = provisionWindowsOfflineInstallerTemplate({
        env: secondEnv,
        fetchImpl: fetchFor(secondEnv, secondBytes, secondDigest),
        renamePath: async (sourcePath, targetPath) => {
          if (path.basename(targetPath) === '.current') {
            signalCommitReached();
            await holdCommit;
          }
          await rename(sourcePath, targetPath);
        },
      });

      await commitReached;
      await waitBriefly(50);
      releaseCommit();
      const [published, readerResult] = await Promise.all([publisher, reader]);
      assert.equal(published.status, 'provisioned');
      assert.equal(readerResult.code, 0, readerResult.stderr);
      const readerEvidence = JSON.parse(readerResult.stdout) as {
        successfulReads: number;
        incompleteReads: number;
      };
      assert.equal(readerEvidence.successfulReads > 0, true);
      assert.equal(readerEvidence.incompleteReads, 0);

      const secondConfig = loadWindowsOfflineInstallerConfig(secondEnv);
      const loaded = loadCachedWindowsOfflineTemplate(secondConfig.templateDir, {
        version: secondConfig.templateVersion,
        commit: secondConfig.templateCommit,
        sha256: secondConfig.templateSha256,
        releaseTag: secondConfig.templateReleaseTag,
      });
      assert.deepEqual(await readFile(loaded.filePath), secondBytes);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('fails closed on a publish error and repairs the partial bundle on the next run', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-publish-failure-'));
    const templateBytes = Buffer.from('publish failure pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    let renameCount = 0;
    const fetchImpl = (url: string | URL | Request): Promise<Response> => {
      const provenance = exactCommitProvenance(url, env);
      if (provenance) return Promise.resolve(provenance);
      return Promise.resolve(
        requestUrl(url).endsWith('.sha256')
          ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
          : response(templateBytes)
      );
    };

    try {
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl,
            renamePath: async (sourcePath, targetPath) => {
              renameCount += 1;
              if (renameCount === 2) throw new Error('injected publish failure');
              await rename(sourcePath, targetPath);
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'PUBLISH_FAILED'
      );
      assert.equal(renameCount, 2);

      const config = loadWindowsOfflineInstallerConfig(env);
      const templatePath = getWindowsOfflineInstallerTemplatePath(config);
      assert.equal(existsSync(path.dirname(templatePath)), true);
      assert.equal(existsSync(path.join(path.dirname(templatePath), '.current')), false);
      await assert.rejects(
        () => provisionWindowsOfflineInstallerTemplate({ env, verifyOnly: true }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError &&
          error.code === 'TEMPLATE_MISSING'
      );

      const repaired = await provisionWindowsOfflineInstallerTemplate({ env, fetchImpl });
      assert.equal(repaired.status, 'provisioned');
      assert.deepEqual(await readFile(repaired.filePath), templateBytes);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('recovers after a separate provisioning process crashes mid-publish', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-crash-'));
    const templateBytes = Buffer.from('crash recovery pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);

    try {
      const crashed = await spawnProvisionWorker(root, digest, templateBytes, {
        crashBeforeCommit: true,
      });
      assert.equal(crashed.code, 17);
      assert.equal(crashed.signal, null);

      const config = loadWindowsOfflineInstallerConfig(env);
      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            verifyOnly: true,
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError &&
          error.code === 'TEMPLATE_MISSING'
      );

      const templateRootEntries = await readdir(config.templateDir);
      const staleStagingRoots = templateRootEntries.filter((entry) =>
        entry.startsWith('.openpath-windows-template-')
      );
      assert.equal(staleStagingRoots.length > 0, true);
      const oldTimestamp = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000);
      for (const entry of staleStagingRoots) {
        await utimes(path.join(config.templateDir, entry), oldTimestamp, oldTimestamp);
      }

      const legacyQuarantineRoot = path.join(
        config.templateDir,
        config.templateVersion,
        `.${config.templateCommit}-11111111-1111-4111-8111-111111111111.quarantine`
      );
      await mkdir(legacyQuarantineRoot, { recursive: true });
      await writeFile(path.join(legacyQuarantineRoot, 'orphan'), 'orphan');
      await utimes(legacyQuarantineRoot, oldTimestamp, oldTimestamp);

      const fetchImpl = (url: string | URL | Request): Promise<Response> => {
        const provenance = exactCommitProvenance(url, env);
        if (provenance) return Promise.resolve(provenance);
        return Promise.resolve(
          requestUrl(url).endsWith('.sha256')
            ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
            : response(templateBytes)
        );
      };
      const result = await provisionWindowsOfflineInstallerTemplate({ env, fetchImpl });
      assert.equal(result.status, 'provisioned');
      assert.deepEqual(await readFile(result.filePath), templateBytes);
      assert.deepEqual(
        (await readdir(config.templateDir)).filter((entry) =>
          entry.startsWith('.openpath-windows-template-')
        ),
        []
      );
      await assert.rejects(access(legacyQuarantineRoot));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('keeps the committed generation usable after a crash immediately after commit', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-crash-after-commit-'));
    const templateBytes = Buffer.from('crash after commit pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);

    try {
      const crashed = await spawnProvisionWorker(root, digest, templateBytes, {
        crashAfterCommit: true,
      });
      assert.equal(crashed.code, 17);
      assert.equal(crashed.signal, null);

      const config = loadWindowsOfflineInstallerConfig(env);
      const loaded = loadCachedWindowsOfflineTemplate(config.templateDir, {
        version: config.templateVersion,
        commit: config.templateCommit,
        sha256: config.templateSha256,
        releaseTag: config.templateReleaseTag,
      });
      assert.deepEqual(await readFile(loaded.filePath), templateBytes);
      const verified = await provisionWindowsOfflineInstallerTemplate({ env, verifyOnly: true });
      assert.equal(verified.status, 'verified');
      assert.equal(verified.filePath, loaded.filePath);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('preserves the previous valid generation when staging I/O fails', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-staging-failure-'));
    const previousBytes = Buffer.from('previous valid generation');
    const nextBytes = Buffer.from('next generation that never commits');
    const previousDigest = sha256(previousBytes);
    const nextDigest = sha256(nextBytes);
    const previousEnv = envFor(root, previousDigest);
    const nextEnv = envFor(root, nextDigest);

    try {
      await provisionWindowsOfflineInstallerTemplate({
        env: previousEnv,
        fetchImpl: fetchForProvisionTest(previousEnv, previousBytes, previousDigest),
      });

      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env: nextEnv,
            fetchImpl: fetchForProvisionTest(nextEnv, nextBytes, nextDigest),
            writeFileImpl: (filePath) => {
              if (filePath.endsWith('OpenPath-Windows-Setup-Template.exe')) {
                throw new Error('injected staging I/O failure');
              }
              return Promise.resolve();
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'PUBLISH_FAILED'
      );

      const previousConfig = loadWindowsOfflineInstallerConfig(previousEnv);
      const loaded = loadCachedWindowsOfflineTemplate(previousConfig.templateDir, {
        version: previousConfig.templateVersion,
        commit: previousConfig.templateCommit,
        sha256: previousConfig.templateSha256,
        releaseTag: previousConfig.templateReleaseTag,
      });
      assert.deepEqual(await readFile(loaded.filePath), previousBytes);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('cleans abandoned generations and staging without deleting the current generation', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-generation-cleanup-'));
    const templateBytes = Buffer.from('generation cleanup pinned template');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);

    try {
      await provisionWindowsOfflineInstallerTemplate({
        env,
        fetchImpl: fetchForProvisionTest(env, templateBytes, digest),
      });
      const config = loadWindowsOfflineInstallerConfig(env);
      const commitDirectory = path.dirname(getWindowsOfflineInstallerTemplatePath(config));
      const currentGeneration = (
        await readFile(path.join(commitDirectory, '.current'), 'utf8')
      ).trim();
      const abandonedGeneration = path.join(commitDirectory, 'generations', 'generation-abandoned');
      await mkdir(abandonedGeneration, { recursive: true });
      await writeFile(path.join(abandonedGeneration, 'orphan'), 'orphan');
      const abandonedStaging = path.join(
        config.templateDir,
        '.openpath-windows-template-abandoned'
      );
      await mkdir(abandonedStaging, { recursive: true });
      const oldTimestamp = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000);
      await utimes(abandonedGeneration, oldTimestamp, oldTimestamp);
      await utimes(abandonedStaging, oldTimestamp, oldTimestamp);

      await cleanupStaleWindowsOfflineInstallerProvisioningDirectories(config);

      await assert.rejects(access(abandonedGeneration));
      await assert.rejects(access(abandonedStaging));
      const loaded = loadCachedWindowsOfflineTemplate(config.templateDir, {
        version: config.templateVersion,
        commit: config.templateCommit,
        sha256: config.templateSha256,
        releaseTag: config.templateReleaseTag,
      });
      assert.equal(path.basename(path.dirname(loaded.filePath)), currentGeneration);
      assert.deepEqual(await readFile(loaded.filePath), templateBytes);
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
            fetchImpl: (url) => {
              const provenance = exactCommitProvenance(url, env);
              if (provenance) return Promise.resolve(provenance);
              return Promise.resolve(
                requestUrl(url).endsWith('.sha256')
                  ? response(`${expected}  OpenPath-Windows-Setup-Template.exe\n`)
                  : response(Buffer.from('wrong bytes'))
              );
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'HASH_MISMATCH'
      );

      await assert.rejects(() => access(path.join(root, 'templates')));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('rejects symlinked template paths without publishing outside the root', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-symlink-'));
    const outsideRoot = await mkdtemp(path.join(tmpdir(), 'openpath-template-outside-'));
    const templateBytes = Buffer.from('symlink escape must be rejected');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    const templateDir = env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR;
    const templateVersion = env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION;
    const templateCommit = env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT;
    if (
      templateDir === undefined ||
      templateVersion === undefined ||
      templateCommit === undefined
    ) {
      throw new Error('expected complete template environment');
    }

    try {
      await mkdir(path.dirname(templateDir), { recursive: true });
      await symlink(outsideRoot, templateDir, 'dir');

      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              const provenance = exactCommitProvenance(url, env);
              if (provenance) return Promise.resolve(provenance);
              return Promise.resolve(
                requestUrl(url).endsWith('.sha256')
                  ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
                  : response(templateBytes)
              );
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'PUBLISH_FAILED'
      );
      await assert.rejects(
        access(
          path.join(
            outsideRoot,
            templateVersion,
            templateCommit,
            'OpenPath-Windows-Setup-Template.exe'
          )
        )
      );
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(outsideRoot, { recursive: true, force: true });
    }
  });

  void test('rejects a symlinked template parent before creating directories outside the root', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-parent-link-'));
    const outsideRoot = await mkdtemp(path.join(tmpdir(), 'openpath-template-parent-outside-'));
    const templateBytes = Buffer.from('parent symlink escape must be rejected');
    const digest = sha256(templateBytes);
    const env = envFor(root, digest);
    env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR = path.join(root, 'template-link', 'templates');

    try {
      await symlink(outsideRoot, path.join(root, 'template-link'), 'dir');

      await assert.rejects(
        () =>
          provisionWindowsOfflineInstallerTemplate({
            env,
            fetchImpl: (url) => {
              const provenance = exactCommitProvenance(url, env);
              if (provenance) return Promise.resolve(provenance);
              return Promise.resolve(
                requestUrl(url).endsWith('.sha256')
                  ? response(`${digest}  OpenPath-Windows-Setup-Template.exe\n`)
                  : response(templateBytes)
              );
            },
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerProvisionError && error.code === 'PUBLISH_FAILED'
      );
      assert.deepEqual(await readdir(outsideRoot), []);
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(outsideRoot, { recursive: true, force: true });
    }
  });

  void test('cleans stale legacy quarantine directories under older versions', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-template-old-version-'));
    const env = envFor(root, 'a'.repeat(64));
    const config = loadWindowsOfflineInstallerConfig(env);
    const quarantine = path.join(
      config.templateDir,
      '4.0.0',
      `.${config.templateCommit}-11111111-1111-4111-8111-111111111111.quarantine`
    );
    const oldTimestamp = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000);

    try {
      await mkdir(quarantine, { recursive: true });
      await writeFile(path.join(quarantine, 'orphan'), 'orphan');
      await utimes(quarantine, oldTimestamp, oldTimestamp);

      await cleanupStaleWindowsOfflineInstallerProvisioningDirectories(config);

      await assert.rejects(access(quarantine));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
