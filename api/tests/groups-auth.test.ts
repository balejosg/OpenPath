import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import {
  type CreateGroupResult,
  type GroupWithCounts,
  startGroupsTestHarness,
  uniqueGroupName,
} from './groups-test-harness.js';
import { assertStatus, bearerAuth, parseTRPC } from './test-utils.js';

let harness: Awaited<ReturnType<typeof startGroupsTestHarness>> | undefined;

function getHarness(): Awaited<ReturnType<typeof startGroupsTestHarness>> {
  if (harness === undefined) {
    throw new Error('Expected groups test harness to be initialized');
  }
  return harness;
}

await describe('Groups Router - authorization and CRUD', { timeout: 30000 }, async () => {
  before(async () => {
    harness = await startGroupsTestHarness();
  });

  after(async () => {
    if (harness !== undefined) {
      await harness.close();
    }
  });

  await describe('Authorization', async () => {
    await test('should reject unauthenticated requests', async () => {
      const response = await getHarness().trpcQuery('groups.list');
      assert.strictEqual(response.status, 401);
    });

    await test('should reject non-admin users', async () => {
      const session = await getHarness().createVerifiedUserSession('nonadmin');

      const response = await getHarness().trpcQuery(
        'groups.list',
        undefined,
        bearerAuth(session.accessToken)
      );
      assert.strictEqual(response.status, 403);
    });

    await test('should accept admin users', async () => {
      const response = await getHarness().trpcQuery(
        'groups.list',
        undefined,
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(response, 200);
    });
  });

  await describe('Group CRUD Operations', async () => {
    let testGroupId = '';
    const testGroupName = uniqueGroupName('crud-test');

    await test('should list groups (initially may be empty)', async () => {
      const response = await getHarness().trpcQuery(
        'groups.list',
        undefined,
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: GroupWithCounts[] };
      assert.ok(Array.isArray(data));
    });

    await test('should create a new group', async () => {
      const response = await getHarness().trpcMutate(
        'groups.create',
        {
          name: testGroupName,
          displayName: 'CRUD Test Group',
        },
        bearerAuth(getHarness().adminToken)
      );

      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: CreateGroupResult };
      assert.ok(data?.id);
      assert.ok(data.name);
      testGroupId = data.id;
    });

    await test('should allow a teacher to create a group', async () => {
      const teacher = await getHarness().createTeacherSession([]);

      const response = await getHarness().trpcMutate(
        'groups.create',
        {
          name: uniqueGroupName('teacher-create'),
          displayName: 'Teacher Created Group',
        },
        bearerAuth(teacher.accessToken)
      );

      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: CreateGroupResult };
      assert.ok(data?.id);
      assert.ok(data.name);
    });

    await test('should get group by ID', async () => {
      const response = await getHarness().trpcQuery(
        'groups.getById',
        { id: testGroupId },
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: GroupWithCounts };
      assert.ok(data);
      assert.strictEqual(data.id, testGroupId);
      assert.strictEqual(data.displayName, 'CRUD Test Group');
      assert.strictEqual(data.enabled, true);
    });

    await test('should get group by name', async () => {
      const response = await getHarness().trpcQuery(
        'groups.getByName',
        { name: testGroupName },
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: GroupWithCounts };
      assert.ok(data);
      assert.strictEqual(data.id, testGroupId);
    });

    await test('should update a group', async () => {
      const response = await getHarness().trpcMutate(
        'groups.update',
        {
          id: testGroupId,
          displayName: 'Updated CRUD Test Group',
          enabled: false,
        },
        bearerAuth(getHarness().adminToken)
      );

      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: GroupWithCounts };
      assert.ok(data);
      assert.strictEqual(data.displayName, 'Updated CRUD Test Group');
      assert.strictEqual(data.enabled, false);
    });

    await test('should reject creating duplicate group name', async () => {
      const response = await getHarness().trpcMutate(
        'groups.create',
        {
          name: testGroupName,
          displayName: 'Duplicate Group',
        },
        bearerAuth(getHarness().adminToken)
      );

      assert.strictEqual(response.status, 409);
    });

    await test('should return NOT_FOUND for non-existent group', async () => {
      const response = await getHarness().trpcQuery(
        'groups.getById',
        { id: 'non-existent-id' },
        bearerAuth(getHarness().adminToken)
      );
      assert.strictEqual(response.status, 404);
    });

    await test('should delete a group', async () => {
      const created = await getHarness().createGroup({
        displayName: 'Group to Delete',
        name: uniqueGroupName('delete-test'),
      });

      const deleteResp = await getHarness().trpcMutate(
        'groups.delete',
        { id: created.id },
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(deleteResp, 200);

      const { data } = (await parseTRPC(deleteResp)) as { data?: { deleted: boolean } };
      assert.strictEqual(data?.deleted, true);

      const getResp = await getHarness().trpcQuery(
        'groups.getById',
        { id: created.id },
        bearerAuth(getHarness().adminToken)
      );
      assert.strictEqual(getResp.status, 404);
    });
  });
});
