import { and, desc, eq, gt } from 'drizzle-orm';
import { db, machineExemptions, machines } from '../db/index.js';
import { type ActiveMachineExemption } from './exemption-storage-shared.js';

export async function isMachineExempt(
  machineId: string,
  classroomId: string,
  now: Date = new Date()
): Promise<boolean> {
  const rows = await db
    .select({ id: machineExemptions.id })
    .from(machineExemptions)
    .where(
      and(
        eq(machineExemptions.machineId, machineId),
        eq(machineExemptions.classroomId, classroomId),
        gt(machineExemptions.expiresAt, now)
      )
    )
    .limit(1);

  return rows.length > 0;
}

export async function getActiveMachineExemptionsByClassroom(
  classroomId: string,
  now: Date = new Date()
): Promise<ActiveMachineExemption[]> {
  const rows = await db
    .select({
      id: machineExemptions.id,
      machineId: machineExemptions.machineId,
      machineHostname: machines.hostname,
      classroomId: machineExemptions.classroomId,
      scheduleId: machineExemptions.scheduleId,
      source: machineExemptions.source,
      reason: machineExemptions.reason,
      createdBy: machineExemptions.createdBy,
      createdAt: machineExemptions.createdAt,
      expiresAt: machineExemptions.expiresAt,
    })
    .from(machineExemptions)
    .innerJoin(machines, eq(machines.id, machineExemptions.machineId))
    .where(
      and(eq(machineExemptions.classroomId, classroomId), gt(machineExemptions.expiresAt, now))
    )
    .orderBy(desc(machineExemptions.source), machineExemptions.expiresAt);

  return rows.map((r) => ({
    id: r.id,
    machineId: r.machineId,
    machineHostname: r.machineHostname,
    classroomId: r.classroomId,
    scheduleId: r.scheduleId,
    source: r.source === 'operational' ? 'operational' : 'schedule',
    reason: r.reason ?? null,
    createdBy: r.createdBy ?? null,
    createdAt: r.createdAt ?? null,
    expiresAt: r.expiresAt,
  }));
}

export async function getActiveExemptHostnamesByClassroom(
  classroomId: string,
  now: Date = new Date()
): Promise<ReadonlySet<string>> {
  const rows = await db
    .select({ hostname: machines.hostname })
    .from(machineExemptions)
    .innerJoin(machines, eq(machines.id, machineExemptions.machineId))
    .where(
      and(eq(machineExemptions.classroomId, classroomId), gt(machineExemptions.expiresAt, now))
    );

  return new Set(rows.map((r) => r.hostname));
}
