import { z } from 'zod';

export const ClassroomMachineStatus = z.enum(['online', 'stale', 'offline']);
export type ClassroomMachineStatus = z.infer<typeof ClassroomMachineStatus>;

export const ClassroomStatus = z.enum(['operational', 'degraded', 'offline']);
export type ClassroomStatus = z.infer<typeof ClassroomStatus>;

export const CLASSROOM_MACHINE_ONLINE_THRESHOLD_MINUTES = 5;
export const CLASSROOM_MACHINE_STALE_THRESHOLD_MINUTES = 15;

export function calculateClassroomMachineStatus(
  lastSeen: Date | null,
  now: Date = new Date()
): ClassroomMachineStatus {
  if (!lastSeen) return 'offline';

  const diffMs = now.getTime() - lastSeen.getTime();
  const diffMinutes = diffMs / (1000 * 60);

  if (diffMinutes <= CLASSROOM_MACHINE_ONLINE_THRESHOLD_MINUTES) return 'online';
  if (diffMinutes <= CLASSROOM_MACHINE_STALE_THRESHOLD_MINUTES) return 'stale';
  return 'offline';
}

export function calculateClassroomStatus(
  machines: { status: ClassroomMachineStatus }[]
): ClassroomStatus {
  if (machines.length === 0) return 'operational';

  const onlineCount = machines.filter((m) => m.status === 'online').length;
  const offlineCount = machines.filter((m) => m.status === 'offline').length;

  if (onlineCount === machines.length) return 'operational';
  if (offlineCount === machines.length) return 'offline';
  return 'degraded';
}

export const CurrentGroupSource = z.enum(['manual', 'schedule', 'default', 'none']);
export type CurrentGroupSource = z.infer<typeof CurrentGroupSource>;

export function resolveCurrentGroup(params: {
  activeGroupId: string | null;
  activeUnrestricted?: boolean;
  scheduleGroupId: string | null;
  defaultGroupId: string | null;
}): { id: string | null; source: CurrentGroupSource } {
  const { activeGroupId, activeUnrestricted = false, scheduleGroupId, defaultGroupId } = params;

  if (activeUnrestricted) {
    return { id: null, source: 'manual' };
  }
  if (activeGroupId !== null && activeGroupId.length > 0) {
    return { id: activeGroupId, source: 'manual' };
  }
  if (scheduleGroupId !== null && scheduleGroupId.length > 0) {
    return { id: scheduleGroupId, source: 'schedule' };
  }
  if (defaultGroupId !== null && defaultGroupId.length > 0) {
    return { id: defaultGroupId, source: 'default' };
  }
  return { id: null, source: 'none' };
}
