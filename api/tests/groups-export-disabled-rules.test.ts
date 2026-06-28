// Tests that disabled rules are excluded from exportGroup output and that
// toggling a rule's enabled state busts the export cache / changes the ETag.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { sql } from 'drizzle-orm';
import { db, whitelistGroups, whitelistRules } from '../src/db/index.js';
import { exportGroup } from '../src/lib/groups-storage.js';
import { setRuleEnabled } from '../src/lib/groups-storage-rules-mutation.js';

const GID = 'g-export-disabled';

before(async () => {
  await db
    .insert(whitelistGroups)
    .values({ id: GID, name: GID, displayName: GID })
    .onConflictDoNothing();
  // Use upsert so repeated runs reset the enabled state to the fixture values.
  await db
    .insert(whitelistRules)
    .values([
      {
        id: 'ex-on',
        groupId: GID,
        type: 'whitelist',
        value: 'on.example.com',
        enabled: 1,
      },
      {
        id: 'ex-off',
        groupId: GID,
        type: 'whitelist',
        value: 'off.example.com',
        enabled: 0,
      },
    ])
    .onConflictDoUpdate({
      target: whitelistRules.id,
      set: { enabled: sql`excluded.enabled` },
    });
});

void test('exportGroup omits disabled rules', async () => {
  const out = (await exportGroup(GID)) ?? '';
  assert.match(out, /on\.example\.com/);
  assert.doesNotMatch(out, /off\.example\.com/);
});

void test('toggling enabled state busts the export cache', async () => {
  const first = (await exportGroup(GID)) ?? '';
  // The enabled rule should be present before the toggle
  assert.match(first, /on\.example\.com/);
  // Disable the only enabled rule
  await setRuleEnabled('ex-on', false);
  const second = (await exportGroup(GID)) ?? '';
  // After disabling, it must no longer appear in the export
  assert.doesNotMatch(second, /on\.example\.com/);
  // The two exports must differ, proving the cache was busted
  assert.notEqual(first, second);

  // Re-enable the rule and confirm the export reverts (cache busted again)
  await setRuleEnabled('ex-on', true);
  const third = (await exportGroup(GID)) ?? '';
  // The re-enabled rule must reappear
  assert.match(third, /on\.example\.com/);
  // The third export must differ from the disabled export (cache busted again)
  assert.notEqual(third, second);
});
