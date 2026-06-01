/**
 * OpenPath - Strict Internet Access Control
 *
 * Public classroom storage facade. Internal responsibilities are split across:
 * - classroom-storage-shared.ts
 * - classroom-storage-classrooms.ts
 * - classroom-storage-machines.ts
 * - classroom-storage-policy.ts
 */

import { logger } from './logger.js';
import {
  buildMachineKey,
  machineHostnameMatches,
  serializePolicyGroupId,
  toClassroomType,
  toMachineDisplayHostname,
  type DBClassroom,
} from './classroom-storage-shared.js';
import {
  createClassroom,
  deleteClassroom,
  getAllClassrooms,
  getClassroomById,
  getClassroomByName,
  getCurrentGroupId,
  getStats,
  setActiveGroup,
  updateClassroom,
} from './classroom-storage-classrooms.js';
import {
  deleteMachine,
  getAllMachines,
  getMachineByDownloadTokenHash,
  getMachineByHostname,
  getMachineById,
  getMachineOnlyByHostname,
  getMachineTokenStatus,
  getMachinesByClassroom,
  getMachinesByClassroomIds,
  registerMachine,
  removeMachinesByClassroom,
  setMachineDownloadTokenHash,
  updateMachineLastSeen,
} from './classroom-storage-machines.js';
import {
  getWhitelistUrlForMachine,
  resolveClassroomGroupContext,
  resolveClassroomPolicyScope,
  resolveClassroomPolicyScopesForClassrooms,
  resolveEffectiveClassroomPolicyContext,
  resolveEffectiveMachineEnforcementPolicyContext,
  resolveEffectiveMachinePolicyContext,
  resolveMachineEnforcementContext,
  resolveMachineGroupContext,
} from './classroom-storage-policy.js';
import type { Classroom, MachineStatus } from '../types/index.js';
import type {
  IClassroomStorage,
  CreateClassroomData,
  UpdateClassroomData,
} from '../types/storage.js';

export {
  buildMachineKey,
  createClassroom,
  deleteClassroom,
  deleteMachine,
  getAllClassrooms,
  getAllMachines,
  getClassroomById,
  getClassroomByName,
  getCurrentGroupId,
  getMachineByDownloadTokenHash,
  getMachineByHostname,
  getMachineById,
  getMachineOnlyByHostname,
  getMachineTokenStatus,
  getMachinesByClassroom,
  getMachinesByClassroomIds,
  getStats,
  getWhitelistUrlForMachine,
  machineHostnameMatches,
  registerMachine,
  removeMachinesByClassroom,
  resolveClassroomGroupContext,
  resolveClassroomPolicyScope,
  resolveClassroomPolicyScopesForClassrooms,
  resolveEffectiveClassroomPolicyContext,
  resolveEffectiveMachineEnforcementPolicyContext,
  resolveEffectiveMachinePolicyContext,
  resolveMachineEnforcementContext,
  resolveMachineGroupContext,
  serializePolicyGroupId,
  setActiveGroup,
  setMachineDownloadTokenHash,
  toMachineDisplayHostname,
  updateClassroom,
  updateMachineLastSeen,
};

export type {
  ClassroomPolicyScope,
  ClassroomPolicyScopeSource,
  ClassroomStats,
  ClassroomWithCount,
  DBClassroom,
  DBMachine,
  EffectivePolicyContext,
  EffectivePolicyContextMode,
  EffectivePolicyContextReason,
  PolicyGroupIdSource,
  WhitelistUrlResult,
} from './classroom-storage-shared.js';

export const classroomStorage: IClassroomStorage = {
  getAllClassrooms: async () => {
    const allClassrooms = await getAllClassrooms();
    const result: Classroom[] = [];

    for (const classroom of allClassrooms) {
      const machineList = await getMachinesByClassroom(classroom.id);
      const classroomType = toClassroomType(
        {
          id: classroom.id,
          name: classroom.name,
          displayName: classroom.displayName,
          defaultGroupId: classroom.defaultGroupId,
          activeGroupId: classroom.activeGroupId,
          captivePortalDomains: classroom.captivePortalDomains,
          createdAt: classroom.createdAt,
          updatedAt: classroom.updatedAt,
        } as DBClassroom,
        machineList
      );
      classroomType.machineCount = classroom.machineCount;
      result.push(classroomType);
    }

    return result;
  },
  getClassroomById: async (id: string) => {
    const classroom = await getClassroomById(id);
    if (!classroom) return null;
    const machineList = await getMachinesByClassroom(id);
    return toClassroomType(classroom, machineList);
  },
  getClassroomByName: async (name: string) => {
    const classroom = await getClassroomByName(name);
    if (!classroom) return null;
    const machineList = await getMachinesByClassroom(classroom.id);
    return toClassroomType(classroom, machineList);
  },
  createClassroom: async (data: CreateClassroomData) => {
    const classroom = await createClassroom(data);
    return toClassroomType(classroom);
  },
  updateClassroom: async (id: string, data: UpdateClassroomData) => {
    const classroom = await updateClassroom(id, data);
    if (!classroom) return null;
    const machineList = await getMachinesByClassroom(id);
    return toClassroomType(classroom, machineList);
  },
  deleteClassroom,
  addMachine: async (classroomId: string, hostname: string) => {
    const machine = await registerMachine({
      hostname: buildMachineKey(classroomId, hostname),
      reportedHostname: hostname,
      classroomId,
    });
    return {
      id: machine.id,
      hostname: toMachineDisplayHostname(machine),
      classroomId: machine.classroomId,
      version: machine.version ?? undefined,
      lastSeen: machine.lastSeen?.toISOString() ?? null,
      status: 'unknown' as MachineStatus,
    };
  },
  removeMachine: async (classroomId: string, hostname: string) => {
    const machine = await getMachineByHostname(hostname);
    if (machine?.classroomId !== classroomId) return false;
    return await deleteMachine(hostname);
  },
  getMachineByHostname: async (hostname: string) => {
    const machine = await getMachineByHostname(hostname);
    if (!machine?.classroomId) return null;
    const classroom = await getClassroomById(machine.classroomId);
    if (!classroom) return null;
    return {
      classroom: toClassroomType(classroom),
      machine: {
        id: machine.id,
        hostname: toMachineDisplayHostname(machine),
        classroomId: machine.classroomId,
        version: machine.version ?? undefined,
        lastSeen: machine.lastSeen?.toISOString() ?? null,
        status: 'unknown' as MachineStatus,
      },
    };
  },
  updateMachineStatus: async (hostname: string, _status: 'online' | 'offline') => {
    const machine = await updateMachineLastSeen(hostname);
    return machine !== null;
  },
};

logger.debug('Classroom storage initialized');

export default classroomStorage;
