import { normalizeManualRequestDomain } from '@openpath/shared/domain';
import * as classroomStorage from '../lib/classroom-storage.js';
import { logger } from '../lib/logger.js';
import { normalizeHostInput } from '../lib/machine-proof.js';
import { parseWhitelistDomain } from '../lib/public-request-input.js';
import { resolveMachineTokenHostnameAccess } from '../lib/server-request-auth.js';
import type { AuthenticatedMachine } from '../lib/server-request-auth.js';
import { createRequest } from './request-command.service.js';
import type { RequestCreationInput } from './request-command.service.js';
import type { RequestResult, RequestServiceError } from './request-service-shared.js';
import type { EffectivePolicyContext } from '../lib/classroom-storage.js';

export type PublicRequestServiceError = RequestServiceError;
export type PublicRequestResult<T> = RequestResult<T>;

export interface MachineRequestContext {
  domain: string;
  groupId: string;
  machineHostname: string;
}

export interface ResolveMachineRequestAdmissionInput {
  domainRaw: string;
  hostnameRaw: string;
  logContext: string;
  token: string;
}

export interface CreateSubmittedMachineRequestInput {
  clientVersion?: string | undefined;
  domainRaw: string;
  errorType?: string | undefined;
  hostnameRaw: string;
  originHost?: string | undefined;
  originPage?: string | undefined;
  reason?: string | undefined;
  targetUrl?: string | undefined;
  token: string;
}

interface CreateMachineRequestInput extends CreateSubmittedMachineRequestInput {
  logContext: string;
  source: 'firefox-extension';
}

export interface PendingMachineRequestOutcome {
  autoApproved: false;
  domain: string;
  groupId: string;
  requestId: string;
  requestStatus: string;
  source: 'firefox-extension';
}

type MachineHostnameAccess =
  | { ok: true; machine: AuthenticatedMachine; requestedHostname: string }
  | {
      ok: false;
      error: 'invalid-token' | 'hostname-mismatch';
      requestedHostname: string;
      machine?: AuthenticatedMachine;
    };

export interface MachineRequestAdmissionDeps {
  createRequest: (
    input: RequestCreationInput
  ) => Promise<RequestResult<{ id: string; status: string }>>;
  logger: Pick<typeof logger, 'warn'>;
  resolveEffectiveMachinePolicyContext: (
    hostname: string
  ) => Promise<EffectivePolicyContext | null>;
  resolveMachineTokenHostnameAccess: (params: {
    machineToken: string;
    hostname: string;
  }) => Promise<MachineHostnameAccess>;
}

const defaultDeps: MachineRequestAdmissionDeps = {
  createRequest,
  logger,
  resolveEffectiveMachinePolicyContext: classroomStorage.resolveEffectiveMachinePolicyContext,
  resolveMachineTokenHostnameAccess,
};

function resolveDeps(deps?: Partial<MachineRequestAdmissionDeps>): MachineRequestAdmissionDeps {
  return { ...defaultDeps, ...deps };
}

export async function resolveMachineRequestAdmission(
  input: ResolveMachineRequestAdmissionInput,
  depsInput?: Partial<MachineRequestAdmissionDeps>
): Promise<PublicRequestResult<MachineRequestContext>> {
  const deps = resolveDeps(depsInput);
  const hostname = normalizeHostInput(input.hostnameRaw);
  const access = await deps.resolveMachineTokenHostnameAccess({
    machineToken: input.token,
    hostname,
  });

  if (!access.ok && access.error === 'invalid-token') {
    deps.logger.warn(`${input.logContext} rejected: invalid machine token`, { hostname });
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Invalid machine token' },
    };
  }

  if (!access.ok) {
    deps.logger.warn(`${input.logContext} rejected: hostname mismatch`, {
      requestedHostname: access.requestedHostname,
      machineHostname: access.machine?.hostname.trim().toLowerCase(),
      reportedHostname: access.machine?.reportedHostname?.trim().toLowerCase(),
    });
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Token is not valid for this hostname' },
    };
  }

  const domainParse = parseWhitelistDomain(input.domainRaw);
  if (!domainParse.ok) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: domainParse.error },
    };
  }

  const policyContext = await deps.resolveEffectiveMachinePolicyContext(access.machine.hostname);
  if (!policyContext) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'No active group found for machine hostname' },
    };
  }

  if (policyContext.mode === 'unrestricted' || !policyContext.groupId) {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'Machine classroom is unrestricted and does not require access requests',
      },
    };
  }

  return {
    ok: true,
    data: {
      domain: domainParse.domain,
      groupId: policyContext.groupId,
      machineHostname: access.machine.hostname,
    },
  };
}

async function createMachineRequestFromContext(
  input: CreateMachineRequestInput,
  context: MachineRequestContext,
  deps: MachineRequestAdmissionDeps
): Promise<PublicRequestResult<PendingMachineRequestOutcome>> {
  const domain = normalizeManualRequestDomain(context.domain);
  const created = await deps.createRequest({
    domain,
    reason: input.reason ?? 'Submitted via Firefox extension',
    groupId: context.groupId,
    source: input.source,
    machineHostname: context.machineHostname,
    ...(input.originHost ? { originHost: input.originHost } : {}),
    ...(input.originPage ? { originPage: input.originPage } : {}),
    ...(input.clientVersion ? { clientVersion: input.clientVersion } : {}),
    ...(input.errorType ? { errorType: input.errorType } : {}),
  });

  if (!created.ok) {
    return created;
  }

  return {
    ok: true,
    data: {
      autoApproved: false,
      domain,
      groupId: context.groupId,
      requestId: created.data.id,
      requestStatus: created.data.status,
      source: input.source,
    },
  };
}

async function createMachineRequest(
  input: CreateMachineRequestInput,
  depsInput?: Partial<MachineRequestAdmissionDeps>
): Promise<PublicRequestResult<PendingMachineRequestOutcome>> {
  const deps = resolveDeps(depsInput);
  const context = await resolveMachineRequestAdmission(input, deps);
  if (!context.ok) {
    return context;
  }

  return createMachineRequestFromContext(input, context.data, deps);
}

export async function createSubmittedMachineRequest(
  input: CreateSubmittedMachineRequestInput,
  deps?: Partial<MachineRequestAdmissionDeps>
): Promise<PublicRequestResult<PendingMachineRequestOutcome>> {
  return createMachineRequest(
    {
      ...input,
      logContext: 'Request submit',
      source: 'firefox-extension',
    },
    deps
  );
}

export default {
  createSubmittedMachineRequest,
  resolveMachineRequestAdmission,
};
