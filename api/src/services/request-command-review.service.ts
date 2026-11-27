import * as auth from '../lib/auth.js';
import {
  findAllowingRule,
  findBlockingRules,
  getRequestBlockCause,
} from '../lib/request-block-cause.js';
import { normalizeRequestHost, ruleValueForApprovalScope } from '@openpath/shared/domain';
import type { ApprovalScope } from '@openpath/shared/schemas';

import type { RequestResult } from './request-service-shared.js';
import {
  canApproveResolvedTarget,
  getStoredRequestById,
  resolveGroupTarget,
  toErrorMessage,
  updateStoredRequestStatus,
  type StoredDomainRequest,
} from './request-command-shared.js';
import { approveWhitelistRequest } from './whitelist-rule-command.service.js';
import type { JWTPayload } from '../lib/auth.js';

export interface ApproveRequestOptions {
  scope: ApprovalScope;
  unblock: boolean;
}

export async function approveRequest(
  id: string,
  groupId: string | undefined,
  user: JWTPayload,
  options: ApproveRequestOptions
): Promise<RequestResult<StoredDomainRequest>> {
  const request = await getStoredRequestById(id);
  if (!request) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Request not found' } };
  }

  if (request.status !== 'pending') {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: `Request is already ${request.status}` },
    };
  }

  const rawTargetGroup = groupId ?? request.groupId;
  const hasRawPermission = auth.canApproveGroup(user, rawTargetGroup);
  const resolvedTarget = await resolveGroupTarget(rawTargetGroup);

  if (
    !hasRawPermission &&
    (!resolvedTarget || !canApproveResolvedTarget(user, rawTargetGroup, resolvedTarget))
  ) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'You do not have permission to approve for this group' },
    };
  }

  if (!resolvedTarget) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Target group does not exist' },
    };
  }

  const blockCause = await getRequestBlockCause(resolvedTarget.id, request.domain);

  if (blockCause.kind === 'blocked_by_rule' && !options.unblock) {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: `Blocked by rule ${blockCause.matchedRule}; approve with unblock to remove it`,
      },
    };
  }

  const host = normalizeRequestHost(request.domain);
  const ruleValue = ruleValueForApprovalScope(host, options.scope);
  // Every blocking rule that reaches the host is removed (a wildcard and an exact
  // rule can overlap); sibling blocks stay. A whitelist rule is created only when
  // nothing enabled already covers the chosen scope (host or whole family).
  const blockedRules =
    blockCause.kind === 'blocked_by_rule' ? await findBlockingRules(resolvedTarget.id, host) : [];
  const blockedList = blockedRules.join(', ');
  const allowedBy = await findAllowingRule(resolvedTarget.id, ruleValue);

  let resolutionNote = `Added to ${resolvedTarget.name}`;
  if (blockedList && allowedBy) {
    resolutionNote = `Removed blocking rule ${blockedList}; already allowed by ${allowedBy}`;
  } else if (blockedList) {
    resolutionNote = `Added to ${resolvedTarget.name}; removed blocking rule ${blockedList}`;
  } else if (allowedBy) {
    resolutionNote = `Already allowed by ${allowedBy}`;
  }

  try {
    const approval = await approveWhitelistRequest({
      domain: ruleValue,
      requestId: request.id,
      resolvedBy: user.name,
      targetGroup: resolvedTarget,
      resolutionNote,
      ...(blockedRules.length > 0 ? { removeBlockedRules: blockedRules } : {}),
      ...(allowedBy ? { skipRuleCreation: true } : {}),
    });

    return { ok: true, data: approval.updated };
  } catch (error) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: toErrorMessage(error) },
    };
  }
}

export async function rejectRequest(
  id: string,
  reason: string | undefined,
  user: JWTPayload
): Promise<RequestResult<StoredDomainRequest>> {
  const request = await getStoredRequestById(id);
  if (!request) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Request not found' } };
  }

  if (request.status !== 'pending') {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: `Request is already ${request.status}` },
    };
  }

  if (!auth.canApproveGroup(user, request.groupId)) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'You do not have permission to manage this request' },
    };
  }

  const updated = await updateStoredRequestStatus(request.id, 'rejected', user.name, reason);
  if (!updated) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Failed to update request status' } };
  }

  return { ok: true, data: updated };
}
