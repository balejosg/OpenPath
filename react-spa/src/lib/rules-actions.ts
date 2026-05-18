import { trpc } from './trpc';
import { detectRuleType } from './ruleDetection';
import { isDuplicateError } from './error-utils';
import { getRuleTypeBadge, type RuleType } from './rules';
import { reportError } from './reportError';

export type ToastFn = (message: string, type: 'success' | 'error', undoAction?: () => void) => void;

export interface AddRuleWithDetectionParams {
  groupId: string;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
}

export interface BulkCreateRulesParams {
  groupId: string;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
}

export interface UpdateRuleParams {
  groupId: string;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
}

export interface DeleteRuleParams {
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
}

export interface BulkDeleteRulesParams {
  ids: string[];
  clearSelection?: () => void;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
}

export interface RuleForUndo {
  id: string;
  groupId: string;
  type: RuleType;
  value: string;
  comment: string | null | undefined;
}

export function readCreatedFlag(value: unknown): boolean | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const created = (value as { created?: unknown }).created;
  return typeof created === 'boolean' ? created : undefined;
}

export async function addRuleWithDetection(
  value: string,
  params: AddRuleWithDetectionParams
): Promise<boolean> {
  const trimmed = value.trim();
  if (!trimmed) return false;

  // Get existing whitelist for detection
  const existingWhitelist = await trpc.groups.listRules.query({
    groupId: params.groupId,
    type: 'whitelist',
  });
  const whitelistDomains = existingWhitelist.map((r) => r.value);

  // Detect type
  const detected = detectRuleType(trimmed, whitelistDomains);

  try {
    const result = await trpc.groups.createRule.mutate({
      groupId: params.groupId,
      type: detected.type,
      value: detected.cleanedValue,
    });

    const created = readCreatedFlag(result);
    if (created === false) {
      params.onToast(
        `"${detected.cleanedValue}" already exists as ${getRuleTypeBadge(detected.type)}`,
        'error'
      );
      return false;
    }

    params.onToast(
      `"${detected.cleanedValue}" added as ${getRuleTypeBadge(detected.type)}`,
      'success'
    );
    await params.fetchRules();
    await params.fetchCounts();
    return true;
  } catch (err) {
    reportError('Failed to add rule:', err);

    if (isDuplicateError(err)) {
      params.onToast(
        `"${detected.cleanedValue}" already exists as ${getRuleTypeBadge(detected.type)}`,
        'error'
      );
      return false;
    }

    params.onToast('Unable to add rule', 'error');
    return false;
  }
}

export async function bulkCreateRulesAction(
  values: string[],
  type: RuleType,
  params: BulkCreateRulesParams
): Promise<{ created: number; total: number }> {
  if (values.length === 0) return { created: 0, total: 0 };

  try {
    const result = await trpc.groups.bulkCreateRules.mutate({
      groupId: params.groupId,
      type,
      values,
    });

    const created = result.count;
    const total = values.length;

    if (created > 0) {
      params.onToast(
        created === total
          ? `${String(created)} rules imported`
          : `${String(created)} of ${String(total)} rules imported (${String(total - created)} duplicates)`,
        'success'
      );
      await params.fetchRules();
      await params.fetchCounts();
    } else {
      params.onToast('All rules already exist', 'error');
    }

    return { created, total };
  } catch (err) {
    reportError('Failed to bulk create rules:', err);
    params.onToast('Unable to import rules', 'error');
    return { created: 0, total: values.length };
  }
}

export async function updateRuleAction(
  id: string,
  data: { value?: string; comment?: string | null },
  params: UpdateRuleParams
): Promise<boolean> {
  try {
    await trpc.groups.updateRule.mutate({
      id,
      groupId: params.groupId,
      value: data.value,
      comment: data.comment,
    });

    params.onToast('Rule updated', 'success');
    await params.fetchRules();
    return true;
  } catch (err) {
    reportError('Failed to update rule:', err);
    params.onToast('Unable to update rule', 'error');
    return false;
  }
}

export async function deleteRuleWithUndoAction(
  rule: RuleForUndo,
  params: DeleteRuleParams
): Promise<void> {
  try {
    await trpc.groups.deleteRule.mutate({ id: rule.id, groupId: rule.groupId });

    params.onToast(`"${rule.value}" deleted`, 'success', () => {
      void (async () => {
        try {
          await trpc.groups.createRule.mutate({
            groupId: rule.groupId,
            type: rule.type,
            value: rule.value,
            comment: rule.comment ?? undefined,
          });
          await params.fetchRules();
          await params.fetchCounts();
          params.onToast(`"${rule.value}" restored`, 'success');
        } catch (err) {
          reportError('Failed to undo delete:', err);
          params.onToast('Unable to restore rule', 'error');
        }
      })();
    });

    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to delete rule:', err);
    params.onToast('Unable to delete rule', 'error');
  }
}

export async function revokeAutoApprovalAction(
  rule: RuleForUndo,
  params: DeleteRuleParams
): Promise<void> {
  try {
    const confirmed =
      typeof window === 'undefined' ||
      window.confirm(
        `Revoking automatic approval for "${rule.value}" will block this domain from being auto-approved again.`
      );
    if (!confirmed) return;

    await trpc.groups.revokeAutoApproval.mutate({ id: rule.id, groupId: rule.groupId });
    params.onToast(`"${rule.value}" blocked after revoking automatic approval`, 'success');
    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to revoke automatic approval:', err);
    params.onToast('Unable to revoke automatic approval', 'error');
  }
}

export async function bulkDeleteRulesWithUndoAction(params: BulkDeleteRulesParams): Promise<void> {
  if (params.ids.length === 0) return;

  try {
    const result = await trpc.groups.bulkDeleteRules.mutate({ ids: params.ids });

    const deletedRules = result.rules;
    const count = result.deleted;

    params.clearSelection?.();

    params.onToast(`${String(count)} rules deleted`, 'success', () => {
      void (async () => {
        try {
          for (const rule of deletedRules) {
            await trpc.groups.createRule.mutate({
              groupId: rule.groupId,
              type: rule.type,
              value: rule.value,
              comment: rule.comment ?? undefined,
            });
          }
          await params.fetchRules();
          await params.fetchCounts();
          params.onToast(`${String(deletedRules.length)} rules restored`, 'success');
        } catch (err) {
          reportError('Failed to undo bulk delete:', err);
          params.onToast('Unable to restore rules', 'error');
        }
      })();
    });

    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to bulk delete rules:', err);
    params.onToast('Unable to delete rules', 'error');
  }
}
