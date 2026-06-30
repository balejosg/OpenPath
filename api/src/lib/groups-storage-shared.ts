import type { GroupVisibility } from '@openpath/shared';
import type { WhitelistGroup, WhitelistRule } from '../db/schema.js';
import type { DbExecutor } from '../db/index.js';

/** Rule type for whitelist entries */
export type RuleType = 'whitelist' | 'blocked_subdomain' | 'blocked_path' | 'allowed_path';

/** Group visibility scope */
export type { GroupVisibility };

/** Group with computed rule counts */
export interface GroupWithCounts {
  id: string;
  name: string;
  displayName: string;
  enabled: boolean;
  visibility: GroupVisibility;
  ownerUserId: string | null;
  createdAt: string;
  updatedAt: string | null;
  whitelistCount: number;
  blockedSubdomainCount: number;
  blockedPathCount: number;
}

/** Minimal group metadata for exports/caching */
export interface GroupMeta {
  id: string;
  name: string;
  displayName: string;
  enabled: boolean;
  visibility: GroupVisibility;
  ownerUserId: string | null;
  updatedAt: Date;
}

/** Rule in API format */
export interface Rule {
  id: string;
  groupId: string;
  type: RuleType;
  value: string;
  enabled: boolean;
  comment: string | null;
  createdAt: string;
}

/** Result of creating a rule */
export interface CreateRuleResult {
  success: boolean;
  id?: string;
  error?: string;
}

/** Group statistics */
export interface GroupStats {
  groupCount: number;
  whitelistCount: number;
  blockedCount: number;
}

/** System status (enabled/disabled groups) */
export interface SystemStatus {
  enabled: boolean;
  totalGroups: number;
  activeGroups: number;
  pausedGroups: number;
}

/** Paginated rules query options */
export interface ListRulesOptions {
  groupId: string;
  type?: RuleType | undefined;
  enabled?: boolean | undefined;
  limit?: number | undefined;
  offset?: number | undefined;
  search?: string | undefined;
}

/** Paginated rules result */
export interface PaginatedRulesResult {
  rules: Rule[];
  total: number;
  hasMore: boolean;
}

/** A domain group containing rules under a root domain */
export interface DomainGroup {
  root: string;
  rules: Rule[];
  status: 'allowed' | 'blocked' | 'mixed';
}

/** Paginated grouped rules query options */
export interface ListRulesGroupedOptions {
  groupId: string;
  type?: RuleType | undefined;
  enabled?: boolean | undefined;
  limit?: number | undefined;
  offset?: number | undefined;
  search?: string | undefined;
}

/** Paginated grouped rules result */
export interface PaginatedGroupedRulesResult {
  groups: DomainGroup[];
  totalGroups: number;
  totalRules: number;
  hasMore: boolean;
}

/** Update rule input */
export interface UpdateRuleInput {
  id: string;
  value?: string | undefined;
  comment?: string | null | undefined;
}

/** Storage interface for dependency injection and testing */
export interface IGroupsStorage {
  getAllGroups(): Promise<GroupWithCounts[]>;
  getGroupById(id: string): Promise<GroupWithCounts | null>;
  getGroupByName(name: string): Promise<GroupWithCounts | null>;
  createGroup(
    name: string,
    displayName: string,
    opts?: {
      enabled?: boolean;
      visibility?: GroupVisibility;
      ownerUserId?: string | null;
    }
  ): Promise<string>;
  updateGroup(
    id: string,
    displayName: string,
    enabled: boolean,
    visibility?: GroupVisibility
  ): Promise<void>;
  deleteGroup(id: string): Promise<boolean>;
  getRulesByGroup(groupId: string, type?: RuleType, enabled?: boolean): Promise<Rule[]>;
  getRulesByGroupPaginated(options: ListRulesOptions): Promise<PaginatedRulesResult>;
  getRulesByGroupGrouped(options: ListRulesGroupedOptions): Promise<PaginatedGroupedRulesResult>;
  getRuleById(id: string): Promise<Rule | null>;
  getRulesByIds(ids: string[]): Promise<Rule[]>;
  createRule(
    groupId: string,
    type: RuleType,
    value: string,
    comment?: string | null,
    executor?: DbExecutor
  ): Promise<CreateRuleResult>;
  updateRule(input: UpdateRuleInput, executor?: DbExecutor): Promise<Rule | null>;
  deleteRule(id: string, executor?: DbExecutor): Promise<boolean>;
  bulkCreateRules(
    groupId: string,
    type: RuleType,
    values: string[],
    executor?: DbExecutor
  ): Promise<number>;
  bulkDeleteRules(ids: string[], executor?: DbExecutor): Promise<number>;
  setRuleEnabled(id: string, enabled: boolean, executor?: DbExecutor): Promise<Rule | null>;
  bulkSetRulesEnabled(ids: string[], enabled: boolean, executor?: DbExecutor): Promise<number>;
  getStats(): Promise<GroupStats>;
  getSystemStatus(): Promise<SystemStatus>;
  toggleSystemStatus(enable: boolean): Promise<SystemStatus>;
  exportGroup(groupId: string): Promise<string | null>;
  exportAllGroups(): Promise<{ name: string; content: string }[]>;
}

export function dbGroupToApi(
  group: WhitelistGroup
): Omit<GroupWithCounts, 'whitelistCount' | 'blockedSubdomainCount' | 'blockedPathCount'> {
  return {
    id: group.id,
    name: group.name,
    displayName: group.displayName,
    enabled: group.enabled === 1,
    visibility: group.visibility === 'instance_public' ? 'instance_public' : 'private',
    ownerUserId: group.ownerUserId ?? null,
    createdAt: group.createdAt?.toISOString() ?? new Date().toISOString(),
    updatedAt: group.updatedAt?.toISOString() ?? null,
  };
}

export function dbGroupToMeta(group: WhitelistGroup): GroupMeta {
  return {
    id: group.id,
    name: group.name,
    displayName: group.displayName,
    enabled: group.enabled === 1,
    visibility: group.visibility === 'instance_public' ? 'instance_public' : 'private',
    ownerUserId: group.ownerUserId ?? null,
    updatedAt: group.updatedAt ?? new Date(),
  };
}

export function dbRuleToApi(rule: WhitelistRule): Rule {
  return {
    id: rule.id,
    groupId: rule.groupId,
    type: rule.type as RuleType,
    value: rule.value,
    enabled: rule.enabled === 1,
    comment: rule.comment ?? null,
    createdAt: rule.createdAt?.toISOString() ?? new Date().toISOString(),
  };
}
