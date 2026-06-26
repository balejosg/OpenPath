import { act, renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useManagedRulesActions } from '../useManagedRulesActions';

vi.mock('../../lib/rules-actions', () => ({
  addRuleWithDetection: vi.fn().mockResolvedValue(true),
  bulkCreateRulesAction: vi.fn().mockResolvedValue({ created: 1, total: 1 }),
  bulkDeleteRulesWithUndoAction: vi.fn().mockResolvedValue(undefined),
  deleteRuleWithUndoAction: vi.fn().mockResolvedValue(undefined),
  revokeAutoApprovalAction: vi.fn().mockResolvedValue(undefined),
  updateRuleAction: vi.fn().mockResolvedValue(true),
}));

import {
  addRuleWithDetection,
  bulkCreateRulesAction,
  bulkDeleteRulesWithUndoAction,
  deleteRuleWithUndoAction,
  revokeAutoApprovalAction,
  updateRuleAction,
} from '../../lib/rules-actions';

describe('useManagedRulesActions', () => {
  const onToast = vi.fn();
  const clearSelection = vi.fn();
  const refetchRules = vi.fn().mockResolvedValue(undefined);
  const refetchCounts = vi.fn().mockResolvedValue(undefined);

  beforeEach(() => {
    vi.clearAllMocks();
  });

  function renderActions(selectedIds = new Set<string>()) {
    return renderHook(() =>
      useManagedRulesActions({
        groupId: 'group-1',
        onToast,
        selectedIds,
        clearSelection,
        refetchRules,
        refetchCounts,
      })
    );
  }

  it('revokes automatic whitelist approvals instead of deleting with undo', async () => {
    const { result } = renderActions();

    await act(async () => {
      await result.current.deleteRule({
        id: 'auto-1',
        groupId: 'group-1',
        type: 'whitelist',
        source: 'auto_extension',
        value: 'cdn.example.com',
        comment: null,
        createdAt: '2024-01-01',
      });
    });

    expect(revokeAutoApprovalAction).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'auto-1', source: 'auto_extension' }),
      expect.objectContaining({ onToast, fetchRules: refetchRules, fetchCounts: refetchCounts })
    );
    expect(deleteRuleWithUndoAction).not.toHaveBeenCalled();
  });

  it('keeps manual deletes undoable and skips empty bulk operations', async () => {
    const { result } = renderActions();

    await act(async () => {
      await result.current.deleteRule({
        id: 'manual-1',
        groupId: 'group-1',
        type: 'whitelist',
        source: 'manual',
        value: 'example.com',
        comment: null,
        createdAt: '2024-01-01',
      });
      await result.current.bulkDeleteRules();
    });

    expect(deleteRuleWithUndoAction).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'manual-1', source: 'manual' }),
      expect.objectContaining({ onToast, fetchRules: refetchRules, fetchCounts: refetchCounts })
    );
    expect(bulkDeleteRulesWithUndoAction).not.toHaveBeenCalled();
  });

  it('returns an empty result for empty bulk create input', async () => {
    const { result } = renderActions(new Set(['rule-1']));

    await expect(result.current.bulkCreateRules([], 'whitelist')).resolves.toEqual({
      created: 0,
      total: 0,
    });

    expect(bulkCreateRulesAction).not.toHaveBeenCalled();
  });

  it('delegates non-empty bulk operations and clears selection after bulk delete', async () => {
    const { result } = renderActions(new Set(['rule-1', 'rule-2']));

    await act(async () => {
      await result.current.bulkDeleteRules();
      await result.current.bulkCreateRules(['a.example.com'], 'whitelist');
    });

    expect(bulkDeleteRulesWithUndoAction).toHaveBeenCalledWith(
      expect.objectContaining({
        ids: ['rule-1', 'rule-2'],
        clearSelection,
        onToast,
        fetchRules: refetchRules,
        fetchCounts: refetchCounts,
      })
    );
    expect(bulkCreateRulesAction).toHaveBeenCalledWith(
      ['a.example.com'],
      'whitelist',
      expect.objectContaining({
        groupId: 'group-1',
        onToast,
        fetchRules: refetchRules,
        fetchCounts: refetchCounts,
      })
    );
  });

  it('delegates add and update rule actions', async () => {
    const { result } = renderActions();

    await act(async () => {
      await result.current.addRule('example.com');
      await result.current.updateRule('rule-1', { value: 'updated.example.com' });
    });

    expect(addRuleWithDetection).toHaveBeenCalledWith(
      'example.com',
      expect.objectContaining({
        groupId: 'group-1',
        onToast,
        fetchRules: refetchRules,
        fetchCounts: refetchCounts,
      })
    );
    expect(updateRuleAction).toHaveBeenCalledWith(
      'rule-1',
      { value: 'updated.example.com' },
      expect.objectContaining({ groupId: 'group-1', onToast, fetchRules: refetchRules })
    );
  });
});
