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

export interface AutomaticWhitelistRuleInput {
  diagnosticContext?: string | undefined;
  domain: string;
  groupId: string;
  originPage?: string | undefined;
  reason?: string | undefined;
}

export interface AutomaticWhitelistRuleCommandResult {
  duplicate: boolean;
  status: 'approved' | 'duplicate';
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

function createSourceComment(input: AutomaticWhitelistRuleInput): string {
  const reasonText = input.reason ?? '';
  const diagnosticText = input.diagnosticContext
    ? ` - diagnostic (${input.diagnosticContext})`
    : '';

  return input.originPage
    ? `Auto-approved via Firefox extension (${input.originPage.slice(0, 300)})${reasonText ? ` - ${reasonText}` : ''}${diagnosticText}`
    : `Auto-approved via Firefox extension${reasonText ? ` - ${reasonText}` : ''}${diagnosticText}`;
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
      'manual',
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
      'manual',
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

export async function createAutomaticWhitelistRule(
  input: AutomaticWhitelistRuleInput,
  deps: CreateRuleDeps = defaultWhitelistRuleCommandDependencies
): Promise<AutomaticWhitelistRuleCommandResult> {
  const created = await withWhitelistEvents(deps, async (tx, events) => {
    const result = await deps.createRule(
      input.groupId,
      'whitelist',
      input.domain,
      createSourceComment(input),
      'auto_extension',
      tx
    );

    if (result.success) {
      events.publishWhitelistChanged(input.groupId);
    }

    return result;
  });

  if (!created.success && created.error !== 'Rule already exists') {
    throw new Error(created.error ?? 'Could not create rule');
  }

  const duplicate = created.error === 'Rule already exists';
  return {
    duplicate,
    status: duplicate ? 'duplicate' : 'approved',
  };
}

export default {
  approveWhitelistRequest,
  bulkDeleteWhitelistRules,
  createAutomaticWhitelistRule,
  createManualWhitelistRule,
  deleteWhitelistRule,
};
