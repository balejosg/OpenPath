import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { eq } from 'drizzle-orm';
import { db, whitelistGroups, whitelistRules } from '../src/db/index.js';

const GID = 'g-enabled-column';

before(async () => {
  await db
    .insert(whitelistGroups)
    .values({ id: GID, name: GID, displayName: GID })
    .onConflictDoNothing();
});

after(async () => {
  // whitelist_rules cascades on group delete
  await db.delete(whitelistGroups).where(eq(whitelistGroups.id, GID));
});

test('whitelist_rules.enabled defaults to 1 when omitted', async () => {
  await db
    .insert(whitelistRules)
    .values({
      id: 'rule-default-enabled',
      groupId: GID,
      type: 'whitelist',
      value: 'default.example.com',
      source: 'manual',
    })
    .onConflictDoNothing();
  const [row] = await db
    .select()
    .from(whitelistRules)
    .where(eq(whitelistRules.id, 'rule-default-enabled'));
  assert.equal(row.enabled, 1);
});

test('whitelist_rules.enabled persists an explicit 0', async () => {
  await db
    .insert(whitelistRules)
    .values({
      id: 'rule-explicit-disabled',
      groupId: GID,
      type: 'whitelist',
      value: 'disabled.example.com',
      source: 'manual',
      enabled: 0,
    })
    .onConflictDoNothing();
  const [row] = await db
    .select()
    .from(whitelistRules)
    .where(eq(whitelistRules.id, 'rule-explicit-disabled'));
  assert.equal(row.enabled, 0);
});
