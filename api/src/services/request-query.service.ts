import * as storage from '../lib/storage.js';
import * as groupsStorage from '../lib/groups-storage.js';
import * as auth from '../lib/auth.js';
import { getRequestBlockCauses, requestBlockCauseKey } from '../lib/request-block-cause.js';
import type { JWTPayload } from '../lib/auth.js';
import type { RequestStats } from '../types/storage.js';
import type { DomainRequest, RequestStatus } from '../types/index.js';
import type { RequestResult } from './request-service-shared.js';

export async function getRequestStatus(
  id: string
): Promise<RequestResult<Pick<DomainRequest, 'id' | 'domain' | 'status'>>> {
  const request = await storage.getRequestById(id);
  if (!request) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Request not found' } };
  }

  return {
    ok: true,
    data: {
      id: request.id,
      domain: request.domain,
      status: request.status,
    },
  };
}

async function attachBlockCauses(requests: DomainRequest[]): Promise<DomainRequest[]> {
  const pending = requests.filter((request) => request.status === 'pending');
  if (pending.length === 0) {
    return requests;
  }

  const causes = await getRequestBlockCauses(pending);

  return requests.map((request) => {
    if (request.status !== 'pending') {
      return request;
    }

    return {
      ...request,
      blockCause: causes.get(requestBlockCauseKey(request.groupId, request.domain)),
    };
  });
}

export async function listRequests(
  status: RequestStatus | null,
  user: JWTPayload
): Promise<DomainRequest[]> {
  let requests = await storage.getAllRequests(status);

  const groups = auth.getApprovalGroups(user);
  if (groups !== 'all') {
    requests = requests.filter((request) => groups.includes(request.groupId));
  }

  return attachBlockCauses(requests);
}

export async function getRequest(
  id: string,
  user: JWTPayload
): Promise<RequestResult<DomainRequest>> {
  const request = await storage.getRequestById(id);
  if (!request) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Request not found' } };
  }

  const groups = auth.getApprovalGroups(user);
  if (groups !== 'all' && !groups.includes(request.groupId)) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'You do not have access to this request' },
    };
  }

  const [requestWithCause] = await attachBlockCauses([request]);
  return { ok: true, data: requestWithCause ?? request };
}

export async function getStats(): Promise<RequestStats> {
  return storage.getStats();
}

export async function listGroupsForUser(
  user: JWTPayload
): Promise<{ id: string; name: string; path: string }[]> {
  const allGroups = await groupsStorage.getAllGroups();
  const userGroups = auth.getApprovalGroups(user);
  const filteredGroups =
    userGroups === 'all'
      ? allGroups
      : allGroups.filter(
          (group) => userGroups.includes(group.name) || userGroups.includes(group.id)
        );

  return filteredGroups.map((group) => ({
    id: group.id,
    name: group.name,
    path: group.id,
  }));
}

export async function listBlockedDomains(groupId: string): Promise<string[]> {
  return groupsStorage.getBlockedSubdomains(groupId);
}

export async function checkDomainBlocked(
  groupId: string,
  domain: string
): Promise<{ blocked: boolean; matchedRule: string | null }> {
  return groupsStorage.isDomainBlocked(groupId, domain);
}

export function getApprovalGroupsForUser(user: JWTPayload): string[] | 'all' {
  return auth.getApprovalGroups(user);
}

export const RequestQueryService = {
  getRequestStatus,
  listRequests,
  getRequest,
  getStats,
  listGroupsForUser,
  listBlockedDomains,
  checkDomainBlocked,
  getApprovalGroupsForUser,
};

export default RequestQueryService;
