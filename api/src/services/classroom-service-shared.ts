import {
  calculateClassroomMachineStatus as calculateMachineStatus,
  calculateClassroomStatus,
  type ClassroomMachineStatus as SharedMachineStatus,
  type ClassroomStatus as SharedClassroomStatus,
  type CurrentGroupSource as SharedCurrentGroupSource,
} from '@openpath/shared/classroom-status';
import type { JWTPayload } from '../types/index.js';

export type MachineStatus = SharedMachineStatus;
export type ClassroomStatus = SharedClassroomStatus;
export type CurrentGroupSource = SharedCurrentGroupSource;

export interface RegisterMachineInput {
  hostname: string;
  classroomId?: string | undefined;
  classroomName?: string | undefined;
  version?: string | undefined;
}

export interface MachineInfo {
  id: string;
  hostname: string;
  lastSeen: string | null;
  status: MachineStatus;
}

export interface MachineRegistrationResult {
  hostname: string;
  classroomId: string;
  classroomName: string;
  version?: string;
  lastSeen: string;
}

export interface ClassroomWithMachines {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
  activeGroupId: string | null;
  captivePortalDomains: string[];
  createdAt: string;
  updatedAt: string;
  currentGroupId: string | null;
  currentGroupSource: CurrentGroupSource;
  machines: MachineInfo[];
  machineCount: number;
  status: ClassroomStatus;
  onlineMachineCount: number;
}

export interface ClassroomAccessScope {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
  activeGroupId: string | null;
  currentGroupId: string | null;
  currentGroupSource: CurrentGroupSource;
}

export interface UpdateClassroomData {
  name?: string;
  displayName?: string;
  defaultGroupId?: string;
  activeGroupId?: string;
  captivePortalDomains?: string[];
}

export interface CreateClassroomInput {
  name: string;
  displayName: string;
  defaultGroupId?: string | undefined;
  captivePortalDomains?: string[] | undefined;
}

export interface SetActiveGroupInput {
  id: string;
  groupId: string | null;
}

export interface CreateMachineExemptionInput {
  machineId: string;
  classroomId: string;
  scheduleId: string;
  createdBy: string;
  groupId?: string | null | undefined;
}

export interface CreateOperationalMachineExemptionInput {
  machineId: string;
  classroomId: string;
  durationHours: number;
  reason: string;
  createdBy: string;
}

export interface MachineExemptionInfo {
  id: string;
  machineId: string;
  machineHostname?: string;
  classroomId: string;
  scheduleId: string | null;
  groupId: string | null;
  source: 'schedule' | 'operational';
  reason: string | null;
  createdBy: string | null;
  createdAt: string | null;
  expiresAt: string;
}

export interface ClassroomMachineListItem {
  id: string;
  hostname: string;
  classroomId: string | null;
  version: string | null;
  lastSeen: string | null;
  hasDownloadToken: boolean;
  downloadTokenLastRotatedAt: string | null;
}

export interface RotateMachineTokenResult {
  whitelistUrl: string;
}

export type ClassroomServiceError =
  | { code: 'BAD_REQUEST'; message: string }
  | { code: 'FORBIDDEN'; message: string }
  | { code: 'NOT_FOUND'; message: string }
  | { code: 'CONFLICT'; message: string }
  | { code: 'INTERNAL_SERVER_ERROR'; message: string };

export type ClassroomResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: ClassroomServiceError };

export type ClassroomAccessResult =
  | { ok: true; data: ClassroomAccessScope }
  | { ok: false; error: { code: 'FORBIDDEN' | 'NOT_FOUND'; message: string } };

export function formatErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function normalizeCurrentGroupSource(value: unknown): CurrentGroupSource {
  return value === 'manual' || value === 'schedule' || value === 'default' || value === 'none'
    ? value
    : 'none';
}

export function toMachineInfo(machine: {
  id: string;
  hostname: string;
  lastSeen: Date | null;
}): MachineInfo {
  return {
    id: machine.id,
    hostname: machine.hostname,
    lastSeen: machine.lastSeen?.toISOString() ?? null,
    status: calculateMachineStatus(machine.lastSeen),
  };
}

export function buildClassroomWithMachines(
  classroom: {
    id: string;
    name: string;
    displayName: string;
    defaultGroupId: string | null;
    activeGroupId: string | null;
    captivePortalDomains?: string[] | null;
    createdAt?: Date | null;
    updatedAt?: Date | null;
  },
  rawMachines: {
    id: string;
    hostname: string;
    lastSeen: Date | null;
  }[],
  scope?: {
    currentGroupId: string | null;
    currentGroupSource: unknown;
  } | null
): ClassroomWithMachines {
  const machines = rawMachines.map(toMachineInfo);
  const status = calculateClassroomStatus(machines);
  const onlineMachineCount = machines.filter((machine) => machine.status === 'online').length;

  return {
    id: classroom.id,
    name: classroom.name,
    displayName: classroom.displayName,
    defaultGroupId: classroom.defaultGroupId,
    activeGroupId: classroom.activeGroupId,
    captivePortalDomains: classroom.captivePortalDomains ?? [],
    createdAt: (classroom.createdAt ?? new Date()).toISOString(),
    updatedAt: (classroom.updatedAt ?? new Date()).toISOString(),
    currentGroupId: scope?.currentGroupId ?? null,
    currentGroupSource: normalizeCurrentGroupSource(scope?.currentGroupSource),
    machines,
    machineCount: machines.length,
    status,
    onlineMachineCount,
  };
}

export function toMachineExemptionInfo(entry: {
  id: string;
  machineId: string;
  machineHostname?: string;
  classroomId: string;
  scheduleId: string | null;
  groupId?: string | null;
  source?: string | null;
  reason?: string | null;
  createdBy: string | null;
  createdAt: Date | null;
  expiresAt: Date;
}): MachineExemptionInfo {
  return {
    id: entry.id,
    machineId: entry.machineId,
    classroomId: entry.classroomId,
    scheduleId: entry.scheduleId,
    groupId: entry.groupId ?? null,
    source: entry.source === 'operational' ? 'operational' : 'schedule',
    reason: entry.reason ?? null,
    createdBy: entry.createdBy,
    createdAt: entry.createdAt ? entry.createdAt.toISOString() : null,
    expiresAt: entry.expiresAt.toISOString(),
    ...(entry.machineHostname !== undefined ? { machineHostname: entry.machineHostname } : {}),
  };
}

export function toClassroomMachineListItem(machine: {
  id: string;
  hostname: string;
  classroomId: string | null;
  version: string | null;
  lastSeen: Date | null;
  downloadTokenHash: string | null;
  downloadTokenLastRotatedAt: Date | null;
}): ClassroomMachineListItem {
  return {
    id: machine.id,
    hostname: machine.hostname,
    classroomId: machine.classroomId,
    version: machine.version,
    lastSeen: machine.lastSeen?.toISOString() ?? null,
    hasDownloadToken: machine.downloadTokenHash !== null,
    downloadTokenLastRotatedAt: machine.downloadTokenLastRotatedAt?.toISOString() ?? null,
  };
}

export type ClassroomUser = JWTPayload;
