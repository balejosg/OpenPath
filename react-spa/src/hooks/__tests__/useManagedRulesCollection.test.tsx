import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { useManagedRulesCollection } from '../useManagedRulesCollection';

const mocks = vi.hoisted(() => {
  const flatRule = {
    id: 'flat-1',
    groupId: 'group-1',
    type: 'whitelist',
    source: 'manual',
    value: 'flat.example.com',
    comment: null,
    createdAt: '2024-01-01T00:00:00Z',
  };
  const groupedRule = {
    id: 'grouped-1',
    groupId: 'group-1',
    type: 'blocked_subdomain',
    source: 'manual',
    value: 'cdn.grouped.example.com',
    comment: null,
    createdAt: '2024-01-01T00:00:00Z',
  };

  return {
    flatRule,
    groupedRule,
    flatSelectedIds: new Set(['flat-1']),
    groupedSelectedIds: new Set(['grouped-1']),
    flatAddRule: vi.fn().mockResolvedValue(true),
    groupedAddRule: vi.fn().mockResolvedValue(true),
    flatRefetch: vi.fn().mockResolvedValue(undefined),
    groupedRefetch: vi.fn().mockResolvedValue(undefined),
    flatSetFilter: vi.fn(),
    groupedSetFilter: vi.fn(),
    flatSetSearch: vi.fn(),
    groupedSetSearch: vi.fn(),
  };
});

vi.mock('../useRulesManager', () => ({
  useRulesManager: () => ({
    rules: [mocks.flatRule],
    total: 1,
    loading: false,
    error: null,
    page: 2,
    setPage: vi.fn(),
    totalPages: 3,
    hasMore: true,
    filter: 'allowed',
    setFilter: mocks.flatSetFilter,
    search: 'flat',
    setSearch: mocks.flatSetSearch,
    counts: { all: 4, allowed: 2, automatic: 1, blocked: 2 },
    selectedIds: mocks.flatSelectedIds,
    toggleSelection: vi.fn(),
    toggleSelectAll: vi.fn(),
    clearSelection: vi.fn(),
    isAllSelected: true,
    hasSelection: true,
    addRule: mocks.flatAddRule,
    deleteRule: vi.fn(),
    bulkDeleteRules: vi.fn(),
    bulkCreateRules: vi.fn(),
    updateRule: vi.fn(),
    refetch: mocks.flatRefetch,
  }),
}));

vi.mock('../useGroupedRulesManager', () => ({
  useGroupedRulesManager: () => ({
    domainGroups: [
      {
        root: 'grouped.example.com',
        rules: [mocks.groupedRule],
        status: 'blocked',
      },
    ],
    totalGroups: 1,
    totalRules: 7,
    loading: false,
    error: null,
    page: 1,
    setPage: vi.fn(),
    totalPages: 1,
    hasMore: false,
    filter: 'blocked',
    setFilter: mocks.groupedSetFilter,
    search: 'grouped',
    setSearch: mocks.groupedSetSearch,
    counts: { all: 7, allowed: 3, automatic: 2, blocked: 4 },
    selectedIds: mocks.groupedSelectedIds,
    toggleSelection: vi.fn(),
    toggleSelectAll: vi.fn(),
    selectGroup: vi.fn(),
    deselectGroup: vi.fn(),
    clearSelection: vi.fn(),
    isAllSelected: false,
    hasSelection: true,
    addRule: mocks.groupedAddRule,
    deleteRule: vi.fn(),
    bulkDeleteRules: vi.fn(),
    bulkCreateRules: vi.fn(),
    updateRule: vi.fn(),
    refetch: mocks.groupedRefetch,
  }),
}));

describe('useManagedRulesCollection', () => {
  const options = {
    groupId: 'group-1',
    onToast: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('adapts the flat manager to the shared collection shape', () => {
    const { result } = renderHook(() =>
      useManagedRulesCollection({
        ...options,
        initialMode: 'flat',
      })
    );

    expect(result.current.mode).toBe('flat');
    expect(result.current.rules).toEqual([mocks.flatRule]);
    expect(result.current.domainGroups).toEqual([]);
    expect(result.current.totalRules).toBe(1);
    expect(result.current.totalGroups).toBe(0);
    expect(result.current.counts.automatic).toBe(1);
    expect(result.current.filters.active).toBe('allowed');
    expect(result.current.filters.setActive).toBe(mocks.flatSetFilter);
    expect(result.current.filters.search).toBe('flat');
    expect(result.current.filters.setSearch).toBe(mocks.flatSetSearch);
    expect(result.current.filters.counts.automatic).toBe(1);
    expect(result.current.page).toBe(2);
    expect(result.current.selection.selectedIds).toBe(mocks.flatSelectedIds);
    expect(result.current.actions.addRule).toBe(mocks.flatAddRule);
    expect(result.current.refetch).toBe(mocks.flatRefetch);
  });

  it('adapts the hierarchical manager to the same collection shape', () => {
    const { result } = renderHook(() =>
      useManagedRulesCollection({
        ...options,
        initialMode: 'hierarchical',
      })
    );

    expect(result.current.mode).toBe('hierarchical');
    expect(result.current.rules).toEqual([mocks.groupedRule]);
    expect(result.current.domainGroups).toEqual([
      {
        root: 'grouped.example.com',
        rules: [mocks.groupedRule],
        status: 'blocked',
      },
    ]);
    expect(result.current.totalRules).toBe(7);
    expect(result.current.totalGroups).toBe(1);
    expect(result.current.counts.blocked).toBe(4);
    expect(result.current.filters.active).toBe('blocked');
    expect(result.current.filters.setActive).toBe(mocks.groupedSetFilter);
    expect(result.current.filters.search).toBe('grouped');
    expect(result.current.filters.setSearch).toBe(mocks.groupedSetSearch);
    expect(result.current.filters.counts.blocked).toBe(4);
    expect(result.current.selection.selectedIds).toBe(mocks.groupedSelectedIds);
    expect(result.current.actions.addRule).toBe(mocks.groupedAddRule);
    expect(result.current.refetch).toBe(mocks.groupedRefetch);
  });

  it('owns view-mode transitions and refetches the newly active adapter', async () => {
    const { result } = renderHook(() =>
      useManagedRulesCollection({
        ...options,
        initialMode: 'flat',
      })
    );

    expect(mocks.flatRefetch).not.toHaveBeenCalled();
    expect(mocks.groupedRefetch).not.toHaveBeenCalled();
    expect(result.current.viewMode.current).toBe('flat');

    act(() => {
      result.current.viewMode.change('hierarchical');
    });

    await waitFor(() => {
      expect(mocks.groupedRefetch).toHaveBeenCalledTimes(1);
    });
    expect(mocks.flatRefetch).not.toHaveBeenCalled();
    expect(result.current.mode).toBe('hierarchical');
    expect(result.current.viewMode.current).toBe('hierarchical');
  });

  it('does not refetch when the requested view mode is already active', () => {
    const { result } = renderHook(() =>
      useManagedRulesCollection({
        ...options,
        initialMode: 'flat',
      })
    );

    act(() => {
      result.current.viewMode.change('flat');
    });

    expect(mocks.flatRefetch).not.toHaveBeenCalled();
    expect(mocks.groupedRefetch).not.toHaveBeenCalled();
  });
});
