import {
  MachineExemptionError,
  createMachineExemption,
  createOperationalMachineExemption,
  deleteMachineExemption,
  getActiveMachineExemptionsByClassroom,
  getMachineExemptionById,
} from '../lib/exemption-storage.js';

import * as auth from '../lib/auth.js';
import { getCurrentSchedule } from '../lib/schedule-storage.js';
import DomainEventsService from './domain-events.service.js';
import { ensureUserCanAccessClassroom } from './classroom-access.service.js';
import type {
  ClassroomResult,
  ClassroomUser,
  CreateMachineExemptionInput,
  CreateOperationalMachineExemptionInput,
  MachineExemptionInfo,
} from './classroom-service-shared.js';
import { toMachineExemptionInfo } from './classroom-service-shared.js';

export async function createExemptionForClassroom(
  user: ClassroomUser,
  input: CreateMachineExemptionInput
): Promise<ClassroomResult<MachineExemptionInfo>> {
  const access = await ensureUserCanAccessClassroom(user, input.classroomId);
  if (!access.ok) {
    return access;
  }

  if (access.data.currentGroupSource !== 'schedule') {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'Machine exemptions are only available while a schedule controls the classroom',
      },
    };
  }

  const currentSchedule = await getCurrentSchedule(input.classroomId, new Date());
  if (currentSchedule?.id !== input.scheduleId) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Schedule is not active for this classroom' },
    };
  }

  try {
    const created = await DomainEventsService.withQueuedEvents(async (events) => {
      const exemption = await createMachineExemption({
        machineId: input.machineId,
        classroomId: input.classroomId,
        scheduleId: input.scheduleId,
        createdBy: input.createdBy,
      });
      events.publishClassroomChanged(input.classroomId);
      return exemption;
    });

    return { ok: true, data: toMachineExemptionInfo(created) };
  } catch (error: unknown) {
    if (error instanceof MachineExemptionError) {
      return { ok: false, error: { code: error.code, message: error.message } };
    }

    return {
      ok: false,
      error: { code: 'INTERNAL_SERVER_ERROR', message: 'Failed to create machine exemption' },
    };
  }
}

export async function createOperationalExemptionForClassroom(
  user: ClassroomUser,
  input: CreateOperationalMachineExemptionInput
): Promise<ClassroomResult<MachineExemptionInfo>> {
  if (!auth.isAdminToken(user)) {
    return {
      ok: false,
      error: {
        code: 'FORBIDDEN',
        message: 'Only administrators can create operational exemptions',
      },
    };
  }

  const access = await ensureUserCanAccessClassroom(user, input.classroomId);
  if (!access.ok) {
    return access;
  }

  try {
    const created = await DomainEventsService.withQueuedEvents(async (events) => {
      const exemption = await createOperationalMachineExemption({
        machineId: input.machineId,
        classroomId: input.classroomId,
        durationHours: input.durationHours,
        reason: input.reason,
        createdBy: input.createdBy,
      });
      events.publishClassroomChanged(input.classroomId);
      return exemption;
    });

    return { ok: true, data: toMachineExemptionInfo(created) };
  } catch (error: unknown) {
    if (error instanceof MachineExemptionError) {
      return { ok: false, error: { code: error.code, message: error.message } };
    }

    return {
      ok: false,
      error: {
        code: 'INTERNAL_SERVER_ERROR',
        message: 'Failed to create operational machine exemption',
      },
    };
  }
}

export async function deleteExemptionForClassroom(
  user: ClassroomUser,
  exemptionId: string
): Promise<ClassroomResult<{ success: true }>> {
  const existing = await getMachineExemptionById(exemptionId);
  if (!existing) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Exemption not found' } };
  }

  const access = await ensureUserCanAccessClassroom(user, existing.classroomId);
  if (!access.ok) {
    return access;
  }

  if (existing.source === 'operational' && !auth.isAdminToken(user)) {
    return {
      ok: false,
      error: {
        code: 'FORBIDDEN',
        message: 'Only administrators can revoke operational exemptions',
      },
    };
  }

  const deleted = await DomainEventsService.withQueuedEvents(async (events) => {
    const removed = await deleteMachineExemption(exemptionId);
    if (removed) {
      events.publishClassroomChanged(removed.classroomId);
    }
    return removed;
  });
  if (!deleted) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Exemption not found' } };
  }
  return { ok: true, data: { success: true } };
}

export async function listExemptionsForClassroom(
  user: ClassroomUser,
  classroomId: string
): Promise<ClassroomResult<{ classroomId: string; exemptions: MachineExemptionInfo[] }>> {
  const access = await ensureUserCanAccessClassroom(user, classroomId);
  if (!access.ok) {
    return access;
  }

  const rows = await getActiveMachineExemptionsByClassroom(classroomId, new Date());
  return {
    ok: true,
    data: {
      classroomId,
      exemptions: rows.map(toMachineExemptionInfo),
    },
  };
}
