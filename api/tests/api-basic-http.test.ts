import { describe, test } from 'node:test';
import assert from 'node:assert';

import { getApiUrl, registerRequestApiLifecycle } from './request-api-test-harness.js';

registerRequestApiLifecycle();

void describe('Request API tests - basic HTTP behavior', async () => {
  await describe('Health Check', async () => {
    await test('GET /health should return 200 OK', async () => {
      const response = await fetch(`${getApiUrl()}/health`);
      assert.strictEqual(response.status, 200);

      const data = (await response.json()) as { service: string; status: string };
      assert.strictEqual(data.status, 'ok');
      assert.strictEqual(data.service, 'openpath-api');
    });
  });

  await describe('CORS Headers', async () => {
    await test('should include CORS headers', async () => {
      const response = await fetch(`${getApiUrl()}/health`, {
        headers: { Origin: 'http://localhost:3000' },
      });
      const corsHeader = response.headers.get('access-control-allow-origin');
      assert.ok(corsHeader !== null && corsHeader !== '');
    });

    await test('allows browser extension origins to submit public domain requests', async () => {
      const origin = 'moz-extension://f8b7c6d5-1111-4222-8333-444455556666';
      const response = await fetch(`${getApiUrl()}/api/requests/submit`, {
        method: 'OPTIONS',
        headers: {
          Origin: origin,
          'Access-Control-Request-Method': 'POST',
          'Access-Control-Request-Headers': 'content-type',
        },
      });

      assert.strictEqual(response.status, 204);
      assert.strictEqual(response.headers.get('access-control-allow-origin'), origin);
    });

    await test('does not allow browser extension origins on unrelated routes', async () => {
      const response = await fetch(`${getApiUrl()}/health`, {
        headers: { Origin: 'moz-extension://f8b7c6d5-1111-4222-8333-444455556666' },
      });

      assert.strictEqual(response.headers.get('access-control-allow-origin'), null);
    });
  });

  await describe('Error Handling', async () => {
    await test('should return 404 for blocked /v2 routes', async () => {
      const response = await fetch(`${getApiUrl()}/v2`);
      assert.strictEqual(response.status, 404);
    });

    await test('should return SPA for client-side routes', async () => {
      const response = await fetch(`${getApiUrl()}/unknown-route`);
      if (response.status === 200) {
        const text = await response.text();
        assert.ok(text.includes('<!DOCTYPE html>') || text.includes('<html'));
        return;
      }

      assert.strictEqual(response.status, 404);
    });

    await test('should handle malformed JSON', async () => {
      const response = await fetch(`${getApiUrl()}/trpc/requests.create`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: 'invalid json{{',
      });

      assert.ok(response.status >= 400);
    });
  });
});
