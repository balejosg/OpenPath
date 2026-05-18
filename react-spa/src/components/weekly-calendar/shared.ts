import type { ScheduleWithPermissions } from '../../types';

export const DAYS = [
  { key: 1, short: 'Mon', full: 'Monday' },
  { key: 2, short: 'Tue', full: 'Tuesday' },
  { key: 3, short: 'Wed', full: 'Wednesday' },
  { key: 4, short: 'Thu', full: 'Thursday' },
  { key: 5, short: 'Fri', full: 'Friday' },
] as const;

export const START_HOUR = 7;
export const END_HOUR = 21;
export const HOURS = Array.from({ length: END_HOUR - START_HOUR }, (_, i) => START_HOUR + i);

export const GROUP_COLORS = [
  {
    bg: 'bg-blue-100',
    border: 'border-blue-300',
    text: 'text-blue-800',
    hover: 'hover:bg-blue-200',
  },
  {
    bg: 'bg-emerald-100',
    border: 'border-emerald-300',
    text: 'text-emerald-800',
    hover: 'hover:bg-emerald-200',
  },
  {
    bg: 'bg-violet-100',
    border: 'border-violet-300',
    text: 'text-violet-800',
    hover: 'hover:bg-violet-200',
  },
  {
    bg: 'bg-amber-100',
    border: 'border-amber-300',
    text: 'text-amber-800',
    hover: 'hover:bg-amber-200',
  },
  {
    bg: 'bg-rose-100',
    border: 'border-rose-300',
    text: 'text-rose-800',
    hover: 'hover:bg-rose-200',
  },
  {
    bg: 'bg-cyan-100',
    border: 'border-cyan-300',
    text: 'text-cyan-800',
    hover: 'hover:bg-cyan-200',
  },
  {
    bg: 'bg-orange-100',
    border: 'border-orange-300',
    text: 'text-orange-800',
    hover: 'hover:bg-orange-200',
  },
] as const;

export const RESERVED_COLOR = {
  bg: 'bg-slate-100',
  border: 'border-slate-300',
  text: 'text-slate-700',
  hover: 'hover:bg-slate-200',
};

export interface WeeklyCalendarGroupInfo {
  id: string;
  displayName: string;
}

export interface WeeklyCalendarDayColumnProps {
  dayKey: number;
  dayFull: string;
  daySchedules: ScheduleWithPermissions[];
  groupColorMap: Map<string, number>;
  groupNameMap: Map<string, string>;
  rowHeight: number;
  onAddClick: (dayOfWeek: number, startTime: string) => void;
  onEditClick: (schedule: ScheduleWithPermissions) => void;
  onDeleteClick: (schedule: ScheduleWithPermissions) => void;
}

export function minutesToPx(minutes: number, rowHeight: number): number {
  return (minutes / 60) * rowHeight;
}
