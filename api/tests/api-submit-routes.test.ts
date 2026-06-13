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
  await describe('Auto Request Endpoint', async () => {
    await test('should create a pending request to the active group and mark source', async () => {
      const suffix = Date.now().toString();
      const groupId = `grp-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const domain = `ajax-${suffix}.example.com`;
      const reason = 'auto-allow ajax (xmlhttprequest)';
      const token = `machine-token-${suffix}`;

      await db.execute(
        sql.raw(
          "ALTER TABLE whitelist_rules ADD COLUMN IF NOT EXISTS source varchar(50) DEFAULT 'manual' NOT NULL"
        )
      );
      await insertMachineAccessContext({
        activeGroupId: groupId,
        classroomId,
        defaultGroupId: groupId,
        hostname,
        machineId,
        token,
      });

      const response = await fetch(`${getApiUrl()}/api/requests/auto`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          hostname,
          token,
          origin_page: `${classroomId}.school.local`,
          reason,
        }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        approved: boolean;
        autoApproved: boolean;
        groupId: string;
        id: string;
        source: string;
        status: string;
        success: boolean;
      };

      assert.strictEqual(data.success, true);
      assert.strictEqual(data.approved, false);
      assert.strictEqual(data.autoApproved, false);
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.groupId, groupId);
      assert.strictEqual(data.source, 'auto_extension');

      const rows = getRows<{
        group_id: string;
        machine_hostname: string;
        origin_page: string;
        reason: string;
        source: string;
        status: string;
      }>(
        await db.execute(
          sql.raw(
            `SELECT status, group_id, source, machine_hostname, origin_page, reason FROM requests WHERE id='${data.id}' LIMIT 1`
          )
        )
      );
      assert.strictEqual(rows.length, 1);
      const firstRow = rows[0];
      assert.ok(firstRow);
      assert.strictEqual(firstRow.status, 'pending');
      assert.strictEqual(firstRow.group_id, groupId);
      assert.strictEqual(firstRow.source, 'auto_extension');
      assert.strictEqual(firstRow.machine_hostname, hostname);
      assert.strictEqual(firstRow.origin_page, `${classroomId}.school.local`);
      assert.ok(firstRow.reason.includes(reason));

      assert.strictEqual(
        getRows(
          await db.execute(
            sql.raw(
              `SELECT id FROM whitelist_rules WHERE group_id='${groupId}' AND value='${domain}'`
            )
          )
        ).length,
        0
      );

      const duplicateResponse = await fetch(`${getApiUrl()}/api/requests/auto`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          hostname,
          token,
          origin_page: `${classroomId}.school.local`,
          reason,
        }),
      });

      assert.strictEqual(duplicateResponse.status, 409);
      const duplicateData = (await duplicateResponse.json()) as {
        error?: string;
        success: boolean;
      };
      assert.strictEqual(duplicateData.success, false);
      assert.match(duplicateData.error ?? '', /pending request exists/i);
    });

    await test('should NOT auto-approve an ajax target on a whitelisted origin when global auto-approval is off', async () => {
      const suffix = `${Date.now().toString()}-origin-allowed`;
      const groupId = `grp-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const originDomain = `lesson-${suffix}.example.com`;
      const domain = `api-${suffix}.example.net`;
      const token = `machine-token-${suffix}`;

      await insertMachineAccessContext({
        activeGroupId: groupId,
        classroomId,
        defaultGroupId: groupId,
        hostname,
        machineId,
        token,
      });
      await db.execute(
        sql.raw(
          `INSERT INTO whitelist_rules (id, group_id, type, value, source) VALUES ('rule-origin-${suffix}', '${groupId}', 'whitelist', '${originDomain}', 'manual')`
        )
      );

      const response = await fetch(`${getApiUrl()}/api/requests/auto`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          hostname,
          token,
          origin_page: `https://${originDomain}/lesson`,
          target_url: `https://${domain}/data.json`,
          reason: 'auto-allow ajax (fetch)',
        }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        approved: boolean;
        autoApproved: boolean;
        duplicate?: boolean;
        groupId: string;
        source: string;
        status: string;
        success: boolean;
      };

      // Security: a whitelisted origin must NOT auto-approve the target when
      // global machine auto-approval is off (attacker-controlled origin_page is
      // not a grant). The request becomes pending for human review.
      assert.strictEqual(data.success, true);
      assert.strictEqual(data.approved, false);
      assert.strictEqual(data.autoApproved, false);
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.groupId, groupId);

      // No whitelist rule is auto-created for the target...
      assert.strictEqual(
        getRows(
          await db.execute(
            sql.raw(
              `SELECT id FROM whitelist_rules WHERE group_id='${groupId}' AND type='whitelist' AND value='${domain}'`
            )
          )
        ).length,
        0
      );
      // ...and a pending request is recorded instead.
      assert.strictEqual(
        getRows(
          await db.execute(
            sql.raw(`SELECT id FROM requests WHERE domain='${domain}' AND group_id='${groupId}'`)
          )
        ).length,
        1
      );
    });

    await test('should NOT auto-approve a font target on a whitelisted origin when global auto-approval is off', async () => {
      const suffix = `${Date.now().toString()}-font-origin`;
      const groupId = `grp-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const originDomain = `reddit-${suffix}.example.com`;
      const domain = `fonts-${suffix}.gstatic.com`;
      const token = `machine-token-${suffix}`;

      await insertMachineAccessContext({
        activeGroupId: groupId,
        classroomId,
        defaultGroupId: groupId,
        hostname,
        machineId,
        token,
      });
      await db.execute(
        sql.raw(
          `INSERT INTO whitelist_rules (id, group_id, type, value, source) VALUES ('rule-origin-font-${suffix}', '${groupId}', 'whitelist', '${originDomain}', 'manual')`
        )
      );

      const response = await fetch(`${getApiUrl()}/api/requests/auto`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          hostname,
          token,
          origin_page: `https://${originDomain}/r/openpath`,
          target_url: `https://${domain}/s/inter/v12/font.woff2`,
          reason: 'auto-allow page-resource (font)',
          diagnostic_context: {
            correlation_id: `corr-${suffix}`,
            probe_id: 'font-subresource',
            request_type: 'font',
            target_hostname: domain,
          },
        }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        approved: boolean;
        autoApproved: boolean;
        duplicate?: boolean;
        groupId: string;
        source: string;
        status: string;
        success: boolean;
      };

      // Security: same as ajax — a whitelisted top-level origin does not
      // auto-approve a font subresource target while global auto-approval is off.
      assert.strictEqual(data.success, true);
      assert.strictEqual(data.approved, false);
      assert.strictEqual(data.autoApproved, false);
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.groupId, groupId);

      // No whitelist rule is auto-created for the target...
      assert.strictEqual(
        getRows(
          await db.execute(
            sql.raw(
              `SELECT id FROM whitelist_rules WHERE group_id='${groupId}' AND type='whitelist' AND value='${domain}'`
            )
          )
        ).length,
        0
      );
      // ...and a pending request is recorded instead.
      assert.strictEqual(
        getRows(
          await db.execute(
            sql.raw(`SELECT id FROM requests WHERE domain='${domain}' AND group_id='${groupId}'`)
          )
        ).length,
        1
      );
    });

    await test('should reject ajax auto-allow when the target matches a blocked subdomain rule', async () => {
      const suffix = `${Date.now().toString()}-blocked-sub`;
      const groupId = `grp-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const originDomain = `lesson-${suffix}.example.com`;
      const blockedBaseDomain = `blocked-${suffix}.example.net`;
      const domain = `api.${blockedBaseDomain}`;
      const token = `machine-token-${suffix}`;

      await insertMachineAccessContext({
        activeGroupId: groupId,
        classroomId,
        defaultGroupId: groupId,
        hostname,
        machineId,
        token,
      });
      await db.execute(
        sql.raw(
          `INSERT INTO whitelist_rules (id, group_id, type, value, source) VALUES ('rule-origin-${suffix}', '${groupId}', 'whitelist', '${originDomain}', 'manual')`
        )
      );
      await db.execute(
        sql.raw(
          `INSERT INTO whitelist_rules (id, group_id, type, value, source) VALUES ('rule-blocked-${suffix}', '${groupId}', 'blocked_subdomain', '${blockedBaseDomain}', 'manual')`
        )
      );

      const response = await fetch(`${getApiUrl()}/api/requests/auto`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          hostname,
          token,
          origin_page: `https://${originDomain}/lesson`,
          target_url: `https://${domain}/data.json`,
          reason: 'auto-allow ajax (xmlhttprequest)',
        }),
      });

      assert.strictEqual(response.status, 403);
      const data = (await response.json()) as { error?: string; success: boolean };
      assert.strictEqual(data.success, false);
      assert.match(data.error ?? '', /blocked subdomain/i);
      assert.strictEqual(
        getRows(
          await db.execute(
            sql.raw(
              `SELECT id FROM whitelist_rules WHERE group_id='${groupId}' AND type='whitelist' AND value='${domain}'`
            )
          )
        ).length,
        0
      );
    });

    await test('should reject ajax auto-allow when the target URL matches a blocked path rule', async () => {
      const suffix = `${Date.now().toString()}-blocked-path`;
      const groupId = `grp-${suffix}`;
      const classroomId = `cls-${suffix}`;
      const machineId = `mach-${suffix}`;
      const hostname = `host-${suffix}`;
      const originDomain = `lesson-${suffix}.example.com`;
      const domain = `api-${suffix}.example.net`;
      const token = `machine-token-${suffix}`;

      await insertMachineAccessContext({
        activeGroupId: groupId,
        classroomId,
        defaultGroupId: groupId,
        hostname,
        machineId,
        token,
      });
      await db.execute(
        sql.raw(
          `INSERT INTO whitelist_rules (id, group_id, type, value, source) VALUES ('rule-origin-${suffix}', '${groupId}', 'whitelist', '${originDomain}', 'manual')`
        )
      );
      await db.execute(
        sql.raw(
          `INSERT INTO whitelist_rules (id, group_id, type, value, source) VALUES ('rule-path-${suffix}', '${groupId}', 'blocked_path', '${domain}/private', 'manual')`
        )
      );

      const response = await fetch(`${getApiUrl()}/api/requests/auto`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain,
          hostname,
          token,
          origin_page: `https://${originDomain}/lesson`,
          target_url: `https://${domain}/private/data.json`,
          reason: 'auto-allow ajax (fetch)',
        }),
      });

      assert.strictEqual(response.status, 403);
      const data = (await response.json()) as { error?: string; success: boolean };
      assert.strictEqual(data.success, false);
      assert.match(data.error ?? '', /blocked path/i);
      assert.strictEqual(
        getRows(
          await db.execute(
            sql.raw(
              `SELECT id FROM whitelist_rules WHERE group_id='${groupId}' AND type='whitelist' AND value='${domain}'`
            )
          )
        ).length,
        0
      );
    });
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
