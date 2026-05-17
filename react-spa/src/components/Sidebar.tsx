import React from 'react';
import {
  LayoutDashboard,
  Users,
  MonitorPlay,
  FolderTree,
  ShieldAlert,
  LogOut,
  Settings,
  Shield,
} from 'lucide-react';
import { NavItem } from '../types';
import { logout, isAdmin } from '../lib/auth';
import { useT } from '../i18n/product-i18n';

interface SidebarProps {
  activeTab: string;
  setActiveTab: (tab: string) => void;
  isOpen: boolean;
  allowDomainRequestsForNonAdmins?: boolean;
}

const Sidebar: React.FC<SidebarProps> = ({
  activeTab,
  setActiveTab,
  isOpen,
  allowDomainRequestsForNonAdmins = false,
}) => {
  const normalizedActiveTab = activeTab === 'rules' ? 'groups' : activeTab;
  const admin = isAdmin();
  const showDomainRequests = admin || allowDomainRequestsForNonAdmins;
  const t = useT();

  const navItems: NavItem[] = [
    {
      id: 'dashboard',
      label: admin ? t('sidebar.nav.dashboard.admin') : t('sidebar.nav.dashboard.user'),
      icon: <LayoutDashboard size={20} />,
    },
    {
      id: 'classrooms',
      label: admin ? t('sidebar.nav.classrooms.admin') : t('sidebar.nav.classrooms.user'),
      icon: <MonitorPlay size={20} />,
    },
    {
      id: 'groups',
      label: admin ? t('sidebar.nav.groups.admin') : t('sidebar.nav.groups.user'),
      icon: <FolderTree size={20} />,
    },
    ...(admin ? [{ id: 'users', label: t('sidebar.nav.users'), icon: <Users size={20} /> }] : []),
    ...(showDomainRequests
      ? [{ id: 'domains', label: t('sidebar.nav.domainRequests'), icon: <ShieldAlert size={20} /> }]
      : []),
  ];

  return (
    <aside
      className={`fixed top-0 left-0 z-40 h-screen transition-transform duration-300 ease-out ${
        isOpen ? 'translate-x-0' : '-translate-x-full'
      } md:translate-x-0 w-64 bg-slate-900 text-white flex flex-col border-r border-slate-800 shadow-xl`}
    >
      {/* Branding */}
      <div className="h-16 flex items-center px-6 bg-slate-950 border-b border-slate-800">
        <div className="flex items-center gap-3">
          <Shield className="text-blue-500" size={24} strokeWidth={2.5} />
          <span className="text-lg font-semibold tracking-wide text-slate-100">OpenPath</span>
        </div>
      </div>

      {/* Navigation */}
      <div className="flex-1 py-6 px-3 space-y-1 overflow-y-auto">
        <div className="px-3 mb-2 text-xs font-semibold text-slate-500 uppercase tracking-wider">
          {t('sidebar.section.mainMenu')}
        </div>
        {navItems.map((item) => (
          <button
            key={item.id}
            onClick={() => setActiveTab(item.id)}
            aria-current={normalizedActiveTab === item.id ? 'page' : undefined}
            className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-lg transition-all duration-200 group ${
              normalizedActiveTab === item.id
                ? 'bg-blue-600 text-white shadow-md shadow-blue-900/20'
                : 'text-slate-400 hover:bg-slate-800 hover:text-slate-200'
            }`}
          >
            <span
              className={
                normalizedActiveTab === item.id
                  ? 'text-white'
                  : 'text-slate-400 group-hover:text-slate-200'
              }
            >
              {item.icon}
            </span>
            <span className="font-medium text-sm">{item.label}</span>
          </button>
        ))}
      </div>

      {/* User Profile / Bottom */}
      <div className="p-4 bg-slate-950 border-t border-slate-800">
        <button
          onClick={() => setActiveTab('settings')}
          aria-current={normalizedActiveTab === 'settings' ? 'page' : undefined}
          className={`flex items-center gap-3 px-3 py-2 w-full transition-colors rounded-lg mb-1 ${
            normalizedActiveTab === 'settings'
              ? 'text-white bg-slate-800'
              : 'text-slate-400 hover:text-white hover:bg-slate-800'
          }`}
        >
          <Settings size={18} />
          <span className="text-sm">{t('sidebar.nav.settings')}</span>
        </button>
        <button
          onClick={() => {
            logout();
          }}
          className="flex items-center gap-3 px-3 py-2 w-full text-red-400 hover:text-red-300 transition-colors rounded-lg hover:bg-red-950/30"
        >
          <LogOut size={18} />
          <span className="text-sm">{t('sidebar.nav.logout')}</span>
        </button>
      </div>
    </aside>
  );
};

export default Sidebar;
