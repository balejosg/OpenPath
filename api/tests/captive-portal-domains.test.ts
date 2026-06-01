import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';

import {
  type ClassroomsTestHarness,
  startClassroomsTestHarness,
  uniqueClassroomName,
} from './classrooms-test-harness.js';
import { assertStatus, bearerAuth, parseTRPC } from './test-utils.js';

let harness: ClassroomsTestHarness | undefined;

function getHarness(): ClassroomsTestHarness {
  assert.ok(harness, 'Classrooms harness should be initialized');
  return harness;
}

void describe('Classroom captive portal domains', () => {
  before(async () => {
    harness = await startClassroomsTestHarness();
  });

  after(async () => {
    await harness?.close();
    harness = undefined;
  });

  void test('create/list/get/update expose normalized exact domains', async () => {
    const createResponse = await getHarness().trpcMutate(
      'classrooms.create',
      {
        name: uniqueClassroomName('portal-room'),
        displayName: 'Portal Room',
        captivePortalDomains: [' Login.EXAMPLE.test ', 'login.example.test', 'wifi.example.test'],
      },
      bearerAuth(getHarness().adminToken)
    );

    assertStatus(createResponse, 200);
    const createdPayload = (await parseTRPC(createResponse)) as {
      data?: { id?: string; captivePortalDomains?: string[] };
    };
    const classroomId = createdPayload.data?.id;
    assert.ok(classroomId);
    assert.deepEqual(createdPayload.data?.captivePortalDomains, [
      'login.example.test',
      'wifi.example.test',
    ]);

    const updateResponse = await getHarness().trpcMutate(
      'classrooms.update',
      {
        id: classroomId,
        captivePortalDomains: ['portal.example.test'],
      },
      bearerAuth(getHarness().adminToken)
    );
    assertStatus(updateResponse, 200);

    const listPayload = (await parseTRPC(
      await getHarness().trpcQuery(
        'classrooms.list',
        undefined,
        bearerAuth(getHarness().adminToken)
      )
    )) as { data?: { id?: string; captivePortalDomains?: string[] }[] };
    assert.deepEqual(
      listPayload.data?.find((entry) => entry.id === classroomId)?.captivePortalDomains,
      ['portal.example.test']
    );

    const getPayload = (await parseTRPC(
      await getHarness().trpcQuery(
        'classrooms.get',
        { id: classroomId },
        bearerAuth(getHarness().adminToken)
      )
    )) as { data?: { captivePortalDomains?: string[] } };
    assert.deepEqual(getPayload.data?.captivePortalDomains, ['portal.example.test']);
  });

  void test('rejects invalid captive portal domains', async () => {
    const response = await getHarness().trpcMutate(
      'classrooms.create',
      {
        name: uniqueClassroomName('bad-portal-room'),
        captivePortalDomains: ['https://login.example.test'],
      },
      bearerAuth(getHarness().adminToken)
    );

    assertStatus(response, 400);
  });
});
