import assert from 'node:assert/strict';
import test from 'node:test';

import { dbGroupToApi, dbGroupToMeta, dbRuleToApi } from '../src/lib/groups-storage-shared.js';

await test('groups-storage shared mappers normalize DB rows', () => {
  const now = new Date('2026-01-01T00:00:00.000Z');

  const group = dbGroupToApi({
    id: 'group-1',
    name: 'group-1',
    displayName: 'Group 1',
    enabled: 1,
    visibility: 'instance_public',
    ownerUserId: 'teacher-1',
    createdAt: now,
    updatedAt: now,
  });
  assert.equal(group.enabled, true);
  assert.equal(group.visibility, 'instance_public');
  assert.equal(group.ownerUserId, 'teacher-1');

  const meta = dbGroupToMeta({
    id: 'group-1',
    name: 'group-1',
    displayName: 'Group 1',
    enabled: 0,
    visibility: 'private',
    ownerUserId: null,
    createdAt: now,
    updatedAt: now,
  });
  assert.equal(meta.enabled, false);
  assert.equal(meta.visibility, 'private');

  const rule = dbRuleToApi({
    id: 'rule-1',
    groupId: 'group-1',
    type: 'whitelist',
    value: 'example.com',
    source: 'manual',
    enabled: 1,
    comment: null,
    createdAt: now,
  });
  assert.equal(rule.id, 'rule-1');
  assert.equal(rule.type, 'whitelist');
  assert.equal(rule.value, 'example.com');
  assert.equal(rule.enabled, true);
  assert.equal(rule.comment, null);
});
