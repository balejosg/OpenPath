/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Shared schedule storage helpers and types.
 */

import { and, eq, isNull, or, sql } from 'drizzle-orm';
import { assertQuarterHourTime, assertQuarterHourInstant } from '@openpath/shared';
import { db, schedules } from '../db/index.js';

export type DBSchedule = typeof schedules.$inferSelect;

export interface ScheduleConflictError extends Error {
  conflict?: DBSchedule;
}

export interface CreateScheduleInput {
  classroomId: string;
  teacherId: string;
  groupId: string;
  dayOfWeek: number;
  startTime: string;
  endTime: string;
}

export interface CreateOneOffScheduleInput {
  classroomId: string;
  teacherId: string;
  groupId: string;
  startAt: Date;
  endAt: Date;
}

export interface UpdateScheduleInput {
  dayOfWeek?: number | undefined;
  startTime?: string | undefined;
  endTime?: string | undefined;
  groupId?: string | undefined;
}

export interface UpdateOneOffScheduleInput {
  startAt?: Date | undefined;
  endAt?: Date | undefined;
  groupId?: string | undefined;
}

export function weeklyRecurrenceWhereClause(): ReturnType<typeof or> {
  return or(eq(schedules.recurrence, 'weekly'), isNull(schedules.recurrence));
}

function normalizeTimeHHMM(time: string): string {
  const match = /^([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/.exec(time);
  if (!match) return time;
  const hh = match[1];
  const mm = match[2];
  if (hh === undefined || mm === undefined) return time;
  return `${hh}:${mm}`;
}

function parseTimeToMinutes(time: string): number {
  const parts = time.split(':');
  const hh = parts[0];
  const mm = parts[1];
  const h = Number(hh);
  const m = Number(mm);
  if (!Number.isInteger(h) || !Number.isInteger(m)) return Number.NaN;
  if (h < 0 || h > 23 || m < 0 || m > 59) return Number.NaN;
  return h * 60 + m;
}

export function timeToMinutes(time: string): number {
  return parseTimeToMinutes(normalizeTimeHHMM(time));
}

export function timesOverlap(start1: string, end1: string, start2: string, end2: string): boolean {
  const s1 = timeToMinutes(start1);
  const e1 = timeToMinutes(end1);
  const s2 = timeToMinutes(start2);
  const e2 = timeToMinutes(end2);

  return s1 < e2 && s2 < e1;
}

export function assertValidScheduleValues(input: {
  dayOfWeek: number;
  startTime: string;
  endTime: string;
}): void {
  const { dayOfWeek, startTime, endTime } = input;

  if (dayOfWeek < 1 || dayOfWeek > 5) {
    throw new Error('dayOfWeek must be between 1 (Monday) and 5 (Friday)');
  }

  assertQuarterHourTime(startTime);
  assertQuarterHourTime(endTime);

  if (timeToMinutes(startTime) >= timeToMinutes(endTime)) {
    throw new Error('startTime must be before endTime');
  }
}

export function assertValidOneOffScheduleValues(input: { startAt: Date; endAt: Date }): void {
  assertQuarterHourInstant(input.startAt);
  assertQuarterHourInstant(input.endAt);

  if (input.endAt.getTime() <= input.startAt.getTime()) {
    throw new Error('endAt must be after startAt');
  }
}

export function createScheduleConflictError(conflict: DBSchedule): ScheduleConflictError {
  const error: ScheduleConflictError = new Error('Schedule conflict');
  error.conflict = conflict;
  return error;
}

export async function findOneOffConflict(
  classroomId: string,
  startAt: Date,
  endAt: Date,
  excludeId: string | null = null
): Promise<DBSchedule | null> {
  const conditions =
    excludeId !== null
      ? and(
          eq(schedules.classroomId, classroomId),
          eq(schedules.recurrence, 'one_off'),
          sql`${schedules.startAt} < ${endAt} AND ${schedules.endAt} > ${startAt}`,
          sql`${schedules.id} != ${excludeId}::uuid`
        )
      : and(
          eq(schedules.classroomId, classroomId),
          eq(schedules.recurrence, 'one_off'),
          sql`${schedules.startAt} < ${endAt} AND ${schedules.endAt} > ${startAt}`
        );

  const result = await db.select().from(schedules).where(conditions).limit(1);
  return result[0] ?? null;
}

export async function findConflict(
  classroomId: string,
  dayOfWeek: number,
  startTime: string,
  endTime: string,
  excludeId: string | null = null
): Promise<DBSchedule | null> {
  const conditions =
    excludeId !== null
      ? and(
          eq(schedules.classroomId, classroomId),
          weeklyRecurrenceWhereClause(),
          eq(schedules.dayOfWeek, dayOfWeek),
          sql`(${startTime}::time, ${endTime}::time) OVERLAPS (${schedules.startTime}, ${schedules.endTime})`,
          sql`${schedules.id} != ${excludeId}::uuid`
        )
      : and(
          eq(schedules.classroomId, classroomId),
          weeklyRecurrenceWhereClause(),
          eq(schedules.dayOfWeek, dayOfWeek),
          sql`(${startTime}::time, ${endTime}::time) OVERLAPS (${schedules.startTime}, ${schedules.endTime})`
        );

  const result = await db.select().from(schedules).where(conditions).limit(1);
  return result[0] ?? null;
}
