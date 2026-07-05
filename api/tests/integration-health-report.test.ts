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

await describe('integration health report workflow', async () => {
  await test('completes health report submission to admin retrieval', async () => {
    const suffix = Date.now().toString();
    const machine = await provisionMachineAccess({
      classroomName: `integration-health-room-${suffix}`,
      groupName: `integration-health-group-${suffix}`,
      hostname: `integration-health-host-${suffix}`,
    });

    const reportResponse = await trpcMutate(
      'healthReports.submit',
      {
        hostname: `integration-health-host-${suffix}`,
        status: 'healthy',
        version: '3.5',
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );

    assert.ok(
      [200, 201].includes(reportResponse.status),
      `Health report submission should succeed, got ${String(reportResponse.status)}`
    );

    const listResponse = await trpcQuery('healthReports.list', undefined, getAdminBearerAuth());
    assert.equal(listResponse.status, 200, 'Should retrieve health reports');

    const listResult = (await parseTRPC(listResponse)).data as {
      hosts?: { hostname: string }[];
    };
    assert.ok(Array.isArray(listResult.hosts), 'Response should contain hosts array');
    assert.ok(
      listResult.hosts.some((host) => host.hostname === machine.machineHostname),
      'Expected registered machine to appear in the health report summary'
    );
  });

  await test('persists configPosture latest-wins and healthReportFailStreak per report', async () => {
    const suffix = `${Date.now().toString()}-posture`;
    const hostname = `integration-posture-host-${suffix}`;
    const machine = await provisionMachineAccess({
      classroomName: `integration-posture-room-${suffix}`,
      groupName: `integration-posture-group-${suffix}`,
      hostname,
    });

    const firstReport = await trpcMutate(
      'healthReports.submit',
      {
        hostname,
        status: 'healthy',
        version: '3.5',
        configPosture: { sinkholeFastFail: 'true', rfc1918EgressMode: 'restricted' },
        healthReportFailStreak: 2,
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );
    assert.ok(
      [200, 201].includes(firstReport.status),
      `First posture report should succeed, got ${String(firstReport.status)}`
    );

    // A later report WITHOUT configPosture must not wipe the stored posture.
    const secondReport = await trpcMutate(
      'healthReports.submit',
      { hostname, status: 'healthy', version: '3.5' },
      { Authorization: `Bearer ${machine.machineToken}` }
    );
    assert.ok([200, 201].includes(secondReport.status), 'Second report should succeed');

    const listResponse = await trpcQuery('classrooms.list', undefined, getAdminBearerAuth());
    assert.equal(listResponse.status, 200, 'Should list classrooms');
    const classrooms = (await parseTRPC(listResponse)).data as {
      machines?: {
        hostname: string;
        configPosture?: Record<string, string> | null;
      }[];
    }[];
    const reported = classrooms
      .flatMap((classroom) => classroom.machines ?? [])
      .find((entry) => entry.hostname === machine.machineHostname);
    assert.ok(reported, 'Expected the reporting machine in classrooms.list output');
    assert.deepEqual(reported.configPosture, {
      sinkholeFastFail: 'true',
      rfc1918EgressMode: 'restricted',
    });

    const hostResponse = await trpcQuery(
      'healthReports.getByHost',
      { hostname: machine.machineHostname },
      getAdminBearerAuth()
    );
    assert.equal(hostResponse.status, 200, 'Should fetch host reports');
    const hostData = (await parseTRPC(hostResponse)).data as {
      reports: { healthReportFailStreak?: number | null }[];
    };
    assert.ok(
      hostData.reports.some((report) => report.healthReportFailStreak === 2),
      'Expected the first report to carry healthReportFailStreak=2'
    );
  });

  await test('persists firefoxRegistration onto the machine and exposes it to classrooms', async () => {
    const suffix = `${Date.now().toString()}-ffreg`;
    const hostname = `integration-ffreg-host-${suffix}`;
    const machine = await provisionMachineAccess({
      classroomName: `integration-ffreg-room-${suffix}`,
      groupName: `integration-ffreg-group-${suffix}`,
      hostname,
    });

    const reportResponse = await trpcMutate(
      'healthReports.submit',
      {
        hostname,
        status: 'healthy',
        version: '3.5',
        firefoxRegistration: {
          registered: 2,
          targetCount: 3,
          lastCheckedAt: '2026-07-02T10:00:00Z',
        },
      },
      { Authorization: `Bearer ${machine.machineToken}` }
    );
    assert.ok(
      [200, 201].includes(reportResponse.status),
      `Health report submission should succeed, got ${String(reportResponse.status)}`
    );

    const listResponse = await trpcQuery('classrooms.list', undefined, getAdminBearerAuth());
    assert.equal(listResponse.status, 200, 'Should list classrooms');
    const classrooms = (await parseTRPC(listResponse)).data as {
      machines?: {
        hostname: string;
        firefoxRegistration?: {
          registered: number;
          targetCount: number;
          lastCheckedAt?: string;
        } | null;
      }[];
    }[];
    const reported = classrooms
      .flatMap((classroom) => classroom.machines ?? [])
      .find((entry) => entry.hostname === machine.machineHostname);
    assert.ok(reported, 'Expected the reporting machine in classrooms.list output');
    assert.deepEqual(reported.firefoxRegistration, {
      registered: 2,
      targetCount: 3,
      lastCheckedAt: '2026-07-02T10:00:00Z',
    });

    // A later report WITHOUT firefoxRegistration must not wipe the stored value.
    const secondReport = await trpcMutate(
      'healthReports.submit',
      { hostname, status: 'healthy', version: '3.5' },
      { Authorization: `Bearer ${machine.machineToken}` }
    );
    assert.ok([200, 201].includes(secondReport.status), 'Second report should succeed');

    const secondListResponse = await trpcQuery('classrooms.list', undefined, getAdminBearerAuth());
    assert.equal(secondListResponse.status, 200, 'Should list classrooms after second report');
    const secondClassrooms = (await parseTRPC(secondListResponse)).data as {
      machines?: {
        hostname: string;
        firefoxRegistration?: {
          registered: number;
          targetCount: number;
          lastCheckedAt?: string;
        } | null;
      }[];
    }[];
    const reportedAfterSecond = secondClassrooms
      .flatMap((classroom) => classroom.machines ?? [])
      .find((entry) => entry.hostname === machine.machineHostname);
    assert.ok(
      reportedAfterSecond,
      'Expected the reporting machine in classrooms.list output after second report'
    );
    assert.deepEqual(
      reportedAfterSecond.firefoxRegistration,
      {
        registered: 2,
        targetCount: 3,
        lastCheckedAt: '2026-07-02T10:00:00Z',
      },
      'A later report without firefoxRegistration must not wipe the stored value'
    );
  });
});
