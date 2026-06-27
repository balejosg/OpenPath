// api/tests/db-schema-rules-enabled.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { whitelistRules } from '../src/db/schema.js';

void test('whitelist_rules tiene columna enabled con default 1 notNull', () => {
  const col = (whitelistRules as unknown as { enabled?: { notNull: boolean; hasDefault: boolean } })
    .enabled;
  assert.ok(col, 'la columna enabled debe existir');
  assert.equal(col.notNull, true);
  assert.equal(col.hasDefault, true);
});
