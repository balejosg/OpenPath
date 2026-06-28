import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';

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

await describe('test-support routes', async () => {
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
});
