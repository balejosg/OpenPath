import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { getRegisteredMachineRoutes } from './machines-route-test-helpers.js';

await describe('machine routes - agent delivery', async () => {
  await test('registers bootstrap, package, and whitelist delivery endpoints', async () => {
    const routes = await getRegisteredMachineRoutes();

    assert.deepEqual(
      routes
        .filter(
          (route) =>
            route.startsWith('GET /api/agent') ||
            route.startsWith('POST /api/agent/windows/releases') ||
            route === 'POST /api/agent/windows/rings' ||
            route === 'GET /api/machines/client-config' ||
            route === 'GET /w/whitelist.txt' ||
            route === 'GET /w/:machineToken/whitelist.txt'
        )
        .sort(),
      [
        'GET /api/agent/windows/bootstrap/manifest',
        'GET /api/agent/windows/bootstrap/bundle.zip',
        'GET /api/agent/windows/bootstrap/files/*path',
        'GET /api/agent/windows/manifest',
        'GET /api/agent/windows/files/*path',
        'POST /api/agent/windows/releases',
        'POST /api/agent/windows/releases/:build/retire',
        'POST /api/agent/windows/rings',
        'GET /api/agent/windows/releases/active',
        'GET /api/agent/linux/manifest',
        'GET /api/agent/linux/packages/:version',
        'GET /api/machines/client-config',
        'GET /w/whitelist.txt',
        'GET /w/:machineToken/whitelist.txt',
      ].sort()
    );
  });
});
