import * as groupsStorage from '../lib/groups-storage.js';
import type {
  ListRulesGroupedOptions,
  ListRulesOptions,
  PaginatedGroupedRulesResult,
  PaginatedRulesResult,
  Rule,
  RuleType,
} from '../lib/groups-storage.js';

import type { GroupsResult } from './groups-service-shared.js';
import { ensureGroupExists } from './groups-rules-shared.js';

export async function listRules(
  groupId: string,
  type?: RuleType,
  enabled?: boolean
): Promise<GroupsResult<Rule[]>> {
  const group = await ensureGroupExists(groupId);
  if (!group.ok) {
    return group;
  }

  const rules = await groupsStorage.getRulesByGroup(groupId, type, enabled);
  return { ok: true, data: rules };
}

export async function listRulesPaginated(
  options: ListRulesOptions
): Promise<GroupsResult<PaginatedRulesResult>> {
  const group = await ensureGroupExists(options.groupId);
  if (!group.ok) {
    return group;
  }

  const result = await groupsStorage.getRulesByGroupPaginated(options);
  return { ok: true, data: result };
}

export async function listRulesGrouped(
  options: ListRulesGroupedOptions
): Promise<GroupsResult<PaginatedGroupedRulesResult>> {
  const group = await ensureGroupExists(options.groupId);
  if (!group.ok) {
    return group;
  }

  const result = await groupsStorage.getRulesByGroupGrouped(options);
  return { ok: true, data: result };
}

export async function getRuleById(id: string): Promise<Rule | null> {
  return groupsStorage.getRuleById(id);
}

export async function getRulesByIds(ids: string[]): Promise<Rule[]> {
  if (ids.length === 0) {
    return [];
  }

  return groupsStorage.getRulesByIds(ids);
}
