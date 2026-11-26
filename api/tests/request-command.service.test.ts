import assert from 'node:assert/strict';
import { test } from 'node:test';

import * as requestCommandService from '../src/services/request-command.service.js';
import type { JWTPayload } from '../src/lib/auth.js';
import { registerRequestApiLifecycle } from './request-api-test-harness.js';

registerRequestApiLifecycle();

const adminUser: JWTPayload = {
  sub: 'request-command-admin',
  email: 'request-command-admin@example.test',
  name: 'Request Command Admin',
  roles: [{ role: 'admin', groupIds: [] }],
  type: 'access',
};

const userWithoutGroups: JWTPayload = {
  sub: 'request-command-user',
  email: 'request-command-user@example.test',
  name: 'Request Command User',
  roles: [],
  type: 'access',
};

void test('request-command service exports expected mutation entrypoints', () => {
  assert.equal(typeof requestCommandService.createRequest, 'function');
  assert.equal(typeof requestCommandService.approveRequest, 'function');
  assert.equal(typeof requestCommandService.deleteRequest, 'function');
});

void test('request-command service dedupes pending requests per normalized host', async () => {
  const suffix = Date.now().toString();
  const host = `gemini-${suffix}.google.com`;

  const first = await requestCommandService.createRequest({
    domain: `Gemini-${suffix}.Google.com.`,
    reason: 'Exact host request',
    requesterEmail: 'student@example.test',
  });
  assert.equal(first.ok, true);
  assert.equal(first.data.domain, host);

  const duplicate = await requestCommandService.createRequest({
    domain: host,
    reason: 'Duplicate exact host request',
    requesterEmail: 'student@example.test',
  });
  assert.equal(duplicate.ok, false);
  assert.equal(duplicate.error.code, 'CONFLICT');

  const otherHost = await requestCommandService.createRequest({
    domain: `docs-${suffix}.google.com`,
    reason: 'Different subdomain in the same group',
    requesterEmail: 'student@example.test',
  });
  assert.equal(otherHost.ok, true);
});

void test('request-command approveRequest covers permission and validation failures', async () => {
  const suffix = Date.now().toString();
  const created = await requestCommandService.createRequest({
    domain: `approve-errors-${suffix}.example.com`,
    reason: 'Approval error coverage',
    requesterEmail: 'student@example.test',
  });
  assert.equal(created.ok, true);
  const requestId = created.data.id;

  assert.deepEqual(
    await requestCommandService.approveRequest('missing-request', undefined, adminUser, {
      scope: 'host',
      unblock: false,
    }),
    { ok: false, error: { code: 'NOT_FOUND', message: 'Request not found' } }
  );

  assert.deepEqual(
    await requestCommandService.approveRequest(requestId, undefined, userWithoutGroups, {
      scope: 'host',
      unblock: false,
    }),
    {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'You do not have permission to approve for this group' },
    }
  );

  assert.deepEqual(
    await requestCommandService.approveRequest(requestId, `missing-group-${suffix}`, adminUser, {
      scope: 'host',
      unblock: false,
    }),
    { ok: false, error: { code: 'BAD_REQUEST', message: 'Target group does not exist' } }
  );

  const approved = await requestCommandService.approveRequest(requestId, undefined, adminUser, {
    scope: 'host',
    unblock: false,
  });
  assert.equal(approved.ok, true);

  assert.deepEqual(
    await requestCommandService.approveRequest(requestId, undefined, adminUser, {
      scope: 'host',
      unblock: false,
    }),
    { ok: false, error: { code: 'BAD_REQUEST', message: 'Request is already approved' } }
  );
});

void test('request-command service deletes existing requests and reports missing ids', async () => {
  const created = await requestCommandService.createRequest({
    domain: `delete-service-${Date.now().toString()}.example.com`,
    reason: 'Cover request command deletion',
    requesterEmail: 'student@example.test',
  });
  assert.equal(created.ok, true);
  assert.ok(created.data.id);

  const requestId = created.data.id;
  assert.deepEqual(await requestCommandService.deleteRequest(requestId), {
    ok: true,
    data: { success: true },
  });

  assert.deepEqual(await requestCommandService.deleteRequest(requestId), {
    ok: false,
    error: { code: 'NOT_FOUND', message: 'Request not found' },
  });
});
