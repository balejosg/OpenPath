import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';
import { eq } from 'drizzle-orm';

import { db, requests } from '../src/db/index.js';
import * as groupsStorage from '../src/lib/groups-storage.js';
import {
  approveWhitelistRequest,
  defaultWhitelistRuleCommandDependencies,
  type WhitelistRuleCommandDependencies,
} from '../src/services/whitelist-rule-command.service.js';
import type { BlockedDomainsTestHarness } from './blocked-domains-test-harness.js';
import { startBlockedDomainsTestHarness } from './blocked-domains-test-harness.js';
import { bearerAuth } from './test-utils.js';

let harness: BlockedDomainsTestHarness | undefined;
let sequence = 0;

function getHarness(): BlockedDomainsTestHarness {
  assert.ok(harness, 'Blocked domains harness should be initialized');
  return harness;
}

function uniqueHost(label: string): string {
  sequence += 1;
  return `${label}-${Date.now().toString()}-${String(sequence)}.example.com`;
}

function uniqueRoot(label: string): string {
  sequence += 1;
  return `${label}-${Date.now().toString()}-${String(sequence)}.example.com`;
}

async function addRule(
  groupId: string,
  type: 'whitelist' | 'blocked_subdomain',
  value: string
): Promise<void> {
  const result = await groupsStorage.createRule(groupId, type, value, null);
  assert.equal(result.success, true, `failed to create ${type} rule ${value}`);
}

async function ruleValues(
  groupId: string,
  type: 'whitelist' | 'blocked_subdomain'
): Promise<string[]> {
  const rules = await groupsStorage.getRulesByGroup(groupId, type);
  return rules.map((rule) => rule.value);
}

async function requestRow(id: string): Promise<{ status: string; resolutionNote: string }> {
  const [row] = await db
    .select({ status: requests.status, resolutionNote: requests.resolutionNote })
    .from(requests)
    .where(eq(requests.id, id))
    .limit(1);
  assert.ok(row, `request ${id} not found`);
  return { status: row.status ?? '', resolutionNote: row.resolutionNote ?? '' };
}

void describe('Blocked domains - approval matrix', () => {
  before(async () => {
    harness = await startBlockedDomainsTestHarness();
  });

  after(async () => {
    await harness?.close();
    harness = undefined;
  });

  void test('approve defaults to exact host', async (): Promise<void> => {
    const current = getHarness();
    const host = uniqueHost('exact-host');
    const requestId = await current.createPendingRequest({
      domain: host,
      groupId: current.teacherGroupId,
    });

    const response = await current.trpcMutate(
      'requests.approve',
      { id: requestId, groupId: current.teacherGroupId },
      bearerAuth(current.teacherToken)
    );

    assert.strictEqual(response.status, 200, await response.clone().text());
    const whitelist = await ruleValues(current.teacherGroupId, 'whitelist');
    assert.ok(whitelist.includes(host), 'exact host rule should be created');
    assert.ok(!whitelist.includes('example.com'), 'root rule must not be created');
  });

  void test('approve family scope whitelists the root', async (): Promise<void> => {
    const current = getHarness();
    const host = `es-${Date.now().toString()}.wikipedia.org`;
    const requestId = await current.createPendingRequest({
      domain: host,
      groupId: current.teacherGroupId,
    });

    const response = await current.trpcMutate(
      'requests.approve',
      { id: requestId, groupId: current.teacherGroupId, scope: 'family' },
      bearerAuth(current.teacherToken)
    );

    assert.strictEqual(response.status, 200, await response.clone().text());
    const whitelist = await ruleValues(current.teacherGroupId, 'whitelist');
    assert.ok(whitelist.includes('wikipedia.org'), 'root rule should be created');
    assert.ok(!whitelist.includes(host), 'exact host rule must not be created');
  });

  void test('teacher cannot approve a host blocked by a subdomain rule', async (): Promise<void> => {
    const current = getHarness();
    const host = uniqueHost('teacher-blocked');
    await addRule(current.teacherGroupId, 'blocked_subdomain', host);
    const requestId = await current.createPendingRequest({
      domain: host,
      groupId: current.teacherGroupId,
    });

    const response = await current.trpcMutate(
      'requests.approve',
      { id: requestId, groupId: current.teacherGroupId },
      bearerAuth(current.teacherToken)
    );

    assert.strictEqual(response.status, 403);
    const payload = (await response.json()) as { error?: { message?: string } };
    assert.match(payload.error?.message ?? '', new RegExp(host.replace(/\./g, '\\.')));
    assert.ok(!(await ruleValues(current.teacherGroupId, 'whitelist')).includes(host));
  });

  void test('admin approve without unblock is rejected with the matching rule', async (): Promise<void> => {
    const current = getHarness();
    const root = uniqueRoot('admin-needs-unblock');
    const host = `gemini.${root}`;
    const wildcard = `*.${root}`;
    await addRule(current.teacherGroupId, 'blocked_subdomain', wildcard);
    const requestId = await current.createPendingRequest({
      domain: host,
      groupId: current.teacherGroupId,
    });

    const response = await current.trpcMutate(
      'requests.approve',
      { id: requestId, groupId: current.teacherGroupId },
      bearerAuth(current.adminToken)
    );

    assert.strictEqual(response.status, 400);
    const payload = (await response.json()) as { error?: { message?: string } };
    assert.match(payload.error?.message ?? '', /\*\./);
    assert.ok((await ruleValues(current.teacherGroupId, 'blocked_subdomain')).includes(wildcard));
    assert.ok(!(await ruleValues(current.teacherGroupId, 'whitelist')).includes(host));
  });

  void test('admin unblock removes exactly the matching rule atomically', async (): Promise<void> => {
    const current = getHarness();
    const root = uniqueRoot('admin-unblock');
    const host = `gemini.${root}`;
    const wildcard = `*.${root}`;
    const otherBlocked = `other-blocked-${Date.now().toString()}.example.net`;
    await addRule(current.teacherGroupId, 'blocked_subdomain', wildcard);
    await addRule(current.teacherGroupId, 'blocked_subdomain', otherBlocked);
    const requestId = await current.createPendingRequest({
      domain: host,
      groupId: current.teacherGroupId,
    });

    const response = await current.trpcMutate(
      'requests.approve',
      { id: requestId, groupId: current.teacherGroupId, unblock: true },
      bearerAuth(current.adminToken)
    );

    assert.strictEqual(response.status, 200, await response.clone().text());
    const blocked = await ruleValues(current.teacherGroupId, 'blocked_subdomain');
    assert.ok(!blocked.includes(wildcard), 'matching blocking rule should be removed');
    assert.ok(blocked.includes(otherBlocked), 'unrelated blocking rule must stay');

    const whitelist = await ruleValues(current.teacherGroupId, 'whitelist');
    assert.ok(whitelist.includes(host), 'exact host rule should be created');

    const row = await requestRow(requestId);
    assert.strictEqual(row.status, 'approved');
    assert.strictEqual(
      row.resolutionNote,
      `Added to ${current.teacherGroupName}; removed blocking rule ${wildcard}`
    );
  });

  void test('admin unblock rolls back if rule creation fails', async (): Promise<void> => {
    const current = getHarness();
    const root = uniqueRoot('admin-unblock-rollback');
    const host = `gemini.${root}`;
    const wildcard = `*.${root}`;
    await addRule(current.teacherGroupId, 'blocked_subdomain', wildcard);
    const requestId = await current.createPendingRequest({
      domain: host,
      groupId: current.teacherGroupId,
    });

    const failingDeps: WhitelistRuleCommandDependencies = {
      ...defaultWhitelistRuleCommandDependencies,
      createRule: () => Promise.reject(new Error('rule creation failed')),
    };

    await assert.rejects(() =>
      approveWhitelistRequest(
        {
          domain: host,
          requestId,
          resolvedBy: 'Blocked Domains Admin',
          targetGroup: { id: current.teacherGroupId, name: current.teacherGroupName },
          removeBlockedRule: wildcard,
        },
        failingDeps
      )
    );

    assert.ok(
      (await ruleValues(current.teacherGroupId, 'blocked_subdomain')).includes(wildcard),
      'blocked rule must survive the failed transaction'
    );
    assert.strictEqual((await requestRow(requestId)).status, 'pending');
  });

  void test('already allowed host approves without a redundant rule', async (): Promise<void> => {
    const current = getHarness();
    const root = `allowed-${Date.now().toString()}.example.org`;
    const host = `maps.${root}`;
    await addRule(current.teacherGroupId, 'whitelist', root);
    const requestId = await current.createPendingRequest({
      domain: host,
      groupId: current.teacherGroupId,
    });

    const response = await current.trpcMutate(
      'requests.approve',
      { id: requestId, groupId: current.teacherGroupId },
      bearerAuth(current.teacherToken)
    );

    assert.strictEqual(response.status, 200, await response.clone().text());
    const whitelist = await ruleValues(current.teacherGroupId, 'whitelist');
    assert.ok(!whitelist.includes(host), 'no redundant exact rule should be created');

    const row = await requestRow(requestId);
    assert.strictEqual(row.status, 'approved');
    assert.strictEqual(row.resolutionNote, `Already allowed by ${root}`);
  });
});
