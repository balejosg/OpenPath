import { describe, test } from 'node:test';
import assert from 'node:assert';
import { createSseHub } from '../src/lib/sse-hub.js';
import { CANONICAL_GROUP_IDS } from './fixtures.js';
import { firstSseDataPayload } from './sse-test-utils.js';

await describe('SSE Hub', async () => {
  await test('publishGroupChangedLocal targets only matching group', () => {
    const writesA: string[] = [];
    const writesB: string[] = [];

    const hub = createSseHub({
      resolveClassroomGroupContext: () => Promise.resolve(null),
    });

    const unsubA = hub.registerSseClient({
      hostname: 'host-a',
      classroomId: 'room-a',
      groupId: CANONICAL_GROUP_IDS.groupA,
      stream: {
        write: (chunk: string) => {
          writesA.push(chunk);
          return true;
        },
      },
    });

    const unsubB = hub.registerSseClient({
      hostname: 'host-b',
      classroomId: 'room-b',
      groupId: CANONICAL_GROUP_IDS.groupB,
      stream: {
        write: (chunk: string) => {
          writesB.push(chunk);
          return true;
        },
      },
    });

    hub.publishGroupChangedLocal(CANONICAL_GROUP_IDS.groupA);

    assert.ok(writesA.length > 0);
    assert.strictEqual(writesB.length, 0);

    const parsed = JSON.parse(firstSseDataPayload(writesA)) as { event?: string; groupId?: string };
    assert.strictEqual(parsed.event, 'whitelist-changed');
    assert.strictEqual(parsed.groupId, CANONICAL_GROUP_IDS.groupA);

    unsubA();
    unsubB();
  });

  await test('publishClassroomChangedLocal updates group index and emits new groupId', async () => {
    const writes: string[] = [];
    const hub = createSseHub({
      resolveClassroomGroupContext: () =>
        Promise.resolve({ mode: 'grouped', groupId: 'new-group' }),
    });

    const unsub = hub.registerSseClient({
      hostname: 'host-c',
      classroomId: 'room-c',
      groupId: 'old-group',
      stream: {
        write: (chunk: string) => {
          writes.push(chunk);
          return true;
        },
      },
    });

    await hub.publishClassroomChangedLocal('room-c', new Date(2026, 1, 23, 9, 0, 0));

    const change = JSON.parse(firstSseDataPayload(writes)) as { event?: string; groupId?: string };
    assert.strictEqual(change.event, 'whitelist-changed');
    assert.strictEqual(change.groupId, 'new-group');

    writes.length = 0;
    hub.publishGroupChangedLocal('new-group');
    assert.ok(writes.join('').includes('"new-group"'));

    unsub();
  });

  await test('publishClassroomChangedLocal assigns unrestricted group for exempt hostnames', async () => {
    const writesA: string[] = [];
    const writesB: string[] = [];

    const hub = createSseHub({
      resolveClassroomGroupContext: () =>
        Promise.resolve({ mode: 'grouped', groupId: 'base-group' }),
      resolveExemptHostnamesByClassroom: () => Promise.resolve(new Set(['host-a'])),
      unrestrictedGroupId: '__unrestricted__',
    });

    const unsubA = hub.registerSseClient({
      hostname: 'host-a',
      classroomId: 'room-1',
      groupId: 'base-group',
      stream: {
        write: (chunk: string) => {
          writesA.push(chunk);
          return true;
        },
      },
    });

    const unsubB = hub.registerSseClient({
      hostname: 'host-b',
      classroomId: 'room-1',
      groupId: 'base-group',
      stream: {
        write: (chunk: string) => {
          writesB.push(chunk);
          return true;
        },
      },
    });

    await hub.publishClassroomChangedLocal('room-1', new Date(2026, 1, 23, 9, 0, 0));

    const change = JSON.parse(firstSseDataPayload(writesA)) as { event?: string; groupId?: string };
    assert.strictEqual(change.event, 'whitelist-changed');
    assert.strictEqual(change.groupId, '__unrestricted__');

    assert.strictEqual(writesB.length, 0);

    writesA.length = 0;
    hub.publishGroupChangedLocal('__unrestricted__');
    assert.ok(writesA.join('').includes('"__unrestricted__"'));

    unsubA();
    unsubB();
  });

  await test('publishAgentUpdateAvailableLocal targets only canary-ring clients', () => {
    const writesCanary: string[] = [];
    const writesStable: string[] = [];

    const hub = createSseHub({
      resolveClassroomGroupContext: () => Promise.resolve(null),
    });

    const unsubCanary = hub.registerSseClient({
      hostname: 'host-canary',
      classroomId: 'room-a',
      groupId: CANONICAL_GROUP_IDS.groupA,
      agentRing: 'canary',
      stream: {
        write: (chunk: string) => {
          writesCanary.push(chunk);
          return true;
        },
      },
    });

    const unsubStable = hub.registerSseClient({
      hostname: 'host-stable',
      classroomId: 'room-b',
      groupId: CANONICAL_GROUP_IDS.groupB,
      stream: {
        write: (chunk: string) => {
          writesStable.push(chunk);
          return true;
        },
      },
    });

    hub.publishAgentUpdateAvailableLocal('a'.repeat(64));

    assert.ok(writesCanary.length > 0);
    assert.strictEqual(writesStable.length, 0);

    const parsed = JSON.parse(firstSseDataPayload(writesCanary)) as {
      event?: string;
      ring?: string;
      build?: string;
    };
    assert.strictEqual(parsed.event, 'agent-update-available');
    assert.strictEqual(parsed.ring, 'canary');
    assert.strictEqual(parsed.build, 'a'.repeat(64));

    unsubCanary();
    unsubStable();
  });
});
