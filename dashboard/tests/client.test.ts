import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { afterEach, beforeEach, describe, it } from 'node:test';

import type { ApiClient, LoginResult } from '../src/api-client.js';

interface FetchCall {
  pathname: string;
  authorization: string | null;
}

interface ApiClientModule {
  createApiClient(token: string): ApiClient;
  login(username: string, password: string): Promise<LoginResult>;
  refreshToken(refreshTokenValue: string): Promise<LoginResult>;
  logout(token: string, refreshTokenValue: string): Promise<boolean>;
  changePassword(
    token: string,
    currentPassword: string,
    newPassword: string
  ): Promise<{ success: boolean; error?: string }>;
}

interface TrpcModule {
  API_URL: string;
  getTRPCErrorCode(error: unknown): string | undefined;
  getTRPCErrorMessage(error: unknown): string;
  getTRPCErrorStatus(error: unknown): number;
}

const originalFetch = globalThis.fetch;

let fetchCalls: FetchCall[] = [];
let failingPaths: Set<string>;

function getRequestUrl(input: Parameters<typeof fetch>[0]): URL {
  if (typeof input === 'string') {
    return new URL(input);
  }
  if (input instanceof URL) {
    return input;
  }
  return new URL(input.url);
}

function getAuthorizationHeader(init: RequestInit | undefined): string | null {
  return new Headers(init?.headers).get('Authorization');
}

function trpcResponse(data: unknown): Response {
  return new Response(JSON.stringify([{ result: { data } }]), {
    headers: { 'content-type': 'application/json' },
    status: 200,
  });
}

beforeEach(() => {
  fetchCalls = [];
  failingPaths = new Set();
  process.env.API_URL = 'http://dashboard.test';
  globalThis.fetch = ((input, init) => {
    const url = getRequestUrl(input);
    fetchCalls.push({
      pathname: url.pathname,
      authorization: getAuthorizationHeader(init),
    });

    if (failingPaths.has(url.pathname)) {
      return Promise.reject(new Error(`Forced tRPC failure: ${url.pathname}`));
    }

    switch (url.pathname) {
      case '/trpc/auth.login':
        return Promise.resolve(
          trpcResponse({
            accessToken: 'access-token',
            refreshToken: 'refresh-token',
            user: { id: 'user-1', email: 'teacher@dashboard.local', name: 'Teacher Dashboard' },
          })
        );
      case '/trpc/auth.refresh':
        return Promise.resolve(
          trpcResponse({ accessToken: 'new-access-token', refreshToken: 'new-refresh-token' })
        );
      case '/trpc/auth.logout':
        return Promise.resolve(trpcResponse({ success: true }));
      case '/trpc/auth.changePassword':
        return Promise.resolve(trpcResponse({ success: true }));
      case '/trpc/groups.list':
        return Promise.resolve(
          trpcResponse([
            {
              id: 'group-1',
              name: 'teachers',
              displayName: 'Teachers',
              enabled: true,
              whitelistCount: 2,
              blockedSubdomainCount: 1,
              blockedPathCount: 0,
            },
          ])
        );
      case '/trpc/groups.getById':
        return Promise.resolve(
          trpcResponse({ id: 'group-1', name: 'teachers', displayName: 'Teachers' })
        );
      case '/trpc/groups.getByName':
        return Promise.resolve(
          trpcResponse({ id: 'group-1', name: 'teachers', displayName: 'Teachers' })
        );
      case '/trpc/groups.create':
        return Promise.resolve(trpcResponse({ id: 'group-2', name: 'new-group' }));
      case '/trpc/groups.update':
        return Promise.resolve(
          trpcResponse({ id: 'group-1', name: 'teachers', displayName: 'Updated Teachers' })
        );
      case '/trpc/groups.delete':
        return Promise.resolve(trpcResponse({ deleted: true }));
      case '/trpc/groups.listRules':
        return Promise.resolve(
          trpcResponse([
            { id: 'rule-1', groupId: 'group-1', type: 'whitelist', value: 'example.com' },
          ])
        );
      case '/trpc/groups.createRule':
        return Promise.resolve(trpcResponse({ id: 'rule-2' }));
      case '/trpc/groups.deleteRule':
        return Promise.resolve(trpcResponse({ deleted: true }));
      case '/trpc/groups.bulkCreateRules':
        return Promise.resolve(trpcResponse({ count: 2 }));
      case '/trpc/groups.stats':
        return Promise.resolve(
          trpcResponse({ groupCount: 3, whitelistCount: 10, blockedCount: 4 })
        );
      case '/trpc/groups.systemStatus':
        return Promise.resolve(
          trpcResponse({ enabled: true, totalGroups: 3, activeGroups: 2, pausedGroups: 1 })
        );
      case '/trpc/groups.toggleSystem':
        return Promise.resolve(
          trpcResponse({ enabled: false, totalGroups: 3, activeGroups: 0, pausedGroups: 3 })
        );
      case '/trpc/groups.export':
        return Promise.resolve(trpcResponse({ name: 'teachers', content: 'example.com' }));
      case '/trpc/groups.exportAll':
        return Promise.resolve(trpcResponse([{ name: 'teachers', content: 'example.com' }]));
      default:
        return Promise.reject(new Error(`Unexpected tRPC request: ${url.pathname}`));
    }
  }) as typeof fetch;
});

afterEach(() => {
  globalThis.fetch = originalFetch;
  delete process.env.API_URL;
});

void describe('dashboard tRPC client wrappers', () => {
  void it('wraps authenticated group operations', async () => {
    const tag = randomUUID();
    const clientModule = (await import(`../src/api-client.ts?${tag}`)) as ApiClientModule;

    const client = clientModule.createApiClient('Bearer-Token');

    assert.deepStrictEqual(await client.getAllGroups(), [
      {
        id: 'group-1',
        name: 'teachers',
        displayName: 'Teachers',
        enabled: true,
        whitelistCount: 2,
        blockedSubdomainCount: 1,
        blockedPathCount: 0,
      },
    ]);
    assert.deepStrictEqual(await client.getGroupById('group-1'), {
      id: 'group-1',
      name: 'teachers',
      displayName: 'Teachers',
    });
    assert.deepStrictEqual(await client.getGroupByName('teachers'), {
      id: 'group-1',
      name: 'teachers',
      displayName: 'Teachers',
    });
    assert.deepStrictEqual(await client.createGroup('new-group', 'New Group'), {
      id: 'group-2',
      name: 'new-group',
    });
    assert.deepStrictEqual(await client.updateGroup('group-1', 'Updated Teachers', true), {
      id: 'group-1',
      name: 'teachers',
      displayName: 'Updated Teachers',
    });
    assert.strictEqual(await client.deleteGroup('group-1'), true);
    assert.deepStrictEqual(await client.getRulesByGroup('group-1'), [
      { id: 'rule-1', groupId: 'group-1', type: 'whitelist', value: 'example.com' },
    ]);
    assert.deepStrictEqual(await client.createRule('group-1', 'whitelist', 'example.com'), {
      id: 'rule-2',
    });
    assert.strictEqual(await client.deleteRule('rule-1'), true);
    assert.strictEqual(
      await client.bulkCreateRules('group-1', 'whitelist', ['a.example.com', 'b.example.com']),
      2
    );
    assert.deepStrictEqual(await client.getStats(), {
      groupCount: 3,
      whitelistCount: 10,
      blockedCount: 4,
    });
    assert.deepStrictEqual(await client.getSystemStatus(), {
      enabled: true,
      totalGroups: 3,
      activeGroups: 2,
      pausedGroups: 1,
    });
    assert.deepStrictEqual(await client.toggleSystemStatus(false), {
      enabled: false,
      totalGroups: 3,
      activeGroups: 0,
      pausedGroups: 3,
    });
    assert.deepStrictEqual(await client.exportGroup('group-1'), {
      name: 'teachers',
      content: 'example.com',
    });
    assert.deepStrictEqual(await client.exportAllGroups(), [
      { name: 'teachers', content: 'example.com' },
    ]);

    assert.ok(fetchCalls.length >= 15);
    assert.ok(fetchCalls.every((call) => call.authorization === 'Bearer Bearer-Token'));
  });

  void it('wraps public authentication operations and helpers', async () => {
    const tag = randomUUID();
    const clientModule = (await import(`../src/api-client.ts?${tag}`)) as ApiClientModule;
    const trpcModule = (await import(`../src/trpc.ts?${tag}`)) as TrpcModule;

    assert.deepStrictEqual(await clientModule.login('teacher', 'Password123!'), {
      success: true,
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      user: {
        id: 'user-1',
        email: 'teacher@dashboard.local',
        name: 'Teacher Dashboard',
      },
    });
    assert.deepStrictEqual(await clientModule.refreshToken('refresh-token'), {
      success: true,
      accessToken: 'new-access-token',
      refreshToken: 'new-refresh-token',
    });
    assert.strictEqual(await clientModule.logout('Bearer-Token', 'refresh-token'), true);
    assert.deepStrictEqual(
      await clientModule.changePassword('Bearer-Token', 'old-password', 'new-password'),
      { success: true }
    );

    const authCalls = fetchCalls.filter((call) => call.pathname.startsWith('/trpc/auth.'));
    assert.strictEqual(authCalls[0]?.authorization, null);
    assert.strictEqual(authCalls[1]?.authorization, null);
    assert.strictEqual(authCalls[2]?.authorization, 'Bearer Bearer-Token');
    assert.strictEqual(authCalls[3]?.authorization, 'Bearer Bearer-Token');

    assert.strictEqual(trpcModule.getTRPCErrorCode(new Error('boom')), undefined);
    assert.strictEqual(trpcModule.getTRPCErrorMessage(new Error('boom')), 'boom');
    assert.strictEqual(trpcModule.getTRPCErrorStatus(new Error('boom')), 500);
    assert.strictEqual(trpcModule.API_URL, 'http://dashboard.test');
  });

  void it('returns auth failure results when tRPC calls fail', async () => {
    const tag = randomUUID();
    const clientModule = (await import(`../src/api-client.ts?${tag}`)) as ApiClientModule;

    failingPaths.add('/trpc/auth.login');
    assert.deepStrictEqual(await clientModule.login('teacher@example.com', 'Password123!'), {
      success: false,
      error: 'Forced tRPC failure: /trpc/auth.login',
    });

    failingPaths.add('/trpc/auth.refresh');
    assert.deepStrictEqual(await clientModule.refreshToken('refresh-token'), {
      success: false,
      error: 'Forced tRPC failure: /trpc/auth.refresh',
    });

    failingPaths.add('/trpc/auth.logout');
    assert.strictEqual(await clientModule.logout('Bearer-Token', 'refresh-token'), false);

    failingPaths.add('/trpc/auth.changePassword');
    assert.deepStrictEqual(
      await clientModule.changePassword('Bearer-Token', 'old-password', 'new-password'),
      {
        success: false,
        error: 'Forced tRPC failure: /trpc/auth.changePassword',
      }
    );
  });
});
