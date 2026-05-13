import { or, eq, isNull } from 'drizzle-orm';
import { schedules, machineExemptions } from '../db/index.js';

export const UNRESTRICTED_GROUP_ID = '__unrestricted__';

export type MachineExemptionErrorCode = 'NOT_FOUND' | 'BAD_REQUEST' | 'CONFLICT';
export type MachineExemptionSource = 'schedule' | 'operational';

export class MachineExemptionError extends Error {
  public readonly code: MachineExemptionErrorCode;

  public constructor(code: MachineExemptionErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

export function weeklyRecurrenceWhereClause(): ReturnType<typeof or> {
  return or(eq(schedules.recurrence, 'weekly'), isNull(schedules.recurrence));
}

export function parseTimeHHMM(time: string): { hours: number; minutes: number } | null {
  const match = /^([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/.exec(time);
  if (!match) return null;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  if (!Number.isInteger(hours) || !Number.isInteger(minutes)) return null;
  return { hours, minutes };
}

export function buildExpiresAtForScheduleEnd(now: Date, endTimeRaw: string): Date {
  const parts = parseTimeHHMM(endTimeRaw);
  if (!parts) {
    throw new MachineExemptionError('BAD_REQUEST', 'Invalid schedule endTime');
  }

  const expiresAt = new Date(now);
  expiresAt.setHours(parts.hours, parts.minutes, 0, 0);

  if (expiresAt.getTime() <= now.getTime()) {
    throw new MachineExemptionError('BAD_REQUEST', 'Schedule is not active');
  }

  return expiresAt;
}

export interface CreateMachineExemptionInput {
  machineId: string;
  classroomId: string;
  scheduleId: string;
  createdBy: string | null;
  now?: Date | undefined;
}

export interface CreateOperationalMachineExemptionInput {
  machineId: string;
  classroomId: string;
  durationHours: number;
  reason: string;
  createdBy: string | null;
  now?: Date | undefined;
}

export type MachineExemptionRow = typeof machineExemptions.$inferSelect;

export interface ActiveMachineExemption {
  id: string;
  machineId: string;
  machineHostname: string;
  classroomId: string;
  scheduleId: string | null;
  source: MachineExemptionSource;
  reason: string | null;
  createdBy: string | null;
  createdAt: Date | null;
  expiresAt: Date;
}
