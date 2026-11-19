import * as classroomStorage from '../lib/classroom-storage.js';
import { logger } from '../lib/logger.js';
import {
  ensureDbEventBridgeStarted,
  ensureScheduleBoundaryTickerStarted,
  getSseClientCount,
  registerSseClient,
  type SseStream,
} from '../lib/rule-events.js';
import {
  resolveMachineEventsAccess,
  type MachinePolicyResult,
  type MachinePolicyServiceError,
} from './machine-policy.service.js';

export type MachineEventsServiceError = MachinePolicyServiceError;
export type MachineEventsServiceResult<T> = MachinePolicyResult<T>;

export interface MachineEventsResponseStream extends SseStream {
  writeHead: (statusCode: number, headers: Record<string, string>) => void;
}

export interface OpenMachineEventsStreamInput {
  authorizationHeader?: string | undefined;
  queryToken?: string | undefined;
  stream: MachineEventsResponseStream;
}

export interface OpenMachineEventsStreamOutput {
  disconnect: () => void;
}

export async function openMachineEventsStream(
  input: OpenMachineEventsStreamInput
): Promise<MachineEventsServiceResult<OpenMachineEventsStreamOutput>> {
  const access = await resolveMachineEventsAccess({
    authorizationHeader: input.authorizationHeader,
    queryToken: input.queryToken,
  });
  if (!access.ok) {
    return access;
  }

  const { machine, classroomId, groupId } = access.data;

  await ensureDbEventBridgeStarted();
  void ensureScheduleBoundaryTickerStarted();

  input.stream.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });

  input.stream.write(
    `data: ${JSON.stringify({
      event: 'connected',
      groupId,
      hostname: machine.hostname,
    })}\n\n`
  );

  const unsubscribe = registerSseClient({
    hostname: machine.hostname,
    classroomId,
    groupId,
    stream: input.stream,
  });

  logger.info('SSE client connected', {
    hostname: machine.hostname,
    classroomId,
    groupId,
    clients: getSseClientCount(),
  });

  await classroomStorage.updateMachineLastSeen(machine.hostname);

  return {
    ok: true,
    data: {
      disconnect: (): void => {
        unsubscribe();
        logger.info('SSE client disconnected', {
          hostname: machine.hostname,
          classroomId,
          groupId,
          clients: getSseClientCount(),
        });
      },
    },
  };
}

export default {
  openMachineEventsStream,
};
