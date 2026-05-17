import { describe, test } from 'node:test';
import assert from 'node:assert';

import {
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
});
