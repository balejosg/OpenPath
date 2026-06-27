import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  bulkCreateRules,
  bulkDeleteRules,
  createRule,
  deleteRule,
  getRulesByIds,
  revokeAutoApproval,
  updateRule,
} from '../src/services/groups-rules.service.js';
import type { GroupWithCounts, Rule } from '../src/lib/groups-storage.js';
import type { UpdateRuleInput as StorageUpdateRuleInput } from '../src/lib/groups-storage-shared.js';

async function runWithFakeTx<T>(callback: (tx: never) => Promise<T>): Promise<T> {
  return callback({} as never);
}

function createGroup(overrides: Partial<GroupWithCounts> = {}): GroupWithCounts {
  return {
    blockedPathCount: 0,
    blockedSubdomainCount: 0,
    createdAt: '',
    displayName: 'Group 1',
    enabled: true,
    id: 'group-1',
    name: 'Group 1',
    ownerUserId: null,
    updatedAt: null,
    visibility: 'private',
    whitelistCount: 0,
    ...overrides,
  };
}

function createRuleRecord(overrides: Partial<Rule> = {}): Rule {
  return {
    id: 'rule-1',
    groupId: 'group-a',
    type: 'whitelist',
    value: 'example.com',
    source: 'manual',
    enabled: true,
    comment: null,
    createdAt: '',
    ...overrides,
  };
}

await describe('groups rules service', async () => {
  await test('returns empty rules immediately for empty ids', async () => {
    assert.deepEqual(await getRulesByIds([]), []);
  });

  await test('creates manual rules through the shared whitelist command boundary', async () => {
    const publishedGroups: string[] = [];
    const createdRules: {
      comment: string | null | undefined;
      groupId: string;
      source: string | undefined;
      type: string;
      value: string;
    }[] = [];

    const result = await createRule(
      {
        comment: 'Teacher note',
        groupId: 'group-1',
        type: 'whitelist',
        value: ' Example.COM ',
      },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: (groupId, type, value, comment, source) => {
          createdRules.push({ comment, groupId, source, type, value });
          return Promise.resolve({ success: true, id: 'rule-1' });
        },
        deleteRule: () => Promise.resolve(false),
        getGroupById: () => Promise.resolve(createGroup()),
        getRuleById: () => Promise.resolve(null),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: (groupId) => {
          publishedGroups.push(groupId);
        },
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, { ok: true, data: { id: 'rule-1' } });
    assert.deepEqual(createdRules, [
      {
        comment: 'Teacher note',
        groupId: 'group-1',
        source: 'manual',
        type: 'whitelist',
        value: 'example.com',
      },
    ]);
    assert.deepEqual(publishedGroups, ['group-1']);
  });

  await test('rejects invalid rule values before touching storage', async () => {
    const result = await createRule(
      {
        groupId: 'group-1',
        type: 'whitelist',
        value: 'http://',
      },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: () => Promise.resolve({ success: false }),
        deleteRule: () => Promise.resolve(false),
        getGroupById: () => Promise.resolve(null),
        getRuleById: () => Promise.resolve(null),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: (_groupId) => undefined,
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Value is required' },
    });
  });

  await test('returns conflict when shared rule creation reports a duplicate', async () => {
    const result = await createRule(
      {
        groupId: 'group-1',
        type: 'whitelist',
        value: 'duplicate.example.com',
      },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: () => Promise.resolve({ success: false, error: 'Rule already exists' }),
        deleteRule: () => Promise.resolve(false),
        getGroupById: () => Promise.resolve(createGroup()),
        getRuleById: () => Promise.resolve(null),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: () => undefined,
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'CONFLICT', message: 'Rule already exists' },
    });
  });

  await test('returns internal error when storage reports success without an id', async () => {
    const result = await createRule(
      {
        groupId: 'group-1',
        type: 'blocked_subdomain',
        value: 'ads.example.com',
      },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: () => Promise.resolve({ success: true }),
        deleteRule: () => Promise.resolve(false),
        getGroupById: () => Promise.resolve(createGroup()),
        getRuleById: () => Promise.resolve(null),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: () => undefined,
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'INTERNAL_SERVER_ERROR', message: 'Failed to create rule' },
    });
  });

  await test('returns empty delete outcome without opening a transaction for empty bulk input', async () => {
    const result = await bulkDeleteRules([], undefined, {
      bulkDeleteRules: () => Promise.resolve(1),
      getRulesByIds: () => Promise.resolve([]),
      publishWhitelistChanged: () => undefined,
      withTransaction: () => Promise.reject(new Error('transaction should not be opened')),
    });

    assert.deepEqual(result, { ok: true, data: { deleted: 0, rules: [] } });
  });

  await test('publishes affected groups on bulk delete', async () => {
    const publishedGroups: string[] = [];

    const result = await bulkDeleteRules(
      ['rule-1', 'rule-2'],
      {
        rules: [
          {
            id: 'rule-1',
            groupId: 'group-a',
            type: 'whitelist',
            value: 'a.example.com',
            source: 'manual',
            enabled: true,
            comment: null,
            createdAt: '',
          },
          {
            id: 'rule-2',
            groupId: 'group-b',
            type: 'whitelist',
            value: 'b.example.com',
            source: 'manual',
            enabled: true,
            comment: null,
            createdAt: '',
          },
        ],
      },
      {
        bulkDeleteRules: () => Promise.resolve(2),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: (groupId: string) => {
          publishedGroups.push(groupId);
        },
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: true,
      data: {
        deleted: 2,
        rules: [
          {
            id: 'rule-1',
            groupId: 'group-a',
            type: 'whitelist',
            value: 'a.example.com',
            source: 'manual',
            enabled: true,
            comment: null,
            createdAt: '',
          },
          {
            id: 'rule-2',
            groupId: 'group-b',
            type: 'whitelist',
            value: 'b.example.com',
            source: 'manual',
            enabled: true,
            comment: null,
            createdAt: '',
          },
        ],
      },
    });
    assert.deepEqual(publishedGroups.sort(), ['group-a', 'group-b']);
  });

  await test('reuses looked-up rule group when deleting a single rule', async () => {
    const publishedGroups: string[] = [];

    const result = await deleteRule('rule-1', undefined, {
      deleteRule: () => Promise.resolve(true),
      getRuleById: () =>
        Promise.resolve({
          id: 'rule-1',
          groupId: 'group-a',
          type: 'whitelist' as const,
          value: 'a.example.com',
          source: 'manual' as const,
          enabled: true,
          comment: null,
          createdAt: '',
        }),
      publishWhitelistChanged: (groupId: string) => {
        publishedGroups.push(groupId);
      },
      withTransaction: runWithFakeTx,
    });

    assert.deepEqual(result, {
      ok: true,
      data: { deleted: true },
    });
    assert.deepEqual(publishedGroups, ['group-a']);
  });

  await test('revokes an automatic approval by replacing it with an explicit block', async () => {
    const publishedGroups: string[] = [];
    const deletedRuleIds: string[] = [];
    const createdRules: {
      groupId: string;
      type: string;
      value: string;
      comment: string | null | undefined;
      source: string | undefined;
    }[] = [];

    const result = await revokeAutoApproval(
      { id: 'rule-auto-1', groupId: 'group-a', resolvedBy: 'teacher@example.com' },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: (groupId, type, value, comment, source) => {
          createdRules.push({ groupId, type, value, comment, source });
          return Promise.resolve({ success: true, id: 'blocked-rule-1' });
        },
        deleteRule: (id) => {
          deletedRuleIds.push(id);
          return Promise.resolve(true);
        },
        getGroupById: () => Promise.resolve(null),
        getRuleById: () =>
          Promise.resolve({
            id: 'rule-auto-1',
            groupId: 'group-a',
            type: 'whitelist',
            value: 'cdn.example.com',
            source: 'auto_extension',
            enabled: true,
            comment: null,
            createdAt: '',
          }),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: (groupId: string) => {
          publishedGroups.push(groupId);
        },
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: true,
      data: { revoked: true, blockedRuleId: 'blocked-rule-1' },
    });
    assert.deepEqual(deletedRuleIds, ['rule-auto-1']);
    assert.deepEqual(createdRules, [
      {
        groupId: 'group-a',
        type: 'blocked_subdomain',
        value: 'cdn.example.com',
        comment: 'Revoked automatic approval by teacher@example.com',
        source: 'manual',
      },
    ]);
    assert.deepEqual(publishedGroups, ['group-a']);
  });

  await test('returns not found when automatic approval rule belongs to another group', async () => {
    const result = await revokeAutoApproval(
      { id: 'rule-auto-1', groupId: 'group-a', resolvedBy: 'teacher@example.com' },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: () => Promise.resolve({ success: true, id: 'blocked-rule-1' }),
        deleteRule: () => Promise.resolve(true),
        getGroupById: () => Promise.resolve(null),
        getRuleById: () =>
          Promise.resolve({
            id: 'rule-auto-1',
            groupId: 'group-b',
            type: 'whitelist',
            value: 'cdn.example.com',
            source: 'auto_extension',
            enabled: true,
            comment: null,
            createdAt: '',
          }),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: () => undefined,
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Rule not found' },
    });
  });

  await test('maps automatic revoke command errors to bad request results', async () => {
    const result = await revokeAutoApproval(
      { id: 'rule-auto-1', groupId: 'group-a', resolvedBy: 'teacher@example.com' },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: () => Promise.resolve({ success: false, error: 'cannot replace rule' }),
        deleteRule: () => Promise.resolve(true),
        getGroupById: () => Promise.resolve(null),
        getRuleById: () =>
          Promise.resolve({
            id: 'rule-auto-1',
            groupId: 'group-a',
            type: 'whitelist',
            value: 'cdn.example.com',
            source: 'auto_extension',
            enabled: true,
            comment: null,
            createdAt: '',
          }),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: () => undefined,
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'cannot replace rule' },
    });
  });

  await test('does not revoke manual whitelist rules as automatic approvals', async () => {
    const result = await revokeAutoApproval(
      { id: 'rule-manual-1', groupId: 'group-a', resolvedBy: 'teacher@example.com' },
      {
        bulkDeleteRules: () => Promise.resolve(0),
        createRule: () => Promise.resolve({ success: true, id: 'blocked-rule-1' }),
        deleteRule: () => Promise.resolve(true),
        getGroupById: () => Promise.resolve(null),
        getRuleById: () =>
          Promise.resolve({
            id: 'rule-manual-1',
            groupId: 'group-a',
            type: 'whitelist',
            value: 'cdn.example.com',
            source: 'manual',
            enabled: true,
            comment: null,
            createdAt: '',
          }),
        getRulesByIds: () => Promise.resolve([]),
        publishWhitelistChanged: () => undefined,
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'Only automatic whitelist approvals can be revoked this way',
      },
    });
  });

  await test('bulk creates cleaned rules and publishes once when storage creates rows', async () => {
    const createdBatches: {
      groupId: string;
      source: string | undefined;
      type: string;
      values: string[];
    }[] = [];

    const result = await bulkCreateRules(
      {
        groupId: 'group-a',
        type: 'whitelist',
        values: [' First.example ', 'second.example'],
      },
      {
        bulkCreateRules: (groupId, type, values, source) => {
          createdBatches.push({ groupId, source, type, values });
          return Promise.resolve(values.length);
        },
        getGroupById: () =>
          Promise.resolve(createGroup({ displayName: 'Group A', id: 'group-a', name: 'Group A' })),
        publishWhitelistChanged: () => undefined,
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, { ok: true, data: { count: 2 } });
    assert.deepEqual(createdBatches, [
      {
        groupId: 'group-a',
        source: 'manual',
        type: 'whitelist',
        values: ['first.example', 'second.example'],
      },
    ]);
  });

  await test('rejects updates before storage when the group or rule is invalid', async () => {
    const missingGroup = await updateRule(
      { groupId: 'group-a', id: 'rule-1', value: 'example.com' },
      {
        getGroupById: () => Promise.resolve(null),
        getRuleById: () => Promise.resolve(createRuleRecord()),
        publishWhitelistChanged: () => undefined,
        updateRule: () => Promise.resolve(createRuleRecord()),
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(missingGroup, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Group not found' },
    });

    const missingRule = await updateRule(
      { groupId: 'group-a', id: 'rule-1', value: 'example.com' },
      {
        getGroupById: () => Promise.resolve(createGroup({ id: 'group-a' })),
        getRuleById: () => Promise.resolve(null),
        publishWhitelistChanged: () => undefined,
        updateRule: () => Promise.resolve(createRuleRecord()),
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(missingRule, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Rule not found' },
    });

    const wrongGroup = await updateRule(
      { groupId: 'group-a', id: 'rule-1', value: 'example.com' },
      {
        getGroupById: () => Promise.resolve(createGroup({ id: 'group-a' })),
        getRuleById: () => Promise.resolve(createRuleRecord({ groupId: 'group-b' })),
        publishWhitelistChanged: () => undefined,
        updateRule: () => Promise.resolve(createRuleRecord()),
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(wrongGroup, {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Rule does not belong to this group' },
    });
  });

  await test('validates updated values before opening the transaction', async () => {
    let transactionOpened = false;
    const deps = {
      getGroupById: (): Promise<GroupWithCounts> => Promise.resolve(createGroup({ id: 'group-a' })),
      getRuleById: (): Promise<Rule> => Promise.resolve(createRuleRecord()),
      publishWhitelistChanged: (): void => undefined,
      updateRule: (): Promise<Rule> => Promise.resolve(createRuleRecord()),
      withTransaction: async <T>(callback: (tx: never) => Promise<T>): Promise<T> => {
        transactionOpened = true;
        return callback({} as never);
      },
    };

    assert.deepEqual(await updateRule({ groupId: 'group-a', id: 'rule-1', value: '   ' }, deps), {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Value cannot be empty' },
    });
    assert.equal(transactionOpened, false);

    assert.deepEqual(
      await updateRule({ groupId: 'group-a', id: 'rule-1', value: 'http://' }, deps),
      {
        ok: false,
        error: { code: 'BAD_REQUEST', message: 'Value cannot be empty' },
      }
    );
    assert.equal(transactionOpened, false);
  });

  await test('updates rules and only publishes when exported content changes', async () => {
    const publishedGroups: string[] = [];
    const updates: { comment?: string | null; id: string; value?: string }[] = [];

    const deps = {
      getGroupById: (): Promise<GroupWithCounts> => Promise.resolve(createGroup({ id: 'group-a' })),
      getRuleById: (): Promise<Rule> => Promise.resolve(createRuleRecord({ value: 'example.com' })),
      publishWhitelistChanged: (groupId: string): void => {
        publishedGroups.push(groupId);
      },
      updateRule: (input: StorageUpdateRuleInput): Promise<Rule> => {
        updates.push({
          id: input.id,
          ...(input.comment !== undefined ? { comment: input.comment } : {}),
          ...(input.value !== undefined ? { value: input.value } : {}),
        });
        return Promise.resolve({
          ...createRuleRecord(),
          ...(input.comment !== undefined ? { comment: input.comment } : {}),
          ...(input.value !== undefined ? { value: input.value } : {}),
        });
      },
      withTransaction: runWithFakeTx,
    };

    const commentOnly = await updateRule(
      { comment: 'new note', groupId: 'group-a', id: 'rule-1' },
      deps
    );
    assert.equal(commentOnly.ok, true);
    assert.deepEqual(publishedGroups, []);

    const changedValue = await updateRule(
      { groupId: 'group-a', id: 'rule-1', value: ' Changed.example.com ' },
      deps
    );
    assert.equal(changedValue.ok, true);
    assert.deepEqual(updates, [
      { comment: 'new note', id: 'rule-1' },
      { id: 'rule-1', value: 'changed.example.com' },
    ]);
    assert.deepEqual(publishedGroups, ['group-a']);
  });

  await test('maps null update results to duplicate conflicts', async () => {
    const result = await updateRule(
      { groupId: 'group-a', id: 'rule-1', value: 'duplicate.example.com' },
      {
        getGroupById: () => Promise.resolve(createGroup({ id: 'group-a' })),
        getRuleById: () => Promise.resolve(createRuleRecord()),
        publishWhitelistChanged: () => undefined,
        updateRule: () => Promise.resolve(null),
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'CONFLICT', message: 'A rule with this value already exists' },
    });
  });
});
