import { useCallback } from 'react';
import {
  addRuleWithDetection,
  bulkCreateRulesAction,
  bulkDeleteRulesWithUndoAction,
  deleteRuleWithUndoAction,
  revokeAutoApprovalAction,
  updateRuleAction,
} from '../lib/rules-actions';
import type { Rule, RuleType } from '../lib/rules';
import { useT, useOpenPathI18n } from '../i18n/product-i18n';

interface UseManagedRulesActionsOptions {
  groupId: string;
  onToast: (message: string, type: 'success' | 'error', undoAction?: () => void) => void;
  selectedIds: Set<string>;
  clearSelection: () => void;
  refetchRules: () => Promise<void>;
  refetchCounts: () => Promise<void>;
}

export function useManagedRulesActions({
  groupId,
  onToast,
  selectedIds,
  clearSelection,
  refetchRules,
  refetchCounts,
}: UseManagedRulesActionsOptions) {
  const t = useT();
  const { locale } = useOpenPathI18n();

  const addRule = useCallback(
    async (value: string): Promise<boolean> => {
      return addRuleWithDetection(value, {
        groupId,
        onToast,
        fetchRules: refetchRules,
        fetchCounts: refetchCounts,
        t,
        locale,
      });
    },
    [groupId, onToast, refetchRules, refetchCounts, t, locale]
  );

  const deleteRule = useCallback(
    async (rule: Rule): Promise<void> => {
      if (rule.type === 'whitelist' && rule.source === 'auto_extension') {
        await revokeAutoApprovalAction(rule, {
          onToast,
          fetchRules: refetchRules,
          fetchCounts: refetchCounts,
          t,
          locale,
        });
        return;
      }

      await deleteRuleWithUndoAction(rule, {
        onToast,
        fetchRules: refetchRules,
        fetchCounts: refetchCounts,
        t,
        locale,
      });
    },
    [onToast, refetchRules, refetchCounts, t, locale]
  );

  const updateRule = useCallback(
    async (id: string, data: { value?: string; comment?: string | null }): Promise<boolean> => {
      return updateRuleAction(id, data, {
        groupId,
        onToast,
        fetchRules: refetchRules,
        t,
        locale,
      });
    },
    [groupId, onToast, refetchRules, t, locale]
  );

  const bulkDeleteRules = useCallback(async (): Promise<void> => {
    if (selectedIds.size === 0) return;

    await bulkDeleteRulesWithUndoAction({
      ids: Array.from(selectedIds),
      clearSelection,
      onToast,
      fetchRules: refetchRules,
      fetchCounts: refetchCounts,
      t,
      locale,
    });
  }, [selectedIds, clearSelection, onToast, refetchRules, refetchCounts, t, locale]);

  const bulkCreateRules = useCallback(
    async (values: string[], type: RuleType): Promise<{ created: number; total: number }> => {
      if (values.length === 0) return { created: 0, total: 0 };

      return bulkCreateRulesAction(values, type, {
        groupId,
        onToast,
        fetchRules: refetchRules,
        fetchCounts: refetchCounts,
        t,
        locale,
      });
    },
    [groupId, onToast, refetchRules, refetchCounts, t, locale]
  );

  return {
    addRule,
    deleteRule,
    updateRule,
    bulkDeleteRules,
    bulkCreateRules,
  };
}
