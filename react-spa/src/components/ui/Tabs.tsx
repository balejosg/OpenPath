import React from 'react';
import { cn } from '../../lib/utils';

export interface TabItem {
  id: string;
  label: string;
  count?: number;
  icon?: React.ReactNode;
}

interface TabsProps {
  tabs: TabItem[];
  activeTab: string;
  onChange: (id: string) => void;
  className?: string;
}

/**
 * Tabs - A horizontal tab navigation component.
 *
 * Usage:
 * ```tsx
 * <Tabs
 *   tabs={[
 *     { id: 'allowed', label: 'Permitidos', count: 12, icon: <Check /> },
 *     { id: 'blocked', label: 'Bloqueados', count: 45, icon: <Ban /> },
 *     { id: 'all', label: 'Todos', count: 57 },
 *   ]}
 *   activeTab="allowed"
 *   onChange={(id) => setActiveTab(id)}
 * />
 * ```
 */
export const Tabs: React.FC<TabsProps> = ({ tabs, activeTab, onChange, className }) => {
  return (
    <div
      className={cn('border-b border-slate-200', className)}
      role="tablist"
      aria-label="Navigation tabs"
    >
      <div className="flex gap-1">
        {tabs.map((tab) => {
          const isActive = tab.id === activeTab;

          return (
            <button
              key={tab.id}
              onClick={() => onChange(tab.id)}
              className={cn(
                'relative inline-flex items-center gap-2 px-4 py-2.5 text-sm font-medium transition-colors',
                'focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-1 rounded-t-lg',
                isActive
                  ? 'text-blue-600 bg-white border-t border-l border-r border-slate-200 -mb-px'
                  : 'text-slate-500 hover:text-slate-700 hover:bg-slate-50'
              )}
              role="tab"
              aria-selected={isActive}
              aria-controls={`tabpanel-${tab.id}`}
              type="button"
            >
              {tab.icon && <span className="flex-shrink-0">{tab.icon}</span>}
              <span>{tab.label}</span>
              {tab.count !== undefined && (
                <span
                  className={cn(
                    'px-2 py-0.5 text-xs rounded-full min-w-[1.5rem] text-center',
                    isActive ? 'bg-blue-100 text-blue-700' : 'bg-slate-100 text-slate-600'
                  )}
                >
                  {tab.count}
                </span>
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
};

export default Tabs;
