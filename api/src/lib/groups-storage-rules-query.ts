import { eq, inArray } from 'drizzle-orm';
import { normalize } from '@openpath/shared';
import { db, whitelistRules } from '../db/index.js';
import {
  dbRuleToApi,
  type ListRulesOptions,
  type PaginatedRulesResult,
  type Rule,
  type RuleType,
} from './groups-storage-shared.js';
import { listRuleRowsByGroup } from './groups-storage-rules-shared.js';

function filterRulesByEnabled<T extends { enabled: number }>(rules: T[], enabled?: boolean): T[] {
  return enabled === undefined ? rules : rules.filter((rule) => (rule.enabled === 1) === enabled);
}

export async function getRulesByGroup(
  groupId: string,
  type?: RuleType,
  enabled?: boolean
): Promise<Rule[]> {
  const rules = await listRuleRowsByGroup(groupId, type);
  return filterRulesByEnabled(rules, enabled)
    .map(dbRuleToApi)
    .sort((left, right) => left.value.localeCompare(right.value));
}

export async function getRulesByGroupPaginated(
  options: ListRulesOptions
): Promise<PaginatedRulesResult> {
  const { groupId, type, enabled, limit = 50, offset = 0, search } = options;
  const rules = await listRuleRowsByGroup(groupId, type);

  let filtered = filterRulesByEnabled(rules, enabled);
  if (search?.trim()) {
    const searchLower = search.toLowerCase().trim();
    filtered = filtered.filter((rule) => rule.value.toLowerCase().includes(searchLower));
  }

  filtered.sort((left, right) => left.value.localeCompare(right.value));

  const total = filtered.length;
  const paginated = filtered.slice(offset, offset + limit);

  return {
    rules: paginated.map(dbRuleToApi),
    total,
    hasMore: offset + limit < total,
  };
}

export async function getRuleById(id: string): Promise<Rule | null> {
  const [rule] = await db.select().from(whitelistRules).where(eq(whitelistRules.id, id));
  return rule ? dbRuleToApi(rule) : null;
}

export async function getRulesByIds(ids: string[]): Promise<Rule[]> {
  if (ids.length === 0) return [];

  const uniqueIds = Array.from(new Set(ids));
  const rows = await db.select().from(whitelistRules).where(inArray(whitelistRules.id, uniqueIds));
  if (rows.length === 0) return [];

  const rulesById = new Map<string, Rule>();
  for (const row of rows) {
    rulesById.set(row.id, dbRuleToApi(row));
  }

  const ordered: Rule[] = [];
  for (const id of ids) {
    const rule = rulesById.get(id);
    if (rule) ordered.push(rule);
  }

  return ordered;
}

export interface BlockedCheckResult {
  blocked: boolean;
  matchedRule: string | null;
}

export async function isDomainBlocked(
  groupId: string,
  domain: string
): Promise<BlockedCheckResult> {
  const rules = await getRulesByGroup(groupId, 'blocked_subdomain');
  const domainLower = normalize.domain(domain);

  for (const rule of rules) {
    const pattern = rule.value.toLowerCase();

    if (pattern === domainLower) {
      return { blocked: true, matchedRule: pattern };
    }

    if (domainLower.endsWith(`.${pattern}`)) {
      return { blocked: true, matchedRule: pattern };
    }

    if (pattern.startsWith('*.')) {
      const baseDomain = pattern.slice(2);
      if (domainLower === baseDomain || domainLower.endsWith(`.${baseDomain}`)) {
        return { blocked: true, matchedRule: pattern };
      }
    }
  }

  return { blocked: false, matchedRule: null };
}

export async function getBlockedSubdomains(groupId: string): Promise<string[]> {
  const rules = await getRulesByGroup(groupId, 'blocked_subdomain');
  return rules.map((rule) => rule.value);
}
