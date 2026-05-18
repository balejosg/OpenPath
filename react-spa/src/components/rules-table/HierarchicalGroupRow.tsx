import React from 'react';
import {
  CheckSquare,
  ChevronDown,
  ChevronRight,
  Globe,
  Minus,
  Plus,
  Route,
  Square,
} from 'lucide-react';
import { cn } from '../../lib/utils';
import type { DomainGroup } from '../HierarchicalRulesTable';
import { useT } from '../../i18n/product-i18n';

interface HierarchicalGroupRowProps {
  group: DomainGroup;
  isExpanded: boolean;
  hasSelectionFeature: boolean;
  allGroupSelected: boolean;
  someGroupSelected: boolean;
  readOnly: boolean;
  selectedIds?: Set<string>;
  onToggleGroup: (rootDomain: string) => void;
  onToggleSelection?: (id: string) => void;
  onAddSubdomain?: (rootDomain: string) => void;
}

export const HierarchicalGroupRow: React.FC<HierarchicalGroupRowProps> = ({
  allGroupSelected,
  group,
  hasSelectionFeature,
  isExpanded,
  onAddSubdomain,
  onToggleGroup,
  onToggleSelection,
  readOnly,
  selectedIds,
  someGroupSelected,
}) => {
  const t = useT();
  const groupRuleIds = group.rules.map((rule) => rule.id);

  return (
    <tr
      className={cn(
        'bg-slate-50/50 hover:bg-slate-100 transition-colors cursor-pointer',
        isExpanded && 'bg-slate-100'
      )}
      onClick={() => onToggleGroup(group.root)}
    >
      {hasSelectionFeature && (
        <td className="px-4 py-3">
          <button
            onClick={(e) => {
              e.stopPropagation();
              groupRuleIds.forEach((id) => {
                if (allGroupSelected) {
                  if (selectedIds?.has(id)) onToggleSelection?.(id);
                } else {
                  if (!selectedIds?.has(id)) onToggleSelection?.(id);
                }
              });
            }}
            className="p-1 text-slate-400 hover:text-slate-600 transition-colors"
            title={allGroupSelected ? t('rules.group.deselectGroup') : t('rules.group.selectGroup')}
          >
            {allGroupSelected ? (
              <CheckSquare size={18} className="text-blue-600" />
            ) : someGroupSelected ? (
              <Minus size={18} className="text-blue-400" />
            ) : (
              <Square size={18} />
            )}
          </button>
        </td>
      )}
      <td className="px-4 py-3 text-slate-400">
        {isExpanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
      </td>
      <td className="px-4 py-3">
        <div className="flex items-center gap-2">
          {group.root ? (
            <Globe size={16} className="text-slate-400 flex-shrink-0" />
          ) : (
            <Route size={16} className="text-slate-400 flex-shrink-0" />
          )}
          <span
            className={cn('font-medium', group.root ? 'text-slate-700' : 'text-slate-500 italic')}
          >
            {group.root || t('rules.group.globalPaths')}
          </span>
          <span className="text-xs text-slate-400 font-normal">({group.rules.length})</span>
        </div>
      </td>
      <td className="px-4 py-3">
        <span
          className={cn(
            'text-xs px-2 py-0.5 rounded-full border font-medium',
            group.status === 'allowed' && 'bg-green-100 text-green-700 border-green-200',
            group.status === 'blocked' && 'bg-red-100 text-red-700 border-red-200',
            group.status === 'mixed' && 'bg-amber-100 text-amber-700 border-amber-200'
          )}
        >
          {group.status === 'allowed'
            ? t('rules.group.status.allowed')
            : group.status === 'blocked'
              ? t('rules.group.status.blocked')
              : t('rules.group.status.mixed')}
        </span>
      </td>
      {!readOnly && (
        <td className="px-4 py-3 text-right">
          {onAddSubdomain && group.root && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                onAddSubdomain(group.root);
              }}
              className="p-1.5 hover:bg-slate-200 rounded text-slate-500 hover:text-slate-700 transition-colors"
              title={t('rules.group.addSubdomain', { rootDomain: group.root })}
            >
              <Plus size={16} />
            </button>
          )}
        </td>
      )}
    </tr>
  );
};
