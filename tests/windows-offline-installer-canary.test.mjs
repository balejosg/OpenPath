import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { runWindowsOfflineInstallerCanary } from '../scripts/windows-offline-installer-canary.mjs';

function hash(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

test('windows offline installer canary CLI resolves direct execution on Windows paths', async () => {
  const source = await readFile(
    fileURLToPath(new URL('../scripts/windows-offline-installer-canary.mjs', import.meta.url)),
    'utf8'
  );

  assert.match(
    source,
    /pathToFileURL\(process\.argv\[1\]\)\.href/,
    'the CLI guard must normalize Windows filesystem paths before comparing import.meta.url'
  );
});

test('windows offline installer canary CLI runs the real bounded HTTP flow', async () => {
  const bytes = Buffer.from('direct-cli-installer');
  let downloadCount = 0;
  const server = createServer((request, response) => {
    if (request.url === '/trpc/windowsOfflineInstaller.generate') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(
        JSON.stringify({
          result: {
            data: {
              fileName: 'OpenPath-Lab-Windows-Setup.exe',
              version: '4.1.0',
              sha256: hash(bytes),
              downloadUrl: '/download?ref=opaque-ref',
            },
          },
        })
      );
      return;
    }

    downloadCount += 1;
    if (downloadCount === 1) {
      response.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-disposition': 'attachment; filename="OpenPath-Lab-Windows-Setup.exe"',
        'cache-control': 'no-store',
        'content-length': String(bytes.length),
        'x-content-type-options': 'nosniff',
      });
      response.end(bytes);
      return;
    }

    response.writeHead(410);
    response.end();
  });
  await once(server.listen(0, '127.0.0.1'), 'listening');
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-offline-canary-cli-'));
  const outputPath = path.join(root, 'downloaded.exe');
  const scriptPath = fileURLToPath(
    new URL('../scripts/windows-offline-installer-canary.mjs', import.meta.url)
  );

  try {
    const child = spawn(process.execPath, [scriptPath], {
      env: {
        ...process.env,
        OPENPATH_CANARY_BASE_URL: `http://127.0.0.1:${address.port}`,
        OPENPATH_CANARY_DOWNLOAD_BASE_URL: `http://127.0.0.1:${address.port}`,
        OPENPATH_CANARY_ACCESS_TOKEN: 'secret-token',
        OPENPATH_CANARY_CLASSROOM_ID: 'classroom-1',
        OPENPATH_CANARY_OUTPUT_PATH: outputPath,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const timeout = setTimeout(() => child.kill('SIGTERM'), 5_000);
    const [exitCode] = await once(child, 'close');
    clearTimeout(timeout);

    assert.equal(exitCode, 0, stderr);
    const result = JSON.parse(stdout);
    assert.equal(result.status, 'ok');
    assert.equal(result.downloadStatus, 200);
    assert.equal(result.replayStatus, 410);
    assert.deepEqual(await readFile(outputPath), bytes);
    assert.equal(stdout.includes('opaque-ref'), false);
    assert.equal(stdout.includes('secret-token'), false);
  } finally {
    await rm(root, { recursive: true, force: true });
    server.close();
    await once(server, 'close').catch(() => undefined);
  }
});

test('windows offline installer canary verifies bytes and bounded single-use replay', async () => {
  const bytes = Buffer.from('fake-installer');
  let replayCount = 0;
  const fetchImpl = async (url, options) => {
    if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
      assert.equal(options?.headers?.Authorization, 'Bearer secret-token');
      return new Response(
        JSON.stringify({
          result: {
            data: {
              fileName: 'OpenPath-Lab-Windows-Setup.exe',
              version: '4.1.0',
              sha256: hash(bytes),
              downloadUrl: '/api/windows-offline-installer/download?ref=opaque',
            },
          },
        }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      );
    }

    if (replayCount === 0) {
      replayCount += 1;
      return new Response(bytes, {
        status: 200,
        headers: {
          'content-type': 'application/octet-stream',
          'content-disposition': 'attachment; filename="OpenPath-Lab-Windows-Setup.exe"',
          'cache-control': 'no-store',
          'content-length': String(bytes.length),
          'x-content-type-options': 'nosniff',
        },
      });
    }

    return new Response(null, { status: 410 });
  };

  const result = await runWindowsOfflineInstallerCanary({
    baseUrl: 'https://openpath.example.test',
    accessToken: 'secret-token',
    classroomId: 'classroom-1',
    fetchImpl,
  });

  assert.deepEqual(result, {
    status: 'ok',
    version: '4.1.0',
    fileName: 'OpenPath-Lab-Windows-Setup.exe',
    bytesVerified: true,
    downloadStatus: 200,
    downloadBytes: bytes.length,
    downloadSha256: hash(bytes),
    headersVerified: true,
    replayStatus: 410,
  });
});

function generationResponse(bytes) {
  return new Response(
    JSON.stringify({
      result: {
        data: {
          fileName: 'OpenPath-Lab-Windows-Setup.exe',
          version: '4.1.0',
          sha256: hash(bytes),
          downloadUrl: '/api/windows-offline-installer/download?ref=opaque-ref',
        },
      },
    }),
    { status: 200, headers: { 'content-type': 'application/json' } }
  );
}

function downloadResponse(bytes, status = 200) {
  return new Response(status === 200 ? bytes : null, {
    status,
    headers:
      status === 200
        ? {
            'content-type': 'application/octet-stream',
            'content-disposition': 'attachment; filename="OpenPath-Lab-Windows-Setup.exe"',
            'cache-control': 'no-store',
            'content-length': String(bytes.length),
            'x-content-type-options': 'nosniff',
          }
        : undefined,
  });
}

test('windows offline installer canary accepts an immediate 410 replay', async () => {
  const bytes = Buffer.from('immediate-replay-installer');
  let downloadCount = 0;
  const result = await runWindowsOfflineInstallerCanary({
    baseUrl: 'https://openpath.example.test',
    accessToken: 'access-token',
    classroomId: 'classroom-1',
    fetchImpl: async (url) => {
      if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
        return generationResponse(bytes);
      }
      downloadCount += 1;
      return downloadCount === 1 ? downloadResponse(bytes) : downloadResponse(bytes, 410);
    },
  });

  assert.equal(result.replayStatus, 410);
  assert.equal(downloadCount, 2);
});

test('windows offline installer canary allows several transient replay 200 responses before 410', async () => {
  const bytes = Buffer.from('transient-replay-installer');
  let downloadCount = 0;
  let clock = 0;
  let sleepCalls = 0;
  const result = await runWindowsOfflineInstallerCanary({
    baseUrl: 'https://openpath.example.test',
    accessToken: 'access-token',
    classroomId: 'classroom-1',
    replayDeadlineMs: 350,
    nowImpl: () => clock,
    sleepImpl: async (milliseconds) => {
      sleepCalls += 1;
      clock += milliseconds;
    },
    fetchImpl: async (url) => {
      if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
        return generationResponse(bytes);
      }
      downloadCount += 1;
      return downloadCount <= 4 ? downloadResponse(bytes) : downloadResponse(bytes, 410);
    },
  });

  assert.equal(result.replayStatus, 410);
  assert.equal(downloadCount, 5);
  assert.equal(sleepCalls, 3);
});

test('windows offline installer canary fails when replay remains 200 past the deadline', async () => {
  const bytes = Buffer.from('permanent-replay-installer');
  let clock = 0;
  await assert.rejects(
    () =>
      runWindowsOfflineInstallerCanary({
        baseUrl: 'https://openpath.example.test',
        accessToken: 'access-token',
        classroomId: 'classroom-1',
        replayDeadlineMs: 20,
        nowImpl: () => clock,
        sleepImpl: async (milliseconds) => {
          clock += milliseconds;
        },
        fetchImpl: async (url) => {
          if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
            return generationResponse(bytes);
          }
          return downloadResponse(bytes);
        },
      }),
    /replay-not-consumed-200/
  );
  assert.equal(clock >= 20, true);
});

test('windows offline installer canary fails on unexpected replay status and network errors', async () => {
  const bytes = Buffer.from('unexpected-replay-installer');
  for (const failure of [
    async (url) => {
      if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
        return generationResponse(bytes);
      }
      return downloadResponse(bytes, 404);
    },
    async (url) => {
      if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
        return generationResponse(bytes);
      }
      return downloadResponse(bytes, 500);
    },
    async (url) => {
      if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
        return generationResponse(bytes);
      }
      throw new Error('network failure with secret-token');
    },
  ]) {
    await assert.rejects(
      () =>
        runWindowsOfflineInstallerCanary({
          baseUrl: 'https://openpath.example.test',
          accessToken: 'secret-token',
          classroomId: 'classroom-1',
          replayDeadlineMs: 20,
          nowImpl: () => 0,
          sleepImpl: async () => undefined,
          fetchImpl: failure,
        }),
      (error) => {
        assert.equal(JSON.stringify(error).includes('secret-token'), false);
        return true;
      }
    );
  }
});

test('windows offline installer canary reports only the generation HTTP status', async () => {
  const response = async () =>
    new Response(JSON.stringify({ error: { message: 'internal details must not escape' } }), {
      status: 503,
      headers: { 'content-type': 'application/json' },
    });

  await assert.rejects(
    () =>
      runWindowsOfflineInstallerCanary({
        baseUrl: 'https://openpath.example.test',
        accessToken: 'secret-token',
        classroomId: 'classroom-1',
        fetchImpl: response,
      }),
    (error) => {
      assert.equal(error instanceof Error ? error.message : String(error), 'generation-status-503');
      assert.equal(JSON.stringify(error).includes('internal details'), false);
      assert.equal(JSON.stringify(error).includes('secret-token'), false);
      return true;
    }
  );
});

test('windows offline installer canary evidence contains no raw references or credentials', async () => {
  const bytes = Buffer.from('safe-evidence-installer');
  let downloadCount = 0;
  const result = await runWindowsOfflineInstallerCanary({
    baseUrl: 'https://openpath.example.test',
    accessToken: 'Bearer secret-token',
    classroomId: 'classroom-1',
    fetchImpl: async (url) => {
      if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
        return generationResponse(bytes);
      }
      downloadCount += 1;
      return downloadCount === 1 ? downloadResponse(bytes) : downloadResponse(bytes, 410);
    },
  });

  const evidence = JSON.stringify(result);
  assert.equal(evidence.includes('opaque-ref'), false);
  assert.equal(evidence.includes('downloadUrl'), false);
  assert.equal(evidence.includes('secret-token'), false);
  assert.equal(evidence.includes('Authorization'), false);
  assert.equal(evidence.includes('Cookie'), false);
  assert.equal(evidence.includes('jwt'), false);
});

test('windows offline installer canary can persist the verified executable without exposing its URL', async () => {
  const bytes = Buffer.from('persisted-safe-installer');
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-offline-canary-'));
  const outputPath = path.join(root, 'downloaded.exe');
  let downloadCount = 0;

  try {
    const result = await runWindowsOfflineInstallerCanary({
      baseUrl: 'http://127.0.0.1:3201',
      downloadBaseUrl: 'http://127.0.0.1:3201',
      outputPath,
      accessToken: 'secret-token',
      classroomId: 'classroom-1',
      fetchImpl: async (url) => {
        if (String(url).endsWith('/trpc/windowsOfflineInstaller.generate')) {
          return new Response(
            JSON.stringify({
              result: {
                data: {
                  fileName: 'OpenPath-Lab-Windows-Setup.exe',
                  version: '4.1.0',
                  sha256: hash(bytes),
                  downloadUrl:
                    'https://localhost:18443/api/windows-offline-installer/download?ref=opaque-ref',
                },
              },
            }),
            { status: 200 }
          );
        }
        downloadCount += 1;
        return downloadCount === 1 ? downloadResponse(bytes) : downloadResponse(bytes, 410);
      },
    });

    assert.equal(result.downloadBytes, bytes.length);
    assert.equal(result.downloadSha256, hash(bytes));
    assert.deepEqual(await readFile(outputPath), bytes);
    assert.equal(JSON.stringify(result).includes('opaque-ref'), false);
    assert.equal(JSON.stringify(result).includes('secret-token'), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
