import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, test } from 'node:test';
import { eq, sql } from 'drizzle-orm';

import { db, whitelistRules } from '../src/db/index.js';
import * as groupsStorage from '../src/lib/groups-storage.js';
import {
  findAllowingRule,
  findBlockingRules,
  getRequestBlockCause,
  getRequestBlockCauses,
} from '../src/lib/request-block-cause.js';
import { insertWhitelistGroup, registerRequestApiLifecycle } from './request-api-test-harness.js';

const GROUP_ID = `rbc-${Math.random().toString(36).slice(2, 8)}`;

registerRequestApiLifecycle();

async function addRule(type: 'whitelist' | 'blocked_subdomain', value: string): Promise<void> {
  const result = await groupsStorage.createRule(GROUP_ID, type, value, null);
  assert.equal(result.success, true, `failed to create ${type} rule ${value}`);
}

void describe('request block cause', () => {
  before(async () => {
    await insertWhitelistGroup(GROUP_ID);
  });

  beforeEach(async () => {
    await db.delete(whitelistRules).where(eq(whitelistRules.groupId, GROUP_ID));
  });

  after(async () => {
    await db.delete(whitelistRules).where(eq(whitelistRules.groupId, GROUP_ID));
    await db.execute(sql.raw(`DELETE FROM whitelist_groups WHERE id='${GROUP_ID}'`));
  });

  void test('reports an exact blocked_subdomain rule', async () => {
    await addRule('blocked_subdomain', 'gemini.google.com');

    assert.deepEqual(await getRequestBlockCause(GROUP_ID, 'gemini.google.com'), {
      kind: 'blocked_by_rule',
      matchedRule: 'gemini.google.com',
    });
  });

  void test('reports a wildcard blocked_subdomain rule', async () => {
    await addRule('blocked_subdomain', '*.google.com');

    assert.deepEqual(await getRequestBlockCause(GROUP_ID, 'gemini.google.com'), {
      kind: 'blocked_by_rule',
      matchedRule: '*.google.com',
    });
  });

  void test('reports the broadest of several overlapping blocked rules', async () => {
    await addRule('blocked_subdomain', 'gemini.google.com');
    await addRule('blocked_subdomain', 'google.com');
    await addRule('blocked_subdomain', '*.google.com');

    assert.deepEqual(await getRequestBlockCause(GROUP_ID, 'gemini.google.com'), {
      kind: 'blocked_by_rule',
      matchedRule: '*.google.com',
    });
    assert.deepEqual(await findBlockingRules(GROUP_ID, 'gemini.google.com'), [
      '*.google.com',
      'google.com',
      'gemini.google.com',
    ]);
  });

  void test('findBlockingRules skips sibling and disabled blocked rules', async () => {
    await addRule('blocked_subdomain', 'bard.google.com');
    const disabled = await groupsStorage.createRule(
      GROUP_ID,
      'blocked_subdomain',
      '*.google.com',
      null
    );
    assert.ok(disabled.id);
    await groupsStorage.setRuleEnabled(disabled.id, false);

    assert.deepEqual(await findBlockingRules(GROUP_ID, 'gemini.google.com'), []);
  });

  void test('reports already_allowed when a whitelist ancestor covers the host', async () => {
    await addRule('whitelist', 'google.com');

    assert.deepEqual(await getRequestBlockCause(GROUP_ID, 'maps.google.com'), {
      kind: 'already_allowed',
      matchedRule: 'google.com',
    });
  });

  void test('blocking wins over an allowed ancestor', async () => {
    await addRule('whitelist', 'google.com');
    await addRule('blocked_subdomain', 'gemini.google.com');

    assert.deepEqual(await getRequestBlockCause(GROUP_ID, 'gemini.google.com'), {
      kind: 'blocked_by_rule',
      matchedRule: 'gemini.google.com',
    });
  });

  void test('ignores disabled rules', async () => {
    const blocked = await groupsStorage.createRule(
      GROUP_ID,
      'blocked_subdomain',
      'gemini.google.com',
      null
    );
    const allowed = await groupsStorage.createRule(GROUP_ID, 'whitelist', 'google.com', null);
    assert.ok(blocked.id && allowed.id);
    await groupsStorage.setRuleEnabled(blocked.id, false);
    await groupsStorage.setRuleEnabled(allowed.id, false);

    assert.deepEqual(await getRequestBlockCause(GROUP_ID, 'gemini.google.com'), {
      kind: 'not_allowed',
    });
  });

  void test('findAllowingRule ignores blocking rules and disabled whitelist rules', async () => {
    await addRule('whitelist', 'google.com');
    await addRule('blocked_subdomain', 'gemini.google.com');
    assert.equal(await findAllowingRule(GROUP_ID, 'gemini.google.com'), 'google.com');
    assert.equal(await findAllowingRule(GROUP_ID, 'google.com'), 'google.com');
    assert.equal(await findAllowingRule(GROUP_ID, 'example.org'), null);

    const disabled = await groupsStorage.createRule(GROUP_ID, 'whitelist', 'example.org', null);
    assert.ok(disabled.id);
    await groupsStorage.setRuleEnabled(disabled.id, false);
    assert.equal(await findAllowingRule(GROUP_ID, 'example.org'), null);
  });

  void test('reports not_allowed without rules', async () => {
    assert.deepEqual(await getRequestBlockCause(GROUP_ID, 'foo.example.com'), {
      kind: 'not_allowed',
    });
  });

  void test('batch evaluation returns one cause per unique host', async () => {
    await addRule('blocked_subdomain', 'gemini.google.com');

    const causes = await getRequestBlockCauses([
      { groupId: GROUP_ID, domain: 'gemini.google.com' },
      { groupId: GROUP_ID, domain: 'gemini.google.com' },
      { groupId: GROUP_ID, domain: 'docs.google.com' },
    ]);

    assert.deepEqual(causes.get(`${GROUP_ID}\u0000gemini.google.com`), {
      kind: 'blocked_by_rule',
      matchedRule: 'gemini.google.com',
    });
    assert.deepEqual(causes.get(`${GROUP_ID}\u0000docs.google.com`), {
      kind: 'not_allowed',
    });
  });
});
