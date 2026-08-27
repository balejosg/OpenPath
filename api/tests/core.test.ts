import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-jwt-secret';

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

await describe('core routes', async () => {
  await test('registers health, config, and export endpoints', async () => {
    const { registerCoreRoutes } = await import('../src/routes/core.js');

    const app = express();
    registerCoreRoutes(app);

    const routes = getRegisteredRoutes(app);
    assert.ok(routes.includes('GET /health'));
    assert.ok(routes.includes('GET /ready'));
    assert.ok(routes.includes('GET /api/config'));
    assert.ok(routes.includes('GET /export/:name.txt'));
  });
});
