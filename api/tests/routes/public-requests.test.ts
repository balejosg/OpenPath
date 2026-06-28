import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';
import { createHash } from 'node:crypto';
import { sql } from 'drizzle-orm';
const { startHttpTestHarness } = await import('../http-test-harness.js');
const { loadConfig } = await import('../../src/config.js');
const { db } = await import('../../src/db/index.js');

let apiUrl: string;
let harness: Awaited<ReturnType<typeof startHttpTestHarness>> | undefined;

function hashMachineToken(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

await describe('public-requests routes', async () => {
  before(async () => {
    harness = await startHttpTestHarness({
      ensureSchema: true,
      loadApp: async () => {
        const express = (await import('express')).default;
        const { registerPublicRequestRoutes } = await import('../../src/routes/public-requests.js');
        const app = express();
        app.use(express.json());
        registerPublicRequestRoutes(app);
        return app;
      },
    });
    apiUrl = harness.apiUrl;
  });

  after(async () => {
    if (harness !== undefined) {
      await harness.close();
    }
  });

  await test('loadConfig disables machine auto-approval by default and only enables it explicitly', () => {
    const baseEnv = {
      NODE_ENV: 'test',
      JWT_SECRET: 'test-jwt-secret',
    };
    const defaultConfig = loadConfig(baseEnv);
    const enabledConfig = loadConfig({
      ...baseEnv,
      AUTO_APPROVE_MACHINE_REQUESTS: 'true',
    });
    const disabledConfig = loadConfig({
      ...baseEnv,
      AUTO_APPROVE_MACHINE_REQUESTS: 'false',
    });

    assert.strictEqual(defaultConfig.autoApproveMachineRequests, false);
    assert.strictEqual(enabledConfig.autoApproveMachineRequests, true);
    assert.strictEqual(disabledConfig.autoApproveMachineRequests, false);
  });

  await test('POST /api/requests/submit normalizes manual requests to root domain and exposes public status', async () => {
    const suffix = `${Date.now().toString()}-submit-root-domain`;
    const groupId = `grp-${suffix}`;
    const classroomId = `cls-${suffix}`;
    const machineId = `mach-${suffix}`;
    const hostname = `host-${suffix}`;
    const token = `machine-token-${suffix}`;

    await db.execute(sql.raw("DELETE FROM requests WHERE domain='wikipedia.org'"));

    await db.execute(
      sql.raw(
        `INSERT INTO whitelist_groups (id, name, display_name, enabled) VALUES ('${groupId}', '${groupId}', '${groupId}', 1)`
      )
    );
    await db.execute(
      sql.raw(
        `INSERT INTO classrooms (id, name, display_name, default_group_id, active_group_id) VALUES ('${classroomId}', '${classroomId}', '${classroomId}', '${groupId}', '${groupId}')`
      )
    );
    await db.execute(
      sql.raw(
        `INSERT INTO machines (id, hostname, classroom_id, version, download_token_hash) VALUES ('${machineId}', '${hostname}', '${classroomId}', 'test', '${hashMachineToken(token)}')`
      )
    );

    const response = await fetch(`${apiUrl}/api/requests/submit`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Connection: 'close',
      },
      body: JSON.stringify({
        domain: 'es.wikipedia.org',
        hostname,
        token,
      }),
    });

    assert.strictEqual(response.status, 200);
    const payload = (await response.json()) as {
      success: boolean;
      id?: string;
      domain?: string;
      status?: string;
    };
    assert.strictEqual(payload.success, true);
    assert.strictEqual(payload.domain, 'wikipedia.org');
    assert.strictEqual(payload.status, 'pending');
    assert.ok(payload.id);

    const statusResponse = await fetch(`${apiUrl}/api/requests/status/${payload.id}`, {
      headers: { Connection: 'close' },
    });
    assert.strictEqual(statusResponse.status, 200);
    const statusPayload = (await statusResponse.json()) as {
      success: boolean;
      id?: string;
      domain?: string;
      status?: string;
    };
    assert.strictEqual(statusPayload.success, true);
    assert.strictEqual(statusPayload.id, payload.id);
    assert.strictEqual(statusPayload.domain, 'wikipedia.org');
    assert.strictEqual(statusPayload.status, 'pending');
  });

  await test('POST /api/requests/submit rejects requests with missing required fields', async () => {
    const response = await fetch(`${apiUrl}/api/requests/submit`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Connection: 'close',
      },
      body: JSON.stringify({
        hostname: 'missing-domain-host',
      }),
    });

    assert.strictEqual(response.status, 400);
    const payload = (await response.json()) as {
      success: boolean;
      error?: string;
    };

    assert.strictEqual(payload.success, false);
    assert.strictEqual(payload.error, 'domain, hostname and token are required');
  });

  await test('POST /api/requests/submit rejects invalid domains after machine proof succeeds', async () => {
    const suffix = `${Date.now().toString()}-submit-invalid-domain`;
    const groupId = `grp-${suffix}`;
    const classroomId = `cls-${suffix}`;
    const machineId = `mach-${suffix}`;
    const hostname = `host-${suffix}`;
    const token = `machine-token-${suffix}`;

    await db.execute(
      sql.raw(
        `INSERT INTO whitelist_groups (id, name, display_name, enabled) VALUES ('${groupId}', '${groupId}', '${groupId}', 1)`
      )
    );
    await db.execute(
      sql.raw(
        `INSERT INTO classrooms (id, name, display_name, default_group_id, active_group_id) VALUES ('${classroomId}', '${classroomId}', '${classroomId}', '${groupId}', '${groupId}')`
      )
    );
    await db.execute(
      sql.raw(
        `INSERT INTO machines (id, hostname, classroom_id, version, download_token_hash) VALUES ('${machineId}', '${hostname}', '${classroomId}', 'test', '${hashMachineToken(token)}')`
      )
    );

    const response = await fetch(`${apiUrl}/api/requests/submit`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Connection: 'close',
      },
      body: JSON.stringify({
        domain: 'http://not-a-valid-domain',
        hostname,
        token,
      }),
    });

    assert.strictEqual(response.status, 400);
    const payload = (await response.json()) as {
      success: boolean;
      error?: string;
    };

    assert.strictEqual(payload.success, false);
    assert.match(payload.error ?? '', /domain/i);
  });
});
