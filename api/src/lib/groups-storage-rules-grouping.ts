import { getRootDomain } from '@openpath/shared';
import {
  dbRuleToApi,
  type DomainGroup,
  type ListRulesGroupedOptions,
  type PaginatedGroupedRulesResult,
} from './groups-storage-shared.js';
import { listRuleRowsByGroup } from './groups-storage-rules-shared.js';

function filterRulesByEnabled<T extends { enabled: number }>(rules: T[], enabled?: boolean): T[] {
  return enabled === undefined ? rules : rules.filter((rule) => (rule.enabled === 1) === enabled);
}

export async function getRulesByGroupGrouped(
  options: ListRulesGroupedOptions
): Promise<PaginatedGroupedRulesResult> {
  const { groupId, type, enabled, limit = 20, offset = 0, search } = options;
  const rules = await listRuleRowsByGroup(groupId, type);

  let filtered = filterRulesByEnabled(rules, enabled);
  if (search?.trim()) {
    const searchLower = search.toLowerCase().trim();
    filtered = filtered.filter((rule) => rule.value.toLowerCase().includes(searchLower));
  }

  const groupedMap = new Map<string, typeof filtered>();
  for (const rule of filtered) {
    const root = getRootDomain(rule.value);
    const existing = groupedMap.get(root) ?? [];
    existing.push(rule);
    groupedMap.set(root, existing);
  }

  const sortedRoots = Array.from(groupedMap.keys()).sort((left, right) =>
    left.localeCompare(right)
  );
  const totalGroups = sortedRoots.length;
  const totalRules = filtered.length;
  const paginatedRoots = sortedRoots.slice(offset, offset + limit);

  const groups: DomainGroup[] = paginatedRoots.map((root) => {
    const groupRules = groupedMap.get(root) ?? [];
    groupRules.sort((left, right) => left.value.localeCompare(right.value));

    const hasWhitelist = groupRules.some((rule) => rule.type === 'whitelist');
    const hasBlocked = groupRules.some(
      (rule) => rule.type === 'blocked_subdomain' || rule.type === 'blocked_path'
    );

    const status: DomainGroup['status'] =
      hasWhitelist && hasBlocked ? 'mixed' : hasBlocked ? 'blocked' : 'allowed';

    return {
      root,
      rules: groupRules.map(dbRuleToApi),
      status,
    };
  });

  return {
    groups,
    totalGroups,
    totalRules,
    hasMore: offset + limit < totalGroups,
  };
}
