import React from 'react';
import { cn } from '../../lib/utils';

export interface FilterOption {
  id: string;
  label: string;
  count: number;
  icon?: React.ReactNode;
}

interface FilterChipsProps {
  options: FilterOption[];
  activeId: string;
  onChange: (id: string) => void;
  className?: string;
}

/**
 * FilterChips - A row of toggleable filter chips for filtering content.
 *
 * Usage:
 * ```tsx
 * <FilterChips
 *   options={[
 *     { id: 'all', label: 'Todos', count: 10 },
 *     { id: 'allowed', label: 'Permitidos', count: 5, icon: <Check /> },
 *     { id: 'blocked', label: 'Bloqueados', count: 5, icon: <Ban /> },
 *   ]}
 *   activeId="all"
 *   onChange={(id) => setFilter(id)}
 * />
 * ```
 */
export const FilterChips: React.FC<FilterChipsProps> = ({
  options,
  activeId,
  onChange,
  className,
}) => {
  return (
    <div
      className={cn('flex items-center gap-2 flex-wrap', className)}
      role="group"
      aria-label="Filters"
    >
      {options.map((option) => {
        const isActive = option.id === activeId;

        return (
          <button
            key={option.id}
            onClick={() => onChange(option.id)}
            className={cn(
              'inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm font-medium transition-colors',
              'focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-1',
              isActive
                ? 'bg-blue-100 text-blue-700 border border-blue-200'
                : 'bg-slate-100 text-slate-600 border border-slate-200 hover:bg-slate-200'
            )}
            aria-pressed={isActive}
            type="button"
          >
            {option.icon && <span className="flex-shrink-0">{option.icon}</span>}
            <span>{option.label}</span>
            <span
              className={cn(
                'px-1.5 py-0.5 text-xs rounded-full min-w-[1.25rem] text-center',
                isActive ? 'bg-blue-200 text-blue-800' : 'bg-slate-200 text-slate-700'
              )}
            >
              {option.count}
            </span>
          </button>
        );
      })}
    </div>
  );
};

export default FilterChips;
