import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { eq, inArray, sql } from 'drizzle-orm';

import { db, requests, whitelistRules } from '../src/db/index.js';
import * as groupsStorage from '../src/lib/groups-storage.js';
import * as requestQueryService from '../src/services/request-query.service.js';
import type { JWTPayload } from '../src/lib/auth.js';
import { insertWhitelistGroup, registerRequestApiLifecycle } from './request-api-test-harness.js';

const RUN_ID = Math.random().toString(36).slice(2, 8);
const GROUP_ID = `rqbc-${RUN_ID}`;
const REQUEST_IDS = [`rqp-${RUN_ID}`, `rqa-${RUN_ID}`];

const adminUser: JWTPayload = {
  sub: 'request-query-admin',
  email: 'request-query-admin@example.test',
  name: 'Request Query Admin',
  roles: [{ role: 'admin', groupIds: [] }],
  type: 'access',
};

registerRequestApiLifecycle();

void describe('request-query block cause', () => {
  before(async () => {
    await insertWhitelistGroup(GROUP_ID);
    const blockedRule = await groupsStorage.createRule(
      GROUP_ID,
      'blocked_subdomain',
      'gemini.google.com',
      null
    );
    assert.equal(blockedRule.success, true);

    await db.insert(requests).values([
      {
        id: REQUEST_IDS[0] ?? '',
        domain: 'gemini.google.com',
        requesterEmail: 'student@example.test',
        groupId: GROUP_ID,
        status: 'pending',
      },
      {
        id: REQUEST_IDS[1] ?? '',
        domain: 'gemini.google.com',
        requesterEmail: 'student@example.test',
        groupId: GROUP_ID,
        status: 'approved',
      },
    ]);
  });

  after(async () => {
    await db.delete(requests).where(inArray(requests.id, REQUEST_IDS));
    await db.delete(whitelistRules).where(eq(whitelistRules.groupId, GROUP_ID));
    await db.execute(sql.raw(`DELETE FROM whitelist_groups WHERE id='${GROUP_ID}'`));
  });

  void test('listRequests attaches blockCause to pending only', async () => {
    const listed = await requestQueryService.listRequests(null, adminUser);
    const own = listed.filter((request) => request.groupId === GROUP_ID);
    const pending = own.find((request) => request.id === REQUEST_IDS[0]);
    const approved = own.find((request) => request.id === REQUEST_IDS[1]);

    assert.ok(pending);
    assert.deepEqual(pending.blockCause, {
      kind: 'blocked_by_rule',
      matchedRule: 'gemini.google.com',
    });

    assert.ok(approved);
    assert.equal(approved.blockCause, undefined);
  });

  void test('getRequest attaches blockCause to a pending request', async () => {
    const result = await requestQueryService.getRequest(REQUEST_IDS[0] ?? '', adminUser);

    assert.equal(result.ok, true);
    assert.deepEqual(result.data.blockCause, {
      kind: 'blocked_by_rule',
      matchedRule: 'gemini.google.com',
    });
  });
});
