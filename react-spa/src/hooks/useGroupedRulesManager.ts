import { useRulesFilters, type RulesFilterType } from './useRulesFilters';
import type { Rule, RuleType } from '../lib/rules';
import type { DomainGroup } from '../lib/rule-groups';
import { useGroupedRulesData } from './useGroupedRulesData';
import { useManagedRulesActions } from './useManagedRulesActions';
import { useGroupedRulesSelection } from './useGroupedRulesSelection';

export type FilterType = RulesFilterType;
export type { DomainGroup } from '../lib/rule-groups';

interface UseGroupedRulesManagerOptions {
  groupId: string;
  onToast: (message: string, type: 'success' | 'error', undoAction?: () => void) => void;
}

export interface UseGroupedRulesManagerReturn {
  // Data
  domainGroups: DomainGroup[];
  totalGroups: number;
  totalRules: number;
  loading: boolean;
  error: string | null;

  // Pagination (by domain groups, not individual rules)
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
  counts: { all: number; allowed: number; blocked: number; disabled: number };

  // Selection
  selectedIds: Set<string>;
  toggleSelection: (id: string) => void;
  toggleSelectAll: () => void;
  selectGroup: (rootDomain: string) => void;
  deselectGroup: (rootDomain: string) => void;
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
  setRuleEnabled: (rule: Rule, enabled: boolean) => Promise<void>;
  bulkSetRulesEnabled: (enabled: boolean) => Promise<void>;
  refetch: () => Promise<void>;
}

/**
 * Hook for managing rules grouped by root domain with pagination on groups.
 * This ensures domain groups are never split across pages.
 */
export function useGroupedRulesManager({
  groupId,
  onToast,
}: UseGroupedRulesManagerOptions): UseGroupedRulesManagerReturn {
  const { filter, page, search, setFilter, setPage, setSearch } = useRulesFilters();

  // Counts for tabs
  const { counts, domainGroups, error, loading, refetch, totalGroups, totalPages, totalRules } =
    useGroupedRulesData({
      filter,
      groupId,
      page,
      search,
    });
  const {
    clearSelection,
    deselectGroup,
    hasSelection,
    isAllSelected,
    selectedIds,
    selectGroup,
    toggleSelectAll,
    toggleSelection,
  } = useGroupedRulesSelection({
    domainGroups,
    resetKeys: [page, filter, search],
  });
  const {
    addRule,
    bulkCreateRules,
    bulkDeleteRules,
    bulkSetRulesEnabled,
    deleteRule,
    setRuleEnabled,
    updateRule,
  } = useManagedRulesActions({
    clearSelection,
    groupId,
    onToast,
    refetchCounts: refetch,
    refetchRules: refetch,
    selectedIds,
  });

  const hasMore = page < totalPages;

  return {
    // Data
    domainGroups,
    totalGroups,
    totalRules,
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
    selectGroup,
    deselectGroup,
    clearSelection,
    isAllSelected,
    hasSelection,

    // Actions
    addRule,
    deleteRule,
    bulkDeleteRules,
    bulkCreateRules,
    updateRule,
    setRuleEnabled,
    bulkSetRulesEnabled,
    refetch,
  };
}

export default useGroupedRulesManager;
