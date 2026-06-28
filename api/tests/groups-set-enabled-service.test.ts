import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { db, whitelistGroups, whitelistRules } from '../src/db/index.js';
import { GroupsService } from '../src/services/groups.service.js';

const GID = 'g-svc-enabled';
before(async () => {
  await db
    .insert(whitelistGroups)
    .values({ id: GID, name: GID, displayName: GID })
    .onConflictDoNothing();
  await db
    .insert(whitelistRules)
    .values({
      id: 'svc-1',
      groupId: GID,
      type: 'whitelist',
      value: 'a.example.com',
      enabled: 1,
    })
    .onConflictDoNothing();
});

void test('setRuleEnabled rejects rule from another group', async () => {
  const res = await GroupsService.setRuleEnabled({ id: 'svc-1', groupId: 'otro', enabled: false });
  assert.ok(!res.ok);
  assert.equal(res.error.code, 'BAD_REQUEST');
});

void test('setRuleEnabled disables a rule', async () => {
  const res = await GroupsService.setRuleEnabled({ id: 'svc-1', groupId: GID, enabled: false });
  assert.ok(res.ok);
  assert.equal(res.data.enabled, false);
});

void test('setRuleEnabled re-enables a rule', async () => {
  const res = await GroupsService.setRuleEnabled({ id: 'svc-1', groupId: GID, enabled: true });
  assert.ok(res.ok);
  assert.equal(res.data.enabled, true);
});

void test('listRules returns only disabled rules when enabled=false', async () => {
  await GroupsService.setRuleEnabled({ id: 'svc-1', groupId: GID, enabled: false });
  const res = await GroupsService.listRules(GID, undefined, false);
  assert.ok(res.ok);
  assert.equal(
    res.data.some((r) => r.id === 'svc-1'),
    true
  );
});
