import { v4 as uuidv4 } from 'uuid';
import { and, eq, inArray } from 'drizzle-orm';
import { normalize } from '@openpath/shared';
import { db, whitelistRules } from '../db/index.js';
import type { DbExecutor } from '../db/index.js';
import { getRowCount } from './utils.js';
import { logger } from './logger.js';
import {
  type CreateRuleResult,
  type Rule,
  type RuleType,
  type UpdateRuleInput,
} from './groups-storage-shared.js';
import { touchGroupUpdatedAt } from './groups-storage-groups.js';
import { getRuleById } from './groups-storage-rules-query.js';
import { normalizeRuleValue } from './groups-storage-rules-shared.js';

export async function updateRule(
  input: UpdateRuleInput,
  executor: DbExecutor = db
): Promise<Rule | null> {
  const { id, value, comment } = input;
  const [existing] = await executor.select().from(whitelistRules).where(eq(whitelistRules.id, id));
  if (!existing) return null;

  const updates: Partial<{ value: string; comment: string | null }> = {};

  if (value !== undefined) {
    const normalizedValue = normalizeRuleValue(existing.type as RuleType, value);
    const [duplicate] = await executor
      .select()
      .from(whitelistRules)
      .where(
        and(
          eq(whitelistRules.groupId, existing.groupId),
          eq(whitelistRules.type, existing.type),
          eq(whitelistRules.value, normalizedValue)
        )
      );

    if (duplicate && duplicate.id !== id) {
      return null;
    }

    updates.value = normalizedValue;
  }

  if (comment !== undefined) {
    updates.comment = comment;
  }

  if (Object.keys(updates).length > 0) {
    await executor.update(whitelistRules).set(updates).where(eq(whitelistRules.id, id));
    await touchGroupUpdatedAt(existing.groupId, executor);
    logger.debug('Updated rule', { id, ...updates });
  }

  return getRuleById(id);
}

export async function createRule(
  groupId: string,
  type: RuleType,
  value: string,
  comment: string | null = null,
  executor: DbExecutor = db
): Promise<CreateRuleResult> {
  const normalizedValue = normalizeRuleValue(type, value);

  const [existing] = await executor
    .select()
    .from(whitelistRules)
    .where(
      and(
        eq(whitelistRules.groupId, groupId),
        eq(whitelistRules.type, type),
        eq(whitelistRules.value, normalizedValue)
      )
    );

  if (existing) {
    return { success: false, error: 'Rule already exists' };
  }

  const id = uuidv4();
  await executor.insert(whitelistRules).values({
    id,
    groupId,
    type,
    value: normalizedValue,
    comment,
  });

  await touchGroupUpdatedAt(groupId, executor);
  logger.debug('Created rule', { id, groupId, type, value: normalizedValue });
  return { success: true, id };
}

export async function deleteRule(id: string, executor: DbExecutor = db): Promise<boolean> {
  const [existing] = await executor.select().from(whitelistRules).where(eq(whitelistRules.id, id));
  const deleted =
    getRowCount(await executor.delete(whitelistRules).where(eq(whitelistRules.id, id))) > 0;

  if (deleted && existing) {
    await touchGroupUpdatedAt(existing.groupId, executor);
  }

  return deleted;
}

export async function bulkDeleteRules(ids: string[], executor: DbExecutor = db): Promise<number> {
  if (ids.length === 0) return 0;

  const uniqueIds = Array.from(new Set(ids));
  const existingRules = await executor
    .select({ groupId: whitelistRules.groupId })
    .from(whitelistRules)
    .where(inArray(whitelistRules.id, uniqueIds));
  const deletedCount = getRowCount(
    await executor.delete(whitelistRules).where(inArray(whitelistRules.id, uniqueIds))
  );

  if (deletedCount > 0) {
    const affectedGroupIds = new Set(existingRules.map((rule) => rule.groupId));
    await Promise.all(
      Array.from(affectedGroupIds, (groupId) => touchGroupUpdatedAt(groupId, executor))
    );
  }

  logger.debug('Bulk deleted rules', { count: deletedCount, requested: ids.length });
  return deletedCount;
}

export async function setRuleEnabled(
  id: string,
  enabled: boolean,
  executor: DbExecutor = db
): Promise<Rule | null> {
  const [existing] = await executor.select().from(whitelistRules).where(eq(whitelistRules.id, id));
  if (!existing) return null;

  await executor
    .update(whitelistRules)
    .set({ enabled: enabled ? 1 : 0 })
    .where(eq(whitelistRules.id, id));
  await touchGroupUpdatedAt(existing.groupId, executor);
  logger.debug('Set rule enabled', { id, enabled });

  // NOTE: getRuleById reads from the ambient db (no executor param), mirroring updateRule;
  // when called inside a transaction the returned Rule reflects committed state. Callers refetch.
  return getRuleById(id);
}

export async function bulkSetRulesEnabled(
  ids: string[],
  enabled: boolean,
  executor: DbExecutor = db
): Promise<number> {
  if (ids.length === 0) return 0;

  const uniqueIds = Array.from(new Set(ids));
  const existingRules = await executor
    .select({ groupId: whitelistRules.groupId })
    .from(whitelistRules)
    .where(inArray(whitelistRules.id, uniqueIds));
  const updatedCount = getRowCount(
    await executor
      .update(whitelistRules)
      .set({ enabled: enabled ? 1 : 0 })
      .where(inArray(whitelistRules.id, uniqueIds))
  );

  if (updatedCount > 0) {
    const affectedGroupIds = new Set(existingRules.map((rule) => rule.groupId));
    await Promise.all(
      Array.from(affectedGroupIds, (groupId) => touchGroupUpdatedAt(groupId, executor))
    );
  }

  logger.debug('Bulk set rules enabled', { count: updatedCount, requested: ids.length, enabled });
  return updatedCount;
}

export async function bulkCreateRules(
  groupId: string,
  type: RuleType,
  values: string[],
  executor: DbExecutor = db
): Promise<number> {
  let count = 0;
  for (const value of values) {
    const normalizedValue = normalize.domain(value);
    if (normalizedValue) {
      const result = await createRule(groupId, type, normalizedValue, null, executor);
      if (result.success) count++;
    }
  }
  return count;
}
