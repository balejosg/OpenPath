import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import {
  type GroupStats,
  type Rule,
  type SystemStatus,
  startGroupsTestHarness,
  uniqueGroupName,
} from './groups-test-harness.js';
import { assertStatus, bearerAuth, parseTRPC, TEST_RUN_ID } from './test-utils.js';
import { createRule as createStoredRule } from '../src/lib/groups-storage.js';

let harness: Awaited<ReturnType<typeof startGroupsTestHarness>> | undefined;

function getHarness(): Awaited<ReturnType<typeof startGroupsTestHarness>> {
  if (harness === undefined) {
    throw new Error('Expected groups test harness to be initialized');
  }
  return harness;
}

await describe(
  'Groups Router - rules, bulk ops, clone and status',
  { timeout: 30000 },
  async () => {
    before(async () => {
      harness = await startGroupsTestHarness();
    });

    after(async () => {
      if (harness !== undefined) {
        await harness.close();
      }
    });

    await describe('Rule CRUD Operations', async () => {
      let ruleGroupId = '';
      let testRuleId = '';

      before(async () => {
        ruleGroupId = (
          await getHarness().createGroup({
            displayName: 'Rule Test Group',
            name: uniqueGroupName('rule-test'),
          })
        ).id;
      });

      await test('should list rules (initially empty)', async () => {
        const response = await getHarness().trpcQuery(
          'groups.listRules',
          { groupId: ruleGroupId },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(response, 200);

        const { data } = (await parseTRPC(response)) as { data?: Rule[] };
        assert.ok(Array.isArray(data));
        assert.strictEqual(data.length, 0);
      });

      await test('should create and list rules by type', async () => {
        const whitelistResp = await getHarness().trpcMutate(
          'groups.createRule',
          {
            groupId: ruleGroupId,
            type: 'whitelist',
            value: 'example.com',
            comment: 'Test whitelist entry',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(whitelistResp, 200);
        const { data: whitelistData } = (await parseTRPC(whitelistResp)) as {
          data?: { id: string };
        };
        testRuleId = whitelistData?.id ?? '';
        assert.ok(testRuleId);

        const blockedSubdomainResp = await getHarness().trpcMutate(
          'groups.createRule',
          {
            groupId: ruleGroupId,
            type: 'blocked_subdomain',
            value: 'ads.example.com',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(blockedSubdomainResp, 200);

        const blockedPathResp = await getHarness().trpcMutate(
          'groups.createRule',
          {
            groupId: ruleGroupId,
            type: 'blocked_path',
            value: '*/api/tracking',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(blockedPathResp, 200);

        const listResp = await getHarness().trpcQuery(
          'groups.listRules',
          { groupId: ruleGroupId },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(listResp, 200);
        const { data: allRules } = (await parseTRPC(listResp)) as { data?: Rule[] };
        assert.ok(Array.isArray(allRules));
        assert.strictEqual(allRules.length, 3);

        const whitelistOnlyResp = await getHarness().trpcQuery(
          'groups.listRules',
          {
            groupId: ruleGroupId,
            type: 'whitelist',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(whitelistOnlyResp, 200);

        const { data: whitelistRules } = (await parseTRPC(whitelistOnlyResp)) as { data?: Rule[] };
        assert.ok(Array.isArray(whitelistRules));
        assert.strictEqual(whitelistRules.length, 1);
        assert.strictEqual(whitelistRules[0]?.type, 'whitelist');
      });

      await test('should reject duplicate rule', async () => {
        const response = await getHarness().trpcMutate(
          'groups.createRule',
          {
            groupId: ruleGroupId,
            type: 'whitelist',
            value: 'example.com',
          },
          bearerAuth(getHarness().adminToken)
        );

        assert.strictEqual(response.status, 409);
      });

      await test('should delete a rule', async () => {
        const response = await getHarness().trpcMutate(
          'groups.deleteRule',
          { id: testRuleId },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(response, 200);

        const { data } = (await parseTRPC(response)) as { data?: { deleted: boolean } };
        assert.strictEqual(data?.deleted, true);
      });

      await test('should list, paginate, group, and revoke automatic approvals by source', async () => {
        const group = await getHarness().createGroup({
          displayName: 'Automatic Approval Rule Test Group',
          name: uniqueGroupName('auto-rule-test'),
        });

        const autoResult = await createStoredRule(
          group.id,
          'whitelist',
          'cdn.auto.example.com',
          'Automatically approved by extension',
          'auto_extension'
        );
        assert.strictEqual(autoResult.success, true);
        assert.ok(autoResult.id);

        const manualResult = await createStoredRule(
          group.id,
          'whitelist',
          'manual.example.com',
          null,
          'manual'
        );
        assert.strictEqual(manualResult.success, true);

        const listResp = await getHarness().trpcQuery(
          'groups.listRules',
          {
            groupId: group.id,
            type: 'whitelist',
            source: 'auto_extension',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(listResp, 200);
        const { data: autoRules } = (await parseTRPC(listResp)) as { data?: Rule[] };
        assert.ok(autoRules);
        assert.strictEqual(autoRules.length, 1);
        const autoRule = autoRules[0];
        assert.ok(autoRule);
        assert.strictEqual(autoRule.id, autoResult.id);
        assert.strictEqual(autoRule.source, 'auto_extension');

        const paginatedResp = await getHarness().trpcQuery(
          'groups.listRulesPaginated',
          {
            groupId: group.id,
            type: 'whitelist',
            source: 'auto_extension',
            limit: 20,
            offset: 0,
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(paginatedResp, 200);
        const { data: paginated } = (await parseTRPC(paginatedResp)) as {
          data?: { rules: Rule[]; total: number };
        };
        assert.ok(paginated);
        assert.strictEqual(paginated.total, 1);
        const paginatedRule = paginated.rules[0];
        assert.ok(paginatedRule);
        assert.strictEqual(paginatedRule.value, 'cdn.auto.example.com');

        const groupedResp = await getHarness().trpcQuery(
          'groups.listRulesGrouped',
          {
            groupId: group.id,
            type: 'whitelist',
            source: 'auto_extension',
            limit: 20,
            offset: 0,
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(groupedResp, 200);
        const { data: grouped } = (await parseTRPC(groupedResp)) as {
          data?: { groups: { root: string; rules: Rule[] }[]; totalRules: number };
        };
        assert.ok(grouped);
        assert.strictEqual(grouped.totalRules, 1);
        const groupedRuleGroup = grouped.groups[0];
        assert.ok(groupedRuleGroup);
        const groupedRule = groupedRuleGroup.rules[0];
        assert.ok(groupedRule);
        assert.strictEqual(groupedRule.source, 'auto_extension');

        const teacher = await getHarness().createTeacherSession([group.id]);
        const revokeResp = await getHarness().trpcMutate(
          'groups.revokeAutoApproval',
          {
            id: autoResult.id,
            groupId: group.id,
          },
          bearerAuth(teacher.accessToken)
        );
        assertStatus(revokeResp, 200);
        const { data: revokeData } = (await parseTRPC(revokeResp)) as {
          data?: { revoked: boolean; blockedRuleId: string | null };
        };
        assert.ok(revokeData);
        assert.strictEqual(revokeData.revoked, true);
        assert.ok(revokeData.blockedRuleId);

        const remainingAutoResp = await getHarness().trpcQuery(
          'groups.listRules',
          {
            groupId: group.id,
            type: 'whitelist',
            source: 'auto_extension',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(remainingAutoResp, 200);
        const { data: remainingAutoRules } = (await parseTRPC(remainingAutoResp)) as {
          data?: Rule[];
        };
        assert.deepStrictEqual(remainingAutoRules, []);

        const blockedResp = await getHarness().trpcQuery(
          'groups.listRules',
          {
            groupId: group.id,
            type: 'blocked_subdomain',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(blockedResp, 200);
        const { data: blockedRules } = (await parseTRPC(blockedResp)) as { data?: Rule[] };
        assert.ok(blockedRules);
        assert.strictEqual(blockedRules.length, 1);
        const blockedRule = blockedRules[0];
        assert.ok(blockedRule);
        assert.strictEqual(blockedRule.value, 'cdn.auto.example.com');
        assert.match(blockedRule.comment ?? '', /Revoked automatic approval by/);
      });
    });

    await describe('Bulk Rule Operations', async () => {
      let bulkGroupId = '';

      before(async () => {
        bulkGroupId = (
          await getHarness().createGroup({
            displayName: 'Bulk Test Group',
            name: uniqueGroupName('bulk-test'),
          })
        ).id;
      });

      await test('should bulk create rules and skip duplicates', async () => {
        const initialResp = await getHarness().trpcMutate(
          'groups.bulkCreateRules',
          {
            groupId: bulkGroupId,
            type: 'whitelist',
            values: ['google.com', 'github.com', 'stackoverflow.com', 'mozilla.org'],
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(initialResp, 200);
        const { data: initialData } = (await parseTRPC(initialResp)) as {
          data?: { count: number };
        };
        assert.strictEqual(initialData?.count, 4);

        const duplicateResp = await getHarness().trpcMutate(
          'groups.bulkCreateRules',
          {
            groupId: bulkGroupId,
            type: 'whitelist',
            values: ['google.com', 'newdomain.com', 'stackoverflow.com'],
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(duplicateResp, 200);
        const { data: duplicateData } = (await parseTRPC(duplicateResp)) as {
          data?: { count: number };
        };
        assert.strictEqual(duplicateData?.count, 1);
      });

      await test('should bulk delete rules (admin) and return ordered rules payload', async () => {
        const valueA = `bulk-delete-a-${TEST_RUN_ID}-${Math.random().toString(36).slice(2, 6)}.com`;
        const valueB = `bulk-delete-b-${TEST_RUN_ID}-${Math.random().toString(36).slice(2, 6)}.com`;

        const createAResp = await getHarness().trpcMutate(
          'groups.createRule',
          {
            groupId: bulkGroupId,
            type: 'whitelist',
            value: valueA,
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(createAResp, 200);
        const { data: createdA } = (await parseTRPC(createAResp)) as { data?: { id: string } };
        const idA = createdA?.id ?? '';
        assert.ok(idA);

        const createBResp = await getHarness().trpcMutate(
          'groups.createRule',
          {
            groupId: bulkGroupId,
            type: 'whitelist',
            value: valueB,
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(createBResp, 200);
        const { data: createdB } = (await parseTRPC(createBResp)) as { data?: { id: string } };
        const idB = createdB?.id ?? '';
        assert.ok(idB);

        const ids = [idB, '00000000-0000-0000-0000-000000000000', idA];
        const bulkResp = await getHarness().trpcMutate(
          'groups.bulkDeleteRules',
          { ids },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(bulkResp, 200);

        const { data } = (await parseTRPC(bulkResp)) as {
          data?: { deleted: number; rules: Rule[] };
        };
        assert.ok(data);
        assert.strictEqual(data.deleted, 2);
        assert.strictEqual(data.rules.length, 2);
        assert.strictEqual(data.rules[0]?.id, idB);
        assert.strictEqual(data.rules[1]?.id, idA);

        const listResp = await getHarness().trpcQuery(
          'groups.listRules',
          { groupId: bulkGroupId },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(listResp, 200);
        const { data: remainingRules } = (await parseTRPC(listResp)) as { data?: Rule[] };
        assert.ok(Array.isArray(remainingRules));
        assert.ok(!remainingRules.some((rule) => rule.id === idA));
        assert.ok(!remainingRules.some((rule) => rule.id === idB));
      });
    });

    await describe('Set Rule Enabled Operations', async () => {
      let setEnabledGroupId = '';
      let setEnabledRuleId = '';

      before(async () => {
        const activeHarness = getHarness();
        setEnabledGroupId = (
          await activeHarness.createGroup({
            displayName: 'Set Enabled Test Group',
            name: uniqueGroupName('set-enabled'),
          })
        ).id;

        const createResp = await activeHarness.trpcMutate(
          'groups.createRule',
          {
            groupId: setEnabledGroupId,
            type: 'whitelist',
            value: `set-enabled-${TEST_RUN_ID}-${Math.random().toString(36).slice(2, 6)}.com`,
          },
          bearerAuth(activeHarness.adminToken)
        );
        assertStatus(createResp, 200);
        const { data: createdRule } = (await parseTRPC(createResp)) as { data?: { id: string } };
        setEnabledRuleId = createdRule?.id ?? '';
        assert.ok(setEnabledRuleId);
      });

      await test('should disable and re-enable a single rule (admin)', async () => {
        const activeHarness = getHarness();

        // Disable the rule
        const disableResp = await activeHarness.trpcMutate(
          'groups.setRuleEnabled',
          { id: setEnabledRuleId, groupId: setEnabledGroupId, enabled: false },
          bearerAuth(activeHarness.adminToken)
        );
        assertStatus(disableResp, 200);
        const { data: disabledRule } = (await parseTRPC(disableResp)) as {
          data?: { id: string; enabled: boolean };
        };
        assert.ok(disabledRule);
        assert.strictEqual(disabledRule.enabled, false);

        // Re-enable the rule
        const enableResp = await activeHarness.trpcMutate(
          'groups.setRuleEnabled',
          { id: setEnabledRuleId, groupId: setEnabledGroupId, enabled: true },
          bearerAuth(activeHarness.adminToken)
        );
        assertStatus(enableResp, 200);
        const { data: enabledRule } = (await parseTRPC(enableResp)) as {
          data?: { id: string; enabled: boolean };
        };
        assert.ok(enabledRule);
        assert.strictEqual(enabledRule.enabled, true);
      });

      await test('should reject setRuleEnabled when groupId does not match rule owner', async () => {
        const activeHarness = getHarness();

        // Create a second group and use its ID with a rule from the first group
        const wrongGroupId = (
          await activeHarness.createGroup({
            displayName: 'Wrong Group',
            name: uniqueGroupName('wrong-group'),
          })
        ).id;

        const resp = await activeHarness.trpcMutate(
          'groups.setRuleEnabled',
          { id: setEnabledRuleId, groupId: wrongGroupId, enabled: false },
          bearerAuth(activeHarness.adminToken)
        );
        // The middleware assertCanAccessGroupId passes (admin has access to everything),
        // but the service rejects because the rule's groupId doesn't match
        assert.ok(resp.status === 400 || resp.status === 404);
      });

      await test('should bulk enable rules as admin (skips per-group preload)', async () => {
        const activeHarness = getHarness();

        // First disable the rule so we have something to enable
        await activeHarness.trpcMutate(
          'groups.setRuleEnabled',
          { id: setEnabledRuleId, groupId: setEnabledGroupId, enabled: false },
          bearerAuth(activeHarness.adminToken)
        );

        const bulkResp = await activeHarness.trpcMutate(
          'groups.bulkSetRulesEnabled',
          { ids: [setEnabledRuleId], enabled: true },
          bearerAuth(activeHarness.adminToken)
        );
        assertStatus(bulkResp, 200);
        const { data: bulkData } = (await parseTRPC(bulkResp)) as {
          data?: { updated: number };
        };
        assert.ok(bulkData);
        assert.ok(typeof bulkData.updated === 'number');
        assert.ok(bulkData.updated >= 0);
      });

      await test('should bulk enable rules as non-admin teacher (preloads getRulesByIds)', async () => {
        const activeHarness = getHarness();

        // Create a group and rule for the teacher
        const teacherGroupId = (
          await activeHarness.createGroup({
            displayName: 'Teacher Bulk Set Group',
            name: uniqueGroupName('teacher-bulk-set'),
          })
        ).id;

        const createRuleResp = await activeHarness.trpcMutate(
          'groups.createRule',
          {
            groupId: teacherGroupId,
            type: 'whitelist',
            value: `teacher-bulk-${TEST_RUN_ID}-${Math.random().toString(36).slice(2, 6)}.com`,
          },
          bearerAuth(activeHarness.adminToken)
        );
        assertStatus(createRuleResp, 200);
        const { data: teacherRule } = (await parseTRPC(createRuleResp)) as {
          data?: { id: string };
        };
        const teacherRuleId = teacherRule?.id ?? '';
        assert.ok(teacherRuleId);

        const teacher = await activeHarness.createTeacherSession([teacherGroupId]);

        const bulkResp = await activeHarness.trpcMutate(
          'groups.bulkSetRulesEnabled',
          { ids: [teacherRuleId], enabled: false },
          bearerAuth(teacher.accessToken)
        );
        assertStatus(bulkResp, 200);
        const { data: bulkData } = (await parseTRPC(bulkResp)) as {
          data?: { updated: number };
        };
        assert.ok(bulkData);
        assert.ok(typeof bulkData.updated === 'number');
      });

      await test('should reject bulkSetRulesEnabled when teacher targets an unauthorized group', async () => {
        const activeHarness = getHarness();

        // Create a group the teacher does NOT own, add a rule to it
        const unauthorizedGroupId = (
          await activeHarness.createGroup({
            displayName: 'Unauthorized Bulk Group',
            name: uniqueGroupName('unauth-bulk'),
          })
        ).id;

        const createRuleResp = await activeHarness.trpcMutate(
          'groups.createRule',
          {
            groupId: unauthorizedGroupId,
            type: 'whitelist',
            value: `unauth-${TEST_RUN_ID}-${Math.random().toString(36).slice(2, 6)}.com`,
          },
          bearerAuth(activeHarness.adminToken)
        );
        assertStatus(createRuleResp, 200);
        const { data: unauthorizedRule } = (await parseTRPC(createRuleResp)) as {
          data?: { id: string };
        };
        const unauthorizedRuleId = unauthorizedRule?.id ?? '';
        assert.ok(unauthorizedRuleId);

        // Create a teacher with access to a DIFFERENT group
        const ownedGroupId = (
          await activeHarness.createGroup({
            displayName: 'Teacher Owned Group For Unauth',
            name: uniqueGroupName('teacher-owned-unauth'),
          })
        ).id;
        const teacher = await activeHarness.createTeacherSession([ownedGroupId]);

        const bulkResp = await activeHarness.trpcMutate(
          'groups.bulkSetRulesEnabled',
          { ids: [unauthorizedRuleId], enabled: true },
          bearerAuth(teacher.accessToken)
        );
        assert.strictEqual(bulkResp.status, 403);
      });
    });

    await describe('Clone Operations', async () => {
      await test('should clone a group and copy its rules', async () => {
        const source = await getHarness().createGroup({
          displayName: 'Clone Source Group',
          name: uniqueGroupName('clone-source'),
        });

        const seedRulesResp = await getHarness().trpcMutate(
          'groups.bulkCreateRules',
          {
            groupId: source.id,
            type: 'whitelist',
            values: ['clone-source-a.example.com', 'clone-source-b.example.com'],
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(seedRulesResp, 200);

        const cloneResp = await getHarness().trpcMutate(
          'groups.clone',
          {
            sourceGroupId: source.id,
            name: uniqueGroupName('clone-copy'),
            displayName: 'Clone Copy Group',
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(cloneResp, 200);

        const { data: clonedGroup } = (await parseTRPC(cloneResp)) as {
          data?: { id: string; name: string };
        };
        const clonedGroupId = clonedGroup?.id ?? '';
        assert.ok(clonedGroupId);
        assert.notStrictEqual(clonedGroupId, source.id);

        const listClonedRulesResp = await getHarness().trpcQuery(
          'groups.listRules',
          { groupId: clonedGroupId },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(listClonedRulesResp, 200);

        const { data: clonedRules } = (await parseTRPC(listClonedRulesResp)) as { data?: Rule[] };
        assert.ok(Array.isArray(clonedRules));
        assert.strictEqual(clonedRules.length, 2);
        assert.ok(clonedRules.some((rule) => rule.value === 'clone-source-a.example.com'));
        assert.ok(clonedRules.some((rule) => rule.value === 'clone-source-b.example.com'));
        assert.ok(clonedRules.every((rule) => rule.groupId === clonedGroupId));
      });
    });

    await describe('Statistics and System Status', async () => {
      await test('should return group statistics', async () => {
        const response = await getHarness().trpcQuery(
          'groups.stats',
          undefined,
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(response, 200);

        const { data } = (await parseTRPC(response)) as { data?: GroupStats };
        assert.ok(data);
        assert.ok(typeof data.groupCount === 'number');
        assert.ok(typeof data.whitelistCount === 'number');
        assert.ok(typeof data.blockedCount === 'number');
      });

      await test('should return system status and toggle it', async () => {
        const statusResp = await getHarness().trpcQuery(
          'groups.systemStatus',
          undefined,
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(statusResp, 200);

        const { data: initialStatus } = (await parseTRPC(statusResp)) as { data?: SystemStatus };
        assert.ok(initialStatus);
        assert.ok(typeof initialStatus.enabled === 'boolean');
        assert.ok(typeof initialStatus.totalGroups === 'number');
        assert.ok(typeof initialStatus.activeGroups === 'number');
        assert.ok(typeof initialStatus.pausedGroups === 'number');

        const toggleResp = await getHarness().trpcMutate(
          'groups.toggleSystem',
          {
            enable: !initialStatus.enabled,
          },
          bearerAuth(getHarness().adminToken)
        );
        assertStatus(toggleResp, 200);

        const { data: toggledStatus } = (await parseTRPC(toggleResp)) as { data?: SystemStatus };
        assert.strictEqual(toggledStatus?.enabled, !initialStatus.enabled);

        await getHarness().trpcMutate(
          'groups.toggleSystem',
          {
            enable: initialStatus.enabled,
          },
          bearerAuth(getHarness().adminToken)
        );
      });
    });
  }
);
