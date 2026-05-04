import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import { sendPgNotification } from '../src/db/notify.js';
import * as classroomStorage from '../src/lib/classroom-storage.js';
import * as scheduleStorage from '../src/lib/schedule-storage.js';
import { createSseTestClient } from './sse-test-utils.js';
import type { SseTestHarness } from './sse-test-harness.js';
import { startSseTestHarness } from './sse-test-harness.js';

let harness: SseTestHarness | undefined;

function getHarness(): SseTestHarness {
  assert.ok(harness, 'SSE harness should be initialized');
  return harness;
}

void describe('SSE Endpoint - real-time event propagation', { timeout: 30000 }, () => {
  before(async () => {
    harness = await startSseTestHarness();
  });

  after(async () => {
    await harness?.close();
    harness = undefined;
  });

  void test('should receive whitelist-changed event when a rule is created', async () => {
    const client = createSseTestClient({
      url: `${getHarness().apiUrl}/api/machines/events`,
      headers: { Authorization: `Bearer ${getHarness().testMachineToken}` },
    });

    let createTimeoutId: ReturnType<typeof setTimeout> | undefined;

    try {
      await client.connect();
      await client.waitFor((event) => event.event === 'connected', 5000, 'connected event');

      createTimeoutId = setTimeout(() => {
        void getHarness().trpcMutate(
          'groups.createRule',
          {
            groupId: getHarness().testGroupId,
            type: 'whitelist',
            value: `sse-test-${Date.now().toString()}.com`,
          },
          { Authorization: `Bearer ${getHarness().adminToken}` }
        );
      }, 500);

      const changeEvent = (await client.waitFor(
        (event) => event.event === 'whitelist-changed',
        8000,
        'whitelist-changed event'
      )) as { event?: string; groupId?: string };

      assert.strictEqual(changeEvent.event, 'whitelist-changed');
      assert.strictEqual(changeEvent.groupId, getHarness().testGroupId);
    } finally {
      if (createTimeoutId !== undefined) {
        clearTimeout(createTimeoutId);
      }
      client.close();
    }
  });

  void test('should receive whitelist-changed event when DB NOTIFY is sent', async () => {
    const client = createSseTestClient({
      url: `${getHarness().apiUrl}/api/machines/events`,
      headers: { Authorization: `Bearer ${getHarness().testMachineToken}` },
    });

    let notifyTimeoutId: ReturnType<typeof setTimeout> | undefined;

    try {
      await client.connect();
      await client.waitFor((event) => event.event === 'connected', 5000, 'connected event');

      notifyTimeoutId = setTimeout(() => {
        void sendPgNotification('openpath_events', {
          type: 'group',
          groupId: getHarness().testGroupId,
        });
      }, 250);

      const changeEvent = (await client.waitFor(
        (event) => event.event === 'whitelist-changed',
        8000,
        'whitelist-changed event'
      )) as { event?: string; groupId?: string };

      assert.strictEqual(changeEvent.event, 'whitelist-changed');
      assert.strictEqual(changeEvent.groupId, getHarness().testGroupId);
    } finally {
      if (notifyTimeoutId !== undefined) {
        clearTimeout(notifyTimeoutId);
      }
      client.close();
    }
  });

  void test('should emit whitelist-changed on schedule boundary tick', async () => {
    const defaultGroupId = await getHarness().createGroup(
      'sse-sched-default',
      'SSE Schedule Default Group'
    );
    assert.ok(defaultGroupId, 'Expected default group ID');

    const scheduleGroupId = await getHarness().createGroup('sse-sched', 'SSE Schedule Group');
    assert.ok(scheduleGroupId, 'Expected schedule group ID');

    const scheduleMachine = await getHarness().createMachineForGroup(
      defaultGroupId,
      'sse-sched',
      'SSE Schedule Room'
    );

    const boundaryNow = new Date(2026, 1, 23, 9, 0, 0);
    const boundaryEnd = new Date(boundaryNow.getTime() + 60 * 60 * 1000);

    await scheduleStorage.createOneOffSchedule({
      classroomId: scheduleMachine.classroomId,
      teacherId: 'legacy_admin',
      groupId: scheduleGroupId,
      startAt: boundaryNow,
      endAt: boundaryEnd,
    });

    const client = createSseTestClient({
      url: `${getHarness().apiUrl}/api/machines/events`,
      headers: { Authorization: `Bearer ${scheduleMachine.token}` },
    });

    let tickTimeoutId: ReturnType<typeof setTimeout> | undefined;

    try {
      await client.connect();
      await client.waitFor((event) => event.event === 'connected', 5000, 'connected event');

      tickTimeoutId = setTimeout(() => {
        void getHarness().runScheduleBoundaryTickOnce(boundaryNow);
      }, 150);

      const changed = (await client.waitFor(
        (event) => event.event === 'whitelist-changed',
        8000,
        'whitelist-changed event (schedule tick)'
      )) as { event?: string; groupId?: string };

      assert.strictEqual(changed.event, 'whitelist-changed');
      assert.strictEqual(changed.groupId, scheduleGroupId);
    } finally {
      if (tickTimeoutId !== undefined) {
        clearTimeout(tickTimeoutId);
      }
      client.close();
    }
  });

  void test('should not broadcast classroom DB NOTIFY to other classrooms', async () => {
    const classroomADefaultGroupId = await getHarness().createGroup(
      'sse-classroom-a-default',
      'SSE Classroom A Default'
    );
    assert.ok(classroomADefaultGroupId, 'Expected classroom A default group ID');

    const overrideGroupId = await getHarness().createGroup('sse-override', 'SSE Override Group');
    assert.ok(overrideGroupId, 'Expected override group ID');

    const machineA = await getHarness().createMachineForGroup(
      classroomADefaultGroupId,
      'sse-classroom-a',
      'SSE Classroom A'
    );

    const machineB = await getHarness().createMachineForGroup(
      overrideGroupId,
      'sse-classroom-b',
      'SSE Classroom B'
    );

    const clientA = createSseTestClient({
      url: `${getHarness().apiUrl}/api/machines/events`,
      headers: { Authorization: `Bearer ${machineA.token}` },
    });
    const clientB = createSseTestClient({
      url: `${getHarness().apiUrl}/api/machines/events`,
      headers: { Authorization: `Bearer ${machineB.token}` },
    });

    let notifyTimeoutId: ReturnType<typeof setTimeout> | undefined;

    try {
      await Promise.all([clientA.connect(), clientB.connect()]);

      await Promise.all([
        clientA.waitFor((event) => event.event === 'connected', 5000, 'connected event (A)'),
        clientB.waitFor((event) => event.event === 'connected', 5000, 'connected event (B)'),
      ]);

      notifyTimeoutId = setTimeout(() => {
        void (async (): Promise<void> => {
          await classroomStorage.setActiveGroup(machineA.classroomId, overrideGroupId);
          await sendPgNotification('openpath_events', {
            type: 'classroom',
            classroomId: machineA.classroomId,
          });
        })();
      }, 250);

      const gotAPromise = clientA.waitFor(
        (event) => event.event === 'whitelist-changed',
        3000,
        'whitelist-changed for classroom A'
      );
      const gotBPromise = clientB.waitFor(
        (event) => event.event === 'whitelist-changed',
        1500,
        'whitelist-changed for classroom B (should not receive)'
      );

      const parsedA = (await gotAPromise) as { event?: string; groupId?: string };
      assert.strictEqual(parsedA.event, 'whitelist-changed');
      assert.strictEqual(parsedA.groupId, overrideGroupId);

      await assert.rejects(gotBPromise, /should not receive/);
    } finally {
      if (notifyTimeoutId !== undefined) {
        clearTimeout(notifyTimeoutId);
      }
      clientA.close();
      clientB.close();
    }
  });
});
