import { ArrowLeft, GitBranch, List } from 'lucide-react';
import { cn } from '../../lib/utils';
import type { ViewMode } from '../../hooks/useRulesManagerViewModel';
import { useT } from '../../i18n/product-i18n';

interface RulesManagerHeaderProps {
  groupName: string;
  viewMode: ViewMode;
  onBack: () => void;
  onViewModeChange: (viewMode: ViewMode) => void;
}

export function RulesManagerHeader({
  groupName,
  viewMode,
  onBack,
  onViewModeChange,
}: RulesManagerHeaderProps) {
  const t = useT();
  return (
    <div className="flex items-center justify-between">
      <div className="flex items-center gap-4">
        <button
          onClick={onBack}
          className="p-2 text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded-lg transition-colors"
          title={t('rules.manager.backToGroups')}
        >
          <ArrowLeft size={20} />
        </button>
        <div>
          <h2 className="text-xl font-bold text-slate-900">{t('rules.manager.title')}</h2>
          <p className="text-slate-500 text-sm">{groupName}</p>
        </div>
      </div>

      <div className="flex items-center gap-1 bg-slate-100 rounded-lg p-1">
        <button
          onClick={() => onViewModeChange('flat')}
          className={cn(
            'flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors',
            viewMode === 'flat'
              ? 'bg-white text-slate-900 shadow-sm'
              : 'text-slate-600 hover:text-slate-900'
          )}
          title={t('rules.manager.flatView')}
        >
          <List size={16} />
          <span className="hidden sm:inline">{t('rules.manager.listLabel')}</span>
        </button>
        <button
          onClick={() => onViewModeChange('hierarchical')}
          className={cn(
            'flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors',
            viewMode === 'hierarchical'
              ? 'bg-white text-slate-900 shadow-sm'
              : 'text-slate-600 hover:text-slate-900'
          )}
          title={t('rules.manager.hierarchicalView')}
        >
          <GitBranch size={16} />
          <span className="hidden sm:inline">{t('rules.manager.treeLabel')}</span>
        </button>
      </div>
    </div>
  );
}
