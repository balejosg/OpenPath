import { normalizeRequestHost, type RequestBlockCause } from '@openpath/shared';

import { getRulesByGroup } from './groups-storage-rules-query.js';
import type { Rule } from './groups-storage-shared.js';

interface GroupRules {
  blocked: Rule[];
  whitelist: Rule[];
}

export interface RequestBlockCauseInput {
  groupId: string;
  domain: string;
}

function matchesRule(host: string, pattern: string): boolean {
  const normalizedPattern = pattern.toLowerCase();

  if (normalizedPattern.startsWith('*.')) {
    const baseDomain = normalizedPattern.slice(2);
    return host === baseDomain || host.endsWith(`.${baseDomain}`);
  }

  return host === normalizedPattern || host.endsWith(`.${normalizedPattern}`);
}

function findBlockedRule(host: string, rules: Rule[]): string | null {
  for (const rule of rules) {
    if (matchesRule(host, rule.value)) {
      return rule.value.toLowerCase();
    }
  }

  return null;
}

function findAllowedRule(host: string, rules: Rule[]): string | null {
  for (const rule of rules) {
    if (matchesRule(host, rule.value)) {
      return rule.value.toLowerCase();
    }
  }

  return null;
}

function evaluateCause(host: string, rules: GroupRules): RequestBlockCause {
  const blockedRule = findBlockedRule(host, rules.blocked);
  if (blockedRule !== null) {
    return { kind: 'blocked_by_rule', matchedRule: blockedRule };
  }

  const allowedRule = findAllowedRule(host, rules.whitelist);
  if (allowedRule !== null) {
    return { kind: 'already_allowed', matchedRule: allowedRule };
  }

  return { kind: 'not_allowed' };
}

async function loadGroupRules(groupId: string): Promise<GroupRules> {
  const [blocked, whitelist] = await Promise.all([
    getRulesByGroup(groupId, 'blocked_subdomain', true),
    getRulesByGroup(groupId, 'whitelist', true),
  ]);

  return { blocked, whitelist };
}

/**
 * Return the enabled whitelist rule that already covers `value` (exact or as an
 * ancestor/wildcard), ignoring blocking rules. Null when nothing covers it.
 */
export async function findAllowingRule(groupId: string, value: string): Promise<string | null> {
  const whitelist = await getRulesByGroup(groupId, 'whitelist', true);
  return findAllowedRule(normalizeRequestHost(value), whitelist);
}

export function requestBlockCauseKey(groupId: string, domain: string): string {
  return `${groupId}\u0000${normalizeRequestHost(domain)}`;
}

/**
 * Compute the block cause for many requests while reading each group's rules
 * only once per batch.
 */
export async function getRequestBlockCauses(
  requests: readonly RequestBlockCauseInput[]
): Promise<Map<string, RequestBlockCause>> {
  const rulesByGroup = new Map<string, GroupRules>();
  const causes = new Map<string, RequestBlockCause>();

  for (const request of requests) {
    const normalizedHost = normalizeRequestHost(request.domain);
    const key = requestBlockCauseKey(request.groupId, normalizedHost);
    if (causes.has(key)) continue;

    let rules = rulesByGroup.get(request.groupId);
    if (!rules) {
      rules = await loadGroupRules(request.groupId);
      rulesByGroup.set(request.groupId, rules);
    }

    causes.set(key, evaluateCause(normalizedHost, rules));
  }

  return causes;
}

export async function getRequestBlockCause(
  groupId: string,
  host: string
): Promise<RequestBlockCause> {
  const normalizedHost = normalizeRequestHost(host);
  const causes = await getRequestBlockCauses([{ groupId, domain: normalizedHost }]);
  return causes.get(requestBlockCauseKey(groupId, normalizedHost)) ?? { kind: 'not_allowed' };
}

export default {
  findAllowingRule,
  getRequestBlockCause,
  getRequestBlockCauses,
  requestBlockCauseKey,
};
