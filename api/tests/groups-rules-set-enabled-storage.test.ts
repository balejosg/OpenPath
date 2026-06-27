// api/tests/groups-rules-set-enabled-storage.test.ts
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { eq, inArray } from 'drizzle-orm';
import { db, whitelistGroups, whitelistRules } from '../src/db/index.js';
import { setRuleEnabled, bulkSetRulesEnabled } from '../src/lib/groups-storage-rules-mutation.js';

const GID = 'g-set-enabled';
const GID2 = 'g-bulk-reenable';
before(async () => {
  await db
    .insert(whitelistGroups)
    .values([
      { id: GID, name: GID, displayName: GID },
      { id: GID2, name: GID2, displayName: GID2 },
    ])
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
      {
        id: 'se-bulk-1',
        groupId: GID2,
        type: 'whitelist',
        value: 'c.example.com',
        source: 'manual',
        enabled: 1,
      },
      {
        id: 'se-bulk-2',
        groupId: GID2,
        type: 'whitelist',
        value: 'd.example.com',
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

test('bulkSetRulesEnabled re-enables previously disabled rules', async () => {
  await bulkSetRulesEnabled(['se-bulk-1', 'se-bulk-2'], false);
  const n = await bulkSetRulesEnabled(['se-bulk-1', 'se-bulk-2'], true);
  assert.equal(n, 2);
  const rows = await db
    .select()
    .from(whitelistRules)
    .where(inArray(whitelistRules.id, ['se-bulk-1', 'se-bulk-2']));
  assert.equal(rows.length, 2);
  for (const row of rows) {
    assert.ok(row, 'expected row to exist');
    assert.equal(row.enabled, 1);
  }
});

test('bulkSetRulesEnabled with empty ids returns 0', async () => {
  const n = await bulkSetRulesEnabled([], true);
  assert.equal(n, 0);
});
