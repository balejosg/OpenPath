import { describe, test } from 'node:test';
import assert from 'node:assert';

import { sql } from 'drizzle-orm';

import { getRows } from '../src/lib/utils.js';
import {
  db,
  getApiUrl,
  insertMachineAccessContext,
  registerRequestApiLifecycle,
} from './request-api-test-harness.js';

registerRequestApiLifecycle();

void describe('Request API tests - public submit routes', async () => {
  await test('POST /api/requests/auto is removed and returns 404', async () => {
    const res = await fetch(`${getApiUrl()}/api/requests/auto`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ domain: 'x.test', hostname: 'h', token: 't' }),
    });
    assert.equal(res.status, 404);
  });

  await describe('Submit Request Endpoint', async () => {
    await test('should create pending request in active classroom group', async () => {
      const suffix = `${Date.now().toString()}-submit-active`;
      const activeGroupId = `grp-active-${suffix}`;
      const defaultGroupId = `grp-default-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const domain = `manual.${suffix}.test`;
      const token = `machine-token-${suffix}`;

      await insertMachineAccessContext({
        activeGroupId,
        classroomId,
        defaultGroupId,
        hostname,
        machineId,
        token,
      });

      const response = await fetch(`${getApiUrl()}/api/requests/submit`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          reason: 'Manual submit from extension',
          token,
          hostname,
          origin_host: `${classroomId}.school.local`,
          client_version: '2.0.0-test',
        }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        groupId: string;
        id: string;
        source: string;
        status: string;
        success: boolean;
      };

      assert.strictEqual(data.success, true);
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.groupId, activeGroupId);
      assert.strictEqual(data.source, 'firefox-extension');

      const rows = getRows<{
        group_id: string;
        machine_hostname: string;
        origin_host: string;
        source: string;
        status: string;
      }>(
        await db.execute(
          sql.raw(
            `SELECT status, group_id, source, machine_hostname, origin_host FROM requests WHERE id='${data.id}' LIMIT 1`
          )
        )
      );

      assert.strictEqual(rows.length, 1);
      const firstRow = rows[0];
      assert.ok(firstRow);
      assert.strictEqual(firstRow.status, 'pending');
      assert.strictEqual(firstRow.group_id, activeGroupId);
      assert.strictEqual(firstRow.source, 'firefox-extension');
      assert.strictEqual(firstRow.machine_hostname, hostname);
      assert.strictEqual(firstRow.origin_host, `${classroomId}.school.local`);
    });

    await test('should fallback to default group when no active group is set', async () => {
      const suffix = `${Date.now().toString()}-submit-default`;
      const defaultGroupId = `grp-default-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const domain = `manual-default.${suffix}.test`;
      const token = `machine-token-${suffix}`;

      await insertMachineAccessContext({
        activeGroupId: null,
        classroomId,
        defaultGroupId,
        hostname,
        machineId,
        token,
      });

      const response = await fetch(`${getApiUrl()}/api/requests/submit`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          reason: 'Manual submit fallback default',
          token,
          hostname,
        }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        groupId: string;
        id: string;
        status: string;
        success: boolean;
      };

      assert.strictEqual(data.success, true);
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.groupId, defaultGroupId);

      const rows = getRows<{ group_id: string }>(
        await db.execute(sql.raw(`SELECT group_id FROM requests WHERE id='${data.id}' LIMIT 1`))
      );
      assert.strictEqual(rows.length, 1);
      const firstRow = rows[0];
      assert.ok(firstRow);
      assert.strictEqual(firstRow.group_id, defaultGroupId);
    });

    await test('should return 400 when the machine classroom is unrestricted because it has no group', async () => {
      const suffix = `${Date.now().toString()}-submit-no-group`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const token = `machine-token-${suffix}`;

      await insertMachineAccessContext({
        activeGroupId: null,
        classroomId,
        defaultGroupId: null,
        hostname,
        machineId,
        token,
      });

      const response = await fetch(`${getApiUrl()}/api/requests/submit`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain: `submit-${suffix}.example.com`,
          reason: 'This classroom has no default or active group',
          token,
          hostname,
        }),
      });

      assert.strictEqual(response.status, 400);
      const data = (await response.json()) as {
        error?: string;
        success: boolean;
      };

      assert.strictEqual(data.success, false);
      assert.strictEqual(
        data.error,
        'Machine classroom is unrestricted and does not require access requests'
      );
    });

    await test('should map duplicate pending requests to HTTP 409', async () => {
      const suffix = `${Date.now().toString()}-submit-conflict`;
      const groupId = `grp-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const token = `machine-token-${suffix}`;
      const domain = `submit.${suffix}.test`;

      await insertMachineAccessContext({
        activeGroupId: groupId,
        classroomId,
        defaultGroupId: groupId,
        hostname,
        machineId,
        token,
      });

      const firstResponse = await fetch(`${getApiUrl()}/api/requests/submit`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          reason: 'First submit creates the pending request',
          token,
          hostname,
        }),
      });
      assert.strictEqual(firstResponse.status, 200);

      const duplicateResponse = await fetch(`${getApiUrl()}/api/requests/submit`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          reason: 'Second submit should surface the conflict',
          token,
          hostname,
        }),
      });

      assert.strictEqual(duplicateResponse.status, 409);
      const data = (await duplicateResponse.json()) as {
        error?: string;
        success: boolean;
      };

      assert.strictEqual(data.success, false);
      assert.match(data.error ?? '', /pending request exists/i);
    });
  });
});
