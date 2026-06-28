/**
 * OpenPath - Strict Internet Access Control
 *
 * Public surface for whitelist group storage. Internal responsibilities are split across:
 * - groups-storage-shared.ts: types and row mappers
 * - groups-storage-groups.ts: group CRUD and system status
 * - groups-storage-rules.ts: rule CRUD and blocking logic
 */

import { logger } from './logger.js';
import type { IGroupsStorage } from './groups-storage-shared.js';
import {
  createGroup,
  deleteGroup,
  getAllGroups,
  getGroupById,
  getGroupByName,
  getGroupMetaById,
  getGroupMetaByName,
  getStats,
  getSystemStatus,
  toggleSystemStatus,
  touchGroupUpdatedAt,
  updateGroup,
} from './groups-storage-groups.js';
import {
  bulkCreateRules,
  bulkDeleteRules,
  bulkSetRulesEnabled,
  copyRulesToGroup,
  createRule,
  deleteRule,
  getBlockedSubdomains,
  getRuleById,
  getRulesByGroup,
  getRulesByGroupGrouped,
  getRulesByGroupPaginated,
  getRulesByIds,
  isDomainBlocked,
  setRuleEnabled,
  updateRule,
} from './groups-storage-rules.js';

export type {
  CreateRuleResult,
  DomainGroup,
  GroupMeta,
  GroupStats,
  GroupVisibility,
  GroupWithCounts,
  IGroupsStorage,
  ListRulesGroupedOptions,
  ListRulesOptions,
  PaginatedGroupedRulesResult,
  PaginatedRulesResult,
  Rule,
  RuleType,
  SystemStatus,
  UpdateRuleInput,
} from './groups-storage-shared.js';
export type { BlockedCheckResult } from './groups-storage-rules.js';
export {
  bulkCreateRules,
  bulkDeleteRules,
  bulkSetRulesEnabled,
  copyRulesToGroup,
  createGroup,
  createRule,
  deleteGroup,
  deleteRule,
  getAllGroups,
  getBlockedSubdomains,
  getGroupById,
  getGroupByName,
  getGroupMetaById,
  getGroupMetaByName,
  getRuleById,
  getRulesByGroup,
  getRulesByGroupGrouped,
  getRulesByGroupPaginated,
  getRulesByIds,
  getStats,
  getSystemStatus,
  isDomainBlocked,
  setRuleEnabled,
  toggleSystemStatus,
  touchGroupUpdatedAt,
  updateGroup,
  updateRule,
};

interface ExportCacheEntry {
  version: string;
  content: string;
}

const EXPORT_CACHE_MAX = ((): number => {
  const raw = process.env.OPENPATH_EXPORT_CACHE_MAX;
  if (!raw) return 5000;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 5000;
})();

const exportCache = new Map<string, ExportCacheEntry>();

export async function exportGroup(groupId: string): Promise<string | null> {
  const group = await getGroupMetaById(groupId);
  if (!group) return null;

  const rules = await getRulesByGroup(groupId);
  const rulesVersion = rules
    .map(
      (rule) =>
        `${rule.id}:${rule.type}:${rule.value}:${rule.enabled ? '1' : '0'}:${rule.comment ?? ''}`
    )
    .sort()
    .join('|');
  const version = `${group.updatedAt.toISOString()}:${group.enabled ? '1' : '0'}:${rulesVersion}`;
  const cached = exportCache.get(groupId);
  const hit = cached?.version === version ? cached : null;
  if (hit) {
    exportCache.delete(groupId);
    exportCache.set(groupId, hit);
    return hit.content;
  }

  if (!group.enabled) {
    const disabledContent = '#DESACTIVADO\n';
    exportCache.delete(groupId);
    exportCache.set(groupId, { version, content: disabledContent });
    return disabledContent;
  }

  let content = '';

  const whitelist = rules.filter((rule) => rule.type === 'whitelist' && rule.enabled);
  if (whitelist.length > 0) {
    content += '## WHITELIST\n';
    whitelist.forEach((rule) => {
      content += `${rule.value}\n`;
    });
    content += '\n';
  }

  const blockedSubdomains = rules.filter(
    (rule) => rule.type === 'blocked_subdomain' && rule.enabled
  );
  if (blockedSubdomains.length > 0) {
    content += '## BLOCKED-SUBDOMAINS\n';
    blockedSubdomains.forEach((rule) => {
      content += `${rule.value}\n`;
    });
    content += '\n';
  }

  const blockedPaths = rules.filter((rule) => rule.type === 'blocked_path' && rule.enabled);
  if (blockedPaths.length > 0) {
    content += '## BLOCKED-PATHS\n';
    blockedPaths.forEach((rule) => {
      content += `${rule.value}\n`;
    });
    content += '\n';
  }

  const finalContent = `${content.trim()}\n`;
  exportCache.delete(groupId);
  exportCache.set(groupId, { version, content: finalContent });

  while (exportCache.size > EXPORT_CACHE_MAX) {
    const oldestKey = exportCache.keys().next().value;
    if (oldestKey === undefined) break;
    exportCache.delete(oldestKey);
  }

  return finalContent;
}

export async function exportAllGroups(): Promise<{ name: string; content: string }[]> {
  const groups = await getAllGroups();
  const results: { name: string; content: string }[] = [];

  for (const group of groups) {
    const content = await exportGroup(group.id);
    if (content) {
      results.push({ name: group.name, content });
    }
  }

  return results;
}

export const groupsStorage: IGroupsStorage = {
  getAllGroups,
  getGroupById,
  getGroupByName,
  createGroup,
  updateGroup,
  deleteGroup,
  getRulesByGroup,
  getRulesByGroupPaginated,
  getRulesByGroupGrouped,
  getRuleById,
  getRulesByIds,
  createRule,
  updateRule,
  deleteRule,
  bulkCreateRules,
  bulkDeleteRules,
  setRuleEnabled,
  bulkSetRulesEnabled,
  getStats,
  getSystemStatus,
  toggleSystemStatus,
  exportGroup,
  exportAllGroups,
};

logger.debug('Groups storage initialized');

export default groupsStorage;
