import { describe, test } from 'node:test';

import assert from 'node:assert/strict';

import { parseTRPC, registerPushLifecycle, trpcQuery } from './push-test-harness.js';

interface VapidResult {
  publicKey?: string;
}

registerPushLifecycle();

void describe('Push Notifications API - VAPID', { timeout: 45_000 }, () => {
  void test('push.getVapidPublicKey returns the configured key', async () => {
    const response = await trpcQuery('push.getVapidPublicKey');

    assert.equal(response.status, 200);

    const result = await parseTRPC(response);
    const data = result.data as VapidResult;

    assert.equal(typeof data.publicKey, 'string');
    assert.ok(data.publicKey);
  });

  void test('push.getVapidKey returns the configured key (alias)', async () => {
    const response = await trpcQuery('push.getVapidKey');

    assert.equal(response.status, 200);

    const result = await parseTRPC(response);
    const data = result.data as VapidResult;

    assert.equal(typeof data.publicKey, 'string');
    assert.ok(data.publicKey);
  });
});
