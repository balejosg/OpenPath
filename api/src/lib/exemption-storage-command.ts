import { v4 as uuidv4 } from 'uuid';
import { and, eq, sql } from 'drizzle-orm';
import { db, machineExemptions, machines, schedules } from '../db/index.js';
import {
  buildExpiresAtForScheduleEnd,
  type CreateOperationalMachineExemptionInput,
  type CreateMachineExemptionInput,
  MachineExemptionError,
  type MachineExemptionRow,
  weeklyRecurrenceWhereClause,
} from './exemption-storage-shared.js';

export async function createMachineExemption(
  input: CreateMachineExemptionInput
): Promise<MachineExemptionRow> {
  const now = input.now ?? new Date();

  const machineRows = await db
    .select({ id: machines.id, classroomId: machines.classroomId })
    .from(machines)
    .where(eq(machines.id, input.machineId))
    .limit(1);
  const machine = machineRows[0];
  if (!machine) {
    throw new MachineExemptionError('NOT_FOUND', 'Machine not found');
  }

  if (machine.classroomId !== input.classroomId) {
    throw new MachineExemptionError('BAD_REQUEST', 'Machine does not belong to classroom');
  }

  const oneOffRows = await db
    .select({ id: schedules.id, endAt: schedules.endAt })
    .from(schedules)
    .where(
      and(
        eq(schedules.id, input.scheduleId),
        eq(schedules.classroomId, input.classroomId),
        eq(schedules.recurrence, 'one_off'),
        sql`${schedules.startAt} <= ${now} AND ${schedules.endAt} > ${now}`
      )
    )
    .limit(1);

  const oneOff = oneOffRows[0];
  if (oneOff) {
    const endAt = oneOff.endAt;
    if (!endAt) {
      throw new MachineExemptionError('BAD_REQUEST', 'Invalid one-off schedule endAt');
    }
    if (endAt.getTime() <= now.getTime()) {
      throw new MachineExemptionError('BAD_REQUEST', 'Schedule is not active');
    }

    return insertOrReuseExemption({
      machineId: input.machineId,
      classroomId: input.classroomId,
      scheduleId: input.scheduleId,
      source: 'schedule',
      reason: null,
      createdBy: input.createdBy,
      groupId: input.groupId ?? null,
      expiresAt: endAt,
    });
  }

  const dayOfWeek = now.getDay();
  if (dayOfWeek === 0 || dayOfWeek === 6) {
    throw new MachineExemptionError('BAD_REQUEST', 'Schedules are inactive on weekends');
  }

  const currentTime = now.toTimeString().slice(0, 5);

  const scheduleRows = await db
    .select({ id: schedules.id, endTime: schedules.endTime })
    .from(schedules)
    .where(
      and(
        eq(schedules.id, input.scheduleId),
        eq(schedules.classroomId, input.classroomId),
        weeklyRecurrenceWhereClause(),
        eq(schedules.dayOfWeek, dayOfWeek),
        sql`${schedules.startTime} <= ${currentTime}::time`,
        sql`${schedules.endTime} > ${currentTime}::time`
      )
    )
    .limit(1);

  const schedule = scheduleRows[0];
  if (!schedule) {
    throw new MachineExemptionError('BAD_REQUEST', 'Schedule is not active');
  }

  if (!schedule.endTime) {
    throw new MachineExemptionError('BAD_REQUEST', 'Invalid schedule endTime');
  }

  return insertOrReuseExemption({
    machineId: input.machineId,
    classroomId: input.classroomId,
    scheduleId: input.scheduleId,
    source: 'schedule',
    reason: null,
    createdBy: input.createdBy,
    groupId: input.groupId ?? null,
    expiresAt: buildExpiresAtForScheduleEnd(now, schedule.endTime),
  });
}

export async function createOperationalMachineExemption(
  input: CreateOperationalMachineExemptionInput
): Promise<MachineExemptionRow> {
  const now = input.now ?? new Date();
  const reason = input.reason.trim();

  if (
    !Number.isInteger(input.durationHours) ||
    input.durationHours < 1 ||
    input.durationHours > 24
  ) {
    throw new MachineExemptionError(
      'BAD_REQUEST',
      'Duration must be an integer from 1 to 24 hours'
    );
  }

  if (reason.length < 3) {
    throw new MachineExemptionError('BAD_REQUEST', 'Reason is required');
  }

  const machineRows = await db
    .select({ id: machines.id, classroomId: machines.classroomId })
    .from(machines)
    .where(eq(machines.id, input.machineId))
    .limit(1);
  const machine = machineRows[0];
  if (!machine) {
    throw new MachineExemptionError('NOT_FOUND', 'Machine not found');
  }

  if (machine.classroomId !== input.classroomId) {
    throw new MachineExemptionError('BAD_REQUEST', 'Machine does not belong to classroom');
  }

  return insertOrReuseExemption({
    machineId: input.machineId,
    classroomId: input.classroomId,
    scheduleId: null,
    source: 'operational',
    reason,
    createdBy: input.createdBy,
    groupId: null,
    expiresAt: new Date(now.getTime() + input.durationHours * 60 * 60 * 1000),
  });
}

export async function deleteMachineExemption(id: string): Promise<{ classroomId: string } | null> {
  const deleted = await db
    .delete(machineExemptions)
    .where(eq(machineExemptions.id, id))
    .returning({ classroomId: machineExemptions.classroomId });

  const row = deleted[0];
  if (!row) return null;
  return { classroomId: row.classroomId };
}

export async function getMachineExemptionById(
  id: string
): Promise<{ id: string; classroomId: string; source: string } | null> {
  const rows = await db
    .select({
      id: machineExemptions.id,
      classroomId: machineExemptions.classroomId,
      source: machineExemptions.source,
    })
    .from(machineExemptions)
    .where(eq(machineExemptions.id, id))
    .limit(1);

  return rows[0] ?? null;
}

interface InsertMachineExemptionInput {
  machineId: string;
  classroomId: string;
  scheduleId: string | null;
  source: 'schedule' | 'operational';
  reason: string | null;
  createdBy: string | null;
  groupId: string | null;
  expiresAt: Date;
}

async function insertOrReuseExemption(
  input: InsertMachineExemptionInput
): Promise<MachineExemptionRow> {
  const id = `exempt_${uuidv4().slice(0, 8)}`;
  const inserted = await db
    .insert(machineExemptions)
    .values({
      id,
      machineId: input.machineId,
      classroomId: input.classroomId,
      scheduleId: input.scheduleId,
      source: input.source,
      reason: input.reason,
      createdBy: input.createdBy,
      groupId: input.groupId,
      expiresAt: input.expiresAt,
    })
    .onConflictDoNothing()
    .returning();

  const created = inserted[0];
  if (created) {
    return created;
  }

  const existing = await db
    .select()
    .from(machineExemptions)
    .where(
      and(
        eq(machineExemptions.machineId, input.machineId),
        input.scheduleId === null
          ? sql`${machineExemptions.scheduleId} IS NULL`
          : eq(machineExemptions.scheduleId, input.scheduleId),
        eq(machineExemptions.source, input.source),
        eq(machineExemptions.expiresAt, input.expiresAt)
      )
    )
    .limit(1);

  const row = existing[0];
  if (!row) {
    throw new MachineExemptionError('CONFLICT', 'Could not create exemption');
  }

  return row;
}
