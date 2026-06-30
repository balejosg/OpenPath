import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

process.env.NODE_ENV = 'test';

import { closeConnection } from '../src/db/index.js';
import * as classroomStorage from '../src/lib/classroom-storage.js';
import * as scheduleStorage from '../src/lib/schedule-storage.js';
import type { JWTPayload } from '../src/types/index.js';
import { createFixtureId, ensureWhitelistGroup } from './fixtures.js';
import { resetDb } from './test-utils.js';

const ADMIN_USER: JWTPayload = {
  sub: 'legacy_admin',
  email: 'admin@openpath.dev',
  name: 'Legacy Admin',
  type: 'access',
  roles: [{ role: 'admin', groupIds: [] }],
};

function teacherUser(groupIds: string[]): JWTPayload {
  return {
    sub: 'legacy_admin',
    email: 'teacher@openpath.dev',
    name: 'Teacher',
    type: 'access',
    roles: [{ role: 'teacher', groupIds }],
  };
}

function activeOneOffWindow(reference = new Date()): { startAt: Date; endAt: Date } {
  const startAt = new Date(reference);
  startAt.setUTCSeconds(0, 0);
  startAt.setUTCMinutes(startAt.getUTCMinutes() - (startAt.getUTCMinutes() % 15));

  const endAt = new Date(startAt.getTime() + 2 * 60 * 60 * 1000);
  return { startAt, endAt };
}

async function createClassroomWithMachine(
  label: string,
  defaultGroupId?: string
): Promise<{
  classroom: Awaited<ReturnType<typeof classroomStorage.createClassroom>>;
  machine: Awaited<ReturnType<typeof classroomStorage.registerMachine>>;
}> {
  const classroom = await classroomStorage.createClassroom({
    name: createFixtureId(`exemption-${label}`),
    displayName: `Exemption ${label}`,
    ...(defaultGroupId ? { defaultGroupId } : {}),
  });

  const machine = await classroomStorage.registerMachine({
    hostname: createFixtureId(`pc-${label}`),
    classroomId: classroom.id,
  });

  return { classroom, machine };
}

async function createActiveOneOffSchedule(
  classroomId: string,
  groupId: string
): Promise<Awaited<ReturnType<typeof scheduleStorage.createOneOffSchedule>>> {
  const { startAt, endAt } = activeOneOffWindow();
  return await scheduleStorage.createOneOffSchedule({
    classroomId,
    teacherId: 'legacy_admin',
    groupId,
    startAt,
    endAt,
  });
}

await describe('classroom command service exports', async () => {
  before(async () => {
    await resetDb();
  });

  after(async () => {
    await resetDb();
    await closeConnection();
  });

  const service = await import('../src/services/classroom-command.service.js');

  await test('exposes write-oriented classroom commands', () => {
    assert.equal(typeof service.createClassroom, 'function');
    assert.equal(typeof service.updateClassroom, 'function');
    assert.equal(typeof service.registerMachine, 'function');
    assert.equal(typeof service.rotateMachineToken, 'function');
    assert.equal(typeof service.createExemptionForClassroom, 'function');
    assert.equal(typeof service.createOperationalExemptionForClassroom, 'function');
  });

  await test('creates and updates classrooms with captive portal domains', async () => {
    const groupId = createFixtureId('command-captive-group');
    await ensureWhitelistGroup(groupId);

    const created = await service.createClassroom({
      name: createFixtureId('command-captive'),
      displayName: 'Command Captive',
      defaultGroupId: groupId,
      captivePortalDomains: [' Login.EXAMPLE.test ', 'login.example.test'],
    });

    if (!created.ok) {
      assert.fail(created.error.message);
    }

    assert.deepEqual(created.data.captivePortalDomains, ['login.example.test']);

    const updated = await service.updateClassroom(created.data.id, {
      captivePortalDomains: ['portal.example.test'],
    });

    if (!updated.ok) {
      assert.fail(updated.error.message);
    }

    assert.ok(updated.data);
    assert.deepEqual(updated.data.captivePortalDomains, ['portal.example.test']);
  });

  await test('returns classroom command errors for duplicate, invalid, and missing classrooms', async () => {
    const classroomName = createFixtureId('command-errors');
    const created = await service.createClassroom({
      name: classroomName,
      displayName: 'Command Errors',
    });
    if (!created.ok) {
      assert.fail(created.error.message);
    }

    const duplicate = await service.createClassroom({
      name: classroomName,
      displayName: 'Duplicate',
    });
    assert.equal(duplicate.ok, false);
    assert.equal(duplicate.error.code, 'CONFLICT');

    const invalidCreate = await service.createClassroom({
      name: createFixtureId('command-invalid-captive'),
      displayName: 'Invalid Captive',
      captivePortalDomains: ['https://portal.example.test'],
    });
    assert.equal(invalidCreate.ok, false);
    assert.equal(invalidCreate.error.code, 'BAD_REQUEST');

    const missingUpdate = await service.updateClassroom('missing-classroom', {
      displayName: 'Missing',
    });
    assert.deepEqual(missingUpdate, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Classroom not found' },
    });

    const invalidUpdate = await service.updateClassroom(created.data.id, {
      captivePortalDomains: ['*.example.test'],
    });
    assert.equal(invalidUpdate.ok, false);
    assert.equal(invalidUpdate.error.code, 'BAD_REQUEST');

    const missingDelete = await service.deleteClassroom('missing-classroom');
    assert.deepEqual(missingDelete, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Classroom not found' },
    });
  });

  await test('guards active group changes by teacher group scope', async () => {
    const allowedGroupId = createFixtureId('command-allowed-group');
    const deniedGroupId = createFixtureId('command-denied-group');
    await ensureWhitelistGroup(allowedGroupId);
    await ensureWhitelistGroup(deniedGroupId);
    const classroom = await classroomStorage.createClassroom({
      name: createFixtureId('command-scope'),
      displayName: 'Command Scope',
      defaultGroupId: allowedGroupId,
    });

    const forbidden = await service.setClassroomActiveGroup(teacherUser([allowedGroupId]), {
      id: classroom.id,
      groupId: deniedGroupId,
    });

    assert.deepEqual(forbidden, {
      ok: false,
      error: {
        code: 'FORBIDDEN',
        message: 'You can only set groups within your assigned scope',
      },
    });

    const missing = await service.setClassroomActiveGroup(ADMIN_USER, {
      id: 'missing-classroom',
      groupId: null,
    });

    assert.deepEqual(missing, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Classroom not found' },
    });
  });

  await test('creates, lists, and revokes schedule exemptions for active scheduled classrooms', async () => {
    const groupId = createFixtureId('schedule-group');
    await ensureWhitelistGroup(groupId);
    const { classroom, machine } = await createClassroomWithMachine('schedule-success');
    const schedule = await createActiveOneOffSchedule(classroom.id, groupId);
    const teacher = teacherUser([groupId]);

    const created = await service.createExemptionForClassroom(teacher, {
      classroomId: classroom.id,
      machineId: machine.id,
      scheduleId: schedule.id,
      createdBy: 'legacy_admin',
    });

    if (!created.ok) {
      assert.fail(created.error.message);
    }
    assert.equal(created.data.source, 'schedule');
    assert.equal(created.data.scheduleId, schedule.id);
    assert.equal(created.data.reason, null);

    const listed = await service.listExemptionsForClassroom(teacher, classroom.id);
    if (!listed.ok) {
      assert.fail(listed.error.message);
    }
    assert.equal(listed.data.classroomId, classroom.id);
    assert.equal(listed.data.exemptions.length, 1);
    assert.equal(listed.data.exemptions[0]?.machineHostname, machine.hostname);

    const deleted = await service.deleteExemptionForClassroom(teacher, created.data.id);
    assert.deepEqual(deleted, { ok: true, data: { success: true } });

    const afterDelete = await service.listExemptionsForClassroom(teacher, classroom.id);
    if (!afterDelete.ok) {
      assert.fail(afterDelete.error.message);
    }
    assert.equal(afterDelete.data.exemptions.length, 0);
  });

  await test('rejects teacher schedule exemptions outside the active schedule context', async () => {
    const defaultGroupId = createFixtureId('default-group');
    await ensureWhitelistGroup(defaultGroupId);
    const defaultClassroom = await createClassroomWithMachine('default-context', defaultGroupId);
    const teacherForDefault = teacherUser([defaultGroupId]);

    const defaultResult = await service.createExemptionForClassroom(teacherForDefault, {
      classroomId: defaultClassroom.classroom.id,
      machineId: defaultClassroom.machine.id,
      scheduleId: randomUUID(),
      createdBy: 'legacy_admin',
    });

    assert.deepEqual(defaultResult, {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'Machine exemptions are only available while a schedule controls the classroom',
      },
    });

    const scheduleGroupId = createFixtureId('mismatch-schedule-group');
    await ensureWhitelistGroup(scheduleGroupId);
    const scheduledClassroom = await createClassroomWithMachine('schedule-mismatch');
    await createActiveOneOffSchedule(scheduledClassroom.classroom.id, scheduleGroupId);
    const teacherForSchedule = teacherUser([scheduleGroupId]);

    const mismatchResult = await service.createExemptionForClassroom(teacherForSchedule, {
      classroomId: scheduledClassroom.classroom.id,
      machineId: scheduledClassroom.machine.id,
      scheduleId: randomUUID(),
      createdBy: 'legacy_admin',
    });

    assert.deepEqual(mismatchResult, {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Schedule is not active for this classroom' },
    });
  });

  await test('translates schedule exemption storage errors to service errors', async () => {
    const groupId = createFixtureId('storage-error-group');
    await ensureWhitelistGroup(groupId);
    const target = await createClassroomWithMachine('storage-error-target');
    const other = await createClassroomWithMachine('storage-error-other');
    const schedule = await createActiveOneOffSchedule(target.classroom.id, groupId);

    const result = await service.createExemptionForClassroom(teacherUser([groupId]), {
      classroomId: target.classroom.id,
      machineId: other.machine.id,
      scheduleId: schedule.id,
      createdBy: 'legacy_admin',
    });

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Machine does not belong to classroom' },
    });
  });

  await test('creates and revokes operational exemptions only for admins', async () => {
    const groupId = createFixtureId('operational-group');
    await ensureWhitelistGroup(groupId);
    const { classroom, machine } = await createClassroomWithMachine('operational', groupId);
    const teacher = teacherUser([groupId]);

    const teacherCreate = await service.createOperationalExemptionForClassroom(teacher, {
      classroomId: classroom.id,
      machineId: machine.id,
      durationHours: 1,
      reason: 'Maintenance',
      createdBy: 'legacy_admin',
    });

    assert.deepEqual(teacherCreate, {
      ok: false,
      error: {
        code: 'FORBIDDEN',
        message: 'Only administrators can create operational exemptions',
      },
    });

    const invalidReason = await service.createOperationalExemptionForClassroom(ADMIN_USER, {
      classroomId: classroom.id,
      machineId: machine.id,
      durationHours: 1,
      reason: '  ',
      createdBy: 'legacy_admin',
    });

    assert.deepEqual(invalidReason, {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Reason is required' },
    });

    const created = await service.createOperationalExemptionForClassroom(ADMIN_USER, {
      classroomId: classroom.id,
      machineId: machine.id,
      durationHours: 1,
      reason: ' Maintenance ',
      createdBy: 'legacy_admin',
    });

    if (!created.ok) {
      assert.fail(created.error.message);
    }
    assert.equal(created.data.source, 'operational');
    assert.equal(created.data.scheduleId, null);
    assert.equal(created.data.reason, 'Maintenance');

    const teacherDelete = await service.deleteExemptionForClassroom(teacher, created.data.id);
    assert.deepEqual(teacherDelete, {
      ok: false,
      error: {
        code: 'FORBIDDEN',
        message: 'Only administrators can revoke operational exemptions',
      },
    });

    const adminDelete = await service.deleteExemptionForClassroom(ADMIN_USER, created.data.id);
    assert.deepEqual(adminDelete, { ok: true, data: { success: true } });
  });

  await test('teacher can apply an allowed group to a machine and is denied an unallowed one', async () => {
    const groupId = createFixtureId('apply-group');
    await ensureWhitelistGroup(groupId);
    const { classroom, machine } = await createClassroomWithMachine('apply-group');
    const schedule = await createActiveOneOffSchedule(classroom.id, groupId);
    const teacher = teacherUser([groupId]);

    const ok = await service.createExemptionForClassroom(teacher, {
      classroomId: classroom.id,
      machineId: machine.id,
      scheduleId: schedule.id,
      groupId,
      createdBy: 'legacy_admin',
    });
    if (!ok.ok) {
      assert.fail(ok.error.message);
    }
    assert.equal(ok.data.groupId, groupId);

    // Un grupo que el profesor NO tiene se rechaza antes de persistir.
    const denied = await service.createExemptionForClassroom(teacher, {
      classroomId: classroom.id,
      machineId: machine.id,
      scheduleId: schedule.id,
      groupId: createFixtureId('not-allowed'),
      createdBy: 'legacy_admin',
    });
    assert.equal(denied.ok, false);
    if (!denied.ok) {
      assert.equal(denied.error.code, 'FORBIDDEN');
    }
  });

  await test('returns access and not-found errors for exemption commands', async () => {
    const groupId = createFixtureId('restricted-group');
    await ensureWhitelistGroup(groupId);
    const { classroom, machine } = await createClassroomWithMachine('restricted', groupId);
    const unauthorizedTeacher = teacherUser([]);

    const listResult = await service.listExemptionsForClassroom(unauthorizedTeacher, classroom.id);
    assert.deepEqual(listResult, {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'You do not have access to this classroom' },
    });

    const createResult = await service.createOperationalExemptionForClassroom(ADMIN_USER, {
      classroomId: 'missing-classroom-id',
      machineId: machine.id,
      durationHours: 1,
      reason: 'Maintenance',
      createdBy: 'legacy_admin',
    });
    assert.deepEqual(createResult, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Classroom not found' },
    });

    const deleteResult = await service.deleteExemptionForClassroom(ADMIN_USER, 'missing-exemption');
    assert.deepEqual(deleteResult, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Exemption not found' },
    });
  });
});
