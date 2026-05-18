/**
 * Dashboard API Integration Tests (Node.js native test runner)
 * Tests for Express routes in index.ts
 *
 * IMPORTANT: These tests require the API server to be running.
 * The Dashboard now acts as a tRPC client, so integration tests
 * need to either:
 * 1. Mock the tRPC client
 * 2. Run against a real API instance
 *
 * TODO: Implement proper mocking for tRPC client
 */

import { describe, it } from 'node:test';
import assert from 'node:assert';
import request from 'supertest';
import app from '../src/index.js';

// Note: These tests are simplified since we now depend on the API
// Full integration tests should mock the tRPC client

await describe('Dashboard API Routes', async () => {
  await describe('Authentication Endpoints', async () => {
    await it('POST /api/auth/login returns 400 for missing credentials', async () => {
      const response = await request(app).post('/api/auth/login').send({});

      assert.strictEqual(response.status, 400);
    });

    await it('GET /api/auth/check returns authenticated: false without token', async () => {
      const response = await request(app).get('/api/auth/check');

      assert.strictEqual(response.status, 200);
      const body = response.body as { authenticated?: boolean };
      assert.strictEqual(body.authenticated, false);
    });

    await it('POST /api/auth/logout succeeds without token', async () => {
      const response = await request(app).post('/api/auth/logout');

      assert.strictEqual(response.status, 200);
      const body = response.body as { success?: boolean };
      assert.strictEqual(body.success, true);
    });

    await it('POST /api/auth/change-password returns 401 without auth', async () => {
      const response = await request(app).post('/api/auth/change-password').send({
        currentPassword: 'CurrentPassword123!',
        newPassword: 'NewPassword123!',
      });

      assert.strictEqual(response.status, 401);
    });

    await it('POST /api/auth/change-password validates minimum length (8)', async () => {
      const response = await request(app)
        .post('/api/auth/change-password')
        .set('Authorization', 'Bearer test-token')
        .send({
          currentPassword: 'CurrentPassword123!',
          newPassword: 'short',
        });

      assert.strictEqual(response.status, 400);
      const body = response.body as { error?: string };
      assert.strictEqual(body.error, 'Password must be at least 8 characters');
    });
  });

  await describe('Unauthenticated Access', async () => {
    await it('GET /api/groups returns 401 without auth', async () => {
      const response = await request(app).get('/api/groups');
      assert.strictEqual(response.status, 401);
    });

    await it('GET /api/stats returns 401 without auth', async () => {
      const response = await request(app).get('/api/stats');
      assert.strictEqual(response.status, 401);
    });

    await it('GET /api/system/status returns 401 without auth', async () => {
      const response = await request(app).get('/api/system/status');
      assert.strictEqual(response.status, 401);
    });

    await it('POST /api/groups returns 401 without auth', async () => {
      const response = await request(app)
        .post('/api/groups')
        .send({ name: 'test', displayName: 'Test' });
      assert.strictEqual(response.status, 401);
    });
  });

  await describe('Export Endpoint', async () => {
    await it('GET /export/:name.txt redirects to API', async () => {
      const response = await request(app).get('/export/test-group.txt').redirects(0);

      // Should redirect to API export endpoint
      assert.strictEqual(response.status, 302);
      assert.ok(response.headers.location?.includes('/export/'));
    });
  });

  await describe('404 Handler', async () => {
    await it('GET / returns 404', async () => {
      const response = await request(app).get('/');
      // Dashboard no longer serves SPA - that's done by the API
      assert.strictEqual(response.status, 404);
    });

    await it('GET /nonexistent returns 404', async () => {
      const response = await request(app).get('/nonexistent-route');
      assert.strictEqual(response.status, 404);
    });
  });
});
