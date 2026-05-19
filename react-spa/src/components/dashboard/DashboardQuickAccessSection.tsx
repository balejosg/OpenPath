import { Folder, CheckCircle, Ban, ArrowRight, ChevronDown, Loader2 } from 'lucide-react';
import {
  DASHBOARD_SORT_OPTIONS,
  type DashboardGroup,
  type DashboardSortOption,
} from '../../hooks/useDashboardViewModel';
import { useT } from '../../i18n/product-i18n';

interface DashboardQuickAccessSectionProps {
  groups: DashboardGroup[];
  groupsLoading: boolean;
  groupsError: string | null;
  sortedGroups: DashboardGroup[];
  sortBy: DashboardSortOption;
  showSortDropdown: boolean;
  setSortBy: (value: DashboardSortOption) => void;
  setShowSortDropdown: (value: boolean) => void;
  hasMoreGroups: boolean;
  onNavigateToRules: (group: { id: string; name: string }) => void;
}

export function DashboardQuickAccessSection({
  groups,
  groupsLoading,
  groupsError,
  sortedGroups,
  sortBy,
  showSortDropdown,
  setSortBy,
  setShowSortDropdown,
  hasMoreGroups,
  onNavigateToRules,
}: DashboardQuickAccessSectionProps) {
  const t = useT();
  const sortLabel = DASHBOARD_SORT_OPTIONS.find((option) => option.value === sortBy)?.label ?? '';

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="text-lg font-semibold text-slate-800">{t('dashboard.quickAccess.title')}</h3>
        <div className="relative">
          <button
            onClick={(e) => {
              e.stopPropagation();
              setShowSortDropdown(!showSortDropdown);
            }}
            className="flex items-center gap-2 px-3 py-1.5 text-sm text-slate-600 hover:text-slate-800 hover:bg-slate-100 rounded-lg transition-colors"
            data-testid="sort-dropdown-button"
          >
            {t('dashboard.quickAccess.sort', { label: sortLabel })}
            <ChevronDown size={14} />
          </button>
          {showSortDropdown && (
            <div
              className="absolute right-0 top-full mt-1 bg-white border border-slate-200 rounded-lg shadow-lg py-1 z-10 min-w-[150px]"
              data-testid="sort-dropdown-menu"
            >
              {DASHBOARD_SORT_OPTIONS.map((option) => (
                <button
                  key={option.value}
                  onClick={(e) => {
                    e.stopPropagation();
                    setSortBy(option.value);
                    setShowSortDropdown(false);
                  }}
                  className={`w-full text-left px-3 py-2 text-sm hover:bg-slate-50 transition-colors ${
                    sortBy === option.value ? 'text-blue-600 font-medium' : 'text-slate-600'
                  }`}
                  data-testid={`sort-option-${option.value}`}
                >
                  {option.label}
                </button>
              ))}
            </div>
          )}
        </div>
      </div>

      {groupsLoading ? (
        <div className="flex items-center justify-center py-8">
          <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
          <span className="ml-2 text-slate-500">{t('dashboard.quickAccess.loadingGroups')}</span>
        </div>
      ) : groupsError ? (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-red-700 text-sm">
          {groupsError}
        </div>
      ) : groups.length === 0 ? (
        <div className="bg-slate-50 border border-slate-200 rounded-lg p-8 text-center">
          <Folder className="w-10 h-10 text-slate-300 mx-auto mb-3" />
          <p className="text-slate-500 text-sm">{t('dashboard.quickAccess.noGroups')}</p>
          <p className="text-slate-400 text-xs mt-1">{t('dashboard.quickAccess.noGroupsHint')}</p>
        </div>
      ) : (
        <>
          <div
            className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
            data-testid="quick-access-grid"
          >
            {sortedGroups.map((group) => {
              const blockedCount = group.blockedSubdomainCount + group.blockedPathCount;
              const isInactive = !group.enabled;

              return (
                <div
                  key={group.id}
                  className={`border rounded-lg p-4 transition-all ${
                    isInactive
                      ? 'bg-slate-50 opacity-60 border-slate-200'
                      : 'bg-white hover:border-blue-300 hover:shadow-md border-slate-200'
                  }`}
                  data-testid={`group-card-${group.id}`}
                >
                  <div className="flex items-start justify-between mb-3">
                    <div className="flex items-center gap-2">
                      <div
                        className={`p-2 rounded-lg ${
                          isInactive ? 'bg-slate-100 text-slate-400' : 'bg-blue-50 text-blue-600'
                        }`}
                      >
                        <Folder size={16} />
                      </div>
                      <div>
                        <h4 className="font-medium text-slate-900 text-sm">{group.displayName}</h4>
                        <p className="text-xs text-slate-400">{group.name}</p>
                      </div>
                    </div>
                    <span
                      className={`text-xs px-2 py-0.5 rounded-full font-medium ${
                        isInactive
                          ? 'bg-slate-100 text-slate-500 border border-slate-200'
                          : 'bg-green-50 text-green-700 border border-green-200'
                      }`}
                    >
                      {isInactive ? t('common.status.inactive') : t('common.status.active')}
                    </span>
                  </div>

                  <div className="flex items-center gap-4 mb-4 text-sm">
                    <span className="flex items-center gap-1 text-emerald-600">
                      <CheckCircle size={14} />
                      {group.whitelistCount}
                    </span>
                    <span className="flex items-center gap-1 text-slate-500">
                      <Ban size={14} />
                      {blockedCount}
                    </span>
                  </div>

                  <button
                    onClick={() => onNavigateToRules({ id: group.id, name: group.displayName })}
                    className={`w-full flex items-center justify-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors ${
                      isInactive
                        ? 'bg-slate-200 text-slate-500 hover:bg-slate-300'
                        : 'bg-blue-600 text-white hover:bg-blue-700'
                    }`}
                    data-testid={`manage-rules-${group.id}`}
                  >
                    {t('dashboard.quickAccess.manageRules')}
                    <ArrowRight size={14} />
                  </button>
                </div>
              );
            })}
          </div>

          {hasMoreGroups && (
            <div className="text-center pt-2">
              <p className="text-sm text-slate-500">
                {t('dashboard.quickAccess.moreGroups', {
                  visibleCount: sortedGroups.length,
                  totalCount: groups.length,
                })}{' '}
                <span className="text-slate-400">{t('dashboard.quickAccess.moreGroupsHint')}</span>
              </p>
            </div>
          )}
        </>
      )}
    </div>
  );
}
