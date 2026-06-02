import { after, before, beforeEach, describe, test } from 'node:test';
import assert from 'node:assert';

import { CANONICAL_GROUP_IDS, createFixtureClassroom } from './fixtures.js';
import { db } from '../src/db/index.js';
import {
  createBlockedSubdomainRule,
  extractMachineToken,
  startTokenDeliveryHarness,
  type TokenDeliveryHarness,
} from './token-delivery-harness.js';
import { sql } from 'drizzle-orm';

let harness: TokenDeliveryHarness;

void describe('Token delivery core flows', { timeout: 30000 }, async () => {
  before(async () => {
    harness = await startTokenDeliveryHarness();
  });

  after(async () => {
    await harness.close();
  });

  await describe('POST /api/setup/validate-token', async () => {
    await test('should validate correct registration token', async () => {
      const response = await fetch(`${harness.apiUrl}/api/setup/validate-token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: harness.registrationToken }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as { valid: boolean };
      assert.strictEqual(data.valid, true);
    });

    await test('should reject invalid registration token', async () => {
      const response = await fetch(`${harness.apiUrl}/api/setup/validate-token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: 'invalid-token' }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as { valid: boolean };
      assert.strictEqual(data.valid, false);
    });

    await test('should return false for missing token', async () => {
      const response = await fetch(`${harness.apiUrl}/api/setup/validate-token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as { valid: boolean };
      assert.strictEqual(data.valid, false);
    });
  });

  await describe('POST /api/machines/register', async () => {
    beforeEach(async () => {
      await db.execute(sql.raw('DELETE FROM machines'));
    });

    await test('should register machine and return tokenized URL', async () => {
      await createFixtureClassroom({
        name: 'TestClassroom',
        groupId: CANONICAL_GROUP_IDS.testGroup,
      });

      const response = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${harness.registrationToken}`,
        },
        body: JSON.stringify({
          hostname: 'test-pc-001',
          classroomName: 'TestClassroom',
          version: '1.0.0',
        }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as { success: boolean; whitelistUrl: string };
      assert.strictEqual(data.success, true);
      assert.ok(data.whitelistUrl.includes('/w/'));
      assert.ok(data.whitelistUrl.includes('/whitelist.txt'));
    });

    await test('should reject without authorization header', async () => {
      const response = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          hostname: 'test-pc-001',
          classroomName: 'TestClassroom',
        }),
      });

      assert.strictEqual(response.status, 401);
    });

    await test('should reject invalid registration token', async () => {
      const response = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer invalid-token',
        },
        body: JSON.stringify({
          hostname: 'test-pc-001',
          classroomName: 'TestClassroom',
        }),
      });

      assert.strictEqual(response.status, 403);
    });

    await test('should reject missing hostname', async () => {
      const response = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${harness.registrationToken}`,
        },
        body: JSON.stringify({
          classroomName: 'TestClassroom',
        }),
      });

      assert.strictEqual(response.status, 400);
    });

    await test('should reject non-existent classroom', async () => {
      const response = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${harness.registrationToken}`,
        },
        body: JSON.stringify({
          hostname: 'test-pc-001',
          classroomName: 'NonExistentClassroom',
        }),
      });

      assert.strictEqual(response.status, 404);
    });
  });

  await describe('POST /api/machines/:hostname/rotate-download-token', async () => {
    let machineHostname = '';
    let machineToken = '';

    before(async () => {
      await createFixtureClassroom({ name: 'RotateTestClassroom', groupId: 'rotate-group' });

      const response = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${harness.registrationToken}`,
        },
        body: JSON.stringify({
          hostname: 'rotate-test-pc',
          classroomName: 'RotateTestClassroom',
        }),
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        machineHostname?: string;
        reportedHostname?: string;
        whitelistUrl?: string;
      };
      assert.ok(data.machineHostname);
      assert.strictEqual(data.reportedHostname, 'rotate-test-pc');
      assert.ok(data.whitelistUrl);
      machineHostname = data.machineHostname;
      machineToken = extractMachineToken(data.whitelistUrl);
    });

    await test('should rotate token and return new URL', async () => {
      const response = await fetch(
        `${harness.apiUrl}/api/machines/${machineHostname}/rotate-download-token`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${machineToken}`,
          },
        }
      );

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as { success: boolean; whitelistUrl: string };
      assert.strictEqual(data.success, true);
      assert.ok(data.whitelistUrl.includes('/w/'));
    });

    await test('should reject without authorization', async () => {
      const response = await fetch(
        `${harness.apiUrl}/api/machines/${machineHostname}/rotate-download-token`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
        }
      );

      assert.strictEqual(response.status, 401);
    });

    await test('should reject invalid machine token', async () => {
      const response = await fetch(
        `${harness.apiUrl}/api/machines/${machineHostname}/rotate-download-token`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: 'Bearer wrong-secret',
          },
        }
      );

      assert.strictEqual(response.status, 403);
    });

    await test('should reject hostname mismatches even with a valid machine token', async () => {
      const response = await fetch(
        `${harness.apiUrl}/api/machines/non-existent-pc/rotate-download-token`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${machineToken}`,
          },
        }
      );

      assert.strictEqual(response.status, 403);
    });
  });

  await describe('GET /w/:machineToken/whitelist.txt', async () => {
    let machineToken = '';

    before(async () => {
      await createFixtureClassroom({ name: 'WhitelistETagClassroom', groupId: 'etag-group' });

      const registerResponse = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${harness.registrationToken}`,
        },
        body: JSON.stringify({
          hostname: 'etag-test-pc-001',
          classroomName: 'WhitelistETagClassroom',
          version: '1.0.0',
        }),
      });
      assert.strictEqual(registerResponse.status, 200);
      const registerData = (await registerResponse.json()) as { whitelistUrl: string };
      machineToken = extractMachineToken(registerData.whitelistUrl);
    });

    await test('should return ETag and support 304 for valid token', async () => {
      const response = await fetch(`${harness.apiUrl}/w/${machineToken}/whitelist.txt`);
      assert.strictEqual(response.status, 200);

      const etag = response.headers.get('etag');
      assert.ok(etag);

      const notModified = await fetch(`${harness.apiUrl}/w/${machineToken}/whitelist.txt`, {
        headers: { 'If-None-Match': etag },
      });
      assert.strictEqual(notModified.status, 304);
      assert.strictEqual(await notModified.text(), '');
    });

    await test('should reflect blocked subdomain rule changes immediately for machine-token downloads', async () => {
      const initial = await fetch(`${harness.apiUrl}/w/${machineToken}/whitelist.txt`);
      assert.strictEqual(initial.status, 200);
      const initialEtag = initial.headers.get('etag');
      assert.ok(initialEtag);
      assert.ok(!(await initial.text()).includes('## BLOCKED-SUBDOMAINS'));

      await createBlockedSubdomainRule({
        apiUrl: harness.apiUrl,
        accessToken: await harness.loginAdmin(),
        groupId: 'etag-group',
        value: 'cdn.token-delivery.example.com',
        comment: 'Token delivery blocked-subdomain regression',
      });

      const updated = await fetch(`${harness.apiUrl}/w/${machineToken}/whitelist.txt`, {
        headers: { 'If-None-Match': initialEtag },
      });
      assert.strictEqual(updated.status, 200);

      const updatedEtag = updated.headers.get('etag');
      assert.ok(updatedEtag);
      assert.notStrictEqual(updatedEtag, initialEtag);

      const updatedBody = await updated.text();
      assert.ok(updatedBody.includes('## BLOCKED-SUBDOMAINS'));
      assert.ok(updatedBody.includes('cdn.token-delivery.example.com'));
    });

    await test('should not return 304 when direct rule writes change whitelist content without touching the group', async () => {
      const initial = await fetch(`${harness.apiUrl}/w/${machineToken}/whitelist.txt`);
      assert.strictEqual(initial.status, 200);
      const initialEtag = initial.headers.get('etag');
      assert.ok(initialEtag);
      const ruleId = `etag-direct-rule-${Date.now().toString()}`;
      const ruleValue = `${ruleId}.example.com`;

      await db.execute(
        sql.raw(`
          INSERT INTO whitelist_rules (id, group_id, type, value, source)
          VALUES ('${ruleId}', 'etag-group', 'whitelist', '${ruleValue}', 'manual')
          ON CONFLICT (group_id, type, value) DO NOTHING
        `)
      );

      const updated = await fetch(`${harness.apiUrl}/w/${machineToken}/whitelist.txt`, {
        headers: { 'If-None-Match': initialEtag },
      });
      assert.strictEqual(updated.status, 200);
      assert.notStrictEqual(updated.headers.get('etag'), initialEtag);

      const updatedBody = await updated.text();
      assert.ok(updatedBody.includes(ruleValue));
    });

    await test('should return fail-open for invalid token', async () => {
      const response = await fetch(`${harness.apiUrl}/w/invalid-token-here/whitelist.txt`);
      assert.strictEqual(response.status, 200);
      assert.ok((await response.text()).includes('#DESACTIVADO'));
    });

    await test('should return fail-open for missing token', async () => {
      const response = await fetch(`${harness.apiUrl}/w/whitelist.txt`);
      const text = await response.text();
      assert.ok(text.includes('#DESACTIVADO') || response.status !== 200);
    });
  });

  await describe('GET /api/machines/client-config', async () => {
    let machineToken = '';

    before(async () => {
      await createFixtureClassroom({
        name: 'ClientConfigClassroom',
        groupId: 'client-config-group',
        captivePortalDomains: ['nce.wedu.comunidad.madrid'],
      });

      const registerResponse = await fetch(`${harness.apiUrl}/api/machines/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${harness.registrationToken}`,
        },
        body: JSON.stringify({
          hostname: 'client-config-pc-001',
          classroomName: 'ClientConfigClassroom',
          version: '1.0.0',
        }),
      });
      assert.strictEqual(registerResponse.status, 200);
      const registerData = (await registerResponse.json()) as { whitelistUrl: string };
      machineToken = extractMachineToken(registerData.whitelistUrl);
    });

    await test('returns classroom captive portal domains for the machine token', async () => {
      const response = await fetch(`${harness.apiUrl}/api/machines/client-config`, {
        headers: { Authorization: `Bearer ${machineToken}` },
      });

      assert.strictEqual(response.status, 200);
      const data = (await response.json()) as {
        success?: boolean;
        captivePortalDomains?: string[];
      };
      assert.strictEqual(data.success, true);
      assert.deepStrictEqual(data.captivePortalDomains, ['nce.wedu.comunidad.madrid']);
    });
  });

  await describe('GET /export/:name.txt', async () => {
    before(async () => {
      await createFixtureClassroom({ name: 'ExportETagClassroom', groupId: 'etag-export-group' });

      await db.execute(
        sql.raw(`
        UPDATE whitelist_groups
        SET visibility = 'instance_public'
        WHERE name = 'etag-export-group'
      `)
      );
    });

    await test('should return ETag and support 304', async () => {
      const response = await fetch(`${harness.apiUrl}/export/etag-export-group.txt`);
      assert.strictEqual(response.status, 200);

      const etag = response.headers.get('etag');
      assert.ok(etag);

      const notModified = await fetch(`${harness.apiUrl}/export/etag-export-group.txt`, {
        headers: { 'If-None-Match': etag },
      });
      assert.strictEqual(notModified.status, 304);
      assert.strictEqual(await notModified.text(), '');
    });
  });
});
