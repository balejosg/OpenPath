import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import { startGroupsTestHarness, uniqueGroupName } from './groups-test-harness.js';
import { assertStatus, bearerAuth, parseTRPC } from './test-utils.js';

let harness: Awaited<ReturnType<typeof startGroupsTestHarness>> | undefined;

function getHarness(): Awaited<ReturnType<typeof startGroupsTestHarness>> {
  if (harness === undefined) {
    throw new Error('Expected groups test harness to be initialized');
  }
  return harness;
}

await describe('Groups Router - export flows', { timeout: 30000 }, async () => {
  before(async () => {
    harness = await startGroupsTestHarness();
  });

  after(async () => {
    if (harness !== undefined) {
      await harness.close();
    }
  });

  await describe('Export Operations', async () => {
    let exportGroupId = '';
    const exportGroupName = uniqueGroupName('export-test');

    before(async () => {
      exportGroupId = (
        await getHarness().createGroup({
          displayName: 'Export Test Group',
          name: exportGroupName,
        })
      ).id;

      await getHarness().trpcMutate(
        'groups.bulkCreateRules',
        {
          groupId: exportGroupId,
          type: 'whitelist',
          values: ['export-test-1.com', 'export-test-2.com'],
        },
        bearerAuth(getHarness().adminToken)
      );
    });

    await test('should export a group', async () => {
      const response = await getHarness().trpcQuery(
        'groups.export',
        { groupId: exportGroupId },
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: { name: string; content: string } };
      assert.ok(data);
      assert.ok(data.name);
      assert.ok(data.content.includes('export-test-1.com'));
      assert.ok(data.content.includes('export-test-2.com'));
    });

    await test('should export all groups', async () => {
      const response = await getHarness().trpcQuery(
        'groups.exportAll',
        undefined,
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as {
        data?: { name: string; content: string }[];
      };
      assert.ok(Array.isArray(data));
      assert.ok(data.length > 0);
      assert.ok(data.some((group) => group.name === exportGroupName));
    });

    await test('should return NOT_FOUND for non-existent group export', async () => {
      const response = await getHarness().trpcQuery(
        'groups.export',
        { groupId: 'non-existent' },
        bearerAuth(getHarness().adminToken)
      );
      assert.strictEqual(response.status, 404);
    });
  });

  await describe('REST Export Endpoint', async () => {
    let restGroupName = '';
    let restGroupId = '';
    let privateGroupName = '';

    before(async () => {
      const publicGroup = await getHarness().createGroup({
        displayName: 'REST Export Test Group',
        name: uniqueGroupName('rest-export'),
      });
      restGroupId = publicGroup.id;
      restGroupName = publicGroup.name;

      await getHarness().trpcMutate(
        'groups.bulkCreateRules',
        {
          groupId: restGroupId,
          type: 'whitelist',
          values: ['rest-domain-1.com', 'rest-domain-2.com'],
        },
        bearerAuth(getHarness().adminToken)
      );

      await getHarness().trpcMutate(
        'groups.update',
        {
          id: restGroupId,
          displayName: 'REST Export Test Group',
          enabled: true,
          visibility: 'instance_public',
        },
        bearerAuth(getHarness().adminToken)
      );

      const privateGroup = await getHarness().createGroup({
        displayName: 'REST Private Export Test Group',
        name: uniqueGroupName('rest-export-private'),
      });
      privateGroupName = privateGroup.name;

      await getHarness().trpcMutate(
        'groups.bulkCreateRules',
        {
          groupId: privateGroup.id,
          type: 'whitelist',
          values: ['rest-private-domain-1.com'],
        },
        bearerAuth(getHarness().adminToken)
      );
    });

    await test('should serve group export as plain text', async () => {
      const response = await fetch(`${getHarness().apiUrl}/export/${restGroupName}.txt`);
      assertStatus(response, 200);

      const contentType = response.headers.get('content-type');
      assert.ok(contentType?.includes('text/plain'));

      const content = await response.text();
      assert.ok(content.includes('rest-domain-1.com'));
      assert.ok(content.includes('rest-domain-2.com'));
    });

    await test('should return 404 for non-existent group', async () => {
      const response = await fetch(`${getHarness().apiUrl}/export/non-existent-group.txt`);
      assert.strictEqual(response.status, 404);
    });

    await test('should return empty content for disabled group', async () => {
      await getHarness().trpcMutate(
        'groups.update',
        {
          id: restGroupId,
          displayName: 'REST Export Test Group',
          enabled: false,
        },
        bearerAuth(getHarness().adminToken)
      );

      const response = await fetch(`${getHarness().apiUrl}/export/${restGroupName}.txt`);
      assertStatus(response, 200);

      const content = await response.text();
      const lines = content
        .split('\n')
        .filter((line) => line.trim() !== '' && !line.startsWith('#'));
      assert.strictEqual(lines.length, 0);

      await getHarness().trpcMutate(
        'groups.update',
        {
          id: restGroupId,
          displayName: 'REST Export Test Group',
          enabled: true,
        },
        bearerAuth(getHarness().adminToken)
      );
    });

    await test('should return 404 for private group', async () => {
      const response = await fetch(`${getHarness().apiUrl}/export/${privateGroupName}.txt`);
      assert.strictEqual(response.status, 404);
    });
  });

  await describe('ALLOWED-PATHS export section', async () => {
    let allowedPathGroupId = '';

    before(async () => {
      allowedPathGroupId = (
        await getHarness().createGroup({
          displayName: 'Allowed Path Export Test Group',
          name: uniqueGroupName('allowed-path-export'),
        })
      ).id;

      for (const rule of [
        { type: 'whitelist', value: 'youtube.com' },
        { type: 'blocked_path', value: 'example.com/ads' },
        { type: 'allowed_path', value: 'youtube.com/watch?v=abc' },
      ] as const) {
        await getHarness().trpcMutate(
          'groups.createRule',
          { groupId: allowedPathGroupId, type: rule.type, value: rule.value },
          bearerAuth(getHarness().adminToken)
        );
      }
    });

    // allowed_path rules must serialize into their own ## ALLOWED-PATHS section.
    await test('exportGroup emits ## ALLOWED-PATHS after ## BLOCKED-PATHS', async () => {
      const response = await getHarness().trpcQuery(
        'groups.export',
        { groupId: allowedPathGroupId },
        bearerAuth(getHarness().adminToken)
      );
      assertStatus(response, 200);

      const { data } = (await parseTRPC(response)) as { data?: { name: string; content: string } };
      const content = data?.content ?? '';
      assert.match(content, /## ALLOWED-PATHS\nyoutube\.com\/watch\?v=abc/);
      assert.ok(content.indexOf('## BLOCKED-PATHS') < content.indexOf('## ALLOWED-PATHS'));
    });
  });
});
