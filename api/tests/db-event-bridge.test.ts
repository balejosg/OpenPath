import { describe, test, after, mock } from 'node:test';
import assert from 'node:assert';
import { sendPgNotification } from '../src/db/notify.js';
import { pool } from '../src/db/pool.js';
import { createDbEventBridge, type DbEventPayload } from '../src/lib/db-event-bridge.js';
import { TEST_RUN_ID } from './test-utils.js';

function sanitizeChannel(raw: string): string {
  return raw.replace(/[^a-zA-Z0-9_]/g, '_');
}

await describe('DB Event Bridge', async () => {
  const previous = process.env.OPENPATH_DB_EVENTS_CHANNEL;
  const channel = sanitizeChannel(`openpath_events_${TEST_RUN_ID}`);
  process.env.OPENPATH_DB_EVENTS_CHANNEL = channel;

  after(() => {
    process.env.OPENPATH_DB_EVENTS_CHANNEL = previous;
  });

  await test('delivers LISTEN/NOTIFY payloads to handler and ignores same-origin', async () => {
    const events: DbEventPayload[] = [];
    const bridge = createDbEventBridge({
      instanceId: 'instance-a',
      onEvent: (evt) => {
        events.push(evt);
      },
    });

    await bridge.ensureStarted();

    const gotEvent = new Promise<void>((resolve, reject) => {
      const interval = setInterval(() => {
        const hit = events.find((e) => e.type === 'group' && e.groupId === 'g1');
        if (!hit) return;
        clearInterval(interval);
        clearTimeout(timeout);
        resolve();
      }, 25);
      interval.unref();

      const timeout = setTimeout(() => {
        clearInterval(interval);
        reject(new Error('Timed out waiting for DB event'));
      }, 4000);
    });

    await sendPgNotification(channel, { type: 'group', groupId: 'g1', origin: 'instance-b' });
    await sendPgNotification(channel, { type: 'group', groupId: 'ignored', origin: 'instance-a' });

    await gotEvent;

    assert.ok(events.some((e) => e.type === 'group' && e.groupId === 'g1'));
    assert.ok(!events.some((e) => e.type === 'group' && e.groupId === 'ignored'));

    await bridge.stop();
  });

  await test('notify contains serialization failures instead of rejecting', async () => {
    const events: DbEventPayload[] = [];
    const bridge = createDbEventBridge({
      instanceId: 'instance-a',
      onEvent: (evt) => {
        events.push(evt);
      },
    });
    const circular: Record<string, unknown> = {};
    circular.self = circular;

    await bridge.notify(circular as unknown as DbEventPayload);

    assert.deepEqual(events, []);
  });

  await test('concurrent ensureStarted calls share one listening client', async () => {
    const bridge = createDbEventBridge({
      instanceId: 'instance-a',
      onEvent: () => undefined,
    });

    await Promise.all([bridge.ensureStarted(), bridge.ensureStarted()]);
    await bridge.stop();
  });

  await test('ensureStarted contains connection failures and retries after them', async () => {
    const connect = mock.method(pool, 'connect', () =>
      Promise.reject(new Error('connect refused'))
    );
    const bridge = createDbEventBridge({
      instanceId: 'instance-a',
      onEvent: () => undefined,
    });

    await bridge.ensureStarted();

    connect.mock.restore();

    await bridge.ensureStarted();
    await bridge.stop();
  });
});
