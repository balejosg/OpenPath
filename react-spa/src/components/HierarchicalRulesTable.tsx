import React, { useMemo } from 'react';
import { CheckSquare, Loader2, Minus, Square } from 'lucide-react';
import { cn } from '../lib/utils';
import type { Rule } from '../lib/rules';
import { HierarchicalGroupRow } from './rules-table/HierarchicalGroupRow';
import { HierarchicalRuleRow } from './rules-table/HierarchicalRuleRow';
import { useRuleEditor } from '../hooks/useRuleEditor';
import { type DomainGroup } from '../lib/rule-groups';
import { useHierarchicalRulesGroups } from '../hooks/useHierarchicalRulesGroups';

export type { DomainGroup } from '../lib/rule-groups';

interface HierarchicalRulesTableProps {
  /** Individual rules to be grouped client-side (legacy mode) */
  rules?: Rule[];
  /** Pre-grouped domain groups from the backend (preferred mode) */
  domainGroups?: DomainGroup[];
  loading?: boolean;
  readOnly?: boolean;
  onDelete: (rule: Rule) => void;
  onSave?: (id: string, data: { value?: string; comment?: string | null }) => Promise<boolean>;
  onAddSubdomain?: (rootDomain: string) => void;
  emptyMessage?: string;
  className?: string;
  // Selection props
  selectedIds?: Set<string>;
  onToggleSelection?: (id: string) => void;
  onToggleSelectAll?: () => void;
  isAllSelected?: boolean;
  hasSelection?: boolean;
}

// =============================================================================
// Component
// =============================================================================

export const HierarchicalRulesTable: React.FC<HierarchicalRulesTableProps> = ({
  rules,
  domainGroups: preGroupedDomains,
  loading = false,
  readOnly = false,
  onDelete,
  onSave,
  onAddSubdomain,
  emptyMessage = 'No rules configured',
  className,
  selectedIds,
  onToggleSelection,
  onToggleSelectAll,
  isAllSelected,
  hasSelection,
}) => {
  const canEdit = !readOnly && onSave !== undefined;
  const hasSelectionFeature =
    !readOnly &&
    selectedIds !== undefined &&
    onToggleSelection !== undefined &&
    onToggleSelectAll !== undefined;

  const { expandedGroups, groups, toggleGroup } = useHierarchicalRulesGroups(
    rules,
    preGroupedDomains
  );
  const allRules = useMemo(() => groups.flatMap((group) => group.rules), [groups]);
  const {
    cancelEdit,
    editingId,
    editValue,
    handleEditKeyDown,
    isSaving,
    saveEdit,
    setEditValue,
    startEdit,
  } = useRuleEditor({
    onSave,
    resolveRule: (id) => allRules.find((rule) => rule.id === id),
  });

  // Loading state
  if (loading) {
    return (
      <div className={cn('bg-white border border-slate-200 rounded-lg', className)}>
        <div className="flex items-center justify-center py-12 text-slate-400">
          <Loader2 size={20} className="animate-spin mr-2" />
          Loading rules...
        </div>
      </div>
    );
  }

  // Empty state
  if (groups.length === 0) {
    return (
      <div className={cn('bg-white border border-slate-200 rounded-lg', className)}>
        <div className="py-12 text-center text-slate-400 text-sm">{emptyMessage}</div>
      </div>
    );
  }

  return (
    <div className={cn('bg-white border border-slate-200 rounded-lg overflow-hidden', className)}>
      <div className="overflow-x-auto">
        <table className="w-full text-left border-collapse">
          <thead>
            <tr className="bg-slate-50 border-b border-slate-200 text-xs uppercase text-slate-500 font-bold tracking-wider">
              {hasSelectionFeature && (
                <th className="px-4 py-3 w-10">
                  <button
                    onClick={onToggleSelectAll}
                    className="p-1 text-slate-400 hover:text-slate-600 transition-colors"
                    title={isAllSelected ? 'Deselect all' : 'Select all'}
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
              <th className="px-4 py-3 w-8"></th>
              <th className="px-4 py-3">Domain / Rule</th>
              <th className="px-4 py-3 w-32">Estado</th>
              {!readOnly && <th className="px-4 py-3 w-24 text-right">Acciones</th>}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {groups.map((group) => {
              const isExpanded = expandedGroups.has(group.root);
              const groupRuleIds = group.rules.map((r) => r.id);
              const selectedInGroup = groupRuleIds.filter((id) => selectedIds?.has(id)).length;
              const allGroupSelected = selectedInGroup === group.rules.length;
              const someGroupSelected = selectedInGroup > 0 && selectedInGroup < group.rules.length;

              return (
                <React.Fragment key={group.root || '__global_paths__'}>
                  <HierarchicalGroupRow
                    allGroupSelected={allGroupSelected}
                    group={group}
                    hasSelectionFeature={hasSelectionFeature}
                    isExpanded={isExpanded}
                    onAddSubdomain={onAddSubdomain}
                    onToggleGroup={toggleGroup}
                    onToggleSelection={onToggleSelection}
                    readOnly={readOnly}
                    selectedIds={selectedIds}
                    someGroupSelected={someGroupSelected}
                  />
                  {isExpanded &&
                    group.rules.map((rule) => {
                      return (
                        <HierarchicalRuleRow
                          key={rule.id}
                          canEdit={canEdit}
                          editValue={editValue}
                          hasSelectionFeature={hasSelectionFeature}
                          isEditing={editingId === rule.id}
                          isSaving={isSaving}
                          isSelected={selectedIds?.has(rule.id) ?? false}
                          onCancelEdit={cancelEdit}
                          onDelete={onDelete}
                          onHandleEditKeyDown={handleEditKeyDown}
                          onSaveEdit={saveEdit}
                          onSetEditValue={setEditValue}
                          onStartEdit={startEdit}
                          onToggleSelection={onToggleSelection}
                          readOnly={readOnly}
                          rule={rule}
                        />
                      );
                    })}
                </React.Fragment>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
};

export default HierarchicalRulesTable;
