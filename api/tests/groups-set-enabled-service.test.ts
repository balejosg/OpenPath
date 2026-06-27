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
      source: 'manual',
      enabled: 1,
    })
    .onConflictDoNothing();
});

test('setRuleEnabled rejects rule from another group', async () => {
  const res = await GroupsService.setRuleEnabled({ id: 'svc-1', groupId: 'otro', enabled: false });
  assert.equal(res.ok, false);
});

test('setRuleEnabled disables a rule', async () => {
  const res = await GroupsService.setRuleEnabled({ id: 'svc-1', groupId: GID, enabled: false });
  assert.equal(res.ok, true);
  assert.equal(res.ok && res.data.enabled, false);
});

test('listRules filters disabled rules', async () => {
  const res = await GroupsService.listRules(GID, undefined, undefined, false);
  assert.equal(res.ok && res.data.some((r) => r.id === 'svc-1'), true);
});
