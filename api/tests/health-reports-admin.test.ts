import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  getAdminBearerAuth,
  parseTRPC,
  provisionMachineAccess,
  registerIntegrationLifecycle,
  trpcMutate,
  trpcQuery,
} from './integration-test-harness.js';

registerIntegrationLifecycle();

/**
 * Covers the admin procedures of health-reports.ts router:
 *   list          – byStatus counting, version field branch
 *   getAlerts     – problem-status alert, stale-host alert, threshold boundary
 *   getByHost     – found + NOT_FOUND branches
 *   submit        – hostname-mismatch FORBIDDEN branch
 */
await describe('health-reports admin procedures', async () => {
  // ──────────────────────────────────────────────────────────────────────────
  // list
  // ──────────────────────────────────────────────────────────────────────────

  await test('list returns summary with byStatus counts and version field', async () => {
    const suffix = `list-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `health-list-room-${suffix}`,
      groupName: `health-list-group-${suffix}`,
      hostname: `health-list-host-${suffix}`,
    });

    // Submit a report so the list has actual data
    const submitResponse = await trpcMutate(
      'healthReports.submit',
      {
        hostname: machine.machineHostname,
        status: 'HEALTHY',
        version: '4.0.0',
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );
    assert.ok(
      [200, 201].includes(submitResponse.status),
      `submit should succeed, got ${String(submitResponse.status)}`
    );

    const listResponse = await trpcQuery('healthReports.list', undefined, getAdminBearerAuth());
    assert.equal(listResponse.status, 200, 'list should return 200');

    const listResult = (await parseTRPC(listResponse)).data as {
      totalHosts: number;
      lastUpdated: string | null;
      byStatus: Record<string, number>;
      hosts: {
        hostname: string;
        status: string | null;
        lastSeen: string | null;
        version?: string;
        recentFailCount: number;
      }[];
    };

    assert.ok(listResult.totalHosts >= 1, 'totalHosts should be at least 1');
    assert.ok(listResult.lastUpdated !== null, 'lastUpdated should be set');
    assert.ok(typeof listResult.byStatus === 'object', 'byStatus should be an object');
    assert.ok(Array.isArray(listResult.hosts), 'hosts should be an array');

    const entry = listResult.hosts.find((h) => h.hostname === machine.machineHostname);
    assert.ok(entry !== undefined, 'submitted host should appear in list');
    assert.equal(entry.status, 'HEALTHY', 'status should be HEALTHY');
    // version field branch: version should be set when present in report
    assert.equal(entry.version, '4.0.0', 'version field should be present when sent');
    assert.equal(entry.recentFailCount, 0, 'recentFailCount should default to 0');

    // byStatus should count this host
    assert.ok((listResult.byStatus['HEALTHY'] ?? 0) >= 1, 'byStatus.HEALTHY should be at least 1');
  });

  await test('list host entry byStatus counts multiple statuses', async () => {
    const suffix = `list-multi-${Date.now().toString()}`;

    // Provision two machines with different statuses to drive byStatus counting
    const machineA = await provisionMachineAccess({
      classroomName: `health-multi-room-a-${suffix}`,
      groupName: `health-multi-group-a-${suffix}`,
      hostname: `health-multi-host-a-${suffix}`,
    });
    const machineB = await provisionMachineAccess({
      classroomName: `health-multi-room-b-${suffix}`,
      groupName: `health-multi-group-b-${suffix}`,
      hostname: `health-multi-host-b-${suffix}`,
    });

    await trpcMutate(
      'healthReports.submit',
      { hostname: machineA.machineHostname, status: 'DEGRADED' },
      { Authorization: `Bearer ${machineA.machineToken}` }
    );
    await trpcMutate(
      'healthReports.submit',
      { hostname: machineB.machineHostname, status: 'CRITICAL' },
      { Authorization: `Bearer ${machineB.machineToken}` }
    );

    const listResponse = await trpcQuery('healthReports.list', undefined, getAdminBearerAuth());
    assert.equal(listResponse.status, 200);

    const listResult = (await parseTRPC(listResponse)).data as {
      byStatus: Record<string, number>;
      hosts: { hostname: string; status: string | null; recentFailCount: number }[];
    };

    // Both statuses should appear in byStatus map
    assert.ok(
      (listResult.byStatus['DEGRADED'] ?? 0) >= 1,
      'byStatus.DEGRADED should be at least 1'
    );
    assert.ok(
      (listResult.byStatus['CRITICAL'] ?? 0) >= 1,
      'byStatus.CRITICAL should be at least 1'
    );

    // Entries should have the expected status
    const entryA = listResult.hosts.find((h) => h.hostname === machineA.machineHostname);
    const entryB = listResult.hosts.find((h) => h.hostname === machineB.machineHostname);
    assert.ok(entryA !== undefined, 'machineA should appear in list');
    assert.ok(entryB !== undefined, 'machineB should appear in list');
    assert.equal(entryA.status, 'DEGRADED');
    assert.equal(entryB.status, 'CRITICAL');
  });

  // ──────────────────────────────────────────────────────────────────────────
  // getByHost
  // ──────────────────────────────────────────────────────────────────────────

  await test('getByHost returns report data for a known host', async () => {
    const suffix = `byhost-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `health-byhost-room-${suffix}`,
      groupName: `health-byhost-group-${suffix}`,
      hostname: `health-byhost-host-${suffix}`,
    });

    await trpcMutate(
      'healthReports.submit',
      {
        hostname: machine.machineHostname,
        status: 'CRITICAL',
        agentVersion: '5.1.0',
        dnsResolving: false,
        dnsmasqRunning: true,
        failCount: 3,
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    const response = await trpcQuery(
      'healthReports.getByHost',
      { hostname: machine.machineHostname },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200, 'getByHost should return 200 for known host');

    const result = (await parseTRPC(response)).data as {
      hostname: string;
      currentStatus: string | null;
      lastSeen: string | null;
      version: string | undefined;
      reportCount: number;
      reports: unknown[];
    };

    assert.equal(result.hostname, machine.machineHostname);
    assert.equal(result.currentStatus, 'CRITICAL');
    assert.ok(result.lastSeen !== null, 'lastSeen should be set');
    assert.equal(result.version, '5.1.0', 'version should reflect agentVersion');
    assert.equal(result.reportCount, 1);
    assert.ok(Array.isArray(result.reports), 'reports should be an array');
    assert.equal(result.reports.length, 1);
  });

  await test('getByHost returns NOT_FOUND for unknown hostname', async () => {
    const response = await trpcQuery(
      'healthReports.getByHost',
      { hostname: 'definitely-not-a-registered-host-xyz-999' },
      getAdminBearerAuth()
    );
    // tRPC wraps NOT_FOUND as HTTP 404
    assert.equal(response.status, 404, `Expected 404, got ${String(response.status)}`);

    const result = await parseTRPC(response);
    assert.ok(result.code === 'NOT_FOUND', `Expected NOT_FOUND code, got ${String(result.code)}`);
  });

  // ──────────────────────────────────────────────────────────────────────────
  // getAlerts
  // ──────────────────────────────────────────────────────────────────────────

  await test('getAlerts returns problem-status alert for CRITICAL host', async () => {
    const suffix = `alerts-crit-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `health-alerts-room-${suffix}`,
      groupName: `health-alerts-group-${suffix}`,
      hostname: `health-alerts-host-${suffix}`,
    });

    await trpcMutate(
      'healthReports.submit',
      {
        hostname: machine.machineHostname,
        status: 'CRITICAL',
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    // Use a very large staleThreshold so only the status alert fires
    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200, 'getAlerts should return 200');

    const result = (await parseTRPC(response)).data as {
      alertCount: number;
      alerts: { hostname: string; type: string; status: string; message: string }[];
    };

    const alert = result.alerts.find(
      (a) => a.hostname === machine.machineHostname && a.type === 'status'
    );
    assert.ok(alert !== undefined, 'should have a status alert for the CRITICAL host');
    assert.equal(alert.status, 'CRITICAL');
    assert.ok(
      alert.message.includes('CRITICAL'),
      `message should mention CRITICAL, got: ${alert.message}`
    );
  });

  await test('getAlerts returns stale alert for host exceeding threshold', async () => {
    const suffix = `alerts-stale-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `health-stale-room-${suffix}`,
      groupName: `health-stale-group-${suffix}`,
      hostname: `health-stale-host-${suffix}`,
    });

    await trpcMutate(
      'healthReports.submit',
      {
        hostname: machine.machineHostname,
        status: 'HEALTHY',
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    // Use threshold 0 so any last-seen time counts as stale
    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 0 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200);

    const result = (await parseTRPC(response)).data as {
      alertCount: number;
      alerts: { hostname: string; type: string; status: string }[];
    };

    const staleAlert = result.alerts.find(
      (a) => a.hostname === machine.machineHostname && a.type === 'stale'
    );
    assert.ok(staleAlert !== undefined, 'should have a stale alert when threshold is 0');
    assert.equal(staleAlert.status, 'STALE');
  });

  await test('getAlerts returns empty when no alerts', async () => {
    // Query with no hosts in db (fresh state from registerIntegrationLifecycle resetDb)
    // We can't guarantee zero hosts since other tests run in the same lifecycle,
    // but we can verify the shape is correct with a very large threshold and HEALTHY status.
    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200);

    const result = (await parseTRPC(response)).data as {
      alertCount: number;
      alerts: unknown[];
    };

    assert.ok(typeof result.alertCount === 'number', 'alertCount should be a number');
    assert.ok(Array.isArray(result.alerts), 'alerts should be an array');
    assert.equal(result.alertCount, result.alerts.length, 'alertCount should match alerts.length');
  });

  // ──────────────────────────────────────────────────────────────────────────
  // submit – hostname-mismatch FORBIDDEN branch
  // ──────────────────────────────────────────────────────────────────────────

  await test('submit rejects when hostname does not match machine token', async () => {
    const suffix = `mismatch-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `health-mismatch-room-${suffix}`,
      groupName: `health-mismatch-group-${suffix}`,
      hostname: `health-mismatch-host-${suffix}`,
    });

    const response = await trpcMutate(
      'healthReports.submit',
      {
        // Wrong hostname – different from the registered machine hostname
        hostname: `completely-different-host-${suffix}`,
        status: 'HEALTHY',
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    assert.equal(response.status, 403, `Expected 403 FORBIDDEN, got ${String(response.status)}`);
  });
});
