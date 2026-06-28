import {
  type ActiveGroupResult,
  type ExemptionResult,
  type HarnessClassroom,
  type HarnessCredentials,
  type HarnessGroup,
  type HarnessSchedule,
  type HarnessSession,
  type PublicRequestSubmission,
  type RequestMutationResult,
  type RequestStatusResult,
  type RuleMutationResult,
  type TrpcEnvelope,
  normalizeApiUrl,
  optionalProp,
  requestJson,
} from './backend-harness-shared.js';

interface ClassroomDetailsResponse {
  id: string;
  name: string;
  displayName: string;
  currentGroupId: string | null;
  machines?: {
    id: string;
    hostname: string;
  }[];
}

interface EnrollmentTicketResponse {
  success: boolean;
  enrollmentToken: string;
  classroomId: string;
  classroomName: string;
}

interface MachineRegistrationResponse {
  success: boolean;
  machineHostname: string;
  reportedHostname: string;
  whitelistUrl: string;
  classroomId: string;
  classroomName: string;
}

interface LoginResult {
  accessToken: string;
  user?: {
    id?: string;
  };
}

interface CreateGroupResult {
  id: string;
  name: string;
  displayName: string;
}

interface CreateClassroomResult {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
}

interface CreateScheduleResult {
  id: string;
  classroomId: string;
  groupId: string;
  startAt: string;
  endAt: string;
}

async function parseTrpcResponse<T>(response: Response, procedure: string): Promise<T> {
  const payload = (await response.json()) as TrpcEnvelope<T>;

  if (response.ok && payload.result?.data !== undefined) {
    return payload.result.data;
  }

  const code = payload.error?.data?.code ?? payload.error?.code ?? response.status;
  const message = payload.error?.message ?? `tRPC call failed for ${procedure}`;
  throw new Error(`[${String(code)}] ${message}`);
}

async function trpcMutate<T>(params: {
  apiUrl: string;
  procedure: string;
  input: unknown;
  accessToken?: string;
}): Promise<T> {
  const response = await fetch(`${normalizeApiUrl(params.apiUrl)}/trpc/${params.procedure}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(params.accessToken ? { Authorization: `Bearer ${params.accessToken}` } : {}),
    },
    body: JSON.stringify(params.input),
  });

  return parseTrpcResponse<T>(response, params.procedure);
}

async function trpcQuery<T>(params: {
  apiUrl: string;
  procedure: string;
  input?: unknown;
  accessToken?: string;
}): Promise<T> {
  const apiUrl = normalizeApiUrl(params.apiUrl);
  const query =
    params.input === undefined ? '' : `?input=${encodeURIComponent(JSON.stringify(params.input))}`;

  const response = await fetch(`${apiUrl}/trpc/${params.procedure}${query}`, {
    headers: params.accessToken ? { Authorization: `Bearer ${params.accessToken}` } : {},
  });

  return parseTrpcResponse<T>(response, params.procedure);
}

export async function login(params: {
  apiUrl: string;
  credentials: HarnessCredentials;
}): Promise<HarnessSession> {
  const result = await trpcMutate<LoginResult>({
    apiUrl: params.apiUrl,
    procedure: 'auth.login',
    input: params.credentials,
  });

  if (result.accessToken === '' || result.accessToken === 'cookie-session') {
    throw new Error(`auth.login for ${params.credentials.email} did not return a bearer token`);
  }

  return {
    email: params.credentials.email,
    accessToken: result.accessToken,
    ...optionalProp('userId', result.user?.id),
  };
}

export async function createGroup(params: {
  apiUrl: string;
  accessToken: string;
  name: string;
  displayName: string;
}): Promise<HarnessGroup> {
  return trpcMutate<CreateGroupResult>({
    apiUrl: params.apiUrl,
    procedure: 'groups.create',
    input: {
      name: params.name,
      displayName: params.displayName,
    },
    accessToken: params.accessToken,
  });
}

export async function createClassroom(params: {
  apiUrl: string;
  accessToken: string;
  name: string;
  displayName: string;
  defaultGroupId: string;
}): Promise<HarnessClassroom> {
  const classroom = await trpcMutate<CreateClassroomResult>({
    apiUrl: params.apiUrl,
    procedure: 'classrooms.create',
    input: {
      name: params.name,
      displayName: params.displayName,
      defaultGroupId: params.defaultGroupId,
    },
    accessToken: params.accessToken,
  });

  return {
    id: classroom.id,
    name: classroom.name,
    displayName: classroom.displayName,
    defaultGroupId: classroom.defaultGroupId ?? params.defaultGroupId,
  };
}

export async function createOneOffSchedule(params: {
  apiUrl: string;
  accessToken: string;
  classroomId: string;
  groupId: string;
  startAt: string;
  endAt: string;
}): Promise<HarnessSchedule> {
  return trpcMutate<CreateScheduleResult>({
    apiUrl: params.apiUrl,
    procedure: 'schedules.createOneOff',
    input: {
      classroomId: params.classroomId,
      groupId: params.groupId,
      startAt: params.startAt,
      endAt: params.endAt,
    },
    accessToken: params.accessToken,
  });
}

export async function createEnrollmentTicket(params: {
  apiUrl: string;
  accessToken: string;
  classroomId: string;
}): Promise<EnrollmentTicketResponse> {
  return requestJson<EnrollmentTicketResponse>(
    `${normalizeApiUrl(params.apiUrl)}/api/enroll/${params.classroomId}/ticket`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${params.accessToken}` },
    }
  );
}

export async function registerMachine(params: {
  apiUrl: string;
  enrollmentToken: string;
  hostname: string;
  classroomId: string;
  version?: string;
}): Promise<MachineRegistrationResponse> {
  return requestJson<MachineRegistrationResponse>(
    `${normalizeApiUrl(params.apiUrl)}/api/machines/register`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${params.enrollmentToken}` },
      body: {
        hostname: params.hostname,
        classroomId: params.classroomId,
        ...(params.version ? { version: params.version } : {}),
      },
    }
  );
}

export async function getClassroomDetails(params: {
  apiUrl: string;
  accessToken: string;
  classroomId: string;
}): Promise<ClassroomDetailsResponse> {
  return trpcQuery<ClassroomDetailsResponse>({
    apiUrl: params.apiUrl,
    procedure: 'classrooms.get',
    input: { id: params.classroomId },
    accessToken: params.accessToken,
  });
}

export async function submitManualRequest(params: {
  apiUrl: string;
  domain: string;
  hostname: string;
  token: string;
  reason?: string;
  originPage?: string;
}): Promise<PublicRequestSubmission> {
  return requestJson<PublicRequestSubmission>(
    `${normalizeApiUrl(params.apiUrl)}/api/requests/submit`,
    {
      method: 'POST',
      body: {
        domain: params.domain,
        hostname: params.hostname,
        token: params.token,
        ...(params.reason ? { reason: params.reason } : {}),
        ...(params.originPage ? { origin_page: params.originPage } : {}),
      },
    }
  );
}

export async function getRequestStatus(params: {
  apiUrl: string;
  requestId: string;
}): Promise<RequestStatusResult> {
  return trpcQuery<RequestStatusResult>({
    apiUrl: params.apiUrl,
    procedure: 'requests.getStatus',
    input: { id: params.requestId },
  });
}

export async function approveRequest(params: {
  apiUrl: string;
  accessToken: string;
  requestId: string;
  groupId?: string;
}): Promise<RequestMutationResult> {
  return trpcMutate<RequestMutationResult>({
    apiUrl: params.apiUrl,
    procedure: 'requests.approve',
    input: {
      id: params.requestId,
      ...(params.groupId ? { groupId: params.groupId } : {}),
    },
    accessToken: params.accessToken,
  });
}

export async function rejectRequest(params: {
  apiUrl: string;
  accessToken: string;
  requestId: string;
  reason?: string;
}): Promise<RequestMutationResult> {
  return trpcMutate<RequestMutationResult>({
    apiUrl: params.apiUrl,
    procedure: 'requests.reject',
    input: {
      id: params.requestId,
      ...(params.reason ? { reason: params.reason } : {}),
    },
    accessToken: params.accessToken,
  });
}

export async function createGroupRule(params: {
  apiUrl: string;
  accessToken: string;
  groupId: string;
  type: 'whitelist' | 'blocked_subdomain' | 'blocked_path';
  value: string;
  comment?: string;
}): Promise<RuleMutationResult> {
  return trpcMutate<RuleMutationResult>({
    apiUrl: params.apiUrl,
    procedure: 'groups.createRule',
    input: {
      groupId: params.groupId,
      type: params.type,
      value: params.value,
      ...(params.comment ? { comment: params.comment } : {}),
    },
    accessToken: params.accessToken,
  });
}

export async function deleteGroupRule(params: {
  apiUrl: string;
  accessToken: string;
  ruleId: string;
  groupId?: string;
}): Promise<{ deleted: boolean }> {
  return trpcMutate<{ deleted: boolean }>({
    apiUrl: params.apiUrl,
    procedure: 'groups.deleteRule',
    input: {
      id: params.ruleId,
      ...(params.groupId ? { groupId: params.groupId } : {}),
    },
    accessToken: params.accessToken,
  });
}

export async function createTemporaryExemption(params: {
  apiUrl: string;
  accessToken: string;
  machineId: string;
  classroomId: string;
  scheduleId: string;
}): Promise<ExemptionResult> {
  return trpcMutate<ExemptionResult>({
    apiUrl: params.apiUrl,
    procedure: 'classrooms.createExemption',
    input: {
      machineId: params.machineId,
      classroomId: params.classroomId,
      scheduleId: params.scheduleId,
    },
    accessToken: params.accessToken,
  });
}

export async function deleteTemporaryExemption(params: {
  apiUrl: string;
  accessToken: string;
  exemptionId: string;
}): Promise<{ success: boolean }> {
  return trpcMutate<{ success: boolean }>({
    apiUrl: params.apiUrl,
    procedure: 'classrooms.deleteExemption',
    input: { id: params.exemptionId },
    accessToken: params.accessToken,
  });
}

export async function setActiveGroup(params: {
  apiUrl: string;
  accessToken: string;
  classroomId: string;
  groupId: string | null;
}): Promise<ActiveGroupResult> {
  const result = await trpcMutate<{
    currentGroupId: string | null;
  }>({
    apiUrl: params.apiUrl,
    procedure: 'classrooms.setActiveGroup',
    input: {
      id: params.classroomId,
      groupId: params.groupId,
    },
    accessToken: params.accessToken,
  });

  return { currentGroupId: result.currentGroupId };
}

export async function tickBoundaries(atIsoTimestamp: string): Promise<{ at: string }> {
  const at = new Date(atIsoTimestamp);
  if (!Number.isFinite(at.getTime())) {
    throw new Error(`Invalid ISO timestamp: ${atIsoTimestamp}`);
  }

  const { runScheduleBoundaryTickOnce } = await import('../../../api/src/lib/rule-events.js');
  await runScheduleBoundaryTickOnce(at);
  return { at: at.toISOString() };
}
