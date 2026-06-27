import React from 'react';
import { Loader2 } from 'lucide-react';
import { cn } from '../lib/utils';
import type { Rule, RuleType } from '../lib/rules';
import { RulesTableHeader } from './rules-table/RulesTableHeader';
import { RulesTableRow } from './rules-table/RulesTableRow';
import { useRuleEditor } from '../hooks/useRuleEditor';
import { useRuleTableSort } from '../hooks/useRuleTableSort';
import { useOpenPathI18n } from '../i18n/product-i18n';

export type { Rule, RuleType };
export type { SortConfig, SortDirection, SortField } from '../hooks/useRuleTableSort';

interface RulesTableProps {
  rules: Rule[];
  loading: boolean;
  onDelete: (rule: Rule) => void;
  onToggleEnabled?: (rule: Rule) => void;
  onEdit?: (rule: Rule) => void;
  onSave?: (id: string, data: { value?: string; comment?: string | null }) => Promise<boolean>;
  readOnly?: boolean;
  emptyMessage?: string;
  className?: string;
  // Selection props
  selectedIds?: Set<string>;
  onToggleSelection?: (id: string) => void;
  onToggleSelectAll?: () => void;
  isAllSelected?: boolean;
  hasSelection?: boolean;
}

/**
 * RulesTable - Displays rules in a table format with actions.
 */
export const RulesTable: React.FC<RulesTableProps> = ({
  rules,
  loading,
  onDelete,
  onToggleEnabled,
  onEdit: _onEdit,
  onSave,
  readOnly = false,
  emptyMessage,
  className,
  selectedIds,
  onToggleSelection,
  onToggleSelectAll,
  isAllSelected,
  hasSelection,
}) => {
  const { locale, t } = useOpenPathI18n();
  const hasSelectionFeature =
    !readOnly && selectedIds !== undefined && onToggleSelection !== undefined;
  const {
    cancelEdit,
    editComment,
    editingId,
    editValue,
    handleEditKeyDown,
    isSaving,
    saveEdit,
    setEditComment,
    setEditValue,
    startEdit,
  } = useRuleEditor({
    onSave,
    resolveRule: (id) => rules.find((rule) => rule.id === id),
  });
  const { handleSort, sortConfig, sortedRules } = useRuleTableSort(rules);

  const formatDate = (dateString: string) => {
    try {
      const date = new Date(dateString);
      return date.toLocaleDateString(locale, {
        day: '2-digit',
        month: 'short',
        year: 'numeric',
      });
    } catch {
      return '-';
    }
  };

  if (loading) {
    return (
      <div className={cn('bg-white border border-slate-200 rounded-lg', className)}>
        <div className="flex items-center justify-center py-12 text-slate-400">
          <Loader2 size={20} className="animate-spin mr-2" />
          {t('rules.table.loading')}
        </div>
      </div>
    );
  }

  if (rules.length === 0) {
    return (
      <div className={cn('bg-white border border-slate-200 rounded-lg', className)}>
        <div className="py-12 text-center text-slate-400 text-sm">
          {emptyMessage ?? t('rules.table.empty')}
        </div>
      </div>
    );
  }

  return (
    <div className={cn('bg-white border border-slate-200 rounded-lg overflow-hidden', className)}>
      <div className="overflow-x-auto">
        <table className="w-full text-left border-collapse">
          <RulesTableHeader
            hasSelection={hasSelection}
            hasSelectionFeature={hasSelectionFeature}
            isAllSelected={isAllSelected}
            onSort={handleSort}
            onToggleSelectAll={onToggleSelectAll}
            readOnly={readOnly}
            sortConfig={sortConfig}
          />
          <tbody className="divide-y divide-slate-100">
            {sortedRules.map((rule) => (
              <RulesTableRow
                key={rule.id}
                canEdit={onSave !== undefined}
                editComment={editComment}
                editValue={editValue}
                formatDate={formatDate}
                hasOnSave={onSave !== undefined}
                hasSelectionFeature={hasSelectionFeature}
                isEditing={editingId === rule.id}
                isSaving={isSaving}
                isSelected={selectedIds?.has(rule.id) ?? false}
                onCancelEdit={cancelEdit}
                onDelete={onDelete}
                onToggleEnabled={onToggleEnabled}
                onHandleEditKeyDown={handleEditKeyDown}
                onSaveEdit={saveEdit}
                onSetEditComment={setEditComment}
                onSetEditValue={setEditValue}
                onStartEdit={startEdit}
                onToggleSelection={onToggleSelection}
                readOnly={readOnly}
                rule={rule}
              />
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
};

export default RulesTable;
