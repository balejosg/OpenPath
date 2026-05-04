import { useEffect, useRef } from 'react';
import type { Rule, RuleType } from '../lib/rules';
import type { DomainGroup } from '../lib/rule-groups';
import {
  useGroupedRulesManager,
  type UseGroupedRulesManagerReturn,
} from './useGroupedRulesManager';
import { useRulesManager, type FilterType, type UseRulesManagerReturn } from './useRulesManager';

export type ManagedRulesCollectionMode = 'flat' | 'hierarchical';
export type ManagedRulesFilterType = FilterType;
export type { DomainGroup };

interface UseManagedRulesCollectionOptions {
  groupId: string;
  mode: ManagedRulesCollectionMode;
  onToast: (message: string, type: 'success' | 'error', undoAction?: () => void) => void;
}

export interface ManagedRulesCounts {
  all: number;
  allowed: number;
  automatic: number;
  blocked: number;
}

export interface ManagedRulesSelection {
  selectedIds: Set<string>;
  toggleSelection: (id: string) => void;
  toggleSelectAll: () => void;
  selectGroup: (rootDomain: string) => void;
  deselectGroup: (rootDomain: string) => void;
  clearSelection: () => void;
  isAllSelected: boolean;
  hasSelection: boolean;
}

export interface ManagedRulesActions {
  addRule: (value: string) => Promise<boolean>;
  deleteRule: (rule: Rule) => Promise<void>;
  bulkDeleteRules: () => Promise<void>;
  bulkCreateRules: (
    values: string[],
    type: RuleType
  ) => Promise<{ created: number; total: number }>;
  updateRule: (id: string, data: { value?: string; comment?: string | null }) => Promise<boolean>;
}

export interface ManagedRulesCollection {
  mode: ManagedRulesCollectionMode;
  rules: Rule[];
  domainGroups: DomainGroup[];
  totalRules: number;
  totalGroups: number;
  counts: ManagedRulesCounts;
  loading: boolean;
  error: string | null;
  filter: ManagedRulesFilterType;
  setFilter: (filter: ManagedRulesFilterType) => void;
  search: string;
  setSearch: (search: string) => void;
  page: number;
  setPage: (page: number) => void;
  totalPages: number;
  hasMore: boolean;
  selection: ManagedRulesSelection;
  actions: ManagedRulesActions;
  refetch: () => Promise<void>;
}

const noopGroupSelection = () => {
  /* Flat mode has no groups to select. */
};

function adaptFlatRulesManager(manager: UseRulesManagerReturn): ManagedRulesCollection {
  return {
    mode: 'flat',
    rules: manager.rules,
    domainGroups: [],
    totalRules: manager.total,
    totalGroups: 0,
    counts: manager.counts,
    loading: manager.loading,
    error: manager.error,
    filter: manager.filter,
    setFilter: manager.setFilter,
    search: manager.search,
    setSearch: manager.setSearch,
    page: manager.page,
    setPage: manager.setPage,
    totalPages: manager.totalPages,
    hasMore: manager.hasMore,
    selection: {
      selectedIds: manager.selectedIds,
      toggleSelection: manager.toggleSelection,
      toggleSelectAll: manager.toggleSelectAll,
      selectGroup: noopGroupSelection,
      deselectGroup: noopGroupSelection,
      clearSelection: manager.clearSelection,
      isAllSelected: manager.isAllSelected,
      hasSelection: manager.hasSelection,
    },
    actions: {
      addRule: manager.addRule,
      deleteRule: manager.deleteRule,
      bulkDeleteRules: manager.bulkDeleteRules,
      bulkCreateRules: manager.bulkCreateRules,
      updateRule: manager.updateRule,
    },
    refetch: manager.refetch,
  };
}

function adaptGroupedRulesManager(manager: UseGroupedRulesManagerReturn): ManagedRulesCollection {
  return {
    mode: 'hierarchical',
    rules: manager.domainGroups.flatMap((group) => group.rules),
    domainGroups: manager.domainGroups,
    totalRules: manager.totalRules,
    totalGroups: manager.totalGroups,
    counts: manager.counts,
    loading: manager.loading,
    error: manager.error,
    filter: manager.filter,
    setFilter: manager.setFilter,
    search: manager.search,
    setSearch: manager.setSearch,
    page: manager.page,
    setPage: manager.setPage,
    totalPages: manager.totalPages,
    hasMore: manager.hasMore,
    selection: {
      selectedIds: manager.selectedIds,
      toggleSelection: manager.toggleSelection,
      toggleSelectAll: manager.toggleSelectAll,
      selectGroup: manager.selectGroup,
      deselectGroup: manager.deselectGroup,
      clearSelection: manager.clearSelection,
      isAllSelected: manager.isAllSelected,
      hasSelection: manager.hasSelection,
    },
    actions: {
      addRule: manager.addRule,
      deleteRule: manager.deleteRule,
      bulkDeleteRules: manager.bulkDeleteRules,
      bulkCreateRules: manager.bulkCreateRules,
      updateRule: manager.updateRule,
    },
    refetch: manager.refetch,
  };
}

export function useManagedRulesCollection({
  groupId,
  mode,
  onToast,
}: UseManagedRulesCollectionOptions): ManagedRulesCollection {
  const flatManager = useRulesManager({ groupId, onToast });
  const groupedManager = useGroupedRulesManager({ groupId, onToast });
  const previousModeRef = useRef(mode);
  const activeRefetch = mode === 'hierarchical' ? groupedManager.refetch : flatManager.refetch;

  useEffect(() => {
    if (previousModeRef.current === mode) return;

    previousModeRef.current = mode;
    void activeRefetch();
  }, [activeRefetch, mode]);

  return mode === 'hierarchical'
    ? adaptGroupedRulesManager(groupedManager)
    : adaptFlatRulesManager(flatManager);
}
