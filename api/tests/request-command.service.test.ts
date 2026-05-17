import assert from 'node:assert/strict';
import { test } from 'node:test';

import * as requestCommandService from '../src/services/request-command.service.js';
import { registerRequestApiLifecycle } from './request-api-test-harness.js';

registerRequestApiLifecycle();

void test('request-command service exports expected mutation entrypoints', () => {
  assert.equal(typeof requestCommandService.createRequest, 'function');
  assert.equal(typeof requestCommandService.approveRequest, 'function');
  assert.equal(typeof requestCommandService.deleteRequest, 'function');
});

void test('request-command service deletes existing requests and reports missing ids', async () => {
  const created = await requestCommandService.createRequest({
    domain: `delete-service-${Date.now().toString()}.example.com`,
    reason: 'Cover request command deletion',
    requesterEmail: 'student@example.test',
  });
  assert.equal(created.ok, true);
  assert.ok(created.ok ? created.data.id : '');

  const requestId = created.ok ? created.data.id : '';
  assert.deepEqual(await requestCommandService.deleteRequest(requestId), {
    ok: true,
    data: { success: true },
  });

  assert.deepEqual(await requestCommandService.deleteRequest(requestId), {
    ok: false,
    error: { code: 'NOT_FOUND', message: 'Request not found' },
  });
});
