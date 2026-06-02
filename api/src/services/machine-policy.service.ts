import * as classroomStorage from '../lib/classroom-storage.js';
import * as groupsStorage from '../lib/groups-storage.js';
import { hashMachineToken } from '../lib/machine-download-token.js';
import { buildStaticEtag, buildWhitelistEtag } from '../lib/server-assets.js';
import {
  getBearerTokenValue,
  resolveMachineTokenAccess,
  type AuthenticatedMachine,
} from '../lib/server-request-auth.js';

const FAIL_OPEN_RESPONSE = '#DESACTIVADO\n';

export type MachinePolicyServiceError =
  | { code: 'UNAUTHORIZED'; message: string }
  | { code: 'FORBIDDEN'; message: string }
  | { code: 'NOT_FOUND'; message: string };

export type MachinePolicyResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: MachinePolicyServiceError };

export type MachineWhitelistDelivery =
  | {
      kind: 'content';
      body: string;
      cacheControl: string;
      etag?: string;
      pragma?: string;
    }
  | {
      kind: 'not-modified';
      cacheControl: string;
      etag: string;
    };

export interface MachineEventsAccessContext {
  classroomId: string;
  groupId: string;
  machine: AuthenticatedMachine;
}

export interface MachineClientConfig {
  captivePortalDomains: string[];
}

function failOpenResponse(): MachineWhitelistDelivery {
  return {
    kind: 'content',
    body: FAIL_OPEN_RESPONSE,
    cacheControl: 'no-store, max-age=0',
    pragma: 'no-cache',
  };
}

async function touchMachine(hostname: string): Promise<void> {
  await classroomStorage.updateMachineLastSeen(hostname);
}

function matchesIfNoneMatchHeader(ifNoneMatchHeader: string | undefined, etag: string): boolean {
  if (typeof ifNoneMatchHeader !== 'string') {
    return false;
  }

  const trimmed = ifNoneMatchHeader.trim();
  if (trimmed === '*') {
    return true;
  }

  return trimmed
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean)
    .some((value) => value === etag || (value.startsWith('W/') && value.slice(2).trim() === etag));
}

export async function resolveMachineWhitelist(
  machineToken: string | undefined,
  currentEvaluationTime: Date,
  ifNoneMatchHeader: string | undefined
): Promise<MachineWhitelistDelivery> {
  if (!machineToken) {
    return failOpenResponse();
  }

  const tokenHash = hashMachineToken(machineToken);
  const machine = await classroomStorage.getMachineByDownloadTokenHash(tokenHash);
  if (!machine) {
    return failOpenResponse();
  }

  const effectiveContext = await classroomStorage.resolveEffectiveMachineEnforcementPolicyContext(
    machine.hostname,
    currentEvaluationTime
  );
  if (!effectiveContext) {
    return failOpenResponse();
  }

  if (effectiveContext.mode === 'unrestricted') {
    const etag = buildStaticEtag('openpath:unrestricted');
    if (matchesIfNoneMatchHeader(ifNoneMatchHeader, etag)) {
      await touchMachine(machine.hostname);
      return {
        kind: 'not-modified',
        etag,
        cacheControl: 'private, no-cache',
      };
    }

    await touchMachine(machine.hostname);
    return {
      kind: 'content',
      body: FAIL_OPEN_RESPONSE,
      etag,
      cacheControl: 'private, no-cache',
    };
  }

  if (!effectiveContext.groupId) {
    return failOpenResponse();
  }

  const group = await groupsStorage.getGroupMetaById(effectiveContext.groupId);
  if (!group) {
    return failOpenResponse();
  }

  const content = await groupsStorage.exportGroup(effectiveContext.groupId);
  if (!content) {
    return failOpenResponse();
  }

  const etag = buildWhitelistEtag({
    groupId: group.id,
    updatedAt: group.updatedAt,
    enabled: group.enabled,
    content,
  });
  if (matchesIfNoneMatchHeader(ifNoneMatchHeader, etag)) {
    await touchMachine(machine.hostname);
    return {
      kind: 'not-modified',
      etag,
      cacheControl: 'private, no-cache',
    };
  }

  await touchMachine(machine.hostname);
  return {
    kind: 'content',
    body: content,
    etag,
    cacheControl: 'private, no-cache',
  };
}

export async function resolveMachineClientConfig(
  machine: AuthenticatedMachine
): Promise<MachinePolicyResult<MachineClientConfig>> {
  if (!machine.classroomId) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'No classroom for this machine' },
    };
  }

  const classroom = await classroomStorage.getClassroomById(machine.classroomId);
  if (!classroom) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'No classroom for this machine' },
    };
  }

  return {
    ok: true,
    data: {
      captivePortalDomains: classroom.captivePortalDomains,
    },
  };
}

export async function resolveMachineEventsAccess(params: {
  authorizationHeader?: string | undefined;
  queryToken?: string | string[] | undefined;
}): Promise<MachinePolicyResult<MachineEventsAccessContext>> {
  const machineToken =
    getBearerTokenValue(params.authorizationHeader) ??
    (typeof params.queryToken === 'string' ? params.queryToken.trim() : '');
  if (!machineToken) {
    return {
      ok: false,
      error: {
        code: 'UNAUTHORIZED',
        message: 'Machine token required (Authorization: Bearer or query param)',
      },
    };
  }

  const machine = await resolveMachineTokenAccess(machineToken);
  if (!machine) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Invalid machine token' },
    };
  }

  const effectiveContext = await classroomStorage.resolveEffectiveMachineEnforcementPolicyContext(
    machine.hostname
  );
  if (!effectiveContext) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'No active group for this machine' },
    };
  }

  const groupId = classroomStorage.serializePolicyGroupId(effectiveContext);
  if (!groupId) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'No active group for this machine' },
    };
  }

  return {
    ok: true,
    data: {
      machine,
      classroomId: effectiveContext.classroomId,
      groupId,
    },
  };
}

export { FAIL_OPEN_RESPONSE };

export default {
  resolveMachineClientConfig,
  resolveMachineEventsAccess,
  resolveMachineWhitelist,
};
