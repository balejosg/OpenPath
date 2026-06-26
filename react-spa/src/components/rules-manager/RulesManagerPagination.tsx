import { ChevronLeft, ChevronRight } from 'lucide-react';
import type { ViewMode } from '../../hooks/useRulesManagerViewModel';
import { useT } from '../../i18n/product-i18n';

interface RulesManagerPaginationProps {
  viewMode: ViewMode;
  loading: boolean;
  error: string | null;
  page: number;
  totalPages: number;
  total: number;
  totalGroups: number;
  visibleGroups: number;
  onPageChange: (page: number) => void;
}

export function RulesManagerPagination({
  viewMode,
  loading,
  error,
  page,
  totalPages,
  total,
  totalGroups,
  visibleGroups,
  onPageChange,
}: RulesManagerPaginationProps) {
  const t = useT();
  if (loading || error || totalPages <= 1) {
    return null;
  }

  return (
    <div className="flex items-center justify-between border-t border-slate-200 pt-4">
      <p className="text-sm text-slate-500">
        {viewMode === 'hierarchical'
          ? t('rules.manager.paginationGroups', {
              visibleGroups: String(visibleGroups),
              totalGroups: String(totalGroups),
              total: String(total),
            })
          : t('rules.manager.paginationFlat', {
              start: String((page - 1) * 50 + 1),
              end: String(Math.min(page * 50, total)),
              total: String(total),
            })}
      </p>
      <div className="flex items-center gap-2">
        <button
          onClick={() => onPageChange(page - 1)}
          disabled={page === 1}
          className="p-2 text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <ChevronLeft size={18} />
        </button>
        <span className="text-sm text-slate-600">
          {t('rules.manager.paginationPage', {
            page: String(page),
            totalPages: String(totalPages),
          })}
        </span>
        <button
          onClick={() => onPageChange(page + 1)}
          disabled={page === totalPages}
          className="p-2 text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <ChevronRight size={18} />
        </button>
      </div>
    </div>
  );
}
