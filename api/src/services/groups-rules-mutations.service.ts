import * as groupsStorage from '../lib/groups-storage.js';
import { cleanRuleValue, validateRuleValue } from '@openpath/shared/rules-validation';
import type { Rule } from '../lib/groups-storage.js';

import DomainEventsService from './domain-events.service.js';
import type {
  BulkCreateRulesInput,
  CreateRuleInput,
  GroupsResult,
  UpdateRuleInput,
} from './groups-service-shared.js';
import {
  defaultRulesDependencies,
  ensureGroupExists,
  type GroupsRulesDependencies,
} from './groups-rules-shared.js';
import {
  bulkDeleteWhitelistRules,
  createManualWhitelistRule,
  deleteWhitelistRule,
  revokeAutomaticWhitelistRule,
} from './whitelist-rule-command.service.js';

export async function createRule(
  input: CreateRuleInput,
  deps: GroupsRulesDependencies = defaultRulesDependencies
): Promise<GroupsResult<{ id: string }>> {
  const cleanedValue = cleanRuleValue(input.value, input.type === 'blocked_path');
  if (!cleanedValue) {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'Value is required' } };
  }

  const validation = validateRuleValue(cleanedValue, input.type);
  if (!validation.valid) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: validation.error ?? 'Invalid rule value format' },
    };
  }

  const group = await ensureGroupExists(input.groupId, deps);
  if (!group.ok) {
    return group;
  }

  const result = await createManualWhitelistRule(
    {
      comment: input.comment,
      groupId: input.groupId,
      type: input.type,
      value: cleanedValue,
    },
    {
      createRule: deps.createRule,
      publishWhitelistChanged: deps.publishWhitelistChanged,
      writeTransactionalCommand: DomainEventsService.writeTransactionalCommand,
      withTransaction: deps.withTransaction,
    }
  );

  if (!result.success) {
    return {
      ok: false,
      error: { code: 'CONFLICT', message: result.error ?? 'Rule already exists' },
    };
  }

  if (!result.id) {
    return {
      ok: false,
      error: { code: 'INTERNAL_SERVER_ERROR', message: 'Failed to create rule' },
    };
  }

  return { ok: true, data: { id: result.id } };
}

export async function deleteRule(
  id: string,
  groupId?: string,
  deps: Pick<
    GroupsRulesDependencies,
    'deleteRule' | 'getRuleById' | 'publishWhitelistChanged' | 'withTransaction'
  > = defaultRulesDependencies
): Promise<GroupsResult<{ deleted: boolean }>> {
  let ruleGroupId = groupId;
  if (!ruleGroupId) {
    const rule = await deps.getRuleById(id);
    ruleGroupId = rule?.groupId;
  }

  const { deleted } = await deleteWhitelistRule(
    { groupId: ruleGroupId, id },
    {
      deleteRule: deps.deleteRule,
      publishWhitelistChanged: deps.publishWhitelistChanged,
      writeTransactionalCommand: DomainEventsService.writeTransactionalCommand,
      withTransaction: deps.withTransaction,
    }
  );

  return { ok: true, data: { deleted } };
}

export async function revokeAutoApproval(
  input: { id: string; groupId: string; resolvedBy: string },
  deps: GroupsRulesDependencies = defaultRulesDependencies
): Promise<GroupsResult<{ revoked: boolean; blockedRuleId: string | null }>> {
  const rule = await deps.getRuleById(input.id);
  if (rule?.groupId !== input.groupId) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Rule not found' } };
  }

  if (rule.type !== 'whitelist' || rule.source !== 'auto_extension') {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'Only automatic whitelist approvals can be revoked this way',
      },
    };
  }

  try {
    const result = await revokeAutomaticWhitelistRule(
      { resolvedBy: input.resolvedBy, rule },
      {
        createRule: deps.createRule,
        deleteRule: deps.deleteRule,
        publishWhitelistChanged: deps.publishWhitelistChanged,
        writeTransactionalCommand: DomainEventsService.writeTransactionalCommand,
        withTransaction: deps.withTransaction,
      }
    );

    return { ok: true, data: result };
  } catch (error) {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: error instanceof Error ? error.message : String(error),
      },
    };
  }
}

export async function bulkDeleteRules(
  ids: string[],
  options?: { rules?: Rule[] },
  deps: Pick<
    GroupsRulesDependencies,
    'bulkDeleteRules' | 'getRulesByIds' | 'publishWhitelistChanged' | 'withTransaction'
  > = defaultRulesDependencies
): Promise<GroupsResult<{ deleted: number; rules: Rule[] }>> {
  if (ids.length === 0) {
    return { ok: true, data: { deleted: 0, rules: [] } };
  }

  const rules = options?.rules ?? (await deps.getRulesByIds(ids));
  const { deleted } = await bulkDeleteWhitelistRules(
    { ids, rules },
    {
      bulkDeleteRules: deps.bulkDeleteRules,
      publishWhitelistChanged: deps.publishWhitelistChanged,
      writeTransactionalCommand: DomainEventsService.writeTransactionalCommand,
      withTransaction: deps.withTransaction,
    }
  );

  return { ok: true, data: { deleted, rules } };
}

export async function updateRule(
  input: UpdateRuleInput,
  deps: Pick<
    GroupsRulesDependencies,
    'getGroupById' | 'getRuleById' | 'publishWhitelistChanged' | 'updateRule' | 'withTransaction'
  > = defaultRulesDependencies
): Promise<GroupsResult<Rule>> {
  const group = await ensureGroupExists(input.groupId, deps);
  if (!group.ok) {
    return group;
  }

  const existingRule = await deps.getRuleById(input.id);
  if (!existingRule) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Rule not found' } };
  }

  if (existingRule.groupId !== input.groupId) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Rule does not belong to this group' },
    };
  }

  let cleanedValue = input.value;
  const didChangeExport =
    cleanedValue !== undefined &&
    cleanRuleValue(cleanedValue, existingRule.type === 'blocked_path') !== existingRule.value;

  if (cleanedValue !== undefined) {
    cleanedValue = cleanRuleValue(cleanedValue, existingRule.type === 'blocked_path');
    if (!cleanedValue) {
      return { ok: false, error: { code: 'BAD_REQUEST', message: 'Value cannot be empty' } };
    }

    const validation = validateRuleValue(cleanedValue, existingRule.type);
    if (!validation.valid) {
      return {
        ok: false,
        error: { code: 'BAD_REQUEST', message: validation.error ?? 'Invalid rule value format' },
      };
    }
  }

  const updated = await DomainEventsService.writeTransactionalCommand(
    {
      publishers: {
        publishWhitelistChanged: deps.publishWhitelistChanged,
      },
      transactionRunner: deps.withTransaction,
    },
    async (tx, events) => {
      const result = await (deps.updateRule ?? groupsStorage.updateRule)(
        {
          id: input.id,
          value: cleanedValue,
          comment: input.comment,
        },
        tx
      );

      if (result && didChangeExport) {
        events.publishWhitelistChanged(input.groupId);
      }

      return result;
    }
  );

  if (!updated) {
    return {
      ok: false,
      error: { code: 'CONFLICT', message: 'A rule with this value already exists' },
    };
  }

  return { ok: true, data: updated };
}

export async function setRuleEnabled(
  input: { id: string; groupId: string; enabled: boolean },
  deps: GroupsRulesDependencies = defaultRulesDependencies
): Promise<GroupsResult<Rule>> {
  const existingRule = await deps.getRuleById(input.id);
  if (!existingRule) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Rule not found' } };
  }
  if (existingRule.groupId !== input.groupId) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Rule does not belong to this group' },
    };
  }

  const didUpdate = await DomainEventsService.writeTransactionalCommand(
    {
      publishers: { publishWhitelistChanged: deps.publishWhitelistChanged },
      transactionRunner: deps.withTransaction,
    },
    async (tx, events) => {
      const result = await (deps.setRuleEnabled ?? groupsStorage.setRuleEnabled)(
        input.id,
        input.enabled,
        tx
      );
      if (result && existingRule.enabled !== input.enabled) {
        events.publishWhitelistChanged(input.groupId);
      }
      return result !== null;
    }
  );

  if (!didUpdate) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Rule not found' } };
  }
  const refreshed = await deps.getRuleById(input.id);
  if (!refreshed) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Rule not found after update' } };
  }
  return { ok: true, data: refreshed };
}

export async function bulkSetRulesEnabled(
  ids: string[],
  enabled: boolean,
  options?: { rules?: Rule[] },
  deps: GroupsRulesDependencies = defaultRulesDependencies
): Promise<GroupsResult<{ updated: number; rules: Rule[] }>> {
  if (ids.length === 0) {
    return { ok: true, data: { updated: 0, rules: [] } };
  }
  const rules = options?.rules ?? (await deps.getRulesByIds(ids));

  const updated = await DomainEventsService.writeTransactionalCommand(
    {
      publishers: { publishWhitelistChanged: deps.publishWhitelistChanged },
      transactionRunner: deps.withTransaction,
    },
    async (tx, events) => {
      const count = await (deps.bulkSetRulesEnabled ?? groupsStorage.bulkSetRulesEnabled)(
        ids,
        enabled,
        tx
      );
      if (count > 0) {
        for (const groupId of new Set(rules.map((rule) => rule.groupId))) {
          events.publishWhitelistChanged(groupId);
        }
      }
      return count;
    }
  );

  return { ok: true, data: { updated, rules } };
}

export async function bulkCreateRules(
  input: BulkCreateRulesInput,
  deps: Pick<
    GroupsRulesDependencies,
    'bulkCreateRules' | 'getGroupById' | 'publishWhitelistChanged' | 'withTransaction'
  > = defaultRulesDependencies
): Promise<GroupsResult<{ count: number }>> {
  const group = await ensureGroupExists(input.groupId, deps);
  if (!group.ok) {
    return group;
  }

  const preservePath = input.type === 'blocked_path';
  const cleanedValues = input.values.map((value) => cleanRuleValue(value, preservePath));

  const count = await DomainEventsService.writeTransactionalCommand(
    {
      publishers: {
        publishWhitelistChanged: deps.publishWhitelistChanged,
      },
      transactionRunner: deps.withTransaction,
    },
    async (tx, events) => {
      const createdCount = await (deps.bulkCreateRules ?? groupsStorage.bulkCreateRules)(
        input.groupId,
        input.type,
        cleanedValues,
        'manual',
        tx
      );

      if (createdCount > 0) {
        events.publishWhitelistChanged(input.groupId);
      }

      return createdCount;
    }
  );

  return { ok: true, data: { count } };
}
