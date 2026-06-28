import { after, before, beforeEach, describe, test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { Server } from 'node:http';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-jwt-secret';
process.env.SHARED_SECRET = 'test-shared-secret';
process.env.DB_HOST = 'localhost';
process.env.DB_PORT = '5433';
process.env.DB_NAME = 'openpath_test';
process.env.DB_USER = 'openpath';
process.env.DB_PASSWORD = 'openpath_test';

const { getAvailablePort, resetDb } = await import('../../../api/tests/test-utils.js');
const { closeConnection } = await import('../../../api/src/db/index.js');
const { seedE2E } = await import('../../../api/scripts/seed-e2e.js');
const {
  approveRequest,
  bootstrapStudentScenario,
  createGroupRule,
  createTemporaryExemption,
  deleteGroupRule,
  deleteTemporaryExemption,
  getClassroomDetails,
  getRequestStatus,
  rejectRequest,
  setActiveGroup,
  submitManualRequest,
  tickBoundaries,
} = await import('./backend-harness.js');

let apiUrl = '';
let port = 0;
let server: Server | undefined;
let testDataDir: string | null = null;

await describe('student policy backend harness', async () => {
  before(async () => {
    port = await getAvailablePort();
    apiUrl = `http://localhost:${String(port)}`;

    process.env.PORT = String(port);
    testDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-student-policy-harness-'));
    process.env.DATA_DIR = testDataDir;

    const etcPath = path.join(process.cwd(), 'etc');
    if (!fs.existsSync(etcPath)) {
      fs.mkdirSync(etcPath, { recursive: true });
    }

    const { app } = await import('../../../api/src/server.js');
    server = app.listen(port);
    await new Promise((resolve) => setTimeout(resolve, 300));
  });

  beforeEach(async () => {
    await resetDb();
    await seedE2E();
  });

  after(async () => {
    if (server !== undefined) {
      if ('closeAllConnections' in server && typeof server.closeAllConnections === 'function') {
        server.closeAllConnections();
      }

      await new Promise<void>((resolve) => {
        server?.close(() => {
          resolve();
        });
      });
    }

    await closeConnection();

    if (testDataDir !== null) {
      fs.rmSync(testDataDir, { recursive: true, force: true });
      testDataDir = null;
    }
  });

  await test('bootstrapStudentScenario creates reusable classroom, schedules, and machine state', async () => {
    const scenario = await bootstrapStudentScenario({
      apiUrl,
      scenarioName: 'Harness Bootstrap',
      machineHostname: 'student-station',
      version: '4.1.0-test',
    });

    assert.strictEqual(scenario.apiUrl, apiUrl);
    assert.ok(scenario.auth.admin.accessToken.length > 0);
    assert.ok(scenario.auth.teacher.accessToken.length > 0);
    assert.notStrictEqual(scenario.groups.restricted.id, scenario.groups.alternate.id);
    assert.strictEqual(scenario.classroom.defaultGroupId, scenario.groups.restricted.id);
    assert.strictEqual(scenario.schedules.activeRestriction.groupId, scenario.groups.restricted.id);
    assert.strictEqual(scenario.schedules.futureAlternate.groupId, scenario.groups.alternate.id);
    assert.ok(scenario.machine.id.length > 0);
    assert.ok(scenario.machine.machineToken.length > 0);
    assert.match(scenario.machine.whitelistUrl, /\/w\/[^/]+\/whitelist\.txt$/);
    assert.strictEqual(scenario.machine.reportedHostname, 'student-station');
    assert.strictEqual(scenario.fixtures.portal, 'portal.127.0.0.1.sslip.io');

    const classroom = await getClassroomDetails({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      classroomId: scenario.classroom.id,
    });

    assert.ok(
      classroom.machines?.some(
        (machine: { id: string; hostname: string }) => machine.id === scenario.machine.id
      )
    );
    assert.ok(
      classroom.machines?.some(
        (machine: { id: string; hostname: string }) =>
          machine.hostname === scenario.machine.machineHostname
      )
    );
  });

  await test('request lifecycle and rule helpers work against a bootstrapped scenario', async () => {
    const scenario = await bootstrapStudentScenario({
      apiUrl,
      scenarioName: 'Harness Request Flow',
      machineHostname: 'request-station',
    });

    const pendingRequest = await submitManualRequest({
      apiUrl,
      domain: 'pending-request.example.com',
      hostname: scenario.machine.reportedHostname,
      token: scenario.machine.machineToken,
      reason: 'Need this site for a test',
      originPage: `https://${scenario.fixtures.portal}/ok`,
    });

    assert.strictEqual(pendingRequest.success, true);
    assert.ok(pendingRequest.id);

    const pendingStatus = await getRequestStatus({
      apiUrl,
      requestId: pendingRequest.id ?? '',
    });
    assert.strictEqual(pendingStatus.status, 'pending');

    await approveRequest({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      requestId: pendingRequest.id ?? '',
      groupId: scenario.groups.restricted.id,
    });

    const approvedStatus = await getRequestStatus({
      apiUrl,
      requestId: pendingRequest.id ?? '',
    });
    assert.strictEqual(approvedStatus.status, 'approved');

    const blockedPathRule = await createGroupRule({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      groupId: scenario.groups.restricted.id,
      type: 'blocked_path',
      value: `${scenario.fixtures.site}/private`,
      comment: 'Harness path rule',
    });
    assert.ok(blockedPathRule.id);

    const deletedRule = await deleteGroupRule({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      ruleId: blockedPathRule.id,
      groupId: scenario.groups.restricted.id,
    });
    assert.strictEqual(deletedRule.deleted, true);

    const rejectedRequest = await submitManualRequest({
      apiUrl,
      domain: 'rejected-request.example.com',
      hostname: scenario.machine.reportedHostname,
      token: scenario.machine.machineToken,
      reason: 'This request should be rejected',
    });
    assert.ok(rejectedRequest.id);

    await rejectRequest({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      requestId: rejectedRequest.id ?? '',
      reason: 'Rejected by harness test',
    });

    const rejectedStatus = await getRequestStatus({
      apiUrl,
      requestId: rejectedRequest.id ?? '',
    });
    assert.strictEqual(rejectedStatus.status, 'rejected');
  });

  await test('exemption, active group, and boundary helpers are callable', async () => {
    const scenario = await bootstrapStudentScenario({
      apiUrl,
      scenarioName: 'Harness Control Flow',
      machineHostname: 'control-station',
    });

    const exemption = await createTemporaryExemption({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      machineId: scenario.machine.id,
      classroomId: scenario.classroom.id,
      scheduleId: scenario.schedules.activeRestriction.id,
    });
    assert.strictEqual(exemption.machineId, scenario.machine.id);
    assert.strictEqual(exemption.classroomId, scenario.classroom.id);

    const override = await setActiveGroup({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      classroomId: scenario.classroom.id,
      groupId: scenario.groups.alternate.id,
    });
    assert.strictEqual(override.currentGroupId, scenario.groups.alternate.id);

    const cleared = await setActiveGroup({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      classroomId: scenario.classroom.id,
      groupId: null,
    });
    assert.strictEqual(cleared.currentGroupId, scenario.groups.restricted.id);

    const deletedExemption = await deleteTemporaryExemption({
      apiUrl,
      accessToken: scenario.auth.teacher.accessToken,
      exemptionId: exemption.id,
    });
    assert.strictEqual(deletedExemption.success, true);

    const tick = await tickBoundaries(scenario.schedules.futureAlternate.startAt);
    assert.strictEqual(tick.at, new Date(scenario.schedules.futureAlternate.startAt).toISOString());
  });
});
