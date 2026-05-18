import React, { useMemo } from 'react';
import { Loader2 } from 'lucide-react';

import type { TeacherScheduleEntry } from './teacher-schedule-model';
import { getWeekMonday, groupTeacherScheduleEntriesByDay } from './teacher-schedule-model';
import { TeacherCalendarDayColumn } from './TeacherCalendarDayColumn';
import { DAYS, GROUP_COLORS, HOURS, START_HOUR } from '../weekly-calendar/shared';

export interface TeacherDashboardCalendarProps {
  entries: readonly TeacherScheduleEntry[];
  loading: boolean;
  error: string | null;
  weekMonday: Date;
  onPrevWeek: () => void;
  onNextWeek: () => void;
  onToday: () => void;
  onRetry: () => void;
  onSelectEntry: (entry: TeacherScheduleEntry) => void;
}

function isEntryInWeek(entry: TeacherScheduleEntry, weekMonday: Date): boolean {
  const weekStart = getWeekMonday(weekMonday);
  const weekEnd = new Date(weekStart);
  weekEnd.setDate(weekEnd.getDate() + 5);

  return entry.endAt.getTime() > weekStart.getTime() && entry.startAt.getTime() < weekEnd.getTime();
}

function formatWeekLabel(weekMonday: Date): string {
  const weekFriday = new Date(weekMonday);
  weekFriday.setDate(weekFriday.getDate() + 4);

  const formatter = new Intl.DateTimeFormat('es-ES', {
    day: 'numeric',
    month: 'short',
  });

  return `${formatter.format(weekMonday)} - ${formatter.format(weekFriday)}`;
}

export const TeacherDashboardCalendar: React.FC<TeacherDashboardCalendarProps> = ({
  entries,
  loading,
  error,
  weekMonday,
  onPrevWeek,
  onNextWeek,
  onToday,
  onRetry,
  onSelectEntry,
}) => {
  const normalizedWeekMonday = getWeekMonday(weekMonday);
  const visibleEntries = useMemo(
    () => entries.filter((entry) => isEntryInWeek(entry, normalizedWeekMonday)),
    [entries, normalizedWeekMonday]
  );
  const entriesByDay = useMemo(
    () => groupTeacherScheduleEntriesByDay(visibleEntries),
    [visibleEntries]
  );
  const colorMap = useMemo(() => {
    const map = new Map<string, number>();
    let next = 0;

    for (const entry of visibleEntries) {
      if (map.has(entry.colorKey)) continue;
      map.set(entry.colorKey, next % GROUP_COLORS.length);
      next += 1;
    }

    return map;
  }, [visibleEntries]);
  const rowHeight = 64;

  if (loading) {
    return (
      <section className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
        <div className="flex items-center gap-2 text-sm text-slate-500">
          <Loader2 size={16} className="animate-spin text-slate-400" />
          <span>Loading your schedule...</span>
        </div>
      </section>
    );
  }

  if (error) {
    return (
      <section className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-sm text-red-600">{error}</p>
          <button
            type="button"
            onClick={onRetry}
            className="inline-flex items-center justify-center rounded-lg border border-red-200 px-3 py-2 text-sm font-medium text-red-700 hover:bg-red-50"
          >
            Retry
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 className="text-lg font-semibold text-slate-800">Week</h3>
          <p className="mt-1 text-sm text-slate-500">{formatWeekLabel(normalizedWeekMonday)}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={onPrevWeek}
            className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
          >
            Previous week
          </button>
          <button
            type="button"
            onClick={onToday}
            className="inline-flex items-center justify-center rounded-lg bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
          >
            Today
          </button>
          <button
            type="button"
            onClick={onNextWeek}
            className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
          >
            Next week
          </button>
        </div>
      </div>

      {visibleEntries.length === 0 ? (
        <div className="mt-6 rounded-xl border border-dashed border-slate-300 bg-slate-50 p-4 text-sm text-slate-600">
          You have no schedules assigned this week. Manage schedules from each classroom.
        </div>
      ) : (
        <>
          <div className="mt-6 space-y-4 md:hidden">
            {DAYS.map((day) => {
              const dayEntries = entriesByDay.get(day.key) ?? [];
              if (dayEntries.length === 0) return null;

              return (
                <div key={day.key} className="rounded-xl border border-slate-200 bg-slate-50 p-4">
                  <h4 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
                    {day.full}
                  </h4>
                  <ul className="mt-3 space-y-2">
                    {dayEntries.map((entry) => (
                      <li key={entry.id}>
                        <button
                          type="button"
                          onClick={() => onSelectEntry(entry)}
                          className="flex w-full items-start justify-between gap-3 rounded-lg border border-slate-200 bg-white px-3 py-3 text-left"
                        >
                          <div>
                            <p className="text-sm font-medium text-slate-800">{entry.label}</p>
                            <p className="mt-1 text-sm text-slate-600">
                              {entry.startTime}-{entry.endTime}
                            </p>
                          </div>
                          {entry.kind === 'one_off' ? (
                            <span className="rounded-full border border-amber-200 bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-700">
                              One-off
                            </span>
                          ) : null}
                        </button>
                      </li>
                    ))}
                  </ul>
                </div>
              );
            })}
          </div>

          <div className="mt-6 hidden overflow-hidden rounded-lg border border-slate-200 md:block">
            <div className="grid grid-cols-[60px_repeat(5,1fr)] border-b border-slate-200 bg-slate-50">
              <div className="flex items-center justify-center p-2 text-xs font-semibold uppercase tracking-wider text-slate-400">
                Time
              </div>
              {DAYS.map((day) => (
                <div
                  key={day.key}
                  className="border-l border-slate-200 p-2 text-center text-xs font-semibold uppercase tracking-wider text-slate-500"
                >
                  {day.full}
                </div>
              ))}
            </div>

            <div className="max-h-[640px] overflow-y-auto">
              <div
                className="grid grid-cols-[60px_repeat(5,1fr)]"
                style={{ height: HOURS.length * rowHeight }}
              >
                <div className="relative border-r border-slate-200">
                  {HOURS.map((hour) => (
                    <div
                      key={hour}
                      className="absolute w-full -translate-y-1/2 pr-2 text-right text-[10px] text-slate-400"
                      style={{ top: (hour - START_HOUR) * rowHeight }}
                    >
                      {String(hour).padStart(2, '0')}:00
                    </div>
                  ))}
                </div>

                {DAYS.map((day) => (
                  <TeacherCalendarDayColumn
                    key={day.key}
                    entries={entriesByDay.get(day.key) ?? []}
                    rowHeight={rowHeight}
                    colorMap={colorMap}
                    onSelectEntry={onSelectEntry}
                  />
                ))}
              </div>
            </div>
          </div>
        </>
      )}
    </section>
  );
};
