import React from 'react';

import type { TeacherScheduleEntry } from './teacher-schedule-model';
import { END_HOUR, GROUP_COLORS, HOURS, START_HOUR, minutesToPx } from '../weekly-calendar/shared';
import { cn } from '../../lib/utils';

export interface TeacherCalendarDayColumnProps {
  entries: readonly TeacherScheduleEntry[];
  rowHeight: number;
  colorMap: ReadonlyMap<string, number>;
  onSelectEntry: (entry: TeacherScheduleEntry) => void;
}

export const TeacherCalendarDayColumn: React.FC<TeacherCalendarDayColumnProps> = ({
  entries,
  rowHeight,
  colorMap,
  onSelectEntry,
}) => (
  <div className="relative border-l border-slate-200">
    {HOURS.map((hour) => (
      <div
        key={hour}
        className="absolute w-full border-t border-slate-100"
        style={{ top: (hour - START_HOUR) * rowHeight, height: rowHeight }}
      />
    ))}

    {entries.map((entry) => {
      const startMin = entry.startMinutes - START_HOUR * 60;
      const endMin = entry.endMinutes - START_HOUR * 60;
      const visibleStartMin = Math.max(startMin, 0);
      const visibleEndMin = Math.min(endMin, (END_HOUR - START_HOUR) * 60);
      const durationMin = visibleEndMin - visibleStartMin;
      if (durationMin <= 0) return null;

      const top = minutesToPx(visibleStartMin, rowHeight);
      const height = Math.max(minutesToPx(durationMin, rowHeight), 28);
      const laneCount = Math.max(entry.laneCount, 1);
      const leftPercent = (entry.laneIndex / laneCount) * 100;
      const widthPercent = 100 / laneCount;
      const colorIdx = colorMap.get(entry.colorKey) ?? 0;
      const color = GROUP_COLORS[colorIdx] ?? GROUP_COLORS[0];

      return (
        <button
          key={entry.id}
          type="button"
          className={cn(
            'absolute rounded-md border px-2 py-1 text-left shadow-sm transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500',
            color.bg,
            color.border,
            color.hover,
            entry.kind === 'one_off' ? 'border-dashed' : 'border-solid'
          )}
          style={{
            top,
            height,
            left: `calc(${leftPercent}% + 0.125rem)`,
            width: `calc(${widthPercent}% - 0.25rem)`,
          }}
          aria-label={`View details ${entry.label} ${entry.startTime}-${entry.endTime}`}
          data-kind={entry.kind}
          onClick={() => onSelectEntry(entry)}
        >
          <div className="flex h-full flex-col justify-between gap-1 overflow-hidden">
            <span className={cn('truncate text-xs font-semibold leading-tight', color.text)}>
              {entry.label}
            </span>
            {height >= 40 ? (
              <span className={cn('text-[11px] opacity-80', color.text)}>
                {entry.startTime}-{entry.endTime}
              </span>
            ) : null}
          </div>
        </button>
      );
    })}
  </div>
);
