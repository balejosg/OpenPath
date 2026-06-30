import { z } from 'zod';

export const classroomIdSchema = z.object({ id: z.string() });

export const classroomListExemptionsSchema = z.object({
  classroomId: z.string().min(1),
});

export const createClassroomInputSchema = z.object({
  name: z.string().min(1),
  displayName: z.string().optional(),
  defaultGroupId: z.string().optional(),
  captivePortalDomains: z.array(z.string()).optional(),
});

export const updateClassroomInputSchema = z.object({
  id: z.string(),
  displayName: z.string().optional(),
  defaultGroupId: z.string().nullable().optional(),
  captivePortalDomains: z.array(z.string()).optional(),
});

export const setActiveGroupInputSchema = z.object({
  id: z.string(),
  groupId: z.string().nullable(),
});

export const createClassroomExemptionInputSchema = z.object({
  machineId: z.string().min(1),
  classroomId: z.string().min(1),
  scheduleId: z.uuid(),
  groupId: z.string().min(1).nullable().optional(),
});

export const createOperationalClassroomExemptionInputSchema = z.object({
  machineId: z.string().min(1),
  classroomId: z.string().min(1),
  durationHours: z.number().int().min(1).max(24),
  reason: z.string().trim().min(3).max(500),
});

export const deleteExemptionInputSchema = z.object({
  id: z.string().min(1),
});

export const registerMachineInputSchema = z.object({
  hostname: z.string().min(1),
  classroomId: z.string().optional(),
  classroomName: z.string().optional(),
  version: z.string().optional(),
});

export const listMachinesInputSchema = z.object({
  classroomId: z.string().optional(),
});

export const deleteMachineInputSchema = z.object({
  hostname: z.string(),
});

export const rotateMachineTokenInputSchema = z.object({
  machineId: z.string(),
});
