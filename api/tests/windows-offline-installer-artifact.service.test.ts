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
        apiUrl: 'https://openpath.example.test',
        classroomId: 'classroom-7',
        user,
      });
      const artifactPath = service.resolvePublishedArtifactPath(result.referenceHash);

      assert.equal(result.fileName, 'OpenPath-Lab-North-Windows-Setup.exe');
      assert.equal(result.version, '4.1.0');
      assert.equal(result.sha256, sha256(Buffer.from('artifact')));
      assert.match(
        result.downloadUrl,
        /^https:\/\/openpath\.example\.test\/api\/windows-offline-installer\/download\?ref=ref-/u
      );
      assert.equal(result.downloadUrl.includes(result.artifactPath), false);
      assert.equal(result.reference.length > 20, true);
      assert.equal(await readFile(artifactPath, 'utf8'), 'artifact');
      assert.equal((await stat(artifactPath)).isFile(), true);
      assert.equal((await stat(path.join(root, 'artifacts'))).mode & 0o777, 0o700);
      assert.equal(ticketCalls.length, 1);
      assert.equal(overlayCalls.length, 1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  void test('invalidates the reference and removes staging output when publish fails', async () => {
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
      assert.equal(refs.invalidated.length, 1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
