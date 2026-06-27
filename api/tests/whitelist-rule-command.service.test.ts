import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import type { DbExecutor } from '../src/db/index.js';
import type { CreateRuleResult, Rule, RuleType } from '../src/lib/groups-storage.js';
import DomainEventsService from '../src/services/domain-events.service.js';
import {
  approveWhitelistRequest,
  bulkDeleteWhitelistRules,
  createAutomaticWhitelistRule,
  createManualWhitelistRule,
  revokeAutomaticWhitelistRule,
  type WhitelistRuleCommandDependencies,
} from '../src/services/whitelist-rule-command.service.js';
import type { StoredDomainRequest } from '../src/services/request-command-shared.js';

const tx = 'tx-1' as unknown as DbExecutor;

function createStoredRequest(overrides: Partial<StoredDomainRequest> = {}): StoredDomainRequest {
  return {
    clientVersion: null,
    createdAt: '',
    domain: 'cdn.example.com',
    errorType: null,
    groupId: 'group-a',
    id: 'request-1',
    machineHostname: null,
    originHost: null,
    originPage: null,
    reason: '',
    requesterEmail: '',
    resolutionNote: '',
    resolvedAt: null,
    resolvedBy: null,
    source: 'manual',
    status: 'approved',
    updatedAt: '',
    ...overrides,
  };
}

function createAutoRule(overrides: Partial<Rule> = {}): Rule {
  return {
    id: 'rule-auto-1',
    groupId: 'group-a',
    type: 'whitelist',
    value: 'cdn.example.com',
    source: 'auto_extension',
    enabled: true,
    comment: null,
    createdAt: '',
    ...overrides,
  };
}

function createDeps(
  overrides: Partial<WhitelistRuleCommandDependencies> = {},
  createRuleResult: CreateRuleResult = { success: true, id: 'rule-1' }
): {
  calls: string[];
  createdRules: {
    comment: string | null | undefined;
    groupId: string;
    source: string | undefined;
    tx: DbExecutor | undefined;
    type: RuleType;
    value: string;
  }[];
  deps: WhitelistRuleCommandDependencies;
} {
  const calls: string[] = [];
  const createdRules: {
    comment: string | null | undefined;
    groupId: string;
    source: string | undefined;
    tx: DbExecutor | undefined;
    type: RuleType;
    value: string;
  }[] = [];

  const deps: WhitelistRuleCommandDependencies = {
    bulkDeleteRules: () => {
      calls.push('delete:bulk');
      return Promise.resolve(0);
    },
    createTransactionalWriter: DomainEventsService.createTransactionalWriter,
    createRule: (groupId, type, value, comment, source, executor) => {
      calls.push(`create:${String(source)}:${type}`);
      createdRules.push({ groupId, type, value, comment, source, tx: executor });
      return Promise.resolve(createRuleResult);
    },
    deleteRule: (id) => {
      calls.push(`delete:${id}`);
      return Promise.resolve(true);
    },
    publishWhitelistChanged: (groupId) => {
      calls.push(`event:${groupId}`);
    },
    updateRequestStatus: (id, status, resolvedBy, note, options) => {
      calls.push(`request:${id}:${status}:${options?.expectedStatus ?? 'any'}`);
      return Promise.resolve(
        createStoredRequest({
          id,
          status,
          resolvedBy: resolvedBy ?? null,
          resolutionNote: note ?? '',
        })
      );
    },
    withTransaction: async (operation) => {
      calls.push('begin');
      const result = await operation(tx);
      calls.push('commit');
      return result;
    },
    ...overrides,
  };

  return { calls, createdRules, deps };
}

await describe('whitelist rule command service', async () => {
  await test('creates manual rules and publishes whitelist changes after commit', async () => {
    const { calls, createdRules, deps } = createDeps();

    const result = await createManualWhitelistRule(
      {
        comment: undefined,
        groupId: 'group-a',
        type: 'whitelist',
        value: 'cdn.example.com',
      },
      deps
    );

    assert.deepEqual(result, { success: true, id: 'rule-1' });
    assert.deepEqual(createdRules, [
      {
        comment: null,
        groupId: 'group-a',
        source: 'manual',
        tx,
        type: 'whitelist',
        value: 'cdn.example.com',
      },
    ]);
    assert.deepEqual(calls, ['begin', 'create:manual:whitelist', 'commit', 'event:group-a']);
  });

  await test('approves requests by creating the rule and updating status in one transaction', async () => {
    const { calls, createdRules, deps } = createDeps();

    const result = await approveWhitelistRequest(
      {
        domain: 'cdn.example.com',
        requestId: 'request-1',
        resolvedBy: 'teacher@example.com',
        targetGroup: { id: 'group-a', name: 'Science' },
      },
      deps
    );

    assert.equal(result.updated.status, 'approved');
    assert.equal(result.createdRule, true);
    assert.deepEqual(createdRules, [
      {
        comment: null,
        groupId: 'group-a',
        source: 'manual',
        tx,
        type: 'whitelist',
        value: 'cdn.example.com',
      },
    ]);
    assert.deepEqual(calls, [
      'begin',
      'create:manual:whitelist',
      'request:request-1:approved:pending',
      'commit',
      'event:group-a',
    ]);
  });

  await test('auto-approval creates auto-extension rules and returns approved outcome', async () => {
    const { calls, createdRules, deps } = createDeps();

    const result = await createAutomaticWhitelistRule(
      {
        diagnosticContext: 'xmlhttprequest',
        domain: 'cdn.example.com',
        groupId: 'group-a',
        originPage: 'https://teacher.school.example/dashboard',
        reason: 'ajax',
      },
      deps
    );

    assert.deepEqual(result, { duplicate: false, status: 'approved' });
    const createdRule = createdRules[0];
    assert.ok(createdRule);
    assert.equal(createdRule.source, 'auto_extension');
    assert.match(String(createdRule.comment), /diagnostic \(xmlhttprequest\)/);
    assert.deepEqual(calls, [
      'begin',
      'create:auto_extension:whitelist',
      'commit',
      'event:group-a',
    ]);
  });

  await test('duplicate auto-approval returns duplicate outcome without publishing', async () => {
    const { calls, deps } = createDeps({}, { success: false, error: 'Rule already exists' });

    const result = await createAutomaticWhitelistRule(
      {
        domain: 'cdn.example.com',
        groupId: 'group-a',
      },
      deps
    );

    assert.deepEqual(result, { duplicate: true, status: 'duplicate' });
    assert.deepEqual(calls, ['begin', 'create:auto_extension:whitelist', 'commit']);
  });

  await test('revokes automatic approvals by replacing them with blocked subdomain rules', async () => {
    const { calls, createdRules, deps } = createDeps();

    const result = await revokeAutomaticWhitelistRule(
      {
        resolvedBy: 'teacher@example.com',
        rule: createAutoRule(),
      },
      deps
    );

    assert.deepEqual(result, { blockedRuleId: 'rule-1', revoked: true });
    assert.deepEqual(createdRules, [
      {
        comment: 'Revoked automatic approval by teacher@example.com',
        groupId: 'group-a',
        source: 'manual',
        tx,
        type: 'blocked_subdomain',
        value: 'cdn.example.com',
      },
    ]);
    assert.deepEqual(calls, [
      'begin',
      'delete:rule-auto-1',
      'create:manual:blocked_subdomain',
      'commit',
      'event:group-a',
    ]);
  });

  await test('bulk deletion publishes each affected group after commit', async () => {
    const { calls, deps } = createDeps({
      bulkDeleteRules: (_ids, executor) => {
        calls.push(`delete:bulk:${executor === tx ? 'tx' : 'root'}`);
        return Promise.resolve(2);
      },
    });

    const result = await bulkDeleteWhitelistRules(
      {
        ids: ['rule-1', 'rule-2'],
        rules: [
          createAutoRule({ groupId: 'group-a', id: 'rule-1' }),
          createAutoRule({ groupId: 'group-b', id: 'rule-2' }),
        ],
      },
      deps
    );

    assert.deepEqual(result, { deleted: 2 });
    assert.deepEqual(calls, [
      'begin',
      'delete:bulk:tx',
      'commit',
      'event:group-a',
      'event:group-b',
    ]);
  });
});
