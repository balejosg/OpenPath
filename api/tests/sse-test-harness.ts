import assert from 'node:assert';

import type { HttpTestHarness } from './http-test-harness.js';
import { TEST_RUN_ID, assertStatus, bearerAuth, parseTRPC } from './test-utils.js';
import { startHttpTestHarness } from './http-test-harness.js';
import {
  runScheduleBoundaryTickOnce,
  stopDbEventBridge,
  stopScheduleBoundaryTicker,
} from '../src/lib/rule-events.js';
import { generateMachineToken, hashMachineToken } from '../src/lib/machine-download-token.js';
import * as classroomStorage from '../src/lib/classroom-storage.js';

export interface SseMachine {
  classroomId: string;
  hostname: string;
  id: string;
  token: string;
}

export interface SseTestHarness extends HttpTestHarness {
  adminToken: string;
  createGroup: (prefix: string, displayName: string) => Promise<string>;
  createMachineForGroup: (
    groupId: string,
    prefix: string,
    displayName: string
  ) => Promise<SseMachine>;
  runScheduleBoundaryTickOnce: typeof runScheduleBoundaryTickOnce;
  testGroupId: string;
  testMachineToken: string;
}

export async function startSseTestHarness(
  extraEnv: Record<string, string | undefined> = {}
): Promise<SseTestHarness> {
  const harness = await startHttpTestHarness({
    cleanup: async () => {
      await stopDbEventBridge();
      await stopScheduleBoundaryTicker();
    },
    env: {
      JWT_SECRET: 'test-jwt-secret',
      ...extraEnv,
    },
    readyDelayMs: 1000,
    resetDb: true,
  });

  const adminToken = (await harness.bootstrapAdminSession({ name: 'SSE Test Admin' })).accessToken;

  const createGroup = async (prefix: string, displayName: string): Promise<string> => {
    const response = await harness.trpcMutate(
      'groups.create',
      { name: `${prefix}-${TEST_RUN_ID}`, displayName },
      bearerAuth(adminToken)
    );
    assertStatus(response, 200);

    const { data } = (await parseTRPC(response)) as { data?: { id?: string } };
    const groupId = data?.id ?? '';
    assert.ok(groupId, `Expected group id for ${prefix}`);
    return groupId;
  };

  const createMachineForGroup = async (
    groupId: string,
    prefix: string,
    displayName: string
  ): Promise<SseMachine> => {
    const classroom = await classroomStorage.createClassroom({
      name: `${prefix}-room-${TEST_RUN_ID}`,
      displayName,
      defaultGroupId: groupId,
    });

    const machine = await classroomStorage.registerMachine({
      hostname: `${prefix}-machine-${TEST_RUN_ID}`,
      classroomId: classroom.id,
    });

    const token = generateMachineToken();
    await classroomStorage.setMachineDownloadTokenHash(machine.id, hashMachineToken(token));

    return {
      classroomId: classroom.id,
      hostname: machine.hostname,
      id: machine.id,
      token,
    };
  };

  const testGroupId = await createGroup('sse-test', 'SSE Test Group');
  const testMachine = await createMachineForGroup(testGroupId, 'sse-test', 'SSE Test Room');

  return {
    ...harness,
    adminToken,
    createGroup,
    createMachineForGroup,
    runScheduleBoundaryTickOnce,
    testGroupId,
    testMachineToken: testMachine.token,
  };
}
