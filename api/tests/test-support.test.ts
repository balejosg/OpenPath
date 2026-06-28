import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';

import { startHttpTestHarness } from './http-test-harness.js';

function getRegisteredRoutes(app: express.Express): string[] {
  return (
    app.router.stack as unknown as {
      route?: { path: string; methods: Record<string, boolean> };
    }[]
  )
    .filter((layer) => layer.route)
    .flatMap((layer) =>
      Object.keys(layer.route?.methods ?? {}).map(
        (method) => `${method.toUpperCase()} ${layer.route?.path ?? ''}`
      )
    );
}

await describe('test-support routes', { timeout: 30000 }, async () => {
  await test('registers teacher/admin-only test helpers in test mode', async () => {
    process.env.NODE_ENV = 'test';
    process.env.JWT_SECRET = 'test-jwt-secret';

    const { registerTestSupportRoutes } = await import('../src/routes/test-support.js');

    const app = express();
    registerTestSupportRoutes(app, {
      getCurrentEvaluationTime: () => new Date('2026-04-01T00:00:00Z'),
      setTestNowOverride: () => undefined,
    });

    const routes = getRegisteredRoutes(app);
    assert.ok(routes.includes('GET /api/test-support/machine-context/:hostname'));
    assert.ok(routes.includes('POST /api/test-support/clock'));
    assert.ok(routes.includes('POST /api/test-support/tick-boundaries'));
  });

  // HTTP integration tests for the handler functions
  await describe('route handlers via HTTP', async () => {
    let harness: Awaited<ReturnType<typeof startHttpTestHarness>> | undefined;
    let adminToken = '';

    before(async () => {
      harness = await startHttpTestHarness({
        env: { JWT_SECRET: 'test-jwt-secret' },
        readyDelayMs: 1000,
        resetDb: true,
      });
      const session = await harness.bootstrapAdminSession({ name: 'Test Support Admin' });
      adminToken = session.accessToken;
    });

    after(async () => {
      if (harness !== undefined) {
        await harness.close();
      }
    });

    function getApiUrl(): string {
      if (harness === undefined) {
        throw new Error('Harness not initialized');
      }
      return harness.apiUrl;
    }

    // --- /api/test-support/clock ---

    await test('POST /api/test-support/clock returns 401 without auth token', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/clock`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ at: null }),
      });
      assert.strictEqual(resp.status, 401);
    });

    await test('POST /api/test-support/clock with null at resets the clock', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/clock`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: null }),
      });
      assert.strictEqual(resp.status, 200);
      const body = (await resp.json()) as { success: boolean; now: string | null };
      assert.strictEqual(body.success, true);
      assert.strictEqual(body.now, null);
    });

    await test('POST /api/test-support/clock with empty string at returns 400', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/clock`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: '' }),
      });
      assert.strictEqual(resp.status, 400);
      const body = (await resp.json()) as { success: boolean };
      assert.strictEqual(body.success, false);
    });

    await test('POST /api/test-support/clock with invalid date returns 400', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/clock`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: 'not-a-date' }),
      });
      assert.strictEqual(resp.status, 400);
      const body = (await resp.json()) as { success: boolean };
      assert.strictEqual(body.success, false);
    });

    await test('POST /api/test-support/clock with valid ISO string sets the clock', async () => {
      const isoDate = '2026-01-01T00:00:00Z';
      const resp = await fetch(`${getApiUrl()}/api/test-support/clock`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: isoDate }),
      });
      assert.strictEqual(resp.status, 200);
      const body = (await resp.json()) as { success: boolean; now: string };
      assert.strictEqual(body.success, true);
      assert.ok(typeof body.now === 'string');

      // Reset the clock so it does not affect other tests
      await fetch(`${getApiUrl()}/api/test-support/clock`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: null }),
      });
    });

    // --- /api/test-support/machine-context/:hostname ---

    await test('GET /api/test-support/machine-context/:hostname returns 401 without auth', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/machine-context/test-host`);
      assert.strictEqual(resp.status, 401);
    });

    await test('GET /api/test-support/machine-context/:hostname returns 200 with admin token', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/machine-context/test-host`, {
        headers: { Authorization: `Bearer ${adminToken}` },
      });
      assert.strictEqual(resp.status, 200);
      const body = (await resp.json()) as { success: boolean };
      assert.strictEqual(body.success, true);
    });

    // --- /api/test-support/tick-boundaries ---

    await test('POST /api/test-support/tick-boundaries returns 401 without auth', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/tick-boundaries`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ at: '2026-01-01T00:00:00Z' }),
      });
      assert.strictEqual(resp.status, 401);
    });

    await test('POST /api/test-support/tick-boundaries returns 400 when at is missing', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/tick-boundaries`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({}),
      });
      assert.strictEqual(resp.status, 400);
      const body = (await resp.json()) as { success: boolean };
      assert.strictEqual(body.success, false);
    });

    await test('POST /api/test-support/tick-boundaries returns 400 when at is empty string', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/tick-boundaries`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: '' }),
      });
      assert.strictEqual(resp.status, 400);
      const body = (await resp.json()) as { success: boolean };
      assert.strictEqual(body.success, false);
    });

    await test('POST /api/test-support/tick-boundaries returns 400 when at is invalid date', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/tick-boundaries`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: 'bad-date' }),
      });
      assert.strictEqual(resp.status, 400);
      const body = (await resp.json()) as { success: boolean };
      assert.strictEqual(body.success, false);
    });

    await test('POST /api/test-support/tick-boundaries returns 200 with valid ISO at', async () => {
      const resp = await fetch(`${getApiUrl()}/api/test-support/tick-boundaries`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${adminToken}`,
        },
        body: JSON.stringify({ at: '2026-01-01T00:00:00Z' }),
      });
      assert.strictEqual(resp.status, 200);
      const body = (await resp.json()) as { success: boolean };
      assert.strictEqual(body.success, true);
    });
  });
});
