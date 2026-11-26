import assert from 'node:assert';

import { startHttpTestHarness, type HttpTestHarness } from './http-test-harness.js';
import { TEST_RUN_ID, assertStatus, bearerAuth, parseTRPC } from './test-utils.js';

interface AuthResult {
  accessToken?: string;
  user?: { id: string };
}

interface RequestResult {
  id: string;
}

export interface BlockedDomainsTestHarness extends HttpTestHarness {
  adminToken: string;
  createPendingRequest: (input?: {
    domain?: string;
    requesterEmail?: string;
    groupId?: string;
  }) => Promise<string>;
  teacherGroupId: string;
  teacherGroupName: string;
  teacherToken: string;
  teacherUserId: string;
}

export function uniqueBlockedDomain(suffix: string): string {
  return `blocked-test-${suffix}-${Date.now().toString()}.example.com`;
}

export function uniqueSafeDomain(suffix: string): string {
  return `safe-test-${suffix}-${Date.now().toString()}.example.org`;
}

async function login(
  harness: HttpTestHarness,
  email: string,
  password: string
): Promise<{ accessToken: string; userId: string }> {
  const response = await harness.trpcMutate('auth.login', { email, password });
  assertStatus(response, 200);
  const payload = (await parseTRPC(response)) as { data?: AuthResult };
  const accessToken = payload.data?.accessToken ?? '';
  const userId = payload.data?.user?.id ?? '';
  assert.ok(accessToken, 'Expected access token');
  assert.ok(userId, 'Expected user id');
  return { accessToken, userId };
}

export async function startBlockedDomainsTestHarness(): Promise<BlockedDomainsTestHarness> {
  const harness = await startHttpTestHarness({
    env: {
      JWT_SECRET: 'test-jwt-secret',
    },
    readyDelayMs: 1000,
    resetDb: true,
  });

  const adminEmail = `blocked-test-admin-${TEST_RUN_ID}@school.edu`;
  const teacherEmail = `blocked-test-teacher-${TEST_RUN_ID}@school.edu`;
  const adminPassword = 'AdminPassword123!';
  const teacherPassword = 'TeacherPassword123!';
  const teacherGroupName = `ciencias-3eso-${TEST_RUN_ID}`;

  const adminSession = await harness.bootstrapAdminSession({
    email: adminEmail,
    name: 'Blocked Domains Admin',
    password: adminPassword,
  });
  const adminToken = adminSession.accessToken;

  const groupResponse = await harness.trpcMutate(
    'groups.create',
    { name: teacherGroupName, displayName: teacherGroupName },
    bearerAuth(adminToken)
  );
  assert.ok([200, 201].includes(groupResponse.status), 'Expected teacher group creation');
  const groupPayload = (await parseTRPC(groupResponse)) as { data?: { id?: string } };
  const teacherGroupId = groupPayload.data?.id ?? '';
  assert.ok(teacherGroupId, 'Expected teacher group id');

  const teacherResponse = await harness.trpcMutate(
    'users.create',
    {
      email: teacherEmail,
      password: teacherPassword,
      name: 'Pedro Garcia (Blocked Domains Test)',
    },
    bearerAuth(adminToken)
  );
  assertStatus(teacherResponse, 200);
  const teacherPayload = (await parseTRPC(teacherResponse)) as { data?: { id?: string } };
  const teacherUserId = teacherPayload.data?.id ?? '';
  assert.ok(teacherUserId, 'Expected teacher user id');

  const assignRoleResponse = await harness.trpcMutate(
    'users.assignRole',
    {
      userId: teacherUserId,
      role: 'teacher',
      groupIds: [teacherGroupId],
    },
    bearerAuth(adminToken)
  );
  assertStatus(assignRoleResponse, 200);

  const teacherSession = await login(harness, teacherEmail, teacherPassword);

  return {
    ...harness,
    adminToken,
    createPendingRequest: async (input = {}): Promise<string> => {
      const response = await harness.trpcMutate('requests.create', {
        domain: input.domain ?? uniqueBlockedDomain(TEST_RUN_ID),
        reason: 'Test request for domain approval',
        requesterEmail: input.requesterEmail ?? `student-${TEST_RUN_ID}@test.com`,
        ...(input.groupId ? { groupId: input.groupId } : {}),
      });
      assertStatus(response, 200);
      const payload = (await parseTRPC(response)) as { data?: RequestResult };
      const requestId = payload.data?.id ?? '';
      assert.ok(requestId, 'Expected pending request id');
      return requestId;
    },
    teacherGroupId,
    teacherGroupName,
    teacherToken: teacherSession.accessToken,
    teacherUserId: teacherSession.userId,
  };
}
