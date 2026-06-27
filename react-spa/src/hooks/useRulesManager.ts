import type { Rule, RuleType } from '../lib/rules';
import { useManagedRulesActions } from './useManagedRulesActions';
import { useRulesData } from './useRulesData';
import { useRulesFilters, type RulesFilterType } from './useRulesFilters';
import { useRulesSelection } from './useRulesSelection';

const PAGE_SIZE = 50;
export type FilterType = RulesFilterType;

interface UseRulesManagerOptions {
  groupId: string;
  onToast: (message: string, type: 'success' | 'error', undoAction?: () => void) => void;
}

export interface UseRulesManagerReturn {
  // Data
  rules: Rule[];
  total: number;
  loading: boolean;
  error: string | null;

  // Pagination
  page: number;
  setPage: (page: number) => void;
  totalPages: number;
  hasMore: boolean;

  // Filtering
  filter: FilterType;
  setFilter: (filter: FilterType) => void;
  search: string;
  setSearch: (search: string) => void;

  // Counts
  counts: { all: number; allowed: number; automatic: number; blocked: number; disabled: number };

  // Selection
  selectedIds: Set<string>;
  toggleSelection: (id: string) => void;
  toggleSelectAll: () => void;
  clearSelection: () => void;
  isAllSelected: boolean;
  hasSelection: boolean;

  // Actions
  addRule: (value: string) => Promise<boolean>;
  deleteRule: (rule: Rule) => Promise<void>;
  bulkDeleteRules: () => Promise<void>;
  bulkCreateRules: (
    values: string[],
    type: RuleType
  ) => Promise<{ created: number; total: number }>;
  updateRule: (id: string, data: { value?: string; comment?: string | null }) => Promise<boolean>;
  refetch: () => Promise<void>;
}

/**
 * Hook for managing rules with pagination, filtering, and CRUD operations.
 */
export function useRulesManager({
  groupId,
  onToast,
}: UseRulesManagerOptions): UseRulesManagerReturn {
  const { filter, page, search, setFilter, setPage, setSearch } = useRulesFilters();
  const { counts, error, fetchCounts, fetchRules, loading, rules, total } = useRulesData({
    filter,
    groupId,
    page,
    pageSize: PAGE_SIZE,
    search,
  });
  const {
    clearSelection,
    hasSelection,
    isAllSelected,
    selectedIds,
    toggleSelectAll,
    toggleSelection,
  } = useRulesSelection({
    rules,
    resetKeys: [page, filter, search],
  });
  const { addRule, bulkCreateRules, bulkDeleteRules, deleteRule, updateRule } =
    useManagedRulesActions({
      clearSelection,
      groupId,
      onToast,
      refetchCounts: fetchCounts,
      refetchRules: fetchRules,
      selectedIds,
    });

  // Calculate derived values
  const totalPages = Math.ceil(total / PAGE_SIZE);
  const hasMore = page < totalPages;

  return {
    // Data
    rules,
    total,
    loading,
    error,

    // Pagination
    page,
    setPage,
    totalPages,
    hasMore,

    // Filtering
    filter,
    setFilter,
    search,
    setSearch,

    // Counts
    counts,

    // Selection
    selectedIds,
    toggleSelection,
    toggleSelectAll,
    clearSelection,
    isAllSelected,
    hasSelection,

    // Actions
    addRule,
    deleteRule,
    bulkDeleteRules,
    bulkCreateRules,
    updateRule,
    refetch: async () => {
      await Promise.all([fetchRules(), fetchCounts()]);
    },
  };
}

export default useRulesManager;
