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

  await test('getAlerts flags enforcement-down only when a field is explicitly false', async () => {
    const suffix = `enf-${Date.now().toString()}`;

    // Host A: firewall reported explicitly DOWN -> should alert.
    const down = await provisionMachineAccess({
      classroomName: `enf-down-room-${suffix}`,
      groupName: `enf-down-group-${suffix}`,
      hostname: `enf-down-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      { hostname: down.machineHostname, status: 'HEALTHY', firewallState: false, dnsState: true },
      { Authorization: `Bearer ${down.machineToken}` }
    );

    // Host B: old agent that does not report enforcement fields (null) -> must NOT alert.
    const unknown = await provisionMachineAccess({
      classroomName: `enf-unknown-room-${suffix}`,
      groupName: `enf-unknown-group-${suffix}`,
      hostname: `enf-unknown-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      { hostname: unknown.machineHostname, status: 'HEALTHY' },
      { Authorization: `Bearer ${unknown.machineToken}` }
    );

    // Large staleThreshold so only enforcement/status alerts fire, not stale.
    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200, 'getAlerts should return 200');

    const result = (await parseTRPC(response)).data as {
      alerts: { hostname: string; type: string; message: string }[];
    };

    const downAlert = result.alerts.find(
      (a) => a.hostname === down.machineHostname && a.type === 'enforcement-down'
    );
    assert.ok(downAlert, 'host reporting firewallState=false must raise an enforcement-down alert');
    assert.match(downAlert.message, /firewall/, 'message should name the down component');

    const unknownAlert = result.alerts.find(
      (a) => a.hostname === unknown.machineHostname && a.type === 'enforcement-down'
    );
    assert.equal(
      unknownAlert,
      undefined,
      'a host with unknown (null) enforcement fields must NOT raise enforcement-down'
    );
  });

  await test('getAlerts flags enforcement-unknown when a capable agent omits firewallState', async () => {
    const suffix = `enf-unknown-${Date.now().toString()}`;

    // Capable agent: reports a real agentVersion at/above the enforcement-telemetry
    // baseline but OMITS firewallState. This is the self-attestation gap: it must
    // not be a free pass, so a distinct enforcement-unknown alert should fire.
    const capable = await provisionMachineAccess({
      classroomName: `enf-unknown-cap-room-${suffix}`,
      groupName: `enf-unknown-cap-group-${suffix}`,
      hostname: `enf-unknown-cap-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      {
        hostname: capable.machineHostname,
        status: 'HEALTHY',
        agentVersion: '1.3.0',
        // firewallState intentionally omitted
      },
      { Authorization: `Bearer ${capable.machineToken}` }
    );

    // Legacy agent: no version reported -> not known to report enforcement -> no alert.
    const legacy = await provisionMachineAccess({
      classroomName: `enf-unknown-legacy-room-${suffix}`,
      groupName: `enf-unknown-legacy-group-${suffix}`,
      hostname: `enf-unknown-legacy-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      { hostname: legacy.machineHostname, status: 'HEALTHY' },
      { Authorization: `Bearer ${legacy.machineToken}` }
    );

    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200, 'getAlerts should return 200');

    const result = (await parseTRPC(response)).data as {
      alerts: { hostname: string; type: string; message: string }[];
    };

    const capableAlert = result.alerts.find(
      (a) => a.hostname === capable.machineHostname && a.type === 'enforcement-unknown'
    );
    assert.ok(
      capableAlert,
      'a capable agent that omits firewallState must raise an enforcement-unknown alert'
    );

    const legacyAlert = result.alerts.find(
      (a) => a.hostname === legacy.machineHostname && a.type === 'enforcement-unknown'
    );
    assert.equal(
      legacyAlert,
      undefined,
      'a legacy agent with no version must NOT raise enforcement-unknown'
    );

    // A capable agent that omits firewallState must never be treated as enforcement-down.
    const wrongType = result.alerts.find(
      (a) => a.hostname === capable.machineHostname && a.type === 'enforcement-down'
    );
    assert.equal(wrongType, undefined, 'unknown enforcement is not enforcement-down');
  });

  await test('getAlerts does not flag enforcement-unknown when a capable agent reports firewallState=true', async () => {
    const suffix = `enf-ok-${Date.now().toString()}`;
    const capable = await provisionMachineAccess({
      classroomName: `enf-ok-room-${suffix}`,
      groupName: `enf-ok-group-${suffix}`,
      hostname: `enf-ok-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      {
        hostname: capable.machineHostname,
        status: 'HEALTHY',
        agentVersion: '1.4.2',
        firewallState: true,
      },
      { Authorization: `Bearer ${capable.machineToken}` }
    );

    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200);

    const result = (await parseTRPC(response)).data as {
      alerts: { hostname: string; type: string }[];
    };
    const alert = result.alerts.find(
      (a) =>
        a.hostname === capable.machineHostname &&
        (a.type === 'enforcement-unknown' || a.type === 'enforcement-down')
    );
    assert.equal(alert, undefined, 'a capable agent reporting firewallState=true is healthy');
  });

  await test('getAlerts flags whitelist-stale when whitelistAgeHours exceeds the max', async () => {
    const suffix = `wl-stale-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `wl-stale-room-${suffix}`,
      groupName: `wl-stale-group-${suffix}`,
      hostname: `wl-stale-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      {
        hostname: machine.machineHostname,
        status: 'HEALTHY',
        agentVersion: '1.4.0',
        firewallState: true,
        // 1000h is far beyond any sane whitelist freshness window
        whitelistAgeHours: 1000,
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200);

    const result = (await parseTRPC(response)).data as {
      alerts: { hostname: string; type: string; message: string }[];
    };
    const staleAlert = result.alerts.find(
      (a) => a.hostname === machine.machineHostname && a.type === 'whitelist-stale'
    );
    assert.ok(staleAlert, 'a far-stale whitelist must raise a whitelist-stale alert');
    assert.match(staleAlert.message, /whitelist/i, 'message should mention the whitelist');
  });

  await test('getAlerts does not flag whitelist-stale for a fresh whitelist', async () => {
    const suffix = `wl-fresh-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `wl-fresh-room-${suffix}`,
      groupName: `wl-fresh-group-${suffix}`,
      hostname: `wl-fresh-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      {
        hostname: machine.machineHostname,
        status: 'HEALTHY',
        agentVersion: '1.4.0',
        firewallState: true,
        whitelistAgeHours: 1,
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200);

    const result = (await parseTRPC(response)).data as {
      alerts: { hostname: string; type: string }[];
    };
    const staleAlert = result.alerts.find(
      (a) => a.hostname === machine.machineHostname && a.type === 'whitelist-stale'
    );
    assert.equal(staleAlert, undefined, 'a fresh whitelist must not raise whitelist-stale');
  });

  await test('getAlerts surfaces captive-portal mode when active', async () => {
    const suffix = `captive-${Date.now().toString()}`;
    const machine = await provisionMachineAccess({
      classroomName: `captive-room-${suffix}`,
      groupName: `captive-group-${suffix}`,
      hostname: `captive-host-${suffix}`,
    });
    await trpcMutate(
      'healthReports.submit',
      {
        hostname: machine.machineHostname,
        status: 'HEALTHY',
        agentVersion: '1.4.0',
        firewallState: true,
        captivePortalMode: true,
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    const response = await trpcQuery(
      'healthReports.getAlerts',
      { staleThreshold: 999999 },
      getAdminBearerAuth()
    );
    assert.equal(response.status, 200);

    const result = (await parseTRPC(response)).data as {
      alerts: { hostname: string; type: string; message: string }[];
    };
    const captiveAlert = result.alerts.find(
      (a) => a.hostname === machine.machineHostname && a.type === 'captive-portal'
    );
    assert.ok(captiveAlert, 'an active captive-portal mode must be surfaced as an alert');
    assert.match(captiveAlert.message, /captive/i, 'message should mention captive portal');
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
