import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';

import { runWindowsOfflineInstallerCanary } from '../scripts/windows-offline-installer-canary.mjs';

function hash(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

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
    replayStatus: 410,
  });
});
