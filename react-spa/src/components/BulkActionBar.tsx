import React from 'react';
import { Trash2, X } from 'lucide-react';
import { Button } from './ui/Button';
import { cn } from '../lib/utils';
import { useT } from '../i18n/product-i18n';

interface BulkActionBarProps {
  selectedCount: number;
  onDelete: () => void;
  onClear: () => void;
  onDisable?: () => void;
  onEnable?: () => void;
  isDeleting?: boolean;
  className?: string;
}

/**
 * BulkActionBar - Floating action bar for bulk operations on selected items.
 */
export const BulkActionBar: React.FC<BulkActionBarProps> = ({
  selectedCount,
  onDelete,
  onClear,
  onDisable,
  onEnable,
  isDeleting = false,
  className,
}) => {
  const t = useT();

  if (selectedCount === 0) return null;

  return (
    <div
      className={cn(
        'fixed bottom-6 left-1/2 -translate-x-1/2 z-50',
        'bg-slate-900 text-white rounded-lg shadow-2xl',
        'flex items-center gap-4 px-4 py-3',
        'animate-in slide-in-from-bottom-4 fade-in duration-200',
        className
      )}
    >
      {/* Selection count */}
      <span className="text-sm font-medium whitespace-nowrap">
        {t('bulkActionBar.selectedCount', { count: String(selectedCount) })}
      </span>

      {/* Divider */}
      <div className="w-px h-6 bg-slate-700" />

      {/* Actions */}
      <div className="flex items-center gap-2">
        {onDisable && (
          <Button
            onClick={onDisable}
            disabled={isDeleting}
            size="sm"
            className="bg-slate-600 hover:bg-slate-700 text-white border-0"
          >
            {t('rulesActions.bulkDisableButton')}
          </Button>
        )}

        {onEnable && (
          <Button
            onClick={onEnable}
            disabled={isDeleting}
            size="sm"
            className="bg-slate-600 hover:bg-slate-700 text-white border-0"
          >
            {t('rulesActions.bulkEnableButton')}
          </Button>
        )}

        <Button
          onClick={onDelete}
          disabled={isDeleting}
          isLoading={isDeleting}
          size="sm"
          className="bg-red-600 hover:bg-red-700 text-white border-0"
        >
          <Trash2 size={14} className="mr-1" />
          {t('common.delete')}
        </Button>

        <button
          onClick={onClear}
          disabled={isDeleting}
          className="p-2 text-slate-400 hover:text-white hover:bg-slate-800 rounded transition-colors disabled:opacity-50"
          title={t('bulkActionBar.cancelSelection')}
        >
          <X size={16} />
        </button>
      </div>
    </div>
  );
};

export default BulkActionBar;
