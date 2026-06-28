import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { eq } from 'drizzle-orm';
import { db, whitelistGroups, whitelistRules } from '../src/db/index.js';
import { getRulesByGroup } from '../src/lib/groups-storage-rules-query.js';
import { dbRuleToApi } from '../src/lib/groups-storage-shared.js';

const GID = 'g-enabled-filter';

before(async () => {
  await db
    .insert(whitelistGroups)
    .values({ id: GID, name: GID, displayName: GID })
    .onConflictDoNothing();
  await db
    .insert(whitelistRules)
    .values([
      {
        id: 'r-on',
        groupId: GID,
        type: 'whitelist',
        value: 'on.example.com',
        source: 'manual',
        enabled: 1,
      },
      {
        id: 'r-off',
        groupId: GID,
        type: 'whitelist',
        value: 'off.example.com',
        source: 'manual',
        enabled: 0,
      },
    ])
    .onConflictDoNothing();
});

after(async () => {
  await db.delete(whitelistGroups).where(eq(whitelistGroups.id, GID));
});

void test('dbRuleToApi exposes enabled as boolean', () => {
  const result = dbRuleToApi({
    id: 'x',
    groupId: GID,
    type: 'whitelist',
    value: 'v',
    source: 'manual',
    enabled: 0,
    comment: null,
    createdAt: new Date(),
  } as never);
  assert.equal(result.enabled, false);
  const resultEnabled = dbRuleToApi({
    id: 'y',
    groupId: GID,
    type: 'whitelist',
    value: 'v2',
    source: 'manual',
    enabled: 1,
    comment: null,
    createdAt: new Date(),
  } as never);
  assert.equal(resultEnabled.enabled, true);
});

void test('getRulesByGroup filters by enabled', async () => {
  const onlyEnabled = await getRulesByGroup(GID, undefined, true);
  assert.deepEqual(onlyEnabled.map((r) => r.id).sort(), ['r-on']);

  const onlyDisabled = await getRulesByGroup(GID, undefined, false);
  assert.deepEqual(onlyDisabled.map((r) => r.id).sort(), ['r-off']);

  const all = await getRulesByGroup(GID);
  assert.equal(all.length, 2);
});
