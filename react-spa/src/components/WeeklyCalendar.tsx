import React from 'react';
import type { ScheduleWithPermissions } from '../types';
import { WeeklyCalendarDayColumn } from './weekly-calendar/WeeklyCalendarDayColumn';
import { WeeklyCalendarHeader } from './weekly-calendar/WeeklyCalendarHeader';
import { DAYS, HOURS, START_HOUR, type WeeklyCalendarGroupInfo } from './weekly-calendar/shared';
import { useWeeklyCalendarLayout } from './weekly-calendar/useWeeklyCalendarLayout';
import { cn } from '../lib/utils';

interface WeeklyCalendarProps {
  schedules: ScheduleWithPermissions[];
  groups: WeeklyCalendarGroupInfo[];
  onAddClick: (dayOfWeek: number, startTime: string) => void;
  onEditClick: (schedule: ScheduleWithPermissions) => void;
  onDeleteClick: (schedule: ScheduleWithPermissions) => void;
  fillAvailable?: boolean;
}

const WeeklyCalendar: React.FC<WeeklyCalendarProps> = ({
  schedules,
  groups,
  onAddClick,
  onEditClick,
  onDeleteClick,
  fillAvailable = false,
}) => {
  const rowHeight = 64;
  const { groupColorMap, groupNameMap, byDay, weekDates, weekMonthLabel, todayKey } =
    useWeeklyCalendarLayout(schedules, groups);

  return (
    <div
      className={cn(
        'border border-slate-200 rounded-lg bg-white overflow-hidden shadow-sm',
        fillAvailable ? 'md:min-h-0 md:flex-1 md:flex md:flex-col' : ''
      )}
    >
      <WeeklyCalendarHeader
        weekMonthLabel={weekMonthLabel}
        weekDates={weekDates}
        todayKey={todayKey}
      />

      <div
        className={cn(
          fillAvailable
            ? 'max-h-[520px] overflow-y-auto md:max-h-none md:min-h-0 md:flex-1'
            : 'max-h-[520px] md:max-h-[640px] overflow-y-auto'
        )}
      >
        <div
          className="grid grid-cols-[60px_repeat(5,1fr)] relative"
          style={{ height: HOURS.length * rowHeight }}
        >
          <div className="relative border-r border-slate-200">
            {HOURS.map((h) => (
              <div
                key={h}
                className="absolute w-full text-right pr-2 text-[10px] text-slate-400 -translate-y-1/2"
                style={{ top: (h - START_HOUR) * rowHeight }}
              >
                {String(h).padStart(2, '0')}:00
              </div>
            ))}
          </div>

          {DAYS.map((d) => (
            <WeeklyCalendarDayColumn
              key={d.key}
              dayKey={d.key}
              dayFull={d.full}
              daySchedules={byDay.get(d.key) ?? []}
              groupColorMap={groupColorMap}
              groupNameMap={groupNameMap}
              rowHeight={rowHeight}
              onAddClick={onAddClick}
              onEditClick={onEditClick}
              onDeleteClick={onDeleteClick}
            />
          ))}
        </div>
      </div>
    </div>
  );
};

export default WeeklyCalendar;
