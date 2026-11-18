import type { Notification, PoolClient } from 'pg';
import { getErrorMessage } from '@openpath/shared';
import { listenToPgChannel, sendPgNotification, stopListeningToPgChannel } from '../db/notify.js';
import { logger } from './logger.js';

export type DbEventPayload =
  | { type: 'group'; groupId: string; origin?: string }
  | { type: 'classroom'; classroomId: string; origin?: string }
  | { type: 'agent-update'; build: string; origin?: string }
  | { type: 'broadcast'; origin?: string };

export interface DbEventBridge {
  ensureStarted: () => Promise<void>;
  stop: () => Promise<void>;
  notify: (event: DbEventPayload) => Promise<void>;
}

function resolveDbEventChannel(): string {
  const raw = process.env.OPENPATH_DB_EVENTS_CHANNEL ?? 'openpath_events';
  return /^[a-zA-Z0-9_]+$/.test(raw) ? raw : 'openpath_events';
}

export function createDbEventBridge(params: {
  instanceId: string;
  onEvent: (event: DbEventPayload) => void;
}): DbEventBridge {
  const channel = resolveDbEventChannel();

  let client: PoolClient | null = null;
  let startPromise: Promise<void> | null = null;

  async function notify(event: DbEventPayload): Promise<void> {
    try {
      await sendPgNotification(channel, event);
    } catch (error: unknown) {
      logger.warn('Failed to NOTIFY DB event channel', {
        channel,
        error: getErrorMessage(error),
      });
    }
  }

  function handleNotificationPayload(payload: string | null): void {
    if (!payload) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(payload);
    } catch {
      return;
    }

    const evt = parsed as Partial<DbEventPayload>;

    if (evt.origin && evt.origin === params.instanceId) {
      return;
    }

    if (evt.type === 'group' && typeof evt.groupId === 'string' && evt.groupId.length > 0) {
      const origin = evt.origin;
      params.onEvent(
        origin
          ? { type: 'group', groupId: evt.groupId, origin }
          : { type: 'group', groupId: evt.groupId }
      );
      return;
    }

    if (
      evt.type === 'classroom' &&
      typeof evt.classroomId === 'string' &&
      evt.classroomId.length > 0
    ) {
      const origin = evt.origin;
      params.onEvent(
        origin
          ? { type: 'classroom', classroomId: evt.classroomId, origin }
          : { type: 'classroom', classroomId: evt.classroomId }
      );
      return;
    }

    if (evt.type === 'broadcast') {
      const origin = evt.origin;
      params.onEvent(origin ? { type: 'broadcast', origin } : { type: 'broadcast' });
      return;
    }

    if (evt.type === 'agent-update' && typeof evt.build === 'string' && evt.build.length > 0) {
      const origin = evt.origin;
      params.onEvent(
        origin
          ? { type: 'agent-update', build: evt.build, origin }
          : { type: 'agent-update', build: evt.build }
      );
    }
  }

  async function ensureStarted(): Promise<void> {
    if (client) return;
    if (startPromise) {
      await startPromise;
      return;
    }

    startPromise = (async (): Promise<void> => {
      try {
        const c = await listenToPgChannel({
          channel,
          onNotification: (msg: Notification) => {
            handleNotificationPayload(msg.payload ?? null);
          },
          onError: (err: unknown) => {
            logger.warn('DB event bridge client error', {
              error: err instanceof Error ? err.message : String(err),
            });
          },
        });
        client = c;
        logger.info('DB event bridge listening', { channel });
      } catch (error: unknown) {
        logger.warn('Failed to start DB event bridge', { error: getErrorMessage(error) });
        try {
          client?.release();
        } catch {
          // ignore
        }
        client = null;
        startPromise = null;
      }
    })();

    await startPromise;
  }

  async function stop(): Promise<void> {
    const c = client;
    if (!c) return;

    client = null;
    startPromise = null;

    try {
      await stopListeningToPgChannel({ channel, client: c });
    } catch {
      // ignore
    }
  }

  return {
    ensureStarted,
    stop,
    notify,
  };
}
