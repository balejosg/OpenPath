import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';

import { serialize } from '../src/lib/windows-offline-installer.js';
import {
  createWindowsOfflineInstallerService,
  WindowsOfflineInstallerError,
} from '../src/services/windows-offline-installer-artifact.service.js';
import type {
  DownloadRefRecord,
  MintWindowsOfflineDownloadReferenceInput,
} from '../src/services/windows-offline-installer-download-refs.service.js';

const user = {
  sub: 'user_teacher_1',
  email: 'teacher@example.test',
  name: 'Teacher',
  roles: [{ role: 'teacher' as const, groupIds: [] }],
  type: 'access' as const,
};

function sha256(value: Buffer): string {
  return createHash('sha256').update(value).digest('hex');
}

function buildEnv(root: string, templateSha256: string): Record<string, string> {
  return {
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: path.join(root, 'templates'),
    OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: path.join(root, 'artifacts'),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: '4.1.0',
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: 'b'.repeat(40),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: templateSha256,
    PUBLIC_URL: 'https://openpath.example.test',
  };
}

interface TestRefs {
  invalidated: string[];
  cleanupExpired: () => Promise<number>;
  invalidateReference: (rawToken: string) => Promise<void>;
  revokeReferencesForArtifact: (artifactStorageFileName: string) => Promise<boolean>;
  mintReference: (
    input: MintWindowsOfflineDownloadReferenceInput
  ) => Promise<{ rawToken: string; ref: DownloadRefRecord }>;
}

function buildRefs(): TestRefs {
  let sequence = 0;
  const invalidated: string[] = [];
  return {
    invalidated,
    cleanupExpired: (): Promise<number> => Promise.resolve(0),
    invalidateReference: (rawToken: string): Promise<void> => {
      invalidated.push(rawToken);
      return Promise.resolve();
    },
    revokeReferencesForArtifact: (): Promise<boolean> => Promise.resolve(true),
    mintReference: (
      input: MintWindowsOfflineDownloadReferenceInput
    ): Promise<{ rawToken: string; ref: DownloadRefRecord }> => {
      sequence += 1;
      const rawToken = `ref-${String(sequence).padStart(2, '0')}-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`;
      return Promise.resolve({
        rawToken,
        ref: {
          id: `id-${String(sequence)}`,
          classroomId: input.classroomId,
          classroomName: input.classroomName,
          createdBy: input.createdBy ?? null,
          referenceHash: sha256(Buffer.from(rawToken)),
          artifactStorageFileName:
            input.artifactStorageFileName ?? `${sha256(Buffer.from(rawToken)).slice(0, 32)}.exe`,
          artifactFileName: input.artifactFileName,
          artifactSha256: input.artifactSha256,
          artifactSize: input.artifactSize,
          maxAttempts: input.maxAttempts,
          usedAttempts: 0,
          activeTransfers: 0,
          expiresAt: new Date(Date.now() + input.ttlMinutes * 60_000),
          consumedAt: null,
        },
      });
    },
  };
}

function tokenExpiry(): string {
  return new Date(Date.now() + 60 * 60 * 1000).toISOString();
}

void describe('OpenPath Windows offline installer artifact service', () => {
  void test('authorizes, overlays, hashes, publishes, and returns only download metadata', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-artifact-service-'));
    const templateBytes = serialize({
      schemaVersion: 1,
      apiUrl: 'https://openpath.example.test',
      classroomId: 'template-classroom',
      enrollmentToken: 'template-token',
      enrollmentTokenExpiresAt: '2026-08-25T23:00:00.000Z',
      captivePortalDomains: [],
      options: {
        approvedStudentBrowsers: ['Firefox'],
        installFirefoxIfMissing: true,
        enforceManagedBrowserBoundary: true,
      },
    });
    const env = buildEnv(root, sha256(templateBytes));
    const refs = buildRefs();
    const ticketCalls: unknown[] = [];
    const overlayCalls: unknown[] = [];

    try {
      const service = createWindowsOfflineInstallerService({
        env,
        refs,
        findClassroom: () =>
          Promise.resolve({
            id: 'classroom-7',
            name: 'Lab North',
            displayName: 'Laboratorio Norte',
            captivePortalDomains: ['login.example.test'],
          }),
        issueEnrollmentTicket: (input) => {
          ticketCalls.push(input);
          return Promise.resolve({
            ok: true as const,
            data: {
              classroomId: 'classroom-7',
              classroomName: 'Lab North',
              enrollmentToken: 'enrollment-token-1',
              expiresAt: tokenExpiry(),
            },
          });
        },
        loadTemplate: () => ({
          filePath: path.join(root, 'template.exe'),
          version: '4.1.0',
          commit: 'b'.repeat(40),
          sha256: sha256(templateBytes),
        }),
        applyOverlay: async (_templatePath, outputPath, payload) => {
          overlayCalls.push(payload);
          await import('node:fs/promises').then(({ writeFile }) =>
            writeFile(outputPath, 'artifact')
          );
        },
      });

      const result = await service.generate({
        apiUrl: 'https://openpath.example.test/base',
        classroomId: 'classroom-7',
        user,
      });
      const artifactPath = result.artifactPath;

      assert.equal(result.fileName, 'OpenPath-Lab-North-Windows-Setup.exe');
      assert.equal(result.version, '4.1.0');
      assert.equal(result.sha256, sha256(Buffer.from('artifact')));
      assert.match(
        result.downloadUrl,
        /^https:\/\/openpath\.example\.test\/base\/api\/windows-offline-installer\/download\?ref=ref-/u
      );
      assert.equal(result.downloadUrl.includes(result.artifactPath), false);
      assert.equal(result.reference.length > 20, true);
      assert.equal(result.artifactPath.includes(result.referenceHash), false);
      assert.equal(await readFile(artifactPath, 'utf8'), 'artifact');
      assert.equal((await stat(artifactPath)).isFile(), true);
      assert.equal((await stat(path.join(root, 'artifacts'))).mode & 0o777, 0o700);
      assert.equal(ticketCalls.length, 1);
      assert.equal(overlayCalls.length, 1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('publishing fails before minting and leaves no active reference', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-artifact-publish-failure-'));
    const templateBytes = Buffer.from('template');
    const refs = buildRefs();

    try {
      const service = createWindowsOfflineInstallerService({
        env: buildEnv(root, sha256(templateBytes)),
        refs,
        findClassroom: () =>
          Promise.resolve({
            id: 'classroom-8',
            name: 'Lab South',
            displayName: 'Lab South',
            captivePortalDomains: [],
          }),
        issueEnrollmentTicket: () =>
          Promise.resolve({
            ok: true as const,
            data: {
              classroomId: 'classroom-8',
              classroomName: 'Lab South',
              enrollmentToken: 'token',
              expiresAt: tokenExpiry(),
            },
          }),
        loadTemplate: () => ({
          filePath: path.join(root, 'template.exe'),
          version: '4.1.0',
          commit: 'b'.repeat(40),
          sha256: sha256(templateBytes),
        }),
        applyOverlay: async (_templatePath, outputPath) => {
          await import('node:fs/promises').then(({ writeFile }) =>
            writeFile(outputPath, 'artifact')
          );
        },
        renameArtifact: (): Promise<void> => Promise.reject(new Error('simulated publish failure')),
      });

      await assert.rejects(
        () =>
          service.generate({
            apiUrl: 'https://openpath.example.test',
            classroomId: 'classroom-8',
            user,
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerError && error.code === 'ARTIFACT_PUBLISH_FAILED'
      );
      assert.equal(refs.invalidated.length, 0);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('does not mint a consumable reference when artifact publication fails', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-artifact-no-orphan-'));
    const templateBytes = Buffer.from('template');
    const baseRefs = buildRefs();
    let mintCalls = 0;
    const refs: TestRefs = {
      ...baseRefs,
      invalidateReference: () => {
        throw new Error('simulated invalidation failure');
      },
      mintReference: (input) => {
        mintCalls += 1;
        return baseRefs.mintReference(input);
      },
    };

    try {
      const service = createWindowsOfflineInstallerService({
        env: buildEnv(root, sha256(templateBytes)),
        refs,
        findClassroom: () =>
          Promise.resolve({
            id: 'classroom-9',
            name: 'Lab Orphan',
            displayName: 'Lab Orphan',
            captivePortalDomains: [],
          }),
        issueEnrollmentTicket: () =>
          Promise.resolve({
            ok: true as const,
            data: {
              classroomId: 'classroom-9',
              classroomName: 'Lab Orphan',
              enrollmentToken: 'token',
              expiresAt: tokenExpiry(),
            },
          }),
        loadTemplate: () => ({
          filePath: path.join(root, 'template.exe'),
          version: '4.1.0',
          commit: 'b'.repeat(40),
          sha256: sha256(templateBytes),
        }),
        applyOverlay: async (_templatePath, outputPath) => {
          await import('node:fs/promises').then(({ writeFile }) =>
            writeFile(outputPath, 'artifact')
          );
        },
        renameArtifact: () => Promise.reject(new Error('simulated publish failure')),
      });

      await assert.rejects(
        () =>
          service.generate({
            apiUrl: 'https://openpath.example.test',
            classroomId: 'classroom-9',
            user,
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerError && error.code === 'ARTIFACT_PUBLISH_FAILED'
      );
      assert.equal(mintCalls, 0);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('publishes before minting and removes the published artifact when mint fails', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-artifact-mint-failure-'));
    const templateBytes = Buffer.from('template');
    const refs = buildRefs();
    const events: string[] = [];
    const storageFiles: string[] = [];

    try {
      const service = createWindowsOfflineInstallerService({
        env: buildEnv(root, sha256(templateBytes)),
        refs: {
          ...refs,
          mintReference: () => {
            events.push('mint');
            return Promise.reject(new Error('simulated mint failure'));
          },
        },
        findClassroom: () =>
          Promise.resolve({
            id: 'classroom-10',
            name: 'Lab Mint Failure',
            displayName: 'Lab Mint Failure',
            captivePortalDomains: [],
          }),
        issueEnrollmentTicket: () =>
          Promise.resolve({
            ok: true as const,
            data: {
              classroomId: 'classroom-10',
              classroomName: 'Lab Mint Failure',
              enrollmentToken: 'token',
              expiresAt: tokenExpiry(),
            },
          }),
        loadTemplate: () => ({
          filePath: path.join(root, 'template.exe'),
          version: '4.1.0',
          commit: 'b'.repeat(40),
          sha256: sha256(templateBytes),
        }),
        applyOverlay: async (_templatePath, outputPath) => {
          await import('node:fs/promises').then(({ writeFile }) =>
            writeFile(outputPath, 'artifact')
          );
        },
        renameArtifact: async (sourcePath, targetPath) => {
          events.push('publish');
          storageFiles.push(targetPath);
          await import('node:fs/promises').then(({ rename }) => rename(sourcePath, targetPath));
        },
      });

      await assert.rejects(
        () =>
          service.generate({
            apiUrl: 'https://openpath.example.test',
            classroomId: 'classroom-10',
            user,
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerError && error.code === 'REFERENCE_MINT_FAILED'
      );
      assert.deepEqual(events, ['publish', 'mint']);
      assert.equal(storageFiles.length, 1);
      const publishedFile = storageFiles[0];
      assert.ok(publishedFile);
      await assert.rejects(() => stat(publishedFile));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('compensates a reference row committed before mint reports failure', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-artifact-mint-uncertain-'));
    const templateBytes = Buffer.from('template');
    const baseRefs = buildRefs();
    const persistedArtifacts = new Set<string>();
    const revokedArtifacts: string[] = [];

    try {
      const service = createWindowsOfflineInstallerService({
        env: buildEnv(root, sha256(templateBytes)),
        refs: {
          ...baseRefs,
          mintReference: (input) => {
            assert.ok(input.artifactStorageFileName);
            persistedArtifacts.add(input.artifactStorageFileName);
            return Promise.reject(new Error('simulated commit acknowledgement failure'));
          },
          revokeReferencesForArtifact: (artifactStorageFileName) => {
            revokedArtifacts.push(artifactStorageFileName);
            persistedArtifacts.delete(artifactStorageFileName);
            return Promise.resolve(true);
          },
        },
        findClassroom: () =>
          Promise.resolve({
            id: 'classroom-11',
            name: 'Lab Uncertain Mint',
            displayName: 'Lab Uncertain Mint',
            captivePortalDomains: [],
          }),
        issueEnrollmentTicket: () =>
          Promise.resolve({
            ok: true as const,
            data: {
              classroomId: 'classroom-11',
              classroomName: 'Lab Uncertain Mint',
              enrollmentToken: 'token',
              expiresAt: tokenExpiry(),
            },
          }),
        loadTemplate: () => ({
          filePath: path.join(root, 'template.exe'),
          version: '4.1.0',
          commit: 'b'.repeat(40),
          sha256: sha256(templateBytes),
        }),
        applyOverlay: async (_templatePath, outputPath) => {
          await import('node:fs/promises').then(({ writeFile }) =>
            writeFile(outputPath, 'artifact')
          );
        },
      });

      await assert.rejects(
        () =>
          service.generate({
            apiUrl: 'https://openpath.example.test',
            classroomId: 'classroom-11',
            user,
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerError && error.code === 'REFERENCE_MINT_FAILED'
      );
      assert.equal(revokedArtifacts.length, 1);
      assert.equal(persistedArtifacts.size, 0);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('retains published bytes when reference revocation is uncertain', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'openpath-artifact-revoke-uncertain-'));
    const templateBytes = Buffer.from('template');
    const baseRefs = buildRefs();
    let publishedPath: string | undefined;

    try {
      const service = createWindowsOfflineInstallerService({
        env: buildEnv(root, sha256(templateBytes)),
        refs: {
          ...baseRefs,
          mintReference: () => Promise.reject(new Error('simulated mint acknowledgement loss')),
          revokeReferencesForArtifact: () =>
            Promise.reject(new Error('simulated reference store outage')),
        },
        findClassroom: () =>
          Promise.resolve({
            id: 'classroom-12',
            name: 'Lab Retained Artifact',
            displayName: 'Lab Retained Artifact',
            captivePortalDomains: [],
          }),
        issueEnrollmentTicket: () =>
          Promise.resolve({
            ok: true as const,
            data: {
              classroomId: 'classroom-12',
              classroomName: 'Lab Retained Artifact',
              enrollmentToken: 'token',
              expiresAt: tokenExpiry(),
            },
          }),
        loadTemplate: () => ({
          filePath: path.join(root, 'template.exe'),
          version: '4.1.0',
          commit: 'b'.repeat(40),
          sha256: sha256(templateBytes),
        }),
        applyOverlay: async (_templatePath, outputPath) => {
          await import('node:fs/promises').then(({ writeFile }) =>
            writeFile(outputPath, 'artifact')
          );
        },
        renameArtifact: async (sourcePath, targetPath) => {
          publishedPath = targetPath;
          await import('node:fs/promises').then(({ rename }) => rename(sourcePath, targetPath));
        },
      });

      await assert.rejects(
        () =>
          service.generate({
            apiUrl: 'https://openpath.example.test',
            classroomId: 'classroom-12',
            user,
          }),
        (error: unknown) =>
          error instanceof WindowsOfflineInstallerError && error.code === 'REFERENCE_MINT_FAILED'
      );
      assert.ok(publishedPath);
      assert.equal(await readFile(publishedPath, 'utf8'), 'artifact');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
