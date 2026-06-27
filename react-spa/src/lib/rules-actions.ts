import { trpc } from './trpc';
import { detectRuleType } from './ruleDetection';
import { isDuplicateError } from './error-utils';
import { getRuleTypeBadge, type RuleType } from './rules';
import { reportError } from './reportError';
import type { ProductT, ProductLocale } from '../i18n/product-i18n';

export type ToastFn = (message: string, type: 'success' | 'error', undoAction?: () => void) => void;

export interface AddRuleWithDetectionParams {
  groupId: string;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
  t: ProductT;
  locale: ProductLocale;
}

export interface BulkCreateRulesParams {
  groupId: string;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
  t: ProductT;
  locale: ProductLocale;
}

export interface UpdateRuleParams {
  groupId: string;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  t: ProductT;
  locale: ProductLocale;
}

export interface DeleteRuleParams {
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
  t: ProductT;
  locale: ProductLocale;
}

export interface BulkDeleteRulesParams {
  ids: string[];
  clearSelection?: () => void;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
  t: ProductT;
  locale: ProductLocale;
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
        params.t('rulesActions.alreadyExists', {
          value: detected.cleanedValue,
          badge: getRuleTypeBadge(detected.type, params.locale),
        }),
        'error'
      );
      return false;
    }

    params.onToast(
      params.t('rulesActions.added', {
        value: detected.cleanedValue,
        badge: getRuleTypeBadge(detected.type, params.locale),
      }),
      'success'
    );
    await params.fetchRules();
    await params.fetchCounts();
    return true;
  } catch (err) {
    reportError('Failed to add rule:', err);

    if (isDuplicateError(err)) {
      params.onToast(
        params.t('rulesActions.alreadyExists', {
          value: detected.cleanedValue,
          badge: getRuleTypeBadge(detected.type, params.locale),
        }),
        'error'
      );
      return false;
    }

    params.onToast(params.t('rulesActions.unableToAdd'), 'error');
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
          ? params.t('rulesActions.imported', { created })
          : params.t('rulesActions.importedPartial', {
              created,
              total,
              duplicates: total - created,
            }),
        'success'
      );
      await params.fetchRules();
      await params.fetchCounts();
    } else {
      params.onToast(params.t('rulesActions.allExist'), 'error');
    }

    return { created, total };
  } catch (err) {
    reportError('Failed to bulk create rules:', err);
    params.onToast(params.t('rulesActions.unableToImport'), 'error');
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

    params.onToast(params.t('rulesActions.updated'), 'success');
    await params.fetchRules();
    return true;
  } catch (err) {
    reportError('Failed to update rule:', err);
    params.onToast(params.t('rulesActions.unableToUpdate'), 'error');
    return false;
  }
}

export async function deleteRuleWithUndoAction(
  rule: RuleForUndo,
  params: DeleteRuleParams
): Promise<void> {
  try {
    await trpc.groups.deleteRule.mutate({ id: rule.id, groupId: rule.groupId });

    params.onToast(params.t('rulesActions.deleted', { value: rule.value }), 'success', () => {
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
          params.onToast(params.t('rulesActions.restored', { value: rule.value }), 'success');
        } catch (err) {
          reportError('Failed to undo delete:', err);
          params.onToast(params.t('rulesActions.unableToRestore'), 'error');
        }
      })();
    });

    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to delete rule:', err);
    params.onToast(params.t('rulesActions.unableToDelete'), 'error');
  }
}

export async function revokeAutoApprovalAction(
  rule: RuleForUndo,
  params: DeleteRuleParams
): Promise<void> {
  try {
    const confirmed =
      typeof window === 'undefined' ||
      window.confirm(params.t('rulesActions.confirmRevoke', { value: rule.value }));
    if (!confirmed) return;

    await trpc.groups.revokeAutoApproval.mutate({ id: rule.id, groupId: rule.groupId });
    params.onToast(params.t('rulesActions.blockedAfterRevoke', { value: rule.value }), 'success');
    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to revoke automatic approval:', err);
    params.onToast(params.t('rulesActions.unableToRevoke'), 'error');
  }
}

export interface SetEnabledParams {
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
  t: ProductT;
  locale: ProductLocale;
}

export async function setRuleEnabledAction(
  rule: RuleForUndo,
  enabled: boolean,
  params: SetEnabledParams
): Promise<void> {
  try {
    await trpc.groups.setRuleEnabled.mutate({ id: rule.id, groupId: rule.groupId, enabled });
    const toastMsg = enabled
      ? params.t('rulesActions.enabled', { value: rule.value })
      : params.t('rulesActions.disabled', { value: rule.value });
    params.onToast(toastMsg, 'success', () => {
      void (async () => {
        try {
          await trpc.groups.setRuleEnabled.mutate({
            id: rule.id,
            groupId: rule.groupId,
            enabled: !enabled,
          });
          await params.fetchRules();
          await params.fetchCounts();
        } catch (err) {
          reportError('Failed to undo set-enabled:', err);
          params.onToast(params.t('rulesActions.unableToUpdate'), 'error');
        }
      })();
    });
    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to set rule enabled:', err);
    params.onToast(params.t('rulesActions.unableToUpdate'), 'error');
  }
}

export interface BulkSetEnabledParams {
  ids: string[];
  enabled: boolean;
  clearSelection?: () => void;
  onToast: ToastFn;
  fetchRules: () => Promise<void>;
  fetchCounts: () => Promise<void>;
  t: ProductT;
  locale: ProductLocale;
}

export async function bulkSetRulesEnabledAction(params: BulkSetEnabledParams): Promise<void> {
  if (params.ids.length === 0) return;
  try {
    const result = await trpc.groups.bulkSetRulesEnabled.mutate({
      ids: params.ids,
      enabled: params.enabled,
    });
    params.clearSelection?.();
    const bulkToastMsg = params.enabled
      ? params.t('rulesActions.bulkEnabled', { count: result.updated })
      : params.t('rulesActions.bulkDisabled', { count: result.updated });
    params.onToast(bulkToastMsg, 'success');
    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to bulk set enabled:', err);
    params.onToast(params.t('rulesActions.unableToUpdate'), 'error');
  }
}

export async function bulkDeleteRulesWithUndoAction(params: BulkDeleteRulesParams): Promise<void> {
  if (params.ids.length === 0) return;

  try {
    const result = await trpc.groups.bulkDeleteRules.mutate({ ids: params.ids });

    const deletedRules = result.rules;
    const count = result.deleted;

    params.clearSelection?.();

    params.onToast(params.t('rulesActions.bulkDeleted', { count }), 'success', () => {
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
          params.onToast(
            params.t('rulesActions.bulkRestored', { count: deletedRules.length }),
            'success'
          );
        } catch (err) {
          reportError('Failed to undo bulk delete:', err);
          params.onToast(params.t('rulesActions.unableToRestoreRules'), 'error');
        }
      })();
    });

    await params.fetchRules();
    await params.fetchCounts();
  } catch (err) {
    reportError('Failed to bulk delete rules:', err);
    params.onToast(params.t('rulesActions.unableToDeleteRules'), 'error');
  }
}
