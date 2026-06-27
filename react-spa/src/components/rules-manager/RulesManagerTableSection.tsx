import type { ReactNode } from 'react';
import { AlertCircle } from 'lucide-react';
import type { DomainGroup, ManagedRulesFilterType } from '../../hooks/useManagedRulesCollection';
import type { Rule } from '../../lib/rules';
import { HierarchicalRulesTable } from '../HierarchicalRulesTable';
import { RulesTable } from '../RulesTable';
import { Tabs } from '../ui/Tabs';
import type { ViewMode } from '../../hooks/useRulesManagerViewModel';
import { useT } from '../../i18n/product-i18n';

interface RulesManagerTableSectionProps {
  tabs: { id: ManagedRulesFilterType; label: string; count: number; icon?: ReactNode }[];
  filter: ManagedRulesFilterType;
  error: string | null;
  viewMode: ViewMode;
  rules: Rule[];
  domainGroups: DomainGroup[];
  loading: boolean;
  readOnly: boolean;
  selectedIds: Set<string>;
  isAllSelected: boolean;
  hasSelection: boolean;
  emptyMessage: string;
  onFilterChange: (filter: ManagedRulesFilterType) => void;
  onRetry: () => void;
  onDelete: (rule: Rule) => void;
  onToggleEnabled?: (rule: Rule) => void;
  onSave: (id: string, data: { value?: string; comment?: string | null }) => Promise<boolean>;
  onToggleSelection: (id: string) => void;
  onToggleSelectAll: () => void;
  onBulkDisable?: () => void;
  onBulkEnable?: () => void;
}

export function RulesManagerTableSection({
  tabs,
  filter,
  error,
  viewMode,
  rules,
  domainGroups,
  loading,
  readOnly,
  selectedIds,
  isAllSelected,
  hasSelection,
  emptyMessage,
  onFilterChange,
  onRetry,
  onDelete,
  onToggleEnabled,
  onSave,
  onToggleSelection,
  onToggleSelectAll,
  onBulkDisable,
  onBulkEnable,
}: RulesManagerTableSectionProps) {
  const t = useT();
  return (
    <>
      <Tabs
        tabs={tabs}
        activeTab={filter}
        onChange={(id) => onFilterChange(id as ManagedRulesFilterType)}
      />

      {!readOnly && hasSelection && (
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => onBulkDisable?.()}
            className="px-3 py-1.5 text-sm rounded-md border border-slate-200 text-slate-600 hover:bg-slate-50"
          >
            {t('rulesActions.bulkDisableButton')}
          </button>
          <button
            type="button"
            onClick={() => onBulkEnable?.()}
            className="px-3 py-1.5 text-sm rounded-md border border-slate-200 text-slate-600 hover:bg-slate-50"
          >
            {t('rulesActions.bulkEnableButton')}
          </button>
        </div>
      )}

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-center">
          <AlertCircle className="w-6 h-6 text-red-400 mx-auto mb-2" />
          <p className="text-red-600 text-sm">{error}</p>
          <button
            onClick={onRetry}
            className="text-red-700 hover:text-red-800 text-sm mt-2 underline"
          >
            {t('common.retry')}
          </button>
        </div>
      )}

      {!error && viewMode === 'flat' && (
        <RulesTable
          rules={rules}
          loading={loading}
          readOnly={readOnly}
          onDelete={onDelete}
          onToggleEnabled={readOnly ? undefined : onToggleEnabled}
          onSave={readOnly ? undefined : onSave}
          selectedIds={readOnly ? undefined : selectedIds}
          onToggleSelection={readOnly ? undefined : onToggleSelection}
          onToggleSelectAll={readOnly ? undefined : onToggleSelectAll}
          isAllSelected={readOnly ? undefined : isAllSelected}
          hasSelection={readOnly ? undefined : hasSelection}
          emptyMessage={emptyMessage}
        />
      )}

      {!error && viewMode === 'hierarchical' && (
        <HierarchicalRulesTable
          domainGroups={domainGroups}
          loading={loading}
          readOnly={readOnly}
          onDelete={onDelete}
          onToggleEnabled={readOnly ? undefined : onToggleEnabled}
          onSave={readOnly ? undefined : onSave}
          selectedIds={readOnly ? undefined : selectedIds}
          onToggleSelection={readOnly ? undefined : onToggleSelection}
          onToggleSelectAll={readOnly ? undefined : onToggleSelectAll}
          isAllSelected={readOnly ? undefined : isAllSelected}
          hasSelection={readOnly ? undefined : hasSelection}
          emptyMessage={emptyMessage}
        />
      )}
    </>
  );
}
