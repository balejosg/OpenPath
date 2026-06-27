import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { useRulesManagerViewModel } from '../useRulesManagerViewModel';

const flatRefetch = vi.fn().mockResolvedValue(undefined);
const groupedRefetch = vi.fn().mockResolvedValue(undefined);
const addRule = vi.fn().mockResolvedValue(true);

vi.mock('../useRulesManager', () => ({
  useRulesManager: () => ({
    rules: [],
    total: 0,
    loading: false,
    error: null,
    page: 1,
    setPage: vi.fn(),
    totalPages: 1,
    filter: 'all',
    setFilter: vi.fn(),
    search: '',
    setSearch: vi.fn(),
    counts: { all: 0, allowed: 0, blocked: 0, disabled: 0 },
    selectedIds: new Set<string>(),
    toggleSelection: vi.fn(),
    toggleSelectAll: vi.fn(),
    clearSelection: vi.fn(),
    isAllSelected: false,
    hasSelection: false,
    addRule,
    deleteRule: vi.fn(),
    bulkDeleteRules: vi.fn(),
    bulkCreateRules: vi.fn(),
    updateRule: vi.fn(),
    refetch: flatRefetch,
  }),
}));

vi.mock('../useGroupedRulesManager', () => ({
  useGroupedRulesManager: () => ({
    domainGroups: [],
    totalRules: 0,
    loading: false,
    error: null,
    page: 1,
    setPage: vi.fn(),
    totalPages: 1,
    filter: 'all',
    setFilter: vi.fn(),
    search: '',
    setSearch: vi.fn(),
    counts: { all: 0, allowed: 0, blocked: 0, disabled: 0 },
    selectedIds: new Set<string>(),
    toggleSelection: vi.fn(),
    toggleSelectAll: vi.fn(),
    clearSelection: vi.fn(),
    isAllSelected: false,
    hasSelection: false,
    addRule: vi.fn(),
    deleteRule: vi.fn(),
    bulkDeleteRules: vi.fn(),
    bulkCreateRules: vi.fn(),
    updateRule: vi.fn(),
    refetch: groupedRefetch,
  }),
}));

vi.mock('../../lib/ruleDetection', () => ({
  detectRuleType: () => ({ type: 'whitelist', confidence: 'high' }),
  validateRuleValue: () => ({ valid: true }),
}));

describe('useRulesManagerViewModel', () => {
  it('adds rules through the active manager and refetches when changing view mode', async () => {
    const { result } = renderHook(() =>
      useRulesManagerViewModel({
        groupId: 'group-1',
        onToast: vi.fn(),
        onError: vi.fn(),
      })
    );

    act(() => {
      result.current.handleInputChange('example.com');
    });

    await act(async () => {
      await result.current.handleAddRule(false);
    });

    act(() => {
      result.current.handleViewModeChange('hierarchical');
    });

    expect(addRule).toHaveBeenCalledWith('example.com');
    await waitFor(() => {
      expect(groupedRefetch).toHaveBeenCalled();
    });
    expect(result.current.viewMode).toBe('hierarchical');
  });
});
