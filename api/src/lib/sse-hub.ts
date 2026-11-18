import { randomUUID } from 'node:crypto';
import { serializePolicyGroupId } from './classroom-storage.js';

export interface SseStream {
  write: (chunk: string) => boolean;
}

interface ClassroomPolicyContextLike {
  mode: 'grouped' | 'unrestricted';
  groupId: string | null;
}

export type ClassroomGroupContextResolver = (
  classroomId: string,
  now: Date
) => Promise<ClassroomPolicyContextLike | null>;

export type ClassroomExemptHostnamesResolver = (
  classroomId: string,
  now: Date
) => Promise<ReadonlySet<string>>;

interface SseClient {
  id: string;
  hostname: string;
  classroomId: string;
  groupId: string;
  agentRing: 'stable' | 'canary';
  stream: SseStream;
  lastWriteAt: number;
}

const KEEP_ALIVE_INTERVAL_MS = 30_000;
const KEEP_ALIVE_IDLE_MS = 25_000;

export interface SseHub {
  registerSseClient: (params: {
    hostname: string;
    classroomId: string;
    groupId: string;
    agentRing?: 'stable' | 'canary';
    stream: SseStream;
  }) => () => void;
  getSseClientCount: () => number;
  publishGroupChangedLocal: (groupId: string) => void;
  publishBroadcastLocal: () => void;
  publishAgentUpdateAvailableLocal: (build: string) => void;
  publishClassroomChangedLocal: (classroomId: string, now?: Date) => Promise<void>;
}

export function createSseHub(params: {
  resolveClassroomGroupContext: ClassroomGroupContextResolver;
  resolveExemptHostnamesByClassroom?: ClassroomExemptHostnamesResolver;
  unrestrictedGroupId?: string;
}): SseHub {
  const clientsById = new Map<string, SseClient>();
  const clientIdsByGroupId = new Map<string, Set<string>>();
  const clientIdsByClassroomId = new Map<string, Set<string>>();

  let keepAliveTimer: NodeJS.Timeout | null = null;

  function indexAdd(index: Map<string, Set<string>>, key: string, id: string): void {
    const set = index.get(key);
    if (set) {
      set.add(id);
      return;
    }
    index.set(key, new Set([id]));
  }

  function indexRemove(index: Map<string, Set<string>>, key: string, id: string): void {
    const set = index.get(key);
    if (!set) return;
    set.delete(id);
    if (set.size === 0) {
      index.delete(key);
    }
  }

  function stopKeepAliveIfIdle(): void {
    if (clientsById.size > 0) return;
    if (!keepAliveTimer) return;
    clearInterval(keepAliveTimer);
    keepAliveTimer = null;
  }

  function removeSseClient(id: string): void {
    const client = clientsById.get(id);
    if (!client) return;

    clientsById.delete(id);
    indexRemove(clientIdsByGroupId, client.groupId, id);
    indexRemove(clientIdsByClassroomId, client.classroomId, id);

    stopKeepAliveIfIdle();
  }

  function ensureKeepAliveRunning(): void {
    if (keepAliveTimer) return;

    keepAliveTimer = setInterval(() => {
      const now = Date.now();
      for (const client of clientsById.values()) {
        if (now - client.lastWriteAt < KEEP_ALIVE_IDLE_MS) continue;
        try {
          client.stream.write(': keep-alive\n\n');
          client.lastWriteAt = now;
        } catch {
          removeSseClient(client.id);
        }
      }
    }, KEEP_ALIVE_INTERVAL_MS);

    keepAliveTimer.unref();
  }

  function tryWrite(client: SseClient, payload: string): void {
    try {
      client.stream.write(payload);
      client.lastWriteAt = Date.now();
    } catch {
      removeSseClient(client.id);
    }
  }

  function registerSseClient(params2: {
    hostname: string;
    classroomId: string;
    groupId: string;
    agentRing?: 'stable' | 'canary';
    stream: SseStream;
  }): () => void {
    const id = randomUUID();
    const client: SseClient = {
      id,
      hostname: params2.hostname,
      classroomId: params2.classroomId,
      groupId: params2.groupId,
      agentRing: params2.agentRing === 'canary' ? 'canary' : 'stable',
      stream: params2.stream,
      lastWriteAt: Date.now(),
    };

    clientsById.set(id, client);
    indexAdd(clientIdsByGroupId, client.groupId, id);
    indexAdd(clientIdsByClassroomId, client.classroomId, id);

    ensureKeepAliveRunning();

    return () => {
      removeSseClient(id);
    };
  }

  function getSseClientCount(): number {
    return clientsById.size;
  }

  function publishGroupChangedLocal(groupId: string): void {
    const ids = clientIdsByGroupId.get(groupId);
    if (!ids || ids.size === 0) return;

    const payload = `data: ${JSON.stringify({ event: 'whitelist-changed', groupId })}\n\n`;
    for (const id of Array.from(ids)) {
      const client = clientsById.get(id);
      if (!client) continue;
      tryWrite(client, payload);
    }
  }

  function publishBroadcastLocal(): void {
    for (const client of clientsById.values()) {
      const payload = `data: ${JSON.stringify({
        event: 'whitelist-changed',
        groupId: client.groupId,
      })}\n\n`;
      tryWrite(client, payload);
    }
  }

  function publishAgentUpdateAvailableLocal(build: string): void {
    const payload = `data: ${JSON.stringify({
      event: 'agent-update-available',
      ring: 'canary',
      build,
    })}\n\n`;
    for (const client of clientsById.values()) {
      if (client.agentRing !== 'canary') continue;
      tryWrite(client, payload);
    }
  }

  async function publishClassroomChangedLocal(
    classroomId: string,
    now: Date = new Date()
  ): Promise<void> {
    const ids = clientIdsByClassroomId.get(classroomId);
    if (!ids || ids.size === 0) return;

    const baseContext = await params.resolveClassroomGroupContext(classroomId, now);
    const exemptHostnames = params.resolveExemptHostnamesByClassroom
      ? await params.resolveExemptHostnamesByClassroom(classroomId, now)
      : null;

    if (!baseContext && (!exemptHostnames || exemptHostnames.size === 0)) return;

    const unrestrictedGroupId = params.unrestrictedGroupId ?? '__unrestricted__';
    const baseGroupId = baseContext ? serializePolicyGroupId(baseContext) : null;

    for (const id of Array.from(ids)) {
      const client = clientsById.get(id);
      if (!client) continue;

      const isExempt = exemptHostnames ? exemptHostnames.has(client.hostname) : false;
      const nextGroupId = isExempt ? unrestrictedGroupId : baseGroupId;
      if (!nextGroupId) continue;

      if (client.groupId === nextGroupId) continue;

      indexRemove(clientIdsByGroupId, client.groupId, id);
      client.groupId = nextGroupId;
      indexAdd(clientIdsByGroupId, client.groupId, id);

      const payload = `data: ${JSON.stringify({
        event: 'whitelist-changed',
        groupId: client.groupId,
      })}\n\n`;
      tryWrite(client, payload);
    }
  }

  return {
    registerSseClient,
    getSseClientCount,
    publishGroupChangedLocal,
    publishBroadcastLocal,
    publishAgentUpdateAvailableLocal,
    publishClassroomChangedLocal,
  };
}
