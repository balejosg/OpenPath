import assert from 'node:assert';

import { startHttpTestHarness, type HttpTestHarness } from './http-test-harness.js';
import { TEST_RUN_ID, assertStatus, bearerAuth, parseTRPC } from './test-utils.js';

export interface UserResult {
  email: string;
  id: string;
  name: string;
  roles?: { groupIds: string[]; id: string; role: string }[];
}

export interface RoleResult {
  groupIds: string[];
  id: string;
  role: string;
}

export interface TeacherResult {
  groupIds: string[];
  userId: string;
}

export interface RolesTestHarness extends HttpTestHarness {
  adminToken: string;
  assignRole: (input: { groupIds?: string[]; role: string; userId: string }) => Promise<RoleResult>;
  createGroup: (name: string) => Promise<{ id: string; name: string }>;
  createUser: (input?: { email?: string; name?: string; password?: string }) => Promise<UserResult>;
  deleteGroup: (id: string) => Promise<{ deleted: boolean }>;
  fetchUser: (userId: string) => Promise<UserResult>;
  groupIds: { ciencias: string; matematicas: string };
  groupNames: { ciencias: string; matematicas: string };
  listTeachers: () => Promise<TeacherResult[]>;
  revokeRole: (input: { roleId: string; userId: string }) => Promise<Response>;
}

function uniqueEmail(prefix: string): string {
  return `${prefix}-${TEST_RUN_ID}-${Math.random().toString(36).slice(2, 6)}@school.edu`;
}

export async function startRolesTestHarness(): Promise<RolesTestHarness> {
  const harness = await startHttpTestHarness({
    env: {
      JWT_SECRET: 'test-jwt-secret',
    },
    readyDelayMs: 1000,
    resetDb: true,
  });

  const adminToken = (await harness.bootstrapAdminSession({ name: 'Roles Test Admin' }))
    .accessToken;

  const createGroup = async (name: string): Promise<{ id: string; name: string }> => {
    const response = await harness.trpcMutate(
      'groups.create',
      { name, displayName: name },
      bearerAuth(adminToken)
    );
    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as { data?: { id?: string; name?: string } };
    const id = payload.data?.id ?? '';
    assert.ok(id, `Expected group id for ${name}`);
    return { id, name: payload.data?.name ?? name };
  };

  const cienciasName = `ciencias-3eso-${TEST_RUN_ID}`;
  const matematicasName = `matematicas-4eso-${TEST_RUN_ID}`;
  const ciencias = await createGroup(cienciasName);
  const matematicas = await createGroup(matematicasName);

  const createUser = async (
    input: { email?: string; name?: string; password?: string } = {}
  ): Promise<UserResult> => {
    const response = await harness.trpcMutate(
      'users.create',
      {
        email: input.email ?? uniqueEmail('teacher'),
        password: input.password ?? 'TeacherPassword123!',
        name: input.name ?? 'Pedro Garcia (Test Teacher)',
      },
      bearerAuth(adminToken)
    );
    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as { data?: UserResult };
    assert.ok(payload.data?.id, 'Expected created user id');
    return payload.data;
  };

  const assignRole = async (input: {
    groupIds?: string[];
    role: string;
    userId: string;
  }): Promise<RoleResult> => {
    const response = await harness.trpcMutate(
      'users.assignRole',
      {
        userId: input.userId,
        role: input.role,
        groupIds: input.groupIds ?? [],
      },
      bearerAuth(adminToken)
    );
    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as { data?: RoleResult };
    assert.ok(payload.data?.id, 'Expected assigned role id');
    return payload.data;
  };

  const fetchUser = async (userId: string): Promise<UserResult> => {
    const response = await harness.trpcQuery('users.get', { id: userId }, bearerAuth(adminToken));
    assertStatus(response, 200);
    const payload = (await parseTRPC(response)) as { data?: UserResult };
    assert.ok(payload.data?.id, 'Expected fetched user');
    return payload.data;
  };

  return {
    ...harness,
    adminToken,
    assignRole,
    createGroup,
    createUser,
    deleteGroup: async (id: string): Promise<{ deleted: boolean }> => {
      const response = await harness.trpcMutate('groups.delete', { id }, bearerAuth(adminToken));
      assertStatus(response, 200);
      const payload = (await parseTRPC(response)) as { data?: { deleted: boolean } };
      assert.equal(payload.data?.deleted, true);
      assert.ok(payload.data, 'Expected deleted group response');
      return payload.data;
    },
    fetchUser,
    groupIds: { ciencias: ciencias.id, matematicas: matematicas.id },
    groupNames: { ciencias: ciencias.name, matematicas: matematicas.name },
    listTeachers: async (): Promise<TeacherResult[]> => {
      const response = await harness.trpcQuery(
        'users.listTeachers',
        undefined,
        bearerAuth(adminToken)
      );
      assertStatus(response, 200);
      const payload = (await parseTRPC(response)) as { data?: TeacherResult[] };
      return payload.data ?? [];
    },
    revokeRole: (input) =>
      harness.trpcMutate(
        'users.revokeRole',
        { userId: input.userId, roleId: input.roleId },
        bearerAuth(adminToken)
      ),
  };
}
