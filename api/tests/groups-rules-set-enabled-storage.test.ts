// api/tests/groups-rules-set-enabled-storage.test.ts
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { eq } from 'drizzle-orm';
import { db, whitelistGroups, whitelistRules } from '../src/db/index.js';
import { setRuleEnabled, bulkSetRulesEnabled } from '../src/lib/groups-storage-rules-mutation.js';

const GID = 'g-set-enabled';
before(async () => {
  await db
    .insert(whitelistGroups)
    .values({ id: GID, name: GID, displayName: GID })
    .onConflictDoNothing();
  await db
    .insert(whitelistRules)
    .values([
      {
        id: 'se-1',
        groupId: GID,
        type: 'whitelist',
        value: 'a.example.com',
        source: 'manual',
        enabled: 1,
      },
      {
        id: 'se-2',
        groupId: GID,
        type: 'whitelist',
        value: 'b.example.com',
        source: 'manual',
        enabled: 1,
      },
    ])
    .onConflictDoNothing();
});

test('setRuleEnabled disables a rule and returns it', async () => {
  const updated = await setRuleEnabled('se-1', false);
  assert.equal(updated?.enabled, false);
  const [row] = await db.select().from(whitelistRules).where(eq(whitelistRules.id, 'se-1'));
  assert.ok(row, 'expected row to exist');
  assert.equal(row.enabled, 0);
});

test('setRuleEnabled with non-existent id returns null', async () => {
  assert.equal(await setRuleEnabled('nope', false), null);
});

test('bulkSetRulesEnabled applies to multiple rules', async () => {
  const n = await bulkSetRulesEnabled(['se-1', 'se-2'], false);
  assert.equal(n, 2);
});
