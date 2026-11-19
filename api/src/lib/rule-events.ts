import { randomUUID } from 'node:crypto';
import { getErrorMessage } from '@openpath/shared';
import { listAgentRingHostnames } from '../services/agent-release.service.js';
import { createDbEventBridge, type DbEventPayload } from './db-event-bridge.js';
import { resolveEffectiveClassroomPolicyContext } from './classroom-storage.js';
import { getActiveExemptHostnamesByClassroom, UNRESTRICTED_GROUP_ID } from './exemption-storage.js';
import { touchGroupUpdatedAt } from './groups-storage.js';
import { logger } from './logger.js';
import { createScheduleBoundaryTicker } from './schedule-boundary-ticker.js';
import { createSseHub, type SseStream } from './sse-hub.js';

const INSTANCE_ID = randomUUID();

const sseHub = createSseHub({
  resolveClassroomGroupContext: resolveEffectiveClassroomPolicyContext,
  resolveExemptHostnamesByClassroom: getActiveExemptHostnamesByClassroom,
  unrestrictedGroupId: UNRESTRICTED_GROUP_ID,
});

const dbBridge = createDbEventBridge({
  instanceId: INSTANCE_ID,
  onEvent: (event: DbEventPayload) => {
    if (event.type === 'group') {
      sseHub.publishGroupChangedLocal(event.groupId);
      return;
    }

    if (event.type === 'classroom') {
      void sseHub.publishClassroomChangedLocal(event.classroomId);
      return;
    }

    if (event.type === 'agent-update') {
      void publishAgentUpdateAvailableLocal(event.hostnames, event.build);
      return;
    }

    sseHub.publishBroadcastLocal();
  },
});

const scheduleTicker = createScheduleBoundaryTicker({
  emitClassroomChanged: (classroomId: string, now: Date) => {
    emitClassroomChanged(classroomId, now);
  },
});

export { type SseStream };

export function registerSseClient(params: {
  hostname: string;
  classroomId: string;
  groupId: string;
  stream: SseStream;
}): () => void {
  return sseHub.registerSseClient(params);
}

export function getSseClientCount(): number {
  return sseHub.getSseClientCount();
}

export async function ensureDbEventBridgeStarted(): Promise<void> {
  await dbBridge.ensureStarted();
}

export async function stopDbEventBridge(): Promise<void> {
  await dbBridge.stop();
}

export async function runScheduleBoundaryTickOnce(now: Date = new Date()): Promise<void> {
  await scheduleTicker.runTickOnce(now);
}

export async function ensureScheduleBoundaryTickerStarted(): Promise<void> {
  await scheduleTicker.ensureStarted();
}

export async function stopScheduleBoundaryTicker(): Promise<void> {
  await scheduleTicker.stop();
}

/**
 * Emit a whitelist-changed event for a specific group.
 * Called after any rule mutation (create, update, delete, bulk operations).
 *
 * @param groupId - The group whose whitelist changed
 */
export function emitWhitelistChanged(groupId: string): void {
  logger.debug('Emitting whitelist-changed event', { groupId });
  sseHub.publishGroupChangedLocal(groupId);
  void dbBridge.notify({ type: 'group', groupId, origin: INSTANCE_ID });
}

export async function touchGroupAndEmitWhitelistChanged(groupId: string): Promise<void> {
  await touchGroupUpdatedAt(groupId);
  emitWhitelistChanged(groupId);
}

/**
 * Emit a classroom context-changed event.
 * Used when schedules or active-group overrides can change the effective group.
 */
export function emitClassroomChanged(classroomId: string, now?: Date): void {
  logger.debug('Emitting classroom-changed event', { classroomId });
  void sseHub.publishClassroomChangedLocal(classroomId, now ?? new Date());
  void dbBridge.notify({ type: 'classroom', classroomId, origin: INSTANCE_ID });
}

/**
 * Delivers agent-update-available to the local SSE clients. Without explicit
 * hostnames the targets are the machines on the canary ring right now, read
 * from the database at emit time, so a ring change needs no reconnect.
 */
async function publishAgentUpdateAvailableLocal(
  hostnames: readonly string[] | undefined,
  build: string | undefined
): Promise<void> {
  try {
    const targets = hostnames ?? (await listAgentRingHostnames('canary'));
    sseHub.publishAgentUpdateAvailableLocal(
      new Set(targets.map((hostname) => hostname.trim().toLowerCase()).filter(Boolean)),
      build
    );
  } catch (error: unknown) {
    logger.warn('Failed to deliver agent-update-available', { error: getErrorMessage(error) });
  }
}

/**
 * Emit an agent-update-available event so machines check their agent release now.
 * Called after a signed canary release is published or retired (targets: the
 * canary ring at emit time) and after a machine's ring changes (targets: that
 * machine), so a machine returning to stable does not wait for a scheduled task.
 */
export async function emitAgentUpdateAvailable(
  params: { build?: string; hostnames?: readonly string[] } = {}
): Promise<void> {
  const hostnames = params.hostnames
    ? params.hostnames.map((hostname) => hostname.trim().toLowerCase()).filter(Boolean)
    : undefined;
  logger.debug('Emitting agent-update-available event', {
    build: params.build,
    targets: hostnames ? hostnames.length : 'canary-ring',
  });
  await publishAgentUpdateAvailableLocal(hostnames, params.build);
  await dbBridge.notify({
    type: 'agent-update',
    ...(params.build ? { build: params.build } : {}),
    ...(hostnames ? { hostnames } : {}),
    origin: INSTANCE_ID,
  });
}

/**
 * Emit whitelist-changed events for all groups.
 * Used when toggling the system status (enable/disable all groups).
 */
export function emitAllWhitelistsChanged(): void {
  logger.debug('Emitting whitelist-changed event for all groups');
  sseHub.publishBroadcastLocal();
  void dbBridge.notify({ type: 'broadcast', origin: INSTANCE_ID });
}

/**
 * Backwards-compatible diagnostic: active SSE client count.
 */
export function getListenerCount(): number {
  return getSseClientCount();
}
