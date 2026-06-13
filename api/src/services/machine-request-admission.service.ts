import { config } from '../config.js';
import { withTransaction, type DbExecutor } from '../db/index.js';
import { normalizeManualRequestDomain } from '@openpath/shared/domain';
import * as classroomStorage from '../lib/classroom-storage.js';
import * as groupsStorage from '../lib/groups-storage.js';
import { logger } from '../lib/logger.js';
import { normalizeHostInput } from '../lib/machine-proof.js';
import { parseWhitelistDomain } from '../lib/public-request-input.js';
import { resolveMachineTokenHostnameAccess } from '../lib/server-request-auth.js';
import type { AuthenticatedMachine } from '../lib/server-request-auth.js';
import type { CreateRuleResult, Rule, RuleSource, RuleType } from '../lib/groups-storage.js';
import DomainEventsService from './domain-events.service.js';
import { createRequest } from './request-command.service.js';
import type { RequestCreationInput } from './request-command.service.js';
import type { RequestResult, RequestServiceError } from './request-service-shared.js';
import { createAutomaticWhitelistRule } from './whitelist-rule-command.service.js';
import type { EffectivePolicyContext } from '../lib/classroom-storage.js';
import {
  admissionTargetMatchesBlockedPath,
  ruleValues,
} from './machine-request-admission-policy.js';

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

export interface DecideAutoMachineRequestInput {
  diagnosticContext?: string | undefined;
  domainRaw: string;
  hostnameRaw: string;
  originPage?: string | undefined;
  reason?: string | undefined;
  targetUrl?: string | undefined;
  token: string;
}

interface CreateMachineRequestInput extends CreateSubmittedMachineRequestInput {
  logContext: string;
  source: 'auto_extension' | 'firefox-extension';
}

export interface PendingMachineRequestOutcome {
  autoApproved: false;
  domain: string;
  groupId: string;
  requestId: string;
  requestStatus: string;
  source: 'auto_extension' | 'firefox-extension';
}

export interface ApprovedMachineRequestOutcome {
  autoApproved: true;
  domain: string;
  duplicate: boolean;
  groupId: string;
  source: 'auto_extension';
  status: 'approved' | 'duplicate';
}

export type AutoMachineRequestOutcome =
  | PendingMachineRequestOutcome
  | ApprovedMachineRequestOutcome;

type AutoMachineAdmissionDecision =
  | {
      kind: 'rejected';
      error: RequestServiceError;
    }
  | {
      kind: 'pending';
      context: MachineRequestContext;
    }
  | {
      kind: 'approved';
      context: MachineRequestContext;
    };

type MachineHostnameAccess =
  | { ok: true; machine: AuthenticatedMachine; requestedHostname: string }
  | {
      ok: false;
      error: 'invalid-token' | 'hostname-mismatch';
      requestedHostname: string;
      machine?: AuthenticatedMachine;
    };

export interface MachineRequestAdmissionDeps {
  autoApproveMachineRequests: boolean;
  createRequest: (
    input: RequestCreationInput
  ) => Promise<RequestResult<{ id: string; status: string }>>;
  createRule: (
    groupId: string,
    type: RuleType,
    value: string,
    comment?: string | null,
    source?: RuleSource,
    tx?: DbExecutor
  ) => Promise<CreateRuleResult>;
  getRulesByGroup: (groupId: string, type?: RuleType) => Promise<Rule[]>;
  isDomainBlocked: typeof groupsStorage.isDomainBlocked;
  logger: Pick<typeof logger, 'warn'>;
  publishWhitelistChanged: (groupId: string) => void;
  resolveEffectiveMachinePolicyContext: (
    hostname: string
  ) => Promise<EffectivePolicyContext | null>;
  resolveMachineTokenHostnameAccess: (params: {
    machineToken: string;
    hostname: string;
  }) => Promise<MachineHostnameAccess>;
  createTransactionalWriter: typeof DomainEventsService.createTransactionalWriter;
  withTransaction: typeof withTransaction;
}

const defaultDeps: MachineRequestAdmissionDeps = {
  autoApproveMachineRequests: config.autoApproveMachineRequests,
  createRequest,
  createRule: groupsStorage.createRule,
  getRulesByGroup: groupsStorage.getRulesByGroup,
  isDomainBlocked: groupsStorage.isDomainBlocked,
  logger,
  publishWhitelistChanged: DomainEventsService.publishWhitelistChanged.bind(DomainEventsService),
  resolveEffectiveMachinePolicyContext: classroomStorage.resolveEffectiveMachinePolicyContext,
  resolveMachineTokenHostnameAccess,
  createTransactionalWriter: DomainEventsService.createTransactionalWriter,
  withTransaction,
};

function resolveDeps(deps?: Partial<MachineRequestAdmissionDeps>): MachineRequestAdmissionDeps {
  return { ...defaultDeps, autoApproveMachineRequests: config.autoApproveMachineRequests, ...deps };
}

async function isTargetBlockedPath(
  groupId: string,
  targetUrl: string | undefined,
  deps: MachineRequestAdmissionDeps
): Promise<boolean> {
  if (!targetUrl) {
    return false;
  }

  const rules = await deps.getRulesByGroup(groupId, 'blocked_path');
  return admissionTargetMatchesBlockedPath(targetUrl, ruleValues(rules));
}

async function decideAutoMachineAdmission(
  input: DecideAutoMachineRequestInput,
  context: MachineRequestContext,
  deps: MachineRequestAdmissionDeps
): Promise<AutoMachineAdmissionDecision> {
  const blockedSubdomain = await deps.isDomainBlocked(context.groupId, context.domain);
  if (blockedSubdomain.blocked) {
    return {
      kind: 'rejected',
      error: { code: 'FORBIDDEN', message: 'Target matches a blocked subdomain rule' },
    };
  }

  if (await isTargetBlockedPath(context.groupId, input.targetUrl, deps)) {
    return {
      kind: 'rejected',
      error: { code: 'FORBIDDEN', message: 'Target URL matches a blocked path rule' },
    };
  }

  if (!deps.autoApproveMachineRequests) {
    return { kind: 'pending', context };
  }

  return { kind: 'approved', context };
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

function requestDomainForSource(
  input: Pick<CreateMachineRequestInput, 'source'>,
  context: MachineRequestContext
): string {
  return input.source === 'firefox-extension'
    ? normalizeManualRequestDomain(context.domain)
    : context.domain;
}

async function createMachineRequestFromContext(
  input: CreateMachineRequestInput,
  context: MachineRequestContext,
  deps: MachineRequestAdmissionDeps
): Promise<PublicRequestResult<PendingMachineRequestOutcome>> {
  const domain = requestDomainForSource(input, context);
  const created = await deps.createRequest({
    domain,
    reason:
      input.reason ??
      (input.source === 'auto_extension'
        ? 'Submitted via Firefox extension auto request'
        : 'Submitted via Firefox extension'),
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

export async function decideAutoMachineRequest(
  input: DecideAutoMachineRequestInput,
  depsInput?: Partial<MachineRequestAdmissionDeps>
): Promise<PublicRequestResult<AutoMachineRequestOutcome>> {
  const deps = resolveDeps(depsInput);
  const context = await resolveMachineRequestAdmission(
    {
      ...input,
      logContext: 'Auto request',
    },
    deps
  );
  if (!context.ok) {
    return context;
  }

  const decision = await decideAutoMachineAdmission(input, context.data, deps);
  if (decision.kind === 'rejected') {
    return { ok: false, error: decision.error };
  }

  if (decision.kind === 'pending') {
    return createMachineRequestFromContext(
      {
        ...input,
        logContext: 'Auto request',
        source: 'auto_extension',
      },
      decision.context,
      deps
    );
  }

  try {
    const created = await createAutomaticWhitelistRule(
      {
        diagnosticContext: input.diagnosticContext,
        domain: decision.context.domain,
        groupId: decision.context.groupId,
        originPage: input.originPage,
        reason: input.reason,
      },
      {
        createRule: deps.createRule,
        createTransactionalWriter: deps.createTransactionalWriter,
        publishWhitelistChanged: deps.publishWhitelistChanged,
        withTransaction: deps.withTransaction,
      }
    );

    return {
      ok: true,
      data: {
        autoApproved: true,
        domain: decision.context.domain,
        duplicate: created.duplicate,
        groupId: decision.context.groupId,
        source: 'auto_extension',
        status: created.status,
      },
    };
  } catch (error) {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: error instanceof Error ? error.message : String(error),
      },
    };
  }
}

export default {
  createSubmittedMachineRequest,
  decideAutoMachineRequest,
  resolveMachineRequestAdmission,
};
