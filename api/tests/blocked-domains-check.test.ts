import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import type { BlockedDomainsTestHarness } from './blocked-domains-test-harness.js';
import { startBlockedDomainsTestHarness } from './blocked-domains-test-harness.js';
import { assertStatus, bearerAuth, parseTRPC } from './test-utils.js';

interface CheckResult {
  blocked: boolean;
}

let harness: BlockedDomainsTestHarness | undefined;

function getHarness(): BlockedDomainsTestHarness {
  assert.ok(harness, 'Blocked domains harness should be initialized');
  return harness;
}

void describe('Blocked domains - requests.check', () => {
  before(async () => {
    harness = await startBlockedDomainsTestHarness();
  });

  after(async () => {
    await harness?.close();
    harness = undefined;
  });

  void test('returns blocked status for facebook.com', async (): Promise<void> => {
    const response = await getHarness().trpcMutate(
      'requests.check',
      { domain: 'facebook.com', groupId: getHarness().teacherGroupId },
      bearerAuth(getHarness().teacherToken)
    );

    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as { data?: CheckResult };
    assert.strictEqual(typeof payload.data?.blocked, 'boolean');
  });

  void test('returns blocked status for wikipedia.org', async (): Promise<void> => {
    const response = await getHarness().trpcMutate(
      'requests.check',
      { domain: 'wikipedia.org', groupId: getHarness().teacherGroupId },
      bearerAuth(getHarness().teacherToken)
    );

    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as { data?: CheckResult };
    assert.strictEqual(typeof payload.data?.blocked, 'boolean');
  });

  void test('rejects checks without authentication', async (): Promise<void> => {
    const response = await getHarness().trpcMutate('requests.check', {
      domain: 'example.com',
      groupId: getHarness().teacherGroupId,
    });

    assert.strictEqual(response.status, 401);
  });

  void test('rejects checks without domain parameter', async (): Promise<void> => {
    const response = await getHarness().trpcMutate(
      'requests.check',
      { groupId: getHarness().teacherGroupId },
      bearerAuth(getHarness().teacherToken)
    );

    assert.strictEqual(response.status, 400);
  });

  void test('denies checking a group the authed user does not belong to', async (): Promise<void> => {
    const harnessRef = getHarness();

    // Admin creates a second group the teacher is NOT assigned to.
    const otherGroupName = `otra-group-${Date.now().toString()}`;
    const createResponse = await harnessRef.trpcMutate(
      'groups.create',
      { name: otherGroupName, displayName: otherGroupName },
      bearerAuth(harnessRef.adminToken)
    );
    assert.ok([200, 201].includes(createResponse.status), 'expected other group creation');
    const createPayload = (await parseTRPC(createResponse)) as { data?: { id?: string } };
    const otherGroupId = createPayload.data?.id ?? '';
    assert.ok(otherGroupId, 'expected other group id');

    // Teacher (member of teacherGroupId only) probes the OTHER group's rules.
    const response = await harnessRef.trpcMutate(
      'requests.check',
      { domain: 'facebook.com', groupId: otherGroupId },
      bearerAuth(harnessRef.teacherToken)
    );

    assert.strictEqual(
      response.status,
      403,
      `a user outside the group must be denied, got ${String(response.status)}`
    );
    const payload = (await response.json()) as { error?: { data?: { code?: string } } };
    assert.strictEqual(payload.error?.data?.code, 'FORBIDDEN');
  });

  void test('admin can check any group', async (): Promise<void> => {
    const harnessRef = getHarness();
    const adminGroupName = `admin-check-group-${Date.now().toString()}`;
    const createResponse = await harnessRef.trpcMutate(
      'groups.create',
      { name: adminGroupName, displayName: adminGroupName },
      bearerAuth(harnessRef.adminToken)
    );
    assert.ok([200, 201].includes(createResponse.status), 'expected group creation');
    const createPayload = (await parseTRPC(createResponse)) as { data?: { id?: string } };
    const adminGroupId = createPayload.data?.id ?? '';
    assert.ok(adminGroupId, 'expected group id');

    const response = await harnessRef.trpcMutate(
      'requests.check',
      { domain: 'facebook.com', groupId: adminGroupId },
      bearerAuth(harnessRef.adminToken)
    );

    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as { data?: CheckResult };
    assert.strictEqual(typeof payload.data?.blocked, 'boolean');
  });
});
