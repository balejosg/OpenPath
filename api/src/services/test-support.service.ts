import * as classroomStorage from '../lib/classroom-storage.js';
import DomainEventsService from './domain-events.service.js';

export interface MachineContextSnapshot {
  classroom: {
    id: string;
    defaultGroupId: string | null;
    activeGroupId: string | null;
  } | null;
  context: Awaited<ReturnType<typeof classroomStorage.resolveMachineEnforcementContext>>;
  effectiveContext: Awaited<
    ReturnType<typeof classroomStorage.resolveEffectiveMachineEnforcementPolicyContext>
  >;
  machine: {
    id: string;
    hostname: string;
    reportedHostname: string | null;
    classroomId: string | null;
  } | null;
}

export async function getMachineContextSnapshot(
  hostname: string,
  evaluatedAt: Date
): Promise<MachineContextSnapshot> {
  const machine = await classroomStorage.getMachineByHostname(hostname);
  const effectiveContext = await classroomStorage.resolveEffectiveMachineEnforcementPolicyContext(
    hostname,
    evaluatedAt
  );
  const context = await classroomStorage.resolveMachineEnforcementContext(hostname, evaluatedAt);
  const classroom = machine?.classroomId
    ? await classroomStorage.getClassroomById(machine.classroomId)
    : null;

  return {
    machine: machine
      ? {
          id: machine.id,
          hostname: machine.hostname,
          reportedHostname: machine.reportedHostname,
          classroomId: machine.classroomId,
        }
      : null,
    effectiveContext,
    context,
    classroom: classroom
      ? {
          id: classroom.id,
          defaultGroupId: classroom.defaultGroupId,
          activeGroupId: classroom.activeGroupId,
        }
      : null,
  };
}

export async function tickScheduleBoundaries(at: Date): Promise<{ at: string }> {
  await DomainEventsService.tickScheduleBoundaryEvents(at);
  return { at: at.toISOString() };
}

export default {
  getMachineContextSnapshot,
  tickScheduleBoundaries,
};
