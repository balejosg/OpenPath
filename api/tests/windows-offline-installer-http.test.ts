import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';

import { serialize } from '../src/lib/windows-offline-installer.js';
import { startHttpTestHarness, type HttpTestHarness } from './http-test-harness.js';
import { assertStatus, bearerAuth, parseTRPC, uniqueEmail } from './test-utils.js';

let harness: HttpTestHarness;
let root: string;
let classroomId: string;
let adminToken: string;

function digest(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

before(async () => {
  root = await mkdtemp(path.join(tmpdir(), 'openpath-windows-installer-http-'));
  const templateBytes = serialize({
    schemaVersion: 1,
    apiUrl: 'https://openpath.example.test',
    classroomId: 'template-classroom',
    enrollmentToken: 'template-token',
    enrollmentTokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    captivePortalDomains: [],
    options: {
      approvedStudentBrowsers: ['Firefox'],
      installFirefoxIfMissing: true,
      enforceManagedBrowserBoundary: true,
    },
  });
  const templateDir = path.join(root, 'templates', '4.1.0', 'c'.repeat(40));
  await mkdir(templateDir, { recursive: true });
  const templatePath = path.join(templateDir, 'OpenPath-Windows-Setup-Template.exe');
  await writeFile(templatePath, templateBytes);
  await writeFile(
    `${templatePath}.sha256`,
    `${digest(templateBytes)}  ${path.basename(templatePath)}\n`
  );

  harness = await startHttpTestHarness({
    env: {
      DATA_DIR: path.join(root, 'data'),
      JWT_SECRET: 'windows-offline-installer-test-secret',
      PUBLIC_URL: 'https://openpath.example.test',
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: path.join(root, 'templates'),
      OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: path.join(root, 'artifacts'),
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: '4.1.0',
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: 'c'.repeat(40),
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: digest(templateBytes),
      OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_MAX_ATTEMPTS: '3',
      OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_TTL_MINUTES: '10',
    },
    resetDb: true,
    readyDelayMs: 250,
  });

  adminToken = (await harness.bootstrapAdminSession({ name: 'Offline Installer Admin' }))
    .accessToken;
  const classroomResponse = await harness.trpcMutate(
    'classrooms.create',
    { name: 'offline-installer-classroom', displayName: 'Offline Installer Classroom' },
    bearerAuth(adminToken)
  );
  assertStatus(classroomResponse, 200);
  const classroomPayload = (await parseTRPC(classroomResponse)) as { data?: { id?: string } };
  classroomId = classroomPayload.data?.id ?? '';
  assert.ok(classroomId);
});

after(async () => {
  await harness.close();
  await rm(root, { recursive: true, force: true });
});

void describe('OpenPath Windows offline installer HTTP capability', () => {
  void test('generates a personalized executable and consumes its download once', async () => {
    const response = await harness.trpcMutate(
      'windowsOfflineInstaller.generate',
      { classroomId },
      bearerAuth(adminToken)
    );
    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as {
      data: {
        fileName: string;
        version: string;
        sha256: string;
        tokenExpiresAt: string;
        downloadUrl: string;
        downloadExpiresAt: string;
      };
    };

    assert.equal(payload.data.version, '4.1.0');
    assert.match(payload.data.fileName, /\.exe$/u);
    assert.match(payload.data.sha256, /^[0-9a-f]{64}$/u);
    assert.match(payload.data.downloadUrl, /^https:\/\/openpath\.example\.test\/api\//u);

    const localDownloadUrl = payload.data.downloadUrl.replace(
      'https://openpath.example.test',
      harness.apiUrl
    );
    const download = await fetch(localDownloadUrl);
    assert.equal(download.status, 200);
    const bytes = Buffer.from(await download.arrayBuffer());
    assert.equal(digest(bytes), payload.data.sha256);
    assert.equal(download.headers.get('content-type'), 'application/octet-stream');

    const replay = await fetch(localDownloadUrl);
    assert.equal(replay.status, 410);
  });

  void test('maps a missing classroom to a not-found tRPC error', async () => {
    const response = await harness.trpcMutate(
      'windowsOfflineInstaller.generate',
      { classroomId: 'classroom-does-not-exist' },
      bearerAuth(adminToken)
    );

    assert.equal(response.status, 404);
  });

  void test('maps a teacher without classroom scope to a forbidden tRPC error', async () => {
    const groupResponse = await harness.trpcMutate(
      'groups.create',
      { name: 'offline-installer-private-group', displayName: 'Offline Installer Private Group' },
      bearerAuth(adminToken)
    );
    assertStatus(groupResponse, 200);
    const groupPayload = (await parseTRPC(groupResponse)) as { data?: { id?: string } };
    const groupId = groupPayload.data?.id ?? '';
    assert.ok(groupId);

    const restrictedClassroomResponse = await harness.trpcMutate(
      'classrooms.create',
      {
        name: 'offline-installer-restricted-classroom',
        displayName: 'Offline Installer Restricted Classroom',
        defaultGroupId: groupId,
      },
      bearerAuth(adminToken)
    );
    assert.ok([200, 201].includes(restrictedClassroomResponse.status));
    const restrictedClassroomPayload = (await parseTRPC(restrictedClassroomResponse)) as {
      data?: { id?: string };
    };
    const restrictedClassroomId = restrictedClassroomPayload.data?.id ?? '';
    assert.ok(restrictedClassroomId);

    const email = uniqueEmail('offline-installer-denied');
    const password = 'TeacherPassword123!';
    const userResponse = await harness.trpcMutate(
      'users.create',
      {
        email,
        password,
        name: 'Offline Installer Denied Teacher',
        role: 'teacher',
        groupIds: [],
      },
      bearerAuth(adminToken)
    );
    assertStatus(userResponse, 200);

    const loginResponse = await harness.trpcMutate('auth.login', { email, password });
    assertStatus(loginResponse, 200);
    const loginPayload = (await parseTRPC(loginResponse)) as {
      data?: { accessToken?: string };
    };
    const teacherToken = loginPayload.data?.accessToken ?? '';
    assert.ok(teacherToken);

    const response = await harness.trpcMutate(
      'windowsOfflineInstaller.generate',
      { classroomId: restrictedClassroomId },
      bearerAuth(teacherToken)
    );

    assert.equal(response.status, 403);
  });

  void test('maps unrecognized installer errors to an internal tRPC error', async () => {
    const templateDigest = process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256;
    delete process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256;

    try {
      const response = await harness.trpcMutate(
        'windowsOfflineInstaller.generate',
        { classroomId },
        bearerAuth(adminToken)
      );

      assert.equal(response.status, 500);
    } finally {
      if (templateDigest === undefined) {
        delete process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256;
      } else {
        process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256 = templateDigest;
      }
    }
  });
});
