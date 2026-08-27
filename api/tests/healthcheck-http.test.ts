import assert from 'node:assert/strict';
import type { Server } from 'node:http';
import express from 'express';
import { afterEach, test } from 'node:test';

import { registerCoreRoutes } from '../src/routes/core.js';
import type { ReadinessResult } from '../src/services/healthcheck.service.js';

const servers: Server[] = [];

async function startTestServer(readiness: () => Promise<ReadinessResult>): Promise<string> {
  const app = express();
  registerCoreRoutes(app, { getReadinessStatus: readiness });
  const server = await new Promise<Server>((resolve) => {
    const started = app.listen(0, '127.0.0.1', () => {
      resolve(started);
    });
  });
  servers.push(server);
  const address = server.address();
  assert.ok(address !== null && typeof address !== 'string');
  return `http://127.0.0.1:${String(address.port)}`;
}

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.close(() => {
            resolve();
          });
        })
    )
  );
});

void test('keeps liveness 200 while readiness reports a degraded offline installer', async () => {
  const baseUrl = await startTestServer(() =>
    Promise.resolve({
      status: 'degraded',
      service: 'openpath-api',
      uptime: 1,
      responseTime: '0 ms',
      checks: {
        windowsOfflineInstaller: {
          status: 'error',
          error: 'TEMPLATE_HASH_MISMATCH',
        },
        storage: { status: 'error', error: '/srv/openpath/password=secret-token' },
      },
    })
  );

  const health = await fetch(`${baseUrl}/health`);
  const ready = await fetch(`${baseUrl}/ready`);

  assert.equal(health.status, 200);
  assert.equal(ready.status, 503);
  assert.deepEqual(await ready.json(), {
    status: 'degraded',
    service: 'openpath-api',
    uptime: 1,
    responseTime: '0 ms',
    checks: {
      windowsOfflineInstaller: {
        status: 'error',
        error: 'TEMPLATE_HASH_MISMATCH',
      },
      storage: {
        status: 'error',
        error: 'UNAVAILABLE',
      },
    },
  });
});

void test('returns 200 from readiness for a valid capability', async () => {
  const baseUrl = await startTestServer(() =>
    Promise.resolve({
      status: 'ok',
      service: 'openpath-api',
      uptime: 1,
      responseTime: '0 ms',
      checks: {},
    })
  );

  const response = await fetch(`${baseUrl}/ready`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    status: 'ok',
    service: 'openpath-api',
    uptime: 1,
    responseTime: '0 ms',
    checks: {},
  });
});

void test('does not expose raw storage errors through readiness', async () => {
  const baseUrl = await startTestServer(() =>
    Promise.resolve({
      status: 'degraded',
      service: 'openpath-api',
      uptime: 1,
      responseTime: '0 ms',
      checks: {
        storage: {
          status: 'error',
          error: '/srv/openpath/password=secret-token',
        },
      },
    })
  );

  const response = await fetch(`${baseUrl}/ready`);
  const body = JSON.stringify(await response.json());

  assert.equal(response.status, 503);
  assert.equal(body.includes('secret-token'), false);
  assert.equal(body.includes('/srv/openpath'), false);
});
