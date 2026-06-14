import { describe, test } from 'node:test';

import assert from 'node:assert/strict';

import {
  createMockSubscription,
  getPushScenario,
  parseTRPC,
  registerPushLifecycle,
  trpcMutate,
  trpcQuery,
} from './push-test-harness.js';

interface PushResult {
  success?: boolean;
  subscriptionId?: string;
  subscriptions?: { id?: string; endpoint?: string }[];
}

registerPushLifecycle();

void describe('Push Notifications API - unsubscribe flows', { timeout: 45_000 }, () => {
  void test('push.unsubscribe removes the subscription from push status', async () => {
    const subscription = createMockSubscription('unsubscribe');

    const subscribeResponse = await trpcMutate(
      'push.subscribe',
      {
        subscription,
        groupIds: ['ciencias-3eso'],
      },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );
    assert.equal(subscribeResponse.status, 200);

    const unsubscribeResponse = await trpcMutate(
      'push.unsubscribe',
      { endpoint: subscription.endpoint },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );
    assert.equal(unsubscribeResponse.status, 200);

    const unsubscribeResult = await parseTRPC(unsubscribeResponse);
    const unsubscribeData = unsubscribeResult.data as PushResult;
    assert.equal(unsubscribeData.success, true);

    const statusResponse = await trpcQuery('push.getStatus', undefined, {
      Authorization: `Bearer ${getPushScenario().teacherToken}`,
    });
    assert.equal(statusResponse.status, 200);

    const statusResult = await parseTRPC(statusResponse);
    const statusData = statusResult.data as PushResult;
    assert.equal(
      statusData.subscriptions?.some(({ endpoint }) => endpoint === subscription.endpoint),
      false
    );
  });

  void test('push.unsubscribe cannot delete another user subscription by endpoint', async () => {
    // Admin owns a subscription.
    const adminSubscription = createMockSubscription('victim-admin-endpoint');
    const adminSubscribe = await trpcMutate(
      'push.subscribe',
      { subscription: adminSubscription, groupIds: ['*'] },
      { Authorization: `Bearer ${getPushScenario().adminToken}` }
    );
    assert.equal(adminSubscribe.status, 200);
    const adminSubId = (await parseTRPC(adminSubscribe)).data as PushResult;
    assert.ok(adminSubId.subscriptionId, 'expected admin subscription id');

    // Teacher (a different user) tries to delete the admin's subscription by endpoint.
    const attackerUnsubscribe = await trpcMutate(
      'push.unsubscribe',
      { endpoint: adminSubscription.endpoint },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );
    assert.equal(
      attackerUnsubscribe.status,
      404,
      `cross-user unsubscribe by endpoint must not succeed, got ${String(attackerUnsubscribe.status)}`
    );

    // Admin's subscription must still be present (getStatus exposes id, not endpoint).
    const adminStatus = await trpcQuery('push.getStatus', undefined, {
      Authorization: `Bearer ${getPushScenario().adminToken}`,
    });
    assert.equal(adminStatus.status, 200);
    const adminStatusData = (await parseTRPC(adminStatus)).data as PushResult;
    assert.equal(
      adminStatusData.subscriptions?.some(({ id }) => id === adminSubId.subscriptionId),
      true,
      'the victim subscription must survive a cross-user unsubscribe attempt'
    );
  });

  void test('push.unsubscribe cannot delete another user subscription by id', async () => {
    const adminSubscription = createMockSubscription('victim-admin-id');
    const adminSubscribe = await trpcMutate(
      'push.subscribe',
      { subscription: adminSubscription, groupIds: ['*'] },
      { Authorization: `Bearer ${getPushScenario().adminToken}` }
    );
    assert.equal(adminSubscribe.status, 200);
    const adminSubId = (await parseTRPC(adminSubscribe)).data as PushResult;
    assert.ok(adminSubId.subscriptionId, 'expected admin subscription id');

    const attackerUnsubscribe = await trpcMutate(
      'push.unsubscribe',
      { subscriptionId: adminSubId.subscriptionId },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );
    assert.equal(
      attackerUnsubscribe.status,
      404,
      `cross-user unsubscribe by id must not succeed, got ${String(attackerUnsubscribe.status)}`
    );

    const adminStatus = await trpcQuery('push.getStatus', undefined, {
      Authorization: `Bearer ${getPushScenario().adminToken}`,
    });
    const adminStatusData = (await parseTRPC(adminStatus)).data as PushResult;
    assert.equal(
      adminStatusData.subscriptions?.some(({ id }) => id === adminSubId.subscriptionId),
      true,
      'the victim subscription must survive a cross-user unsubscribe-by-id attempt'
    );
  });

  void test('push.unsubscribe rejects a request with neither endpoint nor subscriptionId', async () => {
    const response = await trpcMutate(
      'push.unsubscribe',
      {},
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );
    assert.equal(
      response.status,
      400,
      `unsubscribe with no endpoint and no subscriptionId must be a bad request, got ${String(response.status)}`
    );
  });
});
