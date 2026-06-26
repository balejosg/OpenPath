import React from 'react';
import { ArrowDown, ArrowUp, ArrowUpDown, CheckSquare, Minus, Square } from 'lucide-react';
import type { SortConfig, SortField } from '../../hooks/useRuleTableSort';
import { useT } from '../../i18n/product-i18n';

interface RulesTableHeaderProps {
  hasSelectionFeature: boolean;
  hasSelection?: boolean;
  isAllSelected?: boolean;
  onToggleSelectAll?: () => void;
  onSort: (field: SortField) => void;
  sortConfig: SortConfig | null;
  readOnly: boolean;
}

function renderSortIcon(field: SortField, sortConfig: SortConfig | null) {
  const activeSort = sortConfig?.field === field ? sortConfig : null;

  if (!activeSort) {
    return <ArrowUpDown size={14} className="text-slate-300" />;
  }
  return activeSort.direction === 'asc' ? (
    <ArrowUp size={14} className="text-blue-600" />
  ) : (
    <ArrowDown size={14} className="text-blue-600" />
  );
}

export const RulesTableHeader: React.FC<RulesTableHeaderProps> = ({
  hasSelection,
  hasSelectionFeature,
  isAllSelected,
  onSort,
  onToggleSelectAll,
  readOnly,
  sortConfig,
}) => {
  const t = useT();
  return (
    <thead>
      <tr className="bg-slate-50 border-b border-slate-200 text-xs uppercase text-slate-500 font-bold tracking-wider">
        {hasSelectionFeature && (
          <th className="px-4 py-3 w-10">
            <button
              onClick={onToggleSelectAll}
              className="p-1 text-slate-400 hover:text-slate-600 transition-colors"
              title={isAllSelected ? t('common.deselectAll') : t('common.selectAll')}
            >
              {isAllSelected ? (
                <CheckSquare size={18} className="text-blue-600" />
              ) : hasSelection ? (
                <Minus size={18} className="text-blue-400" />
              ) : (
                <Square size={18} />
              )}
            </button>
          </th>
        )}
        <th className="px-4 py-3">
          <button
            onClick={() => onSort('value')}
            className="flex items-center gap-1 hover:text-slate-700 transition-colors group/sort"
            data-testid="sort-value"
          >
            {t('rules.header.value')}
            <span className="opacity-50 group-hover/sort:opacity-100 transition-opacity">
              {renderSortIcon('value', sortConfig)}
            </span>
          </button>
        </th>
        <th className="px-4 py-3 w-32">
          <button
            onClick={() => onSort('type')}
            className="flex items-center gap-1 hover:text-slate-700 transition-colors group/sort"
            data-testid="sort-type"
          >
            {t('rules.header.type')}
            <span className="opacity-50 group-hover/sort:opacity-100 transition-opacity">
              {renderSortIcon('type', sortConfig)}
            </span>
          </button>
        </th>
        <th className="px-4 py-3 hidden md:table-cell">{t('rules.header.comment')}</th>
        <th className="px-4 py-3 w-28 hidden sm:table-cell">
          <button
            onClick={() => onSort('createdAt')}
            className="flex items-center gap-1 hover:text-slate-700 transition-colors group/sort"
            data-testid="sort-createdAt"
          >
            {t('rules.header.date')}
            <span className="opacity-50 group-hover/sort:opacity-100 transition-opacity">
              {renderSortIcon('createdAt', sortConfig)}
            </span>
          </button>
        </th>
        {!readOnly && <th className="px-4 py-3 w-20 text-right">{t('common.actions')}</th>}
      </tr>
    </thead>
  );
};
