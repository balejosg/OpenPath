import { createHash } from 'node:crypto';
import { sanitizeSlug, resolveCurrentGroup, type CurrentGroupSource } from '@openpath/shared';
import type { Classroom, MachineStatus } from '../types/index.js';
import { classrooms, machines } from '../db/index.js';
import { UNRESTRICTED_GROUP_ID } from './exemption-storage.js';

export type DBClassroom = typeof classrooms.$inferSelect;
export type DBMachine = typeof machines.$inferSelect;

export interface ClassroomWithCount {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
  activeGroupId: string | null;
  captivePortalDomains: string[];
  createdAt: Date;
  updatedAt: Date;
  machineCount: number;
}

export interface ClassroomPolicyScopeSource {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
  activeGroupId: string | null;
}

export interface WhitelistUrlResult {
  groupId: string;
  classroomId: string;
  classroomName: string;
}

export type EffectivePolicyContextMode = 'grouped' | 'unrestricted';
export type EffectivePolicyContextReason = CurrentGroupSource | 'exemption';

export interface EffectivePolicyContext {
  classroomId: string;
  classroomName: string;
  groupId: string | null;
  mode: EffectivePolicyContextMode;
  reason: EffectivePolicyContextReason;
}

export interface PolicyGroupIdSource {
  mode: EffectivePolicyContextMode;
  groupId: string | null;
}

export interface ClassroomPolicyScope {
  classroomId: string;
  classroomName: string;
  classroomDisplayName: string;
  defaultGroupId: string | null;
  activeGroupId: string | null;
  currentGroupId: string | null;
  currentGroupSource: CurrentGroupSource;
  mode: EffectivePolicyContextMode;
}

export interface ClassroomStats {
  classrooms: number;
  machines: number;
  classroomsWithActiveGroup: number;
}

export function toMachineDisplayHostname(
  machine: Pick<DBMachine, 'hostname' | 'reportedHostname'>
): string {
  const reportedHostname = machine.reportedHostname?.trim();
  return reportedHostname ?? machine.hostname;
}

export function buildMachineKey(classroomId: string, reportedHostname: string): string {
  const normalizedHostname = reportedHostname.trim().toLowerCase();
  const safeHostname = sanitizeSlug(normalizedHostname).slice(0, 220) || 'machine';
  const classroomHash = createHash('sha256').update(classroomId).digest('hex').slice(0, 12);
  return `${safeHostname}--${classroomHash}`;
}

function normalizeWindowsMachineHostname(hostname: string): string {
  return hostname
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '');
}

export function machineHostnameMatches(
  machine: Pick<DBMachine, 'hostname' | 'reportedHostname'>,
  hostname: string
): boolean {
  const candidate = hostname.trim().toLowerCase();
  if (!candidate) {
    return false;
  }

  const normalizedPersisted = machine.hostname.trim().toLowerCase();
  const normalizedReported = machine.reportedHostname?.trim().toLowerCase();
  if (candidate === normalizedPersisted || candidate === normalizedReported) {
    return true;
  }

  return (
    normalizedPersisted.includes('--') &&
    candidate === normalizeWindowsMachineHostname(normalizedPersisted)
  );
}

export function buildClassroomPolicyScope(
  classroom: ClassroomPolicyScopeSource,
  scheduleGroupId: string | null
): ClassroomPolicyScope {
  const currentGroup = resolveCurrentGroup({
    activeGroupId: classroom.activeGroupId,
    scheduleGroupId,
    defaultGroupId: classroom.defaultGroupId,
  });

  return {
    classroomId: classroom.id,
    classroomName: classroom.name,
    classroomDisplayName: classroom.displayName,
    defaultGroupId: classroom.defaultGroupId,
    activeGroupId: classroom.activeGroupId,
    currentGroupId: currentGroup.id,
    currentGroupSource: currentGroup.source,
    mode: currentGroup.id === null ? 'unrestricted' : 'grouped',
  };
}

export function toEffectivePolicyContext(scope: ClassroomPolicyScope): EffectivePolicyContext {
  return {
    classroomId: scope.classroomId,
    classroomName: scope.classroomName,
    groupId: scope.currentGroupId,
    mode: scope.mode,
    reason: scope.currentGroupSource,
  };
}

export function serializePolicyGroupId(context: PolicyGroupIdSource): string | null {
  return context.mode === 'unrestricted' ? UNRESTRICTED_GROUP_ID : context.groupId;
}

export function toLegacyWhitelistUrlResult(context: EffectivePolicyContext): WhitelistUrlResult {
  return {
    groupId: serializePolicyGroupId(context) ?? '',
    classroomId: context.classroomId,
    classroomName: context.classroomName,
  };
}

export function toClassroomType(classroom: DBClassroom, machineList: DBMachine[] = []): Classroom {
  return {
    id: classroom.id,
    name: classroom.name,
    displayName: classroom.displayName,
    captivePortalDomains: classroom.captivePortalDomains,
    machines: machineList.map((machine) => ({
      id: machine.id,
      hostname: toMachineDisplayHostname(machine),
      classroomId: machine.classroomId,
      version: machine.version ?? undefined,
      lastSeen: machine.lastSeen?.toISOString() ?? null,
      status: 'unknown' as MachineStatus,
    })),
    createdAt: classroom.createdAt?.toISOString() ?? new Date().toISOString(),
    updatedAt: classroom.updatedAt?.toISOString() ?? new Date().toISOString(),
    defaultGroupId: classroom.defaultGroupId,
    activeGroupId: classroom.activeGroupId,
  };
}
