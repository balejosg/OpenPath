import React from 'react';
import { CheckSquare, Edit2, Loader2, Save, Square, Trash2, X } from 'lucide-react';
import { cn } from '../../lib/utils';
import { getRuleTypeBadge } from '../../lib/ruleDetection';
import type { Rule } from '../../lib/rules';
import { useT } from '../../i18n/product-i18n';

interface HierarchicalRuleRowProps {
  rule: Rule;
  isEditing: boolean;
  isSaving: boolean;
  isSelected: boolean;
  hasSelectionFeature: boolean;
  canEdit: boolean;
  readOnly: boolean;
  editValue: string;
  onToggleSelection?: (id: string) => void;
  onStartEdit: (rule: Rule) => void;
  onSaveEdit: () => Promise<void>;
  onCancelEdit: () => void;
  onDelete: (rule: Rule) => void;
  onSetEditValue: (value: string) => void;
  onHandleEditKeyDown: (event: React.KeyboardEvent<HTMLInputElement>) => void;
}

export const HierarchicalRuleRow: React.FC<HierarchicalRuleRowProps> = ({
  canEdit,
  editValue,
  hasSelectionFeature,
  isEditing,
  isSaving,
  isSelected,
  onCancelEdit,
  onDelete,
  onHandleEditKeyDown,
  onSaveEdit,
  onSetEditValue,
  onStartEdit,
  onToggleSelection,
  readOnly,
  rule,
}) => {
  const t = useT();
  return (
    <tr
      className={cn(
        'bg-white hover:bg-slate-50 transition-colors group',
        isSelected && 'bg-blue-50 hover:bg-blue-100',
        isEditing && 'bg-amber-50 hover:bg-amber-50'
      )}
    >
      {hasSelectionFeature && (
        <td className="px-4 py-2">
          <button
            onClick={() => onToggleSelection?.(rule.id)}
            className="p-1 text-slate-400 hover:text-slate-600 transition-colors"
            title={isSelected ? t('common.deselect') : t('common.select')}
            disabled={isEditing}
          >
            {isSelected ? (
              <CheckSquare size={18} className="text-blue-600" />
            ) : (
              <Square size={18} />
            )}
          </button>
        </td>
      )}
      <td className="px-4 py-2"></td>
      <td className="px-4 py-2 pl-12">
        <div className="flex items-center gap-2">
          <span className="text-slate-300">↳</span>
          {isEditing ? (
            <input
              type="text"
              value={editValue}
              onChange={(e) => onSetEditValue(e.target.value)}
              onKeyDown={onHandleEditKeyDown}
              className="flex-1 px-2 py-1 text-sm font-mono border border-amber-300 rounded focus:ring-2 focus:ring-amber-500 focus:border-amber-500 outline-none bg-white"
              autoFocus
              data-testid="edit-value-input"
            />
          ) : (
            <span
              className={cn(
                'text-sm font-mono text-slate-600 break-all',
                canEdit && 'cursor-pointer hover:text-blue-600'
              )}
              onClick={(e) => {
                e.stopPropagation();
                if (canEdit) onStartEdit(rule);
              }}
              title={canEdit ? t('rules.row.clickToEdit') : undefined}
            >
              {rule.value}
            </span>
          )}
        </div>
      </td>
      <td className="px-4 py-2">
        <div className="flex items-center gap-1.5 flex-wrap">
          <span className="text-xs px-2 py-0.5 rounded bg-slate-100 text-slate-600 border border-slate-200">
            {getRuleTypeBadge(rule.type)}
          </span>
          {rule.source === 'auto_extension' && (
            <span className="text-xs px-2 py-0.5 rounded bg-cyan-50 text-cyan-700 border border-cyan-200">
              {t('rules.row.autoFirefox')}
            </span>
          )}
        </div>
      </td>
      {!readOnly && (
        <td className="px-4 py-2 text-right">
          {isEditing ? (
            <div className="flex items-center justify-end gap-1">
              <button
                onClick={() => void onSaveEdit()}
                disabled={isSaving || !editValue.trim()}
                className="p-1.5 text-green-600 hover:text-green-700 hover:bg-green-50 rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                title={t('rules.row.saveHint')}
                data-testid="save-edit-button"
              >
                {isSaving ? <Loader2 size={14} className="animate-spin" /> : <Save size={14} />}
              </button>
              <button
                onClick={onCancelEdit}
                disabled={isSaving}
                className="p-1.5 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded transition-colors disabled:opacity-50"
                title={t('rules.row.cancelHint')}
                data-testid="cancel-edit-button"
              >
                <X size={14} />
              </button>
            </div>
          ) : (
            <div className="flex items-center justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
              {canEdit && (
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    onStartEdit(rule);
                  }}
                  className="p-1.5 text-slate-400 hover:text-blue-600 hover:bg-blue-50 rounded transition-colors"
                  title={t('common.edit')}
                  data-testid="edit-button"
                >
                  <Edit2 size={14} />
                </button>
              )}
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  onDelete(rule);
                }}
                className="p-1.5 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded transition-colors"
                title={
                  rule.type === 'whitelist' && rule.source === 'auto_extension'
                    ? t('rules.row.revokeAutoApproval')
                    : t('common.delete')
                }
              >
                <Trash2 size={14} />
              </button>
            </div>
          )}
        </td>
      )}
    </tr>
  );
};
