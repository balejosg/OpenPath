import React from 'react';
import { DAYS } from './shared';

interface WeeklyCalendarHeaderProps {
  weekMonthLabel: string;
  weekDates: number[];
  todayKey: number | null;
}

export const WeeklyCalendarHeader: React.FC<WeeklyCalendarHeaderProps> = ({
  weekMonthLabel,
  weekDates,
  todayKey,
}) => (
  <>
    <div className="px-4 py-2 bg-slate-50 border-b border-slate-200 text-xs font-semibold text-slate-500 uppercase tracking-wider">
      {weekMonthLabel}
    </div>
    <div className="grid grid-cols-[60px_repeat(5,1fr)] border-b border-slate-200 bg-slate-50">
      <div className="p-2 text-xs font-semibold text-slate-400 text-center flex items-center justify-center">
        Time
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
              <span className="hidden md:inline">{d.full}</span>
              <span className="inline md:hidden">{d.short}</span>
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
