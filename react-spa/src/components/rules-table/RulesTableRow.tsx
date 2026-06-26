import React from 'react';
import {
  Ban,
  Check,
  CheckSquare,
  Edit2,
  Loader2,
  Route,
  Save,
  Square,
  Trash2,
  X,
} from 'lucide-react';
import { cn } from '../../lib/utils';
import { getRuleTypeBadge } from '../../lib/ruleDetection';
import type { Rule, RuleType } from '../../lib/rules';
import { useT } from '../../i18n/product-i18n';

interface RulesTableRowProps {
  rule: Rule;
  isEditing: boolean;
  isSaving: boolean;
  isSelected: boolean;
  hasSelectionFeature: boolean;
  readOnly: boolean;
  editValue: string;
  editComment: string;
  onToggleSelection?: (id: string) => void;
  onStartEdit: (rule: Rule) => void;
  onSaveEdit: () => Promise<void>;
  onCancelEdit: () => void;
  onDelete: (rule: Rule) => void;
  onSetEditValue: (value: string) => void;
  onSetEditComment: (value: string) => void;
  onHandleEditKeyDown: (event: React.KeyboardEvent<HTMLInputElement>) => void;
  canEdit: boolean;
  hasOnSave: boolean;
  formatDate: (dateString: string) => string;
}

function getTypeIcon(type: RuleType) {
  switch (type) {
    case 'whitelist':
      return <Check size={12} className="text-green-600" />;
    case 'blocked_subdomain':
      return <Ban size={12} className="text-red-600" />;
    case 'blocked_path':
      return <Route size={12} className="text-red-600" />;
  }
}

function getTypeBadgeClass(type: RuleType) {
  return type === 'whitelist'
    ? 'bg-green-100 text-green-700 border-green-200'
    : 'bg-red-100 text-red-700 border-red-200';
}

export const RulesTableRow: React.FC<RulesTableRowProps> = ({
  canEdit,
  editComment,
  editValue,
  formatDate,
  hasOnSave,
  hasSelectionFeature,
  isEditing,
  isSaving,
  isSelected,
  onCancelEdit,
  onDelete,
  onHandleEditKeyDown,
  onSaveEdit,
  onSetEditComment,
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
        'hover:bg-slate-50 transition-colors group',
        isSelected && 'bg-blue-50 hover:bg-blue-100',
        isEditing && 'bg-amber-50 hover:bg-amber-50'
      )}
    >
      {hasSelectionFeature && (
        <td className="px-4 py-3">
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
      <td className="px-4 py-3">
        {isEditing ? (
          <input
            type="text"
            value={editValue}
            onChange={(e) => onSetEditValue(e.target.value)}
            onKeyDown={onHandleEditKeyDown}
            className="w-full px-2 py-1 text-sm font-mono border border-amber-300 rounded focus:ring-2 focus:ring-amber-500 focus:border-amber-500 outline-none bg-white"
            autoFocus
            data-testid="edit-value-input"
          />
        ) : (
          <span
            className={cn(
              'text-sm text-slate-800 font-mono break-all',
              hasOnSave && 'cursor-pointer hover:text-blue-600'
            )}
            onClick={() => hasOnSave && onStartEdit(rule)}
            onDoubleClick={() => hasOnSave && onStartEdit(rule)}
            title={hasOnSave ? t('rules.row.clickToEdit') : undefined}
          >
            {rule.value}
          </span>
        )}
      </td>
      <td className="px-4 py-3">
        <div className="flex items-center gap-1.5 flex-wrap">
          <span
            className={cn(
              'inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full border font-medium',
              getTypeBadgeClass(rule.type)
            )}
          >
            {getTypeIcon(rule.type)}
            {getRuleTypeBadge(rule.type)}
          </span>
          {rule.source === 'auto_extension' && (
            <span className="inline-flex items-center px-2 py-0.5 text-xs rounded-full border font-medium bg-cyan-50 text-cyan-700 border-cyan-200">
              {t('rules.row.autoFirefox')}
            </span>
          )}
        </div>
      </td>
      <td className="px-4 py-3 hidden md:table-cell">
        {isEditing ? (
          <input
            type="text"
            value={editComment}
            onChange={(e) => onSetEditComment(e.target.value)}
            onKeyDown={onHandleEditKeyDown}
            placeholder={t('rules.row.commentPlaceholder')}
            className="w-full px-2 py-1 text-sm border border-amber-300 rounded focus:ring-2 focus:ring-amber-500 focus:border-amber-500 outline-none bg-white"
            data-testid="edit-comment-input"
          />
        ) : (
          <span
            className={cn(
              'text-sm text-slate-500 truncate max-w-xs block',
              hasOnSave && 'cursor-pointer hover:text-blue-600'
            )}
            onClick={() => hasOnSave && onStartEdit(rule)}
            onDoubleClick={() => hasOnSave && onStartEdit(rule)}
            title={hasOnSave ? t('rules.row.clickToEdit') : undefined}
          >
            {rule.comment ?? '-'}
          </span>
        )}
      </td>
      <td className="px-4 py-3 hidden sm:table-cell">
        <span className="text-xs text-slate-400">{formatDate(rule.createdAt)}</span>
      </td>
      {!readOnly && (
        <td className="px-4 py-3">
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
                  onClick={() => onStartEdit(rule)}
                  className="p-1.5 text-slate-400 hover:text-blue-600 hover:bg-blue-50 rounded transition-colors"
                  title={t('common.edit')}
                  data-testid="edit-button"
                >
                  <Edit2 size={14} />
                </button>
              )}
              <button
                onClick={() => onDelete(rule)}
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
