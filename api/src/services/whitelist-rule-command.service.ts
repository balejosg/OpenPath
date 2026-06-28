import { withTransaction, type DbExecutor } from '../db/index.js';
import * as groupsStorage from '../lib/groups-storage.js';
import type { CreateRuleResult, Rule, RuleType } from '../lib/groups-storage.js';

import DomainEventsService from './domain-events.service.js';
import { updateStoredRequestStatus, type StoredDomainRequest } from './request-command-shared.js';
import type { DomainEventCollector } from './domain-events/types.js';

export interface WhitelistRuleCommandDependencies {
  bulkDeleteRules: typeof groupsStorage.bulkDeleteRules;
  createTransactionalWriter?: typeof DomainEventsService.createTransactionalWriter;
  createRule: typeof groupsStorage.createRule;
  deleteRule: typeof groupsStorage.deleteRule;
  publishWhitelistChanged: (groupId: string) => void;
  updateRequestStatus: typeof updateStoredRequestStatus;
  writeTransactionalCommand?: typeof DomainEventsService.writeTransactionalCommand;
  withTransaction: typeof withTransaction;
}

export interface ManualWhitelistRuleInput {
  comment?: string | null | undefined;
  groupId: string;
  type: RuleType;
  value: string;
}

export interface ApproveWhitelistRequestInput {
  domain: string;
  requestId: string;
  resolvedBy: string;
  targetGroup: {
    id: string;
    name: string;
  };
}

export interface ApprovedWhitelistRequestCommandResult {
  createdRule: boolean;
  updated: StoredDomainRequest;
}

export interface BulkDeleteWhitelistRulesInput {
  ids: string[];
  rules: Rule[];
}

type TransactionDeps = Pick<
  WhitelistRuleCommandDependencies,
  | 'createTransactionalWriter'
  | 'publishWhitelistChanged'
  | 'withTransaction'
  | 'writeTransactionalCommand'
>;

type CreateRuleDeps = Pick<
  WhitelistRuleCommandDependencies,
  | 'createRule'
  | 'createTransactionalWriter'
  | 'publishWhitelistChanged'
  | 'withTransaction'
  | 'writeTransactionalCommand'
>;

type DeleteRuleDeps = Pick<
  WhitelistRuleCommandDependencies,
  | 'createTransactionalWriter'
  | 'deleteRule'
  | 'publishWhitelistChanged'
  | 'withTransaction'
  | 'writeTransactionalCommand'
>;

type BulkDeleteRuleDeps = Pick<
  WhitelistRuleCommandDependencies,
  | 'bulkDeleteRules'
  | 'createTransactionalWriter'
  | 'publishWhitelistChanged'
  | 'withTransaction'
  | 'writeTransactionalCommand'
>;

type RequestApprovalDeps = Pick<
  WhitelistRuleCommandDependencies,
  | 'createRule'
  | 'createTransactionalWriter'
  | 'publishWhitelistChanged'
  | 'updateRequestStatus'
  | 'writeTransactionalCommand'
  | 'withTransaction'
>;

export const defaultWhitelistRuleCommandDependencies: WhitelistRuleCommandDependencies = {
  bulkDeleteRules: groupsStorage.bulkDeleteRules,
  createRule: groupsStorage.createRule,
  deleteRule: groupsStorage.deleteRule,
  publishWhitelistChanged: DomainEventsService.publishWhitelistChanged.bind(DomainEventsService),
  updateRequestStatus: updateStoredRequestStatus,
  writeTransactionalCommand: DomainEventsService.writeTransactionalCommand,
  withTransaction,
};

function normalizeRuleComment(comment: string | null | undefined): string | null {
  return comment ?? null;
}

async function withWhitelistEvents<TResult>(
  deps: TransactionDeps,
  operation: (tx: DbExecutor, events: DomainEventCollector) => Promise<TResult>
): Promise<TResult> {
  const writeTransactionalCommand =
    deps.writeTransactionalCommand ?? DomainEventsService.writeTransactionalCommand;

  return writeTransactionalCommand<DbExecutor, TResult>(
    {
      publishers: {
        publishWhitelistChanged: deps.publishWhitelistChanged,
      },
      transactionRunner: deps.withTransaction,
    },
    operation
  );
}

export async function createManualWhitelistRule(
  input: ManualWhitelistRuleInput,
  deps: CreateRuleDeps = defaultWhitelistRuleCommandDependencies
): Promise<CreateRuleResult> {
  return withWhitelistEvents(deps, async (tx, events) => {
    const created = await deps.createRule(
      input.groupId,
      input.type,
      input.value,
      normalizeRuleComment(input.comment),
      tx
    );

    if (created.success && created.id) {
      events.publishWhitelistChanged(input.groupId);
    }

    return created;
  });
}

export async function deleteWhitelistRule(
  input: { groupId?: string | undefined; id: string },
  deps: DeleteRuleDeps = defaultWhitelistRuleCommandDependencies
): Promise<{ deleted: boolean }> {
  const deleted = await withWhitelistEvents(deps, async (tx, events) => {
    const wasDeleted = await deps.deleteRule(input.id, tx);
    if (wasDeleted && input.groupId) {
      events.publishWhitelistChanged(input.groupId);
    }
    return wasDeleted;
  });

  return { deleted };
}

export async function bulkDeleteWhitelistRules(
  input: BulkDeleteWhitelistRulesInput,
  deps: BulkDeleteRuleDeps = defaultWhitelistRuleCommandDependencies
): Promise<{ deleted: number }> {
  const deleted = await withWhitelistEvents(deps, async (tx, events) => {
    const deletedCount = await deps.bulkDeleteRules(input.ids, tx);

    if (deletedCount > 0) {
      const affectedGroups = new Set(input.rules.map((rule) => rule.groupId));
      for (const groupId of affectedGroups) {
        events.publishWhitelistChanged(groupId);
      }
    }

    return deletedCount;
  });

  return { deleted };
}

export async function approveWhitelistRequest(
  input: ApproveWhitelistRequestInput,
  deps: RequestApprovalDeps = defaultWhitelistRuleCommandDependencies
): Promise<ApprovedWhitelistRequestCommandResult> {
  return withWhitelistEvents(deps, async (tx, events) => {
    const ruleResult = await deps.createRule(
      input.targetGroup.id,
      'whitelist',
      input.domain,
      null,
      tx
    );

    if (!ruleResult.success && ruleResult.error !== 'Rule already exists') {
      throw new Error(ruleResult.error ?? 'Failed to add domain to whitelist');
    }

    const updated = await deps.updateRequestStatus(
      input.requestId,
      'approved',
      input.resolvedBy,
      `Added to ${input.targetGroup.name}`,
      {
        executor: tx,
        expectedStatus: 'pending',
      }
    );

    if (!updated) {
      throw new Error('Request is no longer pending');
    }

    if (ruleResult.success) {
      events.publishWhitelistChanged(input.targetGroup.id);
    }

    return {
      createdRule: ruleResult.success,
      updated,
    };
  });
}

export default {
  approveWhitelistRequest,
  bulkDeleteWhitelistRules,
  createManualWhitelistRule,
  deleteWhitelistRule,
};
