import { getCurrentSchedule, getCurrentSchedulesByClassroomIds } from './schedule-storage.js';
import { getActiveMachineExemption } from './exemption-storage.js';
import {
  buildClassroomPolicyScope,
  toEffectivePolicyContext,
  toLegacyWhitelistUrlResult,
  type ClassroomPolicyScope,
  type ClassroomPolicyScopeSource,
  type EffectivePolicyContext,
  type WhitelistUrlResult,
} from './classroom-storage-shared.js';
import { getClassroomById } from './classroom-storage-classrooms.js';
import { getMachineByHostname } from './classroom-storage-machines.js';

async function resolveClassroomPolicyScopeForRecord(
  classroom: ClassroomPolicyScopeSource,
  now: Date
): Promise<ClassroomPolicyScope> {
  const currentSchedule = await getCurrentSchedule(classroom.id, now);
  return buildClassroomPolicyScope(classroom, currentSchedule?.groupId ?? null);
}

export async function resolveMachineGroupContext(
  hostname: string,
  now: Date = new Date()
): Promise<WhitelistUrlResult | null> {
  const context = await resolveEffectiveMachinePolicyContext(hostname, now);
  return context ? toLegacyWhitelistUrlResult(context) : null;
}

export async function resolveClassroomPolicyScope(
  classroomId: string,
  now: Date = new Date()
): Promise<ClassroomPolicyScope | null> {
  const classroom = await getClassroomById(classroomId);
  if (!classroom) return null;

  return await resolveClassroomPolicyScopeForRecord(classroom, now);
}

export async function resolveClassroomPolicyScopesForClassrooms(
  classroomRecords: ClassroomPolicyScopeSource[],
  now: Date = new Date()
): Promise<Map<string, ClassroomPolicyScope>> {
  const normalizedClassrooms = classroomRecords.filter((classroom) => classroom.id.length > 0);
  const scheduleMap = await getCurrentSchedulesByClassroomIds(
    normalizedClassrooms.map((classroom) => classroom.id),
    now
  );

  return new Map(
    normalizedClassrooms.map((classroom) => [
      classroom.id,
      buildClassroomPolicyScope(classroom, scheduleMap.get(classroom.id)?.groupId ?? null),
    ])
  );
}

export async function resolveEffectiveClassroomPolicyContext(
  classroomId: string,
  now: Date = new Date()
): Promise<EffectivePolicyContext | null> {
  const scope = await resolveClassroomPolicyScope(classroomId, now);
  return scope ? toEffectivePolicyContext(scope) : null;
}

export async function resolveEffectiveMachinePolicyContext(
  hostname: string,
  now: Date = new Date()
): Promise<EffectivePolicyContext | null> {
  const machine = await getMachineByHostname(hostname);
  if (!machine) return null;

  const classroomId = machine.classroomId;
  if (!classroomId) return null;

  const classroom = await getClassroomById(classroomId);
  if (!classroom) return null;

  const scope = await resolveClassroomPolicyScopeForRecord(classroom, now);
  return toEffectivePolicyContext(scope);
}

export async function resolveMachineEnforcementContext(
  hostname: string,
  now: Date = new Date()
): Promise<WhitelistUrlResult | null> {
  const context = await resolveEffectiveMachineEnforcementPolicyContext(hostname, now);
  return context ? toLegacyWhitelistUrlResult(context) : null;
}

export async function resolveEffectiveMachineEnforcementPolicyContext(
  hostname: string,
  now: Date = new Date()
): Promise<EffectivePolicyContext | null> {
  const machine = await getMachineByHostname(hostname);
  if (!machine) return null;

  const classroomId = machine.classroomId;
  if (!classroomId) return null;

  const classroom = await getClassroomById(classroomId);
  if (!classroom) return null;

  const active = await getActiveMachineExemption(machine.id, classroomId, now);
  if (active) {
    if (active.groupId) {
      return {
        classroomId: classroom.id,
        classroomName: classroom.name,
        groupId: active.groupId,
        mode: 'grouped',
        reason: 'exemption',
      };
    }
    return {
      classroomId: classroom.id,
      classroomName: classroom.name,
      groupId: null,
      mode: 'unrestricted',
      reason: 'exemption',
    };
  }

  const scope = await resolveClassroomPolicyScopeForRecord(classroom, now);
  return toEffectivePolicyContext(scope);
}

export async function resolveClassroomGroupContext(
  classroomId: string,
  now: Date = new Date()
): Promise<WhitelistUrlResult | null> {
  const context = await resolveEffectiveClassroomPolicyContext(classroomId, now);
  return context ? toLegacyWhitelistUrlResult(context) : null;
}

export async function getWhitelistUrlForMachine(
  hostname: string
): Promise<WhitelistUrlResult | null> {
  return await resolveMachineEnforcementContext(hostname);
}
