import type React from 'react';
import { Filter, Search } from 'lucide-react';

import { useT } from '../../i18n/product-i18n';

export interface UsersToolbarProps {
  exportMessage: string | null;
  onExportUsers: () => void;
  onOpenNewUser: () => void;
  searchQuery: string;
  setSearchQuery: (value: string) => void;
}

export function UsersToolbar({
  exportMessage,
  onExportUsers,
  onOpenNewUser,
  searchQuery,
  setSearchQuery,
}: UsersToolbarProps): React.JSX.Element {
  const t = useT();

  return (
    <>
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h2 className="text-xl font-bold text-slate-900">{t('users.toolbar.title')}</h2>
          <p className="text-slate-500 text-sm">{t('users.toolbar.subtitle')}</p>
        </div>
        <button
          onClick={onOpenNewUser}
          className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors shadow-sm"
        >
          {t('users.toolbar.newUser')}
        </button>
      </div>

      <div className="bg-white border border-slate-200 rounded-lg p-4 flex flex-col md:flex-row gap-4 justify-between items-center shadow-sm">
        <div className="relative w-full md:w-96">
          <Search size={18} className="absolute left-3 top-2.5 text-slate-400" />
          <input
            type="text"
            placeholder={t('users.toolbar.searchPlaceholder')}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full bg-slate-50 border border-slate-300 rounded-lg py-2 pl-10 pr-4 text-sm text-slate-900 focus:border-blue-500 focus:bg-white outline-none transition-all"
          />
        </div>
        <div className="flex gap-2 w-full md:w-auto">
          <button
            disabled
            title={t('users.toolbar.filtersComingSoon')}
            className="flex items-center gap-2 px-3 py-2 bg-white border border-slate-300 rounded-lg text-sm text-slate-500 opacity-60 cursor-not-allowed"
          >
            <Filter size={16} /> {t('common.filters')}
          </button>
          <button
            onClick={onExportUsers}
            className="flex items-center gap-2 px-3 py-2 bg-white border border-slate-300 rounded-lg text-sm text-slate-700 hover:bg-slate-50 transition-colors"
          >
            {t('common.export')}
          </button>
        </div>
      </div>

      {exportMessage && (
        <p className="text-sm text-slate-600" role="status">
          {exportMessage}
        </p>
      )}
    </>
  );
}
