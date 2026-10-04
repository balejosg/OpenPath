import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import { createFixtureClassroom } from './fixtures.js';
import {
  extractMachineToken,
  startTokenDeliveryHarness,
  type TokenDeliveryHarness,
} from './token-delivery-harness.js';

let harness: TokenDeliveryHarness;

void describe('Windows agent delivery', { timeout: 30000 }, async () => {
  before(async () => {
    harness = await startTokenDeliveryHarness();
  });

  after(async () => {
    await harness.close();
  });

  await describe('GET /api/agent/windows/*', async () => {
    let machineToken = '';

    before(async () => {
      await createFixtureClassroom({
        name: 'WindowsAgentClassroom',
        groupId: 'windows-agent-group',
      });

      const registerResponse = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${harness.registrationToken}`,
        },
        body: JSON.stringify({
          hostname: 'windows-agent-test-pc',
          classroomName: 'WindowsAgentClassroom',
          version: '4.0.0',
        }),
      });

      assert.strictEqual(registerResponse.status, 200);
      const registerData = (await registerResponse.json()) as { whitelistUrl: string };
      machineToken = extractMachineToken(registerData.whitelistUrl);
    });

    await test('should require machine bearer token for manifest', async () => {
      const response = await fetch(`${harness.apiUrl}/api/agent/windows/manifest`);
      assert.strictEqual(response.status, 401);
    });

    await test('should return manifest using server version and file hashes', async () => {
      const response = await fetch(`${harness.apiUrl}/api/agent/windows/manifest`, {
        headers: { Authorization: `Bearer ${machineToken}` },
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        success: boolean;
        version: string;
        files: { path: string; sha256: string; size: number }[];
      };

      assert.strictEqual(data.success, true);
      assert.ok(data.version.length > 0);
      assert.ok(data.files.length > 0);
      assert.ok(data.files.some((file) => file.path === 'scripts/Update-OpenPath.ps1'));
      assert.ok(data.files.some((file) => file.path === 'runtime/browser-policy-spec.json'));
      assert.ok(data.files.every((file) => file.sha256.length === 64));
      // Phase 5.2 D1: the native host source ships so install/update can compile
      // it; nothing else from native-host/ is published.
      const nativeHostSource = data.files.find(
        (file) => file.path === 'native-host/OpenPathNativeHost.cs'
      );
      assert.ok(nativeHostSource, 'native-host/OpenPathNativeHost.cs must be in the manifest');
      assert.strictEqual(nativeHostSource.sha256.length, 64);
      assert.ok(
        data.files.every(
          (file) => !file.path.startsWith('native-host/') || file.path.endsWith('.cs')
        ),
        'only .cs files may ship from native-host/'
      );
    });

    await test('should download manifest file by relative path', async () => {
      const manifestResponse = await fetch(`${harness.apiUrl}/api/agent/windows/manifest`, {
        headers: { Authorization: `Bearer ${machineToken}` },
      });
      assert.strictEqual(manifestResponse.status, 200);

      const manifest = (await manifestResponse.json()) as {
        files: { path: string }[];
      };
      const filePath = manifest.files[0]?.path;
      assert.ok(filePath);

      const response = await fetch(
        `${harness.apiUrl}/api/agent/windows/files/${filePath
          .split('/')
          .map((segment) => encodeURIComponent(segment))
          .join('/')}`,
        {
          headers: { Authorization: `Bearer ${machineToken}` },
        }
      );

      assert.strictEqual(response.status, 200);
      assert.ok((await response.text()).length > 0);
    });

    await test('should include Firefox browser extension assets in the Windows agent manifest', async () => {
      const response = await fetch(`${harness.apiUrl}/api/agent/windows/manifest`, {
        headers: { Authorization: `Bearer ${machineToken}` },
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        success: boolean;
        files: { path: string; sha256: string; size: number }[];
      };

      assert.strictEqual(data.success, true);
      assert.ok(data.files.some((file) => file.path === 'browser-extension/firefox/manifest.json'));
      assert.ok(
        data.files.some((file) => file.path === 'browser-extension/firefox/dist/background.js')
      );
      assert.ok(
        data.files.some((file) => file.path === 'browser-extension/firefox/popup/popup.html')
      );
    });
  });
});
