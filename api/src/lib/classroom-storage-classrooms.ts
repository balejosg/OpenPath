import { count, eq, sql } from 'drizzle-orm';
import { v4 as uuidv4 } from 'uuid';
import { normalizeCaptivePortalDomains, sanitizeSlug } from '@openpath/shared';
import { classrooms, db, machines } from '../db/index.js';
import { getRowCount } from './utils.js';
import type { CreateClassroomData, UpdateClassroomData } from '../types/storage.js';
import type {
  ClassroomStats,
  ClassroomWithCount,
  DBClassroom,
} from './classroom-storage-shared.js';

export async function getAllClassrooms(): Promise<ClassroomWithCount[]> {
  const result = await db
    .select({
      id: classrooms.id,
      name: classrooms.name,
      displayName: classrooms.displayName,
      defaultGroupId: classrooms.defaultGroupId,
      activeGroupId: classrooms.activeGroupId,
      captivePortalDomains: classrooms.captivePortalDomains,
      createdAt: classrooms.createdAt,
      updatedAt: classrooms.updatedAt,
      machineCount: sql<number>`COUNT(${machines.id})::int`.as('machineCount'),
    })
    .from(classrooms)
    .leftJoin(machines, eq(machines.classroomId, classrooms.id))
    .groupBy(classrooms.id)
    .orderBy(sql`${classrooms.createdAt} DESC`);

  return result.map((row) => ({
    id: row.id,
    name: row.name,
    displayName: row.displayName,
    defaultGroupId: row.defaultGroupId,
    activeGroupId: row.activeGroupId,
    captivePortalDomains: row.captivePortalDomains,
    createdAt: row.createdAt ?? new Date(),
    updatedAt: row.updatedAt ?? new Date(),
    machineCount: row.machineCount,
  }));
}

export async function getClassroomById(id: string): Promise<DBClassroom | null> {
  const result = await db.select().from(classrooms).where(eq(classrooms.id, id)).limit(1);
  return result[0] ?? null;
}

export async function getClassroomByName(name: string): Promise<DBClassroom | null> {
  const normalizedName = sanitizeSlug(name, { maxLength: 100, allowUnderscore: true });
  const result = await db
    .select()
    .from(classrooms)
    .where(eq(classrooms.name, normalizedName))
    .limit(1);

  return result[0] ?? null;
}

export async function createClassroom(
  classroomData: CreateClassroomData & { defaultGroupId?: string }
): Promise<DBClassroom> {
  const { name, displayName, defaultGroupId } = classroomData;
  const slug = sanitizeSlug(name, { maxLength: 100, allowUnderscore: true });
  if (!slug) {
    throw new Error('Classroom name is invalid');
  }

  const existing = await getClassroomByName(slug);
  if (existing) {
    throw new Error(`Classroom with name "${slug}" already exists`);
  }

  const id = `room_${uuidv4().slice(0, 8)}`;
  const [result] = await db
    .insert(classrooms)
    .values({
      id,
      name: slug,
      displayName: displayName ?? name,
      defaultGroupId: defaultGroupId ?? null,
      captivePortalDomains: normalizeCaptivePortalDomains(classroomData.captivePortalDomains),
    })
    .returning();

  if (!result) {
    throw new Error(`Failed to create classroom "${slug}"`);
  }

  return result;
}

export async function updateClassroom(
  id: string,
  updates: UpdateClassroomData & { defaultGroupId?: string }
): Promise<DBClassroom | null> {
  const updateValues: Partial<typeof classrooms.$inferInsert> = {};

  if (updates.displayName !== undefined) {
    updateValues.displayName = updates.displayName;
  }
  if (updates.defaultGroupId !== undefined) {
    updateValues.defaultGroupId = updates.defaultGroupId;
  }
  if (updates.captivePortalDomains !== undefined) {
    updateValues.captivePortalDomains = normalizeCaptivePortalDomains(updates.captivePortalDomains);
  }

  if (Object.keys(updateValues).length === 0) {
    return await getClassroomById(id);
  }

  const [result] = await db
    .update(classrooms)
    .set(updateValues)
    .where(eq(classrooms.id, id))
    .returning();

  return result ?? null;
}

export async function setActiveGroup(
  id: string,
  groupId: string | null
): Promise<DBClassroom | null> {
  const [result] = await db
    .update(classrooms)
    .set({ activeGroupId: groupId })
    .where(eq(classrooms.id, id))
    .returning();

  return result ?? null;
}

export async function getCurrentGroupId(id: string): Promise<string | null> {
  const classroom = await getClassroomById(id);
  if (!classroom) return null;
  return classroom.activeGroupId ?? classroom.defaultGroupId;
}

export async function deleteClassroom(id: string): Promise<boolean> {
  return getRowCount(await db.delete(classrooms).where(eq(classrooms.id, id))) > 0;
}

export async function getStats(): Promise<ClassroomStats> {
  const classroomResult = await db
    .select({
      total: count(),
      active: sql<number>`COUNT(*) FILTER (WHERE ${classrooms.activeGroupId} IS NOT NULL)`.as(
        'active'
      ),
    })
    .from(classrooms);

  const machineResult = await db
    .select({
      total: count(),
    })
    .from(machines);

  return {
    classrooms: classroomResult[0]?.total ?? 0,
    machines: machineResult[0]?.total ?? 0,
    classroomsWithActiveGroup: classroomResult[0]?.active ?? 0,
  };
}
