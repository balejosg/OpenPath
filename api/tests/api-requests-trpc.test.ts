import { describe, test } from 'node:test';
import assert from 'node:assert';

import {
  insertWhitelistGroup,
  parseTRPC,
  registerRequestApiLifecycle,
  trpcMutate,
  trpcQuery,
} from './request-api-test-harness.js';

registerRequestApiLifecycle();

void describe('Request API tests - tRPC request procedures', async () => {
  await describe('tRPC requests.create - Submit Domain Request', async () => {
    await test('should accept valid domain request', async () => {
      const rootDomain = `test-${Date.now().toString()}.test`;
      const response = await trpcMutate('requests.create', {
        domain: rootDomain,
        reason: 'Testing purposes',
        requesterEmail: 'test@example.com',
      });
      assert.strictEqual(response.status, 200);

      const { data } = (await parseTRPC(response)) as {
        data?: { id: string; status: string };
      };
      assert.ok(data);
      assert.ok(data.id !== '');
      assert.strictEqual(data.status, 'pending');
    });

    await test('normalizes subdomain requests to the root domain', async () => {
      const rootDomain = `wikipedia-${Date.now().toString()}.org`;
      const response = await trpcMutate('requests.create', {
        domain: `es.${rootDomain}`,
        reason: 'Testing root domain normalization',
        requesterEmail: 'test@example.com',
      });
      assert.strictEqual(response.status, 200);

      const { data } = (await parseTRPC(response)) as {
        data?: { domain: string; id: string; status: string };
      };
      assert.ok(data);
      assert.strictEqual(data.domain, rootDomain);
      assert.strictEqual(data.status, 'pending');
    });

    await test('should reject request without domain', async () => {
      const response = await trpcMutate('requests.create', {
        reason: 'Testing',
        requesterEmail: 'test@example.com',
      });
      assert.strictEqual(response.status, 400);
    });

    await test('should reject invalid domain format', async () => {
      const response = await trpcMutate('requests.create', {
        domain: 'not-a-valid-domain',
        reason: 'Testing',
      });
      assert.strictEqual(response.status, 400);
    });

    await test('should reject XSS attempts in domain names', async () => {
      const response = await trpcMutate('requests.create', {
        domain: '<script>alert("xss")</script>.com',
        reason: 'Testing',
      });
      assert.strictEqual(response.status, 400);
    });
  });

  await describe('tRPC requests.getStatus - Check Request Status', async () => {
    await test('should return 404 for non-existent request', async () => {
      const response = await trpcQuery('requests.getStatus', { id: 'nonexistent-id' });
      const { error } = await parseTRPC(response);
      assert.ok(error !== undefined || response.status === 404);
    });

    await test('should return status for existing request', async () => {
      const createResponse = await trpcMutate('requests.create', {
        domain: `status-test-${Date.now().toString()}.test`,
        reason: 'Testing status endpoint',
      });
      const { data: createData } = (await parseTRPC(createResponse)) as {
        data?: { id: string };
      };
      assert.ok(createData);

      const statusResponse = await trpcQuery('requests.getStatus', { id: createData.id });
      assert.strictEqual(statusResponse.status, 200);

      const { data: statusData } = (await parseTRPC(statusResponse)) as {
        data?: { domain: string; id: string; status: string };
      };
      assert.ok(statusData);
      assert.strictEqual(statusData.status, 'pending');
      assert.ok(statusData.id !== '');
    });
  });

  await describe('Input Sanitization', async () => {
    await test('should sanitize reason field', async () => {
      const response = await trpcMutate('requests.create', {
        domain: `sanitize-test-${Date.now().toString()}.test`,
        reason: '<script>alert("xss")</script>Normal reason',
      });

      assert.strictEqual(response.status, 200);
    });

    await test('should handle very long domain names', async () => {
      const response = await trpcMutate('requests.create', {
        domain: `${'a'.repeat(300)}.example.com`,
        reason: 'Testing long domain',
      });

      assert.strictEqual(response.status, 400);
    });

    await test('should handle special characters in email', async () => {
      const response = await trpcMutate('requests.create', {
        domain: `email-test-${Date.now().toString()}.test`,
        reason: 'Testing',
        requesterEmail: 'valid+tag@example.com',
      });

      assert.strictEqual(response.status, 200);
    });
  });

  await describe('tRPC requests.create - group scoping and source hardening', async () => {
    await test('same domain in two groups both create (no cross-tenant suppression)', async () => {
      const suffix = Date.now().toString();
      const groupA = `scope-a-${suffix}`;
      const groupB = `scope-b-${suffix}`;
      await insertWhitelistGroup(groupA);
      await insertWhitelistGroup(groupB);

      const domain = `cross-tenant-${suffix}.example.com`;

      const responseA = await trpcMutate('requests.create', {
        domain,
        reason: 'Group A request',
        requesterEmail: 'a@example.com',
        groupId: groupA,
      });
      assert.strictEqual(responseA.status, 200, 'first group request should succeed');
      const dataA = (await parseTRPC(responseA)).data as { id?: string; groupId?: string };
      assert.ok(dataA.id, 'group A request should return an id');

      // Same domain, different group: must NOT be suppressed by group A's pending request.
      const responseB = await trpcMutate('requests.create', {
        domain,
        reason: 'Group B request',
        requesterEmail: 'b@example.com',
        groupId: groupB,
      });
      assert.strictEqual(
        responseB.status,
        200,
        'second group request for the same domain must not be suppressed'
      );
      const dataB = (await parseTRPC(responseB)).data as { id?: string };
      assert.ok(dataB.id, 'group B request should return an id');
      assert.notStrictEqual(dataA.id, dataB.id, 'the two groups should get distinct requests');
    });

    await test('duplicate pending request within the same group still conflicts', async () => {
      const suffix = Date.now().toString();
      const group = `scope-dup-${suffix}`;
      await insertWhitelistGroup(group);
      const domain = `dup-within-group-${suffix}.example.com`;

      const first = await trpcMutate('requests.create', {
        domain,
        reason: 'first',
        requesterEmail: 'dup@example.com',
        groupId: group,
      });
      assert.strictEqual(first.status, 200, 'first request should succeed');

      const second = await trpcMutate('requests.create', {
        domain,
        reason: 'second',
        requesterEmail: 'dup@example.com',
        groupId: group,
      });
      const secondPayload = await parseTRPC(second);
      assert.ok(
        secondPayload.code === 'CONFLICT' || second.status === 409,
        `expected CONFLICT for duplicate within a group, got ${String(second.status)} ${String(secondPayload.code)}`
      );
    });

    await test('unknown groupId is rejected', async () => {
      const response = await trpcMutate('requests.create', {
        domain: `unknown-group-${Date.now().toString()}.example.com`,
        reason: 'poisoning attempt',
        requesterEmail: 'attacker@example.com',
        groupId: `definitely-not-a-real-group-${Date.now().toString()}`,
      });
      const payload = (await response.json()) as {
        error?: { data?: { code?: string }; message?: string };
      };
      assert.strictEqual(
        response.status,
        400,
        'an unknown groupId must be rejected before the request is created'
      );
      const error = payload.error;
      assert.ok(error, 'expected a tRPC error payload');
      assert.strictEqual(
        error.data?.code,
        'BAD_REQUEST',
        `expected BAD_REQUEST for unknown groupId, got ${String(error.data?.code)}`
      );
      assert.match(
        error.message ?? '',
        /does not exist/i,
        'rejection should explain the group does not exist'
      );
    });
  });
});
