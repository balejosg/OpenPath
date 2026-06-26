import React from 'react';
import { Bell, Menu, Search, ShieldCheck, Loader2 } from 'lucide-react';
import { useCurrentUser, getRoleDisplayLabel } from '../hooks/useCurrentUser';
import { useT } from '../i18n/product-i18n';

interface HeaderProps {
  onMenuClick: () => void;
  title: string;
}

const Header: React.FC<HeaderProps> = ({ onMenuClick, title }) => {
  const { user, loading: userLoading } = useCurrentUser();
  const t = useT();

  return (
    <header className="h-16 bg-white border-b border-slate-200 sticky top-0 z-30 px-4 md:px-8 flex items-center justify-between shadow-sm">
      <div className="flex items-center gap-4">
        <button
          onClick={onMenuClick}
          aria-label={t('header.openMenu')}
          className="md:hidden p-2 text-slate-500 hover:text-slate-900 rounded-lg hover:bg-slate-100"
        >
          <Menu size={24} />
        </button>
        <div>
          <h1 className="text-xl font-semibold text-slate-800 tracking-tight">{title}</h1>
        </div>
      </div>

      <div className="flex items-center gap-6">
        {/* Search - Subtle & Functional */}
        <div className="hidden md:flex items-center bg-slate-50 border border-slate-200 rounded-lg px-3 py-1.5 focus-within:ring-2 focus-within:ring-blue-100 focus-within:border-blue-400 transition-all w-64">
          <Search size={16} className="text-slate-400" />
          <input
            type="text"
            placeholder={t('header.search')}
            className="bg-transparent border-none outline-none text-sm text-slate-700 ml-2 w-full placeholder-slate-400"
          />
        </div>

        {/* Security Indicator */}
        <div className="hidden lg:flex items-center gap-2 px-3 py-1 bg-green-50 border border-green-200 rounded-full">
          <ShieldCheck size={14} className="text-green-600" />
          <span className="text-xs font-medium text-green-700">{t('header.secureConnection')}</span>
        </div>

        <div className="h-6 w-[1px] bg-slate-200 hidden sm:block"></div>

        {/* User */}
        <div className="flex items-center gap-4">
          <button
            className="relative text-slate-400 hover:text-blue-600 transition-colors"
            title={t('header.notifications')}
          >
            <Bell size={20} />
            {/* Notification badge - hidden until notifications feature is implemented */}
          </button>

          <div className="flex items-center gap-3">
            {userLoading ? (
              <Loader2 size={20} className="animate-spin text-slate-400" />
            ) : (
              <>
                <div className="w-8 h-8 bg-blue-100 text-blue-700 rounded-full flex items-center justify-center text-sm font-bold border border-blue-200">
                  {user?.initials ?? '??'}
                </div>
                <div className="text-sm hidden md:block">
                  <p className="font-medium text-slate-700 leading-none">
                    {user?.name ?? t('header.userFallback')}
                  </p>
                  <p className="text-xs text-slate-500 mt-0.5">
                    {user?.primaryRole
                      ? getRoleDisplayLabel(user.primaryRole, t)
                      : t('header.noRoleFallback')}
                  </p>
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </header>
  );
};

export default Header;
