import React from 'react';
import { DAYS } from './shared';
import { useT } from '../../i18n/product-i18n';

interface WeeklyCalendarHeaderProps {
  weekMonthLabel: string;
  weekDates: number[];
  todayKey: number | null;
}

const DAY_FULL_KEYS = {
  1: 'teacher.day.monday',
  2: 'teacher.day.tuesday',
  3: 'teacher.day.wednesday',
  4: 'teacher.day.thursday',
  5: 'teacher.day.friday',
} as const;

const DAY_SHORT_KEYS = {
  1: 'calendar.day.monday.short',
  2: 'calendar.day.tuesday.short',
  3: 'calendar.day.wednesday.short',
  4: 'calendar.day.thursday.short',
  5: 'calendar.day.friday.short',
} as const;

export const WeeklyCalendarHeader: React.FC<WeeklyCalendarHeaderProps> = ({
  weekMonthLabel,
  weekDates,
  todayKey,
}) => {
  const t = useT();
  return (
    <>
      <div className="px-4 py-2 bg-slate-50 border-b border-slate-200 text-xs font-semibold text-slate-500 uppercase tracking-wider">
        {weekMonthLabel}
      </div>
      <div className="grid grid-cols-[60px_repeat(5,1fr)] border-b border-slate-200 bg-slate-50">
        <div className="p-2 text-xs font-semibold text-slate-400 text-center flex items-center justify-center">
          {t('calendar.header.time')}
        </div>
        {DAYS.map((d, i) => {
          const isToday = todayKey === d.key;
          return (
            <div
              key={d.key}
              className={`p-2 text-center border-l border-slate-200 flex flex-col items-center justify-center gap-0.5 ${isToday ? 'bg-blue-50' : ''}`}
            >
              <span
                className={`text-xs font-semibold uppercase tracking-wider ${isToday ? 'text-blue-600' : 'text-slate-500'}`}
              >
                <span className="hidden md:inline">{t(DAY_FULL_KEYS[d.key])}</span>
                <span className="inline md:hidden">{t(DAY_SHORT_KEYS[d.key])}</span>
              </span>
              <span
                className={`text-lg font-bold leading-tight ${isToday ? 'text-white bg-blue-600 w-8 h-8 rounded-full flex items-center justify-center' : 'text-slate-800'}`}
              >
                {weekDates[i]}
              </span>
            </div>
          );
        })}
      </div>
    </>
  );
};
