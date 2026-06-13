import { describe, test } from 'node:test';

import assert from 'node:assert/strict';

import {
  createMockSubscription,
  getPushScenario,
  parseTRPC,
  registerPushLifecycle,
  trpcMutate,
} from './push-test-harness.js';

interface PushResult {
  groupIds?: string[];
  subscriptionId?: string;
}

registerPushLifecycle();

void describe('Push Notifications API - subscription flows', { timeout: 45_000 }, () => {
  void test('push.subscribe stores a teacher subscription for assigned groups', async () => {
    const response = await trpcMutate(
      'push.subscribe',
      {
        subscription: createMockSubscription('teacher-subscribe'),
        groupIds: ['ciencias-3eso', 'fisica-4eso'],
      },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );

    assert.equal(response.status, 200);

    const result = await parseTRPC(response);
    const data = result.data as PushResult;

    assert.ok(data.subscriptionId);
    assert.equal(data.groupIds?.includes('ciencias-3eso'), true);
  });

  void test('push.subscribe rejects unknown groups', async () => {
    const response = await trpcMutate(
      'push.subscribe',
      {
        subscription: createMockSubscription('invalid-group'),
        groupIds: ['missing-group-id'],
      },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );

    assert.equal(response.status, 400);
  });

  void test('push.subscribe does not let a teacher subscribe to a non-assigned group', async () => {
    // The teacher is assigned only to ciencias-3eso. fisica-4eso is a real group
    // they do NOT belong to; requesting it must not result in a subscription to it.
    const response = await trpcMutate(
      'push.subscribe',
      {
        subscription: createMockSubscription('idor-foreign-group'),
        groupIds: ['fisica-4eso'],
      },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );

    // Either rejected outright, or the foreign group is filtered out of the result.
    if (response.status === 200) {
      const result = await parseTRPC(response);
      const data = result.data as PushResult;
      assert.equal(
        data.groupIds?.includes('fisica-4eso'),
        false,
        'a teacher must not be subscribed to a group they do not belong to'
      );
    } else {
      assert.ok(
        response.status >= 400,
        `expected filtering or rejection, got ${String(response.status)}`
      );
    }
  });

  void test('push.subscribe intersects requested groups with the teacher assignments', async () => {
    // Mix of an assigned group (kept) and a non-assigned group (dropped).
    const response = await trpcMutate(
      'push.subscribe',
      {
        subscription: createMockSubscription('idor-mixed-groups'),
        groupIds: ['ciencias-3eso', 'fisica-4eso'],
      },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );

    assert.equal(response.status, 200);
    const result = await parseTRPC(response);
    const data = result.data as PushResult;
    const storedGroups = data.groupIds ?? [];
    assert.equal(storedGroups.includes('ciencias-3eso'), true, 'assigned group should be kept');
    assert.equal(storedGroups.includes('fisica-4eso'), false, 'non-assigned group must be dropped');
  });

  void test('push.subscribe rejects when all requested groups are non-assigned', async () => {
    const response = await trpcMutate(
      'push.subscribe',
      {
        subscription: createMockSubscription('idor-all-foreign'),
        // '*' is admin-only; a teacher requesting only it has nothing to subscribe to.
        groupIds: ['*'],
      },
      { Authorization: `Bearer ${getPushScenario().teacherToken}` }
    );

    if (response.status === 200) {
      const result = await parseTRPC(response);
      const data = result.data as PushResult;
      assert.equal(
        data.groupIds?.includes('*'),
        false,
        'a non-admin must not get a wildcard subscription'
      );
    } else {
      assert.ok(
        response.status >= 400,
        `expected rejection for non-admin wildcard, got ${String(response.status)}`
      );
    }
  });
});
