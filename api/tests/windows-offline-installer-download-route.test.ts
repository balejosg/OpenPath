import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import express from 'express';
import { after, before, describe, test } from 'node:test';

import {
  DownloadReferenceError,
  type DownloadRefRecord,
} from '../src/services/windows-offline-installer-download-refs.service.js';
import {
  createWindowsOfflineInstallerDownloadHandler,
  type WindowsOfflineInstallerRouteDeps,
} from '../src/routes/windows-offline-installer.js';

const reference = 'A'.repeat(43).replaceAll('A', 'a');
const referenceHash = 'c'.repeat(64);
const artifactStorageFileName = '11111111-1111-4111-8111-111111111111.exe';
const bytes = Buffer.from('personalized-exe-bytes');
const bytesSha256 = createHash('sha256').update(bytes).digest('hex');

let server: ReturnType<express.Express['listen']>;
let baseUrl: string;
let artifactsDir: string;
let consumedCount = 0;
let releasedCount = 0;
let renewalCount = 0;
let clearedLeaseTimers = 0;

function routeRecord(overrides: Partial<DownloadRefRecord> = {}): DownloadRefRecord {
  return {
    id: 'route-id',
    classroomId: 'classroom-1',
    classroomName: 'Lab North',
    createdBy: 'user-1',
    referenceHash,
    artifactStorageFileName,
    artifactFileName: 'OpenPath-Lab-North-Windows-Setup.exe',
    artifactSha256: bytesSha256,
    artifactSize: bytes.length,
    maxAttempts: 3,
    usedAttempts: 1,
    activeTransfers: 1,
    transferId: 'transfer-route',
    expiresAt: new Date(Date.now() + 60_000),
    consumedAt: null,
    ...overrides,
  };
}

async function withRouteServer(
  refs: WindowsOfflineInstallerRouteDeps['refs'],
  resolveArtifactPath: (storageFileName: string) => string,
  run: (url: string) => Promise<void>,
  timerOptions: Pick<WindowsOfflineInstallerRouteDeps, 'setIntervalImpl' | 'clearIntervalImpl'> = {}
): Promise<void> {
  const app = express();
  app.get(
    '/api/windows-offline-installer/download',
    createWindowsOfflineInstallerDownloadHandler({
      refs,
      resolveArtifactPath,
      ...timerOptions,
    })
  );
  const routeServer = await new Promise<ReturnType<typeof app.listen>>((resolve) => {
    const started = app.listen(0, '127.0.0.1', () => {
      resolve(started);
    });
  });
  const address = routeServer.address();
  assert.ok(address !== null && typeof address !== 'string');
  const url = `http://127.0.0.1:${String(address.port)}`;
  try {
    await run(url);
  } finally {
    await new Promise<void>((resolve, reject) => {
      routeServer.close((error) => {
        if (error) reject(error);
        else resolve();
      });
    });
  }
}

before(async () => {
  artifactsDir = await mkdtemp(path.join(tmpdir(), 'openpath-download-route-'));
  await writeFile(path.join(artifactsDir, artifactStorageFileName), bytes);

  const app = express();
  app.get(
    '/api/windows-offline-installer/download',
    createWindowsOfflineInstallerDownloadHandler({
      refs: {
        consumeAttempt: (rawReference) => {
          if (rawReference !== reference) {
            return Promise.reject(
              new DownloadReferenceError('INVALID', 'Unknown download reference')
            );
          }
          return Promise.resolve({
            id: 'id-1',
            classroomId: 'classroom-1',
            classroomName: 'Lab North',
            createdBy: 'user-1',
            referenceHash,
            artifactStorageFileName,
            artifactFileName: 'OpenPath-Lab-North-Windows-Setup.exe',
            artifactSha256: bytesSha256,
            artifactSize: bytes.length,
            maxAttempts: 3,
            usedAttempts: 1,
            activeTransfers: 1,
            transferId: 'transfer-1',
            expiresAt: new Date(Date.now() + 60_000),
            consumedAt: null,
          });
        },
        releaseAttempt: (): Promise<void> => {
          releasedCount += 1;
          return Promise.resolve();
        },
        renewAttempt: (rawReference, transferId): Promise<boolean> => {
          assert.equal(rawReference, reference);
          assert.equal(transferId, 'transfer-1');
          renewalCount += 1;
          return Promise.resolve(true);
        },
        transferLeaseMs: 3_000,
        markConsumed: (): Promise<boolean> => {
          consumedCount += 1;
          return Promise.resolve(true);
        },
      },
      setIntervalImpl: (callback: () => void): ReturnType<typeof setInterval> => {
        callback();
        return 1 as unknown as ReturnType<typeof setInterval>;
      },
      clearIntervalImpl: () => {
        clearedLeaseTimers += 1;
      },
      resolveArtifactPath: (storageFileName) => path.join(artifactsDir, storageFileName),
    })
  );

  server = await new Promise<ReturnType<typeof app.listen>>((resolve) => {
    const started = app.listen(0, '127.0.0.1', () => {
      resolve(started);
    });
  });
  const address = server.address();
  assert.ok(address !== null && typeof address !== 'string');
  baseUrl = `http://127.0.0.1:${String(address.port)}`;
});

after(async () => {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error) reject(error);
      else resolve();
    });
  });
  await rm(artifactsDir, { recursive: true, force: true });
});

void describe('OpenPath Windows offline installer download route', () => {
  void test('returns 400 when the download reference is missing', async () => {
    const missing = await fetch(`${baseUrl}/api/windows-offline-installer/download`);
    assert.equal(missing.status, 400);
    assert.deepEqual(await missing.json(), { error: 'Download reference unavailable' });
  });

  void test('returns 400 for malformed references before lookup', async () => {
    let lookupCalls = 0;
    await withRouteServer(
      {
        consumeAttempt: () => {
          lookupCalls += 1;
          return Promise.reject(new DownloadReferenceError('INVALID', 'unknown'));
        },
        releaseAttempt: () => Promise.resolve(),
        markConsumed: () => Promise.resolve(false),
      },
      (storageFileName) => path.join(artifactsDir, storageFileName),
      async (url) => {
        const malformed = await fetch(
          `${url}/api/windows-offline-installer/download?ref=not-a-reference`
        );
        assert.equal(malformed.status, 400);
        assert.deepEqual(await malformed.json(), { error: 'Download reference unavailable' });
      }
    );
    assert.equal(lookupCalls, 0);
  });

  void test('returns 404 for an unknown well-formed reference', async () => {
    const malformed = await fetch(
      `${baseUrl}/api/windows-offline-installer/download?ref=${'b'.repeat(43)}`
    );
    assert.equal(malformed.status, 404);
    assert.deepEqual(await malformed.json(), { error: 'Download reference unavailable' });
  });

  void test('returns a no-store attachment and consumes only after the full stream', async () => {
    renewalCount = 0;
    clearedLeaseTimers = 0;
    const response = await fetch(
      `${baseUrl}/api/windows-offline-installer/download?ref=${reference}`
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'application/octet-stream');
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(response.headers.get('content-length'), String(bytes.length));
    assert.equal(
      response.headers.get('content-disposition'),
      'attachment; filename="OpenPath-Lab-North-Windows-Setup.exe"'
    );
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);

    for (let attempt = 0; attempt < 20 && consumedCount === 0; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.equal(consumedCount, 1);
    assert.equal(releasedCount, 0);
    assert.equal(renewalCount, 1);
    assert.equal(clearedLeaseTimers, 1);
  });

  void test('maps reference lookup failures to their safe HTTP statuses', async () => {
    const cases = [
      { label: 'unknown well-formed reference', code: 'INVALID' as const, status: 404 },
      { label: 'expired reference', code: 'EXPIRED' as const, status: 410 },
      { label: 'exhausted reference', code: 'EXHAUSTED' as const, status: 410 },
      { label: 'consumed reference', code: 'CONSUMED' as const, status: 410 },
    ];

    for (const { label, code, status } of cases) {
      await withRouteServer(
        {
          consumeAttempt: () =>
            Promise.reject(new DownloadReferenceError(code, 'test reference failure')),
          releaseAttempt: () => Promise.resolve(),
          markConsumed: () => Promise.resolve(false),
        },
        (storageFileName) => path.join(artifactsDir, storageFileName),
        async (url) => {
          const response = await fetch(
            `${url}/api/windows-offline-installer/download?ref=${reference}`
          );
          assert.equal(label.length > 0, true);
          assert.equal(response.status, status);
          assert.deepEqual(await response.json(), { error: 'Download reference unavailable' });
        }
      );
    }
  });

  void test('contains a synchronous reference lookup failure as a safe JSON error', async () => {
    await withRouteServer(
      {
        consumeAttempt: () => {
          throw new Error('database secret must not escape the route');
        },
        releaseAttempt: () => Promise.resolve(),
        markConsumed: () => Promise.resolve(false),
      },
      (storageFileName) => path.join(artifactsDir, storageFileName),
      async (url) => {
        const response = await fetch(
          `${url}/api/windows-offline-installer/download?ref=${reference}`
        );
        assert.equal(response.status, 500);
        assert.deepEqual(await response.json(), { error: 'Download failed' });
      }
    );
  });

  void test('returns safe errors for missing transfer leases and unexpected lookup failures', async () => {
    await withRouteServer(
      {
        consumeAttempt: () => {
          const record = routeRecord();
          delete record.transferId;
          return Promise.resolve(record);
        },
        releaseAttempt: () => Promise.resolve(),
        markConsumed: () => Promise.resolve(false),
      },
      (storageFileName) => path.join(artifactsDir, storageFileName),
      async (url) => {
        const response = await fetch(
          `${url}/api/windows-offline-installer/download?ref=${reference}`
        );
        assert.equal(response.status, 500);
        assert.deepEqual(await response.json(), { error: 'Download failed' });
      }
    );

    await withRouteServer(
      {
        consumeAttempt: () => Promise.reject(new Error('database unavailable')),
        releaseAttempt: () => Promise.resolve(),
        markConsumed: () => Promise.resolve(false),
      },
      (storageFileName) => path.join(artifactsDir, storageFileName),
      async (url) => {
        const response = await fetch(
          `${url}/api/windows-offline-installer/download?ref=${reference}`
        );
        assert.equal(response.status, 500);
        assert.deepEqual(await response.json(), { error: 'Download failed' });
      }
    );
  });

  void test('releases the reserved attempt when the artifact path or bytes are invalid', async () => {
    let releaseCalls = 0;
    const refs = {
      consumeAttempt: (): Promise<DownloadRefRecord> => Promise.resolve(routeRecord()),
      releaseAttempt: (): Promise<void> => {
        releaseCalls += 1;
        return Promise.resolve();
      },
      markConsumed: (): Promise<boolean> => Promise.resolve(false),
    };

    await withRouteServer(
      refs,
      () => {
        throw new Error('unsafe artifact path');
      },
      async (url) => {
        const response = await fetch(
          `${url}/api/windows-offline-installer/download?ref=${reference}`
        );
        assert.equal(response.status, 404);
        assert.deepEqual(await response.json(), { error: 'Installer artifact unavailable' });
      }
    );

    await withRouteServer(
      refs,
      () => path.join(artifactsDir, 'missing-artifact.exe'),
      async (url) => {
        const response = await fetch(
          `${url}/api/windows-offline-installer/download?ref=${reference}`
        );
        assert.equal(response.status, 404);
        assert.deepEqual(await response.json(), { error: 'Installer artifact unavailable' });
      }
    );

    await withRouteServer(
      {
        ...refs,
        consumeAttempt: () => Promise.resolve(routeRecord({ artifactSha256: '0'.repeat(64) })),
      },
      (storageFileName) => path.join(artifactsDir, storageFileName),
      async (url) => {
        const response = await fetch(
          `${url}/api/windows-offline-installer/download?ref=${reference}`
        );
        assert.equal(response.status, 404);
        assert.deepEqual(await response.json(), { error: 'Installer artifact unavailable' });
      }
    );

    assert.equal(releaseCalls, 3);
  });

  void test('aborts a transfer when its lease cannot be renewed', async () => {
    for (const renewAttempt of [
      (): Promise<boolean> => Promise.resolve(false),
      (): Promise<boolean> => Promise.reject(new Error('lease store unavailable')),
    ]) {
      await writeFile(path.join(artifactsDir, artifactStorageFileName), bytes);
      let releaseCalls = 0;
      let renewalCalls = 0;
      await withRouteServer(
        {
          consumeAttempt: () => Promise.resolve(routeRecord()),
          releaseAttempt: () => {
            releaseCalls += 1;
            return Promise.resolve();
          },
          markConsumed: () => Promise.resolve(true),
          renewAttempt: () => {
            renewalCalls += 1;
            return renewAttempt();
          },
          transferLeaseMs: 3_000,
        },
        (storageFileName) => path.join(artifactsDir, storageFileName),
        async (url) => {
          try {
            const response = await fetch(
              `${url}/api/windows-offline-installer/download?ref=${reference}`
            );
            await response.arrayBuffer();
          } catch {
            // The route destroys the response after a failed lease renewal.
          }
        },
        {
          setIntervalImpl: (callback: () => void) => {
            queueMicrotask(callback);
            return { unref: () => undefined } as unknown as ReturnType<typeof setInterval>;
          },
          clearIntervalImpl: () => undefined,
        }
      );
      assert.equal(renewalCalls, 1);
      assert.equal(releaseCalls, 1);
    }
  });

  void test('does not leave a transfer active when marking completion fails', async () => {
    let markCalls = 0;
    let releaseCalls = 0;
    await writeFile(path.join(artifactsDir, artifactStorageFileName), bytes);
    await withRouteServer(
      {
        consumeAttempt: () => Promise.resolve(routeRecord()),
        releaseAttempt: () => {
          releaseCalls += 1;
          throw new Error('release unavailable');
        },
        markConsumed: () => {
          markCalls += 1;
          throw new Error('mark unavailable');
        },
      },
      (storageFileName) => path.join(artifactsDir, storageFileName),
      async (url) => {
        const response = await fetch(
          `${url}/api/windows-offline-installer/download?ref=${reference}`
        );
        assert.equal(response.status, 200);
        assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
      }
    );

    for (let attempt = 0; attempt < 20 && markCalls === 0; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.equal(markCalls, 1);
    assert.equal(releaseCalls, 1);
  });
});
