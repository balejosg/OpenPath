import { before, describe, test } from 'node:test';
import assert from 'node:assert';

import { registerSecurityLifecycle, request } from './security-test-harness.js';
import { getHostReports } from '../src/lib/health-reports.js';
import { db } from '../src/db/index.js';
import { machines } from '../src/db/schema.js';
import { generateMachineToken, hashMachineToken } from '../src/lib/machine-download-token.js';

registerSecurityLifecycle();

void describe('Security tests - privacy boundaries and public rate limits', () => {
  let machineToken = '';
  let machineHostname = '';

  before(async () => {
    // Provision a machine row directly so we can submit health reports with a
    // valid machine token. The security harness resets the DB before each run,
    // so we insert the row after the harness is up (inside the describe-scoped
    // before hook, which runs after the outer module-level before).
    const cleartext = generateMachineToken();
    const tokenHash = hashMachineToken(cleartext);
    const hostname = `sec-privacy-host-${Date.now().toString()}`;

    await db.insert(machines).values({
      id: `sec-priv-machine-${Date.now().toString()}`,
      hostname,
      downloadTokenHash: tokenHash,
    });

    machineToken = cleartext;
    machineHostname = hostname;
  });

  void test('accepts health reports with unrecognized fields but does not persist them (loose schema, allowlisted storage)', async () => {
    const { status, body } = await request('/trpc/healthReports.submit', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${machineToken}`,
      },
      body: JSON.stringify({
        hostname: machineHostname,
        status: 'OK',
        // Known valid fields
        dnsmasqRunning: true,
        dnsResolving: true,
        failCount: 0,
        actions: '',
        version: '9.9.9',
        // Unknown telemetry fields that must NOT be persisted (privacy boundary)
        browsingHistory: ['forbidden-site.com'],
        unknownTelemetryField: `leak-test-${Date.now().toString()}`,
      }),
    });

    // 1. Submission must succeed — the loose schema accepts unknown fields.
    assert.strictEqual(
      status,
      200,
      `health report submission should succeed, got ${String(status)}: ${JSON.stringify(body)}`
    );
    const resultData = (body as { result: { data: { success: boolean } } }).result.data;
    assert.strictEqual(resultData.success, true, 'response body should report success');

    // 2. The persisted record must NOT contain unknown fields.
    //    The router's stripUndefined allowlist is the privacy boundary — only
    //    schema-known fields reach storage.
    const hostData = await getHostReports(machineHostname);
    assert.ok(hostData !== null, 'stored host data should exist after submission');

    const latestReport = hostData.reports[0];
    assert.ok(latestReport !== undefined, 'at least one report should be stored');

    const reportKeys = Object.keys(latestReport);

    assert.ok(
      !reportKeys.includes('browsingHistory'),
      'browsingHistory must not be persisted (privacy boundary violated)'
    );
    assert.ok(
      !reportKeys.includes('unknownTelemetryField'),
      'unknownTelemetryField must not be persisted (privacy boundary violated)'
    );

    // Sanity-check: known fields are still present (storage is not empty/broken).
    assert.ok(reportKeys.includes('status'), 'status should be persisted');
    assert.ok(reportKeys.includes('version'), 'version should be persisted');
    assert.strictEqual(latestReport.version, '9.9.9', 'known version field should round-trip');
  });

  void test('rejects domain requests with unrecognized fields', async () => {
    const { body, status } = await request('/trpc/requests.create', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Forwarded-For': '198.51.100.25',
      },
      body: JSON.stringify({
        json: {
          domain: `privacy-test-${Date.now().toString()}.com`,
          reason: 'test',
          requesterEmail: 'user@test.local',
          fullUrl: 'https://example.com/private/path',
        },
      }),
    });

    assert.strictEqual(status, 400);
    const errorMessage = (body as { error: { message: string } }).error.message;
    assert.ok(errorMessage.includes('unrecognized_keys'));
  });

  void test('allows auto request bursts from subresource-heavy pages', async () => {
    const responses = await Promise.all(
      Array.from({ length: 6 }, () =>
        request('/api/requests/auto', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Forwarded-For': '198.51.100.80',
          },
          body: JSON.stringify({}),
        })
      )
    );

    assert.equal(
      responses.some((response) => response.status === 429),
      false
    );
  });

  void test('keeps the public manual request rate limit tight', async () => {
    const responses = await Promise.all(
      Array.from({ length: 6 }, () =>
        request('/api/requests/submit', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Forwarded-For': '198.51.100.81',
          },
          body: JSON.stringify({}),
        })
      )
    );

    const blocked = responses.filter((response) => response.status === 429);
    assert.ok(blocked.length > 0);
  });
});
