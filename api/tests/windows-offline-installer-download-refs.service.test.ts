import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';

import {
  artifactFileNameFromReferenceHash,
  createWindowsOfflineDownloadRefsService,
  DownloadReferenceError,
  hashDownloadReference,
} from '../src/services/windows-offline-installer-download-refs.service.js';
import {
  startClassroomsTestHarness,
  type ClassroomsTestHarness,
} from './classrooms-test-harness.js';

let harness: ClassroomsTestHarness;

function adminUserId(): string {
  const payload = harness.adminToken.split('.')[1];
  assert.ok(payload, 'Expected a JWT payload in the admin token');
  const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as {
    sub?: string;
  };
  assert.ok(decoded.sub, 'Expected the admin token to contain a subject');
  return decoded.sub;
}

before(async () => {
  harness = await startClassroomsTestHarness();
});

after(async () => {
  await harness.close();
});

void describe('OpenPath Windows offline installer download references', () => {
  void test('stores only a hash and enforces attempt, consumed, and invalid states', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const minted = await service.mintReference({
      classroomId: (await harness.createClassroom()).id,
      classroomName: 'Lab North',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-North-Windows-Setup.exe',
      artifactSha256: 'a'.repeat(64),
      artifactSize: 42,
      ttlMinutes: 10,
      maxAttempts: 1,
    });

    assert.equal(minted.rawToken.length > 20, true);
    assert.equal(minted.ref.referenceHash, hashDownloadReference(minted.rawToken));
    assert.equal(minted.ref.referenceHash.includes(minted.rawToken), false);

    const consumedAttempt = await service.consumeAttempt(minted.rawToken);
    assert.equal(consumedAttempt.usedAttempts, 1);
    assert.equal(consumedAttempt.artifactFileName, 'OpenPath-Lab-North-Windows-Setup.exe');

    await assert.rejects(
      () => service.consumeAttempt(minted.rawToken),
      (error: unknown) => error instanceof DownloadReferenceError && error.code === 'EXHAUSTED'
    );

    await service.markConsumed(minted.rawToken);
    await assert.rejects(
      () => service.consumeAttempt(minted.rawToken),
      (error: unknown) => error instanceof DownloadReferenceError && error.code === 'CONSUMED'
    );

    await assert.rejects(
      () => service.consumeAttempt('A'.repeat(43)),
      (error: unknown) => error instanceof DownloadReferenceError && error.code === 'INVALID'
    );
  });

  void test('cleans consumed artifacts without touching unrelated template roots', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const classroomId = (await harness.createClassroom()).id;
    const minted = await service.mintReference({
      classroomId,
      classroomName: 'Lab South',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-South-Windows-Setup.exe',
      artifactSha256: 'b'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 10,
      maxAttempts: 2,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-cleanup-'));
    const artifactsDir = path.join(root, 'artifacts');
    const templateDir = path.join(root, 'templates');
    const artifactPath = path.join(
      artifactsDir,
      artifactFileNameFromReferenceHash(minted.ref.referenceHash)
    );
    const templatePath = path.join(templateDir, 'OpenPath-Windows-Setup-Template.exe');

    try {
      await mkdir(artifactsDir, { recursive: true });
      await mkdir(templateDir, { recursive: true });
      await writeFile(artifactPath, 'personalized');
      await writeFile(templatePath, 'immutable template');
      await service.markConsumed(minted.rawToken);

      await service.cleanupExpired(artifactsDir);

      await assert.rejects(() => readFile(artifactPath));
      assert.equal(await readFile(templatePath, 'utf8'), 'immutable template');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('does not delete an artifact while its final bounded attempt is in flight', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const classroomId = (await harness.createClassroom()).id;
    const minted = await service.mintReference({
      classroomId,
      classroomName: 'Lab In Flight',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-In-Flight-Windows-Setup.exe',
      artifactSha256: 'd'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 10,
      maxAttempts: 1,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-in-flight-'));
    const artifactPath = path.join(
      root,
      artifactFileNameFromReferenceHash(minted.ref.referenceHash)
    );

    try {
      await writeFile(artifactPath, 'active transfer');
      await service.consumeAttempt(minted.rawToken);

      await service.cleanupExpired(root);
      assert.equal(await readFile(artifactPath, 'utf8'), 'active transfer');

      await service.markConsumed(minted.rawToken);
      await service.cleanupExpired(root);
      await assert.rejects(() => readFile(artifactPath));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('allows bounded concurrent reservations without letting cleanup remove the active artifact', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const classroomId = (await harness.createClassroom()).id;
    const minted = await service.mintReference({
      classroomId,
      classroomName: 'Lab Concurrent',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-Concurrent-Windows-Setup.exe',
      artifactSha256: 'e'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 10,
      maxAttempts: 2,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-concurrent-'));
    const artifactPath = path.join(
      root,
      artifactFileNameFromReferenceHash(minted.ref.referenceHash)
    );

    try {
      await writeFile(artifactPath, 'active transfer');
      const reservations = await Promise.all([
        service.consumeAttempt(minted.rawToken),
        service.consumeAttempt(minted.rawToken),
      ]);
      assert.deepEqual(reservations.map((reservation) => reservation.usedAttempts).sort(), [1, 2]);

      await service.cleanupExpired(root);
      assert.equal(await readFile(artifactPath, 'utf8'), 'active transfer');

      await Promise.all([
        service.markConsumed(minted.rawToken),
        service.markConsumed(minted.rawToken),
      ]);
      await assert.rejects(
        () => service.consumeAttempt(minted.rawToken),
        (error: unknown) => error instanceof DownloadReferenceError && error.code === 'CONSUMED'
      );
      await service.cleanupExpired(root);
      await assert.rejects(() => readFile(artifactPath));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('gives newly published orphan artifacts time to acquire their reference row', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-orphan-'));
    const orphanPath = path.join(root, `${'f'.repeat(32)}.exe`);

    try {
      await writeFile(orphanPath, 'newly published artifact');
      await service.cleanupExpired(root);
      assert.equal(await readFile(orphanPath, 'utf8'), 'newly published artifact');

      const oldTimestamp = new Date(Date.now() - 10 * 60_000);
      await utimes(orphanPath, oldTimestamp, oldTimestamp);
      await service.cleanupExpired(root);
      await assert.rejects(() => readFile(orphanPath));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('invalidates a freshly minted reference explicitly', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const minted = await service.mintReference({
      classroomId: (await harness.createClassroom()).id,
      classroomName: 'Lab Rollback',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-Rollback-Windows-Setup.exe',
      artifactSha256: 'c'.repeat(64),
      artifactSize: 1,
      ttlMinutes: 10,
      maxAttempts: 1,
    });

    await service.invalidateReference(minted.rawToken);
    await assert.rejects(
      () => service.consumeAttempt(minted.rawToken),
      (error: unknown) => error instanceof DownloadReferenceError && error.code === 'INVALID'
    );
  });
});
