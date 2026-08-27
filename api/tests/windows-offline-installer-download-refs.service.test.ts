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

    assert.ok(consumedAttempt.transferId);
    await service.markConsumed(minted.rawToken, consumedAttempt.transferId);
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
      artifactStorageFileName: '22222222-2222-4222-8222-222222222222.exe',
      artifactSha256: 'b'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 10,
      maxAttempts: 2,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-cleanup-'));
    const artifactsDir = path.join(root, 'artifacts');
    const templateDir = path.join(root, 'templates');
    const artifactPath = path.join(artifactsDir, minted.ref.artifactStorageFileName);
    const templatePath = path.join(templateDir, 'OpenPath-Windows-Setup-Template.exe');

    try {
      await mkdir(artifactsDir, { recursive: true });
      await mkdir(templateDir, { recursive: true });
      await writeFile(artifactPath, 'personalized');
      await writeFile(templatePath, 'immutable template');
      const attempt = await service.consumeAttempt(minted.rawToken);
      assert.ok(attempt.transferId);
      await service.markConsumed(minted.rawToken, attempt.transferId);

      await service.cleanupExpired(artifactsDir);

      await assert.rejects(() => readFile(artifactPath));
      assert.equal(await readFile(templatePath, 'utf8'), 'immutable template');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('removes an expired reference and artifact without another generation', async () => {
    let currentTime = new Date();
    const service = createWindowsOfflineDownloadRefsService({
      now: () => new Date(currentTime),
    });
    const classroomId = (await harness.createClassroom()).id;
    const minted = await service.mintReference({
      classroomId,
      classroomName: 'Lab Expired',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-Expired-Windows-Setup.exe',
      artifactSha256: 'a'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 1,
      maxAttempts: 1,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-expired-'));
    const artifactPath = path.join(root, minted.ref.artifactStorageFileName);

    try {
      await writeFile(artifactPath, 'expired artifact');
      currentTime = new Date(currentTime.getTime() + 2 * 60_000);

      await assert.rejects(
        () => service.consumeAttempt(minted.rawToken),
        (error: unknown) => error instanceof DownloadReferenceError && error.code === 'EXPIRED'
      );
      await service.cleanupExpired(root);

      await assert.rejects(
        () => service.consumeAttempt(minted.rawToken),
        (error: unknown) => error instanceof DownloadReferenceError && error.code === 'INVALID'
      );
      await assert.rejects(() => readFile(artifactPath));
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
      const attempt = await service.consumeAttempt(minted.rawToken);

      await service.cleanupExpired(root);
      assert.equal(await readFile(artifactPath, 'utf8'), 'active transfer');

      assert.ok(attempt.transferId);
      await service.markConsumed(minted.rawToken, attempt.transferId);
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

      await Promise.all(
        reservations.map((reservation) => {
          assert.ok(reservation.transferId);
          return service.markConsumed(minted.rawToken, reservation.transferId);
        })
      );
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

  void test('cleans abandoned staging artifacts after the orphan grace period', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-staging-orphan-'));
    const orphanPath = path.join(root, '.123-11111111-1111-4111-8111-111111111111.staging.exe');

    try {
      await writeFile(orphanPath, 'abandoned staging artifact');
      await service.cleanupExpired(root);
      assert.equal(await readFile(orphanPath, 'utf8'), 'abandoned staging artifact');

      const oldTimestamp = new Date(Date.now() - 10 * 60_000);
      await utimes(orphanPath, oldTimestamp, oldTimestamp);
      await service.cleanupExpired(root);
      await assert.rejects(() => readFile(orphanPath));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('honors configured artifact retention instead of using a fixed orphan grace period', async () => {
    const service = createWindowsOfflineDownloadRefsService();
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-retention-'));
    const orphanPath = path.join(root, `${'1'.repeat(32)}.exe`);

    try {
      await writeFile(orphanPath, 'retained artifact');
      const oneHourAgo = new Date(Date.now() - 60 * 60_000);
      await utimes(orphanPath, oneHourAgo, oneHourAgo);

      await (
        service.cleanupExpired as unknown as (
          artifactsDir: string,
          options: { artifactRetentionHours: number }
        ) => Promise<number>
      )(root, { artifactRetentionHours: 24 });

      assert.equal(await readFile(orphanPath, 'utf8'), 'retained artifact');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('recovers an abandoned final transfer after a simulated process restart', async () => {
    let currentTime = new Date();
    const service = createWindowsOfflineDownloadRefsService({ now: () => new Date(currentTime) });
    const classroomId = (await harness.createClassroom()).id;
    const minted = await service.mintReference({
      classroomId,
      classroomName: 'Lab Crash Recovery',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-Crash-Recovery-Windows-Setup.exe',
      artifactSha256: 'a'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 10,
      maxAttempts: 1,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-crash-recovery-'));
    const artifactPath = path.join(
      root,
      artifactFileNameFromReferenceHash(minted.ref.referenceHash)
    );

    try {
      await writeFile(artifactPath, 'active transfer');
      await service.consumeAttempt(minted.rawToken);

      currentTime = new Date(currentTime.getTime() + 26 * 60_000);
      await service.cleanupExpired(root);

      await assert.rejects(
        () => service.consumeAttempt(minted.rawToken),
        (error: unknown) => error instanceof DownloadReferenceError
      );
      await assert.rejects(() => readFile(artifactPath));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('renews a slow legitimate transfer before cleanup can reclaim its lease', async () => {
    let currentTime = new Date();
    const service = createWindowsOfflineDownloadRefsService({
      now: () => new Date(currentTime),
      transferLeaseMs: 5 * 60_000,
    });
    const classroomId = (await harness.createClassroom()).id;
    const minted = await service.mintReference({
      classroomId,
      classroomName: 'Lab Slow Transfer',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-Slow-Transfer-Windows-Setup.exe',
      artifactSha256: 'e'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 1,
      maxAttempts: 1,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-slow-transfer-'));
    const artifactPath = path.join(
      root,
      artifactFileNameFromReferenceHash(minted.ref.referenceHash)
    );

    try {
      await writeFile(artifactPath, 'slow transfer');
      const attempt = await service.consumeAttempt(minted.rawToken);
      currentTime = new Date(currentTime.getTime() + 5 * 60_000);
      assert.ok(attempt.transferId);
      assert.equal(await service.renewAttempt(minted.rawToken, attempt.transferId), true);

      currentTime = new Date(currentTime.getTime() + 2 * 60_000);
      await service.cleanupExpired(root);
      assert.equal(await readFile(artifactPath, 'utf8'), 'slow transfer');

      await service.markConsumed(minted.rawToken, attempt.transferId);
      await service.cleanupExpired(root);
      await assert.rejects(() => readFile(artifactPath));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('recovers a transfer after its last heartbeat expires', async () => {
    let currentTime = new Date();
    const transferLeaseMs = 5 * 60_000;
    const service = createWindowsOfflineDownloadRefsService({
      now: () => new Date(currentTime),
      transferLeaseMs,
    });
    const classroomId = (await harness.createClassroom()).id;
    const minted = await service.mintReference({
      classroomId,
      classroomName: 'Lab Lease Deadline',
      createdBy: adminUserId(),
      artifactFileName: 'OpenPath-Lab-Lease-Deadline-Windows-Setup.exe',
      artifactSha256: 'f'.repeat(64),
      artifactSize: 12,
      ttlMinutes: 1,
      maxAttempts: 1,
    });
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-ref-lease-deadline-'));
    const artifactPath = path.join(
      root,
      artifactFileNameFromReferenceHash(minted.ref.referenceHash)
    );

    try {
      await writeFile(artifactPath, 'lease deadline');
      const attempt = await service.consumeAttempt(minted.rawToken);
      assert.ok(attempt.transferId);

      currentTime = new Date(currentTime.getTime() + 4 * 60_000);
      assert.equal(await service.renewAttempt(minted.rawToken, attempt.transferId), true);

      currentTime = new Date(currentTime.getTime() + 6 * 60_000);
      await service.cleanupExpired(root);
      await assert.rejects(() => readFile(artifactPath));
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
