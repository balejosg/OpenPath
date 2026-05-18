import { ChevronLeft, ChevronRight } from 'lucide-react';
import type { ViewMode } from '../../hooks/useRulesManagerViewModel';

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
  if (loading || error || totalPages <= 1) {
    return null;
  }

  return (
    <div className="flex items-center justify-between border-t border-slate-200 pt-4">
      <p className="text-sm text-slate-500">
        {viewMode === 'hierarchical' ? (
          <>
            Showing {visibleGroups} of {totalGroups} groups ({total} rules)
          </>
        ) : (
          <>
            Showing {(page - 1) * 50 + 1}-{Math.min(page * 50, total)} of {total} rules
          </>
        )}
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
          Page {page} of {totalPages}
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
