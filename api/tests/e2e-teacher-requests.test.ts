import assert from 'node:assert/strict';
import { beforeEach, describe, test } from 'node:test';
import { and, eq } from 'drizzle-orm';

import { db, whitelistRules } from '../src/db/index.js';
import {
  parseTRPC,
  provisionTeacherScenario,
  registerTeacherE2ELifecycle,
  resetDb,
  trpcMutate,
  type RequestResult,
} from './e2e-teacher-test-harness.js';

registerTeacherE2ELifecycle();

await describe('E2E teacher request approval flow', { timeout: 75_000 }, async () => {
  beforeEach(async () => {
    await resetDb();
  });

  await test('teacher can approve a request created for the assigned group', async () => {
    const scenario = await provisionTeacherScenario();
    const rootDomain = `test-${Date.now().toString()}.org`;
    const exactHost = `es.${rootDomain}`;

    const createResponse = await trpcMutate('requests.create', {
      domain: exactHost,
      reason: 'I need this for homework',
      requesterEmail: 'student@test.com',
      groupId: scenario.teacherGroupId,
    });

    assert.equal(createResponse.status, 200);
    const createData = (await parseTRPC(createResponse)).data as RequestResult;
    assert.ok(createData.id);

    const approveResponse = await trpcMutate(
      'requests.approve',
      {
        id: createData.id,
        groupId: scenario.teacherGroupId,
        scope: 'host',
      },
      { Authorization: `Bearer ${scenario.teacherToken}` }
    );

    assert.equal(approveResponse.status, 200);

    const rules = await db
      .select({ value: whitelistRules.value })
      .from(whitelistRules)
      .where(
        and(
          eq(whitelistRules.groupId, scenario.teacherGroupId),
          eq(whitelistRules.type, 'whitelist')
        )
      );

    assert.deepEqual(
      rules.map((rule) => rule.value),
      [exactHost],
      'approval should whitelist only the exact host'
    );
  });
});
