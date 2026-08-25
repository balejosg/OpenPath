import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import express from 'express';
import { after, before, describe, test } from 'node:test';

import {
  artifactFileNameFromReferenceHash,
  DownloadReferenceError,
} from '../src/services/windows-offline-installer-download-refs.service.js';
import { createWindowsOfflineInstallerDownloadHandler } from '../src/routes/windows-offline-installer.js';

const reference = 'A'.repeat(43).replaceAll('A', 'a');
const referenceHash = 'c'.repeat(64);
const bytes = Buffer.from('personalized-exe-bytes');
const bytesSha256 = createHash('sha256').update(bytes).digest('hex');

let server: ReturnType<express.Express['listen']>;
let baseUrl: string;
let artifactsDir: string;
let consumedCount = 0;

before(async () => {
  artifactsDir = await mkdtemp(path.join(tmpdir(), 'openpath-download-route-'));
  await writeFile(path.join(artifactsDir, artifactFileNameFromReferenceHash(referenceHash)), bytes);

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
            artifactFileName: 'OpenPath-Lab-North-Windows-Setup.exe',
            artifactSha256: bytesSha256,
            artifactSize: bytes.length,
            maxAttempts: 3,
            usedAttempts: 1,
            expiresAt: new Date(Date.now() + 60_000),
            consumedAt: null,
          });
        },
        markConsumed: (): Promise<void> => {
          consumedCount += 1;
          return Promise.resolve();
        },
      },
      resolveArtifactPath: (hash) =>
        path.join(artifactsDir, artifactFileNameFromReferenceHash(hash)),
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
  void test('rejects missing and malformed references before lookup', async () => {
    const missing = await fetch(`${baseUrl}/api/windows-offline-installer/download`);
    assert.equal(missing.status, 400);

    const malformed = await fetch(
      `${baseUrl}/api/windows-offline-installer/download?ref=not-a-reference`
    );
    assert.equal(malformed.status, 400);
  });

  void test('returns a no-store attachment and consumes only after the full stream', async () => {
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
  });
});
