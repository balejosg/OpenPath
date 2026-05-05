import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { getRegisteredMachineRoutes } from './machines-route-test-helpers.js';

await describe('machine routes - agent delivery', async () => {
  await test('registers bootstrap, package, and whitelist delivery endpoints', async () => {
    const routes = await getRegisteredMachineRoutes();

    assert.deepEqual(
      routes.filter(
        (route) =>
          route.startsWith('GET /api/agent') ||
          route === 'GET /w/whitelist.txt' ||
          route === 'GET /w/:machineToken/whitelist.txt'
      ),
      [
        'GET /api/agent/windows/bootstrap/manifest',
        'GET /api/agent/windows/bootstrap/bundle.zip',
        'GET /api/agent/windows/bootstrap/files/*path',
        'GET /api/agent/windows/manifest',
        'GET /api/agent/windows/files/*path',
        'GET /api/agent/linux/manifest',
        'GET /api/agent/linux/packages/:version',
        'GET /w/whitelist.txt',
        'GET /w/:machineToken/whitelist.txt',
      ]
    );
  });
});
